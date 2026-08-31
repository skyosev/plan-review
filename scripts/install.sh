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
# a macOS user their /bin/bash is too old, so it cannot need bash 5 to say it.
#
# The rule covers the WHOLE file, not just the part above preflight_host. Every
# function here is defined before main runs, so bash 3.2 parses all of them before
# preflight can refuse anything: one construct it cannot parse and the refusal
# never prints. Runtime-only newer features would in fact be safe below the
# refusal, and reasoning about which are which per line is not worth it.
#
# In practice: no ${x^^}, no mapfile, no local -n, no associative arrays. Indexed
# arrays do work in 3.2, but `set --` is used as the argument array anyway (main,
# for the optional --bin-dir), because it needs no version reasoning at all. The
# harness tables and the skills-CLI argv that used to need this rule the hardest
# now live in libexec/plan-review-skill.sh, which is bash 5 like everything else.
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

# Set by main's skill step, and read only by the epilogue: the removal line it
# gates takes out a GLOBAL skill by name, so it is printed when this run
# installed AND verified one, and never otherwise.
PR_SKILL_INSTALLED=0

# Under `curl | bash`, stdin IS this script. Nothing below may read it, and git
# must never stop to ask for a credential. Exported once rather than per command,
# so it also covers the git that plan-review itself runs inside the checkout.
#
# The exemption, stated once so a call added later is not read against a rule it
# was never under: the command substitutions here -- `readlink -f /`, `uname -s`,
# `dirname` and the three `git` queries -- carry no redirect because none of them
# reads stdin. Everything that could gets `< /dev/null` at the call site. A new
# call belongs in one of those two groups, and if it is not obvious which, it is
# the second.
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
# warn <headline> [remedy...] -- the same shape as die below, and for the same
# reason: the remedy used to follow as `say` lines, which go to STDOUT while the
# warning goes to stderr. Anything that redirects one and not the other -- a log
# file, a pipe, the doctor's own output being read -- then separated a warning
# from the fix for it, or dropped one of the two entirely. One stream, one
# message. (`local` is fine here: bash 3.2 has it.)
warn() {
  local line
  printf '%swarning:%s %s\n' "$C_Y" "$C_0" "$1" >&2
  shift
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
}

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
  # Two commands, two messages. A single `checkout || die "no such ref"` was one
  # message for two very different failures: the ref really being absent, and a
  # checkout that could not run -- most often a concurrent git holding
  # .git/index.lock, which is also what a second installer running right now
  # looks like. Sending someone to hunt for a ref that is sitting right there is
  # the worse half, so existence is asked separately first. `$ref^{commit}`
  # rather than a bare `$ref`: a tag resolves to a tag object, and this is the
  # same question `checkout` is about to ask.
  #
  # Both spellings, because `checkout` accepts both. Measured against
  # tests/test-bootstrap.sh's ref-switch case: a branch that exists only on the
  # remote is checked out by git's DWIM, which creates the local branch from
  # refs/remotes/origin/<ref> -- but `rev-parse --verify <ref>` never looks in
  # refs/remotes/origin/, so a local-refs-only test refuses exactly the ref the
  # next line would have checked out fine. The remote spelling is written the
  # same way the fast-forward below writes it.
  git -C "$checkout" rev-parse --quiet --verify "$ref^{commit}" > /dev/null 2>&1 \
    || git -C "$checkout" rev-parse --quiet --verify "refs/remotes/origin/$ref^{commit}" \
         > /dev/null 2>&1 \
    || die "no such ref after fetching: $ref"
  git -C "$checkout" checkout --quiet "$ref" < /dev/null \
    || die "git checkout $ref failed in $checkout" \
           "The ref exists; this is usually a concurrent git process holding the" \
           "index lock. Wait for it and run this again."

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

main() {
  local ref="main" bin_dir="" skip_skill=0 checkout before after skill_rc

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
  #
  # The while loop above has already drained $@, so `set --` is free to carry the
  # optional flag -- one invocation rather than two arms that have to be kept
  # identical apart from it.
  set --
  [ -n "$bin_dir" ] && set -- --bin-dir "$bin_dir"
  "$checkout/bin/plan-review" install "$@" < /dev/null

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

  # Before the doctor, so the doctor's report is the last thing on screen.
  #
  # Delegated to the subcommand, the same rule as `install` and the doctor:
  # re-deriving harness detection here is the second derivation that goes
  # stale. Non-fatal, because this script's promise is the RUNNER; the
  # subcommand owns the fatal version of every failure for direct invocations.
  # The removal hint is printed only on a fully verified install now -- an
  # installed-but-unverified skill loses it, an accepted cost: the failure
  # output already carries the exact commands to run by hand.
  #
  # The two failure statuses get different endings, and the difference is the
  # retry line. libexec/plan-review-skill.sh's own header defines them: 1 is
  # "the install ran and failed, or the links could not be verified", where
  # running it again is a reasonable thing to suggest; 2 is "refused before
  # doing anything" -- npx/node or jq missing, or no harness found -- where the
  # retry is guaranteed to refuse identically, and exit 2's own message already
  # names what is missing. Handing an operator a command that cannot work is
  # worse than saying nothing, and the install_skill function this delegation
  # replaced returned 0 quietly in exactly those branches.
  #
  # Reproduced live on macOS 2026-08-29 (a bootstrap under a PATH with no node
  # printed the exit-2 diagnosis and the `retry with:` line directly beneath
  # it), so this is a fix for something measured, not a hypothetical.
  if [ "$skip_skill" != 1 ]; then
    skill_rc=0
    "$checkout/bin/plan-review" skill < /dev/null || skill_rc=$?
    if [ "$skill_rc" -eq 0 ]; then
      PR_SKILL_INSTALLED=1
    elif [ "$skill_rc" -eq 2 ]; then
      warn "the skill step was refused before it did anything (see above)."
    else
      warn "the skill step did not complete (see above)." \
        "retry with: $(q "$checkout/bin/plan-review") skill"
    fi
  fi

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
    say '      npx skills@1.5.18 remove -g plan-review    # global, and by name'
  fi
}

# Last line, so a truncated download defines functions and runs none of them.
main "$@"
