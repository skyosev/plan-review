#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

# Stubs both binaries. The bwrap stub logs its own argv, then execs the first
# `agy` it finds in the argument list, so the adapter's real command still runs
# and the jail flags stay assertable.
#
# The agy stub emits a STREAM, in the shape agy 1.1.24 emitted it under
# --output-format stream-json (probes/2026-09-03-agy-stream-json/raw/A.out, kept
# verbatim as tests/fixtures/agy/leg-a.ndjson): an `init` line, one `step_update`
# per step transition, and a `result` line whose `.result` is the json envelope
# the adapter parsed until 2026-09-07. Every success case therefore needs a
# run_command step that reaches DONE -- that is the adapter's assertion, not
# decoration here -- and the fifth and sixth arguments are how a case turns each
# of the two assertable fields off.
install_stubs() {
  # `${3-...}`, not `${3:-...}`: the empty-response case passes "" deliberately,
  # and the colon form would treat that as "unset" and hand back the default
  # review — leaving the auto-deny signature untested.
  local bindir="$1" status="${2:-SUCCESS}" response="${3-# agy review\n<!-- VERDICT: MINOR -->\n<!-- FILES-INSPECTED: src/a.ts -->}"
  # Fourth argument: text the stub writes to stderr before answering. That is
  # where agy puts a quota refusal, and the classifier reads it from there.
  local errtext="${4:-}"
  # Fifth: the init line's permission_mode. Sixth: 1 to emit a run_command step
  # that reaches DONE, 0 to emit none. Both default to leg A's healthy shape.
  local perm="${5:-always-proceed}" ran="${6:-1}"
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
jq -nc --arg p '$perm' \
  '{event:"init",conversation_id:"conv-abc-123",init:{model:"stub",permission_mode:\$p}}'
if [[ "$ran" == 1 ]]; then
  jq -nc '{event:"step_update",step_update:{conversation_id:"conv-abc-123",step_index:2,state:"ACTIVE",step_type:"tool",tool_name:"run_command",tool_info:{name:"run_command",parameters:{CommandLine:"pwd"}}}}'
  jq -nc '{event:"step_update",step_update:{conversation_id:"conv-abc-123",step_index:2,state:"DONE",step_type:"tool",tool_name:"run_command",duration_seconds:0.5,tool_info:{name:"run_command",parameters:{CommandLine:"pwd"},output:"/work\n"}}}'
fi
jq -nc --arg s "$status" --arg r "\$(printf '$response')" \
  '{event:"result",result:{conversation_id:"conv-abc-123",status:\$s,response:\$r,duration_seconds:1,num_turns:1}}'
exit 0
STUB
  chmod +x "$bindir/bwrap" "$bindir/agy"
}

# A stub that replays a captured leg verbatim. Call it AFTER install_stubs, which
# is what puts the bwrap stub in place; this one only replaces `agy`.
install_leg_stub() {  # install_leg_stub <bindir> <ndjson-file>
  local bindir="$1" leg="$2"
  cat > "$bindir/agy" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >> "$bindir/agy-argv.txt"
if [[ "\$1" == "--version" ]]; then echo "1.1.24"; exit 0; fi
cat > /dev/null
cat "$leg"
exit 0
STUB
  chmod +x "$bindir/agy"
}

export PR_AGY_MODEL=gemini-3.1-pro-high

# Every case below spawns the adapter, and the adapter now CREATES its ~/.gemini
# bind destination -- bwrap cannot mkdir one under `--ro-bind / /`, so it has to
# exist on the host first. Nothing in the offline suite may write into the
# operator's real home, so HOME is redirected for the whole file here; the cases
# that care about its CONTENT still set their own per test, which shadows this.
# Removed after pr_run_tests rather than through a trap: helpers.sh cleans its
# own root the same way, and a trap here would be the only one in the suite.
HOME="$(mktemp -d "${TMPDIR:-/tmp}/pr-test-agy-home-XXXXXX")"; export HOME

# The runner validates this too, but an adapter run by hand has no runner.
test_a_fractional_timeout_is_refused_by_the_adapter() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PR_TIMEOUT_SECS=1.5 PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "refuses a fractional deadline"
  assert_file_missing "$d/bin/agy-argv.txt" "the CLI was never invoked"
}

test_a_zero_timeout_is_refused_by_the_adapter() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PR_TIMEOUT_SECS=0 PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "zero is not a positive integer"
  assert_file_missing "$d/bin/agy-argv.txt" "the CLI was never invoked"
}

# agy carries a deadline of its own inside the runner's. Left at its 5m default
# it cuts a review short with no way to tell that from an auto-deny; passed
# explicitly and below PR_TIMEOUT_SECS, the expiry is ours to recognise.
test_print_timeout_is_derived_from_the_runner_deadline() {
  local d argv; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PR_TIMEOUT_SECS=900 PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(< "$d/bin/agy-argv.txt")"
  assert_contains "$argv" "--print-timeout" "the flag is passed"
  assert_contains "$argv" "810000ms" "derived as 90% of PR_TIMEOUT_SECS, in ms"
}

# The strict ordering has to hold at the boundary too: at 1s the seconds-based
# arithmetic would make the two deadlines equal and timeout(1) could reap agy
# before it writes its final line.
test_print_timeout_stays_below_a_one_second_deadline() {
  local d argv; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PR_TIMEOUT_SECS=1 PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  argv="$(< "$d/bin/agy-argv.txt")"
  assert_contains "$argv" "900ms" "strictly inside a 1s outer deadline"
}

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

# The jail must take a pid namespace (bwrap --die-with-parent alone is
# PR_SET_PDEATHSIG on the immediate command, not tree cleanup — measured
# 2026-08-27, probes/2026-08-27-pid-namespace-adapters) and must NOT hand the
# reviewer the operator's real ~/.gemini read-write: that directory feeds the
# operator's own later sessions, so a writable bind is a persistence channel
# out of the jail. The state that persists across ROUNDS is the private
# sibling directory, exactly like claude's config dir.
test_jail_unshares_pid_and_binds_a_private_state_dir() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  mkdir -p "$d/sandbox/repo" "$d/home/.gemini"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  local argv; argv="$(< "$d/bin/bwrap-argv.txt")"
  assert_contains "$argv" "--unshare-pid" "pid namespace requested"
  assert_contains "$argv" "$d/sandbox/gemini-state" \
    "private state dir, sibling to the repo copy, bound over ~/.gemini"
  # The rw bind of the operator's real state must be gone: no --bind whose
  # SOURCE is the real ~/.gemini. (--ro-bind of individual auth files inside
  # it is allowed, which is why this greps the pair, not the path.)
  assert_eq "$(grep -Fx -A1 -- '--bind' "$d/bin/bwrap-argv.txt" \
               | grep -cFx "$d/home/.gemini")" "0" \
    "the operator's real ~/.gemini is never bound read-write"
  # helpers' assert_file_exists is [[ -f ]] and would always fail on a dir
  [[ -d "$d/sandbox/gemini-state" ]] || pr_fail "the adapter created the dir"
}

# The one file agy actually needs to authenticate, measured in leg 3 of
# probes/2026-08-27-pid-namespace-adapters: it is nested, and it is NOT the
# obvious-looking oauth_creds.json, which was tried first and failed. Bound
# read-only and by path, so nothing the reviewer writes can reach it.
test_the_measured_auth_file_is_ro_bound_and_nothing_else_is() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  mkdir -p "$d/sandbox/repo" "$d/home/.gemini/antigravity-cli"
  : > "$d/home/.gemini/antigravity-cli/antigravity-oauth-token"
  : > "$d/home/.gemini/oauth_creds.json"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  local argv; argv="$(< "$d/bin/bwrap-argv.txt")"
  assert_contains "$argv" "--ro-bind" "auth material comes in read-only"
  assert_contains "$argv" "$d/home/.gemini/antigravity-cli/antigravity-oauth-token" \
    "the file the probe measured"
  assert_not_contains "$argv" "oauth_creds.json" \
    "the candidate that failed the probe is not bound just because it exists"
}

# Reviewer-scoped write integrity: a state dir that cannot be created fails
# THIS reviewer before the CLI is spawned, claude.sh's shape.
test_uncreatable_state_dir_fails_before_spawning() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  mkdir -p "$d/sandbox/repo"; chmod 555 "$d/sandbox"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  rc=$?
  chmod 755 "$d/sandbox"
  assert_exit_code "$rc" 1 "refuses when the private state dir is uncreatable"
  assert_file_missing "$d/bin/agy-argv.txt" "the CLI was never invoked"
}

# Regression, reproduced against bubblewrap 0.9.0 on 2026-08-27: bwrap creates a
# missing bind DESTINATION by mkdir'ing it, and under `--ro-bind / /` it cannot,
# so on a host that has never run agy the jail refused to start ("Can't mkdir
# .../.gemini: Read-only file system") and the adapter reported the auto-deny
# signature instead -- the wrong cause, every round. The stub bwrap here cannot
# reproduce the refusal, so what is pinned is the fix rather than the symptom:
# the mountpoint exists before the jail is built. Note the missing `.gemini`
# in the mkdir below -- that absence IS the case, and the two tests above both
# create it.
test_the_gemini_mountpoint_is_created_when_the_host_has_none() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  mkdir -p "$d/sandbox/repo" "$d/home"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  # helpers' assert_file_exists is [[ -f ]] and would always fail on a dir
  [[ -d "$d/home/.gemini" ]] || pr_fail "the adapter created the bind destination"
  assert_file_exists "$d/r.md" "and the round still produced a review"
  # The reproduced failure was ordering-shaped: under --ro-bind / / bwrap cannot
  # mkdir a missing destination, so the mountpoint must exist BEFORE the jail is
  # built and the root bind must precede the state bind that mounts over it.
  # Assert the TUPLES, not first-token positions: keying on the first --ro-bind
  # alone stays green when the root bind is gone and some other ro-bind (the
  # creds file) stands in for it. Order is then substring order in the joined
  # argv, the same shape the two cases above assert on.
  local argv; argv="$(tr '\n' ' ' < "$d/bin/bwrap-argv.txt")"
  [[ "$argv" == *"--ro-bind / / "*"--bind $d/sandbox/gemini-state "* ]] \
    || pr_fail "the --ro-bind / / triple precedes the --bind of gemini-state over ~/.gemini"
}

# Reviewer-scoped write integrity, the state dir's shape: a mountpoint that
# cannot be created fails THIS reviewer before the CLI is spawned, rather than
# leaving bwrap to say it in its own words after the session bookkeeping.
test_an_uncreatable_gemini_mountpoint_fails_before_spawning() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  mkdir -p "$d/sandbox/repo" "$d/home"; chmod 555 "$d/home"
  echo "prompt" | HOME="$d/home" PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" \
    > /dev/null 2>&1
  rc=$?
  chmod 755 "$d/home"
  assert_exit_code "$rc" 1 "refuses when the ~/.gemini mountpoint is uncreatable"
  assert_file_missing "$d/bin/agy-argv.txt" "the CLI was never invoked"
}

# An unset HOME is the one case the adapter must not "handle": every path here
# would resolve to "/", and mkdir -p /.gemini is a no-op for root rather than an
# error. codex degrades gracefully with no HOME (there is simply no auth to
# copy); agy cannot, because the token it needs is looked up under the same HOME.
test_an_unset_home_is_refused_rather_than_resolved_to_the_filesystem_root() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/sandbox/repo"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" env -u HOME \
    bash "$PR_ROOT/adapters/agy.sh" "$d/sandbox/repo" "" "$d/r.md" "$d/m.txt" 2>&1)"
  rc=$?
  assert_exit_code "$rc" 1 "an absent HOME is refused, not resolved to /"
  assert_contains "$out" "HOME is unset" "and the message says which"
  assert_file_missing "$d/bin/agy-argv.txt" "the CLI was never invoked"
}

# `--input-format stream-json` DOES read a prompt from stdin, so the cap is not
# "agy cannot read stdin" — it is that the route drops a prompt SILENTLY somewhere
# between 16145 and 24145 bytes on the wire (probes/2026-09-03-agy-stream-json/,
# legs C–K), with the same signature the adapter reports as the auto-deny. So the
# prompt goes in argv, and this pins that it does.
test_prompt_is_passed_as_argv_because_the_stdin_route_drops_large_prompts_silently() {
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

# Third copy of one rule (adapters/agent.sh:400, adapters/claude.sh:366): the
# repository under review does not get to ship configuration the reviewer's CLI
# will read. Removed unconditionally rather than on a measurement -- see the
# comment at the removal, and probes/2026-09-01-agy-hook-surface/, whose leg A
# measured agy executing a command out of exactly this file.
test_the_repos_agents_directory_is_removed_before_the_review() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work/.agents"
  printf '{"probe":{"PreInvocation":[{"type":"command","command":"/bin/true"}]}}' \
    > "$d/work/.agents/hooks.json"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 0 "the round still runs"
  assert_file_missing "$d/work/.agents/hooks.json" "and the repo's hook file is gone"
  assert_file_missing "$d/work/.agents" "the directory itself is gone too"
}

# A mode-555 directory is what a repo would ship to make the removal fail, and
# rm -rf cannot descend one. The chmod is what makes this pass; delete it and
# this case is the only thing that notices.
test_a_mode_555_agents_directory_is_still_removed() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  mkdir -p "$d/work/.agents/vendored"
  : > "$d/work/.agents/vendored/hooks.json"
  chmod 555 "$d/work/.agents/vendored"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  chmod -R 755 "$d/work/.agents" 2>/dev/null   # no-op if the removal worked
  assert_exit_code "$rc" 0 "the chmod -R makes it removable, so the round runs"
  assert_file_missing "$d/work/.agents" "and the whole directory is gone"
}

# `rsync -a` copies symlinks as symlinks, so `.agents` in the workdir can be a
# link the TARGET REPO chose the destination of. GNU `chmod -R` dereferences the
# symlink named on its command line, so an unguarded chmod here would add
# owner-write across whatever that link points at -- the operator's home, if the
# repo says so. Measured on the sibling path 2026-08-28: 444 came back 644, 555
# came back 755. This is the case that pins `[[ -L ... ]] ||`; without it the
# guard can be deleted and the suite still passes.
test_an_agents_symlink_is_unlinked_and_never_followed() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  if [[ "$(id -u)" == 0 ]]; then pr_test_skip "root ignores the write bit, so the damage is invisible"; return 0; fi
  mkdir -p "$d/work" "$d/victim"
  echo "the operator's file" > "$d/victim/f"
  chmod 444 "$d/victim/f"
  ln -s "$d/victim" "$d/work/.agents"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  rc=$?
  # -w rather than a mode read: it is the property the dereferencing chmod would
  # have changed, and it needs no GNU/BSD stat spelling.
  [[ -w "$d/victim/f" ]] && pr_fail "chmod followed the symlink and made the target writable"
  assert_file_exists "$d/victim/f" "the link target still exists"
  assert_eq "$(cat "$d/victim/f")" "the operator's file" "and is unchanged"
  assert_file_missing "$d/work/.agents" "while the link itself is gone"
  assert_exit_code "$rc" 0 "and the round still runs"
  chmod -R u+w "$d/victim" 2>/dev/null
}

# The post-check tests `-L` as well as `-e` because `-e` is FALSE for a dangling
# symlink -- so a `.agents` link whose target does not exist, and which the rm
# failed to unlink, would read as "successfully removed" on `-e` alone. An
# unwritable workdir is how the rm is made to fail; the repo cannot choose that
# directly, but the guard is not conditional on how the failure arose. Drop the
# `|| -L` and the adapter runs the review with that path still in place, which
# is exactly what this case catches.
test_a_dangling_agents_symlink_that_survives_is_refused() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"
  if [[ "$(id -u)" == 0 ]]; then pr_test_skip "root unlinks inside an unwritable directory anyway"; return 0; fi
  mkdir -p "$d/work"
  ln -s "$d/no-such-target" "$d/work/.agents"
  chmod 555 "$d/work"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" 2>&1)"
  rc=$?
  chmod 755 "$d/work" 2>/dev/null
  assert_exit_code "$rc" 1 "refuses rather than reviewing with the path in place"
  assert_contains "$out" "could not remove" "and says which path"
  assert_file_missing "$d/bin/agy-argv.txt" "the review never ran"
  [[ -L "$d/work/.agents" ]] || pr_fail "the dangling link was expected to survive the rm"
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

test_review_file_holds_the_result_lines_response_and_none_of_the_stream() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  echo "prompt" | PATH="$d/bin:$PATH" \
    bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/r.md")" "<!-- VERDICT: MINOR -->" "review extracted"
  assert_not_contains "$(cat "$d/r.md")" "conversation_id" "envelope stripped"
  assert_not_contains "$(cat "$d/r.md")" "step_update" "and the steps with it"
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
jq -nc '{event:"init",conversation_id:"conv-abc-123",init:{permission_mode:"always-proceed"}}'
jq -nc '{event:"step_update",step_update:{state:"DONE",step_type:"tool",tool_name:"run_command",tool_info:{name:"run_command",output:"/work\n"}}}'
jq -nc '{event:"result",result:{conversation_id:"conv-abc-123",status:"SUCCESS",response:"# r\n<!-- VERDICT: MINOR -->"}}'
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

# The counterpart of test-adapter-agent.sh's version case, and it is a separate
# copy for the usual reason: adapters are standalone, so the rule has to hold in
# each of them on its own. agy moved 1.1.16 -> 1.1.22 on the same day Cursor
# self-updated mid-round (2026-08-29), which is what took this out of the
# one-vendor-quirk category.
test_the_version_names_the_binary_that_ran_not_a_mid_round_upgrade() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  cat > "$d/bin/agy" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then
  if [[ -f "$d/ran" ]]; then echo "1.1.22"; else echo "1.1.16"; fi
  exit 0
fi
: > "$d/ran"
jq -nc '{event:"init",conversation_id:"conv-abc-123",init:{permission_mode:"always-proceed"}}'
jq -nc '{event:"step_update",step_update:{state:"DONE",step_type:"tool",tool_name:"run_command",tool_info:{name:"run_command",output:"/work\n"}}}'
jq -nc '{event:"result",result:{conversation_id:"conv-abc-123",status:"SUCCESS",response:"# r\n<!-- VERDICT: MINOR -->"}}'
exit 0
STUB
  chmod +x "$d/bin/agy"
  PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" "$d/work" "" "$d/r.md" "$d/m.txt" \
    < /dev/null > /dev/null 2>&1
  assert_eq "$(sed -n '4p' "$d/m.txt")" "1.1.16" \
    "line 4 names the binary that answered, not the one installed after it"
}

# Leg A of probes/2026-09-03-agy-stream-json/, verbatim with home paths redacted:
# the healthy stream at agy 1.1.24 — init reporting always-proceed, a run_command
# step ACTIVE then DONE, a result line carrying the answer. Checked in under
# tests/fixtures/ rather than read from the probe directory because docs/process/
# is a separate repo a fresh clone does not have.
test_leg_a_a_healthy_captured_stream_yields_a_review() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  install_leg_stub "$d/bin" "$PR_ROOT/tests/fixtures/agy/leg-a.ndjson"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/r.md")" "agy-stream-1788437827-12887" \
    "the result line's response is the review"
  assert_eq "$(sed -n '1p' "$d/m.txt")" "8dabbe79-785e-40b1-9f3f-526be0ade43f" \
    "and its conversation id is meta line 1"
  assert_file_missing "$d/reason.txt" "a healthy leg has nothing to explain"
}

# Leg B, verbatim: the shell tool starved the way the 2026-09-02 macOS profile
# starved it (an empty directory --ro-bind'ed over ~/.gemini/antigravity-cli/bin,
# where agy writes its agentapi), status SUCCESS, a CORRECT answer, and no
# command — agy fell back to view_file. This is the case that makes "count any
# tool step" wrong, and the one the assertion exists for.
test_leg_b_a_starved_shell_tool_fails_the_reviewer() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  install_leg_stub "$d/bin" "$PR_ROOT/tests/fixtures/agy/leg-b.ndjson"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "a review that ran nothing is refused"
  assert_file_missing "$d/r.md" "and no review is written"
  assert_contains "$out" "ran no command" "says what was wrong"
  assert_contains "$(cat "$d/reason.txt")" "agentapi" \
    "the reason names the first run_command failure, not just the count"
}

# The stream is the first agy output format that says whether
# --dangerously-skip-permissions took effect. A flag that was ACCEPTED is not a
# flag that took, and a mode that is neither ours nor an outright denial has no
# other signature.
test_a_permission_mode_we_did_not_ask_for_is_refused() {
  local d rc out; d="$(pr_test_tmpdir)"; mkdir -p "$d/work"
  install_stubs "$d/bin" SUCCESS "# r\n<!-- VERDICT: MINOR -->" "" default
  out="$(echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$out" "permission_mode=default" "quotes what it observed"
  assert_contains "$(cat "$d/reason.txt")" "not always-proceed" "and the runner is told why"
  assert_file_missing "$d/r.md" "the review is discarded, not recorded"
}

# An init line that never arrived is the same refusal, for adapters/claude.sh's
# reason: nothing downstream can tell a missing envelope from a review.
test_a_stream_with_no_init_line_is_refused() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  grep -v '"event":"init"' "$PR_ROOT/tests/fixtures/agy/leg-a.ndjson" > "$d/leg.ndjson"
  install_leg_stub "$d/bin" "$d/leg.ndjson"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "refused"
  assert_contains "$out" "permission_mode=MISSING" "names the absence rather than guessing"
  assert_file_missing "$d/r.md" "no review"
}

# A kill mid-write leaves half a line. `fromjson? // empty` on every line is what
# keeps that from reading as "no init line" or "ran nothing" — the same guard
# adapters/claude.sh states, for the same reason.
test_a_malformed_line_does_not_read_as_a_stream_with_nothing_in_it() {
  local d; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  { head -2 "$PR_ROOT/tests/fixtures/agy/leg-a.ndjson"
    printf '{"event":"step_update","step_upda\n'
    tail -n +3 "$PR_ROOT/tests/fixtures/agy/leg-a.ndjson"; } > "$d/leg.ndjson"
  install_leg_stub "$d/bin" "$d/leg.ndjson"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  assert_contains "$(cat "$d/r.md")" "agy-stream-1788437827-12887" \
    "the well-formed lines still read"
}

# A newline inside any scalar the single-pass jq emits would shift every field
# read after it. Measured 2026-09-09 on the unhardened filter: with `status`
# carrying an embedded newline the conversation id landed in `ran_ok`, the
# comparison against 0 failed, and this exact stream -- SUCCESS, a response, and
# not one run_command step -- was ACCEPTED. The `line` def and the digits check
# are what this pins; it is the malformed-FIELD case beside the malformed-LINE
# one, and a stream shape that moves must fail, never pass.
test_a_newline_inside_a_scalar_cannot_shift_the_ran_a_command_count() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  cat > "$d/leg.ndjson" <<'LEG'
{"event":"init","init":{"permission_mode":"always-proceed"}}
{"event":"result","result":{"status":"SUCCESS\nextra-line","conversation_id":"conv-123","response":"a review of nothing"}}
LEG
  install_leg_stub "$d/bin" "$d/leg.ndjson"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "no run_command step is no run_command step"
  assert_file_missing "$d/r.md" "and the review is discarded"
  assert_contains "$(cat "$d/reason.txt")" "ran no command" "with the honest reason"
}

# Under --output-format json the classifier's whole input WAS the response. Under
# stream-json stdout carries every tool_info.output too, so a reviewer that read
# a file mentioning an upgrade must not be reported as an exhausted account. The
# inputs are stderr and the result line, and nothing a tool printed.
test_a_quota_phrase_in_a_tool_output_is_not_read_as_an_exhausted_account() {
  local d rc; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  cat > "$d/leg.ndjson" <<'LEG'
{"event":"init","conversation_id":"conv-abc-123","init":{"permission_mode":"always-proceed"}}
{"event":"step_update","step_update":{"state":"DONE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","output":"NOTICE: please upgrade your subscription\n"}}}
{"event":"result","result":{"conversation_id":"conv-abc-123","status":"SUCCESS","response":""}}
LEG
  install_leg_stub "$d/bin" "$d/leg.ndjson"
  echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" > /dev/null 2>&1
  rc=$?
  assert_exit_code "$rc" 1 "an empty response is still a failure"
  assert_contains "$(cat "$d/reason.txt")" "auto-deny" "diagnosed as the auto-deny"
  assert_not_contains "$(cat "$d/reason.txt")" "quota" \
    "a tool's output is not the classifier's input"
}

# The other half of the same narrowing: agy's own refusal text on the result line
# still reaches the classifier, and still separates an exhausted account from an
# auto-deny.
test_a_quota_refusal_on_the_result_line_is_told_apart_from_the_auto_deny() {
  local d rc out; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  cat > "$d/leg.ndjson" <<'LEG'
{"event":"init","conversation_id":"conv-abc-123","init":{"permission_mode":"always-proceed"}}
{"event":"result","result":{"conversation_id":"conv-abc-123","status":"ERROR","error":"individual quota reached. Resets in 3h20m","response":""}}
LEG
  install_leg_stub "$d/bin" "$d/leg.ndjson"
  out="$(echo "prompt" | PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" 2>&1)"; rc=$?
  assert_exit_code "$rc" 1 "nothing was reviewed"
  assert_contains "$out" "Resets in 3h20m" "the window is surfaced"
  assert_contains "$(cat "$d/reason.txt")" "quota reached" "and the diagnosis is the account"
}

# The kernel's deadline sends TERM, and bash reaches the EXIT trap only after the
# foreground CLI has died (measured 2026-09-07, rc=143) — never the statement
# after the run. Until then the stderr replay lived there, so a timed-out round
# lost the CLI's own diagnostics. Both captures must survive, on the streams they
# came from.
#
# ONE TERM, delivered to the adapter's own process GROUP, and deliberately NOT
# through `timeout -s TERM`: measured 2026-09-09 on bash 5.2.37, a shell that
# takes a SECOND terminating signal while the first is still deferred dies from
# the default disposition and runs no EXIT trap at all -- 0/5 replays with two
# TERMs, 5/5 with one, whether the one goes to the group or to the shell alone.
# GNU `timeout` sends two (coreutils' cleanup() does `kill(child, sig)` and then
# `kill(0, sig)` over its own group, which the child is in), so a `timeout -s TERM
# 1` here would be measuring coreutils' signalling rather than this trap, and
# would pass or fail at random -- it failed 5/5 in this file. The group TERM is
# also what reaps the stub's `sleep`, so bash does not sit in `wait` for thirty
# seconds before reaching its trap.
#
# `set -m` is what gives the background adapter a group of its own, and stdin
# comes from a FILE rather than a pipeline because with job control on a
# pipeline's group leader is its FIRST process -- `kill -- -$!` would then
# address the wrong group. Costs ~0.1s: the handshake is the stub's marker file,
# the way pr_test_hold_lock's is, not a fixed sleep.
test_both_captures_are_replayed_when_the_deadline_kills_the_adapter() {
  local d log pid i; d="$(pr_test_tmpdir)"; install_stubs "$d/bin"; mkdir -p "$d/work"
  cat > "$d/bin/agy" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "--version" ]]; then echo "1.1.24"; exit 0; fi
cat > /dev/null
echo "MARKER-ON-STDOUT"
echo "MARKER-ON-STDERR" >&2
: > "$d/running"
sleep 30
STUB
  chmod +x "$d/bin/agy"
  echo "prompt" > "$d/stdin.txt"
  set -m
  PATH="$d/bin:$PATH" bash "$PR_ROOT/adapters/agy.sh" \
    "$d/work" "" "$d/r.md" "$d/m.txt" "$d/reason.txt" \
    < "$d/stdin.txt" > "$d/log" 2>&1 &
  pid=$!
  set +m
  for ((i = 0; i < 500; i++)); do
    [[ -e "$d/running" ]] && break
    sleep 0.02
  done
  kill -TERM -- "-$pid" 2> /dev/null
  wait "$pid" 2> /dev/null
  log="$(cat "$d/log")"
  assert_contains "$log" "MARKER-ON-STDOUT" "the stream capture reached the log"
  assert_contains "$log" "MARKER-ON-STDERR" "and so did the CLI's diagnostics"
}

pr_run_tests
pr_test_rc=$?
rm -rf "$HOME"
exit "$pr_test_rc"
