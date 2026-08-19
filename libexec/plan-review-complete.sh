#!/usr/bin/env bash
# Marks a round complete after the Integrator has written its rationale files.
#
# Usage: plan-review complete --round <absolute-round-directory>
#
# Takes an absolute directory rather than assuming a working directory: the
# caller is an interactive session sitting in the target repo root, not in the
# round directory.

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/lock.sh"
source "$PR_ROOT/lib/round.sh"

round_dir="$(pr_round_arg_dir "$@")" || exit 2

# Read BEFORE the lock, and only ever to authorise a no-op. Same rule abort
# follows: one read is never enough to justify a write.
case "$(pr_round_state "$round_dir")" in
  complete) exit 0 ;;   # already done; re-running is harmless
esac

# `abort` is a second writer of this file, and without the lock the two race:
# complete reads awaiting_integration, abort writes aborted, complete writes
# complete over it -- moving a round out of a state that is meant to be terminal.
#
# Normally the lock is free by the time this runs; the runner writes
# awaiting_integration and exits moments later. It can still block, on those few
# lines or on a reviewer that outlived the runner, in which case this waits and
# then refuses. That is the same trade the lock makes everywhere else.
pr_lock_hold "$(pr_round_artifact_dir "$round_dir")" \
  "this round's session is locked; a review is still running." ; lock_rc=$?
(( lock_rc == 0 )) || exit $(( lock_rc == PR_LOCK_BUSY ? 1 : 2 ))

# The half that matters. Locking alone would leave this acting on a state it
# observed before it had any right to.
state="$(pr_round_state "$round_dir")"
case "$state" in
  complete)              exit 0 ;;
  awaiting_integration)  ;;
  *) echo "round is '$state', not awaiting_integration — nothing to complete" >&2
     exit 1 ;;
esac

# Every reviewer that produced a usable review is owed a reply. A reviewer that
# failed said nothing, so there is nothing to respond to.
missing=()
while read -r reviewer; do
  [[ -n "$reviewer" ]] || continue
  [[ -s "$round_dir/rationale-$reviewer.md" ]] || missing+=("$reviewer")
done < <(jq -r '.reviewers | to_entries[] | select(.value.status == "ok") | .key' \
           < "$round_dir/round.json")

if [[ "${#missing[@]}" -gt 0 ]]; then
  echo "cannot complete: no rationale written for: ${missing[*]}" >&2
  for reviewer in "${missing[@]}"; do
    echo "  expected: $round_dir/rationale-$reviewer.md" >&2
  done
  exit 1
fi

pr_round_set_state "$round_dir" complete
echo "Round complete: $round_dir"
