#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# Stubs both binaries. The bwrap stub logs its own argv, then execs from the
# first `env` in the argument list, so the real env(1) applies the adapter's
# whitelist and the stub `claude` observes exactly the environment the jail
# would hand the real CLI. That is what makes the scrub assertable.
install_stubs() {
  local bindir="$1"
  local model="${2:-claude-sonnet-5}"
  local mode="${3:-bypassPermissions}"
  local is_error="${4:-false}"
  local result="${5-# claude review\n<!-- VERDICT: MINOR -->\n<!-- FILES-INSPECTED: src/a.ts -->}"
  local denials="${6:-0}"
  local emit_init="${7:-yes}"
  # Eighth, defaulting to empty so every existing caller is unaffected. Measured
  # 2026-08-19 against claude 2.1.235 (probe P4): the real CLI emits
  # terminal_reason on EVERY result frame, `completed` on a clean success -- so
  # the default below is `completed`, not an omitted key.
  # `${8-...}`, not `${8:-...}`: the dropped-field case passes "" deliberately,
  # and the colon form would treat that as "unset" and hand back the default.
  local terminal_reason="${8-completed}"
  mkdir -p "$bindir"

  cat > "$bindir/bwrap" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$bindir/bwrap-argv.txt"
args=("\$@")
for i in "\${!args[@]}"; do
  if [[ "\${args[\$i]}" == */env || "\${args[\$i]}" == env ]]; then
    exec "\${args[@]:\$i}"
  fi
done
echo "bwrap stub: no env in argv" >&2
exit 127
STUB

  cat > "$bindir/claude" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$bindir/claude-argv.txt"
env > "$bindir/claude-env.txt"
cat > "$bindir/claude-stdin.txt"
if [[ "$emit_init" == yes ]]; then
  jq -nc --arg m "$model" --arg p "$mode" \
    '{type:"system",subtype:"init",model:\$m,permissionMode:\$p,
      claude_code_version:"2.1.233",session_id:"sess-abc-123",cwd:"/w"}'
fi
jq -nc --argjson e "$is_error" --arg r "\$(printf '$result')" --argjson d "$denials" \
       --arg tr "$terminal_reason" \
  '{type:"result",subtype:(if \$e then "error" else "success" end),is_error:\$e,
    result:(if \$r == "" then null else \$r end),session_id:"sess-abc-123",
    permission_denials:[range(\$d)|{tool:"Bash"}],total_cost_usd:0.05}
   + (if \$tr == "" then {} else {terminal_reason: \$tr} end)'
exit 0
STUB
  chmod +x "$bindir/bwrap" "$bindir/claude"
}

# A HOME with a credentials file, so the read-only bind is exercised.
mkhome() {
  local h="$1"
  mkdir -p "$h/.claude"
  printf '{"fake":"token"}\n' > "$h/.claude/.credentials.json"
  printf '%s' "$h"
}

run_adapter() {
  local d="$1" session="${2:-}" ; shift 2 || shift
  echo "the actual prompt text" | env "$@" \
    PATH="$d/bin:$PATH" HOME="$d/home" TMPDIR="$d/work/.pr-tmp" \
    bash "$PR_ROOT/adapters/claude.sh" \
      "$d/work" "$session" "$d/r.md" "$d/m.txt" > "$d/out.txt" 2>&1
}

setup() {
  local d; d="$(pr_test_tmpdir)"
  install_stubs "$d/bin" "$@"
  mkdir -p "$d/work/.pr-tmp"
  mkhome "$d/home" > /dev/null
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Confinement. Claude Code exposes no sandbox flag of its own, so bubblewrap is
# the whole write barrier and an adapter that runs without it runs unconfined.
# ---------------------------------------------------------------------------

test_missing_bwrap_fails_closed() {
  local d rc out; d="$(setup)"
  rm -f "$d/bin/bwrap"
  out="$(echo "prompt" | PATH="$d/bin" "$BASH" "$PR_ROOT/adapters/claude.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refuses to run unconfined"
  assert_contains "$out" "bwrap" "names the missing dependency"
  assert_file_missing "$d/bin/claude-argv.txt" "claude was never invoked"
  assert_file_missing "$d/r.md" "no review produced"
}

test_jail_binds_the_workdir_writable_and_the_root_readonly() {
  local d argv; d="$(setup)"; run_adapter "$d"
  argv="$(cat "$d/bin/bwrap-argv.txt")"
  assert_contains "$argv" "--ro-bind" "root mounted read-only"
  assert_contains "$argv" "$d/work" "the workdir is a writable path"
  assert_contains "$argv" "--tmpfs" "private /tmp"
  assert_contains "$argv" "--die-with-parent" "jail dies with the timeout"
  assert_contains "$argv" "--chdir" "cwd set explicitly; claude honours it"
}

# Same measurement as agy's: --die-with-parent alone lets grandchildren
# survive; --unshare-pid is the tree cleanup (2026-08-27,
# probes/2026-08-27-pid-namespace-adapters).
test_jail_unshares_pid() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_contains "$(< "$d/bin/bwrap-argv.txt")" "--unshare-pid" \
    "pid namespace requested"
}

test_the_credentials_file_is_bound_read_only_never_copied() {
  local d argv; d="$(setup)"; run_adapter "$d"
  argv="$(cat "$d/bin/bwrap-argv.txt")"
  assert_contains "$argv" "$d/home/.claude/.credentials.json" "credentials bound in"
  # The bind is read-only and lands in the private config dir, so the reviewer
  # cannot rewrite the operator's token, and nothing is ever duplicated to disk.
  assert_contains "$argv" "--ro-bind
$d/home/.claude/.credentials.json" "bound with --ro-bind"
  assert_file_missing "$d/config/.credentials.json" "no copy was made outside the jail"
}

test_a_missing_credentials_file_is_not_fatal() {
  local d rc; d="$(setup)"
  rm -f "$d/home/.claude/.credentials.json"
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 0 "still runs; auth may come from elsewhere"
  assert_not_contains "$(cat "$d/bin/bwrap-argv.txt")" ".credentials.json" "no bind attempted"
}

# ---------------------------------------------------------------------------
# The private config dir: sessions must survive the per-round wipe of repo/,
# and the operator's own ~/.claude must stay unreachable.
# ---------------------------------------------------------------------------

test_config_dir_is_a_sibling_of_the_repo_copy_not_inside_it() {
  local d; d="$(setup)"; run_adapter "$d"
  # pr_sandbox_refresh wipes <sandbox>/repo every round. A config dir inside it
  # would take every resume handle with it.
  assert_eq "$([[ -d "$d/config" ]] && echo yes)" "yes" "config dir created beside the workdir"
  assert_contains "$(cat "$d/bin/claude-env.txt")" "CLAUDE_CONFIG_DIR=$d/config" \
    "the CLI is pointed at it"
  assert_not_contains "$(cat "$d/bin/bwrap-argv.txt")" "--bind
$d/home/.claude" \
    "the real ~/.claude is never bound writable"
}

# ---------------------------------------------------------------------------
# The environment scrub. A Claude Code session exports eleven CLAUDE_* vars;
# two classes of them are actively harmful to a nested reviewer.
# ---------------------------------------------------------------------------

test_inherited_claude_variables_are_scrubbed() {
  local d env_out; d="$(setup)"
  run_adapter "$d" "" \
    CLAUDE_EFFORT=high \
    CLAUDE_CODE_EFFORT_LEVEL=high \
    CLAUDECODE=1 \
    CLAUDE_CODE_MESSAGING_SOCKET=/run/sock \
    CLAUDE_CODE_MESSAGING_TOKEN=super-secret \
    CLAUDE_CODE_SESSION_ID=parent-session
  env_out="$(cat "$d/bin/claude-env.txt")"
  # An inherited effort could override the tier this round asked for, which is
  # the "round.json names a setting that never ran" failure R11 exists to stop.
  assert_not_contains "$env_out" "CLAUDE_EFFORT=" "parent effort does not leak in"
  assert_not_contains "$env_out" "CLAUDE_CODE_EFFORT_LEVEL=" "nor the other one"
  assert_not_contains "$env_out" "CLAUDECODE=" "reviewer is not told it is nested"
  # The messaging socket and token are a live channel back into the orchestrator
  # session. No bwrap flag closes it: it travels in the environment.
  assert_not_contains "$env_out" "super-secret" "no messaging token reaches the reviewer"
  assert_not_contains "$env_out" "MESSAGING_SOCKET" "no messaging socket either"
  assert_not_contains "$env_out" "parent-session" "no parent session id"
  assert_contains "$env_out" "CLAUDE_CONFIG_DIR=" "the one CLAUDE_ var it does get"
}

test_the_runners_private_tmpdir_is_passed_through_unchanged() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_contains "$(cat "$d/bin/claude-env.txt")" "TMPDIR=$d/work/.pr-tmp" \
    "adapters must not override the runner's TMPDIR"
}

# ---------------------------------------------------------------------------
# Invocation shape.
# ---------------------------------------------------------------------------

test_prompt_arrives_on_stdin_not_argv() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_contains "$(cat "$d/bin/claude-stdin.txt")" "the actual prompt text" "prompt on stdin"
  assert_not_contains "$(cat "$d/bin/claude-argv.txt")" "the actual prompt text" "not in argv"
}

# Measured both ways in S2: without --safe-mode the target repo's
# .claude/settings.json hook fired inside the jail on a tool call; with it, it
# did not. Losing this flag silently executes a reviewed repo's hooks.
test_safe_mode_is_always_passed() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_contains "$(cat "$d/bin/claude-argv.txt")" "--safe-mode" \
    "stops the target repo's hooks executing in the jail"
}

test_permissions_are_skipped_and_the_stream_format_requested() {
  local d argv; d="$(setup)"; run_adapter "$d"
  argv="$(cat "$d/bin/claude-argv.txt")"
  assert_contains "$argv" "--dangerously-skip-permissions" "headless tools auto-deny otherwise"
  assert_contains "$argv" "stream-json" "the init line is the only source of an effective model"
  assert_contains "$argv" "--verbose" "which print mode only emits with this"
}

test_pins_are_optional_and_passed_only_when_set() {
  local d argv rc; d="$(setup)"
  run_adapter "$d"; rc=$?
  argv="$(cat "$d/bin/claude-argv.txt")"
  assert_not_contains "$argv" "--model" "no pin, no flag"
  assert_not_contains "$argv" "--effort" "no effort, no flag"
  # Unlike Cursor and agy, an unset pin is not fatal here: the init line reports
  # the resolved model, so round.json can still record what answered.
  assert_exit_code "$rc" 0 "runs without any pin"

  run_adapter "$d" "" PR_CLAUDE_MODEL=sonnet PR_CLAUDE_EFFORT=xhigh
  argv="$(cat "$d/bin/claude-argv.txt")"
  assert_contains "$argv" "--model
sonnet" "model pin passed"
  assert_contains "$argv" "--effort
xhigh" "effort is a separate axis here, unlike Cursor and agy"
}

test_fresh_run_does_not_resume_and_records_the_session() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_not_contains "$(cat "$d/bin/claude-argv.txt")" "--resume" "no resume on a fresh run"
  assert_eq "$(sed -n 1p "$d/m.txt")" "sess-abc-123" "session_id captured"
  assert_eq "$(sed -n 2p "$d/m.txt")" "claude-sonnet-5" "model from the init line"
  assert_eq "$(sed -n 4p "$d/m.txt")" "2.1.233" "version from the init line, not a second process"
}

test_existing_session_is_resumed() {
  local d argv; d="$(setup)"; run_adapter "$d" "sess-old"
  argv="$(cat "$d/bin/claude-argv.txt")"
  assert_contains "$argv" "--resume" "resumes"
  assert_contains "$argv" "sess-old" "with the stored handle"
}

# ---------------------------------------------------------------------------
# Meta line 3. Empty here for a DIFFERENT reason than Cursor and agy: they fold
# effort into the model id, so line 2 carries it. Claude Code has a real
# separate --effort axis and reports the effective value nowhere.
# ---------------------------------------------------------------------------

test_effort_line_is_empty_even_when_an_effort_was_requested() {
  local d; d="$(setup)"; run_adapter "$d" "" PR_CLAUDE_EFFORT=max
  assert_eq "$(sed -n 3p "$d/m.txt")" "" "no effective effort is knowable"
}

# ---------------------------------------------------------------------------
# Model reporting. The pin is a request; the init line is the answer.
# ---------------------------------------------------------------------------

test_an_alias_pin_resolving_to_a_full_id_is_not_flagged_as_a_swap() {
  local d; d="$(setup)"; run_adapter "$d" "" PR_CLAUDE_MODEL=sonnet
  # `sonnet` legitimately resolves to `claude-sonnet-5`; equality would call
  # that a model swap on every single run.
  assert_eq "$(sed -n 2p "$d/m.txt")" "claude-sonnet-5" "resolved id recorded plainly"
}

test_a_genuine_model_swap_is_recorded_with_what_was_requested() {
  local d; d="$(setup)" ; install_stubs "$d/bin" "claude-opus-4-8"
  run_adapter "$d" "" PR_CLAUDE_MODEL=claude-opus-5
  assert_eq "$(sed -n 2p "$d/m.txt")" "claude-opus-4-8 (requested: claude-opus-5)" \
    "records what answered, not what was asked"
  assert_contains "$(cat "$d/out.txt")" "Recording what answered" "and says so"
}

# ---------------------------------------------------------------------------
# Fail-closed paths. The init line is this adapter's version tripwire, the way
# the banner is codex.sh's.
# ---------------------------------------------------------------------------

test_a_missing_init_line_is_refused_rather_than_recorded_as_blanks() {
  local d rc; d="$(setup)"
  install_stubs "$d/bin" "claude-sonnet-5" bypassPermissions false \
    '# review\n<!-- VERDICT: MINOR -->' 0 no
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 1 "refuses when the stream format moved"
  assert_file_missing "$d/r.md" "no review recorded against an unknown model"
  assert_contains "$(cat "$d/out.txt")" "verified-versions" "points at the drift record"
}

test_an_unexpected_permission_mode_is_refused() {
  local d rc; d="$(setup)"
  install_stubs "$d/bin" "claude-sonnet-5" "default"
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 1 "a reviewer whose tools auto-deny cannot check claims"
  assert_file_missing "$d/r.md" "no review recorded"
  assert_contains "$(cat "$d/out.txt")" "bypassPermissions" "names what it expected"
}

test_an_error_envelope_is_refused_despite_a_zero_exit() {
  local d rc; d="$(setup)"
  install_stubs "$d/bin" "claude-sonnet-5" bypassPermissions true ""
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 1 "judged on is_error, not on the exit code"
  assert_file_missing "$d/r.md" "no review produced"
}

test_an_empty_result_is_refused() {
  local d rc; d="$(setup)"
  install_stubs "$d/bin" "claude-sonnet-5" bypassPermissions false ""
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 1 "an empty review is not a review"
}

# A denial is a warning, not a refusal: the review exists, it may just rest on
# fewer verified claims. agy's empty-response auto-deny signature has no
# equivalent here because the count is structured.
test_denied_tool_calls_warn_but_keep_the_review() {
  local d rc; d="$(setup)"
  install_stubs "$d/bin" "claude-sonnet-5" bypassPermissions false \
    '# review\n<!-- VERDICT: MINOR -->' 2
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 0 "still a usable review"
  assert_file_exists "$d/r.md" "review written"
  assert_contains "$(cat "$d/out.txt")" "denied" "but the operator is told"
}

test_the_review_is_written_to_the_review_file_never_to_stdout() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_contains "$(cat "$d/r.md")" "VERDICT: MINOR" "review in the review file"
  assert_not_contains "$(cat "$d/out.txt")" "VERDICT: MINOR" "diagnostics only on stdout"
}

# --- terminal_reason (U3, probe P4) -----------------------------------------

# claude 2.1.235 names why a session ended in its result frame. Reporting that
# value is what turns "no usable review" into something an operator can act on.
# The value is echoed rather than matched against a list: P4 observed
# `completed` and `budget_exhausted`; `prompt_too_long` is the surveyed Go
# orchestrator's claim and was NOT reproduced, so nothing here special-cases it.
test_the_terminal_reason_is_named_in_the_failure_reason() {
  local d reason; d="$(pr_test_tmpdir)"
  install_stubs "$d/bin" claude-sonnet-5 bypassPermissions true "" 0 yes budget_exhausted
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/claude.sh" \
    "$d/work" "sess-abc-123" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  reason="$(< "$d/reason.txt")"
  assert_contains "$reason" "budget_exhausted" "names what claude said ended it"
  [[ "$reason" != *"--fresh"* ]] || pr_fail "--fresh discards every reviewer's handle"
}

# The stub above proves the code handles the shape we assembled; only this proves
# it handles the shape claude actually sent. Sanitised at capture time -- session
# id, review text and the denial payload redacted, key set and terminal_reason
# value untouched.
test_the_captured_frame_is_recognised() {
  local d reason; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  # Replace the stub's result line with the fixture, leaving the init line alone.
  cat > "$d/bin/claude" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "2.1.235 (Claude Code)"; exit 0; fi
cat > /dev/null
jq -nc '{type:"system",subtype:"init",model:"claude-sonnet-5",
         permissionMode:"bypassPermissions",claude_code_version:"2.1.235",
         session_id:"sess-redacted",cwd:"/w"}'
cat "$PR_ROOT/tests/fixtures/claude/result-budget-exhausted.json"
exit 0
STUB
  chmod +x "$d/bin/claude"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/claude.sh" \
    "$d/work" "sess-redacted" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  reason="$(< "$d/reason.txt")"
  assert_contains "$reason" "budget_exhausted" "the real frame is recognised too"
}

# A release that stops emitting the field must degrade to today's generic reason
# rather than leaving an empty parenthetical or shifting the later reads.
test_a_frame_without_the_field_keeps_the_generic_reason() {
  local d reason; d="$(pr_test_tmpdir)"
  install_stubs "$d/bin" claude-sonnet-5 bypassPermissions true "" 0 yes ""
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/claude.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  reason="$(< "$d/reason.txt")"
  assert_contains "$reason" "is_error=true" "the generic reason survives"
  [[ "$reason" != *"terminal_reason"* ]] || pr_fail "named a field the frame did not carry"
}

# The sibling of test-adapter-agent.sh's stderr test, and the more valuable of
# the two: here stdout is the stream-json, not the review, so a re-introduced
# `2>&1` does not merely misplace the error text -- it interleaves non-JSON into
# the file jq parses below, jq stops at the first parse error, the init line then
# reads as absent, and this adapter exits 1 reporting "no stream-json init line
# ... the envelope has moved". That is a MISDIAGNOSIS of the very failure the
# stderr exists to explain, and it would fire on every run where the CLI wrote a
# byte to stderr. Measured 2026-08-27.
#
# The other way to break it, `2>>"${review_out}.log"`, is the form this replaced:
# on the round path review_out is a scratch name, so the text went to
# <round>/.review-claude.scratch.log, a dotfile nothing named -- and for claude
# that was the ONLY copy, because log-claude.txt was 0 bytes by construction.
# Both breakages are pinned below; neither is visible without this test.
test_the_clis_stderr_is_inherited_not_redirected() {
  local d; d="$(setup)"
  # Line 2 is straight after the shebang, so the stub writes this on the single
  # claude invocation the adapter makes (the version comes off the init line, so
  # there is no second call).
  sed -i '2i echo "CLAUDE CLI FATAL: could not authenticate" >&2' "$d/bin/claude"
  run_adapter "$d"
  # run_adapter merges both streams into out.txt, which is what the execution
  # kernel does into <round>/log-claude.txt (`>> "$log" 2>&1`).
  assert_contains "$(cat "$d/out.txt")" "CLAUDE CLI FATAL" \
    "the CLI's stderr reaches the adapter's stderr, which the round logs"
  assert_file_missing "$d/r.md.log" "no derived .log file beside the review"
  # The stream-json survived the stderr: if it had not, the init-line tripwire
  # would have exited 1 and neither of these would exist.
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" \
    "the stream-json still parsed, so the review was recorded"
  assert_eq "$(sed -n 4p "$d/m.txt")" "2.1.233" "and the init line was still read"
}

pr_run_tests
