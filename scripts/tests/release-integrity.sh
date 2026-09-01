#!/usr/bin/env bash
set -euo pipefail

# Keep Python imports from dirtying the release source tree with bytecode caches.
export PYTHONDONTWRITEBYTECODE=1

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-release-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

python3 "$SCRIPT_DIR/verify-native-validator-assets.py" >/dev/null || \
  fail "repository native validator asset manifest is not current"

# Native validation is executable release evidence, not an untracked build
# convenience. Exercise the standalone asset-manifest verifier in an isolated
# repository-shaped fixture so drift, omission, and duplicate entries all fail
# before an expensive libVLC build begins.
validator_asset_fixture="$temp_dir/validator-assets"
mkdir -p "$validator_asset_fixture"
validator_asset_listing=$(
  python3 "$SCRIPT_DIR/verify-native-validator-assets.py" --list
)
while IFS= read -r relative; do
  [[ -n "$relative" ]] || continue
  mkdir -p "$validator_asset_fixture/$(dirname "$relative")"
  printf 'fixture for %s\n' "$relative" > "$validator_asset_fixture/$relative"
  chmod 0644 "$validator_asset_fixture/$relative"
  case "$relative" in
    scripts/patches/validation/effective-playback-rate-event-source-check.py|\
    scripts/patches/validation/vmem-picture-pts-source-check.py|\
    scripts/validate-*.sh)
      chmod 0755 "$validator_asset_fixture/$relative"
      ;;
  esac
done <<< "$validator_asset_listing"

python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$validator_asset_fixture" --update >/dev/null
python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$validator_asset_fixture" >/dev/null
validator_manifest_before=$(shasum -a 256 \
  "$validator_asset_fixture/scripts/native-validator-assets.sha256" | cut -d' ' -f1)
python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$validator_asset_fixture" --update >/dev/null
validator_manifest_after=$(shasum -a 256 \
  "$validator_asset_fixture/scripts/native-validator-assets.sha256" | cut -d' ' -f1)
[[ "$validator_manifest_before" == "$validator_manifest_after" ]] || \
  fail "native validator asset manifest update is nondeterministic"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-drift"
printf 'drift\n' >> \
  "$temp_dir/validator-assets-drift/scripts/validate-strict-frame-step.sh"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-drift" \
  >"$temp_dir/validator-assets-drift.log" 2>&1; then
  fail "native validator asset drift was accepted"
fi
grep -q 'native validator asset hash mismatch' \
  "$temp_dir/validator-assets-drift.log" || \
  fail "native validator drift did not produce a fail-closed diagnostic"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-mode-drift"
chmod 0755 \
  "$temp_dir/validator-assets-mode-drift/scripts/tests/test_pip_extension_version.py"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-mode-drift" \
  >"$temp_dir/validator-assets-mode-drift.log" 2>&1; then
  fail "native validator asset mode drift was accepted"
fi
grep -q 'native validator asset mode mismatch' \
  "$temp_dir/validator-assets-mode-drift.log" || \
  fail "native validator mode drift did not produce a fail-closed diagnostic"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-omission"
sed '1d' \
  "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256" \
  > "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256.tmp"
mv "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256.tmp" \
  "$temp_dir/validator-assets-omission/scripts/native-validator-assets.sha256"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-omission" \
  >"$temp_dir/validator-assets-omission.log" 2>&1; then
  fail "an omitted native validator asset was accepted"
fi
grep -q 'native validator asset inventory mismatch' \
  "$temp_dir/validator-assets-omission.log" || \
  fail "native validator omission did not produce a fail-closed diagnostic"

cp -R "$validator_asset_fixture" "$temp_dir/validator-assets-duplicate"
head -n 1 \
  "$temp_dir/validator-assets-duplicate/scripts/native-validator-assets.sha256" \
  >> "$temp_dir/validator-assets-duplicate/scripts/native-validator-assets.sha256"
if python3 "$SCRIPT_DIR/verify-native-validator-assets.py" \
  --root "$temp_dir/validator-assets-duplicate" \
  >"$temp_dir/validator-assets-duplicate.log" 2>&1; then
  fail "a duplicate native validator asset was accepted"
fi
grep -q 'duplicate native validator asset' \
  "$temp_dir/validator-assets-duplicate.log" || \
  fail "duplicate native validator asset did not produce a fail-closed diagnostic"

python3 -B -m unittest discover \
  -s "$SCRIPT_DIR/tests" -p 'test_release_version_policy.py'

checksum="03a57454a6159c455406889c7867e0b284db028d2734a10bdf85a6a7285c862f"
cat > "$temp_dir/Package.swift" <<EOF
let package = Package(targets: [
  .binaryTarget(
    name: "libvlc",
    url: "https://github.com/harflabs/SwiftVLC/releases/download/v1.1.0-beta.1/libvlc.xcframework.zip",
    checksum: "$checksum"
  )
])
EOF

resolved_tag=$(python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --field tag)
[[ "$resolved_tag" == "v1.1.0-beta.1" ]] || fail "pre-release tag was not parsed"

python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --expect-tag v1.1.0-beta.1 >/dev/null
if python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --expect-tag v1.1.0 >/dev/null 2>&1; then
  fail "mismatched expected tag was accepted"
fi

sed 's#url: "https://[^\"]*"#path: "Vendor/libvlc.xcframework"#' \
  "$temp_dir/Package.swift" > "$temp_dir/LocalPackage.swift"
if python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/LocalPackage.swift" >/dev/null 2>&1; then
  fail "local binary target was treated as a released artifact"
fi

mkdir -p "$temp_dir/tree-a/Headers" "$temp_dir/tree-b/Headers"
printf 'binary' > "$temp_dir/tree-a/libvlc.a"
printf 'header' > "$temp_dir/tree-a/Headers/libvlc.h"
cp -R "$temp_dir/tree-a/." "$temp_dir/tree-b/"

digest_a=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-a")
digest_b=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-b")
[[ "$digest_a" == "$digest_b" ]] || fail "digest depends on the artifact root path"

touch -t 202001010000 "$temp_dir/tree-b/Headers/libvlc.h"
digest_b=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-b")
[[ "$digest_a" == "$digest_b" ]] || fail "digest depends on file timestamps"

printf 'changed header' > "$temp_dir/tree-b/Headers/libvlc.h"
digest_b=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/tree-b")
[[ "$digest_a" != "$digest_b" ]] || fail "header changes do not affect the digest"

# Both digest implementations must preserve valid internal symlinks while
# refusing links whose bytes are hashed but whose effective content lives
# outside the artifact (or does not exist at all).
python3 - \
  "$SCRIPT_DIR/artifact-tree-digest.py" \
  "$SCRIPT_DIR/libvlc-provenance.py" \
  "$temp_dir" <<'PY'
import importlib.util
import os
import sys
from pathlib import Path


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


standalone = load_module("swiftvlc_artifact_digest", sys.argv[1])
provenance = load_module("swiftvlc_provenance", sys.argv[2])
root = Path(sys.argv[3]) / "symlink-confinement"
outside = root.parent / "symlink-outside.h"
outside.write_text("outside\n")

valid = root / "valid"
valid.mkdir(parents=True)
(valid / "target.h").write_text("inside\n")
(valid / "current.h").symlink_to("target.h")
valid_digests = [
    implementation.tree_digest(valid)
    for implementation in (standalone, provenance)
]
if valid_digests[0] != valid_digests[1]:
    raise SystemExit("tree-digest implementations disagree on an internal symlink")

fixtures = {
    "absolute-escape": str(outside),
    "relative-escape": os.path.relpath(outside, root / "relative-escape"),
    "broken": "missing-target.h",
}
for name, target in fixtures.items():
    fixture = root / name
    fixture.mkdir()
    (fixture / "link.h").symlink_to(target)
    for implementation in (standalone, provenance):
        try:
            implementation.tree_digest(fixture)
        except SystemExit as error:
            if "escapes the tree or is broken" not in str(error):
                raise SystemExit(
                    f"{implementation.__name__} misdiagnosed {name}: {error}"
                )
        else:
            raise SystemExit(
                f"{implementation.__name__} accepted artifact symlink {name}"
            )
PY

# Complete engine provenance records exact slices, SDK/toolchain inputs, patch
# order, contrib checksums, and two-build reproducibility. Exercise it with a
# minimal valid XCFramework so release integrity does not depend on a 368 MB
# binary fixture.
mkdir -p "$temp_dir/fake-vlc/contrib/src/example"
printf 'example contrib checksum\n' > "$temp_dir/fake-vlc/contrib/src/example/SHA512SUMS"
printf '%064d  0001-example.patch\n' 0 > "$temp_dir/patch-manifest.sha256"
printf '#!/bin/sh\necho fixture\n' > "$temp_dir/build-config.sh"
printf '#!/bin/sh\necho validator fixture\n' > "$temp_dir/validator-config.sh"
fixture_source_date_epoch=1700000000
fixture_swiftvlc_revision=2222222222222222222222222222222222222222
mkdir -p "$temp_dir/build-a/macos-arm64/Headers"
printf 'header\n' > "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"
ln -s libvlc.h "$temp_dir/build-a/macos-arm64/Headers/current.h"
printf 'int swiftvlc_provenance_fixture(void) { return 1; }\n' > "$temp_dir/member.c"
xcrun clang -c "$temp_dir/member.c" -o "$temp_dir/member.o"
ar rcs "$temp_dir/build-a/macos-arm64/libvlc.a" "$temp_dir/member.o"
python3 - "$temp_dir/build-a/Info.plist" <<'PY'
import plistlib
import sys

value = {
    "AvailableLibraries": [
        {
            "LibraryIdentifier": "macos-arm64",
            "LibraryPath": "libvlc.a",
            "HeadersPath": "Headers",
            "SupportedArchitectures": ["arm64"],
            "SupportedPlatform": "macos",
        }
    ],
    "CFBundlePackageType": "XFWK",
    "XCFrameworkFormatVersion": "1.0",
}
with open(sys.argv[1], "wb") as output:
    plistlib.dump(value, output, sort_keys=True)
PY
mkdir -p "$temp_dir/build-b/macos-arm64/Headers"
# Create the second logical tree in a different directory-entry order too.
cp "$temp_dir/build-a/Info.plist" "$temp_dir/build-b/Info.plist"
cp "$temp_dir/build-a/macos-arm64/libvlc.a" \
  "$temp_dir/build-b/macos-arm64/libvlc.a"
ln -s libvlc.h "$temp_dir/build-b/macos-arm64/Headers/current.h"
cp "$temp_dir/build-a/macos-arm64/Headers/libvlc.h" \
  "$temp_dir/build-b/macos-arm64/Headers/libvlc.h"

# Provenance deliberately ignores host filesystem metadata, while release ZIP
# bytes must not. Make the two logical trees differ in every excluded metadata
# class and prove canonical staging/archive removes that host dependence.
touch -t 203801190314 "$temp_dir/build-b/Info.plist"
xattr -w com.swiftvlc.release-integrity different \
  "$temp_dir/build-b/macos-arm64/Headers/libvlc.h"
xattr -w com.apple.ResourceFork resource-fork \
  "$temp_dir/build-b/macos-arm64/libvlc.a"
chmod +a "user:$(id -un) allow read" \
  "$temp_dir/build-b/macos-arm64/Headers/libvlc.h"

build_index=0
for build_name in a b; do
  build_index=$((build_index + 1))
  # Provenance records canonical second-resolution UTC completion times. A real
  # clean Apple build takes many minutes; keep the compact fixture ordered too.
  if [[ "$build_name" == b ]]; then
    sleep 1
  fi
  "$SCRIPT_DIR/libvlc-provenance.py" create \
    --xcframework "$temp_dir/build-$build_name" \
    --output "$temp_dir/provenance-$build_name.json" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --vlc-source "$temp_dir/fake-vlc" \
    --source-revision 1111111111111111111111111111111111111111 \
    --pinned-revision 111111111 \
    --source-date-epoch "$fixture_source_date_epoch" \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    --build-invocation-id "00000000-0000-0000-0000-00000000000${build_index}" \
    --clean-build \
    --make-flags=-j1 \
    --deployment-target macos=15.0
done
"$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first-provenance "$temp_dir/provenance-a.json" \
  --first-xcframework "$temp_dir/build-a" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --second-xcframework "$temp_dir/build-b" \
  --output "$temp_dir/reproducibility.json" >/dev/null

# Creating evidence inside the tree it authenticates would make a successful
# command invalidate its own digest. Resolve parent symlinks as well as direct
# paths before any create/compare work or output write occurs.
ln -s "$temp_dir/build-a" "$temp_dir/build-a-output-alias"
create_outputs=(
  "$temp_dir/build-a/forbidden-provenance.json"
  "$temp_dir/build-a-output-alias/forbidden-provenance-alias.json"
)
for forbidden_output in "${create_outputs[@]}"; do
  if "$SCRIPT_DIR/libvlc-provenance.py" create \
    --xcframework "$temp_dir/build-a" \
    --output "$forbidden_output" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --vlc-source "$temp_dir/fake-vlc" \
    --source-revision 1111111111111111111111111111111111111111 \
    --pinned-revision 111111111 \
    --source-date-epoch "$fixture_source_date_epoch" \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    --build-invocation-id 00000000-0000-0000-0000-000000000099 \
    --clean-build \
    --make-flags=-j1 \
    --deployment-target macos=15.0 >/dev/null 2>&1; then
    fail "provenance create wrote evidence inside its XCFramework"
  fi
  [[ ! -e "$forbidden_output" ]] || \
    fail "rejected in-artifact provenance output was still written"
done

compare_outputs=(
  "$temp_dir/build-a/forbidden-proof.json"
  "$temp_dir/build-a-output-alias/forbidden-proof-alias.json"
)
for forbidden_output in "${compare_outputs[@]}"; do
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-a.json" \
    --first-xcframework "$temp_dir/build-a" \
    --second-provenance "$temp_dir/provenance-b.json" \
    --second-xcframework "$temp_dir/build-b" \
    --output "$forbidden_output" >/dev/null 2>&1; then
    fail "provenance compare wrote proof inside a compared XCFramework"
  fi
  [[ ! -e "$forbidden_output" ]] || \
    fail "rejected in-artifact proof output was still written"
done

"$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" >/dev/null

if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision 3333333333333333333333333333333333333333 \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
  >/dev/null 2>&1; then
  fail "provenance verification accepted a different SwiftVLC commit"
fi

# Every named validator is part of the exact build-configuration inventory.
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted an omitted 0037 validator configuration"
fi
"$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --first-provenance "$temp_dir/provenance-a.json" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --current-provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" >/dev/null

# Every field in the proof's per-slice output block is authoritative. Reject
# value, shape, and type mutations cleanly instead of treating it as display
# data or leaking a Python traceback for malformed schema input.
python3 - "$temp_dir/reproducibility.json" "$temp_dir" <<'PY'
import copy
import json
import sys
from pathlib import Path

source_path = Path(sys.argv[1])
output_root = Path(sys.argv[2])
source = json.loads(source_path.read_text())
slices = source["artifactIdentity"]["slices"]
slice_identifier = next(iter(slices))
slice_record = slices[slice_identifier]


def write(name, value):
    (output_root / f"proof-{name}.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n"
    )


changed = copy.deepcopy(source)
changed["artifactIdentity"]["slices"][slice_identifier]["librarySha256"] = "0" * 64
write("changed-slice-value", changed)

missing_slice = copy.deepcopy(source)
del missing_slice["artifactIdentity"]["slices"][slice_identifier]
write("missing-slice", missing_slice)

extra_slice = copy.deepcopy(source)
extra_slice["artifactIdentity"]["slices"]["unexpected-slice"] = copy.deepcopy(
    slice_record
)
write("extra-slice", extra_slice)

missing_key = copy.deepcopy(source)
del missing_key["artifactIdentity"]["slices"][slice_identifier]["memberCount"]
write("missing-slice-key", missing_key)

extra_key = copy.deepcopy(source)
extra_key["artifactIdentity"]["slices"][slice_identifier][
    "uncheckedDisplayField"
] = "not-bound"
write("extra-slice-key", extra_key)

wrong_type = copy.deepcopy(source)
wrong_type["artifactIdentity"]["slices"][slice_identifier]["memberCount"] = True
write("wrong-slice-value-type", wrong_type)

non_object_slices = copy.deepcopy(source)
non_object_slices["artifactIdentity"]["slices"] = []
write("non-object-slices", non_object_slices)

changed_provenance_hash = copy.deepcopy(source)
changed_provenance_hash["firstBuild"]["provenanceSha256"] = "0" * 64
write("changed-provenance-hash", changed_provenance_hash)

missing_timestamp = copy.deepcopy(source)
del missing_timestamp["firstBuild"]["builtAt"]
write("missing-build-timestamp", missing_timestamp)

extra_top_level = copy.deepcopy(source)
extra_top_level["unverifiedDisplayField"] = True
write("extra-top-level", extra_top_level)

write("non-object-proof", [])

unsupported_schema = copy.deepcopy(source)
unsupported_schema["schemaVersion"] = source["schemaVersion"] + 1
write("unsupported-schema", unsupported_schema)

schema_float = copy.deepcopy(source)
schema_float["schemaVersion"] = float(source["schemaVersion"])
write("schema-float", schema_float)

wrong_build_input_type = copy.deepcopy(source)
wrong_build_input_type["buildInputs"]["sourceDateEpoch"] = True
write("wrong-build-input-type", wrong_build_input_type)

raw = source_path.read_text()
(output_root / "proof-duplicate-key.json").write_text(
    raw.replace(
        f'"schemaVersion": {source["schemaVersion"]},',
        f'"schemaVersion": {source["schemaVersion"]},\n'
        f'  "schemaVersion": {source["schemaVersion"]},',
        1,
    )
)
(output_root / "proof-non-finite.json").write_text(
    raw.replace(
        f'"sourceDateEpoch": {source["buildInputs"]["sourceDateEpoch"]}',
        '"sourceDateEpoch": NaN',
        1,
    )
)
PY
proof_mutations=(
  changed-slice-value
  missing-slice
  extra-slice
  missing-slice-key
  extra-slice-key
  wrong-slice-value-type
  non-object-slices
  changed-provenance-hash
  missing-build-timestamp
  extra-top-level
  non-object-proof
  unsupported-schema
  schema-float
  wrong-build-input-type
  duplicate-key
  non-finite
)
for mutation in "${proof_mutations[@]}"; do
  error_log="$temp_dir/proof-$mutation.stderr"
  if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
    --proof "$temp_dir/proof-$mutation.json" \
    --first-provenance "$temp_dir/provenance-a.json" \
    --second-provenance "$temp_dir/provenance-b.json" \
    --current-provenance "$temp_dir/provenance-b.json" \
    --xcframework "$temp_dir/build-b" \
    >/dev/null 2>"$error_log"; then
    fail "reproducibility proof accepted mutation: $mutation"
  fi
  if grep -q 'Traceback' "$error_log"; then
    fail "reproducibility proof leaked a traceback for mutation: $mutation"
  fi
  grep -q '^Error:' "$error_log" \
    || fail "reproducibility proof did not report a schema error: $mutation"
done

mkdir -p "$temp_dir/canonical-a" "$temp_dir/canonical-b"
for build_name in a b; do
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" stage \
    "$temp_dir/build-$build_name" \
    "$temp_dir/canonical-$build_name/libvlc.xcframework" \
    "$temp_dir/provenance-$build_name.json"
  # Host reads and copies can leave arbitrary atimes after staging. Archive
  # normalization must occur after its final provenance read.
  touch -a -t 203801190314 \
    "$temp_dir/canonical-$build_name/libvlc.xcframework/Info.plist"
  "$SCRIPT_DIR/canonical-libvlc-artifact.sh" archive \
    "$temp_dir/canonical-$build_name/libvlc.xcframework" \
    "$temp_dir/canonical-$build_name.zip" \
    "$temp_dir/provenance-$build_name.json"
done
archive_timezones=(Pacific/Honolulu Europe/Amsterdam Asia/Tokyo UTC)
for archive_iteration in 1 2 3 4; do
  archive_timezone=${archive_timezones[$((archive_iteration - 1))]}
  for build_name in a b; do
    repeated_zip="$temp_dir/canonical-$build_name-repeat-$archive_iteration.zip"
    touch -a -t 203801190314 \
      "$temp_dir/canonical-$build_name/libvlc.xcframework/Info.plist"
    TZ="$archive_timezone" "$SCRIPT_DIR/canonical-libvlc-artifact.sh" archive \
      "$temp_dir/canonical-$build_name/libvlc.xcframework" \
      "$repeated_zip" \
      "$temp_dir/provenance-$build_name.json"
    cmp -s "$temp_dir/canonical-a.zip" "$repeated_zip" \
      || fail "canonical libVLC ZIP changed across repeated archives"
  done
done
if xattr -p com.swiftvlc.release-integrity \
  "$temp_dir/canonical-b/libvlc.xcframework/macos-arm64/Headers/libvlc.h" \
  >/dev/null 2>&1; then
  fail "canonical libVLC staging preserved a custom extended attribute"
fi
if xattr -p com.apple.ResourceFork \
  "$temp_dir/canonical-b/libvlc.xcframework/macos-arm64/libvlc.a" \
  >/dev/null 2>&1; then
  fail "canonical libVLC staging preserved a resource fork"
fi
staged_acl_lines=$(ls -lde \
  "$temp_dir/canonical-b/libvlc.xcframework/macos-arm64/Headers/libvlc.h" \
  | wc -l | tr -d ' ')
[[ "$staged_acl_lines" == 1 ]] \
  || fail "canonical libVLC staging preserved an ACL"
[[ $(stat -f%m "$temp_dir/canonical-b/libvlc.xcframework") \
  == "$fixture_source_date_epoch" ]] \
  || fail "canonical libVLC staging did not apply sourceDateEpoch"
cmp -s "$temp_dir/canonical-a.zip" "$temp_dir/canonical-b.zip" \
  || fail "canonical libVLC ZIP depends on excluded filesystem metadata"
python3 - "$temp_dir/canonical-a.zip" "$fixture_source_date_epoch" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import struct
import sys
import zipfile

archive_path = Path(sys.argv[1])
epoch = int(sys.argv[2])
timestamp = datetime.fromtimestamp(epoch, timezone.utc)
expected_timestamp = (
    timestamp.year,
    timestamp.month,
    timestamp.day,
    timestamp.hour,
    timestamp.minute,
    timestamp.second // 2 * 2,
)
with zipfile.ZipFile(archive_path) as archive:
    entries = archive.infolist()
names = [entry.filename for entry in entries]
if any(
    "/__MACOSX/" in f"/{name}"
    or name.rsplit("/", 1)[-1].startswith("._")
    for name in names
):
    raise SystemExit("canonical libVLC ZIP contains AppleDouble metadata")
with archive_path.open("rb") as raw_archive:
    for entry in entries:
        if entry.extra:
            raise SystemExit(
                f"canonical libVLC ZIP has a central extra field: {entry.filename}"
            )
        if entry.date_time != expected_timestamp:
            raise SystemExit(
                f"canonical libVLC ZIP has a noncanonical timestamp: {entry.filename}"
            )
        raw_archive.seek(entry.header_offset)
        header = raw_archive.read(30)
        if len(header) != 30:
            raise SystemExit("canonical libVLC ZIP has a truncated local header")
        values = struct.unpack("<IHHHHHIIIHH", header)
        if values[0] != 0x04034B50:
            raise SystemExit("canonical libVLC ZIP has an invalid local header")
        filename_size, extra_size = values[-2:]
        raw_archive.seek(filename_size, 1)
        local_extra = raw_archive.read(extra_size)
        if local_extra:
            raise SystemExit(
                f"canonical libVLC ZIP has a local extra field: {entry.filename}"
            )
        if len(local_extra) != extra_size:
            raise SystemExit(
                f"canonical libVLC ZIP has a truncated local extra field: "
                f"{entry.filename}"
            )
        if entry.create_system != 3:
            raise SystemExit(
                f"canonical libVLC ZIP lost Unix modes: {entry.filename}"
            )
        if entry.external_attr >> 16 == 0:
            raise SystemExit(
                f"canonical libVLC ZIP has an empty Unix mode: {entry.filename}"
            )
PY
mkdir -p "$temp_dir/canonical-unpacked"
ditto -x -k "$temp_dir/canonical-a.zip" "$temp_dir/canonical-unpacked"
canonical_digest=$("$SCRIPT_DIR/artifact-tree-digest.py" \
  "$temp_dir/canonical-unpacked/libvlc.xcframework")
recorded_digest=$(python3 - "$temp_dir/provenance-a.json" <<'PY'
import json
import sys

print(json.load(open(sys.argv[1]))["xcframeworkTreeDigest"])
PY
)
[[ "$canonical_digest" == "$recorded_digest" ]] \
  || fail "canonical ZIP does not expand to the proven logical tree"
canonical_link="$temp_dir/canonical-unpacked/libvlc.xcframework/macos-arm64/Headers/current.h"
[[ -L "$canonical_link" && $(readlink "$canonical_link") == libvlc.h ]] \
  || fail "canonical ZIP did not preserve the provenance-covered symlink"

mode_before=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/build-a")
chmod +x "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"
mode_after=$("$SCRIPT_DIR/artifact-tree-digest.py" "$temp_dir/build-a")
[[ "$mode_before" != "$mode_after" ]] \
  || fail "logical tree digest ignored a changed POSIX mode"
if "$SCRIPT_DIR/canonical-libvlc-artifact.sh" stage \
  "$temp_dir/build-a" "$temp_dir/mode-mutated/libvlc.xcframework" \
  "$temp_dir/provenance-a.json" >/dev/null 2>&1; then
  fail "canonical staging accepted a mode-mutated logical tree"
fi
chmod -x "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"

# A changed effective build script invalidates otherwise matching provenance.
printf '#!/bin/sh\necho changed\n' > "$temp_dir/build-config.sh"
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted a changed build configuration"
fi
printf '#!/bin/sh\necho fixture\n' > "$temp_dir/build-config.sh"

printf '#!/bin/sh\necho changed validator\n' > "$temp_dir/validator-config.sh"
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted 0037 validator hash drift"
fi
printf '#!/bin/sh\necho validator fixture\n' > "$temp_dir/validator-config.sh"

# A clean-build marker without an independent invocation is not a second build.
cp "$temp_dir/provenance-b.json" "$temp_dir/provenance-same-invocation.json"
python3 - "$temp_dir/provenance-a.json" "$temp_dir/provenance-same-invocation.json" <<'PY'
import json
import sys

first = json.load(open(sys.argv[1]))
second = json.load(open(sys.argv[2]))
second["build"]["invocationId"] = first["build"]["invocationId"]
json.dump(second, open(sys.argv[2], "w"), indent=2, sort_keys=True)
PY
if "$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first-provenance "$temp_dir/provenance-a.json" \
  --first-xcframework "$temp_dir/build-a" \
  --second-provenance "$temp_dir/provenance-same-invocation.json" \
  --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
  fail "reproducibility accepted the same build invocation twice"
fi

# Copying one provenance record and editing only its UUID is not evidence of a
# second build. Missing or equal timestamps are rejected before a proof exists.
python3 - "$temp_dir/provenance-a.json" "$temp_dir/provenance-b.json" "$temp_dir" <<'PY'
import copy
import json
import sys
from pathlib import Path

first = json.load(open(sys.argv[1]))
second = json.load(open(sys.argv[2]))
output = Path(sys.argv[3])

uuid_only = copy.deepcopy(first)
uuid_only["build"]["invocationId"] = "00000000-0000-0000-0000-000000000091"

missing_timestamp = copy.deepcopy(second)
del missing_timestamp["build"]["builtAt"]

equal_timestamp = copy.deepcopy(second)
equal_timestamp["build"]["builtAt"] = first["build"]["builtAt"]

noncanonical_timestamp = copy.deepcopy(second)
noncanonical_timestamp["build"]["builtAt"] = "2099-1-1T1:1:1Z"

coerced_build_input = copy.deepcopy(second)
coerced_build_input["build"]["assertionsEnabled"] = 0

coerced_both_first = copy.deepcopy(first)
coerced_both_first["build"]["assertionsEnabled"] = 0
coerced_both_second = copy.deepcopy(second)
coerced_both_second["build"]["assertionsEnabled"] = 0

schema_float_first = copy.deepcopy(first)
schema_float_first["schemaVersion"] = 4.0
schema_float_second = copy.deepcopy(second)
schema_float_second["schemaVersion"] = 4.0

cross_swiftvlc_revision = copy.deepcopy(second)
cross_swiftvlc_revision["swiftVLCRevision"] = "3" * 40

coerced_member_count = copy.deepcopy(second)
coerced_member_count["slices"][0]["memberCount"] = True

metadata_mismatch = copy.deepcopy(second)
metadata_mismatch["slices"][0]["architectures"] = ["x86_64"]

tampered_first = copy.deepcopy(first)
tampered_first["unboundAfterComparison"] = "tampered"

for name, value in (
    ("uuid-only", uuid_only),
    ("missing-timestamp", missing_timestamp),
    ("equal-timestamp", equal_timestamp),
    ("noncanonical-timestamp", noncanonical_timestamp),
    ("coerced-build-input", coerced_build_input),
    ("coerced-both-a", coerced_both_first),
    ("coerced-both-b", coerced_both_second),
    ("schema-float-a", schema_float_first),
    ("schema-float-b", schema_float_second),
    ("cross-swiftvlc-revision", cross_swiftvlc_revision),
    ("coerced-member-count", coerced_member_count),
    ("metadata-mismatch", metadata_mismatch),
    ("tampered-a", tampered_first),
):
    (output / f"provenance-{name}.json").write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n"
    )

raw = Path(sys.argv[2]).read_text()
(output / "provenance-duplicate-key.json").write_text(
    raw.replace(
        f'"schemaVersion": {second["schemaVersion"]},',
        f'"schemaVersion": {second["schemaVersion"]},\n'
        f'  "schemaVersion": {second["schemaVersion"]},',
        1,
    )
)
(output / "provenance-non-finite.json").write_text(
    raw.replace(
        f'"sourceDateEpoch": {second["build"]["sourceDateEpoch"]}',
        '"sourceDateEpoch": Infinity',
        1,
    )
)
PY

for forged_provenance in \
  uuid-only \
  missing-timestamp \
  equal-timestamp \
  noncanonical-timestamp \
  coerced-build-input \
  cross-swiftvlc-revision \
  duplicate-key \
  non-finite; do
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-a.json" \
    --first-xcframework "$temp_dir/build-a" \
    --second-provenance "$temp_dir/provenance-$forged_provenance.json" \
    --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
    fail "reproducibility accepted forged provenance: $forged_provenance"
  fi
done

for malformed_pair in coerced-both schema-float; do
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-$malformed_pair-a.json" \
    --first-xcframework "$temp_dir/build-a" \
    --second-provenance "$temp_dir/provenance-$malformed_pair-b.json" \
    --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
    fail "reproducibility accepted identically malformed A/B records: $malformed_pair"
  fi
done

# Provenance must match both byte content and the XCFramework's declared slice
# identity. JSON booleans must not compare equal to integer archive counts.
for mismatched_provenance in coerced-member-count metadata-mismatch; do
  if "$SCRIPT_DIR/libvlc-provenance.py" verify \
    --provenance "$temp_dir/provenance-$mismatched_provenance.json" \
    --xcframework "$temp_dir/build-b" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --pinned-revision 111111111 \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    >/dev/null 2>&1; then
    fail "artifact verification accepted mismatched provenance: $mismatched_provenance"
  fi
done

if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --first-provenance "$temp_dir/provenance-tampered-a.json" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --current-provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
  fail "reproducibility proof accepted tampered retained provenance"
fi

for mismatched_build in a b; do
  cp -R "$temp_dir/build-$mismatched_build" \
    "$temp_dir/build-$mismatched_build-artifact-mismatch"
  printf 'mismatched header\n' > \
    "$temp_dir/build-$mismatched_build-artifact-mismatch/macos-arm64/Headers/libvlc.h"
  first_xcframework="$temp_dir/build-a"
  second_xcframework="$temp_dir/build-b"
  if [[ "$mismatched_build" == a ]]; then
    first_xcframework="$temp_dir/build-a-artifact-mismatch"
  else
    second_xcframework="$temp_dir/build-b-artifact-mismatch"
  fi
  if "$SCRIPT_DIR/libvlc-provenance.py" compare \
    --first-provenance "$temp_dir/provenance-a.json" \
    --first-xcframework "$first_xcframework" \
    --second-provenance "$temp_dir/provenance-b.json" \
    --second-xcframework "$second_xcframework" >/dev/null 2>&1; then
    fail "reproducibility comparison accepted an artifact/provenance mismatch: build $mismatched_build"
  fi
done

# Info.plist paths are untrusted artifact metadata. A path outside its slice and
# duplicate slice identifiers must fail even when a forged tree digest would
# otherwise make the record self-consistent.
cp -R "$temp_dir/build-b" "$temp_dir/build-b-escaping-path"
cp -R "$temp_dir/build-b/macos-arm64/Headers" "$temp_dir/outside-headers"
cp -R "$temp_dir/build-b" "$temp_dir/build-b-duplicate-identifier"
python3 - \
  "$temp_dir/build-b-escaping-path/Info.plist" \
  "$temp_dir/build-b-duplicate-identifier/Info.plist" <<'PY'
import copy
import plistlib
import sys

escaping_path, duplicate_path = sys.argv[1:]
with open(escaping_path, "rb") as source:
    escaping = plistlib.load(source)
escaping["AvailableLibraries"][0]["HeadersPath"] = "../../outside-headers"
with open(escaping_path, "wb") as output:
    plistlib.dump(escaping, output, sort_keys=True)

with open(duplicate_path, "rb") as source:
    duplicate = plistlib.load(source)
duplicate["AvailableLibraries"].append(
    copy.deepcopy(duplicate["AvailableLibraries"][0])
)
with open(duplicate_path, "wb") as output:
    plistlib.dump(duplicate, output, sort_keys=True)
PY

for malformed_artifact in escaping-path duplicate-identifier; do
  cp "$temp_dir/provenance-b.json" \
    "$temp_dir/provenance-$malformed_artifact.json"
  malformed_digest=$("$SCRIPT_DIR/artifact-tree-digest.py" \
    "$temp_dir/build-b-$malformed_artifact")
  python3 - \
    "$temp_dir/provenance-$malformed_artifact.json" \
    "$malformed_digest" <<'PY'
import json
import sys

path, digest = sys.argv[1:]
value = json.load(open(path))
value["xcframeworkTreeDigest"] = digest
with open(path, "w") as output:
    json.dump(value, output, indent=2, sort_keys=True)
    output.write("\n")
PY
  if "$SCRIPT_DIR/libvlc-provenance.py" verify \
    --provenance "$temp_dir/provenance-$malformed_artifact.json" \
    --xcframework "$temp_dir/build-b-$malformed_artifact" \
    --swiftvlc-revision "$fixture_swiftvlc_revision" \
    --pinned-revision 111111111 \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
    >/dev/null 2>&1; then
    fail "artifact verification accepted malformed Info.plist: $malformed_artifact"
  fi
done

# An incremental build cannot participate even when its output is identical.
cp "$temp_dir/provenance-b.json" "$temp_dir/provenance-incremental.json"
python3 - "$temp_dir/provenance-incremental.json" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path))
value["build"]["cleanBuild"] = False
value["build"]["invocationId"] = "00000000-0000-0000-0000-000000000003"
json.dump(value, open(path, "w"), indent=2, sort_keys=True)
PY
if "$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first-provenance "$temp_dir/provenance-a.json" \
  --first-xcframework "$temp_dir/build-a" \
  --second-provenance "$temp_dir/provenance-incremental.json" \
  --second-xcframework "$temp_dir/build-b" >/dev/null 2>&1; then
  fail "reproducibility accepted an incremental build"
fi

# There is no generic rebind escape hatch for a post-proof mutation.
if "$SCRIPT_DIR/libvlc-provenance.py" rebind >/dev/null 2>&1; then
  fail "removed provenance rebind command is still accepted"
fi
cp -R "$temp_dir/build-b" "$temp_dir/mutated-build"
printf 'int swiftvlc_provenance_fixture(void) { return 2; }\n' > "$temp_dir/member.c"
xcrun clang -c "$temp_dir/member.c" -o "$temp_dir/member.o"
ar rcs "$temp_dir/mutated-build/macos-arm64/libvlc.a" "$temp_dir/member.o"
"$SCRIPT_DIR/libvlc-provenance.py" create \
  --xcframework "$temp_dir/mutated-build" \
  --output "$temp_dir/mutated-provenance.json" \
  --swiftvlc-revision "$fixture_swiftvlc_revision" \
  --vlc-source "$temp_dir/fake-vlc" \
  --source-revision 1111111111111111111111111111111111111111 \
  --pinned-revision 111111111 \
  --source-date-epoch "$fixture_source_date_epoch" \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-configuration-file "0037-validator=$temp_dir/validator-config.sh" \
  --build-invocation-id 00000000-0000-0000-0000-000000000004 \
  --clean-build \
  --make-flags=-j1 \
  --deployment-target macos=15.0
if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --first-provenance "$temp_dir/provenance-a.json" \
  --second-provenance "$temp_dir/provenance-b.json" \
  --current-provenance "$temp_dir/mutated-provenance.json" \
  --xcframework "$temp_dir/mutated-build" >/dev/null 2>&1; then
  fail "reproducibility proof accepted a mutated post-build tree"
fi

# The artifact binds the post-pin wrapper; the wrapper must in turn reject a
# drifted nested probe before any compiler/tool lookup can make the result
# environment-dependent.
post_pin_fixture="$temp_dir/post-pin-hash-fixture"
mkdir -p \
  "$post_pin_fixture/scripts/patches" \
  "$post_pin_fixture/vlc/modules/demux/json" \
  "$post_pin_fixture/vlc/modules/stream_out/chromecast" \
  "$post_pin_fixture/vlc/modules/services_discovery" \
  "$post_pin_fixture/vlc/src/text" \
  "$post_pin_fixture/vlc/compat" \
  "$post_pin_fixture/work"
cp "$SCRIPT_DIR/validate-post-pin-stability.sh" "$post_pin_fixture/scripts/"
cp -R "$SCRIPT_DIR/patches/validation" "$post_pin_fixture/scripts/patches/"
for fixture_input in \
  modules/demux/json/json.c \
  modules/demux/json/json.h \
  modules/demux/json/grammar.y \
  modules/demux/json/lexicon.l \
  modules/stream_out/chromecast/chromecast_protocol.hpp \
  modules/stream_out/chromecast/chromecast_demux_duration.hpp \
  modules/services_discovery/upnp-wrapper.cpp \
  modules/services_discovery/upnp-wrapper.hpp \
  src/text/url.c \
  src/text/memstream.c \
  compat/memrchr.c; do
  : > "$post_pin_fixture/vlc/$fixture_input"
done
printf '\n// release-integrity nested hash drift\n' >> \
  "$post_pin_fixture/scripts/patches/validation/post-pin-stability-probe.cpp"
if "$post_pin_fixture/scripts/validate-post-pin-stability.sh" \
  "$post_pin_fixture/vlc" "$post_pin_fixture/work" \
  >"$post_pin_fixture/hash-drift.log" 2>&1; then
  fail "post-pin wrapper accepted a drifted nested native probe"
fi
grep -Fq "linked JSON/Cast probe hash changed" \
  "$post_pin_fixture/hash-drift.log" || \
  fail "post-pin wrapper did not diagnose nested native-probe hash drift"

python3 - \
  "$SCRIPT_DIR/build-libvlc.sh" \
  "$SCRIPT_DIR/release.sh" \
  "$SCRIPT_DIR/patches/manifest.sha256" \
  "$SCRIPT_DIR/validate-chromecast-load-transition.sh" \
  "$SCRIPT_DIR/patches/validation/chromecast-load-transition-source-check.py" \
  "$SCRIPT_DIR/validate-post-pin-stability.sh" \
  "$SCRIPT_DIR/native-validator-assets.sha256" \
  "$SCRIPT_DIR/verify-native-validator-assets.py" \
  "$SCRIPT_DIR/validate-audio-media-services-reset.sh" \
  "$SCRIPT_DIR/libvlc-provenance.py" <<'PY'
import ast
import re
import sys

build = open(sys.argv[1]).read()
release = open(sys.argv[2]).read()
load_transition_validator = open(sys.argv[4]).read()
load_transition_checker = open(sys.argv[5]).read()
post_pin_validator = open(sys.argv[6]).read()
validator_asset_manifest = [
    line.rstrip("\n").split("  ", 1)
    for line in open(sys.argv[7])
]
validator_asset_verifier = open(sys.argv[8]).read()
audio_reset_validator = open(sys.argv[9]).read()
provenance_tool = open(sys.argv[10]).read()
manifest_lines = [
    line.strip() for line in open(sys.argv[3]) if line.strip() and not line.lstrip().startswith("#")
]
expected_manifest_tail = [
    "dd3c672da9b7a6fcd82e6eadd298d1c5f86ce75e55d86800de8fd83683461105  0037-chromecast-load-transition-correctness.patch",
    "5f1a58d162c798b2d6f5c2a2fdac9f728279f195ef192405b80272bc2f164c59  0038-apple-assembly-metadata.patch",
    "f78050944caf0c291cac76e28cc4238b3e407d104446e2876c6e0213923d3581  0039-aom-3.13.2-nasm-detection.patch",
    "a4945772122ce3d02f9a5c0c7136fa5dae940f251081238260b760b86c834681  0040-headless-vout-teardown-deadlock.patch",
]
if manifest_lines[-4:] != expected_manifest_tail:
    sys.exit(
        "patch manifest must end with frozen 0037/0038/0039 followed by "
        "headless teardown 0040: "
        f"got {manifest_lines[-4:]}"
    )

required_validator_assets = (
    "scripts/patches/validation/aom-nasm3-detection-probe.cmake",
    "scripts/patches/validation/aom-nasm3-detection-source-check.py",
    "scripts/patches/validation/audio-media-services-reset-source-check.py",
    "scripts/patches/validation/effective-playback-rate-event-abi.c",
    "scripts/patches/validation/effective-playback-rate-event-abi.cpp",
    "scripts/patches/validation/effective-playback-rate-event-probe.c",
    "scripts/patches/validation/effective-playback-rate-event-source-check.py",
    "scripts/patches/validation/headless-vout-teardown-probe.c",
    "scripts/patches/validation/headless-vout-teardown-source-check.py",
    "scripts/patches/validation/native-extension-version-probe.c",
    "scripts/patches/validation/pip-playback-snapshot-probe.c",
    "scripts/patches/validation/pip_extension_version.py",
    "scripts/patches/validation/strict-frame-step-probe.c",
    "scripts/patches/validation/strict-frame-step-source-check.py",
    "scripts/patches/validation/test_pip_extension_version.py",
    "scripts/patches/validation/vmem-configuration-race.c",
    "scripts/patches/validation/vmem-picture-pts-abi.cpp",
    "scripts/patches/validation/vmem-picture-pts-probe.c",
    "scripts/patches/validation/vmem-picture-pts-source-check.py",
    "scripts/tests/test_pip_extension_version.py",
    "scripts/validate-aom-nasm3-detection.sh",
    "scripts/validate-audio-media-services-reset.sh",
    "scripts/validate-effective-playback-rate-event.sh",
    "scripts/validate-headless-vout-teardown.sh",
    "scripts/validate-native-extension-contract.sh",
    "scripts/validate-native-patch-series-source.sh",
    "scripts/validate-pip-playback-snapshot.sh",
    "scripts/validate-strict-frame-step.sh",
    "scripts/validate-vmem-picture-pts.sh",
)
required_executable_validator_assets = (
    "scripts/patches/validation/effective-playback-rate-event-source-check.py",
    "scripts/patches/validation/vmem-picture-pts-source-check.py",
    "scripts/validate-aom-nasm3-detection.sh",
    "scripts/validate-audio-media-services-reset.sh",
    "scripts/validate-effective-playback-rate-event.sh",
    "scripts/validate-headless-vout-teardown.sh",
    "scripts/validate-native-extension-contract.sh",
    "scripts/validate-native-patch-series-source.sh",
    "scripts/validate-pip-playback-snapshot.sh",
    "scripts/validate-strict-frame-step.sh",
    "scripts/validate-vmem-picture-pts.sh",
)
manifest_asset_paths = tuple(path for _, path in validator_asset_manifest)
if manifest_asset_paths != required_validator_assets:
    sys.exit(
        "native validator asset manifest inventory drifted: "
        f"{manifest_asset_paths}"
    )
if len(set(manifest_asset_paths)) != len(manifest_asset_paths):
    sys.exit("native validator asset manifest contains a duplicate path")

verifier_tree = ast.parse(validator_asset_verifier)
verifier_asset_paths = None
verifier_executable_asset_paths = None
for statement in verifier_tree.body:
    if isinstance(statement, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "ASSET_PATHS"
        for target in statement.targets
    ):
        verifier_asset_paths = ast.literal_eval(statement.value)
    if isinstance(statement, ast.Assign) and any(
        isinstance(target, ast.Name) and target.id == "EXECUTABLE_ASSET_PATHS"
        for target in statement.targets
    ):
        verifier_executable_asset_paths = ast.literal_eval(statement.value)
if verifier_asset_paths != required_validator_assets:
    sys.exit(
        "native validator verifier inventory drifted: "
        f"{verifier_asset_paths}"
    )
if verifier_executable_asset_paths != required_executable_validator_assets:
    sys.exit(
        "native validator executable-mode inventory drifted: "
        f"{verifier_executable_asset_paths}"
    )

assembly_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0038-apple-assembly-metadata.patch" ]; then'
)
aom_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0039-aom-3.13.2-nasm-detection.patch" ]; then'
)
headless_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0040-headless-vout-teardown-deadlock.patch" ]; then'
)
warning_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0035-chromecast-metadata-warning.patch" ]; then'
)
schema_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0036-chromecast-metadata-schema-correctness.patch" ]; then'
)
load_transition_manifest_detection = build.index(
    'if [ "$manifest_entry" = "0037-chromecast-load-transition-correctness.patch" ]; then'
)
clean_build_gate = build.index('error "Patch 0038 requires --clean-build;')
aom_clean_build_gate = build.index('error "Patch 0039 requires --clean-build;')
patch_replay = build.index('if [ "$patch_series_matches" = yes ]; then')
assembly_source_gate = build.index(
    'info "Validating Apple assembly tool and Mach-O metadata source contract..."'
)
aom_source_gate = build.index(
    'info "Validating libaom 3.13.2 and NASM 3 detection source contract..."'
)
headless_source_gate = build.index(
    'info "Validating headless video-output teardown source contract..."'
)
first_other_post_replay_gate = build.index(
    '# Patches 0035–0037 deliberately change no public API'
)
dynamic_source_edit = build.index('\npatch_vlc_snapshot_filter_owner\n')
if not (
    warning_manifest_detection
    < schema_manifest_detection
    < load_transition_manifest_detection
    < assembly_manifest_detection
    < aom_manifest_detection
    < headless_manifest_detection
    < clean_build_gate
    < aom_clean_build_gate
    < patch_replay
    < assembly_source_gate
    < aom_source_gate
    < headless_source_gate
    < first_other_post_replay_gate
    < dynamic_source_edit
):
    sys.exit(
        "0038 clean-build/source validation is not ordered before dynamic source edits"
    )
if (
    'if [ "$apple_assembly_metadata_patch_listed" = yes ] &&\n'
    '       [ "$CLEAN_BUILD" != yes ]; then'
    not in build
):
    sys.exit("0038 is not guarded by an exact clean-build requirement")
if (
    '"${SCRIPT_DIR}/validate-apple-assembly-metadata-patch.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0038-apple-assembly-metadata"'
    not in build
):
    sys.exit("build does not invoke the standalone 0038 validator exactly")
if (
    'if [ "$aom_nasm3_detection_patch_listed" = yes ] &&\n'
    '       [ "$CLEAN_BUILD" != yes ]; then'
    not in build
):
    sys.exit("0039 is not guarded by an exact clean-build requirement")
if (
    '"${SCRIPT_DIR}/validate-aom-nasm3-detection.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0039-aom-nasm3-detection"'
    not in build
):
    sys.exit("build does not invoke the standalone 0039 validator exactly")
if (
    '"${SCRIPT_DIR}/validate-headless-vout-teardown.sh" \\\n'
    '            --source-root "${VLC_SRC}" \\\n'
    '            --work-root "${BUILD_DIR}/validation/0040-headless-vout-teardown"'
    not in build
):
    sys.exit("build does not invoke the standalone 0040 source validator exactly")

for assignment in (
    "chromecast_metadata_warning_patch_listed=no",
    "chromecast_metadata_schema_patch_listed=no",
    "chromecast_load_transition_patch_listed=no",
    "apple_assembly_metadata_patch_listed=no",
    "aom_nasm3_detection_patch_listed=no",
    "headless_vout_teardown_patch_listed=no",
    "chromecast_metadata_warning_patch_listed=yes",
    "chromecast_metadata_schema_patch_listed=yes",
    "chromecast_load_transition_patch_listed=yes",
    "apple_assembly_metadata_patch_listed=yes",
    "aom_nasm3_detection_patch_listed=yes",
    "headless_vout_teardown_patch_listed=yes",
):
    if build.count(assignment) != 1:
        sys.exit(f"native patch selector is not initialized exactly once: {assignment}")
load_transition_selection = build.index(
    'if [ "$chromecast_load_transition_patch_listed" = yes ]; then',
    assembly_source_gate,
)
schema_fallback = build.index(
    'elif [ "$chromecast_metadata_schema_patch_listed" = yes ]; then',
    load_transition_selection,
)
warning_fallback = build.index(
    'elif [ "$chromecast_metadata_warning_patch_listed" = yes ]; then',
    schema_fallback,
)
if not (
    assembly_source_gate
    < load_transition_selection
    < schema_fallback
    < warning_fallback
    < dynamic_source_edit
):
    sys.exit("Chromecast validators are not selected newest-first before source edits")
if build.count('"${SCRIPT_DIR}/validate-chromecast-load-transition.sh"') != 1:
    sys.exit("build must invoke the 0037 final-source validator exactly once")
if build.count('"${SCRIPT_DIR}/validate-chromecast-metadata-schema.sh"') != 1:
    sys.exit("build must retain exactly one 0036-only fallback validator")
if (
    '"${SCRIPT_DIR}/validate-chromecast-metadata-schema.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0036-chromecast-metadata-schema"'
    not in build
):
    sys.exit("0036 fallback does not keep generated validation work external")
if (
    '"${SCRIPT_DIR}/validate-chromecast-load-transition.sh" \\\n'
    '            "${VLC_SRC}" "${BUILD_DIR}/validation/0037-chromecast-load-transition"'
    not in build
):
    sys.exit("build does not invoke the 0037 validator with an external build work root")
if (
    'if [ "$chromecast_load_transition_patch_listed" != yes ] &&\n'
    '       [ -f "${VLC_SRC}/modules/stream_out/chromecast/chromecast_demux_eof.hpp" ]; then'
    not in build
):
    sys.exit("build does not suppress the redundant frozen 0034 gate under 0037")
if build.count('"${SCRIPT_DIR}/validate-chromecast-state.sh"') != 1:
    sys.exit("build must retain exactly one direct 0034 fallback gate")
if build.count('"${SCRIPT_DIR}/validate-post-pin-stability.sh"') != 1:
    sys.exit("build must retain the complete post-pin linked/native gate exactly once")
tools_build = build.index('info "Building VLC build tools..."')
post_pin_call = build.index(
    '"${SCRIPT_DIR}/validate-post-pin-stability.sh" \\\n'
    '        "${VLC_SRC}" "${BUILD_DIR}/validation"'
)
if post_pin_call < tools_build:
    sys.exit("post-pin linked/native validation runs before its generated tools exist")

checker_call = load_transition_validator.index(
    'PYTHONDONTWRITEBYTECODE=1 python3 "$CHECKER" "$VLC_SOURCE_ROOT" "$PATCH"'
)
base_probe_call = load_transition_validator.index(
    'compile_and_run "$BASE_PROBE"'
)
schema_probe_call = load_transition_validator.index(
    'compile_and_run "$SCHEMA_PROBE"'
)
load_transition_probe_call = load_transition_validator.index(
    'compile_and_run "$PROBE"'
)
if not checker_call < base_probe_call < schema_probe_call < load_transition_probe_call:
    sys.exit("0037 standalone validation does not run its checker and inherited probes in order")
for marker in (
    'check_hash "$SCHEMA_CHECKER" "$EXPECTED_SCHEMA_CHECKER_SHA"',
    'check_hash "$SCHEMA_PROBE" "$EXPECTED_SCHEMA_PROBE_SHA"',
    'check_hash "$SCHEMA_PATCH" "$EXPECTED_SCHEMA_PATCH_SHA"',
    'check_hash "$WARNING_CHECKER" "$EXPECTED_WARNING_CHECKER_SHA"',
    'check_hash "$WARNING_PATCH" "$EXPECTED_WARNING_PATCH_SHA"',
    'check_hash "$BASE_CHECKER" "$EXPECTED_BASE_CHECKER_SHA"',
    'check_hash "$BASE_PROBE" "$EXPECTED_BASE_PROBE_SHA"',
    'check_hash "$COMPAT" "$EXPECTED_COMPAT_SHA"',
):
    if load_transition_validator.count(marker) != 1:
        sys.exit(f"0037 standalone validator does not hash-bind {marker}")

final_schema_contract = load_transition_checker.index(
    "schema_checker.validate_sources(final_schema_sources)"
)
reverse_to_predecessor = load_transition_checker.index(
    "reconstructed = dict(sources)", final_schema_contract
)
predecessor_schema_contract = load_transition_checker.index(
    "schema_checker.validate_sources(predecessor_schema_sources)",
    reverse_to_predecessor,
)
predecessor_schema_mutations = load_transition_checker.index(
    "schema_checker.run_source_mutations(\n        predecessor_schema_sources",
    predecessor_schema_contract,
)
new_source_mutations = load_transition_checker.index(
    "source_mutations = run_source_mutations(sources)",
    predecessor_schema_mutations,
)
if not (
    final_schema_contract
    < reverse_to_predecessor
    < predecessor_schema_contract
    < predecessor_schema_mutations
    < new_source_mutations
):
    sys.exit("0037 does not separate final 0036 semantics from predecessor mutations")
if load_transition_checker.count("schema_checker.run_source_mutations(") != 1:
    sys.exit("frozen 0036 mutation suite must run exactly once")
if "schema_checker.run_source_mutations(final_schema_sources)" in load_transition_checker:
    sys.exit("frozen 0036 mutations are incorrectly running on 0037 final source")
if "source.count(old) != 1" not in load_transition_checker:
    sys.exit("0037 mutation fixtures are not fail-closed on exact uniqueness")

post_pin_hash_inputs = (
    '"$SOURCE_CHECK"',
    '"$PROBE"',
    '"$ICONV_SUPPORT"',
    '"$COMPAT"',
    '"$UPNP_PROBE"',
    '"$UPNP_FAKES/vlc_common.h"',
    '"$UPNP_FAKES/vlc_threads.h"',
    '"$UPNP_FAKES/vlc_cxx_helpers.hpp"',
    '"$UPNP_FAKES/vlc_charset.h"',
    '"$UPNP_FAKES/upnp.h"',
    '"$UPNP_FAKES/upnptools.h"',
    '"$UPNP_FAKES/TargetConditionals.h"',
)
for bound_input in post_pin_hash_inputs:
    marker = f"verify_sha256 {bound_input}"
    if post_pin_validator.count(marker) != 1:
        sys.exit(f"post-pin wrapper does not hash-bind exactly once: {bound_input}")
for retained_evidence in (
    'python3 "$SOURCE_CHECK" --self-test',
    'python3 "$SOURCE_CHECK" "$VLC_SOURCE_ROOT"',
    '\n"$VALIDATION_DIR/post-pin-stability-probe"\n',
    '\n"$VALIDATION_DIR/upnp-lifecycle-probe"\n',
):
    if post_pin_validator.count(retained_evidence) != 1:
        sys.exit(f"post-pin linked/native evidence was dropped: {retained_evidence}")

artifact_replacement = build.index('rm -rf "${OUTPUT_DIR}/libvlc.xcframework"')
metadata_report_removal = build.index('    "${MACHO_METADATA_REPORT}"')
artifact_creation = build.index('\nxcodebuild -create-xcframework \\\n')
if not metadata_report_removal < artifact_replacement < artifact_creation:
    sys.exit("artifact replacement can retain a stale Mach-O metadata report")

build_metadata_verification = build.index(
    'info "Verifying per-object Mach-O platform metadata and section alignment..."'
)
provenance = build.index('python3 "${SCRIPT_DIR}/libvlc-provenance.py" create')
if provenance < build_metadata_verification:
    sys.exit("provenance is written before per-object Mach-O verification")
startup_evidence_invalidation = (
    'rm -f "${OUTPUT_DIR}/libvlc-provenance-a.json" \\\n'
    '    "${OUTPUT_DIR}/libvlc-provenance.json" \\\n'
    '    "${OUTPUT_DIR}/libvlc-reproducibility.json" \\\n'
    '    "${OUTPUT_DIR}/libvlc-macho-metadata.json"'
)
if build.count(startup_evidence_invalidation) != 1:
    sys.exit(
        "native build startup does not invalidate A/B provenance, proof, and "
        "Mach-O evidence as one exact set"
    )
if build.index(startup_evidence_invalidation) > build.index(
    'info "Setting up VLC source..."'
):
    sys.exit("native build invalidates stale two-build evidence after source setup")

build_validator_asset_verification = build.index(
    'if ! python3 "${SCRIPT_DIR}/verify-native-validator-assets.py"; then'
)
build_source_setup = build.index('info "Setting up VLC source..."')
if build_validator_asset_verification > build_source_setup:
    sys.exit("native validator assets are verified after VLC source setup")

expected_extension_patch_versions = {
    "0004-samplebuffer-pip-safety-geometry.patch": 1,
    "0022-atomic-pip-playback-snapshot.patch": 2,
    "0024-native-pip-overlays.patch": 3,
    "0027-strict-frame-step-contract.patch": 4,
    "0029-sample-buffer-renderer-recovery.patch": 5,
    "0030-vmem-picture-pts.patch": 6,
    "0031-effective-playback-rate-event.patch": 7,
    "0032-audio-media-services-reset.patch": 8,
}
for patch_name, version in expected_extension_patch_versions.items():
    marker = (
        f"{patch_name})\n"
        f"                manifest_extension_candidate={version} ;;"
    )
    if build.count(marker) != 1:
        sys.exit(
            "build does not map the patch manifest to one exact native "
            f"extension version: {patch_name} -> {version}"
        )
lease_marker = (
    "0033-apple-audio-session-policy-leases.patch)\n"
    "                swiftvlc_apple_audio_session_leases_listed=yes ;;"
)
if build.count(lease_marker) != 1:
    sys.exit("build does not track the 0033 same-version lease refinement")
for export_marker in (
    'export SWIFTVLC_EXPECTED_EXTENSION_VERSION="$swiftvlc_manifest_extension_version"',
    'export SWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES="$swiftvlc_apple_audio_session_leases_listed"',
):
    if build.count(export_marker) != 1:
        sys.exit(f"build does not export manifest-owned validator intent: {export_marker}")

native_source_contract_setup = build.index(
    'native_source_contract_args=('
)
native_source_contract = build.index(
    'info "Validating the manifest-owned native extension source and vendored-header contract..."'
)
first_legacy_native_source_gate = build.index(
    '# Exercise the exact production helper whenever this patch is in the engine'
)
if not (
    patch_replay
    < native_source_contract_setup
    < native_source_contract
    < first_legacy_native_source_gate
):
    sys.exit(
        "manifest-owned native extension source validation is not between "
        "exact patch replay and legacy source gates"
    )
native_source_command = build[
    native_source_contract_setup:first_legacy_native_source_gate
]
for marker in (
    '--source-root "$VLC_SRC"',
    '--expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"',
    '--run-mutations',
    'native_source_contract_args+=(--require-apple-audio-session-leases)',
):
    if native_source_command.count(marker) != 1:
        sys.exit(f"native extension source contract is incomplete: {marker}")

audio_source_contract = build.index(
    'info "Validating Apple audio reset/ownership ARC source contract before native compilation..."'
)
dynamic_source_edit = build.index('\npatch_vlc_snapshot_filter_owner\n')
if not native_source_contract < audio_source_contract < dynamic_source_edit:
    sys.exit(
        "Apple audio ARC source validation is not between exact patch replay "
        "and native compilation setup"
    )
audio_source_region = build[audio_source_contract:dynamic_source_edit]
if audio_source_region.count(
    '"${SCRIPT_DIR}/validate-audio-media-services-reset.sh" "${VLC_SRC}"'
) != 1:
    sys.exit("pre-build Apple audio ARC source validation is missing or duplicated")

arc_broker_syntax = (
    '"$CLANG" "${COMMON[@]}" -fobjc-arc \\\n'
    '    "$VLC_SOURCE_ROOT/src/darwin/apple_audio_session.m"'
)
if audio_reset_validator.count(arc_broker_syntax) != 1:
    sys.exit("Apple audio broker syntax proof does not mirror its ARC build mode")

archive_repair = build.index(
    '"${SCRIPT_DIR}/fix-duplicate-symbols.sh" "${OUTPUT_DIR}/libvlc.xcframework"'
)
headless_runtime_selection = build.index(
    'if [ "$headless_vout_teardown_patch_listed" = yes ] && [ "$BUILD_MACOS" = "yes" ]; then'
)
headless_runtime_gate = build.index(
    'info "Validating bounded headless video-output stop and natural-EOF teardown..."'
)
final_archive_mutation = build.index(
    'find "${OUTPUT_DIR}/libvlc.xcframework" -name \'*.a\' -exec xcrun ranlib -D {} \\;'
)
native_archive_contract_setup = build.index(
    'native_archive_contract_args=('
)
native_archive_contract = build.index(
    'info "Validating the exact linked native extension archive contract across every produced slice..."'
)
archive_metadata_gate = build.index(
    'info "Verifying per-object Mach-O platform metadata and section alignment..."'
)
if not (
    archive_repair
    < headless_runtime_selection
    < headless_runtime_gate
    < final_archive_mutation
    < native_archive_contract_setup
    < native_archive_contract
    < archive_metadata_gate
):
    sys.exit(
        "exact linked native extension validation is not after the final "
        "archive mutation and before artifact metadata/provenance gates"
    )
headless_runtime_region = build[headless_runtime_selection:final_archive_mutation]
for marker in (
    'if [ "$headless_vout_teardown_patch_listed" = yes ] && [ "$BUILD_MACOS" = "yes" ]; then',
    '"${SCRIPT_DIR}/validate-headless-vout-teardown.sh" \\\n',
    '        --source-root "${VLC_SRC}" \\\n',
    '        --xcframework "${OUTPUT_DIR}/libvlc.xcframework" \\\n',
    '        --work-root "${BUILD_DIR}/validation/0040-headless-vout-teardown-runtime"',
):
    if headless_runtime_region.count(marker) != 1:
        sys.exit(f"0040 bounded runtime gate is incomplete: {marker}")
native_archive_command = build[
    native_archive_contract_setup:archive_metadata_gate
]
if 'if [ "$BUILD_MACOS" = yes ]; then' in native_archive_command:
    sys.exit("device-only builds bypass the all-slice native extension contract")
if "Exact linked native extension validation skipped" in native_archive_command:
    sys.exit("build retains a device-only native extension validation skip")
for marker in (
    '--xcframework "${OUTPUT_DIR}/libvlc.xcframework"',
    '--expected-version "$SWIFTVLC_EXPECTED_EXTENSION_VERSION"',
    'native_archive_contract_args+=(--require-apple-audio-session-leases)',
):
    if native_archive_command.count(marker) != 1:
        sys.exit(f"native extension archive contract is incomplete: {marker}")

release_validator_asset_verification = release.index(
    'if ! python3 "$SCRIPT_DIR/verify-native-validator-assets.py"; then'
)
release_provenance_verification = release.index(
    'if ! verify_artifact_provenance "$EXPECTED_ARTIFACT_SWIFTVLC_REVISION"; then'
)
if release_validator_asset_verification > release_provenance_verification:
    sys.exit("release verifies native validator assets after artifact provenance")

expected_configurations = {
    "build-libvlc.sh",
    "fix-duplicate-symbols.sh",
    "native-validator-assets.sha256",
    "native-extension-version-probe.c",
    "pip_extension_version.py",
    "validate-libvlc-macho-metadata.py",
    "validate-apple-assembly-metadata-patch.sh",
    "validate-aom-nasm3-detection.sh",
    "validate-headless-vout-teardown.sh",
    "validate-chromecast-load-transition.sh",
    "validate-native-extension-contract.sh",
    "validate-post-pin-stability.sh",
    "verify-native-validator-assets.py",
}
configuration_pattern = re.compile(
    r'--build-configuration-file "([^"=]+)=[^"\n]+"'
)
build_configurations = set(configuration_pattern.findall(build))
release_configurations = set(configuration_pattern.findall(release))
if build_configurations != expected_configurations:
    sys.exit(
        f"build provenance configuration is incomplete: {sorted(build_configurations)}"
    )
if release_configurations != build_configurations:
    sys.exit(
        "build/release provenance configuration sets differ: "
        f"build={sorted(build_configurations)}, release={sorted(release_configurations)}"
    )

for marker in (
    'compare_parser.add_argument("--first-xcframework", type=Path, required=True)',
    'compare_parser.add_argument("--second-xcframework", type=Path, required=True)',
    'verify_recorded_artifact(first, first_xcframework, "first XCFramework")',
    'verify_recorded_artifact(second, second_xcframework, "second XCFramework")',
    'write_json_atomic(arguments.output, proof)',
    'os.replace(temporary_path, path)',
    '"provenanceSha256": first_provenance_sha256',
    '"provenanceSha256": second_provenance_sha256',
):
    if marker not in provenance_tool:
        sys.exit(f"reproducibility implementation is missing: {marker}")

for marker in (
    'libvlc-provenance-a.json',
    '"firstProvenanceChecksum"',
    '--first-provenance "$RELEASE_FIRST_PROVENANCE"',
    '--second-provenance "$RELEASE_PROVENANCE"',
    '--current-provenance "$RELEASE_PROVENANCE"',
    '--xcframework "$WORK_XCFW"',
    '"$RELEASE_FIRST_PROVENANCE"',
):
    if marker not in release:
        sys.exit(f"release does not retain both build records: {marker}")

deployment_constants = {
    "SWIFTVLC_MIN_IOS": "18.0",
    "SWIFTVLC_MIN_TVOS": "18.0",
    "SWIFTVLC_MIN_VISIONOS": "2.0",
    "SWIFTVLC_MIN_MACOS": "15.0",
    "SWIFTVLC_MIN_CATALYST": "18.0",
}
deployment_policies = {
    "ios": "SWIFTVLC_MIN_IOS",
    "tvos": "SWIFTVLC_MIN_TVOS",
    "xros": "SWIFTVLC_MIN_VISIONOS",
    "macos": "SWIFTVLC_MIN_MACOS",
    "catalyst": "SWIFTVLC_MIN_CATALYST",
}
for variable, expected_value in deployment_constants.items():
    assignment = f'{variable}="{expected_value}"'
    if assignment not in build or assignment not in release:
        sys.exit(f"build/release deployment constant drifted: {assignment}")

release_member_manifest = release.index(
    'check-libvlc-manifest.sh" --xcframework "$XCFW_PATH"'
)
release_native_extension_contract = release.index(
    'echo "Verifying exact linked native extension contract..."'
)
release_metadata_report = release.index(
    'MACHO_METADATA_REPORT="$(dirname "$XCFW_PATH")/libvlc-macho-metadata.json"'
)
release_metadata_report_removal = release.index(
    'rm -f "$MACHO_METADATA_REPORT"', release_metadata_report
)
release_metadata_verification = release.index(
    'echo "Verifying release artifact Mach-O platform metadata and section alignment..."'
)
release_provenance = release.index(
    'if ! verify_artifact_provenance "$EXPECTED_ARTIFACT_SWIFTVLC_REVISION"; then'
)
if not (
    release_member_manifest
    < release_native_extension_contract
    < release_metadata_report
    < release_metadata_report_removal
    < release_metadata_verification
    < release_provenance
):
    sys.exit("release Mach-O validation is not ordered before provenance/package work")
release_native_extension_command = release[
    release_native_extension_contract:release_metadata_report
]
for marker in (
    '"$SCRIPT_DIR/validate-native-extension-contract.sh"',
    '--xcframework "$XCFW_PATH"',
    '--expected-version 8',
    '--require-apple-audio-session-leases',
):
    if release_native_extension_command.count(marker) != 1:
        sys.exit(f"release native extension contract is incomplete: {marker}")
if release.count('"$SCRIPT_DIR/validate-libvlc-macho-metadata.py"') != 1:
    sys.exit("release must directly invoke the Mach-O parser exactly once")
build_metadata_command = build[
    build_metadata_verification : build.index(
        'info "Verified every Mach-O object;', build_metadata_verification
    )
]
release_metadata_command = release[
    release_metadata_verification : release.index(
        '# Refuse to publish a debug-configured libVLC',
        release_metadata_verification,
    )
]
if build_metadata_command.count("--deployment-target ") != 5:
    sys.exit("build Mach-O parser invocation does not have exactly five policies")
if release_metadata_command.count("--deployment-target ") != 5:
    sys.exit("release Mach-O parser invocation does not have exactly five policies")
if release_metadata_command.count('--json-output "$MACHO_METADATA_REPORT"') != 1:
    sys.exit("release Mach-O parser does not refresh the invalidated metadata report")
for platform_name, variable in deployment_policies.items():
    marker = f'--deployment-target "{platform_name}=${{{variable}}}"'
    if marker not in build_metadata_command or marker not in release_metadata_command:
        sys.exit(f"build/release Mach-O policy is missing: {marker}")

if "libvlc-provenance.py\" rebind" in release or "find \"$WORK_XCFW\" -name '*.a'" in release:
    sys.exit("release packaging still mutates or rebinds the proven artifact")
if (
    'cp -R "$XCFW_PATH" "$WORK_XCFW"' in release
    or "ditto -c -k --keepParent libvlc.xcframework" in release
):
    sys.exit("release packaging bypasses canonical libVLC staging/archive")
for marker in (
    '"releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1"',
    '"releaseSourceDigest": os.environ["RELEASE_SOURCE_DIGEST"]',
    '"qualificationMatrixChecksum": os.environ["QUALIFICATION_MATRIX_CHECKSUM"]',
    '"featureManifestChecksum": os.environ["FEATURE_MANIFEST_CHECKSUM"]',
    'SWIFTVLC_CANDIDATE_SOURCE_DIGEST="$CANDIDATE_SOURCE_DIGEST"',
    'SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM="$CANDIDATE_FEATURE_MANIFEST_CHECKSUM"',
    'SWIFTVLC_FEATURE_MANIFEST="$FEATURE_MANIFEST"',
    'check-libvlc-manifest.sh" --xcframework "$XCFW_PATH"',
    'canonical-libvlc-artifact.sh" stage',
    'canonical-libvlc-artifact.sh" archive',
    'elif [[ "$DRY_RUN" == true ]]; then',
):
    if marker not in release:
        sys.exit(f"release candidate is not bound to qualification input: {marker}")
PY

source_repo="$temp_dir/release-source-repo"
mkdir -p "$source_repo/Sources" \
  "$source_repo/scripts/qualification/evidence/1.1.0" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj"
git -C "$source_repo" init -q
git -C "$source_repo" config user.name "SwiftVLC Test"
git -C "$source_repo" config user.email "swiftvlc-test@example.invalid"
printf 'public let value = 1\n' > "$source_repo/Sources/Value.swift"
printf '{"scenarios":[],"hardware":[]}\n' > \
  "$source_repo/scripts/qualification/matrix.json"
cp "$ROOT_DIR/Package.swift" "$source_repo/Package.swift"
cp "$ROOT_DIR/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm "source"
source_digest_a=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")

cp "$source_repo/Package.swift" "$temp_dir/source-Package.swift"
cp "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
  "$temp_dir/source-project.pbxproj"
python3 - "$source_repo/Package.swift" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" <<'PY'
import re
import sys

package_path, project_path = sys.argv[1:]
package = open(package_path).read()
package = re.sub(
    r"v1\.1\.0-beta\.5/libvlc\.xcframework\.zip",
    "v1.1.0/libvlc.xcframework.zip",
    package,
)
package = re.sub(r'checksum: "[0-9a-f]{64}"', 'checksum: "' + "0" * 64 + '"', package)
open(package_path, "w").write(package)
project = open(project_path).read().replace(
    "version = 1.1.0-beta.5;", "version = 1.1.0;"
)
open(project_path, "w").write(project)
PY
source_digest_rewritten=$(
  "$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo"
)
if [[ "$source_digest_a" != "$source_digest_rewritten" ]]; then
  fail "deterministic release reference rewrites changed the source digest"
fi
cp "$temp_dir/source-Package.swift" "$source_repo/Package.swift"
cp "$temp_dir/source-project.pbxproj" \
  "$source_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"

printf 'public let untracked = true\n' > "$source_repo/Sources/Untracked.swift"
if "$SCRIPT_DIR/release-source-digest.py" 1.1.0 \
  --root "$source_repo" >/dev/null 2>&1; then
  fail "untracked Swift source did not invalidate the release-source digest"
fi
rm "$source_repo/Sources/Untracked.swift"

printf '{"version":"1.1.0"}\n' > \
  "$source_repo/scripts/qualification/1.1.0.json"
printf '{"result":"pass"}\n' > \
  "$source_repo/scripts/qualification/evidence/1.1.0/result.json"
git -C "$source_repo" add .
git -C "$source_repo" commit -qm "evidence"
source_digest_b=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")
if [[ "$source_digest_a" != "$source_digest_b" ]]; then
  fail "qualification records changed the release-source digest"
fi

printf 'public let value = 2\n' > "$source_repo/Sources/Value.swift"
source_digest_dirty=$(
  "$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo"
)
if [[ "$source_digest_b" == "$source_digest_dirty" ]]; then
  fail "an uncommitted Swift source change did not change the source digest"
fi
git -C "$source_repo" add Sources/Value.swift
git -C "$source_repo" commit -qm "source change"
source_digest_c=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")
if [[ "$source_digest_dirty" != "$source_digest_c" ]]; then
  fail "committing unchanged worktree source changed the release-source digest"
fi

printf '{"scenarios":[{"id":"new"}],"hardware":[]}\n' > \
  "$source_repo/scripts/qualification/matrix.json"
git -C "$source_repo" add scripts/qualification/matrix.json
git -C "$source_repo" commit -qm "matrix change"
source_digest_d=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0 --root "$source_repo")
if [[ "$source_digest_c" == "$source_digest_d" ]]; then
  fail "a qualification matrix change did not change the release-source digest"
fi

python3 - "$temp_dir/matrix.json" "$temp_dir/record.json" \
  "$temp_dir/feature-manifest.json" "$digest_a" \
  "$SCRIPT_DIR/qualification" <<'PY'
import json
import sys

(
    matrix_path,
    record_path,
    feature_manifest_path,
    digest,
    qualification_directory,
) = sys.argv[1:6]
sys.path.insert(0, qualification_directory)
import qualification_policy as policy

matrix = {
    "scenarios": [
        {
            "id": "vod",
            "summary": "Fixture VOD playback",
            "hardware": ["iphone-current"],
            "minimumDurationSeconds": 60,
            "requiredEvidenceFields": ["metrics.cpu", "outcome", "retryCount"],
            "expectedEvidenceValues": {
                "metrics.errors": 0,
                "rates": [1, 2],
            },
            "allowedEvidenceValues": {
                "outcome": ["stable", "recovered"],
                "retryCount": [0, 1],
            },
        }
    ],
    "hardware": [
        {
            "id": "iphone-current",
            "deviceFamily": "iPhone",
            "osMajor": 26,
            "summary": "Fixture iPhone",
        },
        {
            "id": "ipad-current",
            "deviceFamily": "iPad",
            "osMajor": 26,
            "summary": "Fixture iPad",
        },
    ],
    "runnerContracts": [
        {
            "id": runner,
            "selection": {
                "kind": "exact",
                "testIdentifiers": [
                    "iOSUITests/FixtureTests/test_releaseIntegrity"
                ],
            },
            "outputs": [],
        }
        for runner in sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS)
    ]
    + [
        {
            "id": "vod",
            "selection": {
                "kind": "exact",
                "testIdentifiers": [
                    "iOSUITests/FixtureTests/test_releaseIntegrity"
                ],
            },
            "outputs": [
                {
                    "scenario": "vod",
                    "attachmentName": "qualification-vod.json",
                    "testIdentifiers": [
                        "iOSUITests/FixtureTests/test_releaseIntegrity"
                    ],
                }
            ],
        }
    ],
}
feature_manifest = {
    "formatVersion": 1,
    "id": "release-integrity-features",
    "manifestVersion": "1.0.0",
    "releaseVersionPrefix": "1.1.0",
    "title": "Release integrity feature policy",
    "categories": [{"id": "playback", "title": "Playback"}],
    "features": [
        {
            "id": feature_id,
            "category": "playback",
            "title": feature_id.replace("-", " ").title(),
            "description": "The release-integrity fixture maps this canonical obligation to its VOD proof.",
            "releaseRequirement": "required",
            "execution": "automated",
            "evidenceLevel": "engine-output",
            "scenarioIds": ["vod"],
            "runnerScenarioIds": ["vod"],
        }
        for feature_id in sorted(policy.REQUIRED_FEATURE_IDS)
    ],
}
json.dump(matrix, open(matrix_path, "w"))
json.dump(feature_manifest, open(feature_manifest_path, "w"))
PY

export SWIFTVLC_FEATURE_MANIFEST="$temp_dir/feature-manifest.json"

qualification_source_digest=$("$SCRIPT_DIR/release-source-digest.py" 1.1.0)
qualification_source_commit=$(git rev-parse HEAD)
qualification_matrix_checksum=$(shasum -a 256 \
  "$temp_dir/matrix.json" | cut -d' ' -f1)
fixture_feature_checksum=$(shasum -a 256 \
  "$temp_dir/feature-manifest.json" | cut -d' ' -f1)
qualification_profiles_checksum=$(shasum -a 256 \
  "$SCRIPT_DIR/qualification/profiles-v1.json" | cut -d' ' -f1)
python3 - "$temp_dir/record.json" "$temp_dir/evidence.json" \
  "$qualification_source_commit" "$qualification_source_digest" \
  "$qualification_matrix_checksum" "$digest_a" "$fixture_feature_checksum" \
  "$qualification_profiles_checksum" "$SCRIPT_DIR/qualification" "$temp_dir" <<'PY'
import json
import sys
from pathlib import Path

(
    record_path_value,
    evidence_path_value,
    commit,
    source_digest,
    matrix_checksum,
    artifact_digest,
    feature_checksum,
    profiles_checksum,
    qualification_directory,
    temporary_directory,
) = sys.argv[1:]
sys.path.insert(0, qualification_directory)
import qualification_policy as policy

record_path = Path(record_path_value)
evidence_path = Path(evidence_path_value)
root = Path(temporary_directory)
retained_root = root / "retained-report"
retained_root.mkdir()

catalog = ["iOSUITests/FixtureTests/test_releaseIntegrity"]
catalog_record = policy.catalog_record(catalog)
identity = {
    "formatVersion": 2,
    "version": "1.1.0",
    "candidateAppBundleIdentifier": "com.swiftvlc.validation.fixture.app",
    "sourceCommit": commit,
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": source_digest,
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": artifact_digest,
    "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
    "candidateAppDigest": "a" * 64,
    "testRunnerBundleIdentifier": (
        "com.swiftvlc.validation.fixture.uitests.xctrunner"
    ),
    "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
    "testRunnerDigest": "b" * 64,
    "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
    "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
    "testBundleDigest": "c" * 64,
    "baseXCTestRunDigestAlgorithm": "sha256",
    "baseXCTestRunDigest": "d" * 64,
    "baseXCTestRunName": "fixture.xctestrun",
    "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
    "testCatalogDigest": catalog_record["digest"],
    "testCatalogCount": catalog_record["testCount"],
    "testCatalog": catalog_record["testIdentifiers"],
    "qualificationMatrixChecksum": matrix_checksum,
    "featureManifestChecksum": feature_checksum,
    "qualificationProfilesChecksum": profiles_checksum,
    "fixtureManifestChecksum": "f" * 64,
    "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
    "qualificationPolicyDigest": policy.policy_digest(),
}
execution = {
    "expected": catalog_record,
    "executed": catalog_record,
    "identityAndCountMatch": True,
    "allPassed": True,
}

runner_rows = []
runner_data = {}
for runner in sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS | {"vod"}):
    attempt_root = retained_root / f"{runner}-attempt-artifacts"
    attempt_root.mkdir()
    attempt_log = attempt_root / "attempt-1.log"
    attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
    attempt_bundle = attempt_root / "attempt-1.xcresult"
    attempt_bundle.mkdir()
    (attempt_bundle / "Info.plist").write_text("fixture xcresult")
    attempts = policy.bind_attempt_artifacts(
        [
            {
                "attempt": 1,
                "classification": "passed",
                "retryable": False,
                "intendedTestBegan": True,
                "xcodebuildExitCode": 0,
                "logArtifact": attempt_log.relative_to(retained_root).as_posix(),
                "xcresultArtifact": attempt_bundle.relative_to(
                    retained_root
                ).as_posix(),
                "testExecution": execution,
            }
        ],
        retained_root,
    )
    inventory = None
    app_log = "none"
    if runner != "analyzer":
        raw_root = retained_root / f"{runner}-raw-jsonl"
        raw_root.mkdir()
        raw_record = (
            json.dumps(
                {
                    "ts": "2026-08-31T12:00:00Z",
                    "level": "debug",
                    "module": policy.LOG_MIRROR_HEALTH_MODULE,
                    "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
                }
            )
            + "\n"
        )
        raw_name = policy.test_log_filename(
            "run",
            catalog_record["testIdentifiers"][0],
            "00000000-0000-4000-8000-000000000001",
        )
        (raw_root / raw_name).write_text(raw_record)
        declared_children = policy.DECLARED_TEST_CHILD_LOGS.get(runner)
        if declared_children is not None:
            for child in sorted(declared_children):
                raw_name = policy.test_log_filename(
                    "run",
                    catalog_record["testIdentifiers"][0],
                    "00000000-0000-4000-8000-000000000001",
                    child=child,
                )
                (raw_root / raw_name).write_text(raw_record)
        inventory = policy.build_error_inventory(
            raw_root,
            "run",
            runner,
            retained_root=raw_root.name,
            expected_test_catalog=catalog_record,
        )
        app_log = "captured"
    runner_rows.append(
        {
            "scenario": runner,
            "result": "pass",
            "xcodebuildExitCode": 0,
            "libraryErrorCount": 0,
            "appLog": app_log,
            "qualificationEvidence": (
                "captured" if runner == "vod" else "not-applicable"
            ),
            "durationSeconds": 120,
            "expectedTestCatalog": catalog_record,
            "testExecution": execution,
            "attempts": attempts,
            "attemptArtifactRoot": attempt_root.name,
            "hostErrorInventory": inventory,
        }
    )
    runner_data[runner] = {"attempts": attempts, "inventory": inventory}

attachment_root = retained_root / "vod-attachments"
attachment_root.mkdir()
attachment_payload = attachment_root / "vod.json"
raw_evidence = {
    "scenario": "vod",
    "durationSeconds": 120,
    "metrics": {"cpu": 0, "errors": 0},
    "rates": [1.0, 2],
    "outcome": "stable",
    "retryCount": 0,
}
attachment_payload.write_text(json.dumps(raw_evidence, sort_keys=True))
attachment_manifest = attachment_root / "manifest.json"
attachment_manifest.write_text(
    json.dumps(
        [
            {
                "testIdentifier": "iOSUITests/FixtureTests/test_releaseIntegrity",
                "attachments": [
                    {
                        "suggestedHumanReadableName": "qualification-vod.json",
                        "exportedFileName": attachment_payload.name,
                    }
                ]
            }
        ],
        sort_keys=True,
    )
)
vod_attempts = runner_data["vod"]["attempts"]
evidence = {
    **raw_evidence,
    **{field: identity[field] for field in policy.CORE_IDENTITY_FIELDS},
    "hardware": "iphone-current",
    "deviceIdentifier": "fixture-device",
    "testExecution": execution,
    "hostErrorInventory": runner_data["vod"]["inventory"],
    "qualificationProducer": {
        "runnerScenario": "vod",
        "sourceAttempt": 1,
        "sourceXcresultArtifact": vod_attempts[-1]["xcresultArtifact"],
        "sourceXcresultDigestAlgorithm": vod_attempts[-1][
            "xcresultDigestAlgorithm"
        ],
        "sourceXcresultDigest": vod_attempts[-1]["xcresultDigest"],
        "sourceXcresultSizeBytes": vod_attempts[-1]["xcresultSizeBytes"],
        "attachmentName": "qualification-vod.json",
        "attachmentTestIdentifier": "iOSUITests/FixtureTests/test_releaseIntegrity",
        "retainedAttachmentRoot": attachment_root.name,
        "manifestRelativePath": attachment_manifest.relative_to(
            retained_root
        ).as_posix(),
        "manifestDigestAlgorithm": "sha256",
        "manifestDigest": policy.sha256_file(attachment_manifest),
        "manifestSizeBytes": attachment_manifest.stat().st_size,
        "attachmentRelativePath": attachment_payload.relative_to(
            retained_root
        ).as_posix(),
        "attachmentDigestAlgorithm": "sha256",
        "attachmentDigest": policy.sha256_file(attachment_payload),
        "attachmentSizeBytes": attachment_payload.stat().st_size,
    },
}
row = {
    "scenario": "vod",
    "runnerScenario": "vod",
    "hardware": "iphone-current",
    "device": "Test phone",
    "deviceFamily": "iPhone",
    "productType": "iPhone16,1",
    "osVersion": "26.6",
    "osBuild": "23G80",
    "osReleaseType": "stable",
    "fixture": f"qualification-fixtures:{identity['fixtureManifestChecksum']}",
    "duration": "120s",
    "durationSeconds": 120,
    "evidence": "evidence.json",
    "result": "pass",
}
(retained_root / "evidence.json").write_text(json.dumps(evidence, sort_keys=True))
report_path = retained_root / "report.json"
report_path.write_text(
    json.dumps(
        {
            **identity,
            "mode": "qualification",
            "qualificationEligibleEnvironment": True,
            "device": {"udid": "fixture-device"},
            "result": "pass",
            "scenarios": runner_rows,
            "qualificationRows": [row],
        },
        sort_keys=True,
    )
)
source_binding = {
    "path": retained_root.relative_to(root).as_posix(),
    "reportRelativePath": report_path.name,
    "reportDigestAlgorithm": "sha256",
    "reportDigest": policy.sha256_file(report_path),
    "reportSizeBytes": report_path.stat().st_size,
    "treeDigestAlgorithm": "swiftvlc-tree-v1",
    "treeDigest": policy.tree_digest(retained_root),
    "treeSizeBytes": policy.tree_size_bytes(retained_root),
}
evidence_path.write_text(json.dumps(evidence, sort_keys=True))
source_report_relative = (
    Path(source_binding["path"]) / source_binding["reportRelativePath"]
).as_posix()
record_path.write_text(
    json.dumps(
        {
            **identity,
            "sourceReports": [source_binding],
            "runnerScenarios": [
                policy.runner_record_summary(
                    runner_row, "iphone-current", source_report_relative
                )
                for runner_row in runner_rows
            ],
            "rows": [row],
        },
        sort_keys=True,
    )
)
PY

mkdir -p "$temp_dir/fake-bin"
cat > "$temp_dir/fake-bin/xcrun" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "xcresulttool" ]; then
  if [ "${2:-}" = "export" ] && [ "${3:-}" = "attachments" ]; then
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--output-path" ]; then
        shift
        output="${1:-}"
        break
      fi
      shift
    done
    [ -n "$output" ] || exit 2
    mkdir -p "$output"
    cp -R "$SWIFTVLC_RELEASE_TEST_ATTACHMENT_EXPORT/." "$output/"
    exit 0
  fi
  printf '%s\n' '{"testNodes":[{"nodeType":"Test Case","nodeIdentifier":"iOSUITests/FixtureTests/test_releaseIntegrity","result":"Passed"}]}'
  exit 0
fi
exec /usr/bin/xcrun "$@"
EOF
chmod +x "$temp_dir/fake-bin/xcrun"
export SWIFTVLC_RELEASE_TEST_ATTACHMENT_EXPORT="$temp_dir/retained-report/vod-attachments"
export PATH="$temp_dir/fake-bin:$PATH"

SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

if SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM=$(printf '%064d' 0) \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a feature policy from another prepared candidate"
fi

SWIFTVLC_CANDIDATE_SOURCE_COMMIT="$qualification_source_commit" \
  SWIFTVLC_CANDIDATE_SOURCE_DIGEST="$qualification_source_digest" \
  SWIFTVLC_CANDIDATE_MATRIX_CHECKSUM="$qualification_matrix_checksum" \
  SWIFTVLC_CANDIDATE_FEATURE_MANIFEST_CHECKSUM="$fixture_feature_checksum" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/missing-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a missing feature policy"
fi

python3 - "$temp_dir/feature-manifest.json" \
  "$temp_dir/blocked-feature-manifest.json" \
  "$temp_dir/advisory-feature-manifest.json" <<'PY'
import json
import sys

source, blocked_output, advisory_output = sys.argv[1:]
manifest = json.load(open(source))
receiver = {
    "id": "receiver-output",
    "category": "playback",
    "title": "Receiver output",
    "description": "Fixture receiver output must be proven.",
    "releaseRequirement": "required",
    "execution": "external-lab",
    "evidenceLevel": "receiver-output",
    "blocker": "No fixture receiver evidence exists.",
}
manifest["features"].append(receiver)
json.dump(manifest, open(blocked_output, "w"))
receiver["releaseRequirement"] = "advisory"
json.dump(manifest, open(advisory_output, "w"))
PY
if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/blocked-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted an incomplete required feature policy"
fi

if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/advisory-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted advisory feature policy drift"
fi

python3 - "$temp_dir/feature-manifest.json" \
  "$temp_dir/unclassified-feature-manifest.json" <<'PY'
import json
import sys

source, output = sys.argv[1:]
manifest = json.load(open(source))
manifest["features"][0]["scenarioIds"] = []
manifest["features"][0]["execution"] = "planned"
manifest["features"][0]["blocker"] = "Fixture scenario was removed from policy."
manifest["features"][0]["runnerScenarioIds"] = []
json.dump(manifest, open(output, "w"))
PY
if SWIFTVLC_FEATURE_MANIFEST="$temp_dir/unclassified-feature-manifest.json" \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a feature policy that omitted a matrix scenario"
fi

# The scenario is scoped to iPhone, so the unrecorded iPad row must not be
# invented by the checker. The successful call above is the regression test.

python3 - "$temp_dir/record.json" <<'PY'
import json
import sys

path = sys.argv[1]
record = json.load(open(path))
record["releaseSourceDigest"] = "0" * 64
json.dump(record, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification survived a Swift wrapper source change"
fi

python3 - "$temp_dir/record.json" "$qualification_source_digest" <<'PY'
import json
import sys

path, source_digest = sys.argv[1:]
record = json.load(open(path))
record["releaseSourceDigest"] = source_digest
json.dump(record, open(path, "w"))
PY
python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["releaseSourceDigest"] = "0" * 64
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence from another Swift wrapper source"
fi

python3 - "$temp_dir/evidence.json" "$qualification_source_digest" <<'PY'
import json
import sys

path, source_digest = sys.argv[1:]
evidence = json.load(open(path))
evidence["releaseSourceDigest"] = source_digest
json.dump(evidence, open(path, "w"))
PY
cp "$temp_dir/matrix.json" "$temp_dir/matrix-original.json"
python3 - "$temp_dir/matrix.json" <<'PY'
import json
import sys

path = sys.argv[1]
matrix = json.load(open(path))
matrix["changedAfterQualification"] = True
json.dump(matrix, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification survived a matrix change"
fi
cp "$temp_dir/matrix-original.json" "$temp_dir/matrix.json"

if SWIFTVLC_CANDIDATE_SOURCE_COMMIT=0000000000000000000000000000000000000000 \
  SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a record from another candidate commit"
fi

python3 - "$temp_dir/record.json" <<'PY'
import json
import sys

path = sys.argv[1]
record = json.load(open(path))
record["rows"][0]["durationSeconds"] = 30
json.dump(record, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a run shorter than the scenario minimum"
fi

for non_finite in nan infinity; do
  python3 - "$temp_dir/record.json" "$non_finite" <<'PY'
import json
import sys

path, kind = sys.argv[1:3]
record = json.load(open(path))
record["rows"][0]["durationSeconds"] = (
    float("nan") if kind == "nan" else float("inf")
)
json.dump(record, open(path, "w"))
PY
  if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
    SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
    "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
    fail "qualification accepted a non-finite duration: $non_finite"
  fi
done

python3 - "$temp_dir/record.json" "$temp_dir/evidence.json" <<'PY'
import json
import sys

record_path, evidence_path = sys.argv[1:3]
record = json.load(open(record_path))
record["rows"][0]["durationSeconds"] = 120
json.dump(record, open(record_path, "w"))
evidence = json.load(open(evidence_path))
evidence["metrics"].pop("cpu")
json.dump(evidence, open(evidence_path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence missing a required metric"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["cpu"] = 0
json.dump(evidence, open(path, "w"))
PY

SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["errors"] = 1
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence with a wrong expected value"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["errors"] = False
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification treated a boolean as an expected number"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["metrics"]["errors"] = 0
evidence["rates"] = [True, 2]
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification treated a boolean as a number inside an expected array"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["rates"] = [1.0, 2]
evidence["retryCount"] = False
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification treated a boolean as an allowed number"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["retryCount"] = 0
evidence["outcome"] = "failed"
json.dump(evidence, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted evidence outside the allowed values"
fi

python3 - "$temp_dir/evidence.json" <<'PY'
import json
import sys

path = sys.argv[1]
evidence = json.load(open(path))
evidence["outcome"] = "stable"
json.dump(evidence, open(path, "w"))
PY

SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null

if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-b" >/dev/null 2>&1; then
  fail "qualification survived a header change"
fi

python3 - "$temp_dir/record.json" <<'PY'
import json
import sys

path = sys.argv[1]
record = json.load(open(path))
record["rows"][0]["osReleaseType"] = "beta"
json.dump(record, open(path, "w"))
PY
if SWIFTVLC_QUALIFICATION_MATRIX="$temp_dir/matrix.json" \
  SWIFTVLC_QUALIFICATION_RECORD="$temp_dir/record.json" \
  "$SCRIPT_DIR/check-qualification.sh" 1.1.0 "$temp_dir/tree-a" >/dev/null 2>&1; then
  fail "qualification accepted a beta OS row"
fi

python3 - "$ROOT_DIR/scripts/qualification/matrix.json" <<'PY'
import json
import sys

matrix = json.load(open(sys.argv[1]))
for scenario in matrix["scenarios"]:
    if 88 not in scenario.get("issues", []):
        continue
    expected = scenario.get("expectedEvidenceValues", {})
    if not any(field.startswith("events.") for field in expected):
        raise SystemExit(
            f"issue 88 scenario {scenario['id']} does not enforce lifecycle outcomes"
        )
    if "controls" in scenario.get("requiredEvidenceFields", []):
        allowed = scenario.get("allowedEvidenceValues", {})
        if not any(
            field == "controls" or field.startswith("controls.")
            for field in expected.keys() | allowed.keys()
        ):
            raise SystemExit(
                f"issue 88 scenario {scenario['id']} does not enforce control outcomes"
            )
PY

# Exercise the production release shell in an isolated repository with local
# command doubles. Static source markers cannot prove candidate field ordering,
# private snapshot use, or the exact bytes handed to `gh release create`.
release_flow_root="$temp_dir/release-flow"
release_flow_repo="$release_flow_root/repository"
release_flow_origin="$release_flow_root/origin.git"
release_flow_candidate="$release_flow_root/candidate"
release_flow_expected="$release_flow_root/expected-upload"
release_flow_capture="$release_flow_root/captured-upload"
release_flow_fake_bin="$release_flow_root/fake-bin"
release_flow_tmp="$release_flow_root/tmp"
mkdir -p \
  "$release_flow_repo/scripts/patches/validation" \
  "$release_flow_repo/scripts/qualification" \
  "$release_flow_repo/Showcase/SwiftVLCShowcase.xcodeproj" \
  "$release_flow_repo/Vendor" \
  "$release_flow_expected" \
  "$release_flow_capture" \
  "$release_flow_fake_bin" \
  "$release_flow_tmp"

cp "$SCRIPT_DIR/release.sh" "$release_flow_repo/scripts/release.sh"
cp "$SCRIPT_DIR/artifact-tree-digest.py" \
  "$release_flow_repo/scripts/artifact-tree-digest.py"
cp "$ROOT_DIR/Package.swift" "$release_flow_repo/Package.swift"
cp "$ROOT_DIR/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj" \
  "$release_flow_repo/Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
printf 'Vendor/\n' > "$release_flow_repo/.gitignore"
printf '{"fixture":true}\n' > \
  "$release_flow_repo/scripts/qualification/matrix.json"
printf '{"fixture":true}\n' > \
  "$release_flow_repo/scripts/qualification/feature-manifest-v1.json"
printf '%064d  0001-fixture.patch\n' 0 > \
  "$release_flow_repo/scripts/patches/manifest.sha256"
printf 'fixture native probe\n' > \
  "$release_flow_repo/scripts/patches/validation/native-extension-version-probe.c"
printf 'fixture extension parser\n' > \
  "$release_flow_repo/scripts/patches/validation/pip_extension_version.py"

cat > "$release_flow_repo/scripts/release-version-policy.py" <<'PY'
#!/usr/bin/env python3
import sys

if len(sys.argv) != 4 or sys.argv[2:] != ["--field", "kind"]:
    raise SystemExit(2)
print("stable")
PY
cat > "$release_flow_repo/scripts/verify-native-validator-assets.py" <<'PY'
#!/usr/bin/env python3
raise SystemExit(0)
PY
cat > "$release_flow_repo/scripts/validate-libvlc-macho-metadata.py" <<'PY'
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

arguments = sys.argv[1:]
output = Path(arguments[arguments.index("--json-output") + 1])
output.write_text(json.dumps({"fixture": True}) + "\n")
PY
cat > "$release_flow_repo/scripts/libvlc-provenance.py" <<'PY'
#!/usr/bin/env python3
import os
import sys
from pathlib import Path

arguments = sys.argv[1:]
command = arguments[0]


def value(flag):
    return Path(arguments[arguments.index(flag) + 1]).resolve()


def require_private_snapshot(paths):
    parents = {path.parent for path in paths}
    if len(parents) != 1 or next(iter(parents)).name != "release-assets":
        raise SystemExit(
            "Error: release provenance verification bypassed its private snapshot"
        )
    if any(not path.exists() for path in paths):
        raise SystemExit("Error: snapshotted release input is missing")


if command == "verify":
    require_private_snapshot([value("--provenance"), value("--xcframework")])
    expected_revision = os.environ["SWIFTVLC_RELEASE_TEST_EXPECTED_REVISION"]
    actual_revision = arguments[arguments.index("--swiftvlc-revision") + 1]
    if actual_revision != expected_revision:
        raise SystemExit(
            "Error: release verified provenance against the wrong SwiftVLC "
            f"revision: {actual_revision} != {expected_revision}"
        )
elif command == "verify-proof":
    require_private_snapshot(
        [
            value("--proof"),
            value("--first-provenance"),
            value("--second-provenance"),
            value("--current-provenance"),
            value("--xcframework"),
        ]
    )
else:
    raise SystemExit(f"Error: unexpected provenance command: {command}")
PY
cat > "$release_flow_repo/scripts/release-source-digest.py" <<'PY'
#!/usr/bin/env python3
print("a" * 64)
PY

cat > "$release_flow_repo/scripts/canonical-libvlc-artifact.sh" <<'SH'
#!/bin/sh
set -eu

command_name=$1
source_path=$2
output_path=$3
case "$command_name" in
  stage)
    [ ! -e "$output_path" ]
    mkdir -p "$(dirname "$output_path")"
    cp -R "$source_path" "$output_path"
    ;;
  archive)
    [ ! -e "$output_path" ]
    source_parent=$(cd "$(dirname "$source_path")" && pwd)
    source_name=$(basename "$source_path")
    output_parent=$(dirname "$output_path")
    mkdir -p "$output_parent"
    output_path=$(cd "$output_parent" && pwd)/$(basename "$output_path")
    (
      cd "$source_parent"
      COPYFILE_DISABLE=1 LC_ALL=C TZ=UTC \
        /usr/bin/zip -q -r -X -y "$output_path" "$source_name"
    )
    ;;
  *)
    exit 2
    ;;
esac
SH

cat > "$release_flow_repo/scripts/check-libvlc-manifest.sh" <<'SH'
#!/bin/sh
set -eu

if [ -n "${SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR:-}" ]; then
  for name in \
    libvlc-provenance-a.json \
    libvlc-provenance.json \
    libvlc-reproducibility.json; do
    printf 'mutated after private snapshot\n' >> \
      "$SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR/$name"
  done
  printf 'mutated after private snapshot\n' > \
    "$SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR/libvlc.xcframework/ios-arm64/libvlc.a"
fi
SH

cat > "$release_flow_repo/scripts/check-qualification.sh" <<'SH'
#!/bin/sh
set -eu

case "$2" in
  */swiftvlc-release.*/release-assets/libvlc.xcframework) ;;
  *)
    echo "qualification did not receive the private XCFramework snapshot: $2" >&2
    exit 1
    ;;
esac
if [ -n "${SWIFTVLC_RELEASE_TEST_MUTATE_CANDIDATE:-}" ]; then
  for name in \
    libvlc.xcframework.zip \
    libvlc-provenance-a.json \
    libvlc-provenance.json \
    libvlc-reproducibility.json \
    release-candidate.json; do
    printf 'mutated after private snapshot\n' >> \
      "$SWIFTVLC_RELEASE_TEST_MUTATE_CANDIDATE/$name"
  done
fi
SH

for release_flow_stub in \
  fix-duplicate-symbols.sh \
  validate-native-extension-contract.sh \
  validate-apple-assembly-metadata-patch.sh \
  validate-aom-nasm3-detection.sh \
  validate-headless-vout-teardown.sh \
  validate-chromecast-load-transition.sh \
  validate-post-pin-stability.sh \
  verify-patch-manifest.sh; do
  printf '#!/bin/sh\nexit 0\n' > \
    "$release_flow_repo/scripts/$release_flow_stub"
done
printf '#!/bin/sh\nVLC_HASH="111111111"\n' > \
  "$release_flow_repo/scripts/build-libvlc.sh"

cat > "$release_flow_fake_bin/swift" <<'SH'
#!/bin/sh
set -eu

if [ "$#" -eq 3 ] && [ "$1" = package ] && \
    [ "$2" = compute-checksum ]; then
  shasum -a 256 "$3" | cut -d' ' -f1
  exit 0
fi
exit 2
SH
cat > "$release_flow_fake_bin/git" <<'SH'
#!/bin/sh
set -eu

if [ "${1:-}" = push ]; then
  printf '%s\n' "$*" >> "$SWIFTVLC_RELEASE_TEST_GIT_LOG"
  exit 0
fi
exec /usr/bin/git "$@"
SH
cat > "$release_flow_fake_bin/gh" <<'SH'
#!/bin/sh
set -eu

if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
if [ "${1:-}" = release ] && [ "${2:-}" = view ]; then
  exit 1
fi
if [ "${1:-}" = release ] && [ "${2:-}" = edit ]; then
  exit 0
fi
if [ "${1:-}" = release ] && [ "${2:-}" = create ]; then
  shift 3
  : > "$SWIFTVLC_RELEASE_TEST_CAPTURE/assets.paths"
  while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do
    source_path=$1
    output_path="$SWIFTVLC_RELEASE_TEST_CAPTURE/$(basename "$source_path")"
    [ ! -e "$output_path" ] || exit 3
    cp "$source_path" "$output_path"
    printf '%s\n' "$source_path" >> \
      "$SWIFTVLC_RELEASE_TEST_CAPTURE/assets.paths"
    shift
  done
  exit 0
fi
echo "unexpected gh invocation: $*" >&2
exit 2
SH
chmod +x \
  "$release_flow_repo/scripts/"*.sh \
  "$release_flow_repo/scripts/"*.py \
  "$release_flow_fake_bin/git" \
  "$release_flow_fake_bin/gh" \
  "$release_flow_fake_bin/swift"

for slice in \
  ios-arm64 \
  ios-arm64_x86_64-simulator \
  tvos-arm64 \
  tvos-arm64_x86_64-simulator \
  xros-arm64 \
  xros-arm64_x86_64-simulator \
  macos-arm64_x86_64 \
  ios-arm64_x86_64-maccatalyst; do
  mkdir -p "$release_flow_repo/Vendor/libvlc.xcframework/$slice"
  printf 'fixture archive for %s\n' "$slice" > \
    "$release_flow_repo/Vendor/libvlc.xcframework/$slice/libvlc.a"
done
printf 'fixture first provenance\n' > \
  "$release_flow_repo/Vendor/libvlc-provenance-a.json"
printf 'fixture second provenance\n' > \
  "$release_flow_repo/Vendor/libvlc-provenance.json"
printf 'fixture reproducibility proof\n' > \
  "$release_flow_repo/Vendor/libvlc-reproducibility.json"

git -C "$release_flow_repo" init -q
git -C "$release_flow_repo" branch -M main
git -C "$release_flow_repo" config user.name "SwiftVLC Release Test"
git -C "$release_flow_repo" config user.email \
  "swiftvlc-release-test@example.invalid"
git -C "$release_flow_repo" add .
git -C "$release_flow_repo" commit -qm "release fixture"
release_flow_source_commit=$(git -C "$release_flow_repo" rev-parse HEAD)
git clone -q --bare "$release_flow_repo" "$release_flow_origin"
git -C "$release_flow_repo" remote add origin "$release_flow_origin"
git -C "$release_flow_repo" fetch -q origin main

release_flow_vendor_digest=$(
  "$release_flow_repo/scripts/artifact-tree-digest.py" \
    "$release_flow_repo/Vendor/libvlc.xcframework"
)
for release_flow_sidecar in \
  libvlc-provenance-a.json \
  libvlc-provenance.json \
  libvlc-reproducibility.json; do
  cp "$release_flow_repo/Vendor/$release_flow_sidecar" \
    "$release_flow_expected/$release_flow_sidecar"
done

release_flow_git_log="$release_flow_root/git-pushes.log"
: > "$release_flow_git_log"
(
  cd "$release_flow_repo"
  PATH="$release_flow_fake_bin:$PATH" \
    TMPDIR="$release_flow_tmp" \
    SWIFTVLC_RELEASE_TEST_EXPECTED_REVISION="$release_flow_source_commit" \
    SWIFTVLC_RELEASE_TEST_GIT_LOG="$release_flow_git_log" \
    SWIFTVLC_RELEASE_TEST_MUTATE_VENDOR="$release_flow_repo/Vendor" \
    ./scripts/release.sh 1.1.0 --prepare "$release_flow_candidate" \
    > "$release_flow_root/prepare.log"
)

for release_flow_sidecar in \
  libvlc-provenance-a.json \
  libvlc-provenance.json \
  libvlc-reproducibility.json; do
  cmp -s "$release_flow_expected/$release_flow_sidecar" \
    "$release_flow_candidate/$release_flow_sidecar" || \
    fail "prepared candidate used a post-snapshot $release_flow_sidecar"
done
release_flow_candidate_digest=$(
  "$release_flow_repo/scripts/artifact-tree-digest.py" \
    "$release_flow_candidate/libvlc.xcframework"
)
[[ "$release_flow_candidate_digest" == "$release_flow_vendor_digest" ]] || \
  fail "prepared candidate used a post-snapshot XCFramework"

python3 - \
  "$release_flow_candidate/release-candidate.json" \
  "$release_flow_candidate" \
  "$release_flow_repo/scripts/artifact-tree-digest.py" \
  "$release_flow_source_commit" \
  "$release_flow_repo/scripts/qualification/matrix.json" \
  "$release_flow_repo/scripts/qualification/feature-manifest-v1.json" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

(
    manifest_path_value,
    candidate_root_value,
    digest_tool_value,
    source_commit,
    matrix_path_value,
    feature_path_value,
) = sys.argv[1:]
manifest_path = Path(manifest_path_value)
candidate_root = Path(candidate_root_value)


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


candidate = json.loads(manifest_path.read_text())
expected = {
    "version": "1.1.0",
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": subprocess.check_output(
        [digest_tool_value, candidate_root / "libvlc.xcframework"], text=True
    ).strip(),
    "zipChecksum": sha256(candidate_root / "libvlc.xcframework.zip"),
    "firstProvenanceChecksum": sha256(
        candidate_root / "libvlc-provenance-a.json"
    ),
    "provenanceChecksum": sha256(candidate_root / "libvlc-provenance.json"),
    "reproducibilityChecksum": sha256(
        candidate_root / "libvlc-reproducibility.json"
    ),
    "sourceCommit": source_commit,
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": "a" * 64,
    "qualificationMatrixChecksum": sha256(matrix_path_value),
    "featureManifestChecksum": sha256(feature_path_value),
}
if candidate != expected:
    raise SystemExit(
        "release candidate field/checksum mapping differs:\n"
        f"expected={expected}\nactual={candidate}"
    )
PY

for release_flow_asset in \
  libvlc.xcframework.zip \
  libvlc-provenance-a.json \
  libvlc-provenance.json \
  libvlc-reproducibility.json \
  release-candidate.json; do
  cp "$release_flow_candidate/$release_flow_asset" \
    "$release_flow_expected/$release_flow_asset"
done

# Candidate consumption may happen after qualification evidence advances main.
# The artifact must still be checked against the candidate's source commit, not
# the newer checkout HEAD, while the candidate source remains an ancestor.
mkdir -p "$release_flow_repo/scripts/qualification/evidence/1.1.0"
printf '{"fixture":"qualified"}\n' > \
  "$release_flow_repo/scripts/qualification/evidence/1.1.0/device.json"
git -C "$release_flow_repo" add \
  scripts/qualification/evidence/1.1.0/device.json
git -C "$release_flow_repo" commit -qm "Record qualification evidence"
/usr/bin/git -C "$release_flow_repo" push -q origin main
release_flow_origin_before_release=$(
  git --git-dir="$release_flow_origin" rev-parse refs/heads/main
)
[[ "$release_flow_origin_before_release" != "$release_flow_source_commit" ]] || \
  fail "release revision fixture did not advance main after preparation"

(
  cd "$release_flow_repo"
  PATH="$release_flow_fake_bin:$PATH" \
    TMPDIR="$release_flow_tmp" \
    SWIFTVLC_RELEASE_TEST_EXPECTED_REVISION="$release_flow_source_commit" \
    SWIFTVLC_RELEASE_TEST_CAPTURE="$release_flow_capture" \
    SWIFTVLC_RELEASE_TEST_GIT_LOG="$release_flow_git_log" \
    SWIFTVLC_RELEASE_TEST_MUTATE_CANDIDATE="$release_flow_candidate" \
    ./scripts/release.sh 1.1.0 --candidate "$release_flow_candidate" \
    > "$release_flow_root/release.log"
)

expected_release_assets=(
  libvlc.xcframework.zip
  libvlc-provenance-a.json
  libvlc-provenance.json
  libvlc-reproducibility.json
  release-candidate.json
)
captured_release_count=0
while IFS= read -r captured_release_path; do
  captured_release_paths[$captured_release_count]="$captured_release_path"
  captured_release_count=$((captured_release_count + 1))
done < "$release_flow_capture/assets.paths"
[[ $captured_release_count -eq ${#expected_release_assets[@]} ]] || \
  fail "release uploaded the wrong number of assets"
for ((release_flow_index = 0;
      release_flow_index < ${#expected_release_assets[@]};
      release_flow_index++)); do
  release_flow_asset=${expected_release_assets[$release_flow_index]}
  release_flow_path=${captured_release_paths[$release_flow_index]}
  [[ $(basename "$release_flow_path") == "$release_flow_asset" ]] || \
    fail "release asset order/name drifted: expected $release_flow_asset, got $release_flow_path"
  case "$release_flow_path" in
    "$release_flow_tmp"/swiftvlc-release.*/release-assets/*) ;;
    *) fail "release uploaded an asset outside its private snapshot: $release_flow_path" ;;
  esac
  cmp -s "$release_flow_expected/$release_flow_asset" \
    "$release_flow_capture/$release_flow_asset" || \
    fail "release uploaded changed bytes for $release_flow_asset"
  if cmp -s "$release_flow_expected/$release_flow_asset" \
    "$release_flow_candidate/$release_flow_asset"; then
    fail "release TOCTOU fixture did not mutate original $release_flow_asset"
  fi
done
[[ $(wc -l < "$release_flow_git_log" | tr -d ' ') == 2 ]] || \
  fail "mock release did not reach both production push boundaries"
[[ $(git --git-dir="$release_flow_origin" rev-parse refs/heads/main) == \
  "$release_flow_origin_before_release" ]] || \
  fail "mock release changed its local origin/main"
if git --git-dir="$release_flow_origin" rev-parse refs/tags/v1.1.0 \
  >/dev/null 2>&1; then
  fail "mock release pushed a tag to its local origin"
fi

cd "$ROOT_DIR"
bash -n \
  scripts/canonical-libvlc-artifact.sh \
  scripts/check-engine-coverage.sh \
  scripts/check-qualification.sh \
  scripts/ci-use-released-xcframework.sh \
  scripts/release.sh \
  scripts/resolve-release-artifact.sh \
  scripts/setup-dev.sh

# GitHub's macOS runners still execute these scripts with Bash 3.2. An empty
# array expansion under nounset fails there even though newer Bash accepts it.
if grep -En '\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}' scripts/setup-dev.sh >/dev/null; then
  fail "setup-dev.sh contains an array expansion that is unsafe under Bash 3.2 nounset"
fi

artifact_info=$(./scripts/resolve-release-artifact.sh)
actual_tag=$(printf '%s' "$artifact_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
showcase_version=$(sed -n \
  's/^[[:space:]]*version = \([^;]*\);$/\1/p' \
  Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj)
[[ -n "$showcase_version" ]] || fail "Showcase release version was not found"
[[ "$actual_tag" == "v$showcase_version" ]] \
  || fail "checkout resolves $actual_tag but Showcase resolves v$showcase_version"

stable_info=$(SWIFTVLC_RELEASE_TAG=v1.0.0 ./scripts/resolve-release-artifact.sh)
stable_tag=$(printf '%s' "$stable_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
[[ "$stable_tag" == "v1.0.0" ]] \
  || fail "explicit release override resolved $stable_tag instead of v1.0.0"

if ./scripts/release.sh 1.1.0 >/dev/null 2>&1; then
  fail "stable release was accepted without a prepared candidate"
fi
if ./scripts/release.sh 1.1.0 --unqualified >/dev/null 2>&1; then
  fail "stable release bypassed qualification through --unqualified"
fi

echo "Release-integrity tests passed."
