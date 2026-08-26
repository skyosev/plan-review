#!/usr/bin/env bash
# Succeeds immediately but leaves a TERM-ignoring child in its process group.
#
# Exists to pin the kernel's UNCONDITIONAL sweep: `timeout --kill-after` never
# fires for an adapter that exits cleanly, so without the sweep this child
# would outlive the round and could keep appending to artifacts the caller has
# already read. fake-term-handling-with-child.sh does NOT cover it -- its
# leak is only reachable through a timeout.
set -uo pipefail
workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"
cat > /dev/null
( trap '' TERM; sleep 300 ) &
echo $! > "${PR_TEST_CHILD_PIDFILE:-$workdir/child.pid}"
{
  echo "# Review from fake-ok-leaves-child"
  echo "<!-- VERDICT: MINOR -->"
  echo "<!-- FILES-INSPECTED: src/a.ts -->"
} > "$review_out"
printf '%s\n%s\n%s\n%s\n' fake-session-leak fake-model-1 "" fake-cli-9.9 > "$meta_out"
exit 0
