#!/usr/bin/env bash
#
# Verifies that the archive members of every libvlc.a slice in
# Vendor/libvlc.xcframework match the manifests checked in under
# scripts/libvlc-manifests/. A rebuilt binary that silently drops or
# gains plugins/objects in one slice shows up as a manifest diff. A semantic
# validator also prevents --write from blessing a rebuild that lost required
# renderer/Chromecast objects (or accidentally added Chromecast to tvOS).
#
# Regenerate a manifest after an intentional rebuild with:
#   ./scripts/check-libvlc-manifest.sh --write
#
# Member lists are computed per architecture (fat archives are thinned
# with lipo first, since `ar t` rejects universal files); each line is
# "<arch> <member>", sorted with LC_ALL=C.

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
xcframework="$repo_root/Vendor/libvlc.xcframework"
manifests="$repo_root/scripts/libvlc-manifests"
feature_validator="$repo_root/scripts/validate_libvlc_feature_contract.py"
write_mode=false

while [ "$#" -gt 0 ]; do
  case "$1" in
    --write)
      write_mode=true
      shift
      ;;
    --xcframework)
      if [ "$#" -lt 2 ]; then
        echo "error: --xcframework requires a path" >&2
        exit 2
      fi
      xcframework=$2
      shift 2
      ;;
    --help|-h)
      echo "Usage: $0 [--write] [--xcframework PATH]"
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ ! -d "$xcframework" ]; then
  echo "error: $xcframework not found — run ./scripts/setup-dev.sh first" >&2
  exit 1
fi

if [ ! -f "$feature_validator" ]; then
  echo "error: $feature_validator not found" >&2
  exit 1
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-libvlc-manifest.XXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# Prints "<arch> <member>" lines for every architecture in the archive,
# sorted bytewise so the output is stable across machines.
list_members() {
  local archive=$1
  local tmpdir
  tmpdir=$(mktemp -d "$scratch/thin.XXXXXX")

  local archs
  archs=$(lipo -archs "$archive")

  local arch thin
  for arch in $archs; do
    if [ "$(echo "$archs" | wc -w)" -gt 1 ]; then
      thin="$tmpdir/$arch.a"
      lipo -thin "$arch" -output "$thin" "$archive"
    else
      thin="$archive"
    fi
    ar t "$thin" | sed "s/^/$arch /"
  done | LC_ALL=C sort

  rm -rf -- "$tmpdir"
}

failures=0
slice_count=0

# Capture and semantically validate every real archive before comparing or
# rewriting any checked-in manifest. This makes --write all-or-nothing with
# respect to the product feature contract.
for slice_dir in "$xcframework"/*/; do
  slice=$(basename "$slice_dir")
  archive="$slice_dir/libvlc.a"
  [ -f "$archive" ] || continue
  slice_count=$((slice_count + 1))
  actual="$scratch/$slice.txt"
  list_members "$archive" > "$actual"

  if ! python3 "$feature_validator" --slice "$slice" --members "$actual"; then
    echo "FAIL  $slice — libvlc feature contract is not satisfied"
    failures=$((failures + 1))
  fi
done

if [ "$slice_count" -eq 0 ]; then
  echo "error: no libvlc.a slices found under $xcframework" >&2
  exit 1
fi

if [ "$failures" -gt 0 ]; then
  echo "libvlc feature-contract check failed ($failures slice(s))"
  exit 1
fi

for actual in "$scratch"/*.txt; do
  slice=$(basename "$actual" .txt)
  manifest="$manifests/$slice.txt"

  if $write_mode; then
    mkdir -p "$manifests"
    cp "$actual" "$manifest"
    echo "WROTE $slice ($(wc -l < "$manifest" | tr -d ' ') members)"
    continue
  fi

  if [ ! -f "$manifest" ]; then
    echo "FAIL  $slice — manifest missing at scripts/libvlc-manifests/$slice.txt"
    failures=$((failures + 1))
    continue
  fi

  if diff -u "$manifest" "$actual"; then
    echo "PASS  $slice"
  else
    echo "FAIL  $slice — archive members differ from checked-in manifest"
    failures=$((failures + 1))
  fi
done

# A manifest with no corresponding slice means the xcframework lost a
# whole platform slice (or the manifest is stale) — fail either way.
if ! $write_mode; then
  for manifest in "$manifests"/*.txt; do
    [ -f "$manifest" ] || continue
    slice=$(basename "$manifest" .txt)
    if [ ! -f "$xcframework/$slice/libvlc.a" ]; then
      echo "FAIL  $slice — manifest exists but slice is absent from the xcframework"
      failures=$((failures + 1))
    fi
  done

  if [ "$failures" -gt 0 ]; then
    echo "libvlc manifest check failed ($failures problem(s))"
    exit 1
  fi
  echo "libvlc manifest check passed"
fi
