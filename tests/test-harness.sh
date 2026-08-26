#!/usr/bin/env bash
# Self-test of the assert harness.
set -uo pipefail
PR_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$PR_TESTS_DIR/helpers.sh"

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

# A SKIP must be a counted, printed outcome, not a silent pass: the first
# platform-shaped fixtures (setsid, /dev/full) land in this cycle, and a box
# without the dependency has to say "1 skipped" rather than report a green run
# over a surface it never exercised. Driven as a whole test file in a child
# shell, because what is asserted is the SUMMARY LINE -- this file's own
# counters cannot be used to test themselves.
test_a_missing_requirement_is_a_counted_printed_skip() {
  local d out; d="$(pr_test_tmpdir)"
  cat > "$d/test-skipping.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$PR_TESTS_DIR/helpers.sh"
test_needs_something_absent() {
  pr_test_requires /no/such/path || return 0
  pr_fail "the guard let an unavailable dependency through"
}
pr_run_tests
EOF
  out="$(bash "$d/test-skipping.sh" 2>&1)"
  assert_contains "$out" "  SKIP test_needs_something_absent: needs /no/such/path" \
    "the skip names the test and what it needed"
  assert_contains "$out" "1 run, 0 failed, 1 skipped" \
    "and the summary counts it instead of hiding it in the run count"
}

pr_run_tests
