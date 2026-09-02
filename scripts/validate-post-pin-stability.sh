#!/usr/bin/env bash
# Compile and run patches 0025/0028's source/native regression gate without
# building libVLC. This deliberately links VLC's JSON grammar/tokeniser,
# json_get_str(), vlc_uri_compose(), and the exact Cast helpers called by
# production, then compiles the actual UPnP wrapper against deterministic
# fake libupnp boundaries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:?usage: validate-post-pin-stability.sh VLC_SOURCE_ROOT [WORK_ROOT]}"
WORK_ROOT="${2:-${SWIFTVLC_VALIDATION_WORK_ROOT:-${TMPDIR:-/tmp}}}"
SOURCE_CHECK="$SCRIPT_DIR/patches/validation/post-pin-stability-source-check.py"
PROBE="$SCRIPT_DIR/patches/validation/post-pin-stability-probe.cpp"
ICONV_SUPPORT="$SCRIPT_DIR/patches/validation/post-pin-stability-iconv.c"
COMPAT="$SCRIPT_DIR/patches/validation/post-pin-stability-compat.h"
UPNP_PROBE="$SCRIPT_DIR/patches/validation/upnp-lifecycle-probe.cpp"
UPNP_FAKES="$SCRIPT_DIR/patches/validation/upnp-lifecycle-fakes"
JSON_DIR="$VLC_SOURCE_ROOT/modules/demux/json"
CAST_DIR="$VLC_SOURCE_ROOT/modules/stream_out/chromecast"
UPNP_DIR="$VLC_SOURCE_ROOT/modules/services_discovery"

for path in \
  "$JSON_DIR/json.c" \
  "$JSON_DIR/json.h" \
  "$JSON_DIR/grammar.y" \
  "$JSON_DIR/lexicon.l" \
  "$CAST_DIR/chromecast_protocol.hpp" \
  "$CAST_DIR/chromecast_demux_duration.hpp" \
  "$UPNP_DIR/upnp-wrapper.cpp" \
  "$UPNP_DIR/upnp-wrapper.hpp" \
  "$VLC_SOURCE_ROOT/src/text/url.c" \
  "$VLC_SOURCE_ROOT/src/text/memstream.c" \
  "$VLC_SOURCE_ROOT/compat/memrchr.c" \
  "$SOURCE_CHECK" \
  "$PROBE" \
  "$ICONV_SUPPORT" \
  "$COMPAT" \
  "$UPNP_PROBE" \
  "$UPNP_FAKES/vlc_common.h" \
  "$UPNP_FAKES/vlc_threads.h" \
  "$UPNP_FAKES/vlc_cxx_helpers.hpp" \
  "$UPNP_FAKES/vlc_charset.h" \
  "$UPNP_FAKES/upnp.h" \
  "$UPNP_FAKES/upnptools.h" \
  "$UPNP_FAKES/TargetConditionals.h"; do
  if [[ ! -f "$path" ]]; then
    echo "Post-pin stability validation input not found: $path" >&2
    exit 1
  fi
done

verify_sha256() {
  local path="$1"
  local expected="$2"
  local description="$3"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Post-pin stability ${description} hash changed: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
}

# This wrapper is artifact-bound by build-libvlc.sh/release.sh. Bind every
# repository-owned checker, compatibility shim, native probe, and fake header
# transitively here so out-of-band edits cannot silently weaken its evidence.
verify_sha256 "$SOURCE_CHECK" \
  "389b89eea8f689953c8ba13110e907895a20f59534e40fed23fc57d916cc0e5a" \
  "source checker"
verify_sha256 "$PROBE" \
  "3532e99172ec40fbe3258ad8a2d76cfdb6fec7a493fd3d5fda3ddcc120b5411a" \
  "linked JSON/Cast probe"
verify_sha256 "$ICONV_SUPPORT" \
  "57bc231664366bdf7058394efe3308a0cc3ce762c3930e34ce3d80f2f0ac3970" \
  "iconv support"
verify_sha256 "$COMPAT" \
  "13c06861628085b804a245f62222388d34b841d763c4cb471952b565b0db089f" \
  "compatibility header"
verify_sha256 "$UPNP_PROBE" \
  "66f15fbbfe15b2d5b56d848b0374368975af18a764dde3e2da443e32e3a12f24" \
  "UPnP lifecycle probe"
verify_sha256 "$UPNP_FAKES/vlc_common.h" \
  "1aca1dee0583759678489317da721a60c718dc684b2cf69c9484b8aab2981389" \
  "UPnP fake vlc_common.h"
verify_sha256 "$UPNP_FAKES/vlc_threads.h" \
  "24e7db5f82108cc04508244d76e9785b097c1a4d7d360fa476bdd83e56f98bab" \
  "UPnP fake vlc_threads.h"
verify_sha256 "$UPNP_FAKES/vlc_cxx_helpers.hpp" \
  "2ddf687baecbcecc2bef68fe22ebd7824113aabae4eb3c4458eb8bd26af85351" \
  "UPnP fake vlc_cxx_helpers.hpp"
verify_sha256 "$UPNP_FAKES/vlc_charset.h" \
  "8eb7a6edea2b70d4976a4dcd9a05c5d8e5a470a7291d77119c1af678d57c0fc9" \
  "UPnP fake vlc_charset.h"
verify_sha256 "$UPNP_FAKES/upnp.h" \
  "c295b26447dddd49b54ea71f1331e84e4298b3c21688830a8394b44cf35755d6" \
  "UPnP fake upnp.h"
verify_sha256 "$UPNP_FAKES/upnptools.h" \
  "67beb72e17a8c567835c6ff2de8cccd61946ae7dc77544b98e450f281626077f" \
  "UPnP fake upnptools.h"
verify_sha256 "$UPNP_FAKES/TargetConditionals.h" \
  "ba4377806a68dd74b0abb044d9ed09e261d72ca589ba8bbfd975a83270b85d88" \
  "UPnP fake TargetConditionals.h"

BISON_BIN="${SWIFTVLC_BISON:-}"
if [[ -z "$BISON_BIN" && -x "$VLC_SOURCE_ROOT/extras/tools/build/bin/bison" ]]; then
  BISON_BIN="$VLC_SOURCE_ROOT/extras/tools/build/bin/bison"
fi
if [[ -z "$BISON_BIN" ]]; then
  BISON_BIN="$(command -v bison || true)"
fi
if [[ -z "$BISON_BIN" ]]; then
  echo "Post-pin stability validation requires bison 3+ (build VLC extras/tools first)" >&2
  exit 1
fi

BISON_MAJOR="$("$BISON_BIN" --version | awk 'NR == 1 { split($NF, version, "."); print version[1] }')"
if [[ ! "$BISON_MAJOR" =~ ^[0-9]+$ || "$BISON_MAJOR" -lt 3 ]]; then
  echo "Post-pin stability validation requires bison 3+; found $("$BISON_BIN" --version | head -n 1)" >&2
  exit 1
fi

FLEX_BIN="${SWIFTVLC_FLEX:-$(command -v flex || true)}"
if [[ -z "$FLEX_BIN" ]]; then
  echo "Post-pin stability validation requires flex" >&2
  exit 1
fi

mkdir -p "$WORK_ROOT"
VALIDATION_DIR=$(mktemp -d "$WORK_ROOT/swiftvlc-post-pin-stability.XXXXXX")
trap 'rm -rf "$VALIDATION_DIR"' EXIT
GENERATED_DIR="$VALIDATION_DIR/generated"
OBJECT_DIR="$VALIDATION_DIR/objects"
mkdir -p "$GENERATED_DIR" "$OBJECT_DIR"

python3 "$SOURCE_CHECK" --self-test
python3 "$SOURCE_CHECK" "$VLC_SOURCE_ROOT"

"$BISON_BIN" \
  --defines="$GENERATED_DIR/grammar.h" \
  --output="$GENERATED_DIR/grammar.c" \
  "$JSON_DIR/grammar.y"
"$FLEX_BIN" \
  --outfile="$GENERATED_DIR/lexicon.c" \
  "$JSON_DIR/lexicon.l"

COMMON_FLAGS=(
  -Wall -Wextra -Werror
  -fdata-sections -ffunction-sections
  -DHAVE_OPEN_MEMSTREAM=1
  -include "$COMPAT"
  -I "$VLC_SOURCE_ROOT/include"
  -I "$VLC_SOURCE_ROOT/src"
  -I "$JSON_DIR"
  -I "$GENERATED_DIR"
  -I "$CAST_DIR"
)

compile_c() {
  local source="$1"
  local output="$2"
  xcrun --sdk macosx clang \
    -std=c11 "${COMMON_FLAGS[@]}" \
    -Wno-sign-compare -Wno-unused-function -Wno-unused-but-set-variable \
    -c "$source" -o "$output"
}

compile_c "$JSON_DIR/json.c" "$OBJECT_DIR/json.o"
compile_c "$GENERATED_DIR/grammar.c" "$OBJECT_DIR/grammar.o"
compile_c "$GENERATED_DIR/lexicon.c" "$OBJECT_DIR/lexicon.o"
compile_c "$ICONV_SUPPORT" "$OBJECT_DIR/iconv-support.o"
compile_c "$VLC_SOURCE_ROOT/src/text/url.c" "$OBJECT_DIR/url.o"
compile_c "$VLC_SOURCE_ROOT/src/text/memstream.c" "$OBJECT_DIR/memstream.o"
compile_c "$VLC_SOURCE_ROOT/compat/memrchr.c" "$OBJECT_DIR/memrchr.o"

xcrun --sdk macosx clang++ \
  -std=c++17 "${COMMON_FLAGS[@]}" \
  -c "$PROBE" -o "$OBJECT_DIR/probe.o"

xcrun --sdk macosx clang++ \
  -Wl,-dead_strip \
  "$OBJECT_DIR/probe.o" \
  "$OBJECT_DIR/json.o" \
  "$OBJECT_DIR/grammar.o" \
  "$OBJECT_DIR/lexicon.o" \
  "$OBJECT_DIR/iconv-support.o" \
  "$OBJECT_DIR/url.o" \
  "$OBJECT_DIR/memstream.o" \
  "$OBJECT_DIR/memrchr.o" \
  -liconv -pthread \
  -o "$VALIDATION_DIR/post-pin-stability-probe"

"$VALIDATION_DIR/post-pin-stability-probe"

# Compile the actual UpnpInstanceWrapper implementation against deterministic
# fake libupnp/VLC boundaries. The fake Finish callback reenters production
# Callback while a concurrent production get() proves teardown serialization.
xcrun --sdk macosx clang++ \
  -std=c++17 -Wall -Wextra -Werror \
  -fdata-sections -ffunction-sections \
  -I "$UPNP_FAKES" \
  -I "$UPNP_DIR" \
  "$UPNP_DIR/upnp-wrapper.cpp" \
  "$UPNP_PROBE" \
  -Wl,-dead_strip \
  -pthread \
  -o "$VALIDATION_DIR/upnp-lifecycle-probe"

"$VALIDATION_DIR/upnp-lifecycle-probe"
