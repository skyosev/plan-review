---
paths:
  - adapters/**
  - lib/sandbox.sh
  - tests/test-adapter-*.sh
---

# Confinement, per adapter

Moved verbatim from `CLAUDE.md` (Architecture notes) on 2026-09-03. Loads when an adapter
is being edited. The never-rules stay in `CLAUDE.md`; this is the measurement record.

- **Confinement is per-adapter and not uniform**: codex confines its own *writes*, and so
  does Cursor — but only once the adapter takes the *user-level* config away from it.
  `--sandbox enabled` is **inert** under `approvalMode: "unrestricted"` in
  `~/.cursor/cli-config.json` (Run Everything; the vendor's own mode table says
  "Sandbox: No"): the tool call runs with `CURSOR_SANDBOX` unset and the `$HOME` canary
  lands on the host. That is what leg 4 of the pid-namespace probe measured and read as a
  vendor regression — the binary was innocent and so was `--trust`, which every confining
  run since passes (`docs/process/probes/2026-08-28-cursor-containment`, same version,
  2026-08-28). So `adapters/agent.sh` exports a private `CURSOR_CONFIG_DIR` and rewrites
  its `cli-config.json` every round, and it `rm -rf`s the target repo's `.cursor/` first:
  **two of the three repo-supplied surfaces escaped** — `additionalReadwritePaths: ["$HOME"]`
  in `sandbox.json` widened the jail with the sandbox still reporting `native`, and
  `permissions.allow: ["Shell(sh)"]` in `cli.json` switched it off outright; only
  `type: "insecure_none"` was refused. Nothing is written back in `.cursor`'s place,
  because `type` from a per-repo `sandbox.json` was measured inert in *both* directions.
  The empty allowlist in the pinned config is not cosmetic: an allowlisted command is
  exempted **from the sandbox**, not merely from the prompt. One cost came with the
  private directory: `agent create-chat` prints the new id and then **never exits** in a
  config dir that has not yet completed a `-p` run, so it runs under a
  `timeout --kill-after=1` whose deadline is derived from `PR_TIMEOUT_SECS` (half, capped
  at 30, floored at 1 — `0` disables a GNU timeout), and the adapter keeps the id it
  printed. That the killed `create-chat`'s chat still resumes is measured by the acceptance
  matrix cited below and by nothing else — not by the containment probe's leg 7, whose rc=0
  the same branch retired as a non-discriminator. That derivation is *not* agy's strict
  inequality: at `PR_TIMEOUT_SECS=1` the inner bound equals the outer one and can overrun
  it by the kill grace, which the kernel's own `timeout` then reaps. The escalation is
  load-bearing for the same reason it is on the `ps` caps: `timeout N` signals at N and
  then *waits*, and never exiting is the only thing this process is known to do. What the
  matrix establishes is that an id minted under this bound is usable: its agent leg ran two
  rounds through the shipped adapter from a fresh throwaway repo, so round 1 minted its chat
  in a cold config dir — through this very bound — and round 2 reproduced a token round 1 had
  been told to hold and never to write down, a token absent from round 1's published review
  and from round 2's prompt, so a cold chat could not have emitted it
  (`docs/process/probes/2026-08-28-acceptance-matrix/`, 2026-08-28). What it does **not**
  record is the kill: no rc and no duration of that `create-chat` was captured, so the
  *killed* half follows from the cold-directory hang measured above, not from the matrix.
  That discriminator is the point: `agent --resume` returns rc=0 for a UUID that was never
  a chat id, so **rc
  discriminates nothing** and every claim here has to rest on content. What stays
  **unknown** is the *transition*: what moving Cursor's config home costs a handle minted
  under the operator's `~/.cursor`, which is codex's measured one-cold-round tax and has
  no counterpart measurement here. Rounds that mint and resume inside the private
  directory — every round the runner actually starts — are covered; the one migration is
  not. `agy` is
  wrapped in bubblewrap by its adapter and
  **fails closed** when `bwrap` is missing. Never add an unconfined fallback for it.
  It is the one adapter that did **not** grow a second engine on Darwin, and that is a
  measured outcome rather than an unexplored gap
  (`docs/process/probes/2026-09-01-agy-macos-routes/`, 2026-09-02, `agy 1.1.24`). The write
  barrier ports — a `sandbox-exec` profile held, and `agy` authenticated and reached its model
  behind one — but the **private state directory** does not: it is a bind over `~/.gemini` and
  there is no bind without `bwrap`. All three replacements are closed. `GEMINI_HOME` and
  `XDG_CONFIG_HOME` are both ignored (`agy` composes `$HOME/.gemini` and dies at
  `installation_id`), and `agy --help` has no state-directory flag. A private `HOME` has **no
  login keychain in its search list at all** — `security default-keychain` answers "A default
  keychain could not be found" — so the Safe Storage key that Mac authenticates with is
  unreachable by mechanism; that also *explains* row 9's legs A–C, which is an attribution and
  not a measurement, since row 9 was not re-run. And a profile narrowed to deny the
  configuration paths is a **correct** narrowing that `agy` cannot run behind: its shell tool
  layer must write `~/.gemini/antigravity-cli/bin/agentapi` before a tool call can run — four
  attempts, four denials, no tool call, all under `rc=0` and a confident
  `"status":"SUCCESS"`, with the decisive evidence in neither stream nor envelope but in
  `agy`'s own brain store. So the price is **irreducible and worse than a state directory**:
  write access to a path that already holds executables, in the operator's real tree,
  surviving the round. The write is measured; that `agy` then *executes* it is inference —
  never write "write-then-execute" unhedged. `specs/2026-09-01-agy-macos-port/00.plan.md:166`'s
  "R4 is not a shippable variant" is **superseded**: it was derived from a ship gate aimed at
  `agy`'s *configuration* paths and decided before the price was known.

  **That exposure was accepted by the operator on 2026-09-02**, price in hand, on the stated
  condition that declining costs nothing but not naming `agy` in a macOS roster. **Nothing has
  been built**, and the four `bwrap` gates stay exactly as they are until it is — do not take
  one down alone. The condition is the reason: `pr_roster_default_map` (`lib/roster.sh`) is the
  shipped adapters minus the orchestrator and knows nothing about platforms, so the derived
  default on a Mac already names `agy`, and today only `pr_init_needs_jail` and the adapter's
  own refusal keep it out. Remove the refusal by itself and macOS `agy` is **opt-out**, which
  is not the decision that was taken. A port owes an explicit-opt-in rule, platform-awareness
  in `pr_init_needs_jail` and preflight's jail list, a `sandbox-exec` engine chosen at one
  `$confinement` variable on `adapters/claude.sh`'s pattern, a doctor check naming the half,
  and a paid acceptance round **on a Mac** — none of it is verifiable from Linux.
  `docs/process/BACKLOG.md` carries that list.
  It is also the **third** adapter to `rm -rf` the repository's own configuration
  directory — `<workdir>/.agents`, beside `agent.sh`'s `.cursor` and `claude.sh`'s
  `.claude` — and unlike codex's `-c features.hooks=false`, whose non-execution was
  measured but whose *gate* is inferred, this one closes a path that was measured
  **firing**. A `$work/.agents/hooks.json` carrying a `PreInvocation` command was
  executed by agy in this adapter's own invocation shape
  (`--sandbox --dangerously-skip-permissions -p`), with no prompting and **no trace at
  all on the `--output-format json` transcript** — a clean `"status":"SUCCESS"` and an
  unrelated model answer; the evidence is a marker file on the host and the CLI's own
  log inside the state directory, which is the transferable lesson (a probe that judges
  `agy` by its JSON envelope alone is reading the wrong stream). Measured 2026-09-01 at
  `agy 1.1.22` on Linux, leg A of
  `docs/process/probes/2026-09-01-agy-hook-surface/`. The whole directory goes rather
  than the one file **because the measurement is narrower than the surface**: `.agents/`
  also carries custom agents and other workspace customisation that no leg touched, and
  nothing here establishes which other events fire or what the `flat` hook shape does.
  The same probe's leg B measured the identical execution from
  `~/.gemini/config/hooks.json`, which is what re-prices the private state directory
  above: its read-write bind of the operator's real `~/.gemini` would be arbitrary code
  execution in *their* later sessions, and that argument now rests on a measurement
  rather than on the vendor's documentation. It does **not** rest on the reviewer
  writing that file itself — leg C asked for exactly that and the file never appeared.
  **What refused it is not established**: the quotes naming `agy`'s own terminal sandbox
  were read live from a state directory that no longer exists, so that attribution is a
  hypothesis worth testing rather than a measured property of 1.1.22. The **negative**
  half is auditable in the probe's `raw/` and does stand — **bwrap did not deny it**: the
  jail bound that directory read-**write** on purpose, and the leg's own listing shows
  the CLI process creating four entries inside it in the same run. `DENIED` there is
  "this route was refused" from one command in one shape with no control run, not "the
  directory is unreachable".

  **`claude` stopped being the second such adapter on 2026-08-30 and now switches
  mechanism per host**, chosen once at a `$confinement` variable and reported by
  `pr_doctor_check_claude_confinement` — two bounds on the drift two halves invite.
  With `bwrap`: the jail, `--dangerously-skip-permissions`, an init line asserted
  to say `bypassPermissions` — byte-for-byte what shipped, because nothing on a Mac can
  re-run the twelve-row acceptance matrix that pins it, and buying symmetry by rewriting
  the measured path was the trade this branch refused (row 2, `HANDOFF-claude-macos.md`;
  `specs/claude-macos-rewire/NOTES.md` specified ONE path and is overruled in writing).
  That Linux path was re-verified live on 2026-08-30 at `claude 2.1.251` — init line,
  `--safe-mode` against a control, and the resume handle — so the byte-for-byte claim is
  measured and not merely readable (`docs/process/FINDINGS-2026-08-30-linux.md`).
  On **Darwin** without `bwrap`: Claude Code's own sandbox, `failIfUnavailable: true`, no
  `--dangerously-skip-permissions`, `permissionMode: default`.

  **There is no third case: a non-Darwin host with no `bwrap` is REFUSED**, in
  `adapters/agy.sh`'s spelling and for its reason. That is a correction to how the branch
  first shipped, and the measurement is worth carrying because it is counter-intuitive:
  **Claude Code's own sandbox is implemented with bubblewrap on Linux.** So the condition
  that selected the builtin half there — no `bwrap` — was exactly the condition that broke
  it, and the CLI exited with no init line naming `bwrap` as the missing dependency
  (measured 2026-08-30, row L3). The builtin half is a **Darwin path**, and `socat` is the
  second binary of the same dependency pair rather than an alternative to the first — which
  is what the doctor check originally asserted, so it PASSed a host whose reviewer could not
  start. It now FAILs that host and names bubblewrap. Refusing in the adapter costs a
  `command -v` instead of a paid round, and reports the missing package rather than "the
  envelope has moved"; the reason goes into the round's `detail` so it is not
  `exit 1, no output`. Still never unconfined, on any host.

  **A second refusal sits above that predicate and is about a coreutil: no `tee`, no round**
  (2026-08-31). It is there because a missing `tee` is the one dependency this adapter would
  *misdiagnose*: the CLI runs through `| tee "$stream"` and `jq` parses the file, so without
  it the pipe fails, `$stream` is empty, the init line reads as absent, and the tripwire
  reports the vendor's stream envelope as having changed — sending someone to re-measure a
  CLI that is behaving perfectly. `PR_DOCTOR_UTILS` lists `tee`, but that list never reaches
  a round (`pr_doctor_preflight` does not call `pr_doctor_check_utils`) and is machine-wide,
  so on its own it both misses the round and fails a codex-only roster for a util that roster
  never uses. Same depth as `lib/lock.sh` checking `flock` at the lock site; the
  `PR_DOCTOR_UTILS` row stays, as the report rather than the guard. Above the confinement
  predicate, so it costs one builtin instead of refusing after the credential copy, the
  private TMPDIR and the sandbox setup are all paid for — and so neither half can reach the
  pipe without one.

  **`pr_doctor_preflight`'s `claude` arm checks it too, and that copy is the one that saves
  something.** The adapter's refusal is correct but late: it fires after `pr_sandbox_refresh`
  has copied the repo and, under R1, after the reviewer has forfeited its resume handle — the
  exact price that arm's credential check already exists to avoid, in its own words. Preflight
  is roster-scoped and per-adapter, so unlike `PR_DOCTOR_UTILS` it costs a codex-only roster
  nothing. Two copies is `PR_TIMEOUT_SECS`'s rule, for `PR_TIMEOUT_SECS`'s reasons: adapters
  are standalone, and `PR_SKIP_PREFLIGHT=1` can skip the early one. `tee` is the only util
  that earns a per-adapter arm, and the reason is worth keeping: every other external a round
  reads through — `jq` above all — is spent long before an adapter is spawned, so a host
  missing one never reaches a reviewer at all. `tee` is spent nowhere but `adapters/claude.sh`.

  The adapter's predicate is `uname -s` where the doctor's is `$OSTYPE`, and that is the
  one deliberate difference between them: `$OSTYPE` is fixed when bash is compiled and no
  environment can override it in a subprocess, so spelling it that way in the adapter would
  make every builtin-half case in `tests/test-adapter-claude.sh` unrunnable on the Linux
  hosts they were written on. The doctor cannot fork (builtins only, so its tests can point
  `PATH` at a stub directory alone). They agree on every real host; move both or neither.

  Four things about that half, all measured 2026-08-30
  (`docs/process/probes/2026-08-30-claude-macos-row1`, `-row5`, `-row67`), and each one
  changed the code:

  - **The built-in sandbox confines Bash tool calls ONLY — not the CLI's own process.**
    With `permissions.allow: ["Write"]` the Write tool wrote `$HOME`, outside
    `filesystem.allowWrite`, and the file landed on the host. So `permissionMode: default`
    is load-bearing rather than incidental: denying the unsandboxed Write and Edit is what
    keeps those writes in the workspace. **Never put Write or Edit in a `permissions.allow`
    there.** `NOTES.md`'s "its built-in sandbox enforces the same write barrier bwrap gives
    us" is wrong in exactly this way — bwrap contains the process, this contains its
    children.
  - **The repo under review reopens the sandbox from the other side, and `--settings` does
    not outrank it.** A repo `.claude/settings.json` with `sandbox.enabled: false` let a
    Bash call write `$HOME` with our settings saying the opposite; `--safe-mode` did not
    stop it, that flag stops repo *hooks*. Remedy is `agent.sh`'s: `rm -rf "$workdir/.claude"`,
    builtin half only. The probe fired four keys at once and did not separate them, and did
    not fire `.claude/settings.local.json` or a repo-root `.mcp.json` — parked in `BACKLOG.md`.
  - **`failIfUnavailable` does NOT refuse to start on Darwin.** Row 5 made Seatbelt
    unavailable by nesting (an outer `sandbox-exec (allow default)` refuses the inner
    `sandbox_apply`) and the CLI started anyway, denied every Bash call with
    `Exit code 71 / sandbox-exec: sandbox_apply: Operation not permitted`, and ended
    `subtype: success`, `is_error: false`, `permission_denials: []` with a non-empty review.
    It fails **safe** — nothing ran unsandboxed — but not **closed**. The refuse-to-start
    path A7 measured on Linux has never been seen on a Mac. **What makes this half safe to
    ship is the tripwire below, not `failIfUnavailable`**, and that reverses the weighting
    the rewire spec gave the two.
  - **macOS credentials come out of the login Keychain**, under its own 5s `timeout`, because
    `~/.claude/.credentials.json` does not exist there and a *locked* keychain BLOCKS the read
    rather than failing it — charged to `PR_TIMEOUT_SECS` it reads as "the reviewer timed out",
    a wrong diagnosis of a login problem. They are **copied**, not bound; there is no bwrap to
    bind with, so this is a second credential at rest exactly as codex's `auth.json` is, and the
    item carries `organizationUuid` and a live `mcpOAuth` token per authenticated MCP server.
    `.claude.json` is **synthesized** (`{"hasCompletedOnboarding":true}`), not copied from the
    operator's — the smallest file that satisfies a headless run, measured.

  **A reviewer that ran no command is refused, on BOTH halves.** Four measured routes end in a
  confident, empty, `status: ok` round with a real session id and model — C1 (the `$TMPDIR`
  socket ceiling), C3 (starts, denies everything), C6 (Linux: needs an approval headless cannot
  grant), D3 (Darwin: the command runs and the kernel denies the write). Three of the four are
  Linux's, which is why the assertion is not conditioned on the platform. It counts Bash
  `tool_use` ids whose `tool_result` is not an error, and quotes the first failing result into
  the round's `detail` — without that excerpt an unsandboxable host reads as a lazy reviewer.
  Accepted cost, stated: a review that legitimately needed no command fails its reviewer too.

  `claude` additionally rebuilds the environment from a
  whitelist (the orchestrator's `CLAUDE_*` messaging socket is a channel out of the jail)
  and runs `--safe-mode`. Neither is relaxed on the builtin half: the scrub was never bwrap's
  work.
  `adapters/agent.sh` is the exception and is deliberately **not** fail-closed: its bwrap
  supplies the pid namespace and nothing else (`/` is bound read-write on purpose — and
  Cursor's own sandbox still reports `native`/`fully_enforced` and still denies the `$HOME`
  canary when the adapter runs on a host where the wrap gate passes — the two coexist, which
  is weaker than "Landlock nests" and is all the transcripts witness, since the gate is a
  silent trial and the probe command echoed nothing naming its namespace), so
  where the jail does not *work* it runs unwrapped and the kernel's sweep is the bound,
  exactly as `docs/adapter-contract.md`'s containment clause says — and that gate is a
  trial run of the flags, not `command -v`, because a host with bwrap installed and its
  userns denied would otherwise lose the reviewer outright. Both fail-closed adapters also
  keep a **private state directory** beside the repo copy — as does `adapters/agent.sh`,
  at `<sandbox>/cursor-config`, which is the cheapest of the four because an *empty*
  `CURSOR_CONFIG_DIR` is still authenticated: no credential is copied or bound in, and the
  operator's `~/.cursor` hooks, plugins, rules and skills fall out of scope for free.
  It stopped being **partial** on 2026-08-31, and what completed it was a
  second variable rather than a second directory: the variable moves a config file, not a
  home, so `~/.cursor/sandbox.json` was still read — an `additionalReadwritePaths` grant
  there widened the reviewer's jail to the operator's home with the private directory in
  force, the `approvalMode: "unrestricted"` failure mode one file over (measured 2026-08-31,
  `docs/process/probes/2026-08-31-cursor-write-barrier-gaps/`). Nothing *in band* fixes it:
  path lists are unioned across sources so no file the adapter writes can subtract one, and
  `XDG_CONFIG_HOME` moves `cli-config.json` without moving this.

  **A private `HOME` closes both, and it ships; the cost is measured and accepted**
  (2026-08-31, `docs/process/probes/2026-09-01-cursor-private-home/` — four paid rounds,
  `agent 2026.08.25-3e8eec8`, `composer-2.5`, Linux). The claim that `HOME` relocation breaks
  Cursor's authentication is **wrong** and was written into three files here before it was
  checked: the credential is at `~/.config/cursor/auth.json`, XDG-anchored rather than under
  `~/.cursor`, so moving `HOME` merely drags `XDG_CONFIG_HOME` to an empty `.config`. The
  adapter therefore pins `XDG_CONFIG_HOME` off the **real** home and *then* exports
  `HOME="$(dirname "$workdir")/cursor-home"`. **The order of those two lines is the whole
  mechanism** — reverse them and XDG resolves under the empty private home, the round reports
  `Not logged in`, and someone concludes for the second time that a private `HOME` costs the
  credential. Two cases in `tests/test-adapter-agent.sh` hold the two halves and they are
  **not** interchangeable — the ordering guard is
  `test_an_unset_xdg_config_home_is_pinned_before_the_home_moves`, which fails if and only if
  the exports are reversed (verified by swapping them in a scratch copy: `26 run, 1 failed`,
  that case alone), while `test_the_adapter_runs_cursor_under_a_private_home` is the *custom*
  `XDG_CONFIG_HOME` coverage and **passes under either order**. Delete the first as "the
  redundant one" and the mechanism goes unguarded. That custom case is also the only coverage
  of its half at all: the probe host had the variable unset, so only the default branch of the
  expansion ran live. What the probe measured — through `agent -p` **directly**, never through
  this adapter, because the adapter deletes `<workdir>/.cursor` and so cannot be the instrument
  for a question about what a `.cursor` path does; the confining configuration was reproduced
  by hand, byte-for-byte: a positive control escaped to an isolated target, the identical
  grant went inert under the relocation with the kernel itself denying the write, the round still
  authenticated with **nothing copied** — so Cursor is still not a credential at rest, and the
  adapter keeps its one real advantage over the other three — and two rounds proved resume
  carries context across it, judged on a reproduced token because `agent --resume` returns
  rc=0 for a UUID that was never a chat id. Per-project state moved with the policy, which is
  more than the brief asked for: `~/.cursor/projects/<slug>/` — `.workspace-trusted` plus the
  full transcript of every round — now lands under the private home, and after four rounds the
  operator's real `projects/` held no entry naming any path the probe used (argued from the
  slug, not from mtime). The cost, **recorded rather than gated**: the reviewer runs without
  the operator's `HOME`-anchored tool configuration — no `~/.gitconfig`, so no git identity at
  all, and no `~/.ssh`. It is the only adapter here that moves a whole `HOME` (codex moves
  `CODEX_HOME`, agy binds one directory over `~/.gemini`, claude keeps `HOME` in its
  whitelist), and the probe states that cost as an **inference** from where those files live
  rather than a differential measurement — both of its legs ran with `HOME` already moved, so
  none of them ever showed the unmoved baseline. The remedy for a workflow that needs one of
  those files is not to start copying dotfiles in; that is a policy inventory of the
  operator's environment, maintained forever, one file at a time. Two things are still
  unmeasured. The transition round, exactly as codex's is: every round the runner starts mints
  and resumes inside the private home. And **every one of those four rounds was Linux** — on
  Darwin nothing here has been run, and the XDG anchoring of `auth.json` that the whole
  ordering rests on is an **assumption** there — not a measurement, and not a citation either:
  nothing under `docs/process/probes/` cites a vendor page for it. It is deliberately **not**
  gated on `$OSTYPE`, and the justification is narrower than it first read here. What a
  credential-less `agent -p` does is unmeasured — the only `Not logged in` anyone has seen came
  from `agent status` — so "the round fails loudly" is inferred from a different command. Both
  shapes are safe and they differ: the CLI writes nothing and the adapter exits 1, **or** it
  prints its refusal on stdout and the round publishes that as `status: ok` /
  `UNPARSEABLE`, since `[[ -s "$review_out" ]]` is the whole publication gate and
  `lib/reviewer-runner.sh` accepts `UNPARSEABLE` on an `ok` reviewer. **Neither is a silent
  widening** — the two exports run before the CLI starts on every platform, so wherever a Mac
  keeps its credential the per-user policy is already out of scope — and that, not the exit
  code, is what decides the gate. Gating would ship a second confinement path nobody has
  measured either. `BACKLOG.md` carries the reopen trigger.
  `<sandbox>/config` for claude,
  `<sandbox>/gemini-state` for agy — with the one auth file each needs bound in read-only
  *by path*. Only agy's is a mount over the real location: it is bound at `~/.gemini`
  because agy cannot be told to look elsewhere, while claude's is bound at its own path
  and named by `CLAUDE_CONFIG_DIR`. Neither operator directory is ever a bind **source**:
  both CLIs run hooks out of `~/.claude` and `~/.gemini` in the operator's own later
  sessions, which is what makes a writable bind of one a persistence channel out of the
  jail. agy's file list came from a measurement, not a guess — the obvious-looking
  `oauth_creds.json` is the wrong answer
  (`docs/process/probes/2026-08-27-pid-namespace-adapters/`, leg 3). agy's mount is also
  why `adapters/agy.sh` `mkdir -p`s `~/.gemini` before building the jail: bwrap makes a
  missing bind destination with `mkdir`, and under `--ro-bind / /` it cannot, so on a host
  that had never run agy the jail refused to start and the adapter blamed auto-denied tool
  permissions (bubblewrap 0.9.0). Neither the doctor's jail probe nor preflight sees that —
  both bind a `$TMPDIR` directory they created first.

  **codex has the third private directory, and it is not a bind at all**:
  `$(dirname "$workdir")/codex-home`, exported as `CODEX_HOME`, sited beside the repo
  copy for the same reason claude's is — the rollouts `codex exec resume` needs must
  survive `pr_sandbox_refresh`'s per-round wipe of `<sandbox>/repo`. codex confines its
  own writes, so this is an *ambient-state* change, not a sandbox one: the `-c` overrides
  already outranked every config file and still do. It moves codex's **user** layer only;
  managed/MDM, enterprise-requirements, session-flag, plugin and **project** layers stay
  in scope, and nothing here detects a conflicting managed layer. `auth.json` is **copied
  in** rather than bound, because the reviewer needs it writable and must never write the
  operator's — a second credential at rest, and the stated remedy for staleness is
  deleting it. `_pr_doctor_smoke_one` removes that copy, by path, from a smoke directory it
  keeps for diagnosis: the smoke's session key is `doctor-smoke.$$`, nothing ever cleans a
  kept one, and the smoke fails most often while codex auth is what is being debugged. The adapter seeds no `config.toml`; codex writes one itself recording the
  workdir's trust level, which is why the Q8 diagnostics now name *that* file and no
  longer name `~/.codex`. codex also passes `-c features.hooks=false`: the repository
  under review can ship a `.codex/hooks.json` and codex was measured reading it, while
  handlers from an untrusted source were measured **not** executing at 0.150.1. *Why*
  they did not is inference, not measurement — on the binary's own evidence a per-source
  `trusted_hash` written by an interactive TUI review is the gate, and a headless `exec`
  cannot reach it; trusting a hook and re-running was never attempted, so the
  once-trusted path is unproven in both directions. The flag's comment carries that same
  hedge and claims no sentinel it never saw fire
  (`docs/process/probes/2026-08-27-codex-private-home/`).
