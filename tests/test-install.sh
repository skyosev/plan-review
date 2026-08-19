#!/usr/bin/env bash
# `plan-review install`: one link, and a refusal for everything else already at
# that path.
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

PR="$PR_ROOT/bin/plan-review"
SELF="$(readlink -f "$PR")"

install_to() {  # install_to <bin-dir> [extra args...]
  local dir="$1"; shift
  "$PR" install --bin-dir "$dir" "$@" 2>&1
}

test_it_creates_the_directory_and_links_into_it() {
  local d out rc; d="$(pr_test_tmpdir)"
  out="$(install_to "$d/bin")"; rc=$?
  assert_exit_code "$rc" 0 "installed"
  assert_eq "$(readlink "$d/bin/plan-review")" "$SELF" "the link points at this checkout"
  assert_contains "$out" "verified:" "it proved the link runs"
}

# Verification goes through the link's own path. A bare `plan-review` on a first
# install is exactly what might resolve to some older command earlier on PATH.
test_verification_reports_the_version_the_link_produces() {
  local d out; d="$(pr_test_tmpdir)"
  out="$(install_to "$d/bin")"
  assert_contains "$out" "$("$PR" version)" "the version came from the new link"
}

# The doctor refuses to run without PR_ORCHESTRATOR, so an install that ran it
# would write the link and then report a refusal.
test_it_needs_no_orchestrator_and_runs_no_doctor() {
  local d out rc; d="$(pr_test_tmpdir)"
  out="$(env -u PR_ORCHESTRATOR "$PR" install --bin-dir "$d/bin" 2>&1)"; rc=$?
  assert_exit_code "$rc" 0 "installing is not a diagnosis"
  assert_not_contains "$out" "PASS" "no doctor output"
  assert_contains "$out" "plan-review doctor" "it names the command to run next"
}

test_a_second_run_changes_nothing() {
  local d out rc; d="$(pr_test_tmpdir)"
  install_to "$d/bin" > /dev/null
  out="$(install_to "$d/bin")"; rc=$?
  assert_exit_code "$rc" 0 're-running is safe, so "git pull" needs no thought'
  assert_contains "$out" "already installed" "and says it did nothing"
  assert_eq "$(readlink "$d/bin/plan-review")" "$SELF" "still the same link"
}

refusal_leaves_it_alone() {  # refusal_leaves_it_alone <bin-dir> <what>
  local d="$1" what="$2" out rc before after
  before="$(ls -ld "$d/plan-review")"
  out="$("$PR" install --bin-dir "$d" 2>&1)"; rc=$?
  after="$(ls -ld "$d/plan-review")"
  assert_exit_code "$rc" 2 "refused: $what"
  assert_contains "$out" "refusing" "said so"
  assert_eq "$after" "$before" "and wrote nothing"
}

test_it_refuses_a_regular_file() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  printf 'not ours\n' > "$d/bin/plan-review"
  refusal_leaves_it_alone "$d/bin" "a regular file"
}

test_it_refuses_a_directory() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin/plan-review"
  refusal_leaves_it_alone "$d/bin" "a directory"
}

# Ownership is the exact target, not "somewhere inside the checkout" -- which
# would read a link to README.md as an installation of ourselves.
test_it_refuses_a_link_elsewhere_in_this_checkout() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  ln -s "$PR_ROOT/README.md" "$d/bin/plan-review"
  refusal_leaves_it_alone "$d/bin" "a link to another file here"
}

# The case that decides the occupancy test: `-e` follows the link and calls a
# dangling one vacant, so `-e` alone would clobber it.
test_it_refuses_a_broken_link() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  ln -s "$d/gone" "$d/bin/plan-review"
  refusal_leaves_it_alone "$d/bin" "a broken link"
}

test_it_refuses_a_bin_dir_that_is_a_file() {
  local d out rc; d="$(pr_test_tmpdir)"
  printf 'x\n' > "$d/bin"
  out="$(install_to "$d/bin")"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$out" "not a directory" "named the problem"
}

test_it_warns_when_the_directory_is_not_on_path() {
  local d out; d="$(pr_test_tmpdir)"
  out="$(install_to "$d/bin")"
  assert_contains "$out" "not on your PATH" "the link is useless until it is"
  out="$(PATH="$d/bin2:$PATH" "$PR" install --bin-dir "$d/bin2" 2>&1)"
  assert_not_contains "$out" "not on your PATH" "and quiet when it is"
}

test_an_unknown_argument_is_refused() {
  local out rc
  out="$("$PR" install --prefix /usr/local 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused, having written nothing"
  assert_contains "$out" "--bin-dir" "usage names the flag that exists"
}

pr_run_tests
