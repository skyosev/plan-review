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
#   - -p/--print takes the prompt as its VALUE. --input-format stream-json DOES
#     read a prompt from stdin at 1.1.24, so "agy never reads stdin" -- what this
#     line said until 2026-09-07 -- was false. What stays true is that the route
#     is no FALLBACK: somewhere between 16145 and 24145 bytes on the wire it
#     drops the prompt SILENTLY -- status SUCCESS, num_turns 1, empty response,
#     usage all zeros, nothing in either stream, in the CLI's log/ or in the
#     brain store -- which is the same signature this adapter reports as the
#     auto-deny, so a plan routed there would be diagnosed as a permissions
#     problem (probes/2026-09-03-agy-stream-json/, legs C-K). The 64 KiB
#     bufio.Scanner default was the obvious explanation and the legs disprove it.
#     So the prompt goes in argv and the cap below is enforced here.
#   - --model and --effort are mutually exclusive; the id carries the tier.
#   - --output-format stream-json carries what json does not: an `init` line with
#     permission_mode, and one step_update per step transition with tool_name and
#     tool_info. Both assertions at the bottom of this file rest on that, and the
#     stream's `result` line is the envelope in shape, so the three fields this
#     adapter always parsed survive as a filter on one line.

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
# taking the prompt on stdin; agy's stdin route drops a prompt of this size
# without saying so (header above), so the cap is enforced here.
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
  echo "agy's --input-format stream-json route does read stdin, but drops prompts" >&2
  echo "far below this size silently, so there is no fallback path here." >&2
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
# reach. agy was measured EXECUTING workspace hooks under .agents/
# (probes/2026-09-01-agy-hook-surface/, leg A, agy 1.1.22, Linux) -- the remedy
# for THAT half is the removal below, and leg B measured the same execution out
# of ~/.gemini/config/hooks.json, so a read-write bind of the real directory is
# arbitrary code execution on every LATER agy round of the operator's own,
# outliving the jail. The channel is that hook route, not a reviewer write: leg
# C asked the reviewer to create ~/.gemini/config/hooks.json with a shell
# command and the file never appeared. WHAT refused it is NOT established --
# the quotes naming agy's own terminal sandbox were read live from a state
# directory that no longer exists, so that attribution is a hypothesis worth
# testing, not a measured property of 1.1.22. What IS auditable in the probe's
# raw/ is the negative: bwrap did not deny it. The jail bound that directory
# read-WRITE on purpose and the leg's own listing shows the CLI process
# creating four entries inside it in the same run. DENIED there is "this route
# was refused", not "the directory is unreachable": one command, one shape, one
# model, one platform, and no control run.
# The bind therefore stays private on leg B's evidence rather than on C's. Same
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

# The repository under review ships .agents/, and agy reads hooks from there --
# MEASURED, not inferred: probes/2026-09-01-agy-hook-surface/ leg A seeded
# $work/.agents/hooks.json with a PreInvocation command and agy EXECUTED it, in
# this adapter's own invocation shape (--sandbox --dangerously-skip-permissions
# -p), with no prompting and no trace whatsoever on the --output-format json
# transcript -- the evidence is a marker file on the host and the CLI's own log
# (agy 1.1.22, Linux, 2026-09-01). Removed rather than sanitised because the
# measurement is narrower than the surface: .agents/ also carries custom agents
# and other workspace customisation that no leg touched. adapters/agent.sh:400
# does the identical thing to .cursor, and adapters/claude.sh:366 to .claude --
# that one on its BUILT-IN half only, since the bwrap half contains the process
# instead. This is the third copy of one rule, not a new idea. Adapters source nothing, so it
# is restated here by convention.
#
# Safe because <workdir> is a disposable per-round copy, never the operator's
# checkout (lib/sandbox.sh; docs/adapter-contract.md says the same).
#
# chmod first, and CHECKED after, for adapters/agent.sh's measured reasons:
# `rsync -a` preserves the target's permissions and `rm -rf` cannot descend a
# mode-555 directory (lib/sandbox.sh:67), which vendored dependencies really do
# ship -- so a repo wanting its hooks to survive need only ship one mode 555
# inside .agents. The `[[ -e ]]` is the evidence, not rm's exit status.
#
# The -L branch is not tidiness. GNU `chmod -R` DEREFERENCES the symlink named on
# its command line, and `rsync -a` copies symlinks as symlinks, so a target repo
# shipping `.agents -> /home/<operator>` would arrive here as exactly that and an
# unguarded chmod would add owner-write across the operator's home (measured
# 2026-08-28 on the sibling path). Unlinking a symlink IS the clean outcome: what
# the CLI would have read is gone from the workdir either way. `-L` is tested
# again below because `-e` is false for a DANGLING symlink.
[[ -L "$workdir/.agents" ]] || chmod -R u+w "$workdir/.agents" 2>/dev/null
rm -rf "$workdir/.agents"
if [[ -e "$workdir/.agents" || -L "$workdir/.agents" ]]; then
  echo "agy adapter: could not remove $workdir/.agents" >&2
  echo "That path can supply hooks and agent definitions agy may execute, so the" >&2
  echo "review is refused rather than run with it in place." >&2
  pr_reason "The target repo's .agents path could not be removed; refusing to run with it in place"
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
  # stream-json, not json. The `result` line at the end of the stream is the
  # envelope this adapter parsed until 2026-09-07 -- same three fields, same
  # names -- and what the stream ADDS is the `init` line's permission_mode and
  # one step_update per step transition. Both assertions at the bottom of this
  # file exist only because of that, and neither costs an extra call: same run,
  # more lines. pr_doctor_check_agy_help_flags asserts the mode is still offered,
  # matching on the --output-format LINE because --input-format and --json-schema
  # name stream-json too.
  --output-format stream-json
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
# Both captures are replayed at exit, exactly once each, on the streams they came
# from: stdout to stdout, stderr to stderr. The adapter's own stdout and stderr
# are log-<reviewer>.txt (docs/adapter-contract.md), so this is what puts the
# stream -- every step, every tool_info.output -- where a failed assertion can be
# read back.
#
# In the EXIT trap rather than on the line after the run, because that line is not
# always reached: on the runner's deadline the execution kernel sends TERM, and
# bash runs the EXIT trap once the foreground CLI has died (measured 2026-09-07,
# rc=143) while the next statement never runs. Until 2026-09-07 the stderr replay
# lived there, so a timed-out agy round dropped the CLI's own diagnostics.
#
# What this does NOT buy, stated rather than implied: the log fills at exit, so
# there is no live stream to watch during a stall, and a SIGKILL before or during
# the replay loses some or all of the capture. An EXIT trap cannot do better than
# either -- a stronger guarantee needs a different owner for the durable capture,
# and nothing here builds one. NOT `tee`, and deliberately not claude.sh's shape:
# this adapter removed its last pipe after the measured hang above, and
# tests/test-adapter-agy.sh pins that a descendant holding stdout cannot block it.
pr_replay_and_clean() {
  cat "$out_file"
  cat "$err_file" >&2
  rm -f "$out_file" "$err_file"
}
trap pr_replay_and_clean EXIT

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

# Exit code is not a success signal: a permission-denied run exits 0 with an
# empty response. Judge on the stream instead.
#
# ONE pass, six answers. Every line is selected by its `event` field and never by
# position -- agy emits one step_update per step TRANSITION and the count is not
# fixed. `fromjson? // empty` on every line for adapters/claude.sh's measured
# reason: one malformed or truncated line (a kill mid-write) must not abort the
# read and come back as "no init line" or "ran nothing".
#
# `response` is LAST because it is the only multi-line value: the five scalars
# come off `read -r` in order and the rest of the pipe is the review. Which makes
# the FRAMING load-bearing, and it is enforced rather than assumed: every scalar
# goes through `line`, which squashes newlines, because ONE embedded newline
# above shifts every field after it. Measured 2026-09-09 against this exact
# filter, with a result line carrying `status: "SUCCESS\nextra-line"`: the
# conversation id landed in `ran_ok`, `[[ "$ran_ok" == 0 ]]` was false, and a
# reviewer that ran nothing walked past the ran-a-command assertion. `tojson` on
# the result object escapes newlines by construction; `line` on it is the belt to
# that brace.
{ IFS= read -r perm; IFS= read -r status; IFS= read -r session
  IFS= read -r ran_ok; IFS= read -r first_fail; IFS= read -r result_json
  response="$(cat)"; } < <(jq -Rrn '
  def line: tostring | gsub("[\r\n]+"; " ");
  [inputs | fromjson? // empty] as $s
  | ([ $s[] | select(.event == "init")   | .init.permission_mode   // empty ][0] // "MISSING" | line),
    ([ $s[] | select(.event == "result") | .result.status          // empty ][0] // "MISSING" | line),
    ([ $s[] | select(.event == "result") | .result.conversation_id // empty ][0] // ""        | line),
    ([ $s[] | select(.event == "step_update") | .step_update
       | select(.step_type == "tool" and .tool_name == "run_command"
                and .state == "DONE") ] | length | tostring),
    ([ $s[] | select(.event == "step_update") | .step_update
       | select(.step_type == "tool" and .tool_name == "run_command"
                and .state == "ERROR")
       | .tool_info.error.message // empty ][0] // "" | line),
    ([ $s[] | select(.event == "result") | .result | tojson ][0] // "" | line),
    ([ $s[] | select(.event == "result") | .result.response // empty ][0] // "")' \
  < "$out_file" 2>/dev/null)
: "${perm:=MISSING}" "${status:=MISSING}" "${ran_ok:=0}" "${first_fail:=}" "${result_json:=}"
# A count is digits, or the framing moved under us. Either way the round is not
# trustworthy, and reading a shifted field as "commands ran" is the one failure
# this block exists to prevent.
[[ "$ran_ok" =~ ^[0-9]+$ ]] || ran_ok=0

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
  # INPUTS NARROWED 2026-09-07, and the narrowing is the point. This used to grep
  # the whole of $out_file, which under --output-format json WAS the response and
  # nothing else. Under stream-json stdout also carries every tool_info.output, so
  # a reviewer that ran `cat build.log` on a file saying "upgrade your
  # subscription" and then hit a truncated stream would be reported as an
  # exhausted account. The inputs are therefore stderr -- where octopus measured
  # the refusal -- and the result line, which is where agy's own status and error
  # text land. Nothing a tool printed is read.
  if { cat "$err_file"; printf '%s\n' "$result_json"; } \
       | grep -qF -e 'individual quota reached' -e 'quota reached.' \
                  -e 'upgrade your subscription' 2>/dev/null; then
    window="$( { cat "$err_file"; printf '%s\n' "$result_json"; } \
      | grep -ohE 'Resets in [0-9]+h[0-9]+m' 2>/dev/null | head -1)"
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

# ---------------------------------------------------------------------------
# "The run had the permission mode we asked for."
#
# --dangerously-skip-permissions is passed above because headless tool calls are
# auto-denied without it, and a denied run still exits 0 with an empty response --
# which the branch above catches. What had no signature at all until the stream is
# a mode that is neither what we asked for NOR an outright denial: the json
# envelope carries no such field, which is why docs/feature-matrix.md recorded agy
# as having nowhere to assert one. Same move as adapters/claude.sh's
# permissionMode check on its init line, for the same reason: a flag that was
# accepted is not a flag that took effect.
#
# MISSING covers an init line that never arrived -- a stream cut short before its
# first line, or a format change -- and is a failure on claude's grounds: nothing
# downstream can tell that from a review.
if [[ "$perm" != "always-proceed" ]]; then
  echo "agy adapter: the stream's init line reports permission_mode=$perm." >&2
  echo "This adapter passes --dangerously-skip-permissions and requires" >&2
  echo "always-proceed; a review produced under anything else is discarded." >&2
  pr_reason "agy reported permission_mode=$perm, not always-proceed; the review was discarded"
  exit 1
fi

# ---------------------------------------------------------------------------
# "The reviewer ran at least one command."
#
# Everything above this line can be satisfied by a review that ran NOTHING;
# adapters/claude.sh's comment lists four measured routes to exactly that. agy had
# no counterpart, and docs/feature-matrix.md called that a structural gap on the
# strength of §2's `absent` for per-tool-call visibility. It was the FORMAT's
# limit, not the CLI's: under stream-json every step transition is a line,
# failures included.
#
# The check names the tool -- `run_command`, exactly as claude's names `Bash` --
# and counting ANY tool step would be wrong, measured: leg B of
# probes/2026-09-03-agy-stream-json/ starved the shell tool the way the 2026-09-02
# macOS profile did, and agy fell back to `view_file`, read the canary and
# answered correctly under status SUCCESS with num_turns 1. Both legs are pinned
# offline as tests/fixtures/agy/leg-{a,b}.ndjson.
#
# What DONE proves, stated narrowly: the shell layer launched a command and the
# step finished. A DONE step carries tool_info.output and NO exit status, so this
# is "a command executed" rather than the contract's "at least one command
# succeeded" -- docs/adapter-contract.md carries the exception by name. It rules
# out every route where nothing ran, which is the failure the clause exists for;
# it does not rule out a command that ran while something else denied its write.
# That gap is deliberate: a command that ran and exited non-zero has proved the
# reviewer's shell works, and refusing such a review would fail a healthy round to
# satisfy a word. Nothing here claims anything about what claude's tool_result
# check admits -- the D3 record's is_error: false is the RESULT FRAME, not the
# tool_result adapters/claude.sh reads, and that object has never been captured.
# No text heuristic on tool_info.output either: a parser that decided "succeeded"
# by reading a command's output would be a guess dressed as a check.
#
# The cost, stated rather than glossed: a review that legitimately needed no
# command now FAILS its reviewer, as it does for claude. lib/prompt.sh
# tells every reviewer to run things, and a confident review that checked nothing
# is worse than a missing one, because round.json records it as ok. A successful
# `pwd` satisfies both adapters, which is why lib/doctor.sh's smoke ping asks for
# one.
if [[ "$ran_ok" == 0 ]]; then
  echo "agy adapter: the reviewer ran no command." >&2
  echo "No run_command step reached DONE, so this review rests on reading alone." >&2
  [[ -n "$first_fail" ]] && printf 'First run_command error: %s\n' "${first_fail:0:400}" >&2
  # Truncated hard, and already newline-free from the jq above: this is
  # round.json's one-line `detail` (docs/adapter-contract.md), and a tool error
  # can be a whole build log.
  pr_reason "agy ran no command; the review rests on reading alone${first_fail:+ (first failure: ${first_fail:0:160})}"
  exit 1
fi

printf '%s\n' "$response" > "$review_out"
exit 0
