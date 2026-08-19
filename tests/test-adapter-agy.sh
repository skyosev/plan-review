#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# Stubs both binaries. The bwrap stub logs its own argv, then execs the first
# `agy` it finds in the argument list, so the adapter's real command still runs
# and the jail flags stay assertable.
install_stubs() {
  # `${3-...}`, not `${3:-...}`: the empty-response case passes "" deliberately,
  # and the colon form would treat that as "unset" and hand back the default
  # review — leaving the auto-deny signature untested.
  local bindir="$1" status="${2:-SUCCESS}" response="${3-# agy review\n<!-- VERDICT: MINOR -->\n<!-- FILES-INSPECTED: src/a.ts -->}"
  # Fourth argument: text the stub writes to stderr before answering. That is
  # where agy puts a quota refusal, and the classifier reads it from there.
  local errtext="${4:-}"
  mkdir -p "$bindir"

  cat > "$bindir/bwrap" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$bindir/bwrap-argv.txt"
args=("\$@")
for i in "\${!args[@]}"; do
  if [[ "\${args[\$i]}" == */agy || "\${args[\$i]}" == agy ]]; then
    exec "\${args[@]:\$i}"
  fi
done
echo "bwrap stub: no agy in argv" >&2
exit 127
STUB

  cat > "$bindir/agy" <<STUB
#!/usr/bin/env bash
# Appends: the adapter also calls \`agy --version\`, and an overwrite here would
# clobber the record of the run being asserted on.
printf '%s\n' "\$@" >> "$bindir/agy-argv.txt"
cat > "$bindir/agy-stdin.txt"
if [[ "\$1" == "--version" ]]; then echo "1.1.13"; exit 0; fi
printf '%s' '$errtext' >&2
jq -nc --arg s "$status" --arg r "\$(printf '$response')" \
  '{conversation_id: "conv-abc-123", status: \$s, response: \$r, duration_seconds: 1, num_turns: 1}'
exit 0
STUB
  chmod +x "$bindir/bwrap" "$bindir/agy"
}

export PR_AGY_MODEL=gemini-3.1-pro-high

test_an_unset_model_pin_is_refused() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PR_AGY_MODEL= PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "refuses without a model pin"
  assert_file_missing "$d/bin/agy-argv.txt" "the CLI was never invoked"
}

# The single most important test in this file. agy has no working sandbox of its
# own, so an adapter that runs it without bwrap runs it unconfined.
test_missing_bwrap_fails_closed() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  rm -f "$d/bin/bwrap"
  # PATH is narrowed to the stub dir so `command -v bwrap` genuinely misses, and
  # bash is invoked by absolute path because it is no longer on that PATH either.
  # The adapter checks for bwrap before it needs any other external binary.
  out="$(echo "prompt" | PATH="$d/bin" "$BASH" "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refuses to run unconfined"
  assert_contains "$out" "bwrap" "names the missing dependency"
  assert_file_missing "$d/bin/agy-argv.txt" "agy was never invoked"
  assert_file_missing "$d/r.md" "no review produced"
}

test_jail_binds_the_workdir_writable_and_the_root_readonly() {
  local d argv; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(cat "$d/bin/bwrap-argv.txt")"
  assert_contains "$argv" "--ro-bind" "root mounted read-only"
  assert_contains "$argv" "--bind" "workdir mounted read-write"
  assert_contains "$argv" "$d/work" "the workdir is the writable path"
  assert_contains "$argv" "--tmpfs" "private /tmp, so a /tmp escape lands nowhere real"
  assert_contains "$argv" "--die-with-parent" "jail dies with the timeout"
}

test_prompt_is_passed_as_argv_because_agy_cannot_read_stdin() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "the actual prompt text" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/bin/agy-argv.txt")" "the actual prompt text" "prompt in argv"
}

# No stdin fallback exists for agy, so the cap must be enforced here rather than
# surfacing as a bare E2BIG from execve.
test_an_oversized_prompt_is_refused_with_a_clear_message() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  out="$(head -c 200000 /dev/zero | tr '\0' 'x' \
    | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
        "$d/work" "" "$d/r.md" "$d/m.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refuses an oversized prompt"
  assert_contains "$out" "131072" "names the limit"
  assert_file_missing "$d/bin/agy-argv.txt" "never reached execve"
}

test_workdir_is_targeted_with_add_dir() {
  local d argv; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(cat "$d/bin/agy-argv.txt")"
  assert_contains "$argv" "--add-dir" "workspace targeted explicitly"
  assert_contains "$argv" "$d/work" "at the workdir; agy ignores cwd"
}

test_permissions_are_skipped_and_effort_is_never_passed() {
  local d argv; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(cat "$d/bin/agy-argv.txt")"
  assert_contains "$argv" "--dangerously-skip-permissions" "headless tools would auto-deny otherwise"
  assert_contains "$argv" "gemini-3.1-pro-high" "model pin passed"
  # --model and --effort are mutually exclusive: passing both is a hard error.
  assert_not_contains "$argv" "--effort" "effort lives in the model id"
}

test_fresh_run_records_the_conversation_id() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_not_contains "$(cat "$d/bin/agy-argv.txt")" "--conversation" "no resume on a fresh run"
  assert_eq "$(sed -n 1p "$d/m.txt")" "conv-abc-123" "conversation_id captured"
  assert_eq "$(sed -n 2p "$d/m.txt")" "gemini-3.1-pro-high" "pin recorded as the model"
  assert_eq "$(sed -n 3p "$d/m.txt")" "" "no separate effort: the id carries it"
  assert_eq "$(sed -n 4p "$d/m.txt")" "1.1.13" "cli version recorded"
}

test_existing_session_is_resumed() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "conv-old" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  local argv; argv="$(cat "$d/bin/agy-argv.txt")"
  assert_contains "$argv" "--conversation" "resumes"
  assert_contains "$argv" "conv-old" "with the stored handle"
}

test_review_file_holds_the_response_not_the_json_envelope() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" "review extracted"
  assert_not_contains "$(cat "$d/r.md")" "conversation_id" "envelope stripped"
  assert_not_contains "$(cat "$d/r.md")" "duration_seconds" "envelope stripped"
}

# The auto-deny signature: exit 0, status SUCCESS, empty response. Trusting the
# exit code here would record a silent non-review as a real one.
test_an_empty_response_is_a_failure_despite_exit_zero() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin" SUCCESS ""; mkdir -p "$d/work"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "empty response is a failure"
  assert_contains "$out" "empty" "says what was wrong"
  assert_contains "$(cat "$d/reason.txt")" "auto-deny signature" \
    "the runner gets the diagnosis, not just the log"
}

# A CLI descendant that inherits stdout holds a PIPE open past the CLI's own
# exit. Captured through a command substitution, the adapter would then block on
# a finished review until the runner's deadline fired, and the round would record
# a timeout for a review that was already written.
#
# The stub's grandchild holds the inherited descriptor rather than a `sleep` of
# its own, which is what makes this different from
# tests/fixtures/adapters/fake-slow-with-child.sh.
test_a_descendant_holding_stdout_does_not_block_the_adapter() {
  local d rc child; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  cat > "$d/bin/agy" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "1.1.13"; exit 0; fi
cat > /dev/null
# Inherits this process's stdout and keeps it open for five minutes.
( sleep 300 ) &
echo \$! > "$d/child.pid"
jq -nc '{conversation_id: "conv-abc-123", status: "SUCCESS", response: "# r\n<!-- VERDICT: MINOR -->"}'
exit 0
STUB
  chmod +x "$d/bin/agy"

  echo "prompt" | PATH="$d/bin:$PATH" \
    timeout 10 bash "$PR_ROOT/adapters/agy.sh" \
      "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  rc=$?

  child="$(cat "$d/child.pid" 2>/dev/null)"
  [[ -n "$child" ]] && kill -9 "$child" 2>/dev/null

  assert_exit_code "$rc" 0 "returned without waiting for the descendant"
  assert_contains "$(cat "$d/r.md" 2>/dev/null)" "VERDICT: MINOR" "and kept the review"
}

# ${#prompt} counts characters under a UTF-8 locale; MAX_ARG_STRLEN counts bytes.
# 70000 two-byte characters is 140000 bytes: comfortably over the cap, and
# comfortably under it if the check measures the wrong thing.
test_the_argv_cap_is_measured_in_bytes_not_characters() {
  local d rc out prompt; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  prompt="$(yes 'é' | head -70000 | tr -d '\n')"
  out="$(printf '%s' "$prompt" | LC_ALL=C.UTF-8 PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"
  rc=$?
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$out" "140000 bytes" "counted bytes, not the 70000 characters"
  assert_file_missing "$d/bin/agy-argv.txt" "never reached execve"
}

# Quota exhaustion and the auto-deny empty response look identical in the
# envelope: exit 0, no response. The strings are the only thing that separates
# them, and they are octopus's, unverified here — which is why classification
# runs only after parsing has established there is nothing to lose.
test_a_quota_refusal_is_told_apart_from_the_auto_deny_signature() {
  local d rc out; d="$(pr_test_tmpdir)"; mkdir -p "$d/work"
  install_stubs "$d/bin" SUCCESS "" \
    "Error: individual quota reached. Resets in 3h42m. Please upgrade your subscription."
  out="$(echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "still a failure"
  assert_contains "$out" "quota is exhausted" "diagnosed, not reported as auto-deny"
  assert_contains "$(cat "$d/reason.txt")" "quota reached" "and the runner is told"
  assert_contains "$(cat "$d/reason.txt")" "3h42m" "with the reset window agy gave"
}

# The reason file is a diagnosis of failure, not a log. A round that worked has
# nothing to explain, and writing one anyway would put noise in every status line.
test_a_successful_review_writes_no_reason() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  assert_file_missing "$d/reason.txt" "nothing to explain"
}

# Four arguments is how this adapter is invoked by hand, and by anything written
# against the older contract.
test_a_missing_reason_argument_is_not_an_error() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin" SUCCESS ""; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "still reports the empty response, and nothing else"
}

pr_run_tests
