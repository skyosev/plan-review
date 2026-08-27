#!/usr/bin/env bash
# Disposable per-reviewer copy of the target repo (D11).
# Gitignored build state IS copied — reviewers need it to build (D4).
# .plan-review/ is NOT copied — no reviewer sees another's output (D6).

# pr_sandbox_refresh <target-repo-root> <sandbox-dir>
# Creates <sandbox-dir>/repo (a fresh copy) containing <sandbox-dir>/repo/.pr-tmp
# (empty). Safe to call every round; wipes whatever the previous round left.
#
# TMPDIR lives INSIDE the repo copy because codex runs with
# sandbox_workspace_write.exclude_tmpdir_env_var=true: $TMPDIR is removed from
# the writable roots, so a sibling directory would not be writable. Under the
# workdir it inherits the workdir root and the header stays `[workdir]`.
pr_sandbox_refresh() {
  local target="$1" sandbox="$2"
  local repo="$sandbox/repo" tmp="$sandbox/repo/.pr-tmp"

  [[ -d "$target" ]] || { echo "pr_sandbox_refresh: no such repo: $target" >&2; return 1; }

  # Whatever the previous round left, including its permissions. Ignored on
  # failure: `mkdir -p` and `rsync --delete` below still produce a correct copy.
  pr_sandbox_discard "$sandbox"
  mkdir -p "$repo"

  rsync -a --delete \
    --exclude='.plan-review/' \
    --exclude='.pr-tmp/' \
    "$target"/ "$repo"/

  mkdir -p "$tmp"

  # Strip remotes in the COPY only. Never run this in a worktree of the real
  # repo: git config is shared and the removal would hit the user's checkout.
  local remote
  while read -r remote; do
    [[ -n "$remote" ]] && git -C "$repo" remote remove "$remote"
  done < <(git -C "$repo" remote 2>/dev/null)

  return 0
}

# pr_sandbox_discard <sandbox-dir>
# Removes <sandbox-dir>/repo and nothing else.
#
# It appends `/repo` itself, and there is no flag or parameter that could make it
# remove anything higher. That is deliberate, and THREE adapters now depend on
# it: adapters/claude.sh sites CLAUDE_CONFIG_DIR at <sandbox-dir>/config,
# adapters/agy.sh its private state at <sandbox-dir>/gemini-state, and
# adapters/codex.sh its CODEX_HOME at <sandbox-dir>/codex-home -- each holding
# the sessions or rollouts that make round-to-round resume work, and each sited
# there precisely so it survives the wipe at the start of every round. One
# directory holding two things with opposite lifetimes is what a blanket
# `rm -rf` gets wrong. Making it inexpressible beats documenting that it must
# not be done. A fourth private directory would need no change here, which is
# the point.
pr_sandbox_discard() {
  local sandbox="$1"
  # Before constructing anything: "" + /repo is /repo.
  [[ -n "$sandbox" ]] || {
    echo "pr_sandbox_discard: refusing an empty sandbox directory" >&2; return 1; }

  local repo="$sandbox/repo"
  [[ -e "$repo" ]] || return 0

  # rsync -a preserved the target's permissions, and `rm -rf` cannot descend a
  # mode-555 directory -- which vendored dependencies really do ship.
  chmod -R u+w "$repo" 2>/dev/null
  rm -rf "$repo"
}
