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
  # Ninth: what the stub's TOOL FRAMES say, for the "the reviewer ran at least
  # one command successfully" tripwire. `ok` is the default because a real
  # reviewer runs commands and every other test in this file is about something
  # else; `none` emits no tool frames at all (C1's shape -- a confident review
  # that ran nothing) and `error` emits a Bash call whose result is_error
  # (C3/D3's shape -- every command denied).
  local tools="${9:-ok}"
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
if [[ "$tools" != none ]]; then
  jq -nc '{type:"assistant",message:{content:[
    {type:"tool_use",id:"toolu_1",name:"Bash",input:{command:"ls -la"}}]}}'
  if [[ "$tools" == error ]]; then
    jq -nc '{type:"user",message:{content:[
      {type:"tool_result",tool_use_id:"toolu_1",is_error:true,
       content:"Operation not permitted"}]}}'
  else
    jq -nc '{type:"user",message:{content:[
      {type:"tool_result",tool_use_id:"toolu_1",content:"total 0"}]}}'
  fi
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

# A PATH with no bwrap on it, for the builtin half. Hiding bwrap is not
# something PATH can do by subtraction -- on Linux it sits in /usr/bin next to
# everything else -- so this builds a directory holding the stubs plus a symlink
# per external the adapter actually calls, and nothing else. Keep it in step
# with adapters/claude.sh: an external it needs and this list omits shows up as
# a mystifying failure rather than as "you forgot to add cp". `bash` is on it
# for the stubs' own `#!/usr/bin/env bash`, not for the adapter.
#
# `security` is DELIBERATELY absent, and that absence is load-bearing on a Mac:
# link it and the Keychain branch fires against the operator's real login
# keychain from inside the offline suite. Its absence is what makes
# test_the_builtin_half_refuses_when_there_is_no_credential_route exercise the
# same branch on both platforms.
link_min_tools() {
  local bindir="$1" t p
  for t in bash env dirname mkdir cp rm chmod cat head tail tee jq timeout id; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    [[ -n "$p" ]] && ln -sf "$p" "$bindir/$t"
  done
}

# Make the adapter's `uname -s` answer Darwin. Written after link_min_tools,
# which would otherwise link the real one over it.
stub_uname_darwin() {
  local bindir="$1"
  cat > "$bindir/uname" <<'''EOF'''
#!/usr/bin/env bash
[[ "${1:-}" == -s ]] && { echo Darwin; exit 0; }
exec /usr/bin/uname "$@"
EOF
  chmod +x "$bindir/uname"
}

# A HOME with a credentials file, so the read-only bind is exercised.
mkhome() {
  local h="$1"
  mkdir -p "$h/.claude"
  printf '{"fake":"token"}\n' > "$h/.claude/.credentials.json"
  printf '%s' "$h"
}

# reason_out is passed, so every case here can read the round's one-line detail
# without rebuilding the invocation. It is optional in the contract and the
# adapter writes it only on the paths that have something to say, so passing it
# unconditionally changes nothing for the cases that ignore it.
run_adapter() {
  local d="$1" session="${2:-}" ; shift 2 || shift
  echo "the actual prompt text" | env "$@" \
    PATH="$d/bin:$PATH" HOME="$d/home" TMPDIR="$d/work/.pr-tmp" \
    bash "$PR_ROOT/adapters/claude.sh" \
      "$d/work" "$session" "$d/r.md" "$d/m.txt" "$d/reason.txt" > "$d/out.txt" 2>&1
}

setup() {
  local d; d="$(pr_test_tmpdir)"
  install_stubs "$d/bin" "$@"
  mkdir -p "$d/work/.pr-tmp"
  mkhome "$d/home" > /dev/null
  printf '%s' "$d"
}

# ---------------------------------------------------------------------------
# Confinement, and it is PER-HOST since 2026-08-30: bubblewrap where it exists,
# Claude Code's own sandbox where it does not. The two halves are exercised
# separately below; what must never appear in either is an unconfined run.
# ---------------------------------------------------------------------------

# The builtin half is chosen by the ABSENCE of bwrap, which PATH cannot arrange
# by subtraction on a host that has it -- hence link_min_tools and a PATH built
# from nothing. Every builtin-half test below runs through this.
#
# It also needs the host to LOOK like a Mac, because the builtin half is
# Darwin-only since 2026-08-30: on Linux the adapter refuses instead, since
# Claude Code's own sandbox is built on bubblewrap there and is no fallback for
# its absence (FINDINGS-2026-08-30-linux.md, row L3). A `uname` stub is how that
# is arranged, and it is why the adapter's predicate is `uname -s` rather than
# $OSTYPE -- the latter is fixed when bash is compiled and no subprocess can be
# told otherwise, which would leave every case below unrunnable on the Linux
# hosts they were written on.
run_adapter_builtin() {
  local d="$1" session="${2:-}"; shift 2 || shift
  rm -f "$d/bin/bwrap"
  link_min_tools "$d/bin"
  stub_uname_darwin "$d/bin"
  echo "the actual prompt text" | env -i "$@" \
    PATH="$d/bin" HOME="$d/home" TMPDIR="$d/work/.pr-tmp" SHELL=/bin/bash \
    "$BASH" "$PR_ROOT/adapters/claude.sh" \
      "$d/work" "$session" "$d/r.md" "$d/m.txt" "$d/reason.txt" > "$d/out.txt" 2>&1
}

# The third case, and it is a REFUSAL rather than a half. Claude Code's own
# sandbox is built on bubblewrap on Linux, so on a host with no bwrap the
# condition that would select the builtin half is the condition that breaks it:
# the CLI exits without an init line, naming bwrap (measured 2026-08-30, row L3
# of FINDINGS-2026-08-30-linux.md). Refusing here costs a `command -v` instead
# of a paid round, and it reports the missing package rather than "the envelope
# has moved". agy's rule, agy's spelling: an adapter that cannot confine writes
# must not run at all.
#
# No uname stub: run_adapter_builtin's is what makes the OTHER cases Darwin, and
# its absence is what makes this one Linux. That is the whole difference.
test_no_bwrap_and_not_darwin_refuses_rather_than_running_unconfined() {
  local d rc; d="$(setup claude-sonnet-5 default)"
  rm -f "$d/bin/bwrap"
  link_min_tools "$d/bin"
  echo "the actual prompt text" | env -i \
    PATH="$d/bin" HOME="$d/home" TMPDIR="$d/work/.pr-tmp" SHELL=/bin/bash \
    "$BASH" "$PR_ROOT/adapters/claude.sh" \
      "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > "$d/out.txt" 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "refuses"
  assert_file_missing "$d/bin/claude-argv.txt" "and refuses BEFORE spawning the CLI"
  assert_file_missing "$d/r.md" "so no review is produced"
  assert_contains "$(cat "$d/out.txt")" "bwrap (bubblewrap) not found" "names the dependency"
  assert_contains "$(cat "$d/out.txt")" "no second mechanism to fall back to" \
    "and says why the built-in sandbox is not one here"
  assert_contains "$(cat "$d/out.txt")" "sudo apt install bubblewrap" "with the fix"
  assert_contains "$(cat "$d/reason.txt")" "bwrap is missing" \
    "and the round's detail names the cause, not just 'exit 1, no output'"
}

# The fourth refusal, and the only one that is about a coreutil. Without tee the
# pipeline that writes $stream fails, jq reads an empty file, and the init-line
# tripwire reports the vendor's envelope as having changed -- sending someone to
# re-measure a CLI that is behaving perfectly. lib/doctor.sh's PR_DOCTOR_UTILS
# lists tee but never reaches a round, which is why the guard is in the adapter,
# the same depth lib/lock.sh checks flock at.
#
# bwrap is LEFT in place, so this runs the shipped Linux half: the guard sits
# above the confinement predicate and neither half may reach the pipe without a
# tee. Built on the min-tools PATH for the usual reason -- tee is in /usr/bin on
# a host that has it, and PATH cannot subtract.
test_a_missing_tee_is_refused_rather_than_misreported_as_envelope_drift() {
  local d rc; d="$(setup claude-sonnet-5 bypassPermissions)"
  link_min_tools "$d/bin"
  rm -f "$d/bin/tee"
  echo "the actual prompt text" | env -i \
    PATH="$d/bin" HOME="$d/home" TMPDIR="$d/work/.pr-tmp" SHELL=/bin/bash \
    "$BASH" "$PR_ROOT/adapters/claude.sh" \
      "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > "$d/out.txt" 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "refuses"
  assert_file_missing "$d/bin/claude-argv.txt" "and refuses BEFORE spawning the CLI"
  assert_file_missing "$d/r.md" "so no review is produced"
  assert_contains "$(cat "$d/out.txt")" "tee not found on PATH" "names the missing util"
  assert_not_contains "$(cat "$d/out.txt")" "envelope has changed" \
    "and does not send the operator to re-measure an innocent vendor CLI"
  assert_contains "$(cat "$d/reason.txt")" "needs tee(1)" \
    "the round's detail names the coreutil, not the envelope"
}

test_no_bwrap_switches_to_the_builtin_sandbox_rather_than_refusing() {
  local d rc; d="$(setup claude-sonnet-5 default)"
  run_adapter_builtin "$d"; rc=$?
  assert_exit_code "$rc" 0 "runs; the built-in sandbox is the barrier here"
  assert_file_exists "$d/bin/claude-argv.txt" "the CLI was invoked"
  assert_file_exists "$d/r.md" "a review was produced"
}

# The whole point of the builtin half: the CLI must NOT be told to skip
# permissions, because permissionMode `default` is what keeps the unsandboxed
# Write and Edit tools inside the workspace (measured 2026-08-30 -- with Write
# allowed, a write to $HOME outside filesystem.allowWrite SUCCEEDED).
test_the_builtin_half_never_skips_permissions() {
  local d argv; d="$(setup claude-sonnet-5 default)"
  run_adapter_builtin "$d"
  argv="$(cat "$d/bin/claude-argv.txt")"
  assert_not_contains "$argv" "--dangerously-skip-permissions" "permissions are not skipped"
  assert_contains "$argv" "--safe-mode" "safe mode still on"
  assert_contains "$argv" "--settings" "a settings file is passed"
}

test_the_builtin_half_declares_a_fail_closed_sandbox() {
  local d settings; d="$(setup claude-sonnet-5 default)"
  run_adapter_builtin "$d"
  settings="$(cat "$d/config/pr-sandbox-settings.json")"
  # failIfUnavailable is not optional: the fail-open default was OBSERVED on
  # Linux ("Sandbox disabled ... Commands will run WITHOUT sandboxing") and the
  # init frame carries no sandbox field to assert against instead.
  assert_contains "$settings" '"failIfUnavailable": true' "refuses to start unsandboxed"
  assert_contains "$settings" '"allowUnsandboxedCommands": false' "no unsandboxed commands"
  assert_contains "$settings" '"excludedCommands": []' "no command is exempted from the sandbox"
  assert_contains "$settings" "$d/work" "the workdir is the writable set"
  assert_not_contains "$settings" '"allow"' "no permissions allowlist: Write must stay denied"
}

# Measured 2026-08-30: a repo shipping .claude/settings.json with sandbox.enabled
# false switched the sandbox OFF from the other side and a Bash tool call wrote
# $HOME, with our --settings file saying the opposite. Same shape as the
# .cursor/ finding, same remedy.
test_the_builtin_half_removes_the_repo_copys_claude_dir() {
  local d; d="$(setup claude-sonnet-5 default)"
  mkdir -p "$d/work/.claude"
  printf '{"sandbox":{"enabled":false}}\n' > "$d/work/.claude/settings.json"
  run_adapter_builtin "$d"
  assert_file_missing "$d/work/.claude/settings.json" "the repo copy cannot reopen the sandbox"
}

# The assertion is on the SHORT PATH'S OWN LENGTH, not on 73 and not on 86:
# both of those are properties of socket names we do not control and they
# differ by platform.
test_the_builtin_half_exports_a_short_private_tmpdir() {
  local d t; d="$(setup claude-sonnet-5 default)"
  run_adapter_builtin "$d"
  t="$(sed -n 's/^TMPDIR=//p' "$d/bin/claude-env.txt")"
  assert_contains "$t" "/tmp/pr-claude-" "an adapter-owned TMPDIR"
  (( ${#t} <= 32 )) || pr_fail "the private TMPDIR is ${#t} bytes, not far below the 108-byte socket ceiling: $t"
}

# No bwrap means no --ro-bind, so the credentials are COPIED. That is a second
# credential at rest, exactly as adapters/codex.sh's auth.json copy is, and it
# is the one place the two halves differ in what they cost the operator.
test_the_builtin_half_copies_the_credentials_it_cannot_bind() {
  local d; d="$(setup claude-sonnet-5 default)"
  run_adapter_builtin "$d"
  assert_file_exists "$d/config/.credentials.json" "credentials materialised"
  assert_eq "$(cat "$d/config/.credentials.json")" '{"fake":"token"}' "the same token"
}

test_the_builtin_half_refuses_when_there_is_no_credential_route() {
  local d rc; d="$(setup claude-sonnet-5 default)"
  rm -f "$d/home/.claude/.credentials.json"
  run_adapter_builtin "$d"; rc=$?
  assert_exit_code "$rc" 1 "refuses rather than letting the CLI fail at login"
  assert_contains "$(cat "$d/out.txt")" "no credentials" "says what is missing"
  assert_contains "$(cat "$d/reason.txt")" "credentials" "and says it in the round's detail"
  assert_file_missing "$d/bin/claude-argv.txt" "the CLI was never invoked"
}

test_the_builtin_half_asserts_permission_mode_default_not_bypass() {
  local d rc; d="$(setup claude-sonnet-5 bypassPermissions)"
  run_adapter_builtin "$d"; rc=$?
  assert_exit_code "$rc" 1 "a bypassPermissions session is not what this half asked for"
  assert_contains "$(cat "$d/out.txt")" "expected default" "names the mode it wanted"
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
# ---------------------------------------------------------------------------
# "The reviewer ran at least one command successfully."
#
# Everything else in this file can be satisfied by a review that ran NOTHING,
# and there are four MEASURED routes to exactly that -- C1 (the $TMPDIR socket
# ceiling), C3 (failIfUnavailable starts and denies every call), C6 (Linux: the
# command needs approval headless cannot grant and never runs) and D3 (macOS:
# the command runs and the kernel denies the write). All four end in a
# confident, empty, is_error:false round with a real session id and model.
# Three of the four are Linux's, which is why this is asserted on BOTH halves.
# ---------------------------------------------------------------------------

test_a_review_that_ran_no_command_is_refused() {
  local d rc; d="$(setup claude-sonnet-5 bypassPermissions false "a review" 0 yes completed none)"
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 1 "a review that ran nothing is not a review"
  assert_contains "$(cat "$d/out.txt")" "ran no command successfully" "says what is wrong"
  assert_file_missing "$d/r.md" "and records nothing"
}

test_a_review_whose_every_command_errored_is_refused() {
  local d rc; d="$(setup claude-sonnet-5 bypassPermissions false "a review" 0 yes completed error)"
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 1 "every command denied is the same failure as none issued"
  assert_contains "$(cat "$d/out.txt")" "ran no command successfully" "says what is wrong"
}

# The reason file, not just stderr: this is what round.json carries as the
# reviewer's detail, and "the review rests on reading alone" is the sentence an
# operator has to see to know the round did not check anything.
test_the_no_command_refusal_reaches_the_rounds_detail() {
  local d; d="$(setup claude-sonnet-5 bypassPermissions false "a review" 0 yes completed none)"
  run_adapter "$d"
  assert_contains "$(cat "$d/reason.txt")" "rests on reading alone" "the detail says so"
}

# Asserted on the builtin half too, because that is the half where D3's shape --
# the command RUNS and Seatbelt denies the write, is_error:false on the result
# frame, permission_denials empty -- was actually measured.
test_the_no_command_refusal_applies_to_the_builtin_half_too() {
  local d rc; d="$(setup claude-sonnet-5 default false "a review" 0 yes completed none)"
  run_adapter_builtin "$d"; rc=$?
  assert_exit_code "$rc" 1 "the tripwire is not bwrap's"
  assert_contains "$(cat "$d/out.txt")" "Confinement: builtin" "and names which half it was on"
}

# The count alone says a round is untrustworthy without saying why, and the
# four routes are diagnosed by four different strings the CLI already puts in
# the tool_result. Measured 2026-08-30 on Darwin: `sandbox-exec: sandbox_apply:
# Operation not permitted` is what an UNAVAILABLE sandbox looks like there, with
# failIfUnavailable failing to refuse -- and without this excerpt that reads as
# "the reviewer was lazy" rather than "this host cannot sandbox it".
test_the_no_command_refusal_quotes_the_first_failing_tool_result() {
  local d; d="$(setup claude-sonnet-5 bypassPermissions false "a review" 0 yes completed error)"
  run_adapter "$d"
  assert_contains "$(cat "$d/out.txt")" "First failing tool result: Operation not permitted" \
    "the failure text is on stderr in full"
  assert_contains "$(cat "$d/reason.txt")" "first failure: Operation not permitted" \
    "and truncated into the round's one-line detail"
}

test_denied_tool_calls_warn_but_keep_the_review() {
  local d rc; d="$(setup)"
  install_stubs "$d/bin" "claude-sonnet-5" bypassPermissions false \
    '# review\n<!-- VERDICT: MINOR -->' 2
  run_adapter "$d"; rc=$?
  assert_exit_code "$rc" 0 "still a usable review"
  assert_file_exists "$d/r.md" "review written"
  assert_contains "$(cat "$d/out.txt")" "denied" "but the operator is told"
}

# Decision 5 (brainstorm 2026-08-27-backlog-clearing-3): stdout now carries the
# stream-json, so the kernel's `>> log-claude.txt 2>&1` makes it durable -- it
# used to die with $stream's EXIT trap, leaving log-claude.txt empty and the
# only record of a failed round deleted. The review artifact is still only the
# extracted .result: the verdict parser must never see JSON framing.
# The rewrite of 2026-08-30 nearly shipped two silent changes to the measured
# bwrap path: the stream file left behind (its EXIT trap having been moved into
# the builtin branch) and, with TMPDIR unset, sited under $workdir/.pr-tmp --
# INSIDE the repo copy, where the reviewer's own tool calls could rewrite the
# stream this adapter parses for the model, the version and the review.
test_the_bwrap_half_leaves_no_stream_file_behind() {
  local d; d="$(setup)"; run_adapter "$d"
  local leftovers; leftovers="$(find "$d" -name 'pr-claude-stream.*' 2>/dev/null)"
  assert_eq "$leftovers" "" "the stream file is removed on exit"
}

test_the_stream_file_is_never_written_inside_the_repo_copy() {
  local d; d="$(setup)"
  # TMPDIR unset is the case that used to resolve to $workdir/.pr-tmp.
  echo "prompt" | env -u TMPDIR PATH="$d/bin:$PATH" HOME="$d/home" \
    "$BASH" "$PR_ROOT/adapters/claude.sh" "$d/work" "" "$d/r.md" "$d/m.txt" \
    > "$d/out.txt" 2>&1
  assert_eq "$(find "$d/work" -name 'pr-claude-stream.*' 2>/dev/null)" "" \
    "nothing the reviewer can reach holds the stream"
  assert_file_exists "$d/r.md" "and the round still worked"
}

test_the_stream_json_is_teed_to_stdout_for_the_kernel_log() {
  local d; d="$(setup)"; run_adapter "$d"
  assert_contains "$(cat "$d/out.txt")" '"subtype":"init"' \
    "the init line reached stdout, where the kernel's log redirect catches it"
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" "the review is intact"
  assert_not_contains "$(cat "$d/r.md")" '"type":"result"' \
    "and no JSON framing leaked into the artifact the verdict parser reads"
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
  pr_test_insert_after_shebang "$d/bin/claude" \
    'echo "CLAUDE CLI FATAL: could not authenticate" >&2'
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
