#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/sandbox.sh"

# Builds a throwaway target repo with a remote, a commit, an uncommitted file,
# a gitignored build dir, and a .plan-review artifact dir.
make_target_repo() {
  local root="$1"
  mkdir -p "$root/src" "$root/node_modules" "$root/.plan-review/somekey"
  pr_test_git_init_identity "$root"
  git -C "$root" remote add origin https://example.com/real.git
  echo "node_modules/" > "$root/.gitignore"
  echo "committed" > "$root/src/a.txt"
  git -C "$root" add -A
  git -C "$root" commit -qm init
  echo "uncommitted" > "$root/src/b.txt"
  echo "dep" > "$root/node_modules/dep.txt"
  echo "leak" > "$root/.plan-review/somekey/review-codex.md"
}

test_copy_includes_committed_uncommitted_and_ignored_files() {
  local d; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  assert_file_exists "$d/sandbox/repo/src/a.txt" "committed file copied"
  assert_file_exists "$d/sandbox/repo/src/b.txt" "uncommitted file copied"
  assert_file_exists "$d/sandbox/repo/node_modules/dep.txt" "gitignored dep copied"
}

test_copy_excludes_plan_review_artifacts() {
  local d; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  assert_file_missing "$d/sandbox/repo/.plan-review" "artifacts excluded"
}

test_remotes_are_stripped_in_the_copy_only() {
  local d; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  assert_eq "$(git -C "$d/sandbox/repo" remote)" "" "copy has no remotes"
  assert_eq "$(git -C "$d/target" remote)" "origin" "target keeps its remote"
}

test_private_tmpdir_is_created_inside_the_repo_copy() {
  local d; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  [[ -d "$d/sandbox/repo/.pr-tmp" ]] || pr_fail "private TMPDIR created under the workdir"
}

test_refresh_wipes_previous_round_state() {
  local d; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  echo "experiment" > "$d/sandbox/repo/scratch.txt"
  echo "old" > "$d/sandbox/repo/.pr-tmp/old.txt"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  assert_file_missing "$d/sandbox/repo/scratch.txt" "reviewer scratch wiped"
  assert_file_missing "$d/sandbox/repo/.pr-tmp/old.txt" "tmp wiped"
  assert_file_exists "$d/sandbox/repo/src/a.txt" "repo re-copied"
}

# rsync -a preserves permissions. A target repo containing a mode-555 directory
# (vendored deps do this) would otherwise make the NEXT round's `rm -rf` fail
# with "Permission denied" and abort the reviewer. Verified reproducible.
test_refresh_survives_read_only_content_from_the_previous_round() {
  local d; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  mkdir -p "$d/target/vendor"
  echo locked > "$d/target/vendor/lib.txt"
  chmod 444 "$d/target/vendor/lib.txt"
  chmod 555 "$d/target/vendor"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  assert_file_exists "$d/sandbox/repo/vendor/lib.txt" "read-only content copied"
  pr_sandbox_refresh "$d/target" "$d/sandbox" \
    || pr_fail "second refresh must not fail on read-only content"
  assert_file_exists "$d/sandbox/repo/src/a.txt" "repo re-copied after wipe"
  chmod -R u+w "$d/target/vendor"
}

test_target_repo_is_untouched_by_refresh() {
  local d before after; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  before="$(git -C "$d/target" status --porcelain)"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  after="$(git -C "$d/target" status --porcelain)"
  assert_eq "$after" "$before" "target working tree unchanged"
}

# --- discard ----------------------------------------------------------------

# adapters/claude.sh puts CLAUDE_CONFIG_DIR at <sandbox>/config, a SIBLING of the
# repo copy, precisely so it survives every round's wipe. Discard must not be the
# thing that finally takes it.
test_discard_removes_the_repo_copy_and_nothing_beside_it() {
  local d rc; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  mkdir -p "$d/sandbox/config"
  echo state > "$d/sandbox/config/sessions.json"

  pr_sandbox_discard "$d/sandbox"; rc=$?
  assert_exit_code "$rc" 0 "discarded"
  assert_file_missing "$d/sandbox/repo" "the copy is gone"
  assert_file_exists "$d/sandbox/config/sessions.json" "the resume state is not"
}

# An empty argument would make the target `/repo`. The guard runs before the path
# is constructed, which is the only place it can run and still be a guard.
test_discard_refuses_an_empty_argument() {
  local rc err
  err="$(pr_sandbox_discard "" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$err" "empty sandbox directory" "says why"
}

test_discarding_what_is_not_there_is_not_a_failure() {
  local d rc; d="$(pr_test_tmpdir)"
  pr_sandbox_discard "$d/never-existed"; rc=$?
  assert_exit_code "$rc" 0 "nothing to do is not an error"
}

# The same mode-555 case refresh already survives, now that both go through one
# implementation.
test_discard_survives_read_only_content() {
  local d rc; d="$(pr_test_tmpdir)"
  make_target_repo "$d/target"
  mkdir -p "$d/target/vendor"
  echo locked > "$d/target/vendor/lib.txt"
  chmod 444 "$d/target/vendor/lib.txt"
  chmod 555 "$d/target/vendor"
  pr_sandbox_refresh "$d/target" "$d/sandbox"
  pr_sandbox_discard "$d/sandbox"; rc=$?
  chmod -R u+w "$d/target/vendor"
  assert_exit_code "$rc" 0 "read-only content did not stop it"
  assert_file_missing "$d/sandbox/repo" "the copy is gone"
}

pr_run_tests
