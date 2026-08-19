#!/usr/bin/env bash
# Cursor adapter. See docs/adapter-contract.md.
#
# --sandbox enabled gives write confinement AND network. Cursor's sandbox is
# default-deny with a host allowlist (github, the package registries, cloud
# storage), not network-off; an early probe against a host outside that
# allowlist was misread as the sandbox blocking all traffic. Verified against
# 2026.08.11-e8db854: github.com 200, api.github.com 200, write inside the
# workdir OK, write outside denied with no file created.
#
# Cursor exits 2 when a tool call is denied while still producing a correct
# review, so the adapter normalises that to 0 when output exists.

set -uo pipefail

workdir="$1"; session_in="$2"; review_out="$3"; meta_out="$4"

# Optional; see docs/adapter-contract.md. One line, used by the runner as the
# round's `detail` for this reviewer.
reason_out="${5:-}"

pr_reason() {
  [[ -n "$reason_out" ]] || return 0
  printf '%s\n' "$1" > "$reason_out"
}

# Cursor reports no effective model anywhere in --output-format text, so the
# requested pin is the only answer available. An *empty* pin is therefore not a
# weaker answer, it is no answer: round.json could not say which model reviewed
# the plan, which is exactly what R11 needs. Demand a concrete value instead of
# recording a blank.
#
# There is no separate effort setting here. Cursor encodes effort in the model id
# itself -- `claude-opus-5-low`, `claude-opus-5-medium`,
# `claude-opus-5-thinking-high`, `gpt-5.6-sol-xhigh`, plus `-fast` variants -- so
# the pin already names both. `agent --list-models` is the authority on which
# combinations exist; they are not uniform across models. (`--help` also documents
# a bracket form, `claude-opus-4-8[context=1m,effort=high]`, which is untested
# here; prefer the plain ids that --list-models prints.)
PR_AGENT_MODEL="${PR_AGENT_MODEL:-}"
if [[ -z "$PR_AGENT_MODEL" ]]; then
  echo "agent adapter: PR_AGENT_MODEL must name a model (agent --list-models)" >&2
  echo "The id includes the effort tier, e.g. claude-opus-5-thinking-high" >&2
  exit 1
fi

cd "$workdir" || exit 1

session="$session_in"
if [[ -z "$session" ]]; then
  session="$(agent create-chat 2>/dev/null | tail -1 | tr -d '[:space:]')"
  if [[ -z "$session" ]]; then
    echo "agent adapter: create-chat produced no id" >&2
    pr_reason "Cursor's create-chat produced no session id; nothing was run"
    exit 1
  fi
fi
args=(-p --trust --sandbox enabled --resume "$session" --output-format text
      --model "$PR_AGENT_MODEL")

agent "${args[@]}" > "$review_out" 2>>"${review_out}.log"
rc=$?

# Cursor can swap the model out from under the pin and say so only in prose in
# its own output -- measured: "Claude Opus 5 hit a safety filter, and the
# conversation was automatically switched to Claude Opus 4.8", while the run
# continued and produced a review. Recording the pin unconditionally would make
# round.json name a model that never answered, which is the exact failure Q2/R11
# exist to prevent. There is no structured field for this in --output-format
# text, so the notice is the only signal available.
model_effective="$PR_AGENT_MODEL"
switched_to="$(sed -n 's/^[[:space:]]*Switched to \(.*[^[:space:]]\)[[:space:]]*$/\1/p' \
                 "$review_out" 2>/dev/null | head -1)"
if [[ -n "$switched_to" ]]; then
  model_effective="$switched_to (requested: $PR_AGENT_MODEL)"
  echo "agent adapter: the CLI switched models mid-run to '$switched_to'." >&2
  echo "Recording that as the effective model; '$PR_AGENT_MODEL' did not answer." >&2
  # An `ok` round is worth explaining too: without this the swap is visible only
  # in round.json's model field, which a reader comparing verdicts across rounds
  # has no reason to look at.
  pr_reason "Cursor switched to '$switched_to' mid-run; '$PR_AGENT_MODEL' did not answer"
fi

# Line 3 is deliberately empty: effort is inside the model id on line 2, so there
# is no separate effective value to report. See docs/adapter-contract.md.
printf '%s\n%s\n%s\n%s\n' \
  "$session" \
  "$model_effective" \
  "" \
  "$(agent --version 2>/dev/null | head -1 | tr -d '[:space:]')" \
  > "$meta_out"

if [[ -s "$review_out" ]]; then
  exit 0
fi
echo "agent adapter: exit $rc with no output" >&2
pr_reason "Cursor exited $rc without writing a review"
exit 1
