#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/session.sh"

test_get_returns_empty_when_no_map_exists() {
  local d; d="$(pr_test_tmpdir)"
  assert_eq "$(pr_session_get "$d/session-map.json" codex)" "" "no map yet"
}

test_set_then_get_round_trips() {
  local d f; d="$(pr_test_tmpdir)"; f="$d/session-map.json"
  pr_session_set "$f" codex "thread-abc"
  pr_session_set "$f" agent "uuid-def"
  assert_eq "$(pr_session_get "$f" codex)" "thread-abc" "codex handle"
  assert_eq "$(pr_session_get "$f" agent)" "uuid-def" "agent handle"
}

test_set_overwrites_a_stale_handle() {
  local d f; d="$(pr_test_tmpdir)"; f="$d/session-map.json"
  pr_session_set "$f" codex "old"
  pr_session_set "$f" codex "new"
  assert_eq "$(pr_session_get "$f" codex)" "new" "latest handle wins"
}

test_set_ignores_an_empty_handle() {
  local d f; d="$(pr_test_tmpdir)"; f="$d/session-map.json"
  pr_session_set "$f" codex "good"
  pr_session_set "$f" codex ""
  assert_eq "$(pr_session_get "$f" codex)" "good" "empty id does not clobber"
}

test_del_drops_one_handle_only() {
  local d f; d="$(pr_test_tmpdir)"; f="$d/session-map.json"
  pr_session_set "$f" codex "abc"
  pr_session_set "$f" agent "def"
  pr_session_del "$f" codex
  assert_eq "$(pr_session_get "$f" codex)" "" "failed reviewer's handle dropped"
  assert_eq "$(pr_session_get "$f" agent)" "def" "sibling handle untouched"
}

test_clear_removes_every_handle() {
  local d f; d="$(pr_test_tmpdir)"; f="$d/session-map.json"
  pr_session_set "$f" codex "abc"
  pr_session_clear "$f"
  assert_eq "$(pr_session_get "$f" codex)" "" "handles gone"
  assert_file_exists "$f" "map file still present"
}

pr_run_tests
