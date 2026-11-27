---
description: Take Linear issues and epics, one unit at a time and in dependency order, from ticket to a reviewed local feature branch in herdr-managed Claude sessions, pausing for you only when nobody else can decide
argument-hint: <ID> [<ID> ...] [--base <branch>] [--slug <name>] [--orchestrator-model <m>] [--brainstorm-model <m>] [--advisor-model <m>] [--worker-model <m>] [--review-model <m>] [--execution linear|subagent] [--map-only] | --resume <slug> | --dry-run <ID> ...
disable-model-invocation: true
---

Launch a linear-loop run for `$ARGUMENTS`. You are only the launcher. The run is owned by a
separate orchestrator session inside herdr; do not read the issues, brainstorm, plan or
implement anything yourself.

## Steps

1. Locate the engine. It ships with this package, in the `linear-loop-engine` skill's
   `scripts/` directory. Resolve it fresh — never from a path recorded in a ledger.
2. From the repo root run exactly: `<engine>/scripts/launch.sh $ARGUMENTS`
   Pass the arguments through unchanged — do not add, reorder, or drop any.
3. If it exits non-zero, show the `herd: error: …` line to the user verbatim and stop.
   Typical causes: herdr server not running (`herdr status`), the herd package missing or too
   old, a malformed issue ID, a base ref that does not exist, the run ledger or the design
   worktree already present (pass `--slug`, or `--resume <slug>`), an unsupported
   `.claude/linear-loop.config.json` or `.claude/herd.config.json` version, or the
   orchestrator agent still alive (exit it: `herdr agent prompt <slug>-loop /exit`).
4. If it succeeds, relay its report block to the user unchanged (base, units, workspace,
   orchestrator, Remote Control session name, run dir, `PROGRESS.md`, watch/abort/resume
   commands). Do not summarize it away. For `--dry-run`, relay the `DRY-RUN:` lines.
5. Stop. Do not wait for, poll, read, or prompt the spawned sessions. The orchestrator
   reports through herdr notifications; the user resumes with `/linear-loop --resume <slug>`.

## Models and herd flags

Optional flags; omit one to keep its default. They ride through `$ARGUMENTS` like every other
flag — do not parse or rewrite them.

| Flag | Applies to | Default |
|---|---|---|
| `--orchestrator-model <m>` | the loop orchestrator | `fable` |
| `--brainstorm-model <m>` | the brainstormer session of each unit | `fable` |
| `--advisor-model <m>` | the advisor subagents (answers and spec review) | `fable` |
| `--worker-model <m>` | passed to every herd run: plan worker | herd's default |
| `--review-model <m>` | passed to every herd run: security auditor and code reviewer | herd's default |
| `--execution linear\|subagent` | passed to every herd run: how a plan worker executes | herd's default |

`<m>` is a `claude --model` alias (`fable`, `opus`, `sonnet`, `haiku`) or a full model id.
Models and herd flags are pinned at launch; `--resume` takes only the slug (and `--dry-run`).
Example: `/linear-loop ENG-12 ENG-15 --worker-model opus`

## `--map-only`

`/linear-loop --map-only <ID> ...` launches the run, but the orchestrator stops after the
dependency map: it reads the issues, orders the units, writes the ledger and `PROGRESS.md`,
and prints the ordered list (status `mapped`). Check it, exit that session
(`herdr agent prompt <slug>-loop /exit`), then `/linear-loop --resume <slug>` runs it.

`--dry-run` is different: it only prints the commands the launcher would run and creates
nothing. It cannot show the map, because only a session can reach Linear.

## Human pauses

The run stops to ask you only when it has to: a problem in the dependency map, a question the
advisor cannot ground, an architecture decision or a doubtful spec, a unit that must be split,
or a failed or stuck step. You get a herdr notification. Answer in the orchestrator session,
locally (`herdr agent focus <slug>-loop`) or over Remote Control (session `<slug>`); your
reply there is the ruling and the loop continues. The question is also in
`<run dir>/PROGRESS.md`. Do not answer in this launcher session.

Finished branches are local and stacked, each on the one before it. Nothing is merged or
pushed.

## Reference

- Engine: the `linear-loop-engine` skill. It builds on the `herd-engine` skill.
- Repo profile: `.claude/linear-loop.config.json` (optional, `version: 1`): `adrDir`,
  `runsDir`, `statusStarted`, `statusReview`, `linearWrites` (`none`, `comments`, `status`),
  `advisorMaxRevisions`.
- Run state: `<runsDir>/<slug>/` (default `.claude/loop-runs`, gitignore it) — `run.json`
  ledger, `PROGRESS.md`, `orchestrator.log`, pause questions, per-unit files.
- Watch: `herdr agent list | jq '.result.agents[] | {name, agent_status}'`
