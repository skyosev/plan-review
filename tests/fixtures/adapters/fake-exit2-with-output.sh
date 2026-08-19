#!/usr/bin/env bash
# The Cursor case: correct output, non-zero exit from a denied tool call.
set -uo pipefail
review_out="$3"; meta_out="$4"
cat > /dev/null
{
  echo "# Review despite exit 2"
  echo "<!-- VERDICT: BLOCKING -->"
  echo "<!-- FILES-INSPECTED: src/c.ts -->"
} > "$review_out"
printf '%s\n%s\n%s\n%s\n' fake-session-exit2 fake-model-2 "" fake-cli-2.0 > "$meta_out"
exit 2
