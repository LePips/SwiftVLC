#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-release-tests.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

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

# Complete engine provenance records exact slices, SDK/toolchain inputs, patch
# order, contrib checksums, and two-build reproducibility. Exercise it with a
# minimal valid XCFramework so release integrity does not depend on a 368 MB
# binary fixture.
mkdir -p "$temp_dir/fake-vlc/contrib/src/example"
printf 'example contrib checksum\n' > "$temp_dir/fake-vlc/contrib/src/example/SHA512SUMS"
printf '%064d  0001-example.patch\n' 0 > "$temp_dir/patch-manifest.sha256"
printf '#!/bin/sh\necho fixture\n' > "$temp_dir/build-config.sh"
mkdir -p "$temp_dir/build-a/macos-arm64/Headers"
printf 'header\n' > "$temp_dir/build-a/macos-arm64/Headers/libvlc.h"
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
cp -R "$temp_dir/build-a" "$temp_dir/build-b"

build_index=0
for build_name in a b; do
  build_index=$((build_index + 1))
  "$SCRIPT_DIR/libvlc-provenance.py" create \
    --xcframework "$temp_dir/build-$build_name" \
    --output "$temp_dir/provenance-$build_name.json" \
    --vlc-source "$temp_dir/fake-vlc" \
    --source-revision 1111111111111111111111111111111111111111 \
    --pinned-revision 111111111 \
    --source-date-epoch 0 \
    --patch-manifest "$temp_dir/patch-manifest.sha256" \
    --build-configuration-file "build-script=$temp_dir/build-config.sh" \
    --build-invocation-id "00000000-0000-0000-0000-00000000000${build_index}" \
    --clean-build \
    --make-flags=-j1 \
    --deployment-target macos=15.0
done
"$SCRIPT_DIR/libvlc-provenance.py" compare \
  --first "$temp_dir/provenance-a.json" \
  --second "$temp_dir/provenance-b.json" \
  --output "$temp_dir/reproducibility.json" >/dev/null
"$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" >/dev/null
"$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --provenance "$temp_dir/provenance-b.json" >/dev/null

# A changed effective build script invalidates otherwise matching provenance.
printf '#!/bin/sh\necho changed\n' > "$temp_dir/build-config.sh"
if "$SCRIPT_DIR/libvlc-provenance.py" verify \
  --provenance "$temp_dir/provenance-b.json" \
  --xcframework "$temp_dir/build-b" \
  --pinned-revision 111111111 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" >/dev/null 2>&1; then
  fail "provenance accepted a changed build configuration"
fi
printf '#!/bin/sh\necho fixture\n' > "$temp_dir/build-config.sh"

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
  --first "$temp_dir/provenance-a.json" \
  --second "$temp_dir/provenance-same-invocation.json" >/dev/null 2>&1; then
  fail "reproducibility accepted the same build invocation twice"
fi

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
  --first "$temp_dir/provenance-a.json" \
  --second "$temp_dir/provenance-incremental.json" >/dev/null 2>&1; then
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
  --vlc-source "$temp_dir/fake-vlc" \
  --source-revision 1111111111111111111111111111111111111111 \
  --pinned-revision 111111111 \
  --source-date-epoch 0 \
  --patch-manifest "$temp_dir/patch-manifest.sha256" \
  --build-configuration-file "build-script=$temp_dir/build-config.sh" \
  --build-invocation-id 00000000-0000-0000-0000-000000000004 \
  --clean-build \
  --make-flags=-j1 \
  --deployment-target macos=15.0
if "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
  --proof "$temp_dir/reproducibility.json" \
  --provenance "$temp_dir/mutated-provenance.json" >/dev/null 2>&1; then
  fail "reproducibility proof accepted a mutated post-build tree"
fi

python3 - "$SCRIPT_DIR/build-libvlc.sh" "$SCRIPT_DIR/release.sh" <<'PY'
import sys

build = open(sys.argv[1]).read()
release = open(sys.argv[2]).read()
verification = build.rindex("verify_deployment_targets\n")
provenance = build.index('python3 "${SCRIPT_DIR}/libvlc-provenance.py" create')
if provenance < verification:
    sys.exit("provenance is written before deployment-target verification")
if 'rm -f "${OUTPUT_DIR}/libvlc-provenance.json"' not in build:
    sys.exit("a failed rebuild can leave stale provenance beside its artifact")
if "libvlc-provenance.py\" rebind" in release or "find \"$WORK_XCFW\" -name '*.a'" in release:
    sys.exit("release packaging still mutates or rebinds the proven artifact")
PY

python3 - "$temp_dir/matrix.json" "$temp_dir/record.json" "$digest_a" <<'PY'
import json
import sys

matrix_path, record_path, digest = sys.argv[1:4]
open(str(record_path).rsplit("/", 1)[0] + "/evidence.json", "w").write("{}\n")
matrix = {
    "scenarios": [{"id": "vod"}],
    "hardware": [
        {"id": "iphone-current", "deviceFamily": "iPhone", "osMajor": 26}
    ],
}
record = {
    "version": "1.1.0",
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": digest,
    "rows": [
        {
            "scenario": "vod",
            "hardware": "iphone-current",
            "device": "Test phone",
            "deviceFamily": "iPhone",
            "productType": "iPhone16,1",
            "osVersion": "26.6",
            "osBuild": "23G80",
            "osReleaseType": "stable",
            "fixture": "fixture.mp4",
            "duration": "2m",
            "evidence": "evidence.json",
            "result": "pass",
        }
    ],
}
json.dump(matrix, open(matrix_path, "w"))
json.dump(record, open(record_path, "w"))
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

cd "$ROOT_DIR"
bash -n \
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
[[ "$actual_tag" == "v1.1.0-beta.1" ]] \
  || fail "checkout resolved $actual_tag instead of v1.1.0-beta.1"

stable_info=$(SWIFTVLC_RELEASE_TAG=v1.0.0 ./scripts/resolve-release-artifact.sh)
stable_tag=$(printf '%s' "$stable_info" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
[[ "$stable_tag" == "v1.0.0" ]] \
  || fail "explicit release override resolved $stable_tag instead of v1.0.0"

if ./scripts/release.sh 1.1.0 >/dev/null 2>&1; then
  fail "stable release was accepted without a prepared candidate"
fi

echo "Release-integrity tests passed."
