#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# Sourced here as well as inside doctor_run's fresh bash, because the jail-probe
# cases below call _pr_doctor_bwrap_probe directly: it returns a status and
# fills a nameref, and neither survives a `$BASH -c` subshell. Sourcing lib/ is
# side-effect free by convention, so this costs nothing the other cases notice.
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/doctor.sh"

# The probe now WAITS for a marker that must never appear, so its pass path
# costs ticks x 0.1s. Ten is the operator-facing default (generous against a
# loaded host); two is what keeps the offline suite inside CLAUDE.md's budget.
# Exported at file scope rather than per test, because the probe is reached
# three ways here -- directly, through pr_doctor_check_bwrap_jail, and through
# a real `plan-review doctor` whose roster happens to include agy or claude --
# and only the first of those is obvious at the call site.
export PR_BWRAP_PROBE_TICKS=2

# Each case runs the checks in a fresh bash so the pass/warn/fail counters start
# at zero, and appends a `counts <pass> <warn> <fail>` line for the assertions.
#
# `set -uo pipefail` inside the snippet on purpose: libexec/plan-review-doctor.sh runs
# under -u, so an unguarded ${PR_SOMETHING} in lib/doctor.sh must break a test
# here rather than only the real script.
#
# PATH is the first argument, not a prefix assignment, because bash's rules for
# whether an assignment before a *function* call persists afterwards are not worth
# relying on. $BASH is absolute, so overriding PATH cannot stop the interpreter
# being found.
doctor_run() {
  local path="$1" snippet="$2"
  PATH="$path" "$BASH" -c "set -uo pipefail
source '$PR_ROOT/lib/paths.sh'
source '$PR_ROOT/lib/doctor.sh'
$snippet
printf 'counts %s %s %s\n' \"\$PR_DOCTOR_PASS\" \"\$PR_DOCTOR_WARN\" \"\$PR_DOCTOR_FAIL\"" 2>&1
}


# Presence is all check_utils tests, so an empty executable file is a truthful
# stub for it.
mkpresent() {
  mkdir -p "${1%/*}"
  : > "$1"
  chmod +x "$1"
}

# --- Tier A: machine -------------------------------------------------------

test_missing_core_utilities_fail_and_name_themselves() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_utils')"
  assert_contains "$out" "missing core utilities" "absence is a failure"
  assert_contains "$out" "jq" "the missing tool is named"
  assert_contains "$out" "brew install" "and macOS is told how to fix it"
  assert_not_contains "$out" "Linux-only" "and is not told to give up"
  assert_contains "$out" "counts 0 0 1" "one failure, no passes"
}

test_present_core_utilities_pass_as_one_check() {
  local d u; d="$(pr_test_tmpdir)"
  # $PR_DOCTOR_UTILS, not a second copy: this test's whole claim is that the
  # WHOLE set passes as one check, which a stale literal would silently narrow.
  for u in $(PATH="$PATH" "$BASH" -c "source '$PR_ROOT/lib/doctor.sh'; printf '%s' \"\$PR_DOCTOR_UTILS\""); do
    mkpresent "$d/bin/$u"
  done
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_utils')"
  assert_contains "$out" "counts 1 0 0" "one pass for the whole set"
}

# The group sweep asserts GNU timeout's own-process-group behaviour
# (lib/adapter-exec.sh header, measured 2026-08-27). busybox timeout stays in
# the caller's group, so under it `kill -- -$pid` is silently inert. README
# already requires GNU coreutils; this checks the requirement -- and FAILS,
# not warns, because a silently inert sweep is the kind of degrade nothing
# else would ever surface.
#
# Through doctor_run, like every other check case here, and asserting the
# `counts` line rather than the return status: rc=1 alone cannot tell a FAIL
# from a `pr_d_warn` that happens to return 1, and fail-vs-warn is the whole
# claim above. It also keeps the counters in a fresh bash -- calling the check
# in this file's own shell would print a red [FAIL] block in the middle of a
# green run and leave PR_DOCTOR_FAIL raised for every case after it.
test_doctor_fails_a_non_gnu_timeout() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  pr_test_mkstub "$d/bin/timeout" 'echo "BusyBox v1.36.1 multi-call binary"'
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_gnu_timeout')"
  assert_contains "$out" "not GNU coreutils" "names what is wrong"
  assert_contains "$out" "BusyBox" "and echoes back what it found"
  assert_contains "$out" "counts 0 0 1" "non-GNU timeout is a FAILURE, not a warning"
}

test_doctor_passes_gnu_timeout() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  pr_test_mkstub "$d/bin/timeout" 'echo "timeout (GNU coreutils) 9.4"'
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_gnu_timeout')"
  assert_contains "$out" "counts 1 0 0" "GNU coreutils timeout passes, cleanly"
}

test_absent_reviewer_cli_points_at_the_roster_escape_hatch() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_cli codex')"
  assert_contains "$out" "codex not on PATH" "names the CLI"
  assert_contains "$out" "PR_ADAPTER_MAP" "offers dropping the reviewer instead"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_bash_floor_is_five_and_this_bash_clears_it() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_bash')"
  assert_contains "$out" "counts 1 0 0" "the interpreter running the suite passes"
  assert_contains "$out" "need 5 or newer" "states the floor it enforced"
}

test_missing_bwrap_explains_why_agy_needs_it() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_bwrap_jail')"
  assert_contains "$out" "bwrap (bubblewrap) not on PATH" "names the dependency"
  assert_contains "$out" "only write barrier" "says why it is not optional"
  assert_contains "$out" "macOS" "and the platform that can never satisfy it is named"
  assert_contains "$out" "--reviewers codex,agent" "with the roster that works there"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# The jail case needs mkdir and rmdir, so it runs on a real PATH with the stub
# shadowing bwrap. No risk of a real reviewer CLI leaking in: this check never
# invokes one.
test_broken_jail_is_distinguished_from_missing_bwrap() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/bwrap" 'echo "bwrap: setting up uid map: Permission denied" >&2; exit 1'
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_bwrap_jail')"
  assert_contains "$out" "installed but the jail those reviewers run in does not work" \
    "installed-but-broken is its own diagnosis"
  assert_contains "$out" "apparmor_restrict_unprivileged_userns" \
    "points at the actual cause on 24.04"
  assert_contains "$out" "Permission denied" "quotes what bwrap said"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# The truthful pass stub -- the payload ran (spawned appears) and the detached
# writer died with the namespace (survived never lands) -- lives in helpers.sh,
# because test-init.sh needs the same shape.
test_working_jail_passes() {
  local d; d="$(pr_test_tmpdir)"
  install_containing_bwrap_stub "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_bwrap_jail')"
  assert_contains "$out" "counts 1 0 0" "a working jail is one pass"
  assert_contains "$out" "contains a detached process" \
    "and the message says what was proved, not merely which flags started"
}

# The probe must MEASURE containment, not flag acceptance: a bwrap that
# starts the jail fine but lets a detached process outlive it (the exact
# shape of --die-with-parent without --unshare-pid) has to fail. The stub
# runs the payload with plain host bash -- uncontained by construction -- so
# both markers appear and the probe must notice within its wait window.
# Runs the probe payload with plain host bash -- uncontained by construction,
# so both markers appear.
install_escaping_bwrap_stub() {
  cat > "$1/bwrap" <<'STUB'
#!/usr/bin/env bash
args=("$@")
for i in "${!args[@]}"; do
  [[ "${args[$i]}" == bash ]] && exec "${args[@]:$i}"
done
exit 0
STUB
  chmod +x "$1/bwrap"
}

test_bwrap_probe_fails_when_a_detached_process_survives() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  install_escaping_bwrap_stub "$d/bin"
  local out rc=0
  PATH="$d/bin:$PATH" PR_BWRAP_PROBE_TICKS=5 \
    _pr_doctor_bwrap_probe pr-test-jail out || rc=$?
  assert_eq "$rc" "1" "an escaping writer is a failed jail"
  assert_contains "$out" "survived" "the failure names what happened"
}

# A bwrap that exits 0 without ever running the payload must FAIL, not pass:
# silence is not containment. This is the case a one-marker probe gets wrong.
test_bwrap_probe_fails_when_the_payload_never_ran() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  pr_test_mkstub "$d/bin/bwrap" 'exit 0'
  local out rc=0
  PATH="$d/bin:$PATH" PR_BWRAP_PROBE_TICKS=2 \
    _pr_doctor_bwrap_probe pr-test-jail out || rc=$?
  assert_eq "$rc" "1" "no spawned marker means the measurement never happened"
  assert_contains "$out" "never started" "the failure names what happened"
}

# A garbage tick count must not silently disable the containment window:
# `(( _i < abc ))` reads an unset name as 0, so an unclamped bound would skip
# the loop entirely and report an escaping jail as contained -- a false pass on
# the one thing this probe adds. The stub is the escaping one, so the correct
# answer is still a failure. (It costs ~0.2s, not the clamped ten ticks: the
# loop breaks as soon as `survived` lands.)
test_a_non_numeric_tick_count_is_clamped_not_honoured() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  install_escaping_bwrap_stub "$d/bin"
  local out rc=0
  PATH="$d/bin:$PATH" PR_BWRAP_PROBE_TICKS=abc \
    _pr_doctor_bwrap_probe pr-test-jail out || rc=$?
  assert_eq "$rc" "1" "the escape is still caught with a garbage tick count"
  assert_contains "$out" "survived" "the window ran at the clamped default"
}

test_bwrap_probe_passes_when_the_jail_contains() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  install_containing_bwrap_stub "$d/bin"
  local out rc=0
  PATH="$d/bin:$PATH" PR_BWRAP_PROBE_TICKS=2 \
    _pr_doctor_bwrap_probe pr-test-jail out || rc=$?
  assert_eq "$rc" "0" "spawned without survived is containment"
}

# agent's bwrap is a pid fence, not a write barrier, and its adapter degrades
# to unwrapped rather than refusing -- so a jail that does not work is a WARN
# here, not the failure pr_doctor_check_bwrap_jail reports for agy and claude.
# Failing would refuse a roster that works.
test_a_broken_jail_only_warns_for_agent() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/bwrap" 'echo "bwrap: setting up uid map: Permission denied" >&2; exit 1'
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agent_pid_fence')"
  assert_contains "$out" "counts 0 1 0" "a warning, not a failure"
  assert_contains "$out" "runs without a pid namespace" "says what was lost"
  assert_contains "$out" "still runs" "and that the reviewer is not lost with it"
}

test_a_missing_bwrap_only_warns_for_agent() {
  local d; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_agent_pid_fence')"
  assert_contains "$out" "counts 0 1 0" "no bwrap is a warning here; macOS never has one"
  assert_contains "$out" "session lock" "names the consequence of a survivor"
}

test_a_working_jail_passes_for_agent_as_a_fence() {
  local d; d="$(pr_test_tmpdir)"
  install_containing_bwrap_stub "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agent_pid_fence')"
  assert_contains "$out" "counts 1 0 0" "a working jail is one pass"
  assert_contains "$out" "not a write barrier" "and the report says what it is not"
}

test_unwritable_cache_root_fails() {
  local d; d="$(pr_test_tmpdir)"
  : > "$d/not-a-dir"
  local out
  out="$(doctor_run "$PATH" "PR_CACHE_ROOT='$d/not-a-dir/sub'
pr_doctor_check_cache_root")"
  assert_contains "$out" "sandbox root not writable" "a file in the way is a failure"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# --- Tier B: auth and pins -------------------------------------------------

# pr_doctor_run wraps the CLI in timeout(1) when it exists, so the stub PATH needs
# a timeout that actually execs its argument rather than swallowing it.
stub_timeout() { pr_test_mkstub "$1/timeout" 'shift; exec "$@"'; }

# A command substitution is held open by any descendant that inherited stdout,
# so a wall-clock cap on the command does not bound the substitution. Measured
# 2026-08-19: `out="$(timeout 5 timeout 1 ./fakever.sh)"` returned after 30s --
# the grandchild's own lifetime -- while the same command redirected to a file
# returned at once.
test_doctor_run_is_not_held_open_by_a_grandchild() {
  local d out start elapsed pid; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  # Through pr_test_mkstub for its absolute $BASH shebang: this file runs cases
  # with a stub directory as the entire PATH, where /usr/bin/env is not present.
  pr_test_mkstub "$d/bin/slowver" '( trap "" TERM; sleep 30 ) &
echo $! > "$PR_TEST_GC_PIDFILE"
echo "9.9.9"
exit 0'
  # Exported, not an assignment prefix on a function call -- see the note on
  # doctor_run above for why that distinction is not worth relying on.
  export PR_TEST_GC_PIDFILE="$d/gc.pid"
  start="$SECONDS"
  out="$(doctor_run "$d/bin:$PATH" \
    'out="$(pr_doctor_run 15 slowver 2>&1)"; printf "got:%s\n" "$out"')"
  elapsed=$((SECONDS - start))
  unset PR_TEST_GC_PIDFILE
  assert_contains "$out" "got:9.9.9" "the version line came back"
  (( elapsed < 10 )) || pr_fail "pr_doctor_run took ${elapsed}s; a grandchild held it open"

  assert_pid_gone "$(< "$d/gc.pid")" "grandchild survived pr_doctor_run; the group was not swept"
}

# pr_doctor_run captures to files, and merging both streams into one would be
# shorter -- but pr_doctor_version_of word-splits the first line looking for a
# digit, so a CLI that prints a deprecation notice on stderr would have its
# notice parsed as the version and compared against docs/verified-versions.txt.
# The streams stay separate for that reason; this pins it.
test_version_parsing_ignores_stderr() {
  local d out; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  pr_test_mkstub "$d/bin/noisy" 'echo "1.0.0-deprecated, use newtool" >&2
echo "noisy 2.5.0"
exit 0'
  out="$(doctor_run "$d/bin:$PATH" 'printf "ver:%s\n" "$(pr_doctor_version_of noisy)"')"
  assert_contains "$out" "ver:2.5.0" "the version came from stdout"
  assert_not_contains "$out" "ver:1.0.0-deprecated" "a stderr token is not the version"
}

# The other half of the same contract: a call site that asks for both streams
# still gets both, so the auth and model-list checks keep seeing CLI errors.
test_callers_can_still_merge_stderr() {
  local d out; d="$(pr_test_tmpdir)"; mkdir -p "$d/bin"
  pr_test_mkstub "$d/bin/noisy" 'echo "on stderr" >&2; echo "on stdout"; exit 0'
  out="$(doctor_run "$d/bin:$PATH" 'printf "got:%s\n" "$(pr_doctor_run 10 noisy 2>&1)"')"
  assert_contains "$out" "on stderr" "2>&1 at the call site still merges"
  assert_contains "$out" "on stdout" "stdout survives the merge"
}

test_codex_auth_reports_the_status_line_on_success() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/codex" 'echo "Logged in using ChatGPT"; exit 0'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_codex_auth')"
  assert_contains "$out" "codex authenticated (Logged in using ChatGPT)" \
    "echoes what the CLI said"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

test_codex_auth_failure_names_the_fix() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/codex" 'echo "Not logged in" >&2; exit 1'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_codex_auth')"
  assert_contains "$out" "not authenticated" "a failure, in words"
  assert_contains "$out" "codex login" "names the remediation"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# One stub for all three things the doctor asks Cursor. Which subcommand a test
# exercises is the point of that test; the others answer plausibly so a check
# never fails for a reason the test did not intend.
#
# `about` returns a userEmail because the real one does — that is what the
# never-echo assertion below is testing against.
mkagent() {
  local path="$1" authed="${2:-true}" models="${3:-gpt-5.2 - GPT-5.2}"
  pr_test_mkstub "$path" "case \"\$1\" in
  about)  echo '{\"cliVersion\":\"2026.08.11-e8db854\",\"userEmail\":\"a@b.c\"}' ;;
  status) echo '{\"isAuthenticated\":$authed}' ;;
  --list-models) printf '%s\n' 'Available models' '$models' ;;
esac"
}

# `agent` is a generic name. Presence on PATH says nothing about which tool it is,
# and adapters/agent.sh would run whatever it finds with Cursor's flags.
test_cursor_identity_comes_from_a_structured_field_not_the_binary_name() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent"
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agent_identity')"
  assert_contains "$out" "agent is the Cursor CLI, version 2026.08.11-e8db854" \
    "cliVersion identifies it"
  # A doctor's output gets pasted into issues, and `agent about` returns the
  # account address right next to the version.
  assert_not_contains "$out" "a@b.c" "the account email is never echoed"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

test_an_impostor_named_agent_is_caught_before_the_round() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agent" 'echo "usage: agent [options]" >&2; exit 1'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agent_identity')"
  assert_contains "$out" "does not answer 'agent about --format json'" "names the probe"
  assert_contains "$out" "different tool with the same name" "says what it suspects"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# Judged on isAuthenticated, not on the exit code — agy's lesson, applied to the
# CLI that now has a structured answer for it.
test_cursor_auth_is_judged_on_the_status_subcommand() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent" true
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agent_auth')"
  assert_contains "$out" "Cursor authenticated" "the status field is the probe"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

test_unauthenticated_cursor_fails_despite_a_zero_exit() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent" false
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agent_auth')"
  assert_contains "$out" "isAuthenticated=false" "quotes the field it judged on"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# The model list is no longer the auth probe, but it is still the pin check's
# source of truth, and its parser is the fiddly part. Tested directly rather than
# through a check, so a failure here names the parser.
test_model_list_parser_counts_ids_and_skips_prose() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out
  out="$(doctor_run "$d/bin" 'printf "header=%s auto=%s agy=%s two=%s\n" \
    "$(pr_doctor_count_ids "Available models")" \
    "$(pr_doctor_count_ids "auto - Auto (default)")" \
    "$(pr_doctor_count_ids "Fetching available models...
gemini-3.1-pro-high	Gemini 3.1 Pro (High)")" \
    "$(pr_doctor_count_ids "Available models

auto - Auto (default)
gpt-5.2 - GPT-5.2")"')"
  # `auto` has no dash and no dot in it: counting only id-shaped tokens would drop
  # a real model, which is why the separator clause exists.
  assert_contains "$out" "header=0 auto=1 agy=1 two=2" \
    "prose lines carry neither a separator nor punctuation"
}

test_agy_progress_line_is_not_counted_as_a_model() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agy" \
    'printf "Fetching available models...\ngemini-3.1-pro-high\tGemini 3.1 Pro (High)\n"'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_agy_auth')"
  assert_contains "$out" "agy answered: 1 models available" \
    "the progress line has no id in it"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

# The adapter passes --print-timeout now, so the doctor asserts the flag still
# exists rather than reporting a default the adapter no longer relies on.
test_agy_still_accepting_print_timeout_is_a_pass() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agy" \
    'printf "  --print-timeout                 Timeout for print mode wait (default 5m0s)\n"'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agy_print_timeout')"
  assert_contains "$out" "still accepts --print-timeout" "the flag is there"
  assert_contains "$out" "counts 1 0 0" "a pass, not context"
}

# A dropped flag is a failure, not a warning: agy silently falls back to 5m0s.
test_a_moved_print_timeout_flag_fails() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agy" 'printf "  --print                 Run a single prompt\n"'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_agy_print_timeout')"
  assert_contains "$out" "no longer lists --print-timeout" "says what it lost"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_agy_failure_says_there_is_no_login_subcommand() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agy" 'echo "token expired" >&2; exit 1'
  stub_timeout "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_agy_auth')"
  assert_contains "$out" "no login subcommand" "does not invent a headless fix"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_pin_that_does_not_exist_is_a_failure() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent"
  stub_timeout "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_AGENT_MODEL=nope-9
pr_doctor_check_pins")"
  assert_contains "$out" "PR_AGENT_MODEL=nope-9 is not in agent --list-models" \
    "a set-but-absent pin fails"
  assert_contains "$out" "counts 0 0 1" "the pin check fetches its own list now"
}

test_pin_present_in_the_list_passes_on_an_exact_first_field() {
  local d; d="$(pr_test_tmpdir)"
  # `gpt-5.2-fast` must not satisfy a pin of `gpt-5.2`: the match is on the whole
  # first field, not a prefix.
  mkagent "$d/bin/agent" true 'gpt-5.2-fast - GPT-5.2 Fast
gpt-5.2 - GPT-5.2'
  stub_timeout "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_AGENT_MODEL=gpt-5.2
pr_doctor_check_pins")"
  assert_contains "$out" "PR_AGENT_MODEL=gpt-5.2 exists" "exact match found"
  assert_contains "$out" "counts 1 0 0" "no failures"
}

test_prefix_of_a_real_model_is_still_a_failure() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent" true 'gpt-5.2-fast - GPT-5.2 Fast'
  stub_timeout "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_AGENT_MODEL=gpt-5.2
pr_doctor_check_pins")"
  assert_contains "$out" "is not in agent --list-models" "prefixes do not match"
}

# --offline must stay offline. The pin check is the one place that still reaches
# the network, and libexec/plan-review-doctor.sh sets this flag to stop it.
test_offline_pin_check_makes_no_model_list_call() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agent" "printf 'called\n' >> '$d/called.txt'"
  stub_timeout "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_DOCTOR_OFFLINE=1
PR_AGENT_MODEL=gpt-5.2
pr_doctor_check_pins")"
  assert_file_missing "$d/called.txt" "the CLI was never invoked"
  assert_contains "$out" "not checked: no model list" "and the pin is reported unchecked"
}

# The pins have no config file, so an unset one is the normal state of a fresh
# shell. Failing on it would fire for everyone, always, and train the reader to
# ignore the output.
test_unset_pins_are_reported_without_failing() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_pins')"
  assert_contains "$out" "PR_AGENT_MODEL unset" "says so"
  assert_contains "$out" "PR_AGY_MODEL unset" "for both"
  assert_contains "$out" "counts 0 0 0" "neither a pass nor a failure"
}

test_invalid_codex_effort_fails_before_the_backend_does() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_CODEX_EFFORT=hgih
pr_doctor_check_codex_effort")"
  assert_contains "$out" "is not one of" "rejects the typo"
  assert_contains "$out" "400" "explains what would otherwise happen"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_valid_codex_effort_passes() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_CODEX_EFFORT=xhigh
pr_doctor_check_codex_effort")"
  assert_contains "$out" "counts 1 0 0" "xhigh is a real tier"
}

# --- Tier C: version drift -------------------------------------------------

# One parser for three formats. If this breaks, the drift check silently reports
# "could not read a version" for a CLI that answered perfectly well.
test_version_parser_handles_all_three_cli_formats() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/codex" 'echo "codex-cli 0.147.0"'
  pr_test_mkstub "$d/bin/agent" 'echo "2026.08.11-e8db854"'
  pr_test_mkstub "$d/bin/agy"   'echo "1.1.13"'
  local out
  out="$(doctor_run "$d/bin" 'printf "%s %s %s\n" \
    "$(pr_doctor_version_of codex)" \
    "$(pr_doctor_version_of agent)" \
    "$(pr_doctor_version_of agy)"')"
  assert_contains "$out" "0.147.0 2026.08.11-e8db854 1.1.13" \
    "label stripped where there is one, kept intact where there is not"
}

test_matching_versions_pass() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/codex" 'echo "codex-cli 0.147.0"'
  printf '# comment\n\ncodex 0.147.0\n' > "$d/versions.txt"
  local out
  out="$(doctor_run "$d/bin" "PR_DOCTOR_VERSIONS_FILE='$d/versions.txt'
pr_doctor_check_versions")"
  assert_contains "$out" "codex 0.147.0 matches the verified version" "a match"
  assert_contains "$out" "counts 1 0 0" "comments and blank lines are skipped"
}

test_version_drift_warns_and_does_not_fail() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/codex" 'echo "codex-cli 0.148.0"'
  printf 'codex 0.147.0\n' > "$d/versions.txt"
  local out
  out="$(doctor_run "$d/bin" "PR_DOCTOR_VERSIONS_FILE='$d/versions.txt'
pr_doctor_check_versions")"
  assert_contains "$out" "codex is 0.148.0; the adapters were verified against 0.147.0" \
    "names both versions"
  assert_contains "$out" "fails closed" "explains what drift threatens"
  assert_contains "$out" "counts 0 1 0" "a warning, never a failure"
}

# A missing CLI is already one FAIL in Tier A. Counting it again here would report
# one problem as two and inflate the summary.
test_absent_tool_is_not_double_counted_by_the_drift_check() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  printf 'codex 0.147.0\n' > "$d/versions.txt"
  local out
  out="$(doctor_run "$d/bin" "PR_DOCTOR_VERSIONS_FILE='$d/versions.txt'
pr_doctor_check_versions")"
  assert_contains "$out" "counts 0 0 0" "silent about a tool Tier A already failed"
}

test_missing_versions_file_warns_rather_than_failing() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out
  out="$(doctor_run "$d/bin" "PR_DOCTOR_VERSIONS_FILE='$d/nope.txt'
pr_doctor_check_versions")"
  assert_contains "$out" "no verified-versions file" "says what is missing"
  assert_contains "$out" "counts 0 1 0" "a warning"
}

test_the_shipped_versions_file_matches_its_own_format() {
  # Guards the real file against a typo that would make every check warn.
  local out
  out="$(doctor_run "$PATH" "PR_ROOT='$PR_ROOT'
while read -r tool want rest; do
  [[ -z \"\$tool\" || \"\$tool\" == \\#* ]] && continue
  [[ -n \"\$want\" ]] || echo \"BAD: \$tool has no version\"
  [[ -z \"\$rest\" ]] || echo \"BAD: \$tool has trailing junk: \$rest\"
done < '$PR_ROOT/docs/verified-versions.txt'")"
  assert_not_contains "$out" "BAD:" "every non-comment line is <tool> <version>"
}

# --- Tier D: target repo ---------------------------------------------------

mkrepo() {
  local repo="$1"
  mkdir -p "$repo"
  pr_test_git_init_identity "$repo"
  printf '# plan\n' > "$repo/plan.md"
}

test_artifacts_ignored_is_checked_by_rule_not_by_grepping_gitignore() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  # Deliberately NOT .gitignore: the rule is equally binding here, and a grep of
  # .gitignore would report a false failure.
  mkdir -p "$d/repo/.git/info"
  printf '.plan-review/\n' > "$d/repo/.git/info/exclude"
  local out; out="$(doctor_run "$PATH" "pr_doctor_check_artifacts_ignored '$d/repo'")"
  assert_contains "$out" "counts 1 0 0" "an exclude-file rule counts"
}

test_unignored_artifacts_directory_fails_with_the_fix() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  local out; out="$(doctor_run "$PATH" "pr_doctor_check_artifacts_ignored '$d/repo'")"
  assert_contains "$out" "is NOT ignored" "a failure"
  assert_contains "$out" ">> $d/repo/.gitignore" "prints the exact command"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_non_repository_target_fails_before_the_other_repo_checks() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/plain"
  local out; out="$(doctor_run "$PATH" "pr_doctor_check_repo '$d/plain'")"
  assert_contains "$out" "is not a git repository" "named plainly"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_plan_reached_through_a_symlink_out_of_the_repo_is_rejected() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  printf '# elsewhere\n' > "$d/outside.md"
  ln -s "$d/outside.md" "$d/repo/linked.md"
  local out; out="$(doctor_run "$PATH" "pr_doctor_check_plan '$d/repo' linked.md")"
  assert_contains "$out" "resolves outside the repository" \
    "the same containment rule the runner applies"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_empty_plan_is_rejected() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  : > "$d/repo/empty.md"
  local out; out="$(doctor_run "$PATH" "pr_doctor_check_plan '$d/repo' empty.md")"
  assert_contains "$out" "the plan is empty" "nothing to review is a failure"
}

test_readable_plan_passes() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  local out; out="$(doctor_run "$PATH" "pr_doctor_check_plan '$d/repo' plan.md")"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

# pr_doctor_check_rounds needs lib/paths.sh for the session key, lib/round.sh for
# the lifecycle rule and lib/lock.sh to probe the session, so the snippet sources
# all three the way libexec/plan-review-doctor.sh does.
rounds_run() {
  local repo="$1" plan="$2"
  doctor_run "$PATH" "PR_ROOT='$PR_ROOT'
source '$PR_ROOT/lib/lock.sh'
source '$PR_ROOT/lib/round.sh'
pr_doctor_check_rounds '$repo' '$plan'"
}

seed_round() {
  local repo="$1" plan="$2" state="$3" key dir
  key="$(cd "$repo" && pwd)"
  key="$( PR_ROOT="$PR_ROOT" "$BASH" -c "source '$PR_ROOT/lib/paths.sh'
pr_session_key '$key' '$plan'" )"
  dir="$repo/.plan-review/$key/round-1"
  mkdir -p "$dir"
  printf '{"round":1,"state":"%s"}\n' "$state" > "$dir/round.json"
  printf '%s' "$dir"
}

test_no_previous_rounds_passes() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  local out; out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "the next round will be round 1" "nothing in the way"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

test_round_awaiting_integration_is_reported_as_the_blocker() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  seed_round "$d/repo" plan.md awaiting_integration > /dev/null
  local out; out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "round 1 is awaiting_integration; round 2 is blocked" \
    "answers why the next round will not start"
  assert_contains "$out" "plan-review complete" "names the command that clears it"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# The runner's guard is an allow-list, so a crashed round blocks exactly as hard
# as one awaiting integration. The doctor has to agree with it.
test_crashed_round_also_blocks() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  seed_round "$d/repo" plan.md reviewing > /dev/null
  local out; out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "in state 'reviewing' and cannot be left behind" \
    "a crashed round is not silently buried"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

test_completed_round_clears_the_way() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  seed_round "$d/repo" plan.md complete > /dev/null
  local out; out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "round 1 is complete; round 2 can start" "a pass"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

# The runner refuses a round over an aborted predecessor without --fresh
# (pr_round_needs_fresh, lib/round.sh); a doctor that said plain "can start"
# would send the operator straight into that refusal. Still a pass, not a
# blocker: the way is clear, and the flag is the way.
test_an_aborted_round_is_startable_with_fresh_only() {
  local d; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  seed_round "$d/repo" plan.md aborted > /dev/null
  local out; out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "round 1 is aborted; round 2 starts with --fresh only" \
    "the doctor and the runner tell one story"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

# --- the session lock -------------------------------------------------------
#
# round.json cannot tell these two apart. Its state is written once, so
# `reviewing` reads the same whether a runner is working right now or died three
# days ago -- and the two need opposite advice.

test_a_crashed_round_with_nothing_running_gets_the_abort_command() {
  local d rd out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  rd="$(seed_round "$d/repo" plan.md reviewing)"
  out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "Nothing is running" "says the runner did not finish"
  assert_contains "$out" "plan-review abort --round $rd" "an executable remedy"
}

test_a_held_session_is_reported_as_running_rather_than_reclaimable() {
  local d rd out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  rd="$(seed_round "$d/repo" plan.md reviewing)"
  pr_test_hold_lock "${rd%/*}/.lock" "$d/release"
  out="$(rounds_run "$d/repo" plan.md)"
  pr_test_release_lock "$d/release"
  assert_contains "$out" "a review is running in this session" "the lock, not the state"
  assert_contains "$out" "$PR_TEST_HOLDER" "and who started it"
  assert_contains "$out" "wait for it to finish" "the right advice"
  assert_not_contains "$out" "plan-review abort" "never offer to reclaim a live round"
}

test_awaiting_integration_offers_abandoning_as_well_as_finishing() {
  local d rd out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo"
  rd="$(seed_round "$d/repo" plan.md awaiting_integration)"
  out="$(rounds_run "$d/repo" plan.md)"
  assert_contains "$out" "plan-review complete --round $rd" "finish it"
  assert_contains "$out" "plan-review abort --round $rd" "or abandon it"
}

# --- Preflight -------------------------------------------------------------

preflight_run() {
  local path="$1" env_line="$2" map="$3"
  PATH="$path" "$BASH" -c "set -uo pipefail
PR_ROOT='$PR_ROOT'
source '$PR_ROOT/lib/doctor.sh'
$env_line
pr_doctor_preflight '$map'
echo \"rc=\$?\"" 2>&1
}

# The load-bearing case. tests/test-runner.sh runs the whole suite against fake
# adapters with reviewer names like `codex`; a preflight keyed on the NAME would
# demand three real CLIs and three vendor logins to run an offline test suite.
test_preflight_requires_nothing_of_an_adapter_this_repo_does_not_ship() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(preflight_run "$d/bin" '' "codex=$d/fake-ok.sh agy=$d/fake-ok.sh")"
  assert_contains "$out" "rc=0" "fakes carry no requirements, whatever they are named"
  assert_not_contains "$out" "not on PATH" "and say nothing"
}

test_preflight_demands_the_cli_for_a_shipped_adapter() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out
  out="$(preflight_run "$d/bin" '' "codex=$PR_ROOT/adapters/codex.sh")"
  assert_contains "$out" "codex not on PATH" "the real adapter needs the real CLI"
  assert_contains "$out" "rc=1" "and that is a refusal"
}

test_preflight_catches_the_unset_cursor_pin() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent"
  local out
  out="$(preflight_run "$d/bin" 'unset PR_AGENT_MODEL' \
    "agent=$PR_ROOT/adapters/agent.sh")"
  assert_contains "$out" "PR_AGENT_MODEL is unset" "caught before the sandbox copy"
  assert_contains "$out" "rc=1" "a refusal"
}

test_preflight_is_silent_when_the_roster_is_satisfied() {
  local d; d="$(pr_test_tmpdir)"
  mkagent "$d/bin/agent"
  local out
  out="$(preflight_run "$d/bin" 'PR_AGENT_MODEL=some-model' \
    "agent=$PR_ROOT/adapters/agent.sh")"
  assert_eq "$out" "rc=0" "no output at all on success"
}

# Presence on PATH is not identity. The preflight matches the substring rather
# than parsing with jq, so it needs nothing on PATH but the CLI it is asking
# about — which is why this case runs on the stub directory alone.
test_preflight_rejects_an_agent_that_is_not_the_cursor_cli() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/agent" 'echo "usage: agent [options]" >&2; exit 1'
  local out
  out="$(preflight_run "$d/bin" 'PR_AGENT_MODEL=some-model' \
    "agent=$PR_ROOT/adapters/agent.sh")"
  assert_contains "$out" "does not answer 'agent about --format json'" "names the probe"
  assert_contains "$out" "rc=1" "a refusal, before the sandbox copy"
}

# bwrap is only agy's problem, so a roster without agy must not require it.
test_preflight_only_probes_the_jail_when_agy_is_in_the_roster() {
  local d; d="$(pr_test_tmpdir)"
  mkpresent "$d/bin/codex"
  local out
  out="$(preflight_run "$d/bin" '' "codex=$PR_ROOT/adapters/codex.sh")"
  assert_eq "$out" "rc=0" "no bwrap on PATH, and no complaint about it"
}

test_preflight_refuses_an_agy_roster_without_bwrap() {
  local d; d="$(pr_test_tmpdir)"
  mkpresent "$d/bin/agy"
  local out
  out="$(preflight_run "$d/bin" 'PR_AGY_MODEL=some-model' \
    "agy=$PR_ROOT/adapters/agy.sh")"
  assert_contains "$out" "refuse to run without it" "the fail-closed rule holds"
  assert_contains "$out" "agy" "and names which reviewer needs it"
  assert_contains "$out" "rc=1" "a refusal"
}

# --- roster awareness -------------------------------------------------------

# claude used to be checked by pr_doctor_check_optional_cli, whose whole premise
# was a fixed default roster it was not in. With the roster derived from
# PR_ORCHESTRATOR it is a reviewer in three configurations out of four, so its
# absence is a plain FAIL like any other reviewer's -- the bug being that a WARN
# used to greenlight a machine whose next round could not run.
test_an_absent_claude_is_a_failure_like_any_other_reviewer() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_cli claude')"
  assert_contains "$out" "claude not on PATH" "names the CLI"
  assert_contains "$out" "self-updates with \`claude update\`" "and how to get it"
  assert_contains "$out" "counts 0 0 1" "a failure, not context"
  # The commonest claude failure is not a missing install, it is an install the
  # non-interactive shell cannot see. The hint is on the FAIL line itself, so it
  # survives a reader who stops at the first red line.
  assert_contains "$out" "~/.local/bin/claude" "and where the native installer put it"
  assert_contains "$out" "~/.claude/local/claude" "with the legacy location as a clause"
}

# Only claude. Every other CLI has one obvious install and no PATH folklore, so
# the hint would be noise on three lines out of four.
test_the_path_hint_is_claude_only() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_cli codex')"
  assert_contains "$out" "codex not on PATH" "the plain failure still reads plainly"
  assert_not_contains "$out" ".local/bin" "and carries no claude-specific hint"
}

test_claude_auth_fails_when_the_cli_is_absent() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_doctor_check_claude_auth')"
  assert_contains "$out" "claude not on PATH" "no longer a silent pass"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# A skipped check is printed, not omitted: absence from the report reads as an
# oversight, and it is uncounted because there was nothing to pass or fail.
test_a_skip_is_printed_but_counts_as_nothing() {
  local d; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  local out; out="$(doctor_run "$d/bin" 'pr_d_skip "codex is the orchestrator, not a reviewer"')"
  assert_contains "$out" "[SKIP] codex is the orchestrator" "the line is there"
  assert_contains "$out" "counts 0 0 0" "and changes no count"
}

# The argument is the roster, not the orchestrator: only the pins of CLIs that
# are actually reviewing are reported. Telling someone PR_AGENT_MODEL is REQUIRED
# when Cursor is not in the round is false.
test_only_the_rosters_own_pins_are_checked() {
  local d out; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  out="$(doctor_run "$d/bin" 'pr_doctor_check_pins agent')"
  assert_contains "$out" "PR_AGENT_MODEL unset" "Cursor is reviewing, so its pin is required"
  assert_not_contains "$out" "PR_AGY_MODEL" "agy is not in this roster"

  out="$(doctor_run "$d/bin" 'pr_doctor_check_pins "codex agy"')"
  assert_contains "$out" "PR_AGY_MODEL unset" "agy is"
  assert_not_contains "$out" "PR_AGENT_MODEL" "and Cursor now is not"
}

# The argument is optional so a caller with no roster still checks all four.
test_check_pins_without_an_orchestrator_checks_everything() {
  local d out; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin"
  out="$(doctor_run "$d/bin" 'pr_doctor_check_pins')"
  assert_contains "$out" "PR_AGENT_MODEL unset" "Cursor pin reported"
  assert_contains "$out" "PR_AGY_MODEL unset" "agy pin reported"
}

# Judged on the loggedIn field, not the exit code -- agy's lesson.
test_claude_auth_is_judged_on_the_json_field() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/claude" \
    'echo "{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"max\",\"email\":\"a@b.c\"}"'
  stub_timeout "$d/bin"
  # PATH keeps the real jq: this check parses its CLI's JSON, so a stub-only PATH
  # would test the absence of jq rather than the parse.
  local out
  out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_claude_auth')"
  assert_contains "$out" "claude authenticated (claude.ai, max)" "reports method and plan"
  # A doctor's output gets pasted into issues; the account address must not be in it.
  assert_not_contains "$out" "a@b.c" "the account email is never echoed"
  assert_contains "$out" "counts 1 0 0" "a pass"
}

test_claude_auth_failure_is_detected_despite_a_zero_exit() {
  local d; d="$(pr_test_tmpdir)"
  pr_test_mkstub "$d/bin/claude" 'echo "{\"loggedIn\":false}"; exit 0'
  stub_timeout "$d/bin"
  local out
  out="$(doctor_run "$d/bin:$PATH" 'pr_doctor_check_claude_auth')"
  assert_contains "$out" "not authenticated" "exit 0 is not a success signal"
  assert_contains "$out" "claude auth login" "names the fix"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# A different enum from codex's: no `none`, no `minimal`.
test_claude_effort_enum_differs_from_codex() {
  local d; d="$(pr_test_tmpdir)"
  mkpresent "$d/bin/claude"
  local out
  out="$(doctor_run "$d/bin" 'PR_CLAUDE_EFFORT=minimal pr_doctor_check_claude_effort')"
  assert_contains "$out" "is not one of" "minimal is valid for codex, not here"
  assert_contains "$out" "counts 0 0 1" "a failure"
  out="$(doctor_run "$d/bin" 'PR_CLAUDE_EFFORT=xhigh pr_doctor_check_claude_effort')"
  assert_contains "$out" "valid tier" "xhigh is accepted"
  assert_contains "$out" "reports no effective effort" "and flagged as unverifiable"
}

# Unlike Cursor and agy, whose pins the runner cannot do without.
test_preflight_does_not_require_a_model_pin_for_claude() {
  local d; d="$(pr_test_tmpdir)"
  mkpresent "$d/bin/claude"; mkpresent "$d/bin/bwrap"
  local out
  out="$(preflight_run "$d/bin" '' "claude=$PR_ROOT/adapters/claude.sh")"
  assert_not_contains "$out" "PR_CLAUDE_MODEL" "the init line reports the resolved model"
}

test_preflight_refuses_a_claude_roster_without_the_cli() {
  local d; d="$(pr_test_tmpdir)"
  mkpresent "$d/bin/bwrap"
  local out
  out="$(preflight_run "$d/bin" '' "claude=$PR_ROOT/adapters/claude.sh")"
  assert_contains "$out" "claude not on PATH" "names the missing CLI"
  assert_contains "$out" "rc=1" "a refusal"
}

# claude has no sandbox flag of its own, so it needs the jail exactly as agy does.
test_preflight_probes_the_jail_for_claude_too() {
  local d; d="$(pr_test_tmpdir)"
  mkpresent "$d/bin/claude"
  local out
  out="$(preflight_run "$d/bin" '' "claude=$PR_ROOT/adapters/claude.sh")"
  assert_contains "$out" "refuse to run without it" "fails closed without bwrap"
  assert_contains "$out" "claude" "names which reviewer needs it"
  assert_contains "$out" "rc=1" "a refusal"
}

# --- plan-review doctor, driven by the resolved adapter map ----------------
#
# The cases above test lib/doctor.sh with a stub PATH. These test the entry
# point's own decisions -- which checks run at all -- and so they use the real
# PATH and --offline. What they assert is the gating, never the outcome of a
# check that depends on this machine.

DOCTOR="$PR_ROOT/bin/plan-review"

mkrepo_with_config() {  # mkrepo_with_config <dir> <config-json>
  local d="$1"
  mkdir -p "$d"
  pr_test_git_init_identity "$d"
  printf '%s\n' "$2" > "$d/config.json"
  mkdir -p "$d/.plan-review"
  mv "$d/config.json" "$d/.plan-review/config.json"
  printf '.plan-review/\n' > "$d/.gitignore"
}

# The jail check used to be unconditional, on the premise that one of agy and
# claude is always reviewing. A config naming only codex makes that false, and
# an unconditional check would FAIL a machine for missing bwrap on a round that
# never needed it.
test_a_codex_only_roster_does_not_check_the_bubblewrap_jail() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo_with_config "$d/repo" '{"reviewers": ["codex"]}'
  out="$(PR_ORCHESTRATOR=claude bash "$DOCTOR" doctor --repo "$d/repo" --offline 2>&1)"
  assert_contains "$out" "no reviewer here needs the bubblewrap jail" "skipped, and said so"
  assert_not_contains "$out" "bwrap jail contains" "the probe did not run"
}

# agent wraps every vendor invocation in a pid-namespace bwrap now, so the old
# "no reviewer here needs the bubblewrap jail" was false for this roster.
test_an_agent_roster_checks_the_pid_fence_instead_of_skipping() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo_with_config "$d/repo" '{"reviewers": ["codex", "agent"]}'
  # `agent` is stubbed even though this case runs on the real PATH: the roster
  # makes the doctor run pr_doctor_check_agent_identity, and that invokes the
  # real Cursor CLI. Nothing in this suite may call a real CLI.
  pr_test_mkstub "$d/bin/agent" \
    '[[ "$1 $2" == "about --format" ]] && { echo "{\"cliVersion\":\"stub\"}"; exit 0; }
exit 1'
  out="$(PATH="$d/bin:$PATH" PR_ORCHESTRATOR=claude \
         bash "$DOCTOR" doctor --repo "$d/repo" --offline 2>&1)"
  assert_not_contains "$out" "no reviewer here needs the bubblewrap jail" \
    "agent needs one now, and the report no longer claims otherwise"
  assert_contains "$out" "pid namespace" "the fence is what is reported"
}

test_an_agy_roster_does_check_the_bubblewrap_jail() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo_with_config "$d/repo" '{"reviewers": ["agy"]}'
  out="$(PR_ORCHESTRATOR=claude bash "$DOCTOR" doctor --repo "$d/repo" --offline 2>&1)"
  assert_contains "$out" "bwrap" "agy has no other write barrier"
}

# Keyed on the adapter path, so a fake mounted under a real reviewer's name
# carries no vendor requirement -- the rule pr_doctor_preflight already follows.
test_a_fake_adapter_under_a_real_name_demands_no_vendor_login() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo_with_config "$d/repo" '{"reviewers": ["codex"]}'
  out="$(PR_ORCHESTRATOR=none PR_ADAPTER_MAP="agy=/tmp/fake-ok.sh" \
         bash "$DOCTOR" doctor --repo "$d/repo" --offline 2>&1)"
  assert_contains "$out" "does not ship" "named as unknown to this repo"
  assert_contains "$out" "no reviewer here needs the bubblewrap jail" "and carries no requirement"
}

test_show_config_prints_json_and_writes_nothing() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo_with_config "$d/repo" '{"reviewers": ["codex"], "pins": {"codex": {"effort": "low"}}}'
  out="$(PR_ORCHESTRATOR=claude bash "$DOCTOR" doctor --repo "$d/repo" --show-config 2>&1)"
  assert_eq "$(jq -r '.pins.codex.effort_source' <<<"$out")" "config" "provenance is the point"
  assert_eq "$(jq -r '.adapter_map.codex' <<<"$out")" "$PR_ROOT/adapters/codex.sh" \
    "and the roster it would run"
  assert_eq "$(ls "$d/repo/.plan-review")" "config.json" "nothing was written"
}

test_a_preset_without_a_repo_is_a_usage_error() {
  local out rc
  out="$(PR_ORCHESTRATOR=claude bash "$DOCTOR" doctor --preset quick 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused, like --plan without --repo"
  assert_contains "$out" "needs --repo" "says what is missing"
}

# A doctor report is usually read somewhere other than the machine that produced
# it, so it has to say which runner produced it.
test_the_header_names_the_runner_s_revision() {
  local out version
  source "$PR_ROOT/lib/version.sh"
  version="$(pr_version "$PR_ROOT")"
  out="$(PR_ORCHESTRATOR=none bash "$DOCTOR" doctor --offline 2>&1)"
  assert_contains "$out" "$version" "the header carries the same string as \`plan-review version\`"
}

# --- Smoke (--smoke): one live prompt per reviewer --------------------------
#
# The only doctor check that spends tokens, so it is opt-in and never reached
# by preflight. Driven with fake adapters on the real PATH: the check runs
# adapters under timeout(1), so a stub-only PATH would test the absence of
# coreutils rather than the smoke logic.

FAKES="$PR_ROOT/tests/fixtures/adapters"

# PR_CACHE_ROOT is pointed into the test tmpdir because the smoke builds its
# workdirs with the pr_sandbox_* paths -- without it, a unit case would write
# under the operator's real ~/.cache/plan-review.
smoke_run() {  # smoke_run <map> [secs] [env-line]
  doctor_run "$PATH" "source '$PR_ROOT/lib/adapter-exec.sh'
PR_CACHE_ROOT='$(pr_test_tmpdir)/cache'
${3:-}
pr_doctor_check_smoke '$1' '${2:-5}'"
}

test_smoke_passes_a_reviewer_that_answers() {
  local out; out="$(smoke_run "codex=$FAKES/fake-ok.sh")"
  assert_contains "$out" "codex" "names the reviewer"
  assert_contains "$out" "counts 1 0 0" "an answer is a pass"
}

# Cursor exits 2 on a denied tool call while still producing a correct review
# (D7). The smoke must agree with the round about what alive means, or it
# would tell an operator to fix a reviewer the round runs happily.
test_smoke_judges_on_output_not_exit_code() {
  local out; out="$(smoke_run "agent=$FAKES/fake-exit2-with-output.sh")"
  assert_contains "$out" "counts 1 0 0" "output with a non-zero exit is alive"
}

test_smoke_fails_a_dead_reviewer_and_quotes_its_reason() {
  local out; out="$(smoke_run "codex=$FAKES/fake-fail-with-reason.sh")"
  assert_contains "$out" "the vendor said no" "reason_out outranks the exit code"
  assert_not_contains "$out" "a second line nobody should read" "first line only"
  assert_contains "$out" "counts 0 0 1" "a failure"
}

# A failed smoke keeps its directory for diagnosis and nothing ever cleans it,
# so a copied credential left in there is permanent -- one per failed smoke,
# under a doctor-smoke.$$ key, invisible to `codex logout`. The token is the one
# thing the diagnosis never needs, so it goes before the "kept" line names the
# directory. The fixture sites it exactly where adapters/codex.sh does.
test_a_failed_smoke_keeps_the_evidence_but_not_the_credentials() {
  local d out; d="$(pr_test_tmpdir)"
  out="$(smoke_run "codex=$FAKES/fake-fail-leaving-credentials.sh")"
  assert_contains "$out" "kept for diagnosis" "the directory is still kept"
  local home=("$d"/cache/doctor-smoke.*/codex/codex-home)
  assert_file_missing "${home[0]}/auth.json" "the credential copy is gone"
  assert_file_exists "${home[0]}/config.toml" \
    "and only the credential -- the rest of the private home is evidence"
}

# The case the smoke exists for, and the round's measured lesson in one: an
# auth probe can pass while the exec path hangs on an interactive prompt, the
# hang must be cut at the smoke deadline rather than the round's, and
# --kill-after reaps only the direct child -- a TERM-ignoring grandchild would
# survive the deadline without the group sweep. Asserted by pid, the way
# test-runner.sh does.
test_smoke_times_out_a_hung_reviewer_and_sweeps_its_group() {
  local d pidfile out; d="$(pr_test_tmpdir)"; pidfile="$d/child.pid"
  out="$(smoke_run "codex=$FAKES/fake-term-handling-with-child.sh" 1 \
    "export PR_TEST_CHILD_PIDFILE='$pidfile' PR_KILL_GRACE_SECS=1")"
  assert_contains "$out" "counts 0 0 1" "a hang is a failure"
  assert_contains "$out" "timed out after 1s" "and the deadline is named"
  assert_file_exists "$pidfile" "the fake recorded its grandchild pid"
  assert_pid_gone "$(cat "$pidfile")" "grandchild survived; the smoke did not sweep the group"
}

# The regression the kernel refit fixes: the staged smoke backgrounded the
# adapter behind a herestring with no explicit stdin redirect, and bash gave
# the job /dev/null -- every real smoke ping would have sent an EMPTY prompt
# (measured 2026-08-22; the fakes passed because they ignore prompt content).
# fake-echo-prompt writes what it received, so this asserts delivery itself.
test_smoke_delivers_the_prompt() {
  local d out review; d="$(pr_test_tmpdir)"
  out="$(smoke_run "codex=$FAKES/fake-echo-prompt.sh" 5 "export PR_KEEP_SANDBOX=1")"
  assert_contains "$out" "counts 1 0 0" "the ping passes"
  review=("$d"/cache/doctor-smoke.*/codex/review.md)
  assert_file_exists "${review[0]}" "PR_KEEP_SANDBOX kept the workdir"
  assert_contains "$(cat "${review[0]}")" "SMOKE OK" \
    "the smoke prompt actually reached the adapter's stdin"
}

# The smoke needs lib/adapter-exec.sh the way pr_doctor_check_rounds needs
# lib/round.sh; sourced alone (as the stub-PATH tests source this file) it must
# say what is missing rather than die on an unset function. Reachable only from
# a unit test: libexec/plan-review-doctor.sh always sources the kernel.
test_smoke_skips_when_the_kernel_is_not_sourced() {
  local out
  out="$(doctor_run "$PATH" "PR_CACHE_ROOT='$(pr_test_tmpdir)/cache'
pr_doctor_check_smoke 'codex=$FAKES/fake-ok.sh' 5")"
  assert_contains "$out" "counts 0 0 0" "an uncounted skip, like the timeout skip"
  assert_contains "$out" "adapter-exec" "names the missing module"
}

# The probe stub for the doctor-CLI cases: answers, and leaves a marker proving
# it was invoked at all -- silence in the report is not proof.
mk_smoke_probe() {
  pr_test_mkstub "$1" 'cat > /dev/null; : > "$PR_TEST_SMOKE_MARKER"; echo alive > "$3"'
}

# Opt-in is the load-bearing promise: without --smoke the doctor still costs
# nothing, and the marker file proves no adapter ran rather than trusting the
# report's silence.
test_doctor_smoke_is_opt_in() {
  local d out; d="$(pr_test_tmpdir)"
  mk_smoke_probe "$d/probe.sh"
  out="$(PR_ORCHESTRATOR=none PR_ADAPTER_MAP="codex=$d/probe.sh" \
         PR_CACHE_ROOT="$d/cache" PR_TEST_SMOKE_MARKER="$d/marker" \
         bash "$DOCTOR" doctor --offline 2>&1)"
  assert_not_contains "$out" "Smoke" "no smoke section without --smoke"
  assert_file_missing "$d/marker" "and no adapter was invoked"
}

# The pins are blanked because this is the one doctor-CLI case that cannot use
# --offline: with a fakes-only map $shipped is empty, pr_doctor_check_pins ""
# reports all four, and an exported PR_AGENT_MODEL would make it fetch a real
# model list mid-suite.
test_doctor_smoke_invokes_the_roster_end_to_end() {
  local d out rc; d="$(pr_test_tmpdir)"
  mk_smoke_probe "$d/probe.sh"
  out="$(PR_ORCHESTRATOR=none PR_ADAPTER_MAP="codex=$d/probe.sh" \
         PR_CACHE_ROOT="$d/cache" PR_TEST_SMOKE_MARKER="$d/marker" \
         PR_AGENT_MODEL= PR_AGY_MODEL= \
         bash "$DOCTOR" doctor --smoke 2>&1)"; rc=$?
  assert_file_exists "$d/marker" "the adapter really ran"
  assert_contains "$out" "spends tokens" "the cost is stated in the report"
  assert_exit_code "$rc" 0 "an answering roster passes"
}

# --smoke beside --show-config is deliberately NOT refused: that path exits
# before any check runs, so the flag is inert there, exactly as --offline has
# always silently been.
test_doctor_smoke_conflicts_with_offline() {
  local out rc
  out="$(PR_ORCHESTRATOR=none bash "$DOCTOR" doctor --smoke --offline 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "a contradiction is a usage error"
  assert_contains "$out" "--offline" "and both flags are named"
}

# The adapters do integer arithmetic on the deadline they are handed (agy
# derives --print-timeout from it), so the same positive-integer rule the round
# enforces on PR_TIMEOUT_SECS applies here.
test_doctor_smoke_rejects_a_fractional_deadline() {
  local out rc
  out="$(PR_ORCHESTRATOR=none PR_SMOKE_TIMEOUT_SECS=1.5 \
         PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh" \
         bash "$DOCTOR" doctor --smoke 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "same rule as PR_TIMEOUT_SECS, same refusal"
  assert_contains "$out" "PR_SMOKE_TIMEOUT_SECS" "names the variable"
}

pr_run_tests
