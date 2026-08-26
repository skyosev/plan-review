#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/prompt.sh"

setup_artifacts() {
  local art="$1"
  mkdir -p "$art/round-1"
  echo "# The Plan v1" > "$art/round-1/plan.snapshot.md"
  echo "codex said this" > "$art/round-1/review-codex.md"
  echo "agy said something else" > "$art/round-1/review-agy.md"
  echo "reply to codex" > "$art/round-1/rationale-codex.md"
  echo "reply to agy" > "$art/round-1/rationale-agy.md"
  printf 'src/a.ts\nsrc/b.ts\n' > "$art/round-1/files-inspected-codex.txt"
  mkdir -p "$art/round-2"
  echo "# The Plan v2" > "$art/round-2/plan.snapshot.md"
  echo "--- a/plan +++ b/plan @@ changed @@" > "$art/round-2/plan.diff"
}

test_round_one_prompt_contains_plan_and_verdict_instruction() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  out="$(pr_build_prompt "$d/art" 1 codex)"
  assert_contains "$out" "# The Plan v1" "plan text inlined"
  assert_contains "$out" "VERDICT:" "verdict sentinel required"
  assert_contains "$out" "FILES-INSPECTED:" "file list required"
  assert_contains "$out" "NO_MATERIAL_OBJECTIONS" "valid values listed"
  assert_contains "$out" "not addressed to you" "the reviewer is told it is not the Integrator"
  # Named commands, not a category. This repository's own plans are reviewed
  # through this prompt and they make claims about commands that orchestrate, so
  # "run a command to check a claim" was too broad: `doctor --smoke` spawns every
  # adapter and spends real tokens. The permitted and forbidden sides are both
  # enumerated, and both spellings are pinned here so neither can quietly widen.
  # `plan-review --help`, not `doctor --show-config`: the latter was in the
  # permitted list until it was found not to run (exits 2 without --repo, and
  # lib/sandbox.sh keeps .plan-review/ out of the reviewer's tree anyway). The
  # permitted side must name a command that actually works.
  assert_contains "$out" "plan-review --help" "read-only investigation is named as allowed"
  assert_contains "$out" "doctor --smoke" "and the one costly doctor flag is named as forbidden"
  assert_contains "$out" "spends real tokens" "with the reason its name does not give away"
}

test_round_one_prompt_has_no_prior_round_sections() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  out="$(pr_build_prompt "$d/art" 1 codex)"
  assert_not_contains "$out" "Your previous critique" "no prior critique in round 1"
  assert_not_contains "$out" "plan.diff" "no diff in round 1"
}

test_round_two_prompt_carries_own_history_forward() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  out="$(pr_build_prompt "$d/art" 2 codex)"
  assert_contains "$out" "# The Plan v2" "current plan"
  assert_contains "$out" "@@ changed @@" "diff included"
  assert_contains "$out" "codex said this" "own prior critique"
  assert_contains "$out" "reply to codex" "own rationale"
  assert_contains "$out" "src/a.ts" "own inspected files"
}

test_round_two_prompt_leaks_nothing_from_other_reviewers() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  out="$(pr_build_prompt "$d/art" 2 codex)"
  assert_not_contains "$out" "agy said something else" "no sibling critique"
  assert_not_contains "$out" "reply to agy" "no sibling rationale"
}

test_fresh_round_carries_no_history_despite_being_round_two() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  out="$(pr_build_prompt "$d/art" 2 codex true)"
  assert_contains "$out" "# The Plan v2" "current plan still present"
  assert_not_contains "$out" "codex said this" "prior critique suppressed"
  assert_not_contains "$out" "reply to codex" "prior rationale suppressed"
  assert_not_contains "$out" "@@ changed @@" "diff suppressed"
  assert_not_contains "$out" "src/a.ts" "prior inspected files suppressed"
}

test_prompt_is_stable_across_calls() {
  # Cache-stable prefix (R2): identical inputs must yield identical bytes.
  local d a b; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  a="$(pr_build_prompt "$d/art" 2 codex)"
  b="$(pr_build_prompt "$d/art" 2 codex)"
  assert_eq "$a" "$b" "no timestamps or nondeterminism in the prompt"
}

test_missing_optional_sections_are_skipped_not_errored() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  rm "$d/art/round-1/files-inspected-codex.txt"
  out="$(pr_build_prompt "$d/art" 2 codex)"
  assert_contains "$out" "codex said this" "still builds"
  assert_not_contains "$out" "Files you inspected" "absent section omitted"
}

# --- project criteria (D10, D11) -------------------------------------------
#
# Appended below the runner contract, never substituted for it. The two files
# are passed together and this function picks, so the test that defines a
# baseline round exists once.

write_criteria() {
  local d="$1"
  printf 'House rule: start from the threat model.\n' > "$d/initial.md"
  printf 'House rule: say whether the objection stands.\n' > "$d/rereview.md"
}

test_a_baseline_round_gets_the_initial_criteria() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"; write_criteria "$d"
  out="$(pr_build_prompt "$d/art" 1 codex false "$d/initial.md" "$d/rereview.md")"
  assert_contains "$out" "start from the threat model" "the project's brief is there"
  assert_not_contains "$out" "whether the objection stands" "and not the other slot's"
}

test_a_history_round_gets_the_rereview_criteria() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"; write_criteria "$d"
  out="$(pr_build_prompt "$d/art" 2 codex false "$d/initial.md" "$d/rereview.md")"
  assert_contains "$out" "whether the objection stands" "the re-review brief"
  assert_not_contains "$out" "start from the threat model" "not the baseline one"
}

# Round type, not round number: --fresh has no critique to react to.
test_a_fresh_round_five_gets_the_initial_criteria() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"; write_criteria "$d"
  out="$(pr_build_prompt "$d/art" 2 codex true "$d/initial.md" "$d/rereview.md")"
  assert_contains "$out" "start from the threat model" "a baseline round again"
}

# The worst a bad criteria file can do is waste reviewer attention. It cannot
# drop "do not push", and it cannot make a round unparseable.
test_criteria_cannot_displace_the_runner_contract() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  printf 'banana\n' > "$d/silly.md"
  out="$(pr_build_prompt "$d/art" 1 codex false "$d/silly.md")"
  assert_contains "$out" "banana" "the file was used"
  assert_contains "$out" "do not push" "and the operational instructions survived"
  assert_contains "$out" "VERDICT:" "with the sentinels"
}

# Emitted above the plan, so the brief is read before the thing it applies to.
test_criteria_are_emitted_before_the_plan() {
  local d out; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"; write_criteria "$d"
  out="$(pr_build_prompt "$d/art" 1 codex false "$d/initial.md")"
  local before="${out%%## The plan under review*}"
  assert_contains "$before" "House rule" "criteria come first"
}

test_no_criteria_is_the_prompt_as_it_was() {
  local d with without; d="$(pr_test_tmpdir)"; setup_artifacts "$d/art"
  with="$(pr_build_prompt "$d/art" 1 codex false "" "")"
  without="$(pr_build_prompt "$d/art" 1 codex)"
  assert_eq "$with" "$without" "empty paths add nothing, not an empty heading"
}

pr_run_tests
