#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/roster.sh"

# pr_roster_orchestrator reads the environment, so each case runs it in a
# subshell with the variable set (or explicitly unset) rather than mutating the
# suite's own environment.
orch_run() {  # orch_run <value-or-UNSET>
  if [[ "$1" == UNSET ]]; then
    ( unset PR_ORCHESTRATOR; pr_roster_orchestrator; printf ' rc=%s' "$?" ) 2>&1
  else
    ( PR_ORCHESTRATOR="$1"; pr_roster_orchestrator; printf ' rc=%s' "$?" ) 2>&1
  fi
}

# --- resolving the orchestrator --------------------------------------------

test_a_valid_orchestrator_is_echoed() {
  local name
  for name in codex agent agy claude none; do
    assert_eq "$(orch_run "$name")" "$name rc=0" "$name resolves to itself"
  done
}

# Unset is refused rather than defaulted. Every available default is silently
# wrong for someone, and a self-reviewing round leaves no evidence behind.
test_an_unset_orchestrator_is_refused_with_the_values_named() {
  local out; out="$(orch_run UNSET)"
  assert_contains "$out" "PR_ORCHESTRATOR is unset" "says what is missing"
  assert_contains "$out" "codex | agent | agy | claude" "names the CLIs"
  assert_contains "$out" "none" "and the no-agent case"
  assert_contains "$out" "not independent" "says why it matters"
  assert_contains "$out" "rc=1" "a refusal"
}

test_an_unknown_orchestrator_is_refused_by_adapter_name() {
  local out; out="$(orch_run cursor)"
  assert_contains "$out" "is not one of" "rejected"
  assert_contains "$out" "Cursor is \`agent\`" "points at the adapter name"
  assert_contains "$out" "rc=1" "a refusal"
}

# --- deriving the roster ----------------------------------------------------

test_the_default_roster_is_every_adapter_but_the_orchestrator() {
  local map; map="$(pr_roster_default_map claude)"
  assert_contains "$map" "codex=$PR_ROOT/adapters/codex.sh" "codex reviews"
  assert_contains "$map" "agent=$PR_ROOT/adapters/agent.sh" "Cursor reviews"
  assert_contains "$map" "agy=$PR_ROOT/adapters/agy.sh" "agy reviews"
  assert_not_contains "$map" "claude=" "the orchestrator does not"
}

test_each_orchestrator_gets_three_reviewers() {
  local orch map; local -a n
  for orch in codex agent agy claude; do
    map="$(pr_roster_default_map "$orch")"
    read -ra n <<< "$map"   # builtin: BSD wc pads its count, GNU does not
    assert_eq "${#n[@]}" "3" "$orch orchestrating leaves three reviewers"
    assert_not_contains "$map" "$orch=" "$orch is not in its own roster"
  done
}

# A human at a terminal is not a reviewer, so nothing has to be excluded.
test_none_means_every_adapter_reviews() {
  local map; local -a n; map="$(pr_roster_default_map none)"
  read -ra n <<< "$map"
  assert_eq "${#n[@]}" "4" "all four review"
}

# --- an explicit roster ------------------------------------------------------
#
# There is no conflict check any more. It tested CLI-name equality while the
# property that matters is model identity, and it was wrong in both directions:
# it refused an opus orchestrator reviewing on sonnet and permitted Cursor
# pinned to claude-opus-5 beside an opus orchestrator.

test_a_named_reviewer_list_becomes_a_map() {
  local map; map="$(pr_roster_map "codex agy")"
  assert_eq "$map" "codex=$PR_ROOT/adapters/codex.sh agy=$PR_ROOT/adapters/agy.sh" \
    "keys and adapter basenames are the same string"
}

test_a_list_naming_the_orchestrator_is_obeyed() {
  local map; map="$(PR_ADAPTER_MAP="" pr_roster_resolve_map claude "claude codex")"
  assert_contains "$map" "claude=$PR_ROOT/adapters/claude.sh" \
    "a stated list is stated, not filtered"
  assert_contains "$map" "codex=$PR_ROOT/adapters/codex.sh" "and the rest of it too"
}

test_adapter_map_outranks_the_reviewer_list() {
  local map; map="$(PR_ADAPTER_MAP="peer=/tmp/fake.sh" pr_roster_resolve_map claude "codex")"
  assert_eq "$map" "peer=/tmp/fake.sh" "the escape hatch is still the top of the order"
}

test_no_list_falls_back_to_the_derived_default() {
  local map; map="$(PR_ADAPTER_MAP="" pr_roster_resolve_map claude "")"
  assert_eq "$map" "$(pr_roster_default_map claude)" "the default is what a default is for"
}

# --- membership -------------------------------------------------------------

pr_run_tests
