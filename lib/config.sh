#!/usr/bin/env bash
# Per-project configuration: <repo>/.plan-review/config.json.
#
# Resolves into the PR_*_MODEL / PR_*_EFFORT variables the adapters already read
# (D17), so nothing downstream of this file knows a config exists: the adapters,
# docs/adapter-contract.md and pr_doctor_preflight's adapter-path keying are
# untouched.
#
# This needs `jq`, which is why it is NOT in lib/doctor.sh -- that file uses bash
# builtins only so tests/test-doctor.sh can point PATH at a stub directory alone
# (lib/doctor.sh:9-14). It is sourced by both bin/ entry points AFTER
# lib/doctor.sh and lib/roster.sh, whose effort enums and adapter list it uses.
#
# Sourcing has no side effects. Nothing here reads a file until pr_config_resolve
# is called.

PR_CONFIG_SLOTS="initial rereview"
PR_CONFIG_TOP_KEYS="default_preset reviewers pins criteria presets"
PR_CONFIG_PRESET_KEYS="reviewers pins criteria"

# Set by pr_config_resolve. Empty means "nothing resolved to it".
PR_CONFIG_PATH=""            # absolute path to the config file, or ""
PR_CONFIG_PRESET=""          # selected preset name, or ""
PR_CONFIG_REVIEWERS=""       # space-separated reviewer keys, or "" (derive)
PR_CONFIG_CRITERIA_INITIAL=""   # absolute path to the source file, or ""
PR_CONFIG_CRITERIA_REREVIEW=""
PR_CONFIG_RECORD='{"path":null,"preset":null,"pins":{},"criteria":{"initial":null,"rereview":null}}'

# --- validation -------------------------------------------------------------
# One jq program, returning an array of error strings. Everything expressible in
# JSON terms is checked here so the runner and the doctor cannot diverge on a
# case nobody wrote down (D16). File-system facts -- readable, non-empty,
# contained -- are checked in bash below, because jq cannot see them.
#
# The effort enums are checked here AND on the resolved value. A config effort
# that a stale env pin happens to mask is still wrong, and it goes live the
# moment that export is dropped.
read -r -d '' _PR_CONFIG_VALIDATE_JQ <<'JQ' || true
def unknown($o; $known; $where):
  (($o | keys_unsorted) - $known) | map("unknown key \"\(.)\" \($where)");

def nonempty($v): ($v | type) == "string" and ($v | length) > 0;

def check_reviewers($r; $where):
  if ($r | type) != "array" then ["\"reviewers\" \($where) must be an array"]
  elif ($r | length) == 0 then ["\"reviewers\" \($where) must name at least one reviewer"]
  else
    [ $r[] | . as $name
      | select(($name | type) != "string" or ($adapters | index($name)) == null)
      | "\"reviewers\" \($where) names \($name | tojson), which is not one of: \($adapters | join(", "))" ]
    + (if ($r | unique | length) != ($r | length)
       then ["\"reviewers\" \($where) lists the same reviewer twice"] else [] end)
  end;

def check_effort($cli; $v; $where):
  if $cli == "agy" or $cli == "agent"
  then ["\"pins.\($cli).effort\" \($where) is not settable: for \($cli) the tier lives in the model id"]
  elif (nonempty($v) | not)
  then ["\"pins.\($cli).effort\" \($where) must be a non-empty string"]
  elif $cli == "codex" and ($codex_efforts | index($v)) == null
  then ["\"pins.codex.effort\" \($where) is \"\($v)\", not one of: \($codex_efforts | join(", "))"]
  elif $cli == "claude" and ($claude_efforts | index($v)) == null
  then ["\"pins.claude.effort\" \($where) is \"\($v)\", not one of: \($claude_efforts | join(", "))"]
  else [] end;

def check_pins($p; $where):
  if ($p | type) != "object" then ["\"pins\" \($where) must be an object"]
  else
    unknown($p; $adapters; "under \"pins\" \($where)")
    + ([ $p | to_entries[]
         | .key as $cli | .value as $pin
         | if ($pin | type) != "object" then ["\"pins.\($cli)\" \($where) must be an object"]
           else
             unknown($pin; ["model", "effort"]; "in \"pins.\($cli)\" \($where)")
             + (if ($pin | has("model")) and (nonempty($pin.model) | not)
                then ["\"pins.\($cli).model\" \($where) must be a non-empty string"] else [] end)
             + (if ($pin | has("effort")) then check_effort($cli; $pin.effort; $where) else [] end)
           end ] | add // [])
  end;

def check_criteria($c; $where):
  if ($c | type) != "object" then ["\"criteria\" \($where) must be an object"]
  else
    unknown($c; ["initial", "rereview"]; "under \"criteria\" \($where)")
    + [ $c | to_entries[] | select(nonempty(.value) | not)
        | "\"criteria.\(.key)\" \($where) must be a non-empty string" ]
  end;

unknown(.; ($top_keys); "at the top level")
+ (if has("default_preset") and (nonempty(.default_preset) | not)
   then ["\"default_preset\" must be a non-empty string"] else [] end)
+ (if has("reviewers") then check_reviewers(.reviewers; "at the top level") else [] end)
+ (if has("pins")      then check_pins(.pins; "at the top level") else [] end)
+ (if has("criteria")  then check_criteria(.criteria; "at the top level") else [] end)
+ (if has("presets") then
     (if (.presets | type) != "object" then ["\"presets\" must be an object"]
      else [ .presets | to_entries[]
             | .key as $n | .value as $p
             | if ($p | type) != "object" then ["preset \"\($n)\" must be an object"]
               else unknown($p; $preset_keys; "in preset \"\($n)\"")
                 + (if ($p | has("reviewers")) then check_reviewers($p.reviewers; "in preset \"\($n)\"") else [] end)
                 + (if ($p | has("pins"))      then check_pins($p.pins; "in preset \"\($n)\"") else [] end)
                 + (if ($p | has("criteria"))  then check_criteria($p.criteria; "in preset \"\($n)\"") else [] end)
               end ] | add // []
      end)
   else [] end)
JQ

_pr_config_err() {
  printf '%s\n' "$@" >&2
}

# _pr_config_json_errors <file>
# Every JSON-expressible rule at once, so one run reports every problem rather
# than one per invocation.
_pr_config_json_errors() {
  jq -r --argjson adapters "$(_pr_config_json_array "$PR_ROSTER_ADAPTERS")" \
        --argjson top_keys "$(_pr_config_json_array "$PR_CONFIG_TOP_KEYS")" \
        --argjson preset_keys "$(_pr_config_json_array "$PR_CONFIG_PRESET_KEYS")" \
        --argjson codex_efforts "$(_pr_config_json_array "$PR_EFFORTS_CODEX")" \
        --argjson claude_efforts "$(_pr_config_json_array "$PR_EFFORTS_CLAUDE")" \
        "$_PR_CONFIG_VALIDATE_JQ | .[]" "$1"
}

# Space-separated words -> a JSON array.
_pr_config_json_array() {
  local w out="" sep=""
  for w in $1; do
    out="${out}${sep}\"${w}\""
    sep=","
  done
  printf '[%s]' "$out"
}

# --- criteria paths ---------------------------------------------------------

# _pr_config_criteria_path <config-dir> <slot> <value>
# Echoes the resolved absolute path, or explains and returns 1.
#
# Resolved against the CONFIG's directory, not the repo's: that is what lets a
# PR_CONFIG outside the repo carry its own prompts (D3). Containment is checked
# after `readlink -f`, which is the actual control -- the '..' rejection below
# only buys a better message, and a symlink walks straight past it.
_pr_config_criteria_path() {
  local dir="$1" slot="$2" v="$3" abs canon_dir candidate

  if pr_path_escapes "$v"; then
    _pr_config_err "criteria.$slot: '$v' walks out of the config's directory."
    return 1
  fi

  [[ "$v" == /* ]] && candidate="$v" || candidate="$dir/$v"
  if ! pr_path_resolve_within "$dir" "$candidate" abs canon_dir; then
    _pr_config_err "criteria.$slot: '$v' resolves outside $canon_dir." \
                   "  Criteria files must live beside the config that names them."
    return 1
  fi
  if [[ ! -r "$abs" || ! -s "$abs" ]]; then
    _pr_config_err "criteria.$slot: $abs is not a readable, non-empty file."
    return 1
  fi
  printf '%s' "$abs"
}

# --- effort, on the resolved value ------------------------------------------

# pr_config_check_efforts
#
# Called by the runner after pr_config_resolve, and separate from it because the
# doctor reports the same fact as a FAIL line rather than exiting: a diagnosis
# that stops at the first problem is a worse diagnosis.
#
# The enums are checked again here, on whatever won the precedence contest.
# Env pins outrank both the preset and the config (D6), so a stale
# `PR_CODEX_EFFORT=hgih` is the likeliest way a bad tier ever reaches a backend
# -- and it is the one path a check over the JSON alone would miss. This runs
# with or without a config file.
# The same indirection pr_config_resolve uses for pins: a CLI has an effort axis
# exactly when lib/doctor.sh declares a PR_EFFORTS_<CLI> enum for it, and the
# explanation comes from pr_doctor_effort_note. Naming codex and claude here as
# well was a third copy of a fact stated in two other files.
pr_config_check_efforts() {
  local rc=0 cli enum var line notes
  for cli in $PR_ROSTER_ADAPTERS; do
    enum="PR_EFFORTS_${cli^^}"
    var="PR_${cli^^}_EFFORT"
    [[ -n "${!enum:-}" && -n "${!var:-}" ]] || continue
    [[ " ${!enum} " == *" ${!var} "* ]] && continue
    notes=()
    while IFS= read -r line; do notes+=("  $line"); done < <(pr_doctor_effort_note "$cli")
    _pr_config_err "$var='${!var}' is not one of: ${!enum}" "${notes[@]}"
    rc=1
  done
  return "$rc"
}

# --- resolution -------------------------------------------------------------

# pr_config_resolve <repo> [preset-from-flag]
#
# Discovers, validates and resolves. Sets the PR_CONFIG_* globals, exports the
# resolved pins, and returns 1 with an explanation on stderr for every rule in
# the brainstorm's "Validation rules". Callers exit 2 on that 1: a config that
# does not parse must not become a round that half-ran.
pr_config_resolve() {
  local repo="$1" preset_flag="${2:-}"
  local path="" dir="" raw="{}" errors preset="" cli field env_name value source

  PR_CONFIG_PATH="" PR_CONFIG_PRESET="" PR_CONFIG_REVIEWERS=""
  PR_CONFIG_CRITERIA_INITIAL="" PR_CONFIG_CRITERIA_REREVIEW=""

  if [[ "${PR_SKIP_CONFIG:-0}" == 1 ]] \
     && [[ -n "${PR_CONFIG:-}" || -n "${PR_PRESET:-}" || -n "$preset_flag" ]]; then
    _pr_config_err "PR_SKIP_CONFIG=1 says no config applies, but PR_CONFIG, PR_PRESET or" \
                   "--preset says one does. Drop one of them."
    return 1
  fi

  if [[ -n "$preset_flag" && -n "${PR_PRESET:-}" && "$preset_flag" != "${PR_PRESET}" ]]; then
    _pr_config_err "--preset $preset_flag and PR_PRESET=$PR_PRESET name different presets." \
                   "The flag does not win here: PR_PRESET is exported once by the skill and" \
                   "the flag is typed per run, so silently overriding it is the drift this" \
                   "config exists to expose. Unset one."
    return 1
  fi
  preset="${preset_flag:-${PR_PRESET:-}}"

  if [[ "${PR_SKIP_CONFIG:-0}" != 1 ]]; then
    if [[ -n "${PR_CONFIG:-}" ]]; then
      path="$PR_CONFIG"
      if [[ ! -f "$path" ]]; then
        _pr_config_err "PR_CONFIG=$path does not exist."
        return 1
      fi
    elif [[ -f "$repo/.plan-review/config.json" ]]; then
      path="$repo/.plan-review/config.json"
    fi
  fi

  if [[ -n "$path" ]]; then
    path="$(readlink -f "$path")"
    dir="${path%/*}"
    if ! raw="$(jq -e 'if type == "object" then . else error("not an object") end' "$path" 2>&1)"; then
      _pr_config_err "$path is not a readable JSON object:" "  ${raw%%$'\n'*}" \
                     "A malformed config is refused, never silently replaced by defaults."
      return 1
    fi
    errors="$(_pr_config_json_errors "$path")"
    if [[ -n "$errors" ]]; then
      _pr_config_err "$path:" "$errors"
      return 1
    fi
    PR_CONFIG_PATH="$path"
  fi

  # Preset selection. `default_preset` applies only when neither the flag nor the
  # variable named one.
  if [[ -z "$preset" ]]; then
    preset="$(jq -r '.default_preset // ""' <<<"$raw")"
  fi
  if [[ -n "$preset" ]]; then
    if [[ "$(jq -r --arg p "$preset" '(.presets // {}) | has($p)' <<<"$raw" 2>/dev/null)" != true ]]; then
      local known
      known="$(jq -r '(.presets // {}) | keys_unsorted | join(", ")' <<<"$raw")"
      _pr_config_err "no preset named '$preset'${PR_CONFIG_PATH:+ in $PR_CONFIG_PATH}." \
                     "  presets defined: ${known:-(none)}"
      return 1
    fi
    PR_CONFIG_PRESET="$preset"
  fi

  # Reviewers: the preset replaces the list wholesale (D5). PR_ADAPTER_MAP
  # outranks both, and the caller applies that.
  PR_CONFIG_REVIEWERS="$(jq -r --arg p "$PR_CONFIG_PRESET" \
    '((if $p == "" then null else .presets[$p].reviewers end) // .reviewers // []) | join(" ")' \
    <<<"$raw")"

  # Pins, per field, first that exists wins (D6). The source is recorded per
  # field because a preset that sets only `effort` inherits `model` from the top
  # level, and one source string cannot say that (D9).
  local pins='{}'
  for cli in $PR_ROSTER_ADAPTERS; do
    for field in model effort; do
      env_name="PR_${cli^^}_${field^^}"
      value="${!env_name:-}"
      source=""
      if [[ -n "$value" ]]; then
        source="env"
      else
        if [[ -n "$PR_CONFIG_PRESET" ]]; then
          value="$(jq -r --arg p "$PR_CONFIG_PRESET" --arg c "$cli" --arg f "$field" \
                     '.presets[$p].pins[$c][$f] // ""' <<<"$raw")"
          [[ -n "$value" ]] && source="preset:$PR_CONFIG_PRESET"
        fi
        if [[ -z "$value" ]]; then
          value="$(jq -r --arg c "$cli" --arg f "$field" '.pins[$c][$f] // ""' <<<"$raw")"
          [[ -n "$value" ]] && source="config"
        fi
        # Exported, not just recorded: the adapters read these variables and
        # know nothing about a config file.
        [[ -n "$value" ]] && export "$env_name=$value"
      fi
      [[ -z "$source" ]] && continue
      pins="$(jq -c --arg c "$cli" --arg f "$field" --arg v "$value" --arg s "$source" \
                '.[$c] = ((.[$c] // {}) | .[$f] = $v | .[$f + "_source"] = $s)' <<<"$pins")"
    done
  done

  # Criteria, per slot, independently.
  local slot value_as_written initial_written="" rereview_written="" abs
  for slot in $PR_CONFIG_SLOTS; do
    value_as_written="$(jq -r --arg p "$PR_CONFIG_PRESET" --arg s "$slot" \
      '((if $p == "" then null else .presets[$p].criteria[$s] end) // .criteria[$s]) // ""' <<<"$raw")"
    [[ -z "$value_as_written" ]] && continue
    abs="$(_pr_config_criteria_path "$dir" "$slot" "$value_as_written")" || return 1
    # Same indirection as the doctor's reader: PR_CONFIG_CRITERIA_<SLOT^^> and a
    # <slot>_written local, so adding a slot means adding it to PR_CONFIG_SLOTS
    # and nowhere else in this loop.
    local -n _resolved="PR_CONFIG_CRITERIA_${slot^^}" _written="${slot}_written"
    _resolved="$abs"; _written="$value_as_written"
  done

  PR_CONFIG_RECORD="$(jq -nc \
    --arg path "$PR_CONFIG_PATH" --arg preset "$PR_CONFIG_PRESET" \
    --argjson pins "$pins" \
    --arg ci "$initial_written" --arg cr "$rereview_written" \
    '{path:     (if $path   == "" then null else $path   end),
      preset:   (if $preset == "" then null else $preset end),
      pins:     $pins,
      criteria: {initial:  (if $ci == "" then null else $ci end),
                 rereview: (if $cr == "" then null else $cr end)}}')"

  return 0
}

# pr_config_hash <reviewers> [criteria-file ...]
#
# Covers the resolved settings AND the bytes of the criteria files, in slot
# order: editing prompts/initial.md without touching config.json is the likeliest
# change of all, and a hash over the JSON alone would not see it. The files are
# the round's own snapshots, never the sources -- hashing one copy and prompting
# from another is how the hash, the snapshot and the delivered text end up
# describing three different things.
#
# Values only, no sources: the same model from the environment and from the
# config is the same setting. `jq -S` fixes key order so two runs of an unchanged
# config hash identically.
pr_config_hash() {
  local reviewers="$1" f settings
  shift
  settings="$(jq -S -c --arg rev "$reviewers" \
    '{reviewers: ($rev | split(" ") | map(select(. != ""))),
      pins:      (.pins | with_entries(.value |= with_entries(select(.key | endswith("_source") | not)))),
      criteria:  .criteria}' <<<"$PR_CONFIG_RECORD")"
  {
    printf '%s\n' "$settings"
    for f in "$@"; do
      [[ -n "$f" && -f "$f" ]] && sha256sum < "$f"
    done
  } | sha256sum | cut -d' ' -f1
}

# pr_config_record <sha256>
# The round.json `.config` object: the resolved settings, their provenance, and
# the hash the next round compares against.
pr_config_record() {
  jq -c --arg h "$1" '. + {sha256: $h}' <<<"$PR_CONFIG_RECORD"
}

