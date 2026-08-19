#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/paths.sh"

test_plan_slug_replaces_separators_and_strips_extension() {
  assert_eq "$(pr_plan_slug 'docs/plans/feat.md')" "docs--plans--feat" "nested path"
  assert_eq "$(pr_plan_slug 'PLAN.md')" "PLAN" "top-level file"
}

test_plan_slug_rejects_absolute_paths() {
  local out rc
  out="$(pr_plan_slug '/abs/plan.md' 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "absolute path rejected"
  assert_contains "$out" "repo-relative" "explains why"
}

test_plan_slug_rejects_parent_traversal() {
  local out rc
  out="$(pr_plan_slug '../outside.md' 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "leading .. rejected"
  out="$(pr_plan_slug 'docs/../../outside.md' 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "embedded .. rejected"
}

test_key_hash_is_stable_and_short() {
  local a b
  a="$(pr_key_hash /home/stoyan/code/foo docs/p.md)"
  b="$(pr_key_hash /home/stoyan/code/foo docs/p.md)"
  assert_eq "$a" "$b" "same input, same hash"
  assert_eq "${#a}" 8 "hash is 8 chars"
}

test_key_hash_differs_between_repos() {
  local a b
  a="$(pr_key_hash /home/stoyan/code/foo docs/p.md)"
  b="$(pr_key_hash /home/stoyan/code/bar docs/p.md)"
  [[ "$a" != "$b" ]] || pr_fail "different repos must not collide"
}

# 'a/b.md' and 'a--b.md' flatten to the same slug. The hash covers the exact
# relative path, so the full key still separates them.
test_key_hash_separates_slug_collisions() {
  local a b
  a="$(pr_key_hash /r 'a/b.md')"
  b="$(pr_key_hash /r 'a--b.md')"
  assert_eq "$(pr_plan_slug 'a/b.md')" "$(pr_plan_slug 'a--b.md')" "slugs do collide"
  [[ "$a" != "$b" ]] || pr_fail "colliding slugs must still get different keys"
  [[ "$(pr_session_key /r 'a/b.md')" != "$(pr_session_key /r 'a--b.md')" ]] \
    || pr_fail "session keys must differ"
}

test_session_key_combines_hash_and_slug() {
  local key
  key="$(pr_session_key /home/stoyan/code/foo 'docs/plans/feat.md')"
  assert_contains "$key" "-docs--plans--feat" "slug present"
  # 8-char hash + '-' + 17-char slug
  assert_eq "${#key}" $((8 + 1 + 17)) "hash-dash-slug length"
}

test_artifact_and_sandbox_dirs() {
  local key; key="$(pr_session_key /r 'p.md')"
  assert_eq "$(pr_artifact_dir /r "$key")" "/r/.plan-review/$key" "artifact dir"
  assert_eq "$(pr_sandbox_dir "$key" codex)" \
    "$HOME/.cache/plan-review/$key/codex" "sandbox dir"
  assert_eq "$(pr_sandbox_repo "$key" codex)" \
    "$HOME/.cache/plan-review/$key/codex/repo" "sandbox repo"
}

# TMPDIR must live INSIDE the workdir. codex runs with
# sandbox_workspace_write.exclude_tmpdir_env_var=true, which removes $TMPDIR
# from the writable roots; a sibling directory would therefore be unwritable.
# Under the workdir it is covered by the workdir root regardless (Q8).
test_sandbox_tmp_is_inside_the_repo_copy() {
  local key repo tmp
  key="$(pr_session_key /r 'p.md')"
  repo="$(pr_sandbox_repo "$key" codex)"
  tmp="$(pr_sandbox_tmp "$key" codex)"
  assert_eq "$tmp" "$repo/.pr-tmp" "tmpdir under the workdir"
  assert_contains "$tmp" "$repo/" "tmpdir is a descendant of the workdir"
}

pr_run_tests
