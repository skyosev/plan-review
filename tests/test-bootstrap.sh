#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# The clone source is a local clone of this checkout, not PR_ROOT itself. Three
# cases mutate the source -- one adds a branch, one rewrites `origin`, one adds a
# commit -- and mutating the developer's own repository to run the suite is not
# acceptable. `--no-hardlinks` so the object stores stay separate too.
#
# The script under test is always read from PR_ROOT's WORKING TREE, so the clone
# only has to be a valid checkout, not an up-to-date one.
mk_case() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/home" "$d/stub"
  git clone --quiet --no-hardlinks "$PR_ROOT" "$d/src" > /dev/null 2>&1
  # The bootstrap's default ref is `main`, and a clone carries only the source's
  # CHECKED-OUT branch -- remote-tracking refs are not transferred. So on a feature
  # branch the source would have no `main` at all, and the case that advances the
  # source would advance a branch the checkout is not following. Name this copy's
  # HEAD `main`: the subject here is the bootstrap, not which branch the developer
  # happens to be standing on. `-B`, because it must also work when that is `main`.
  git -C "$d/src" checkout -q -B main
  printf '%s' "$d"
}

# PATH is assigned in the environment of the command itself, not as a prefix on a
# function call -- the distinction tests/helpers.sh's pr_test_mkstub note explains.
run_bootstrap() {
  local d="$1" src="$2"; shift 2
  env HOME="$d/home" \
      PR_INSTALL_SOURCE="$src" \
      PR_INSTALL_DIR="$d/home/.local/share/plan-review" \
      PATH="$d/stub:$PATH" \
      bash "$PR_ROOT/scripts/install.sh" "$@" 2>&1
}

checkout_of() { printf '%s' "$1/home/.local/share/plan-review"; }

# `git commit` needs an identity, and a test must not depend on the developer's.
src_commit() {
  git -C "$1" -c user.name=test -c user.email=test@example.invalid \
      commit --quiet --allow-empty -m "$2"
}

# --- the host preflight ----------------------------------------------------

# bin/plan-review:45 resolves itself with `readlink -f` before it does anything
# else, so on a host without it neither `install` nor `doctor` can start -- and
# delegating the diagnosis to a doctor that cannot run delivers nothing. This is
# a behaviour probe, not a platform check: it asks whether `readlink -f` resolves
# a path, which is the only question that matters and the only one that stays
# true. The stub prints to stdout and exits 0, so it also pins the difference
# between "answered" and "answered correctly".
#
# The companion bash-5 refusal has no test at all. BASH_VERSINFO belongs to the
# running shell and no stub reaches it, so the only thing that ever exercises it
# is Task 2 Step 10's manual macOS pass on a machine with /bin/bash 3.2.
test_a_broken_readlink_f_is_refused_before_anything_is_cloned() {
  local d out rc; d="$(mk_case)"
  pr_test_mkstub "$d/stub/readlink" 'echo "usage: readlink [-n] file ..."; exit 0'
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 1 "the host was refused"
  assert_contains "$out" "readlink -f does not resolve a path" "and the reason was named"
  assert_contains "$out" "gnubin" "with the part of the brew fix that people miss"
  assert_file_missing "$(checkout_of "$d")" "nothing was cloned"
}

# --- fresh install ---------------------------------------------------------

test_fresh_install_clones_links_and_reports_readiness() {
  local d out rc; d="$(mk_case)"
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 0 "the bootstrap succeeded"
  assert_file_exists "$(checkout_of "$d")/bin/plan-review" "the checkout is here"
  [[ -L "$d/home/.local/bin/plan-review" ]] || pr_fail "no symlink was made"
  assert_contains "$out" "linked" "install's own message was surfaced"
  assert_contains "$out" "verified: plan-review" "install proved the link runs"
  assert_contains "$out" "installed plan-review" "the version was reported"
  assert_contains "$out" "next: export PR_ORCHESTRATOR" "the next step was printed"
  assert_contains "$out" "rm -rf $(checkout_of "$d")" "the uninstall lines name the checkout"
}

# %q leaves an ordinary path alone, so the case above cannot tell it from a bare
# interpolation. This is the one that can, and it asks the only question worth
# asking: RUN the line the epilogue printed, and see what it does. Asserting on
# the escaped spelling instead was the first draft and it was wrong twice over --
# %q escapes the parenthesis as well, so the expected substring was not what bash
# produces, and any future change to how bash spells an escape would break a test
# whose subject is not spelling. Double quotes -- the design before %q -- would
# have printed $(touch ...) intact and the eval below would have run it.
test_the_printed_removal_line_removes_the_checkout_and_nothing_else() {
  local d out line nasty; d="$(mk_case)"
  nasty="$d/home/pl an\$(touch $d/pwned)"
  out="$(env HOME="$d/home" PR_INSTALL_SOURCE="$d/src" PR_INSTALL_DIR="$nasty" \
             PATH="$d/stub:$PATH" bash "$PR_ROOT/scripts/install.sh" 2>&1)"
  assert_file_exists "$nasty/bin/plan-review" "the awkward path installed fine"
  line="$(printf '%s\n' "$out" | grep '^ *rm -rf ')"
  # eval, deliberately: this line is printed to be pasted into a shell, so a
  # shell is the only thing that can say whether it is correct. Everything it
  # can touch is inside this case's own tmpdir.
  eval "$line"
  assert_file_missing "$nasty" "the paste removed the checkout it named"
  assert_file_missing "$d/pwned" "and did not run the substitution in its name"
}

test_help_exits_zero_and_touches_nothing() {
  local d out rc; d="$(mk_case)"
  out="$(run_bootstrap "$d" "$d/src" --help)"; rc=$?
  assert_exit_code "$rc" 0 "--help succeeded"
  assert_contains "$out" "--ref" "the flags are documented"
  assert_file_missing "$(checkout_of "$d")" "nothing was cloned"
}

test_windows_is_refused_by_name() {
  local d out rc; d="$(mk_case)"
  pr_test_mkstub "$d/stub/uname" 'echo MINGW64_NT-10.0-22621'
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 1 "Windows was refused"
  assert_contains "$out" "Windows is not supported" "and said so"
  assert_file_missing "$(checkout_of "$d")" "nothing was cloned"
}

test_git_is_never_allowed_to_prompt() {
  local d out rc real_git; d="$(mk_case)"
  real_git="$(command -v git)"
  # Exported once, near the top of main, so EVERY git invocation carries it --
  # including the ones plan-review itself makes through the checkout.
  pr_test_mkstub "$d/stub/git" "[ \"\${GIT_TERMINAL_PROMPT:-unset}\" = 0 ] || {
  echo \"git ran with GIT_TERMINAL_PROMPT=\${GIT_TERMINAL_PROMPT:-unset}\" >&2; exit 9; }
exec '$real_git' \"\$@\""
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 0 "the install succeeded"
  assert_not_contains "$out" "GIT_TERMINAL_PROMPT=unset" "no git ran without it"
}

# --- what a failure leaves behind ------------------------------------------

test_a_failed_clone_leaves_no_destination() {
  local d out rc; d="$(mk_case)"
  out="$(run_bootstrap "$d" "$d/no-such-source")"; rc=$?
  assert_exit_code "$rc" 1 "the clone failure was fatal"
  assert_contains "$out" "clone failed" "and was named"
  assert_file_missing "$(checkout_of "$d")" "the trap removed what mkdir claimed"
}

# The trap is disarmed the moment the clone is complete, so a failure downstream
# of it keeps the checkout. `plan-review install` can exit 1 having written a link
# that does not run; deleting the checkout there would turn a diagnosable state
# into a dangling symlink. Here the refusal is exit 2 and no link is written, but
# the retained checkout is the same property and is what makes the recovery --
# `rm` the foreign link, run this again -- a cheap upgrade rather than a re-clone.
test_an_occupied_symlink_is_surfaced_verbatim_and_costs_nothing() {
  local d out rc; d="$(mk_case)"
  mkdir -p "$d/home/.local/bin"
  ln -s /bin/true "$d/home/.local/bin/plan-review"
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 2 "install's own refusal status came through"
  assert_contains "$out" "refusing:" "install's own message was surfaced"
  assert_eq "$(readlink "$d/home/.local/bin/plan-review")" "/bin/true" \
    "the foreign link was left alone"
  assert_file_exists "$(checkout_of "$d")/bin/plan-review" "the clone was kept"
}

# --- re-run is upgrade -----------------------------------------------------

test_a_rerun_reports_that_nothing_changed() {
  local d out rc; d="$(mk_case)"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 0 "the re-run succeeded"
  assert_contains "$out" "already at" "the version transition was reported"
  assert_contains "$out" "already installed:" "install said the link was already ours"
}

# The one that proves "re-run is upgrade" is not just a slogan: advance the
# source and require the checkout to arrive at the same commit.
test_a_rerun_fast_forwards_to_a_new_commit() {
  local d out rc before after; d="$(mk_case)"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  before="$(git -C "$(checkout_of "$d")" rev-parse HEAD)"
  src_commit "$d/src" "something new"
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  after="$(git -C "$(checkout_of "$d")" rev-parse HEAD)"
  assert_exit_code "$rc" 0 "the upgrade succeeded"
  assert_eq "$after" "$(git -C "$d/src" rev-parse HEAD)" "the checkout reached the new commit"
  [[ "$before" != "$after" ]] || pr_fail "the checkout never moved"
}

test_ref_switches_the_checkout_between_runs() {
  local d out rc head; d="$(mk_case)"
  git -C "$d/src" branch experiment > /dev/null 2>&1
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  out="$(run_bootstrap "$d" "$d/src" --ref experiment)"; rc=$?
  assert_exit_code "$rc" 0 "the ref switch succeeded"
  head="$(git -C "$(checkout_of "$d")" rev-parse --abbrev-ref HEAD)"
  assert_eq "$head" "experiment" "the checkout moved to the named ref"
}

test_a_dirty_checkout_is_refused() {
  local d out rc; d="$(mk_case)"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  echo "local edit" >> "$(checkout_of "$d")/README.md"
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 1 "the dirty tree was refused"
  assert_contains "$out" "uncommitted changes" "and named the reason"
}

test_a_foreign_remote_is_refused() {
  local d out rc; d="$(mk_case)"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  git -C "$(checkout_of "$d")" remote set-url origin https://example.invalid/other.git
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 1 "the foreign remote was refused"
  assert_contains "$out" "different origin" "and named the reason"
}

test_a_directory_that_is_not_a_checkout_is_refused_with_the_recovery() {
  local d out rc; d="$(mk_case)"
  mkdir -p "$(checkout_of "$d")"
  : > "$(checkout_of "$d")/stray"
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 1 "a non-checkout directory was refused"
  assert_contains "$out" "not a git checkout" "and named the reason"
  assert_contains "$out" "rm -rf $(checkout_of "$d")" "and printed the recovery"
  assert_file_exists "$(checkout_of "$d")/stray" "and removed nothing itself"
}

pr_run_tests
