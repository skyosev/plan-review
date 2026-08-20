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
    PR_ORCHESTRATOR=none make doctor
    PR_ORCHESTRATOR=none make doctor OFFLINE=1     # no auth/model-list calls
    bin/plan-review doctor --repo <dir> --show-config

The suite is offline and takes seconds: every test drives the runner with fake adapters
from `tests/fixtures/adapters/` via `PR_ADAPTER_MAP`, so nothing costs tokens. There is
no framework — `tests/helpers.sh` defines `assert_*`, and `pr_run_tests` runs every
`test_*` function in the sourcing file.

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
  `jq`-using logic belongs in `lib/config.sh` / `lib/init.sh` instead.
- **`pr_doctor_run` captures each probe to its own pair of files** and replays them on
  the streams they came from, then removes them itself. Both halves are load-bearing:
  a command substitution is held open by any descendant that inherited stdout, so the
  file is what bounds a hung probe; and merging the two streams would make
  `pr_doctor_run ... 2>/dev/null` a lie, letting `pr_doctor_version_of` parse a
  deprecation notice as the version. The `rm` is inside the function because the round
  path reaches it through preflight and never runs the doctor's own tail.
- **The session lock** (`lib/lock.sh`) is an `flock` on `<session>/.lock`, taken before
  anything is read and inherited by every spawned process — that inheritance is the
  mechanism, so never close descriptors or sanitise the environment in the fan-out path
  of `libexec/plan-review-round.sh`.
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
- **The round fan-out sweeps the reviewer's process group** (`kill -KILL -- -$timeout_pid`)
  on timeout, before any artifact is read — `timeout --kill-after` stops escalating once
  the direct child is reaped, so a TERM-ignoring grandchild otherwise survives and can
  still append to `review-<reviewer>.md`. `PR_KILL_GRACE_SECS` therefore covers the
  adapter only, not its descendants.
- **Round state machine** lives in `lib/round.sh`; every mutation of `round.json` happens
  serially in the parent after `wait`, never in a reviewer background job.
- **Confinement is per-adapter and not uniform**: codex and Cursor confine themselves;
  `agy` and `claude` are wrapped in bubblewrap by their adapters and **fail closed** when
  `bwrap` is missing. `claude` additionally rebuilds the environment from a whitelist
  (the orchestrator's `CLAUDE_*` messaging socket is a channel out of the jail) and runs
  `--safe-mode`. Never add an unconfined fallback.

- **`PR_TIMEOUT_SECS` must be a positive integer**, enforced in
  `libexec/plan-review-round.sh` before preflight (which `PR_SKIP_PREFLIGHT=1` can
  skip) and again in `adapters/agy.sh`, which derives its own deadline from it with
  integer arithmetic. Two copies, because adapters are standalone.

## Conventions

- Comments here carry the reasoning, often at length, and frequently record what a CLI
  was *measured* doing. Match that density; when you remove a guard, replace it with the
  comment explaining why.
- `docs/verified-versions.txt` pins the CLI versions the adapters were verified against;
  the doctor warns on drift. Update it only after re-running the probes.
