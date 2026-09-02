#!/usr/bin/env bash
set -euo pipefail

SOURCE_SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-build-root-tests.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

expect_failure() {
  local description="$1"
  local expected="$2"
  shift 2
  if "$BUILD_SCRIPT" "$@" > "$temporary_root/failure.log" 2>&1; then
    fail "$description was accepted"
  fi
  grep -Fq -- "$expected" "$temporary_root/failure.log" || {
    cat "$temporary_root/failure.log" >&2
    fail "$description did not produce the expected diagnostic"
  }
}

fixture_repo="$temporary_root/repository"
mkdir -p "$fixture_repo/scripts"
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" "$fixture_repo/scripts/build-libvlc.sh"
git -C "$fixture_repo" init -q
ROOT_DIR=$(cd "$fixture_repo" && pwd -P)
BUILD_SCRIPT="$ROOT_DIR/scripts/build-libvlc.sh"

external_root="$temporary_root/external-root"
mkdir -p "$external_root"
external_root=$(cd "$external_root" && pwd -P)
managed_child="$external_root/swiftvlc-libvlc-build"
lock_directory="$external_root/.swiftvlc-libvlc-build.lock"
marker="$managed_child/.swiftvlc-managed-libvlc-build-v1"
checkout_lock=$(git -C "$ROOT_DIR" rev-parse --git-path swiftvlc-libvlc-output.lock)
case "$checkout_lock" in
  /*) ;;
  *) checkout_lock="$ROOT_DIR/$checkout_lock" ;;
esac

expect_failure \
  "relative external build root" \
  "--build-root must be an absolute directory path" \
  --build-root=relative --clean

expect_failure \
  "empty external build root" \
  "--build-root requires an absolute directory path" \
  --build-root= --clean

expect_failure \
  "missing external build root" \
  "External build root does not exist" \
  --build-root="$temporary_root/missing" --clean

expect_failure \
  "build root inside the checkout" \
  "--build-root must be outside the SwiftVLC checkout" \
  --build-root="$ROOT_DIR" --clean

root_alias="$temporary_root/root-alias"
ln -s "$external_root" "$root_alias"
expect_failure \
  "non-canonical external build root" \
  "--build-root must use its canonical physical path" \
  --build-root="$root_alias" --clean

mkdir -p "$managed_child"
printf 'user data\n' > "$managed_child/keep.txt"
expect_failure \
  "unowned external build directory" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean
[[ -f "$managed_child/keep.txt" ]] || \
  fail "unowned external data was removed"

rm -rf "$managed_child"
mkdir -p "$temporary_root/symlink-target"
printf 'user data\n' > "$temporary_root/symlink-target/keep.txt"
ln -s "$temporary_root/symlink-target" "$managed_child"
expect_failure \
  "symlinked managed build directory" \
  "Refusing symlinked managed build directory" \
  --build-root="$external_root" --clean
[[ -f "$temporary_root/symlink-target/keep.txt" ]] || \
  fail "symlink target data was removed"

rm "$managed_child"
ln -s "$temporary_root/missing-symlink-target" "$managed_child"
expect_failure \
  "dangling managed build-directory symlink" \
  "Refusing symlinked managed build directory" \
  --build-root="$external_root" --clean
rm "$managed_child"

mkdir -p "$managed_child"
printf 'wrong marker\n' > "$marker"
expect_failure \
  "incorrect managed-directory marker" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean

printf 'SwiftVLC managed libVLC build directory v1\n\n' > "$marker"
expect_failure \
  "managed-directory marker with extra bytes" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean

marker_target="$temporary_root/marker-target"
printf 'SwiftVLC managed libVLC build directory v1\n' > "$marker_target"
rm "$marker"
ln -s "$marker_target" "$marker"
expect_failure \
  "symlinked managed-directory marker" \
  "Refusing unowned external build directory" \
  --build-root="$external_root" --clean
rm "$marker"

printf 'SwiftVLC managed libVLC build directory v1\n' > "$marker"
printf 'managed data\n' > "$managed_child/remove.txt"
printf 'sibling data\n' > "$external_root/preserve.txt"
"$BUILD_SCRIPT" --clean --build-root="$external_root" \
  > "$temporary_root/clean.log" 2>&1
[[ ! -e "$managed_child" ]] || fail "managed build child was not removed"
[[ -f "$external_root/preserve.txt" ]] || fail "build-root sibling was removed"
[[ ! -e "$lock_directory" ]] || fail "successful cleanup left its lock behind"
[[ ! -e "$checkout_lock" ]] || fail "successful cleanup left checkout lock behind"

# If another writer replaces the managed directory between removal attempts,
# the second attempt must not inherit the first marker's authorization.
mkdir -p "$managed_child"
printf 'SwiftVLC managed libVLC build directory v1\n' > "$marker"
fake_bin="$temporary_root/fake-bin"
mkdir "$fake_bin"
cat > "$fake_bin/rm" <<'EOF'
#!/bin/bash
set -eu
target="${@: -1}"
if [ ! -e "$SWIFTVLC_RM_RACE_STATE" ] &&
   [ "$target" = "$SWIFTVLC_RM_RACE_TARGET" ]; then
  : > "$SWIFTVLC_RM_RACE_STATE"
  /bin/rm "$@"
  mkdir -p "$target"
  printf 'replacement data\n' > "$target/do-not-delete"
  exit 1
fi
exec /bin/rm "$@"
EOF
chmod +x "$fake_bin/rm"
if PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SWIFTVLC_RM_RACE_STATE="$temporary_root/rm-race-state" \
  SWIFTVLC_RM_RACE_TARGET="$managed_child" \
  "$BUILD_SCRIPT" --build-root="$external_root" --clean \
  > "$temporary_root/rm-race.log" 2>&1; then
  fail "replacement external build directory was deleted on retry"
fi
grep -Fq "Refusing unowned external build directory" \
  "$temporary_root/rm-race.log" || \
  fail "replacement build directory did not fail closed"
[[ -f "$managed_child/do-not-delete" ]] || \
  fail "replacement build-directory data was deleted"
/bin/rm -rf "$managed_child"

mkdir "$lock_directory"
printf 'pid=12345\nhost=test-host\n' > "$lock_directory/owner"
expect_failure \
  "locked external build root" \
  "External build root is locked" \
  --build-root="$external_root" --clean
[[ -f "$lock_directory/owner" ]] || fail "contended lock was modified"
rm "$lock_directory/owner"
rmdir "$lock_directory"

expect_failure \
  "duplicate external build root" \
  "--build-root may be specified only once" \
  --build-root="$external_root" --build-root="$external_root" --clean

expect_failure \
  "unknown option after locking" \
  "Unknown argument '--definitely-unknown'" \
  --build-root="$external_root" --definitely-unknown
[[ ! -e "$lock_directory" ]] || fail "failed invocation left its lock behind"

mkdir "$checkout_lock"
printf 'pid=67890\nhost=test-host\n' > "$checkout_lock/owner"
expect_failure \
  "locked checkout artifact output" \
  "This checkout already has a native build or cleanup in progress" \
  --build-root="$external_root" --clean
[[ ! -e "$lock_directory" ]] || \
  fail "checkout-lock contention left the external-root lock behind"
rm "$checkout_lock/owner"
rmdir "$checkout_lock"

# A normal build acquires the checkout lock before resolving HEAD. This fixture
# intentionally has no commit, so the later provenance preflight fails and
# proves the EXIT trap releases the already-acquired lock.
if "$BUILD_SCRIPT" > "$temporary_root/post-lock-failure.log" 2>&1; then
  fail "commitless build fixture unexpectedly passed"
fi
[[ ! -e "$checkout_lock" ]] || fail "post-lock failure left checkout lock behind"

overlap_root="$temporary_root/overlap-root"
mkdir -p "$overlap_root"
overlap_root=$(cd "$overlap_root" && pwd -P)
overlap_checkout="$overlap_root/swiftvlc-libvlc-build/checkout"
mkdir -p "$overlap_checkout/scripts"
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" \
  "$overlap_checkout/scripts/build-libvlc.sh"
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$overlap_root/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
printf 'preserve checkout\n' > "$overlap_checkout/preserve.txt"
overlap_alias="$temporary_root/overlap-checkout-alias"
ln -s "$overlap_checkout" "$overlap_alias"
if "$overlap_alias/scripts/build-libvlc.sh" \
  --build-root="$overlap_root" --clean \
  > "$temporary_root/overlap.log" 2>&1; then
  fail "managed build directory containing its checkout was accepted"
fi
grep -Fq "external build directory that contains the SwiftVLC checkout" \
  "$temporary_root/overlap.log" || \
  fail "checkout-ancestor rejection did not produce the expected diagnostic"
[[ -f "$overlap_checkout/preserve.txt" ]] || \
  fail "checkout was removed through its logical symlink path"

expect_failure \
  "clean build without external root" \
  "--clean-build requires a canonical external --build-root" \
  --clean-build --all

dirty_repo="$temporary_root/dirty-repository"
mkdir -p "$dirty_repo/scripts"
cp "$SOURCE_SCRIPT_DIR/build-libvlc.sh" "$dirty_repo/scripts/build-libvlc.sh"
git -C "$dirty_repo" init -q
git -C "$dirty_repo" add scripts/build-libvlc.sh
git -C "$dirty_repo" \
  -c user.name=SwiftVLC -c user.email=swiftvlc@example.invalid \
  commit -qm fixture
printf 'untracked input\n' > "$dirty_repo/untracked"
dirty_root="$temporary_root/dirty-external-root"
mkdir -p "$dirty_root/swiftvlc-libvlc-build"
dirty_root=$(cd "$dirty_root" && pwd -P)
printf 'SwiftVLC managed libVLC build directory v1\n' > \
  "$dirty_root/swiftvlc-libvlc-build/.swiftvlc-managed-libvlc-build-v1"
printf 'preserve native cache\n' > \
  "$dirty_root/swiftvlc-libvlc-build/preserve.txt"
if "$dirty_repo/scripts/build-libvlc.sh" \
  --build-root="$dirty_root" --clean-build --all \
  > "$temporary_root/dirty-checkout.log" 2>&1; then
  fail "dirty checkout was accepted for a clean native build"
fi
grep -Fq "requires a clean SwiftVLC checkout" \
  "$temporary_root/dirty-checkout.log" || \
  fail "dirty checkout did not produce the expected diagnostic"
[[ -f "$dirty_root/swiftvlc-libvlc-build/preserve.txt" ]] || \
  fail "clean build deleted its cache before rejecting a dirty checkout"
[[ ! -e "$dirty_root/.swiftvlc-libvlc-build.lock" ]] || \
  fail "dirty-checkout failure left external build lock behind"

help_output=$("$BUILD_SCRIPT" --help)
grep -Fq -- '--build-root=DIR' <<< "$help_output" || \
  fail "help does not document the external build root"

echo "libVLC build-root tests passed."
