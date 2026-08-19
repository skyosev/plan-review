#!/usr/bin/env bash
# Hangs, and spawns a long-lived grandchild that must also be reaped.
#
# It records the grandchild's PID immediately. A marker file written by the
# grandchild would be useless: it only appears long after the test ends, so its
# absence is guaranteed whether or not the grandchild survived. The test must
# check the PID with `kill -0` instead.
set -uo pipefail
workdir="$1"
cat > /dev/null
pidfile="${PR_TEST_CHILD_PIDFILE:-$workdir/child.pid}"
( sleep 300 ) &
echo $! > "$pidfile"
sleep 300
exit 0
