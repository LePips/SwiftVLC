#!/usr/bin/env bash
# Resolve and verify the exact released libvlc artifact this checkout declares.
set -euo pipefail

REPO="harflabs/SwiftVLC"
ASSET_NAME="libvlc.xcframework.zip"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TAG="${SWIFTVLC_RELEASE_TAG:-}"
ALLOW_DRAFT="${SWIFTVLC_ALLOW_DRAFT_RELEASE:-}"

usage() {
  echo "Usage: $0 [--tag vX.Y.Z]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      TAG="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown argument '$1'." >&2
      usage
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"

if [[ -z "$TAG" ]]; then
  if ! TAG=$(python3 "$SCRIPT_DIR/release-artifact-info.py" Package.swift --field tag); then
    echo "  Supply --tag or SWIFTVLC_RELEASE_TAG when Package.swift uses a local artifact." >&2
    exit 1
  fi
fi

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Error: invalid release tag '$TAG'." >&2
  exit 1
fi
if [[ -n "$ALLOW_DRAFT" && "$ALLOW_DRAFT" != "1" ]]; then
  echo "Error: SWIFTVLC_ALLOW_DRAFT_RELEASE must be exactly 1 when enabled." >&2
  exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required to verify release metadata." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Error: GitHub CLI authentication is required to verify release metadata." >&2
  exit 1
fi

CHECKOUT_COMMIT=$(git rev-parse HEAD)
RELEASE_TAG="$TAG"
RELEASE_REF="refs/swiftvlc-release/$TAG"
EXPECTED_ASSET_URL=""
CANDIDATE_COMMIT=""
CANDIDATE_EVENT=""

# Draft assets are not public SwiftPM inputs. The sole exception is an
# authenticated push of the exact release-candidate branch in this repository,
# or the same-repository pull request from that exact branch into main. A PR
# checkout is GitHub's synthetic merge commit, so its separately authenticated
# head SHA remains the release identity and the merge tree is compared below.
# Its draft release uses a deliberately non-SemVer tag so SwiftPM cannot select
# the unqualified final version. The tag is deterministic and bound to all 40
# bits of the checkout commit; callers cannot supply or redirect it.
if [[ "$ALLOW_DRAFT" == "1" ]]; then
  if [[ "${GITHUB_ACTIONS:-}" != "true" \
      || "${GITHUB_REPOSITORY:-}" != "$REPO" ]]; then
    echo "Error: draft releases are available only to authenticated candidate CI in $REPO." >&2
    exit 1
  fi
  if [[ ! "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Error: draft release CI is missing an exact GITHUB_SHA." >&2
    exit 1
  fi
  EXPECTED_RELEASE_REF="refs/heads/release-candidates/$TAG"
  if [[ "$CHECKOUT_COMMIT" != "$GITHUB_SHA" ]]; then
    echo "Error: checked-out HEAD and GITHUB_SHA must be identical." >&2
    exit 1
  fi

  case "${GITHUB_EVENT_NAME:-}" in
    push)
      if [[ "${GITHUB_REF:-}" != "$EXPECTED_RELEASE_REF" \
          || -n "${GITHUB_HEAD_REF:-}" \
          || -n "${GITHUB_BASE_REF:-}" ]]; then
        echo "Error: candidate push ref must be exactly $EXPECTED_RELEASE_REF." >&2
        exit 1
      fi
      CANDIDATE_COMMIT="$GITHUB_SHA"
      CANDIDATE_EVENT="push"
      ;;
    pull_request)
      if [[ "${GITHUB_HEAD_REF:-}" != "release-candidates/$TAG" \
          || "${GITHUB_BASE_REF:-}" != "main" \
          || ! "${GITHUB_REF:-}" =~ ^refs/pull/[1-9][0-9]*/merge$ \
          || -z "${GITHUB_EVENT_PATH:-}" \
          || ! -f "${GITHUB_EVENT_PATH:-}" ]]; then
        echo "Error: candidate PR must be the exact release branch into main." >&2
        exit 1
      fi
      CANDIDATE_COMMIT=$(python3 - "$GITHUB_EVENT_PATH" "$REPO" \
        "release-candidates/$TAG" <<'PY'
import json
import re
import sys

path, repository, expected_head = sys.argv[1:]
try:
    event = json.load(open(path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot read pull-request event: {error}")
pull = event.get("pull_request")
if not isinstance(pull, dict):
    sys.exit("Error: GitHub event has no pull_request object")
head = pull.get("head") or {}
base = pull.get("base") or {}
if (event.get("repository") or {}).get("full_name") != repository:
    sys.exit("Error: pull-request event repository differs")
if (head.get("repo") or {}).get("full_name") != repository:
    sys.exit("Error: release pull request must come from this repository")
if head.get("ref") != expected_head:
    sys.exit("Error: release pull-request head branch differs")
commit = head.get("sha")
if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
    sys.exit("Error: release pull-request head SHA is invalid")
if (base.get("repo") or {}).get("full_name") != repository or base.get("ref") != "main":
    sys.exit("Error: release pull-request base must be this repository's main")
number = pull.get("number")
if type(number) is not int or number <= 0:
    sys.exit("Error: release pull-request number is invalid")
print(commit)
PY
      )
      CANDIDATE_EVENT="pull_request"
      ;;
    *)
      echo "Error: draft release authorization rejects event ${GITHUB_EVENT_NAME:-missing}." >&2
      exit 1
      ;;
  esac

  RELEASE_TAG="swiftvlc-candidate-${TAG}-${CANDIDATE_COMMIT}"
  RELEASE_REF="refs/swiftvlc-release/$RELEASE_TAG"
  EXPECTED_ASSET_URL="https://github.com/$REPO/releases/download/$RELEASE_TAG/$ASSET_NAME"

  # A final SemVer tag before publication would make this still-draft package
  # selectable by normal SwiftPM clients. Candidate CI treats that as a P0.
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "Error: final SemVer tag $TAG exists before candidate publication." >&2
    exit 1
  fi
  REMOTE_BRANCH_COMMIT=$(git ls-remote origin "$EXPECTED_RELEASE_REF" \
    | awk 'NR == 1 { print $1 }')
  if [[ "$REMOTE_BRANCH_COMMIT" != "$CANDIDATE_COMMIT" ]]; then
    echo "Error: release-candidate branch does not resolve to the authenticated candidate commit." >&2
    exit 1
  fi
fi

temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-artifact.XXXXXX")
trap 'rm -rf "$temp_dir"' EXIT

# Fetch into a private ref rather than installing release tags into the
# checkout. Force is safe for this script-owned ref and lets a retry diagnose a
# moved remote tag instead of silently reading stale local state.
git fetch --quiet --force origin "refs/tags/$RELEASE_TAG:$RELEASE_REF"
TAG_COMMIT=$(git rev-parse "${RELEASE_REF}^{commit}")
if [[ "$ALLOW_DRAFT" == "1" ]]; then
  if [[ "$TAG_COMMIT" != "$CANDIDATE_COMMIT" ]]; then
    echo "Error: candidate tag does not equal the authenticated candidate commit." >&2
    exit 1
  fi
  if [[ "$CANDIDATE_EVENT" == "pull_request" ]]; then
    # actions/checkout intentionally uses a depth-1 synthetic merge checkout;
    # do not depend on parent reachability that the shallow clone omits. The
    # GitHub event authenticates the exact same-repository head SHA/ref, while
    # this complete tree comparison proves the checked merge adds no bytes.
    if ! git diff --quiet "$TAG_COMMIT" "$CHECKOUT_COMMIT" --; then
      echo "Error: pull-request merge checkout does not preserve the exact candidate tree." >&2
      exit 1
    fi
  fi
fi
git show "$RELEASE_REF:Package.swift" > "$temp_dir/Package.swift"
python3 "$SCRIPT_DIR/release-artifact-info.py" \
  "$temp_dir/Package.swift" --expect-tag "$TAG" > "$temp_dir/manifest.json"

gh release view "$RELEASE_TAG" --repo "$REPO" \
  --json tagName,targetCommitish,isDraft,isPrerelease,assets \
  > "$temp_dir/release.json"

EXPECTED_RELEASE_TAG="$RELEASE_TAG" \
EXPECTED_TAG_COMMIT="$TAG_COMMIT" \
EXPECTED_CHECKOUT_COMMIT="$CHECKOUT_COMMIT" \
EXPECTED_CANDIDATE_COMMIT="$CANDIDATE_COMMIT" \
EXPECTED_ASSET_URL="$EXPECTED_ASSET_URL" \
python3 - \
  "$temp_dir/manifest.json" \
  "$temp_dir/release.json" \
  "$ASSET_NAME" \
  "$ALLOW_DRAFT" > "$temp_dir/resolved.json" <<'PY'
import json
import os
import sys

manifest_path, release_path, asset_name, allow_draft = sys.argv[1:5]
manifest = json.load(open(manifest_path))
release = json.load(open(release_path))
release_tag = os.environ["EXPECTED_RELEASE_TAG"]
tag_commit = os.environ["EXPECTED_TAG_COMMIT"]
checkout_commit = os.environ["EXPECTED_CHECKOUT_COMMIT"]
candidate_commit = os.environ["EXPECTED_CANDIDATE_COMMIT"]

if release.get("tagName") != release_tag:
    sys.exit(
        f"Error: GitHub returned release {release.get('tagName')!r}, "
        f"expected {release_tag!r}."
    )
is_draft = release.get("isDraft") is True
if allow_draft == "1":
    if not is_draft:
        sys.exit("Error: candidate authorization may resolve only a draft release.")
    if tag_commit != candidate_commit:
        sys.exit(
            "Error: candidate tag and authenticated release commit differ.\n"
            f"  tag:  {tag_commit}\n"
            f"  head: {candidate_commit}"
        )
    if release.get("targetCommitish") != candidate_commit:
        sys.exit("Error: candidate release target does not equal its authenticated commit.")
else:
    if is_draft:
        sys.exit(f"Error: {manifest['tag']} is still a draft release.")
    if release_tag != manifest["tag"]:
        sys.exit("Error: public release tag does not match Package.swift.")

matches = [asset for asset in release.get("assets", []) if asset.get("name") == asset_name]
if len(matches) != 1:
    sys.exit(
        f"Error: {release_tag} must contain exactly one {asset_name}; "
        f"found {len(matches)}."
    )
asset = matches[0]
expected_digest = f"sha256:{manifest['checksum']}"
if asset.get("digest") != expected_digest:
    sys.exit(
        "Error: release asset digest does not match the tagged Package.swift.\n"
        f"  manifest: {expected_digest}\n"
        f"  asset:    {asset.get('digest')}"
    )
expected_url = os.environ["EXPECTED_ASSET_URL"] or manifest["url"]
if asset.get("url") != expected_url:
    sys.exit(
        "Error: release asset URL does not match its exact release identity.\n"
        f"  expected: {expected_url}\n"
        f"  asset:    {asset.get('url')}"
    )

manifest["downloadTag"] = release_tag
manifest["isPrerelease"] = bool(release.get("isPrerelease"))
manifest["isDraft"] = is_draft
manifest["releaseCommit"] = tag_commit
manifest["size"] = asset.get("size")
print(json.dumps(manifest, sort_keys=True))
PY

cat "$temp_dir/resolved.json"
