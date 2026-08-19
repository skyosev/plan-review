#!/usr/bin/env bash
# Holds the session lock until <release-file> is deleted.
#
# Usage: hold-lock.sh <lock-file> <release-file>
#
# It records its own pid in the lock file exactly as lib/lock.sh does, so a
# refusal built from that file has something real to report. `<>` and not `>`:
# a truncating open would erase the pid before flock ever ran.
#
# Deliberately NOT `source lib/lock.sh; pr_lock_acquire`. This is the oracle the
# lock tests check the real implementation against -- test-lock.sh asserts that a
# waiter does not truncate the pid this fixture wrote. Sourcing the code under
# test would make that assertion true by construction.
set -uo pipefail
lock="$1" release="$2"
exec {fd}<> "$lock" || exit 2
flock "$fd" || exit 2
printf '%s\n' "$$" > "$lock"
: > "$release.held"
while [[ -e "$release" ]]; do sleep 0.05; done
