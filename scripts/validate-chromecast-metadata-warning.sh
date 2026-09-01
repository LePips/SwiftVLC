#!/usr/bin/env bash
# Audited source/mutation proof for VLC patch 0035.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:-}"

if [[ -z "$VLC_SOURCE_ROOT" || ! -d "$VLC_SOURCE_ROOT" ]]; then
    echo "Usage: $0 <patched-vlc-source>" >&2
    exit 2
fi
VLC_SOURCE_ROOT="$(cd "$VLC_SOURCE_ROOT" && pwd)"

CHECKER="$SCRIPT_DIR/patches/validation/chromecast-metadata-warning-source-check.py"
PATCH="$SCRIPT_DIR/patches/0035-chromecast-metadata-warning.patch"
EXPECTED_CHECKER_SHA=155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc
EXPECTED_PATCH_SHA=e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d

for path in "$CHECKER" "$PATCH"; do
    if [[ ! -f "$path" ]]; then
        echo "Chromecast 0035 validation input not found: $path" >&2
        exit 1
    fi
done

actual_checker_sha="$(shasum -a 256 "$CHECKER" | awk '{print $1}')"
actual_patch_sha="$(shasum -a 256 "$PATCH" | awk '{print $1}')"
if [[ "$actual_checker_sha" != "$EXPECTED_CHECKER_SHA" ]]; then
    echo "Chromecast 0035 source checker hash mismatch: expected $EXPECTED_CHECKER_SHA, got $actual_checker_sha" >&2
    exit 1
fi
if [[ "$actual_patch_sha" != "$EXPECTED_PATCH_SHA" ]]; then
    echo "Chromecast 0035 patch hash mismatch: expected $EXPECTED_PATCH_SHA, got $actual_patch_sha" >&2
    exit 1
fi

python3 "$CHECKER" "$VLC_SOURCE_ROOT" "$PATCH"
echo "PASS Chromecast 0035 validation: checker_sha=$actual_checker_sha patch_sha=$actual_patch_sha"
