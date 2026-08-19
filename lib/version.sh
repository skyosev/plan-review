#!/usr/bin/env bash
# Which revision of this checkout is running.
#
# One home, because two callers want the same answer: `plan-review version` and
# the doctor's header. A doctor report is where the question actually gets asked,
# and a report that cannot say which runner produced it is worth less.
#
# Nothing asserts a minimum version anywhere. The skill and the runner are
# installed separately and may drift (see the brainstorm's R2): this reports, it
# does not gate.

# pr_version [checkout] -> a describe string, or `unknown`.
pr_version() {
  local root="${1:-$PR_ROOT}" desc
  # Look for `.git` at the checkout root rather than asking git where it is: a
  # checkout unpacked inside some other repository would otherwise be described by
  # that repository, which is a confident wrong answer. `-e`, not `-d`, because a
  # linked worktree's `.git` is a file.
  [[ -e "$root/.git" ]] || { printf 'unknown\n'; return 0; }
  # Also `unknown` when git itself is missing: describe fails and prints nothing.
  desc="$(git -C "$root" describe --tags --always --dirty 2>/dev/null)" || desc=""
  printf '%s\n' "${desc:-unknown}"
}
