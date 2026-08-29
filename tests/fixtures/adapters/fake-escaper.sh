#!/usr/bin/env bash
# Adapter-shaped escaper: writes a normal review, then leaves a grandchild that
# has taken its own SESSION (a real setsid(2), not merely setpgid) -- the shape P6
# measured agent's tool layer producing
# (docs/process/probes/2026-08-26-roster-sweep-reach/). The group sweep cannot
# address it; only the descendant sweep can. The trailing sleep keeps this
# adapter alive long enough that the kernel's poller has sampled the escaper --
# the sweep is best-effort against a fork-and-detach racing the sampler, and
# this fixture tests reach, not the race.
#
# It also stamps an EXIT-PHASE MARKER, `exiting`, as its last act. That lets a
# stub `ps` behave NORMALLY while this adapter lives and hang only from its
# exit onward -- the only way to steer a hung `ps` into the kernel's post-`wait`
# sweep deterministically, since an always-hanging stub never lets the poller
# build a table, so the escaper is never REMEMBERED and a sweep with nothing
# remembered reads nothing and proves nothing. Inert for the cases that do not
# stub `ps`: they read `escaper.pid` and never look at the marker.
set -uo pipefail
workdir="$1"; review="$3"; meta="$4"
cat > /dev/null
printf 'sess-esc\nmodel-esc\neffort-esc\ncli-esc\n' > "$meta"
echo "review from escaper" > "$review"
# ../bin/pr-setsid, not `setsid`: util-linux's is absent on macOS and the shim
# falls back to POSIX::setsid(2), which Darwin does have. Resolved from $0
# because adapter fixtures are standalone by contract and get no PR_ROOT. It
# must not fork -- $! below has to name the escaper itself; the shim's header
# says why.
"$(cd "$(dirname "$0")/../bin" && pwd)/pr-setsid" bash -c 'trap "" TERM; exec sleep 300' &
echo $! > "$workdir/escaper.pid"
sleep 1
# LAST, deliberately: everything above must have run under a working ps.
: > "$workdir/exiting"
exit 0
