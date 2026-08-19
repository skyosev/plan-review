#!/usr/bin/env bash
# Finalises a round nothing is working on, so the next round may start.
#
# Usage: plan-review abort --round <absolute-round-directory>
#
# It deletes nothing -- not the round directory, not the sandboxes. A round is
# aborted precisely when something went wrong, which is when its artifacts are
# most worth reading.
#
# There is no --force. Aborting under a live session would leave reviewer
# processes writing reviews into a round already marked `aborted`, and
# pr_round_can_start would then let the next round start on top of them. The
# operator already has `kill`; this command's contract stays one sentence.

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/lock.sh"
source "$PR_ROOT/lib/round.sh"

round_dir="$(pr_round_arg_dir "$@")" || exit 2

# Read BEFORE the lock, and only ever to authorise a refusal or a no-op. The lock
# is per session and this command names a round: re-aborting round 3 must not be
# refused because round 4 legitimately holds the session. An operator repeating a
# command that already succeeded should not be told no.
case "$(pr_round_state "$round_dir")" in
  aborted)  exit 0 ;;
  complete) echo "round is 'complete'; reopening it as aborted would discard the record that it finished" >&2
            exit 1 ;;
esac

pr_lock_hold "$(pr_round_artifact_dir "$round_dir")" \
  "this round's session is locked; a review is still running." ; lock_rc=$?
(( lock_rc == 0 )) || exit $(( lock_rc == PR_LOCK_BUSY ? 1 : 2 ))

# Re-read, now that this process has the right to act on what it reads. One read
# before the lock could only ever justify doing nothing.
state="$(pr_round_state "$round_dir")"
case "$state" in
  reviewing|awaiting_integration) ;;
  aborted) exit 0 ;;
  *) echo "round is '$state', not a round that can be aborted" >&2; exit 1 ;;
esac

pr_round_set_state "$round_dir" aborted || exit 2
echo "Round aborted: $round_dir"
