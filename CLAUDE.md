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
from `tests/fixtures/adapters/` via `PR_ADAPTER_MAP`, so nothing costs tokens. **Budget
against 550 tests / ~83s on Linux and 542 / 4m34s on Darwin** (this Mac's run-to-run spread
is ~7s, Linux's ~2.5s; nothing smaller is measurable). The full record — every row of the
timing table, what each branch cost and why — is `docs/test-timing.md`; read it before
adding a per-adapter fork or an always-waited probe window. The rules it distils to:

- **Any suite that shells out to `plan-review doctor`, `init` or a round needs
  `export PR_BWRAP_PROBE_TICKS=2` at file scope**, including the indirect ones — the
  probe's containment window costs ~1s per doctor run at the operator default, and
  `tests/test-bootstrap.sh` went 6s → 27s once because it reached the probe through a
  subprocess and was missed.
- A stub-only test is free here; a real reviewer-CLI spawn or a deliberately stalled clamp
  test is not (the four `ps`-hang tests in `tests/test-adapter-exec.sh` are ~15s on their
  own, and are the price of the cap). Price the next per-adapter fork before it lands.
- **A whole-suite clock read on a loaded host is worse than no clock.** Measure a
  same-session control (a `git worktree` at `main`, two back-to-back runs) rather than
  diffing against a number from another day; per-file timing is the fallback and is what
  found every regression so far. "The host got slower" has been the wrong answer once and
  the right one once.
- **Darwin traps**: BSD `sed` rejects `sed -i` without a suffix and a same-line `2i` — use
  `pr_test_insert_after_shebang` and assume nothing about GNU flags in a test. `setsid` is
  util-linux — the escaper fixture goes through `tests/fixtures/bin/pr-setsid`. `ps -o
  lstart=` answers in the host locale (`bg_BG` here) — any observer that *parses* it pins
  `LC_ALL=C`; the kernel only string-compares it, which is the property to preserve.
  **PATH cannot hide `bwrap`** on a host that has it — `tests/test-adapter-claude.sh` runs
  from a directory of symlinks to the externals the adapter actually calls; keep that list
  in step with the adapter, and never link `security` (the Keychain branch would fire
  against the operator's real keychain from inside the offline suite).

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
  install`, `plan-review skill` and `plan-review doctor --offline`; it re-derives none of
  their rules, because the second derivation is the one that goes stale. It checks `readlink -f` and bash 5
  before cloning — without those the doctor cannot start, so there is nothing to delegate
  to. Its skill step is non-fatal by design: the promise is the runner. It does read that
  step's **status**, though, and the two failures get different endings — 1 ("ran and
  failed") earns the `retry with:` line, 2 ("refused before doing anything": no npx/node or
  jq, no harness) does not, because re-running it refuses identically and exit 2's own
  message already names what is missing. That is one of the few rules the bootstrap owns
  rather than delegates, and it owns it because only the caller knows the retry is a wrapper
  around the same refusal. Covered by
  `tests/test-bootstrap.sh`, which drives it against a throwaway local git repo via
  `PR_INSTALL_SOURCE` — one case per arm, and they are a pair: whichever is read alone, the
  retry line looks unconditional.
- `lib/*.sh` — sourcing is side-effect free everywhere; nothing runs until a `pr_*`
  function is called.
- `adapters/<reviewer>.sh` — one per reviewer CLI. **Standalone**: they source nothing,
  by contract, so shared constants (e.g. `PR_MAX_ARG_BYTES`) are deliberately stated
  twice, with cross-referencing comments.
- `libexec/plan-review-skill.sh` — installs and verifies the skill below into every harness
  detected on PATH, via the third-party `skills` CLI pinned at `@1.5.18`. It owns the
  harness id/name tables and the Cursor identity gate, which `scripts/install.sh` used to
  carry; it may require `jq`, which the bootstrap may not, and that is what let the
  bootstrap's node JSON parser retire with them (2026-08-28). Fatal on every failure —
  0 verified, 1 installed-but-unverified or failed, 2 refused before acting — because the
  bootstrap wraps it non-fatally and something has to own the strict version.
- `skills/plan-review/SKILL.md` — the Integrator-side workflow, installed by
  `plan-review skill`. Behaviour changes usually need edits in three places: the code,
  `README.md`, and this file.

## Architecture notes that span files

- **The adapter contract** (`docs/adapter-contract.md`) is the seam. Every adapter is
  invoked as `<workdir> <session_id> <review_out> <meta_out> <reason_out>`, prompt on
  **stdin**, review only into `<review_out>`, four fixed lines into `<meta_out>`. Adding
  a reviewer = a new adapter plus its key in `PR_ROSTER_ADAPTERS` (`lib/roster.sh`);
  nothing else derives the roster. Its companion is `docs/feature-matrix.md`, which
  records what the four CLIs *offer* in the invocation shape each adapter builds, and
  which of it a round depends on. It is the file to update when a pin moves in
  `docs/verified-versions.txt`, and the place to look before assuming a CLI cannot do
  something — several of its rows say "nobody has run it", which is not the same answer.
- **The version on meta line 4 must name the binary that wrote the review.** Take it
  from the run's own output where the CLI offers one — `codex` off its banner,
  `claude` off the `init` frame — and otherwise read it **before** the run.
  `agent` and `agy` have no such field and so read first; they used to read after,
  and on 2026-08-29 Cursor self-updated *mid-round* and `round.json` recorded a
  binary that had not answered
  (`docs/process/probes/2026-08-29-macos-row3-sweep/`, and `agy` moved versions the
  same day, so it is not one vendor). Nothing is *wrong* when that happens — no
  review changes — which is exactly why it went unnoticed: what it quietly breaks is
  `docs/verified-versions.txt`'s drift warning and every "measured at version X"
  claim in the probe records. Reading first narrows the window from the whole review
  to the gap between two adjacent commands; it does not close it, and nothing
  detects the remainder.
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
- **Every doctor check is now roster-scoped, `pr_doctor_check_versions` included** — it was
  the last one that was not (fixed 2026-08-31). It iterated `docs/verified-versions.txt`, so
  a `{"reviewers": ["codex"]}` repo printed "`agy` is not in this round's roster" and then
  spawned `agy`, `claude` and `agent --version` anyway, the last a ~1.5s live account read.
  Two things about the fix are decisions rather than derivations. **The orchestrator's own
  CLI is kept** even though `lib/roster.sh` removes it from every roster: it is the binary
  running the rounds and nothing else here would report drift on it. It arrives as part of
  one name list rather than as its own argument — `"$shipped $orchestrator"`, read by the
  same `_pr_doctor_wants` `pr_doctor_check_pins` uses at the same call site, so `lib/doctor.sh`
  carries no notion of an orchestrator and the two roster-scoped checks cannot drift apart in
  how they read an empty list. And the skip is gated on
  `PR_ROSTER_ADAPTERS` as well as on the roster, so it applies only to names this repo ships
  an adapter for — a future pins line naming a non-reviewer dependency is in no roster and a
  bare roster test would drop it in silence. `tests/test-doctor.sh`'s "no real CLI" rule
  **survives this**: rostered CLIs and the orchestrator's are still spawned, and most cases
  there name a real orchestrator. What the gate retired is the `PR_TEST_NO_REAL_CLI` shim
  `BACKLOG.md` proposed — that enforcement was a net under a cause this removed.
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
- **The execution kernel sweeps the adapter's process group unconditionally, then its
  remembered descendants best-effort** (`lib/adapter-exec.sh`). `wait` is polled; each tick
  walks a `ps -eo pid=,ppid=` fixpoint from the adapter's pid and remembers each descendant
  with its `ps -o lstart=` start time, and a remembered pid is signalled after the group kill
  only if that start time still string-equals the remembered one. Every `ps` read is wrapped
  in `timeout --kill-after=1` (cap `PR_PS_CAP_SECS`, clamped `1..5`, because GNU `timeout`
  reads `0` as *disabling* the timeout) and the post-`wait` sweep carries a 30s deadline.
  Any failure to read identity skips the pid: never an unsafe kill, never a broken round,
  always degrading to group-only cleanup. The sweep is best-effort by construction; what
  makes the review artifact final is the child's **publication** step in
  `lib/reviewer-runner.sh`, not the sweep. Which shipped reviewer escapes the group kill is a
  per-platform vendor choice (on Linux every reviewer is contained by a bwrap pid
  namespace; on macOS none is and the sweep is the only bound), and neither `--unshare-pid`
  nor the sweep is contingent on it. **GNU** `ps` and `timeout` are load-bearing:
  `pr_doctor_check_ps_forms` and `pr_doctor_check_gnu_timeout` therefore **fail** rather than
  warn, and there is no non-GNU fallback. **Coupling rule**: fold the per-tick reads into one
  `ps -eo pid=,ppid=,lstart=` and that probe and its fixtures change in the same commit as
  `lib/adapter-exec.sh`. Nothing in the poller closes a descriptor. Every measurement
  behind this paragraph is in `.claude/rules/adapter-exec.md`, which loads when the kernel,
  the runner or the doctor is being edited.
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
  and makes no success claim. `libexec/plan-review-complete.sh` was the last store-scoped
  transition still unchecked and is now guarded like the rest (2026-08-28): its
  `pr_round_set_state ... complete` carries `|| exit 2` with `aborting` on stderr, because
  "Round complete" printed over a state that never persisted is exactly the lie the rule
  exists to stop. It takes **no** writability preflight, unlike `abort`'s — that one exists
  only to beat jq's tmpfile error to the diagnosis, and here the raw error plus one sentence
  is diagnosis enough, while a preflight would also put the guard out of reach of the test
  that makes the round directory unwritable. Every store-scoped write now checks.
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
- **Confinement is per-adapter and not uniform**, and the full measured account of each
  adapter's jail, private state directory and credential handling is
  `.claude/rules/confinement.md`, which loads when an adapter is being edited. The rules
  that must hold everywhere, regardless of what is open:
  - `agy` is wrapped in bubblewrap and **fails closed** without `bwrap`. **Never add an
    unconfined fallback for it.** It has **no Darwin half**: the port was priced on
    2026-09-02 (write access to a path holding executables, in the operator's real tree) and
    accepted only as explicit opt-in, and nothing has been built — the four `bwrap` gates stay
    exactly as they are, **do not take one down alone** (`docs/process/BACKLOG.md` has the list).
    `claude` is likewise never unconfined on any host: bwrap on Linux, Claude Code's own sandbox
    on Darwin, and a non-Darwin host without `bwrap` is **refused** (Claude Code's sandbox is
    itself bubblewrap on Linux). `adapters/agent.sh` is the deliberate exception — its bwrap
    supplies only the pid namespace and it runs unwrapped where the jail does not work, with
    the kernel's sweep as the bound.
  - `agent.sh` runs Cursor under a **private `HOME`** and pins `XDG_CONFIG_HOME` off the
    *real* home first: **the order of those two exports is the whole mechanism** (the
    credential lives at `~/.config/cursor/auth.json`; reverse them and the round reports
    `Not logged in`). `test_an_unset_xdg_config_home_is_pinned_before_the_home_moves` is the
    only guard on that order — never delete it as "the redundant one". Measured on Linux only;
    deliberately not gated on `$OSTYPE`.
  - On `claude`'s Darwin half the built-in sandbox confines Bash tool calls **only**, so
    `permissionMode: default` is load-bearing: **never put Write or Edit in a
    `permissions.allow` there.** `failIfUnavailable` fails safe but not closed; what makes
    that half shippable is the ran-no-command tripwire, on both halves.
  - Neither `~/.claude` nor `~/.gemini` is ever a bind **source**; both CLIs run hooks out of
    them in the operator's later sessions (agy's `~/.gemini/config/hooks.json` was measured
    firing). Credentials are copied or bound read-only by path, and the copies (codex
    `auth.json`, claude's Keychain item on macOS) are a second credential at rest whose
    staleness remedy is deletion. Cursor copies nothing and is the one adapter with no
    credential at rest.
  - The repo under review can reopen a sandbox from its own side: `agent.sh` removes the
    repo's `.cursor/`, `claude.sh`'s builtin half removes its `.claude/`, `agy.sh` removes its
    `.agents/` (a `PreInvocation` hook there was measured executing with no trace in the JSON
    envelope), codex passes `-c features.hooks=false`. Keep all four.
  - `agy` passes `--print-timeout` at 90% of `PR_TIMEOUT_SECS` and `agent` bounds
    `create-chat` (which never exits in a cold config dir) with a `timeout --kill-after=1`
    derived from it; both derivations are in the adapters and the reasons in the rule file.

- **`PR_TIMEOUT_SECS` must be a positive integer**, enforced in
  `libexec/plan-review-round.sh` before preflight (which `PR_SKIP_PREFLIGHT=1` can
  skip) and again in `adapters/agy.sh` and `adapters/agent.sh`, which each derive their
  own deadline from it with integer arithmetic. Three copies, because adapters are
  standalone — and identical copies, deliberately: `docs/adapter-contract.md` names
  `adapters/agy.sh` as *the* reference spelling for an adapter that derives an inner
  deadline, so an adapter that quietly substituted a default instead would leave the
  contract pointing at the minority. `doctor --smoke`
  enforces the same rule on `PR_SMOKE_TIMEOUT_SECS`, which the smoke hands to the
  adapters *as* their `PR_TIMEOUT_SECS`.

## Conventions

- Comments here carry the reasoning, often at length, and frequently record what a CLI
  was *measured* doing. Match that density; when you remove a guard, replace it with the
  comment explaining why.
- `docs/verified-versions.txt` pins the CLI versions the adapters were verified against;
  the doctor warns on drift. Update it only after re-running the probes.
