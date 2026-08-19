#!/usr/bin/env bash
# Succeeds, and writes the prompt it was given into the review. Exists so a test
# can assert what a reviewer actually received rather than what the runner meant
# to send -- the assembled prompt is deleted with the round's scratch files.
set -euo pipefail
workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

{
  echo "# Review from fake-echo-prompt"
  echo '--- prompt begins ---'
  cat
  echo '--- prompt ends ---'
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"

printf '%s\n%s\n%s\n%s\n' \
  "fake-session-$(basename "$workdir")" fake-model-echo "" fake-cli-9.9 \
  > "$meta_out"
exit 0
