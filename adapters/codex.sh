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
#   - features.hooks=false                the repo under review can hand codex a
#                                         hook config; see the flag's comment
# The reviewer also runs under a private CODEX_HOME sited beside the repo copy,
# which is what keeps the operator's ~/.codex out of the round; see below.
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

# A private CODEX_HOME, SIBLING to the repo copy rather than inside it:
# pr_sandbox_refresh wipes <sandbox>/repo every round, and the session
# rollouts that make `codex exec resume` work round to round live in here --
# measured at <private>/sessions/<yyyy>/<mm>/<dd>/rollout-*.jsonl, and a second
# invocation with the same CODEX_HOME really did resume the first session rather
# than start cold wearing its id (probes/2026-08-27-codex-private-home, leg 2).
# Same siting as adapters/claude.sh's CLAUDE_CONFIG_DIR, restated here because
# adapters source nothing.
#
# This removes the operator's USER-LEVEL ~/.codex from the round -- that is the
# whole guarantee. Measured (P6 side-finding, 2026-08-26, and still reproducible
# unprompted on the probe host at codex-cli 0.150.1): one obsolete top-level
# field in the operator's config.toml failed --strict-config and the reviewer
# never started, no banner, no review. It is NOT a sandbox change -- the -c
# overrides below already outrank any config file and still do.
#
# codex also reads managed/MDM, enterprise-requirements, session-flag, plugin
# and PROJECT configuration layers; CODEX_HOME does not touch those, they stay
# in scope, and a managed layer that conflicts is accepted, not detected --
# there is nothing here to detect it with. None were present on the probe host,
# so nothing was observed leaking through: that is an absence of evidence, not
# evidence of absence. The project layer is the one confirmed live, and the
# `features.hooks=false` below is what shuts its executable half.
#
# This adapter seeds NO config.toml into the private home. codex writes one
# itself on first run, recording the workdir's trust_level -- which is why the
# diagnostics further down name that file and no longer name ~/.codex.
#
# auth.json is COPIED, not bound or symlinked: the reviewer needs a writable
# copy and must never write the operator's real one. Measured: a private home
# holding nothing but a copy of auth.json authenticates, so a writable directory
# is sufficient on a host using the file credential store (the keyring mode
# `cli_auth_credentials_store` selects is untested). The copy was NOT rewritten
# during either probe run -- the token was inside its refresh window -- so
# copy-once is cheap insurance rather than a demonstrated need: codex maintains
# a `last_refresh` field, and if a refresh ever does land in the private copy,
# copy-once is what keeps round N+1 from clobbering it.
codex_home="$(dirname "$workdir")/codex-home"
if ! mkdir -p "$codex_home" 2>/dev/null; then
  echo "codex adapter: cannot create the private CODEX_HOME at $codex_home" >&2
  exit 1
fi
# ${HOME:-} rather than $HOME: there is no set -e here but there IS set -u, and
# PR_CACHE_ROOT lets the runner work in an environment with no HOME at all. Bare
# $HOME would take the reviewer out with a bash-internal "unbound variable" on a
# path that otherwise runs fine -- no auth to copy is a state this handles.
if [[ -f "${HOME:-}/.codex/auth.json" && ! -f "$codex_home/auth.json" ]]; then
  if ! cp "${HOME:-}/.codex/auth.json" "$codex_home/auth.json" 2>/dev/null; then
    echo "codex adapter: cannot copy auth.json into $codex_home" >&2
    exit 1
  fi
fi
export CODEX_HOME="$codex_home"

config_args=(
  --strict-config
  -c sandbox_mode=workspace-write
  -c sandbox_workspace_write.exclude_slash_tmp=true
  -c sandbox_workspace_write.exclude_tmpdir_env_var=true
  -c sandbox_workspace_write.network_access=true
  -c approval_policy=never
  # Hooks are a stable feature, ON by default (measured: codex-cli 0.150.1,
  # `codex features list` -> `hooks stable true`), and the discovery layers
  # include the REPOSITORY under review: <repo>/.codex/hooks.json is read.
  # Measured both ways with a malformed file (probes/2026-08-27-codex-private-home,
  # leg 4c): without this flag codex warns `failed to parse hooks config
  # <repo>/.codex/hooks.json`, with it the file is not read at all, and
  # `codex doctor --json` drops `hooks` from its enabled feature flags.
  # features.hooks is a recognised key, so --strict-config does not object.
  #
  # What was NOT measured, stated so no one later mistakes this for more than it
  # is: a valid repo hook did not EXECUTE either way. Two live control runs with
  # no flag -- one registering SessionStart, one registering five events against
  # a prompt that really did make a tool call -- fired nothing. Execution is
  # gated, on the binary's own evidence rather than on a measurement of the
  # gate, by a per-source `hooks.state."<source>".trusted_hash` record (the key
  # is real -- --strict-config types it as a string) that appears to be written
  # only by codex's interactive TUI review (`tui/src/startup_hooks_review.rs`),
  # which a non-interactive `codex exec` cannot reach. Trusting a hook and
  # re-running was NOT attempted, so the once-trusted path is unproven in both
  # directions. So this flag closes a read the
  # reviewer demonstrably performs, ahead of an execution path currently held
  # shut by a gate that is codex's to change, not ours to rely on.
  -c features.hooks=false
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
  # reason for that is a config field this codex version rejects: codex runs
  # --strict-config here, so one bad field takes the reviewer out with a config
  # error and no banner. That USED to mean the operator's ~/.codex/config.toml;
  # with the private CODEX_HOME above it no longer can, and a message still
  # naming a file the reviewer does not read would be worse than none. What the
  # reviewer does read is the config.toml codex writes into the private home
  # itself, so that is what is named. The second cause is new and is a one-round
  # transition: a session handle stored before the private home existed names a
  # rollout in the operator's ~/.codex/sessions, and resuming it here fails with
  # `no rollout found for thread id <id>` (measured 2026-08-27, codex 0.150.1,
  # rc=1, no banner -- which is why it arrives at this branch rather than a
  # nicer one). R1 drops that handle, so the next round starts clean by itself.
  #
  # Said twice on purpose -- once here for whoever reads the log, once in the
  # reason below, which is what the round's summary shows; adapters source
  # nothing, so there is no shared constant to hold it. The two are NOT the same
  # text: lib/reviewer-runner.sh truncates the reason at 200 characters, so the
  # absolute path stays here, in the log, where nothing clips it, and the reason
  # says which file to look for instead of spelling out where it is.
  echo "codex adapter: if codex printed a config error above, the likeliest cause is a" >&2
  echo "  field this codex version rejects in $codex_home/config.toml (--strict-config)." >&2
  echo "  Deleting that file is safe: codex rewrites it, and the operator's ~/.codex is" >&2
  echo "  not read by this reviewer." >&2
  echo "  If it instead says 'no rollout found for thread id', the stored session predates" >&2
  echo "  this private home; the handle is dropped and the next round starts clean." >&2
  pr_reason "codex ran under an unexpected sandbox; the review was discarded (if codex refused to start, see the log: likeliest a bad field in the private CODEX_HOME's config.toml, or a stale session handle)"
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
