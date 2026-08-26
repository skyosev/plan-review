#!/usr/bin/env bash
# Codex adapter. See docs/adapter-contract.md.
#
# Flags are the empirically verified set from the brainstorm doc:
#   - sandbox_mode=workspace-write        blocks writes outside the workdir
#   - exclude_slash_tmp / exclude_tmpdir  removes /tmp from the writable roots,
#                                         so reviewers cannot reach each other
#   - network_access=true                 D14
#   - --strict-config                     a misspelled key fails loudly
#   - model_reasoning_effort              codex's own effort axis, set only when
#                                         PR_CODEX_EFFORT is present
# The sandbox must be reasserted on resume: `codex exec resume` does not inherit
# the original session's sandbox and falls back to the trust level in config.toml.

set -uo pipefail

workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

# Optional; see docs/adapter-contract.md. One line, used by the runner as the
# round's `detail` for this reviewer.
reason_out="${5:-}"

pr_reason() {
  [[ -n "$reason_out" ]] || return 0
  printf '%s\n' "$1" > "$reason_out"
}

PR_EXPECTED_SANDBOX="${PR_EXPECTED_SANDBOX:-workspace-write [workdir]}"
PR_CODEX_MODEL="${PR_CODEX_MODEL:-}"

# Codex is the only reviewer with reasoning effort as a knob separate from the
# model. Verified against 0.147.0: the key is `model_reasoning_effort` and the
# banner echoes it as `reasoning effort: <value>`. `reasoning_effort` (no `model_`
# prefix) is rejected by --strict-config.
#
# Validation is split, and neither half is the CLI's own config parser:
#   - `--strict-config` checks the key NAME only. A misspelled key fails here.
#   - the backend checks the VALUE, at request time, with a 400:
#       [reasoning.effort] [invalid_enum_value] Invalid value: 'hgih'. Supported
#       values are: 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'.
#     Verified. The banner still echoes the typo, so the banner is not a validator.
#     The run produces no review, so the adapter's -s check below catches it.
#
# The effort assertion further down therefore does NOT catch typos — those are
# already fatal. It catches a *silent divergence*: the banner reporting an effort
# other than the one requested, which is what a backend-side downgrade for a model
# that does not support the tier would look like. That would otherwise be recorded
# in round.json as the requested value and quietly skew round-to-round comparison.
PR_CODEX_EFFORT="${PR_CODEX_EFFORT:-}"

config_args=(
  --strict-config
  -c sandbox_mode=workspace-write
  -c sandbox_workspace_write.exclude_slash_tmp=true
  -c sandbox_workspace_write.exclude_tmpdir_env_var=true
  -c sandbox_workspace_write.network_access=true
  -c approval_policy=never
)
[[ -n "$PR_CODEX_MODEL" ]] && config_args+=(--model "$PR_CODEX_MODEL")
[[ -n "$PR_CODEX_EFFORT" ]] \
  && config_args+=(-c "model_reasoning_effort=$PR_CODEX_EFFORT")

# Flag placement is exact and was determined by trial, not by reading the help:
#   `codex exec resume --color never …`  -> error: unexpected argument '--color'
#   `codex --color never exec …`         -> error: unexpected argument '--color'
#   `codex exec --color never resume …`  -> accepted
# --color belongs to `exec`, and must sit between `exec` and `resume`.
# --skip-git-repo-check is needed on BOTH branches: resume re-checks directory
# trust and aborts with "Not inside a trusted directory" without it.
# The review is collected with -o rather than parsed out of --json, because
# --json suppresses the banner that the Q8 assertion below depends on.
if [[ -n "$session_in" ]]; then
  args=(exec --color never --skip-git-repo-check resume "$session_in"
        "${config_args[@]}" --output-last-message "$review_out" -)
else
  args=(exec --color never --skip-git-repo-check
        "${config_args[@]}" --output-last-message "$review_out" -)
fi

err="$(mktemp)"
trap 'rm -f "$err"' EXIT

# stdout is the human-readable transcript and goes to the runner's log. stderr
# carries the banner. They must NOT be merged: nothing downstream can separate
# them again, and any parse of the combined stream trips over the banner.
cd "$workdir" || exit 1
codex "${args[@]}" 2> "$err"
rc=$?

cat "$err" >&2

# Q8: refuse to trust output produced under an unexpected sandbox. Fails closed
# when the banner is absent entirely.
if ! grep -qF "sandbox: $PR_EXPECTED_SANDBOX" "$err"; then
  echo "codex adapter: expected 'sandbox: $PR_EXPECTED_SANDBOX' in the banner." >&2
  echo "Got:" >&2
  grep -i '^sandbox:' "$err" >&2 || echo "(no sandbox line at all)" >&2
  # The banner is also absent when codex never started, and the commonest
  # reason for that is the operator's own config: codex runs --strict-config
  # here, so one field this codex version rejects takes the reviewer out with a
  # config error and no banner. The symptom ("unexpected sandbox") names no
  # file, so the likeliest cause is spelled out beside it. Said twice on
  # purpose -- once here for whoever reads the log, once in the reason below,
  # which is what the round's summary shows; adapters source nothing, so there
  # is no shared constant to hold it.
  echo "codex adapter: if codex printed a config error above, the likeliest cause is a" >&2
  echo "  ~/.codex/config.toml field this codex version rejects (--strict-config)." >&2
  pr_reason "codex ran under an unexpected sandbox; the review was discarded (if codex refused to start, check ~/.codex/config.toml for a field it rejects)"
  rm -f "$review_out"
  exit 1
fi

# Banner fields: "session id: <uuid>", "model: <name>", "reasoning effort: high",
# and the "OpenAI Codex v0.147.0" line the version comes from. One pass fills all
# four -- a sed|head per field was two processes and a full read of the banner
# each. First match wins, as `head -1` did, so a field that appears empty stays
# empty rather than being filled by a later line. Absent fields stay unset and
# become empty below, so the meta file always has exactly four lines.
unset session_effective model_effective effort_effective version_effective
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    'session id:'*)
      [[ -v session_effective ]] || { v="${line#session id:}"
                                      session_effective="${v#"${v%%[![:space:]]*}"}"; } ;;
    'model:'*)
      [[ -v model_effective ]]   || { v="${line#model:}"
                                      model_effective="${v#"${v%%[![:space:]]*}"}"; } ;;
    'reasoning effort:'*)
      [[ -v effort_effective ]]  || { v="${line#reasoning effort:}"
                                      effort_effective="${v#"${v%%[![:space:]]*}"}"; } ;;
    'OpenAI Codex v'*)
      [[ -v version_effective ]] || version_effective="${line#OpenAI Codex v}" ;;
  esac
done < "$err"
: "${session_effective=}" "${model_effective=}" "${effort_effective=}" "${version_effective=}"

# Asserted, not merely recorded, so a silent downgrade cannot pass as the pin.
# Only when a pin was requested: with none, codex uses its configured default and
# there is nothing to compare against.
if [[ -n "$PR_CODEX_EFFORT" && "$effort_effective" != "$PR_CODEX_EFFORT" ]]; then
  echo "codex adapter: asked for reasoning effort '$PR_CODEX_EFFORT'," >&2
  echo "banner reports '${effort_effective:-(no reasoning effort line)}'." >&2
  echo "The effort was changed underneath us; do not trust it as the pin." >&2
  pr_reason "codex reported effort '${effort_effective:-none}', not the requested '$PR_CODEX_EFFORT'"
  rm -f "$review_out"
  exit 1
fi
# The version comes from the banner's "OpenAI Codex v0.147.0" line, not from a
# second `codex --version` call: one invocation per review keeps the adapter
# cheap and keeps the reported version the one that actually ran.
printf '%s\n%s\n%s\n%s\n' \
  "$session_effective" \
  "$model_effective" \
  "$effort_effective" \
  "$version_effective" \
  > "$meta_out"

if [[ ! -s "$review_out" ]]; then
  echo "codex adapter: -o produced no review" >&2
  pr_reason "codex exited $rc without writing a last message"
  exit 1
fi
exit "$rc"
