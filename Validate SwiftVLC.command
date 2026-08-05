#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
set +e
"$ROOT_DIR/scripts/qualification/volunteer-validation.sh" "$@"
status=$?
set -e

if [[ -t 0 && -n "${TERM_PROGRAM:-}" ]]; then
  echo
  printf "Press Return to close this window: "
  read -r _
fi
exit "$status"
