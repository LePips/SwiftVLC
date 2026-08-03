#!/usr/bin/env python3
"""Create, verify, and compare complete libVLC XCFramework provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import stat
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 3
SDK_BY_PLATFORM = {
    ("ios", None): "iphoneos",
    ("ios", "simulator"): "iphonesimulator",
    ("ios", "maccatalyst"): "macosx",
    ("macos", None): "macosx",
    ("tvos", None): "appletvos",
    ("tvos", "simulator"): "appletvsimulator",
    ("xros", None): "xros",
    ("xros", "simulator"): "xrsimulator",
}


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def run(*command: str) -> str:
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        fail(f"command failed ({' '.join(command)}): {detail.strip()}")
    return result.stdout.strip()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        fail(f"cannot hash {path}: {error}")
    return digest.hexdigest()


def update_field(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def tree_digest(root: Path) -> str:
    if not root.is_dir():
        fail(f"artifact directory not found: {root}")

    digest = hashlib.sha256(b"SwiftVLC artifact tree digest v1\0")
    entries = sorted(
        root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()
    )
    if not entries:
        fail(f"artifact directory is empty: {root}")

    for path in entries:
        relative = path.relative_to(root).as_posix().encode()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode).to_bytes(4, "big")
        if stat.S_ISDIR(metadata.st_mode):
            kind, payload = b"directory", b""
        elif stat.S_ISREG(metadata.st_mode):
            kind, payload = b"file", bytes.fromhex(sha256_file(path))
        elif stat.S_ISLNK(metadata.st_mode):
            kind, payload = b"symlink", os.readlink(path).encode()
        else:
            fail(f"unsupported artifact entry type: {path}")
        update_field(digest, kind)
        update_field(digest, relative)
        update_field(digest, mode)
        update_field(digest, payload)
    return digest.hexdigest()


def manifest_entries(path: Path) -> list[dict[str, str]]:
    entries: list[dict[str, str]] = []
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        fail(f"cannot read patch manifest {path}: {error}")
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) != 2 or len(fields[0]) != 64:
            fail(f"invalid patch manifest entry at {path}:{number}")
        entries.append({"sha256": fields[0], "file": fields[1]})
    if not entries:
        fail(f"patch manifest has no entries: {path}")
    return entries


def named_file_records(values: list[str]) -> list[dict[str, str]]:
    records: list[dict[str, str]] = []
    names: set[str] = set()
    for value in values:
        if "=" not in value:
            fail(f"build configuration file must be NAME=PATH: {value}")
        name, raw_path = value.split("=", 1)
        path = Path(raw_path).resolve()
        if not name or name in names or not path.is_file():
            fail(f"invalid or duplicate build configuration file: {value}")
        names.add(name)
        records.append({"name": name, "sha256": sha256_file(path)})
    if not records:
        fail("at least one build configuration file is required")
    return sorted(records, key=lambda record: record["name"])


def invocation_id(value: str) -> str:
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        fail(f"build invocation ID is not a UUID: {value}")


def contrib_manifest(vlc_source: Path) -> dict[str, Any]:
    root = vlc_source / "contrib" / "src"
    checksum_files = sorted(root.glob("*/SHA512SUMS"), key=lambda path: path.as_posix())
    if not checksum_files:
        fail(f"no contrib SHA512SUMS files found under {root}")
    digest = hashlib.sha256(b"SwiftVLC VLC contrib checksum manifest v1\0")
    for path in checksum_files:
        update_field(digest, path.relative_to(root).as_posix().encode())
        update_field(digest, path.read_bytes())
    return {
        "algorithm": "swiftvlc-vlc-contrib-checksums-v1",
        "fileCount": len(checksum_files),
        "sha256": digest.hexdigest(),
    }


def archive_member_digest(archive: Path) -> dict[str, Any]:
    architectures = sorted(run("lipo", "-archs", str(archive)).split())
    if not architectures:
        fail(f"static archive has no architectures: {archive}")

    digest = hashlib.sha256(b"SwiftVLC archive member manifest v2\0")
    member_count = 0
    with tempfile.TemporaryDirectory(prefix="swiftvlc-archive-") as temporary:
        temporary_root = Path(temporary)
        for architecture in architectures:
            candidate = archive
            if len(architectures) > 1:
                candidate = temporary_root / f"{architecture}.a"
                run(
                    "lipo",
                    str(archive),
                    "-thin",
                    architecture,
                    "-output",
                    str(candidate),
                )
            members = run("ar", "-t", str(candidate)).splitlines()
            if not members:
                fail(f"static archive has no members for {architecture}: {archive}")
            update_field(digest, architecture.encode())
            for member in members:
                update_field(digest, member.encode())
            member_count += len(members)

    return {
        "memberCount": member_count,
        "manifestSha256": digest.hexdigest(),
    }


def sdk_details(name: str) -> dict[str, str]:
    return {
        "canonicalName": name,
        "version": run("xcrun", "--sdk", name, "--show-sdk-version"),
        "buildVersion": run("xcrun", "--sdk", name, "--show-sdk-build-version"),
    }


def xcode_details() -> dict[str, str]:
    lines = run("xcodebuild", "-version").splitlines()
    if len(lines) < 2 or not lines[0].startswith("Xcode "):
        fail("xcodebuild -version returned an unexpected value")
    return {
        "version": lines[0].removeprefix("Xcode "),
        "buildVersion": lines[1].removeprefix("Build version "),
    }


def first_line(*command: str) -> str:
    output = run(*command).splitlines()
    if not output:
        fail(f"command produced no version: {' '.join(command)}")
    return output[0]


def load_xcframework_libraries(xcframework: Path) -> list[dict[str, Any]]:
    info_path = xcframework / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read {info_path}: {error}")
    libraries = info.get("AvailableLibraries")
    if not isinstance(libraries, list) or not libraries:
        fail(f"{info_path} has no AvailableLibraries")
    return libraries


def slice_records(
    xcframework: Path,
    deployment_targets: dict[str, str],
) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    sdk_cache: dict[str, dict[str, str]] = {}
    for library in load_xcframework_libraries(xcframework):
        identifier = library.get("LibraryIdentifier")
        platform_name = library.get("SupportedPlatform")
        variant = library.get("SupportedPlatformVariant")
        architectures = library.get("SupportedArchitectures")
        library_path = library.get("LibraryPath")
        headers_path = library.get("HeadersPath")
        if not all(
            (identifier, platform_name, architectures, library_path, headers_path)
        ):
            fail("XCFramework library record is missing required identity fields")
        sdk_name = SDK_BY_PLATFORM.get((platform_name, variant))
        if sdk_name is None:
            fail(f"unsupported XCFramework platform/variant: {platform_name}/{variant}")
        sdk_cache.setdefault(sdk_name, sdk_details(sdk_name))
        archive = xcframework / identifier / library_path
        headers = xcframework / identifier / headers_path
        if not archive.is_file() or not headers.is_dir():
            fail(f"slice {identifier} is missing its library or headers")
        deployment_key = "catalyst" if variant == "maccatalyst" else platform_name
        target = deployment_targets.get(deployment_key)
        if target is None:
            fail(f"no deployment target supplied for {deployment_key}")
        record = {
            "identifier": identifier,
            "platform": platform_name,
            "architectures": architectures,
            "deploymentTarget": target,
            "sdk": sdk_cache[sdk_name],
            "librarySha256": sha256_file(archive),
            "headersTreeDigest": tree_digest(headers),
            **archive_member_digest(archive),
        }
        if variant is not None:
            record["variant"] = variant
        records.append(record)
    return sorted(records, key=lambda record: record["identifier"])


def parse_deployment_targets(values: list[str]) -> dict[str, str]:
    targets: dict[str, str] = {}
    for value in values:
        if "=" not in value:
            fail(f"deployment target must be PLATFORM=VERSION: {value}")
        name, version = value.split("=", 1)
        if not name or not version or name in targets:
            fail(f"invalid or duplicate deployment target: {value}")
        targets[name] = version
    return targets


def create(arguments: argparse.Namespace) -> None:
    xcframework = arguments.xcframework.resolve()
    patch_manifest = (
        arguments.patch_manifest.resolve() if arguments.patch_manifest else None
    )
    patch_record = (
        {
            "sha256": sha256_file(patch_manifest),
            "entries": manifest_entries(patch_manifest),
        }
        if patch_manifest is not None
        else {"sha256": "none", "entries": []}
    )
    record = {
        "schemaVersion": SCHEMA_VERSION,
        "vlcSourceRevision": arguments.source_revision,
        "pinnedRevision": arguments.pinned_revision,
        "patchManifest": patch_record,
        "buildConfiguration": named_file_records(arguments.build_configuration_file),
        "contribChecksums": contrib_manifest(arguments.vlc_source.resolve()),
        "build": {
            "assertionsEnabled": arguments.assertions_enabled,
            "makeFlags": arguments.make_flags,
            "sourceDateEpoch": arguments.source_date_epoch,
            "cleanBuild": arguments.clean_build,
            "invocationId": invocation_id(arguments.build_invocation_id),
            "hostArchitecture": platform.machine(),
            "xcode": xcode_details(),
            "clangVersion": first_line("xcrun", "clang", "--version"),
            "swiftVersion": first_line("xcrun", "swift", "--version"),
            "builtAt": datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
        },
        "xcframeworkTreeDigest": tree_digest(xcframework),
        "slices": slice_records(
            xcframework,
            parse_deployment_targets(arguments.deployment_target),
        ),
    }
    arguments.output.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")


def load_record(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        fail(f"cannot read provenance {path}: {error}")
    if value.get("schemaVersion") != SCHEMA_VERSION:
        fail(f"{path} is not schema version {SCHEMA_VERSION}")
    return value


def verify(arguments: argparse.Namespace) -> None:
    record = load_record(arguments.provenance)
    xcframework = arguments.xcframework.resolve()
    if record.get("pinnedRevision") != arguments.pinned_revision:
        fail("provenance engine pin does not match the repository")
    manifest = record.get("patchManifest", {})
    if manifest.get("sha256") != sha256_file(arguments.patch_manifest):
        fail("provenance patch manifest does not match the repository")
    if manifest.get("entries") != manifest_entries(arguments.patch_manifest):
        fail("provenance patch order does not match the repository")
    if record.get("buildConfiguration") != named_file_records(
        arguments.build_configuration_file
    ):
        fail("provenance build configuration does not match the repository")
    if record.get("xcframeworkTreeDigest") != tree_digest(xcframework):
        fail("XCFramework tree digest does not match provenance")
    recorded_slices = {item["identifier"]: item for item in record.get("slices", [])}
    actual_libraries = load_xcframework_libraries(xcframework)
    actual_identifiers = {item["LibraryIdentifier"] for item in actual_libraries}
    if set(recorded_slices) != actual_identifiers:
        fail("XCFramework slice set does not match provenance")
    for library in actual_libraries:
        identifier = library["LibraryIdentifier"]
        recorded = recorded_slices[identifier]
        root = xcframework / identifier
        archive = root / library["LibraryPath"]
        headers = root / library["HeadersPath"]
        members = archive_member_digest(archive)
        if recorded.get("librarySha256") != sha256_file(archive):
            fail(f"slice {identifier} library checksum does not match provenance")
        if recorded.get("headersTreeDigest") != tree_digest(headers):
            fail(f"slice {identifier} headers digest does not match provenance")
        if any(recorded.get(key) != value for key, value in members.items()):
            fail(
                f"slice {identifier} archive member manifest does not match provenance"
            )
    print(
        f"libVLC provenance verified: {len(recorded_slices)} slice(s), "
        f"tree {record['xcframeworkTreeDigest'][:12]}…"
    )


def normalized_build_inputs(record: dict[str, Any]) -> dict[str, Any]:
    return {
        key: value
        for key, value in record.get("build", {}).items()
        if key not in {"builtAt", "invocationId"}
    }


def slice_inputs(record: dict[str, Any]) -> dict[str, dict[str, Any]]:
    artifact_keys = {
        "librarySha256",
        "headersTreeDigest",
        "manifestSha256",
        "memberCount",
    }
    return {
        item["identifier"]: {
            key: value for key, value in item.items() if key not in artifact_keys
        }
        for item in record.get("slices", [])
    }


def compare(arguments: argparse.Namespace) -> None:
    first = load_record(arguments.first)
    second = load_record(arguments.second)
    input_keys = (
        "vlcSourceRevision",
        "pinnedRevision",
        "patchManifest",
        "buildConfiguration",
        "contribChecksums",
    )
    for key in input_keys:
        if first.get(key) != second.get(key):
            fail(f"build inputs differ at {key}")
    if normalized_build_inputs(first) != normalized_build_inputs(second):
        fail("build toolchain, host, flags, or assertion inputs differ")
    if slice_inputs(first) != slice_inputs(second):
        fail("build slice SDK, target, platform, or architecture inputs differ")
    first_build = first.get("build", {})
    second_build = second.get("build", {})
    if not first_build.get("cleanBuild") or not second_build.get("cleanBuild"):
        fail("reproducibility proof requires two clean builds")
    first_invocation = first_build.get("invocationId")
    second_invocation = second_build.get("invocationId")
    if not first_invocation or first_invocation == second_invocation:
        fail("reproducibility proof requires independent build invocations")
    first_slices = {item["identifier"]: item for item in first.get("slices", [])}
    second_slices = {item["identifier"]: item for item in second.get("slices", [])}
    if set(first_slices) != set(second_slices):
        fail("build slice sets differ")
    differences = []
    for identifier in sorted(first_slices):
        before = first_slices[identifier]
        after = second_slices[identifier]
        for key in (
            "librarySha256",
            "headersTreeDigest",
            "manifestSha256",
            "memberCount",
        ):
            if before.get(key) != after.get(key):
                differences.append(f"{identifier}.{key}")
    if first.get("xcframeworkTreeDigest") != second.get("xcframeworkTreeDigest"):
        differences.append("xcframeworkTreeDigest")
    if differences:
        fail("clean builds are not byte-reproducible: " + ", ".join(differences))
    if arguments.output is not None:
        proof = {
            "schemaVersion": 2,
            "vlcSourceRevision": first["vlcSourceRevision"],
            "pinnedRevision": first["pinnedRevision"],
            "patchManifestSha256": first["patchManifest"]["sha256"],
            "buildConfiguration": first["buildConfiguration"],
            "contribChecksums": first["contribChecksums"],
            "buildInputs": normalized_build_inputs(first),
            "sliceInputs": slice_inputs(first),
            "firstBuiltAt": first["build"]["builtAt"],
            "secondBuiltAt": second["build"]["builtAt"],
            "firstInvocationId": first_invocation,
            "secondInvocationId": second_invocation,
            "xcframeworkTreeDigest": first["xcframeworkTreeDigest"],
            "slices": {
                identifier: {
                    key: first_slices[identifier][key]
                    for key in (
                        "librarySha256",
                        "headersTreeDigest",
                        "manifestSha256",
                        "memberCount",
                    )
                }
                for identifier in sorted(first_slices)
            },
        }
        arguments.output.write_text(json.dumps(proof, indent=2, sort_keys=True) + "\n")
    print(
        f"libVLC clean builds are byte-reproducible: "
        f"{first['xcframeworkTreeDigest']}"
    )


def verify_proof(arguments: argparse.Namespace) -> None:
    provenance = load_record(arguments.provenance)
    try:
        proof = json.loads(arguments.proof.read_text())
    except (OSError, ValueError) as error:
        fail(f"cannot read reproducibility proof {arguments.proof}: {error}")
    if proof.get("schemaVersion") != 2:
        fail("reproducibility proof has an unsupported schema")
    expected = {
        "vlcSourceRevision": provenance["vlcSourceRevision"],
        "pinnedRevision": provenance["pinnedRevision"],
        "patchManifestSha256": provenance["patchManifest"]["sha256"],
        "buildConfiguration": provenance["buildConfiguration"],
        "contribChecksums": provenance["contribChecksums"],
        "buildInputs": normalized_build_inputs(provenance),
        "sliceInputs": slice_inputs(provenance),
        "xcframeworkTreeDigest": provenance["xcframeworkTreeDigest"],
    }
    for key, value in expected.items():
        if proof.get(key) != value:
            fail(f"reproducibility proof does not match provenance at {key}")
    if not provenance.get("build", {}).get("cleanBuild"):
        fail("provenance does not describe a clean build")
    invocation_ids = {
        proof.get("firstInvocationId"),
        proof.get("secondInvocationId"),
    }
    if None in invocation_ids or len(invocation_ids) != 2:
        fail("reproducibility proof does not describe independent builds")
    if provenance["build"].get("invocationId") not in invocation_ids:
        fail("provenance build invocation is absent from reproducibility proof")
    print(
        f"libVLC reproducibility proof verified: "
        f"{proof['xcframeworkTreeDigest'][:12]}…"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    create_parser = commands.add_parser("create")
    create_parser.add_argument("--xcframework", type=Path, required=True)
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--vlc-source", type=Path, required=True)
    create_parser.add_argument("--source-revision", required=True)
    create_parser.add_argument("--pinned-revision", required=True)
    create_parser.add_argument("--source-date-epoch", type=int, required=True)
    create_parser.add_argument("--patch-manifest", type=Path)
    create_parser.add_argument(
        "--build-configuration-file",
        action="append",
        default=[],
        required=True,
    )
    create_parser.add_argument("--assertions-enabled", action="store_true")
    create_parser.add_argument("--clean-build", action="store_true")
    create_parser.add_argument("--build-invocation-id", required=True)
    create_parser.add_argument("--make-flags", required=True)
    create_parser.add_argument(
        "--deployment-target",
        action="append",
        default=[],
        required=True,
    )
    create_parser.set_defaults(function=create)

    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--provenance", type=Path, required=True)
    verify_parser.add_argument("--xcframework", type=Path, required=True)
    verify_parser.add_argument("--pinned-revision", required=True)
    verify_parser.add_argument("--patch-manifest", type=Path, required=True)
    verify_parser.add_argument(
        "--build-configuration-file",
        action="append",
        default=[],
        required=True,
    )
    verify_parser.set_defaults(function=verify)

    compare_parser = commands.add_parser("compare")
    compare_parser.add_argument("--first", type=Path, required=True)
    compare_parser.add_argument("--second", type=Path, required=True)
    compare_parser.add_argument("--output", type=Path)
    compare_parser.set_defaults(function=compare)

    proof_parser = commands.add_parser("verify-proof")
    proof_parser.add_argument("--proof", type=Path, required=True)
    proof_parser.add_argument("--provenance", type=Path, required=True)
    proof_parser.set_defaults(function=verify_proof)

    arguments = parser.parse_args()
    arguments.function(arguments)


if __name__ == "__main__":
    main()
