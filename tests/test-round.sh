#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/round.sh"

make_repo() {
  local root="$1"
  mkdir -p "$root/docs"
  git -C "$root" init -q
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name Test
  echo "# plan" > "$root/docs/plan.md"
  git -C "$root" add -A
  git -C "$root" commit -qm init
}

# Mirrors the runner's write_result. Kept here so the record's shape is asserted
# in one place and these tests do not depend on libexec/plan-review-round.sh.
# result_file <path> <status> <detail> <verdict> <session> <model> <effort> <cli>
result_file() {
  jq -n --arg status "$2" --arg detail "$3" --arg verdict "$4" \
        --arg session "$5" --arg model "$6" --arg effort "$7" --arg cli "$8" \
        '{$status, $detail, $verdict, $session, $model, $effort, $cli}' > "$1"
}

test_round_dir_is_numbered() {
  assert_eq "$(pr_round_dir /a/b 3)" "/a/b/round-3" "round dir"
}

test_grounding_records_sha_and_clean_flag() {
  local d g; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  g="$(pr_git_grounding "$d/repo" docs/plan.md)"
  assert_eq "$(jq -r '.is_dirty_worktree' <<<"$g")" "false" "clean tree"
  assert_eq "$(jq -r '.git_head_sha | length' <<<"$g")" "40" "full sha"
  assert_eq "$(jq -r '.plan_content_hash | length' <<<"$g")" "64" "plan sha256"
}

test_grounding_detects_a_dirty_tree() {
  local d g; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  echo "edit" >> "$d/repo/docs/plan.md"
  g="$(pr_git_grounding "$d/repo" docs/plan.md)"
  assert_eq "$(jq -r '.is_dirty_worktree' <<<"$g")" "true" "dirty tree"
}

test_worktree_hash_changes_when_dirty_content_changes() {
  # The case git_head_sha + is_dirty_worktree cannot detect (R5).
  local d h1 h2; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  echo "first" >> "$d/repo/docs/plan.md"
  h1="$(jq -r '.worktree_content_hash' <<<"$(pr_git_grounding "$d/repo" docs/plan.md)")"
  echo "second" >> "$d/repo/docs/plan.md"
  h2="$(jq -r '.worktree_content_hash' <<<"$(pr_git_grounding "$d/repo" docs/plan.md)")"
  [[ "$h1" != "$h2" ]] || pr_fail "worktree hash must change with dirty content"
}

test_worktree_hash_covers_untracked_files() {
  local d h1 h2; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  h1="$(jq -r '.worktree_content_hash' <<<"$(pr_git_grounding "$d/repo" docs/plan.md)")"
  echo "new" > "$d/repo/docs/extra.md"
  h2="$(jq -r '.worktree_content_hash' <<<"$(pr_git_grounding "$d/repo" docs/plan.md)")"
  [[ "$h1" != "$h2" ]] || pr_fail "untracked file must change the hash"
}

test_round_init_writes_reviewing_state() {
  local d rd; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  rd="$d/art/round-1"
  pr_round_init "$rd" 1 "$d/repo" docs/plan.md
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "reviewing" "initial state"
  assert_eq "$(jq -r '.round' < "$rd/round.json")" "1" "round number"
  assert_eq "$(jq -r '.reviewers | length' < "$rd/round.json")" "0" "no results yet"
  assert_eq "$(jq -r '.fresh' < "$rd/round.json")" "false" "not a baseline by default"
}

test_round_init_marks_a_fresh_baseline() {
  local d rd; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  rd="$d/art/round-7"
  pr_round_init "$rd" 7 "$d/repo" docs/plan.md true
  assert_eq "$(jq -r '.fresh' < "$rd/round.json")" "true" "baseline recorded"
  assert_eq "$(jq -r '.round' < "$rd/round.json")" "7" "numbering not reset by a baseline"
}

test_record_reviewer_accumulates_results() {
  local d rd; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  rd="$d/art/round-1"
  pr_round_init "$rd" 1 "$d/repo" docs/plan.md
  result_file "$d/ok.json" ok "" MINOR sess-1 gpt-5.6-sol xhigh 0.147.0
  result_file "$d/bad.json" failed "timed out after 900s" UNPARSEABLE "" "" "" ""
  pr_round_record_reviewer "$rd" codex "$d/ok.json"
  pr_round_record_reviewer "$rd" agy "$d/bad.json"
  assert_eq "$(jq -r '.reviewers.codex.verdict' < "$rd/round.json")" "MINOR" "codex verdict"
  assert_eq "$(jq -r '.reviewers.codex.model' < "$rd/round.json")" "gpt-5.6-sol" "effective model"
  assert_eq "$(jq -r '.reviewers.codex.effort' < "$rd/round.json")" "xhigh" "effective effort"
  assert_eq "$(jq -r '.reviewers.codex.cli_version' < "$rd/round.json")" "0.147.0" "cli version"
  assert_eq "$(jq -r '.reviewers.codex.session_id' < "$rd/round.json")" "sess-1" "session id"
  assert_eq "$(jq -r '.reviewers.agy.status' < "$rd/round.json")" "failed" "agy failed"
  assert_contains "$(jq -r '.reviewers.agy.detail' < "$rd/round.json")" "timed out" "reason kept"
}

# An empty effort is normal, not a gap: Cursor and agy fold effort into the model
# id, so only codex has a value to report here.
test_record_reviewer_accepts_an_empty_effort() {
  local d rd; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  rd="$d/art/round-1"
  pr_round_init "$rd" 1 "$d/repo" docs/plan.md
  result_file "$d/cur.json" ok "" MINOR uuid-1 claude-opus-5-medium "" 2026.08.11
  pr_round_record_reviewer "$rd" agent "$d/cur.json"
  assert_eq "$(jq -r '.reviewers.agent.effort' < "$rd/round.json")" "" "empty, not null"
  assert_eq "$(jq -r '.reviewers.agent.model' < "$rd/round.json")" "claude-opus-5-medium" "id carries it"
}

test_set_state_advances_the_lifecycle() {
  local d rd; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  rd="$d/art/round-1"
  pr_round_init "$rd" 1 "$d/repo" docs/plan.md
  pr_round_set_state "$rd" awaiting_integration
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "awaiting_integration" "runner finalizes"
  pr_round_set_state "$rd" complete
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "complete" "integrator finalizes"
}

test_set_state_rejects_unknown_states() {
  local d rd rc; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  rd="$d/art/round-1"
  pr_round_init "$rd" 1 "$d/repo" docs/plan.md
  pr_round_set_state "$rd" almost_done 2>/dev/null; rc=$?
  assert_exit_code "$rc" 1 "unknown state rejected"
  assert_eq "$(jq -r '.state' < "$rd/round.json")" "reviewing" "state unchanged"
}

# Regression guard. `local rd="$1" tmp="$rd/..."` in one statement leaves $rd
# unbound inside the callee, but bash's dynamic scoping hid that for as long as
# every caller here happened to name its own variable `rd` too — the callee then
# resolved $rd to the CALLER's variable, which held the same value. The runner
# (Task 10) names it `round_dir`, so it would have been the first caller to trip
# it. This test deliberately does not use the name `rd`.
test_set_state_does_not_depend_on_the_callers_variable_name() {
  local d round_dir; d="$(pr_test_tmpdir)"; make_repo "$d/repo"
  round_dir="$d/art/round-1"
  pr_round_init "$round_dir" 1 "$d/repo" docs/plan.md
  pr_round_set_state "$round_dir" awaiting_integration
  assert_eq "$(jq -r '.state' < "$round_dir/round.json")" "awaiting_integration" \
    "state advances regardless of the caller's variable name"
}

pr_run_tests
