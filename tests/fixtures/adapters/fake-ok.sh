#!/usr/bin/env bash
# Succeeds: writes a review with a valid verdict and a session id.
set -euo pipefail
workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"
prompt="$(cat)"

{
  echo "# Review from fake-ok"
  echo "workdir=$workdir"
  echo "resumed_from=${session_in:-NONE}"
  echo "prompt_bytes=${#prompt}"
  echo "tmpdir=${TMPDIR:-UNSET}"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts, src/b.ts -->"
} > "$review_out"

printf '%s\n%s\n%s\n%s\n' \
  "fake-session-$(basename "$workdir")" fake-model-1 fake-effort-high fake-cli-9.9 \
  > "$meta_out"
exit 0
