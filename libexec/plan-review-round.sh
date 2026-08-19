#!/usr/bin/env bash
# Runs one review round. Invoked by the Author harness, never by a reviewer.
#
# Usage:
#   plan-review round --repo <target-repo> --plan <repo-relative-plan.md> \
#                     [--fresh] [--preset <name>]
#
# Environment:
#   PR_ORCHESTRATOR  REQUIRED. The CLI running this, or `none` when a human is.
#                    Recorded in round.json as the only answer to "who drove this
#                    round". With no config, the roster is also derived from it:
#                    the shipped adapters minus this one.
#   PR_KEEP_SANDBOX=1  keep every reviewer's repo copy after the round. Normally
#                    a copy is discarded when that reviewer finished cleanly, on
#                    time and with exit 0; anything else keeps it to look at.
#
# Project configuration (lib/config.sh), all optional:
#   PR_CONFIG        use this config file instead of <repo>/.plan-review/config.json
#   PR_SKIP_CONFIG=1 ignore any config entirely
#   PR_PRESET        select a preset; --preset is the same thing, typed per run
#
# Overrides (used by tests):
#   PR_CACHE_ROOT    sandbox root                 (default ~/.cache/plan-review)
#   PR_ADAPTER_MAP   space-separated reviewer=adapter-path pairs; outranks the
#                    config's reviewer list and the derived default
#   PR_TIMEOUT_SECS  per-reviewer timeout         (default 900)
#   PR_LOCK_WAIT_SECS  how long to wait for the session lock (default 5)
#
# Model and effort pins, read by the adapters. Values pass through verbatim to
# each CLI: there is no portable effort enum, because the three vocabularies do
# not line up. Codex treats effort as a separate axis reaching `xhigh`; Cursor and
# agy fold it into the model id, with different tiers available per model.
#   PR_CODEX_MODEL   optional; codex reports the effective model either way
#   PR_CODEX_EFFORT  optional; codex's own axis. The backend accepts none, minimal,
#                    low, medium, high, xhigh, max -- an invalid value is a 400.
#   PR_AGENT_MODEL   REQUIRED; a full Cursor id, effort included
#                    (e.g. claude-opus-5-thinking-high). `agent --list-models`.
#   PR_AGY_MODEL     REQUIRED once Task 0 clears agy; a full agy id, effort
#                    included (e.g. gemini-3.1-pro-high). `agy models`.

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/verdict.sh"
source "$PR_ROOT/lib/status.sh"
source "$PR_ROOT/lib/lock.sh"
source "$PR_ROOT/lib/sandbox.sh"
source "$PR_ROOT/lib/prompt.sh"
source "$PR_ROOT/lib/round.sh"
source "$PR_ROOT/lib/session.sh"
source "$PR_ROOT/lib/doctor.sh"
source "$PR_ROOT/lib/roster.sh"
source "$PR_ROOT/lib/config.sh"

PR_TIMEOUT_SECS="${PR_TIMEOUT_SECS:-900}"
PR_KILL_GRACE_SECS="${PR_KILL_GRACE_SECS:-15}"

repo="" plan_rel="" fresh=0 preset=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)   repo="$2"; shift 2 ;;
    --plan)   plan_rel="$2"; shift 2 ;;
    --fresh)  fresh=1; shift ;;
    --preset) preset="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$repo" && -n "$plan_rel" ]] || { echo "usage: --repo <dir> --plan <rel.md>" >&2; exit 2; }
repo="$(cd "$repo" && pwd)"
[[ -f "$repo/$plan_rel" ]] || { echo "no such plan: $repo/$plan_rel" >&2; exit 2; }

# pr_plan_slug rejects '..' syntactically; symlinks need the filesystem. Resolve
# and re-check containment, or a plan outside the repo would be reviewed against
# the wrong tree and write artifacts into a directory that does not describe it.
if ! pr_path_resolve_within "$repo" "$repo/$plan_rel" plan_abs repo_abs; then
  echo "plan resolves outside the repository: $plan_abs not under $repo_abs" >&2
  exit 2
fi
plan_rel="${plan_abs#"$repo_abs"/}"

# Who drove the round. Required with or without a config: a reviewer list says
# who reviewed and nothing about who read the reviews, and round.json cannot
# answer that afterwards without this field.
orchestrator="$(pr_roster_orchestrator)" || exit 2

# The config resolves into the PR_*_MODEL / PR_*_EFFORT variables the adapters
# read, so everything below this line -- preflight included -- sees pins without
# knowing where they came from. Before the artifact directory exists, so a
# config this refuses leaves no round behind.
pr_config_resolve "$repo" "$preset" || exit 2

# On the resolved value, whatever its source. An env pin outranks the config, so
# a stale PR_CODEX_EFFORT is the likeliest way a bad tier reaches a backend --
# and it is the one path a check over the config file alone would miss.
pr_config_check_efforts || exit 2

# PR_ADAPTER_MAP, then the config's reviewer list, then the shipped adapters
# minus the orchestrator. A list that names the orchestrator's own CLI is obeyed
# exactly -- see "The exclusion rule, removed" in the process notes (2026-08-17,
# project config).
adapter_map="$(pr_roster_resolve_map "$orchestrator" "$PR_CONFIG_REVIEWERS")"

# Preflight: the offline half of the doctor, for the roster this round will
# actually run. Deliberately here -- after the map resolves, before the artifact
# directory exists -- so a machine that cannot run a reviewer leaves no round
# behind. Silent when everything passes.
#
# What this buys over letting the adapters fail: an adapter that exits on a
# missing bwrap or an unset pin does so *after* the sandbox copy and the session
# bookkeeping, and a failed reviewer forfeits its resume handle. The dependency
# was knowable in milliseconds.
if [[ "${PR_SKIP_PREFLIGHT:-0}" != 1 ]]; then
  if ! pr_doctor_preflight "$adapter_map"; then
    echo "preflight failed; no round was started." >&2
    echo "Run plan-review doctor for the full diagnosis," >&2
    echo "or set PR_SKIP_PREFLIGHT=1 to run anyway." >&2
    exit 2
  fi
fi

session_key="$(pr_session_key "$repo" "$plan_rel")" || exit 2
artifact_dir="$(pr_artifact_dir "$repo" "$session_key")"
session_map="$artifact_dir/session-map.json"
mkdir -p "$artifact_dir"

# The session lock, before anything is read or decided. Round selection below is
# a read-then-create with no atomicity of its own: two invocations can both
# compute round 4, both mkdir it and overwrite each other's snapshots. Inside the
# lock they cannot.
#
# It also answers the question round.json cannot. `state: reviewing` is a fact
# about the work, written once; the lock is a fact about right now, and it is
# held by every process the runner spawned, so it stays held while an orphan is
# still writing into the round.
# Busy and broken both exit 2 here, matching every other pre-start refusal in
# this file; they stay distinguishable by what pr_lock_hold printed.
pr_lock_hold "$artifact_dir" "a review of $plan_rel is already running." || exit 2

# Round numbering is monotonic and never reused, including after --fresh.
# --fresh means "drop the resume handles AND build the prompt with no history",
# not "delete history": US-11 promises every prior round stays readable. The
# baseline is recorded as `fresh: true` inside round.json, not by renumbering.
# Both halves matter -- clearing the handle alone would leave pr_build_prompt to
# re-inject the diff, critique and rationale the reset was meant to shed.
highest_round="$(pr_round_highest "$artifact_dir")"
round=$((highest_round + 1))

# Refuse to start a round unless the previous one is finished. pr_round_can_start
# owns the rule; the doctor reports on the same predicate so the two can never
# disagree about which rounds are blocked.
if [[ "$highest_round" -gt 0 ]]; then
  prev_dir_guard="$(pr_round_dir "$artifact_dir" "$highest_round")"
  prev_state="$(pr_round_state "$prev_dir_guard")"
  if ! pr_round_can_start "$prev_state"; then
    case "$prev_state" in
      awaiting_integration)
        echo "round $highest_round is awaiting_integration: write the rationale files," >&2
        echo "then run plan-review complete --round $prev_dir_guard" >&2 ;;
      *)
        # This runner holds the session lock, so it can say more than the doctor
        # can: nothing from that round survived, or the lock would not be here.
        echo "round $highest_round is in state '$prev_state' and cannot be left behind." >&2
        echo "Nothing is running; its runner did not finish." >&2
        echo "Inspect $prev_dir_guard, then:" >&2
        echo "  plan-review abort --round $prev_dir_guard" >&2 ;;
    esac
    exit 2
  fi
fi

# Only after the guard: a refused --fresh must not have already destroyed the
# handles it was going to reset.
[[ "$fresh" -eq 1 ]] && pr_session_clear "$session_map"

round_dir="$(pr_round_dir "$artifact_dir" "$round")"
mkdir -p "$round_dir"
status_file="$round_dir/status.jsonl"
pr_status_init "$status_file"

fresh_flag="$([[ "$fresh" -eq 1 ]] && echo true || echo false)"

# The criteria are copied once, here, and every prompt below is built from the
# copy. Copy first, hash the copies, prompt from the copies: hashing the source
# and then re-reading it per reviewer leaves a window in which the hash, the
# snapshot and the text two reviewers received are three different things, and
# the source is a working file the operator edits between rounds.
#
# Both slots are copied, not only the one this round reads, because the hash
# covers both -- round 1 reads `initial` and round 2 reads `rereview`, so a hash
# over one slot would differ between them by construction and report drift on
# every second round.
criteria_initial="" criteria_rereview=""
if [[ -n "$PR_CONFIG_CRITERIA_INITIAL" ]]; then
  criteria_initial="$round_dir/criteria-initial.snapshot.md"
  cp "$PR_CONFIG_CRITERIA_INITIAL" "$criteria_initial"
fi
if [[ -n "$PR_CONFIG_CRITERIA_REREVIEW" ]]; then
  criteria_rereview="$round_dir/criteria-rereview.snapshot.md"
  cp "$PR_CONFIG_CRITERIA_REREVIEW" "$criteria_rereview"
fi
# Validation read the source, earlier and elsewhere. This is the copy actually
# being sent, so it is the copy that has to be non-empty. The round directory
# goes with the refusal: a directory with no round.json in it blocks every later
# round, which is a worse outcome than the race it came from.
for f in "$criteria_initial" "$criteria_rereview"; do
  [[ -n "$f" && ! -s "$f" ]] || continue
  echo "criteria file could not be copied, or became empty: $f" >&2
  rm -rf "$round_dir"
  exit 2
done

reviewer_keys="$(pr_roster_keys "$adapter_map")"
config_sha="$(pr_config_hash "$reviewer_keys" "$criteria_initial" "$criteria_rereview")"

pr_round_init "$round_dir" "$round" "$repo" "$plan_rel" \
  "$fresh_flag" "$orchestrator" "$(pr_config_record "$config_sha")"

cp "$repo/$plan_rel" "$round_dir/plan.snapshot.md"
prev_dir="$(pr_round_dir "$artifact_dir" $((round - 1)))"
if [[ "$round" -gt 1 && -f "$prev_dir/plan.snapshot.md" ]]; then
  diff -u "$prev_dir/plan.snapshot.md" "$round_dir/plan.snapshot.md" \
    > "$round_dir/plan.diff" || true
fi

# Drift: this round's settings against the previous round's. History rounds only
# (D15). A --fresh round has no carried-over context to be inconsistent with, so
# the warning there would be noise. It never blocks -- the round still runs.
if [[ "$round" -gt 1 && "$fresh" -ne 1 && -f "$prev_dir/round.json" ]]; then
  prev_sha="$(jq -r '.config.sha256 // ""' < "$prev_dir/round.json" 2>/dev/null)"
  if [[ -n "$prev_sha" && "$prev_sha" != "$config_sha" ]]; then
    drift_warning="configuration changed since round $((round - 1)); resumed sessions carry context built under the old settings — consider --fresh"
    echo "warning: $drift_warning" >&2
    pr_round_add_warning "$round_dir" "$drift_warning"
  fi
fi

# --- child-to-parent result records -----------------------------------------
# JSON, not a delimited line. The first attempt was tab-separated and read back
# with `IFS=$'\t' read`, which is silently wrong: tab is IFS *whitespace*, so a
# run of tabs collapses into one delimiter and an empty field — the normal case,
# since `detail` is empty on success — shifts every later field left by one. The
# verdict lands in `detail`, the session id in `verdict`, and the last variable
# comes back empty. jq has no delimiter to get wrong.
write_result() {
  local reviewer="$1"
  jq -n --arg status "$2" --arg detail "$3" --arg verdict "$4" \
        --arg session "$5" --arg model "$6" --arg effort "$7" --arg cli "$8" \
        --argjson discard "${9:-false}" \
        '{$status, $detail, $verdict, $session, $model, $effort, $cli, $discard}' \
    > "$round_dir/.result-$reviewer"
}

# read_result <reviewer> <status-var> <session-var> <discard-var>
# The only values the parent branches on, in one jq rather than one each.
#
# `discard` is read as "true or nothing". A truncated or unparseable record
# leaves every variable empty, which means keep -- the safe direction, since the
# copy exists to be looked at when something went wrong.
read_result() {
  local -n _status="$2" _session="$3" _discard="$4"
  # Cleared first: `read` leaves a variable alone when it has nothing to read,
  # and these are reused across the loop, so an unreadable record would silently
  # inherit the previous reviewer's answer.
  _status="" _session="" _discard=""
  { IFS= read -r _status; IFS= read -r _session; IFS= read -r _discard; } < <(
    jq -r '.status, .session, (.discard == true)' < "$round_dir/.result-$1")
}

# What an exit code is allowed to be reported as.
#
# `exit 143` run by a script and death by SIGTERM are the same number through
# $?, and nothing downstream can separate them. So this NAMES the signal the
# code is consistent with and states what the runner does know -- that its own
# deadline had not elapsed -- rather than asserting a signal was delivered. The
# only kills this runner can speak for are the ones it initiated, which are the
# 124 and 137 that timeout(1) reports and the caller handles separately.
exit_detail() {
  local rc="$1" sig=""
  if (( rc > 128 && rc < 193 )); then
    sig="$(kill -l "$((rc - 128))" 2>/dev/null)"
  fi
  if [[ -n "$sig" ]]; then
    printf "exit %s (consistent with SIG%s); the runner's deadline had not elapsed" "$rc" "$sig"
  else
    printf 'exit %s' "$rc"
  fi
}

# --- run one reviewer -------------------------------------------------------
# Each reviewer runs under timeout(1), which places the adapter in its own
# process group and signals the WHOLE group on expiry. That reaps builds the CLI
# spawned, which `kill $pid` would orphan.
#
# Do not reach for `setsid` here: plain `setsid cmd &` forks and the parent exits
# immediately, so `wait` returns 0 in milliseconds and the reviewer is judged
# before the adapter has written anything. `setsid -w` waits but then $! is the
# setsid parent, which is no longer in the child's group, so a group kill misses
# the child anyway. timeout(1) does both jobs correctly with no watchdog.
run_reviewer() {
  local reviewer="$1" adapter="$2"
  local sandbox review_out meta_out reason_out log prompt_file
  sandbox="$(pr_sandbox_dir "$session_key" "$reviewer")"
  review_out="$round_dir/review-$reviewer.md"
  meta_out="$round_dir/.meta-$reviewer"
  reason_out="$round_dir/.reason-$reviewer"
  log="$round_dir/log-$reviewer.txt"
  prompt_file="$round_dir/.prompt-$reviewer.txt"

  pr_status_event "$status_file" "$reviewer" started

  # The prompt is built BEFORE the sandbox copy so a reviewer that cannot be
  # given this prompt at all is refused without first rsyncing a full copy of
  # the repository for it. pr_build_prompt reads only the artifact directory,
  # never the sandbox, so the order is free.
  pr_build_prompt "$artifact_dir" "$round" "$reviewer" "$fresh_flag" \
    "$criteria_initial" "$criteria_rereview" > "$prompt_file"

  # Keyed on the adapter PATH, never the reviewer name -- the rule
  # pr_doctor_preflight follows, and for the same reason: tests run fakes under
  # real reviewer names, and a fake has no argv cap. adapters/agy.sh enforces
  # this itself and is the authority; this copy only saves the rsync.
  local prompt_bytes
  if [[ "$adapter" == "$PR_ROOT/adapters/agy.sh" ]]; then
    prompt_bytes="$(pr_prompt_bytes "$prompt_file")"
    if (( prompt_bytes >= PR_MAX_ARG_BYTES )); then
      local cap_detail="prompt is $prompt_bytes bytes, over agy's $PR_MAX_ARG_BYTES argv cap"
      pr_status_event "$status_file" "$reviewer" failed "$cap_detail"
      write_result "$reviewer" failed "$cap_detail" "" "" "" "" ""
      return 0
    fi
  fi

  if ! pr_sandbox_refresh "$repo" "$sandbox" >> "$log" 2>&1; then
    pr_status_event "$status_file" "$reviewer" failed "sandbox refresh failed"
    write_result "$reviewer" failed "sandbox refresh failed" "" "" "" "" ""
    return 0
  fi

  printf '\n\n\n' > "$meta_out"

  local session_in timed_out=0 rc=0
  session_in="$(pr_session_get "$session_map" "$reviewer")"

  TMPDIR="$(pr_sandbox_tmp "$session_key" "$reviewer")" \
  timeout --kill-after="$PR_KILL_GRACE_SECS" "$PR_TIMEOUT_SECS" \
    bash "$adapter" \
      "$(pr_sandbox_repo "$session_key" "$reviewer")" \
      "$session_in" "$review_out" "$meta_out" "$reason_out" \
      < "$prompt_file" >> "$log" 2>&1
  rc=$?
  # 124 = TERM deadline reached; 137 = the KILL grace also elapsed.
  [[ "$rc" -eq 124 || "$rc" -eq 137 ]] && timed_out=1

  # Judge on output, not exit code alone: Cursor exits 2 on a denied tool call
  # while still producing a correct review (D7).
  local status detail=""
  if [[ -s "$review_out" ]]; then
    status=ok
    if [[ "$timed_out" -eq 1 ]]; then
      detail="timed out after ${PR_TIMEOUT_SECS}s, partial output kept"
    elif [[ "$rc" -ne 0 ]]; then
      detail="$(exit_detail "$rc"), output kept"
    fi
  else
    status=failed
    if [[ "$timed_out" -eq 1 ]]; then
      detail="timed out after ${PR_TIMEOUT_SECS}s"
    else
      detail="$(exit_detail "$rc"), no output"
    fi
  fi

  # An adapter that knows why it went the way it did outranks anything inferred
  # from an exit code -- including on a successful round, where a swapped model
  # or a denied tool call has nothing else to report it. First line only, any
  # trailing CR stripped, truncated: this lands in a status line and round.json.
  if [[ -s "$reason_out" ]]; then
    local reason=""
    IFS= read -r reason < "$reason_out"
    reason="${reason%$'\r'}"
    [[ -n "$reason" ]] && detail="${reason:0:200}"
  fi

  if [[ "$status" == ok ]]; then
    pr_parse_files_inspected "$review_out" > "$round_dir/files-inspected-$reviewer.txt"
    pr_status_event "$status_file" "$reviewer" finished "$detail"
  else
    pr_status_event "$status_file" "$reviewer" \
      "$([[ "$timed_out" -eq 1 ]] && echo timed_out || echo failed)" "$detail"
  fi

  # The session map is NOT written here. This function runs as a background job,
  # and three concurrent unlocked read-modify-writes through a shared temp file
  # would drop handles or make one `mv` fail. The parent applies them serially
  # after `wait`, using the session id carried in this record.
  # <meta_out> line order is the adapter contract; see docs/adapter-contract.md.
  # Read as a whole: one builtin, and the positions stay visibly the contract's
  # line numbers. A short file is not an error -- an adapter that died before
  # writing its version leaves fewer than four lines, and the missing ones are
  # empty, exactly as the per-line reads left them.
  local meta=()
  [[ -r "$meta_out" ]] && mapfile -t meta < "$meta_out"

  # Whether this reviewer's repo copy can go. Decided here, where status, rc and
  # Decided here, where every input to the decision -- rc, timed_out and the
  # operator's PR_KEEP_SANDBOX, which a background job of this shell sees just as
  # the parent does -- is already in hand; acted on by the parent, because cleanup that
  # warns has to write round.json and every mutation of that file happens in the
  # serial pass. `$$` inside a subshell is the PARENT's pid, so two children
  # warning at once would collide on one temp file in _pr_round_edit.
  #
  # `status == ok` alone is not "finished cleanly" -- Cursor exits 2 on a denied
  # tool call while still producing a correct review, and a timed-out reviewer's
  # partial output is kept precisely so its tree can be read.
  local discard=false
  [[ "${PR_KEEP_SANDBOX:-0}" != 1 && "$status" == ok && "$timed_out" -eq 0 && "$rc" -eq 0 ]] \
    && discard=true

  write_result "$reviewer" "$status" "$detail" \
    "$(pr_parse_verdict "$review_out")" \
    "${meta[0]-}" "${meta[1]-}" "${meta[2]-}" "${meta[3]-}" "$discard"
}

# --- fan out ----------------------------------------------------------------
# Every process below inherits the session lock's descriptor, and that
# inheritance IS the mechanism: an orphan that outlives this runner keeps the
# session held, so the next round waits instead of writing over it. Anything
# added here that closes descriptors -- a `>&-` in a wrapper, an `env -i` style
# sanitiser -- would silently narrow that to whoever still holds the fd.
reviewers=()
for pair in $adapter_map; do
  reviewers+=("${pair%%=*}")
  run_reviewer "${pair%%=*}" "${pair#*=}" &
done
wait

# Serial: every mutation of round.json and session-map.json happens here, in the
# parent, after all reviewers have finished. Nothing below races.
ok_count=0
for reviewer in "${reviewers[@]}"; do
  # round.json is written straight from the child's record, so no field list is
  # restated here. Only the two values the parent actually branches on are read.
  pr_round_record_reviewer "$round_dir" "$reviewer" "$round_dir/.result-$reviewer"
  read_result "$reviewer" status session discard
  if [[ "$discard" == true ]]; then
    # Housekeeping, never a verdict on the round: a round that produced three
    # good reviews must not be reported broken because a temp copy would not
    # delete. The warning is best-effort for the same reason a full disk can
    # defeat it -- it is recorded if it can be, and printed either way.
    if ! pr_sandbox_discard "$(pr_sandbox_dir "$session_key" "$reviewer")"; then
      discard_warning="could not discard the sandbox copy for $reviewer"
      echo "warning: $discard_warning" >&2
      pr_round_add_warning "$round_dir" "$discard_warning"
    fi
  fi
  if [[ "$status" == ok ]]; then
    pr_session_set "$session_map" "$reviewer" "$session"
    ok_count=$((ok_count + 1))
  else
    # R1: forfeit the handle on failure so the next round retries clean instead
    # of resuming a handle that may be exactly what broke.
    pr_session_del "$session_map" "$reviewer"
  fi
  rm -f "$round_dir/.result-$reviewer" "$round_dir/.meta-$reviewer" \
        "$round_dir/.reason-$reviewer" "$round_dir/.prompt-$reviewer.txt"
done

# One warning, after the round, and only one the artifact can prove: two
# successful reviewers whose recorded models are identical. Post-spend by
# nature -- it says the round just past bought one perspective twice, not that
# the next one will.
while IFS= read -r dup; do
  [[ -n "$dup" ]] || continue
  echo "warning: $dup" >&2
  pr_round_add_warning "$round_dir" "$dup"
done < <(pr_round_duplicate_model_warnings "$round_dir")

if [[ "$ok_count" -eq 0 ]]; then
  pr_round_set_state "$round_dir" aborted
  echo "All reviewers failed. Round $round preserved at $round_dir" >&2
  pr_status_render "$status_file" >&2
  exit 1
fi

pr_round_set_state "$round_dir" awaiting_integration
echo "Round $round complete: $round_dir"
pr_status_render "$status_file"
