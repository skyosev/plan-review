#!/usr/bin/env bash
# Building a project config out of what is installed here.
#
# Needs `jq`, like lib/config.sh and for the same reason: it emits JSON and then
# hands it to that file's validator. Sourced by libexec/plan-review-init.sh AFTER
# lib/doctor.sh, lib/roster.sh and lib/config.sh, whose probes, adapter list and
# validator it uses rather than growing second copies of them.
#
# Sourcing has no side effects. Nothing here touches the network or the
# filesystem until a pr_init_* function is called.
#
# Two halves, deliberately separable:
#   pr_init_build_config  a pure function of (roster, pins) -- no probing, no
#                         environment, no filesystem, so the shape of the
#                         generated file is testable on a machine with none of
#                         the four CLIs on it.
#   pr_init_probe         everything that asks the machine a question.

# One entry per blocking problem, printed together at the end. Reporting them
# one at a time would mean a person fixes an auth problem, re-runs, and only
# then learns about the missing pin.
PR_INIT_PROBLEMS=()

# The temp file, so the entry point's trap can remove it. Empty when there
# isn't one.
PR_INIT_TMP=""

# pr_init_problem <headline> [detail ...]
pr_init_problem() {
  local text="  - $1" d
  shift
  for d in "$@"; do text+=$'\n'"    $d"; done
  PR_INIT_PROBLEMS+=("$text")
}

# 0 when there was nothing to report.
pr_init_problems_report() {
  (( ${#PR_INIT_PROBLEMS[@]} == 0 )) && return 0
  {
    echo
    echo "These reviewers cannot review here, so nothing was written:"
    printf '%s\n' "${PR_INIT_PROBLEMS[@]}"
    echo
    echo "Fix them, or leave those reviewers out with --reviewers."
  } >&2
  return 1
}

# pr_init_quiet <doctor-check> [args...]
#
# Runs one of lib/doctor.sh's checks for its RETURN CODE only: the output goes
# nowhere and the pass/warn/fail counters are put back afterwards, because those
# belong to whoever prints a summary and init prints its own. Reimplementing the
# checks here instead would put two answers to "is codex authenticated" in one
# repo, and the round is lost when the two disagree -- a suppressed printf is
# the smaller problem.
pr_init_quiet() {
  local pass="$PR_DOCTOR_PASS" warn="$PR_DOCTOR_WARN" fail="$PR_DOCTOR_FAIL" rc
  "$@" > /dev/null 2>&1
  rc=$?
  PR_DOCTOR_PASS="$pass" PR_DOCTOR_WARN="$warn" PR_DOCTOR_FAIL="$fail"
  return "$rc"
}

# Which CLIs have an effort axis at all: exactly those lib/doctor.sh declares a
# PR_EFFORTS_<CLI> enum for. For agy and Cursor the tier lives inside the model
# id, and `pins.<cli>.effort` is a schema violation there (lib/config.sh's
# check_effort), not merely a no-op.
pr_init_has_effort() { local e="PR_EFFORTS_${1^^}"; [[ -n "${!e:-}" ]]; }

# Which CLIs refuse to run without a model pin. Both report no effective model,
# so without one round.json could not record what reviewed the plan.
pr_init_needs_pin() { [[ "$1" == agent || "$1" == agy ]]; }

# Which CLIs need the bubblewrap jail. agy's own --sandbox does not confine
# writes and Claude Code exposes no sandbox flag, so both adapters refuse to run
# without bwrap.
pr_init_needs_jail() { [[ "$1" == agy || "$1" == claude ]]; }

# pr_init_lookup <pairs> <key>  -- "cli=value cli=value" -> value, or 1.
pr_init_lookup() {
  local pair
  for pair in $1; do
    if [[ "${pair%%=*}" == "$2" ]]; then
      printf '%s' "${pair#*=}"
      return 0
    fi
  done
  return 1
}

# pr_init_model_env <cli> -- the exported pin for that CLI, or "".
pr_init_model_env() {
  local name="PR_${1^^}_MODEL"
  printf '%s' "${!name:-}"
}

# pr_init_model_list <cli> -- that CLI's models, one line each, or "" if the list
# could not be fetched (offline, absent, or the call failed).
pr_init_model_list() {
  case "$1" in
    agent) pr_doctor_fetch_agent_models > /dev/null 2>&1 && printf '%s' "$PR_DOCTOR_AGENT_MODELS" ;;
    agy)   pr_doctor_fetch_agy_models   > /dev/null 2>&1 && printf '%s' "$PR_DOCTOR_AGY_MODELS" ;;
  esac
}

# pr_init_probe <cli> <model>
#
# Can this CLI review here? Auth, and the pin it may require. 0 yes; 1 no, with
# the reasons appended to PR_INIT_PROBLEMS. The jail is roster-wide and checked
# once by pr_init_probe_jail; a per-reviewer jail probe would report one broken
# kernel setting twice.
#
# Under PR_DOCTOR_OFFLINE=1 the auth probe and the model-list check are both
# skipped, and a required pin is still required: a missing one is a fact about
# the arguments, not about the network.
pr_init_probe() {
  local cli="$1" model="$2" rc=0 list=""

  if [[ "${PR_DOCTOR_OFFLINE:-0}" != 1 ]]; then
    case "$cli" in
      codex)  pr_init_quiet pr_doctor_check_codex_auth \
                || { pr_init_problem "codex is not authenticated." "Fix with: codex login"; rc=1; } ;;
      agent)  if ! pr_init_quiet pr_doctor_check_agent_identity; then
                pr_init_problem "the \`agent\` on PATH does not answer \`agent about --format json\`." \
                                "$(command -v agent) looks like a different tool with the same name."
                rc=1
              elif ! pr_init_quiet pr_doctor_check_agent_auth; then
                pr_init_problem "Cursor is not authenticated." \
                                "Log in with the Cursor CLI, or set CURSOR_API_KEY."
                rc=1
              fi ;;
      agy)    pr_init_quiet pr_doctor_check_agy_auth \
                || { pr_init_problem "agy did not answer \`agy models\`." \
                       "agy has no login subcommand. Run \`agy\` interactively once."; rc=1; } ;;
      claude) pr_init_quiet pr_doctor_check_claude_auth \
                || { pr_init_problem "claude is not authenticated." "Fix with: claude auth login"; rc=1; } ;;
    esac
  fi

  pr_init_needs_pin "$cli" || return "$rc"

  if [[ -z "$model" ]]; then
    # The whole point of refusing rather than dropping the reviewer: a forgotten
    # pin is fixable in one flag, and silently narrowing the roster instead is
    # the outcome the strict schema exists to prevent.
    local line lines=("PR_${cli^^}_MODEL is unset and no --pin gave one; $cli refuses to run without it."
                      "Re-run with --pin $cli=<id>.")
    list="$(pr_init_model_list "$cli")"
    if [[ -n "$list" ]]; then
      lines+=("Available ids:")
      # The id lines only. Both CLIs print prose around their list -- "Available
      # models", "Fetching available models..." -- and pasting that back at
      # someone as a menu of ids is how a header ends up in a --pin flag.
      while IFS= read -r line; do
        pr_doctor_is_id_line "$line" && lines+=("  $line")
      done <<< "$list"
    else
      lines+=("The ids are what \`$(pr_init_list_cmd "$cli")\` prints; it was not asked here.")
    fi
    pr_init_problem "${lines[@]}"
    return 1
  fi

  (( rc == 0 )) || return "$rc"
  [[ "${PR_DOCTOR_OFFLINE:-0}" == 1 ]] && return 0

  list="$(pr_init_model_list "$cli")"
  if [[ -z "$list" ]]; then
    # Unvalidated, not refused. The list is not what the adapter needs -- it is
    # only how init checks a pin -- so a list call that fails on a CLI whose auth
    # just passed should cost a warning, not the config.
    printf 'warning: %s=%s was written unchecked; %s did not answer with a model list.\n' \
      "PR_${cli^^}_MODEL" "$model" "$cli" >&2
    return 0
  fi
  if ! pr_doctor_model_listed "$list" "$model"; then
    pr_init_problem "$model is not in \`$(pr_init_list_cmd "$cli")\`." \
                    "The id carries the effort tier, e.g. $(pr_init_model_example "$cli")."
    return 1
  fi
  return 0
}

pr_init_list_cmd() {
  case "$1" in
    agent) printf 'agent --list-models' ;;
    agy)   printf 'agy models' ;;
    *)     printf '%s' "$1" ;;
  esac
}

pr_init_model_example() {
  case "$1" in
    agent) printf 'claude-opus-5-thinking-high' ;;
    agy)   printf 'gemini-3.1-pro-high (ceiling is high, there is no xhigh)' ;;
    *)     printf 'the id its own list prints' ;;
  esac
}

# pr_init_probe_jail <reviewers>
# Only when a reviewer that needs the jail is actually in the roster: bwrap is
# irrelevant to a config naming only codex and Cursor, and failing that machine
# for it would refuse a setup that works.
pr_init_probe_jail() {
  local cli needed=""
  for cli in $1; do
    pr_init_needs_jail "$cli" && needed="${needed}${needed:+, }$cli"
  done
  [[ -z "$needed" ]] && return 0
  pr_init_quiet pr_doctor_check_bwrap_jail && return 0
  pr_init_problem "the bubblewrap jail does not work here, and these refuse to run without it: $needed" \
                  "Run plan-review doctor for the diagnosis; on Ubuntu 24.04 it is usually" \
                  "kernel.apparmor_restrict_unprivileged_userns."
  return 1
}

# pr_init_build_config <reviewers> <pins-json>
#
# Emits the config on stdout. Pure: same arguments, same bytes, which is what
# makes --force idempotent and the generated shape testable without a machine.
#
# Three shapes, and only the ones that differ from another are written (D7). A
# `quick` that resolves exactly as the top level does, or costs what `deep`
# costs, is a lie the file should not contain.
pr_init_build_config() {
  local reviewers="$1" pins="$2"
  local cli first="" count=0 quick_pins='{}' deep_pins='{}' presets='{}'

  # Roster order, not the order they were written: `quick` has to pick one
  # reviewer and PR_ROSTER_ADAPTERS is the order this repo states everywhere
  # else, so the choice is explainable in a sentence (D8).
  for cli in $PR_ROSTER_ADAPTERS; do
    [[ " $reviewers " == *" $cli "* ]] || continue
    [[ -z "$first" ]] && first="$cli"
    count=$((count + 1))
    pr_init_has_effort "$cli" \
      && deep_pins="$(jq -c --arg c "$cli" '.[$c] = {effort: "xhigh"}' <<<"$deep_pins")"
  done

  pr_init_has_effort "$first" \
    && quick_pins="$(jq -c --arg c "$first" '.[$c] = {effort: "low"}' <<<"$quick_pins")"

  # A one-reviewer roster whose CLI has no effort axis would give `quick` the
  # same roster and the same pins as the top level.
  if (( count > 1 )) || [[ "$quick_pins" != '{}' ]]; then
    presets="$(jq -c --arg q "$first" --argjson p "$quick_pins" \
      '.quick = ({reviewers: [$q]} + (if ($p | length) > 0 then {pins: $p} else {} end))' \
      <<<"$presets")"
  fi
  # `deep` omits `reviewers`: an absent list inherits the top-level one, so the
  # preset states its difference and nothing else. With neither codex nor claude
  # in the roster there is no difference to state.
  if [[ "$deep_pins" != '{}' ]]; then
    presets="$(jq -c --argjson p "$deep_pins" '.deep = {pins: $p}' <<<"$presets")"
  fi

  jq -n --argjson reviewers "$(_pr_config_json_array "$reviewers")" \
        --argjson pins "$pins" --argjson presets "$presets" \
        '{reviewers: $reviewers}
         + (if ($pins    | length) > 0 then {pins: $pins}       else {} end)
         + (if ($presets | length) > 0 then {presets: $presets} else {} end)'
}

# pr_init_describe_preset <name> <reviewers> -- one line saying what it changes.
pr_init_describe_preset() {
  local name="$1" reviewers="$2" cli deepens="" flat=""
  case "$name" in
    quick)
      for cli in $PR_ROSTER_ADAPTERS; do
        [[ " $reviewers " == *" $cli "* ]] && { flat="$cli"; break; }
      done
      printf '%s only%s' "$flat" \
        "$(pr_init_has_effort "$flat" && printf ', at effort low')"
      ;;
    deep)
      for cli in $PR_ROSTER_ADAPTERS; do
        [[ " $reviewers " == *" $cli "* ]] || continue
        if pr_init_has_effort "$cli"; then
          deepens="${deepens}${deepens:+, }$cli"
        else
          flat="${flat}${flat:+, }$cli"
        fi
      done
      printf 'effort xhigh for %s' "$deepens"
      [[ -n "$flat" ]] && printf ' (not %s: the tier is inside the model id)' "$flat"
      ;;
  esac
}

# pr_init_gitignore <repo>
#
# 0 when a line was added, 1 when one was already effective. `git check-ignore`
# rather than a grep of .gitignore, because that is the call the doctor makes
# (pr_doctor_check_artifacts_ignored) and the two must not disagree about
# whether this repo is done. It honours .git/info/exclude and core.excludesFile
# as well, so a developer who excluded the path locally gets no new line and
# their colleagues stay un-ignored -- a consequence of matching the doctor,
# which matters more here than uniformity.
pr_init_gitignore() {
  local repo="$1" file="$repo/.gitignore"
  git -C "$repo" check-ignore -q .plan-review/ 2>/dev/null && return 1
  # A file whose last byte is not a newline would otherwise have the new rule
  # welded onto its last line, silently changing a rule someone else wrote.
  if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
    printf '\n' >> "$file" || return 2
  fi
  printf '.plan-review/\n' >> "$file" || return 2
  return 0
}

# pr_init_install <repo> <json>
#
# The bytes are already known good by the time this runs (the caller validates
# them in memory), so this is only about landing them whole: written beside the
# destination and renamed, because mv within one filesystem is atomic and the
# runner must never read a half-written config. The temp name goes in
# PR_INIT_TMP so the entry point's trap can remove it if this is interrupted.
pr_init_install() {
  local repo="$1" json="$2" dir="$repo/.plan-review"
  mkdir -p "$dir" || return 1
  PR_INIT_TMP="$dir/config.json.tmp.$$"
  printf '%s\n' "$json" > "$PR_INIT_TMP" || return 1
  mv "$PR_INIT_TMP" "$dir/config.json" || return 1
  PR_INIT_TMP=""
  return 0
}
