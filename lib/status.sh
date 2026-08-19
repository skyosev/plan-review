#!/usr/bin/env bash
# Per-reviewer progress events (D15). One JSON object per line, append-only.

pr_status_init() {
  mkdir -p "$(dirname "$1")"
  : > "$1"
}

# pr_status_event <status-file> <reviewer> <state> [detail]
# state is one of: started | finished | failed | timed_out
pr_status_event() {
  local file="$1" reviewer="$2" state="$3" detail="${4:-}"
  # printf's %()T rather than date(1): this runs several times per reviewer per
  # round, and the format is the same ISO-8601 UTC string either way. TZ is set
  # for the builtin alone, so nothing after this sees a changed timezone.
  local at; TZ=UTC printf -v at '%(%Y-%m-%dT%H:%M:%SZ)T' -1
  jq -nc --arg at "$at" \
         --arg reviewer "$reviewer" \
         --arg state "$state" \
         --arg detail "$detail" \
         '{at: $at, reviewer: $reviewer, state: $state, detail: $detail}' >> "$file"
}

# pr_status_render <status-file>
# One line per reviewer showing its most recent state. Safe to call mid-round.
pr_status_render() {
  local file="$1"
  [[ -s "$file" ]] || return 0
  jq -rs 'group_by(.reviewer)
          | map(sort_by(.at) | last)
          | .[]
          | "\(.reviewer): \(.state)" + (if .detail == "" then "" else " (\(.detail))" end)' \
    < "$file"
}
