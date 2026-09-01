# Adapter contract

Four adapters ship: `codex`, `agent` (Cursor), `agy` (Antigravity), and `claude`
(Claude Code). There is no fixed default roster: a project config's `reviewers`
list names them outright, and with no config `PR_ORCHESTRATOR` names the CLI
driving the round and the default roster is the other three — see "Reviewer
roster" in the README, and `lib/roster.sh`.

A fifth adapter would be added to `PR_ROSTER_ADAPTERS` in that file, keyed by the
basename of `adapters/<name>.sh`; nothing else derives the roster.

**Nothing below changes because a config exists.** `lib/config.sh` resolves a
project's pins into the same `PR_*_MODEL` and `PR_*_EFFORT` variables adapters
already read, before any adapter is invoked. An adapter cannot tell a pin that
came from a config file from one typed on the command line, and must not try.

Every adapter — real or fake — is invoked identically:

    adapters/<reviewer>.sh <workdir> <session_id_or_empty> <review_out> <meta_out> <reason_out>

- **stdin** — the full prompt. Never passed as an argument: a single argv entry
  is capped at 128 KiB (`MAX_ARG_STRLEN`), which a plan plus diff plus rationale
  can exceed.
- **stdout / stderr** — diagnostics only, captured to a log. The review must never
  arrive on stdout. One shipped exception, and it is about the *artifact*, not the
  stream: `adapters/claude.sh` tees the CLI's `stream-json` to stdout so the
  kernel's `>> log-<reviewer>.txt 2>&1` records it, and the result frame in that
  stream carries the review text inside its JSON. What the clause protects is
  `<review_out>` — no framing, no duplicate — and that still holds: the adapter
  extracts `.result` from the FILE it also wrote. Read the clause as "nothing
  downstream may read the review off stdout", which nothing does.
- **`<review_out>`** — the Markdown review, written by the adapter. Write the review
  to exactly the path you are given and to no other: the round hands adapters a
  scratch path and publishes a copy of it under its own name once the adapter has
  gone, so a survivor still writing cannot change the artifact the round recorded.
  Diagnostics do not belong on a derived path at all: write them to **stderr**,
  which the round captures to `log-<reviewer>.txt`. No shipped adapter derives a
  path from `<review_out>` — `claude` and `agent` each wrote a `<review_out>.log`
  until 2026-08-27, which on the round path became a hidden dotfile beside the
  scratch review that nothing named and nothing cleaned up. If you derive one
  anyway, it is yours to clean up: the round sweeps only the scratch names it
  composes itself (`pr_reviewer_scratch_rm`, `lib/reviewer-runner.sh`).
- **`<meta_out>`** — exactly four lines, any of which may be empty:

      line 1   session handle to resume next round ('' if the CLI reports none)
      line 2   effective model — what actually answered, not what was requested
      line 3   effective reasoning effort, or '' if the CLI has no separate axis
      line 4   CLI version

  The runner reads `<meta_out>` back only while it is a regular file -- a
  symlink to a device or a FIFO reads as four empty lines -- and reads at
  most its first 4096 bytes.

  The adapter reports the *effective* values because a pin the CLI silently
  ignored would make `round.json` claim a model that never ran (Q2, R11).

  Line 4 has the same rule and it is not free: **the version must name the
  binary that wrote the review**, so take it from the run's own output where the
  CLI offers one (`codex`'s banner, `claude`'s `init` frame) and otherwise read
  it *before* the run rather than after. Measured 2026-08-29: Cursor
  self-updated mid-round, and a post-run `agent --version` recorded a binary
  that had not written the review
  (`docs/process/probes/2026-08-29-macos-row3-sweep/`). Reading first does not
  close the window, it only narrows it to the gap between two adjacent commands
  — but a version read after the run is wrong for the whole duration of every
  round a self-updating CLI happens to overlap, and nothing detects it.

  Line 3 is empty for Cursor and agy by design, not by omission: both fold effort
  into the model id (`claude-opus-5-medium`, `gemini-3.1-pro-high`), so line 2
  already carries it. Codex is the only CLI that fills line 3.

  Claude Code is empty on line 3 for a third reason, worth distinguishing from
  the other two: `--effort` is a genuine independent axis there, and the
  effective value is reported in neither `--output-format json` nor
  `stream-json`. `PR_CLAUDE_EFFORT` is passed through and nothing can confirm it
  took, so two rounds run at different tiers are indistinguishable in
  `round.json`. An unverifiable value is not written to a field that means
  "effective".
- **`<reason_out>`** — optional, and the only argument an adapter may ignore
  entirely. An adapter that knows *why* the round went the way it did writes one
  line here; the runner uses it as `detail` in `round.json` and in the status
  line. Semantics, so they are not left to each adapter to invent:

      when written   whenever the adapter has a better answer than an exit code,
                     whatever the status — an `ok` round whose model was swapped
                     underneath it is worth explaining too
      how it is read first line only, newlines stripped, truncated to 200
                     characters
      when absent    the runner's generic message, byte for byte what it wrote
                     before this argument existed
      lifetime       deleted with the round's other scratch files

  Adapters must tolerate the argument being missing (`"${5:-}"`), so a hand-run
  invocation with four arguments still works. It is a diagnostic channel, not a
  second review: the review still goes to `<review_out>` and nowhere else.
- **exit code** — 0 means usable output. The runner also accepts a non-zero exit
  when `<review_out>` is non-empty, because Cursor exits 2 on a denied tool call
  while still producing a correct review (D7).
- **`TMPDIR`** — the runner exports a private one per reviewer, always a directory
  *inside* `<workdir>`. Adapters must not override it. It has to be inside the
  workdir because codex removes `$TMPDIR` from its writable roots
  (`exclude_tmpdir_env_var`), so a path outside would not be writable.
- **`PR_TIMEOUT_SECS`** — the deadline `timeout(1)` is enforcing on *this* call, a
  positive whole number of seconds. An adapter that derives an inner deadline
  (`adapters/agy.sh` passes 90% of it as `--print-timeout`) reads it from here, so
  the inner deadline is guaranteed to sit strictly inside the outer one. Both this
  and `TMPDIR` are exported by the execution kernel (`lib/adapter-exec.sh`) from
  the values it was handed as positionals — one fact, one channel, with no way for
  a caller to set a second, disagreeing copy. An adapter run by hand must therefore
  set it itself, and refuse a non-positive-integer value the way `adapters/agy.sh`
  does.
- **stdin is the contract even when the CLI cannot honour it.** `agy` reads no
  prompt from stdin — its `-p/--print` is a string flag whose value *is* the
  prompt — so `adapters/agy.sh` consumes stdin and re-passes it as an argv entry.
  That reintroduces the 128 KiB `MAX_ARG_STRLEN` cap this contract exists to
  dodge, for that adapter alone, with no fallback path. It must measure the
  prompt and fail with a clear message above the cap rather than let `execve`
  return a bare `E2BIG`. Do not "fix" this by moving the whole contract to argv.
- **confinement is the adapter's job, and it is not uniform.** codex confines
  its own writes via its sandbox flags. Cursor does too, but only once the
  adapter decides whose configuration it reads — measured 2026-08-28 against
  `2026.08.25-3e8eec8` (`docs/process/probes/2026-08-28-cursor-containment`).
  `--sandbox enabled` is *inert* under `approvalMode: "unrestricted"` in the
  operator's `~/.cursor/cli-config.json`: the tool call runs with
  `CURSOR_SANDBOX` unset and a write to `$HOME` lands on the host, which is what
  the 2026-08-27 probe saw and misread as a vendor regression. So
  `adapters/agent.sh` points `CURSOR_CONFIG_DIR` at a private directory beside
  the repo copy and pins the approval mode there, and it deletes the target
  repo's own `.cursor/` first — a repo-supplied `sandbox.json` granting
  `additionalReadwritePaths` to `$HOME`, and a repo-supplied `cli.json`
  allowlisting a shell command, were each measured putting the canary on the
  host. With both closed the `$HOME` canary is denied and the sandbox reports
  `native`/`fully_enforced` — measured through the adapter, so with its bwrap gate
  in play, though nothing in that run witnesses which namespace the command was in.
  The bwrap stays a pid fence and is deliberately still not the write barrier.
  `agy` never did: its
  `--sandbox` was measured to allow a write to `/tmp` while reporting itself
  enabled, so its adapter wraps the CLI in `bubblewrap` instead and **fails
  closed** when `bwrap` is unavailable. `claude` used to be the second such
  adapter and is not any more: since 2026-08-30 it **switches mechanism per
  host** rather than refusing, taking bubblewrap where `bwrap` exists and Claude
  Code's own sandbox where it does not, chosen once at a single `$confinement`
  variable. That is not an exception to the rule below and must not become one:
  the second mechanism is itself fail-closed, by a settings file carrying
  `failIfUnavailable: true`, and neither half ever runs unconfined. An adapter
  that cannot confine writes must refuse to run, never run unconfined — a vendor
  sandbox you have not measured *at the version you ship against* is not
  confinement, it is a claim.

  Three qualifications on that switch, all measured 2026-08-30 and all
  load-bearing (`docs/process/probes/2026-08-30-claude-macos-row1`, `-row5`,
  `-row67`). **A vendor sandbox may confine less than a jail does**: Claude
  Code's confines the commands its Bash tool spawns and *not the CLI's own
  process*, so with `Write` allowed the CLI wrote outside the declared writable
  set — which is why that half must run at `permissionMode: default`, where the
  unsandboxed Write and Edit tools are denied outright. **The repository under
  review is a configuration surface and outranks the flags you pass**: a
  repo-supplied `.claude/settings.json` switched the sandbox off with our own
  `--settings` saying the opposite, exactly as `.cursor/`'s two surfaces did, so
  that adapter deletes the repo copy's `.claude/` too. And **`failIfUnavailable`
  is not the backstop it reads as**: with Seatbelt made unavailable the CLI
  started anyway and denied every command, ending `is_error: false` with a
  non-empty review — so an adapter whose confinement is a vendor's must also
  assert that the reviewer *ran something*, which is the clause below.
- **a reviewer that ran no command must not be recorded as a review.** There are
  four measured routes to a confident, empty, `status: ok` round with a real
  session id and model: a `$TMPDIR` socket path over the 108-byte unix-socket
  ceiling; a sandbox that starts and denies every call; a command needing an
  approval a headless run cannot grant; and, on Darwin, a command that *runs*
  while the kernel denies its write. None of them trips an envelope check,
  because in all four the envelope is honest — the CLI did what it was asked.
  Where an adapter's output format makes tool calls visible, it must assert that
  at least one command succeeded and fail the reviewer otherwise. The cost is
  stated rather than hidden: a review that legitimately needed no command fails
  too. That is the intended direction — `lib/prompt.sh` tells every reviewer to
  run things, and a confident review that checked nothing is worse than a missing
  one, because `round.json` records it as `ok`.
- **the environment is part of the boundary.** A jail confines the filesystem;
  it does not stop a variable. When the orchestrating harness is itself an agent
  CLI, its own variables are inherited by everything the runner spawns —
  measured for Claude Code, which exports eleven `CLAUDE_*` variables including
  a messaging socket and token that address the orchestrator session, and an
  effort level that could override the one the round asked for. An adapter whose
  CLI shares a vendor with a possible orchestrator must rebuild the child
  environment from a whitelist rather than inherit it.
- **state that must outlive the round goes beside the workdir, never inside it.**
  `pr_sandbox_refresh` wipes `<sandbox>/repo` every round. `adapters/claude.sh`
  keeps its private `CLAUDE_CONFIG_DIR` at `<sandbox>/config` for that reason:
  the sessions that make carry-forward possible would otherwise be deleted by
  the next round's copy. `adapters/agy.sh` does the same at
  `<sandbox>/gemini-state`, bound over `~/.gemini` — a bind, and therefore the one
  of the four with no macOS expression: `HOME` relocation was measured failing to
  authenticate even with the whole `~/.gemini` copied, and with no sandbox in the
  picture at all (`docs/process/probes/2026-08-30-claude-macos-row9-agy`) — `adapters/codex.sh` at
  `<sandbox>/codex-home`, exported as `CODEX_HOME`, and `adapters/agent.sh` at
  `<sandbox>/cursor-config`, exported as `CURSOR_CONFIG_DIR` — four private
  directories, one per adapter that has durable state. Two of them are not binds
  at all: they are environment variables the CLI honours, which is the cheaper
  mechanism wherever a CLI offers one, and Cursor's is cheaper still, since an
  empty `CURSOR_CONFIG_DIR` is already authenticated and so needs no credential
  copied or bound in at all. For Cursor the isolation is not only hygiene: the
  approval mode that decides whether its sandbox applies lives in that file.
  Isolating them also keeps the
  operator's own `~/.claude/settings.json` — which defines hooks that run in
  *their* interactive sessions — outside the reviewer's reach, and the same
  argument applies to `~/.gemini`, whose hook file agy was measured *executing*
  (`docs/process/probes/2026-09-01-agy-hook-surface/`; the adapter also removes the
  repository's own `.agents/`, on that measurement **plus** the rest of that
  directory, which no leg touched), and to
  `~/.codex`, whose ambient configuration had already taken a reviewer out.

  Auth material comes in **read-only and by path**, one file at a time, measured
  rather than guessed: never a read-write bind of the operator's real directory,
  which would be a persistence channel out of the jail. **Where the CLI needs its
  credential writable, copy the one file instead** — `adapters/codex.sh` copies
  `~/.codex/auth.json` into the private home because codex may refresh the token
  in place, and a bind would have it refresh the operator's. A copy is a second
  credential at rest, so it comes with three obligations: copy **once** (round
  N+1 must not clobber a refresh round N wrote), copy only into a directory the
  reviewer already owns, and name the copy anywhere it can be left behind —
  `lib/doctor.sh` removes it from a smoke directory kept for diagnosis, by path.
  A read-write bind of the real directory remains forbidden; this carve-out is
  for one file, not for the directory holding it.
- **Containment.** An adapter must contain its own process tree where the
  platform provides a mechanism — on Linux, `bwrap --unshare-pid` (agy, claude,
  agent) or the CLI's own equivalent (codex `--as-pid-1`). Where the platform
  provides none (macOS has neither pid namespaces nor bwrap), the execution
  kernel's best-effort descendant sweep is the bound, and the adapter is not
  required to invent one.
- **process group** — the runner invokes adapters under `timeout(1)`, which places
  each adapter in its own process group and signals the whole group. A descendant
  that leaves that group by taking one of its own is swept separately and
  best-effort, from a `ps` walk sampled while the adapter ran. Adapters do not need
  to reap their own children. That sweep is the *fallback*, not the primary bound:
  where the containment clause above applies, the namespace collapsing is what
  actually disposes of the tree, and the sweep is what remains where it does not.
