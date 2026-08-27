#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# The adapter copies $HOME/.codex/auth.json into the private CODEX_HOME. Point
# HOME at a path that cannot exist, for the whole file, so no test that does not
# set its own HOME can copy the operator's real credentials into a tmpdir. The
# two tests that care about the copy override this per invocation.
HOME=/nonexistent/pr-test-home

# Installs a stub `codex` mimicking 0.147.0: banner on stderr, final message
# written to the file named by -o.
# `effort_echo` overrides what the banner reports, so a mismatch can be forced.
# The real CLI echoes back whatever it was given, including invalid values.
install_stub() {
  local bindir="$1" header="$2" effort_echo="${3:-}"
  mkdir -p "$bindir"
  cat > "$bindir/codex" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$bindir/argv.txt"
printf 'CODEX_HOME=%s\n' "\${CODEX_HOME:-}" > "$bindir/env.txt"
cat > "$bindir/stdin.txt"
out=""
prev=""
effort=""
for a in "\$@"; do
  [[ "\$prev" == "-o" || "\$prev" == "--output-last-message" ]] && out="\$a"
  [[ "\$a" == model_reasoning_effort=* ]] && effort="\${a#model_reasoning_effort=}"
  prev="\$a"
done
[[ -n "$effort_echo" ]] && effort="$effort_echo"
{
  echo "OpenAI Codex v0.147.0"
  echo "--------"
  echo "workdir: \$PWD"
  echo "model: stub-model-1"
  echo "$header"
  [[ -n "\$effort" ]] && echo "reasoning effort: \$effort"
  echo "session id: thread-xyz"
  echo "--------"
} >&2
[[ -n "\$out" ]] && printf '# Review\n<!-- VERDICT: MINOR -->\n<!-- FILES-INSPECTED: src/a.ts -->\n' > "\$out"
echo "the answer also goes to stdout"
exit 0
STUB
  chmod +x "$bindir/codex"
}

test_fresh_invocation_sets_the_verified_sandbox_flags() {
  local d; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  local argv; argv="$(cat "$d/bin/argv.txt")"
  assert_contains "$argv" "--strict-config" "strict config"
  assert_contains "$argv" 'sandbox_mode=workspace-write' "sandbox mode"
  assert_contains "$argv" "sandbox_workspace_write.exclude_slash_tmp=true" "tmp excluded"
  assert_contains "$argv" "sandbox_workspace_write.exclude_tmpdir_env_var=true" "tmpdir excluded"
  assert_contains "$argv" 'network_access=true' "network enabled per D14"
  assert_contains "$argv" "--output-last-message" "review comes from -o, not a parsed stream"
  assert_not_contains "$argv" "--json" "no JSON mode: it suppresses the sandbox banner"
  assert_not_contains "$argv" "resume" "fresh run does not resume"
}

test_prompt_arrives_on_stdin_not_argv() {
  local d; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "the actual prompt text" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/bin/stdin.txt")" "the actual prompt text" "prompt on stdin"
  assert_not_contains "$(cat "$d/bin/argv.txt")" "the actual prompt text" "not in argv"
}

test_resume_reasserts_the_sandbox_and_orders_global_flags_first() {
  local d; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "thread-old" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  local argv; argv="$(cat "$d/bin/argv.txt")"
  assert_contains "$argv" "resume" "resumes"
  assert_contains "$argv" "thread-old" "with the stored handle"
  assert_contains "$argv" 'sandbox_mode=workspace-write' "sandbox reasserted on resume"
  # codex rejects both `exec resume --color never` and `--color never exec`.
  # --color belongs to `exec` and must sit between `exec` and `resume`.
  # argv.txt is one argument per line, so compare line numbers.
  local exec_line color_line resume_line
  exec_line="$(grep -n -x -- 'exec' "$d/bin/argv.txt" | cut -d: -f1)"
  color_line="$(grep -n -x -- '--color' "$d/bin/argv.txt" | cut -d: -f1)"
  resume_line="$(grep -n -x -- 'resume' "$d/bin/argv.txt" | cut -d: -f1)"
  [[ -n "$exec_line" && -n "$color_line" && -n "$resume_line" \
     && "$exec_line" -lt "$color_line" && "$color_line" -lt "$resume_line" ]] \
    || pr_fail "argv order must be exec < --color < resume (got exec=${exec_line:-none} color=${color_line:-none} resume=${resume_line:-none})"
  assert_contains "$argv" "--skip-git-repo-check" "resume re-checks directory trust too"
}

test_meta_captures_session_model_effort_and_cli_version_from_stderr() {
  local d; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "prompt" | PR_CODEX_EFFORT=xhigh PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_eq "$(sed -n 1p "$d/m.txt")" "thread-xyz" "session id captured"
  assert_eq "$(sed -n 2p "$d/m.txt")" "stub-model-1" "effective model captured"
  assert_eq "$(sed -n 3p "$d/m.txt")" "xhigh" "effective effort captured"
  assert_eq "$(sed -n 4p "$d/m.txt")" "0.147.0" "cli version captured"
}

test_effort_pin_reaches_argv_as_a_config_override() {
  local d argv; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "prompt" | PR_CODEX_EFFORT=high PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(cat "$d/bin/argv.txt")"
  assert_contains "$argv" "model_reasoning_effort=high" "effort passed as -c override"
  assert_not_contains "$argv" "--effort" "codex has no --effort flag; that is agy's"
}

# An unset pin means "use whatever codex is configured for", so there is nothing
# to compare and the adapter must not invent an expectation.
test_no_effort_pin_sends_no_override_and_still_succeeds() {
  local d rc; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "prompt" | PR_CODEX_EFFORT= PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "runs without a pin"
  assert_not_contains "$(cat "$d/bin/argv.txt")" "model_reasoning_effort" "no override sent"
  assert_eq "$(sed -n 3p "$d/m.txt")" "" "effort line empty, not fabricated"
}

# Guards against a silent downgrade, not a typo: a typo is rejected by the backend
# with a 400 and produces no review at all (verified). This fires when the banner
# reports an effort other than the one asked for, which would otherwise be recorded
# in round.json as the requested value.
test_an_effort_the_banner_does_not_confirm_aborts() {
  local d rc; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]" "medium"
  mkdir -p "$d/work"
  echo "prompt" | PR_CODEX_EFFORT=xhigh PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > "$d/out.txt" 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "aborts"
  assert_file_missing "$d/r.md" "no review kept"
  assert_contains "$(cat "$d/out.txt")" "asked for reasoning effort 'xhigh'" "says what it wanted"
  assert_contains "$(cat "$d/out.txt")" "medium" "and what it got"
}

# The banner is on stderr and the answer arrives via -o. If the adapter ever
# merges the streams, this file gains banner text and the review is corrupt.
test_review_file_holds_only_the_review() {
  local d; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" "review captured"
  assert_not_contains "$(cat "$d/r.md")" "OpenAI Codex v" "no banner leaked in"
  assert_not_contains "$(cat "$d/r.md")" "session id:" "no session line leaked in"
}

test_unexpected_sandbox_header_aborts_with_no_review() {
  local d rc; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: danger-full-access"
  mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > "$d/out.txt" 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "aborts"
  assert_file_missing "$d/r.md" "no review written"
  assert_contains "$(cat "$d/out.txt")" "workspace-write [workdir]" "explains the expectation"
  # The symptom names no file, so both the log and the reason -- the only line
  # the round's summary shows -- must name the likeliest cause. That file is the
  # config.toml codex writes into the private CODEX_HOME, NOT the operator's
  # ~/.codex, which this reviewer no longer reads: a diagnostic pointing at a
  # file the reviewer does not read is worse than none.
  assert_contains "$(cat "$d/out.txt")" "codex-home/config.toml" \
    "the log names the file the operator has to look in"
  assert_not_contains "$(cat "$d/out.txt")" "~/.codex/config.toml" \
    "and not the one the private home took out of scope"
  assert_contains "$(cat "$d/reason.txt")" "codex-home/config.toml" \
    "and so does the reason carried back to the round"
}

# A missing banner is not a pass. --json suppresses it, and so would any future
# change that quiets stderr; the assertion must fail closed.
test_missing_sandbox_header_aborts() {
  local d rc; d="$(pr_test_tmpdir)"
  mkdir -p "$d/bin" "$d/work"
  cat > "$d/bin/codex" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
exit 0
STUB
  chmod +x "$d/bin/codex"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > "$d/out.txt" 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "aborts on a silent CLI"
  assert_contains "$(cat "$d/out.txt")" "no sandbox line" "says the banner was absent"
}

# The operator's ~/.codex/config.toml took a reviewer out once already
# (P6 side-finding: an obsolete top-level field failed --strict-config and
# codex never started -- still reproducible on this host at codex-cli 0.150.1,
# probes/2026-08-27-codex-private-home leg 0). A private CODEX_HOME, sibling to
# the repo copy so rollouts survive pr_sandbox_refresh's per-round wipe, removes
# the operator's user-level config from the round.
test_codex_runs_under_a_private_home_with_hooks_off() {
  local d; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/sandbox/repo" "$d/home/.codex"
  echo '{"tokens": "operator"}' > "$d/home/.codex/auth.json"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  assert_contains "$(< "$d/bin/env.txt")" \
    "CODEX_HOME=$d/sandbox/codex-home" "private home, sibling to the repo copy"
  assert_contains "$(< "$d/bin/argv.txt")" "features.hooks=false" \
    "repo-supplied hooks are off"
  assert_file_exists "$d/sandbox/codex-home/auth.json" \
    "auth material copied in, not pointed at"
  assert_eq "$(< "$d/home/.codex/auth.json")" '{"tokens": "operator"}' \
    "the operator's real auth file is untouched"
}

# Reviewer-scoped write integrity: an uncreatable home fails THIS reviewer
# before the CLI is spawned -- claude's and agy's shape.
test_uncreatable_codex_home_fails_before_spawning() {
  local d rc; d="$(pr_test_tmpdir)"
  install_stub "$d/bin" "sandbox: workspace-write [workdir]"
  mkdir -p "$d/sandbox/repo"; chmod 555 "$d/sandbox"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/codex.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  rc=$?
  chmod 755 "$d/sandbox"
  assert_exit_code "$rc" 1 "refuses when the private home is uncreatable"
  assert_file_missing "$d/bin/argv.txt" "the CLI was never invoked"
}

pr_run_tests
