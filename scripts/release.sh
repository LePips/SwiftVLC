#!/usr/bin/env bash
#
# release.sh — Strip, zip, checksum, and publish the libVLC xcframework.
#
# Prerequisites:
#   - ./scripts/build-libvlc.sh --all  (produces Vendor/libvlc.xcframework)
#   - gh authed (gh auth login)
#   - A completely clean, up-to-date main checkout
#
# Usage:
#   ./scripts/release.sh 0.1.0
#   ./scripts/release.sh 0.1.0 --prepare /path/to/candidate
#   ./scripts/release.sh 0.1.0 --candidate /path/to/candidate
#   ./scripts/release.sh 0.1.0 --dry-run            # strip/zip/checksum only, no push
#
set -euo pipefail

REPO="harflabs/SwiftVLC"
XCFW_PATH="Vendor/libvlc.xcframework"
SHOWCASE_PROJECT="Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj"
ZIP_NAME="libvlc.xcframework.zip"
MAX_SIZE=$((2 * 1024 * 1024 * 1024))  # 2 GB (GitHub release asset limit)

# All 8 slices the xcframework must contain. If a slice is missing, the release
# would ship a partial artifact that fails on one of SwiftVLC's Apple platforms.
EXPECTED_SLICES=(
  "ios-arm64"
  "ios-arm64_x86_64-simulator"
  "tvos-arm64"
  "tvos-arm64_x86_64-simulator"
  "xros-arm64"
  "xros-arm64_x86_64-simulator"
  "macos-arm64_x86_64"
  "ios-arm64_x86_64-maccatalyst"
)

# ── Args ──────────────────────────────────────────────────────────────────────

VERSION=""
DRY_RUN=false
UNQUALIFIED=false
PREPARE_DIR=""
CANDIDATE_DIR=""
CANDIDATE_SOURCE_COMMIT=""
CANDIDATE_SOURCE_DIGEST=""
CANDIDATE_MATRIX_CHECKSUM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift ;;
    --unqualified)
      UNQUALIFIED=true
      shift ;;
    --prepare)
      [[ $# -ge 2 ]] || { echo "Error: --prepare requires a directory." >&2; exit 2; }
      PREPARE_DIR="$2"
      DRY_RUN=true
      shift 2 ;;
    --candidate)
      [[ $# -ge 2 ]] || { echo "Error: --candidate requires a directory." >&2; exit 2; }
      CANDIDATE_DIR="$2"
      shift 2 ;;
    --allow-dirty-branch)
      echo "Error: --allow-dirty-branch is no longer supported." >&2
      echo "  Releases advance origin/main and must be run from main." >&2
      exit 1 ;;
    --help|-h)
      sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^Usage:/,/^$/p'
      exit 0 ;;
    -*)
      echo "Error: unknown flag '$1'" >&2
      exit 1 ;;
    *)
      if [[ -n "$VERSION" ]]; then
        echo "Error: version already specified ('$VERSION'), got extra arg '$1'" >&2
        exit 1
      fi
      VERSION="$1"
      shift ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [--dry-run]" >&2
  echo "  e.g. $0 0.1.0" >&2
  exit 1
fi

TAG="v${VERSION}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RELEASE_URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_NAME"
cd "$ROOT_DIR"

if [[ -n "$PREPARE_DIR" && -n "$CANDIDATE_DIR" ]]; then
  echo "Error: --prepare and --candidate are mutually exclusive." >&2
  exit 2
fi
if [[ "$DRY_RUN" == false && "$UNQUALIFIED" == false && -z "$CANDIDATE_DIR" ]]; then
  echo "Error: a qualified release must consume a prepared candidate directory." >&2
  echo "  First: $0 $VERSION --prepare /path/to/candidate" >&2
  echo "  Then qualify that directory and release with --candidate." >&2
  exit 1
fi
if [[ -n "$CANDIDATE_DIR" ]]; then
  CANDIDATE_DIR="$(cd "$CANDIDATE_DIR" 2>/dev/null && pwd)" || {
    echo "Error: candidate directory not found." >&2
    exit 1
  }
  XCFW_PATH="$CANDIDATE_DIR/libvlc.xcframework"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

WORK_DIR=""
RELEASE_RESTORE_DIR=""
RELEASE_RESTORE_FILES=false

make_temp_dir() {
  local temp_root="${TMPDIR:-/tmp}"
  mkdir -p "$temp_root"
  mktemp -d "$temp_root/swiftvlc-release.XXXXXX"
}

cleanup() {
  local status=$?

  if [[ "$RELEASE_RESTORE_FILES" == true ]]; then
    if [[ -n "$RELEASE_RESTORE_DIR" && -f "$RELEASE_RESTORE_DIR/Package.swift" ]]; then
      cp "$RELEASE_RESTORE_DIR/Package.swift" Package.swift
    fi
    if [[ -n "$RELEASE_RESTORE_DIR" && -f "$RELEASE_RESTORE_DIR/project.pbxproj" ]]; then
      cp "$RELEASE_RESTORE_DIR/project.pbxproj" "$SHOWCASE_PROJECT"
    fi
    git reset -q -- Package.swift "$SHOWCASE_PROJECT" 2>/dev/null || true
    if [[ "$status" -ne 0 ]]; then
      echo "Restored Package.swift and $SHOWCASE_PROJECT after failed release rewrite." >&2
    fi
  fi

  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
  if [[ -n "$RELEASE_RESTORE_DIR" ]]; then
    rm -rf "$RELEASE_RESTORE_DIR"
  fi
}
trap cleanup EXIT

begin_release_file_restore() {
  RELEASE_RESTORE_DIR=$(make_temp_dir)
  cp Package.swift "$RELEASE_RESTORE_DIR/Package.swift"
  cp "$SHOWCASE_PROJECT" "$RELEASE_RESTORE_DIR/project.pbxproj"
  RELEASE_RESTORE_FILES=true
}

switch_package_to_release_url() {
  RELEASE_URL="$RELEASE_URL" CHECKSUM="$CHECKSUM" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

url = os.environ["RELEASE_URL"]
checksum = os.environ["CHECKSUM"]
path = "Package.swift"

with open(path, "r") as f:
    text = f.read()

pattern = r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)'
replacement = (
    '.binaryTarget(\n'
    '      name: "libvlc",\n'
    f'      url: "{url}",\n'
    f'      checksum: "{checksum}"\n'
    '    )'
)
result, n = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
if n == 0:
    print("ERROR: binaryTarget pattern not found in Package.swift", file=sys.stderr)
    sys.exit(1)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".Package.swift.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(result)
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF
}

switch_showcase_to_release_version() {
  RELEASE_VERSION="$VERSION" SHOWCASE_PROJECT="$SHOWCASE_PROJECT" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

version = os.environ["RELEASE_VERSION"]
path = os.environ["SHOWCASE_PROJECT"]

with open(path, "r") as f:
    text = f.read()

remote_block = f"""/* Begin XCRemoteSwiftPackageReference section */
\t\tBA000001 /* XCRemoteSwiftPackageReference \"SwiftVLC\" */ = {{
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = \"https://github.com/harflabs/SwiftVLC\";
\t\t\trequirement = {{
\t\t\t\tkind = exactVersion;
\t\t\t\tversion = {version};
\t\t\t}};
\t\t}};
/* End XCRemoteSwiftPackageReference section */"""

local_pattern = re.compile(
    r'/\* Begin XCLocalSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCLocalSwiftPackageReference "\.\." \*/ = \{\n'
    r'\t\t\tisa = XCLocalSwiftPackageReference;\n'
    r'\t\t\trelativePath = (?:"\.\."|\.\.);\n'
    r'\t\t\};\n'
    r'/\* End XCLocalSwiftPackageReference section \*/'
)

remote_pattern = re.compile(
    r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
    r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
    r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
    r'\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";\n'
    r'\t\t\trequirement = \{\n'
    r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
    # Pre-release identifiers carry letters and hyphens: 1.1.0-beta.1.
    r'\t\t\t\t(?:minimumVersion|version) = [0-9][0-9A-Za-z.\-]*;\n'
    r'\t\t\t\};\n'
    r'\t\t\};\n'
    r'/\* End XCRemoteSwiftPackageReference section \*/'
)

result, n = local_pattern.subn(remote_block, text, count=1)
if n == 0:
    result, n = remote_pattern.subn(remote_block, text, count=1)
    if n == 0:
        print("ERROR: Showcase package reference block not found", file=sys.stderr)
        sys.exit(1)

result = result.replace(
    'BA000001 /* XCLocalSwiftPackageReference ".." */',
    'BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */',
)

fd, tmp = tempfile.mkstemp(dir=".", prefix=".SwiftVLCShowcase.", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        f.write(result)
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF
}

validate_release_rewrites() {
  local validation_dir
  local validation_status=0
  validation_dir=$(make_temp_dir)
  cp Package.swift "$validation_dir/Package.swift"
  cp "$SHOWCASE_PROJECT" "$validation_dir/project.pbxproj"

  (
    set -e
    cd "$validation_dir"
    SHOWCASE_PROJECT="$validation_dir/project.pbxproj"
    CHECKSUM="0000000000000000000000000000000000000000000000000000000000000000"
    switch_package_to_release_url
    switch_showcase_to_release_version
    grep -q 'name: "CLibVLC"' Package.swift
    grep -q 'kind = exactVersion;' "$SHOWCASE_PROJECT"

    # Round trip. The release direction alone is not enough: setup-dev.sh has
    # to be able to flip the *result* back to a local reference, and CI runs it
    # on every job. v1.1.0-beta.1 passed this validator and still broke every
    # PR, because setup-dev's version pattern was digits-only and could not
    # match a pre-release identifier.
    python3 - "$SHOWCASE_PROJECT" <<'ROUNDTRIP'
import re
import sys

text = open(sys.argv[1]).read()
# Keep in sync with the same pattern in setup-dev.sh.
remote = re.compile(
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
if not remote.search(text):
    sys.exit(
        "setup-dev.sh could not match the released Showcase reference.\n"
        "  CI flips this back to a local package on every job, so releasing\n"
        "  this would break every pull request."
    )
ROUNDTRIP
    grep -q "version = $VERSION;" "$SHOWCASE_PROJECT"
  ) || validation_status=$?

  rm -rf "$validation_dir"
  return "$validation_status"
}

# ── Preflight ─────────────────────────────────────────────────────────────────

if [[ ! -d "$XCFW_PATH" ]]; then
  echo "Error: $XCFW_PATH not found. Build it first: ./scripts/build-libvlc.sh --all" >&2
  exit 1
fi

# Verify every expected platform slice is present. Missing slices would produce
# a release that breaks at SPM-resolution time for affected platforms.
missing_slices=()
for slice in "${EXPECTED_SLICES[@]}"; do
  if [[ ! -d "$XCFW_PATH/$slice" ]]; then
    missing_slices+=("$slice")
  fi
done
if [[ ${#missing_slices[@]} -gt 0 ]]; then
  echo "Error: xcframework is missing slices: ${missing_slices[*]}" >&2
  echo "  Re-run ./scripts/build-libvlc.sh --all to build all platforms." >&2
  exit 1
fi

# Refuse to publish a debug-configured libVLC. Run-time assertions turn
# malformed-media edge cases into process-killing abort()s (issue #30);
# build-libvlc.sh disables them by default. assert() embeds its stringified
# condition only when NDEBUG is undefined, so finding this hxxx_helper assertion
# text proves the slices were built with --with-asserts by mistake. grep -c
# (not -q) consumes the whole stream, avoiding a pipefail/SIGPIPE false negative.
#
# We match a VLC-specific assert *condition*, not the __assert_rtn symbol:
# contrib libraries (libaom, etc.) reference __assert_rtn even in a correct
# --disable-debug build (~348 refs on macOS), so a symbol-presence check would
# false-positive and block every release. Revalidate this signature whenever
# VLC_HASH is bumped to a revision where hxxx_helper.c changes.
assert_hits=$(strings -a "$XCFW_PATH"/*/libvlc.a 2>/dev/null \
  | grep -c 'i_input_nal_length_size || !hh->i_output_nal_length_size' || true)
if [[ "${assert_hits:-0}" -gt 0 ]]; then
  echo "Error: libVLC slices were built with run-time assertions enabled." >&2
  echo "  Shipping them would re-introduce the issue #30 abort() crash." >&2
  echo "  Rebuild without --with-asserts: ./scripts/build-libvlc.sh --clean-build --all" >&2
  exit 1
fi

if ! command -v gh &>/dev/null; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh" >&2
  exit 1
fi

if [[ "$DRY_RUN" == false || -n "$PREPARE_DIR" ]]; then
  if ! gh auth status &>/dev/null; then
    echo "Error: Not authenticated with gh. Run: gh auth login" >&2
    exit 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Error: the working tree is not clean." >&2
    echo "  Every release input and script must come from a committed checkout." >&2
    git status --short >&2
    exit 1
  fi

  # The engine binary's inputs must be answerable from the repository, so a
  # release refuses to proceed while the patch directory disagrees with its
  # committed manifest — an unlisted patch is exactly the case that would
  # otherwise ship without appearing in release history. Same check the build
  # performs; repeated here because a release can package an xcframework built
  # by an earlier invocation.
  if [[ -n "$(git status --porcelain -- scripts/patches)" ]]; then
    echo "Error: scripts/patches has uncommitted changes." >&2
    echo "  A release must be reproducible from committed sources." >&2
    exit 1
  fi
  if ! MANIFEST_OUTPUT=$("$SCRIPT_DIR/verify-patch-manifest.sh" 2>&1); then
    echo "Error: patch manifest verification failed." >&2
    echo "$MANIFEST_OUTPUT" >&2
    exit 1
  fi

  CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
  if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "Error: refusing to release from branch '$CURRENT_BRANCH'." >&2
    echo "  Release commits advance origin/main, so rerun from main." >&2
    exit 1
  fi

  git fetch --quiet origin main --tags
  LOCAL_HEAD=$(git rev-parse HEAD)
  REMOTE_MAIN=$(git rev-parse origin/main)
  if [[ "$LOCAL_HEAD" != "$REMOTE_MAIN" ]]; then
    echo "Error: local main is not exactly origin/main." >&2
    echo "  local:       $LOCAL_HEAD" >&2
    echo "  origin/main: $REMOTE_MAIN" >&2
    echo "  Fetch and fast-forward before preparing a release." >&2
    exit 1
  fi

  if git rev-parse "$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists locally." >&2
    echo "  If the previous release attempt was partial, clean up:" >&2
    echo "    git tag -d $TAG && git push origin :refs/tags/$TAG" >&2
    exit 1
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" &>/dev/null; then
    echo "Error: tag '$TAG' already exists on origin." >&2
    echo "  Finish that release or delete the remote tag before retrying:" >&2
    echo "    git push origin :refs/tags/$TAG" >&2
    exit 1
  fi

  if gh release view "$TAG" --repo "$REPO" &>/dev/null; then
    echo "Error: GitHub Release '$TAG' already exists." >&2
    echo "  Delete it first or pick a new version." >&2
    exit 1
  fi
fi

echo "Validating release manifest rewrites..."
validate_release_rewrites
echo "Release rewrite validation passed."

SOURCE_COMMIT=$(git rev-parse HEAD)
# These two files contain narrowly validated release-managed references. The
# digest normalizes only those fields, so local Showcase wiring and the final
# URL/version rewrite describe the same runtime source while every other
# tracked byte remains qualification-significant.
RELEASE_SOURCE_DIGEST=$("$SCRIPT_DIR/release-source-digest.py" "$VERSION")
QUALIFICATION_MATRIX_CHECKSUM=$(shasum -a 256 \
  "$SCRIPT_DIR/qualification/matrix.json" | cut -d' ' -f1)

# ── Artifact freshness ────────────────────────────────────────────────────────
#
# Everything below packages whatever xcframework is in Vendor/. Nothing so far
# has established that it was built from the sources this release will claim,
# so a binary produced months ago against a different pin or patch set would be
# published as new and nothing would notice (#97, second criterion).
#
# The build records its complete inputs and every slice checksum beside the
# artifact. A separate proof records two byte-identical clean builds. Both have
# to match the exact tree entering the release pipeline.
verify_artifact_provenance() {
  # Derived from XCFW_PATH rather than hard-coded, so the provenance always
  # describes the artifact actually being packaged even if Vendor/ moves.
  local provenance="$(dirname "$XCFW_PATH")/libvlc-provenance.json"
  local reproducibility="$(dirname "$XCFW_PATH")/libvlc-reproducibility.json"

  if [[ ! -f "$provenance" || ! -f "$reproducibility" ]]; then
    echo "Error: complete provenance is missing beside $XCFW_PATH." >&2
    echo "  Required: $provenance" >&2
    echo "  Required: $reproducibility" >&2
    echo "  $XCFW_PATH was built before provenance was recorded, so its inputs" >&2
    echo "  cannot be established. Rebuild with:" >&2
    echo "    ./scripts/build-libvlc.sh --clean-build --all" >&2
    return 1
  fi

  local current_pin current_manifest
  current_pin=$(sed -n 's/^VLC_HASH="\(.*\)"$/\1/p' "$SCRIPT_DIR/build-libvlc.sh" | head -1)
  current_manifest=$(shasum -a 256 "$SCRIPT_DIR/patches/manifest.sha256" | cut -d' ' -f1)

  if ! python3 "$SCRIPT_DIR/libvlc-provenance.py" verify \
    --provenance "$provenance" \
    --xcframework "$XCFW_PATH" \
    --pinned-revision "$current_pin" \
    --patch-manifest "$SCRIPT_DIR/patches/manifest.sha256" \
    --build-configuration-file "build-libvlc.sh=$SCRIPT_DIR/build-libvlc.sh" \
    --build-configuration-file "fix-duplicate-symbols.sh=$SCRIPT_DIR/fix-duplicate-symbols.sh"; then
    echo "  Rebuild so every shipped slice and input has current provenance:" >&2
    echo "    ./scripts/build-libvlc.sh --clean-build --all" >&2
    return 1
  fi
  if ! python3 "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
    --proof "$reproducibility" \
    --provenance "$provenance"; then
    echo "  Run two clean builds and compare their provenance before release." >&2
    return 1
  fi

  echo "Artifact provenance verified: pin $current_pin, patch manifest ${current_manifest:0:12}…"
}

if ! verify_artifact_provenance; then
  exit 1
fi

# ── Prepare or load immutable candidate ───────────────────────────────────────

if [[ -n "$CANDIDATE_DIR" ]]; then
  CANDIDATE_MANIFEST="$CANDIDATE_DIR/release-candidate.json"
  ZIP_PATH="$CANDIDATE_DIR/$ZIP_NAME"
  WORK_XCFW="$XCFW_PATH"

  RELEASE_PROVENANCE="$CANDIDATE_DIR/libvlc-provenance.json"
  RELEASE_REPRODUCIBILITY="$CANDIDATE_DIR/libvlc-reproducibility.json"
  for candidate_file in "$CANDIDATE_MANIFEST" "$ZIP_PATH" \
    "$RELEASE_PROVENANCE" "$RELEASE_REPRODUCIBILITY"; do
    if [[ ! -f "$candidate_file" ]]; then
      echo "Error: prepared candidate is missing $candidate_file." >&2
      exit 1
    fi
  done

  echo "Verifying immutable release candidate..."
  CANDIDATE_VALUES=$(python3 - "$CANDIDATE_MANIFEST" "$VERSION" <<'PY'
import json
import re
import sys

path, version = sys.argv[1:3]
try:
    candidate = json.load(open(path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot read candidate manifest: {error}")

required = {
    "version",
    "artifactDigestAlgorithm",
    "artifactDigest",
    "zipChecksum",
    "provenanceChecksum",
    "reproducibilityChecksum",
    "sourceCommit",
    "releaseSourceDigestAlgorithm",
    "releaseSourceDigest",
    "qualificationMatrixChecksum",
}
missing = sorted(required - candidate.keys())
if missing:
    sys.exit(f"Error: candidate manifest is missing: {', '.join(missing)}")
if candidate["version"] != version:
    sys.exit(
        f"Error: candidate is for {candidate['version']!r}, not {version!r}"
    )
if candidate["artifactDigestAlgorithm"] != "swiftvlc-tree-v1":
    sys.exit("Error: candidate uses an unsupported artifact digest algorithm")
if candidate["releaseSourceDigestAlgorithm"] != "swiftvlc-git-tree-v1":
    sys.exit("Error: candidate uses an unsupported release source digest algorithm")
for field, length in (
    ("sourceCommit", 40),
    ("artifactDigest", 64),
    ("zipChecksum", 64),
    ("provenanceChecksum", 64),
    ("reproducibilityChecksum", 64),
    ("releaseSourceDigest", 64),
    ("qualificationMatrixChecksum", 64),
):
    value = candidate[field]
    if not isinstance(value, str) or not re.fullmatch(
        rf"[0-9a-f]{{{length}}}", value
    ):
        sys.exit(f"Error: candidate has an invalid {field}")
print(candidate["artifactDigest"])
print(candidate["zipChecksum"])
print(candidate["provenanceChecksum"])
print(candidate["reproducibilityChecksum"])
print(candidate["sourceCommit"])
print(candidate["releaseSourceDigestAlgorithm"])
print(candidate["releaseSourceDigest"])
print(candidate["qualificationMatrixChecksum"])
PY
)
  CANDIDATE_TREE_DIGEST=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '1p')
  EXPECTED_ZIP_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '2p')
  EXPECTED_PROVENANCE_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '3p')
  EXPECTED_REPRODUCIBILITY_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '4p')
  CANDIDATE_SOURCE_COMMIT=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '5p')
  CANDIDATE_SOURCE_DIGEST_ALGORITHM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '6p')
  CANDIDATE_SOURCE_DIGEST=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '7p')
  CANDIDATE_MATRIX_CHECKSUM=$(printf '%s\n' "$CANDIDATE_VALUES" | sed -n '8p')

  ACTUAL_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" "$WORK_XCFW")
  CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
  ACTUAL_PROVENANCE_CHECKSUM=$(shasum -a 256 \
    "$RELEASE_PROVENANCE" | cut -d' ' -f1)
  ACTUAL_REPRODUCIBILITY_CHECKSUM=$(shasum -a 256 \
    "$RELEASE_REPRODUCIBILITY" | cut -d' ' -f1)
  if [[ "$ACTUAL_TREE_DIGEST" != "$CANDIDATE_TREE_DIGEST" ]]; then
    echo "Error: prepared XCFramework changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$CHECKSUM" != "$EXPECTED_ZIP_CHECKSUM" ]]; then
    echo "Error: prepared zip changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$ACTUAL_PROVENANCE_CHECKSUM" != "$EXPECTED_PROVENANCE_CHECKSUM" ]]; then
    echo "Error: prepared provenance changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$ACTUAL_REPRODUCIBILITY_CHECKSUM" != "$EXPECTED_REPRODUCIBILITY_CHECKSUM" ]]; then
    echo "Error: prepared reproducibility proof changed after candidate creation." >&2
    exit 1
  fi
  if [[ "$RELEASE_SOURCE_DIGEST" != "$CANDIDATE_SOURCE_DIGEST" ]]; then
    echo "Error: release-significant Swift source changed after candidate creation." >&2
    echo "  candidate: $CANDIDATE_SOURCE_DIGEST" >&2
    echo "  current:   $RELEASE_SOURCE_DIGEST" >&2
    exit 1
  fi
  if [[ "$QUALIFICATION_MATRIX_CHECKSUM" != "$CANDIDATE_MATRIX_CHECKSUM" ]]; then
    echo "Error: the qualification matrix changed after candidate creation." >&2
    exit 1
  fi
  if ! git cat-file -e "${CANDIDATE_SOURCE_COMMIT}^{commit}" 2>/dev/null || \
      ! git merge-base --is-ancestor "$CANDIDATE_SOURCE_COMMIT" HEAD; then
    echo "Error: candidate source commit is not an ancestor of the release checkout." >&2
    exit 1
  fi

  # Prove the zip expands to the qualified tree; matching independent digests
  # is stronger than trusting that the side-by-side directory was the source.
  WORK_DIR=$(make_temp_dir)
  ditto -x -k "$ZIP_PATH" "$WORK_DIR/unpacked"
  PACKED_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" \
    "$WORK_DIR/unpacked/libvlc.xcframework")
  if [[ "$PACKED_TREE_DIGEST" != "$CANDIDATE_TREE_DIGEST" ]]; then
    echo "Error: prepared zip does not contain the qualified XCFramework." >&2
    exit 1
  fi
else
  WORK_DIR=$(make_temp_dir)
  WORK_XCFW="$WORK_DIR/libvlc.xcframework"

  echo "Copying xcframework to temp dir..."
  cp -R "$XCFW_PATH" "$WORK_XCFW"

  echo "Verifying duplicate symbols in release-ready libraries..."
  "$SCRIPT_DIR/fix-duplicate-symbols.sh" --verify "$WORK_XCFW"

  RELEASE_PROVENANCE="$(dirname "$XCFW_PATH")/libvlc-provenance.json"
  RELEASE_REPRODUCIBILITY="$(dirname "$XCFW_PATH")/libvlc-reproducibility.json"
  python3 "$SCRIPT_DIR/libvlc-provenance.py" verify-proof \
    --proof "$RELEASE_REPRODUCIBILITY" \
    --provenance "$RELEASE_PROVENANCE"

  echo "Creating zip..."
  ZIP_PATH="$WORK_DIR/$ZIP_NAME"
  (cd "$WORK_DIR" && ditto -c -k --keepParent libvlc.xcframework "$ZIP_NAME")

  echo "Computing checksum..."
  CHECKSUM=$(swift package compute-checksum "$ZIP_PATH")
fi

ZIP_SIZE=$(stat -f%z "$ZIP_PATH")
ZIP_SIZE_MB=$((ZIP_SIZE / 1024 / 1024))
echo "  Zip size: ${ZIP_SIZE_MB} MB"
echo "  SHA256: $CHECKSUM"

if [[ "$ZIP_SIZE" -ge "$MAX_SIZE" ]]; then
  echo "Error: Zip is ${ZIP_SIZE_MB} MB — exceeds GitHub's 2 GB limit." >&2
  echo "  The xcframework may need further size reduction." >&2
  exit 1
fi

if [[ -n "$PREPARE_DIR" ]]; then
  if [[ -e "$PREPARE_DIR" ]]; then
    echo "Error: prepare destination already exists: $PREPARE_DIR" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$PREPARE_DIR")"
  mkdir "$PREPARE_DIR"
  cp -R "$WORK_XCFW" "$PREPARE_DIR/libvlc.xcframework"
  cp "$ZIP_PATH" "$PREPARE_DIR/$ZIP_NAME"
  cp "$RELEASE_PROVENANCE" "$PREPARE_DIR/libvlc-provenance.json"
  cp "$RELEASE_REPRODUCIBILITY" "$PREPARE_DIR/libvlc-reproducibility.json"

  CANDIDATE_TREE_DIGEST=$("$SCRIPT_DIR/artifact-tree-digest.py" "$WORK_XCFW")
  PROVENANCE_CHECKSUM=$(shasum -a 256 \
    "$PREPARE_DIR/libvlc-provenance.json" | cut -d' ' -f1)
  REPRODUCIBILITY_CHECKSUM=$(shasum -a 256 \
    "$PREPARE_DIR/libvlc-reproducibility.json" | cut -d' ' -f1)
  VERSION="$VERSION" \
    CANDIDATE_TREE_DIGEST="$CANDIDATE_TREE_DIGEST" \
    CHECKSUM="$CHECKSUM" \
    PROVENANCE_CHECKSUM="$PROVENANCE_CHECKSUM" \
    REPRODUCIBILITY_CHECKSUM="$REPRODUCIBILITY_CHECKSUM" \
    SOURCE_COMMIT="$SOURCE_COMMIT" \
    RELEASE_SOURCE_DIGEST="$RELEASE_SOURCE_DIGEST" \
    QUALIFICATION_MATRIX_CHECKSUM="$QUALIFICATION_MATRIX_CHECKSUM" \
    python3 - "$PREPARE_DIR/release-candidate.json" <<'PY'
import json
import os
import sys

candidate = {
    "version": os.environ["VERSION"],
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": os.environ["CANDIDATE_TREE_DIGEST"],
    "zipChecksum": os.environ["CHECKSUM"],
    "provenanceChecksum": os.environ["PROVENANCE_CHECKSUM"],
    "reproducibilityChecksum": os.environ["REPRODUCIBILITY_CHECKSUM"],
    "sourceCommit": os.environ["SOURCE_COMMIT"],
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": os.environ["RELEASE_SOURCE_DIGEST"],
    "qualificationMatrixChecksum": os.environ["QUALIFICATION_MATRIX_CHECKSUM"],
}
with open(sys.argv[1], "w") as output:
    json.dump(candidate, output, indent=2, sort_keys=True)
    output.write("\n")
PY
  echo "Prepared immutable candidate at $PREPARE_DIR"
fi

# Device qualification must describe the exact provenance-covered tree that the
# zip contains. Preparation intentionally precedes qualification; stable
# publishing later requires --candidate and refuses to rebuild or mutate bytes.
if [[ -n "$PREPARE_DIR" ]]; then
  echo "Candidate prepared but not yet device-qualified."
elif [[ "$UNQUALIFIED" == true ]]; then
  echo "WARNING: releasing WITHOUT device qualification."
  echo "  Publishing as a pre-release. It must not be described as qualified,"
  echo "  and the device matrix in scripts/qualification still owes a run."
elif [[ "$DRY_RUN" == true ]]; then
  echo "Dry run only; no device qualification is claimed."
else
  if ! SWIFTVLC_CANDIDATE_SOURCE_COMMIT="$CANDIDATE_SOURCE_COMMIT" \
    SWIFTVLC_CANDIDATE_SOURCE_DIGEST="$CANDIDATE_SOURCE_DIGEST" \
    SWIFTVLC_CANDIDATE_MATRIX_CHECKSUM="$CANDIDATE_MATRIX_CHECKSUM" \
    "$SCRIPT_DIR/check-qualification.sh" "$VERSION" "$WORK_XCFW"; then
    echo "" >&2
    echo "  Qualify the prepared candidate before publishing stable." >&2
    exit 1
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Release Summary ==="
echo "  Version:  $VERSION ($TAG)"
echo "  Zip:      ${ZIP_SIZE_MB} MB"
echo "  Checksum: $CHECKSUM"
echo "  URL:      $RELEASE_URL"

if [[ "$DRY_RUN" == true ]]; then
  echo ""
  echo "Dry run complete. No changes pushed."
  echo ""
  echo "Package.swift snippet:"
  echo "  .binaryTarget("
  echo "    name: \"libvlc\","
  echo "    url: \"$RELEASE_URL\","
  echo "    checksum: \"$CHECKSUM\""
  echo "  )"
  echo ""
  echo "Showcase package requirement:"
  echo "  kind = exactVersion"
  echo "  version = $VERSION"
  exit 0
fi

# ── Release commit on main ───────────────────────────────────────────────────
#
# main should always resolve the most recently published xcframework, and the
# Showcase app should always resolve the matching Swift package release. Local
# development can flip both back to repo-local sources via `setup-dev.sh`.
#
# Mechanics:
#   1. Rewrite Package.swift and the Showcase app, commit, and tag.
#   2. Push the tag and create a draft GitHub Release containing the asset.
#   3. Fast-forward origin/main to the same commit.
#   4. Publish the already-uploaded draft. A failed main push therefore never
#      leaves a public stable release detached from main.
#
# If the tag or draft upload succeeds but the main push fails, nothing public
# has been published. Repair or remove the draft/tag before retrying.

echo ""
echo "Creating release commit on $CURRENT_BRANCH..."

begin_release_file_restore

echo "Pointing Package.swift at $RELEASE_URL..."
switch_package_to_release_url

echo "Pointing Showcase app at SwiftVLC $TAG..."
switch_showcase_to_release_version

# Sanity-check: a corrupted regex result would wipe the rest of Package.swift.
if ! grep -q 'name: "CLibVLC"' Package.swift; then
  echo "Error: Package.swift corrupted — CLibVLC target missing." >&2
  exit 1
fi

if ! grep -q 'kind = exactVersion;' "$SHOWCASE_PROJECT"; then
  echo "Error: Showcase project was not pinned to an exact SwiftVLC version." >&2
  exit 1
fi

git add Package.swift "$SHOWCASE_PROJECT"
git commit --quiet -m "Release $TAG"
RELEASE_RESTORE_FILES=false
TAG_COMMIT=$(git rev-parse HEAD)
git tag "$TAG" "$TAG_COMMIT"

echo "  Tag $TAG → $TAG_COMMIT (Package.swift pinned to $RELEASE_URL)"
echo "  Showcase app → exactVersion $VERSION"

echo "Pushing tag..."
git push origin "$TAG"

# ── GitHub Release ────────────────────────────────────────────────────────────

echo "Creating draft GitHub Release..."
RELEASE_FLAGS=(--draft)
RELEASE_ASSETS=("$ZIP_PATH" "$RELEASE_PROVENANCE" "$RELEASE_REPRODUCIBILITY")
if [[ -n "$CANDIDATE_DIR" ]]; then
  RELEASE_ASSETS+=("$CANDIDATE_DIR/release-candidate.json")
fi
QUALIFICATION_NOTE=""
if [[ "$UNQUALIFIED" == true ]]; then
  RELEASE_FLAGS+=(--prerelease)
  QUALIFICATION_NOTE=$'\n> **Not device-qualified.** The physical-device matrix in `scripts/qualification` has not been executed against this artifact. Published as a pre-release for that reason.\n'
fi

gh release create "$TAG" "${RELEASE_ASSETS[@]}" \
  --repo "$REPO" \
  --verify-tag \
  ${RELEASE_FLAGS[@]+"${RELEASE_FLAGS[@]}"} \
  --title "SwiftVLC $TAG" \
  --notes "$(cat <<EOF
## libVLC xcframework
$QUALIFICATION_NOTE
Pre-built static xcframework for libVLC 4.0.

**Platforms:** iOS 18+, macOS 15+, tvOS 18+, visionOS 2+, Mac Catalyst
**Size:** ${ZIP_SIZE_MB} MB (stripped)
**Checksum:** \`$CHECKSUM\`

SPM resolves this automatically — just add the package dependency.
EOF
)"

echo "Pushing $CURRENT_BRANCH to origin/main..."
git push origin HEAD:main

echo "  origin/main → $TAG_COMMIT"

echo "Publishing GitHub Release..."
gh release edit "$TAG" --repo "$REPO" --draft=false

echo ""
echo "Release $TAG published: https://github.com/$REPO/releases/tag/$TAG"
