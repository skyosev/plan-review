# plan-review

Sends a Markdown plan to several agent CLIs for independent critique, then feeds each
reviewer's own rationale back on the next round. Built to replace copy-pasting a plan
between three terminals.

## Requirements

`bash` 5+, `git`, `jq`, `rsync`, GNU coreutils (`sha256sum`, `timeout`, `readlink -f`), `flock`,
and the reviewer CLIs on `PATH`. `bwrap` (bubblewrap) as well, if `agy` or `claude` is in the
roster — see the `bwrap` note below and "Reviewer roster".

5 is what `make doctor` enforces and it is a support statement rather than a measured
requirement: nothing here uses a construct newer than `bash` 4 (`${x^^}`, `mapfile`,
`printf %()T`), so 4.4 would very likely run — it is simply never tested. Its practical job
is catching macOS's `/bin/bash` 3.2. The one exception is `scripts/install.sh`, which runs
under 3.2 on purpose, because it is the file that has to deliver that message.

**`claude` is the one that is usually installed and still not found.** Measured here on
2026-08-26: the native installer had put the binary at `~/.local/bin/claude`, a symlink into
`~/.local/share/claude/versions/<version>`. If `plan-review doctor` says `claude not on PATH`
while `claude` works in your terminal, that directory is on your *interactive* `PATH` — a shell
rc file — and a non-interactive shell never reads it; put `~/.local/bin` somewhere every shell
sees. The other location to know about is `~/.claude/local/claude`, which an npm install
migrated with `claude migrate-installer` leaves behind together with a shell **alias** — an
alias being invisible to everything here, that one needs a symlink from a directory on `PATH`.
That path was checked on this machine on the same date and **does not exist here**, so the
migrate-installer behaviour is reported from its documentation and not observed; only the
native location above was seen. Neither installer's future layout is promised here — if
`claude` is somewhere else again, `command -v claude` in a non-interactive shell is the
question the doctor is actually asking.

**macOS** ships `/bin/bash` 3.2 and none of the GNU utilities. Install the reviewer CLIs however
their vendors say to, and `git` with the Xcode command line tools; the rest is one brew command,
plus the `PATH` line that makes it count:

    brew install bash coreutils flock jq rsync
    PATH="$(brew --prefix)/opt/coreutils/libexec/gnubin:$PATH"

`bash`, `coreutils` and `flock` are the measured ones — 3.2 is refused, `sha256sum` and `timeout`
do not exist, and there is no system `flock` at all. `readlink -f` is the exception this list was
originally built around: on Darwin 25 the stock `/usr/bin/readlink` accepts `-f` (measured
2026-08-20), so on a current macOS the bootstrap's `readlink` refusal never fires and bash 3.2 is
the one that does. `jq` and `rsync` are here because they are the supported baseline, not because
the system versions are known to break: `lib/sandbox.sh` asks `rsync` for `-a --delete --exclude`
and nothing more, and nobody has measured what macOS's own copy does with them. If yours works,
keeping it is fine.

The second line is not optional: coreutils installs as `gtimeout`, `gsha256sum` and so on, and the
runner calls the unprefixed names. `flock` is its own formula — `util-linux` is keg-only, and
installing it does not put `flock` on `PATH`.

`bwrap` is not optional if `agy` or `claude` is in the roster: it is those reviewers' only write
barrier, and both adapters refuse to run without it. A project config naming neither — `"reviewers":
["codex"]` — needs no `bwrap` at all, and the doctor skips the check rather than failing the machine
for it.

`bwrap` is Linux-only, and no macOS equivalent is wired up yet, so on macOS the roster is
`codex` and `agent` — both of which confine themselves. All four CLIs still work there as
orchestrators and as skill targets; only reviewing is affected.

**What has actually been run on macOS** is one manual pass, on 2026-08-20, on Darwin 25 with the
packages above: `plan-review doctor`, and one real round in which `codex` and `agent` each
produced a review — read reviewer by reviewer out of `round.json`, because a round succeeds when
one reviewer does. After that pass's fixes landed, the full `make test` was re-run on
the same Mac and passed. Getting there took four macOS-only corrections, all on this branch: the
trailing slash macOS puts on `$TMPDIR`, BSD `wc`'s space-padded counts, BSD `ln`'s missing `-r`,
and BSD `readlink -f` erroring on a path whose last component does not exist where GNU
canonicalises it — `lib/paths.sh` now emulates the GNU reading, so a missing plan or criteria
file is reported as missing rather than as escaping its directory. Nothing about macOS is checked
automatically, so treat it as verified once rather than supported continuously.

## Reviewer roster

Four adapters ship: `codex`, `agent` (Cursor), `agy` (Antigravity) and `claude` (Claude Code). Who
reviews is decided in this order:

    PR_ADAPTER_MAP  >  the project config's `reviewers` list  >  every adapter but the orchestrator's

The last of those is a **default**, and the orchestrator comes from one required variable:

    PR_ORCHESTRATOR=<codex|agent|agy|claude|none>

There is no default for it. Every candidate is silently wrong for someone: assuming Claude Code
hands a codex-orchestrated round a roster containing codex, and that round then completes, looks
correct, and is not independent. `plan-review round`, `doctor` and `init` all refuse to run without it.
`round.json` records it — what the caller declared, not a measurement of who actually ran it. `none`
says no agent is orchestrating, and puts all four adapters in the default roster.

**A stated roster is obeyed exactly, including one that names the orchestrator's own CLI.** There
used to be a check that refused that outright. It compared CLI *names*, and independence is lost on
*model identity* — so it refused Claude Code orchestrating on opus with `PR_CLAUDE_MODEL=claude-sonnet-5`
reviewing (different weights, a separate jailed process, a session that has never seen your
conversation) and said nothing about Cursor pinned to `claude-opus-5` beside an opus orchestrator,
which is the actual collision. Nothing here can tell the two apart: the orchestrator has no pin and
this project reads no CLI's own configuration, so the model driving a round is unknowable from
inside it. The advice below replaces the check.

Three things the runner cannot check for you:

- **The orchestrator's own model.** If you are orchestrating on the same model a reviewer runs, you
  paid twice for one perspective and nothing will tell you. Pin the reviewer to something else.
- **Model families, not CLI names.** Cursor pinned to a `claude-opus-*` id in a roster that also
  contains `claude` is two prices for one perspective; pin Cursor to a `gpt-5.6-sol-*` id there.
  After the round, two reviewers whose *recorded* models are the exact same string do produce a
  warning — string equality is the only version of this the artifact can prove.
- **Cost, when `claude` reviews.** Claude Code hands a reviewer its full tool surface, which
  includes `Task` and `Workflow` (subagents, so unbounded spend), the `Cron*` tools and
  `ScheduleWakeup` (work that would outlive the round), and `SendMessage` / `RemoteTrigger`. The
  bubblewrap jail confines writes and the environment scrub closes the messaging channel, but
  neither bounds cost. `PR_TIMEOUT_SECS` (default 900) is what actually caps a runaway reviewer.

Check all of it with:

    PR_ORCHESTRATOR=claude make doctor                          # this machine
    PR_ORCHESTRATOR=claude make doctor REPO=/path/to/repo PLAN=docs/plans/thing.md
    PR_ORCHESTRATOR=claude make doctor REPO=/path/to/repo PRESET=quick
    PR_ORCHESTRATOR=claude make doctor OFFLINE=1                # skip the auth checks
    PR_ORCHESTRATOR=claude make doctor SMOKE=1                  # + one live prompt per reviewer

    plan-review doctor --repo /path/to/repo --show-config   # what a round would do, as JSON

It reports missing dependencies, whether the roster's CLIs are authenticated, whether your pins
name models that exist, whether the reviewer CLIs have drifted from the versions the adapters were
verified against, and — with `REPO` — whether the project config parses, whether `.plan-review/` is
gitignored and whether an unfinished round is blocking the next one. Every check is driven by the
adapter map the round would actually use, keyed on adapter *paths*: a CLI that is not reviewing is
reported as `SKIP` and its pin is not checked, and an adapter this repo does not ship carries no
requirements at all. Exit status is 1 only for things that would stop a round; drift and unset pins
are reported without failing. Nothing it runs costs tokens — unless you pass `--smoke`, which is
why that one is opt-in.

`--smoke` sends every reviewer in the roster one trivial prompt, through its adapter exactly as a
round would send one — same sandbox layout, same stdin contract, same process-group and
descendant sweep — under a short deadline (`PR_SMOKE_TIMEOUT_SECS`, default 90s) instead of the round's. It
exists because the auth checks hit status endpoints, and the exec path is different code in a
vendor's CLI: it can hang on an interactive login prompt the auth check never reaches, or die on
flag drift the version check only warns about. Alive means the adapter produced a review file, the
same rule the round judges by; a dead reviewer FAILs with the adapter's own reason and its work
directory kept for diagnosis (`PR_KEEP_SANDBOX=1` keeps the passing ones too). It contradicts
`--offline` by definition, so the two together are refused.

`--show-config` is the narrow companion to all that: it resolves and validates exactly as a round
would, prints the roster, the pins, the criteria and **where each value came from**, and then exits
without checking auth, versions, the jail or round state, and without writing anything.

The bubblewrap check runs the jail with `adapters/agy.sh`'s exact flags rather than
`unshare --user --map-root-user true`. The two are not equivalent: Ubuntu 24.04 defaults
`kernel.apparmor_restrict_unprivileged_userns=1`, which leaves `unshare` working while denying
`bwrap`, so the shorter check passes on a machine where `agy` cannot run at all.

It also **measures containment** rather than flag acceptance. The jail runs a payload that
detaches a writer; the writer stamps a `spawned` marker, the payload exits once it sees it,
and the writer would stamp a `survived` marker a fraction of a second later. A pass is
`spawned` present and `survived` absent — the jail ran the payload *and* disposed of the
detached process. Both signals are needed: "no marker" on its own cannot tell containment
from a payload that never ran.

The offline half of these checks also runs automatically before every round, for the reviewers in
that round's roster, so a missing `bwrap` or an unset pin costs a second rather than a forfeited
reviewer session. `PR_SKIP_PREFLIGHT=1` turns it off.

## Install

    curl -fsSL https://raw.githubusercontent.com/skyosev/plan-review/main/scripts/install.sh | bash

That clones to `~/.local/share/plan-review`, links `~/.local/bin/plan-review`, installs the skill
into every harness it finds, and finishes with an offline doctor listing what is still missing —
which on a fresh machine is most of it. `--ref <branch|tag>`, `--bin-dir <dir>` and `--no-skill`
are the options; pass them as `| bash -s -- --no-skill`. `PR_INSTALL_DIR` moves the checkout.

The skill step runs `npx -y skills`, the [skills](https://skills.sh) CLI — a third-party package
fetched from npm at run time and executed as you, unsandboxed, at whatever version is current that
day. `--no-skill` skips it and keeps npm out of the install entirely.

**Exit 0 means the runner is linked.** It does not mean a round can run — that needs the
Requirements above, which the doctor names and your package manager installs — and it does not
mean the skill is available either, because the skill step warns rather than failing.

Two things are checked before anything is cloned: that `readlink -f` works and that `bash` is 5 or
newer. Without them nothing here can start, including the doctor, so there would be no report to
give you. It says which brew command fixes it.

A pipe reports **bash's** exit status, so a `curl` that dies before emitting anything looks like
success. The script guards against running a truncated download — everything happens in `main "$@"`
on the last line — but it cannot report the download failure. If you want that:

    bash -o pipefail -c 'curl -fsSL https://raw.githubusercontent.com/skyosev/plan-review/main/scripts/install.sh | bash'

Re-running is the upgrade: it fast-forwards the checkout and re-installs the skill. It refuses a
dirty tree, a diverged one, a foreign `origin` and a directory it did not create, and it never
removes anything it did not make. To remove what it did make:

    rm ~/.local/bin/plan-review
    rm -rf ~/.local/share/plan-review

The skill is separate, because removing it is **global and by name** — it takes out whatever
`plan-review` skill is registered, whether this installer put it there or you did. Run it only if
you let the installer install one, which the installer's own last line tells you:

    npx skills remove -g plan-review

**By hand instead**, if you want the checkout in your own source tree:

    git clone <this repo> ~/code/plan-review
    ~/code/plan-review/bin/plan-review install      # links ~/.local/bin/plan-review
    npx skills add ~/code/plan-review -g -a claude-code -a codex

`install` makes one symlink and then runs `plan-review version` through that link to prove it works.
`--bin-dir <dir>` puts it elsewhere. It refuses any destination that is already occupied rather than
overwriting it, so uninstalling is `rm ~/.local/bin/plan-review` and upgrading is `git pull`.

Nothing is copied, which is the trade: the link points into the checkout, so move or delete the
checkout and the command breaks. Repair is `rm` on the stale link, then `install` from the new
location. Installing is a convenience in any case — `~/code/plan-review/bin/plan-review doctor`
works without it.

Name whichever harnesses you use in `skills add`. What it installs is a snapshot taken at that
moment, and nothing here reports an installed skill's revision, so run `npx skills update` when you
update the checkout.

On macOS, `agy` and `claude` cannot review yet (see Requirements), and `plan-review init` treats a
reviewer that cannot review as a refusal rather than a silent omission. So name the roster — and
pin Cursor, which refuses to run without a model because it reports none, so `round.json` could
not otherwise say what reviewed the plan (`agent --list-models`, or export `PR_AGENT_MODEL`):

    PR_ORCHESTRATOR=claude plan-review init --repo <dir> \
        --reviewers codex,agent --pin agent=<model-id>

## Use

From inside a session in your target repo, invoke the `plan-review` skill. It runs the rounds and
does the integration. The skill finds the runner through `PR_HOME` first and `PATH` second, so
`PR_HOME=/some/other/checkout` is how you point a session at a development copy; with neither, it
stops and says so rather than guessing.

To run one round by hand:

    PR_ORCHESTRATOR=none \
    PR_CODEX_MODEL=gpt-5.6-sol PR_CODEX_EFFORT=xhigh \
    PR_AGENT_MODEL=claude-opus-5-thinking-high \
    PR_AGY_MODEL=gemini-3.1-pro-high \
      plan-review round --repo /path/to/repo --plan docs/plans/thing.md [--fresh]

`plan-review complete --round <dir>` closes a round once its rationale files are written;
`plan-review abort --round <dir>` finalises one that will never be finished. See "When a
round does not finish".

## Per-project configuration

Optional. `<repo>/.plan-review/config.json` says who reviews that repo's plans, at which pins,
against which house criteria — so the settings stop living in shell history. It is **gitignored and
per developer**, alongside the artifacts. Nothing makes you write it by hand: "Generating a config"
below does it from what is installed on the machine.

```json
{
  "default_preset": "thorough",
  "reviewers": ["codex", "agy"],
  "pins": {
    "codex": { "model": "gpt-5.6-sol", "effort": "xhigh" },
    "agy":   { "model": "gemini-3.1-pro-high" }
  },
  "criteria": { "initial": "prompts/initial.md", "rereview": "prompts/rereview.md" },
  "presets": {
    "quick":    { "reviewers": ["codex"], "pins": { "codex": { "effort": "low" } } },
    "thorough": { "reviewers": ["codex", "agy"] }
  }
}
```

Every key is optional, and no config at all means today's roster, pins and prompt.

- **Reviewers.** At least one, from `codex`, `agent`, `agy`, `claude`.
- **Pins.** Per CLI, exactly the `PR_*_MODEL` / `PR_*_EFFORT` values the adapters already read. An
  `effort` under `agy` or `agent` is refused: for those two the tier lives inside the model id.
- **Criteria.** Paths to Markdown files, resolved against **the config's own directory** and
  required to stay inside it. Their contents are **appended** to the reviewer's brief, never
  substituted for it — the operational instructions and the verdict sentinels are emitted whatever a
  config says. `initial` goes to baseline rounds, `rereview` to history rounds; a `--fresh` round 5
  is a baseline round.
- **Presets.** Named bundles selected per run with `--preset <name>` or `PR_PRESET`. They merge per
  top-level key: `reviewers` is replaced wholesale, `pins` merge per CLI, `criteria` per slot. So
  `{"quick": {"pins": {"codex": {"effort": "low"}}}}` keeps the model from the top level.

Precedence, highest first: `PR_ADAPTER_MAP`, then environment pins, then the selected preset, then
the top level, then whatever the adapter does on its own. `PR_CONFIG=<path>` points at a config
elsewhere; `PR_SKIP_CONFIG=1` ignores one entirely.

**The schema is strict and the runner exits 2 on any violation, before it writes anything.**
`"reviewrs"` silently ignored is a silently wrong roster, and a round that ran the wrong reviewers
looks exactly like one that ran the right ones. Unknown keys, unknown reviewer names, an effort
outside its CLI's enum, a criteria file that is missing, empty or outside the config's directory,
and a `--preset` that disagrees with `PR_PRESET` are all refusals with the offending key named.

Each round records what it resolved, in `round.json`:

```json
"config": {
  "path": "/repo/.plan-review/config.json", "preset": "quick", "sha256": "7f0c…",
  "pins": { "codex": { "model": "gpt-5.6-sol", "model_source": "config",
                       "effort": "low",        "effort_source": "preset:quick" } },
  "criteria": { "initial": "prompts/initial.md", "rereview": null }
}
```

Each field carries its own source (`env`, `preset:<name>`, `config`), because a preset that sets
only the effort inherits the model from the top level. The hash covers the resolved settings **and
the bytes of the criteria files**; when it changes between history rounds the next round warns and
suggests `--fresh`, because resumed sessions carry context built under the old settings. The
criteria themselves are copied into each round directory as `criteria-<slot>.snapshot.md`, and those
copies — not the source files — are what the reviewers are sent.

One cost, stated plainly: the config and its criteria files live under `.plan-review/`, so
`git clean -xdf` deletes them along with the round history, and a fresh clone has none.

## Generating a config

`plan-review init` writes the file above out of what is installed on this machine, and then
runs the doctor over the result:

    PR_ORCHESTRATOR=claude plan-review init --repo /path/to/repo \
      --pin agent=claude-opus-5-thinking-high \
      --pin agy=gemini-3.1-pro-high

The roster is every supported CLI on `PATH` except the one you are orchestrating from. Each is
probed before anything is written — authenticated, jailed where it needs to be, pinned where a pin
is required — and **a reviewer that cannot review is a refusal, not a silent omission**;
`--reviewers` is how you leave one out on purpose. That is stricter than a round, which survives a
failed reviewer and completes on the others. A config is written once and read for months, so a
reviewer that cannot answer today would forfeit a seat on every future round.

Model ids are never guessed. `agent` and `agy` require one, and init takes it from `PR_AGENT_MODEL` /
`PR_AGY_MODEL` or from `--pin`; given neither, it prints that CLI's ids and the flag to re-run with.
An id is unbounded and prices every round by default, which is not a thing to pick for you.

Two presets are generated, and only the ones that would differ from the top level or from each
other — a roster with no effort axis and one reviewer gets none at all:

- `quick` — the first reviewer in `codex agent agy claude` order, plus `"effort": "low"` if that CLI
  has an effort axis. Fewer opinions and, where it applies, less thinking.
- `deep` — the whole roster, plus `"effort": "xhigh"` for whichever of `codex` and `claude` are in
  it. agy and Cursor carry the tier inside the model id, so **`deep` deepens those two and nothing
  else**, and init prints which reviewers it could not deepen.

`.plan-review/` is then added to the repo's `.gitignore`, unless `git check-ignore` says some rule
already covers it — the same call the doctor makes, so the two cannot disagree. It is a tracked file
in someone else's repository, so the line is printed rather than added quietly.

The rest of the flags: `--reviewers a,b` states the roster instead of deriving it, and may name your
own CLI (init warns once and obeys — a CLI name does not establish model identity, and pinning that
reviewer to different weights is a real roster). `--force` rewrites an existing config whole; there
is no merge. `--offline` skips every auth and model-list call, here and in the doctor afterwards,
and writes the pins unvalidated. `--no-verify` skips the doctor, so exit 0 then means "written,
readiness unmeasured".

Exit 2 means it refused and wrote nothing: every refusal happens before the directory is created,
and the config is built and validated in memory before `.plan-review/` exists at all. Exit 1 means
the config was written and the doctor is not green.

`PR_ORCHESTRATOR` is the one variable init cannot take off your hands. It says who is driving *this*
run rather than anything about the repository — the same repo is reviewed from Claude Code on Monday
and from codex on Friday — so it stays per-run and the schema has no key for it. Carry it on the
commands you run next.

Through make:

    PR_ORCHESTRATOR=claude make init REPO=/path/to/repo PINS="agent=<id> agy=<id>"

## Choosing models and effort

One pin per reviewer, passed through verbatim. A pin may come from the environment or from the
project config; the environment wins, and `round.json` records which it was. Only the roster's pins
matter. There is no portable effort setting, because the four CLIs do not agree on what effort is:

- **codex** — effort is its own axis, sent as `-c model_reasoning_effort=`. Accepted
  values are `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; an invalid one
  fails the request with a 400 rather than falling back. `PR_CODEX_MODEL` is optional;
  codex reports the effective model and effort in its banner either way, and the adapter
  aborts if the reported effort differs from what you asked for.
- **Cursor** — effort is part of the model id: `claude-opus-5-low`,
  `claude-opus-5-medium`, `gpt-5.6-sol-xhigh`, plus `-fast` variants.
  `agent --list-models` lists what exists; the tiers are not uniform across models.
  `PR_AGENT_MODEL` is **required** — Cursor never reports which model answered, so
  without a pin `round.json` could not record what reviewed the plan.
- **agy** — also part of the id: `agy models` lists `gemini-3.1-pro-high`,
  `gemini-3.7-flash-low` and so on. Ceiling is `high`; there is no `xhigh`.
  `PR_AGY_MODEL` is required for the same reason as Cursor's.
- **agy's `--effort` flag exists and is unreachable.** It is mutually exclusive with `--model`,
  which is required because agy reports no effective model — so the tier-bearing id is the only
  mechanism, and `pins.agy.effort` is refused rather than wired to a hard error.
- **claude** — effort is its own axis again (`--effort`, accepting `low`, `medium`,
  `high`, `xhigh`, `max` — no `none` or `minimal`, unlike codex). `PR_CLAUDE_MODEL`
  is **optional**: the `stream-json` init line reports the model the session
  resolved to, including from an alias (`sonnet` → `claude-sonnet-5`), so
  `round.json` records what answered whether or not you pin one. There is no
  model-listing command, so the pin is passed through unchecked; a wrong one exits
  in under a second having billed nothing.

  `PR_CLAUDE_EFFORT` is passed through **unverified**. Claude Code reports the
  effective effort in neither output format, so `round.json` cannot record which
  tier answered and two rounds at different tiers look identical in the artifacts.
  Keeping the pins identical across a plan's rounds matters more here than
  anywhere else, because nothing downstream can catch you changing one.

Keep the pins identical across the rounds of one plan. Changing a model or effort
mid-loop makes the rounds incomparable, and a resumed session carries context
produced at the old setting.

A model recorded as `X (requested: Y)` means the CLI swapped the model out mid-run —
measured with Cursor, which announces it only as prose in its own output. The pin did
not answer, so that round is not comparable to one that ran on it.

A reviewer that **fails or times out forfeits its own resume handle**, and only its
own — the next round starts that one reviewer clean while everyone else resumes. When
*every* reviewer fails, though, the round itself is marked `aborted`, and the runner then
refuses the next round without `--fresh` (exit 2, naming the flag): the handles are all
forfeited already, so the flag costs the retry only its prompt history. That
holds even when a timed-out reviewer produced usable partial output and is recorded
`ok`: the review is kept, but the vendor-side session state behind the handle was
written by a process the runner killed mid-run, so resuming it is not safe. `--fresh`
is never the fix for a single reviewer; it discards every handle.

`--fresh` starts a new baseline. It drops the resume handles *and* omits the diff,
your previous critique and the rationale from the prompt, so the reviewer sees only
the plan as it stands. Round numbering carries on; nothing is deleted. Dropping the
handles is a store-scoped write like any other: a `--fresh` that cannot clear the
session map aborts with exit 2 before any reviewer starts, rather than running a
round marked `fresh` whose reviewers resume from the handles it failed to drop.

## What it writes

    <repo>/.plan-review/                            gitignored
      config.json                                   optional, yours, per developer
      <repo-hash>-<plan-slug>/
        .lock                                       the session lock (see below)
        session-map.json
        round-N/
          plan.snapshot.md  plan.diff  status.jsonl  round.json
          criteria-<slot>.snapshot.md     the brief this round actually sent
          review-<reviewer>.md
          rationale-<reviewer>.md         written by the Integrator
          files-inspected-<reviewer>.txt

    ~/.cache/plan-review/<repo-hash>-<plan-slug>/<reviewer>/
      repo/          disposable copy, re-copied every round and removed after a
                     clean one; kept when anything went wrong, to be read
      repo/.pr-tmp/  that reviewer's private TMPDIR
      config/        claude only: its private CLAUDE_CONFIG_DIR, and durable

`repo/` is rebuilt from scratch every round rather than synced, so keeping it between
rounds buys nothing but post-hoc debugging — which is exactly when it is kept. A copy
is discarded only when that reviewer finished cleanly, on time and with exit 0;
a timeout, a failure or a non-zero exit keeps its tree. `PR_KEEP_SANDBOX=1` keeps
every copy whatever happened. `config/` is never touched: it is a *sibling* of the
copy precisely so it outlives the wipe, and it is where Claude Code's resume state
lives.

`TMPDIR` sits *inside* `repo/` on purpose. Codex drops `$TMPDIR` from its writable
roots, so a sibling directory would not be writable at all.

## When a round does not finish

`PR_TIMEOUT_SECS` (default 900) caps each reviewer. It must be a **positive whole
number of seconds**: GNU `timeout` would accept `1.5`, but `adapters/agy.sh` derives
its own deadline from this value with integer arithmetic, so a fractional or zero
value is refused with exit 2 before the round starts. The check runs in the runner
rather than in preflight, because `PR_SKIP_PREFLIGHT=1` turns preflight off;
`adapters/agy.sh` repeats it for its own sake, since an adapter can be run by hand.

`PR_KILL_GRACE_SECS` (default 15) is the interval between the TERM `timeout` sends on
expiry and the SIGKILL that follows. It applies to the **adapter itself and not to its
descendants**: `timeout` stops escalating as soon as the direct child is reaped, so an
adapter that handles TERM politely used to leave a TERM-ignoring grandchild behind
forever. The runner now kills the reviewer's whole process group — on every round, not
only on a timeout, since a cleanly exiting adapter can leak a child too — and then, on a
best-effort basis, any descendant that escaped the group by taking one of its own. Those
are sampled while the reviewer runs, one `ps` per second, and killed afterwards only if
their start time still matches, so a recycled pid is not signalled by mistake. A
descendant that detaches after the last sample still escapes; when one does, it keeps the
session's lock, and the next command on that session waits rather than writing over it.
The cost of the sweep is that a descendant mid-write loses whatever it had buffered.

What makes the review file final is not the sweep but **publication**: the adapter writes
to a scratch file, and the runner copies it into place before reading anything from it. A
survivor still writing to the scratch file cannot change the review the round recorded.

**A write the runner cannot make is never reported as a round that worked.** Every
critical write is checked, and the two ways one can fail are answered differently. A
failure scoped to *one reviewer* fails that reviewer and nothing else: a prompt that
cannot be written refuses to start that adapter at all rather than sending it an empty
prompt, and a result record that is missing or unparseable becomes a synthesized `failed`
entry (`reviewer result record missing` / `record invalid`) so `round.json` always
carries every reviewer in the roster. Either way the resume handle is forfeited, like any
other failure, and the round continues on the reviewers that worked. Loss of the
**artifact store itself** — `round.json`, the session map or the runner's own record
cannot be written, because the disk is full or the directory is not writable — is a hard
abort: the runner prints what it could not write, ending in `aborting`, and exits 2. It
does not print "Round complete" over an artifact it failed to record, and the state left
in `round.json` is the last one that actually persisted — usually `reviewing`, and it
stays that way on disk: `abort` writes through the same directory that just refused a
write, so **when that directory is unwritable** it refuses too — one sentence naming the
store — rather than dying half-way through a write. That preflight tests permissions and
nothing else; a full disk leaves the directory writable, so there `abort` still fails on
the write itself, with the same raw `.round.json.<pid>.tmp` error the round printed. Fix
the disk or the permissions first; then the round aborts and reads exactly as any other
unfinished one. **The next round is then `--fresh`, and the runner enforces
it**: a round whose predecessor is `aborted` is refused with exit 2 and a message naming
the flag. The reason is that the serial pass stopped part-way, so every reviewer it had
not reached yet still holds the resume handle from the round before — including handles
this round would have forfeited. The runner does not clear the map on its way out,
because clearing it needs the same store that just refused a write.

**agy runs under a deadline of its own**, derived by the adapter as 90% of
`PR_TIMEOUT_SECS` and passed as `--print-timeout`. Left unset, agy would apply its own
`5m0s` default *inside* the runner's 900s and cut a long review short with nothing to
say why. Passed explicitly and strictly inside the outer deadline, its expiry arrives
as a named error the adapter reports (`agy: print timeout expired`) instead of as a
SIGKILL. The cost is a tenth of agy's budget.

**claude says why a session ended.** When a claude round produces no review, the
recorded reason carries the `terminal_reason` claude reported — `budget_exhausted`
when a spend cap bound, and whatever else the CLI names. The value is echoed rather
than translated, so a reason the CLI invents tomorrow is still reported today.

One `(repo, plan)` pair is one **session**, and at most one round of a session runs at
a time. The runner takes an `flock` on `<session>/.lock` before it reads anything, and
holds it until it exits. Two `plan-review round` invocations on the same plan therefore
cannot both pick round 4; the second waits briefly and then refuses, naming the pid that
holds the session. Two different plans in one repo review concurrently, by design.

The lock answers a question `round.json` cannot. `state: reviewing` is written once, so
it reads the same whether a runner is working right now or died three days ago. The lock
is inherited by every process the runner spawned, which means `kill -9` on the runner
does **not** free the session — its reviewers are still writing, and the lock says so.

    plan-review abort --round <absolute-round-dir>

finalises a round nothing is working on, so the next one may start. It deletes nothing:
a round is aborted when something went wrong, which is when its artifacts are most worth
reading. It refuses while the session is locked, and there is no `--force` — aborting
under a live session would let the next round start on top of reviewers still writing.
When it refuses because the runner is gone but its children are not, it prints a
fixed-string `ps | grep -F` over the sandbox path to find them; killing a `timeout` there
ends its reviewer.

Deleting `.lock` is not an escape hatch. `flock` lives on the inode, so unlinking the
path releases nothing: the orphans keep their lock while the next command creates a fresh
file and locks that, and both run at once.

## What the sandbox is and is not

An accidental-dirtiness barrier, not a security boundary. Every reviewer is
write-confined, but not by the same thing:

- **codex** and **Cursor** confine themselves, via their own OS sandboxes. Writes land
  inside the disposable copy; writes outside it are denied. Cursor's half of that is
  currently in doubt: re-measured 2026-08-27 against `2026.08.25-3e8eec8`, a tool-call
  write to `/tmp` and to `$HOME` both succeeded, wrapped and unwrapped alike. Treat
  Cursor as unconfined for writes at that version until a probe says otherwise.
- **agy** does not. Its `--sandbox` flag exists, reports itself as enabled, and was
  measured allowing a write to `/tmp` anyway. It is confined by **bubblewrap**, which
  this project applies in `adapters/agy.sh` — so that one barrier is ours to maintain
  and ours to get wrong. The adapter refuses to run if `bwrap` is unavailable rather
  than falling back to running unconfined.

  Its conversations live in a private state directory beside the repo copy —
  `<sandbox>/gemini-state`, bound over `~/.gemini` — for the same reasons claude's
  config directory does, and the operator's real `~/.gemini` is **never written**. agy
  honours workspace hooks under `.agents/`, so a read-write bind of the real directory
  would let a hostile workspace plant something that runs later in the operator's own
  sessions. Exactly one file comes in, read-only and by path:
  `~/.gemini/antigravity-cli/antigravity-oauth-token`, which is the minimum agy needs to
  authenticate — measured on 2026-08-27 by binding candidates one at a time from an
  empty private directory. What is lost is agy history from *other* sessions, which
  nothing here relied on: resume is per-session and the session map carries the handles.
- **claude** has no sandbox flag to ask for at all, so `adapters/claude.sh` uses the same
  bubblewrap jail and fails closed the same way. Two additions specific to it. It runs with
  `--safe-mode`, because without it the *target repo's* `.claude/settings.json` hooks
  execute inside the jail on every tool call — measured in both directions, with a control
  run that let the hook fire. And it rebuilds the environment from a whitelist instead of
  inheriting it: a Claude Code session exports a messaging socket and token addressing the
  orchestrator, which is a channel out of the jail that no mount flag closes.

  Its sessions live in a private `CLAUDE_CONFIG_DIR` beside the repo copy, not in
  `~/.claude`. That directory survives the per-round wipe, and it keeps the operator's own
  `settings.json` — whose hooks run in *their* interactive sessions — out of a reviewer's
  reach. The OAuth credentials file is bind-mounted in read-only; it is never read or copied.

`agy` additionally runs with `--dangerously-skip-permissions`, because headless tool
calls are auto-denied otherwise and a reviewer that cannot run commands cannot check
the plan's claims. The jail is what makes that acceptable.

**Process containment is a separate axis from writes.** A reviewer that spawns a
background process can leave it running after the round has returned, still holding the
round's session lock. On Linux every reviewer is now contained by a pid namespace:
`agy`, `claude` and `agent` pass `bwrap --unshare-pid`, and codex uses its own
`--as-pid-1`. `--die-with-parent` alone was not enough — measured 2026-08-27, a detached
`setsid sleep` survived the jail's exit without `--unshare-pid` and was gone with it. For
`agent` the bubblewrap is *only* a pid fence: `/` is bound read-write, the write barrier
stays Cursor's own, and where there is no `bwrap` — macOS — the adapter runs unwrapped
rather than refusing, because refusing would remove the reviewer for a barrier it never
supplied. On macOS there are no pid namespaces at all, and the runner's best-effort
descendant sweep is the only bound.

Reads are unconfined for every reviewer. Codex has open network access; Cursor's is
default-deny with a host allowlist; agy's is open. Point this only at repos you already
trust these CLIs with.

## Tests

    make test          # or: bash tests/run-tests.sh

No test framework and no npm dependencies. Every runner test uses fake adapters, so the
suite runs offline in a couple of seconds.

## Design

`docs/adapter-contract.md` — how to add a reviewer.

The decision record — what was tried, what each CLI was measured doing, and why a call
went the way it did — is kept as process notes in a separate repository, and is not
published with the code. Comments that rest on one cite it by date and title rather
than by path, so the citation stays true wherever those notes live.

Anything captured from a CLI is sanitised before it enters a process note: session and
conversation identifiers, generated text, paths, account metadata and usage figures all
come out, and only the fields a conclusion rests on stay verbatim.
