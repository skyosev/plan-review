#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/roster.sh"
source "$PR_ROOT/lib/doctor.sh"
source "$PR_ROOT/lib/config.sh"
source "$PR_ROOT/lib/init.sh"

INIT="$PR_ROOT/bin/plan-review"

# Every entry-point case runs against a PATH that holds NOTHING but the
# utilities init needs plus the stubs the case asks for. Prepending a stub
# directory to the real PATH would leave whatever is installed on the machine
# running the suite visible behind it, and "codex is not installed" would then
# be a property of the developer's laptop rather than of the test.
# Deliberately NARROWER than $PR_DOCTOR_UTILS: most cases want the doctor's
# core-utilities check to fail, so this is the minimum init itself needs, not a
# copy of the doctor's list. `ps` is on it because the execution kernel's
# descendant sweep made it a core utility (2026-08-26, lib/adapter-exec.sh). The
# one case that wants a green doctor widens the PATH with $PR_DOCTOR_UTILS
# itself rather than restating it.
PR_INIT_TEST_UTILS="bash env dirname git jq mkdir mv readlink rm tail timeout cat sed ps"

mkpath() {
  local d="$1" u real
  mkdir -p "$d"
  for u in $PR_INIT_TEST_UTILS; do
    real="$(command -v "$u")" && ln -sf "$real" "$d/$u"
  done
  printf '%s' "$d"
}


# An authenticated stub per CLI. `$log` records every invocation, so a test can
# assert that --offline or an argument error cost no call at all.
stub_codex() {
  pr_test_mkstub "$1/codex" "printf '%s\n' \"\$*\" >> '$2'
[[ \"\$1 \$2\" == 'login status' ]] && { echo 'Logged in'; exit 0; }
exit 0"
}
stub_agent() {
  local models="${3:-claude-opus-5-thinking-high - Claude Opus 5 Thinking High}"
  pr_test_mkstub "$1/agent" "printf '%s\n' \"\$*\" >> '$2'
case \"\$1\" in
  about)  echo '{\"cliVersion\":\"2026.08.11-e8db854\"}' ;;
  status) echo '{\"isAuthenticated\":true}' ;;
  --list-models) printf '%s\n' 'Available models' '$models' ;;
esac"
}
stub_agy() {
  local models="${3:-gemini-3.1-pro-high	Gemini 3.1 Pro (High)}"
  # --help lists --print-timeout because pr_doctor_check_agy_print_timeout now
  # FAILS when it does not -- adapters/agy.sh passes that flag.
  pr_test_mkstub "$1/agy" "printf '%s\n' \"\$*\" >> '$2'
[[ \"\$1\" == models ]] && printf '%s\n' 'Fetching available models...' '$models'
[[ \"\$1\" == --help ]] && printf '%s\n' '  --print-timeout   Timeout for print mode wait (default 5m0s)'
exit 0"
}
stub_claude() {
  pr_test_mkstub "$1/claude" "printf '%s\n' \"\$*\" >> '$2'
[[ \"\$1 \$2\" == 'auth status' ]] && { echo '{\"loggedIn\":true,\"authMethod\":\"oauth\",\"subscriptionType\":\"max\"}'; exit 0; }
exit 0"
}
# The jail probe runs bwrap itself rather than a proxy, so a stub that exits 0 is
# what makes an agy or claude roster testable off a machine with a working one.
stub_bwrap() { pr_test_mkstub "$1/bwrap" 'exit 0'; }

mkrepo() {
  local d="$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
}

# run <path-dir> <repo> [args...] -- stdout+stderr, then a trailing `rc=<n>`.
# The pin variables are cleared explicitly: a developer with PR_AGY_MODEL
# exported would otherwise see different results from CI.
run() {
  local path="$1" repo="$2" out rc
  shift 2
  out="$(PATH="$path" \
         PR_ORCHESTRATOR="${ORCH:-claude}" \
         PR_CODEX_MODEL="" PR_AGENT_MODEL="" PR_AGY_MODEL="" PR_CLAUDE_MODEL="" \
         PR_CODEX_EFFORT="" PR_CLAUDE_EFFORT="" \
         PR_CONFIG="" PR_PRESET="" PR_ADAPTER_MAP="" PR_SKIP_CONFIG="" \
         "$BASH" "$INIT" init --repo "$repo" "$@" 2>&1)"
  rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}

# --- the generated shape ----------------------------------------------------
#
# pr_init_build_config is pure, so these need no machine, no stubs and no PATH
# games. Each asserts against the validator the runner itself uses: init must
# not be able to produce a file the runner rejects.

validates() {
  local errors; errors="$(_pr_config_json_errors /dev/stdin <<<"$1")"
  [[ -z "$errors" ]] || pr_fail "the runner would reject this config: $errors"
}

test_the_generated_config_is_one_the_runner_accepts() {
  local out
  out="$(pr_init_build_config "codex agent agy" \
    '{"agent":{"model":"claude-opus-5-thinking-high"},"agy":{"model":"gemini-3.1-pro-high"}}')"
  validates "$out"
  assert_eq "$(jq -c '.reviewers' <<<"$out")" '["codex","agent","agy"]' "the stated roster"
  assert_eq "$(jq -r '.presets.quick.reviewers[0]' <<<"$out")" "codex" \
    "quick takes the first reviewer in PR_ROSTER_ADAPTERS order"
  assert_eq "$(jq -r '.presets.quick.pins.codex.effort' <<<"$out")" "low" "quick is lighter"
  assert_eq "$(jq -r '.presets.quick.pins.codex.model // "absent"' <<<"$out")" "absent" \
    "quick inherits the model from the top level"
  assert_eq "$(jq -r '.presets.deep.reviewers // "absent"' <<<"$out")" "absent" \
    "deep inherits the roster and states only its difference"
  assert_eq "$(jq -r '.presets.deep.pins.codex.effort' <<<"$out")" "xhigh" "deep is heavier"
}

# agy and Cursor carry the tier inside the model id, so an effort key for them is
# a schema violation rather than a no-op. deep is partial by construction.
test_deep_deepens_only_the_two_clis_with_an_effort_axis() {
  local out
  out="$(pr_init_build_config "agent agy claude" \
    '{"agent":{"model":"a"},"agy":{"model":"b"}}')"
  validates "$out"
  assert_eq "$(jq -c '.presets.deep.pins | keys' <<<"$out")" '["claude"]' "claude only"
  assert_contains "$(pr_init_describe_preset deep "agent agy claude")" \
    "not agent, agy" "and the line says which it could not deepen"
}

test_a_roster_with_no_effort_axis_gets_no_deep_preset() {
  local out; out="$(pr_init_build_config "agent agy" '{"agent":{"model":"a"},"agy":{"model":"b"}}')"
  validates "$out"
  assert_eq "$(jq -r '.presets.deep // "absent"' <<<"$out")" "absent" "nothing to deepen"
  assert_eq "$(jq -c '.presets.quick.reviewers' <<<"$out")" '["agent"]' "quick still narrows"
}

# A preset that resolves exactly as the top level does is a preset that says
# nothing, and a `quick` costing what the top level costs is a lie.
test_one_reviewer_without_an_effort_axis_gets_no_presets_at_all() {
  local out; out="$(pr_init_build_config "agy" '{"agy":{"model":"b"}}')"
  validates "$out"
  assert_eq "$(jq -r '.presets // "absent"' <<<"$out")" "absent" "nothing would differ"
}

test_one_reviewer_with_an_effort_axis_still_gets_both_presets() {
  local out; out="$(pr_init_build_config "codex" '{}')"
  validates "$out"
  assert_eq "$(jq -r '.presets.quick.pins.codex.effort' <<<"$out")" "low" "quick differs by effort"
  assert_eq "$(jq -r '.presets.deep.pins.codex.effort' <<<"$out")" "xhigh" "so does deep"
  assert_eq "$(jq -r '.pins // "absent"' <<<"$out")" "absent" "no pins, no empty pins object"
}

# --- deriving the roster ----------------------------------------------------

test_the_derived_roster_is_what_is_installed_minus_the_orchestrator() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "rc=0" "codex reviews, claude orchestrates"
  assert_eq "$(jq -c '.reviewers' < "$d/repo/.plan-review/config.json")" '["codex"]' "one reviewer"
  assert_contains "$out" "agy     not installed" "absence is a note, not a failure"
}

# A roster of one is a roster. Nothing in the output describes it as reduced.
test_a_one_reviewer_roster_is_written_in_the_same_terms_as_any_other() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "reviewers: codex" "reported like any other roster"
  assert_not_contains "$out" "only one" "no editorialising about the size"
  assert_not_contains "$out" "cheap" "nor about what it costs"
}

test_an_empty_roster_refuses_and_leaves_nothing_behind() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_claude "$p" "$d/log"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "roster would be empty" "says what is wrong"
  assert_contains "$out" "rc=2" "a refusal"
  assert_file_missing "$d/repo/.plan-review" "no directory"
  assert_file_missing "$d/repo/.gitignore" "and no ignore line"
}

# The refusal that was deleted from lib/roster.sh compared CLI names, and CLI
# names do not establish model identity. init knows nothing that check did not.
test_reviewers_may_name_the_orchestrators_own_cli() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"; stub_bwrap "$p"
  out="$(run "$p" "$d/repo" --reviewers codex,claude --no-verify)"
  assert_contains "$out" "rc=0" "written, not refused"
  assert_eq "$(jq -c '.reviewers' < "$d/repo/.plan-review/config.json")" '["codex","claude"]' "obeyed exactly"
  assert_eq "$(grep -c 'both the orchestrator and a reviewer' <<<"$out")" "1" "warned once"
}

test_reviewers_naming_a_cli_that_is_not_here_refuses() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"
  out="$(run "$p" "$d/repo" --reviewers codex,agy --no-verify)"
  assert_contains "$out" "not on PATH" "a config for a machine you do not have"
  assert_contains "$out" "rc=2" "a refusal"
  assert_file_missing "$d/repo/.plan-review" "nothing written"
}

# --- probes -----------------------------------------------------------------

test_a_required_pin_that_nobody_supplied_refuses_and_prints_the_ids() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_agy "$p" "$d/log"; stub_bwrap "$p"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "PR_AGY_MODEL is unset" "names the variable"
  assert_contains "$out" "--pin agy=<id>" "and the flag to re-run with"
  assert_contains "$out" "gemini-3.1-pro-high" "and the ids it could have used"
  assert_not_contains "$out" "Fetching available models" "prose is not an id"
  assert_contains "$out" "rc=2" "a refusal, not a quiet omission"
  assert_file_missing "$d/repo/.plan-review" "nothing written"

  # Leaving it out is how you say "not that one, here".
  out="$(run "$p" "$d/repo" --reviewers codex --no-verify)"
  assert_contains "$out" "rc=0" "the same machine, one reviewer fewer"
}

test_an_unauthenticated_reviewer_stops_init_even_though_a_round_would_survive() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  pr_test_mkstub "$p/codex" 'echo "not logged in" >&2; exit 1'
  stub_claude "$p" "$d/log"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "codex is not authenticated" "the reason"
  assert_contains "$out" "codex login" "the remediation"
  assert_contains "$out" "rc=2" "stricter than the runner, deliberately"
}

test_a_pin_that_is_not_in_the_model_list_refuses() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_agy "$p" "$d/log"; stub_claude "$p" "$d/log"; stub_bwrap "$p"
  out="$(run "$p" "$d/repo" --reviewers agy --pin agy=gemini-9-imaginary --no-verify)"
  assert_contains "$out" "gemini-9-imaginary is not in \`agy models\`" "checked before the round"
  assert_contains "$out" "rc=2" "a refusal"
}

test_every_blocking_problem_is_reported_in_one_run() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  pr_test_mkstub "$p/codex" 'exit 1'
  stub_agy "$p" "$d/log"; stub_claude "$p" "$d/log"; stub_bwrap "$p"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "codex is not authenticated" "the auth problem"
  assert_contains "$out" "PR_AGY_MODEL is unset" "and the pin problem, in the same run"
}

test_offline_writes_the_pins_unvalidated_and_calls_nothing() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_agy "$p" "$d/log"; stub_claude "$p" "$d/log"; stub_bwrap "$p"
  out="$(run "$p" "$d/repo" --reviewers agy --pin agy=gemini-9-imaginary --offline --no-verify)"
  assert_contains "$out" "rc=0" "an imaginary id is written when nothing checked it"
  assert_contains "$out" "written unvalidated" "and the output says so"
  assert_file_missing "$d/log" "no auth call and no model-list call"
}

# --- the writes -------------------------------------------------------------

test_an_existing_config_needs_force_and_force_is_idempotent() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  run "$p" "$d/repo" --no-verify > /dev/null
  cp "$d/repo/.plan-review/config.json" "$d/first.json"

  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "already exists" "names the path it will not overwrite"
  assert_contains "$out" "rc=2" "a refusal"

  out="$(run "$p" "$d/repo" --force --no-verify)"
  assert_contains "$out" "rc=0" "--force rewrites it whole"
  assert_eq "$(cat "$d/repo/.plan-review/config.json")" "$(cat "$d/first.json")" \
    "same inputs, same bytes"
}

test_a_symlinked_config_or_directory_is_refused_with_and_without_force() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  mkdir -p "$d/elsewhere"
  ln -s "$d/elsewhere" "$d/repo/.plan-review"
  out="$(run "$p" "$d/repo" --force --no-verify)"
  assert_contains "$out" "is a symlink" "refused rather than followed"
  assert_contains "$out" "rc=2" "a refusal"
  assert_file_missing "$d/elsewhere/config.json" "and nothing was written through it"

  rm "$d/repo/.plan-review"
  mkdir -p "$d/repo/.plan-review"
  : > "$d/elsewhere/config.json"
  ln -s "$d/elsewhere/config.json" "$d/repo/.plan-review/config.json"
  out="$(run "$p" "$d/repo" --force --no-verify)"
  assert_contains "$out" "is a symlink" "the file case too"
  assert_contains "$out" "rc=2" "a refusal"
  assert_eq "$(cat "$d/elsewhere/config.json")" "" "the target is untouched"
}

test_the_ignore_line_is_added_once_and_never_welded_onto_another_rule() {
  local d p; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  printf 'node_modules/' > "$d/repo/.gitignore"     # no trailing newline
  run "$p" "$d/repo" --no-verify > /dev/null
  assert_eq "$(cat "$d/repo/.gitignore")" "node_modules/
.plan-review/" "the existing rule survives intact"

  run "$p" "$d/repo" --force --no-verify > /dev/null
  assert_eq "$(grep -c '^\.plan-review/$' "$d/repo/.gitignore")" "1" "and is not added twice"
}

# git check-ignore is what the doctor asks, and it honours .git/info/exclude.
# Matching the doctor matters more here than a uniform .gitignore.
test_a_repo_that_ignores_the_path_some_other_way_gets_no_line() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  printf '.plan-review/\n' >> "$d/repo/.git/info/exclude"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_contains "$out" "already ignored" "the doctor would agree"
  assert_file_missing "$d/repo/.gitignore" "so no tracked file was touched"
}

# --- refusals that cost nothing ---------------------------------------------

test_a_conflicting_environment_refuses_before_any_probe() {
  local d p out rc; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  local var
  for var in PR_CONFIG=/tmp/x.json PR_ADAPTER_MAP="codex=/tmp/a.sh" PR_PRESET=quick PR_SKIP_CONFIG=1; do
    out="$(PATH="$p" PR_ORCHESTRATOR=claude env "$var" "$BASH" "$INIT" init --repo "$d/repo" --no-verify 2>&1)"
    rc=$?
    assert_exit_code "$rc" 2 "${var%%=*} refuses"
    assert_contains "$out" "${var%%=*}" "and names the variable"
    assert_file_missing "$d/repo/.plan-review" "having written nothing"
  done
  assert_file_missing "$d/log" "and having called nothing"
}

# Only the literal 1 changes what the doctor would read (lib/config.sh:211), and
# inventing a stricter reading of someone else's variable is not init's business.
test_pr_skip_config_is_rejected_at_one_and_ignored_otherwise() {
  local d p out rc; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  out="$(PATH="$p" PR_ORCHESTRATOR=claude PR_SKIP_CONFIG=0 "$BASH" "$INIT" init --repo "$d/repo" --no-verify 2>&1)"
  rc=$?
  assert_exit_code "$rc" 0 "PR_SKIP_CONFIG=0 is not PR_SKIP_CONFIG=1"
}

test_argument_contradictions_are_caught_before_anything_is_asked() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"

  out="$(run "$p" "$d/repo" --reviewers codex,codex --no-verify)"
  assert_contains "$out" "twice" "a duplicate reviewer"
  out="$(run "$p" "$d/repo" --reviewers codex,,agy --no-verify)"
  assert_contains "$out" "empty name" "an empty token"
  out="$(run "$p" "$d/repo" --reviewers cursor --no-verify)"
  assert_contains "$out" "not one of" "the adapter's name, not the vendor's"
  out="$(run "$p" "$d/repo" --pin agy --no-verify)"
  assert_contains "$out" "no '='" "a malformed pin"
  out="$(run "$p" "$d/repo" --pin agy=a --pin agy=b --no-verify)"
  assert_contains "$out" "twice for agy" "a repeated pin"
  out="$(run "$p" "$d/repo" --reviewers codex --pin agy=a --no-verify)"
  assert_contains "$out" "not in the roster" "a pin for a CLI that is not reviewing"

  assert_file_missing "$d/log" "no CLI was invoked for any of them"
  assert_file_missing "$d/repo/.plan-review" "and nothing was written"
}

test_a_pin_that_disagrees_with_an_exported_one_refuses() {
  local d p out rc; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_agy "$p" "$d/log"; stub_claude "$p" "$d/log"; stub_bwrap "$p"
  out="$(PATH="$p" PR_ORCHESTRATOR=claude PR_AGY_MODEL=gemini-3.1-pro-high \
         "$BASH" "$INIT" init --repo "$d/repo" --reviewers agy --pin agy=gemini-3.7-flash-low --no-verify 2>&1)"
  rc=$?
  assert_exit_code "$rc" 2 "two answers to one question"
  assert_contains "$out" "name different models" "says what disagrees"
}

test_no_repo_is_an_argument_error_and_a_missing_one_is_named() {
  local d p out rc; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"
  out="$(PATH="$p" PR_ORCHESTRATOR=claude "$BASH" "$INIT" init --no-verify 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "--repo is required"
  out="$(run "$p" "$d/nowhere" --no-verify)"
  assert_contains "$out" "no such directory" "names what it could not find"
  mkdir -p "$d/plain"
  out="$(run "$p" "$d/plain" --no-verify)"
  assert_contains "$out" "not a git repository" "and what it is not"
}

test_an_unset_orchestrator_refuses_exactly_as_a_round_does() {
  local d p out rc; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  out="$(PATH="$p" PR_ORCHESTRATOR="" "$BASH" "$INIT" init --repo "$d/repo" --no-verify 2>&1)"; rc=$?
  assert_exit_code "$rc" 2 "no default is right for everyone"
  assert_contains "$out" "PR_ORCHESTRATOR is unset" "the roster's own refusal"
}

# --- verification -----------------------------------------------------------

test_no_verify_runs_no_doctor() {
  local d p out; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  stub_codex "$p" "$d/log"; stub_claude "$p" "$d/log"
  out="$(run "$p" "$d/repo" --no-verify)"
  assert_not_contains "$out" "plan-review doctor" "no subprocess"
  assert_contains "$out" "readiness was not measured" "and exit 0 says what it means"
}

# The whole point: one command, and the doctor is green afterwards. This needs
# everything pr_doctor_check_utils asks for, so the PATH is wider here than in
# any other case -- which is itself the measurement.
test_a_generated_config_leaves_the_doctor_green() {
  local d p out u real; d="$(pr_test_tmpdir)"; p="$(mkpath "$d/bin")"; mkrepo "$d/repo"
  for u in $PR_DOCTOR_UTILS cut grep awk head; do
    real="$(command -v "$u")" && ln -sf "$real" "$p/$u"
  done
  stub_codex "$p" "$d/log"; stub_agy "$p" "$d/log"; stub_claude "$p" "$d/log"; stub_bwrap "$p"
  out="$(PATH="$p" PR_ORCHESTRATOR=claude PR_CACHE_ROOT="$d/cache" \
         PR_AGY_MODEL="" PR_CODEX_MODEL="" \
         "$BASH" "$INIT" init --repo "$d/repo" --pin agy=gemini-3.1-pro-high 2>&1
         printf 'rc=%s' "$?")"
  assert_contains "$out" "plan-review doctor" "the real doctor, as a subprocess"
  assert_contains "$out" "0 failed" "green"
  assert_contains "$out" "rc=0" "and init exits with its status"
  assert_contains "$out" "config parsed and resolved" "over the file init just wrote"
}

pr_run_tests
