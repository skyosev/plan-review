#!/usr/bin/env bash
set -uo pipefail
PR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PR_ROOT/tests/helpers.sh"
source "$PR_ROOT/lib/paths.sh"
source "$PR_ROOT/lib/roster.sh"
source "$PR_ROOT/lib/doctor.sh"
source "$PR_ROOT/lib/config.sh"

# Every resolution runs in a subshell. pr_config_resolve EXPORTS the pins it
# resolves, which is the whole point of it, and one test's exports would
# otherwise decide the next test's precedence.

# mkrepo <dir> [config-json] -- a repo-shaped directory, optionally with a config
mkrepo() {
  local d="$1" cfg="${2:-}"
  mkdir -p "$d/.plan-review/prompts"
  printf 'Check the threat model.\n' > "$d/.plan-review/prompts/initial.md"
  printf 'Was it fixed?\n'          > "$d/.plan-review/prompts/rereview.md"
  [[ -n "$cfg" ]] && printf '%s\n' "$cfg" > "$d/.plan-review/config.json"
  return 0
}

# resolve <repo> [preset] -- the resolved record, plus the fields that live in
# variables rather than in it. Empty output means the resolution failed.
resolve() {
  ( pr_config_resolve "$1" "${2:-}" > /dev/null 2>&1 || exit 1
    jq -c --arg rev "$PR_CONFIG_REVIEWERS" \
          --arg ci "$PR_CONFIG_CRITERIA_INITIAL" \
          --arg cr "$PR_CONFIG_CRITERIA_REREVIEW" \
          --arg cm "${PR_CODEX_MODEL:-}" --arg ce "${PR_CODEX_EFFORT:-}" \
          --arg am "${PR_AGY_MODEL:-}" \
          '. + {rev: $rev, ci: $ci, cr: $cr,
                exported: {codex_model: $cm, codex_effort: $ce, agy_model: $am}}' \
      <<<"$PR_CONFIG_RECORD" )
}

# try <repo> [preset] -- stderr and the exit code, for the refusals
try() {
  local out rc
  out="$( ( pr_config_resolve "$1" "${2:-}" > /dev/null ) 2>&1 )"; rc=$?
  printf '%s\nrc=%s' "$out" "$rc"
}

# --- discovery --------------------------------------------------------------

test_no_config_resolves_to_todays_defaults() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo"
  out="$(resolve "$d/repo")"
  assert_eq "$(jq -r '.path' <<<"$out")" "null" "no config file, no path"
  assert_eq "$(jq -r '.rev' <<<"$out")" "" "the roster is derived, not stated"
  assert_eq "$(jq -c '.pins' <<<"$out")" "{}" "no pins to record"
}

test_pr_config_points_at_a_config_outside_the_repo() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo"
  mkrepo "$d/elsewhere" '{"reviewers": ["codex"]}'
  out="$(PR_CONFIG="$d/elsewhere/.plan-review/config.json" resolve "$d/repo")"
  assert_eq "$(jq -r '.rev' <<<"$out")" "codex" "the external config is what applied"
}

test_a_missing_pr_config_is_a_refusal_not_a_fallback() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo"
  out="$(PR_CONFIG="$d/nope.json" try "$d/repo")"
  assert_contains "$out" "does not exist" "says so"
  assert_contains "$out" "rc=1" "and refuses"
}

test_skip_config_ignores_a_config_that_is_there() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"reviewers": ["codex"]}'
  out="$(PR_SKIP_CONFIG=1 resolve "$d/repo")"
  assert_eq "$(jq -r '.path' <<<"$out")" "null" "the file was not read"
  assert_eq "$(jq -r '.rev' <<<"$out")" "" "and its roster did not apply"
}

test_skip_config_together_with_a_preset_is_a_contradiction() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"presets": {"quick": {}}}'
  out="$(PR_SKIP_CONFIG=1 try "$d/repo" quick)"
  assert_contains "$out" "PR_SKIP_CONFIG=1" "names both sides"
  assert_contains "$out" "rc=1" "and refuses rather than picking one"
}

# --- shape ------------------------------------------------------------------

test_malformed_json_refuses_and_never_falls_back_to_defaults() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"reviewers": ['
  out="$(try "$d/repo")"
  assert_contains "$out" "not a readable JSON object" "says what is wrong"
  assert_contains "$out" "never silently replaced by defaults" "and why it stops"
  assert_contains "$out" "rc=1" "a refusal"
}

test_a_top_level_that_is_not_an_object_refuses() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '["codex"]'
  out="$(try "$d/repo")"
  assert_contains "$out" "rc=1" "an array is not a config"
}

# The reason the schema is strict: "reviewrs" silently ignored is a silently
# wrong roster, and a round that ran the wrong reviewers looks exactly like one
# that ran the right ones.
test_an_unknown_top_level_key_refuses_and_names_it() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"reviewrs": ["codex"]}'
  out="$(try "$d/repo")"
  assert_contains "$out" 'unknown key "reviewrs" at the top level' "named, not guessed at"
  assert_contains "$out" "rc=1" "a refusal"
}

test_an_unknown_cli_under_pins_refuses() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"pins": {"codx": {"model": "x"}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" 'unknown key "codx" under "pins"' "a typo is not inert"
  assert_contains "$out" "rc=1" "a refusal"
}

test_an_unknown_key_inside_a_pin_refuses() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"pins": {"codex": {"modell": "x"}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" 'unknown key "modell"' "named"
  assert_contains "$out" "rc=1" "a refusal"
}

test_an_unknown_criteria_slot_refuses() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"criteria": {"third_round": "prompts/initial.md"}}'
  out="$(try "$d/repo")"
  assert_contains "$out" 'unknown key "third_round"' "only initial and rereview exist"
  assert_contains "$out" "rc=1" "a refusal"
}

test_pins_that_are_not_an_object_refuse() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"pins": ["codex"]}'
  out="$(try "$d/repo")"
  assert_contains "$out" 'must be an object' "says what shape it wanted"
  assert_contains "$out" "rc=1" "a refusal"
}

test_every_problem_is_reported_at_once() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"reviewrs": [], "pins": {"codx": {"model": "x"}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" "reviewrs" "the first"
  assert_contains "$out" "codx" "and the second, in one run"
}

# --- values -----------------------------------------------------------------

test_an_unknown_reviewer_name_refuses() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"reviewers": ["cursor"]}'
  out="$(try "$d/repo")"
  assert_contains "$out" "not one of: codex, agent, agy, claude" "lists what exists"
  assert_contains "$out" "rc=1" "a refusal"
}

test_an_empty_reviewer_list_refuses() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"reviewers": []}'
  out="$(try "$d/repo")"
  assert_contains "$out" "at least one reviewer" "a round with no reviewers is not a round"
  assert_contains "$out" "rc=1" "a refusal"
}

test_a_repeated_reviewer_refuses() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"reviewers": ["codex", "codex"]}'
  out="$(try "$d/repo")"
  assert_contains "$out" "same reviewer twice" "one instance per adapter (D13)"
  assert_contains "$out" "rc=1" "a refusal"
}

test_one_reviewer_is_a_valid_roster() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" '{"reviewers": ["codex"]}'
  out="$(resolve "$d/repo")"
  assert_eq "$(jq -r '.rev' <<<"$out")" "codex" "one reviewer is a roster"
}

test_an_effort_outside_the_enum_refuses_before_the_backend_does() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"pins": {"codex": {"effort": "hgih"}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" "not one of: none, minimal, low" "the codex enum"
  assert_contains "$out" "rc=1" "a refusal"
}

# The two enums differ, and the difference is the point of checking each against
# its own: claude has no `none` and no `minimal`.
test_the_claude_enum_is_not_the_codex_enum() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"pins": {"claude": {"effort": "minimal"}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" '"pins.claude.effort"' "rejected for claude"
  assert_contains "$out" "rc=1" "a refusal"

  mkrepo "$d/repo2" '{"pins": {"codex": {"effort": "minimal"}}}'
  out="$(resolve "$d/repo2")"
  assert_eq "$(jq -r '.pins.codex.effort' <<<"$out")" "minimal" "accepted for codex"
}

# The flag exists on agy and is unreachable: it is mutually exclusive with
# --model, which is required because agy reports no effective model.
test_effort_on_agy_or_cursor_refuses_and_says_where_the_tier_lives() {
  local d out cli; d="$(pr_test_tmpdir)"
  for cli in agy agent; do
    mkrepo "$d/$cli" "{\"pins\": {\"$cli\": {\"effort\": \"high\"}}}"
    out="$(try "$d/$cli")"
    assert_contains "$out" "the tier lives in the model id" "the true reason, for $cli"
    assert_contains "$out" "rc=1" "a refusal for $cli"
  done
}

test_an_empty_model_string_refuses() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"pins": {"codex": {"model": ""}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" "non-empty string" "an empty pin is not a pin"
  assert_contains "$out" "rc=1" "a refusal"
}

# --- criteria ---------------------------------------------------------------

test_criteria_resolve_against_the_configs_own_directory() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"criteria": {"initial": "prompts/initial.md"}}'
  out="$(resolve "$d/repo")"
  assert_eq "$(jq -r '.ci' <<<"$out")" \
    "$(readlink -f "$d/repo/.plan-review/prompts/initial.md")" "resolved to a real file"
  assert_eq "$(jq -r '.criteria.initial' <<<"$out")" "prompts/initial.md" \
    "recorded as written, so the record is portable"
  assert_eq "$(jq -r '.criteria.rereview' <<<"$out")" "null" "the unset slot stays null"
}

# The anchor is the config, not the repo. Without this an external PR_CONFIG and
# a criteria file could not both exist.
test_an_external_configs_criteria_resolve_beside_that_config() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo"
  mkrepo "$d/elsewhere" '{"criteria": {"initial": "prompts/initial.md"}}'
  out="$(PR_CONFIG="$d/elsewhere/.plan-review/config.json" resolve "$d/repo")"
  assert_contains "$(jq -r '.ci' <<<"$out")" "elsewhere" "beside the config that named it"
}

test_a_criteria_path_leaving_the_config_directory_refuses() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"criteria": {"initial": "../../etc/passwd"}}'
  out="$(try "$d/repo")"
  assert_contains "$out" "walks out of the config's directory" "rejected"
  assert_contains "$out" "rc=1" "a refusal"
}

# A symlink walks straight past the '..' check, which is why canonicalisation is
# the actual control and the syntactic check is only a better message.
test_a_symlinked_criteria_file_is_caught_by_canonicalisation() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"criteria": {"initial": "prompts/sneaky.md"}}'
  printf 'outside\n' > "$d/outside.md"
  ln -s "$d/outside.md" "$d/repo/.plan-review/prompts/sneaky.md"
  out="$(try "$d/repo")"
  assert_contains "$out" "resolves outside" "the link target is what counts"
  assert_contains "$out" "rc=1" "a refusal"
}

test_a_missing_or_empty_criteria_file_refuses() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"criteria": {"initial": "prompts/absent.md"}}'
  out="$(try "$d/repo")"
  assert_contains "$out" "readable, non-empty file" "says which property failed"

  mkrepo "$d/empty" '{"criteria": {"initial": "prompts/blank.md"}}'
  : > "$d/empty/.plan-review/prompts/blank.md"
  out="$(try "$d/empty")"
  assert_contains "$out" "readable, non-empty file" "an empty brief is not a brief"
  assert_contains "$out" "rc=1" "a refusal"
}

# --- presets ----------------------------------------------------------------

CFG_PRESETS='{
  "reviewers": ["codex", "agy"],
  "pins": {"codex": {"model": "gpt-5.6-sol", "effort": "xhigh"},
           "agy": {"model": "gemini-3.1-pro-high"}},
  "criteria": {"initial": "prompts/initial.md"},
  "presets": {
    "quick": {"reviewers": ["codex"], "pins": {"codex": {"effort": "low"}}},
    "security": {"criteria": {"initial": "prompts/rereview.md"}}
  }
}'

test_a_preset_replaces_the_reviewer_list_wholesale() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(resolve "$d/repo" quick)"
  assert_eq "$(jq -r '.rev' <<<"$out")" "codex" "a list has no sensible merge"
  assert_eq "$(jq -r '.preset' <<<"$out")" "quick" "and the choice is recorded"
}

# D5's own worked example, and the reason provenance is per field: `effort` came
# from the preset and `model` from the top level, in one pin.
test_a_preset_merges_pins_per_field_and_records_both_sources() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(resolve "$d/repo" quick)"
  assert_eq "$(jq -r '.pins.codex.effort' <<<"$out")" "low" "the preset's effort"
  assert_eq "$(jq -r '.pins.codex.effort_source' <<<"$out")" "preset:quick" "from the preset"
  assert_eq "$(jq -r '.pins.codex.model' <<<"$out")" "gpt-5.6-sol" "the inherited model"
  assert_eq "$(jq -r '.pins.codex.model_source' <<<"$out")" "config" "from the top level"
}

test_a_preset_merges_criteria_per_slot() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(resolve "$d/repo" security)"
  assert_contains "$(jq -r '.ci' <<<"$out")" "rereview.md" "the preset's initial brief"
  assert_eq "$(jq -r '.rev' <<<"$out")" "codex agy" "and the top-level roster survives"
}

test_default_preset_applies_when_nothing_names_one() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"default_preset": "quick",
                     "presets": {"quick": {"reviewers": ["codex"]}}}'
  out="$(resolve "$d/repo")"
  assert_eq "$(jq -r '.preset' <<<"$out")" "quick" "the default was selected"
}

test_an_unknown_preset_refuses_and_lists_the_real_ones() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(try "$d/repo" thorough)"
  assert_contains "$out" "no preset named 'thorough'" "named"
  assert_contains "$out" "presets defined: quick, security" "and the alternatives listed"
  assert_contains "$out" "rc=1" "a refusal"
}

test_a_preset_may_not_carry_a_default_preset_of_its_own() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"presets": {"quick": {"default_preset": "quick"}}}'
  out="$(try "$d/repo")"
  assert_contains "$out" 'unknown key "default_preset" in preset "quick"' "no inheritance layer"
  assert_contains "$out" "rc=1" "a refusal"
}

# The flag is typed per run and the variable is exported once by the skill, so
# silently overriding one with the other is the drift the record exists to show.
test_a_flag_and_a_variable_naming_different_presets_refuse() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(PR_PRESET=security try "$d/repo" quick)"
  assert_contains "$out" "name different presets" "neither wins"
  assert_contains "$out" "rc=1" "a refusal"
}

test_a_flag_and_a_variable_naming_the_same_preset_are_fine() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(PR_PRESET=quick resolve "$d/repo" quick)"
  assert_eq "$(jq -r '.preset' <<<"$out")" "quick" "agreement is not a conflict"
}

test_pr_preset_alone_selects_a_preset() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(PR_PRESET=quick resolve "$d/repo")"
  assert_eq "$(jq -r '.rev' <<<"$out")" "codex" "the variable is the flag's equal"
}

# --- precedence -------------------------------------------------------------

test_an_environment_pin_beats_the_config_and_says_so() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(PR_AGY_MODEL=env-wins resolve "$d/repo")"
  assert_eq "$(jq -r '.pins.agy.model' <<<"$out")" "env-wins" "the one-off wins"
  assert_eq "$(jq -r '.pins.agy.model_source' <<<"$out")" "env" "and is visible as one"
}

test_an_environment_pin_beats_a_preset_too() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(PR_CODEX_EFFORT=high resolve "$d/repo" quick)"
  assert_eq "$(jq -r '.pins.codex.effort' <<<"$out")" "high" "not the preset's low"
  assert_eq "$(jq -r '.pins.codex.effort_source' <<<"$out")" "env" "recorded honestly"
}

# The adapters read the environment and know nothing about a config file. If the
# resolution did not export, a config's pins would be inert.
test_resolved_pins_are_exported_for_the_adapters() {
  local d out; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  out="$(resolve "$d/repo")"
  assert_eq "$(jq -r '.exported.codex_model' <<<"$out")" "gpt-5.6-sol" "PR_CODEX_MODEL"
  assert_eq "$(jq -r '.exported.codex_effort' <<<"$out")" "xhigh" "PR_CODEX_EFFORT"
  assert_eq "$(jq -r '.exported.agy_model' <<<"$out")" "gemini-3.1-pro-high" "PR_AGY_MODEL"
}

# Pins for CLIs outside the roster are the defaults other presets draw on.
test_a_pin_for_a_reviewer_outside_the_roster_is_ignored_not_an_error() {
  local d out; d="$(pr_test_tmpdir)"
  mkrepo "$d/repo" '{"reviewers": ["codex"], "pins": {"agy": {"model": "gemini-3.1-pro-high"}}}'
  out="$(resolve "$d/repo")"
  assert_eq "$(jq -r '.rev' <<<"$out")" "codex" "the roster is unaffected"
  assert_eq "$(jq -r '.pins.agy.model' <<<"$out")" "gemini-3.1-pro-high" "the pin is still resolved"
}

# --- the resolved-value effort check ----------------------------------------

test_a_bad_environment_effort_is_caught_even_with_no_config() {
  local out rc
  out="$( ( PR_CODEX_EFFORT=hgih pr_config_check_efforts ) 2>&1 )"; rc=$?
  assert_contains "$out" "is not one of" "the stale export is the likeliest bad tier"
  assert_exit_code "$rc" 1 "and it is refused"
}

test_a_good_environment_effort_passes() {
  ( PR_CODEX_EFFORT=xhigh PR_CLAUDE_EFFORT=high pr_config_check_efforts ) 2>/dev/null \
    || pr_fail "valid tiers on both axes"
  return 0
}

test_the_claude_effort_enum_is_enforced_on_the_resolved_value_too() {
  local out rc
  out="$( ( PR_CLAUDE_EFFORT=none pr_config_check_efforts ) 2>&1 )"; rc=$?
  assert_contains "$out" "differs from codex's" "explains the difference"
  assert_exit_code "$rc" 1 "refused"
}

# --- the drift hash ---------------------------------------------------------

hash_of() {  # hash_of <repo> [preset] -- the settings hash, criteria included
  ( pr_config_resolve "$1" "${2:-}" > /dev/null 2>&1 || exit 1
    pr_config_hash "codex agy" "$PR_CONFIG_CRITERIA_INITIAL" "$PR_CONFIG_CRITERIA_REREVIEW" )
}

test_the_hash_is_stable_across_runs_of_an_unchanged_config() {
  local d a b; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  a="$(hash_of "$d/repo")"; b="$(hash_of "$d/repo")"
  assert_eq "$a" "$b" "no drift warning for standing still"
}

# The likeliest change of all, and the one a hash over the JSON alone misses.
test_editing_a_criteria_file_changes_the_hash() {
  local d a b; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  a="$(hash_of "$d/repo")"
  printf 'Also check the tests.\n' >> "$d/repo/.plan-review/prompts/initial.md"
  b="$(hash_of "$d/repo")"
  [[ "$a" != "$b" ]] || pr_fail "the criteria contents are part of the settings"
  return 0
}

test_changing_a_pin_changes_the_hash() {
  local d a b; d="$(pr_test_tmpdir)"; mkrepo "$d/repo" "$CFG_PRESETS"
  a="$(hash_of "$d/repo")"
  b="$(PR_AGY_MODEL=something-else hash_of "$d/repo")"
  [[ "$a" != "$b" ]] || pr_fail "a mid-loop env change is detectable now"
  return 0
}

# Values, not provenance: the same model from the environment and from the
# config is the same setting, and a round run either way is comparable.
test_the_same_values_from_different_sources_hash_the_same() {
  local d a b; d="$(pr_test_tmpdir)"
  mkrepo "$d/config" '{"pins": {"agy": {"model": "gemini-3.1-pro-high"}}}'
  mkrepo "$d/env"
  a="$(hash_of "$d/config")"
  b="$(PR_AGY_MODEL=gemini-3.1-pro-high hash_of "$d/env")"
  assert_eq "$a" "$b" "the hash covers what applied, not where it came from"
}


pr_run_tests
