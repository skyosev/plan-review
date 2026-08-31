#!/usr/bin/env bash
# Checks that everything a review round needs is actually in place, before a round
# spends minutes discovering it is not.
#
# Usage:
#   plan-review doctor [--repo <dir> [--plan <rel.md>] [--preset <name>]
#                      [--show-config]] [--offline]
#
# Exit status is 1 only when something would stop a round working. Version drift
# and unset model pins are reported and do not fail: the point is a diagnosis, not
# a gate.
#
# No inference call is made anywhere in here unless --smoke asks for one. The
# auth checks use status and list endpoints only, so the default run costs
# nothing; --smoke sends each reviewer one trivial prompt end to end, which is
# the one check that spends tokens and the reason it is opt-in.

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/lock.sh"
source "$PR_ROOT/lib/round.sh"
source "$PR_ROOT/lib/doctor.sh"
source "$PR_ROOT/lib/adapter-exec.sh"
source "$PR_ROOT/lib/roster.sh"
source "$PR_ROOT/lib/config.sh"
source "$PR_ROOT/lib/version.sh"

usage() {
  cat <<'EOF'
usage: plan-review doctor [options]

  --repo <dir>       also check a target repository's readiness, and read its
                     .plan-review/config.json
  --plan <rel.md>    with --repo: check this plan and whether a round is blocked
  --preset <name>    with --repo: resolve the config through this preset
  --show-config      with --repo: print the resolved configuration as JSON and
                     exit, running no other check and writing nothing
  --offline          skip the auth and model-list checks (no network)
  --smoke            also send each reviewer one trivial prompt end to end,
                     through its adapter exactly as a round would. The only
                     doctor check that spends tokens. Deadline per reviewer:
                     PR_SMOKE_TIMEOUT_SECS (default 90)
  -h, --help         this text

PR_ORCHESTRATOR is required, exactly as it is for a round: with no config it is
what the roster is derived from, and it is the only record of who drove a round.
Use `none` when no agent is orchestrating.
EOF
}

repo="" plan_rel="" offline=0 preset="" show_config=0 smoke=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        repo="${2:-}"; shift 2 ;;
    --plan)        plan_rel="${2:-}"; shift 2 ;;
    --preset)      preset="${2:-}"; shift 2 ;;
    --show-config) show_config=1; shift ;;
    --offline)     offline=1; shift ;;
    --smoke)       smoke=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Everything --smoke requires, in one place. It is NOT refused next to
# --show-config: that path exits before any check runs, so --smoke is inert
# there, exactly as --offline has always silently been.
if (( smoke == 1 )); then
  if (( offline == 1 )); then
    echo "--smoke and --offline contradict each other: --smoke is a live call per" >&2
    echo "reviewer, --offline promises none." >&2
    exit 2
  fi
  # The same rule, the same reason and nearly the same words as the round's
  # check on PR_TIMEOUT_SECS: the smoke hands the value to the adapters AS
  # their PR_TIMEOUT_SECS, and adapters/agy.sh does integer arithmetic on it.
  PR_SMOKE_TIMEOUT_SECS="${PR_SMOKE_TIMEOUT_SECS:-90}"
  if [[ ! "$PR_SMOKE_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]]; then
    echo "PR_SMOKE_TIMEOUT_SECS must be a positive whole number of seconds, got: $PR_SMOKE_TIMEOUT_SECS" >&2
    exit 2
  fi
fi

if [[ -n "$plan_rel" && -z "$repo" ]]; then
  echo "--plan needs --repo: the path is repo-relative." >&2
  exit 2
fi

# Both for the same reason as --plan: there is no config to select a preset from,
# or to print, until a repository says where to look for one.
if [[ -n "$preset" && -z "$repo" ]]; then
  echo "--preset needs --repo: the config lives in the target repository." >&2
  exit 2
fi
if (( show_config == 1 )) && [[ -z "$repo" ]]; then
  echo "--show-config needs --repo: there is no configuration without one." >&2
  exit 2
fi

# Same requirement, and the same refusal, as libexec/plan-review-round.sh.
orchestrator="$(pr_roster_orchestrator)" || exit 2

# Resolved exactly as a round would resolve it, including the exports: the pin
# checks below read PR_*_MODEL and must see what the round will see.
if [[ -n "$repo" ]]; then
  pr_config_resolve "$repo" "$preset" || exit 2
fi

# One authoritative adapter map, and every check below derives from it. Keyed on
# the PATH, never on the key: PR_ADAPTER_MAP may alias one adapter under another
# name and a test may run a fake under a real one, so a name-keyed doctor would
# demand a vendor login for a fake and miss an alias entirely. This is the rule
# pr_doctor_preflight already follows; the two now agree by construction.
adapter_map="$(pr_roster_resolve_map "$orchestrator" "$PR_CONFIG_REVIEWERS")"

reviewer_keys="$(pr_roster_keys "$adapter_map")"
shipped="" custom=""
for pair in $adapter_map; do
  key="${pair%%=*}" path="${pair#*=}" name=""
  for cli in $PR_ROSTER_ADAPTERS; do
    [[ "$path" == "$PR_ROOT/adapters/$cli.sh" ]] && name="$cli"
  done
  if [[ -z "$name" ]]; then
    custom="${custom}${custom:+ }$key"
  elif [[ " $shipped " != *" $name "* ]]; then
    shipped="${shipped}${shipped:+ }$name"
  fi
done

if (( show_config == 1 )); then
  # Deliberately narrow: it resolves and validates exactly as a round would, then
  # prints. No auth call, no version check, no jail probe, no round state, and
  # nothing written anywhere. It answers "what would a round do right now, and
  # why", which is the question the environment-wins precedence rule creates.
  # The hash is taken over the same bytes a round would take it over: the
  # criteria sources here, the round's own copies of them there.
  jq -n --arg orchestrator "$orchestrator" \
        --arg map "$adapter_map" \
        --argjson config "$(pr_config_record \
          "$(pr_config_hash "$reviewer_keys" \
             "$PR_CONFIG_CRITERIA_INITIAL" "$PR_CONFIG_CRITERIA_REREVIEW")")" \
        '$config + {orchestrator: $orchestrator,
                    adapter_map: ($map | split(" ") | map(select(. != "")) | map(split("="))
                                  | map({(.[0]): .[1]}) | add // {})}'
  # Printed first, then judged: the resolved values are exactly what someone
  # debugging a refusal needs to see. The exit status mirrors the round's, so
  # "would a round start right now" is answerable by this command alone.
  pr_config_check_efforts || exit 2
  exit 0
fi

printf '%splan-review doctor%s  %s\n' "$PR_D_BOLD" "$PR_D_RESET" "$(pr_version)"
pr_d_info "orchestrator: $orchestrator — reviewers: ${reviewer_keys// /, }"
[[ -n "$PR_CONFIG_PATH" ]] && pr_d_info "config: $PR_CONFIG_PATH${PR_CONFIG_PRESET:+ (preset: $PR_CONFIG_PRESET)}"
[[ -n "$custom" ]] && pr_d_info "adapters this repo does not ship, and therefore does not check: $custom"

pr_d_section "Machine"
pr_doctor_check_bash
pr_doctor_check_utils
pr_doctor_check_gnu_timeout
pr_doctor_check_ps_forms
for cli in $PR_ROSTER_ADAPTERS; do
  if [[ " $shipped " != *" $cli "* ]]; then
    pr_d_skip "$cli is not in this round's roster"
    continue
  fi
  pr_doctor_check_cli "$cli"
  # `agent` is a generic name, so presence on PATH is not identity.
  [[ "$cli" == agent ]] && pr_doctor_check_agent_identity
done
# Only when a reviewer that needs the jail is actually in the roster. It used to
# be unconditional, on the premise that one of agy and claude is always
# reviewing -- which a config naming only codex makes false, and which would
# then FAIL a machine for missing bwrap on a round that never needed it.
# agent is the third case, added 2026-08-27: its adapter now wraps every vendor
# invocation in a pid-namespace bwrap, so "no reviewer here needs the jail" was
# false for a codex+agent roster. It gets a WARN-only check, because that
# adapter runs unwrapped rather than refusing -- see pr_doctor_check_agent_pid_fence.
# claude stopped being one of the two unconditional cases on 2026-08-30: it now
# picks its confinement per host (bwrap where it exists, Claude Code's own
# sandbox where it does not), so it needs the jail probe only on the first half
# -- and on the second half a missing bwrap is not a defect to report. agy is
# the last reviewer that REQUIRES bubblewrap and refuses without it.
needs_jail=""
[[ " $shipped " == *" agy "* ]] && needs_jail="agy"
[[ " $shipped " == *" claude "* ]] && pr_doctor_have bwrap && needs_jail="${needs_jail:+$needs_jail }claude"

if [[ -n "$needs_jail" ]]; then
  pr_doctor_check_bwrap_jail
elif [[ " $shipped " == *" agent "* ]]; then
  pr_doctor_check_agent_pid_fence
else
  pr_d_skip "no reviewer here needs the bubblewrap jail"
fi
# Always, when claude is on the roster: it says which half the adapter will take
# and checks that half's own prerequisites, which the jail probe knows nothing
# about -- credentials to materialise on a Mac, and on any other platform with no
# bwrap the fact that there is no second mechanism at all and the adapter will
# refuse (2026-08-30: Claude Code's own sandbox is built on bubblewrap here).
[[ " $shipped " == *" claude "* ]] && pr_doctor_check_claude_confinement
pr_doctor_check_cache_root

pr_d_section "Reviewer CLIs"
if (( offline == 1 )); then
  # Read by pr_doctor_check_pins, which would otherwise fetch Cursor's model
  # list to validate PR_AGENT_MODEL.
  PR_DOCTOR_OFFLINE=1
  pr_d_info "--offline: skipped the auth and model-list checks."
else
  # Every shipped adapter has a pr_doctor_check_<cli>_auth; $shipped only ever
  # holds names from PR_ROSTER_ADAPTERS, so the convention is the dispatch.
  for cli in $shipped; do "pr_doctor_check_${cli}_auth"; done
fi
[[ " $shipped " == *" agy "* ]] && pr_doctor_check_agy_print_timeout
# The effort checks exist for exactly the CLIs with a PR_EFFORTS_<CLI> enum.
for cli in $shipped; do
  enum="PR_EFFORTS_${cli^^}"
  [[ -n "${!enum:-}" ]] && "pr_doctor_check_${cli}_effort"
done
pr_doctor_check_pins "$shipped"

pr_d_section "Versions"
pr_doctor_check_versions "$shipped" "$orchestrator"

if [[ -n "$repo" ]]; then
  pr_d_section "Project config"
  if [[ -z "$PR_CONFIG_PATH" ]]; then
    pr_d_info "no .plan-review/config.json; the roster, pins and prompt are the defaults."
  else
    pr_d_pass "config parsed and resolved: $PR_CONFIG_PATH"
    pr_d_info "reviewers: ${PR_CONFIG_REVIEWERS:-(derived from PR_ORCHESTRATOR)}"
    [[ -n "$PR_CONFIG_PRESET" ]] && pr_d_info "preset: $PR_CONFIG_PRESET"
    # The globals are named PR_CONFIG_CRITERIA_<SLOT^^>, so the loop reads them by
    # indirection. A `case` re-listing the slots defeated the point of the list.
    for slot in $PR_CONFIG_SLOTS; do
      file="PR_CONFIG_CRITERIA_${slot^^}"
      [[ -n "${!file:-}" ]] && pr_d_info "criteria.$slot: ${!file}"
    done
    pr_d_info "Run with --show-config to see the resolved pins and where each came from."
  fi

  pr_d_section "Target repo"
  # The later checks all assume a git repository at $repo, so stop this section
  # when that is false rather than reporting three consequences of one cause.
  if pr_doctor_check_repo "$repo"; then
    pr_doctor_check_artifacts_ignored "$repo"
    if [[ -n "$plan_rel" ]]; then
      pr_doctor_check_plan "$repo" "$plan_rel" \
        && pr_doctor_check_rounds "$repo" "$plan_rel"
    else
      pr_d_info "No --plan given; skipped the plan and blocked-round checks."
    fi
  fi
fi

# Last on purpose: it is the expensive check, and a smoke failure is best read
# under the cheap diagnoses above it -- a reviewer that fails here after its
# auth check failed is one problem, not two.
if (( smoke == 1 )); then
  pr_d_section "Smoke"
  pr_d_info "one live prompt per reviewer, ${PR_SMOKE_TIMEOUT_SECS}s deadline each;"
  pr_d_info "this is the only doctor check that spends tokens."
  pr_doctor_check_smoke "$adapter_map" "$PR_SMOKE_TIMEOUT_SECS"
fi

printf '\n%s\n' '――――――――――――'
printf '%d passed, %d warned, %d failed\n' \
  "$PR_DOCTOR_PASS" "$PR_DOCTOR_WARN" "$PR_DOCTOR_FAIL"

if (( PR_DOCTOR_FAIL > 0 )); then
  exit 1
fi
exit 0
