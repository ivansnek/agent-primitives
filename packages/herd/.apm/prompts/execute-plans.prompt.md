---
description: Execute one or more superpowers plans sequentially in herdr-managed Claude sessions — worker per plan (default sonnet), then a security auditor and a code-quality reviewer that evaluate and fix after every plan (both on the review model, default sonnet), one orchestrator that owns the run (default fable) and leaves a feat/<slug> branch
argument-hint: <plan.md> [<plan.md> ...] [--base <branch>] [--slug <name>] [--orchestrator-model <m>] [--worker-model <m>] [--review-model <m>] [--execution linear|subagent] | --resume <slug> | --dry-run <plan.md> ...
disable-model-invocation: true
---

Launch a herd run for `$ARGUMENTS`. You are only the launcher. The run is owned by a
separate orchestrator session inside herdr; do not execute any plan yourself.

## Steps

1. Locate the engine. It ships with this package, in the `herd-engine` skill's
   `scripts/` directory. Resolve it fresh — never from a path recorded in a ledger.
2. From the repo root run exactly: `<engine>/scripts/launch.sh $ARGUMENTS`
   Pass the arguments through unchanged — do not add, reorder, or drop any.
3. If it exits non-zero, show the `herd: error: …` line to the user verbatim and stop.
   Typical causes: herdr server not running (`herdr status`), a plan path typo, branch
   `feat/<slug>` / worktree / ledger already present (pass `--slug`, or `--resume <slug>`),
   an unsupported `.claude/herd.config.json` version, or the orchestrator agent still alive
   (exit it: `herdr agent prompt <slug>-orch /exit`).
4. If it succeeds, relay its report block to the user unchanged (branch, worktree,
   workspace, agent names, run dir, watch/abort/resume commands). Do not summarize it away.
5. Stop. Do not wait for, poll, read, or prompt the spawned agents. The orchestrator
   reports through herdr notifications; the user resumes with `/execute-plans --resume <slug>`.

## Model selection

Optional flags, one per stage; omit a flag to keep its default. They ride through
`$ARGUMENTS` like every other flag — do not parse or rewrite them.

| Flag | Stage | Default |
|---|---|---|
| `--orchestrator-model <m>` | orchestrator | `fable` |
| `--worker-model <m>` | plan worker (code implementer) | `sonnet` |
| `--review-model <m>` | security auditor and code-quality reviewer | `sonnet` |

`<m>` is a `claude --model` alias (`fable`, `opus`, `sonnet`, `haiku`) or a full model id.
Each plan runs plan → security audit → code review. The security auditor has no flag of its
own: it runs on the `--review-model`. Models are pinned at launch; `--resume` takes no model flags.
Example: `/execute-plans docs/superpowers/plans/x.md --worker-model opus`

## Execution approach

`--execution <mode>` picks how each plan worker executes its plan. Omit it to keep the
default. Like the model flags it rides through `$ARGUMENTS` — do not parse or rewrite it.

| Mode | Superpowers skill | What the plan worker does |
|---|---|---|
| `linear` (default; alias `native`) | `superpowers:executing-plans` | Implements every task itself, inline, in its one session. |
| `subagent` (alias `sub-agent`) | `superpowers:subagent-driven-development` | Acts as controller: a fresh subagent per task, a review after each. More thorough, costs a fresh context per task and per review. |

The approach is pinned at launch; `--resume` takes no `--execution`.
Example: `/execute-plans docs/superpowers/plans/x.md --execution subagent`

## Reference

- Engine and repo profile: the `herd-engine` skill.
- Run state: `<runsDir>/<slug>/` (gitignored) — `run.json` ledger, briefs, audit and review findings,
  sentinels, `orchestrator.log`.
- Watch: `herdr agent list | jq '.result.agents[] | {name, agent_status}'`
