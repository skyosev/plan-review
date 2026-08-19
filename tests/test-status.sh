#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/status.sh"

test_init_creates_empty_file() {
  local f; f="$(pr_test_tmpdir)/status.jsonl"
  pr_status_init "$f"
  assert_file_exists "$f" "status file created"
  assert_eq "$(wc -l < "$f" | tr -d ' ')" "0" "starts empty"
}

test_event_appends_one_json_line_per_call() {
  local f; f="$(pr_test_tmpdir)/status.jsonl"
  pr_status_init "$f"
  pr_status_event "$f" codex started
  pr_status_event "$f" codex finished
  assert_eq "$(wc -l < "$f" | tr -d ' ')" "2" "two events"
  assert_eq "$(jq -r '.reviewer' < "$f" | head -1)" "codex" "reviewer recorded"
  assert_eq "$(jq -r '.state' < "$f" | tail -1)" "finished" "state recorded"
}

test_event_records_a_timestamp() {
  local f; f="$(pr_test_tmpdir)/status.jsonl"
  pr_status_init "$f"
  pr_status_event "$f" agy started
  assert_contains "$(jq -r '.at' < "$f")" "T" "ISO-8601 timestamp"
}

test_event_carries_optional_detail() {
  local f; f="$(pr_test_tmpdir)/status.jsonl"
  pr_status_init "$f"
  pr_status_event "$f" agent failed "exit 2, empty output"
  assert_eq "$(jq -r '.detail' < "$f")" "exit 2, empty output" "detail preserved"
}

test_render_shows_latest_state_per_reviewer() {
  local f out; f="$(pr_test_tmpdir)/status.jsonl"
  pr_status_init "$f"
  pr_status_event "$f" codex started
  pr_status_event "$f" agy started
  pr_status_event "$f" codex finished
  out="$(pr_status_render "$f")"
  assert_contains "$out" "codex: finished" "codex latest state"
  assert_contains "$out" "agy: started" "agy latest state"
  assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2" "one line per reviewer"
}

pr_run_tests
