#!/usr/bin/env bash
# fake-escaper.sh plus one extra fact: an EXIT-PHASE MARKER. Same escaper --
# a grandchild that has taken its own session, the shape P6 measured agent's
# tool layer producing (docs/process/probes/2026-08-26-roster-sweep-reach/) --
# but the last act before `exit 0` is `: > "$workdir/exiting"`.
#
# The marker exists so a stub `ps` can behave NORMALLY while this adapter lives
# and hang only from its exit onward. That is the only way to steer a hung `ps`
# into the kernel's post-`wait` sweep deterministically: an always-hanging stub
# never lets the poller build a table, so the escaper is never REMEMBERED, and
# a sweep with nothing remembered reads nothing and proves nothing.
set -uo pipefail
workdir="$1"; review="$3"; meta="$4"
cat > /dev/null
printf 'sess-esc\nmodel-esc\neffort-esc\ncli-esc\n' > "$meta"
echo "review from escaper" > "$review"
setsid bash -c 'trap "" TERM; exec sleep 300' &
echo $! > "$workdir/escaper.pid"
sleep 1
# LAST, deliberately: everything above must have run under a working ps.
: > "$workdir/exiting"
exit 0
