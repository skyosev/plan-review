#!/usr/bin/env bash
# Self-test of the assert harness.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

test_assert_eq_passes() {
  assert_eq "abc" "abc" "identical strings are equal"
}

test_assert_contains_passes() {
  assert_contains "hello world" "lo wo" "substring is found"
}

test_assert_file_exists_passes() {
  local f; f="$(pr_test_tmpdir)/f.txt"
  echo hi > "$f"
  assert_file_exists "$f" "created file exists"
}

pr_run_tests
