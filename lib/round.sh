#!/usr/bin/env bash
# round.json: the per-round record and its lifecycle. Two states are terminal,
# and every transition is written under the session lock (lib/lock.sh).
#   reviewing            -> awaiting_integration  (runner, reviewers done)
#   reviewing            -> aborted               (runner on a signal; abort)
#   awaiting_integration -> complete              (complete, rationales written)
#   awaiting_integration -> aborted               (abort)

PR_ROUND_STATES="reviewing awaiting_integration complete aborted"

pr_round_dir() {
  printf '%s/round-%s' "$1" "$2"
}

# pr_round_artifact_dir <round-dir>
# The inverse of pr_round_dir: the session directory a round lives in, which is
# where the lock and the other rounds are. Written once here rather than as
# ${dir%/*} at each caller, so the trailing-slash precondition below sits with
# the code that has the precondition.
pr_round_artifact_dir() {
  local dir="${1%/}"
  printf '%s' "${dir%/*}"
}

# pr_round_arg_dir <args...>
# Parses `--round <absolute-round-dir>`, prints the canonical directory, and
# returns non-zero with the reason on stderr. `complete` and `abort` name a
# round the same way and must refuse the same paths for the same reasons; two
# copies of that had already drifted into two different behaviours for
# `--round` with no value.
pr_round_arg_dir() {
  local round_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      # Checked rather than shifted blindly: `shift 2` with one argument left
      # shifts NOTHING and returns non-zero, so the loop would spin forever.
      --round) [[ $# -ge 2 ]] || { echo "--round needs a directory" >&2; return 2; }
               round_dir="$2"; shift 2 ;;
      *) echo "unknown argument: $1" >&2; return 2 ;;
    esac
  done

  [[ -n "$round_dir" ]] || { echo "usage: --round <round-dir>" >&2; return 2; }
  # Enforced, not merely documented: a relative path would resolve against the
  # implementation's working directory rather than the caller's, and silently
  # point at nothing or at the wrong round.
  [[ "$round_dir" == /* ]] || { echo "--round must be absolute, got: $round_dir" >&2; return 2; }
  # A trailing slash would make pr_round_artifact_dir return the round directory
  # itself rather than the session directory the lock lives in.
  round_dir="${round_dir%/}"
  # Doubled slashes too, not only the trailing one: the Integrator assembles
  # this path by hand (SKILL.md substitutes <repo>/.plan-review/<key>/round-N),
  # every consumer resolves `//` fine, but this string is echoed back on the
  # user-facing "Round complete:" line, so it is canonicalised where it enters.
  while [[ "$round_dir" == *//* ]]; do round_dir="${round_dir//\/\//\/}"; done
  [[ -f "$round_dir/round.json" ]] || { echo "no round.json in $round_dir" >&2; return 2; }

  printf '%s' "$round_dir"
}

# pr_round_highest <artifact-dir>
# The highest existing round number, or 0 when there are none.
pr_round_highest() {
  local d i highest=0
  for d in "$1"/round-*; do
    [[ -d "$d" ]] || continue
    i="${d##*/round-}"
    [[ "$i" =~ ^[0-9]+$ ]] && (( i > highest )) && highest="$i"
  done
  printf '%s' "$highest"
}

# pr_round_state <round-dir>
# `unreadable` covers a missing, truncated or state-less round.json alike: the
# callers below only ever act on the allow-list, so every unknown collapses to
# one blocking answer.
pr_round_state() {
  local state
  # `2>/dev/null` precedes the input redirect deliberately: redirections apply
  # left to right, so trailing it would let the shell's own "No such file" leak.
  state="$(jq -r '.state // "unreadable"' 2>/dev/null < "$1/round.json")"
  printf '%s' "${state:-unreadable}"
}

# pr_round_can_start <state-of-previous-round>
# Allow-list, not deny-list: `reviewing` (a crashed run), `unknown`, a truncated
# round.json and a missing round.json must all block. Blocking only
# awaiting_integration would let a crashed round be silently buried under a new
# one. The runner enforces this and the doctor explains it, so it lives here
# rather than in either of them.
pr_round_can_start() {
  [[ "$1" == complete || "$1" == aborted ]]
}

# pr_git_grounding <repo-root> <repo-relative-plan-path>
# Emits a JSON object. worktree_content_hash covers the tracked diff AND
# untracked files, because head sha + dirty flag cannot distinguish two
# materially different dirty trees (R5).
pr_git_grounding() {
  local repo="$1" plan_rel="$2"
  local head dirty plan_hash wt_hash

  head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || printf 'UNKNOWN')"
  if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
    dirty=true
  else
    dirty=false
  fi
  plan_hash="$(sha256sum "$repo/$plan_rel" 2>/dev/null | cut -d' ' -f1)"
  # No `-I{}`: that would fork one sha256sum per untracked file. Batched, this
  # is a handful of processes regardless of how many untracked files exist.
  wt_hash="$( { git -C "$repo" diff HEAD 2>/dev/null
                ( cd "$repo" \
                  && git ls-files --others --exclude-standard -z 2>/dev/null \
                     | xargs -0 -r sha256sum 2>/dev/null )
              } | sha256sum | cut -d' ' -f1 )"

  jq -nc --arg head "$head" \
         --argjson dirty "$dirty" \
         --arg plan_hash "${plan_hash:-}" \
         --arg wt_hash "$wt_hash" \
         '{git_head_sha: $head,
           is_dirty_worktree: $dirty,
           plan_content_hash: $plan_hash,
           worktree_content_hash: $wt_hash}'
}

# pr_round_init <round-dir> <round-number> <repo-root> <plan-rel-path> [fresh] [orchestrator] [config-json]
# fresh: "true" if this round starts a new baseline (resume handles dropped).
# Round numbers stay monotonic across baselines, so this flag is the only record
# that the reviewers lost their memory here.
#
# orchestrator: which CLI drove the round, or `none`. A record, not a proof --
# the runner cannot measure who invoked it, so this is what the caller declared.
# It is still the only thing that distinguishes an independent round from one
# whose orchestrator sat in its own roster, which is unanswerable afterwards
# without it.
#
# config: the resolved project configuration -- path, preset, per-field pin
# provenance, criteria and the settings hash. Written whether or not a config
# file exists, because the hash covers the resolved settings whatever their
# source, which is what makes a mid-loop change to an env pin detectable.
pr_round_init() {
  local rd="$1" n="$2" repo="$3" plan_rel="$4" fresh="${5:-false}" orch="${6:-unknown}"
  local config="${7:-null}"
  mkdir -p "$rd"
  local started_at; TZ=UTC printf -v started_at '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  jq -n --argjson round "$n" \
        --arg started_at "$started_at" \
        --arg plan "$plan_rel" \
        --argjson fresh "$fresh" \
        --arg orchestrator "$orch" \
        --argjson grounding "$(pr_git_grounding "$repo" "$plan_rel")" \
        --argjson config "$config" \
        '{round: $round,
          state: "reviewing",
          fresh: $fresh,
          orchestrator: $orchestrator,
          started_at: $started_at,
          plan: $plan,
          grounding: $grounding,
          config: $config,
          warnings: [],
          reviewers: {}}' > "$rd/round.json"
}

# pr_round_add_warning <round-dir> <text>
#
# Warnings never affect exit status and never stop a round. They are printed
# when they are found and kept in round.json so the artifact carries them too --
# a warning only on stderr is lost the moment the terminal scrolls.
pr_round_add_warning() {
  _pr_round_edit "$1" --arg w "$2" '.warnings += [$w]'
}

# _pr_round_edit <round-dir> <jq-args...>
# Read-modify-write round.json through a temp file, so a jq failure leaves the
# previous contents intact rather than a truncated file. The temp name carries
# $$ because the runner has several writers alive at once.
_pr_round_edit() {
  local rd="$1"; shift
  local tmp="$rd/.round.json.$$.tmp"
  jq "$@" < "$rd/round.json" > "$tmp" && mv "$tmp" "$rd/round.json"
}

# pr_round_duplicate_model_warnings <round-dir>
#
# Two successful reviewers whose RECORDED models are identical: one perspective
# bought twice (D14). Recorded, not effective -- adapters/agy.sh:118 writes the
# requested pin because agy reports no effective model, and Cursor is the same.
# Failed reviewers both recording "" are two absences, not a duplicate, so they
# are excluded rather than reported on a round that already failed loudly.
pr_round_duplicate_model_warnings() {
  jq -r '[.reviewers | to_entries[]
          | select(.value.status == "ok" and (.value.model // "") != "")]
         | group_by(.value.model)[]
         | select(length > 1)
         | "\((map(.key) | sort | join(" and "))) recorded the same model: \(.[0].value.model)"' \
    < "$1/round.json"
}

# pr_round_record_reviewer <round-dir> <reviewer> <result-json-file>
#
# Takes the runner's result file rather than a positional argument per field.
# Eight positional strings was already at the edge of readable, and `effort`
# would have made nine — one transposed pair and round.json records a session id
# as a model, silently. The result file is the same JSON the child wrote, so
# there is no ordering to get wrong and no field list to keep in sync in two
# places. Same reasoning that replaced the tab-delimited record.
#
# Every value is the EFFECTIVE one the adapter reported, not the requested pin.
# Q2/R11 need to know what actually answered, which is the only way to notice two
# reviewers collapsing onto the same model at the same effort.
# Called serially from the parent after `wait`, never from a background job.
pr_round_record_reviewer() {
  local rd="$1" reviewer="$2" result="$3"
  _pr_round_edit "$rd" --arg r "$reviewer" --slurpfile res "$result" \
     '.reviewers[$r] = {status:      $res[0].status,
                        verdict:     $res[0].verdict,
                        model:       $res[0].model,
                        effort:      $res[0].effort,
                        cli_version: $res[0].cli,
                        detail:      $res[0].detail,
                        session_id:  $res[0].session}'
}

# pr_round_set_state <round-dir> <state>
pr_round_set_state() {
  local rd="$1" state="$2"
  if [[ " $PR_ROUND_STATES " != *" $state "* ]]; then
    echo "pr_round_set_state: unknown state '$state' (want: $PR_ROUND_STATES)" >&2
    return 1
  fi
  _pr_round_edit "$rd" --arg s "$state" '.state = $s'
}
