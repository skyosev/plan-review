#!/usr/bin/env bash
# The session lock: one flock(2) on <artifact-dir>/.lock, held by the runner and
# inherited by every process it spawns.
#
# Held means work is in progress. Not held means nothing is running, whatever
# round.json says -- and that is the whole point. flock releases only when ALL
# descriptors referring to the open file description are closed, and the
# descriptor bash opens here is not CLOEXEC, so a reviewer that outlives a
# SIGKILLed runner keeps holding it. A pid check cannot answer that: the case it
# exists for is exactly the one where the runner is the process that is gone.
#
# Sourced after lib/paths.sh, which owns every path named in here.
#
# Deleting the lock FILE releases nothing. flock lives on the inode: the orphans
# keep their lock on the old one while the next command creates a fresh one and
# locks that, so both run at once. It is a bypass, not an unlock.

# flock --conflict-exit-code. A bare exit status cannot separate "someone else
# holds this" from "flock could not run", and the two need opposite advice.
PR_LOCK_BUSY=75

# How long a would-be holder waits before refusing. Five seconds is nothing next
# to a review round, and it removes a whole class of spurious refusals: without
# it the doctor's microsecond-long probe could make a concurrent round fail.
PR_LOCK_WAIT_SECS="${PR_LOCK_WAIT_SECS:-5}"

# pr_lock_acquire <lock-path>
#   0   acquired; this process holds it until it exits, and so do its children
#   75  someone else holds it
#   2   operational failure, already reported on stderr
#
# Never released explicitly. The lock's whole job is to outlive an orphaned
# runner, so there is nothing a trap could usefully do here (D6).
pr_lock_acquire() {
  local path="$1"

  # PR_DOCTOR_UTILS does not reach the runner -- pr_doctor_preflight never calls
  # pr_doctor_check_utils -- so the check has to happen here too, before the lock
  # file is created and before anything else has run.
  command -v flock > /dev/null 2>&1 || {
    echo "flock is required to serialise a session, and is not on PATH." >&2
    echo "Debian/Ubuntu: sudo apt install util-linux" >&2
    return 2; }

  # `<>` and not `>`. A `>` redirect truncates at open time, BEFORE flock runs,
  # so a second runner would erase the holder's pid merely by waiting for a lock
  # it never gets, and then have an empty file to report from.
  exec {PR_LOCK_FD}<> "$path" || {
    echo "could not open the session lock: $path" >&2
    return 2; }

  local rc=0
  flock -w "$PR_LOCK_WAIT_SECS" -E "$PR_LOCK_BUSY" "$PR_LOCK_FD" || rc=$?
  case "$rc" in
    0) ;;
    "$PR_LOCK_BUSY") return "$PR_LOCK_BUSY" ;;
    *) echo "could not take the session lock (flock exited $rc): $path" >&2
       return 2 ;;
  esac

  # Only now, and only by the holder. By pathname so the write truncates:
  # through the descriptor it would leave the tail of a longer predecessor.
  printf '%s\n' "$$" > "$path"
  return 0
}

# pr_lock_probe <lock-path>
#   0   free       75  held       2  cannot tell
#
# Takes the lock and drops it again, which is why it uses -n: a probe that waited
# would be a probe that blocked the doctor behind a review round.
pr_lock_probe() {
  local path="$1" fd rc=0
  command -v flock > /dev/null 2>&1 || return 2
  # No lock file, nothing held -- and checking first keeps the doctor from
  # creating one in a session directory it is only reading.
  [[ -e "$path" ]] || return 0
  exec {fd}<> "$path" 2>/dev/null || return 2
  flock -n -E "$PR_LOCK_BUSY" "$fd" || rc=$?
  exec {fd}>&-
  [[ "$rc" -eq 0 || "$rc" -eq "$PR_LOCK_BUSY" ]] || return 2
  return "$rc"
}

# pr_lock_pid <lock-path>
# The pid recorded by whoever took the lock, or nothing. It identifies the
# ORIGINAL holder, not necessarily any surviving one, and nothing branches on
# it: the lock says whether anything is running, this only says who started it.
pr_lock_pid() {
  local pid=""
  [[ -r "$1" ]] && IFS= read -r pid < "$1" 2>/dev/null
  [[ "$pid" =~ ^[0-9]+$ ]] && printf '%s' "$pid"
}

# pr_lock_explain <lock-path> <session-key>
# The second half of a refusal, on stderr: who started this and how to find what
# is still holding it.
#
# It never says "kill <pid>". In the case that matters -- the runner killed,
# orphans still writing -- that process is gone and its number may have been
# reused, so naming it as a target is advice to kill a stranger.
pr_lock_explain() {
  local path="$1" key="$2" pid
  pid="$(pr_lock_pid "$path")"

  if [[ -z "$pid" ]]; then
    echo "  No pid was recorded, so who started it is not known." >&2
  elif kill -0 "$pid" 2> /dev/null; then
    # `kill -0` answers about whatever process holds that number now, which is
    # why this reports what it saw rather than asserting the runner is alive.
    echo "  Started by pid $pid; a process with that number is still running." >&2
    echo "  Wait for it to finish." >&2
    return 0
  else
    echo "  Started by pid $pid, which is no longer running -- reviewer processes it" >&2
    echo "  spawned still hold the session." >&2
  fi

  # ps and grep -F, never pgrep -f: pgrep matches an extended regular expression
  # and pr_plan_slug does not sanitise, so a plan named v1.2+final.md puts a `+`
  # in this path -- where pgrep silently matches nothing and a `[` makes it die.
  # A diagnostic that says "nothing is running" when something is sends the
  # operator to delete the lock file, which is the one thing that corrupts.
  echo "  Wait for them, or list them with:" >&2
  echo "    ps -eo pid=,args= | grep -F '$(pr_session_cache_dir "$key")'" >&2
  echo "  Killing a \`timeout\` process there ends its reviewer. status.jsonl shows" >&2
  echo "  what each reviewer last reported -- as evidence, not as an answer: a" >&2
  echo "  reviewer can read as finished while a descendant still holds the lock." >&2
}

# pr_lock_hold <artifact-dir> <headline>
#   0   held by this process
#   75  someone else holds it; <headline> and the explanation are already on
#       stderr, so the caller only chooses an exit code
#   2   operational failure, already reported
#
# The sequence, not just the primitive. Two halves of it are safety-relevant and
# were previously convention at three call sites: a busy session must always be
# followed by pr_lock_explain, or the refusal is a dead end; and a lock that
# could not be taken for any OTHER reason must never be reported as busy, which
# would send the operator away to wait for something that will never finish.
# Callers keep their own headline and their own exit code -- only the rule is
# shared.
pr_lock_hold() {
  local artifact_dir="$1" headline="$2" lock rc
  lock="$(pr_session_lock "$artifact_dir")"
  pr_lock_acquire "$lock"; rc=$?
  (( rc == PR_LOCK_BUSY )) || return "$rc"

  echo "$headline" >&2
  pr_lock_explain "$lock" "$(pr_artifact_session_key "$artifact_dir")"
  return "$PR_LOCK_BUSY"
}
