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
  arrive on stdout.
- **`<review_out>`** — the Markdown review, written by the adapter. Write to the
  path you are given and derive no other: the round hands adapters a scratch path
  and publishes a copy of it under its own name once the adapter has gone, so a
  survivor still writing cannot change the artifact the round recorded.
- **`<meta_out>`** — exactly four lines, any of which may be empty:

      line 1   session handle to resume next round ('' if the CLI reports none)
      line 2   effective model — what actually answered, not what was requested
      line 3   effective reasoning effort, or '' if the CLI has no separate axis
      line 4   CLI version

  The adapter reports the *effective* values because a pin the CLI silently
  ignored would make `round.json` claim a model that never ran (Q2, R11).

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
- **confinement is the adapter's job, and it is not uniform.** codex and Cursor
  confine their own writes via their sandbox flags. `agy` does not: its
  `--sandbox` was measured to allow a write to `/tmp` while reporting itself
  enabled, so its adapter wraps the CLI in `bubblewrap` instead and **fails
  closed** when `bwrap` is unavailable. `claude` exposes no sandbox flag to ask
  for, so it is confined the same way and fails closed the same way. An adapter
  that cannot confine writes must refuse to run, never run unconfined.
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
  the next round's copy. Isolating it also keeps the operator's own
  `~/.claude/settings.json` — which defines hooks that run in *their*
  interactive sessions — outside the reviewer's reach.
- **process group** — the runner invokes adapters under `timeout(1)`, which places
  each adapter in its own process group and signals the whole group. A descendant
  that leaves that group by taking one of its own is swept separately and
  best-effort, from a `ps` walk sampled while the adapter ran. Adapters do not need
  to reap their own children.
