#!/usr/bin/env bash
# Succeeds AND has something to explain: the model was swapped mid-run. An `ok`
# round with a reason is the case a failure-only channel would lose.
set -euo pipefail
workdir="$1"; review_out="$3"; meta_out="$4"; reason_out="${5:-}"
cat > /dev/null

{
  echo "# Review from fake-ok-with-reason"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"

printf '%s\n%s\n%s\n%s\n' \
  "fake-session-$(basename "$workdir")" fake-model-swapped "" fake-cli-9.9 \
  > "$meta_out"

[[ -n "$reason_out" ]] && echo "switched to fake-model-swapped mid-run" > "$reason_out"
exit 0
