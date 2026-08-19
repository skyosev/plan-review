#!/usr/bin/env bash
# bin/plan-review itself: the file every other entry-point test now runs through,
# and the only file in this project that is ever symlinked.
#
# The migrated cases invoke it as `bash "$PR"`, which never checks the executable
# bit or the shebang. Everything here runs it directly, the way a link on PATH
# does.
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

PR="$PR_ROOT/bin/plan-review"
FAKES="$PR_ROOT/tests/fixtures/adapters"

make_target() {
  local root="$1"
  mkdir -p "$root/docs"
  git -C "$root" init -q
  git -C "$root" config user.email t@example.com
  git -C "$root" config user.name Test
  printf '# Plan\n\nDo the thing.\n' > "$root/docs/plan.md"
  git -C "$root" add -A
  git -C "$root" commit -qm init
}

# A whole round, driven through whatever path is handed in. A round is the right
# unit here: it is the subcommand that sources the most libraries, so it is the
# one that proves PR_ROOT was resolved to the checkout rather than to the link.
round_via() {  # round_via <command-path> <target> <cache>
  PR_CACHE_ROOT="$3" PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" PR_TIMEOUT_SECS=60 \
  PR_ORCHESTRATOR=none \
    "$1" round --repo "$2" --plan docs/plan.md
}

assert_round_ran() {
  local target="$1" art
  art="$(ls -d "$target/.plan-review/"*/ 2>/dev/null)"
  assert_file_exists "$art/round-1/review-codex.md" "${2:-the round produced a review}"
}

# A checkout with the dispatcher in it and nothing else. Copied, not linked: these
# cases are about an incomplete checkout, which is a different failure from a
# broken link.
fake_checkout() {
  local root="$1"
  mkdir -p "$root/bin" "$root/libexec"
  cp "$PR" "$root/bin/plan-review"
  printf '%s' "$root/bin/plan-review"
}


test_help_exits_0_with_usage_on_stdout() {
  local out rc
  out="$("$PR" help 2>/dev/null)"; rc=$?
  assert_exit_code "$rc" 0 "help is not an error"
  assert_contains "$out" "usage: plan-review <command>" "usage on stdout"
  assert_contains "$out" "round" "lists the subcommands"
  assert_contains "$out" "abort" "including the one that clears a crashed round"
}

# Reachable, not merely present: the dispatcher's case list and the libexec file
# have to agree, and an unknown subcommand is refused before either is consulted.
test_abort_is_reachable_through_the_dispatcher() {
  local d out rc; d="$(pr_test_tmpdir)"
  mkdir -p "$d/session/round-1"
  jq -n '{round: 1, state: "reviewing", reviewers: {}}' > "$d/session/round-1/round.json"
  out="$("$PR" abort --round "$d/session/round-1" 2>&1)"; rc=$?
  assert_exit_code "$rc" 0 "the subcommand ran"
  assert_eq "$(jq -r '.state' < "$d/session/round-1/round.json")" "aborted" "and did its job"
}

test_no_arguments_is_help() {
  local out rc
  out="$("$PR" 2>/dev/null)"; rc=$?
  assert_exit_code "$rc" 0 "bare invocation is not an error"
  assert_contains "$out" "usage: plan-review <command>" "usage on stdout"
}

test_an_unknown_subcommand_exits_2_with_usage_on_stderr() {
  local err rc
  err="$("$PR" wat 2>&1 >/dev/null)"; rc=$?
  assert_exit_code "$rc" 2 "refused, having done nothing"
  assert_contains "$err" "unknown command: wat" "names what it did not understand"
  assert_contains "$err" "usage: plan-review <command>" "usage on stderr"
}

test_a_round_completes_through_an_absolute_symlink() {
  local d; d="$(pr_test_tmpdir)"; make_target "$d/target"
  mkdir -p "$d/bin"
  ln -s "$PR" "$d/bin/plan-review"
  round_via "$d/bin/plan-review" "$d/target" "$d/cache" > "$d/out.txt" 2>&1
  assert_round_ran "$d/target" "an absolute link resolves to the checkout"
}

test_a_round_completes_through_a_relative_symlink() {
  local d; d="$(pr_test_tmpdir)"; make_target "$d/target"
  mkdir -p "$d/bin"
  ln -sr "$PR" "$d/bin/plan-review"
  [[ "$(readlink "$d/bin/plan-review")" != /* ]] || pr_fail "the link under test is not relative"
  round_via "$d/bin/plan-review" "$d/target" "$d/cache" > "$d/out.txt" 2>&1
  assert_round_ran "$d/target" "a relative link resolves to the checkout"
}

test_a_round_completes_through_a_two_hop_chain() {
  local d; d="$(pr_test_tmpdir)"; make_target "$d/target"
  mkdir -p "$d/one" "$d/two"
  ln -s "$PR" "$d/one/plan-review"
  ln -s "$d/one/plan-review" "$d/two/plan-review"
  round_via "$d/two/plan-review" "$d/target" "$d/cache" > "$d/out.txt" 2>&1
  assert_round_ran "$d/target" "a chain of links resolves to the checkout"
}

# Not tested here: a broken link and a symlink cycle. Bash rejects both before a
# line of ours runs -- 127 "No such file or directory" and 126 "Too many levels of
# symbolic links" -- so a test of either would be a test of the shell.

test_without_readlink_the_dispatcher_says_so() {
  local d p err rc; d="$(pr_test_tmpdir)"
  # A closed PATH, as in test-init.sh: prepending to the real one would leave the
  # machine's readlink visible behind the stub directory.
  p="$d/path"; mkdir -p "$p"
  local u real
  for u in env bash; do real="$(command -v "$u")" && ln -s "$real" "$p/$u"; done
  err="$(PATH="$p" "$PR" doctor 2>&1 >/dev/null)"; rc=$?
  assert_exit_code "$rc" 2 "refused, having run nothing"
  assert_contains "$err" "readlink is required" "names the missing tool"
}

test_a_missing_implementation_is_named() {
  local d cmd err rc; d="$(pr_test_tmpdir)"
  cmd="$(fake_checkout "$d/root")"
  err="$("$cmd" doctor 2>&1 >/dev/null)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$err" "libexec/plan-review-doctor.sh" "names the file it looked for"
  assert_contains "$err" "complete checkout" "says what that means"
}

# `readlink -f` resolves a path whose final component is missing, so the executable
# test is what actually catches a half-installed checkout -- not the return code.
test_a_non_executable_implementation_is_named() {
  local d cmd err rc; d="$(pr_test_tmpdir)"
  cmd="$(fake_checkout "$d/root")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/root/libexec/plan-review-doctor.sh"
  chmod 644 "$d/root/libexec/plan-review-doctor.sh"
  err="$("$cmd" doctor 2>&1 >/dev/null)"; rc=$?
  assert_exit_code "$rc" 2 "refused"
  assert_contains "$err" "not executable" "names the problem"
}

pr_run_tests
