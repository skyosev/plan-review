# CLAUDE.md

This file provides guidance to Claude Code  when working with code in this repository.

## What this is

Pure bash (no build step, no dependencies). `plan-review` sends a Markdown plan to
several agent CLIs for independent critique, in rounds, and keeps the artifacts under
`<target-repo>/.plan-review/`. `README.md` is the user-facing manual and is unusually
complete — read the relevant section before changing behaviour it documents.

## Commands

    make test                     # whole suite: bash tests/run-tests.sh
    bash tests/test-round.sh      # one file — that is the finest granularity
    PR_TEST_BASH32=1 bash tests/test-bootstrap.sh   # + the 3.2 refusal, in docker
    PR_ORCHESTRATOR=none make doctor
    PR_ORCHESTRATOR=none make doctor OFFLINE=1     # no auth/model-list calls
    bin/plan-review doctor --repo <dir> --show-config

The suite is offline and takes seconds: every test drives the runner with fake adapters
from `tests/fixtures/adapters/` via `PR_ADAPTER_MAP`, so nothing costs tokens. "Seconds"
is the loosest it has been: 51.6s at `d0d8177` (433 tests) against 62.3s at the kernel
branch (455 tests) — **+21%**, measured 2026-08-27, two back-to-back runs each on a clean
clone. Roughly half of that is the execution kernel's polled descendant sweep, which
costs every `pr_adapter_exec` a minimum 0.05s tick plus a `ps` fork: stripping the poll
loop runs 56.8s on the same 455, so the poll is ~5.5s and the remaining ~5.2s is simply
the 22 tests that branch added.

The 457/~62s figure that stood here was stale in its count but not in its clock. Measured
2026-08-27 on this host (32 cores, load ~0.5), two back-to-back `make test` runs per tree,
a `git worktree` per revision:

| tree | tests | run 1 | run 2 |
| --- | --- | --- | --- |
| `ea2b59e` (pre-`reviewer-isolation-hardening`) | 467 | 62.159s | 62.214s |
| + tasks 1–2 of that branch | 485 | 85.243s | 85.359s |
| + task 3 (`ps` caps, sweep deadline, GNU-`timeout` check) | 490 | 93.993s | 94.060s |

So ~62s was still exactly right for `main`, and the whole +31.8s is this branch's, not
host drift — worth knowing, because "the host got slower" was the first explanation
offered and it was wrong. Where it went, by per-file timing of both trees: **+20.5s in
`tests/test-bootstrap.sh`** (6.156s → 26.707s), a file this branch never edited. It drives
`plan-review doctor` as a subprocess ~20 times, and task 1 gave `_pr_doctor_bwrap_probe` a
real containment window that the pass path always waits out — ~1s per doctor run at the
default `PR_BWRAP_PROBE_TICKS=10`. `tests/test-doctor.sh` accounts for another +2.2s;
`tests/test-runner.sh` (29.5s, the single largest file) did not move at all.

Task 3's own +8.7s is **entirely** its three hang tests in `tests/test-adapter-exec.sh`
(3.028s → 11.560s): each deliberately stalls a stubbed `ps` and measures that the cap cuts
it short, at `PR_PS_CAP_SECS=1`, 1 and the clamped 5. The per-tick `timeout` fork those
caps add to every `pr_adapter_exec` — one more fork beside the `ps` it wraps, on the poll
loop and on each identity read — is below the noise floor here: the remaining ~0.2s of the
delta covers it and everything else. Budget against the ~5.5s poll and the ~1s-per-doctor
probe, not the whole delta; weigh the next per-adapter poll, and the next always-waited
probe window, before adding either.

There is no framework — `tests/helpers.sh` defines `assert_*`, and `pr_run_tests` runs every
`test_*` function in the sourcing file. Anything that would break "offline and seconds"
is opt-in behind a flag and skips by default — `PR_TEST_BASH32=1` is the only one, and it
is double-gated (flag, then `docker`) because it pulls the `bash:3.2` image.

`PR_ORCHESTRATOR` (`codex|agent|agy|claude|none`) is required by `round`, `doctor` and
`init`, deliberately with no default.

## Layout

- `bin/plan-review` — the only executable and the only file `install` symlinks. Resolves
  `PR_ROOT` via `readlink -f`, then **execs** `libexec/plan-review-<subcommand>.sh` so
  exit codes and signals stay the implementation's own.
- `libexec/plan-review-*.sh` — one entry point per subcommand; they source `lib/` and own
  argument parsing and exit statuses.
- `scripts/install.sh` — the curl-pipe bootstrap, and the only file outside `bin/` that
  users run directly. **The one file that must run under bash 3.2**, because it is what
  tells a macOS user their bash is too old. It clones and then **calls** `plan-review
  install` and `plan-review doctor --offline`; it re-derives none of their rules, because
  the second derivation is the one that goes stale. It checks `readlink -f` and bash 5
  before cloning — without those the doctor cannot start, so there is nothing to delegate
  to. Its skill step is non-fatal by design: the promise is the runner. Covered by
  `tests/test-bootstrap.sh`, which drives it against a throwaway local git repo via
  `PR_INSTALL_SOURCE`.
- `lib/*.sh` — sourcing is side-effect free everywhere; nothing runs until a `pr_*`
  function is called.
- `adapters/<reviewer>.sh` — one per reviewer CLI. **Standalone**: they source nothing,
  by contract, so shared constants (e.g. `PR_MAX_ARG_BYTES`) are deliberately stated
  twice, with cross-referencing comments.
- `skills/plan-review/SKILL.md` — the Integrator-side workflow, installed separately via
  `npx skills add`. Behaviour changes usually need edits in three places: the code,
  `README.md`, and this file.

## Architecture notes that span files

- **The adapter contract** (`docs/adapter-contract.md`) is the seam. Every adapter is
  invoked as `<workdir> <session_id> <review_out> <meta_out> <reason_out>`, prompt on
  **stdin**, review only into `<review_out>`, four fixed lines into `<meta_out>`. Adding
  a reviewer = a new adapter plus its key in `PR_ROSTER_ADAPTERS` (`lib/roster.sh`);
  nothing else derives the roster.
- **Roster precedence**: `PR_ADAPTER_MAP` > config `reviewers` > shipped adapters minus
  the orchestrator. A stated roster is obeyed exactly, including one naming the
  orchestrator's own CLI — that check was removed on purpose (see `lib/roster.sh`).
- **Config resolution** (`lib/config.sh`) writes the project config's pins into the same
  `PR_*_MODEL` / `PR_*_EFFORT` variables adapters already read, so nothing downstream
  knows a config exists. Schema violations exit 2 before anything is written.
- **`lib/doctor.sh` and `lib/roster.sh` use bash builtins only** — no sed/grep/awk, no
  `jq`. That is what lets `tests/test-doctor.sh` point `PATH` at a stub directory alone.
  `jq`-using logic belongs in `lib/config.sh` / `lib/init.sh` instead. The rule is about
  parsing: Tier E (`doctor --smoke`) exists to run adapters and so assumes a working
  PATH, exactly as `_pr_doctor_bwrap_probe` already does.
- **`pr_doctor_run` captures each probe to its own pair of files** and replays them on
  the streams they came from, then removes them itself. Both halves are load-bearing:
  a command substitution is held open by any descendant that inherited stdout, so the
  file is what bounds a hung probe; and merging the two streams would make
  `pr_doctor_run ... 2>/dev/null` a lie, letting `pr_doctor_version_of` parse a
  deprecation notice as the version. The `rm` is inside the function because the round
  path reaches it through preflight and never runs the doctor's own tail.
- **The session lock** (`lib/lock.sh`) is an `flock` on `<session>/.lock`, taken before
  anything is read and inherited by every spawned process — that inheritance is the
  mechanism, so never close descriptors in the fan-out path (`lib/reviewer-runner.sh`,
  `lib/adapter-exec.sh`). Environment sanitisation is independent of the lock —
  `adapters/claude.sh` rebuilds its environment from a whitelist while the lock fd,
  deliberately not CLOEXEC, rides through.
- **`adapters/agy.sh` passes `--print-timeout $((PR_TIMEOUT_SECS * 900))ms`** — 90% of
  the runner's deadline, in milliseconds so the inner deadline stays strictly below the
  outer one even at `PR_TIMEOUT_SECS=1`. Without it agy applies its own 5m0s default
  inside ours. The doctor asserts the flag still exists.
- **`adapters/claude.sh` echoes `terminal_reason`** from the result frame into the
  failure reason. It does not match against a list of values — probe P4 verified the
  field exists on every frame in 2.1.235 but never reproduced `prompt_too_long`, so
  branching on that string would be a citation standing in for a measurement.
- **R1: a reviewer forfeits its resume handle on a timeout *or* a failure**, and only
  its own. The parent branches on the `timed_out` field the child records, not on
  `status` — a timed-out reviewer with partial output is still `ok` but must not resume.
  The round-level counterpart is **enforced, not advised**: an `aborted` round forfeits
  every handle in it, so `libexec/plan-review-round.sh` refuses the next round without
  `--fresh` (`pr_round_needs_fresh`, `lib/round.sh` — one predicate, because two
  spellings of `aborted` is how the runner and the doctor would drift). It is a policy,
  not an inference: `abort` on an `awaiting_integration` round discards handles that
  were still good. That is the fourth accepted cost in the spec, priced deliberately
  against the per-reviewer marker the design rejected, and pinned by
  `tests/test-runner.sh`. `--fresh` then *clears* the session map, and that clear is a
  store-scoped write like any other — checked, `exit 2` on failure, before the round
  directory is created.
- **The execution kernel sweeps the adapter's process group unconditionally, and
  then its remembered descendants best-effort** (`lib/adapter-exec.sh`).
  `timeout --kill-after` stops escalating once the direct child is reaped, and
  never fires at all for an adapter that exits cleanly, which is why the group
  kill is not conditional on the timeout; `PR_KILL_GRACE_SECS` therefore covers
  the adapter only, not its descendants. But the group sweep alone reaches the
  spawned command of **no shipped reviewer**
  (P6, `docs/process/probes/2026-08-26-roster-sweep-reach/`):
  `codex` is contained by its own `--as-pid-1`, and `agent`'s tool layer takes
  its own process group *and* session. P6's other claim — that `agy`/`claude`
  were already contained by their adapters' bwrap — was inference, and false:
  `--die-with-parent` without `--unshare-pid` is `PR_SET_PDEATHSIG` on the
  immediate command, so a detached grandchild survives. Measured both ways
  2026-08-27 and fixed the same day
  (`docs/process/probes/2026-08-27-pid-namespace-adapters/`): `agy`, `claude`
  and now `agent` all pass **`--unshare-pid`**, so on **Linux** every shipped
  reviewer is contained by a jail. On **macOS** none of them is — no bwrap, no
  pid namespaces — and the sweep below is the only bound there. So `wait` is
  polled: each tick walks a `ps -eo pid=,ppid=`
  fixpoint from the adapter's pid (`_pr_ae_descendants`, bash builtins over a
  table so both GNU and Darwin shapes are fixture-tested offline) and remembers
  each descendant with its `ps -o lstart=` start time. After the group kill, a
  remembered pid is signalled only if that start time still string-equals the
  remembered one. `lstart` has one-second resolution, so the identity is
  probabilistic: a pid recycled within the round to a process born in the same
  wall-clock second would be killed in error — a stated residual risk, not an
  impossibility, and narrower the larger `pid_max` is. Any failure to read
  identity skips the pid, degrading to group-only cleanup: never an unsafe kill,
  never a broken round. The sweep is **best-effort by construction** — a
  fork-and-detach between the last sample and the kill escapes. What makes the
  review artifact final is therefore *not* the sweep but the child's
  **publication** step in `lib/reviewer-runner.sh`: the adapter writes
  `.review-<reviewer>.scratch`, the child copies it to `review-<reviewer>.md`
  before any judgment, and a survivor holding the scratch inode can no longer
  change what the round recorded. A survivor the poller misses keeps the
  inherited session lock, and later operations on that session fail closed until
  it exits — the accepted availability cost. Nothing in the poller closes a
  descriptor. `ps` is therefore a core utility (`PR_DOCTOR_UTILS`), though that
  is a presence check and busybox's `ps` rejects `-eo`, which degrades silently.
  **Every one of those three `ps` calls is wrapped in `timeout`**, and the
  post-`wait` sweep additionally carries a 30s deadline stamped before it
  starts: `timeout(1)` bounds the *adapter*, never the loop watching it, so an
  uncapped `ps` that never returned would wedge the round forever with the
  session lock held. The cap is `PR_PS_CAP_SECS`, read once and clamped to
  `1..5` — it exists so the offline suite can shrink its hang tests, not as an
  operator knob, and it is clamped because the environment is still input and
  GNU `timeout` accepts a syntactically valid `999999` verbatim. The sweep's
  true bound is the deadline **plus one cap of slack**, since a read that
  starts just under the wire still runs to its own cap. That a `ps` ever stalls
  is *unmeasured* — a `/proc` read against a task in uninterruptible sleep is
  the credible mechanism, not reproduced — and the comments say so; the
  unbounded wait itself was certain. Both degradations, a capped read and a
  tripped deadline, land on the same documented group-only cleanup.
  Which makes **GNU** `timeout` load-bearing twice over: the group kill only
  reaches the adapter's tree because GNU `timeout` puts *itself* in a new
  process group (measured 2026-08-27, transcript in `lib/adapter-exec.sh`'s
  header), and busybox's does not, leaving the sweep silently inert in the same
  environment its `ps` already breaks. `pr_doctor_check_gnu_timeout` therefore
  **fails** rather than warns.
  macOS descendant cleanup is unverified live (first row of the macOS cycle).
  The round (`lib/reviewer-runner.sh`) and `doctor --smoke` both spawn
  through the kernel — the smoke's call guarded by `declare -F` so the stub-PATH
  doctor tests stay green, and the smoke deliberately does *not* publish (it keeps
  no record and judges only alive/dead, so the finality rule above is the
  round's); `pr_doctor_run` keeps its own synchronous two-stream capture — the
  opposite discipline, deliberately not unified.
- **The kernel is the single channel for the adapter's environment.** It takes the
  deadline and the tmpdir as positionals (eight and nine of eleven) and exports
  exactly `PR_TIMEOUT_SECS` and `TMPDIR` through `env(1)`; callers pass no trailing
  `VAR=val` words, and the variadic mechanism that allowed them was deleted
  (2026-08-26, `/simplify`). `env` is last-assignment-wins, so keeping both channels
  would have let a caller's word silently override the deadline the kernel is
  actually enforcing — on `main` the two agreed only by coincidence, which is what
  made the divergence latent rather than visible. `env` execs the adapter's bash in
  place: no extra process in the group, no descriptor touched.
- **Round state machine** lives in `lib/round.sh`; every mutation of `round.json` happens
  serially in the parent after `wait`, never in a reviewer background job.
- **Write integrity splits along the blast radius, not the call site.** There is no
  `set -e` here, so every critical write is checked by hand, and the two failure kinds
  get different answers. Reviewer-scoped (`lib/reviewer-runner.sh`): a prompt or meta
  pre-seed that cannot be written fails *that* reviewer before the adapter is spawned —
  measured 2026-08-26, an unchecked prompt write let the adapter read the same
  `/dev/full` back as an endless NUL stream and file a review of nothing as `ok`, and an
  unchecked meta pre-seed left the child's own `mapfile` reading that stream past 3GB
  RSS under no deadline. The child's read of `<meta_out>` is bounded the same way and for
  the same measured reason: `[[ -f ]]` first, because a `<meta_out>` that is a symlink to
  `/dev/zero` fed `mapfile` an endless stream and a FIFO with no writer blocked forever at
  `open(2)`, and then `head -c 4096`, because `read -N` is builtin but drops NUL bytes
  without counting them against its own limit. That `head` is one fork per reviewer per
  round — the only new per-reviewer fork on this path, and the reason the bound is stated
  in `docs/adapter-contract.md` rather than repeated in every adapter.
  Store-scoped (`libexec/plan-review-round.sh`, `libexec/plan-review-abort.sh`): a `round.json`,
  session-map or synthesized-record write that fails is a hard `exit 2` with `aborting`
  on stderr — including the terminal `awaiting_integration` transition, because "Round
  complete" printed over a state that never persisted is the lie the guard exists to
  stop. The parent bridges the two with `pr_reviewer_result_ensure` (0 valid / 1
  synthesized / 2 store lost), so `round.json` lists every reviewer in the roster or the
  round does not claim to have finished. `abort` additionally refuses **before** it
  writes when the round directory is unwritable, so the operator gets one sentence
  instead of jq's tmpfile error; the check promises nothing beyond that, since a
  writable directory does not guarantee the write succeeds — hence the `|| exit 2`
  behind it. The all-failed path warns instead of escalating: it already exits non-zero
  and makes no success claim. **`libexec/plan-review-complete.sh` is the one store-scoped
  transition still unchecked** — it prints "Round complete" over a `pr_round_set_state`
  whose status it never reads (backlogged, 2026-08-27).
- **The reviewer runner** (`lib/reviewer-runner.sh`) owns the fan-out:
  `pr_reviewer_run_all` is the only public entry to the fan-out and validates
  the module's variable contract (fourteen caller variables, listed in the
  module header) before the first spawn, then waits on collected pids — never bare `wait`, which
  in a sourced function would reap a caller's unrelated job. The round caller
  reads each record through `pr_reviewer_result_path` / `pr_reviewer_result_read`
  and retires the round's scratch through `pr_reviewer_scratch_rm`; it composes
  no scratch name of its own, so a rename inside the module cannot silently
  break the round. Every `round.json` and session-map mutation stays serial, in
  the parent.
- **Confinement is per-adapter and not uniform**: codex and Cursor confine their own
  *writes*; `agy` and `claude` are wrapped in bubblewrap by their adapters and **fail
  closed** when `bwrap` is missing. `claude` additionally rebuilds the environment from a
  whitelist (the orchestrator's `CLAUDE_*` messaging socket is a channel out of the jail)
  and runs `--safe-mode`. Never add an unconfined fallback — for those two.
  `adapters/agent.sh` is the exception and is deliberately **not** fail-closed: its bwrap
  supplies the pid namespace and nothing else (`/` is bound read-write on purpose), so
  where the jail does not *work* it runs unwrapped and the kernel's sweep is the bound,
  exactly as `docs/adapter-contract.md`'s containment clause says — and that gate is a
  trial run of the flags, not `command -v`, because a host with bwrap installed and its
  userns denied would otherwise lose the reviewer outright. Both fail-closed adapters also
  keep a **private state directory** beside the repo copy — `<sandbox>/config` for claude,
  `<sandbox>/gemini-state` for agy — with the one auth file each needs bound in read-only
  *by path*. Only agy's is a mount over the real location: it is bound at `~/.gemini`
  because agy cannot be told to look elsewhere, while claude's is bound at its own path
  and named by `CLAUDE_CONFIG_DIR`. Neither operator directory is ever a bind **source**:
  both CLIs run hooks out of `~/.claude` and `~/.gemini` in the operator's own later
  sessions, which is what makes a writable bind of one a persistence channel out of the
  jail. agy's file list came from a measurement, not a guess — the obvious-looking
  `oauth_creds.json` is the wrong answer
  (`docs/process/probes/2026-08-27-pid-namespace-adapters/`, leg 3).

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
  deleting it. The adapter seeds no `config.toml`; codex writes one itself recording the
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

- **`PR_TIMEOUT_SECS` must be a positive integer**, enforced in
  `libexec/plan-review-round.sh` before preflight (which `PR_SKIP_PREFLIGHT=1` can
  skip) and again in `adapters/agy.sh`, which derives its own deadline from it with
  integer arithmetic. Two copies, because adapters are standalone. `doctor --smoke`
  enforces the same rule on `PR_SMOKE_TIMEOUT_SECS`, which the smoke hands to the
  adapters *as* their `PR_TIMEOUT_SECS`.

## Conventions

- Comments here carry the reasoning, often at length, and frequently record what a CLI
  was *measured* doing. Match that density; when you remove a guard, replace it with the
  comment explaining why.
- `docs/verified-versions.txt` pins the CLI versions the adapters were verified against;
  the doctor warns on drift. Update it only after re-running the probes.
