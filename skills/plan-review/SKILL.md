---
name: plan-review
description: Use when the user wants a Markdown plan critically reviewed by multiple agent CLIs and the feedback integrated - runs rounds of independent CLI review, verifies their claims against the repo, and writes per-reviewer rationale
---

# Plan Review Loop

Runs a plan past independent reviewer CLIs, then integrates their feedback critically.
You are the **Integrator**: you decide what is true and what gets accepted. The
reviewers are inputs, not authorities.

**If you are a reviewer, stop here.** This skill is installed globally into the same
harnesses the reviewers run in, so it is visible from inside a review. A reviewer's
instructions arrive on stdin and say so; if that is what you were given, ignore this
file and write the review. It is addressed only to the Integrator.

**Announce at start:** "Using the plan-review skill. Starting round N."

## Before the first round

Confirm you have: the target repo root, the plan's repo-relative path. Derive nothing
else from the user — everything else comes from the repo.

Two things are yours to set once, and they apply to every command below:

```bash
if [[ -n "${PR_HOME:-}" ]]; then PR="$PR_HOME/bin/plan-review"
else PR="$(command -v plan-review 2>/dev/null || true)"; fi
[[ -x "$PR" ]] || {
  echo 'plan-review runner not found. Set PR_HOME to a plan-review checkout, or run' >&2
  echo '/path/to/plan-review/bin/plan-review install, then retry.' >&2
  exit 2; }

export PR_ORCHESTRATOR=<codex|agent|agy|claude> # the CLI YOU are running as
```

`PR_HOME` wins over `PATH`, so a development checkout can be chosen on a machine that
already has one installed. If neither finds the runner, **stop and tell the user**. Do
not clone the repository and do not install anything: writing into someone's `PATH`
unasked is not yours to do, and a round improvised without the runner produces something
that looks like a review and is not one.

`PR_ORCHESTRATOR` names **your own** CLI, never a reviewer's. It has no default and
both commands below refuse to run without it. `agent` is Cursor, `agy` is Antigravity,
`claude` is Claude Code, `codex` is Codex. If you are unsure which of these you are,
ask the user rather than guessing — the whole roster is derived from this answer.

**Then look for a project config before you export anything:**

```bash
ls <repo>/.plan-review/config.json
```

If there is none, there is a command that writes one — **suggest it, do not run it**:

```bash
PR_ORCHESTRATOR=<yours> "$PR" init --repo <repo> [--pin agy=<id>] [--pin agent=<id>]
```

It writes into the user's repository and edits their tracked `.gitignore`, which is theirs to
decide. Give them the command, say that it configures the reviewers that are installed and
leaves the doctor green, and carry on with pins of your own if they would rather not.

If it exists, **do not export the pins it already sets** — an exported `PR_*_MODEL` or
`PR_*_EFFORT` overrides the config every time, so exporting out of habit makes the
project's own settings dead. Read what it resolves to instead:

```bash
"$PR" doctor --repo <repo> --show-config
```

That prints the roster, the pins, the criteria files and where each value came from
(`config`, `preset:<name>`, `env`), runs no checks, costs nothing and writes nothing.
Export a pin only to override the config deliberately, and say so to the user when you
do. With no config, set the pins yourself as below.

Then run the doctor once:

```bash
"$PR" doctor --repo <repo> --plan <rel-path>
```

It costs nothing and takes seconds. It checks the dependencies, that the reviewer CLIs in
*this round's* roster are authenticated, that the pins name models that actually exist,
that the project config parses, that `.plan-review/` is gitignored in the target repo, and
whether an unfinished round is blocking the next one. A CLI that is not reviewing is
reported as `SKIP`.

- A **FAIL** is a round that would not work. Fix it or drop that reviewer from the roster
  before starting; do not start a round hoping it resolves itself.
- A **WARN** about version drift means a reviewer CLI has moved since its adapter was
  verified. Report it to the user. It is not a reason to stop, but if a round then aborts
  with a sandbox-header error, that warning was the cause.
- `.plan-review/` not gitignored is a FAIL with the fix printed. Apply it and say so.
- If the doctor is green but a reviewer still dies at round time with nothing useful in
  its log, run `"$PR" doctor --smoke` once: it sends each reviewer one trivial prompt
  through its adapter, which catches a CLI that authenticates fine but hangs or fails on
  the exec path. It is the one doctor check that **spends tokens**, so ask the user
  before running it.

## The roster

Four adapters ship — `codex`, `agent`, `agy`, `claude`. Who reviews is decided in this
order: `PR_ADAPTER_MAP`, then the project config's `reviewers` list, then **all of them
except yours**. You do not assemble the last of those; set `PR_ORCHESTRATOR` and the
runner derives it. If a user asks why one particular CLI is not reviewing and there is no
config, the answer is that it is the one reading this.

A config's list is obeyed exactly, **including one that names your own CLI**. That is not
refused any more: the old check compared CLI names, while independence is lost on model
identity, and nothing here can learn which model is orchestrating. Do not work around such
a list; report it to the user with the point below.

Three things to watch that the runner cannot check for you:

- **Your own model.** If a reviewer runs the same model you are running, the user paid
  twice for one perspective. Say so and recommend a different pin.
- **Model families, not CLI names.** Cursor pinned to a `claude-opus-*` id in a roster
  that also contains `claude` is two prices for one perspective. Pin Cursor to a
  different family in that case. After a round, two reviewers whose recorded models are
  the exact same string produce a warning in `round.json`; report it.
- **Cost, when `claude` is a reviewer.** Claude Code hands a reviewer its full tool
  surface, including subagents. The jail confines writes, the environment scrub closes
  the messaging channel, and `--unshare-pid` means a background process the reviewer
  spawns dies with the round — but none of them bounds spend. `PR_TIMEOUT_SECS`
  (default 900) is the only thing that does.

## Running a round

With a project config, the pins are already in it:

```bash
"$PR" round --repo <repo> --plan <rel-path> [--preset <name>]
```

Without one, set the pins yourself:

```bash
PR_CODEX_EFFORT=<none|minimal|low|medium|high|xhigh|max> \
PR_AGENT_MODEL=<an id from `agent --list-models`> \
PR_AGY_MODEL=<an id from `agy models`> \
  "$PR" round --repo <repo> --plan <rel-path>
```

Set only the pins for reviewers actually in your roster. `--preset` selects one of the
config's presets; `PR_PRESET` is the same thing, and setting both to *different* names is
refused rather than silently resolved.

`PR_AGENT_MODEL` and `PR_AGY_MODEL` are required whenever Cursor or agy is reviewing —
neither CLI reports which model answered, so without a pin the round could not record
what reviewed the plan. Their ids already include the effort tier
(`claude-opus-5-thinking-high`, `gemini-3.1-pro-high`); there is no separate effort
setting for them. codex has `PR_CODEX_EFFORT` and claude has `PR_CLAUDE_EFFORT`, and
both of those CLIs report their own effective model, so their pins are optional.

Keep every pin identical across the rounds of one plan. Changing a model or effort
mid-loop makes the rounds incomparable, and resumed sessions carry context produced at
the old setting. If the user asks to change one, say that it resets comparability and
recommend `--fresh` alongside it.

Add `--fresh` when the plan has changed enough that reviewer memory is a liability, or
when your own context was compacted or summarised since the last round (see "After a
context reset"). It drops the resume handles *and* omits the diff, the previous critique
and the rationale from the prompt, so reviewers see the plan as it now stands. Numbering
carries on and nothing is deleted.

Pass the round directory to the completion command as an **absolute** path; it rejects
relative paths, which would resolve against the wrong working directory.

The runner blocks. While it runs you may poll progress:

```bash
cat <repo>/.plan-review/<key>/round-N/status.jsonl | jq -r '"\(.reviewer): \(.state)"'
```

## After the round

1. **Read every review in full.** Do not summarise them to yourself first — a digest
   cannot be verified.

2. **Verify factual claims against the real repo**, not against the sandbox copies and
   not against the plan. When a reviewer says "X is at file:line", open it. Reviewers
   assert wrong things confidently; this step is the point of the loop.

3. **Surface contradictions to the user.** When two reviewers recommend incompatible
   directions, present both with your recommendation and wait. Never pick silently.

4. **Ask the user about anything genuinely ambiguous** — mid-integration is the right
   time, not after.

5. **Edit the plan** with what you accepted.

6. **Write one rationale document per reviewer**, at
   `<repo>/.plan-review/<key>/round-N/rationale-<reviewer>.md`. For each point that
   reviewer raised: accepted / rejected / deferred, and why. Where you rejected a
   factual claim, state what you checked and what you found. Write only that
   reviewer's points in its file — never mention what another reviewer said.

7. **Mark the round complete.** Use the command; it takes an absolute round
   directory and refuses to complete a round whose successful reviewers have no
   rationale, so a skipped step 6 fails loudly instead of silently.

```bash
"$PR" complete --round <repo>/.plan-review/<key>/round-N
```

   Until this succeeds the runner will refuse to start round N+1.

8. **Report verdicts to the user** and ask whether to run another round. Never decide
   this yourself — reviewers drift agreeable across rounds, so converging verdicts are
   not a reliable stop signal.

If a verdict reads `UNPARSEABLE`, say so explicitly. Do not guess what the reviewer
meant.

## Failure handling

- One or two reviewers failed: integrate the rest, tell the user which failed and why.
- All failed: the runner exits 1 and preserves the round directory. Report the status
  file contents; do not retry blindly. The round is left in state `aborted`, so once the
  cause is fixed the retry **must** carry `--fresh` — the runner refuses a round whose
  predecessor is `aborted` with exit 2 and a message naming the flag. Nothing was lost by
  that: every reviewer failed, so every handle was already forfeited; `--fresh`
  additionally leaves the diff and the earlier critique out of the prompt.
- The runner refuses with `PR_ORCHESTRATOR is unset`: you did not name your own CLI. Fix
  the variable; do not work around it with `PR_ADAPTER_MAP`.
- The runner says a review of this plan **is already running**: another round holds the
  session. Wait for it. Do not start a second one, and never delete `.lock` — unlinking
  it releases nothing and lets both rounds write into the same directory.
- The runner says a previous round **is in state 'reviewing' and nothing is running**:
  its runner died without finishing. Show the user the round directory, and run the
  command the message prints once they agree:

  ```bash
  "$PR" abort --round <repo>/.plan-review/<key>/round-N
  ```

  It deletes nothing; the round stays readable. If `abort` refuses because the session is
  locked, reviewers spawned by the dead runner are still writing — report that and wait
  rather than forcing anything. If instead it refuses with exit 2 and the sentence `the
  artifact store refuses writes: <dir>`, the round **directory** is unwritable and this is
  the store-loss case two bullets down — `abort` cannot succeed until that is fixed, so do
  not loop on it. That preflight tests permissions only, so it does not cover a full disk:
  there the directory is writable and `abort` dies mid-write instead, naming a
  `.round.json.<pid>.tmp` file. Match on the `.tmp` filename and treat it as the same
  store-loss case.
- The runner exits 2 with a message ending in `aborting` that names something it could
  not write (`round.json`, a result record, the session map): the artifact store itself
  is gone — a full disk or an unwritable `.plan-review/` — not a reviewer problem. The
  round stopped mid-way and its artifacts are incomplete by definition, so do not read
  verdicts out of them and do not retry until the user has fixed the disk or the
  permissions. Report the message verbatim. The round directory stays, but it stays in
  state `reviewing`: `abort` writes `round.json` through the same directory that just
  refused a write, so **when the directory is unwritable** it refuses rather than trying:
  exit 2 and the one sentence `the artifact store refuses writes: <dir>; retry after
  restoring store writes`. That preflight is a permission test and nothing more — on a
  full disk the directory is writable, so `abort` runs into the write and dies with the
  raw error itself. Raw write errors therefore come from either command: a
  `.round.json.<pid>.tmp` file, `Permission denied` when the directory is unwritable,
  `No space left on device` when the disk is full; match those on the `.tmp` filename,
  not on either message. Do
  not run `abort` until the store is writable again — which is also the only point at
  which it is worth running. When the user is ready to run again, run the next round with
  `--fresh`: the runner refuses a round whose predecessor is `aborted` without it, exiting
  2 with a message naming the flag. The reason is unchanged — the serial pass stopped
  part-way, so reviewers it never reached still hold last round's resume handles,
  including ones this round would have thrown away — but a forgotten flag is now a
  refusal to relay, not a silent unsafe resume.
- A reviewer's `detail` reads `reviewer result record missing` or `record invalid`: that
  reviewer's job died without leaving a readable record, and the runner synthesized a
  failed entry so `round.json` still lists it. Treat it as a failed reviewer — there is
  no review to integrate — and mention it, because it means something killed the job
  rather than the reviewer declining.
- The runner exits 2 naming a key in `config.json`: the project config is invalid and no
  round was started. Show the user the message — it names the offending key — and fix the
  config or ask them to. Do not route around it with `PR_SKIP_CONFIG=1`.
- A round warns that the configuration changed since the last one: the pins, roster or
  criteria moved mid-loop, and resumed sessions still carry context built under the old
  settings. Report it and recommend `--fresh`.
- The runner aborts with a sandbox-header error: a CLI default changed. Stop and tell
  the user to re-run the verification probes in the brainstorm doc.
- `agy` or `claude` fails with a `bwrap` error: that is the adapter refusing to run a
  reviewer whose CLI does not confine its own writes. This is correct behaviour, not a
  bug. Report it and continue with the other reviewers; do not work around it by editing
  the adapter. On a Mac that refusal is `agy`'s every time, and it is **measured, not an
  unexplored gap**: three routes to confining `agy` there are closed
  (`docs/process/probes/2026-09-01-agy-macos-routes/NOTES.md`). The operator accepted the
  fourth — the exposure — on 2026-09-02, but **nothing has been built**, so the refusal is
  still correct and still the right thing to report. Do not offer to "just" relax it: what
  the decision needs is an engine and an explicit opt-in, not a deleted guard. `agent` never fails this
  way — its bubblewrap supplies only a pid namespace, not a write barrier, so with no
  working `bwrap` it runs unwrapped by design.
  The doctor warns for that case rather than failing; report the warning, and do not
  treat it as a reason to drop the reviewer.
- The doctor's jail check now says "bwrap jail **contains** a detached process". It
  measures containment, not whether the flags were accepted, so a failure there means a
  reviewer could leave a process running after the round returns — not merely that a
  flag was rejected. Report the doctor's own diagnosis verbatim.
- **`agy` no longer sees the user's real `~/.gemini`.** It runs against a private state
  directory beside the disposable repo copy, with one auth file bound in read-only. If a
  user asks why agy cannot see a conversation from their own interactive session, that is
  why, and it is deliberate: a writable bind of their state directory would be a
  persistence channel out of the jail. Round-to-round resume is unaffected — the session
  map carries the handles. That holds wherever `agy` reviews at all, which is Linux only:
  the private directory is a bind, and macOS has nothing to bind with — which is why `agy`
  is not on the macOS roster rather than being on it without one.
- **`codex` no longer reads the user's `~/.codex` either.** It runs under a private
  `CODEX_HOME` beside the disposable repo copy, holding a copy of `auth.json` and nothing
  else the operator put there. This closes a real failure: an obsolete field in the
  user's own `config.toml` failed codex's `--strict-config` and the reviewer never
  started. Two things to say when it comes up. First, the copied `auth.json` goes stale
  when the user re-authenticates — the fix is deleting `<sandbox>/codex-home/auth.json`,
  and the next round copies a fresh one in. Second, if codex still refuses to start with
  a config error, the file to look in is `<sandbox>/codex-home/config.toml`, which codex
  writes itself; the adapter's own message names it. Their `~/.codex` is not the cause
  any more, and telling them to edit it would waste their time.
- **`agent` failing on the first round after the private config home landed: cause
  unverified.** Cursor's config home moved to `<sandbox>/cursor-config` the same way
  codex's did, but unlike codex nobody could measure whether a handle minted before the
  move still resumes: `--resume` returns rc=0 even for an id that was never a chat, so
  the exit status settles nothing (measured 2026-08-28). If `agent` reports "exited N
  without writing a review", read the log first — it names the causes that *are*
  established, authentication and the model pin. `--fresh` is worth one try if a stored
  handle was in play, but say what it costs: it drops every other reviewer's handle and
  the history baseline too.
- **A plan that was mid-loop when the private home landed loses one codex round.** Its
  stored handle names a rollout in the user's `~/.codex/sessions/`, which the private home
  does not have, so the resume fails before the banner and codex is recorded as failed for
  that round. Say what it is rather than debugging it: the handle is dropped by that
  failure and the next round starts codex cold, so running again is the whole fix.
  `--fresh` skips the wasted round if the user would rather not spend it, but say what it
  costs: it drops EVERY reviewer's handle and the history baseline, not just codex's, so
  spending the one wasted round is usually cheaper. This happens once per plan, never again.
- **Repo-supplied codex hooks are off for reviews** (`-c features.hooks=false`). A
  repository can ship a `.codex/hooks.json` and codex was measured reading the one in the
  workspace under review. Handlers from an untrusted source were measured *not* executing
  at codex-cli 0.150.1 — codex *appears to gate* them behind an interactive trust review a
  headless run cannot reach — so do not describe this to a user as a closed exploit. The
  non-execution was measured; the gate is inferred from the binary's own strings and the
  once-trusted path was never attempted. It closes a read, ahead of an execution path that
  is codex's to open.
- **The repository's `.agents/` is deleted from agy's sandbox copy** before the review
  (`rm -rf <workdir>/.agents`), and this one is not a precaution: a `.agents/hooks.json`
  shipped by the repository under review was measured *executing* an arbitrary command,
  in the adapter's own invocation shape and with nothing about it on agy's JSON
  transcript (agy 1.1.22, Linux, 2026-09-01). Unlike the codex bullet above, describing
  this as a closed execution path is fair. Two caveats to pass on: the deletion is
  wider than the measurement — `.agents/` also holds custom agents and other workspace
  customisation nobody tested — and it hits the **disposable per-round copy**, never the
  user's checkout, which is the question they will actually ask.
- A reviewer's recorded model reads `<something> (requested: <pin>)`: the CLI swapped the
  model out mid-run and the adapter caught it. The pin did not answer. Say so when
  reporting verdicts — that round is not comparable to one run on the pinned model.

## After a context reset

Rounds continue in-conversation using what you remember. If your context was compacted,
summarised or otherwise truncated since the last round, that memory is unreliable:
**re-read the previous round directory from disk before writing any rationale**, or
start over with `--fresh`. Say which you did.

## Round ceiling

At round 4 and beyond, ask the user to confirm before running. Three rounds is the
soft ceiling.
