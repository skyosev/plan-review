#!/usr/bin/env bash
# Parses the machine-readable sentinels a reviewer must append to its review.

# This set plus UNPARSEABLE is stated a second time, in
# _pr_reviewer_result_valid (lib/reviewer-runner.sh), which refuses a result
# record whose verdict is outside it. Deliberate duplication, cross-referenced
# the way the adapters' shared constants are: a fifth verdict has to be added
# in both places or the runner will reject records it just wrote.
PR_VERDICT_RE='^[[:space:]]*<!--[[:space:]]*VERDICT:[[:space:]]*(NO_MATERIAL_OBJECTIONS|MINOR|BLOCKING)[[:space:]]*-->[[:space:]]*$'

# pr_parse_verdict <review-file>
# Echoes NO_MATERIAL_OBJECTIONS | MINOR | BLOCKING | UNPARSEABLE.
# Never defaults: an unreadable verdict must be visible to the human.
pr_parse_verdict() {
  local file="$1" line verdict="UNPARSEABLE"
  [[ -f "$file" ]] || { printf 'UNPARSEABLE'; return 0; }
  # `|| [[ -n "$line" ]]` is load-bearing: `read` returns false at EOF without a
  # trailing newline, discarding the final line. codex's --output-last-message
  # writes exactly that, and the sentinels are the LAST lines of a review.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $PR_VERDICT_RE ]]; then
      verdict="${BASH_REMATCH[1]}"
    fi
  done < "$file"
  printf '%s' "$verdict"
}

# pr_parse_files_inspected <review-file>
# Echoes one trimmed path per line. Empty output if the sentinel is absent.
pr_parse_files_inspected() {
  local file="$1" line raw
  [[ -f "$file" ]] || return 0
  # See pr_parse_verdict: a file with no trailing newline would otherwise lose
  # its last line, which is precisely where this sentinel lives.
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*\<!--[[:space:]]*FILES-INSPECTED:(.*)--\>[[:space:]]*$ ]]; then
      raw="${BASH_REMATCH[1]}"
    fi
  done < "$file"
  [[ -n "${raw:-}" ]] || return 0
  # Split and trim in the shell: tr|sed|grep was three processes per reviewer for
  # work parameter expansion does with none.
  local item
  local IFS=,
  for item in $raw; do
    item="${item#"${item%%[![:space:]]*}"}"
    item="${item%"${item##*[![:space:]]}"}"
    [[ -n "$item" ]] && printf '%s\n' "$item"
  done
  return 0
}
