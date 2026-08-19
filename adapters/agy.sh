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

# The jail: everything read-only, the disposable repo copy read-write, a private
# /tmp so a stray absolute write lands nowhere real, and agy's own state
# directory writable so conversations and logs still persist across rounds.
# --die-with-parent matters because the runner kills the process group on timeout.
jail=(
  bwrap
  --ro-bind / /
  --dev /dev
  --proc /proc
  --tmpfs /tmp
  --bind "$workdir" "$workdir"
  --die-with-parent
  --unshare-uts
  --unshare-ipc
)
[[ -d "$HOME/.gemini" ]] && jail+=(--bind "$HOME/.gemini" "$HOME/.gemini")

# --sandbox is passed for defence in depth, not because it works: Task 0 measured
# it as inert here. If a future release makes it real, this costs nothing.
args=(
  agy
  --sandbox
  --dangerously-skip-permissions
  --add-dir "$workdir"
  --model "$PR_AGY_MODEL"
  --output-format json
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
  "$(agy --version 2>/dev/null | head -1 | tr -d '[:space:]')" \
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
