#!/usr/bin/env bash
# Installs and verifies the plan-review skill, via the third-party `skills` CLI,
# into the global directory of every harness detected on PATH.
#
# Usage: plan-review skill
#
# scripts/install.sh calls this the way it already calls `install` and
# `doctor --offline`: the bootstrap re-derives none of these rules, because the
# second derivation is the one that goes stale. There the call is wrapped
# non-fatally -- the bootstrap's promise is the RUNNER -- so the fatal version of
# every failure lives here, for direct invocations:
#
# Exit status:
#   0  installed (or already present) and verified for every detected harness
#   1  the install ran and failed, or the links could not be verified
#   2  refused before doing anything: npx/node or jq missing, or no harness found
#
# jq, not node: unlike scripts/install.sh this file may require jq -- it is a
# hard requirement of plan-review itself (PR_DOCTOR_UTILS) -- which is what lets
# the bootstrap's node JSON parser retire with the relocation.

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/doctor.sh"   # pr_agent_identity_version, pr_doctor_run

usage() {
  cat <<'USAGE'
usage: plan-review skill

Installs the plan-review skill globally, once, for every harness found on PATH
(claude, codex, agent, agy), then verifies the links via `skills ls -g --json`.

  -h, --help    this text
USAGE
}

case "${1-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
esac

# Harness ids and display names as the skills CLI spells them, read at version
# 1.5.18 on 2026-08-19 and CONFIRMED against a real 1.5.18 on macOS 2026-08-20:
# all four ids exit 0, and all four display names came back exactly as written
# below. Two strings per harness because verification needs both: the id selects,
# the display name is what comes back.
#
# `agy` is `antigravity-cli`, NOT `antigravity`: skills lists those as two agents
# with two separate global directories, and lib/doctor.sh identifies agy as the
# Antigravity *CLI*.
#
# Re-confirm both tables whenever this comment's version goes stale. No offline
# test can check any of them -- a stub reproduces whatever name it is given, which
# is how `antigravity` survived a draft of this file, and tests/test-skill.sh's
# ALL_LINKED fixture hard-codes the same four names, so a correction here needs the
# fixture corrected with it or the suite passes against the old world. A wrong name
# is at least self-diagnosing rather than silent: the verification below prints
# both what it wanted and what came back. Same convention, same reason, as
# lib/doctor.sh's version table.
#
# Moved here from scripts/install.sh, comment and all, when the skill step became
# a subcommand: the bootstrap now calls this rather than re-deriving it.
skill_id_for() {
  case "$1" in
    claude) printf 'claude-code\n' ;;
    codex)  printf 'codex\n' ;;
    agent)  printf 'cursor\n' ;;
    agy)    printf 'antigravity-cli\n' ;;
  esac
}

skill_name_for() {
  case "$1" in
    claude) printf 'Claude Code\n' ;;
    codex)  printf 'Codex\n' ;;
    agent)  printf 'Cursor\n' ;;
    agy)    printf 'Antigravity CLI\n' ;;
  esac
}

command -v npx > /dev/null 2>&1 && command -v node > /dev/null 2>&1 || {
  echo "npx and node are needed for the skill, and one of them is not on PATH." >&2
  echo "install it later with: npx skills@1.5.18 add $PR_ROOT -g -a claude-code" >&2
  echo "repeat -a for each one you use: claude-code, codex, cursor, antigravity-cli" >&2
  exit 2
}
command -v jq > /dev/null 2>&1 || {
  echo "jq is needed to verify the links, and it is not on PATH." >&2
  exit 2
}

# The same four CLIs lib/roster.sh's PR_ROSTER_ADAPTERS names, spelled again
# because this asks a different question: which harnesses can HOST the skill --
# so it includes the orchestrator, and a fifth one would need skill_id_for and
# skill_name_for entries regardless.
targets=(); ids=(); names=()
for cli in claude codex agent agy; do
  command -v "$cli" > /dev/null 2>&1 || continue
  # `agent` is a generic name; the pure predicate (lib/doctor.sh) is the same
  # rule the doctor's own identity check reports on.
  if [[ "$cli" == agent ]] && ! pr_agent_identity_version > /dev/null 2>&1; then
    echo "the 'agent' on PATH does not answer 'agent about --format json'." >&2
    echo "it looks like a different tool with the same name; skipping Cursor." >&2
    continue
  fi
  targets+=("$cli"); ids+=(-a "$(skill_id_for "$cli")"); names+=("$(skill_name_for "$cli")")
done
(( ${#targets[@]} > 0 )) || {
  echo "no supported harness on PATH (claude, codex, agent, agy); nothing to install into." >&2
  exit 2
}

echo "installing the skill for: ${targets[*]}"
# ONE add for every harness, not one per harness. Two -y flags belonging to two
# programs: the leading one is npm's "do not ask before fetching", the trailing
# one the skills CLI's own "do not prompt". DISABLE_TELEMETRY because this runs
# on the user's behalf. stdin closed: under the bootstrap's `curl | bash`,
# stdin is the script itself. @1.5.18 pins the CLI to the version the id table
# and the ls-parse behavior were measured at -- an unpinned npx floats silently
# and no doctor check watches it; bumping the pin means re-running those
# measurements first.
if ! DISABLE_TELEMETRY=1 npx -y skills@1.5.18 add "$PR_ROOT" -g "${ids[@]}" -y < /dev/null; then
  echo "the skill install failed." >&2
  echo "retry with: DISABLE_TELEMETRY=1 npx -y skills@1.5.18 add $PR_ROOT -g ${ids[*]} -y" >&2
  exit 1
fi

# One `skills ls -g --json`, then the real question: does plan-review's agents
# array contain the display name of every harness just installed for? Exact
# names, not array-non-empty -- the CLI attributes skills to agents outside any
# filter, and name presence alone was measured lying too (an install that
# produced no Claude Code link still printed plan-review, annotated `not
# linked`; skills 1.5.18, 2026-08-19). A missing name is not always a missing
# link either: ls attributes a skill to an agent only when that agent's config
# directory exists in the same HOME (measured on macOS, 2026-08-20), so the
# failure message below stays honest about that.
out="$(DISABLE_TELEMETRY=1 npx -y skills@1.5.18 ls -g --json < /dev/null 2>/dev/null)" || out=""
if [[ -z "$out" ]]; then
  echo "could not read 'skills ls -g --json'; the links are unverified." >&2
  echo "check it by hand: npx skills@1.5.18 ls -g --json" >&2
  exit 1
fi
missing="$(jq -r --args '
    (if type == "array" then . else (.skills // []) end)
    | (map(select(.name == "plan-review")) | first) as $hit
    | (($hit.agents // []) | map(tostring)) as $have
    | [$ARGS.positional[] | select(. as $w | $have | index($w) | not)]
    | join(", ")' "${names[@]}" <<< "$out" 2>/dev/null)" || {
  echo "could not parse 'skills ls -g --json'; the links are unverified." >&2
  echo "check it by hand: npx skills@1.5.18 ls -g --json" >&2
  exit 1
}
if [[ -n "$missing" ]]; then
  echo "not linked into: $missing" >&2
  echo "a harness you have never launched reports this way whether linked or not." >&2
  echo "check it by hand: npx skills@1.5.18 ls -g --json" >&2
  exit 1
fi
echo "verified: the skill is linked into: ${targets[*]}"
