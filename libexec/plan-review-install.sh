#!/usr/bin/env bash
# Links this checkout's `bin/plan-review` into a directory on PATH, and proves the
# link works.
#
# Usage:
#   plan-review install [--bin-dir <dir>]
#
# A link, not a copy: one source of truth, and `git pull` is the upgrade. The cost
# is stated where it bites -- move or delete the checkout and the command breaks.
#
# Exit status:
#   0  linked, and the link runs -- or was already this checkout's, and nothing
#      needed doing
#   1  linked, and the link does not run
#   2  refused, having written nothing

set -uo pipefail

PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'USAGE'
usage: plan-review install [options]

  --bin-dir <dir>    where to put the link (default ~/.local/bin). Created if it
                     does not exist.
  -h, --help         this text

Nothing else is touched: no shell rc file is edited, and the skill is installed
separately with `plan-review skill`.
USAGE
}

bin_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) bin_dir="${2-}"; [[ -n "$bin_dir" ]] || { echo "--bin-dir needs a directory" >&2; exit 2; }; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$bin_dir" ]]; then
  [[ -n "${HOME:-}" ]] || { echo "HOME is unset; pass --bin-dir" >&2; exit 2; }
  bin_dir="$HOME/.local/bin"
fi

source_cmd="$(readlink -f "$PR_ROOT/bin/plan-review")" || {
  echo "cannot resolve $PR_ROOT/bin/plan-review" >&2; exit 2; }
[[ -x "$source_cmd" ]] || { echo "$source_cmd is missing or not executable" >&2; exit 2; }

destination="$bin_dir/plan-review"

# `-e` alone is not enough: it follows the link and reports a DANGLING one as
# vacant, and this would then overwrite whatever someone else left behind.
if [[ -L "$destination" ]] || [[ -e "$destination" ]]; then
  # Exact target, not "somewhere inside the checkout" -- the latter would treat a
  # link to README.md as an installation of ourselves.
  current="$(readlink -f "$destination" 2>/dev/null)" || current=""
  if [[ "$current" == "$source_cmd" ]]; then
    echo "already installed: $destination -> $source_cmd"
    exit 0
  fi
  if [[ -L "$destination" ]]; then
    echo "refusing: $destination is a symlink to $(readlink "$destination")" >&2
  elif [[ -d "$destination" ]]; then
    echo "refusing: $destination is a directory" >&2
  else
    echo "refusing: $destination already exists" >&2
  fi
  # No --force. Replacing what is at that path is not this command's decision to
  # make, and `rm` is one word.
  echo "remove it yourself, then run this again" >&2
  exit 2
fi

# Running `install` is the authorisation to create its own install directory. Any
# deeper claim on the filesystem is not.
if [[ -e "$bin_dir" && ! -d "$bin_dir" ]]; then
  echo "refusing: $bin_dir exists and is not a directory" >&2
  exit 2
fi
mkdir -p "$bin_dir" || { echo "cannot create $bin_dir" >&2; exit 2; }

ln -s "$source_cmd" "$destination" || { echo "cannot link $destination" >&2; exit 2; }
echo "linked $destination -> $source_cmd"

# Through the link's own path, never a bare `plan-review`: on a first install the
# bare name is exactly what might resolve to an older command earlier on PATH.
if ! version="$("$destination" version 2>&1)"; then
  echo "the link was written but does not run:" >&2
  echo "$version" >&2
  exit 1
fi
echo "verified: plan-review $version"

case ":${PATH:-}:" in
  *":$bin_dir:"*) ;;
  *) echo
     echo "note: $bin_dir is not on your PATH, so \`plan-review\` will not be found."
     echo "      add it in your shell's rc file -- this command does not edit one." ;;
esac

echo
echo "next: export PR_ORCHESTRATOR=<your CLI, or none>; plan-review doctor"
