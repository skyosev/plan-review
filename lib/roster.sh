#!/usr/bin/env bash
# Who is orchestrating, and therefore who is not reviewing BY DEFAULT.
#
# The default roster is the shipped adapters minus the orchestrator's own,
# because a default has to pick something and that is the better guess. It is a
# default and nothing more: a project config or PR_ADAPTER_MAP that names the
# orchestrator's own CLI is obeyed exactly, silently.
#
# There used to be a check here -- pr_roster_conflict -- that refused such a
# roster outright. It tested CLI-name equality, and the property that matters is
# model identity: it refused an opus orchestrator reviewing on sonnet (different
# weights, separate jailed process, blind session) and waved through Cursor
# pinned to claude-opus-5 beside an opus orchestrator (identical weights). No
# version of it works, either, because the runner never learns the
# orchestrator's own model. What replaced it is prose in README.md and
# SKILL.md, and `orchestrator` in round.json, which still records who drove
# every round.
#
# Sourcing has no side effects, and every function here uses builtins only --
# the same discipline as lib/doctor.sh, and for the same reason: bin/ sources
# this before it has established that anything else on PATH works.

# Every adapter this repo ships. The reviewer key and the adapter basename are
# the same string by construction, which is what lets a roster be derived from a
# name rather than looked up in a table.
PR_ROSTER_ADAPTERS="codex agent agy claude"

# `none` is not an adapter: it means no agent is orchestrating, which is the case
# when a human runs a round from a terminal. All four are then independent of the
# reader, so all four review.
PR_ROSTER_ORCHESTRATORS="codex agent agy claude none"

# pr_roster_orchestrator
#
# Echoes the validated PR_ORCHESTRATOR on stdout; explains on stderr and returns
# 1 otherwise. Unset is an error rather than a default because every available
# default is silently wrong for someone: defaulting to `claude` hands a
# codex-orchestrated round a roster containing codex, and the round then
# completes, looks correct, and is not independent. There is nothing downstream
# that could notice.
pr_roster_orchestrator() {
  local name="${PR_ORCHESTRATOR:-}"

  if [[ -z "$name" ]]; then
    echo "PR_ORCHESTRATOR is unset." >&2
    echo >&2
    echo "Set it to the CLI you are orchestrating from:" >&2
    echo "  ${PR_ROSTER_ADAPTERS// / | }" >&2
    echo "or \`none\` if no agent is orchestrating." >&2
    echo >&2
    echo "The roster is the other three; a round that reviews its own" >&2
    echo "orchestrator is not independent." >&2
    return 1
  fi

  if [[ " $PR_ROSTER_ORCHESTRATORS " != *" $name "* ]]; then
    echo "PR_ORCHESTRATOR='$name' is not one of: ${PR_ROSTER_ORCHESTRATORS// /, }" >&2
    echo "The name is the adapter's, not the vendor's: Cursor is \`agent\` and" >&2
    echo "Antigravity is \`agy\`, matching adapters/<name>.sh." >&2
    return 1
  fi

  printf '%s' "$name"
}

# pr_roster_map <reviewer names>
#
# Space-separated reviewer keys -> the space-separated reviewer=path pairs
# PR_ADAPTER_MAP takes. Needs PR_ROOT. This is how a config's `reviewers` list
# becomes a roster; the key and the adapter basename are the same string by
# construction, which is what makes the lookup a substitution rather than a
# table.
pr_roster_map() {
  local name sep="" out=""
  for name in $1; do
    out="${out}${sep}${name}=${PR_ROOT}/adapters/${name}.sh"
    sep=" "
  done
  printf '%s' "$out"
}

# pr_roster_keys <adapter-map>
#
# The reviewer names out of a `key=path` map -- the inverse of pr_roster_map, and
# the only other place that needs to know how a map is encoded. The runner and
# the doctor both decoded it by hand, which meant the encoding was defined here
# and read in two other files.
pr_roster_keys() {
  local pair sep="" out=""
  for pair in $1; do
    out="${out}${sep}${pair%%=*}"
    sep=" "
  done
  printf '%s' "$out"
}

# pr_roster_default_map <orchestrator>
#
# The roster when nothing names one: the shipped adapters minus the
# orchestrator's own.
pr_roster_default_map() {
  local orch="$1" name list=""
  for name in $PR_ROSTER_ADAPTERS; do
    [[ "$name" == "$orch" ]] && continue
    list="${list}${list:+ }${name}"
  done
  pr_roster_map "$list"
}

# pr_roster_resolve_map <orchestrator> <config-reviewers>
#
# The one place the roster's precedence lives, so the runner and the doctor
# cannot disagree about who is reviewing:
#
#   PR_ADAPTER_MAP  >  the config's reviewer list  >  the derived default
#
# A list that names the orchestrator's own CLI is obeyed exactly. Excluding it
# is what a DEFAULT does, not what a stated list means.
pr_roster_resolve_map() {
  if [[ -n "${PR_ADAPTER_MAP:-}" ]]; then
    printf '%s' "$PR_ADAPTER_MAP"
  elif [[ -n "$2" ]]; then
    pr_roster_map "$2"
  else
    pr_roster_default_map "$1"
  fi
}

