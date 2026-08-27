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
#   - claude has no OS write confinement of its own to ask for, so bubblewrap
#     supplies it and this script REFUSES TO RUN without bwrap.

set -uo pipefail

workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

# Optional; see docs/adapter-contract.md. One line, used by the runner as the
# round's `detail` for this reviewer.
reason_out="${5:-}"

pr_reason() {
  [[ -n "$reason_out" ]] || return 0
  printf '%s\n' "$1" > "$reason_out"
}

# Fail closed. An adapter that cannot confine writes must not run at all.
if ! command -v bwrap > /dev/null 2>&1; then
  echo "claude adapter: bwrap (bubblewrap) not found on PATH." >&2
  echo "Claude Code exposes no sandbox flag, so bubblewrap is this reviewer's only" >&2
  echo "write barrier. Refusing to run it unconfined." >&2
  exit 1
fi

# A private config directory, SIBLING to the repo copy rather than inside it:
# pr_sandbox_refresh wipes <sandbox>/repo every round, and the sessions that make
# round-to-round carry-forward possible live in here.
#
# Isolating it also keeps the real ~/.claude/settings.json out of the reviewer's
# reach. That file defines hooks which run in the operator's own interactive
# sessions, so a writable bind of ~/.claude would hand a reviewer a persistence
# channel that outlives the jail. The credentials file is bound in read-only and
# by path: it is never read by this script and never copied anywhere.
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

# The environment is rebuilt from nothing, not inherited. A Claude Code session
# exports eleven CLAUDE_* variables, and two classes of them are actively
# harmful to a nested reviewer: CLAUDE_EFFORT / CLAUDE_CODE_EFFORT_LEVEL could
# override the --effort this round asked for, which is the "round.json names a
# setting that never ran" failure R11 exists to prevent; and
# CLAUDE_CODE_MESSAGING_SOCKET / _TOKEN are a live channel back into the
# orchestrator session that no bwrap flag closes, because it travels in the
# environment rather than through the filesystem.
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
  TMPDIR="${TMPDIR:-$workdir/.pr-tmp}"
)

# stream-json rather than json, for the init line alone -- it is the only place
# an authoritative effective model appears. --verbose is what makes print mode
# emit the full stream.
args=(
  claude
  -p
  --safe-mode
  --dangerously-skip-permissions
  --output-format stream-json
  --verbose
)
[[ -n "${PR_CLAUDE_MODEL:-}" ]]  && args+=(--model "$PR_CLAUDE_MODEL")
[[ -n "${PR_CLAUDE_EFFORT:-}" ]] && args+=(--effort "$PR_CLAUDE_EFFORT")
[[ -n "$session_in" ]]           && args+=(--resume "$session_in")

stream="${TMPDIR:-/tmp}/pr-claude-stream.$$"
trap 'rm -f "$stream"' EXIT

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
"${jail[@]}" "${env_clean[@]}" "${args[@]}" > "$stream"
rc=$?

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

if [[ "$mode" != "bypassPermissions" ]]; then
  echo "claude adapter: permissionMode is '$mode', expected bypassPermissions." >&2
  echo "Tool calls would be auto-denied, and a reviewer that cannot run commands" >&2
  echo "cannot check the plan's claims. Refusing to record this as a review." >&2
  pr_reason "claude ran in permissionMode '$mode', not bypassPermissions"
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
  echo "claude adapter: $denials tool call(s) were denied despite" >&2
  echo "--dangerously-skip-permissions. The review may rest on unverified claims." >&2
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

printf '%s\n' "$review" > "$review_out"
exit 0
