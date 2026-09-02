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
# That list is exhaustive, and it used to be written as though it generalised.
# CURSOR_CONFIG_DIR moves cli-config.json and chats/. It does NOT move
# ~/.cursor/sandbox.json, which is a SECOND user-level file that can switch the
# write barrier off: an additionalReadwritePaths: ["$HOME"] there puts the
# reviewer's canary in the operator's home with this private directory in force
# and the sandbox still reporting native/fully_enforced (measured 2026-08-31,
# docs/process/probes/2026-08-31-cursor-write-barrier-gaps/, leg B5). That is
# the same failure mode approvalMode: "unrestricted" was, one file over, and
# there is no in-band answer to it: our own copy is not read from this directory
# (leg B3), the repo layer cannot revoke a per-user path grant because paths are
# UNIONED across sources (leg B6, and the vendor's own merge table), and
# XDG_CONFIG_HOME relocates cli-config.json without relocating this (leg C1).
#
# What DOES close it is moving HOME, and the first version of this comment said
# that breaks authentication. It does not, and the correction matters because it
# is the difference between a shut door and an open one: `agent status` under a
# relocated HOME reports "Not logged in" only because Cursor's credential lives
# at ~/.config/cursor/auth.json -- XDG-anchored, not in ~/.cursor -- so moving
# HOME moves XDG_CONFIG_HOME with it to an empty .config. Copy that one file and
# a private HOME authenticates, the operator's real ~/.cursor/sandbox.json goes
# inert, and projects/ follows the private home too (leg C2).
#
# That is what ships, and it is measured. A private HOME at <sandbox>/cursor-home
# with the operator's real XDG_CONFIG_HOME pinned FIRST was run live over four
# paid rounds on 2026-08-31 (docs/process/probes/2026-09-01-cursor-private-home/
# -- the directory name is a day ahead of the rounds it holds and is left alone
# because four files point at it; agent 2026.08.25-3e8eec8, composer-2.5
# throughout). Those rounds drove `agent -p` DIRECTLY, never through this file:
# the adapter rm -rf's <workdir>/.cursor, so it cannot be the instrument for a
# question about what a .cursor path does. The confining configuration -- a
# private CURSOR_CONFIG_DIR seeded with the cli-config.json pinned below -- was
# reproduced by hand, byte-for-byte. So what is measured is the MECHANISM these
# two exports use, not this file's invocation of it. A positive control put the
# canary in an escape target the sandbox would otherwise deny, using a
# $HOME-anchored additionalReadwritePaths grant; the identical grant went inert
# under the relocated HOME, denied by the kernel in its own words, while the round
# still authenticated and NOTHING was copied into the private home. So the cost
# argument the C2 leg raised evaporated: auth.json is XDG-anchored, the policy is
# HOME-anchored, and moving one without the other moves exactly the file we wanted
# moved. Cursor is still not a credential at rest here.
#
# Resume survives it: two rounds through that same environment, and round 2
# reproduced a token round 1 was told to hold and never to write down -- absent
# from round 1's published review and from round 2's prompt, so the chat carried
# it. Judged on content, because `agent --resume` returns rc=0 for a UUID that was
# never a chat id and rc therefore discriminates nothing.
#
# The cost, recorded and accepted rather than gated: the reviewer runs without the
# operator's HOME-anchored tool configuration -- no ~/.gitconfig, so no git
# identity, and no ~/.ssh. The probe records that as an INFERENCE from where those
# files live, not as a differential measurement: both of its legs ran with HOME
# already moved, so no leg ever showed the unmoved baseline. See the block beside
# the export below for why the answer to a workflow that needs one of them is not
# to start copying dotfiles in.
#
# The per-project state moves with it, which the earlier version of this paragraph
# said it did not. ~/.cursor/projects/<slugged-workdir>/ -- .workspace-trusted and
# the full agent-transcripts/*.jsonl of every round -- now lands under the private
# home beside the repo copy. Measured by slug, not by clock: after four rounds the
# operator's real ~/.cursor/projects/ held no entry naming any path the probe used.
# It is relocated, not eliminated; the record of the review is still on the host,
# and it now lives as long as the session cache does.
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

# Part three -- the operator's ~/.cursor/sandbox.json, which the private config directory
# above does NOT move. An additionalReadwritePaths grant there was measured widening this
# reviewer's jail with CURSOR_CONFIG_DIR in force and the sandbox still reporting
# native/fully_enforced (leg B5, 2026-08-31; reproduced the same day against an isolated
# escape target by the private-HOME probe). Our own file cannot go where it would win:
# CURSOR_CONFIG_DIR does not relocate this path (B3), nor does XDG_CONFIG_HOME (C1), and
# the repo layer cannot revoke a per-user grant because paths are unioned across sources
# and the schema has no deny list (B6).
#
# HOME is the only thing that moves it, and the ORDER of these two lines is the whole
# mechanism. ~/.cursor follows HOME; Cursor's credential at ~/.config/cursor/auth.json
# follows XDG. Pin XDG off the REAL home first and the operator's per-user policy goes out
# of scope while their login stays in it -- nothing copied, no third credential at rest,
# which is this adapter's one real advantage over the other three. Swap the lines and XDG
# resolves under the empty private home, the round reports "Not logged in", and someone
# concludes for the second time that moving HOME breaks Cursor's authentication. It does
# not; measured 2026-08-31, docs/process/probes/2026-09-01-cursor-private-home/.
#
# TWO tests in tests/test-adapter-agent.sh, one per half, and they are NOT redundant:
#
#   test_an_unset_xdg_config_home_is_pinned_before_the_home_moves
#       the ORDERING guard. Fails if and only if these two exports are swapped --
#       verified by swapping them in a scratch copy of the tree: 26 run, 1 failed,
#       that case alone. It is the only thing standing between a reordering edit
#       and a round that reports "Not logged in".
#   test_the_adapter_runs_cursor_under_a_private_home
#       the CUSTOM XDG_CONFIG_HOME half. PASSES UNDER EITHER ORDER, so it proves
#       nothing about the ordering -- what it holds is that an explicitly set
#       XDG_CONFIG_HOME survives the relocation.
#
# Naming them is the point: whoever reads "two cases that both set HOME" and deletes
# the redundant-looking one has a fifty-fifty chance of deleting the guard.
#
# The probe host had XDG_CONFIG_HOME UNSET, so only the default half of the expansion
# below was exercised against a live CLI. The custom half is the same code path and is
# covered by test_the_adapter_runs_cursor_under_a_private_home and by nothing else.
#
# UNMEASURED ON DARWIN, and not gated on it. All four rounds were Linux; that
# auth.json is XDG-anchored rather than HOME-anchored on a Mac is an ASSUMPTION -- not
# a measurement, and not a citation either: nothing under docs/process/probes/ cites a
# vendor page for it. It is the fact this whole ordering rests on.
#
# Left ungated deliberately, and the justification is narrower than the first draft of
# this comment claimed. What a credential-less run does HERE is not measured: the only
# "Not logged in" anyone has seen came out of `agent status`
# (probes/2026-08-31-cursor-write-barrier-gaps/), never out of `agent -p`, so any claim
# that the failure is loud is inferred from a different command. Both shapes it could
# take are safe anyway, and they are different. Either the CLI writes nothing and this
# adapter exits 1 with the empty-output reason below -- or it prints its refusal on
# STDOUT, which is exactly where the probe's own pass condition looked for that string,
# and then the round publishes it: `[[ -s "$review_out" ]]` is the whole publication
# gate here, and lib/reviewer-runner.sh accepts UNPARSEABLE as a legal verdict on an
# `ok` reviewer. So a Darwin credential problem can land as `status: ok` with the CLI's
# refusal quoted in the round's own artifact. Not silent, but not a failed round
# either -- say so rather than promising an exit code that may not come.
#
# NEITHER SHAPE IS A SILENT WIDENING, and that is the property the gate turns on: these
# two exports run before the CLI starts on every platform, so wherever a Mac keeps its
# credential, the operator's per-user policy is already out of scope. An $OSTYPE gate
# would instead ship a second confinement path for agent that nobody has measured
# either. Recorded in BACKLOG.md with its reopen trigger instead.
#
# Sited beside the repo copy for the reason CODEX_HOME and cursor-config are: it must
# survive pr_sandbox_refresh's per-round wipe of <sandbox>/repo. NOT under /tmp -- the C2
# leg worked there only because Cursor grants /tmp by default, which proves nothing about
# this placement, and lib/sandbox.sh puts TMPDIR inside the repo copy for the sibling
# reason.
#
# Accepted cost, stated rather than solved: this moves the reviewer's WHOLE environment,
# not just Cursor's state lookup. ~/.gitconfig, ~/.npmrc, ~/.ssh and everything else
# HOME-anchored go with it, and no other adapter here does that -- codex moves CODEX_HOME,
# agy binds a private directory over $HOME/.gemini, claude keeps HOME in its whitelist. A
# reviewer reads code and writes a critique, so the delta is affordable; the probe recorded
# exactly what it was -- as an INFERENCE from where those files live, not as a differential
# measurement, since both of its legs ran with HOME already moved and none of them ever
# showed the unmoved baseline. The answer to a workflow that turns out to need one of those
# files is NOT to start copying dotfiles in -- that is a policy inventory of the operator's
# environment, maintained forever, one file at a time.
#
# What this does NOT do is isolate the reviewer's user state: XDG_CONFIG_HOME still points
# at the operator's real ~/.config, deliberately, because the credential is there. And the
# transcripts are relocated, not eliminated -- ~/.cursor/projects/<slug>/ now lands in the
# session cache and lives as long as it does.
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
cursor_home="$(dirname "$workdir")/cursor-home"
if ! mkdir -p "$cursor_home" 2>/dev/null; then
  echo "agent adapter: cannot create $cursor_home" >&2
  pr_reason "Could not create Cursor's private home; refusing to run under the operator's per-user sandbox policy"
  exit 1
fi
export HOME="$cursor_home"

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
# One directory is the WHOLE boundary, not the root of one that needs walking:
# both surfaces are read from the workspace root and nowhere below it. The leg-3
# grant that escapes from <repo>/.cursor/sandbox.json is inert at
# <repo>/sub/.cursor/sandbox.json, twice, with the write denied by the kernel;
# and a rules/injected.mdc planted one directory down never fires while the same
# file at the root does -- the review comes back carrying its token (measured
# 2026-08-31, docs/process/probes/2026-08-31-cursor-write-barrier-gaps/, legs
# A1/A2). That rules half is also the first time the surface was witnessed doing
# anything at all: leg 3 planted the file and only ever checked the canary. This
# adapter always runs from the workspace root (`cd "$workdir"` below), which is
# the CWD those legs measured.
#
# Safe because <workdir> is a disposable per-round copy, never the operator's
# checkout (lib/sandbox.sh; docs/adapter-contract.md says the same).
#
# chmod first, and CHECKED after, for the same reason its two siblings above are
# checked: this is the half that closes the two measured escapes, and a silent
# failure here leaves cli.json in place and runs the review anyway. The failure
# is not hypothetical -- lib/sandbox.sh:67 records it: `rsync -a` preserves the
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
# is touched; the target is not -- `rm -rf` unlinks a link without descending it,
# so the chmod is the only line a symlink must be kept away from, and it is the
# only one guarded. `-L` is tested again below because `-e` is false for a
# DANGLING symlink, and a `.cursor` link left in place is still a policy path the
# CLI could resolve later.
[[ -L "$workdir/.cursor" ]] || chmod -R u+w "$workdir/.cursor" 2>/dev/null
rm -rf "$workdir/.cursor"
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
# and session ON LINUX, so neither the kernel's group kill nor a session sweep
# can address a survivor -- one real 90s round left `sleep 900` holding the
# session lock.
#
# That scoping is not pedantry, and it was added after the fact. On Darwin the
# same tool layer was measured NOT regrouping: a detached escaper stayed in the
# adapter's timeout(1) process group for all 81 frames it lived, and the
# ordinary group kill got it (probes/2026-08-29-macos-row3-sweep, two live
# rounds). So the regrouping is a vendor behaviour that differs by PLATFORM,
# which is the strongest available evidence that it can differ by version too.
# The fence below is deliberately not contingent on it: a pid namespace
# disposes of the tree whichever group the vendor picks, so the flag needs no
# re-measurement when that pick changes. There is no Darwin question to answer
# either way -- macOS has no bwrap, and the kernel's descendant sweep is the
# bound there.
#
# bwrap here adds ONLY the pid namespace: / is bound
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
#
# A malformed value is REFUSED, not defaulted away, and the refusal is a copy of
# adapters/agy.sh's: docs/adapter-contract.md names that adapter as the reference
# for exactly this, so an adapter deriving an inner deadline that quietly
# substituted 900 would leave the contract pointing at the minority spelling.
# Adapters source nothing, so this is the third copy of one rule, on purpose --
# libexec/plan-review-round.sh holds the runner's.
_pr_agent_deadline="${PR_TIMEOUT_SECS:-900}"
if [[ ! "$_pr_agent_deadline" =~ ^[1-9][0-9]*$ ]]; then
  echo "agent adapter: PR_TIMEOUT_SECS must be a positive whole number, got: $_pr_agent_deadline" >&2
  exit 1
fi
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
# frame); Cursor's text mode carries no such field, so reading it while the binary
# about to answer is still the one on disk is the nearest equivalent. It narrows
# the window from the whole review to the gap between two adjacent commands; it
# does not close it, and nothing here detects the remainder.
version="$("${wrap[@]}" agent --version 2>/dev/null | head -1 | tr -d '[:space:]')"

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
  "$version" \
  > "$meta_out"

if [[ -s "$review_out" ]]; then
  exit 0
fi
# Said twice, once for the log and once for the round summary, the way
# adapters/codex.sh's Q8 diagnostics are -- adapters source nothing, so there is
# no shared constant, and lib/reviewer-runner.sh clips the reason at 200
# characters, so the long form stays here where nothing clips it.
#
# The first line names the possibility a reader coming from codex will otherwise
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
