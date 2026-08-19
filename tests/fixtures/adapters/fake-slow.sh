#!/usr/bin/env bash
# Hangs until PR_TEST_HOLD is deleted, recording its own pid first.
#
# The pid is written by the adapter itself rather than discovered with pgrep:
# a pattern search matches the test's own wrapping shells too, and the sandbox
# paths these tests build are not safe as regular expressions.
set -uo pipefail
workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"
cat > /dev/null
[[ -n "${PR_TEST_ADAPTER_PIDFILE:-}" ]] && echo $$ > "$PR_TEST_ADAPTER_PIDFILE"
while [[ -e "${PR_TEST_HOLD:-/nonexistent}" ]]; do sleep 0.05; done
{
  echo "# Review from fake-slow"
  echo "<!-- VERDICT: MINOR -->"
} > "$review_out"
printf '%s\n%s\n%s\n%s\n' fake-session-slow fake-model-1 fake-effort-high fake-cli-9.9 \
  > "$meta_out"
exit 0
