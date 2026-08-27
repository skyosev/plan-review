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
  # The skill step reaches out to two kinds of third-party program, and EVERY
  # case runs it -- not just the skill ones -- so both holes are closed here
  # rather than case by case. The stub directory is first on PATH, which is what
  # makes that possible.
  #
  # `npx`: without a stub the installer finds the real one behind the empty stub
  # directory and runs a real `npx -y skills add ... -g`, which reaches the
  # network and writes into the developer's own global harness directories. A
  # silent no-op makes the skill step "succeed" and its verification warn --
  # both non-fatal, so no assertion outside the skill cases moves.
  #
  # The four harness CLIs: three of them are only ever `command -v`'d, but
  # `agent` is EXECUTED, by cursor_identity_ok. Measured unstubbed: `agent about
  # --format json` takes ~1.5s and returns live account state, on roughly ten of
  # the fourteen Task 1 cases, in a suite whose stated property is that it is
  # offline and takes seconds.
  #
  # Cases that care about either override them -- stub_npx and stub_harness_clis
  # write to these same paths, and two cases then replace `agent` again on top
  # of that. Order is what makes those overrides win, so nothing here may move
  # below them.
  pr_test_mkstub "$d/stub/npx" 'exit 0'
  stub_harness_clis "$d/stub"
  printf '%s' "$d"
}

# Where the checkout lands, named once: the assertions and the PR_INSTALL_DIR
# that decides it must not be able to disagree.
checkout_of() { printf '%s' "$1/home/.local/share/plan-review"; }

# PATH is assigned in the environment of the command itself, not as a prefix on a
# function call -- the distinction tests/helpers.sh's pr_test_mkstub note explains.
#
# NPX_LOG is read only by stub_npx, so it is inert in the cases that have no npx
# stub, and one runner beats two that drift apart. Truncating it here rather than
# per case also means `cat "$d/npx.log"` has a file to read in the case that
# asserts npx was never called.
run_bootstrap() {
  local d="$1" src="$2"; shift 2
  : > "$d/npx.log"
  env NPX_LOG="$d/npx.log" \
      HOME="$d/home" \
      PR_INSTALL_SOURCE="$src" \
      PR_INSTALL_DIR="$(checkout_of "$d")" \
      PATH="$d/stub:$PATH" \
      bash "$PR_ROOT/scripts/install.sh" "$@" 2>&1
}

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

# --bin-dir is passed through to `plan-review install`, which owns the link. The
# three things worth asserting are the three that can break independently: the
# flag reaches install at all, the link it wrote resolves into THIS checkout
# (rather than some older plan-review on the machine), and the epilogue's
# removal line names the same directory -- that last one is not free, because
# the epilogue re-derives the path from $bin_dir with its own default rather
# than reusing what install was given.
#
# The removal assertion is scoped to the `rm` LINE, not to the whole output, and
# that is load-bearing. $d/altbin appears three times in a successful run --
# install's own `linked ...`, its not-on-PATH note, and the epilogue -- so a
# whole-output `assert_contains` is satisfied by the first of them and says
# nothing about the epilogue at all. Measured: with the epilogue's
# `${bin_dir:-$HOME/.local/bin}` mutated to a bare `$HOME/.local/bin`, the
# unscoped form stayed green and this one goes red. Same technique, same reason,
# as test_the_printed_removal_line_removes_the_checkout_and_nothing_else below.
test_bin_dir_flag_places_the_link_where_told() {
  local d out; d="$(mk_case)"
  out="$(run_bootstrap "$d" "$d/src" --bin-dir "$d/altbin")"
  assert_file_exists "$d/altbin/plan-review" "the link landed in --bin-dir"
  assert_eq "$(readlink -f "$d/altbin/plan-review")" \
    "$(readlink -f "$(checkout_of "$d")/bin/plan-review")" \
    "and it resolves into the checkout"
  assert_contains "$(printf '%s\n' "$out" | grep '^ *rm ')" "$d/altbin" \
    "the epilogue's removal line names it"
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

# The two halves of the split die on the upgrade path. They used to share one
# message -- "no such ref after fetching" -- which sent someone hunting for a ref
# that was sitting right there whenever the checkout itself was what failed.
#
# Only the SECOND of the two is a guard. This first one is characterisation: it
# passes with the split fully reverted, because the old conflated die printed
# this same message for a missing ref too. Measured, not assumed. It is kept
# because it pins the message a missing ref gets, which is half of what the
# split is for -- but it is not what would catch the split being undone.
test_a_ref_that_does_not_exist_is_named_as_missing() {
  local d out rc; d="$(mk_case)"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  out="$(run_bootstrap "$d" "$d/src" --ref no-such-branch)"; rc=$?
  assert_exit_code "$rc" 1 "a missing ref is fatal"
  assert_contains "$out" "no such ref after fetching: no-such-branch" "and is named as missing"
}

# An index.lock is what a concurrent git leaves -- including a second copy of
# this installer running right now, which is the case the message is written for.
# THIS is the guard: revert the split and this case goes red while the one above
# stays green.
test_a_checkout_that_cannot_run_is_not_reported_as_a_missing_ref() {
  local d out rc; d="$(mk_case)"
  git -C "$d/src" branch experiment > /dev/null 2>&1
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  : > "$(checkout_of "$d")/.git/index.lock"
  out="$(run_bootstrap "$d" "$d/src" --ref experiment)"; rc=$?
  assert_exit_code "$rc" 1 "the failed checkout is fatal"
  assert_contains "$out" "git checkout experiment failed" "and is named for what it was"
  assert_contains "$out" "index lock" "with the cause that explains it"
  assert_not_contains "$out" "no such ref" "and never as a missing ref"
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

# --- the skill step --------------------------------------------------------

# Records the argv and the telemetry variable of every npx call, and answers
# `skills ls --json` with whatever the case wants. Anything else exits 0 quietly,
# which is what `skills add` succeeding looks like.
stub_npx() {
  local dir="$1" ls_json="$2"
  pr_test_mkstub "$dir/npx" "
{ printf 'DISABLE_TELEMETRY=%s argv:' \"\${DISABLE_TELEMETRY:-unset}\"
  printf ' %s' \"\$@\"
  printf '\\n'
} >> \"\$NPX_LOG\"
case \" \$* \" in
  *' ls '*) printf '%s\\n' '$ls_json' ;;
esac
exit 0"
}

# All four harness CLIs, so detection does not depend on what is installed here.
# `agent` answers the Cursor identity probe with a non-empty cliVersion unless a
# case overrides it.
stub_harness_clis() {
  local dir="$1" c
  for c in claude codex agy; do pr_test_mkstub "$dir/$c" 'exit 0'; done
  pr_test_mkstub "$dir/agent" '[ "${1:-}" = about ] && { printf "{\"cliVersion\":\"test\"}\n"; exit 0; }
exit 0'
}

# What a fully linked install looks like. The display names are the ones
# skill_name_for claims -- confirmed against a real `skills ls -g --json` at
# 1.5.18 on macOS 2026-08-20, all four exact -- and they are hard-coded here, so
# a correction to that table needs this string corrected with it or the suite
# goes on passing against the old world. A case that wants a miss returns a subset.
ALL_LINKED='[{"name":"plan-review","agents":["Claude Code","Codex","Cursor","Antigravity CLI"]}]'

# tests/helpers.sh has no skip. Six cases need a real `node`: four to exercise a
# JSON parse, and two more because install_skill requires node before it will run
# npx at all, so without it there is no add to make an assertion about. npx
# implies node in production, but the suite must not fail on a machine that has
# neither.
test_one_add_covers_every_detected_harness() {
  local d log checkout; d="$(mk_case)"
  pr_test_requires node || return 0
  stub_npx "$d/stub" "$ALL_LINKED"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  log="$(cat "$d/npx.log")"
  checkout="$(checkout_of "$d")"
  assert_contains "$log" \
    "argv: -y skills add $checkout -g -a claude-code -a codex -a cursor -a antigravity-cli -y" \
    "one add named every harness, and agy is antigravity-cli"
  assert_eq "$(grep -c 'skills add' "$d/npx.log")" "1" "exactly one add process"
  assert_eq "$(grep -c 'skills ls' "$d/npx.log")" "1" "exactly one ls process"
  assert_not_contains "$log" "DISABLE_TELEMETRY=unset" "telemetry was off on BOTH calls"
}

test_cursor_is_skipped_when_the_identity_probe_returns_no_version() {
  local d out log; d="$(mk_case)"
  pr_test_requires node || return 0
  # Exit 0, valid JSON, empty field: the case that an exit-status-only probe
  # passes and lib/doctor.sh:408's non-empty .cliVersion test catches.
  pr_test_mkstub "$d/stub/agent" 'printf "{\"cliVersion\":\"\"}\n"; exit 0'
  stub_npx "$d/stub" "$ALL_LINKED"
  out="$(run_bootstrap "$d" "$d/src")"
  log="$(cat "$d/npx.log")"
  assert_not_contains "$log" "-a cursor" "nothing was written into a Cursor directory"
  assert_contains "$out" "agent about --format json" "the probe was named"
  assert_contains "$log" "-a codex" "the other harnesses still got the skill"
}

# The confusion the probe exists to resolve is "some other tool is also called
# agent". Its output is not JSON, and it may well mention the word it is being
# searched for. A substring hunt -- the first draft -- passes both of these.
test_a_non_cursor_agent_does_not_pass_the_identity_probe() {
  local d log; d="$(mk_case)"
  pr_test_requires node || return 0
  pr_test_mkstub "$d/stub/agent" \
    'printf "agent: unknown flag --format (try: agent --cliVersion \"1.2\")\n"; exit 0'
  stub_npx "$d/stub" "$ALL_LINKED"
  run_bootstrap "$d" "$d/src" > /dev/null 2>&1
  log="$(cat "$d/npx.log")"
  assert_not_contains "$log" "-a cursor" "a key-shaped substring is not an identity"
  assert_contains "$log" "-a codex" "the other harnesses still got the skill"
}

test_a_missing_display_name_is_not_a_pass() {
  local d out rc; d="$(mk_case)"
  pr_test_requires node || return 0
  # The false positive the previous design could not see: linked into Claude Code
  # alone, while a per-harness `ls -a codex` query would still answer non-empty.
  stub_npx "$d/stub" '[{"name":"plan-review","agents":["Claude Code"]}]'
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 0 "a partial link is not a failed install"
  assert_contains "$out" "not linked into" "the missing harnesses were named"
  assert_contains "$out" "Codex" "including this one"
  assert_not_contains "$out" "verified: the skill" "and nothing was called verified"
}

test_unparseable_json_warns_rather_than_passing() {
  local d out rc; d="$(mk_case)"
  pr_test_requires node || return 0
  stub_npx "$d/stub" 'this is not json'
  out="$(run_bootstrap "$d" "$d/src")"; rc=$?
  assert_exit_code "$rc" 0 "unreadable output is not a failed install"
  assert_contains "$out" "unverified" "readiness was left unverified"
  assert_not_contains "$out" "verified: the skill" "and nothing was called verified"
}

test_no_skill_takes_npm_out_of_the_install_path() {
  local d out rc; d="$(mk_case)"
  stub_npx "$d/stub" "$ALL_LINKED"
  out="$(run_bootstrap "$d" "$d/src" --no-skill)"; rc=$?
  assert_exit_code "$rc" 0 "--no-skill succeeded"
  assert_eq "$(cat "$d/npx.log")" "" "npx was never invoked"
  assert_contains "$out" "verified: plan-review" "the runner was still installed"
  assert_not_contains "$out" "skills remove" \
    "and no one was invited to delete a global skill this run never touched"
}

test_the_removal_line_appears_only_when_a_skill_was_installed() {
  local d out; d="$(mk_case)"
  pr_test_requires node || return 0
  stub_npx "$d/stub" "$ALL_LINKED"
  out="$(run_bootstrap "$d" "$d/src")"
  assert_contains "$out" "npx skills remove -g plan-review" "printed after a real install"
  assert_contains "$out" "global" "and says that removal is global, by name"
}

# `command -v npx` cannot be made to fail by adding something to PATH, so this is
# the one case that runs on a CONSTRUCTED PATH instead of a stub prefix. The list
# is what bin/plan-review, libexec/plan-review-install.sh and git need; the doctor
# is non-fatal, so whatever it cannot find it simply reports.
# Deliberately not derived from PR_DOCTOR_UTILS (lib/doctor.sh) and not hoisted
# into tests/helpers.sh: the installer's needs are not the doctor's, and these
# cases run where helpers.sh is unavailable by construction -- the same
# stated-twice device the standalone adapters use for PR_MAX_ARG_BYTES.
test_a_missing_npx_warns_and_the_install_still_succeeds() {
  local d out rc b p; d="$(mk_case)"
  mkdir -p "$d/minpath"
  for b in bash env git uname readlink dirname basename mkdir ln rm cat sed grep tr head jq; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/minpath/$b"
  done
  out="$(env HOME="$d/home" \
             PR_INSTALL_SOURCE="$d/src" \
             PR_INSTALL_DIR="$(checkout_of "$d")" \
             PATH="$d/minpath" \
             bash "$PR_ROOT/scripts/install.sh" 2>&1)"; rc=$?
  assert_exit_code "$rc" 0 "a missing npx is not a failed install"
  assert_contains "$out" "npx and node are needed" "and was named"
  assert_contains "$out" "npx skills add" "with the command to run later"
  assert_contains "$out" "verified: plan-review" "the runner was still installed"
  assert_not_contains "$out" "skills remove" "and no removal line for a skill never installed"
}

# The bash-5 refusal is the one thing in this file no stub can reach:
# BASH_VERSINFO belongs to the running shell, so the only way to exercise it is
# to run the script under a real 3.2. Hence a container -- and hence a case that
# is opt-in.
#
# Opt-in: pulls a container image, so it must never run inside `make test`'s
# offline, seconds-long promise. PR_TEST_BASH32=1 is the operator saying "spend
# the time"; docker is then a skip, not a failure.
test_bash32_host_refusal_is_the_one_install_sh_promises() {
  if [ "${PR_TEST_BASH32:-0}" != 1 ]; then
    pr_test_skip "set PR_TEST_BASH32=1"
    return 0
  fi
  pr_test_requires docker || return 0
  # The binary is not the service. `docker` on PATH with no daemon behind it --
  # a rootless setup that is not started, Docker Desktop not running -- fails
  # `docker run` with a connection error, which would read as this case failing
  # rather than as this machine not being able to run it. `docker info` is the
  # cheapest question that distinguishes the two.
  if ! docker info > /dev/null 2>&1; then
    pr_test_skip "docker is on PATH but its daemon is not reachable"
    return 0
  fi
  # A stub git, because main checks for git BEFORE preflight_host and the
  # bash:3.2 image (measured 2026-08-26: bash 3.2.57, busybox readlink -f
  # resolves, no git) would otherwise be refused for the wrong reason. Nothing
  # ever runs it -- preflight_host dies two lines later -- it exists only so
  # `command -v git` finds something. The mount stays read-only, so the stub is
  # written into the container's own /tmp.
  local out rc=0
  out="$(docker run --rm -v "$PR_ROOT:/w:ro" bash:3.2 bash -c '
    mkdir -p /tmp/stub
    printf "#!/bin/sh\nexit 0\n" > /tmp/stub/git
    chmod +x /tmp/stub/git
    PATH=/tmp/stub:$PATH exec bash /w/scripts/install.sh' 2>&1)" || rc=$?
  assert_exit_code "$rc" 1 "a 3.2 host is refused, not half-installed"
  assert_contains "$out" "too old; plan-review needs 5" \
    "and the refusal is the bash-version one, printed by 3.2 itself"
}

pr_run_tests
