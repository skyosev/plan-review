#!/usr/bin/env bash
# The reviewer runner: fan-out, per-reviewer workspace, status events and the
# result record for one round's reviewers. Extracted from
# libexec/plan-review-round.sh (2026-08-22 dispatch-layer note, C1) for a unit
# seam below the CLI, and coupled to plan-review's sandbox, status and result
# conventions ON PURPOSE: this is a product module, not a dispatch framework.
# The spawn/deadline/sweep primitive lives beneath it in lib/adapter-exec.sh.
#
# Sourcing is side-effect free. The sourcer provides the functions this module
# calls -- pr_sandbox_dir/repo/tmp (lib/paths.sh), pr_sandbox_refresh
# (lib/sandbox.sh), pr_status_event (lib/status.sh), pr_build_prompt and
# pr_prompt_bytes (lib/prompt.sh), pr_session_get (lib/session.sh),
# pr_parse_verdict, pr_parse_files_inspected and PR_VERDICTS (lib/verdict.sh),
# pr_adapter_exec (lib/adapter-exec.sh) -- and the variable contract below.
#
# THE VARIABLE CONTRACT. Beyond its arguments, this module reads a fixed set
# of caller variables through bash's dynamic scope. A coupling stated candidly,
# not sold as enforcement: `set -u` would check existence at first use, inside
# a backgrounded child whose death leaves a missing result record rather than
# a refusal; and dynamic scope can resolve a like-named variable elsewhere on
# the stack -- this repo has been bitten once (the regression case in
# tests/test-round.sh). Hence pr_reviewer_run_all validates the whole list
# before the first spawn, where a refusal is loud and synchronous, and this
# module declares no locals named like contract variables, so its own frames
# cannot shadow them.
#
# That validation covers the FAN-OUT, which is the part that runs in the
# background. The record accessors below (pr_reviewer_result_path,
# pr_reviewer_result_read, pr_reviewer_result_ensure) are public too and
# validate nothing: they read `round_dir`, and _ensure also `status_file`, and
# they run only in the round's serial pass, in the foreground, where an unset
# one fails immediately and visibly instead of vanishing with a child.
_PR_REVIEWER_CONTRACT="repo session_key artifact_dir round_dir round fresh_flag \
status_file session_map criteria_initial criteria_rereview \
PR_ROOT PR_TIMEOUT_SECS PR_KILL_GRACE_SECS PR_MAX_ARG_BYTES"
# Set but legitimately empty: an unconfigured project has no criteria files.
_PR_REVIEWER_CONTRACT_EMPTY_OK=" criteria_initial criteria_rereview "
# PR_KEEP_SANDBOX is read too, with a default -- the operator's optional
# override, not part of the contract.

# --- the result record -------------------------------------------------------
# JSON, not a delimited line. The first attempt was tab-separated and read back
# with `IFS=$'\t' read`, which is silently wrong: tab is IFS *whitespace*, so a
# run of tabs collapses into one delimiter and an empty field — the normal case,
# since `detail` is empty on success — shifts every later field left by one. The
# verdict lands in `detail`, the session id in `verdict`, and the last variable
# comes back empty. jq has no delimiter to get wrong.
#
# Field provenance, the line a future extraction would cut along: `timed_out`
# and the four meta lines (session, model, effort, cli) are execution FACTS the
# child observed; `status`, `detail`, `verdict` and `discard` are product
# RULINGS made here. Prose, not nesting -- a facts/rulings split of the JSON
# would rewrite both readers for no failure caught today.

# pr_reviewer_result_path <reviewer>
# The record's location, stated once. The round reads the record through this
# and pr_reviewer_result_read; it composes no scratch name of its own.
pr_reviewer_result_path() { printf '%s/.result-%s' "$round_dir" "$1"; }

# pr_reviewer_scratch_rm <reviewer>
# Every scratch name this module owns, retired in one place. The published
# review and the reviewer log are NOT scratch and are deliberately absent.
#
# `.review-$1.scratch.log` was briefly on this list: adapters/claude.sh and
# adapters/agent.sh derived `"${review_out}.log"`, which on the round path landed
# here as a hidden file nothing swept. Sweeping it was the wrong half of the fix
# -- it deleted the CLI's only stderr copy. Both adapters now inherit stderr into
# <round>/log-<reviewer>.txt instead, so no shipped adapter derives a path from
# review_out and there is nothing extra to retire. If one ever does again, the
# contract (docs/adapter-contract.md) points here.
pr_reviewer_scratch_rm() {
  rm -f "$(pr_reviewer_result_path "$1")" "$round_dir/.meta-$1" \
        "$round_dir/.reason-$1" \
        "$round_dir/.prompt-$1.txt" "$round_dir/.review-$1.scratch" \
        "$round_dir/review-$1.md.publish"
}

# _pr_reviewer_result_write <reviewer> <status> <detail> <verdict> <session>
#                           <model> <effort> <cli> [discard] [timed_out]
_pr_reviewer_result_write() {
  local reviewer="$1"
  jq -n --arg status "$2" --arg detail "$3" --arg verdict "$4" \
        --arg session "$5" --arg model "$6" --arg effort "$7" --arg cli "$8" \
        --argjson discard "${9:-false}" --argjson timed_out "${10:-false}" \
        '{$status, $detail, $verdict, $session, $model, $effort, $cli, $discard, $timed_out}' \
    > "$(pr_reviewer_result_path "$reviewer")"
}

# pr_reviewer_result_read <reviewer> <status-var> <session-var> <discard-var> <timed-out-var>
# The only values the parent branches on, in one jq rather than one each --
# the parent's whole view of the record.
#
# `discard` is read as "true or nothing". A truncated or unparseable record
# leaves every variable empty, which means keep -- the safe direction, since the
# copy exists to be looked at when something went wrong.
pr_reviewer_result_read() {
  local -n _status="$2" _session="$3" _discard="$4" _timed_out="$5"
  # Cleared first: `read` leaves a variable alone when it has nothing to read,
  # and these are reused across the loop, so an unreadable record would silently
  # inherit the previous reviewer's answer.
  _status="" _session="" _discard="" _timed_out=""
  { IFS= read -r _status; IFS= read -r _session; IFS= read -r _discard
    IFS= read -r _timed_out; } < <(
    jq -r '.status, .session, (.discard == true), (.timed_out == true)' \
      < "$(pr_reviewer_result_path "$1")")
}

# _pr_reviewer_result_valid <reviewer> -> 0 valid, 1 missing, 2 invalid.
# jq -es over the nine fields AND their closed domains -- exactly one JSON
# object, status from {ok, failed}, verdict from pr_parse_verdict's output set
# or empty (a failed reviewer's) -- not existence or types alone: a truncated,
# concatenated or hand-mangled record must not flow into round.json as
# authoritative. detail/session/model/effort/cli stay free-form by design --
# they are display strings, and inventing constraints for them would reject
# tomorrow's legitimate vendor value.
_pr_reviewer_result_valid() {
  local rec; rec="$(pr_reviewer_result_path "$1")"
  [[ -f "$rec" ]] || return 1
  jq -es --arg verdicts "$PR_VERDICTS UNPARSEABLE" \
         'length == 1 and (.[0] |
          type == "object"
          and ([.status, .detail, .verdict, .session, .model, .effort, .cli]
               | all(type == "string"))
          and ([.discard, .timed_out] | all(type == "boolean"))
          and (.status | IN("ok", "failed"))
          and (.verdict | IN("", ($verdicts | split(" ")[]))))' \
    < "$rec" > /dev/null 2>&1 && return 0
  return 2
}

# pr_reviewer_result_ensure <reviewer>
# The serial parent's guard: 0 = the record is present and valid; 1 = it was
# not, and a synthesized failed record now stands in its place (detail says
# "record missing" or "record invalid" -- the diagnosis differs); 2 = the store
# refused the synthesized write too, which is no longer a reviewer-scoped
# failure and the caller must abort rather than promise a coherent artifact.
pr_reviewer_result_ensure() {
  local why
  _pr_reviewer_result_valid "$1"
  case $? in 0) return 0 ;; 1) why=missing ;; *) why=invalid ;; esac
  _pr_reviewer_result_write "$1" failed "reviewer result record $why" \
    "" "" "" "" "" || return 2
  pr_status_event "$status_file" "$1" failed "reviewer result record $why"
  return 1
}

# _pr_reviewer_fail <reviewer> <detail> [session model effort cli discard timed_out]
# The child's failure exit, written once: the status event and the result record
# always carry the same detail, and a reviewer that failed before or instead of
# publishing has no verdict to record. The optional tail is the publication
# case, which is the only failure holding facts worth keeping.
_pr_reviewer_fail() {
  pr_status_event "$status_file" "$1" failed "$2"
  _pr_reviewer_result_write "$1" failed "$2" "" \
    "${3-}" "${4-}" "${5-}" "${6-}" "${7-}" "${8-}"
}

# What an exit code is allowed to be reported as.
#
# `exit 143` run by a script and death by SIGTERM are the same number through
# $?, and nothing downstream can separate them. So this NAMES the signal the
# code is consistent with and states what the runner does know -- that its own
# deadline had not elapsed -- rather than asserting a signal was delivered. The
# only kills this runner can speak for are the ones it initiated, which are the
# 124 and 137 the kernel classifies and the caller handles separately.
_pr_reviewer_exit_detail() {
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

# --- run one reviewer --------------------------------------------------------
# Internal: a public run-one would bypass the contract validation and be exposed
# to exactly the unset-variable, missing-record failure it exists to prevent.
# One production caller (the fan-out below).
# _pr_reviewer_run_one <reviewer> <adapter>
_pr_reviewer_run_one() {
  local reviewer="$1" adapter="$2"
  local sandbox review_out meta_out reason_out log prompt_file
  sandbox="$(pr_sandbox_dir "$session_key" "$reviewer")"
  review_out="$round_dir/review-$reviewer.md"
  local review_scratch="$round_dir/.review-$reviewer.scratch"
  meta_out="$round_dir/.meta-$reviewer"
  reason_out="$round_dir/.reason-$reviewer"
  log="$round_dir/log-$reviewer.txt"
  prompt_file="$round_dir/.prompt-$reviewer.txt"

  pr_status_event "$status_file" "$reviewer" started

  # The prompt is built BEFORE the sandbox copy so a reviewer that cannot be
  # given this prompt at all is refused without first rsyncing a full copy of
  # the repository for it. pr_build_prompt reads only the artifact directory,
  # never the sandbox, so the order is free.
  #
  # A reviewer that cannot be given this prompt is refused before anything is
  # rsynced or spawned -- a failed record and a reason, never an empty-stdin
  # review. -s as well as the exit status: a function whose last write failed
  # can still return 0, and the prompt is never legitimately empty (the
  # instructions heredoc alone guarantees bytes).
  #
  # Measured before the guard existed (2026-08-26, a /dev/full symlink at
  # $prompt_file): the write errors went to stderr, the failure was ignored,
  # and the adapter was spawned reading that same descriptor -- /dev/full
  # READS as an endless stream of NULs, so the reviewer got zero bytes where
  # the plan should have been, wrote a review of nothing, and the round
  # recorded it ok/MINOR. An empty prompt was the optimistic half of it.
  #
  # The residue, since -s closes the empty case and not the class: a prompt
  # TRUNCATED by a full disk can still arrive here. pr_build_prompt's exit
  # status is the only defence against that, and it is not airtight --
  # _pr_emit_section returns 0 early when its file is empty (lib/prompt.sh:26),
  # so a heredoc that failed partway followed by a skipped last section leaves
  # rc 0 over a short but non-empty file. It needs an empty plan.snapshot.md to
  # line up, which is why it is named rather than defended against.
  if ! pr_build_prompt "$artifact_dir" "$round" "$reviewer" "$fresh_flag" \
       "$criteria_initial" "$criteria_rereview" > "$prompt_file" 2>> "$log" \
     || [[ ! -s "$prompt_file" ]]; then
    _pr_reviewer_fail "$reviewer" "prompt write failed"
    return 0
  fi

  # Keyed on the adapter PATH, never the reviewer name -- the rule
  # pr_doctor_preflight follows, and for the same reason: tests run fakes under
  # real reviewer names, and a fake has no argv cap. adapters/agy.sh enforces
  # this itself and is the authority; this copy only saves the rsync.
  local prompt_bytes
  if [[ "$adapter" == "$PR_ROOT/adapters/agy.sh" ]]; then
    prompt_bytes="$(pr_prompt_bytes "$prompt_file")"
    if (( prompt_bytes >= PR_MAX_ARG_BYTES )); then
      local cap_detail="prompt is $prompt_bytes bytes, over agy's $PR_MAX_ARG_BYTES argv cap"
      _pr_reviewer_fail "$reviewer" "$cap_detail"
      return 0
    fi
  fi

  if ! pr_sandbox_refresh "$repo" "$sandbox" >> "$log" 2>&1; then
    _pr_reviewer_fail "$reviewer" "sandbox refresh failed"
    return 0
  fi

  # Checked for the same reason as the prompt: the meta pre-seed is what makes
  # a short meta file readable as "empty lines", and a pre-seed that failed to
  # write says the store under this reviewer is already broken.
  #
  # It is also what keeps the mapfile below off a file it cannot trust.
  # Measured unguarded (2026-08-26, a /dev/full symlink at $meta_out): the
  # failed printf was ignored, and `mapfile -t meta < "$meta_out"` then read
  # the same device -- an endless NUL stream -- past 3GB RSS in twelve seconds
  # and never returned. Nothing bounds that read: the kernel's deadline covers
  # the adapter, not this child's own artifact reads.
  if ! printf '\n\n\n' > "$meta_out" 2>> "$log"; then
    _pr_reviewer_fail "$reviewer" "meta pre-seed failed"
    return 0
  fi

  local session_in rc=0 timed_out=0 timed_out_json=false
  session_in="$(pr_session_get "$session_map" "$reviewer")"

  # The spawn, the deadline, the 124/137 classification and the sweeps live in
  # the kernel (lib/adapter-exec.sh), which reads the prompt from ITS stdin --
  # the file redirect below -- and before returning sweeps the adapter's
  # process group and, best-effort, the descendants it sampled while the
  # adapter ran. Best-effort is the whole point of the qualifier: P6 measured a
  # reviewer whose tool layer took its own session, and a survivor that
  # detaches between the last sample and the kill still escapes. So what makes
  # the artifact reads below final is the PUBLICATION step immediately after
  # this call, not the sweep. The adapter is handed the scratch path, never the
  # published one. TMPDIR is a POSITIONAL now, not a trailing env word: the
  # kernel is the single writer of the adapter's environment and exports both
  # the deadline it is handed and this tmpdir itself, so PR_TIMEOUT_SECS is not
  # passed here at all -- the eighth positional IS what the adapter reads, and
  # adapters/agy.sh derives its inner --print-timeout from that one value.
  # Nothing in this path closes a descriptor, so the session lock is still
  # inherited.
  pr_adapter_exec "$adapter" "$(pr_sandbox_repo "$session_key" "$reviewer")" \
    "$session_in" "$review_scratch" "$meta_out" "$reason_out" \
    "$log" "$PR_TIMEOUT_SECS" "$(pr_sandbox_tmp "$session_key" "$reviewer")" \
    rc timed_out < "$prompt_file"
  (( timed_out )) && timed_out_json=true

  # Publication. The child owns judgment -- the size check, the verdict and
  # files-inspected all run below, before the serial parent -- so the child
  # publishes too: scratch -> fresh copy -> rename, and every semantic read
  # after this point uses the published file. The rename is safe because a
  # survivor holds the SCRATCH inode, never the copy's; what this prevents is
  # post-publication mutation, so the record and the artifact describe the same
  # bytes. It is not an instantaneous snapshot: a survivor writing during the
  # copy can leave a torn tail, accepted because every downstream read uses the
  # same immutable copy. An absent scratch publishes nothing and the size check
  # below fails the reviewer exactly as an absent review always has.
  #
  # <meta_out> is read BEFORE publication rather than beside the other judgment
  # below, because the publication-failure record needs it: a reviewer that
  # timed out and then failed to publish still timed out, and its model is
  # still on disk. Its line order is the adapter contract; see
  # docs/adapter-contract.md. Read as a whole: one builtin, and the positions
  # stay visibly the contract's line numbers. A short file is not an error --
  # an adapter that died before writing its version leaves fewer than four
  # lines, and the missing ones are empty, exactly as the per-line reads left
  # them.
  # Guarded and bounded, both measured (2026-08-27). -f in place of -r: the
  # file test follows symlinks, so a <meta_out> swapped for a device or a FIFO
  # by the adapter -- or by a descendant the sweep missed -- is skipped instead
  # of read. Unguarded, a /dev/zero symlink grew this child past 3GB RSS under
  # no deadline, and a writer-less FIFO blocks forever at open(2), which no
  # byte bound reaches. head -c rather than a builtin bound because the builtin
  # is a trap: `read -r -N` drops NUL bytes without counting them toward N and
  # hangs on an endless NUL stream. 4096 covers the contract's four short lines
  # many times over; oversize gibberish lands where undersize gibberish already
  # does -- only meta[0..3] are ever read. Two residuals, accepted: the
  # microsecond window between test and open (the same best-effort class as
  # the sweep that missed the survivor), and a regular file on a stalled
  # filesystem, an exposure every other read the round makes already shares.
  # The process substitution closes no descriptors -- the session lock rides
  # through head exactly as it rides through the adapter.
  local meta=()
  [[ -f "$meta_out" ]] && mapfile -t meta < <(head -c 4096 "$meta_out")
  if [[ -e "$review_scratch" ]]; then
    if ! cp "$review_scratch" "$review_out.publish" 2>> "$log" \
       || ! mv "$review_out.publish" "$review_out" 2>> "$log"; then
      # Every fact the child holds, not just the ruling: `verdict` is empty
      # because nothing was published to parse one from, and `discard` is
      # false because a reviewer whose review could not be written is exactly
      # the case whose sandbox is worth keeping. timed_out and the four meta
      # lines are carried, so round.json does not claim a timed-out reviewer
      # finished on time and the duplicate-model warning can still see this
      # reviewer's model.
      _pr_reviewer_fail "$reviewer" "review publication failed" \
        "${meta[0]-}" "${meta[1]-}" "${meta[2]-}" "${meta[3]-}" false \
        "$timed_out_json"
      return 0
    fi
  fi

  # Judge on output, not exit code alone: Cursor exits 2 on a denied tool call
  # while still producing a correct review (D7).
  local status detail=""
  if [[ -s "$review_out" ]]; then
    status=ok
    if [[ "$timed_out" -eq 1 ]]; then
      detail="timed out after ${PR_TIMEOUT_SECS}s, partial output kept"
    elif [[ "$rc" -ne 0 ]]; then
      detail="$(_pr_reviewer_exit_detail "$rc"), output kept"
    fi
  else
    status=failed
    if [[ "$timed_out" -eq 1 ]]; then
      detail="timed out after ${PR_TIMEOUT_SECS}s"
    else
      detail="$(_pr_reviewer_exit_detail "$rc"), no output"
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
  # would drop handles or make one `mv` fail. The caller applies them serially
  # after the fan-out, using the session id carried in this record.
  # Whether this reviewer's repo copy can go. Decided here, where every input to
  # the decision -- rc, timed_out and the operator's PR_KEEP_SANDBOX, which a
  # background job of this shell sees just as the parent does -- is already in
  # hand; acted on by the caller, because cleanup that warns has to write
  # round.json and every mutation of that file happens in the serial pass. `$$`
  # inside a subshell is the PARENT's pid, so two children warning at once would
  # collide on one temp file in _pr_round_edit.
  #
  # `status == ok` alone is not "finished cleanly" -- Cursor exits 2 on a denied
  # tool call while still producing a correct review, and a timed-out reviewer's
  # partial output is kept precisely so its tree can be read.
  local discard=false
  [[ "${PR_KEEP_SANDBOX:-0}" != 1 && "$status" == ok && "$timed_out" -eq 0 && "$rc" -eq 0 ]] \
    && discard=true

  _pr_reviewer_result_write "$reviewer" "$status" "$detail" \
    "$(pr_parse_verdict "$review_out")" \
    "${meta[0]-}" "${meta[1]-}" "${meta[2]-}" "${meta[3]-}" "$discard" \
    "$timed_out_json"
}

# --- fan out -----------------------------------------------------------------
# pr_reviewer_run_all <adapter-map>
#
# The ONLY public entry to the fan-out, and the validation point for the
# variable contract above. No output parameter: pr_roster_keys (lib/roster.sh)
# already owns map decoding, and the round caller iterates those keys.
#
# Every process spawned below inherits the session lock's descriptor, and that
# inheritance IS the mechanism: an orphan that outlives the runner keeps the
# session held, so the next round waits instead of writing over it. The
# invariant is about DESCRIPTORS, not the environment: variables may be -- and
# for adapters/claude.sh must be -- sanitised independently (its env -i
# whitelist rebuilds the environment while the lock fd, deliberately not
# CLOEXEC, rides through; lib/lock.sh:8). A wrapper is unsafe only if it closes
# the descriptor or starts the reviewer without inheriting it.
#
# The waits are on COLLECTED pids, never bare `wait`: bare `wait` in a sourced
# function would block on and reap a caller's unrelated background job --
# tolerable in an exec-owned script, wrong in a library.
pr_reviewer_run_all() {
  local map="$1" name pair
  for name in $_PR_REVIEWER_CONTRACT; do
    if [[ -z "${!name+x}" ]]; then
      echo "pr_reviewer_run_all: contract variable is unset: $name" >&2
      return 2
    fi
    [[ "$_PR_REVIEWER_CONTRACT_EMPTY_OK" == *" $name "* ]] && continue
    if [[ -z "${!name}" ]]; then
      echo "pr_reviewer_run_all: contract variable is empty: $name" >&2
      return 2
    fi
  done
  local pids=() pid
  for pair in $map; do
    _pr_reviewer_run_one "${pair%%=*}" "${pair#*=}" &
    pids+=("$!")
  done
  # The children's statuses are deliberately discarded: the result record is
  # the report (D7 judges output, and the serial pass reads the record), and
  # the bare `wait` this replaces never surfaced them either -- propagating the
  # last child's code here would turn an internal hiccup one reviewer masked
  # yesterday into a round abort today.
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done
  return 0
}
