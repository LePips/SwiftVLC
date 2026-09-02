#!/usr/bin/env bash
#
# ci-use-released-xcframework.sh — Rewrite Package.swift's libvlc
# binaryTarget to the exact release declared by the checkout (or
# SWIFTVLC_RELEASE_TAG), so CI cannot silently test a different engine because
# GitHub's "latest" pointer excludes pre-releases. A narrowly authorized draft
# is downloaded with gh and rewritten to a verified local Vendor path because
# SwiftPM cannot authenticate its normal binary-target download.
#
# Only the binaryTarget is rewritten; other Package.swift changes on the
# branch (swiftSettings, new targets, platform bumps) are preserved.
#
# Writes `sha` and `tag` to $GITHUB_OUTPUT if that env var is set, so later
# steps can key their caches on the resolved checksum.
#
# Requires: gh (authed via GH_TOKEN / GITHUB_TOKEN), git, python3.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

artifact_info=$("$SCRIPT_DIR/resolve-release-artifact.sh")
tag=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag"])')
download_tag=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; value=json.load(sys.stdin); print(value.get("downloadTag", value["tag"]))')
url=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["url"])')
checksum=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checksum"])')
is_draft=$(printf '%s' "$artifact_info" | python3 -c 'import json,sys; print("true" if json.load(sys.stdin)["isDraft"] else "false")')

if [[ "$is_draft" == true ]]; then
  echo "Installing authenticated draft asset $download_tag for exact-commit CI..." >&2
  "$SCRIPT_DIR/setup-dev.sh" --artifact-only
fi

# Atomic rewrite of only the binaryTarget line.
URL="$url" CHECKSUM="$checksum" IS_DRAFT="$is_draft" python3 - <<'PYEOF'
import os
import re
import sys
import tempfile

url = os.environ["URL"]
checksum = os.environ["CHECKSUM"]
is_draft = os.environ["IS_DRAFT"] == "true"
path = "Package.swift"

with open(path) as f:
    text = f.read()

pattern = r'\.binaryTarget\(\s*name:\s*"libvlc"[^)]*\)'
if is_draft:
    replacement = (
        '.binaryTarget(name: "libvlc", '
        'path: "Vendor/libvlc.xcframework")'
    )
else:
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

if [[ "$is_draft" == true ]]; then
  echo "Pinned Package.swift to authenticated local bytes from draft $tag (checksum=$checksum)" >&2
else
  echo "Pinned Package.swift to $tag (checksum=$checksum)" >&2
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "sha=$checksum"
    echo "tag=$tag"
    echo "download-tag=$download_tag"
  } >> "$GITHUB_OUTPUT"
fi
