#!/usr/bin/env bash
# Adapter-shaped escaper: writes a normal review, then leaves a grandchild that
# has taken its own SESSION (a real setsid, not merely setpgid) -- the shape P6
# measured agent's tool layer producing
# (docs/process/probes/2026-08-26-roster-sweep-reach/). The group sweep cannot
# address it; only the descendant sweep can. The trailing sleep keeps this
# adapter alive long enough that the kernel's poller has sampled the escaper --
# the sweep is best-effort against a fork-and-detach racing the sampler, and
# this fixture tests reach, not the race.
set -uo pipefail
workdir="$1"; review="$3"; meta="$4"
cat > /dev/null
printf 'sess-esc\nmodel-esc\neffort-esc\ncli-esc\n' > "$meta"
echo "review from escaper" > "$review"
setsid bash -c 'trap "" TERM; exec sleep 300' &
echo $! > "$workdir/escaper.pid"
sleep 1
exit 0
