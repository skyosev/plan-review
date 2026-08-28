#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# Stub `agent`: logs argv, emits a review, and exits with a configurable code.
install_stub() {
  local bindir="$1" exit_code="$2"
  mkdir -p "$bindir"
  cat > "$bindir/agent" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$bindir/argv.txt"
if [[ "\$1" == "create-chat" ]]; then
  echo "chat-uuid-123"
  exit 0
fi
if [[ "\$1" == "--version" ]]; then
  echo "2026.08.11-e8db854"
  exit 0
fi
cat > "$bindir/stdin.txt"
printf '# Cursor review\n<!-- VERDICT: MINOR -->\n<!-- FILES-INSPECTED: src/a.ts -->\n'
exit $exit_code
STUB
  chmod +x "$bindir/agent"
  # Every test in this file now resolves `bwrap`, because the adapter wraps all
  # three of its invocations. A host whose real bwrap is installed but unusable
  # (userns restrictions, no bwrap at all) must not decide unit-test outcomes,
  # so the stub goes in unconditionally and the no-bwrap case removes it again.
  install_bwrap_stub "$bindir"
}

# Records argv one per line, then execs the real command from the first
# `agent` in the argument list — same shape as agy's bwrap stub.
install_bwrap_stub() {
  local bindir="$1"
  cat > "$bindir/bwrap" <<STUB
#!/usr/bin/env bash
args=("\$@")
for i in "\${!args[@]}"; do
  # The adapter's readiness probe is \`bwrap <flags> true\`: presence on PATH is
  # not a working jail, so it tries the flags before deciding to wrap. It is
  # not a vendor invocation, so it is answered but NOT recorded -- the argv log
  # counts wrapped \`agent\` calls and the count assertion below depends on that.
  [[ "\${args[\$i]}" == true ]] && exit 0
  if [[ "\${args[\$i]}" == agent ]]; then
    printf '%s\n' "\$@" >> "$bindir/bwrap-argv.txt"
    exec "\${args[@]:\$i}"
  fi
done
exit 1
STUB
  chmod +x "$bindir/bwrap"
}

# Every test below pins a model, because the adapter now requires one.
export PR_AGENT_MODEL=stub-model-high

test_an_unset_model_pin_is_refused() {
  local d rc; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "prompt" | PR_AGENT_MODEL= PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "refuses to run without a model pin"
  assert_file_missing "$d/bin/argv.txt" "the CLI was never invoked"
}

test_the_model_pin_reaches_argv_and_the_meta_block() {
  local d; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "uuid-old" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/bin/argv.txt")" "stub-model-high" "pin passed to the CLI"
  assert_eq "$(sed -n 2p "$d/m.txt")" "stub-model-high" "pin recorded as the model"
  assert_not_contains "$(cat "$d/bin/argv.txt")" "--effort" "Cursor has no --effort flag"
}

test_fresh_run_creates_a_chat_and_records_its_uuid() {
  local d; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/bin/argv.txt")" "create-chat" "chat created"
  assert_eq "$(sed -n 1p "$d/m.txt")" "chat-uuid-123" "uuid stored"
  assert_eq "$(sed -n 3p "$d/m.txt")" "" "no separate effort: it is in the model id"
  assert_eq "$(sed -n 4p "$d/m.txt")" "2026.08.11-e8db854" "cli version recorded"
}

test_run_uses_sandbox_enabled_and_trust() {
  local d argv; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(cat "$d/bin/argv.txt")"
  assert_contains "$argv" "--sandbox" "sandbox flag present"
  assert_contains "$argv" "enabled" "write confinement on; the sandbox does allow network"
  assert_not_contains "$argv" "disabled" "sandbox must not be turned off"
  assert_contains "$argv" "--trust" "directory trusted"
}

test_existing_session_is_resumed_without_creating_a_chat() {
  local d; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "uuid-old" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  local argv; argv="$(cat "$d/bin/argv.txt")"
  assert_not_contains "$argv" "create-chat" "no new chat"
  assert_contains "$argv" "uuid-old" "resumed"
  assert_eq "$(sed -n 1p "$d/m.txt")" "uuid-old" "handle preserved"
}

test_prompt_arrives_on_stdin() {
  local d; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "the actual prompt text" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/bin/stdin.txt")" "the actual prompt text" "stdin used"
}

test_exit_two_still_yields_a_review() {
  local d rc; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 2; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "adapter normalises the known exit-2 case"
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" "review kept"
}

# Measured during the Task 12 smoke test: Cursor answered with a different model
# than the pin after the pinned one hit a safety filter, announcing it only as
# prose in its own output while the run succeeded. Recording the pin regardless
# would put a model in round.json that never answered (Q2/R11).
install_switching_stub() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/agent" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "create-chat" ]]; then echo "chat-uuid-123"; exit 0; fi
if [[ "$1" == "--version" ]]; then echo "2026.08.11-e8db854"; exit 0; fi
cat > /dev/null
printf '# Review\n<!-- VERDICT: MINOR -->\n<!-- FILES-INSPECTED: src/a.ts -->\n'
printf 'Switched to Claude Opus 4.8\n\n'
printf 'Claude Opus 5 hit a safety filter, and the conversation was automatically switched.\n'
exit 0
STUB
  chmod +x "$bindir/agent"
  # Same reason as in install_stub: this helper builds its own `agent` rather
  # than calling that one, so it has to supply the bwrap stub itself or the
  # test would run against whatever bwrap the host happens to have.
  install_bwrap_stub "$bindir"
}

test_a_mid_run_model_switch_is_recorded_not_the_pin() {
  local d; d="$(pr_test_tmpdir)"; install_switching_stub "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(sed -n 2p "$d/m.txt")" "Claude Opus 4.8" "the model that actually answered"
  assert_contains "$(sed -n 2p "$d/m.txt")" "stub-model-high" "the pin is still visible as requested"
}

test_no_switch_notice_records_the_pin_alone() {
  local d; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_eq "$(sed -n 2p "$d/m.txt")" "stub-model-high" "no annotation when nothing switched"
}

# The CLI's stderr is INHERITED, not redirected (2026-08-27). That is what puts
# it on this adapter's own stderr and so, in a round, into <round>/log-agent.txt
# via the kernel's `>> "$log" 2>&1`. There are exactly two ways to break it and
# this pins both, because neither is visible without an assertion here:
# `2>>"${review_out}.log"` -- the form this replaced -- loses the text to a
# dotfile no documentation names, and `2>&1` splices it INTO the review, because
# stdout has already been pointed at "$review_out" by the time it runs. Measured
# 2026-08-27: the second put "CURSOR CLI FATAL" above the VERDICT marker that
# lib/verdict.sh parses.
#
# `2>&1 >/dev/null` captures stderr ALONE -- fd 2 is duplicated onto the capture
# pipe first, then fd 1 is sent elsewhere. That is the same ordering rule the fix
# turns on, which is why it is spelled this way rather than with a temp file.
test_the_clis_stderr_is_inherited_not_redirected() {
  local d out; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0; mkdir -p "$d/work"
  # Line 2 is straight after the shebang, so every stub invocation writes it. The
  # adapter's own create-chat and --version calls drop stderr with 2>/dev/null,
  # so what reaches the capture is the review run's stderr and nothing else.
  sed -i '2i echo "CURSOR CLI FATAL: could not authenticate" >&2' "$d/bin/agent"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" 2>&1 >/dev/null)"
  assert_contains "$out" "CURSOR CLI FATAL" \
    "the CLI's stderr reaches the adapter's stderr, which the round logs"
  # Positive first, so the negative below cannot pass vacuously on a missing file.
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" "the review is intact"
  assert_not_contains "$(cat "$d/r.md")" "CURSOR CLI FATAL" \
    "and the error text never enters the artifact the verdict parser reads"
  assert_file_missing "$d/r.md.log" "no derived .log file beside the review"
}

# Cursor confines its own WRITES (--sandbox enabled) but nothing contains its
# process tree: P6 measured its tool layer taking its own process group AND
# session, out of reach of the kernel's group kill. bwrap here supplies ONLY
# the pid namespace — and EVERY agent invocation goes through it, create-chat
# and --version included, because "short-lived, nothing to contain" is an
# assumption nobody measured.
test_every_agent_invocation_runs_in_a_pid_namespace_when_bwrap_exists() {
  local d; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  local argv; argv="$(< "$d/bin/bwrap-argv.txt")"
  assert_contains "$argv" "--unshare-pid" "pid namespace requested"
  assert_contains "$argv" "--die-with-parent" "dies with the runner"
  # The stub appends one argv block per invocation, and every wrapped
  # invocation carries --unshare-pid exactly once — so the count IS the
  # number of wrapped calls. Three call sites exist; create-chat and
  # --version are named below, which pins the third as the review run.
  # A concatenated-contains check alone would pass an implementation that
  # wraps only one of them.
  assert_eq "$(grep -cx -- '--unshare-pid' "$d/bin/bwrap-argv.txt")" "3" \
    "all three agent invocations are wrapped"
  assert_contains "$argv" "create-chat" "session creation is wrapped"
  assert_contains "$argv" "--version" "the meta version read is wrapped"
}

# No bwrap is not an error here, unlike agy/claude: bwrap is not this
# adapter's write barrier, only its pid fence, and macOS has no bwrap at all.
# The kernel's descendant sweep is the documented bound in that case.
test_review_still_runs_without_bwrap() {
  local d rc b; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0
  rm -f "$d/bin/bwrap"
  mkdir -p "$d/work"
  # PATH is narrowed so `command -v bwrap` genuinely misses; bash goes by
  # "$BASH" because it is no longer on that PATH either (agy's
  # test_missing_bwrap_fails_closed pattern). Unlike agy, this adapter runs
  # to completion unwrapped, so the narrowed PATH must carry every external
  # the adapter and stub call: sed and head (the Switched-to parse), tail
  # and tr (create-chat and the meta version read), cat (the stub) -- and
  # bash, because the stub's `#!/usr/bin/env bash` resolves the interpreter
  # through PATH, so without it the CLI cannot start and the test would fail
  # for a reason that has nothing to do with bwrap.
  for b in sed head tail tr cat bash; do ln -s "$(command -v "$b")" "$d/bin/$b"; done
  echo "prompt" | PATH="$d/bin" \
    "$BASH" "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "runs unwrapped when the platform has no mechanism"
  assert_file_exists "$d/bin/argv.txt" "the CLI ran"
}

# Presence on PATH is not a working jail. On a host with bwrap installed but
# its user namespaces denied (Ubuntu 24.04's
# kernel.apparmor_restrict_unprivileged_userns=1 — the exact case
# lib/doctor.sh diagnoses), a wrap gated on `command -v` made all three
# invocations fail and the round lost this reviewer with "create-chat produced
# no session id". The adapter tries the flags instead, so a jail that will not
# start costs the pid fence and not the review.
test_a_broken_jail_costs_the_fence_not_the_reviewer() {
  local d rc; d="$(pr_test_tmpdir)"; install_stub "$d/bin" 0
  # The failing stub still RECORDS: without that, asserting bwrap-argv.txt
  # missing proved only that the recording stub was overwritten (BACKLOG
  # 2026-08-27, "Four checks..."). Appending, so the trial and any would-be
  # wrap both land in the file.
  pr_test_mkstub "$d/bin/bwrap" \
    "printf '%s\n' \"\$@\" >> '$d/bin/bwrap-argv.txt'; exit 1"
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agent.sh" "$d/work" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "the review still runs unwrapped"
  assert_file_exists "$d/bin/argv.txt" "the CLI ran"
  assert_contains "$(cat "$d/bin/bwrap-argv.txt")" "true" "the jail was trialled once"
  assert_not_contains "$(cat "$d/bin/bwrap-argv.txt")" "agent" "and no vendor call was wrapped"
}

pr_run_tests
