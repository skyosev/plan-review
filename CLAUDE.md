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
a `git worktree` per revision — every row but the last, which is 2026-08-28 in place:

| tree | tests | run 1 | run 2 |
| --- | --- | --- | --- |
| `ea2b59e` (pre-`reviewer-isolation-hardening`) | 467 | 62.159s | 62.214s |
| + tasks 1–2 of that branch | 485 | 85.243s | 85.359s |
| + task 3, as first written | 490 | 93.993s | 94.060s |
| + task 3 review fixes (`reviewer-isolation-hardening`, as merged) | 491 | 84.624s | 84.460s |
| + `backlog-clearing-3` | 519 | 81.060s | 83.451s |
| **+ the macOS pass's return** | **521** | **80.885s** | **80.610s** |
| + `claude-macos` — **Darwin only, see below** | 542 | 274.2s | — |
| **+ `claude-macos`, on Linux** | **542** | **78.84s** | **79.25s** |
| **+ the row-L3 fix** | **543** | **78.38s** | **78.38s** |
| `main` re-timed 2026-08-31, same tree as the row above | 543 | 82.17s | 81.13s |
| **+ `backlog-clearing-4`** | **547** | **81.71s** | **83.53s** |
| **+ `cursor-peruser-policy`** | **550** | **83.73s** | **82.68s** |

So ~62s was still right for `main` at the time: the whole delta was
`reviewer-isolation-hardening`'s, not host drift —
worth stating, because "the host got slower" was the first explanation offered and it was
wrong. Per-file timing of both trees found where it went, and one line of it was a **bug**:
`tests/test-bootstrap.sh` had gone 6.156s → 26.707s, a file that branch never edited. It
drives `plan-review doctor` as a subprocess ~20 times, and task 1 gave
`_pr_doctor_bwrap_probe` a containment window the pass path always waits out — ~1.04s per
doctor run at the operator default `PR_BWRAP_PROBE_TICKS=10`. `tests/test-doctor.sh` and
`tests/test-init.sh` already export `PR_BWRAP_PROBE_TICKS=2` at file scope for exactly
this; `test-bootstrap.sh` reaches the probe through a *subprocess*, which inherits the
environment identically, and that indirection is why it was missed. Adding the export took
it to 10.674s. **Any new suite that shells out to `plan-review doctor`, `init` or a round
needs that export**, and the indirect ones are the easy misses.
`tests/test-runner.sh` (29.5s, still the single largest file) never moved.

Task 3 itself **costs ~+15s** and **all of it is in `tests/test-adapter-exec.sh`**
(3.028s → 18.004s; `tests/test-doctor.sh`'s 9.479s → 11.684s was tasks 1–2, and task 3's
two checks there cost 0.03s on top). That +15s against the bootstrap fix's −16.0s is the
whole reason the tree lands marginally *cheaper* than before task 3 started — 84.6s at 491
tests against 85.3s at 485 — and the two numbers have to be read together: the saving paid
for the coverage exactly once, and the next contributor gets no such refund. **Budget the
+15s, not the net.** Every second of it is four clamp/hang tests that stall a stubbed `ps`
on purpose and assert the cap cuts it short: `PR_PS_CAP_SECS=1` for the two hang cases, and
~5s each for the clamped `999999` and `0`. That is the price of a clamp — there is nothing
observable about one but the consequence — and the `0` case in particular buys real
coverage, since GNU `timeout` reads `0` as *disabling* the timeout. The fifth,
`abc`, is checked against the escaper instead of the clock for ~1s, because an unclamped
`abc` makes the suite *faster* while silently switching descendant tracking off.

The production cost of task 3 — one extra `timeout` fork per poll tick and per identity
read, beside the `ps` it wraps — stays below this host's noise floor; run-to-run spread on
an identical tree is under 0.2s. Budget against the ~5.5s poll and the ~1s-per-doctor
probe, not against test wall-clock that a missing knob export can explain; weigh the next
per-adapter poll, and the next always-waited probe window, before adding either.

**The last row is the one to budget against: 521 tests in ~81s**, measured 2026-08-29;
its two tests are the `cli_version` pair and they cost nothing this method can see — the
two runs came in 0.27s apart, an order of magnitude inside the ~2.5s the row below it
establishes as this method's floor. Read the two rows together and the conclusion is
that a stub-only test is free here; that is not a licence, it is why the *next*
per-adapter fork is still worth pricing before it lands.

The `backlog-clearing-3` row is the one that explains the shape: 519 tests in ~82s,
measured 2026-08-28 on the same host (load ~0.7) by the same two back-to-back runs the rows above use. Read the
spread, not the midpoint: 81.1s and 83.5s on an identical tree is the widest gap any row
here has shown, so a change under ~2.5s is not visible to this method. Both numbers
moved and they moved in *opposite* directions, which is the fact worth carrying:
`backlog-clearing-3` added 28 tests and the tree still came out ~2s cheaper than the 491
it started from. The refund is Task 1's, and it is not a fixture trick — `stub_all_reviewer_clis`
replaced **20 real reviewer-CLI `--version` spawns** in `tests/test-doctor.sh` (6 claude, 5
agy, 5 agent, 4 codex, counted with recording wrappers) with stubs that leave every check
intact and only change what answers, including the one genuinely expensive read: a live
`agent about --format json`, ~1.5s on its own. `pr_doctor_check_versions` is
roster-independent, which is why a case whose config named only codex was still reading four
versions off the host. So the suite did not merely get faster; it stopped consulting live
account state to assert a drift message. Read that the same way as the bootstrap saving
above — it paid for this branch's 28 tests exactly once, there are no live spawns left to
reclaim, and the next contributor budgets against ~82s at 519 with no credit to spend.

**The second-to-last row is Darwin, and it is the only row that is.** `claude-macos` added 23 tests
(the confinement branch's two halves, the credential and settings assertions, the
no-command tripwire on both halves, the stream-file pair, and five doctor cases) and
measured **4m34.2s at the 539 of them that existed when the clock was read, 542 now on
this Mac**, against the **4m36.6s at 519** the row below establishes for the same host — so
the branch's tests cost *nothing this method can see*, which on a Mac with ~7s of run-to-run
spread means anything under ~7s. That is not a licence: the tests it added are stub-only, and
the one thing on this branch with a real per-round cost is the Keychain read, which is one
`security` fork per `claude` round on the builtin half and does not touch the suite at all.
The Linux number that was missing when that row was written **now exists and is the last
row**: 542 tests in 78.84s and 79.25s, measured 2026-08-30 on this host (32 cores, load ~0.8)
by the same two back-to-back runs on a clean clone. Read it against the 521/~81s below it and
the branch's +21 tests cost **nothing this method can see** — the two runs came in 0.41s
apart, well inside the ~2.5s floor the `backlog-clearing-3` row establishes. The same
conclusion on both platforms, by two independent measurements, and for the same reason: the
tests it added are stub-only. It is still not a licence. The one thing on this branch with a
real per-round cost is the Keychain read, which is one `security` fork per `claude` round on
the builtin half and never runs on Linux at all. The row below it is the same tree plus row L3's fix, and its 543rd test — the
adapter's Linux refusal — is likewise free (two runs identical to the centisecond).
**Budget against 550/~83s Linux and 542/4m34.2s Darwin**; the Darwin row predates the
row-L3 fix and the private-`HOME` branch both, and nobody has re-timed a Mac since.

**The last two rows are a pair and only mean anything read together.** The ~78s of the
row-L3 tree was measured 2026-08-30; the same tree re-timed on 2026-08-31 — a `git worktree`
at `main`, two back-to-back runs, the method every row here uses — came in at 82.17s and
81.13s. So the host is ~3s slower than it was the day before, and `backlog-clearing-4`'s four
tests cost **nothing this method can see**: 81.71s and 83.53s against main's 82.17s and 81.13s
on the same afternoon, the two trees interleaved inside the ~2.5s floor. The tree is **548**
after that branch's `/simplify` pass, and that row's clock was deliberately NOT re-read: the
host went under heavy external load the same afternoon (`/proc/loadavg` swinging 25 → 3.8 → 26
between adjacent runs on 32 cores) and four interleaved whole-suite runs came back 99s–133s
against 82s–104s, a ~20s spread that no change in this diff could explain. Per-file timing —
the technique that found the `test-bootstrap.sh` bug above — settled it instead: all four
files the pass touched are identical across the two trees (`test-doctor.sh` 6.75s → 6.40s,
`test-adapter-claude.sh` 2.52s → 2.65s, `test-adapter-agent.sh` 0.97s → 0.96s,
`test-bootstrap.sh` 9.49s → 9.57s), and it touched no others. **A whole-suite clock read on a
loaded host is worse than no clock**; per-file is the fallback, and the 548th test is one more
stub-only preflight case. Measure the baseline
again rather than diffing against a number from another day — "the host got slower" was the
wrong answer once in this table and the right one here, and only a same-session control tells
the two apart. What the four tests are is also why they are free: three doctor unit cases and
one adapter refusal that exits before spawning anything. The Debian-container run in
`docs/process/probes/2026-08-30-claude-macos-row8/` is superseded: its 14 failures were the
container's PID view and seccomp profile and did **not** reproduce on a real host
(`docs/process/FINDINGS-2026-08-30-linux.md`).

**The last row is `cursor-peruser-policy`, and it is two more stub-only cases.** 550 tests in
83.73s and 82.68s, measured 2026-08-31 on this host (32 cores, load ~1.1 at both ends, checked
rather than assumed after the row above), two back-to-back runs on the same tree, the method
every row here uses. Read against the 547/81.71s–83.53s directly above it — same host, same
afternoon — the two trees interleave, so the branch's cost is **nothing this method can see**.
That is the expected answer and not a surprising one: the branch's whole diff is two exports
in `adapters/agent.sh` and two cases in `tests/test-adapter-agent.sh` that drive the shipped
stub. What it does **not** license is the next per-round fork. The one thing here with a
production cost is a single `mkdir -p` per `agent` round, which is below anything this table
can resolve; a Keychain read or a `ps` poll would not be, and the rows above price those.

**Every row but the Darwin one is Linux.** The suite first ran on **Darwin on 2026-08-29** and cost
**4m36.6s** for the 519 of the `backlog-clearing-3` row — ~3.4x, spread evenly across files rather than concentrated
in one, which is what rules out the missing-`PR_BWRAP_PROBE_TICKS` shape and leaves fork
cost. Two things came out of that first run and both are load-bearing here. **BSD sed
rejects `sed -i` without a suffix and rejects a same-line `2i`**, which is how three tests
were silently asserting against unmodified stubs — use `pr_test_insert_after_shebang`, and
assume nothing about GNU flags in a test. And **`setsid` is util-linux**: Darwin has
`setsid(2)` but no `setsid(1)`, so the escaper fixture goes through
`tests/fixtures/bin/pr-setsid`, which prefers the real tool and falls back to perl's
`POSIX::setsid`. Four cases skip on a Mac — three need `/dev/full`, one is
`PR_TEST_BASH32` — and none of them is the descendant sweep any more. Run-to-run spread on
this Mac is ~7s, so nothing smaller than that is measurable there
(`docs/process/probes/2026-08-29-macos-row1-suite/`).

A third joined them on 2026-08-30 and it is a *reading* trap rather than a writing one:
**this Mac's locale is `bg_BG`, and `ps -o lstart=` answers `пн 10 авг. 21:07:39 2026`
there.** It costs `lib/adapter-exec.sh` nothing — the kernel only ever string-compares one
`lstart` against another and never parses one, which is the property to preserve — but any
probe observer that *parses* that field must pin `LC_ALL=C` first, and the two on this
branch do. A fourth, for anyone writing a test that has to exercise a code path chosen by
the ABSENCE of a binary: **PATH cannot hide `bwrap`** on a host that has it, so
`tests/test-adapter-claude.sh` builds a directory of symlinks to the externals the adapter
actually calls and runs from that alone. Keep that list in step with the adapter, and note
that `security` is deliberately *not* on it — link it and the Keychain branch fires against
the operator's real login keychain from inside the offline suite.

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
- **The execution kernel sweeps the adapter's process group unconditionally, and
  then its remembered descendants best-effort** (`lib/adapter-exec.sh`).
  `timeout --kill-after` stops escalating once the direct child is reaped, and
  never fires at all for an adapter that exits cleanly, which is why the group
  kill is not conditional on the timeout; `PR_KILL_GRACE_SECS` therefore covers
  the adapter only, not its descendants. But the group sweep alone reaches the
  spawned command of **no shipped reviewer**
  (P6, `docs/process/probes/2026-08-26-roster-sweep-reach/`):
  `codex` is contained by its own `--as-pid-1`, and `agent`'s tool layer takes
  its own process group *and* session — **on Linux**, which is the only place P6
  ran. On **Darwin** the two swap: `agent`'s escaper stays in the adapter's group
  and the group kill gets it, while `codex`'s tool layer regroups and codex reaps
  its own (`docs/process/probes/2026-08-29-macos-row3-sweep/`, 2026-08-29, two
  live rounds). Which reviewer escapes the group kill is therefore a per-platform
  vendor choice, and neither `--unshare-pid` nor the sweep is contingent on it —
  that is the point of both. P6's other claim — that `agy`/`claude`
  were already contained by their adapters' bwrap — was inference, and false:
  `--die-with-parent` without `--unshare-pid` is `PR_SET_PDEATHSIG` on the
  immediate command, so a detached grandchild survives. Measured both ways
  2026-08-27 and fixed the same day
  (`docs/process/probes/2026-08-27-pid-namespace-adapters/`): `agy`, `claude`
  and now `agent` all pass **`--unshare-pid`**, so on **Linux** every shipped
  reviewer is contained by a jail. On **macOS** none of them is — no bwrap, no
  pid namespaces — and the sweep below is the only bound there. **That sweep was measured
  doing the work on Darwin for the first time on 2026-08-30**, against `claude`'s Bash-tool
  wrapper, which takes its own process group (D2/B6's 2026-08-21 mechanism, unchanged at
  2.1.251) and so is out of the group kill's reach: the marker was remembered in three or
  four poll frames, reparented to `launchd`, outlived its adapter by a frame, and was gone
  in the next (`docs/process/probes/2026-08-30-claude-macos-row1` and `-row67`). The
  2026-08-29 pass concluded the sweep "never had to fire" here; putting `claude` on the
  macOS roster is what made it fire. So `wait` is
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
  descriptor. `ps` is therefore a core utility (`PR_DOCTOR_UTILS`) — but that
  list is a presence check, and presence is not sufficiency: busybox's `ps` exists
  and rejects `-eo`. Sufficiency is `pr_doctor_check_ps_forms` (2026-08-28), a
  Machine-tier probe on `pr_doctor_check_gnu_timeout`'s precedent that *runs* both
  invocations the kernel ships and **fails** on either. It is behavioural rather
  than a version match because both the GNU and Darwin shapes must pass. The two
  degrades it catches are not the same: a `ps` that rejects `-eo` loses the whole
  descendant table, while one that answers the table but not `lstart` loses only
  the identity read — every remembered pid then fails its check and is skipped,
  which is safe but is group-only cleanup under a green doctor. **Coupling rule**:
  fold the per-tick reads into one `ps -eo pid=,ppid=,lstart=` and that probe and
  its fixtures change in the same commit as `lib/adapter-exec.sh`.
  **Every one of those three `ps` calls is wrapped in
  `timeout --kill-after=1`**, and the post-`wait` sweep additionally carries a
  30s deadline stamped before it starts: `timeout(1)` bounds the *adapter*,
  never the loop watching it, so an uncapped `ps` that never returned would
  wedge the round forever with the session lock held. The cap is
  `PR_PS_CAP_SECS`, read once and clamped to `1..5` — it exists so the offline
  suite can shrink its hang tests, not as an operator knob, and it is clamped
  because the environment is still input and GNU `timeout` accepts a
  syntactically valid `999999` verbatim (and reads `0` as *disabling* the
  timeout, which is why the clamp rejects it too). The
  sweep's true bound is the deadline **plus one cap of slack**, since a read
  that starts just under the wire still runs to its own cap. `--kill-after` is
  load-bearing in that sentence: `timeout N` does not *return* at N, it signals
  and then waits for its child, so without the escalation a TERM-ignoring `ps`
  is still unbounded (measured 2026-08-27: 5.003s against 2.002s). What
  **nothing** here bounds is a `ps` in uninterruptible sleep — it takes neither
  signal, `timeout` blocks in `waitpid`, and the deadline is checked *before*
  each read so it is never reached. That is the one case the caps do not cover,
  and it is also the one nobody has reproduced. That a `ps` ever stalls at all
  is *unmeasured* — a `/proc` read against a task in uninterruptible sleep is
  the credible mechanism, not reproduced — and the comments say so; the
  unbounded wait itself was certain. Both degradations, a capped read and a
  tripped deadline, land on the same documented group-only cleanup.
  Which makes **GNU** `timeout` load-bearing twice over: the group kill only
  reaches the adapter's tree because GNU `timeout` puts *itself* in a new
  process group (measured 2026-08-27, transcript in `lib/adapter-exec.sh`'s
  header), and busybox's does not, leaving the sweep silently inert in the same
  environment its `ps` already breaks. `pr_doctor_check_gnu_timeout` therefore
  **fails** rather than warns. The mixed host — GNU `ps`, busybox `timeout` — is
  not the extra hazard it looks like: the `--kill-after` the `ps` caps use is
  rejected there (measured 2026-08-27, BusyBox 1.36.1), but so is the identical
  flag on the *adapter* spawn, which has carried it since the kernel landed. A
  busybox `timeout` is a host that runs no reviewer at all, which is why nothing
  carries a non-GNU fallback.
  macOS descendant cleanup is verified live as of 2026-08-30 — see above. In one
  acceptance round all three shapes appeared at once: `claude`'s escaper was reached by the
  remembered-descendant path, `agent`'s stayed in the adapter's own group and the group kill
  got it, and `codex` reaped its own 26s before its adapter exited. Do not read that as a
  design: it is three vendors behaving three ways, which is the whole argument for a bound
  that does not care which.
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
  writing that file itself — leg C asked for exactly that and `agy`'s **own** terminal
  sandbox refused it read-only, with bwrap binding the directory read-**write** on
  purpose and the CLI process writing into it in the same run. The split is tool call
  versus CLI, not jail versus host, and `DENIED` there is "this route was refused" from
  one command in one shape, not "the directory is unreachable".

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
