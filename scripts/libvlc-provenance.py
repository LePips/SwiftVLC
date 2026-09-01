#!/usr/bin/env python3
"""Create, verify, and compare complete libVLC XCFramework provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import stat
import subprocess
import tempfile
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 4
PROOF_SCHEMA_VERSION = 4
ARTIFACT_IDENTITY_ALGORITHM = "swiftvlc-tree-v1"
BUILD_TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
FULL_REVISION_PATTERN = re.compile(r"[0-9a-f]{40}")
PINNED_REVISION_PATTERN = re.compile(r"[0-9a-f]{7,40}")
PROOF_SLICE_KEYS = (
    "librarySha256",
    "headersTreeDigest",
    "manifestSha256",
    "memberCount",
)
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


def reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    """Decode one JSON object while refusing ambiguous duplicate names."""
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise ValueError(f"duplicate JSON key: {key!r}")
        output[key] = value
    return output


def reject_non_finite_json(value: str) -> None:
    raise ValueError(f"non-finite JSON number: {value}")


def load_json_object(path: Path, description: str) -> dict[str, Any]:
    """Load strict JSON: one object, unique keys, and finite standard values."""
    try:
        value = json.loads(
            path.read_text(),
            object_pairs_hook=reject_duplicate_json_keys,
            parse_constant=reject_non_finite_json,
        )
    except (OSError, ValueError, RecursionError) as error:
        fail(f"cannot read {description} {path}: {error}")
    if type(value) is not dict:
        fail(f"{path} is not a {description} object")
    return value


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


def write_json_atomic(path: Path, value: Any) -> None:
    """Write JSON beside its destination and atomically publish the complete file."""
    parent = path.parent.resolve()
    if not parent.is_dir():
        fail(f"output directory not found: {parent}")
    descriptor = -1
    temporary_path: Path | None = None
    try:
        descriptor, raw_temporary = tempfile.mkstemp(
            dir=parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        )
        temporary_path = Path(raw_temporary)
        with os.fdopen(descriptor, "w") as output:
            descriptor = -1
            json.dump(value, output, allow_nan=False, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_path, path)
        temporary_path = None
    except (OSError, TypeError, ValueError) as error:
        fail(f"cannot write {path}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass


def update_field(digest: Any, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def tree_digest(root: Path) -> str:
    try:
        root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        fail(f"cannot resolve artifact directory {root}: {error}")
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
            raw_target = os.readlink(path)
            try:
                resolved_target = path.resolve(strict=True)
                resolved_target.relative_to(root)
            except (OSError, RuntimeError, ValueError):
                fail(f"artifact symlink target escapes the tree or is broken: {path}")
            kind, payload = b"symlink", os.fsencode(raw_target)
        else:
            fail(f"unsupported artifact entry type: {path}")
        update_field(digest, kind)
        update_field(digest, relative)
        update_field(digest, mode)
        update_field(digest, payload)
    return digest.hexdigest()


def resolved_output_location(path: Path, description: str) -> Path:
    """Resolve parent aliases without following the destination directory entry."""
    try:
        parent = path.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        fail(f"cannot resolve {description} parent {path.parent}: {error}")
    if not parent.is_dir():
        fail(f"{description} parent is not a directory: {parent}")
    return parent / path.name


def reject_output_within_tree(output: Path, root: Path, description: str) -> None:
    """Prevent a successful write from invalidating an already-hashed artifact."""
    destination = resolved_output_location(output, description)
    try:
        resolved_root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        fail(f"cannot resolve artifact directory {root}: {error}")
    try:
        destination.relative_to(resolved_root)
    except ValueError:
        return
    fail(f"{description} cannot be written inside the XCFramework")


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


def require_exact_object(
    value: Any,
    required_keys: set[str],
    description: str,
    optional_keys: set[str] | None = None,
) -> dict[str, Any]:
    if type(value) is not dict:
        fail(f"{description} is not an object")
    optional = optional_keys or set()
    actual_keys = set(value)
    missing = sorted(required_keys - actual_keys)
    unexpected = sorted(actual_keys - required_keys - optional)
    if missing:
        fail(f"{description} is missing fields: {', '.join(missing)}")
    if unexpected:
        fail(f"{description} has unsupported fields: {', '.join(unexpected)}")
    return value


def require_string(value: Any, description: str, *, allow_empty: bool = False) -> str:
    if type(value) is not str or (not allow_empty and not value):
        fail(f"{description} is not a valid string")
    return value


def require_boolean(value: Any, description: str) -> bool:
    if type(value) is not bool:
        fail(f"{description} is not a boolean")
    return value


def require_integer(
    value: Any,
    description: str,
    *,
    minimum: int = 0,
) -> int:
    if type(value) is not int or value < minimum:
        fail(f"{description} is not an integer greater than or equal to {minimum}")
    return value


def require_sha256(value: Any, description: str) -> str:
    if type(value) is not str or SHA256_PATTERN.fullmatch(value) is None:
        fail(f"{description} is not a lowercase SHA-256 digest")
    return value


def require_full_revision(value: Any, description: str) -> str:
    if type(value) is not str or FULL_REVISION_PATTERN.fullmatch(value) is None:
        fail(f"{description} is not a full lowercase 40-hex Git revision")
    return value


def require_pinned_revision(value: Any, description: str) -> str:
    if type(value) is not str or PINNED_REVISION_PATTERN.fullmatch(value) is None:
        fail(f"{description} is not a lowercase 7-40 hex Git revision")
    return value


def parse_build_timestamp(value: Any, description: str) -> datetime:
    raw_timestamp = require_string(value, description)
    try:
        timestamp = datetime.strptime(raw_timestamp, BUILD_TIMESTAMP_FORMAT).replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        fail(
            f"{description} is not canonical UTC "
            f"({BUILD_TIMESTAMP_FORMAT}): {raw_timestamp!r}"
        )
    if timestamp.strftime(BUILD_TIMESTAMP_FORMAT) != raw_timestamp:
        fail(
            f"{description} is not canonical UTC "
            f"({BUILD_TIMESTAMP_FORMAT}): {raw_timestamp!r}"
        )
    return timestamp


def validate_patch_manifest(value: Any, description: str) -> None:
    manifest = require_exact_object(
        value,
        {"sha256", "entries"},
        description,
    )
    checksum = manifest["sha256"]
    if checksum != "none":
        require_sha256(checksum, f"{description} checksum")
    entries = manifest["entries"]
    if type(entries) is not list:
        fail(f"{description} entries are not an array")
    if checksum == "none" and entries:
        fail(f"{description} without a checksum cannot contain entries")
    if checksum != "none" and not entries:
        fail(f"{description} with a checksum has no entries")

    files: set[str] = set()
    for index, raw_entry in enumerate(entries):
        entry_description = f"{description} entry at index {index}"
        entry = require_exact_object(
            raw_entry,
            {"sha256", "file"},
            entry_description,
        )
        require_sha256(entry["sha256"], f"{entry_description} checksum")
        filename = require_string(entry["file"], f"{entry_description} file")
        relative = Path(filename)
        if (
            relative.is_absolute()
            or ".." in relative.parts
            or relative.name != filename
        ):
            fail(f"{entry_description} file is not a confined filename")
        if filename in files:
            fail(f"{description} contains duplicate file {filename}")
        files.add(filename)


def validate_build_configuration(value: Any, description: str) -> None:
    if type(value) is not list or not value:
        fail(f"{description} is not a non-empty array")
    names: list[str] = []
    for index, raw_record in enumerate(value):
        record_description = f"{description} entry at index {index}"
        record = require_exact_object(
            raw_record,
            {"name", "sha256"},
            record_description,
        )
        name = require_string(record["name"], f"{record_description} name")
        if name in names:
            fail(f"{description} contains duplicate name {name}")
        names.append(name)
        require_sha256(record["sha256"], f"{record_description} checksum")
    if names != sorted(names):
        fail(f"{description} is not in canonical name order")


def validate_contrib_checksums(value: Any, description: str) -> None:
    record = require_exact_object(
        value,
        {"algorithm", "fileCount", "sha256"},
        description,
    )
    if record["algorithm"] != "swiftvlc-vlc-contrib-checksums-v1":
        fail(f"{description} uses an unsupported algorithm")
    require_integer(record["fileCount"], f"{description} file count", minimum=1)
    require_sha256(record["sha256"], f"{description} checksum")


BUILD_INPUT_KEYS = {
    "assertionsEnabled",
    "makeFlags",
    "sourceDateEpoch",
    "cleanBuild",
    "hostArchitecture",
    "xcode",
    "clangVersion",
    "swiftVersion",
}
BUILD_IDENTITY_KEYS = {"invocationId", "builtAt"}


def validate_build_record(
    value: Any,
    description: str,
    *,
    include_identity: bool,
    require_clean: bool = False,
) -> None:
    required_keys = set(BUILD_INPUT_KEYS)
    if include_identity:
        required_keys.update(BUILD_IDENTITY_KEYS)
    build = require_exact_object(value, required_keys, description)
    require_boolean(build["assertionsEnabled"], f"{description} assertionsEnabled")
    require_string(build["makeFlags"], f"{description} makeFlags", allow_empty=True)
    require_integer(build["sourceDateEpoch"], f"{description} sourceDateEpoch")
    clean_build = require_boolean(build["cleanBuild"], f"{description} cleanBuild")
    if require_clean and not clean_build:
        fail(f"{description} does not describe a clean build")
    require_string(build["hostArchitecture"], f"{description} hostArchitecture")
    xcode = require_exact_object(
        build["xcode"],
        {"version", "buildVersion"},
        f"{description} Xcode",
    )
    require_string(xcode["version"], f"{description} Xcode version")
    require_string(xcode["buildVersion"], f"{description} Xcode build version")
    require_string(build["clangVersion"], f"{description} clangVersion")
    require_string(build["swiftVersion"], f"{description} swiftVersion")
    if include_identity:
        raw_invocation = require_string(
            build["invocationId"], f"{description} invocationId"
        )
        if invocation_id(raw_invocation) != raw_invocation:
            fail(f"{description} invocationId is not canonical")
        parse_build_timestamp(build["builtAt"], f"{description} builtAt")


SLICE_INPUT_KEYS = {
    "identifier",
    "platform",
    "architectures",
    "deploymentTarget",
    "sdk",
}
SLICE_ARTIFACT_KEYS = set(PROOF_SLICE_KEYS)


def validate_slice_input(
    value: Any,
    description: str,
    *,
    include_artifact: bool,
) -> str:
    required_keys = set(SLICE_INPUT_KEYS)
    if include_artifact:
        required_keys.update(SLICE_ARTIFACT_KEYS)
    item = require_exact_object(value, required_keys, description, {"variant"})
    identifier = require_string(item["identifier"], f"{description} identifier")
    if identifier in {".", ".."} or Path(identifier).name != identifier:
        fail(f"{description} identifier is not a confined directory name")
    platform_name = require_string(item["platform"], f"{description} platform")
    variant = item.get("variant")
    if "variant" in item:
        variant = require_string(variant, f"{description} variant")
    sdk_name = SDK_BY_PLATFORM.get((platform_name, variant))
    if sdk_name is None:
        fail(f"{description} has an unsupported platform/variant")

    architectures = item["architectures"]
    if (
        type(architectures) is not list
        or not architectures
        or any(
            type(architecture) is not str or not architecture
            for architecture in architectures
        )
        or len(set(architectures)) != len(architectures)
    ):
        fail(f"{description} architectures are not a unique non-empty string array")
    require_string(item["deploymentTarget"], f"{description} deploymentTarget")
    sdk = require_exact_object(
        item["sdk"],
        {"canonicalName", "version", "buildVersion"},
        f"{description} SDK",
    )
    if sdk["canonicalName"] != sdk_name:
        fail(f"{description} SDK does not match its platform/variant")
    require_string(sdk["version"], f"{description} SDK version")
    require_string(sdk["buildVersion"], f"{description} SDK build version")

    if include_artifact:
        require_sha256(item["librarySha256"], f"{description} library checksum")
        require_sha256(item["headersTreeDigest"], f"{description} headers tree digest")
        require_sha256(item["manifestSha256"], f"{description} member manifest")
        require_integer(item["memberCount"], f"{description} member count", minimum=1)
    return identifier


def validate_record(record: dict[str, Any], description: str) -> None:
    record = require_exact_object(
        record,
        {
            "schemaVersion",
            "swiftVLCRevision",
            "vlcSourceRevision",
            "pinnedRevision",
            "patchManifest",
            "buildConfiguration",
            "contribChecksums",
            "build",
            "xcframeworkTreeDigest",
            "slices",
        },
        description,
    )
    if (
        type(record["schemaVersion"]) is not int
        or record["schemaVersion"] != SCHEMA_VERSION
    ):
        fail(f"{description} is not schema version {SCHEMA_VERSION}")
    require_full_revision(
        record["swiftVLCRevision"], f"{description} SwiftVLC revision"
    )
    require_full_revision(record["vlcSourceRevision"], f"{description} VLC revision")
    require_pinned_revision(record["pinnedRevision"], f"{description} VLC pin")
    validate_patch_manifest(record["patchManifest"], f"{description} patch manifest")
    validate_build_configuration(
        record["buildConfiguration"], f"{description} build configuration"
    )
    validate_contrib_checksums(
        record["contribChecksums"], f"{description} contrib checksums"
    )
    validate_build_record(
        record["build"],
        f"{description} build",
        include_identity=True,
    )
    require_sha256(
        record["xcframeworkTreeDigest"], f"{description} XCFramework tree digest"
    )

    slices = record["slices"]
    if type(slices) is not list or not slices:
        fail(f"{description} slices are not a non-empty array")
    identifiers: list[str] = []
    for index, item in enumerate(slices):
        identifier = validate_slice_input(
            item,
            f"{description} slice at index {index}",
            include_artifact=True,
        )
        if identifier in identifiers:
            fail(f"{description} contains duplicate slice {identifier}")
        identifiers.append(identifier)
    if identifiers != sorted(identifiers):
        fail(f"{description} slices are not in canonical identifier order")


def build_identity(
    record: dict[str, Any], description: str
) -> tuple[dict[str, str], datetime]:
    build = record.get("build")
    if not isinstance(build, dict):
        fail(f"{description} build record is not an object")
    if build.get("cleanBuild") is not True:
        fail(f"{description} does not describe a clean build")

    raw_invocation = build.get("invocationId")
    if not isinstance(raw_invocation, str):
        fail(f"{description} build invocation ID is missing")
    canonical_invocation = invocation_id(raw_invocation)
    if canonical_invocation != raw_invocation:
        fail(f"{description} build invocation ID is not canonical")

    raw_timestamp = build.get("builtAt")
    timestamp = parse_build_timestamp(
        raw_timestamp,
        f"{description} build timestamp",
    )
    return {
        "invocationId": canonical_invocation,
        "builtAt": raw_timestamp,
    }, timestamp


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


def confined_slice_path(
    xcframework: Path,
    identifier: str,
    value: Any,
    field: str,
) -> Path:
    if not isinstance(value, str) or not value:
        fail(f"XCFramework slice {identifier} has an invalid {field}")
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts:
        fail(f"XCFramework slice {identifier} {field} escapes its slice directory")
    try:
        root = xcframework.resolve()
        slice_root = (root / identifier).resolve()
        candidate = (slice_root / relative).resolve()
        slice_root.relative_to(root)
        candidate.relative_to(slice_root)
    except (OSError, RuntimeError, ValueError):
        fail(f"XCFramework slice {identifier} {field} escapes the XCFramework")
    return candidate


def load_xcframework_libraries(xcframework: Path) -> list[dict[str, Any]]:
    xcframework = xcframework.resolve()
    info_path = xcframework / "Info.plist"
    try:
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"cannot read {info_path}: {error}")
    libraries = info.get("AvailableLibraries")
    if not isinstance(libraries, list) or not libraries:
        fail(f"{info_path} has no AvailableLibraries")

    validated: list[dict[str, Any]] = []
    identifiers: set[str] = set()
    for index, raw_library in enumerate(libraries):
        if not isinstance(raw_library, dict):
            fail(f"{info_path} library at index {index} is not an object")
        identifier = raw_library.get("LibraryIdentifier")
        if (
            not isinstance(identifier, str)
            or not identifier
            or identifier in {".", ".."}
            or Path(identifier).name != identifier
        ):
            fail(f"{info_path} library at index {index} has an invalid identifier")
        if identifier in identifiers:
            fail(f"{info_path} contains duplicate library identifier {identifier}")
        identifiers.add(identifier)

        platform_name = raw_library.get("SupportedPlatform")
        variant = raw_library.get("SupportedPlatformVariant")
        architectures = raw_library.get("SupportedArchitectures")
        if not isinstance(platform_name, str) or not platform_name:
            fail(f"XCFramework slice {identifier} has an invalid platform")
        if variant is not None and (not isinstance(variant, str) or not variant):
            fail(f"XCFramework slice {identifier} has an invalid platform variant")
        if (
            not isinstance(architectures, list)
            or not architectures
            or any(not isinstance(item, str) or not item for item in architectures)
            or len(set(architectures)) != len(architectures)
        ):
            fail(f"XCFramework slice {identifier} has invalid architectures")

        library = dict(raw_library)
        library["_archivePath"] = confined_slice_path(
            xcframework,
            identifier,
            library.get("LibraryPath"),
            "LibraryPath",
        )
        library["_headersPath"] = confined_slice_path(
            xcframework,
            identifier,
            library.get("HeadersPath"),
            "HeadersPath",
        )
        if not library["_archivePath"].is_file():
            fail(f"XCFramework slice {identifier} is missing its library")
        if not library["_headersPath"].is_dir():
            fail(f"XCFramework slice {identifier} is missing its headers")
        validated.append(library)
    return validated


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
        sdk_name = SDK_BY_PLATFORM.get((platform_name, variant))
        if sdk_name is None:
            fail(f"unsupported XCFramework platform/variant: {platform_name}/{variant}")
        sdk_cache.setdefault(sdk_name, sdk_details(sdk_name))
        archive = library["_archivePath"]
        headers = library["_headersPath"]
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
    reject_output_within_tree(arguments.output, xcframework, "provenance output")
    swiftvlc_revision = require_full_revision(
        arguments.swiftvlc_revision,
        "SwiftVLC revision",
    )
    source_revision = require_full_revision(arguments.source_revision, "VLC revision")
    pinned_revision = require_pinned_revision(arguments.pinned_revision, "VLC pin")
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
        "swiftVLCRevision": swiftvlc_revision,
        "vlcSourceRevision": source_revision,
        "pinnedRevision": pinned_revision,
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
    validate_record(record, "generated provenance")
    write_json_atomic(arguments.output, record)


def load_record(path: Path) -> dict[str, Any]:
    value = load_json_object(path, "provenance")
    validate_record(value, f"provenance {path}")
    return value


def verify_recorded_artifact(
    record: dict[str, Any],
    xcframework: Path,
    description: str = "XCFramework",
) -> int:
    """Verify the complete artifact identity recorded by one provenance file."""
    xcframework = xcframework.resolve()
    if record.get("xcframeworkTreeDigest") != tree_digest(xcframework):
        fail(f"{description} tree digest does not match provenance")
    recorded_slices = indexed_slices(record)
    actual_libraries = load_xcframework_libraries(xcframework)
    actual_identifiers = {item["LibraryIdentifier"] for item in actual_libraries}
    if set(recorded_slices) != actual_identifiers:
        fail(f"{description} slice set does not match provenance")
    for library in actual_libraries:
        identifier = library["LibraryIdentifier"]
        recorded = recorded_slices[identifier]
        if not exact_json_equal(recorded.get("platform"), library["SupportedPlatform"]):
            fail(f"{description} slice {identifier} platform does not match Info.plist")
        variant = library.get("SupportedPlatformVariant")
        if variant is None:
            if "variant" in recorded:
                fail(
                    f"{description} slice {identifier} variant does not match Info.plist"
                )
        elif not exact_json_equal(recorded.get("variant"), variant):
            fail(f"{description} slice {identifier} variant does not match Info.plist")
        if not exact_json_equal(
            recorded.get("architectures"), library["SupportedArchitectures"]
        ):
            fail(
                f"{description} slice {identifier} architectures do not match Info.plist"
            )
        archive = library["_archivePath"]
        headers = library["_headersPath"]
        members = archive_member_digest(archive)
        if recorded.get("librarySha256") != sha256_file(archive):
            fail(
                f"{description} slice {identifier} library checksum "
                "does not match provenance"
            )
        if recorded.get("headersTreeDigest") != tree_digest(headers):
            fail(
                f"{description} slice {identifier} headers digest "
                "does not match provenance"
            )
        if any(
            not exact_json_equal(recorded.get(key), value)
            for key, value in members.items()
        ):
            fail(
                f"{description} slice {identifier} archive member manifest "
                "does not match provenance"
            )
    return len(recorded_slices)


def verify(arguments: argparse.Namespace) -> None:
    record = load_record(arguments.provenance)
    xcframework = arguments.xcframework.resolve()
    expected_swiftvlc_revision = require_full_revision(
        arguments.swiftvlc_revision,
        "expected SwiftVLC revision",
    )
    if record["swiftVLCRevision"] != expected_swiftvlc_revision:
        fail("provenance SwiftVLC revision does not match the repository")
    expected_pinned_revision = require_pinned_revision(
        arguments.pinned_revision,
        "expected VLC pin",
    )
    if record["pinnedRevision"] != expected_pinned_revision:
        fail("provenance engine pin does not match the repository")
    manifest = record.get("patchManifest", {})
    if not isinstance(manifest, dict):
        fail("provenance patch manifest is not an object")
    if manifest.get("sha256") != sha256_file(arguments.patch_manifest):
        fail("provenance patch manifest does not match the repository")
    if not exact_json_equal(
        manifest.get("entries"), manifest_entries(arguments.patch_manifest)
    ):
        fail("provenance patch order does not match the repository")
    if not exact_json_equal(
        record.get("buildConfiguration"),
        named_file_records(arguments.build_configuration_file),
    ):
        fail("provenance build configuration does not match the repository")
    slice_count = verify_recorded_artifact(record, xcframework)
    print(
        f"libVLC provenance verified: {slice_count} slice(s), "
        f"tree {record['xcframeworkTreeDigest'][:12]}…"
    )


def normalized_build_inputs(record: dict[str, Any]) -> dict[str, Any]:
    build = record.get("build")
    if not isinstance(build, dict):
        fail("provenance build record is not an object")
    return {
        key: value
        for key, value in build.items()
        if key not in {"builtAt", "invocationId"}
    }


def indexed_slices(record: dict[str, Any]) -> dict[str, dict[str, Any]]:
    slices = record.get("slices")
    if not isinstance(slices, list) or not slices:
        fail("provenance slices must be a non-empty array")
    indexed: dict[str, dict[str, Any]] = {}
    for index, item in enumerate(slices):
        if not isinstance(item, dict):
            fail(f"provenance slice at index {index} is not an object")
        identifier = item.get("identifier")
        if not isinstance(identifier, str) or not identifier:
            fail(f"provenance slice at index {index} has an invalid identifier")
        if identifier in indexed:
            fail(f"provenance contains duplicate slice {identifier}")
        indexed[identifier] = item
    return indexed


def slice_inputs(record: dict[str, Any]) -> dict[str, dict[str, Any]]:
    artifact_keys = set(PROOF_SLICE_KEYS)
    return {
        identifier: {
            key: value for key, value in item.items() if key not in artifact_keys
        }
        for identifier, item in indexed_slices(record).items()
    }


def proof_slices(record: dict[str, Any]) -> dict[str, dict[str, Any]]:
    output: dict[str, dict[str, Any]] = {}
    for identifier, item in sorted(indexed_slices(record).items()):
        missing = [key for key in PROOF_SLICE_KEYS if key not in item]
        if missing:
            fail(
                f"provenance slice {identifier} is missing reproducibility fields: "
                f"{', '.join(missing)}"
            )
        output[identifier] = {key: item[key] for key in PROOF_SLICE_KEYS}
    return output


def exact_json_equal(actual: Any, expected: Any) -> bool:
    """Compare decoded JSON without Python's bool/int numeric coercion."""
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            exact_json_equal(actual[key], value) for key, value in expected.items()
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            exact_json_equal(left, right) for left, right in zip(actual, expected)
        )
    return actual == expected


def validate_proof_build_identity(value: Any, description: str) -> tuple[str, datetime]:
    record = require_exact_object(
        value,
        {"invocationId", "builtAt", "provenanceSha256"},
        description,
    )
    raw_invocation = require_string(
        record["invocationId"], f"{description} invocationId"
    )
    canonical_invocation = invocation_id(raw_invocation)
    if canonical_invocation != raw_invocation:
        fail(f"{description} invocationId is not canonical")
    timestamp = parse_build_timestamp(record["builtAt"], f"{description} builtAt")
    require_sha256(record["provenanceSha256"], f"{description} provenance checksum")
    return canonical_invocation, timestamp


def validate_proof_slice_inputs(value: Any, description: str) -> set[str]:
    if type(value) is not dict or not value:
        fail(f"{description} is not a non-empty object")
    identifiers: set[str] = set()
    for identifier, raw_item in value.items():
        require_string(identifier, f"{description} key")
        validated_identifier = validate_slice_input(
            raw_item,
            f"{description} {identifier}",
            include_artifact=False,
        )
        if validated_identifier != identifier:
            fail(f"{description} key {identifier} does not match its slice identifier")
        identifiers.add(identifier)
    return identifiers


def validate_proof_artifact_slices(value: Any, description: str) -> set[str]:
    if type(value) is not dict or not value:
        fail(f"{description} is not a non-empty object")
    identifiers: set[str] = set()
    for identifier, raw_item in value.items():
        require_string(identifier, f"{description} key")
        item = require_exact_object(
            raw_item,
            set(PROOF_SLICE_KEYS),
            f"{description} {identifier}",
        )
        require_sha256(
            item["librarySha256"],
            f"{description} {identifier} library checksum",
        )
        require_sha256(
            item["headersTreeDigest"],
            f"{description} {identifier} headers tree digest",
        )
        require_sha256(
            item["manifestSha256"],
            f"{description} {identifier} member manifest",
        )
        require_integer(
            item["memberCount"],
            f"{description} {identifier} member count",
            minimum=1,
        )
        identifiers.add(identifier)
    return identifiers


def validate_proof(proof: dict[str, Any], description: str) -> None:
    proof = require_exact_object(
        proof,
        {
            "schemaVersion",
            "swiftVLCRevision",
            "vlcSourceRevision",
            "pinnedRevision",
            "patchManifestSha256",
            "buildConfiguration",
            "contribChecksums",
            "buildInputs",
            "sliceInputs",
            "firstBuild",
            "secondBuild",
            "artifactIdentity",
        },
        description,
    )
    if (
        type(proof["schemaVersion"]) is not int
        or proof["schemaVersion"] != PROOF_SCHEMA_VERSION
    ):
        fail(f"{description} is not schema version {PROOF_SCHEMA_VERSION}")
    require_full_revision(proof["swiftVLCRevision"], f"{description} SwiftVLC revision")
    require_full_revision(proof["vlcSourceRevision"], f"{description} VLC revision")
    require_pinned_revision(proof["pinnedRevision"], f"{description} VLC pin")
    patch_checksum = proof["patchManifestSha256"]
    if patch_checksum != "none":
        require_sha256(patch_checksum, f"{description} patch manifest checksum")
    validate_build_configuration(
        proof["buildConfiguration"], f"{description} build configuration"
    )
    validate_contrib_checksums(
        proof["contribChecksums"], f"{description} contrib checksums"
    )
    validate_build_record(
        proof["buildInputs"],
        f"{description} build inputs",
        include_identity=False,
        require_clean=True,
    )
    slice_input_identifiers = validate_proof_slice_inputs(
        proof["sliceInputs"], f"{description} slice inputs"
    )
    first_invocation, first_timestamp = validate_proof_build_identity(
        proof["firstBuild"], f"{description} first build"
    )
    second_invocation, second_timestamp = validate_proof_build_identity(
        proof["secondBuild"], f"{description} second build"
    )
    if first_invocation == second_invocation:
        fail(f"{description} does not contain independent build invocations")
    if second_timestamp <= first_timestamp:
        fail(f"{description} build timestamps are not in strict completion order")

    artifact = require_exact_object(
        proof["artifactIdentity"],
        {"algorithm", "xcframeworkTreeDigest", "slices"},
        f"{description} artifact identity",
    )
    if artifact["algorithm"] != ARTIFACT_IDENTITY_ALGORITHM:
        fail(f"{description} uses an unsupported artifact identity algorithm")
    require_sha256(
        artifact["xcframeworkTreeDigest"],
        f"{description} XCFramework tree digest",
    )
    artifact_identifiers = validate_proof_artifact_slices(
        artifact["slices"], f"{description} artifact slices"
    )
    if slice_input_identifiers != artifact_identifiers:
        fail(f"{description} slice inputs and artifact slice sets differ")


def load_proof(path: Path) -> dict[str, Any]:
    proof = load_json_object(path, "reproducibility proof")
    validate_proof(proof, f"reproducibility proof {path}")
    return proof


def reproducibility_proof(
    first_path: Path,
    second_path: Path,
    first: dict[str, Any],
    second: dict[str, Any],
) -> dict[str, Any]:
    input_keys = (
        "swiftVLCRevision",
        "vlcSourceRevision",
        "pinnedRevision",
        "patchManifest",
        "buildConfiguration",
        "contribChecksums",
    )
    for key in input_keys:
        if key not in first or key not in second:
            fail(f"provenance build input is missing: {key}")
        if not exact_json_equal(first.get(key), second.get(key)):
            fail(f"build inputs differ at {key}")
    if not exact_json_equal(
        normalized_build_inputs(first), normalized_build_inputs(second)
    ):
        fail("build toolchain, host, flags, or assertion inputs differ")
    if not exact_json_equal(slice_inputs(first), slice_inputs(second)):
        fail("build slice SDK, target, platform, or architecture inputs differ")

    first_identity, first_timestamp = build_identity(first, "first provenance")
    second_identity, second_timestamp = build_identity(second, "second provenance")
    if first_identity["invocationId"] == second_identity["invocationId"]:
        fail("reproducibility proof requires independent build invocations")
    if second_timestamp <= first_timestamp:
        fail(
            "reproducibility proof requires the second clean build to have a "
            "later distinct UTC completion timestamp"
        )

    first_provenance_sha256 = sha256_file(first_path)
    second_provenance_sha256 = sha256_file(second_path)
    if first_provenance_sha256 == second_provenance_sha256:
        fail("reproducibility proof requires two distinct provenance records")

    first_slices = indexed_slices(first)
    second_slices = indexed_slices(second)
    if set(first_slices) != set(second_slices):
        fail("build slice sets differ")
    differences = []
    for identifier in sorted(first_slices):
        before = first_slices[identifier]
        after = second_slices[identifier]
        for key in PROOF_SLICE_KEYS:
            if not exact_json_equal(before.get(key), after.get(key)):
                differences.append(f"{identifier}.{key}")
    if not exact_json_equal(
        first.get("xcframeworkTreeDigest"), second.get("xcframeworkTreeDigest")
    ):
        differences.append("xcframeworkTreeDigest")
    if differences:
        fail("clean builds are not byte-reproducible: " + ", ".join(differences))

    patch_manifest = first.get("patchManifest")
    if not isinstance(patch_manifest, dict) or "sha256" not in patch_manifest:
        fail("first provenance patch manifest is missing its checksum")

    return {
        "schemaVersion": PROOF_SCHEMA_VERSION,
        "swiftVLCRevision": first["swiftVLCRevision"],
        "vlcSourceRevision": first["vlcSourceRevision"],
        "pinnedRevision": first["pinnedRevision"],
        "patchManifestSha256": patch_manifest["sha256"],
        "buildConfiguration": first["buildConfiguration"],
        "contribChecksums": first["contribChecksums"],
        "buildInputs": normalized_build_inputs(first),
        "sliceInputs": slice_inputs(first),
        "firstBuild": {
            **first_identity,
            "provenanceSha256": first_provenance_sha256,
        },
        "secondBuild": {
            **second_identity,
            "provenanceSha256": second_provenance_sha256,
        },
        "artifactIdentity": {
            "algorithm": ARTIFACT_IDENTITY_ALGORITHM,
            "xcframeworkTreeDigest": first["xcframeworkTreeDigest"],
            "slices": proof_slices(first),
        },
    }


def compare(arguments: argparse.Namespace) -> None:
    first_path = arguments.first_provenance.resolve()
    second_path = arguments.second_provenance.resolve()
    first_xcframework = arguments.first_xcframework.resolve()
    second_xcframework = arguments.second_xcframework.resolve()
    if first_path == second_path:
        fail("reproducibility comparison requires two provenance files")
    if first_xcframework == second_xcframework:
        fail("reproducibility comparison requires two artifact directories")
    if arguments.output is not None:
        output_path = arguments.output.resolve()
        if output_path in {first_path, second_path}:
            fail("reproducibility proof cannot overwrite a provenance record")
        reject_output_within_tree(
            arguments.output,
            first_xcframework,
            "reproducibility proof output",
        )
        reject_output_within_tree(
            arguments.output,
            second_xcframework,
            "reproducibility proof output",
        )

    first = load_record(first_path)
    second = load_record(second_path)
    verify_recorded_artifact(first, first_xcframework, "first XCFramework")
    verify_recorded_artifact(second, second_xcframework, "second XCFramework")
    proof = reproducibility_proof(first_path, second_path, first, second)
    validate_proof(proof, "generated reproducibility proof")
    if arguments.output is not None:
        write_json_atomic(arguments.output, proof)
    print(
        f"libVLC clean builds are byte-reproducible: "
        f"{first['xcframeworkTreeDigest']}"
    )


def verify_proof(arguments: argparse.Namespace) -> None:
    first_path = arguments.first_provenance.resolve()
    second_path = arguments.second_provenance.resolve()
    current_path = arguments.current_provenance.resolve()
    if first_path == second_path:
        fail("reproducibility verification requires two retained provenance files")

    first = load_record(first_path)
    second = load_record(second_path)
    current = load_record(current_path)
    proof = load_proof(arguments.proof)

    expected = reproducibility_proof(first_path, second_path, first, second)
    for label, path, field in (
        ("first", first_path, "firstBuild"),
        ("second", second_path, "secondBuild"),
    ):
        proof_build = proof.get(field)
        if not isinstance(proof_build, dict):
            fail(f"reproducibility proof has no {label} build identity")
        if proof_build.get("provenanceSha256") != sha256_file(path):
            fail(
                f"reproducibility proof {label} provenance checksum "
                "does not match the retained record"
            )
    if not exact_json_equal(proof, expected):
        fail(
            "reproducibility proof does not exactly match both retained "
            "provenance records"
        )

    if sha256_file(current_path) != sha256_file(second_path):
        fail("current provenance is not the proof's retained second build")
    if not exact_json_equal(current, second):
        fail("current provenance content differs from the retained second build")
    verify_recorded_artifact(
        current,
        arguments.xcframework,
        "current XCFramework",
    )
    print(
        f"libVLC reproducibility proof verified: "
        f"{proof['artifactIdentity']['xcframeworkTreeDigest'][:12]}…"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)

    create_parser = commands.add_parser("create")
    create_parser.add_argument("--xcframework", type=Path, required=True)
    create_parser.add_argument("--output", type=Path, required=True)
    create_parser.add_argument("--vlc-source", type=Path, required=True)
    create_parser.add_argument("--swiftvlc-revision", required=True)
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
    verify_parser.add_argument("--swiftvlc-revision", required=True)
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
    compare_parser.add_argument(
        "--first-provenance",
        "--first",
        dest="first_provenance",
        type=Path,
        required=True,
    )
    compare_parser.add_argument("--first-xcframework", type=Path, required=True)
    compare_parser.add_argument(
        "--second-provenance",
        "--second",
        dest="second_provenance",
        type=Path,
        required=True,
    )
    compare_parser.add_argument("--second-xcframework", type=Path, required=True)
    compare_parser.add_argument("--output", type=Path)
    compare_parser.set_defaults(function=compare)

    proof_parser = commands.add_parser("verify-proof")
    proof_parser.add_argument("--proof", type=Path, required=True)
    proof_parser.add_argument("--first-provenance", type=Path, required=True)
    proof_parser.add_argument("--second-provenance", type=Path, required=True)
    proof_parser.add_argument("--current-provenance", type=Path, required=True)
    proof_parser.add_argument("--xcframework", type=Path, required=True)
    proof_parser.set_defaults(function=verify_proof)

    arguments = parser.parse_args()
    arguments.function(arguments)


if __name__ == "__main__":
    main()
