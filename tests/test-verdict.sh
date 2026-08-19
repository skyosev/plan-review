#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/verdict.sh"

write_review() {
  local f="$1"; shift
  printf '%s\n' "$@" > "$f"
}

test_parses_each_valid_verdict() {
  local d; d="$(pr_test_tmpdir)"
  local v
  for v in NO_MATERIAL_OBJECTIONS MINOR BLOCKING; do
    write_review "$d/r.md" "Some critique." "<!-- VERDICT: $v -->"
    assert_eq "$(pr_parse_verdict "$d/r.md")" "$v" "parses $v"
  done
}

test_tolerates_extra_whitespace() {
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" "text" "<!--   VERDICT:   MINOR   -->"
  assert_eq "$(pr_parse_verdict "$d/r.md")" "MINOR" "whitespace tolerated"
}

test_missing_sentinel_is_unparseable() {
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" "A review with no sentinel at all."
  assert_eq "$(pr_parse_verdict "$d/r.md")" "UNPARSEABLE" "missing sentinel"
}

test_invalid_value_is_unparseable() {
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" "<!-- VERDICT: LOOKS_FINE -->"
  assert_eq "$(pr_parse_verdict "$d/r.md")" "UNPARSEABLE" "unknown value"
}

test_pipe_separated_template_is_unparseable() {
  # Guards against a reviewer echoing the template back verbatim.
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" "<!-- VERDICT: NO_MATERIAL_OBJECTIONS | MINOR | BLOCKING -->"
  assert_eq "$(pr_parse_verdict "$d/r.md")" "UNPARSEABLE" "template not accepted"
}

test_last_sentinel_wins() {
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" \
    "I might say <!-- VERDICT: BLOCKING --> early," \
    "but conclude:" \
    "<!-- VERDICT: MINOR -->"
  assert_eq "$(pr_parse_verdict "$d/r.md")" "MINOR" "trailing sentinel wins"
}

test_missing_file_is_unparseable() {
  assert_eq "$(pr_parse_verdict /nonexistent/r.md)" "UNPARSEABLE" "absent file"
}

test_parses_files_inspected() {
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" "<!-- VERDICT: MINOR -->" \
    "<!-- FILES-INSPECTED: src/a.ts, src/b.ts ,  src/c.ts -->"
  assert_eq "$(pr_parse_files_inspected "$d/r.md")" \
"src/a.ts
src/b.ts
src/c.ts" "trimmed, one per line"
}

test_files_inspected_absent_is_empty() {
  local d; d="$(pr_test_tmpdir)"
  write_review "$d/r.md" "<!-- VERDICT: MINOR -->"
  assert_eq "$(pr_parse_files_inspected "$d/r.md")" "" "no list"
}

# Regression, found by the Task 11 real-CLI smoke test. codex's
# --output-last-message writes no trailing newline, and `while read` drops a
# final unterminated line — so the FILES-INSPECTED sentinel, which the contract
# puts LAST, vanished from every real codex review while every fake (all of
# which end with a newline) kept passing.
test_sentinels_survive_a_missing_trailing_newline() {
  local d; d="$(pr_test_tmpdir)"
  printf '# R\n<!-- VERDICT: BLOCKING -->\n<!-- FILES-INSPECTED: f.txt, g.ts -->' \
    > "$d/r.md"
  assert_eq "$(pr_parse_verdict "$d/r.md")" "BLOCKING" "verdict read without a final newline"
  assert_eq "$(pr_parse_files_inspected "$d/r.md")" \
"f.txt
g.ts" "file list read without a final newline"
}

# The verdict is the unterminated last line here, so this fails in the other
# order from the case above.
test_a_verdict_on_the_unterminated_last_line_is_read() {
  local d; d="$(pr_test_tmpdir)"
  printf '# R\n<!-- VERDICT: NO_MATERIAL_OBJECTIONS -->' > "$d/r.md"
  assert_eq "$(pr_parse_verdict "$d/r.md")" "NO_MATERIAL_OBJECTIONS" "last-line verdict"
}

pr_run_tests
