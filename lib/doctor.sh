#!/usr/bin/env bash
# Dependency and readiness checks.
#
# Sourced by libexec/plan-review-doctor.sh (the full run) and by
# libexec/plan-review-round.sh (the offline preflight). Sourcing has no side effects:
# nothing here runs a check or prints anything until a pr_doctor_* function is
# called.
#
# Presence and version checks use bash builtins only -- `command -v`, `[[ =~ ]]`,
# parameter expansion, `read` -- and never sed/grep/awk. That is what lets
# tests/test-doctor.sh point PATH at a stub directory *alone*. If this file
# shelled out to parse a version string, the stub PATH would have to carry
# coreutils too, and a test for "this machine is missing jq" would no longer be
# testing anything.
#
# Three outcomes, not two:
#   pass  the thing is there and works
#   warn  it works but diverges from what was measured (version drift, no pin)
#   fail  a round would not work
# Only fail sets the exit status. A newer CLI is a thing to know about, not a
# reason to refuse to run.

PR_DOCTOR_PASS=0
PR_DOCTOR_WARN=0
PR_DOCTOR_FAIL=0

if [[ -t 1 ]]; then
  PR_D_GREEN=$'\033[0;32m'
  PR_D_RED=$'\033[0;31m'
  PR_D_YELLOW=$'\033[0;33m'
  PR_D_BOLD=$'\033[1m'
  PR_D_RESET=$'\033[0m'
else
  PR_D_GREEN='' PR_D_RED='' PR_D_YELLOW='' PR_D_BOLD='' PR_D_RESET=''
fi

pr_d_pass() {
  printf '%s[PASS]%s %s\n' "$PR_D_GREEN" "$PR_D_RESET" "$1"
  PR_DOCTOR_PASS=$((PR_DOCTOR_PASS + 1))
}

pr_d_warn() {
  printf '%s[WARN]%s %s\n' "$PR_D_YELLOW" "$PR_D_RESET" "$1"
  PR_DOCTOR_WARN=$((PR_DOCTOR_WARN + 1))
}

pr_d_fail() {
  printf '%s[FAIL]%s %s\n' "$PR_D_RED" "$PR_D_RESET" "$1"
  PR_DOCTOR_FAIL=$((PR_DOCTOR_FAIL + 1))
}

# Remediation and context. Deliberately uncounted: an info line is never a result.
pr_d_info() {
  printf '       %s\n' "$1"
}

# A check that did not apply. Uncounted for the same reason as info: the
# orchestrator's own CLI is not a reviewer, so there was nothing to pass or fail.
# Printed rather than silent, because "codex is missing from this report" and
# "codex is the orchestrator" look identical when the line is simply absent.
pr_d_skip() {
  printf '%s[SKIP]%s %s\n' "$PR_D_BOLD" "$PR_D_RESET" "$1"
}

pr_d_section() {
  printf '\n%s%s%s\n' "$PR_D_BOLD" "$1" "$PR_D_RESET"
}

pr_doctor_have() { command -v "$1" > /dev/null 2>&1; }

# Run with a wall-clock cap when timeout(1) exists, plain otherwise. The auth
# checks reach the network; a hung one must not hang the doctor. timeout's own
# absence is reported by pr_doctor_check_utils, so this degrades rather than dies.
#
# Output goes to a FILE, never straight into the caller's command substitution.
# Measured 2026-08-19: a probe whose grandchild inherits stdout holds `$(...)`
# open for the grandchild's whole life, and the outer `timeout` is blocked in
# the same substitution, so a second cap does not rescue it. The file breaks the
# descriptor chain; the group sweep then disposes of the grandchild itself,
# which the file alone does not. The Go orchestrator surveyed in the process
# notes reaches the same place with cmd.WaitDelay -- that is where the question
# came from, not the evidence.
#
# The two streams go to SEPARATE files and are replayed on the streams they came
# from. A single `2>&1` capture would be shorter, but it silently rewrites every
# call site: `pr_doctor_run ... 2>&1` and `pr_doctor_run ... 2>/dev/null` would
# both mean "merged", and pr_doctor_version_of -- which word-splits the first
# line looking for a digit -- can then return a token from a deprecation notice
# instead of the version. Replaying keeps the choice where the caller makes it.
#
# Builtins only, and that is a hard constraint, not a preference:
# tests/test-doctor.sh runs Tier B checks with a stub directory as the ENTIRE
# PATH. No mktemp, no cat. `rm` may be missing too, which is why the names are
# stable per-process: cleanup is best-effort, and a PATH without rm reuses the
# same two files rather than accumulating them.
pr_doctor_run() {
  local secs="$1"; shift
  local out="${TMPDIR:-/tmp}/pr-doctor-run.$$" err="${TMPDIR:-/tmp}/pr-doctor-err.$$"
  local rc pid
  if pr_doctor_have timeout; then
    # Backgrounded so $! names timeout's pid, which is the process-group id;
    # the KILL sweep after wait is unconditional because it, not the grace, is
    # what disposes of a descendant that outlives the direct child (measured
    # 2026-08-19). The files above break a hung probe's descriptor chain; the
    # sweep disposes of the probe itself. This used to be _pr_doctor_run_capped,
    # shared with the smoke tier; the smoke now goes through lib/adapter-exec.sh
    # and this synchronous capture is deliberately the discipline the kernel
    # does not absorb. The fallback branch shares this shell's process group,
    # so a `-$pid` sweep there would name nothing of ours.
    timeout "$secs" "$@" > "$out" 2> "$err" &
    pid=$!
    wait "$pid"; rc=$?
    kill -KILL -- "-$pid" 2> /dev/null
  else
    "$@" > "$out" 2> "$err"
    rc=$?
  fi
  printf '%s\n' "$(< "$out")"
  # Guarded so an empty stderr stays empty rather than becoming a blank line,
  # which a call site's `2>&1` would otherwise splice into the captured output.
  [[ -s "$err" ]] && printf '%s\n' "$(< "$err")" >&2
  # Here rather than at the exits: pr_doctor_preflight calls this from the round
  # path too, and the doctor's own early exits skip anything wired to its tail.
  pr_doctor_have rm && rm -f "$out" "$err"
  return "$rc"
}

# ---------------------------------------------------------------------------
# Tier A: the machine. Offline, no network, safe to run on every round.
# ---------------------------------------------------------------------------

# The floor is 5: that is the shell the suite runs on, the shell the adapters
# were verified against, and the only one anything here is tested under. It is a
# support statement, not a measured requirement -- no bash-5-only construct is
# used (the candidates, EPOCHREALTIME, `wait -n -p`, SRANDOM and ${x@K}, have no
# job in this code), and the constructs that ARE used top out at bash 4: ${x^^}
# in lib/config.sh and lib/init.sh, mapfile in libexec/plan-review-round.sh, printf
# %()T in lib/status.sh. 4.x would very likely run; it is simply not tested, and
# a gate that decides whether a round may start should say what is supported
# rather than guess what might work. Its practical job is still catching macOS's
# /bin/bash 3.2.
pr_doctor_check_bash() {
  local major="${BASH_VERSINFO[0]:-0}"
  if (( major >= 5 )); then
    pr_d_pass "bash ${BASH_VERSION%%[^0-9.]*} (need 5 or newer)"
    return 0
  fi
  pr_d_fail "bash ${BASH_VERSION:-unknown} is older than 5"
  pr_d_info "macOS ships 3.2 as /bin/bash. Install a current one (brew install bash)"
  pr_d_info "and make sure it is the bash on PATH, since the scripts use #!/usr/bin/env bash."
  return 1
}

# `wc` is here for lib/prompt.sh's pr_prompt_bytes: the argv cap agy runs into is
# a BYTE limit, and bash's ${#var} counts characters under a UTF-8 locale.
# `flock` is the session lock (lib/lock.sh). Not coreutils: util-linux on Linux,
# and on macOS the separate discoteq `flock` formula, which is a different
# program with the same name -- see the macOS note in docs/process/BACKLOG.md.
# `ps` is the execution kernel's descendant sweep (lib/adapter-exec.sh): the
# poller reads `ps -eo pid=,ppid=` every tick and `ps -o lstart= -p` per new
# descendant. Load-bearing on the round path since 2026-08-26 -- without it the
# kernel degrades to the group-only sweep, which P6 measured reaching the
# spawned command of no shipped reviewer, so a round leaks the survivor AND
# keeps the session lock. This is a PRESENCE check and presence is not
# sufficiency: busybox `ps` exists and rejects `-eo`, which produces the same
# silent degrade with the doctor still reporting the set present. Sufficiency
# belongs to Tier E (`doctor --smoke`), which runs an adapter for real; this
# tier stays a `command -v` over a stub PATH by design.
# This list does NOT reach a round: pr_doctor_preflight never calls
# pr_doctor_check_utils, so lib/lock.sh checks for flock at the lock site too.
PR_DOCTOR_UTILS="jq rsync git sha256sum timeout readlink sed diff wc flock ps head"

pr_doctor_check_utils() {
  local u missing=()
  for u in $PR_DOCTOR_UTILS; do
    pr_doctor_have "$u" || missing+=("$u")
  done
  if (( ${#missing[@]} == 0 )); then
    pr_d_pass "core utilities present: ${PR_DOCTOR_UTILS// /, }"
    return 0
  fi
  pr_d_fail "missing core utilities: ${missing[*]}"
  pr_d_info "Debian/Ubuntu: sudo apt install jq rsync git coreutils diffutils util-linux procps"
  pr_d_info "macOS: brew install jq rsync coreutils flock, then put the GNU names first:"
  pr_d_info "  PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$PATH\""
  pr_d_info "without that PATH line coreutils installs as greadlink and gtimeout, and this"
  pr_d_info "check still fails. flock is its own formula; util-linux is keg-only."
  return 1
}

# Presence is not sufficiency: PR_DOCTOR_UTILS proves timeout EXISTS, and the
# execution kernel's group sweep additionally requires GNU coreutils'
# behaviour -- timeout placing ITSELF in a new process group, which is what
# makes `kill -- -$pid` reach the adapter's tree (measured 2026-08-27; the
# transcript is in lib/adapter-exec.sh's header). busybox timeout stays in
# the caller's group and the sweep is then silently inert, in the same
# environment where busybox ps already rejects -eo. A FAIL, not a warning:
# README's Requirements already demand GNU coreutils, and a warning invites
# running with a load-bearing sweep that does nothing.
# The version check, not a capability probe: `timeout 1 sleep 0` is racy --
# the child can exit before ps samples it -- and would argue against the
# project's own stated baseline. Bash-builtin match on purpose: this file
# parses with builtins only, so the stub-PATH doctor tests stay green.
pr_doctor_check_gnu_timeout() {
  local v
  # Through pr_doctor_run like every other version read in this file, not a bare
  # command substitution: a substitution is held open by any descendant that
  # inherited stdout, and the two-file capture is what bounds that. The risk from
  # `timeout --version` itself is small; being the one probe here that does not
  # follow the file's own rule is the actual cost. Watchdogging timeout WITH
  # timeout is circular but harmless -- the outer copy only has to wait, and
  # where the inner one is not GNU the outer is the same binary and the FAIL
  # below is what the operator gets either way.
  # 2>&1, unlike pr_doctor_version_of: busybox timeout answers --version with a
  # usage block on STDERR, which is the diagnostic the `got:` line should show.
  # Safe here because the match is the fixed string "GNU coreutils", which no
  # deprecation notice on stderr turns into a false pass.
  v="$(pr_doctor_run 10 timeout --version 2>&1)"
  if [[ "$v" == *"GNU coreutils"* ]]; then
    pr_d_pass "timeout is GNU coreutils (the kernel's group sweep depends on its process-group behaviour)"
    return 0
  fi
  pr_d_fail "timeout is not GNU coreutils; the execution kernel's group sweep would be silently inert"
  pr_d_info "got: ${v%%$'\n'*}"
  pr_d_info "macOS: brew install coreutils, then put the GNU names first:"
  pr_d_info "  PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$PATH\""
  return 1
}

# What to say when a reviewer CLI is absent. No install URLs: the three CLIs are
# installed by different mechanisms that change independently of this repo, and a
# stale command line printed with authority is worse than none. codex and agy do
# have self-update subcommands, which is worth knowing when the binary is present
# but old.
pr_doctor_cli_note() {
  case "$1" in
    codex)  printf 'install the Codex CLI (it self-updates with `codex update`)' ;;
    agent)  printf 'install the Cursor CLI, which provides `agent`' ;;
    agy)    printf 'install the Antigravity CLI (it self-updates with `agy update`)' ;;
    claude) printf 'install Claude Code (it self-updates with `claude update`)' ;;
    *)      printf 'install it' ;;
  esac
}

# pr_doctor_check_cli <reviewer-cli-name>
pr_doctor_check_cli() {
  local cli="$1"
  if pr_doctor_have "$cli"; then
    pr_d_pass "$cli on PATH ($(command -v "$cli"))"
    return 0
  fi
  # claude alone gets a location hint, because claude alone is routinely
  # INSTALLED and still absent here. Measured on this machine, 2026-08-26: the
  # native installer puts the binary at ~/.local/bin/claude, a symlink into
  # ~/.local/share/claude/versions/<version> -- and that directory is on an
  # interactive PATH via a shell rc file, which a non-interactive shell never
  # reads. ~/.claude/local/claude, what the old npm `migrate-installer` left
  # behind (alias-only, so invisible to any non-interactive shell), does NOT
  # exist on this machine -- so that half is documented rather than observed,
  # which is why the hint says "documented at" and README.md says the same. It is
  # worth one clause, not the headline.
  # A string branch rather than a lookup table: this file is builtins-only, and
  # one exception does not earn a table.
  local hint=""
  [[ "$cli" == claude ]] && \
    hint=" (usually ~/.local/bin/claude with that directory missing from PATH; legacy installs are documented at ~/.claude/local/claude)"
  pr_d_fail "$cli not on PATH$hint"
  pr_d_info "$(pr_doctor_cli_note "$cli"), or drop that reviewer from the roster"
  pr_d_info "by setting PR_ADAPTER_MAP to the pairs you do want."
  return 1
}

# _pr_doctor_bwrap_probe <probe-name> [output-var]
#
# Runs bwrap with adapters/agy.sh's and claude.sh's exact flag set against a
# throwaway directory, and returns its exit status. It deliberately does NOT use
# the README's `unshare --user --map-root-user true`, because the two are not
# equivalent: Ubuntu 24.04 defaults
# kernel.apparmor_restrict_unprivileged_userns=1, which leaves unshare(1)
# working while denying bwrap's path. The proxy passes on a machine where the
# one reviewer that needs a jail cannot run at all.
#
# The flag set is the point of this function: it must match what the adapters
# run, so it is written once here rather than once per caller.
#
# 200 means the probe directory could not be created, which is a different
# failure from a jail that does not work. It is deliberately outside the range
# bwrap reports (125/126/127 for its own errors) and outside anything the
# payload can return, so the two cannot be confused.
# The locals are underscore-prefixed because <output-var> names a variable in the
# CALLER's scope: an ordinary `out` here would shadow the very variable the
# nameref is supposed to reach.
_pr_doctor_bwrap_probe() {
  local _probe="${TMPDIR:-/tmp}/$1.$$" _said _rc _i _ticks
  mkdir -p "$_probe" 2>/dev/null || return 200
  # Two signals, because "no marker" alone cannot tell containment from a
  # payload that never ran (a no-op bwrap, a quoting error, a bwrap that
  # cannot start at all -- see the AppArmor note below -- all look like
  # silence). The detached writer stamps `spawned` FIRST; the payload exits
  # only once it sees that stamp, so the jail cannot tear the writer down
  # before the stamp exists; the writer stamps `survived` 0.2s later. In a jail
  # that contains -- these flags are the adapters' flags, so --unshare-pid is
  # asserted by construction -- the namespace dies between the two stamps. In
  # one that does not (--die-with-parent alone is PDEATHSIG on the immediate
  # command, not tree cleanup), `survived` lands. Measured both ways on
  # 2026-08-27 with exactly this flag set, which is what the probe now checks
  # rather than assumes
  # (docs/process/probes/2026-08-27-pid-namespace-adapters).
  #
  # Pass = bwrap exited 0 AND spawned exists AND survived never appears within
  # the wait window. The payload's own wait on `spawned` is bounded (exit 1 ->
  # bwrap reports non-zero) so a writer that never starts cannot hang the
  # probe.
  #
  # The wait window is the probe's whole cost, because the pass path always
  # waits it out for a marker that must never appear: measured on this host
  # 2026-08-27, 1.04s at the default 10 ticks against 0.33s at 3. It is
  # generous against a loaded host, and PR_BWRAP_PROBE_TICKS is what lets the
  # offline suite and the round's preflight shrink it -- not a knob for
  # operators to tune. A non-numeric value is CLAMPED to the default rather
  # than honoured: `(( _i < abc ))` reads an unset name as 0, which would skip
  # the containment window entirely and pass a jail that does not contain --
  # a silent false pass on the one thing this probe exists to measure. Clamped
  # rather than refused because the knob is ours, not operator input, and the
  # measurement is still correct at the default.
  #
  # The payload takes $_probe as an ARGV word, not by interpolation into the
  # `bash -c` string: $_probe derives from $TMPDIR, so a `$(...)` or a backtick
  # in an operator's TMPDIR would otherwise execute here.
  #
  # No `setsid`: a plain `&` measures the same thing, and setsid is util-linux,
  # a dependency PR_DOCTOR_UTILS never declared and whose absence would fail
  # this probe -- and so block `plan-review init` -- on a machine whose jail is
  # fine. All the writer has to be is NOT the immediate command bwrap set
  # PR_SET_PDEATHSIG on, and a background job already is not; the namespace
  # teardown that contains it cares about neither process group nor session.
  # Measured both ways 2026-08-27 with exactly this payload: `survived` lands
  # without --unshare-pid and never with it.
  #
  # The writer's own output goes to /dev/null on purpose: this is a command
  # substitution, and a descendant that inherited the pipe would hold it open
  # past bwrap's exit -- the same trap adapters/agy.sh documents.
  _said="$(bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp \
                 --bind "$_probe" "$_probe" --die-with-parent \
                 --unshare-uts --unshare-ipc --unshare-pid \
                 bash -c '{ : > "$1/spawned"; sleep 0.2; : > "$1/survived"; } \
                            > /dev/null 2>&1 &
                          for (( i = 0; i < 100; i++ )); do
                            [[ -e "$1/spawned" ]] && exit 0
                            sleep 0.01
                          done
                          exit 1' _ "$_probe" 2>&1)"
  _rc=$?
  if (( _rc == 0 )) && [[ ! -e "$_probe/spawned" ]]; then
    _said="the probe payload never started its detached writer"
    _rc=1
  fi
  _ticks="${PR_BWRAP_PROBE_TICKS:-10}"
  [[ "$_ticks" =~ ^[1-9][0-9]*$ ]] || _ticks=10
  # SLEEP FIRST, then check. Same wall time, one more useful check inside it:
  # the writer stamps `survived` 0.2s after `spawned`, so a check at t=0 can
  # never see anything and the last sleep of a check-first loop was thrown away.
  # Measured 2026-08-27 on this host, against this payload with --unshare-pid
  # REMOVED so the marker really does land, ten runs each: check-first at three
  # ticks caught it at the third and last check every time -- zero spare checks,
  # not the "delay plus half again" the preflight comment used to claim -- and
  # sleep-first at three ticks caught it at the second, leaving one whole tick
  # of slack. Sixty-four spinners on thirty-two cores did not move either
  # number. The failure direction is what makes this worth the swap: a marker
  # that lands after the last check reads as a PASS.
  if (( _rc == 0 )); then
    for (( _i = 0; _i < _ticks; _i++ )); do
      sleep 0.1
      if [[ -e "$_probe/survived" ]]; then
        _said="a detached process survived the jail's exit and wrote its marker"
        _rc=1
        break
      fi
    done
  fi
  # rm -rf, not rmdir: the probe directory now holds markers, and on the
  # failing paths it holds one written by a process the jail did not contain.
  rm -rf "$_probe" 2>/dev/null
  if [[ -n "${2:-}" ]]; then local -n _sink="$2"; _sink="$_said"; fi
  return "$_rc"
}

pr_doctor_check_bwrap_jail() {
  if ! pr_doctor_have bwrap; then
    pr_d_fail "bwrap (bubblewrap) not on PATH"
    pr_d_info "Debian/Ubuntu: sudo apt install bubblewrap"
    pr_d_info "agy's own --sandbox was measured NOT confining writes, and Claude Code"
    pr_d_info "exposes no sandbox flag at all, so bubblewrap is the only write barrier"
    pr_d_info "either reviewer has. Both adapters refuse to run without it. Dropping"
    pr_d_info "them from the roster is the other way out."
    pr_d_info "macOS has no bubblewrap and no equivalent is wired up yet, so there it is"
    pr_d_info "the ONLY way out: plan-review init --repo <dir> --reviewers codex,agent"
    return 1
  fi

  local out rc
  _pr_doctor_bwrap_probe pr-doctor-jail out
  rc=$?
  if (( rc == 200 )); then
    pr_d_fail "cannot create a probe directory under ${TMPDIR:-/tmp}"
    return 1
  fi

  if (( rc == 0 )); then
    pr_d_pass "bwrap jail contains a detached process (the flags adapters/agy.sh and claude.sh run)"
    return 0
  fi
  pr_d_fail "bwrap is installed but the jail those reviewers run in does not work (exit $rc)"
  [[ -n "$out" ]] && pr_d_info "bwrap said: ${out%%$'\n'*}"
  pr_d_info "On Ubuntu 24.04 and later this is usually AppArmor. Check with:"
  pr_d_info "  sysctl kernel.apparmor_restrict_unprivileged_userns"
  pr_d_info "A 1 there denies bwrap while leaving unshare(1) working, which is why"
  pr_d_info "this probe runs bwrap itself rather than the unshare check in the README."
  return 1
}

# adapters/agent.sh's bwrap is a PID FENCE, not a write barrier, and unlike agy
# and claude that adapter does not fail closed: with no working jail it runs the
# reviewer unwrapped and the execution kernel's best-effort descendant sweep
# becomes the only bound (docs/adapter-contract.md, the containment clause).
# So this reports a WARN, never a failure -- there is no refusal here to
# predict, and failing a machine for it would refuse a roster that works.
#
# It exists because the alternative was worse: with agent on the roster and
# neither agy nor claude, the doctor used to print "no reviewer here needs the
# bubblewrap jail", which stopped being true the moment agent started using one.
# Only called in that case; when agy or claude is present,
# pr_doctor_check_bwrap_jail runs the same probe under the strict rule.
pr_doctor_check_agent_pid_fence() {
  local out rc
  if ! pr_doctor_have bwrap; then
    pr_d_warn "no bwrap: agent runs without a pid namespace"
    pr_d_info "Cursor's tool layer takes its own process group AND session, so a"
    pr_d_info "background process it spawns can outlive the round and keep holding"
    pr_d_info "the session lock. bwrap --unshare-pid is what disposes of it."
    pr_d_info "Debian/Ubuntu: sudo apt install bubblewrap. Expected on macOS, which"
    pr_d_info "has neither bubblewrap nor pid namespaces."
    return 0
  fi
  _pr_doctor_bwrap_probe pr-doctor-agent-fence out
  rc=$?
  if (( rc == 0 )); then
    pr_d_pass "bwrap pid namespace available for agent (a fence, not a write barrier)"
    return 0
  fi
  if (( rc == 200 )); then
    pr_d_warn "cannot create a probe directory under ${TMPDIR:-/tmp}; agent's pid fence is unverified"
    return 0
  fi
  pr_d_warn "bwrap is installed but its jail does not work; agent runs without a pid namespace"
  [[ -n "$out" ]] && pr_d_info "bwrap said: ${out%%$'\n'*}"
  pr_d_info "On Ubuntu 24.04 and later this is usually AppArmor. Check with:"
  pr_d_info "  sysctl kernel.apparmor_restrict_unprivileged_userns"
  pr_d_info "The reviewer still runs -- adapters/agent.sh degrades to unwrapped rather"
  pr_d_info "than refusing -- but a process it leaks is bounded only by the runner's"
  pr_d_info "best-effort descendant sweep."
  return 0
}

pr_doctor_check_cache_root() {
  local root="${PR_CACHE_ROOT:-$HOME/.cache/plan-review}"
  if mkdir -p "$root" 2>/dev/null && [[ -w "$root" ]]; then
    pr_d_pass "sandbox root writable: $root"
    return 0
  fi
  pr_d_fail "sandbox root not writable: $root"
  pr_d_info "Each reviewer gets a full copy of the target repo here, every round."
  pr_d_info "Override the location with PR_CACHE_ROOT."
  return 1
}

# ---------------------------------------------------------------------------
# Tier B: liveness and auth. Reaches the network. Never spends tokens: no
# inference call is made anywhere in this file, only status and list endpoints.
# ---------------------------------------------------------------------------

pr_doctor_check_codex_auth() {
  pr_doctor_have codex || { pr_d_fail "codex auth: codex not on PATH"; return 1; }
  local out rc
  out="$(pr_doctor_run 30 codex login status 2>&1)"
  rc=$?
  if (( rc == 0 )); then
    pr_d_pass "codex authenticated (${out%%$'\n'*})"
    return 0
  fi
  pr_d_fail "codex is not authenticated (codex login status exit $rc)"
  [[ -n "$out" ]] && pr_d_info "${out%%$'\n'*}"
  pr_d_info "Fix with: codex login"
  return 1
}

# Model lists are the source of truth for the pin check, and for agy they double
# as the auth probe. Fetched once and cached so a full run makes one call per CLI.
PR_DOCTOR_AGENT_MODELS=""
PR_DOCTOR_AGY_MODELS=""

# Why the last fetch failed, for whoever is printing. Empty after a success.
# The fetchers themselves print nothing: libexec/plan-review-init.sh calls them
# outside a doctor report, where a stray PASS line would be counted by nobody.
PR_DOCTOR_AGENT_MODELS_ERR=""
PR_DOCTOR_AGY_MODELS_ERR=""

# Counts lines that look like a model listing. Judge the list on this as well as
# on the exit code: `agy models` prints a progress line before the ids, and a CLI
# that fails while exiting 0 would otherwise read as a pass.
#
# Two clauses, because neither alone is enough:
#   separator  both CLIs print `<id><sep><label>` -- agent uses " - ", agy a tab.
#              This is what catches Cursor's `auto`, whose id has no punctuation
#              in it at all.
#   id shape   a dash or a dot in the first field, so a bare one-id-per-line
#              format would still be counted if either CLI ever prints one.
# Prose lines have neither: "Available models" and "Fetching available models..."
# carry no separator and no punctuation in their first word.
pr_doctor_is_id_line() {
  local tok="${1%%[[:space:]]*}"
  [[ "$1" == *$'\t'* || "$1" == *" - "* || "$tok" == *[-.]* ]]
}

pr_doctor_count_ids() {
  local line n=0
  while IFS= read -r line; do
    pr_doctor_is_id_line "$line" && n=$((n + 1))
  done <<< "$1"
  printf '%s' "$n"
}

# pr_doctor_model_listed <models-text> <pin>
# Exact match on the first field. Both CLIs print `<id><separator><label>`; agent
# uses " - " and agy a tab, and %%[[:space:]]* handles both.
pr_doctor_model_listed() {
  local line
  while IFS= read -r line; do
    [[ "${line%%[[:space:]]*}" == "$2" ]] && return 0
  done <<< "$1"
  return 1
}

# pr_doctor_fetch_agent_models / pr_doctor_fetch_agy_models
#
# One place per CLI knows how to ask it for its models. Quiet, cached, and
# offline-aware; 0 means the global now holds a list, 1 means it does not and
# PR_DOCTOR_*_MODELS_ERR says why. The auth check, the pin check and
# libexec/plan-review-init.sh all come through here, so "which models exist" cannot
# be answered two ways in one repo.
pr_doctor_fetch_agent_models() {
  [[ -n "$PR_DOCTOR_AGENT_MODELS" ]] && return 0
  PR_DOCTOR_AGENT_MODELS_ERR=""
  if [[ "${PR_DOCTOR_OFFLINE:-0}" == 1 ]]; then
    PR_DOCTOR_AGENT_MODELS_ERR="offline: no model list was fetched"
    return 1
  fi
  if ! pr_doctor_have agent; then
    PR_DOCTOR_AGENT_MODELS_ERR="agent not on PATH"
    return 1
  fi
  local out rc n
  out="$(pr_doctor_run 60 agent --list-models 2>&1)"
  rc=$?
  n="$(pr_doctor_count_ids "$out")"
  if (( n > 0 )); then
    PR_DOCTOR_AGENT_MODELS="$out"
    return 0
  fi
  PR_DOCTOR_AGENT_MODELS_ERR="agent --list-models exit $rc, $n model ids parsed"
  return 1
}

pr_doctor_fetch_agy_models() {
  [[ -n "$PR_DOCTOR_AGY_MODELS" ]] && return 0
  PR_DOCTOR_AGY_MODELS_ERR=""
  if [[ "${PR_DOCTOR_OFFLINE:-0}" == 1 ]]; then
    PR_DOCTOR_AGY_MODELS_ERR="offline: no model list was fetched"
    return 1
  fi
  if ! pr_doctor_have agy; then
    PR_DOCTOR_AGY_MODELS_ERR="agy not on PATH"
    return 1
  fi
  local out rc n
  out="$(pr_doctor_run 60 agy models 2>&1)"
  rc=$?
  n="$(pr_doctor_count_ids "$out")"
  # Judged on the parsed count as well as the exit code: `agy models` prints a
  # progress line before the ids, and a CLI that fails while exiting 0 would
  # otherwise read as a list of nothing.
  if (( rc == 0 && n > 0 )); then
    PR_DOCTOR_AGY_MODELS="$out"
    return 0
  fi
  PR_DOCTOR_AGY_MODELS_ERR="exit $rc, $n model ids parsed"
  [[ -n "$out" ]] && PR_DOCTOR_AGY_MODELS_ERR+=$'\n'"${out%%$'\n'*}"
  return 1
}

# `agent` is a generic name, and `command -v agent` cannot tell the Cursor CLI
# from any other tool that happens to be called agent. `agent about --format
# json` can: it answers with a structured cliVersion. Verified against
# 2026.08.11-e8db854 on 2026-08-17.
#
# `about` also returns the account's userEmail. It is never echoed here -- a
# doctor's output gets pasted into issues -- which is the rule
# pr_doctor_check_claude_auth already follows for the account address.
pr_doctor_check_agent_identity() {
  pr_doctor_have agent || return 0   # absence is already a FAIL in Tier A
  local out rc ver
  out="$(pr_doctor_run 15 agent about --format json 2>&1)"
  rc=$?
  ver="$(jq -r '.cliVersion // ""' <<< "$out" 2>/dev/null)"
  if (( rc == 0 )) && [[ -n "$ver" ]]; then
    pr_d_pass "agent is the Cursor CLI, version $ver"
    return 0
  fi
  pr_d_fail "the agent on PATH does not answer 'agent about --format json' (exit $rc)"
  pr_d_info "$(command -v agent) may be a different tool with the same name."
  pr_d_info "adapters/agent.sh would run it with Cursor's flags and fail mid-round."
  return 1
}

# Cursor's own status subcommand, structured, rather than a 60-second model-list
# call standing in for one. `agent status --format json` answers exactly the
# question being asked -- would a round authenticate -- and `--list-models` is
# left to the only thing that still needs it, validating a pin.
#
# Judged on isAuthenticated rather than on the exit code, for the reason agy
# taught: a CLI that fails while exiting 0 would otherwise read as a pass.
pr_doctor_check_agent_auth() {
  pr_doctor_have agent || { pr_d_fail "Cursor auth: agent not on PATH"; return 1; }
  local out rc authed
  out="$(pr_doctor_run 30 agent status --format json 2>&1)"
  rc=$?
  authed="$(jq -r 'if .isAuthenticated == true then "true" else "false" end' \
             <<< "$out" 2>/dev/null)"
  if (( rc == 0 )) && [[ "$authed" == "true" ]]; then
    pr_d_pass "Cursor authenticated (agent status)"
    return 0
  fi
  pr_d_fail "Cursor is not authenticated (exit $rc, isAuthenticated=${authed:-unparseable})"
  pr_d_info "Log in with the Cursor CLI, or set CURSOR_API_KEY."
  return 1
}

# agy has no status subcommand, so the model list IS the auth probe. The fetch
# itself lives in pr_doctor_fetch_agy_models; what is here is the reporting.
pr_doctor_check_agy_auth() {
  pr_doctor_have agy || { pr_d_fail "agy auth: agy not on PATH"; return 1; }
  if pr_doctor_fetch_agy_models; then
    pr_d_pass "agy answered: $(pr_doctor_count_ids "$PR_DOCTOR_AGY_MODELS") models available"
    return 0
  fi
  pr_d_fail "agy models failed (${PR_DOCTOR_AGY_MODELS_ERR%%$'\n'*})"
  [[ "$PR_DOCTOR_AGY_MODELS_ERR" == *$'\n'* ]] && pr_d_info "${PR_DOCTOR_AGY_MODELS_ERR#*$'\n'}"
  # Verified against agy 1.1.13: `agy help` lists agent(s), changelog, help,
  # install, models, plugin(s) and update. There is no login and no logout, so
  # re-authenticating means one interactive run -- there is no headless fix to
  # print here.
  pr_d_info "agy has no login subcommand. Run \`agy\` interactively once to"
  pr_d_info "re-authenticate; its OAuth token lives under ~/.gemini/antigravity-cli/."
  return 1
}

# agy carries a deadline of its own INSIDE the runner's. adapters/agy.sh now
# passes it explicitly, derived from PR_TIMEOUT_SECS, so what matters here is no
# longer the default -- it is whether the flag we pass is still accepted. A
# renamed or dropped flag would make agy fall back to its own 5m0s and cut long
# reviews short with no signal. Offline: `agy --help` makes no network call.
pr_doctor_check_agy_print_timeout() {
  pr_doctor_have agy || return 0
  local out
  out="$(pr_doctor_run 15 agy --help 2>&1)"
  if [[ "$out" == *"--print-timeout"* ]]; then
    pr_d_pass "agy still accepts --print-timeout (adapters/agy.sh derives it from PR_TIMEOUT_SECS)"
    return 0
  fi
  pr_d_fail "agy no longer lists --print-timeout in its help"
  pr_d_info "adapters/agy.sh passes that flag. Without it agy falls back to its own"
  pr_d_info "5m0s default, which silently cuts long reviews short."
  return 1
}

# The only reviewer with a structured auth status. Judged on the loggedIn field
# rather than on the exit code, for the reason agy taught: a CLI that fails while
# exiting 0 would otherwise read as a pass.
#
# `claude auth status` also prints the account email, org id and org name. None
# of that is echoed here -- a doctor's output gets pasted into issues.
#
# Absence is a failure here, as it is for the other three. It was a silent
# `return 0` while claude was a swap-in that no default roster asked for; now
# the caller only reaches this when claude is a reviewer this round.
pr_doctor_check_claude_auth() {
  pr_doctor_have claude || { pr_d_fail "claude auth: claude not on PATH"; return 1; }
  local out rc logged_in method plan
  out="$(pr_doctor_run 30 claude auth status 2>&1)"
  rc=$?
  logged_in="$(jq -r '.loggedIn // false' <<< "$out" 2>/dev/null)"
  if (( rc == 0 )) && [[ "$logged_in" == "true" ]]; then
    method="$(jq -r '.authMethod // "?"' <<< "$out" 2>/dev/null)"
    plan="$(jq -r '.subscriptionType // "?"' <<< "$out" 2>/dev/null)"
    pr_d_pass "claude authenticated ($method, $plan)"
    return 0
  fi
  pr_d_fail "claude is not authenticated (exit $rc, loggedIn=$logged_in)"
  pr_d_info "Fix with: claude auth login"
  return 1
}

# Effort is validated offline against the enum the backend enforces. codex does
# not reject an invalid value locally: --strict-config checks the key name only,
# and the value comes back as a 400 at request time, after the round has started.
PR_EFFORTS_CODEX="none minimal low medium high xhigh max"

# pr_doctor_effort_note <cli>
# Why a bad tier for this CLI matters, one line per line of output. The doctor
# reports it and lib/config.sh refuses on it, so it is written once here rather
# than once per caller -- the two used to carry the same paragraph verbatim.
#
# The set of CLIs with an effort axis at all is exactly the set with a
# PR_EFFORTS_<CLI> enum above; lib/init.sh's pr_init_has_effort reads it that way
# rather than naming them again.
pr_doctor_effort_note() {
  case "$1" in
    codex)
      printf '%s\n' "codex accepts the key but the backend rejects the value with a 400," \
                    "minutes into the round rather than now." ;;
    claude)
      printf '%s\n' "This enum differs from codex's, which also accepts none and minimal." ;;
  esac
}

pr_doctor_check_codex_effort() {
  if [[ -z "${PR_CODEX_EFFORT:-}" ]]; then
    pr_d_info "PR_CODEX_EFFORT unset: codex will use its configured default."
    return 0
  fi
  if [[ " $PR_EFFORTS_CODEX " == *" $PR_CODEX_EFFORT "* ]]; then
    pr_d_pass "PR_CODEX_EFFORT=$PR_CODEX_EFFORT is a valid tier"
    return 0
  fi
  pr_d_fail "PR_CODEX_EFFORT='$PR_CODEX_EFFORT' is not one of: $PR_EFFORTS_CODEX"
  local line
  while IFS= read -r line; do pr_d_info "$line"; done < <(pr_doctor_effort_note codex)
  return 1
}

# A different enum from codex's: Claude Code's --effort has no `none` and no
# `minimal`. Validating it offline is the only check available for this axis --
# S2 measured that the effective effort is reported in neither output format, so
# unlike codex there is no post-hoc assertion the adapter can make.
PR_EFFORTS_CLAUDE="low medium high xhigh max"

pr_doctor_check_claude_effort() {
  pr_doctor_have claude || return 0
  if [[ -z "${PR_CLAUDE_EFFORT:-}" ]]; then
    return 0
  fi
  if [[ " $PR_EFFORTS_CLAUDE " == *" $PR_CLAUDE_EFFORT "* ]]; then
    pr_d_pass "PR_CLAUDE_EFFORT=$PR_CLAUDE_EFFORT is a valid tier"
    pr_d_info "Passed through unverified: Claude Code reports no effective effort,"
    pr_d_info "so round.json cannot record which tier actually answered."
    return 0
  fi
  pr_d_fail "PR_CLAUDE_EFFORT='$PR_CLAUDE_EFFORT' is not one of: $PR_EFFORTS_CLAUDE"
  local line
  while IFS= read -r line; do pr_d_info "$line"; done < <(pr_doctor_effort_note claude)
  return 1
}

# pr_doctor_check_pins [reviewer-names]
#
# The argument is the set of SHIPPED adapters this round actually runs, derived
# by the caller from the adapter map's paths -- never from its keys, and never
# from the orchestrator. A map may alias one adapter under another key, and a
# test may run a fake under a real name; pins belong to the CLI at the end of the
# path. Empty means "no roster to speak of": all four are reported.
#
# An unset pin is reported as context, not as a failure. Pins can come from a
# project config now, but they are still optional for two of the four CLIs, so
# failing on absence would fire for everyone with no config and tell them
# nothing. A pin that IS set and does not exist is a failure: the round would die
# in the adapter after the sandbox copy, forfeiting that reviewer's session.
# Empty list means "no roster to speak of": report everything. Deliberately not
# expressed as a default naming the four adapters -- that list belongs to
# lib/roster.sh, and this file cannot source it (tests/test-doctor.sh runs with
# nothing but lib/doctor.sh and a stub PATH).
_pr_doctor_wants() {
  [[ -z "$1" || " $1 " == *" $2 "* ]]
}

pr_doctor_check_pins() {
  local names="${1:-}" rc=0

  # The Cursor model list is fetched HERE, not by the auth check: `agent status`
  # answers auth now, and a pin is the only thing left that needs the list. A
  # machine with no pin set does not pay for the call at all.
  if _pr_doctor_wants "$names" agent && [[ -n "${PR_AGENT_MODEL:-}" ]]; then
    pr_doctor_fetch_agent_models || true
  fi

  if ! _pr_doctor_wants "$names" agent; then
    :
  elif [[ -z "${PR_AGENT_MODEL:-}" ]]; then
    pr_d_info "PR_AGENT_MODEL unset. It is REQUIRED at round time: Cursor never"
    pr_d_info "reports which model answered, so round.json could not record it."
  elif [[ -z "$PR_DOCTOR_AGENT_MODELS" ]]; then
    pr_d_warn "PR_AGENT_MODEL=$PR_AGENT_MODEL not checked: no model list to check against"
  elif pr_doctor_model_listed "$PR_DOCTOR_AGENT_MODELS" "$PR_AGENT_MODEL"; then
    pr_d_pass "PR_AGENT_MODEL=$PR_AGENT_MODEL exists"
  else
    pr_d_fail "PR_AGENT_MODEL=$PR_AGENT_MODEL is not in agent --list-models"
    pr_d_info "The id carries the effort tier, e.g. claude-opus-5-thinking-high."
    rc=1
  fi

  if ! _pr_doctor_wants "$names" agy; then
    :
  elif [[ -z "${PR_AGY_MODEL:-}" ]]; then
    pr_d_info "PR_AGY_MODEL unset. It is REQUIRED at round time, for the same reason."
  elif [[ -z "$PR_DOCTOR_AGY_MODELS" ]]; then
    pr_d_warn "PR_AGY_MODEL=$PR_AGY_MODEL not checked: no model list to check against"
  elif pr_doctor_model_listed "$PR_DOCTOR_AGY_MODELS" "$PR_AGY_MODEL"; then
    pr_d_pass "PR_AGY_MODEL=$PR_AGY_MODEL exists"
  else
    pr_d_fail "PR_AGY_MODEL=$PR_AGY_MODEL is not in agy models"
    pr_d_info "The id carries the effort tier, e.g. gemini-3.1-pro-high. Ceiling is high."
    rc=1
  fi

  if _pr_doctor_wants "$names" codex && [[ -n "${PR_CODEX_MODEL:-}" ]]; then
    pr_d_info "PR_CODEX_MODEL=$PR_CODEX_MODEL is passed through unchecked; codex"
    pr_d_info "reports the effective model in its banner either way."
  fi

  # Unchecked for the same reason as codex's, but the reason it CANNOT be checked
  # is worth stating: Claude Code has no model-listing command, and the only way
  # to test a pin is to run it -- which bills a real request when the pin is
  # valid, so it does not belong in a doctor that costs nothing. S2 measured the
  # consolation: an unrecognised model exits 1 in under a second having spent
  # exactly $0, so a typo costs a reviewer slot rather than money.
  if _pr_doctor_wants "$names" claude && [[ -n "${PR_CLAUDE_MODEL:-}" ]]; then
    pr_d_info "PR_CLAUDE_MODEL=$PR_CLAUDE_MODEL is passed through unchecked; the init"
    pr_d_info "line reports the resolved model, so round.json records what answered."
  fi

  return "$rc"
}

# ---------------------------------------------------------------------------
# Tier C: version drift. Warns, never fails.
# ---------------------------------------------------------------------------

# First whitespace-delimited token that starts with a digit. Covers all three
# formats without a per-tool parser: `codex-cli 0.147.0`, `2026.08.11-e8db854`,
# `1.1.13`, `bubblewrap 0.9.0`. Note codex --version says `codex-cli 0.147.0`
# while its banner says `OpenAI Codex v0.147.0` -- same number, different label,
# which is why the number is what gets compared.
pr_doctor_version_of() {
  local out tok
  # Through pr_doctor_run, not a bare substitution: a CLI that leaves a
  # descendant on stdout would otherwise hang the whole doctor on a --version
  # call. 10s is generous for a version string.
  out="$(pr_doctor_run 10 "$1" --version 2>/dev/null)" || return 1
  out="${out%%$'\n'*}"
  # Unquoted on purpose: word splitting is the parse. Globbing is off for the
  # duration so a version string could not be expanded against the filesystem.
  set -f
  for tok in $out; do
    if [[ "$tok" == [0-9]* ]]; then
      set +f
      printf '%s' "$tok"
      return 0
    fi
  done
  set +f
  return 1
}

pr_doctor_check_versions() {
  local file="${PR_DOCTOR_VERSIONS_FILE:-${PR_ROOT:-.}/docs/verified-versions.txt}"
  if [[ ! -f "$file" ]]; then
    pr_d_warn "no verified-versions file at $file; skipping drift checks"
    return 0
  fi

  # Compared against the count on entry, not against zero: an earlier tier's
  # warning (an unchecked pin, say) must not make this section print a drift
  # explanation for drift that did not happen.
  local warn_before="$PR_DOCTOR_WARN"
  local tool want got
  while read -r tool want _; do
    [[ -z "$tool" || "$tool" == \#* ]] && continue
    # Absence is already a FAIL in Tier A. Repeating it here would double-count
    # one problem as two.
    pr_doctor_have "$tool" || continue
    got="$(pr_doctor_version_of "$tool")" || got=""
    if [[ -z "$got" ]]; then
      pr_d_warn "$tool: could not read a version from --version output"
    elif [[ "$got" == "$want" ]]; then
      pr_d_pass "$tool $got matches the verified version"
    else
      pr_d_warn "$tool is $got; the adapters were verified against $want"
    fi
  done < "$file"

  if (( PR_DOCTOR_WARN > warn_before )); then
    pr_d_info "Drift is a warning, not a failure: a newer CLI usually works. What it"
    pr_d_info "puts at risk is the banner and flag behaviour the adapters assert --"
    pr_d_info "codex.sh fails closed on an unexpected sandbox line, which costs a round."
    pr_d_info "Re-run the version probes and update $file."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Tier D: the target repo. Requires --repo; --plan adds the plan-specific checks.
# ---------------------------------------------------------------------------

pr_doctor_check_repo() {
  local repo="$1"
  if [[ ! -d "$repo" ]]; then
    pr_d_fail "no such directory: $repo"
    return 1
  fi
  if ! git -C "$repo" rev-parse --git-dir > /dev/null 2>&1; then
    pr_d_fail "$repo is not a git repository"
    pr_d_info "The runner records HEAD and the worktree hash for every round, and"
    pr_d_info "strips remotes from each sandbox copy. Both need a repository."
    return 1
  fi
  pr_d_pass "target repo is a git repository: $repo"
  return 0
}

# `git check-ignore` rather than a grep of .gitignore: the rule is equally valid
# in .git/info/exclude or a global core.excludesFile, and grepping one file would
# report a false failure on a repo that ignores it somewhere else.
pr_doctor_check_artifacts_ignored() {
  local repo="$1"
  if git -C "$repo" check-ignore -q .plan-review/ 2>/dev/null; then
    pr_d_pass ".plan-review/ is gitignored in the target repo"
    return 0
  fi
  pr_d_fail ".plan-review/ is NOT ignored in $repo"
  pr_d_info "Rounds write reviews, prompts and rationale there. Un-ignored, the next"
  pr_d_info "commit in that repo would carry them. Fix with:"
  pr_d_info "  echo '.plan-review/' >> $repo/.gitignore"
  return 1
}

# pr_doctor_check_plan <repo> <repo-relative-plan>
# Containment is pr_path_resolve_within's, the same call the runner makes, so a
# plan the doctor accepts is a plan the runner accepts.
pr_doctor_check_plan() {
  local repo="$1" plan_rel="$2" plan_abs repo_abs
  if [[ ! -f "$repo/$plan_rel" ]]; then
    pr_d_fail "no such plan: $repo/$plan_rel"
    return 1
  fi
  if ! pr_path_resolve_within "$repo" "$repo/$plan_rel" plan_abs repo_abs; then
    pr_d_fail "the plan resolves outside the repository"
    pr_d_info "$plan_abs is not under $repo_abs (a symlink, most likely)."
    return 1
  fi
  if [[ ! -s "$repo/$plan_rel" ]]; then
    pr_d_fail "the plan is empty: $repo/$plan_rel"
    return 1
  fi
  pr_d_pass "plan readable: $plan_rel"
  return 0
}

# Answers "why will the next round not start". The runner's guard is an
# allow-list: only `complete` and `aborted` let round N+1 begin, so a crashed
# round blocks just as hard as one awaiting integration.
# pr_doctor_check_rounds <repo> <repo-relative-plan>
pr_doctor_check_rounds() {
  local repo="$1" plan_rel="$2"
  if ! declare -F pr_session_key > /dev/null || ! declare -F pr_round_highest > /dev/null \
     || ! declare -F pr_lock_probe > /dev/null; then
    pr_d_warn "lib/paths.sh, lib/round.sh or lib/lock.sh not sourced; cannot locate the session"
    return 0
  fi
  pr_doctor_have jq || { pr_d_warn "jq missing; cannot read round state"; return 0; }

  local canon key artifact_dir highest
  canon="$(cd "$repo" && pwd)"
  key="$(pr_session_key "$canon" "$plan_rel")" || {
    pr_d_fail "could not derive a session key for $plan_rel"
    return 1
  }
  artifact_dir="$(pr_artifact_dir "$canon" "$key")"
  highest="$(pr_round_highest "$artifact_dir")"

  # The session lock, probed and released. round.json cannot answer this: its
  # state is written once, so `reviewing` reads the same whether a runner is
  # working right now or died three days ago. The lock is held by every process
  # the runner spawned, so it is the one thing that tells those two apart.
  local lock_file lock_rc locked_pid=""
  lock_file="$(pr_session_lock "$artifact_dir")"
  pr_lock_probe "$lock_file"; lock_rc=$?
  case "$lock_rc" in
    "$PR_LOCK_BUSY")
      locked_pid="$(pr_lock_pid "$lock_file")"
      # "started by", never "pid N is the runner". pr_lock_explain is careful
      # about this because pids get reused, and the one command whose whole job
      # is diagnosis should not be the one that overstates what it knows.
      pr_d_info "a review is running in this session${locked_pid:+ (started by pid $locked_pid)}; wait for it to finish" ;;
    0) ;;
    # Never "busy": an unreadable lock must not send the operator away to wait
    # for something that will never finish.
    *) pr_d_warn "could not determine the session lock state: $lock_file" ;;
  esac

  if (( highest == 0 )); then
    pr_d_pass "no previous rounds; the next round will be round 1"
    return 0
  fi

  local prev_dir state
  prev_dir="$(pr_round_dir "$artifact_dir" "$highest")"
  state="$(pr_round_state "$prev_dir")"

  if pr_round_can_start "$state"; then
    # Not the whole truth for aborted: the runner refuses that round without
    # --fresh (pr_round_needs_fresh -- the shared rule, lib/round.sh). A pass
    # either way: the way is clear, the flag is the way.
    if pr_round_needs_fresh "$state"; then
      pr_d_pass "round $highest is $state; round $((highest + 1)) starts with --fresh only"
      pr_d_info "its resume handles are forfeit; the runner refuses a round without --fresh"
    else
      pr_d_pass "round $highest is $state; round $((highest + 1)) can start"
    fi
    return 0
  fi
  case "$state" in
    awaiting_integration)
      pr_d_fail "round $highest is awaiting_integration; round $((highest + 1)) is blocked"
      pr_d_info "Write the rationale files, then run:"
      pr_d_info "  plan-review complete --round $prev_dir"
      pr_d_info "Or abandon it: plan-review abort --round $prev_dir" ;;
    *)
      pr_d_fail "round $highest is in state '$state' and cannot be left behind"
      # The remedy, only when there is one. A held lock was already reported
      # above, with the advice that goes with it; repeating it here would be a
      # second place to keep that story straight.
      if (( lock_rc != PR_LOCK_BUSY )); then
        pr_d_info "Nothing is running; its runner did not finish."
        pr_d_info "Inspect $prev_dir, then:"
        pr_d_info "  plan-review abort --round $prev_dir"
      fi ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------
# Tier E: smoke. The ONE check that spends tokens, which is why it runs only
# behind `doctor --smoke` and is never reached by a round's preflight. It
# exists because Tier B can lie by omission: an auth probe hits a status
# endpoint, but the exec path is different code in the vendor's CLI -- it can
# hang on an interactive prompt an auth check never reaches, or die on flag
# drift the version check only warns about. The smoke ping is the one check
# that exercises the same path a round does.
#
# The builtins-only rule does not bind here: this tier RUNS adapters, so a
# working PATH is its subject matter, not an assumption to test away.
# tests/test-doctor.sh drives it with fake adapters on the real PATH.
# ---------------------------------------------------------------------------

# Deliberately tiny -- the point is the transport, not the answer -- and
# explicit that no tools should run, so the reply costs the minimum the vendor
# bills. The reply's CONTENT is never asserted: alive means "produced output",
# same as the round; a model that answers in its own words is still alive.
PR_DOCTOR_SMOKE_PROMPT='plan-review doctor connectivity check.
Reply with exactly: SMOKE OK
Do not read files, run tools, or write anything.'

# pr_doctor_check_smoke <adapter-map> <deadline-secs>
#
# One live prompt per reviewer in the map, through the adapter contract exactly
# as a round sends one: same argv, prompt on stdin, the pr_sandbox_* workdir
# layout under a throwaway session key, capped and group-swept by the same core
# as every other probe. Sequential on purpose: the pr_d_* counters are parent
# state, and roster × deadline is an accepted worst case for an opt-in
# diagnostic -- the round's fan-out exists to overlap 15-minute reviews, not
# 90-second pings. Custom adapters are smoked too: they are in the roster, so
# a round would run them.
pr_doctor_check_smoke() {
  local map="$1" secs="$2"
  # Without a cap, the hung-login case this check exists to catch would hang
  # the doctor itself. Uncounted, like every skip: timeout's absence is already
  # a Tier A failure, and counting it again would report one problem as two.
  if ! pr_doctor_have timeout; then
    pr_d_skip "smoke: timeout(1) is missing; an uncapped live call could hang the doctor"
    return 0
  fi
  # Guarded the way pr_doctor_check_rounds guards lib/round.sh: this file is
  # sourceable with nothing beside it, and the smoke must say what is missing
  # rather than die on an unset function. libexec/plan-review-doctor.sh always
  # sources the kernel, so only a unit test can reach this skip.
  if ! declare -F pr_adapter_exec > /dev/null; then
    pr_d_skip "smoke: lib/adapter-exec.sh is not sourced; the smoke tier cannot run adapters"
    return 0
  fi
  local key="doctor-smoke.$$" pair reviewer rc=0
  for pair in $map; do
    reviewer="${pair%%=*}"
    _pr_doctor_smoke_one "$reviewer" "${pair#*=}" "$secs" "$key" || rc=1
  done
  # Empty when every reviewer passed and was discarded; kept otherwise.
  rmdir "$(pr_session_cache_dir "$key")" 2> /dev/null
  return "$rc"
}

# _pr_doctor_smoke_one <reviewer> <adapter-path> <deadline-secs> <session-key>
_pr_doctor_smoke_one() {
  local reviewer="$1" adapter="$2" secs="$3" key="$4"
  local dir workdir tmp
  dir="$(pr_sandbox_dir "$key" "$reviewer")"
  workdir="$(pr_sandbox_repo "$key" "$reviewer")"
  tmp="$(pr_sandbox_tmp "$key" "$reviewer")"
  local review="$dir/review.md" meta="$dir/meta" reason="$dir/reason" log="$dir/log.txt"

  # The round's workdir layout by construction -- the same pr_sandbox_* paths a
  # round hands its adapters, under the PR_CACHE_ROOT that Tier A already
  # verified writable -- minus the repo copy a ping has no use for. No git
  # init: codex passes --skip-git-repo-check and the other three only cd or
  # bind the directory.
  if ! mkdir -p "$tmp" 2>/dev/null; then
    pr_d_fail "smoke: $reviewer: cannot create $workdir"
    return 1
  fi

  # PR_TIMEOUT_SECS no longer travels as an env word: the kernel exports the
  # deadline it is handed, and that is exactly $secs -- the SMOKE deadline, not
  # the round's 900s default, which would put agy's derived inner
  # --print-timeout far outside the outer one. TMPDIR is the ninth positional,
  # per the adapter contract a private directory inside the workdir. One value
  # each, one channel each, so the two cannot drift apart here.
  # PR_KILL_GRACE_SECS the kernel reads itself, with the same default this file
  # used to pass.
  local rc=0 timed_out=0
  pr_adapter_exec "$adapter" "$workdir" "" "$review" "$meta" "$reason" \
    "$log" "$secs" "$tmp" rc timed_out \
    <<< "$PR_DOCTOR_SMOKE_PROMPT"

  # Judge on output, not the exit code alone -- the round's rule: Cursor exits
  # 2 on a denied tool call while still producing a correct review (D7).
  #
  # $review is read in place: the smoke deliberately does NOT publish it the
  # way lib/reviewer-runner.sh does. Publication exists so the round's record
  # and its artifact describe the same bytes; the smoke keeps no record and
  # judges only alive/dead, and the file is a diagnostic that is deleted three
  # lines below on success. A survivor appending to it after the sweep could
  # at worst turn a dead reviewer into a live-looking one -- which is the
  # reviewer being alive, in the only sense this tier claims to measure. So
  # CLAUDE.md's and README.md's "publication is what makes the review artifact
  # final" is a statement about the ROUND, not about this.
  if [[ -s "$review" ]]; then
    pr_d_pass "smoke: $reviewer answered end to end"
    # A smoke session has no next round to carry state into, so the whole
    # directory -- adapter config included -- is discardable, which a round's
    # sandbox (lib/sandbox.sh) deliberately is not. PR_KEEP_SANDBOX means here
    # what it means there: keep the evidence whatever happened.
    [[ "${PR_KEEP_SANDBOX:-0}" != 1 ]] && rm -rf "$dir"
    return 0
  fi

  # An adapter that knows why outranks anything inferred from an exit code --
  # first line only, truncated, exactly as the runner reads reason_out.
  local detail=""
  if [[ -s "$reason" ]]; then
    IFS= read -r detail < "$reason"
    detail="${detail%$'\r'}"
    detail="${detail:0:200}"
  fi
  local why="exit $rc"
  (( timed_out )) && why="timed out after ${secs}s"
  pr_d_fail "smoke: $reviewer produced no output ($why${detail:+ — $detail})"
  if (( timed_out )); then
    pr_d_info "A trivial prompt should not need the round's deadline; a hang here"
    pr_d_info "usually means an interactive login prompt the auth check cannot reach."
  fi
  # The kept directory holds whatever the adapter sited BESIDE the repo copy,
  # and for codex that is a private CODEX_HOME containing a copy of the
  # operator's ~/.codex/auth.json -- adapters/codex.sh copies it in because the
  # reviewer needs it writable. Nothing ever cleans a kept smoke directory: the
  # session key is doctor-smoke.$$, so the rmdir in pr_doctor_check_smoke fails
  # on a non-empty directory and every failed smoke would strand another
  # credential copy under the cache root. The smoke fails most often while an
  # operator is debugging codex auth, i.e. repeatedly, and `codex logout` cannot
  # see any of them. Mode 600 (cp preserves it), so this is sprawl rather than
  # exposure -- but there is no `plan-review clean` to sweep it later.
  #
  # Diagnosis needs the log, the meta and the reason file; it never needs the
  # token. Named by path rather than found by a `find`: this is the doctor's
  # file, and a scan for "auth.json" would be a second place that has to learn
  # every adapter's private-directory layout. An adapter that starts copying a
  # credential somewhere else has to be added here too -- which is the same
  # rule docs/adapter-contract.md now states for the copy case.
  #
  # Only on this path: the success path already removed the whole directory,
  # and PR_KEEP_SANDBOX is an explicit "keep the evidence whatever happened".
  rm -f "$dir/codex-home/auth.json" 2> /dev/null
  pr_d_info "kept for diagnosis: $dir"
  return 1
}

# ---------------------------------------------------------------------------
# Preflight. Called by libexec/plan-review-round.sh before it spawns anything.
# ---------------------------------------------------------------------------

# pr_doctor_preflight <adapter-map>
#
# Tier A only -- offline, no network, milliseconds -- and restricted to the
# adapters actually in the roster. Silent on success: this runs on every round
# and a wall of PASS lines above the reviews would train the reader to skip them.
#
# Keyed on the adapter PATH, never on the reviewer name. tests/test-runner.sh
# runs PR_ADAPTER_MAP="codex=$FAKES/fake-ok.sh"; keyed on the name `codex` this
# would demand the real CLI, and a suite built to run offline with fakes would
# suddenly need three vendor logins. An adapter path this repo does not ship
# carries no requirements, which is exactly right for a fake.
pr_doctor_preflight() {
  local map="$1" pair path rc=0 jail_for=""
  local root="${PR_ROOT:-}"

  for pair in $map; do
    path="${pair#*=}"
    [[ -n "$root" ]] || continue
    case "$path" in
      "$root/adapters/codex.sh")
        pr_doctor_have codex \
          || { echo "preflight: codex not on PATH, but the roster runs adapters/codex.sh" >&2; rc=1; }
        ;;
      "$root/adapters/agent.sh")
        if pr_doctor_have agent; then
          # `agent` is a generic name. This is the check that tells the Cursor
          # CLI from something else installed under it -- offline, milliseconds.
          # Matched as a substring rather than with jq on purpose: the preflight
          # runs before anything else and should need nothing but the CLI it is
          # asking about. pr_doctor_check_agent_identity does the parsed version.
          local about
          about="$(pr_doctor_run 15 agent about --format json 2>/dev/null)"
          if [[ "$about" != *'"cliVersion"'* ]]; then
            echo "preflight: the 'agent' on PATH does not answer 'agent about --format json'." >&2
            echo "  adapters/agent.sh needs the Cursor CLI; this looks like a different tool." >&2
            rc=1
          fi
        else
          echo "preflight: agent not on PATH, but the roster runs adapters/agent.sh" >&2
          rc=1
        fi
        if [[ -z "${PR_AGENT_MODEL:-}" ]]; then
          echo "preflight: PR_AGENT_MODEL is unset and adapters/agent.sh requires it." >&2
          echo "  Cursor never reports which model answered, so the pin is the only record." >&2
          rc=1
        fi
        ;;
      "$root/adapters/agy.sh")
        pr_doctor_have agy \
          || { echo "preflight: agy not on PATH, but the roster runs adapters/agy.sh" >&2; rc=1; }
        if [[ -z "${PR_AGY_MODEL:-}" ]]; then
          echo "preflight: PR_AGY_MODEL is unset and adapters/agy.sh requires it." >&2
          rc=1
        fi
        jail_for="${jail_for}agy "
        ;;
      "$root/adapters/claude.sh")
        pr_doctor_have claude \
          || { echo "preflight: claude not on PATH, but the roster runs adapters/claude.sh" >&2; rc=1; }
        # No pin requirement, deliberately. Unlike Cursor and agy, the stream-json
        # init line reports the resolved model, so round.json can record what
        # answered even when PR_CLAUDE_MODEL is unset.
        jail_for="${jail_for}claude "
        ;;
    esac
  done

  # `agent` is deliberately NOT in $jail_for: its bwrap is a pid fence, its
  # adapter degrades to unwrapped rather than refusing, and a preflight that
  # failed the round for it would refuse a roster that works. The doctor reports
  # that case as a warning instead (pr_doctor_check_agent_pid_fence).
  #
  # The jail probe is worth its cost only when a reviewer that needs one is
  # actually in the roster. Without it, that adapter fails after the sandbox copy
  # and the session bookkeeping, which forfeits its resume handle for the price of
  # a check we could have run first.
  #
  # That cost is no longer ~10ms. Since the probe started MEASURING containment
  # it always waits its window out for a marker that must never appear: 1.04s at
  # the default ten ticks, measured on this host 2026-08-27. A second on every
  # round with agy or claude in the roster is not worth paying for a margin that
  # exists to absorb a loaded interactive `doctor`, so preflight shrinks the
  # window to three ticks -- 0.33s measured the same way. Three is not arbitrary,
  # but the margin is thinner than it sounds: the writer stamps `survived` 0.2s
  # after `spawned`, bwrap has already exited by the time this loop starts, and
  # the loop checks at 0.1s, 0.2s and 0.3s. So the marker is seen on the SECOND
  # of three checks -- one whole tick of slack, and no more. Measured, ten runs
  # each, with --unshare-pid removed from the probe payload so the marker really
  # lands: caught at the second check every time, unchanged under 64 spinners on
  # 32 cores. Before that measurement this loop checked BEFORE its first sleep
  # and the marker landed on the last check with nothing to spare; the ordering
  # in _pr_doctor_bwrap_probe is what buys the tick, at no extra wall time.
  # Widen this rather than trim it: the failure direction is a false PASS.
  # `local` rather than an assignment prefixed to the call, because the probe
  # reads the variable and bash's rules for whether such a prefix persists past a
  # FUNCTION call are the ones tests/test-doctor.sh already refuses to rely on.
  local PR_BWRAP_PROBE_TICKS=3
  if [[ -n "$jail_for" ]]; then
    if ! pr_doctor_have bwrap; then
      echo "preflight: bwrap not found, and these adapters refuse to run without it:" >&2
      echo "  ${jail_for% }" >&2
      echo "  Install bubblewrap, or drop them from PR_ADAPTER_MAP." >&2
      rc=1
    else
      local probe_rc=0
      _pr_doctor_bwrap_probe pr-preflight-jail || probe_rc=$?
      if (( probe_rc != 0 && probe_rc != 200 )); then
        echo "preflight: bwrap is installed but its jail does not work here." >&2
        echo "  Run plan-review doctor for the diagnosis." >&2
        rc=1
      fi
    fi
  fi

  return "$rc"
}
