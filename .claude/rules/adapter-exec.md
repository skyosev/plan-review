---
paths:
  - lib/adapter-exec.sh
  - lib/reviewer-runner.sh
  - lib/doctor.sh
  - tests/test-adapter-exec.sh
---

# Execution kernel: process-group sweep and descendant tracking

Moved verbatim from `CLAUDE.md` (Architecture notes) on 2026-09-03. Loads when the files
above are being edited. The one-paragraph summary and the coupling rule stay in `CLAUDE.md`.

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
