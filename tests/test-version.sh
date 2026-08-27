#!/usr/bin/env bash
# lib/version.sh and the `version` subcommand.
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/version.sh"

PR="$PR_ROOT/bin/plan-review"

mkrepo() {  # a repository with one commit, path on stdout
  local d="$1"
  mkdir -p "$d"
  pr_test_git_init_identity "$d"
  printf 'x\n' > "$d/f"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  printf '%s' "$d"
}

test_the_subcommand_prints_this_checkout_s_revision() {
  local out; out="$("$PR" version)"
  assert_eq "$out" "$(pr_version "$PR_ROOT")" "the subcommand is the library call"
  assert_not_contains "$out" "unknown" "a git checkout is not unknown"
}

test_a_repository_without_tags_reports_a_commit_id() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" > /dev/null
  out="$(pr_version "$d/repo")"
  [[ "$out" =~ ^[0-9a-f]{7,}$ ]] || pr_fail "expected a commit id, got [$out]"
}

test_a_tag_wins_over_the_commit_id() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" > /dev/null
  git -C "$d/repo" tag v1.2.3
  assert_eq "$(pr_version "$d/repo")" "v1.2.3" "the tag is the version"
}

test_a_modified_checkout_says_so() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" > /dev/null
  printf 'changed\n' > "$d/repo/f"
  out="$(pr_version "$d/repo")"
  assert_contains "$out" "-dirty" "a dirty checkout is not the commit it claims"
}

test_without_git_metadata_it_is_unknown() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/plain"
  assert_eq "$(pr_version "$d/plain")" "unknown" "a source copy has no revision"
}

# The interesting failure this guards: unpack a tarball inside some other
# repository and `git describe` from that directory answers about the *host*
# repository, confidently and wrongly.
test_a_copy_inside_another_repository_is_still_unknown() {
  local d; d="$(pr_test_tmpdir)"; mkrepo "$d/host" > /dev/null
  mkdir -p "$d/host/vendor/plan-review"
  assert_eq "$(pr_version "$d/host/vendor/plan-review")" "unknown" "not the host's version"
}

pr_run_tests
