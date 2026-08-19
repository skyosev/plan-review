#!/usr/bin/env bash
# Dies politely on TERM and leaves a grandchild that does not.
#
# This is the shape `timeout --kill-after` cannot handle: it reaps the direct
# child at once, exits 124, and never delivers the deferred SIGKILL to the
# group. fake-slow-with-child.sh does NOT cover it -- its child takes the
# default TERM action, so the group dies on the first signal.
set -uo pipefail
workdir="$1"
cat > /dev/null
pidfile="${PR_TEST_CHILD_PIDFILE:-$workdir/child.pid}"
( trap '' TERM; sleep 300 ) &
echo $! > "$pidfile"
# `sleep & wait` rather than a bare `sleep`: bash runs a trap only between
# commands, so a foreground sleep would swallow the signal for its full 300s.
trap 'exit 0' TERM
sleep 300 &
wait
