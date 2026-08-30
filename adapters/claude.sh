#!/usr/bin/env bash
# Claude Code adapter. See docs/adapter-contract.md.
#
# This reviewer exists for rounds orchestrated from a harness that is NOT Claude
# Code. When the Integrator is a Claude Code session, putting this adapter in the
# roster is self-review: the integrator would be verifying its own reviewer's
# claims. It is deliberately absent from default_adapter_map() for that reason.
#
# Everything unusual below traces to a measurement in spike S2 (2026-08-17),
# against claude 2.1.233. --help was not trusted for any of it:
#   - -p reads the prompt from stdin, so the contract needs no argv workaround.
#   - the stream-json `init` line reports the RESOLVED model (--model sonnet ->
#     claude-sonnet-5), the permission mode, and the CLI version. The plain json
#     envelope does not: it has no model field, only a modelUsage MAP that also
#     contains auxiliary models, so there is nothing single-valued to read there.
#   - effort is reported NOWHERE, in either format. See line 3 below.
#   - the CLI respects the invocation cwd, so no --add-dir is needed.
#   - --safe-mode is load-bearing, not cosmetic: without it the TARGET REPO's
#     .claude/settings.json hooks execute inside the jail on every tool call.
#     Measured both ways -- the hook fired without the flag and did not fire with
#     it, so the negative result is a real one.
#
# CONFINEMENT IS PER-HOST, and that is the one structural thing to know before
# reading anything below. This adapter has two halves and picks between them
# ONCE, at $confinement, on `command -v bwrap`:
#
#   bwrap    bubblewrap supplies the write barrier, as it always has. The CLI
#            runs --dangerously-skip-permissions inside it and the init line
#            must report `bypassPermissions`. This is the Linux path, it is
#            unchanged, and it is the one the 2026-08-28 acceptance matrix
#            pinned.
#   builtin  Claude Code's OWN sandbox supplies it, through a settings file
#            carrying `failIfUnavailable: true`. No --dangerously-skip-permissions,
#            and the init line must report `default`.
#
# Neither half is an unconfined fallback and neither may become one: the builtin
# half is fail-closed on its own terms -- `failIfUnavailable: true` makes the CLI
# refuse to START when its sandbox is unavailable, which A7 measured on Linux
# with socat hidden from PATH (exit 1). What replaced the old `command -v bwrap ||
# exit 1` refusal is therefore a different fail-closed mechanism, not the absence
# of one. Read that sentence with its limit attached: the refuse-to-start path is
# measured on LINUX only. Seatbelt is a system facility with no removable
# dependency and nobody has yet made it unavailable to measure the macOS half
# (row 5, 2026-08-30; B2 before it).
#
# Why two halves rather than one (the decision, 2026-08-30, row 2 of
# HANDOFF-claude-macos.md; specs/claude-macos-rewire/NOTES.md specified ONE path
# and this overrules it, in writing): the one-path option rewrites the measured,
# pinned Linux path to gain symmetry on a platform that has none, and nothing on
# a Mac can re-run the twelve-row acceptance matrix that pins it. The contract
# already blesses larger drift than this -- docs/adapter-contract.md's containment
# clause says an adapter confines where the platform provides a mechanism, and
# codex, Cursor, agy and claude already confine four different ways. A branch
# inside one adapter is smaller drift than the drift between adapters.
#
# The cost of two halves is that they can drift, and it is bounded twice: the
# choice is ONE variable assembled here rather than a `command -v bwrap` repeated
# at each use, and pr_doctor_check_claude_confinement (lib/doctor.sh) reports
# which half a given host will take, using the same predicate.

set -uo pipefail

workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

# Optional; see docs/adapter-contract.md. One line, used by the runner as the
# round's `detail` for this reviewer.
reason_out="${5:-}"

pr_reason() {
  [[ -n "$reason_out" ]] || return 0
  printf '%s\n' "$1" > "$reason_out"
}

# The one predicate. Everything below reads $confinement; nothing re-derives it.
if command -v bwrap > /dev/null 2>&1; then
  confinement=bwrap
else
  confinement=builtin
fi

# A private config directory, SIBLING to the repo copy rather than inside it:
# pr_sandbox_refresh wipes <sandbox>/repo every round, and the sessions that make
# round-to-round carry-forward possible live in here.
#
# Isolating it also keeps the real ~/.claude/settings.json out of the reviewer's
# reach. That file defines hooks which run in the operator's own interactive
# sessions, so a writable bind of ~/.claude would hand a reviewer a persistence
# channel that outlives the jail.
cfg="$(dirname "$workdir")/config"
if ! mkdir -p "$cfg" 2>/dev/null; then
  echo "claude adapter: cannot create the private config dir at $cfg" >&2
  exit 1
fi
# ${HOME:-} rather than $HOME, here and in the whitelist below: set -u is on and
# PR_CACHE_ROOT lets the runner work in an environment with no HOME at all, where
# bare $HOME would take this reviewer out with a bash-internal "unbound variable"
# on a path that otherwise runs fine. No credentials file to bind is a state the
# [[ -f ]] below already handles. The reasoning is adapters/codex.sh:97's, at
# length; adapters source nothing, so the pointer is the cross-reference.
creds="${HOME:-}/.claude/.credentials.json"

jail=()
perm_args=()
settings_args=()
expect_mode=bypassPermissions
cli_tmpdir="${TMPDIR:-$workdir/.pr-tmp}"

if [[ "$confinement" == bwrap ]]; then
  # The credentials file is bound in read-only and by path: it is never read by
  # this script and never copied anywhere. The builtin half below cannot do that
  # -- there is no bind without bwrap -- and copies instead, which is the one
  # place the two halves differ in what they cost the operator.
  jail=(
    bwrap
    --ro-bind / /
    --dev /dev
    --proc /proc
    --tmpfs /tmp
    --bind "$workdir" "$workdir"
    --bind "$cfg" "$cfg"
  )
  [[ -f "$creds" ]] && jail+=(--ro-bind "$creds" "$cfg/.credentials.json")
  jail+=(
    --chdir "$workdir"
    --die-with-parent
    --unshare-uts
    --unshare-ipc
    # --unshare-pid is what makes --die-with-parent tree cleanup rather than
    # PDEATHSIG on the immediate command (measured 2026-08-27,
    # probes/2026-08-27-pid-namespace-adapters). Without it a grandchild
    # survives the jail and only the kernel's best-effort descendant sweep
    # stands between it and files the round has already read.
    --unshare-pid
  )
  perm_args=(--dangerously-skip-permissions)
else
  # ---------------------------------------------------------------- builtin ---
  # No bwrap on this host, so Claude Code's own sandbox is the write barrier.
  # Measured holding on Darwin through this exact shape on 2026-08-30 (row 1,
  # claude 2.1.251): a Bash tool call's writes to $HOME and to an absolute path
  # outside the workspace were both refused with `Operation not permitted`,
  # while the write inside the workspace succeeded.

  # CREDENTIALS. On Linux the file exists and is copied; on macOS it DOES NOT
  # EXIST -- the OAuth item lives in the login Keychain -- and without it the CLI
  # prints `Not logged in · Please run /login` and exits 1. This is the one
  # prerequisite the whole macOS path rests on and it is independent of
  # sandboxing.
  #
  # A COPY, not a bind: there is no bwrap here to bind with. That is a second
  # credential at rest, exactly as adapters/codex.sh's auth.json copy is, and it
  # is deleted with the sandbox. Do not undersell what it holds: the Keychain
  # item carries `organizationUuid` and a live `mcpOAuth` access token per
  # authenticated MCP server, not only the OAuth pair. Nothing closed is being
  # widened -- B1 measured Keychain reads as unconfined from inside the sandbox
  # anyway -- but the blob is broader than "the token".
  #
  # THE READ GETS ITS OWN SHORT TIMEOUT, and this is a requirement rather than a
  # nicety. D5 (2026-08-21) measured a LOCKED login keychain BLOCKING rather than
  # erroring: rc=124 under both a 5s and an 8s cap, with the password dialog
  # drawn by the read itself and the operator unable to answer it in time. A
  # blocked read is indistinguishable from a reviewer that is thinking, so
  # without a cap of its own it is charged to PR_TIMEOUT_SECS and surfaces as
  # "the reviewer timed out" -- a wrong diagnosis of a login problem. The
  # escalation is load-bearing for the same reason it is everywhere else in this
  # project: `timeout N` signals at N and then WAITS for its child.
  if [[ -f "$creds" ]]; then
    if ! cp "$creds" "$cfg/.credentials.json" 2>/dev/null; then
      echo "claude adapter: cannot copy $creds into $cfg" >&2
      pr_reason "claude credentials could not be copied into the private config dir"
      exit 1
    fi
  elif command -v security > /dev/null 2>&1; then
    if ! timeout --kill-after=1 5 \
         security find-generic-password -s "Claude Code-credentials" \
                  -a "${USER:-$(id -un)}" -w > "$cfg/.credentials.json" 2>/dev/null; then
      krc=$?
      if [[ "$krc" -eq 124 || "$krc" -eq 137 ]]; then
        echo "claude adapter: the login Keychain did not answer within 5s." >&2
        echo "A locked keychain BLOCKS this read rather than failing it, and draws a" >&2
        echo "dialog nobody is watching. Unlock it and re-run." >&2
        pr_reason "the login Keychain did not answer within 5s; unlock it and re-run"
      else
        echo "claude adapter: could not read 'Claude Code-credentials' from the" >&2
        echo "login Keychain (exit $krc). Run 'claude auth login' as this user." >&2
        pr_reason "could not read claude's credentials from the login Keychain (exit $krc)"
      fi
      exit 1
    fi
  else
    echo "claude adapter: no credentials to give the reviewer." >&2
    echo "$creds does not exist and there is no security(1) to read a Keychain" >&2
    echo "item with. Run 'claude auth login' as this user." >&2
    pr_reason "claude has no credentials this adapter can materialise"
    exit 1
  fi
  chmod 600 "$cfg/.credentials.json" 2>/dev/null

  # SYNTHESIZED, not copied from ~/.claude.json. Claude Code refuses to run
  # headless in a config dir that has not completed onboarding, and this is the
  # smallest file that satisfies it (measured 2026-08-30, row 3 bench). Copying
  # the operator's own would hand the reviewer their MCP server list, their
  # project trust records and their history -- the same class of thing the
  # private config dir exists to keep out of reach, and the bwrap half does not
  # hand any of it over. Only written when absent, so a carried-forward config
  # dir keeps whatever the CLI has since written there.
  [[ -f "$cfg/.claude.json" ]] || printf '{"hasCompletedOnboarding":true}\n' > "$cfg/.claude.json"

  # C1/C5: Claude Code's sandbox puts its bridge sockets under $TMPDIR and a unix
  # socket path caps at 108 bytes. lib/reviewer-runner.sh hands the kernel
  # pr_sandbox_tmp, and pr_plan_slug flattens the WHOLE repo-relative plan path
  # into the session key, so the ceiling is breached by how deep the plan is
  # filed -- `PLAN.md` at the root cleared it by 8 bytes and `docs/plans/feat.md`
  # failed, end to end, silently: exit 0, a valid session id and model, and a
  # non-empty "review" that was the model explaining it could not run commands.
  #
  # The fix is an adapter-owned short $TMPDIR, and the assertion below is on the
  # SHORT PATH'S OWN LENGTH -- not on 73 and not on 86. Both of those are
  # properties of socket names we do not control (`claude-http-<16 hex>.sock` on
  # Linux, `srt-mux-<pid>-0.sock` under Seatbelt) and they differ by platform.
  # 22 bytes here against a 108-byte ceiling is 86 of headroom, which is the
  # claim worth pinning.
  cli_tmpdir="/tmp/pr-claude-$(printf '%08x' "$((RANDOM * 32768 + RANDOM))")"
  if (( ${#cli_tmpdir} > 32 )); then
    echo "claude adapter: the private TMPDIR grew to ${#cli_tmpdir} bytes ($cli_tmpdir)." >&2
    echo "It exists to stay far below the 108-byte unix socket ceiling; something" >&2
    echo "changed its shape. Refusing rather than failing silently mid-review." >&2
    pr_reason "claude's private TMPDIR is ${#cli_tmpdir} bytes; it must stay short"
    exit 1
  fi
  if ! mkdir -m 700 -p "$cli_tmpdir" 2>/dev/null; then
    echo "claude adapter: cannot create the private TMPDIR at $cli_tmpdir" >&2
    pr_reason "claude's private TMPDIR could not be created"
    exit 1
  fi
  trap 'rm -rf "$cli_tmpdir"' EXIT

  # THE SANDBOX, declared. `failIfUnavailable` is not optional: the fail-open
  # default was OBSERVED on Linux -- "Sandbox disabled ... Commands will run
  # WITHOUT sandboxing" with socat missing -- and the init frame carries no
  # sandbox field to assert against instead (A2), so this file is the only place
  # the requirement can be stated.
  #
  # allowWrite is the workdir ALONE, deliberately narrower than the bwrap half,
  # which binds $cfg writable too. Nothing the reviewer runs needs to write the
  # config dir, and the credentials copy lives there.
  #
  # excludedCommands is empty because B3 measured the holes a plan reviewer needs
  # at zero. An excluded command runs OUTSIDE the sandbox, which is the same
  # trap adapters/agent.sh's empty Cursor allowlist exists for.
  settings="$cfg/pr-sandbox-settings.json"
  cat > "$settings" <<JSON || { echo "claude adapter: cannot write $settings" >&2; exit 1; }
{ "sandbox": { "enabled": true, "failIfUnavailable": true,
    "allowUnsandboxedCommands": false, "excludedCommands": [],
    "filesystem": { "allowWrite": ["$workdir"] } } }
JSON
  settings_args=(--settings "$settings")

  # THE REPOSITORY UNDER REVIEW REOPENS THIS SANDBOX FROM THE OTHER SIDE, and
  # `--settings` does not outrank it. Measured 2026-08-30 (row 3 bench, claude
  # 2.1.251) with our settings file exactly as written above -- sandbox enabled,
  # failIfUnavailable true, allowUnsandboxedCommands false, allowWrite the
  # workdir alone -- against a repo shipping `.claude/settings.json` that carried
  # `sandbox.enabled: false`, `allowUnsandboxedCommands: true`,
  # `excludedCommands: ["sh"]` and `filesystem.allowWrite: ["$HOME"]` at once:
  # a Bash tool call wrote `$HOME/pr-repo-bash-<nonce>.txt`, `is_error: false`,
  # and the file landed on the host. `--safe-mode` did not stop it; that flag
  # stops repo HOOKS executing, which is a different surface and was measured
  # separately (S2).
  #
  # So the repo copy's `.claude` goes, unconditionally, before the CLI is
  # invoked -- exactly what adapters/agent.sh does to `.cursor` and for exactly
  # the reason it does it. Nothing is written back in its place.
  #
  # Two limits, stated rather than glossed. The probe fired all four keys at
  # once and did NOT separate which one did the work, because the remedy is the
  # same for all four. And it did not fire `.claude/settings.local.json` or a
  # repo-root `.mcp.json` -- the second of which would spawn an unsandboxed
  # process if it were ever honoured without approval; removing the directory
  # takes the settings file that could set `enableAllProjectMcpServers` with it,
  # but `.mcp.json` itself is UNMEASURED and is parked in BACKLOG.md.
  #
  # The repo's `permissions.allow: ["Write"]` was refused in the same run, so
  # that surface at least is closed -- see the Write/Edit note below.
  #
  # Only the builtin half does this. Under bwrap the jail is the write barrier
  # and no settings file the repo ships can widen it, so removing the directory
  # there would change the measured Linux path to buy nothing.
  rm -rf "$workdir/.claude"

  # WRITE AND EDIT STAY DENIED, AND THAT IS THE POINT. Measured 2026-08-30 (row
  # 3 bench): Claude Code's built-in sandbox confines BASH TOOL CALLS ONLY. The
  # CLI's own Write tool is not sandboxed by it -- with `permissions.allow:
  # ["Write"]` added to the settings above, a Write to `$HOME` outside
  # `filesystem.allowWrite` SUCCEEDED and the file landed on the host. Under
  # bwrap that cannot happen, because the jail contains the whole process rather
  # than the commands it spawns; the two mechanisms are NOT equivalent and
  # specs/claude-macos-rewire/NOTES.md's "enforces the same write barrier bwrap
  # gives us" is wrong in exactly this way.
  #
  # `permissionMode: default` is therefore load-bearing rather than incidental:
  # it is the only thing keeping the unsandboxed Write and Edit tools inside the
  # workspace, by denying them outright in a headless run nothing can approve.
  # NEVER add Write or Edit to a `permissions.allow` here. The reviewer keeps its
  # write capability through Bash, which the sandbox does contain.
  #
  # The visible cost: a reviewer that reaches for Write gets one entry in
  # `permission_denials` and the round carries the "tool call(s) denied" reason.
  # That is honest -- it did lose a tool -- and lib/prompt.sh tells reviewers
  # where they may write for the same reason.
  # --dangerously-skip-permissions is NOT passed. It is the reason Write and Edit
  # were unbound in Phase B -- our invocation, not the CLI -- and without it
  # autoAllowBashIfSandboxed runs Bash unprompted BECAUSE the sandbox contains
  # it, which is the whole mechanism this half rests on. Measured 2026-08-30:
  # permissionMode `default`, five tool calls, none prompted, none denied.
  expect_mode=default
fi

# The environment is rebuilt from nothing, not inherited. A Claude Code session
# exports eleven CLAUDE_* variables, and two classes of them are actively
# harmful to a nested reviewer: CLAUDE_EFFORT / CLAUDE_CODE_EFFORT_LEVEL could
# override the --effort this round asked for, which is the "round.json names a
# setting that never ran" failure R11 exists to prevent; and
# CLAUDE_CODE_MESSAGING_SOCKET / _TOKEN are a live channel back into the
# orchestrator session that no bwrap flag closes, because it travels in the
# environment rather than through the filesystem. That last reason is why the
# whitelist is NOT relaxed on the builtin half, which has no bwrap at all: the
# scrub was never bwrap's work.
#
# This is the exact whitelist S2 ran under. Nothing is added to it on the theory
# that it might be needed -- an untested variable here is an untested jail.
env_clean=(
  env -i
  HOME="${HOME:-}"
  PATH="$PATH"
  TERM="${TERM:-dumb}"
  LANG="${LANG:-C.UTF-8}"
  SHELL="${SHELL:-/bin/bash}"
  CLAUDE_CONFIG_DIR="$cfg"
  TMPDIR="$cli_tmpdir"
)

# stream-json rather than json, for the init line alone -- it is the only place
# an authoritative effective model appears. --verbose is what makes print mode
# emit the full stream.
args=(
  claude
  -p
  --safe-mode
  "${perm_args[@]}"
  --output-format stream-json
  --verbose
  "${settings_args[@]}"
)
[[ -n "${PR_CLAUDE_MODEL:-}" ]]  && args+=(--model "$PR_CLAUDE_MODEL")
[[ -n "${PR_CLAUDE_EFFORT:-}" ]] && args+=(--effort "$PR_CLAUDE_EFFORT")
[[ -n "$session_in" ]]           && args+=(--resume "$session_in")

# Where the stream lands, and its cleanup, differ by half -- deliberately, and
# the bwrap line is the one that shipped, unchanged.
#
# On the bwrap half: ${TMPDIR:-/tmp}, exactly as before, with its own EXIT trap.
# Siting it under $cli_tmpdir instead would have been a silent behaviour change
# on the measured path -- with TMPDIR unset that variable is $workdir/.pr-tmp,
# which is INSIDE the repo copy, so the reviewer's own tool calls could read or
# rewrite the stream this adapter is about to parse for the model, the version
# and the review.
#
# On the builtin half: inside the private $cli_tmpdir, whose trap was armed at
# creation and removes the whole directory -- so the stream goes with it and a
# second trap would only fight the first. Armed there rather than here because
# the settings write between the two can exit.
if [[ "$confinement" == builtin ]]; then
  stream="$cli_tmpdir/pr-claude-stream.$$"
else
  stream="${TMPDIR:-/tmp}/pr-claude-stream.$$"
  trap 'rm -f "$stream"' EXIT
fi

# stderr is NOT redirected: it is inherited, so it lands on this adapter's own
# stderr, which the execution kernel points at <round>/log-claude.txt
# (lib/adapter-exec.sh runs every adapter as `>> "$log" 2>&1`). This is the only
# durable record of WHY a claude round failed -- bwrap refusing to start, an
# authentication failure -- and until now it went to `"${review_out}.log"`, which
# on the round path is <round>/.review-claude.scratch.log, a dotfile nothing
# names. The tripwire below tells the operator the envelope moved; this is what
# tells them what actually happened. Same shape as codex.sh's `cat "$err" >&2`,
# which is why log-codex.txt has always been the useful one.
#
# What must stay separated is stderr from STDOUT, not stderr from this script's
# stderr: stdout is the stream-json that jq parses below. `> "$stream" 2>&1`
# would interleave non-JSON error text into it, jq stops at the first parse
# error, the init line then reads as absent, and every such run would exit 1
# claiming "the envelope has changed" -- misdiagnosing the very failure this
# stderr exists to explain. Verified 2026-08-27. Deleting the redirect is the
# fix; duplicating fd 2 onto fd 1 is its opposite.
# tee, not a redirect: stdout flows on to the kernel's `>> log-claude.txt 2>&1`
# (lib/adapter-exec.sh), which is what makes the stream durable -- $stream dies
# with this process's EXIT trap (its own on the bwrap half, the private TMPDIR's
# on the other), and before this change log-claude.txt carried
# stderr only, so a failed round's stream-json was deleted with the evidence.
# Accepted cost (decision 5, brainstorm 2026-08-27-backlog-clearing-3): the log
# interleaves stream-json with stderr -- and the volume is the half the first
# draft of this comment left out. What lands in log-claude.txt is the WHOLE
# stream, every tool call and the full review text, on every round, where before
# the tee that file carried stderr alone. That is the point (a failed round's
# stream is now recoverable) and the cost (nothing prefixes either writer, so a
# reader cannot attribute a line -- BACKLOG.md carries that as a watch item).
# jq below still reads $stream, the FILE --
# never the pipe. PIPESTATUS[0], because $? is now tee's exit, and rc must keep
# meaning what the messages below say it means.
#
# On the builtin half, `cd` rather than bwrap's --chdir: nothing else puts the
# CLI in the workdir there, and S2 measured that claude respects the invocation
# cwd. A subshell, so this script's own cwd is untouched.
(
  [[ "$confinement" == builtin ]] && { cd "$workdir" || exit 1; }
  "${jail[@]}" "${env_clean[@]}" "${args[@]}"
) | tee "$stream"
rc=${PIPESTATUS[0]}

# The init line is this adapter's version tripwire, the way the banner is
# codex.sh's. Its absence means the stream format moved under us, and every
# field below would silently read as empty -- a review recorded against an
# unknown model on an unknown CLI. Refuse rather than record fiction.
init="$(jq -c 'select(.type == "system" and .subtype == "init")' "$stream" 2>/dev/null | head -1)"
if [[ -z "$init" ]]; then
  echo "claude adapter: no stream-json init line (exit $rc)." >&2
  echo "The --output-format stream-json envelope has changed, or the CLI never" >&2
  echo "started. Re-run the S2 probes and update docs/verified-versions.txt." >&2
  pr_reason "claude produced no stream-json init line; the envelope has moved"
  exit 1
fi

# Three fields off one line: a jq per field was three processes to re-parse a
# single object already sitting in a variable.
{ IFS= read -r mode; IFS= read -r model_init; IFS= read -r version; } < <(
  jq -r '(.permissionMode // ""), (.model // ""), (.claude_code_version // "")' \
     <<< "$init" 2>/dev/null)
: "${mode:=}" "${model_init:=}" "${version:=}"

# The expected mode is the confinement half's, not a constant. Under bwrap the
# CLI is told to skip permissions and must report bypassPermissions; under the
# builtin sandbox it is not, and must report `default` -- which is what
# autoAllowBashIfSandboxed runs under, and what attempt 2's init frame already
# reported with Bash running unprompted. Either way the check is the same one:
# a mode this adapter did not ask for means tool calls behave differently from
# what the round assumes, and a reviewer that cannot run commands cannot check
# the plan's claims.
if [[ "$mode" != "$expect_mode" ]]; then
  echo "claude adapter: permissionMode is '$mode', expected $expect_mode" >&2
  echo "(confinement: $confinement). Tool calls would behave differently from" >&2
  echo "what this round assumes. Refusing to record this as a review." >&2
  pr_reason "claude ran in permissionMode '$mode', not $expect_mode"
  exit 1
fi

result="$(jq -c 'select(.type == "result")' "$stream" 2>/dev/null | tail -1)"
# Everything the result line carries, in one pass. `.result` is the whole review
# and comes last, so the scalars can be read line by line and the review is
# whatever remains. The trailing $(...) strips the final newline exactly as the
# per-field command substitutions did.
#
# is_error is NOT `.is_error // true`: in jq, `//` treats false as empty, so that
# expression reports every successful run as an error. Spelled out, it still
# defaults to true when the field is missing entirely, which is the fail-closed
# direction.
#
# terminal_reason is one more scalar in the same expression, no extra process. It
# goes BEFORE .result, which stays last because it is multi-line and read with
# `cat`. `// ""` is what makes an absent field read as "not reported" rather than
# shifting every later line -- the same failure mode the tab-separated record had
# in libexec/plan-review-round.sh.
{ IFS= read -r is_error; IFS= read -r session; IFS= read -r denials
  IFS= read -r subtype;  IFS= read -r terminal_reason; review="$(cat)"; } < <(
  jq -r '(if .is_error == false then "false" else "true" end),
         (.session_id // ""),
         ((.permission_denials // []) | length | tostring),
         (.subtype // ""),
         (.terminal_reason // ""),
         (.result // "")' <<< "$result" 2>/dev/null)
: "${is_error:=true}" "${session:=}" "${denials:=}" "${subtype:=}" "${terminal_reason:=}"

# The pin is a request; the init line is the answer. They differ legitimately
# when the pin is an alias -- `sonnet` resolves to `claude-sonnet-5` -- which is
# why this is a containment test and not equality, and why a mismatch is recorded
# rather than fatal. The annotation format matches adapters/agent.sh, so
# round.json reads the same whichever CLI swapped a model out.
model_effective="$model_init"
if [[ -n "${PR_CLAUDE_MODEL:-}" && "$model_init" != *"$PR_CLAUDE_MODEL"* ]]; then
  model_effective="$model_init (requested: $PR_CLAUDE_MODEL)"
  echo "claude adapter: asked for '$PR_CLAUDE_MODEL' but the session reports" >&2
  echo "'$model_init'. Recording what answered." >&2
fi

# Line 3 is empty because the effective effort is UNKNOWABLE here, which is not
# the same reason Cursor and agy leave it empty. They fold effort into the model
# id, so line 2 carries it. Claude Code has --effort as a genuine separate axis
# and then reports it in neither output format, so a round run at max effort and
# one run at low are indistinguishable in round.json. PR_CLAUDE_EFFORT is passed
# through, but nothing here can confirm it took.
printf '%s\n%s\n%s\n%s\n' \
  "$session" \
  "$model_effective" \
  "" \
  "$version" \
  > "$meta_out"

if [[ "$denials" != "0" && -n "$denials" ]]; then
  echo "claude adapter: $denials tool call(s) were denied." >&2
  echo "The review may rest on unverified claims." >&2
  # Worth surfacing even when the round is otherwise ok: a review written by a
  # reviewer that could not run its tools is a weaker review, and nothing else
  # in round.json says so. Overwritten below if the round also failed.
  pr_reason "$denials tool call(s) denied; the review may rest on unverified claims"
fi

# Judge the envelope, not the exit code: an unrecognised --model exits 1 with a
# well-formed result line, and is_error is what distinguishes that from a review.
if [[ "$is_error" == "true" || -z "$review" ]]; then
  echo "claude adapter: no usable review (is_error=$is_error, exit=$rc)." >&2
  [[ -n "${review:-$subtype}" ]] && printf '%s\n' "${review:-$subtype}" >&2
  # claude names why the session ended, and that value is REPORTED rather than
  # matched against a list. Measured against claude 2.1.235 in probe P4
  # (process note 2026-08-19, "claude terminal_reason"): the field is on
  # every result frame -- `completed` on a clean success, `budget_exhausted` when
  # a spend cap binds. The surveyed Go orchestrator special-cases the single value
  # `prompt_too_long` for a filled context window; P4 did NOT reproduce that value,
  # both legs having hit the budget cap first, so a branch on the literal string
  # would be a citation standing in for a measurement.
  # Echoing the field diagnoses prompt_too_long too, if that is ever what arrives.
  #
  # No tripwire on the field: if a release stops emitting it, `// ""` above makes
  # this fall back to the generic message and nothing else changes.
  #
  # The message must NOT suggest --fresh: a failed reviewer already forfeits its
  # own handle in libexec/plan-review-round.sh, while --fresh would discard every
  # reviewer's handle and the history baseline. Nor does it state that rule --
  # R1 is the runner's, an adapter that asserts it becomes a lie if it changes.
  #
  # One line, not a branch: `${var:+...}` drops the clause when the field is
  # absent, which is the same "absent reads as not reported" the `// ""` gives.
  pr_reason "claude reported is_error=$is_error${terminal_reason:+, terminal_reason=$terminal_reason} and no review (exit $rc)"
  exit 1
fi

# ---------------------------------------------------------------------------
# "The reviewer ran at least one command successfully."
#
# Everything above this line can be satisfied by a review that ran NOTHING, and
# there are FOUR measured routes to exactly that -- a confident, empty,
# is_error:false round with a real session id and model:
#
#   C1  the $TMPDIR socket ceiling: exit 0, is_error false, and a "review" that
#       is the model explaining it could not run commands. `[[ -s ]]` passes.
#   C3  failIfUnavailable starts, denies every Bash call, and exits 0.
#   C6  (Linux) a command writing outside the writable set gets `This command
#       requires approval`, which headless cannot grant; it never runs and the
#       round still exits 0.
#   D3  (macOS) the same hazard in a different shape -- the command RUNS and the
#       kernel denies the write: `Operation not permitted`, exit 1,
#       permission_denials: [], subtype success, is_error false,
#       terminal_reason completed. The tool layer allowed it and Seatbelt
#       stopped it, so nothing above notices.
#
# Three of the four are Linux's, which is why this is asserted on BOTH halves and
# not only the builtin one. The stream-json tool calls are what make it
# checkable: a Bash tool_use whose matching tool_result is not an error.
#
# The cost, stated rather than glossed: a review that legitimately needed no
# command now FAILS its reviewer. That is deliberate. lib/prompt.sh tells every
# reviewer to run things, and a confident review that checked nothing is the
# failure this whole adapter's tripwires exist to refuse -- worse than a missing
# review, because round.json records it as ok.
#
# `.is_error != true` rather than `.is_error == false`: a successful tool_result
# omits the field entirely, and null != true.
# jq -Rn with `fromjson? // empty` rather than a plain read of $stream: one
# malformed line must not abort the count and read as "ran nothing".
# ---------------------------------------------------------------------------
# One jq, two answers: the count, and -- when the count is zero -- the first
# failing tool_result's text. The count alone says a round is untrustworthy
# without saying why, and the four routes are diagnosed by four different
# strings the CLI already puts in that field: `This command requires approval`
# (C6), the model's own explanation (C1), and on 2026-08-30 a Darwin
# measurement worth the extra line -- `sandbox-exec: sandbox_apply: Operation
# not permitted`, exit 71, which is Claude Code's sandbox being UNAVAILABLE
# while `failIfUnavailable: true` fails to refuse. Without the excerpt that
# reads as "the reviewer was lazy" rather than "this host cannot sandbox it".
{ IFS= read -r ran_ok; first_fail="$(cat)"; } < <(jq -Rrn '
  [inputs | fromjson? // empty] as $s
  | ([ $s[] | select(.type == "assistant") | .message.content[]?
       | select(.type == "tool_use" and .name == "Bash") | .id ]) as $ids
  | ([ $s[] | select(.type == "user") | .message.content[]?
       | select(.type == "tool_result")
       | select(.tool_use_id as $i | $ids | index($i)) ]) as $res
  | ([ $res[] | select(.is_error != true) ] | length | tostring),
    ([ $res[] | select(.is_error == true) | (.content | tostring) ][0] // "")' \
  < "$stream" 2>/dev/null)
: "${ran_ok:=0}" "${first_fail:=}"
if [[ "$ran_ok" == 0 ]]; then
  echo "claude adapter: the reviewer ran no command successfully." >&2
  echo "Every Bash tool call was denied, refused approval, or never issued, so" >&2
  echo "this review rests on reading alone. Confinement: $confinement." >&2
  [[ -n "$first_fail" ]] && printf 'First failing tool result: %s\n' "${first_fail:0:400}" >&2
  # Truncated hard: this is round.json's one-line `detail`, and a tool_result
  # can be a whole build log. Newlines out for the same reason -- the runner
  # reads one line (docs/adapter-contract.md).
  fail_line="${first_fail//$'\n'/ }"
  pr_reason "claude ran no command successfully; the review rests on reading alone${fail_line:+ (first failure: ${fail_line:0:160})}"
  exit 1
fi

printf '%s\n' "$review" > "$review_out"
exit 0
