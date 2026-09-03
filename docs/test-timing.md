# Test-suite timing history

Moved verbatim from `CLAUDE.md` on 2026-09-03 so the always-loaded file stays under the
large-file threshold. The distilled rules live in `CLAUDE.md` under Commands; this file is
the measurement record behind them. Append new rows and narrative here.

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
