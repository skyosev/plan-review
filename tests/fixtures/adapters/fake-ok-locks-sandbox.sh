#!/usr/bin/env bash
# Succeeds, then makes its own sandbox directory unwritable so the round's
# discard cannot remove the repo copy. Exists to prove that failing to clean up
# does not fail the round.
set -euo pipefail
workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"
cat > /dev/null
{
  echo "# Review from fake-ok-locks-sandbox"
  echo "<!-- VERDICT: MINOR -->"
} > "$review_out"
printf '%s\n%s\n%s\n%s\n' fake-session-locked fake-model-1 fake-effort-high fake-cli-9.9 \
  > "$meta_out"
chmod 555 "$(dirname "$workdir")"
exit 0
