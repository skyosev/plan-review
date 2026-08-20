#!/usr/bin/env bash
# Path derivation and containment. No side effects; the containment helpers
# below resolve symlinks, which is the only filesystem access in here and the
# only thing that can actually enforce "stays inside this directory".

PR_CACHE_ROOT="${PR_CACHE_ROOT:-$HOME/.cache/plan-review}"

# pr_path_escapes <relative-path>
# True when the path walks out of its own directory syntactically. This only
# buys a better message: a symlink walks straight past it, so every caller must
# still resolve and check containment with pr_path_resolve_within.
pr_path_escapes() {
  [[ "$1" == ".." || "$1" == "../"* || "$1" == *"/../"* || "$1" == *"/.." ]]
}

# pr_path_resolve_within <dir> <candidate> <abs-var> <dir-abs-var>
# Sets the two named variables to the canonical candidate and directory, and
# returns non-zero when the candidate resolves outside the directory. This is
# the actual containment control -- the one place the rule is written, so a plan
# the doctor accepts is a plan the runner accepts.
pr_path_resolve_within() {
  local -n _abs="$3" _root="$4"
  _abs="$(readlink -f "$2" 2>/dev/null)"
  # GNU readlink -f canonicalises a path whose last component does not exist;
  # BSD readlink -f (macOS stock, measured on Darwin 25) errors instead. The
  # GNU reading is the one the callers rely on: a missing criteria file or plan
  # must pass containment and then fail the existence check that owns the
  # message, not be reported as escaping the directory. Emulate it by
  # canonicalising the parent and re-appending the component -- but only when
  # that component is truly absent and not a symlink, so a dangling link (whose
  # target GNU would resolve) still fails closed.
  if [[ -z "$_abs" && ! -e "$2" && ! -L "$2" ]]; then
    local _parent _base
    _parent="$(readlink -f "$(dirname "$2")" 2>/dev/null)"
    _base="$(basename "$2")"
    if [[ -n "$_parent" && "$_base" != . && "$_base" != .. ]]; then
      _abs="$_parent/$_base"
    fi
  fi
  _root="$(readlink -f "$1" 2>/dev/null)"
  [[ -n "$_abs" && -n "$_root" && "$_abs" == "$_root"/* ]]
}

# pr_plan_slug <repo-relative-plan-path>
# docs/plans/feat.md -> docs--plans--feat
# The slug is a human-readable label only; it is lossy ('a/b.md' and 'a--b.md'
# both flatten to 'a--b'). Uniqueness comes from the hash in pr_session_key.
pr_plan_slug() {
  local rel="$1"
  if [[ "$rel" == /* ]]; then
    echo "pr_plan_slug: expected a repo-relative path, got absolute: $rel" >&2
    return 1
  fi
  if pr_path_escapes "$rel"; then
    echo "pr_plan_slug: path escapes the repository: $rel" >&2
    return 1
  fi
  rel="${rel%.md}"
  printf '%s' "${rel//\//--}"
}

# pr_key_hash <canonical-repo-path> <repo-relative-plan-path>
# Covers BOTH the repo and the exact relative path, so neither two repos sharing
# a plan path nor two plan paths sharing a slug can collide. NUL-separated so
# ('ab','c') and ('a','bc') hash differently.
pr_key_hash() {
  local h; h="$(printf '%s\0%s' "$1" "$2" | sha256sum)"
  printf '%s' "${h:0:8}"
}

# pr_session_key <canonical-repo-path> <repo-relative-plan-path>
pr_session_key() {
  local slug
  slug="$(pr_plan_slug "$2")" || return 1
  printf '%s-%s' "$(pr_key_hash "$1" "$2")" "$slug"
}

# pr_artifact_dir <repo-root> <session-key>
pr_artifact_dir() {
  printf '%s/.plan-review/%s' "$1" "$2"
}

# pr_artifact_session_key <artifact-dir>
# The inverse of pr_artifact_dir. Commands that are handed a round directory
# rather than a repo and a plan have no other way back to the key, and doing it
# by hand at each of those sites would put the layout in three places while the
# forward direction lives here.
pr_artifact_session_key() {
  printf '%s' "${1##*/}"
}

# pr_session_lock <artifact-dir>
# The session lock file. One per (repo, plan), beside the rounds it serialises,
# so two plans in one repo never wait on each other.
pr_session_lock() {
  printf '%s/.lock' "$1"
}

# pr_session_cache_dir <session-key>
# Everything cached for one session: one directory per reviewer beneath it. The
# refusal in lib/lock.sh points an operator at this path to find the processes
# still holding a lock, so it is not only the sandboxes' parent.
pr_session_cache_dir() {
  printf '%s/%s' "$PR_CACHE_ROOT" "$1"
}

# pr_sandbox_dir <session-key> <reviewer>
pr_sandbox_dir() {
  printf '%s/%s' "$(pr_session_cache_dir "$1")" "$2"
}

pr_sandbox_repo() {
  printf '%s/repo' "$(pr_sandbox_dir "$1" "$2")"
}

# Inside the repo copy on purpose: codex excludes $TMPDIR from its writable
# roots, so only a path under the workdir is actually writable.
pr_sandbox_tmp() {
  printf '%s/.pr-tmp' "$(pr_sandbox_repo "$1" "$2")"
}
