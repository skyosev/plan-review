# Reviewer feature matrix

What each of the four reviewer CLIs offers *in the shape this app runs it*, and which
of those features `plan-review` actually depends on. It is a companion to
`docs/adapter-contract.md`, which says what an adapter must do; this says what the
CLIs make possible.

**Scope, stated once so no row is read wider than it is.** Every claim here is about
the invocation the shipped adapter builds — `codex exec --output-last-message`,
`agent -p --output-format text`, `agy -p --output-format json`,
`claude -p --output-format stream-json --verbose`. A CLI may well offer a feature in
some other mode; unless a row says otherwise, nobody here has run that mode, and a
capability nobody ran is not a capability this repo knows about.

Versions the rows were measured at are the pins in `docs/verified-versions.txt`:
`codex 0.150.1`, `agent 2026.08.25-3e8eec8`, `agy 1.1.22`, `claude 2.1.251` — with one
row excepted. §3's "the CLI's own `--sandbox` was measured inert" predates the pin and
`docs/verified-versions.txt` disclaims it in as many words: the early probes established
what that flag does not confine but **never recorded the version they ran against**, so
that cell is not "measured at 1.1.22" and nothing here should be read as saying it is.
It is also the one row nothing rests on — the jail `adapters/agy.sh` builds is what
confines agy, not the flag.

## How to read the marks

| Mark | Meaning |
| --- | --- |
| **used** | The adapter depends on it. If the CLI changes it, rounds break — that is what the version pins are for. |
| **offered** | The CLI provides it in the format we run, and nothing here reads it. Available for the taking; not a promise it stays. |
| **absent** | Not present in the format the adapter runs. Says nothing about other formats. |
| **unmeasured** | Nobody has run it. Not "no" — no evidence either way, and it must not be cited as one. |

`plan-review` is a fan-out of independent one-shot reviews, so several features a
chat client cares about have no expression here at all. Those rows are `offered` or
`unmeasured` rather than missing, and the reasons are in the prose below.

---

## 1. Round mechanics

| | codex | agent (Cursor) | agy (Antigravity) | claude |
| --- | --- | --- | --- | --- |
| Resume a conversation by id | **used** — `exec resume <id>` | **used** — `--resume <id>` | **used** — `--conversation <id>` | **used** — `--resume <id>` |
| Where the id comes from | banner `session id:` | `agent create-chat`, minted before round 1 | envelope `.conversation_id` | result frame `.session_id` |
| Prompt on stdin | **used** — trailing `-` | **used** | **absent** — `-p` takes the prompt as an argv value | **used** |
| Effective model reported | **used** — banner `model:` | **absent** — pin is required, and a mid-run swap shows only as prose | **absent** — pin is required | **used** — `init` line, resolves aliases |
| Effective reasoning effort reported | **used** — banner `reasoning effort:`, and asserted against the pin | **absent** — folded into the model id | **absent** — folded into the model id | **absent** — `--effort` is a real axis and is reported nowhere |
| Version off the run's own output | **used** — banner | **absent** — read before the run | **absent** — read before the run | **used** — `init` line |
| Inner deadline the adapter can set | **absent** | partial — bounds `create-chat` only | **used** — `--print-timeout`, 90% of ours | **absent** |
| Review arrives as | file, `--output-last-message` | stdout | envelope `.response` | result frame `.result` |

## 2. Reporting and observability

Nothing in this column group reaches `round.json`. See §7.

| | codex | agent | agy | claude |
| --- | --- | --- | --- | --- |
| Tokens used | **offered** — `tokens used N` on the banner | **absent** | **offered** — `.usage` object | **offered** — `.usage` on the result frame |
| Prompt-cache counters | **unmeasured** | **unmeasured** | **offered** — `.usage.cache_read_tokens` | **offered** — `cache_read_input_tokens`, `cache_creation_input_tokens`, and a 5m/1h split |
| Cost | **unmeasured** | **absent** | **unmeasured** | **offered** — `total_cost_usd`, plus per-model `costUSD` |
| Context window size | **unmeasured** | **absent** | **unmeasured** | **offered** — `modelUsage[].contextWindow` |
| Context *remaining* | **absent** | **absent** | **absent** | **absent** |
| Turn count | **unmeasured** | **absent** | **offered** — `.num_turns` | **offered** — `.num_turns` |
| Wall-clock duration | **unmeasured** | **absent** | **offered** — `.duration_seconds` | **offered** — `.duration_api_ms` |
| Denied tool calls | **absent** | **absent** (a denial shows as exit 2) | **absent** | **used** — `.permission_denials`, surfaced as the round's `detail` |
| Per-tool-call visibility | **absent** | **absent** | **absent** | **used** — the stream's `tool_use` / `tool_result` pairs |
| Why the session ended | **absent** | **absent** | partial — `.status` / `.error` | **used** — `.terminal_reason`, echoed verbatim |
| Compaction | **unmeasured** | **unmeasured** | **unmeasured** | **unmeasured** |

## 3. Confinement and platform

| | codex | agent | agy | claude |
| --- | --- | --- | --- | --- |
| Write barrier | its own sandbox, `workspace-write` | Cursor's own sandbox, `--sandbox enabled` | **bubblewrap** — the CLI's own `--sandbox` was measured inert | bubblewrap **or** Claude Code's own sandbox, chosen per host |
| Barrier asserted, not assumed | **used** — refuses unless the banner names the expected sandbox | indirect — via the config it pins | n/a — the jail is ours | **used** — refuses unless `init` reports the expected `permissionMode` |
| Behaviour with no `bwrap` | unaffected | runs unwrapped; loses only the pid fence | **refuses to run** | Darwin: built-in sandbox. Anything else: **refuses to run** |
| Process containment | its own `--as-pid-1` (Linux) | `bwrap --unshare-pid`, behind a trial-run gate | `bwrap --unshare-pid` | `bwrap --unshare-pid` (bwrap half only) |
| Linux | **measured** | **measured** | **measured** | **measured** |
| macOS | **measured** | **measured**, minus the pid fence | **not shipped** — priced, not blocked; see §9 | **measured**, built-in half |
| Network | **used** — `network_access=true` | default-deny with a host allowlist | inherited (no `--unshare-net`) | inherited |

## 4. Isolation of the operator's environment

| | codex | agent | agy | claude |
| --- | --- | --- | --- | --- |
| Private state directory | `<sandbox>/codex-home` via `CODEX_HOME` | `<sandbox>/cursor-config` **and** a private `HOME` | `<sandbox>/gemini-state`, bound over `~/.gemini` | `<sandbox>/config` via `CLAUDE_CONFIG_DIR` |
| Mechanism | env var | env vars | bind mount | env var + bind |
| Credential cost | **copied** — `auth.json`, once | **none copied** — an empty config dir is already authenticated | ro-bound by path | ro-bound (bwrap) / **copied** (Darwin, incl. from the Keychain) |
| Repo-supplied config neutralised | `-c features.hooks=false` | `rm -rf <workdir>/.cursor` | `rm -rf <workdir>/.agents` | `rm -rf <workdir>/.claude` (built-in half only) |
| Environment rebuilt from a whitelist | no | no | no | **used** — `env -i`, seven variables |
| Survives the per-round repo wipe | yes — sibling of `<sandbox>/repo` | yes | yes | yes |

---

## 5. Restoring a conversation by id

All four support it and the app uses all four. `<meta_out>` line 1 is the handle, the
session map stores it per plan per reviewer, and the next round hands it back. Two
rules sit above the CLIs and apply to every one of them (**R1**, `lib/round.sh`): a
reviewer that timed out or failed forfeits its own handle, and an `aborted` round
forfeits every handle in it, so the next round refuses without `--fresh`.

The four differ in ways that cost real work:

- **codex** takes the id off its banner, and `exec resume` does **not** inherit the
  original session's sandbox — the adapter reasserts every `-c` flag on the resume
  branch. Rollouts live under `$CODEX_HOME/sessions/`, which is why that directory
  is a sibling of the repo copy rather than inside it.
- **Cursor** is the only one where the id is minted by a *separate command*.
  `agent create-chat` runs before round 1, and in a config directory that has not yet
  completed a `-p` run it prints the id and then never exits — so it runs under a
  derived `timeout`, and the adapter keeps the id it printed. `agent --resume` returns
  **rc=0 for a UUID that was never a chat id**, so nothing about resume can be judged
  on an exit code; both probes that establish carry-forward judge it on reproduced
  content instead.
- **agy** reads `.conversation_id` off the JSON envelope. State lives in the private
  `~/.gemini` bind, so history from other sessions is out of scope by construction —
  resume is per-session and the session map holds the handles.
- **claude** reads `.session_id` off the result frame.

**Unmeasured, in the same place for three of the four:** the *transition* round — what
a handle minted under the operator's real home does when the adapter moves that home
away. Every round the runner starts both mints and resumes inside the private
directory, so the case is reachable only once, on the upgrade. codex's is known to cost
one cold round (`no rollout found for thread id`, which R1 clears by itself); Cursor's
and claude's have no equivalent measurement.

## 6. Prompt caching

**No adapter requests, configures or reads a cache.** There is no flag here for it and
no field of it in `round.json`.

Two of the four report that the vendor cached anyway. claude's result frame carried
`cache_read_input_tokens: 72671` against `cache_creation_input_tokens: 26665` in a live
round (`docs/process/probes/2026-08-30-claude-macos-row1/artifacts/stream.json`), with
the creation split across 5-minute and 1-hour ephemeral buckets. agy's envelope carries
`.usage.cache_read_tokens`. codex and Cursor expose nothing of the kind in the formats
run here.

It is tempting to read resume as a caching strategy and it is not one. Resume exists so
round N+1 sees round N's context; whether that also produces a cache hit is plausible,
unmeasured, and would be the vendor's decision either way. Nothing in this repo would
notice if it stopped.

## 7. Context and token accounting

**Nothing here counts tokens, prices a round, or budgets a context window.** The data
is there for three of the four CLIs — codex prints `tokens used N` on the banner line
the adapter already parses for the session id; agy's envelope carries a five-field
`usage` object; claude's result frame carries `usage`, `modelUsage` (with each model's
`contextWindow` and `maxOutputTokens`), and `total_cost_usd`. The adapters read none of
it. `<meta_out>` is four lines by contract, and none of them is a number.

**Context *remaining* is reported by none of the four**, in any format run here. A
context window size is not a remaining budget: it would have to be differenced against
a running total the CLI does not publish per turn. Treat "context left" as unavailable
rather than unimplemented.

The one place token counts have ever been used is by hand:
`docs/process/probes/2026-08-28-acceptance-matrix/report.md` costs its 18 paid
operations off whatever each CLI reported, and says so where a CLI reported nothing.

## 8. Compaction

**Not used, not exposed, and unmeasured on all four.** Every round is one
non-interactive `-p` invocation; the app's carry-forward mechanism is resume, not
compaction, and no adapter passes a compaction flag or reads a compaction event.

Whether a CLI compacts *on its own* inside a long resumed session is the open question,
and it is genuinely open: a reviewer's round is several turns (claude's frames report
`num_turns: 6` for a round with tool calls), and rounds accumulate across a plan. If a
CLI silently compacted a resumed session, round N+1 would carry less of round N than
`round.json` implies, and nothing here would detect it. No probe has looked.

## 9. Platform restrictions

Read this section as the reason behind row `macOS` in §3.

- **codex** — both platforms, both measured. On Linux it contains its own tree; on
  Darwin it reaps its own descendants before its adapter exits (measured in two live
  rounds, `docs/process/probes/2026-08-29-macos-row3-sweep/`).
- **agent** — both platforms. macOS has no bubblewrap, so the pid fence is absent and
  the execution kernel's best-effort descendant sweep is the only bound; the write
  barrier is Cursor's own sandbox and is unaffected. Two caveats are Darwin-specific
  and both are recorded rather than gated: the private-`HOME` policy was measured on
  **Linux only**, and the XDG anchoring of Cursor's credential that makes the private
  home safe is an **assumption** on a Mac — not a measurement, and not a citation
  either.
- **agy** — **Linux only as shipped**, because its adapter fails closed without `bwrap`
  and macOS has none. Read that as a priced decision rather than a capability gap: it
  was measured, and the parts that port and the part that does not are different parts
  (`docs/process/probes/2026-08-30-claude-macos-row9-agy`, 2026-08-30, `agy 1.1.22`).

  The **write barrier ports.** A `sandbox-exec` Seatbelt profile supplied it — workdir
  wrote, the real `$HOME` and `/Users/Shared` were denied with the file absent on the
  host — and it held against a detached, TERM-ignoring grandchild, because a Seatbelt
  profile is inherited across fork and exec and cannot be dropped. The CLI ran and
  authenticated under it. So "run it unconfined on macOS" is not the choice on offer:
  there is a barrier, and running without one is what the contract refuses. That
  refusal is not squeamishness about a missing flag — agy's own `--sandbox` was
  measured allowing a write to `/tmp` while logging itself as enabled, and the adapter
  must pass `--dangerously-skip-permissions` or every headless tool call is auto-denied.
  Unconfined agy is an unattended agent with permissions skipped and write access to the
  operator's home, against a repository nobody here wrote.

  The **private state directory does not port**, and that is the whole cost. It is a
  bind over `~/.gemini`; there is no bind without bwrap, and the only remaining lever
  was measured failing — a private `HOME` did not authenticate empty, did not
  authenticate with the entire 24 MB `~/.gemini` copied into it, and did not
  authenticate with no sandbox in the picture at all. That third leg is the bisect: the
  failure is `HOME` relocation, not Seatbelt. The reason is visible in the surrounding
  evidence rather than proven by it — the auth file `adapters/agy.sh` ro-binds does not
  exist on that Mac, which authenticates out of the login Keychain the way `claude` does,
  so the Linux adapter's ro-bind is inert there via its own `[[ -f ]]` guard.

  What a macOS agy would therefore cost: the reviewer runs with the operator's real
  `~/.gemini` **writable**, and one hook file there — `config/hooks.json`, the only one
  tried — was measured **executing** an arbitrary command
  (`probes/2026-09-01-agy-hook-surface/`, leg B, agy 1.1.22, Linux), so whatever can
  write *that file* gets a command run in the operator's own later sessions. That is the
  persistence channel the Linux private directory closes and nothing on macOS closes
  today. The repository half of the surface is closed in the adapter
  **unconditionally** — it `rm -rf`s `<workdir>/.agents` on every host, because the same
  probe's leg A measured agy executing a command out of a hook file the repository under
  review shipped there, the counterpart of what the `agent` and `claude` adapters
  already do to `.cursor` and `.claude`. It is not platform-gated, so a macOS port
  inherits it — but no Mac reaches it **today**: the adapter refuses a host without
  `bwrap` many lines earlier, so there is no macOS round for the removal to run in. What
  is left named and **unmeasured** is narrowing the profile to deny the hook locations
  inside `~/.gemini` while allowing the paths agy needs.
- **claude** — both platforms, by **two different mechanisms** chosen once at a single
  `$confinement` variable. With `bwrap`: the jail,
  `--dangerously-skip-permissions`, an asserted `bypassPermissions`. On Darwin without
  it: Claude Code's own sandbox, `failIfUnavailable: true`, `permissionMode: default`.
  There is no third case — a **non-Darwin host with no `bwrap` is refused**, because
  Claude Code's own sandbox is *implemented with bubblewrap* on Linux, so the condition
  that selects the second mechanism is exactly the condition that breaks it.

Three properties of the built-in half are worth carrying here, because each of them
reverses something that reads as obvious:

- It confines the commands the Bash tool spawns, **not the CLI's own process** — which
  is why that half must run at `permissionMode: default`, where the unsandboxed Write
  and Edit tools are denied outright.
- The repository under review is a configuration surface that **outranks the flags we
  pass**, on both Cursor and claude — hence *their* two `rm -rf` cells in §4's
  "Repo-supplied config neutralised" row. That row now holds a third, agy's, and it
  rests on a different measurement: not a repo file outranking a flag, but a repo file
  the CLI simply **executed** (`probes/2026-09-01-agy-hook-surface/`, leg A). Three
  cells, two reasons.
- `failIfUnavailable` **does not refuse to start** on Darwin. With Seatbelt made
  unavailable the CLI started, denied every command, and ended `is_error: false` with a
  non-empty review. It fails safe, not closed. What makes that half shippable is the
  ran-a-command assertion below, not the flag.

## 10. The assertions that cost a reviewer its round

Not a capability of the CLIs so much as of the adapters, but it belongs in a feature
matrix because it decides whether a round is recorded at all.

| Assertion | Where | What it catches |
| --- | --- | --- |
| The sandbox is the expected one | codex | output produced under a sandbox we did not ask for |
| The effort is the one requested | codex | a silent backend-side downgrade recorded as the pin |
| The `init` line exists and names the expected mode | claude | the stream envelope moving, or a permission mode we did not ask for |
| At least one Bash tool call succeeded | claude | four measured routes to a confident, empty, `status: ok` review |
| The envelope carries a response | agy | the auto-deny signature, which exits 0 with an empty response |
| A model swap is recorded as `X (requested: Y)` | agent, claude | `round.json` naming a model that never answered |

The ran-a-command assertion has a stated cost rather than a hidden one: a review that
legitimately needed no command fails its reviewer too. That is the intended direction —
`lib/prompt.sh` tells every reviewer to run things, and a confident review that checked
nothing is worse than a missing one.

---

## Keeping this file honest

A row here is a claim about a CLI at a pinned version. When a pin moves in
`docs/verified-versions.txt`, the rows measured at the old one are the ones to re-read
— particularly every **used** row, since those are what a round breaks on. An
`unmeasured` row is never upgraded by reasoning about it; it is upgraded by a probe
under `docs/process/probes/`, and by nothing else.
