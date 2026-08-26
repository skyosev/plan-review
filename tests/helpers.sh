#!/usr/bin/env bash
# Minimal assert harness. No external dependencies.
# Usage: source this, define test_* functions, call pr_run_tests at the end.

PR_TESTS_RUN=0
PR_TESTS_FAILED=0
PR_CURRENT_TEST=""
PR_TEST_TMPROOT=""

# The temp root is created once by pr_run_tests, NOT lazily here. A lazy
# `PR_TEST_TMPROOT=...` inside this function would be assigned in the
# command-substitution subshell of `d="$(pr_test_tmpdir)"` and would never reach
# the parent, so every call would mint a fresh root and cleanup would remove none.
pr_test_tmpdir() {
  local d="$PR_TEST_TMPROOT/$PR_CURRENT_TEST"
  mkdir -p "$d"
  printf '%s' "$d"
}

pr_fail() {
  PR_TESTS_FAILED=$((PR_TESTS_FAILED + 1))
  printf '  FAIL %s: %s\n' "$PR_CURRENT_TEST" "$1" >&2
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-values equal}"
  if [[ "$actual" != "$expected" ]]; then
    pr_fail "$msg
    expected: [$expected]
    actual:   [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring present}"
  if [[ "$haystack" != *"$needle"* ]]; then
    pr_fail "$msg
    looking for: [$needle]
    in:          [$haystack]"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="${3:-substring absent}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pr_fail "$msg
    should not contain: [$needle]"
  fi
}

assert_file_exists() {
  [[ -f "$1" ]] || pr_fail "${2:-file exists}: $1 not found"
}

assert_file_missing() {
  [[ ! -e "$1" ]] || pr_fail "${2:-file absent}: $1 unexpectedly exists"
}

assert_exit_code() {
  local actual="$1" expected="$2" msg="${3:-exit code}"
  [[ "$actual" == "$expected" ]] || pr_fail "$msg: expected $expected, got $actual"
}

# pr_test_mkstub <path> <body>
#
# Stubs get the running shell's absolute path as their shebang. `#!/usr/bin/env
# bash` would need `bash` on PATH, and the whole point of the bare-PATH cases in
# test-doctor.sh and test-init.sh is that PATH holds nothing but the stub
# directory -- which is why both files needed this and why it lives here now.
pr_test_mkstub() {
  local path="$1" body="$2"
  mkdir -p "${path%/*}"
  printf '#!%s\n%s\n' "$BASH" "$body" > "$path"
  chmod +x "$path"
}

# assert_pid_gone <pid> <msg>
# Several tests across the runner, kernel and doctor suites assert that a
# process-group sweep disposed of a grandchild, so the shape is written once. The grace second is not decoration:
# the sweep is a SIGKILL the parent does not wait on, so the kernel may not have
# reaped the target by the time the runner returns. The kill -9 keeps a failure
# from leaking a 30-300s sleeper into the rest of the suite.
assert_pid_gone() {
  local pid="$1" msg="$2"
  sleep 1
  if kill -0 "$pid" 2> /dev/null; then
    kill -9 "$pid" 2> /dev/null
    pr_fail "$msg (pid $pid still alive)"
  fi
}

# pr_test_hold_lock <lock-file> <release-file>
# pr_test_release_lock <release-file>
#
# Holds a session lock from another process until released, and blocks until it
# really has it -- the `.held` marker, not a sleep, so nothing races. The pid
# lands in PR_TEST_HOLDER rather than on stdout: a background job started inside
# a command substitution inherits its pipe, so `$(...)` would block until the
# holder exited, which is exactly never.
#
# Four test files hold a lock this way. The handshake has to stay in step with
# tests/fixtures/hold-lock.sh, so it is written once.
PR_TEST_HOLDER=""
pr_test_hold_lock() {
  local lock="$1" release="$2" i
  : > "$release"
  bash "$PR_ROOT/tests/fixtures/hold-lock.sh" "$lock" "$release" > /dev/null 2>&1 &
  PR_TEST_HOLDER=$!
  for ((i = 0; i < 500; i++)); do
    [[ -e "$release.held" ]] && return 0
    sleep 0.02
  done
  pr_fail "the lock holder never started"
}

pr_test_release_lock() {
  rm -f "$1"
  wait "$PR_TEST_HOLDER" 2> /dev/null
  rm -f "$1.held"
}

pr_run_tests() {
  local fn
  # The property every test needs from this root is that it EQUALS what the
  # runner will print for the same path, and the runner normalises its own paths
  # through `cd && pwd`. So normalise here the same way rather than patching the
  # differences one at a time: `cd` collapses the doubled slash macOS's
  # trailing-slash $TMPDIR produces (measured on Darwin 25, 2026-08-20 -- the
  # single failure in test-runner.sh's stuck-round case), and `-P` resolves the
  # /var -> private/var symlink macOS's $TMPDIR sits under, which is the other
  # half of the same finding.
  PR_TEST_TMPROOT="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/pr-test-XXXXXX")" && pwd -P)"
  # `compgen -A function` already returns names sorted, so this replaces a
  # declare|awk|grep|sort pipeline -- four forks per test file, in a harness whose
  # header promises no external dependencies.
  for fn in $(compgen -A function); do
    [[ "$fn" == test_* ]] || continue
    PR_CURRENT_TEST="$fn"
    PR_TESTS_RUN=$((PR_TESTS_RUN + 1))
    "$fn"
  done
  printf '%s: %d run, %d failed\n' "$(basename "${BASH_SOURCE[1]}")" \
    "$PR_TESTS_RUN" "$PR_TESTS_FAILED"
  # rm -rf cannot descend a mode-555 directory, and rsync -a reproduces exactly
  # those from a target repo (vendored deps do this — see test-sandbox.sh's
  # read-only case). Without the chmod the suite passes but litters TMPDIR.
  if [[ -n "$PR_TEST_TMPROOT" ]]; then
    chmod -R u+w "$PR_TEST_TMPROOT" 2>/dev/null
    rm -rf "$PR_TEST_TMPROOT"
  fi
  [[ "$PR_TESTS_FAILED" -eq 0 ]]
}
