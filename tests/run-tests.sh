#!/usr/bin/env bash
# Runs every tests/test-*.sh. Exits non-zero if any file fails.
set -uo pipefail
shopt -s nullglob   # an unmatched glob must run zero files, not one literal one
cd "$(dirname "${BASH_SOURCE[0]}")/.."

failed=0
for f in tests/test-*.sh; do
  bash "$f" || failed=1
done

if [[ "$failed" -ne 0 ]]; then
  echo "SUITE FAILED" >&2
  exit 1
fi
echo "SUITE PASSED"
