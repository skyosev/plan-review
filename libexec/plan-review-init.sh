#!/usr/bin/env bash
# Writes <repo>/.plan-review/config.json from what is installed on this machine,
# and then runs the doctor over the result.
#
# Usage:
#   plan-review init --repo <dir> [--reviewers a,b] [--pin cli=model]...
#                    [--offline] [--force] [--no-verify]
#
# Cheap refusals first, network next, writes last: everything that can refuse
# does so before `mkdir -p` runs, so a refused init leaves no directory, no
# config and no .gitignore line.
#
# Exit status:
#   0  written, and the doctor is green -- or, under --no-verify, written and
#      its readiness unmeasured
#   1  written, and the doctor is not green
#   2  refused, having written nothing
#
# No inference call is made here or in anything it invokes. The probes reach
# status and list endpoints only, so running this costs nothing.

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/doctor.sh"
source "$PR_ROOT/lib/roster.sh"
source "$PR_ROOT/lib/config.sh"
source "$PR_ROOT/lib/init.sh"

usage() {
  cat <<'EOF'
usage: plan-review init --repo <dir> [options]

  --repo <dir>       the repository to configure (required)
  --reviewers a,b    state the roster instead of deriving it from what is
                     installed. Every name must be a CLI that is present here.
  --pin cli=model    a model id for this run, without exporting anything.
                     Repeatable, once per CLI. `agent` and `agy` require one.
  --offline          skip the auth and model-list probes, here and in the
                     doctor afterwards. The pins are written unvalidated.
  --force            overwrite an existing config
  --no-verify        skip the doctor afterwards. Exit 0 then means "written,
                     readiness unmeasured".
  -h, --help         this text

PR_ORCHESTRATOR is required, exactly as it is for a round and for the doctor: it
says who is driving THIS run, so it is per-run rather than per-project and the
config has no key for it. Carry it on the commands you run next.
EOF
}

die() { printf '%s\n' "$@" >&2; exit 2; }

# The temp file is removed however this exits. A killed init must not leave a
# half-written config.json.tmp.* beside the config it was going to become.
trap '[[ -n "$PR_INIT_TMP" ]] && rm -f "$PR_INIT_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- 1. arguments -----------------------------------------------------------

repo="" reviewers_flag="" reviewers_given=0 offline=0 force=0 verify=1
pin_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)      repo="${2:-}"; shift 2 ;;
    --reviewers)
      (( reviewers_given == 1 )) && die "--reviewers was given twice. One list, comma-separated."
      reviewers_flag="${2:-}"; reviewers_given=1; shift 2 ;;
    --pin)       pin_args+=("${2:-}"); shift 2 ;;
    --offline)   offline=1; shift ;;
    --force)     force=1; shift ;;
    --no-verify) verify=0; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# Contradictions among the arguments are argument errors, and they are reported
# here, before any probe (D15). The generated JSON is validated too, but a
# validator message about a duplicate array element is a poor way to learn you
# typed `codex,codex`. "Set" means non-empty throughout, matching lib/.
pins=""
for arg in ${pin_args[@]+"${pin_args[@]}"}; do
  [[ "$arg" == *=* ]] || die "--pin $arg has no '='. The form is --pin <cli>=<model-id>."
  pin_cli="${arg%%=*}" pin_model="${arg#*=}"
  [[ " $PR_ROSTER_ADAPTERS " == *" $pin_cli "* ]] \
    || die "--pin $arg names '$pin_cli', which is not one of: ${PR_ROSTER_ADAPTERS// /, }" \
           "The name is the adapter's, not the vendor's: Cursor is \`agent\`, Antigravity is \`agy\`."
  [[ -n "$pin_model" ]] || die "--pin $pin_cli= has an empty model id."
  pr_init_lookup "$pins" "$pin_cli" > /dev/null \
    && die "--pin was given twice for $pin_cli. One pin per CLI."
  pins="${pins}${pins:+ }$pin_cli=$pin_model"
done

stated=""
if (( reviewers_given == 1 )); then
  [[ -n "$reviewers_flag" ]] || die "--reviewers was given an empty list."
  rest="$reviewers_flag"
  while :; do
    name="${rest%%,*}"
    [[ -n "$name" ]] \
      || die "--reviewers $reviewers_flag has an empty name in it." \
             "The form is a comma-separated list with nothing missing, e.g. codex,agy."
    [[ " $PR_ROSTER_ADAPTERS " == *" $name "* ]] \
      || die "--reviewers names '$name', which is not one of: ${PR_ROSTER_ADAPTERS// /, }"
    [[ " $stated " == *" $name "* ]] \
      && die "--reviewers names $name twice. One instance per adapter."
    stated="${stated}${stated:+ }$name"
    [[ "$rest" == *,* ]] || break
    rest="${rest#*,}"
  done
fi

# --- 2. the repository, and who is driving ----------------------------------

[[ -n "$repo" ]] || { echo "--repo is required: init writes into a repository." >&2; usage >&2; exit 2; }
[[ -d "$repo" ]] || die "no such directory: $repo"
git -C "$repo" rev-parse --git-dir > /dev/null 2>&1 \
  || die "$repo is not a git repository." \
         "The runner records HEAD and the worktree hash for every round, and the" \
         "doctor decides whether .plan-review/ is ignored with git check-ignore."
repo="$(cd "$repo" && pwd)"

orchestrator="$(pr_roster_orchestrator)" || exit 2

# --- 3. a conflicting environment -------------------------------------------
#
# Each of these makes the verifying doctor describe something other than the file
# just written, and a green doctor that was reading a different config is the one
# outcome worse than a red one. PR_PRESET is the sharpest: lib/config.sh:225
# resolves through it, so the doctor would verify the generated preset rather
# than the top level.
for var in PR_CONFIG PR_ADAPTER_MAP PR_PRESET; do
  [[ -n "${!var:-}" ]] \
    && die "$var=${!var} is set, and init would then verify something other than the" \
           "config it just wrote. Unset it for this command."
done
# Exactly 1, because that is the only value lib/config.sh:211 acts on. Inventing
# a stricter reading of someone else's variable is not init's business.
[[ "${PR_SKIP_CONFIG:-0}" == 1 ]] \
  && die "PR_SKIP_CONFIG=1 says no config applies, and init exists to write one." \
         "Unset it for this command."

# --- 4. what is already there -----------------------------------------------

config_dir="$repo/.plan-review"
config_file="$config_dir/config.json"

# Refused rather than followed, with and without --force: through a symlinked
# .plan-review even the repository-local temporary file resolves somewhere
# nobody named, and rounds would write their artifacts there too.
[[ -L "$config_dir" ]] \
  && die "$config_dir is a symlink. init refuses to write through one: the config," \
         "the temporary file beside it and every round's artifacts would land" \
         "somewhere this repository does not name. Replace it with a directory."
[[ -L "$config_file" ]] \
  && die "$config_file is a symlink. init refuses to write through one; replace it" \
         "with a regular file or remove it."
if [[ -e "$config_file" ]] && (( force == 0 )); then
  die "$config_file already exists." \
      "--force rewrites it whole. There is no merge: a generated roster folded into" \
      "a hand-edited file is a diff problem, not a setup one."
fi

# --- 5. the roster and its pins ---------------------------------------------

roster=""
if (( reviewers_given == 1 )); then
  for cli in $stated; do
    pr_doctor_have "$cli" \
      || die "--reviewers names $cli, which is not on PATH here." \
             "init exists to match this machine; $(pr_doctor_cli_note "$cli"), or leave it out."
  done
  roster="$stated"
else
  for cli in $PR_ROSTER_ADAPTERS; do
    [[ "$cli" == "$orchestrator" ]] && continue
    pr_doctor_have "$cli" || continue
    roster="${roster}${roster:+ }$cli"
  done
fi

printf '%splan-review init%s\n' "$PR_D_BOLD" "$PR_D_RESET"
pr_d_info "repo:         $repo"
pr_d_info "orchestrator: $orchestrator"
for cli in $PR_ROSTER_ADAPTERS; do
  if [[ " $roster " == *" $cli "* ]]; then
    status="reviewer"
  elif ! pr_doctor_have "$cli"; then
    status="not installed"
  elif [[ "$cli" == "$orchestrator" ]]; then
    status="orchestrator — not a candidate for a derived roster"
  else
    status="installed, left out by --reviewers"
  fi
  pr_d_info "$(printf '%-7s %s' "$cli" "$status")"
done

if [[ -z "$roster" ]]; then
  die "" \
      "The roster would be empty, so nothing was written." \
      "Install one of the other CLIs, or name one with --reviewers." \
      "A roster of one is a normal outcome; a roster of none is not a config."
fi

# A stated roster may name the orchestrator's own CLI, and init writes it. This
# project deleted the check that refused such a roster because CLI names do not
# establish model identity, and init knows nothing that check did not.
if [[ " $roster " == *" $orchestrator "* ]]; then
  pr_d_warn "$orchestrator is both the orchestrator and a reviewer here."
  pr_d_info "Obeyed exactly: a CLI name does not establish model identity, so this is a"
  pr_d_info "real roster when the reviewer runs different weights (--pin $orchestrator=<other id>)."
  pr_d_info "Running the same model twice pays twice for one perspective."
fi

for pair in $pins; do
  cli="${pair%%=*}"
  [[ " $roster " == *" $cli "* ]] \
    || die "--pin $pair names $cli, which is not in the roster (${roster// /, })." \
           "A pin for a CLI that is not reviewing would be written and never read."
done

models=""
for cli in $roster; do
  flag_model="$(pr_init_lookup "$pins" "$cli")" || flag_model=""
  env_model="$(pr_init_model_env "$cli")"
  if [[ -n "$flag_model" && -n "$env_model" && "$flag_model" != "$env_model" ]]; then
    die "--pin $cli=$flag_model and PR_${cli^^}_MODEL=$env_model name different models." \
        "The flag does not win here, for the reason --preset does not win over PR_PRESET:" \
        "silently overriding an export is the drift this config exists to expose. Unset one."
  fi
  model="${flag_model:-$env_model}"
  [[ -n "$model" ]] && models="${models}${models:+ }$cli=$model"
done

# --- 6. the probes ----------------------------------------------------------

(( offline == 1 )) && PR_DOCTOR_OFFLINE=1
if (( offline == 1 )); then
  pr_d_info "--offline: no auth or model-list call was made. Candidacy means \"on PATH\","
  pr_d_info "and the pins below are written unvalidated."
fi

for cli in $roster; do
  pr_init_probe "$cli" "$(pr_init_lookup "$models" "$cli" || true)"
done
pr_init_probe_jail "$roster"
pr_init_problems_report || exit 2

# --- 7. the config, built and validated in memory ---------------------------
#
# Nothing is on disk yet, and nothing needs to be: the JSON is small, and
# _pr_config_json_errors reads a file that /dev/stdin can be. Validating here is
# what makes "a refused init leaves no .plan-review/" literally true.

pins_json='{}'
for cli in $roster; do
  model="$(pr_init_lookup "$models" "$cli")" || continue
  pins_json="$(jq -c --arg c "$cli" --arg m "$model" '.[$c] = {model: $m}' <<<"$pins_json")"
done

config_json="$(pr_init_build_config "$roster" "$pins_json")" \
  || die "could not build the config JSON (is jq working?)."

errors="$(_pr_config_json_errors /dev/stdin <<<"$config_json")"
if [[ -n "$errors" ]]; then
  die "init generated a config the runner would reject. This is a bug in init;" \
      "nothing was written. The validator said:" "$errors"
fi

# --- 8. the writes ----------------------------------------------------------

pr_init_gitignore "$repo"
case $? in
  0) ignore_added=1 ;;
  1) ignore_added=0 ;;
  *) die "could not append .plan-review/ to $repo/.gitignore; nothing was written." ;;
esac

if ! pr_init_install "$repo" "$config_json"; then
  # The two files are not transactional, and saying so beats implying otherwise.
  (( ignore_added == 1 )) \
    && die "could not write $config_file, and the .gitignore line was already added." \
           "Remove that line if you are not going to re-run this."
  die "could not write $config_file."
fi

printf '\n'
pr_d_pass "wrote $config_file"
pr_d_info "reviewers: ${roster// /, }"
for preset in quick deep; do
  jq -e --arg p "$preset" '.presets // {} | has($p)' <<<"$config_json" > /dev/null \
    && pr_d_info "$(printf 'preset %-6s %s' "$preset" "$(pr_init_describe_preset "$preset" "$roster")")"
done
if (( ignore_added == 1 )); then
  pr_d_pass "added .plan-review/ to $repo/.gitignore"
  pr_d_info "That is a tracked file in someone else's repository, so it will show up in"
  pr_d_info "the next git status. It is the line the doctor was going to ask for anyway."
else
  pr_d_info ".plan-review/ was already ignored here; no .gitignore line was added."
fi

# D9's cost, printed once. The list no longer adapts when you switch
# orchestrator, which is the price of a file that says what it means.
pr_d_info "The roster is written down, so it no longer follows PR_ORCHESTRATOR. Orchestrating"
pr_d_info "later from a CLI in that list has it review its own work — obeyed exactly and"
pr_d_info "silently. Re-run with --force after switching."
pr_d_info "No criteria were written. See the README's per-project configuration section for"
pr_d_info "house criteria; a placeholder nobody edited would reach every reviewer every round."

for cli in $PR_ROSTER_ADAPTERS; do
  pr_init_has_effort "$cli" || continue
  var="PR_${cli^^}_EFFORT"
  [[ -n "${!var:-}" ]] && {
    pr_d_warn "$var=${!var} is exported, and an environment pin outranks every preset in the"
    pr_d_info "file. quick and deep would run at that effort until you unset it."
  }
done

# --- 9. verification --------------------------------------------------------

if (( verify == 0 )); then
  printf '\n'
  pr_d_info "--no-verify: the config was written and its readiness was not measured."
  exit 0
fi

printf '\n'
doctor_args=(--repo "$repo")
(( offline == 1 )) && doctor_args+=(--offline)
"$PR_ROOT/bin/plan-review" doctor "${doctor_args[@]}"
exit $?
