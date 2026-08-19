#!/usr/bin/env bash
# Persistent per-(plan, reviewer) session handles for native resume (D5).

pr_session_get() {
  local file="$1" reviewer="$2"
  [[ -f "$file" ]] || return 0
  jq -r --arg r "$reviewer" '.[$r] // ""' < "$file"
}

# An empty id is ignored rather than stored: a CLI that failed to report a
# handle must not silently destroy the previous, still-valid one.
pr_session_set() {
  local file="$1" reviewer="$2" id="$3"
  local tmp="$file.tmp"
  [[ -n "$id" ]] || return 0
  mkdir -p "$(dirname "$file")"
  [[ -f "$file" ]] || echo '{}' > "$file"
  jq --arg r "$reviewer" --arg id "$id" '.[$r] = $id' < "$file" > "$tmp" && mv "$tmp" "$file"
}

# Drops one reviewer's handle. A handle the CLI has pruned or invalidated cannot
# be told apart from a crash without parsing version-specific error text, so any
# failure forfeits the handle: the next round starts that reviewer fresh. The
# prompt is self-contained, so a fresh start is degraded, not broken. Keeping a
# suspect handle would fail the same reviewer every round until a human noticed.
pr_session_del() {
  local file="$1" reviewer="$2"
  local tmp="$file.tmp"
  [[ -f "$file" ]] || return 0
  jq --arg r "$reviewer" 'del(.[$r])' < "$file" > "$tmp" && mv "$tmp" "$file"
}

# pr_session_clear <file>  — implements --fresh (Q4).
pr_session_clear() {
  mkdir -p "$(dirname "$1")"
  echo '{}' > "$1"
}
