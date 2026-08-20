#!/usr/bin/env bash
# The one-line bootstrap.
#
#   curl -fsSL https://raw.githubusercontent.com/skyosev/plan-review/main/scripts/install.sh | bash
#
# Its whole job is small and stays small: get a checkout onto the machine, then
# call the subcommand that already works. libexec/plan-review-install.sh owns the
# symlink, the occupied-destination refusal and the proof that the link runs, and
# nothing here re-derives any of it -- a second derivation is the one that goes
# stale.
#
# BASH 3.2, unlike every other file in this project. This is the file that tells
# a macOS user their /bin/bash is too old, so it cannot need bash 5 to say it. No
# arrays, no ${x^^}, no mapfile. `set --` inside a function is the substitute for
# an argument array (Task 2 uses it).
#
# What it promises is the RUNNER, not a working plan-review, and not the skill:
# the skill step is non-fatal, so exit 0 says the runner was linked and nothing
# more. A round also needs jq, rsync, GNU coreutils, flock, bwrap and at least one
# reviewer CLI, none of which this installs. The doctor at the end names them.
#
# `set -e`, unlike every libexec/ entry point. Those use `set -uo pipefail` and
# handle statuses explicitly because each has a meaningful exit code to protect.
# This is linear, every step is fatal, and no test can reach its real remote, so
# -e is the cheapest way to stop at the first failure rather than carry on into a
# worse one.
set -euo pipefail

# The remote, overridable so the offline suite can point the clone at a throwaway
# local repository -- the only reason this is a variable.
PR_INSTALL_SOURCE="${PR_INSTALL_SOURCE:-https://github.com/skyosev/plan-review.git}"

# Set by install_skill, and read only by the epilogue: the removal line it gates
# takes out a GLOBAL skill by name, so it is printed when this run installed one
# and never otherwise.
PR_SKILL_INSTALLED=0

# Under `curl | bash`, stdin IS this script. Nothing below may read it, and git
# must never stop to ask for a credential. Exported once rather than per command,
# so it also covers the git that plan-review itself runs inside the checkout.
export GIT_TERMINAL_PROMPT=0

# stdout only. Gating on `[ -t 1 ] || [ -t 2 ]` would paint a redirected stdout
# whenever stderr happened to be a terminal.
if [ -t 1 ]; then
  C_B=$'\033[1m'; C_Y=$'\033[33m'; C_R=$'\033[31m'; C_0=$'\033[0m'
else
  C_B=""; C_Y=""; C_R=""; C_0=""
fi

say()  { printf '%s\n' "$*"; }
step() { printf '%s==>%s %s\n' "$C_B" "$C_0" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$*" >&2; }

# die <headline> [detail...] -- details are indented continuation lines, so a
# refusal can say what to do about itself without a heredoc at every call site.
# printf %q, for the lines that exist to be pasted back into a shell. Double
# quotes cover a space and a glob and stop there: $(...), a backtick, an embedded
# quote and a backslash all survive them, and PR_INSTALL_DIR and --bin-dir are
# strings the caller chose. %q is bash's own answer to exactly this question, it
# is a builtin, and it leaves an ordinary path completely untouched.
q() { printf '%q' "$1"; }

die() {
  local line
  printf '%serror:%s %s\n' "$C_R" "$C_0" "$1" >&2
  shift
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  exit 1
}

usage() {
  cat <<'USAGE'
usage: curl -fsSL <url>/scripts/install.sh | bash -s -- [options]

  --ref <branch|tag>   what to check out (default: main)
  --bin-dir <dir>      where to link the runner (default ~/.local/bin)
  --no-skill           do not install the plan-review skill, which also keeps
                       npm out of the install entirely
  -h, --help           this text

  PR_INSTALL_DIR       where the checkout goes (default ~/.local/share/plan-review)

It writes the checkout and the link above and, unless --no-skill, the skill into
each detected harness's own global directory -- and running npx populates npm's
cache. No sudo, and no shell rc file is edited. It finishes by telling you what
is still missing; exit 0 means the runner is linked, not that a round can run.
USAGE
}

# The two things the runner needs before it can report on anything else.
# bin/plan-review resolves its own path with `readlink -f` at line 45 and the
# libexec/ scripts need bash 5, so on a host without either, `plan-review doctor`
# dies before printing a word -- and "install the runner, let the doctor tell the
# truth" delivers nothing at all. Everything else a round needs is the doctor's
# to name, because by then it runs.
#
# `readlink -f /` is a BEHAVIOUR probe, not a platform check. Whether a given
# macOS release ships a readlink with -f is a moving target and not worth
# tracking; whether this machine's does is one command. The answer is compared
# against `/` rather than merely tested for emptiness -- a readlink that prints a
# usage line to stdout and exits 0 would pass a non-empty test while resolving
# nothing.
preflight_host() {
  local probe
  probe="$(readlink -f / 2>/dev/null)" || probe=""
  [ "$probe" = "/" ] || die \
    "readlink -f does not resolve a path here, so plan-review cannot find itself." \
    "It needs the GNU readlink. If this is macOS, install coreutils and put it" \
    "first on PATH:" \
    "  brew install coreutils" \
    "  PATH=\"\$(brew --prefix)/opt/coreutils/libexec/gnubin:\$PATH\"" \
    "The second line is the one people miss: without it coreutils installs as" \
    "greadlink, gtimeout and so on, and plain readlink is untouched."

  [ "${BASH_VERSINFO[0]:-0}" -ge 5 ] || die \
    "bash ${BASH_VERSINFO[0]:-?} is too old; plan-review needs 5." \
    "macOS ships 3.2 as /bin/bash. Install a current one and make sure it comes" \
    "first on PATH, since every script here starts with #!/usr/bin/env bash:" \
    "  brew install bash"
}

# The checkout's own answer, never a bare `plan-review`. `unknown` is what
# lib/version.sh returns without git or without .git, so this cannot fail.
checkout_version() {
  "$1/bin/plan-review" version < /dev/null 2>/dev/null || printf 'unknown\n'
}

fresh_clone() {
  local checkout="$1" ref="$2" parent
  parent="$(dirname "$checkout")"
  mkdir -p "$parent" || die "cannot create $parent"

  # `mkdir`, not `mkdir -p`, and no staging directory. It is atomic and portable,
  # and it fails when the path already exists -- so this one call is BOTH the
  # occupied-path refusal and the guard against a second installer running at the
  # same moment. git clones happily into a directory that exists and is empty.
  #
  # A staging directory plus `mv` had neither property: /tmp is often another
  # filesystem, so the rename degraded to copy-and-delete, and BSD `mv` has no
  # -T, so the loser of the race would have nested its clone inside the winner's
  # checkout.
  mkdir "$checkout" || die "cannot create $checkout"

  # Armed only after the mkdir succeeded, which is the proof that this run made
  # the directory: we remove what we created and nothing else. SIGKILL and power
  # loss are not covered -- the next run refuses the partial directory by name and
  # prints the `rm -rf`, which is the one case the old staging design handled
  # better, traded for the race it could not handle at all.
  trap 'rm -rf "$checkout"' EXIT INT TERM HUP

  step "cloning $PR_INSTALL_SOURCE"
  git clone --quiet "$PR_INSTALL_SOURCE" "$checkout" < /dev/null \
    || die "clone failed: $PR_INSTALL_SOURCE" \
           "Check the URL and your network, then run this again."
  git -C "$checkout" checkout --quiet "$ref" < /dev/null \
    || die "no such ref in $PR_INSTALL_SOURCE: $ref"

  # Disarmed HERE, not at the end of main, and that placement is the whole point.
  # From this line the checkout is a complete clone and worth keeping. Everything
  # after it is repairable by re-running -- and `plan-review install` has a
  # documented exit 1 meaning "the link was written but does not run", where
  # deleting the checkout underneath it would convert a diagnosable state into a
  # dangling symlink pointing at nothing.
  trap - EXIT INT TERM HUP
}

upgrade_checkout() {
  local checkout="$1" ref="$2" origin
  # No trap on this path at all. This directory was here before we ran, so
  # removing it is not ours to do under any failure.
  [ -d "$checkout/.git" ] || die \
    "$checkout exists but is not a git checkout." \
    "Nothing here created it, so nothing here removes it." \
    "If it is a leftover from an interrupted install: rm -rf $(q "$checkout")"

  origin="$(git -C "$checkout" remote get-url origin 2>/dev/null || true)"
  [ "$origin" = "$PR_INSTALL_SOURCE" ] || die \
    "$checkout has a different origin: ${origin:-none}" \
    "This only upgrades checkouts it made from $PR_INSTALL_SOURCE." \
    "Upgrade that one with git pull, or set PR_INSTALL_DIR somewhere else."

  [ -z "$(git -C "$checkout" status --porcelain)" ] || die \
    "$checkout has uncommitted changes." \
    "Refusing to move a working tree that is not ours to move." \
    "Commit or stash them, then run this again."

  step "updating $checkout to $ref"
  git -C "$checkout" fetch --quiet --tags origin < /dev/null \
    || die "git fetch failed in $checkout"
  git -C "$checkout" checkout --quiet "$ref" < /dev/null \
    || die "no such ref after fetching: $ref"

  # Fast-forward against the remote ref BY NAME, rather than asking `git pull` to
  # find an upstream. A tag has no refs/remotes/origin/<ref>, so nothing happens
  # and the detached HEAD stands. Every branch that CAME FROM the remote has one,
  # which is the case "re-run is upgrade" is about, and an upstream-based test let
  # any of them decline silently for want of tracking configuration.
  #
  # A branch the operator created inside the checkout has no remote ref either, so
  # it is skipped too. That is the right answer -- there is nothing to fast-forward
  # it to -- and the fetch above still ran, so `git merge origin/<whatever>` by
  # hand works. Refusing such a ref outright would buy nothing and cost a rule.
  if git -C "$checkout" rev-parse --quiet --verify "refs/remotes/origin/$ref" \
       > /dev/null 2>&1; then
    git -C "$checkout" merge --quiet --ff-only "origin/$ref" < /dev/null || die \
      "$checkout cannot fast-forward to origin/$ref; it has diverged." \
      "Sort it out with git, or remove it: rm -rf $(q "$checkout")"
  fi
}

# Harness ids and display names as the skills CLI spells them, read at version
# 1.5.18 on 2026-08-19. Two strings per harness because verification needs both:
# the id selects, the display name is what comes back.
#
# `agy` is `antigravity-cli`, NOT `antigravity`: skills lists those as two agents
# with two separate global directories, and lib/doctor.sh:141 identifies agy as
# the Antigravity *CLI*.
#
# THE DISPLAY NAMES ARE UNCONFIRMED. Task 2 Step 10 confirms them against a real
# `skills ls -g --json` and corrects this table. A wrong one is self-diagnosing
# rather than silent: verify_skill prints both what it wanted and what came back,
# so the fix is a copy-paste. No offline test can check any of these -- a stub
# reproduces whatever name it is given, which is how `antigravity` survived a
# draft of this file. Same convention, same reason, as lib/doctor.sh:396.
skill_id_for() {
  case "$1" in
    claude) printf 'claude-code\n' ;;
    codex)  printf 'codex\n' ;;
    agent)  printf 'cursor\n' ;;
    agy)    printf 'antigravity-cli\n' ;;
  esac
}

skill_name_for() {
  case "$1" in
    claude) printf 'Claude Code\n' ;;
    codex)  printf 'Codex\n' ;;
    agent)  printf 'Cursor\n' ;;
    agy)    printf 'Antigravity CLI\n' ;;
  esac
}

# `agent` is a generic name, and `command -v agent` cannot tell the Cursor CLI
# from any other tool called agent. lib/doctor.sh:405 asks the same question and
# requires a NON-EMPTY .cliVersion; an exit-status-only probe is a different and
# much weaker test, because another tool can exit 0 on a subcommand it does not
# recognise.
#
# Parsed with node, not jq and not parameter expansion. jq is not a requirement
# of this installer and must not become one; npx has already proved node is here,
# one function above. A substring hunt for "cliVersion" was the first draft and it
# accepts truncated JSON, an unterminated value, and the key appearing inside some
# other tool's error string -- which is the exact confusion this function exists
# to resolve, so it cannot be the thing doing the resolving.
cursor_identity_ok() {
  agent about --format json < /dev/null 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", d => { s += d; });
    process.stdin.on("end", () => {
      let v;
      try { v = JSON.parse(s); } catch (e) { process.exit(1); }
      const ok = v && typeof v === "object" && !Array.isArray(v)
              && typeof v.cliVersion === "string" && v.cliVersion.length > 0;
      process.exit(ok ? 0 : 1);
    });'
}

# The skill is the primary interface, and it is installed by a third-party CLI
# into each harness's own global directory. Everything here is NON-FATAL: the
# promise is scoped to the runner, and a missing npx or a registry outage must
# not turn a good install into a failed one. Every failure prints the exact
# command to run by hand.
install_skill() {
  local checkout="$1" cli targets="" add_args=""
  # node before npx, because cursor_identity_ok and verify_skill both need it and
  # a bare `npx` with no node behind it is not a thing anyone has.
  if ! command -v npx > /dev/null 2>&1 || ! command -v node > /dev/null 2>&1; then
    warn "npx and node are needed for the skill, and one of them is not on PATH."
    say  "  install it later with: npx skills add $(q "$checkout") -g -a <harness>"
    return 0
  fi
  for cli in claude codex agent agy; do
    command -v "$cli" > /dev/null 2>&1 || continue
    if [ "$cli" = agent ] && ! cursor_identity_ok; then
      warn "the 'agent' on PATH does not answer 'agent about --format json'."
      say  "  it looks like a different tool with the same name; skipping Cursor."
      continue
    fi
    targets="$targets $cli"
    add_args="$add_args -a $(skill_id_for "$cli")"
  done
  [ -n "$targets" ] || {
    warn "no supported harness on PATH, so the skill was not installed."
    return 0; }

  step "installing the skill for:$targets"
  # ONE add for every harness, not one per harness. The CLI takes repeated -a,
  # and four separate calls were four snapshots of the checkout taken at four
  # moments as well as four mutable third-party processes.
  #
  # $add_args is deliberately unquoted: word splitting is the mechanism, and
  # every id is a bare word by construction above.
  #
  # Two -y flags, belonging to two different programs: the leading one is npm's
  # "do not ask before fetching this package", the trailing one is the skills
  # CLI's own "do not prompt". Only the second suppresses its questions.
  # DISABLE_TELEMETRY because we spawn this on the user's behalf rather than them
  # running it -- and it is on BOTH npx calls, not just this one. stdin is closed
  # because under `curl | bash` stdin is us.
  if ! DISABLE_TELEMETRY=1 npx -y skills add "$checkout" -g $add_args -y < /dev/null; then
    warn "the skill install failed."
    say  "  retry with: DISABLE_TELEMETRY=1 npx -y skills add $(q "$checkout") -g$add_args -y"
    return 0
  fi
  PR_SKILL_INSTALLED=1
  verify_skill "$targets" || true
}

# One `skills ls -g --json`, then the real question: does plan-review's `agents`
# array contain the display name of every harness we just installed for?
#
# An earlier design asked only whether the array was non-empty under
# `skills ls -a <harness>`, on the theory that scoping the query made the answer
# unambiguous. It does not -- the CLI attributes skills to agents outside the
# filter -- so a skill linked into Claude Code alone answers "non-empty" to a
# Codex query. The fixture written for that check encoded the same false
# positive: it returned ["Claude Code"] to all four queries and called all four
# verified. Exact names cost four more third-party strings; a check that cannot
# fail costs more.
#
# Name presence alone is not verification either. Measured with skills 1.5.18 in
# an isolated home on 2026-08-19: an install that produced no Claude Code link
# still had `skills ls` print plan-review and exit 0, annotated only `not linked`.
# The JSON is where the difference lives.
#
# node, not jq: jq is not a requirement of this installer and must not become
# one, while npx has already proved Node is here.
verify_skill() {
  local targets="$1" cli out rc=0
  out="$(DISABLE_TELEMETRY=1 npx -y skills ls -g --json < /dev/null 2>/dev/null)" || out=""
  if [ -z "$out" ]; then
    warn "could not read 'skills ls -g --json'; the links are unverified."
    say  "  check it by hand: npx skills ls -g --json"
    return 2
  fi
  # `set --` rather than an array: this file has to run under bash 3.2, and the
  # display names contain spaces so a split string will not do.
  set --
  for cli in $targets; do set -- "$@" "$(skill_name_for "$cli")"; done
  printf '%s' "$out" | node -e '
    let s = "";
    process.stdin.on("data", d => { s += d; });
    process.stdin.on("end", () => {
      let v;
      try { v = JSON.parse(s); } catch (e) { process.exit(2); }
      const list = Array.isArray(v) ? v : (v && v.skills) || [];
      const hit = list.find(x => x && x.name === "plan-review");
      const have = (hit && Array.isArray(hit.agents)) ? hit.agents : [];
      const want = process.argv.slice(1);
      const missing = want.filter(n => have.indexOf(n) < 0);
      if (missing.length) {
        console.error("  not linked into: " + missing.join(", "));
        console.error("  skills reports: " + (have.length ? have.join(", ") : "no agent at all"));
        process.exit(1);
      }
    });' "$@" || rc=$?
  case "$rc" in
    0) say "  verified: the skill is linked into$targets"; return 0 ;;
    1) warn "the skill is installed but not linked everywhere (see above)." ;;
    *) warn "could not parse 'skills ls -g --json'; the links are unverified." ;;
  esac
  say "  check it by hand: npx skills ls -g --json"
  return "$rc"
}

main() {
  local ref="main" bin_dir="" skip_skill=0 checkout before after

  while [ $# -gt 0 ]; do
    case "$1" in
      --ref)     ref="${2-}";     [ -n "$ref" ]     || die "--ref needs a branch or tag";  shift 2 ;;
      --bin-dir) bin_dir="${2-}"; [ -n "$bin_dir" ] || die "--bin-dir needs a directory";  shift 2 ;;
      --no-skill) skip_skill=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done

  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      die "Windows is not supported." \
          "plan-review needs a POSIX shell, GNU coreutils and a jail its adapters" \
          "can fail closed against. Run it under WSL." ;;
  esac

  [ -n "${HOME:-}" ] || die "HOME is unset, so there is nowhere to install." \
    "Set it, or pass --bin-dir and PR_INSTALL_DIR."
  command -v git > /dev/null 2>&1 || die "git is required and is not on PATH." \
    "It is a hard requirement of plan-review itself, not just of this installer."

  preflight_host

  checkout="${PR_INSTALL_DIR:-$HOME/.local/share/plan-review}"

  if [ -e "$checkout" ]; then
    before="$(checkout_version "$checkout")"
    upgrade_checkout "$checkout" "$ref"
  else
    before=""
    fresh_clone "$checkout" "$ref"
  fi

  step "linking the runner"
  # Fatal, and its message is the diagnosis. `refusing: ... is a symlink to ...`
  # is the occupied-destination case, and re-deriving that rule here instead of
  # calling the command that owns it is exactly the mistake this delegates away.
  if [ -n "$bin_dir" ]; then
    "$checkout/bin/plan-review" install --bin-dir "$bin_dir" < /dev/null
  else
    "$checkout/bin/plan-review" install < /dev/null
  fi

  after="$(checkout_version "$checkout")"
  if [ -z "$before" ]; then
    say "installed plan-review $after"
  elif [ "$before" = "$after" ]; then
    say "already at $after"
  else
    # ASCII `->`, not an arrow: this is the one line that reports success, and it
    # should not be the line that turns into mojibake on a terminal without UTF-8.
    say "$before -> $after"
  fi

  # Before the doctor, so the doctor's report is the last thing on screen -- and
  # non-fatal in every branch it can take, which is why nothing here guards the
  # status.
  [ "$skip_skill" = 1 ] || install_skill "$checkout"

  step "checking readiness"
  # Through the checkout's own path, never a bare `plan-review`: it is not on
  # PATH in this shell yet, and where it does resolve it may be an older install.
  # The same reasoning libexec/plan-review-install.sh gives for verifying through
  # $destination.
  #
  # Non-fatal, and offline. An incomplete machine is the normal state right after
  # installing a tool that orchestrates four other tools, and the whole point of
  # this step is to say so rather than to gate on it. Offline means no auth calls
  # and no model lists, so it costs no tokens and reaches no network.
  PR_ORCHESTRATOR=none "$checkout/bin/plan-review" doctor --offline < /dev/null || true

  # Escaped with %q, because these lines exist to be pasted. An ordinary path
  # comes through unchanged; one with a space, a glob or a $(...) comes through
  # as something a shell reads back as the single path it started as.
  cat <<EPILOGUE

next: export PR_ORCHESTRATOR=<codex|agent|agy|claude>
      plan-review doctor

to remove it all:
      rm $(q "${bin_dir:-$HOME/.local/bin}/plan-review")
      rm -rf $(q "$checkout")
EPILOGUE

  # A GLOBAL skill, removed by name. Printing this after --no-skill, a missing
  # npx or a failed install would be inviting someone to delete a skill this run
  # never touched.
  if [ "$PR_SKILL_INSTALLED" = 1 ]; then
    say '      npx skills remove -g plan-review    # global, and by name'
  fi
}

# Last line, so a truncated download defines functions and runs none of them.
main "$@"
