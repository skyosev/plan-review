#!/usr/bin/env bash
# Cursor adapter. See docs/adapter-contract.md.
#
# --sandbox enabled gives write confinement AND network. Cursor's sandbox is
# default-deny with a host allowlist (github, the package registries, cloud
# storage), not network-off; an early probe against a host outside that
# allowlist was misread as the sandbox blocking all traffic. Verified against
# 2026.08.11-e8db854: github.com 200, api.github.com 200, write inside the
# workdir OK, write outside denied with no file created.
#
# That last clause read "NO LONGER TRUE at 2026.08.25-3e8eec8" here until
# 2026-08-28, when the probe that was supposed to confirm the regression found
# a configuration one instead (docs/process/probes/2026-08-28-cursor-containment,
# same binary, 2026.08.25-3e8eec8, unchanged by `agent update`):
#
#   ~/.cursor/cli-config.json      flags                     $HOME canary  CURSOR_SANDBOX
#   approvalMode "unrestricted"    --sandbox enabled --trust ON THE HOST    unset
#   approvalMode "auto-review"     --sandbox enabled --trust absent         native
#   a fresh, empty config dir      --sandbox enabled --trust absent         native
#
# `approvalMode: "unrestricted"` -- Run Everything, which the docs' own mode
# table gives as "Sandbox: No" -- makes `--sandbox enabled` INERT: the tool call
# runs with CURSOR_SANDBOX unset and the write to $HOME lands on the host. It is
# a *user-level* setting, so the reviewer inherits whatever the operator last
# clicked, and this host had clicked it. `--sandbox enabled` does still override
# `sandbox.mode: "disabled"` in the same file (measured separately), so the flag
# is not broken; only Run Everything outranks it.
#
# So the 2026-08-27 finding was real and its cause was not. `--trust` was named
# as the obvious suspect there and is innocent: every confining run below passes
# it. The fix is to stop reading the operator's config at all -- see
# CURSOR_CONFIG_DIR below -- and with that the header's original claim holds
# again at the current version.
#
# Cursor exits 2 when a tool call is denied while still producing a correct
# review, so the adapter normalises that to 0 when output exists.

set -uo pipefail

workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

# Optional; see docs/adapter-contract.md. One line, used by the runner as the
# round's `detail` for this reviewer.
reason_out="${5:-}"

pr_reason() {
  [[ -n "$reason_out" ]] || return 0
  printf '%s\n' "$1" > "$reason_out"
}

# Cursor reports no effective model anywhere in --output-format text, so the
# requested pin is the only answer available. An *empty* pin is therefore not a
# weaker answer, it is no answer: round.json could not say which model reviewed
# the plan, which is exactly what R11 needs. Demand a concrete value instead of
# recording a blank.
#
# There is no separate effort setting here. Cursor encodes effort in the model id
# itself -- `claude-opus-5-low`, `claude-opus-5-medium`,
# `claude-opus-5-thinking-high`, `gpt-5.6-sol-xhigh`, plus `-fast` variants -- so
# the pin already names both. `agent --list-models` is the authority on which
# combinations exist; they are not uniform across models. (`--help` also documents
# a bracket form, `claude-opus-4-8[context=1m,effort=high]`, which is untested
# here; prefer the plain ids that --list-models prints.)
PR_AGENT_MODEL="${PR_AGENT_MODEL:-}"
if [[ -z "$PR_AGENT_MODEL" ]]; then
  echo "agent adapter: PR_AGENT_MODEL must name a model (agent --list-models)" >&2
  echo "The id includes the effort tier, e.g. claude-opus-5-thinking-high" >&2
  exit 1
fi

# Guard before the two paths below are composed. An empty or missing <workdir>
# would make them "/.cursor" and "./cursor-config" -- one an `rm -rf` aimed at
# the root of the filesystem, the other a private config directory dropped in
# whatever the current directory happens to be. `cd "$workdir" || exit 1` used
# to be the check that caught a bad workdir, and it no longer runs first.
# lib/sandbox.sh refuses an empty directory for the same reason.
[[ -d "$workdir" ]] || {
  echo "agent adapter: no such workdir: $workdir" >&2
  pr_reason "The review workdir does not exist; nothing was run"
  exit 1
}

# The write barrier, in two parts. Both are about *whose* configuration Cursor
# reads: the sandbox itself works, and every measured escape came from a policy
# file written by somebody the reviewer should not be taking orders from.
#
# Part one -- the operator's. A private config directory, sited beside the repo
# copy like codex's CODEX_HOME and claude's CLAUDE_CONFIG_DIR, so it survives
# pr_sandbox_refresh's per-round wipe of <sandbox>/repo: Cursor keeps its chats
# there, and `--resume` needs them. Unlike those two it costs no credential
# dance -- `agent status` in an EMPTY CURSOR_CONFIG_DIR still reports the
# operator logged in (measured 2026-08-28), so the auth material lives outside
# the directory entirely and nothing has to be copied or bound in. Isolating it
# is therefore free, and it buys the same thing it buys for claude and codex:
# the operator's own ~/.cursor -- hooks.json, plugins/, rules/, skills-cursor/,
# and the approvalMode that made --sandbox enabled inert above -- is out of the
# reviewer's reach.
#
# What this costs in transition rounds is UNKNOWN, and the attempt to measure it
# is worth recording because it failed in an instructive way. BACKLOG.md
# pre-registered the price of moving a CLI's state home, and codex really paid
# it: a handle minted before the move names a rollout file the new home does not
# have, and the first resume fails with `no rollout found for thread id`. The
# obvious analogue was tried here on 2026-08-28 -- a chat id minted under the
# operator's ~/.cursor, resumed under an empty private directory -- and it came
# back rc=0 with a normal answer. That looked like "no cost". Then the negative
# control was run: `--resume` with a UUID that had NEVER been a chat id also
# comes back rc=0 with a normal answer. So rc=0 distinguishes nothing, and no
# claim can be made in either direction from it.
#
# Whether `--resume` attaches to a prior conversation at all in `-p` mode WAS the
# open question here, and it is now SETTLED, in the affirmative
# (docs/process/probes/2026-08-28-acceptance-matrix/, 2026-08-28). Two rounds
# through this adapter: round 2 reproduced a token round 1 had been told to hold
# and not to write down -- a token absent from round 1's published review and
# from round 2's prompt, so the chat carried it and the prompt did not.
#
# The probe that settled it needed a discriminator that is not rc, which is the
# whole reason the earlier reading failed. Asked an OPEN question about an
# earlier turn, a resumed chat disclaims knowledge of it -- identically from the
# directory that minted it and from a foreign one, which is what made that
# reading look like "the handle carries nothing". A disclaimer is a behaviour,
# not an absence of state, and a nonce it was told to hold beats it.
#
# What is still unmeasured is the TRANSITION only: a handle minted under the
# operator's ~/.cursor and resumed under this private directory. Every round the
# runner starts mints and resumes inside CURSOR_CONFIG_DIR, so that case is the
# migration and nothing else.
cursor_config="$(dirname "$workdir")/cursor-config"
if ! mkdir -p "$cursor_config" 2>/dev/null; then
  echo "agent adapter: cannot create $cursor_config" >&2
  pr_reason "Could not create Cursor's private config directory; refusing to run unconfined"
  exit 1
fi
export CURSOR_CONFIG_DIR="$cursor_config"

# Pin the settings the measurement turned on rather than inheriting a fresh
# install's defaults. They happen to agree today -- a fresh directory comes up
# `allowlist` with the sandbox off, and `--sandbox enabled` supplies the rest,
# measured confining -- but "the default is safe" is a claim about a version,
# and this is the one setting that decides whether the barrier exists at all.
#
# The allowlist is EMPTY on purpose, and that is the counter-intuitive half: an
# allowlisted command is exempted FROM the sandbox, not merely from the prompt.
# Leg 3b measured exactly that -- allowlisting `Shell(sh)` took CURSOR_SANDBOX
# from `native` to unset and put the $HOME canary on the host. Every entry here
# would be a hole; a reviewer needs none.
#
# Rewritten every round, not seeded once: the file is CLI-managed and the CLI
# rewrites it, so a one-shot seed would be a pin that drifts. This write is
# checked because an unchecked one fails silently into exactly the unconfined
# state the whole change exists to close. Even the failure mode is bounded --
# the CLI backs a malformed config up as .bad and recreates it from defaults,
# which are `allowlist` too.
#
# Only fields the probe actually exercised are written. `sandbox.networkAccess`
# was in the first draft of this line, copied out of the fresh install's own
# file; it appears in none of the four vendor pages the probe fetched and in no
# transcript, so it is gone. In a file whose whole job is pinning what was
# measured, an unmeasured field is the one thing that must not be in it. The
# CLI self-repairs whatever it needs.
if ! printf '%s\n' \
  '{"version":1,"approvalMode":"allowlist","permissions":{"allow":[],"deny":[]},"sandbox":{"mode":"enabled"}}' \
  > "$cursor_config/cli-config.json"; then
  echo "agent adapter: cannot write $cursor_config/cli-config.json" >&2
  pr_reason "Could not pin Cursor's approval mode; refusing to run unconfined"
  exit 1
fi

# Part two -- the target repo's. Deleted, not merged. Same probe, and two of the
# three surfaces escaped:
#
#   <repo>/.cursor/sandbox.json  {"type": "insecure_none"}                  ignored
#   <repo>/.cursor/sandbox.json  additionalReadwritePaths: ["<the $HOME>"]  CANARY ON THE HOST
#   <repo>/.cursor/cli.json      permissions.allow: ["Shell(sh)", ...]      CANARY ON THE HOST
#
# The path grant is the documented union merge working exactly as documented and
# against us: the sandbox still reported itself `native`/`fully_enforced` while
# writing into the operator's home. The cli.json allowlist did not widen the
# jail, it switched it off. Only the blunt `insecure_none` was refused -- which
# is the least useful of the three to an attacker, and refusing one of three is
# not a boundary.
#
# Directory replacement rather than per-file surgery: it closes cli.json,
# permissions.json (the Auto-review policy file), rules/, skills/, commands/ and
# whatever policy file the next CLI version puts there, by construction and with
# no per-file probe to keep current. Nothing is written back in its place, which
# is where this departs from the plan that asked for it: `type` from a per-repo
# sandbox.json was measured INERT in *both* directions -- `insecure_none` and
# `workspace_readonly` were each ignored -- so a replacement file would be a
# policy that demonstrably decides nothing. The deletion is the whole counter.
#
# Accepted cost, and it cuts both ways: a repo's legitimate deny rules and extra
# read paths go too. An untrusted target gets no say either way. What this does
# NOT reach is the repo-root surfaces that live outside .cursor/ -- .cursorignore
# can still hide files from the reviewer, and AGENTS.md is still read; neither
# was measured widening the sandbox, and hiding a file from a reviewer is a
# weaker attack than writing to the operator's home.
#
# Safe because <workdir> is a disposable per-round copy, never the operator's
# checkout (lib/sandbox.sh; docs/adapter-contract.md says the same).
#
# chmod first, and CHECKED after, for the same reason its two siblings above are
# checked: this is the half that closes the two measured escapes, and a silent
# failure here leaves cli.json in place and runs the review anyway. The failure
# is not hypothetical -- lib/sandbox.sh:70 records it: `rsync -a` preserves the
# target's permissions and `rm -rf` cannot descend a mode-555 directory, which
# vendored dependencies really do ship. A repo that wanted its policy to survive
# would only have to ship one mode 555 inside `.cursor`. The `[[ -e ]]` is the
# evidence, not rm's exit status: what matters is whether the path is gone.
#
# The -L branch is not tidiness, it is the whole reason the chmod is guarded.
# GNU `chmod -R` DEREFERENCES the symlink named on its command line (it does not
# follow links found during the walk, only the argument). `rsync -a` copies
# symlinks as symlinks (lib/sandbox.sh:25), so a target repo shipping
# `.cursor -> /home/<operator>` arrives in the workdir as exactly that, and an
# unguarded `chmod -R u+w` would then add owner-write across the operator's home
# -- measured on this host 2026-08-28: a 444 file under a symlinked tree came
# back 644, and a 555 directory came back 755. `rm -rf` would then remove only
# the link, `[[ -e ]]` would be false, and the round would proceed as though the
# policy directory had been cleaned. This is where the adapter differs from
# lib/sandbox.sh:67, which runs the same line against a path plan-review created
# itself; here the path is named by an untrusted repo.
#
# A symlink is removed, never followed: unlinking it IS the clean outcome, since
# what the CLI would have read is gone from the workdir either way. Only the link
# is touched; the target is not. `-L` is tested again below because `-e` is false
# for a DANGLING symlink, and a `.cursor` link left in place is still a policy
# path the CLI could resolve later.
if [[ -L "$workdir/.cursor" ]]; then
  rm -f "$workdir/.cursor"
elif [[ -d "$workdir/.cursor" ]]; then
  chmod -R u+w "$workdir/.cursor" 2>/dev/null
  rm -rf "$workdir/.cursor"
else
  rm -f "$workdir/.cursor"
fi
if [[ -e "$workdir/.cursor" || -L "$workdir/.cursor" ]]; then
  echo "agent adapter: could not remove $workdir/.cursor" >&2
  echo "That path can widen or switch off Cursor's sandbox (measured" >&2
  echo "2026-08-28), so the review is refused rather than run with it in place." >&2
  pr_reason "The target repo's .cursor policy path could not be removed; refusing to run unconfined"
  exit 1
fi

cd "$workdir" || exit 1

# Cursor's --sandbox enabled is meant to supply write confinement and the host
# allowlist; what nothing supplied until now is process-TREE containment. P6
# (probes 2026-08-26) measured the tool layer taking its own process group
# and session, so neither the kernel's group kill nor a session sweep can
# address a survivor -- one real 90s round left `sleep 900` holding the
# session lock. bwrap here adds ONLY the pid namespace: / is bound
# read-write on purpose, because the write barrier is meant to stay Cursor's
# own. Every vendor invocation goes through it -- create-chat and --version
# included, because "short-lived, nothing to contain" is an assumption, and
# an escaped descendant of either would hold the inherited session lock all
# the same. Verified live 2026-08-27
# (probes/2026-08-27-pid-namespace-adapters): authentication, session
# creation, tool execution and output capture all intact inside the
# namespace, and containment measured against an unwrapped control that DID
# leave a survivor on the host.
#
# That probe also measured a tool-call write to /tmp and to $HOME succeeding
# wrapped and unwrapped alike, and this comment used to conclude from it that
# Cursor had no write barrier. It had one; this host's ~/.cursor had turned it
# off. See the header, and CURSOR_CONFIG_DIR above, which is where the barrier
# actually comes from. The jail stays a pid fence only: / is still bound
# read-write, deliberately, because widening it would put Cursor's own Landlock
# sandbox inside a second jail for no measured gain. The two do coexist: run
# through this adapter on a host where the wrap gate passes, the $HOME canary is
# still denied and CURSOR_SANDBOX still reads `native`/`fully_enforced`
# (2026-08-28, same probe directory). Read that as "the fence did not break the
# barrier", not as a measurement of nesting: the wrap gate is a silent trial and
# the probe command echoed nothing that would witness which namespace it ran in.
# One `echo "pid=$$"` in that command would close the gap next time.
#
# No bwrap is NOT fail-closed here, unlike agy and claude: for them bwrap is
# the write barrier, for this adapter it is only the pid fence, and macOS
# has no bwrap at all. Where the platform provides no mechanism the kernel's
# descendant sweep is the bound -- docs/adapter-contract.md states exactly
# that.
#
# The gate is a working jail, not `command -v bwrap`. Presence is not
# function: on the host class lib/doctor.sh already documents -- Ubuntu 24.04
# with kernel.apparmor_restrict_unprivileged_userns=1 -- bwrap is installed and
# every jail it starts is denied. Gated on presence, all three invocations
# below would fail there and the round would lose this reviewer entirely
# ("create-chat produced no session id") on a machine where `agent` worked fine
# before this wrap existed. So the flags are tried once, on `true`, and a jail
# that will not start simply means no wrap: the reviewer still runs,
# containment degrades to the kernel's sweep, and the doctor is what tells the
# operator they lost the fence (pr_doctor_check_agent_pid_fence, a WARN --
# there is no fail-closed rule to enforce here). One extra bwrap spawn per
# adapter run, ~10ms, against silently losing a reviewer.
#
# The flag list is written ONCE and then trialled, rather than stated for the
# trial and restated for the wrap: two copies three lines apart are two copies
# that can disagree, and a trial that no longer matches what actually runs
# proves nothing about it.
wrap=(bwrap --bind / / --dev /dev --proc /proc
      --die-with-parent --unshare-uts --unshare-ipc --unshare-pid)
"${wrap[@]}" true > /dev/null 2>&1 || wrap=()

# `agent create-chat` prints the new chat id and then, in a CURSOR_CONFIG_DIR
# that has never completed a `-p` run, NEVER EXITS -- measured 2026-08-28, the
# private directory above is cold on its first round and this hung a 420s round
# to a dead stop before the bound went in. A directory that has completed one
# `-p` run exits immediately, which is why nothing saw this while the adapter
# read the operator's long-warm ~/.cursor. Root cause unidentified: it is some
# piece of first-run state the review run persists and `agent status` does not,
# and the config content is not it (an exact copy of a warm directory's
# cli-config.json in a fresh directory still hangs).
#
# So bound it and keep what it printed. The id is on stdout within a second or
# two, long before the hang, and a chat created by a create-chat that was then
# KILLED resumes normally -- measured, not assumed, because "the id exists" and
# "the chat is usable" are different claims. The measurement is
# docs/process/probes/2026-08-28-acceptance-matrix/, NOT leg 7 of the containment
# probe, whose rc=0 the same branch retired as a non-discriminator (`agent
# --resume` returns 0 for a UUID that was never a chat id). The matrix's agent
# resume leg ran from a fresh throwaway repo, so round 1's chat was minted
# through exactly this bound in a cold directory, and round 2 resumed that id and
# reproduced a token round 1 had been told to hold and never write down -- a
# token absent from round 1's published review and from round 2's prompt. What
# the matrix recorded is that minting and that resume, not the kill: no rc and no
# duration of its create-chat was captured, so the KILLED half follows from the
# cold-directory hang bisected above, not from the matrix. GNU `timeout` is already a hard
# requirement of this project (pr_doctor_check_gnu_timeout FAILS without it) --
# this is the one adapter that reaches for it directly, and the reasoning is
# restated here rather than shared because adapters source nothing.
#
# `--kill-after` is not optional, and least of all here. `timeout N` does not
# RETURN at N: it signals and then waits for its child, so against a process
# that ignores or blocks SIGTERM the bound is not a bound at all -- measured
# 2026-08-27 for the kernel's `ps` caps, 5.003s against 2.002s, and every other
# timeout in this project carries the escalation for that reason
# (lib/adapter-exec.sh). The thing being bounded here is a process whose
# defining observed property is that it never exits and whose root cause was
# NOT identified. Assuming it dies politely is exactly the assumption the
# measurement forbids, and without the escalation the "one stall per sandbox
# lifetime" below silently becomes the round's whole deadline.
#
# The deadline is derived, not fixed. 30s was the first draft and it can exceed
# the deadline it sits inside: `doctor --smoke` hands the adapter a
# PR_SMOKE_TIMEOUT_SECS that may be a few seconds. Half the round deadline,
# capped at 30 and floored at 1; the floor matters because GNU timeout reads 0 as
# *disabling* the timeout, which is the opposite of what this line is for.
#
# NOT the strict inequality adapters/agy.sh buys with its 900-per-mille
# derivation, and it should not be read as one: at PR_TIMEOUT_SECS=1 the derived
# value is also 1, and with --kill-after=1 this call can run about 2s inside a 1s
# round. That is harmless -- the execution kernel's own `timeout` bounds this
# whole adapter and reaps it -- but the property is "scales down with the round
# deadline", not "finishes before it". Cost in the normal case is one such stall
# per sandbox lifetime: the first round pays it, every later round either passes
# a session id or finds the directory warm.
_pr_agent_deadline="${PR_TIMEOUT_SECS:-900}"
[[ "$_pr_agent_deadline" =~ ^[1-9][0-9]*$ ]] || _pr_agent_deadline=900
_pr_agent_create_secs=$(( _pr_agent_deadline / 2 ))
(( _pr_agent_create_secs > 30 )) && _pr_agent_create_secs=30
(( _pr_agent_create_secs < 1 )) && _pr_agent_create_secs=1

session="$session_in"
if [[ -z "$session" ]]; then
  session="$(timeout --kill-after=1 "$_pr_agent_create_secs" \
               "${wrap[@]}" agent create-chat 2>/dev/null | tail -1 | tr -d '[:space:]')"
  if [[ -z "$session" ]]; then
    echo "agent adapter: create-chat produced no id" >&2
    pr_reason "Cursor's create-chat produced no session id; nothing was run"
    exit 1
  fi
fi
args=(-p --trust --sandbox enabled --resume "$session" --output-format text
      --model "$PR_AGENT_MODEL")

# stderr is NOT redirected: it is inherited, so it lands on this adapter's own
# stderr, which the execution kernel points at <round>/log-agent.txt
# (lib/adapter-exec.sh runs every adapter as `>> "$log" 2>&1`). That is where an
# operator looks, and it puts the CLI's error text beside this adapter's own
# echoes instead of in a file nothing names. It used to go to
# `"${review_out}.log"`; on the round path review_out is a scratch name, so that
# was <round>/.review-agent.scratch.log -- a dotfile no documentation mentions.
#
# What must stay separated is stderr from STDOUT, not stderr from this script's
# stderr: stdout IS the review here. `> "$review_out" 2>&1` would therefore
# splice the CLI's error text into the review markdown itself -- the artifact the
# verdict parser and the `Switched to` scan below both read. Deleting the
# redirect is the fix; duplicating fd 2 onto fd 1 is its opposite.
"${wrap[@]}" agent "${args[@]}" > "$review_out"
rc=$?

# Cursor can swap the model out from under the pin and say so only in prose in
# its own output -- measured: "Claude Opus 5 hit a safety filter, and the
# conversation was automatically switched to Claude Opus 4.8", while the run
# continued and produced a review. Recording the pin unconditionally would make
# round.json name a model that never answered, which is the exact failure Q2/R11
# exist to prevent. There is no structured field for this in --output-format
# text, so the notice is the only signal available.
model_effective="$PR_AGENT_MODEL"
switched_to="$(sed -n 's/^[[:space:]]*Switched to \(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
                 "$review_out" 2>/dev/null | head -1)"
if [[ -n "$switched_to" ]]; then
  model_effective="$switched_to (requested: $PR_AGENT_MODEL)"
  echo "agent adapter: the CLI switched models mid-run to '$switched_to'." >&2
  echo "Recording that as the effective model; '$PR_AGENT_MODEL' did not answer." >&2
  # An `ok` round is worth explaining too: without this the swap is visible only
  # in round.json's model field, which a reader comparing verdicts across rounds
  # has no reason to look at.
  pr_reason "Cursor switched to '$switched_to' mid-run; '$PR_AGENT_MODEL' did not answer"
fi

# Line 3 is deliberately empty: effort is inside the model id on line 2, so there
# is no separate effective value to report. See docs/adapter-contract.md.
printf '%s\n%s\n%s\n%s\n' \
  "$session" \
  "$model_effective" \
  "" \
  "$("${wrap[@]}" agent --version 2>/dev/null | head -1 | tr -d '[:space:]')" \
  > "$meta_out"

if [[ -s "$review_out" ]]; then
  exit 0
fi
# Said twice, once for the log and once for the round summary, the way
# adapters/codex.sh's Q8 diagnostics are -- adapters source nothing, so there is
# no shared constant, and lib/reviewer-runner.sh clips the reason at 200
# characters, so the long form stays here where nothing clips it.
#
# Said twice on purpose, the way adapters/codex.sh's Q8 diagnostics are. The
# first line names the possibility a reader coming from codex will otherwise
# assume they can rule in or out -- this adapter moved Cursor's state home too --
# and names it as UNRESOLVED rather than as a cause or a non-cause, because that
# is what the probe found: the resume of a stale handle and the resume of a UUID
# that was never a chat id are indistinguishable, both rc=0 with a normal answer.
# The rest names the causes the probe did leave standing. `--mode plan` is on the
# list because it was measured returning EMPTY output for a prompt that asks for
# a tool call, twice, while answering a plain question fine -- this adapter never
# passes it, but a config or a future flag change that did would land exactly
# here.
echo "agent adapter: exit $rc with no output" >&2
echo "  Cursor's config home is private to this round ($cursor_config), and" >&2
echo "  whether a handle minted before that move still resumes is UNVERIFIED:" >&2
echo "  --resume returns rc=0 even for an id that was never a chat (measured" >&2
echo "  2026-08-28), so its exit status rules nothing in or out. If this round" >&2
echo "  passed a stored handle, --fresh is worth one try." >&2
echo "  Likelier: authentication ($cursor_config holds no credential -- check" >&2
echo "  \`agent status\`), a model pin this account cannot use, or a run mode that" >&2
echo "  returns nothing for a prompt asking for a tool call, as --mode plan was" >&2
echo "  measured doing." >&2
pr_reason "Cursor exited $rc without writing a review (check auth and the model pin in the log; a stale session handle is unverified as a cause either way)"
exit 1
