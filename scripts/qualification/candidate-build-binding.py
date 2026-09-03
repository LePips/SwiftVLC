#!/usr/bin/env python3
"""Attest that a qualification build consumed the intended local SwiftVLC tree.

The prebuild receipt binds SwiftPM's resolved local package/artifact state and the
source inventory.  The postbuild operation rechecks that state and proves that
Xcode's Swift driver received exactly that inventory through its SwiftFileList.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
TEAM = re.compile(r"[A-Z0-9]{10}")
BUNDLE_PREFIX = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+"
)
RECEIPT_AUTHORITY = "swiftvlc-candidate-build-resolution-v1"
ATTESTATION_AUTHORITY = "swiftvlc-candidate-build-binding-v1"
SOURCE_SET_ALGORITHM = "swiftvlc-compiled-source-set-v2"
BUILD_INPUT_SET_ALGORITHM = "swiftvlc-build-input-set-v1"
BUILD_SETTINGS_ALGORITHM = "swiftvlc-effective-build-settings-v1"
AUTHORIZED_BUILD_INPUT_TRANSFORMS = {
    "Package.swift",
    "Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj",
    (
        "Showcase/SwiftVLCShowcase.xcodeproj/project.xcworkspace/"
        "xcshareddata/swiftpm/Package.resolved"
    ),
}
REQUIRED_BUILD_INPUTS = {
    "Package.swift",
    "Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj",
    "Showcase/SwiftVLCShowcase.xcodeproj/xcshareddata/xcschemes/iOS.xcscheme",
    "Showcase/iOS/Info.plist",
}
MATERIAL_BUILD_SETTING_PREFIXES = (
    "ARCH",
    "CLANG_",
    "CODE_SIGN",
    "DEBUG_INFORMATION_FORMAT",
    "DEVELOPER_DIR",
    "ENABLE_",
    "EXCLUDED_",
    "FRAMEWORK_",
    "GCC_",
    "GENERATE_INFOPLIST_FILE",
    "HEADER_SEARCH_PATHS",
    "INFOPLIST_",
    "IPHONEOS_DEPLOYMENT_TARGET",
    "LD_",
    "LIBRARY_SEARCH_PATHS",
    "LINK_WITH_STANDARD_LIBRARIES",
    "MACH_O_TYPE",
    "MODULEMAP_FILE",
    "OTHER_",
    "PACKAGE_",
    "PRODUCT_",
    "SDKROOT",
    "STRIP_",
    "SUPPORTED_PLATFORMS",
    "SWIFT_",
    "TARGETED_DEVICE_FAMILY",
    "VALIDATE_",
)


class BuildBindingError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise BuildBindingError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def load_json(path: Path, description: str) -> dict:
    try:
        value = json.loads(
            path.read_text(),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=lambda item: (_ for _ in ()).throw(
                BuildBindingError(f"non-finite JSON number {item!r}")
            ),
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BuildBindingError(f"cannot read {description} {path}: {error}") from error
    if not isinstance(value, dict):
        raise BuildBindingError(f"{description} must be a JSON object")
    return value


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def command_output(arguments: list[str]) -> str:
    try:
        return subprocess.run(
            arguments, check=True, capture_output=True, text=True
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or str(error)
        raise BuildBindingError(detail) from error


def _absolute_lexical(path: Path) -> Path:
    return Path(os.path.abspath(os.path.normpath(path)))


def _require_plain_directory(path: Path, description: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise BuildBindingError(f"cannot inspect {description} {path}: {error}") from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise BuildBindingError(f"{description} must be a real directory: {path}")


def _reject_tree_symlinks(root: Path, description: str) -> None:
    _require_plain_directory(root, description)
    try:
        entries = root.rglob("*")
        for entry in entries:
            if entry.is_symlink():
                raise BuildBindingError(
                    f"{description} contains a symlink escape or ambiguous entry: {entry}"
                )
    except OSError as error:
        raise BuildBindingError(f"cannot inspect {description} {root}: {error}") from error


def artifact_binding(
    source_root: Path, logical_artifact: Path, authority_artifact: Path
) -> tuple[str, str]:
    source_root = _absolute_lexical(source_root)
    logical_artifact = _absolute_lexical(logical_artifact)
    authority_artifact = _absolute_lexical(authority_artifact)
    expected_logical = source_root / "Vendor" / "libvlc.xcframework"
    if logical_artifact != expected_logical:
        raise BuildBindingError(
            "local artifact must use BUILD_SOURCE_ROOT/Vendor/libvlc.xcframework"
        )
    _require_plain_directory(source_root, "build source root")
    _reject_tree_symlinks(authority_artifact, "artifact authority tree")
    authority_resolved = authority_artifact.resolve(strict=True)

    vendor = source_root / "Vendor"
    if vendor.is_symlink():
        target = vendor.resolve(strict=True)
        if target != authority_artifact.parent.resolve(strict=True):
            raise BuildBindingError(
                "BUILD_SOURCE_ROOT/Vendor symlink does not target the exact "
                "attested artifact authority directory"
            )
        mode = "vendor-symlink-to-authority-root"
    else:
        _require_plain_directory(vendor, "build Vendor directory")
        mode = "direct"
    try:
        resolved = logical_artifact.resolve(strict=True)
    except OSError as error:
        raise BuildBindingError(f"cannot resolve local artifact {logical_artifact}: {error}") from error
    if resolved != authority_resolved:
        raise BuildBindingError(
            "build-local artifact does not resolve to the exact authority artifact"
        )
    try:
        digest = policy.tree_digest(authority_artifact)
    except policy.QualificationPolicyError as error:
        raise BuildBindingError(str(error)) from error
    return mode, digest


def _swiftvlc_reference(package_ref: object) -> bool:
    if not isinstance(package_ref, dict):
        return False
    name = str(package_ref.get("name", "")).lower()
    identity = str(package_ref.get("identity", "")).lower()
    location = str(package_ref.get("location", "")).rstrip("/").lower()
    return name == "swiftvlc" or identity == "swiftvlc" or location.endswith("/swiftvlc")


def workspace_binding(source_root: Path, derived_data: Path) -> tuple[dict, str]:
    source_root = _absolute_lexical(source_root)
    state_path = derived_data / "SourcePackages" / "workspace-state.json"
    state = load_json(state_path, "SwiftPM workspace state")
    obj = state.get("object")
    if not isinstance(obj, dict):
        raise BuildBindingError("SwiftPM workspace state has no object")
    dependencies = obj.get("dependencies")
    artifacts = obj.get("artifacts")
    if not isinstance(dependencies, list) or not isinstance(artifacts, list):
        raise BuildBindingError("SwiftPM workspace state has invalid dependency/artifact lists")

    swiftvlc_dependencies = [
        item
        for item in dependencies
        if isinstance(item, dict) and _swiftvlc_reference(item.get("packageRef"))
    ]
    if len(swiftvlc_dependencies) != 1:
        raise BuildBindingError(
            "SwiftPM workspace state must contain exactly one SwiftVLC dependency; "
            f"found {len(swiftvlc_dependencies)}"
        )
    dependency = swiftvlc_dependencies[0]
    package_ref = dependency.get("packageRef")
    dep_state = dependency.get("state")
    if not isinstance(package_ref, dict) or not isinstance(dep_state, dict):
        raise BuildBindingError("SwiftVLC workspace dependency is malformed")
    if package_ref.get("kind") != "fileSystem" or dep_state.get("name") != "fileSystem":
        raise BuildBindingError(
            "SwiftVLC workspace dependency must be fileSystem; sourceControl is forbidden"
        )
    expected_root = str(source_root)
    if package_ref.get("location") != expected_root or dep_state.get("path") != expected_root:
        raise BuildBindingError(
            "SwiftVLC workspace dependency does not point to the exact build source root"
        )

    swiftvlc_artifacts = [
        item
        for item in artifacts
        if isinstance(item, dict)
        and (item.get("targetName") == "libvlc" or _swiftvlc_reference(item.get("packageRef")))
    ]
    if len(swiftvlc_artifacts) != 1:
        raise BuildBindingError(
            "SwiftPM workspace state must contain exactly one SwiftVLC/libvlc artifact; "
            f"found {len(swiftvlc_artifacts)}"
        )
    artifact = swiftvlc_artifacts[0]
    artifact_ref = artifact.get("packageRef")
    kind = artifact.get("kind")
    source = artifact.get("source")
    if (
        not isinstance(artifact_ref, dict)
        or artifact_ref.get("kind") != "fileSystem"
        or not isinstance(kind, dict)
        or set(kind) != {"xcframework"}
        or not isinstance(source, dict)
        or source.get("type") != "local"
        or artifact.get("targetName") != "libvlc"
    ):
        raise BuildBindingError(
            "SwiftVLC libvlc workspace artifact must be one local fileSystem xcframework"
        )
    expected_artifact = str(source_root / "Vendor" / "libvlc.xcframework")
    if artifact_ref.get("location") != expected_root or artifact.get("path") != expected_artifact:
        raise BuildBindingError(
            "SwiftVLC workspace artifact does not use the exact build-local artifact path"
        )

    binding = {
        "dependencyKind": "fileSystem",
        "dependencyLocation": "$BUILD_SOURCE_ROOT",
        "dependencyStateName": "fileSystem",
        "dependencyStatePath": "$BUILD_SOURCE_ROOT",
        "artifactKind": "xcframework",
        "artifactPath": "$BUILD_SOURCE_ROOT/Vendor/libvlc.xcframework",
        "artifactSourceType": "local",
        "artifactTargetName": "libvlc",
    }
    return binding, policy.sha256_file(state_path)


def compiled_source_inventory(
    source_root: Path, relative_root: str, description: str
) -> tuple[list[dict], str]:
    source_root = _absolute_lexical(source_root)
    compiled_root = source_root / relative_root
    _reject_tree_symlinks(compiled_root, description)
    records: list[dict] = []
    for source in sorted(compiled_root.rglob("*.swift")):
        try:
            metadata = source.lstat()
        except OSError as error:
            raise BuildBindingError(f"cannot inspect Swift source {source}: {error}") from error
        if not stat.S_ISREG(metadata.st_mode):
            raise BuildBindingError(f"Swift source is not a regular file: {source}")
        records.append(
            {
                "relativePath": source.relative_to(compiled_root).as_posix(),
                "mode": stat.S_IMODE(metadata.st_mode),
                "digestAlgorithm": "sha256",
                "digest": policy.sha256_file(source),
            }
        )
    if not records:
        raise BuildBindingError(f"{description} contains no .swift files")
    return records, policy.compiled_source_set_digest(records)


def _build_input_paths(source_root: Path) -> list[Path]:
    candidates = [source_root / "Package.swift"]
    for relative_root in (
        "Sources/CLibVLC",
        "Showcase/SwiftVLCShowcase.xcodeproj",
        "Showcase/Shared",
        "Showcase/iOS",
        "Showcase/UITests/iOS",
    ):
        root = source_root / relative_root
        if root.exists():
            _reject_tree_symlinks(root, f"build input tree {relative_root}")
            candidates.extend(path for path in root.rglob("*") if path.is_file())
    return sorted(
        {
            path
            for path in candidates
            if (path.name == "Package.swift" or path.suffix != ".swift")
            and path.is_file()
        },
        key=lambda path: path.relative_to(source_root).as_posix(),
    )


def build_input_inventory(source_root: Path) -> tuple[list[dict], str]:
    source_root = _absolute_lexical(source_root)
    _require_plain_directory(source_root, "build input root")
    records: list[dict] = []
    for path in _build_input_paths(source_root):
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise BuildBindingError(f"build input is not a regular file: {path}")
        records.append(
            {
                "relativePath": path.relative_to(source_root).as_posix(),
                "mode": stat.S_IMODE(metadata.st_mode),
                "digestAlgorithm": "sha256",
                "digest": policy.sha256_file(path),
            }
        )
    paths = {record["relativePath"] for record in records}
    missing = sorted(REQUIRED_BUILD_INPUTS - paths)
    if missing:
        raise BuildBindingError(
            f"build input inventory is missing required configuration files: {missing!r}"
        )
    try:
        digest = policy.build_input_set_digest(records)
    except policy.QualificationPolicyError as error:
        raise BuildBindingError(str(error)) from error
    return records, digest


def expected_local_package(text: str) -> str:
    pattern = r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)'
    replacement = '.binaryTarget(name: "libvlc", path: "Vendor/libvlc.xcframework")'
    result, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise BuildBindingError(
            "clean authority Package.swift has no unique libvlc binary target"
        )
    return result


def expected_local_signed_project(
    text: str, development_team: str, bundle_prefix: str
) -> str:
    local_block = """/* Begin XCLocalSwiftPackageReference section */
\t\tBA000001 /* XCLocalSwiftPackageReference ".." */ = {
\t\t\tisa = XCLocalSwiftPackageReference;
\t\t\trelativePath = "..";
\t\t};
/* End XCLocalSwiftPackageReference section */"""
    remote_pattern = re.compile(
        r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
        r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
        r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
        r'\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";\n'
        r'\t\t\trequirement = \{\n'
        r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
        r'\t\t\t\t(?:minimumVersion|version) = [0-9][0-9A-Za-z.\-]*;\n'
        r'\t\t\t\};\n'
        r'\t\t\};\n'
        r'/\* End XCRemoteSwiftPackageReference section \*/'
    )
    local_pattern = re.compile(
        r'/\* Begin XCLocalSwiftPackageReference section \*/\n'
        r'\t\tBA000001 /\* XCLocalSwiftPackageReference "\.\." \*/ = \{\n'
        r'\t\t\tisa = XCLocalSwiftPackageReference;\n'
        r'\t\t\trelativePath = "?\.\."?;\n'
        r'\t\t\};\n'
        r'/\* End XCLocalSwiftPackageReference section \*/'
    )
    if local_block in text or local_pattern.search(text):
        result = text
    else:
        result, count = remote_pattern.subn(local_block, text, count=1)
        if count != 1:
            raise BuildBindingError(
                "clean authority project has no unique SwiftVLC package reference"
            )
    result = result.replace(
        'BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */',
        'BA000001 /* XCLocalSwiftPackageReference ".." */',
    )
    result, team_count = re.subn(
        r"DEVELOPMENT_TEAM = [A-Z0-9]{10};",
        f"DEVELOPMENT_TEAM = {development_team};",
        result,
    )
    app_id = f"{bundle_prefix}.app"
    test_id = f"{bundle_prefix}.uitests"
    result, app_count = re.subn(
        r"PRODUCT_BUNDLE_IDENTIFIER = com\.swiftvlc\.showcase\.ios;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {app_id};",
        result,
    )
    result, test_count = re.subn(
        r"PRODUCT_BUNDLE_IDENTIFIER = com\.swiftvlc\.showcase\.ios\.uitests;",
        f"PRODUCT_BUNDLE_IDENTIFIER = {test_id};",
        result,
    )
    if team_count != 2 or app_count != 2 or test_count != 2:
        raise BuildBindingError(
            "clean authority project does not match the exact signing transform contract"
        )
    return result


def _require_empty_local_package_resolution(path: Path) -> None:
    if not path.exists():
        return
    value = load_json(path, "local Package.resolved")
    if value.get("version") not in {2, 3} or value.get("pins") != []:
        raise BuildBindingError(
            "effective Package.resolved must be a canonical empty local resolution"
        )


def compare_build_input_authority(
    source_authority: Path,
    effective_root: Path,
    authority_records: list[dict],
    effective_records: list[dict],
    development_team: str,
    bundle_prefix: str,
) -> list[str]:
    if TEAM.fullmatch(development_team) is None:
        raise BuildBindingError("development team must be a 10-character identifier")
    if BUNDLE_PREFIX.fullmatch(bundle_prefix) is None:
        raise BuildBindingError("bundle prefix must be a reverse-DNS identifier")
    authority = {record["relativePath"]: record for record in authority_records}
    effective = {record["relativePath"]: record for record in effective_records}
    resolved = next(
        path
        for path in AUTHORIZED_BUILD_INPUT_TRANSFORMS
        if path.endswith("Package.resolved")
    )
    comparable_authority = set(authority) - {resolved}
    comparable_effective = set(effective) - {resolved}
    if comparable_authority != comparable_effective:
        raise BuildBindingError(
            "effective build input file set differs from the clean authority"
        )
    package = "Package.swift"
    project = "Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
    expected_package = expected_local_package(
        (source_authority / package).read_text()
    ).encode()
    expected_project = expected_local_signed_project(
        (source_authority / project).read_text(), development_team, bundle_prefix
    ).encode()
    for relative, expected_bytes in (
        (package, expected_package),
        (project, expected_project),
    ):
        actual_path = effective_root / relative
        if actual_path.read_bytes() != expected_bytes:
            raise BuildBindingError(
                f"effective {relative} is not the exact clean-authority transform"
            )
        if authority[relative]["mode"] != effective[relative]["mode"]:
            raise BuildBindingError(f"effective {relative} mode changed")
    unexpected = sorted(
        path
        for path in comparable_authority - {package, project}
        if authority[path] != effective[path]
    )
    if unexpected:
        raise BuildBindingError(
            "effective build inputs differ from the clean source authority: "
            f"{unexpected!r}"
        )
    _require_empty_local_package_resolution(effective_root / resolved)
    return sorted(
        path
        for path in AUTHORIZED_BUILD_INPUT_TRANSFORMS
        if authority.get(path) != effective.get(path)
    )


def effective_build_settings(path: Path) -> tuple[list[dict], str]:
    try:
        value = json.loads(
            path.read_text(),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=lambda item: (_ for _ in ()).throw(
                BuildBindingError(f"non-finite JSON number {item!r}")
            ),
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise BuildBindingError(
            f"cannot read effective Xcode build settings {path}: {error}"
        ) from error
    if not isinstance(value, list) or not value:
        raise BuildBindingError("effective Xcode build settings must be a JSON array")
    records: list[dict] = []
    seen_targets: set[str] = set()
    for item in value:
        if not isinstance(item, dict):
            raise BuildBindingError("effective Xcode build-settings entry is malformed")
        target = item.get("target")
        settings = item.get("buildSettings")
        if (
            not isinstance(target, str)
            or not target
            or target in seen_targets
            or not isinstance(settings, dict)
            or any(
                not isinstance(key, str) or not isinstance(setting, str)
                for key, setting in settings.items()
            )
        ):
            raise BuildBindingError(
                "effective Xcode build-settings targets are malformed or ambiguous"
            )
        seen_targets.add(target)
        material = {
            key: settings[key]
            for key in sorted(settings)
            if key.startswith(MATERIAL_BUILD_SETTING_PREFIXES)
        }
        if not material:
            raise BuildBindingError(
                f"effective Xcode build settings contain no material settings for {target}"
            )
        other_swift_flags = settings.get("OTHER_SWIFT_FLAGS", "").strip()
        canonical_ui_test_flags = False
        if target == "iOSUITests" and other_swift_flags:
            try:
                flag_tokens = shlex.split(other_swift_flags)
            except ValueError:
                flag_tokens = []
            developer_dir = settings.get("DEVELOPER_DIR", "")
            canonical_plugin_path = (
                f"{developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/lib/"
                "swift/host/plugins/testing"
            )
            canonical_ui_test_flags = flag_tokens == [
                "-module-alias",
                "Testing=_Testing_Unavailable",
                "-plugin-path",
                canonical_plugin_path,
            ]
        forbidden_nonempty = {
            name: settings.get(name, "").strip()
            for name in (
                "OTHER_CFLAGS",
                "OTHER_CPLUSPLUSFLAGS",
                "OTHER_LDFLAGS",
            )
            if settings.get(name, "").strip()
        }
        if other_swift_flags and not canonical_ui_test_flags:
            forbidden_nonempty["OTHER_SWIFT_FLAGS"] = other_swift_flags
        if forbidden_nonempty:
            raise BuildBindingError(
                f"effective Xcode build settings inject forbidden compile/link flags "
                f"for {target}: {sorted(forbidden_nonempty)!r}"
            )
        conditions = settings.get(
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS", ""
        ).split()
        if target in {"iOS", "iOSUITests"}:
            conditions_are_canonical = not conditions
        elif target == "SwiftVLC":
            conditions_are_canonical = set(conditions) == {"SWIFT_PACKAGE"}
        else:
            conditions_are_canonical = set(conditions).issubset({"SWIFT_PACKAGE"})
        if not conditions_are_canonical:
            raise BuildBindingError(
                "effective Xcode build settings have non-canonical Swift active "
                f"compilation conditions for {target}: {conditions!r}"
            )
        if settings.get("CONFIGURATION") != "Release":
            raise BuildBindingError(
                f"effective Xcode build settings are not Release for {target}"
            )
        if settings.get("SWIFT_OPTIMIZATION_LEVEL", "-O") != "-O":
            raise BuildBindingError(
                f"effective Xcode build settings are not optimized for {target}"
            )
        records.append({"target": target, "settings": material})
    missing_targets = {"iOS", "iOSUITests"} - seen_targets
    if missing_targets:
        raise BuildBindingError(
            "effective Xcode build settings do not include the candidate and UI-test "
            f"targets: {sorted(missing_targets)!r}"
        )
    records.sort(key=lambda record: record["target"])
    try:
        digest = policy.effective_build_settings_digest(records)
    except policy.QualificationPolicyError as error:
        raise BuildBindingError(str(error)) from error
    return records, digest


def verify_source_authority(
    source_authority: Path,
    version: str,
    source_commit: str,
    release_source_digest: str,
) -> None:
    source_authority = _absolute_lexical(source_authority)
    _require_plain_directory(source_authority, "source authority checkout")
    dirty = command_output(
        [
            "git",
            "-C",
            str(source_authority),
            "status",
            "--porcelain",
            "--untracked-files=normal",
        ]
    )
    if dirty:
        raise BuildBindingError(
            "source authority checkout must be clean before build attestation"
        )
    actual_commit = command_output(
        ["git", "-C", str(source_authority), "rev-parse", "HEAD"]
    )
    if actual_commit != source_commit:
        raise BuildBindingError(
            "claimed source commit does not match the clean source authority checkout"
        )
    digest_script = source_authority / "scripts" / "release-source-digest.py"
    actual_digest = command_output(
        ["python3", str(digest_script), version, "--root", str(source_authority)]
    )
    if actual_digest != release_source_digest:
        raise BuildBindingError(
            "claimed release source digest does not match the clean source authority checkout"
        )


def filelist_root(derived_data: Path, configuration: str, platform: str) -> Path:
    return (
        derived_data
        / "Build"
        / "Intermediates.noindex"
        / "SwiftVLC.build"
        / f"{configuration}-{platform}"
        / "SwiftVLC.build"
        / "Objects-normal"
    )


def discover_filelists(derived_data: Path, configuration: str, platform: str) -> list[Path]:
    root = filelist_root(derived_data, configuration, platform)
    return sorted(root.glob("*/SwiftVLC.SwiftFileList")) if root.is_dir() else []


def preexisting_filelists(
    derived_data: Path, configuration: str, platform: str
) -> dict[str, str]:
    root = _absolute_lexical(derived_data)
    return {
        path.relative_to(root).as_posix(): policy.sha256_file(path)
        for path in discover_filelists(root, configuration, platform)
    }


def discover_showcase_filelists(
    derived_data: Path, configuration: str, platform: str, target: str
) -> list[Path]:
    root = (
        derived_data
        / "Build"
        / "Intermediates.noindex"
        / "SwiftVLCShowcase.build"
        / f"{configuration}-{platform}"
        / f"{target}.build"
        / "Objects-normal"
    )
    return sorted(root.glob(f"*/{target}.SwiftFileList")) if root.is_dir() else []


def preexisting_showcase_filelists(
    derived_data: Path, configuration: str, platform: str
) -> dict[str, str]:
    root = _absolute_lexical(derived_data)
    paths = [
        path
        for target in ("iOS", "iOSUITests")
        for path in discover_showcase_filelists(
            root, configuration, platform, target
        )
    ]
    return {
        path.relative_to(root).as_posix(): policy.sha256_file(path) for path in paths
    }


def make_receipt(args: argparse.Namespace) -> dict:
    source_root = _absolute_lexical(args.source_root)
    source_authority = _absolute_lexical(args.source_authority)
    derived_data = _absolute_lexical(args.derived_data)
    logical_artifact = source_root / "Vendor" / "libvlc.xcframework"
    binding_mode, artifact_digest = artifact_binding(
        source_root, logical_artifact, args.artifact_authority
    )
    workspace, workspace_digest = workspace_binding(source_root, derived_data)
    if SHA1.fullmatch(args.source_commit) is None:
        raise BuildBindingError("source commit must be a lowercase 40-character SHA-1")
    if SHA256.fullmatch(args.release_source_digest) is None:
        raise BuildBindingError("release source digest must be a lowercase SHA-256")
    if SHA256.fullmatch(args.candidate_runtime_binding) is None:
        raise BuildBindingError(
            "candidate runtime binding must be 64 lowercase hex characters"
        )
    verify_source_authority(
        source_authority,
        args.version,
        args.source_commit,
        args.release_source_digest,
    )
    sources, source_set_digest = compiled_source_inventory(
        source_root, "Sources/SwiftVLC", "build SwiftVLC source tree"
    )
    authority_sources, authority_source_set_digest = compiled_source_inventory(
        source_authority, "Sources/SwiftVLC", "authority SwiftVLC source tree"
    )
    if sources != authority_sources or source_set_digest != authority_source_set_digest:
        raise BuildBindingError(
            "build SwiftVLC source bytes/modes do not exactly match the clean source authority"
        )
    showcase_sources, showcase_source_set_digest = compiled_source_inventory(
        source_root, "Showcase", "build Showcase source tree"
    )
    authority_showcase_sources, authority_showcase_digest = compiled_source_inventory(
        source_authority, "Showcase", "authority Showcase source tree"
    )
    if (
        showcase_sources != authority_showcase_sources
        or showcase_source_set_digest != authority_showcase_digest
    ):
        raise BuildBindingError(
            "build Showcase Swift/UI-test source bytes/modes do not exactly match "
            "the clean source authority"
        )
    authority_build_inputs, authority_build_input_digest = build_input_inventory(
        source_authority
    )
    effective_build_inputs, effective_build_input_digest = build_input_inventory(
        source_root
    )
    authorized_transforms = compare_build_input_authority(
        source_authority,
        source_root,
        authority_build_inputs,
        effective_build_inputs,
        args.development_team,
        args.bundle_prefix,
    )
    build_settings, build_settings_digest = effective_build_settings(
        args.build_settings
    )
    return {
        "formatVersion": 1,
        "authority": RECEIPT_AUTHORITY,
        "sourceRoot": str(source_root),
        "sourceAuthority": str(source_authority),
        "derivedData": str(derived_data),
        "artifactAuthority": str(_absolute_lexical(args.artifact_authority)),
        "artifactBindingMode": binding_mode,
        "version": args.version,
        "candidateRuntimeBinding": args.candidate_runtime_binding,
        "sourceCommit": args.source_commit,
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": args.release_source_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": artifact_digest,
        "workspaceStateDigestAlgorithm": "sha256",
        "workspaceStateDigest": workspace_digest,
        "workspaceBinding": workspace,
        "buildConfiguration": args.configuration,
        "buildPlatform": args.platform,
        "swiftSourceRoot": "Sources/SwiftVLC",
        "swiftSourceSetDigestAlgorithm": SOURCE_SET_ALGORITHM,
        "swiftSourceSetDigest": source_set_digest,
        "swiftSourceCount": len(sources),
        "swiftSourceRelativePaths": [item["relativePath"] for item in sources],
        "swiftSourceFiles": sources,
        "showcaseSourceRoot": "Showcase",
        "showcaseSourceSetDigestAlgorithm": SOURCE_SET_ALGORITHM,
        "showcaseSourceSetDigest": showcase_source_set_digest,
        "showcaseSourceCount": len(showcase_sources),
        "showcaseSourceRelativePaths": [
            item["relativePath"] for item in showcase_sources
        ],
        "showcaseSourceFiles": showcase_sources,
        "sourceAuthorityBuildInputSetDigestAlgorithm": BUILD_INPUT_SET_ALGORITHM,
        "sourceAuthorityBuildInputSetDigest": authority_build_input_digest,
        "sourceAuthorityBuildInputCount": len(authority_build_inputs),
        "sourceAuthorityBuildInputFiles": authority_build_inputs,
        "effectiveBuildInputSetDigestAlgorithm": BUILD_INPUT_SET_ALGORITHM,
        "effectiveBuildInputSetDigest": effective_build_input_digest,
        "effectiveBuildInputCount": len(effective_build_inputs),
        "effectiveBuildInputFiles": effective_build_inputs,
        "authorizedBuildInputTransforms": authorized_transforms,
        "developmentTeam": args.development_team,
        "bundlePrefix": args.bundle_prefix,
        "effectiveBuildSettingsPath": str(_absolute_lexical(args.build_settings)),
        "effectiveBuildSettingsDigestAlgorithm": BUILD_SETTINGS_ALGORITHM,
        "effectiveBuildSettingsDigest": build_settings_digest,
        "effectiveBuildSettings": build_settings,
        "preexistingSwiftFileLists": preexisting_filelists(
            derived_data, args.configuration, args.platform
        ),
        "preexistingShowcaseFileLists": preexisting_showcase_filelists(
            derived_data, args.configuration, args.platform
        ),
    }


def _validate_receipt_shape(receipt: dict) -> None:
    if receipt.get("formatVersion") != 1 or receipt.get("authority") != RECEIPT_AUTHORITY:
        raise BuildBindingError("prebuild receipt has an unsupported authority or format")
    if TEAM.fullmatch(str(receipt.get("developmentTeam", ""))) is None or (
        BUNDLE_PREFIX.fullmatch(str(receipt.get("bundlePrefix", ""))) is None
    ):
        raise BuildBindingError("prebuild receipt has invalid signing transform inputs")
    for field, pattern in (
        ("sourceCommit", SHA1),
        ("releaseSourceDigest", SHA256),
        ("artifactDigest", SHA256),
        ("workspaceStateDigest", SHA256),
        ("swiftSourceSetDigest", SHA256),
        ("sourceAuthorityBuildInputSetDigest", SHA256),
        ("effectiveBuildInputSetDigest", SHA256),
        ("effectiveBuildSettingsDigest", SHA256),
        ("candidateRuntimeBinding", SHA256),
    ):
        if pattern.fullmatch(str(receipt.get(field, ""))) is None:
            raise BuildBindingError(f"prebuild receipt has no valid {field}")
    sources = receipt.get("swiftSourceRelativePaths")
    if (
        not isinstance(sources, list)
        or not sources
        or any(not isinstance(path, str) or not path.endswith(".swift") for path in sources)
        or sources != sorted(set(sources))
        or receipt.get("swiftSourceCount") != len(sources)
    ):
        raise BuildBindingError("prebuild receipt has an invalid Swift source inventory")
    for prefix in ("swift", "showcase"):
        records = receipt.get(f"{prefix}SourceFiles")
        relative_paths = receipt.get(f"{prefix}SourceRelativePaths")
        if (
            not isinstance(records, list)
            or not records
            or not isinstance(relative_paths, list)
            or [item.get("relativePath") for item in records if isinstance(item, dict)]
            != relative_paths
            or policy.compiled_source_set_digest(records)
            != receipt.get(f"{prefix}SourceSetDigest")
            or receipt.get(f"{prefix}SourceCount") != len(records)
        ):
            raise BuildBindingError(
                f"prebuild receipt has an invalid {prefix} source content inventory"
            )
    preexisting = receipt.get("preexistingSwiftFileLists")
    if not isinstance(preexisting, dict) or any(
        not isinstance(path, str) or SHA256.fullmatch(str(digest)) is None
        for path, digest in preexisting.items()
    ):
        raise BuildBindingError("prebuild receipt has invalid preexisting SwiftFileLists")
    preexisting_showcase = receipt.get("preexistingShowcaseFileLists")
    if not isinstance(preexisting_showcase, dict) or any(
        not isinstance(path, str) or SHA256.fullmatch(str(digest)) is None
        for path, digest in preexisting_showcase.items()
    ):
        raise BuildBindingError(
            "prebuild receipt has invalid preexisting Showcase SwiftFileLists"
        )
    for prefix in ("sourceAuthority", "effective"):
        records = receipt.get(f"{prefix}BuildInputFiles")
        if (
            not isinstance(records, list)
            or receipt.get(f"{prefix}BuildInputCount") != len(records)
            or policy.build_input_set_digest(records)
            != receipt.get(f"{prefix}BuildInputSetDigest")
        ):
            raise BuildBindingError(
                f"prebuild receipt has invalid {prefix} build input inventory"
            )
    transforms = receipt.get("authorizedBuildInputTransforms")
    if (
        not isinstance(transforms, list)
        or transforms != sorted(set(transforms))
        or not set(transforms).issubset(AUTHORIZED_BUILD_INPUT_TRANSFORMS)
    ):
        raise BuildBindingError("prebuild receipt has invalid build input transforms")
    settings = receipt.get("effectiveBuildSettings")
    if (
        not isinstance(settings, list)
        or policy.effective_build_settings_digest(settings)
        != receipt.get("effectiveBuildSettingsDigest")
    ):
        raise BuildBindingError("prebuild receipt has invalid effective build settings")


def verify_filelists(receipt: dict) -> list[dict]:
    source_root = Path(receipt["sourceRoot"])
    derived_data = Path(receipt["derivedData"])
    configuration = receipt["buildConfiguration"]
    platform = receipt["buildPlatform"]
    lists = discover_filelists(derived_data, configuration, platform)
    if not lists:
        raise BuildBindingError(
            "postbuild verification found no SwiftVLC.SwiftFileList for "
            f"{configuration}-{platform}; rerun build-for-testing without --skip-build"
        )
    expected = [
        str(source_root / "Sources" / "SwiftVLC" / relative)
        for relative in receipt["swiftSourceRelativePaths"]
    ]
    expected_set = set(expected)
    root = _absolute_lexical(derived_data)
    preexisting = receipt["preexistingSwiftFileLists"]
    records: list[dict] = []
    architectures: set[str] = set()
    for path in lists:
        relative = path.relative_to(root).as_posix()
        raw_digest = policy.sha256_file(path)
        if preexisting.get(relative) == raw_digest:
            raise BuildBindingError(
                "SwiftVLC.SwiftFileList was not refreshed by this build; remove the "
                f"stale {configuration}-{platform} SwiftVLC intermediates and rebuild: {path}"
            )
        try:
            lines = path.read_text().splitlines()
        except (OSError, UnicodeError) as error:
            raise BuildBindingError(f"cannot read Swift file list {path}: {error}") from error
        if any(not line.strip() for line in lines):
            raise BuildBindingError(f"Swift file list contains an empty entry: {path}")
        actual = [str(_absolute_lexical(Path(line))) for line in lines]
        if len(actual) != len(set(actual)):
            raise BuildBindingError(f"Swift file list contains duplicate entries: {path}")
        actual_set = set(actual)
        missing = sorted(Path(item).name for item in expected_set - actual_set)
        extra = sorted(actual_set - expected_set)
        if missing or extra:
            raise BuildBindingError(
                "Swift file list does not exactly match BUILD_SOURCE_ROOT/Sources/SwiftVLC; "
                f"missing={missing!r}, extra={extra!r}, file={path}"
            )
        architecture = path.parent.name
        if architecture in architectures:
            raise BuildBindingError(f"ambiguous duplicate Swift file list architecture: {architecture}")
        architectures.add(architecture)
        records.append(
            {
                "architecture": architecture,
                "digestAlgorithm": "sha256",
                "digest": raw_digest,
                "relativePath": relative,
                "sourceCount": len(actual),
            }
        )
    return sorted(records, key=lambda item: (item["architecture"], item["relativePath"]))


def verify_showcase_filelists(receipt: dict) -> list[dict]:
    source_root = Path(receipt["sourceRoot"])
    derived_data = Path(receipt["derivedData"])
    configuration = receipt["buildConfiguration"]
    platform = receipt["buildPlatform"]
    derived_root = _absolute_lexical(derived_data)
    showcase_root = source_root / "Showcase"
    all_showcase_sources = receipt["showcaseSourceRelativePaths"]
    expected_by_target = {
        "iOS": sorted(
            relative
            for relative in all_showcase_sources
            if relative.startswith("Shared/") or relative.startswith("iOS/")
        ),
        "iOSUITests": sorted(
            relative
            for relative in all_showcase_sources
            if relative.startswith("Shared/")
            or relative.startswith("UITests/iOS/")
        ),
    }
    preexisting = receipt["preexistingShowcaseFileLists"]
    records: list[dict] = []
    for target, source_relatives in expected_by_target.items():
        if not source_relatives:
            raise BuildBindingError(
                f"attested Showcase inventory has no expected {target} sources"
            )
        paths = discover_showcase_filelists(
            derived_data, configuration, platform, target
        )
        if not paths:
            raise BuildBindingError(
                f"postbuild verification found no {target}.SwiftFileList; "
                "rebuild the candidate and UI-test runner"
            )
        architectures: set[str] = set()
        expected_sources = {
            str(showcase_root / relative) for relative in source_relatives
        }
        for path in paths:
            relative_path = path.relative_to(derived_root).as_posix()
            raw_digest = policy.sha256_file(path)
            if preexisting.get(relative_path) == raw_digest:
                raise BuildBindingError(
                    f"{target}.SwiftFileList was not refreshed by this build; remove "
                    f"the stale {configuration}-{platform} Showcase intermediates and rebuild"
                )
            try:
                lines = path.read_text().splitlines()
            except (OSError, UnicodeError) as error:
                raise BuildBindingError(
                    f"cannot read {target} Swift file list {path}: {error}"
                ) from error
            if any(not line.strip() for line in lines):
                raise BuildBindingError(
                    f"{target} Swift file list contains an empty entry: {path}"
                )
            actual = [str(_absolute_lexical(Path(line))) for line in lines]
            if len(actual) != len(set(actual)):
                raise BuildBindingError(
                    f"{target} Swift file list contains duplicate entries: {path}"
                )
            generated_root = path.parents[2] / "DerivedSources"
            expected_generated = str(generated_root / "GeneratedAssetSymbols.swift")
            actual_sources = set(actual) - {expected_generated}
            missing = sorted(expected_sources - actual_sources)
            extra = sorted(actual_sources - expected_sources)
            if missing or extra or expected_generated not in actual:
                raise BuildBindingError(
                    f"{target} Swift file list does not exactly match its attested "
                    "Showcase source set plus GeneratedAssetSymbols.swift; "
                    f"missing={missing!r}, extra={extra!r}, file={path}"
                )
            generated_path = Path(expected_generated)
            if not generated_path.is_file() or generated_path.is_symlink():
                raise BuildBindingError(
                    f"{target} generated Swift compile input is missing or unsafe: "
                    f"{generated_path}"
                )
            architecture = path.parent.name
            if architecture in architectures:
                raise BuildBindingError(
                    f"ambiguous duplicate {target} Swift file-list architecture: {architecture}"
                )
            architectures.add(architecture)
            records.append(
                {
                    "target": target,
                    "architecture": architecture,
                    "digestAlgorithm": "sha256",
                    "digest": raw_digest,
                    "relativePath": relative_path,
                    "sourceCount": len(expected_sources),
                    "generatedSourceCount": 1,
                    "generatedSourceDigestAlgorithm": "sha256",
                    "generatedSourceDigest": policy.sha256_file(generated_path),
                }
            )
    return sorted(
        records,
        key=lambda item: (
            item["target"],
            item["architecture"],
            item["relativePath"],
        ),
    )


def make_attestation(receipt: dict) -> dict:
    _validate_receipt_shape(receipt)
    source_root = Path(receipt["sourceRoot"])
    binding_mode, artifact_digest = artifact_binding(
        source_root,
        source_root / "Vendor" / "libvlc.xcframework",
        Path(receipt["artifactAuthority"]),
    )
    workspace, workspace_digest = workspace_binding(source_root, Path(receipt["derivedData"]))
    verify_source_authority(
        Path(receipt["sourceAuthority"]),
        receipt["version"],
        receipt["sourceCommit"],
        receipt["releaseSourceDigest"],
    )
    sources, source_set_digest = compiled_source_inventory(
        source_root, "Sources/SwiftVLC", "build SwiftVLC source tree"
    )
    authority_sources, authority_source_set_digest = compiled_source_inventory(
        Path(receipt["sourceAuthority"]),
        "Sources/SwiftVLC",
        "authority SwiftVLC source tree",
    )
    showcase_sources, showcase_source_set_digest = compiled_source_inventory(
        source_root, "Showcase", "build Showcase source tree"
    )
    authority_showcase_sources, authority_showcase_digest = compiled_source_inventory(
        Path(receipt["sourceAuthority"]),
        "Showcase",
        "authority Showcase source tree",
    )
    authority_build_inputs, authority_build_input_digest = build_input_inventory(
        Path(receipt["sourceAuthority"])
    )
    effective_build_inputs, effective_build_input_digest = build_input_inventory(
        source_root
    )
    authorized_transforms = compare_build_input_authority(
        Path(receipt["sourceAuthority"]),
        source_root,
        authority_build_inputs,
        effective_build_inputs,
        receipt["developmentTeam"],
        receipt["bundlePrefix"],
    )
    build_settings, build_settings_digest = effective_build_settings(
        Path(receipt["effectiveBuildSettingsPath"])
    )
    if sources != authority_sources or source_set_digest != authority_source_set_digest:
        raise BuildBindingError(
            "postbuild SwiftVLC source bytes/modes differ from the clean authority"
        )
    if (
        showcase_sources != authority_showcase_sources
        or showcase_source_set_digest != authority_showcase_digest
    ):
        raise BuildBindingError(
            "postbuild Showcase Swift/UI-test source bytes/modes differ from the clean authority"
        )
    expected_rechecks = {
        "artifactBindingMode": binding_mode,
        "artifactDigest": artifact_digest,
        "workspaceStateDigest": workspace_digest,
        "workspaceBinding": workspace,
        "swiftSourceRelativePaths": [item["relativePath"] for item in sources],
        "swiftSourceFiles": sources,
        "swiftSourceSetDigest": source_set_digest,
        "swiftSourceCount": len(sources),
        "showcaseSourceRelativePaths": [
            item["relativePath"] for item in showcase_sources
        ],
        "showcaseSourceFiles": showcase_sources,
        "showcaseSourceSetDigest": showcase_source_set_digest,
        "showcaseSourceCount": len(showcase_sources),
        "sourceAuthorityBuildInputSetDigest": authority_build_input_digest,
        "sourceAuthorityBuildInputCount": len(authority_build_inputs),
        "sourceAuthorityBuildInputFiles": authority_build_inputs,
        "effectiveBuildInputSetDigest": effective_build_input_digest,
        "effectiveBuildInputCount": len(effective_build_inputs),
        "effectiveBuildInputFiles": effective_build_inputs,
        "authorizedBuildInputTransforms": authorized_transforms,
        "effectiveBuildSettingsDigest": build_settings_digest,
        "effectiveBuildSettings": build_settings,
    }
    for field, actual in expected_rechecks.items():
        if receipt.get(field) != actual:
            raise BuildBindingError(
                f"postbuild {field} changed since the prebuild resolution receipt"
            )
    filelists = verify_filelists(receipt)
    showcase_filelists = verify_showcase_filelists(receipt)
    candidate_app = _absolute_lexical(receipt["candidateApp"])
    test_runner = _absolute_lexical(receipt["testRunner"])
    test_bundle = _absolute_lexical(receipt["testBundle"])
    base_xctestrun = _absolute_lexical(receipt["baseXCTestRun"])
    if test_bundle.parent.parent != test_runner or test_bundle.suffix != ".xctest":
        raise BuildBindingError(
            "postbuild test bundle is not the exact embedded runner PlugIns product"
        )
    if (
        candidate_app.name != "iOS.app"
        or test_runner.name != "iOSUITests-Runner.app"
        or base_xctestrun.suffix != ".xctestrun"
    ):
        raise BuildBindingError("postbuild candidate product names are not canonical")
    try:
        candidate_app_digest = policy.tree_digest(candidate_app)
        test_runner_digest = policy.tree_digest(test_runner)
        test_bundle_digest = policy.tree_digest(test_bundle)
        xctestrun_digest = policy.sha256_file(base_xctestrun)
    except policy.QualificationPolicyError as error:
        raise BuildBindingError(str(error)) from error
    return {
        "formatVersion": 1,
        "authority": ATTESTATION_AUTHORITY,
        "version": receipt["version"],
        "candidateRuntimeBinding": receipt["candidateRuntimeBinding"],
        "sourceCommit": receipt["sourceCommit"],
        "releaseSourceDigestAlgorithm": receipt["releaseSourceDigestAlgorithm"],
        "releaseSourceDigest": receipt["releaseSourceDigest"],
        "artifactRelativePath": "Vendor/libvlc.xcframework",
        "artifactBindingMode": receipt["artifactBindingMode"],
        "artifactDigestAlgorithm": receipt["artifactDigestAlgorithm"],
        "artifactDigest": receipt["artifactDigest"],
        "workspaceStateRelativePath": "SourcePackages/workspace-state.json",
        "workspaceStateDigestAlgorithm": receipt["workspaceStateDigestAlgorithm"],
        "workspaceStateDigest": receipt["workspaceStateDigest"],
        "workspaceBinding": receipt["workspaceBinding"],
        "buildConfiguration": receipt["buildConfiguration"],
        "buildPlatform": receipt["buildPlatform"],
        "swiftSourceRoot": receipt["swiftSourceRoot"],
        "swiftSourceSetDigestAlgorithm": receipt["swiftSourceSetDigestAlgorithm"],
        "swiftSourceSetDigest": receipt["swiftSourceSetDigest"],
        "swiftSourceCount": receipt["swiftSourceCount"],
        "swiftSourceRelativePaths": receipt["swiftSourceRelativePaths"],
        "swiftSourceFiles": receipt["swiftSourceFiles"],
        "showcaseSourceRoot": receipt["showcaseSourceRoot"],
        "showcaseSourceSetDigestAlgorithm": receipt[
            "showcaseSourceSetDigestAlgorithm"
        ],
        "showcaseSourceSetDigest": receipt["showcaseSourceSetDigest"],
        "showcaseSourceCount": receipt["showcaseSourceCount"],
        "showcaseSourceRelativePaths": receipt["showcaseSourceRelativePaths"],
        "showcaseSourceFiles": receipt["showcaseSourceFiles"],
        "sourceAuthorityBuildInputSetDigestAlgorithm": receipt[
            "sourceAuthorityBuildInputSetDigestAlgorithm"
        ],
        "sourceAuthorityBuildInputSetDigest": receipt[
            "sourceAuthorityBuildInputSetDigest"
        ],
        "sourceAuthorityBuildInputCount": receipt[
            "sourceAuthorityBuildInputCount"
        ],
        "sourceAuthorityBuildInputFiles": receipt[
            "sourceAuthorityBuildInputFiles"
        ],
        "effectiveBuildInputSetDigestAlgorithm": receipt[
            "effectiveBuildInputSetDigestAlgorithm"
        ],
        "effectiveBuildInputSetDigest": receipt["effectiveBuildInputSetDigest"],
        "effectiveBuildInputCount": receipt["effectiveBuildInputCount"],
        "effectiveBuildInputFiles": receipt["effectiveBuildInputFiles"],
        "authorizedBuildInputTransforms": receipt[
            "authorizedBuildInputTransforms"
        ],
        "developmentTeam": receipt["developmentTeam"],
        "bundlePrefix": receipt["bundlePrefix"],
        "effectiveBuildSettingsDigestAlgorithm": receipt[
            "effectiveBuildSettingsDigestAlgorithm"
        ],
        "effectiveBuildSettingsDigest": receipt[
            "effectiveBuildSettingsDigest"
        ],
        "effectiveBuildSettings": receipt["effectiveBuildSettings"],
        "swiftFileLists": filelists,
        "showcaseTargetFileLists": showcase_filelists,
        "candidateAppRelativePath": "Release-iphoneos/iOS.app",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": candidate_app_digest,
        "testRunnerRelativePath": "Release-iphoneos/iOSUITests-Runner.app",
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerDigest": test_runner_digest,
        "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleDigest": test_bundle_digest,
        "baseXCTestRunName": base_xctestrun.name,
        "baseXCTestRunDigestAlgorithm": "sha256",
        "baseXCTestRunDigest": xctestrun_digest,
    }


def bind_catalog(attestation: dict, catalog_path: Path) -> dict:
    if attestation.get("authority") != ATTESTATION_AUTHORITY:
        raise BuildBindingError("cannot bind a catalog to an unsupported attestation")
    try:
        catalog = policy.load_json(catalog_path, "XCTest catalog")
        canonical = policy.catalog_record(catalog.get("testIdentifiers", []))
    except policy.QualificationPolicyError as error:
        raise BuildBindingError(str(error)) from error
    if catalog != canonical:
        raise BuildBindingError("XCTest catalog is not canonical")
    result = dict(attestation)
    result.update(
        {
            "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
            "testCatalogDigest": canonical["digest"],
            "testCatalogCount": canonical["testCount"],
            "testCatalog": canonical["testIdentifiers"],
        }
    )
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prebuild = subparsers.add_parser("prebuild")
    prebuild.add_argument("--source-root", type=Path, required=True)
    prebuild.add_argument("--source-authority", type=Path, required=True)
    prebuild.add_argument("--artifact-authority", type=Path, required=True)
    prebuild.add_argument("--derived-data", type=Path, required=True)
    prebuild.add_argument("--build-settings", type=Path, required=True)
    prebuild.add_argument("--development-team", required=True)
    prebuild.add_argument("--bundle-prefix", required=True)
    prebuild.add_argument("--source-commit", required=True)
    prebuild.add_argument("--release-source-digest", required=True)
    prebuild.add_argument("--version", required=True)
    prebuild.add_argument("--candidate-runtime-binding", required=True)
    prebuild.add_argument("--configuration", default="Release")
    prebuild.add_argument("--platform", default="iphoneos")
    prebuild.add_argument("--output", type=Path, required=True)
    postbuild = subparsers.add_parser("postbuild")
    postbuild.add_argument("--receipt", type=Path, required=True)
    postbuild.add_argument("--candidate-app", type=Path, required=True)
    postbuild.add_argument("--test-runner", type=Path, required=True)
    postbuild.add_argument("--test-bundle", type=Path, required=True)
    postbuild.add_argument("--xctestrun", type=Path, required=True)
    postbuild.add_argument("--output", type=Path, required=True)
    catalog = subparsers.add_parser("bind-catalog")
    catalog.add_argument("--attestation", type=Path, required=True)
    catalog.add_argument("--test-catalog", type=Path, required=True)
    catalog.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "prebuild":
            value = make_receipt(args)
        elif args.command == "postbuild":
            receipt = load_json(args.receipt, "prebuild receipt")
            receipt.update(
                {
                    "candidateApp": str(args.candidate_app),
                    "testRunner": str(args.test_runner),
                    "testBundle": str(args.test_bundle),
                    "baseXCTestRun": str(args.xctestrun),
                }
            )
            value = make_attestation(receipt)
        else:
            value = bind_catalog(
                load_json(args.attestation, "candidate build attestation"),
                args.test_catalog,
            )
        write_json(args.output, value)
    except (BuildBindingError, OSError, policy.QualificationPolicyError) as error:
        parser.error(str(error))
    print(json.dumps(value, sort_keys=True))


if __name__ == "__main__":
    main()
