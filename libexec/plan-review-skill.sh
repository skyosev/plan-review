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
source "$PR_ROOT/lib/doctor.sh"   # pr_doctor_have, pr_agent_identity_version

# The one pin, spelled once. It selects the skills CLI for every call below AND
# for the retry lines those calls print, so a bump that reached the call but not
# the paste would hand the operator a different version to debug with. See the
# add below for what the pin is measured against.
SKILLS_PIN="skills@1.5.18"

# printf %q, for the lines that exist to be pasted back into a shell. Carried
# over from scripts/install.sh's q() with its reason intact, because the lines
# came with it: the whole point of this helper is that these get pasted, and a
# checkout path with a space in it otherwise hands the operator a command that
# breaks on the paste. An ordinary path comes through completely untouched. Only
# the PATHS go through it -- the -a ids beside them are bare words by
# construction (the table below), so escaping those would only add noise.
q() { printf '%q' "$1"; }

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

pr_doctor_have npx && pr_doctor_have node || {
  echo "npx and node are needed for the skill, and one of them is not on PATH." >&2
  echo "install it later with: npx $SKILLS_PIN add $(q "$PR_ROOT") -g -a claude-code" >&2
  echo "repeat -a for each one you use: claude-code, codex, cursor, antigravity-cli" >&2
  exit 2
}
pr_doctor_have jq || {
  echo "jq is needed to verify the links, and it is not on PATH." >&2
  exit 2
}

# The same four CLIs lib/roster.sh's PR_ROSTER_ADAPTERS names, spelled again
# because this asks a different question: which harnesses can HOST the skill --
# so it includes the orchestrator, and a fifth one would need a row in the table
# below regardless, which is why the loop is not roster-driven.
#
# That table is the harness ids and display names as the skills CLI spells them,
# read at version 1.5.18 on 2026-08-19 and CONFIRMED against a real 1.5.18 on
# macOS 2026-08-20: all four ids exit 0, and all four display names came back
# exactly as written. Two strings per harness because verification needs both --
# the id selects, the display name is what comes back -- which is why they sit on
# one row rather than in two case statements a caller has to keep aligned.
#
# `agy` is `antigravity-cli`, NOT `antigravity`: skills lists those as two agents
# with two separate global directories, and lib/doctor.sh identifies agy as the
# Antigravity *CLI*.
#
# Re-confirm the table whenever this comment's version goes stale. No offline
# test can check any of it -- a stub reproduces whatever name it is given, which
# is how `antigravity` survived a draft of this file, and tests/helpers.sh's
# PR_TEST_SKILLS_ALL_LINKED fixture hard-codes the same four names, so a
# correction here needs that fixture corrected with it or the suite passes
# against the old world. One fixture, in helpers.sh, because two test files read
# it and a pointer that named only one of them was already wrong. A bad name is
# at least self-diagnosing rather than silent: the verification below prints both
# what it wanted and what came back. Same convention, same reason, as
# lib/doctor.sh's version table.
#
# Moved here from scripts/install.sh, comment and all, when the skill step became
# a subcommand: the bootstrap now calls this rather than re-deriving it.
targets=(); ids=(); names=()
for cli in claude codex agent agy; do
  pr_doctor_have "$cli" || continue
  case "$cli" in
    claude) id=claude-code;     name="Claude Code" ;;
    codex)  id=codex;           name="Codex" ;;
    agent)  id=cursor;          name="Cursor" ;;
    agy)    id=antigravity-cli; name="Antigravity CLI" ;;
  esac
  # `agent` is a generic name; the pure predicate (lib/doctor.sh) is the same
  # rule the doctor's own identity check reports on.
  if [[ "$cli" == agent ]] && ! pr_agent_identity_version > /dev/null 2>&1; then
    echo "the 'agent' on PATH does not answer 'agent about --format json'." >&2
    echo "it looks like a different tool with the same name; skipping Cursor." >&2
    continue
  fi
  targets+=("$cli"); ids+=(-a "$id"); names+=("$name")
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
if ! DISABLE_TELEMETRY=1 npx -y "$SKILLS_PIN" add "$PR_ROOT" -g "${ids[@]}" -y < /dev/null; then
  echo "the skill install failed." >&2
  echo "retry with: DISABLE_TELEMETRY=1 npx -y $SKILLS_PIN add $(q "$PR_ROOT") -g ${ids[*]} -y" >&2
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
out="$(DISABLE_TELEMETRY=1 npx -y "$SKILLS_PIN" ls -g --json < /dev/null 2>/dev/null)" || out=""
if [[ -z "$out" ]]; then
  echo "could not read 'skills ls -g --json'; the links are unverified." >&2
  echo "check it by hand: npx $SKILLS_PIN ls -g --json" >&2
  exit 1
fi
# TWO lines out of one jq: what was wanted and did not come back, then what did.
# The second line is the half the id/name table comment above promises ("a wrong
# name is at least self-diagnosing rather than silent"), and it went missing when
# scripts/install.sh's verify_skill was deleted -- that node program printed
# `skills reports: ...` beside the misses. Without it a mistyped display name
# reads as a bare "not linked into: Antigravity CLI" with nothing to compare it
# against, which is exactly the confusion the table's two-strings-per-harness
# design exists to resolve. $have is already computed here; only printing it was
# lost. `no agent at all` is verify_skill's own wording, kept, because it is the
# case that separates "linked somewhere else" from "this install did nothing".
#
# One command substitution, split with parameter expansion rather than a process
# substitution: `< <(jq ...)` would drop jq's exit status, and that status is the
# unparseable-JSON branch below.
verdict="$(jq -r --args '
    (if type == "array" then . else (.skills // []) end)
    | (map(select(.name == "plan-review")) | first) as $hit
    | (($hit.agents // []) | map(tostring)) as $have
    | ([$ARGS.positional[] | select(. as $w | $have | index($w) | not)] | join(", ")),
      (if ($have | length) == 0 then "no agent at all" else ($have | join(", ")) end)
    ' "${names[@]}" <<< "$out" 2>/dev/null)" || {
  echo "could not parse 'skills ls -g --json'; the links are unverified." >&2
  echo "check it by hand: npx $SKILLS_PIN ls -g --json" >&2
  exit 1
}
missing="${verdict%%$'\n'*}"
have="${verdict#*$'\n'}"
if [[ -n "$missing" ]]; then
  echo "not linked into: $missing" >&2
  echo "skills reports: $have" >&2
  echo "a harness you have never launched reports this way whether linked or not." >&2
  echo "check it by hand: npx $SKILLS_PIN ls -g --json" >&2
  exit 1
fi
echo "verified: the skill is linked into: ${targets[*]}"
