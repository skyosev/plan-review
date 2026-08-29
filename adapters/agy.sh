#!/usr/bin/env bash
# Antigravity (agy) adapter. See docs/adapter-contract.md.
#
# This is the one adapter whose CLI provides no usable confinement. Everything
# unusual below traces to a measurement in Task 0 / spike S1:
#   - agy's --sandbox allowed a write to /tmp while logging itself as enabled,
#     so bubblewrap supplies the write barrier and this script REFUSES TO RUN
#     without it. Running agy unconfined is the failure D11 exists to prevent.
#   - agy ignores the invocation cwd (it runs in ~/.gemini/.../scratch), so the
#     workdir must be named explicitly with --add-dir.
#   - headless tool calls are auto-denied without --dangerously-skip-permissions,
#     and a denied run still exits 0 with an empty response.
#   - -p/--print takes the prompt as its VALUE; agy never reads stdin.
#   - --model and --effort are mutually exclusive; the id carries the tier.

set -uo pipefail

workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

# Optional fifth argument: a file this adapter writes ONE line to when it knows
# why the round went the way it did. The runner uses it as `detail` in
# round.json. Absent -- a hand-run invocation, or any caller that still passes
# four arguments -- means the runner's generic message. See
# docs/adapter-contract.md.
reason_out="${5:-}"

pr_reason() {
  [[ -n "$reason_out" ]] || return 0
  printf '%s\n' "$1" > "$reason_out"
}

# Linux caps a single argv entry at PAGE_SIZE*32. codex and Cursor dodge this by
# taking the prompt on stdin; agy cannot, so the cap is enforced here.
PR_MAX_ARG_BYTES=131072

# Restated here, not sourced: adapters are standalone by contract and can be run
# by hand under the four-argument contract, where nothing has vetted the
# environment. libexec/plan-review-round.sh enforces the same shape for the
# runner path -- deliberately in two places, like PR_MAX_ARG_BYTES above.
PR_TIMEOUT_SECS="${PR_TIMEOUT_SECS:-900}"
if [[ ! "$PR_TIMEOUT_SECS" =~ ^[1-9][0-9]*$ ]]; then
  echo "agy adapter: PR_TIMEOUT_SECS must be a positive whole number, got: $PR_TIMEOUT_SECS" >&2
  exit 1
fi

PR_AGY_MODEL="${PR_AGY_MODEL:-}"
if [[ -z "$PR_AGY_MODEL" ]]; then
  echo "agy adapter: PR_AGY_MODEL must name a model (agy models)" >&2
  echo "The id includes the effort tier, e.g. gemini-3.1-pro-high" >&2
  exit 1
fi

# Fail closed. An adapter that cannot confine writes must not run at all.
if ! command -v bwrap > /dev/null 2>&1; then
  echo "agy adapter: bwrap (bubblewrap) not found on PATH." >&2
  echo "agy's own --sandbox does not confine writes, so bubblewrap is the only" >&2
  echo "write barrier this reviewer has. Refusing to run it unconfined." >&2
  exit 1
fi

prompt="$(cat)"

# ${#prompt} counts CHARACTERS under a UTF-8 locale, and MAX_ARG_STRLEN is a
# BYTE limit. Measured on 2026-08-17 under C.UTF-8: this repo's own spec is
# 162686 bytes but 162402 characters, so a prompt sitting just under the cap in
# characters can still come back from execve as a bare E2BIG. Assigning LC_ALL
# in a subshell re-runs setlocale, which is what makes ${#} count bytes; the
# subshell keeps the C locale from reaching anything else.
prompt_bytes="$( LC_ALL=C; printf '%s' "${#prompt}" )"
if (( prompt_bytes >= PR_MAX_ARG_BYTES )); then
  echo "agy adapter: prompt is $prompt_bytes bytes; the argv limit is $PR_MAX_ARG_BYTES." >&2
  echo "agy cannot read a prompt from stdin, so there is no fallback path here." >&2
  echo "Shorten the plan, or drop agy from this round's roster." >&2
  pr_reason "agy: prompt is $prompt_bytes bytes, over the $PR_MAX_ARG_BYTES argv cap"
  exit 1
fi

# A private state directory, SIBLING to the repo copy rather than inside it:
# pr_sandbox_refresh wipes <sandbox>/repo every round, and the conversations
# that make round-to-round resume possible live in here. It is bound OVER
# ~/.gemini so agy still finds its state at the path it expects.
#
# Isolating it also keeps the operator's real ~/.gemini out of the reviewer's
# reach. agy honours workspace hooks under .agents/, so a hostile workspace
# can make the reviewer write into its state directory -- and a read-write
# bind of the real one would hand that write a persistence channel that
# outlives the jail, running later in the operator's own sessions. Same
# argument, same shape, as adapters/claude.sh's private CLAUDE_CONFIG_DIR;
# adapters source nothing, so the reasoning is restated here by convention.
# What is lost is agy history from OTHER sessions, which nothing here ever
# relied on: resume is per-session by design and the session map carries the
# handles. Auth material is ro-bound in by path below, never copied.
state="$(dirname "$workdir")/gemini-state"
if ! mkdir -p "$state" 2>/dev/null; then
  echo "agy adapter: cannot create the private state dir at $state" >&2
  exit 1
fi

# The bind DESTINATION has to exist on the host as well. bwrap creates a missing
# destination by mkdir'ing it, and under `--ro-bind / /` it cannot: on a host
# with no ~/.gemini the jail refuses to start with
#
#     bwrap: Can't mkdir /home/<user>/.gemini: Read-only file system
#
# and an rc=1 that produced no output lands in the empty-response branch at the
# bottom of this file, which then tells the operator to check tool permissions
# -- the wrong cause, on every round, for as long as the directory is absent.
# Reproduced against bubblewrap 0.9.0, 2026-08-27. Nothing upstream catches it:
# pr_doctor_check_bwrap_jail and pr_doctor_preflight both bind a directory under
# $TMPDIR that they `mkdir -p` first, so their mountpoint always exists and they
# pass on exactly the host this fails on.
#
# Creating it is the whole fix: an empty ~/.gemini is what agy itself would
# leave on a first run, and the jail overmounts it, so nothing of the
# operator's is touched. Checked by hand like the state dir above -- there is
# no set -e here -- and fatal, because the jail would refuse to start anyway.
# ${HOME:-} in the TEST rather than $HOME for the reason adapters/codex.sh:97
# states at length: set -u is on, and PR_CACHE_ROOT makes a round with no HOME
# reachable. Past this guard the bare form is correct and used: an empty HOME
# has already exited, and `:-` there would quietly resolve a later slip to
# "/.gemini" instead of failing.
# But unlike codex, agy cannot DEGRADE to a round without one: an unset HOME
# would resolve every path here to "/", and "/.gemini" is a real destination --
# mkdir fails for an ordinary user, and for root it would create a directory at
# the filesystem root. So an absent HOME is refused outright rather than
# resolved. Nothing is lost by refusing: the auth file the loop below needs is
# looked up under the same HOME, so that round could not have authenticated.
if [[ -z "${HOME:-}" ]] || ! mkdir -p "$HOME/.gemini" 2>/dev/null; then
  echo "agy adapter: cannot create the bind destination ${HOME:-<HOME is unset>}/.gemini" >&2
  echo "agy's private state is bound over ~/.gemini, and bwrap cannot mkdir that" >&2
  echo "destination itself under --ro-bind / /. Refusing to run agy without it." >&2
  exit 1
fi

# The jail: everything read-only, the disposable repo copy read-write, a private
# /tmp so a stray absolute write lands nowhere real, and the private state
# directory above mounted where agy expects to find ~/.gemini, so conversations
# and logs still persist across rounds.
# --die-with-parent matters because the runner kills the process group on timeout.
#
# --unshare-pid is what makes --die-with-parent tree cleanup instead of
# PDEATHSIG on the immediate command: measured 2026-08-27 with this exact flag
# shape, a detached `setsid sleep` survived bwrap's exit without it and was
# contained with it (probes/2026-08-27-pid-namespace-adapters).
jail=(
  bwrap
  --ro-bind / /
  --dev /dev
  --proc /proc
  --tmpfs /tmp
  --bind "$workdir" "$workdir"
  --bind "$state" "$HOME/.gemini"
  --die-with-parent
  --unshare-uts
  --unshare-ipc
  --unshare-pid
)
# The minimal auth material, measured in leg 3 of the probe above: the one file
# the CLI needs to authenticate, bound read-only and by path over the private
# dir. It is the probe's output, not a guess -- and the guess would have been
# wrong. Starting from an empty private dir, agy answered "authentication
# required" with nothing bound AND with the obvious-looking oauth_creds.json
# bound; it authenticated on the nested antigravity-cli token alone. Re-run leg
# 3 before changing this path, or before adding a second one beside it.
creds="$HOME/.gemini/antigravity-cli/antigravity-oauth-token"
[[ -f "$creds" ]] && jail+=(--ro-bind "$creds" "$creds")

# --sandbox is passed for defence in depth, not because it works: Task 0 measured
# it as inert here. If a future release makes it real, this costs nothing.
args=(
  agy
  --sandbox
  --dangerously-skip-permissions
  --add-dir "$workdir"
  --model "$PR_AGY_MODEL"
  --output-format json
  # agy's own deadline, derived from the runner's and always strictly inside it.
  # Left unset it defaults to 5m0s -- a third of PR_TIMEOUT_SECS -- and cuts a
  # long review short. Measured against agy 1.1.15 in probe P1
  # (process note 2026-08-19, "agy print-timeout and invalid-model"): the expiry comes back
  # as exit 1 with .status ERROR and .error "timeout waiting for response", which
  # is what the classifier below recognises. The surveyed Go orchestrator is where
  # the question came from, not the evidence -- its own note says the expiry exits
  # 0, which is text mode, not the json mode we run in.
  #
  # Milliseconds, not seconds: integer seconds collapse to equality at
  # PR_TIMEOUT_SECS=1, which is a supported value, and if the two deadlines
  # coincide timeout(1) can reap agy before it writes its final line -- trading
  # a diagnosable exit for a SIGKILL. The 10% margin is what it costs. P1b
  # confirmed the ms unit is accepted at 810000ms.
  --print-timeout "$((PR_TIMEOUT_SECS * 900))ms"
)
[[ -n "$session_in" ]] && args+=(--conversation "$session_in")
args+=(-p "$prompt")

# Both streams are captured to FILES, never through a pipe. A CLI descendant
# that inherits stdout keeps the pipe open past the CLI's own exit, so
# `out="$(...)"` would block on a finished review until the runner's deadline
# fired -- a completed round reported as a timeout. Measured in production by
# claude-octopus (scripts/lib/heartbeat.sh:256, their issue #892); codex.sh and
# claude.sh already capture this way, and this was the last pipe in the roster.
out_file="${TMPDIR:-/tmp}/pr-agy-out.$$"
err_file="${TMPDIR:-/tmp}/pr-agy-err.$$"
trap 'rm -f "$out_file" "$err_file"' EXIT

# The CLI version is read BEFORE the review run, not after it. Cursor and agy
# both self-update in place, and on 2026-08-29 one did it MID-ROUND: the `agent`
# process that produced round 1's review carried 2026.08.11-e8db854 in its argv,
# 2026.08.25-3e8eec8 was installed while the round ran, and the post-run
# `--version` put the binary that had NOT written the review into round.json
# (docs/process/probes/2026-08-29-macos-row3-sweep/). No review is wrong when
# that happens; what breaks, silently and unfalsifiably after the fact, is every
# "measured at version X" claim -- including the drift warning in
# docs/verified-versions.txt. adapters/codex.sh and adapters/claude.sh are immune
# because they take the version off the run's OWN output (the banner and the init
# frame); agy's JSON envelope carries no such field, so reading it while the binary
# about to answer is still the one on disk is the nearest equivalent. It narrows
# the window from the whole review to the gap between two adjacent commands; it
# does not close it, and nothing here detects the remainder.
version="$(agy --version 2>/dev/null | head -1 | tr -d '[:space:]')"

"${jail[@]}" "${args[@]}" > "$out_file" 2> "$err_file"
rc=$?
cat "$err_file" >&2

# Exit code is not a success signal: a permission-denied run exits 0 with an
# empty response. Judge on the envelope instead.
# One pass over the envelope: `response` is the whole review, so parsing the file
# once per field read it three times over. The two scalars come out first, on
# their own lines; the response is taken separately because it is multi-line.
{ IFS= read -r status; IFS= read -r session; } < <(
  jq -r '(.status // "MISSING"), (.conversation_id // "")' < "$out_file" 2>/dev/null)
: "${status:=MISSING}"
response="$(jq -r '.response // ""' < "$out_file" 2>/dev/null)"

printf '%s\n%s\n%s\n%s\n' \
  "$session" \
  "$PR_AGY_MODEL" \
  "" \
  "$version" \
  > "$meta_out"

if [[ -z "$response" ]]; then
  # Classification runs ONLY here, after parsing has established there is no
  # response. A false positive can therefore change the diagnosis and nothing
  # else: no match can turn a substantive review into a failure, because a
  # substantive review never reaches this branch.
  #
  # The strings are claude-octopus's, measured by them against a different agy
  # version and a different invocation shape -- their `--print` text mode, not
  # our --output-format json (scripts/helpers/agy-exec.sh:235). Unverified here,
  # which is why the fallback below is the generic message rather than a guess;
  # the provenance is in the process notes (2026-08-17, borrowing from
  # claude-octopus).
  # Fixed-string matching, deliberately: their equivalent was a regex and they
  # got it wrong twice in production (their issues #516 and #536).
  if grep -qF -e 'individual quota reached' -e 'quota reached.' \
               -e 'upgrade your subscription' "$out_file" "$err_file" 2>/dev/null; then
    window="$(grep -ohE 'Resets in [0-9]+h[0-9]+m' "$out_file" "$err_file" 2>/dev/null | head -1)"
    echo "agy adapter: the account's quota is exhausted, so nothing was reviewed." >&2
    [[ -n "$window" ]] && echo "agy said: $window" >&2
    echo "This is account-wide, not per-model: rerunning now will fail the same way." >&2
    pr_reason "agy: account quota reached${window:+ (${window,})}"
  else
    echo "agy adapter: empty response (status=$status, exit=$rc)." >&2
    echo "This is the auto-deny signature; check that tool permissions were skipped." >&2
    pr_reason "agy: empty response (status=$status, exit=$rc), the auto-deny signature"
  fi
  exit 1
fi

printf '%s\n' "$response" > "$review_out"
exit 0
