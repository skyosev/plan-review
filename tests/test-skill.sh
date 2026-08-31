#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"

SKILL="$PR_ROOT/bin/plan-review"
# mk_case [ls-json] -- a stubbed PATH answering `skills ls` with a fully linked
# install unless the case wants something else. stub_npx, stub_harness_clis and
# PR_TEST_SKILLS_ALL_LINKED come from tests/helpers.sh; test-bootstrap.sh reads
# the same three.
mk_case() {
  local d; d="$(pr_test_tmpdir)"
  stub_npx "$d/stub" "${1:-$PR_TEST_SKILLS_ALL_LINKED}"
  stub_harness_clis "$d/stub"
  : > "$d/npx.log"
  printf '%s' "$d"
}

run_skill() {
  local d="$1"; shift
  env NPX_LOG="$d/npx.log" PATH="$d/stub:$PATH" bash "$SKILL" skill "$@" 2>&1
}

test_one_add_for_every_detected_harness() {
  local d out rc; d="$(mk_case)"
  out="$(run_skill "$d")"; rc=$?
  assert_exit_code "$rc" 0 "installed and verified"
  assert_contains "$(cat "$d/npx.log")" \
    "DISABLE_TELEMETRY=1 argv: -y skills@1.5.18 add $PR_ROOT -g -a claude-code -a codex -a cursor -a antigravity-cli -y" \
    "one add, every harness, telemetry off"
  assert_eq "$(grep -c 'skills@1.5.18 add' "$d/npx.log")" "1" "exactly one add process"
  assert_eq "$(grep -c 'skills@1.5.18 ls' "$d/npx.log")" "1" "exactly one ls process"
  assert_contains "$out" "verified: the skill is linked" "and said so"
}

test_cursor_is_skipped_when_the_identity_probe_fails() {
  local d; d="$(mk_case)"
  pr_test_mkstub "$d/stub/agent" 'exit 1'
  run_skill "$d" > /dev/null
  assert_not_contains "$(cat "$d/npx.log")" "-a cursor" "no skill for a tool that never answered"
  assert_contains "$(cat "$d/npx.log")" "-a codex" "the other harnesses still got the skill"
}

test_a_non_cursor_agent_does_not_pass_the_identity_probe() {
  local d; d="$(mk_case)"
  pr_test_mkstub "$d/stub/agent" 'echo "error: cliVersion flag unknown"; exit 0'
  run_skill "$d" > /dev/null
  assert_not_contains "$(cat "$d/npx.log")" "-a cursor" "a key-shaped substring is not an identity"
}

test_a_partial_link_is_nonzero_when_invoked_directly() {
  local d out rc; d="$(mk_case '[{"name":"plan-review","agents":["Claude Code"]}]')"
  out="$(run_skill "$d")"; rc=$?
  assert_exit_code "$rc" 1 "an unverifiable link is a failure, not a shrug"
  assert_contains "$out" "not linked into:" "and the misses are named"
  assert_contains "$out" "skills reports: Claude Code" "beside what actually came back"
}

# The half the id/name table comment promises: a wrong display name must be
# self-diagnosing rather than silent. `Antigravity` against `Antigravity CLI` is
# the near-miss the table exists to prevent (skills lists them as two agents), and
# the misses alone cannot show it -- "not linked into: Antigravity CLI" reads
# identically whether skills said `Antigravity` or said nothing. scripts/install.sh's
# deleted verify_skill printed both halves; this is what pins the restoration.
test_a_near_miss_display_name_shows_what_came_back() {
  local d out rc
  d="$(mk_case '[{"name":"plan-review","agents":["Claude Code","Codex","Cursor","Antigravity"]}]')"
  out="$(run_skill "$d")"; rc=$?
  assert_exit_code "$rc" 1 "a near miss is still a miss"
  assert_contains "$out" "not linked into: Antigravity CLI" "what was wanted"
  assert_contains "$out" "skills reports: Claude Code, Codex, Cursor, Antigravity" \
    "and what came back, which is the only way to see the two differ"
}

# The pristine-home shape, measured on macOS 2026-08-20: `ls` attributes a skill
# to an agent only once that agent's config directory exists in the same HOME, so
# a first run can produce a plan-review entry attributed to nobody. Its own
# wording, because it is the line that separates "linked somewhere else" from
# "this install did nothing".
test_a_skill_attributed_to_no_agent_says_so() {
  local d out; d="$(mk_case '[{"name":"plan-review","agents":[]}]')"
  out="$(run_skill "$d")"
  assert_contains "$out" "skills reports: no agent at all" "an empty array is not a blank line"
}

# "could not PARSE", not "unverified": both branches print the latter -- the
# empty-`out` one at libexec/plan-review-skill.sh's first exit and the jq-failure
# one at its second -- so asserting on the shared word left the case unable to
# say which it had exercised. It would have passed a regression that stopped
# parsing altogether and reported every host as unreadable instead.
test_an_unparseable_ls_is_nonzero() {
  local d out rc; d="$(mk_case 'this is not json')"
  out="$(run_skill "$d")"; rc=$?
  assert_exit_code "$rc" 1 "unverified is nonzero when invoked directly"
  assert_contains "$out" "could not parse 'skills ls -g --json'" \
    "and names the jq-failure branch, not the empty-output one beside it"
  assert_not_contains "$out" "could not read" "which is the other branch"
}

test_a_failed_add_is_nonzero_with_the_retry_line() {
  local d out rc; d="$(mk_case)"
  # The add fails; the harness stubs mk_case installed are what this replaces.
  pr_test_mkstub "$d/stub/npx" 'case " $* " in *" add "*) exit 1 ;; esac; exit 0'
  out="$(run_skill "$d")"; rc=$?
  assert_exit_code "$rc" 1 "a failed install is a failure"
  assert_contains "$out" "retry with:" "with the exact command to run by hand"
}

# `command -v npx` cannot be made to fail by adding to PATH, so the refusal
# cases run on a CONSTRUCTED PATH -- the device tests/test-bootstrap.sh's
# missing-npx case already uses, restated here for the same reason its stub
# shapes are.
mk_minpath() {
  local d="$1" b p; mkdir -p "$d/minpath"
  for b in bash env readlink dirname cat sed grep head jq; do
    p="$(command -v "$b" 2>/dev/null)" && ln -sf "$p" "$d/minpath/$b"
  done
}

test_missing_npx_refuses_with_the_hand_command() {
  local d out rc; d="$(pr_test_tmpdir)"; mk_minpath "$d"
  out="$(env PATH="$d/minpath" bash "$SKILL" skill 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "refused before doing anything"
  assert_contains "$out" "npx and node are needed" "and was named"
  assert_contains "$out" "npx skills@1.5.18 add" "with the command to run later"
}

test_no_harness_on_path_refuses() {
  local d out rc; d="$(pr_test_tmpdir)"; mk_minpath "$d"
  pr_test_mkstub "$d/minpath/npx" 'exit 0'
  pr_test_mkstub "$d/minpath/node" 'exit 0'
  out="$(env PATH="$d/minpath" bash "$SKILL" skill 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "nothing to install into is a refusal, not a silent success"
  assert_contains "$out" "no supported harness" "and says so"
}

pr_run_tests
