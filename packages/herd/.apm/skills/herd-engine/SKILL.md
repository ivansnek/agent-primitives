---
name: herd-engine
description: Use when running, resuming, or debugging a herd plan-execution run — the launcher, orchestrator, worker briefs, ledger, and the repo profile contract that adapts the engine to a repository.
disable-model-invocation: true
---

# Herd engine

Runs one or more superpowers plans back to back in herdr-managed Claude Code sessions: a
worker per plan (default sonnet), then a security auditor and a code-quality reviewer after
each plan (both on the review model, default sonnet), one orchestrator (default fable) that
owns the run and leaves a `feat/<slug>` branch.

## Stages

Each plan runs three stages, in order, each in its own session and herdr tab:

| Stage | Agent | Model | What it does |
|---|---|---|---|
| plan | `<slug>-plan-N` | `--worker-model` | Implements the plan and commits it. |
| audit | `<slug>-audit-N` | `--review-model` | Security audit of the phase's range against the security standard; records findings (`audit-N.findings.md`), commits the fixes it can make safely, defers the rest. |
| review | `<slug>-rev-N` | `--review-model` | Code-quality review of the same range, the audit's fixes included; applies its fixes. |

The audit runs after implementation and before review on purpose: the reviewer sees and
quality-checks the security fixes, and is told never to revert or weaken them. Security
findings never fail a run on their own; deferred `critical`/`high` findings are counted in
the audit sentinel (`deferred_critical_high`) and flagged first in the run summary.

An audit is a read, not a search, and the reading is spent by risk. The auditor inventories
the range and reads whole every runtime file whose diff changes logic; config and tooling
are judged from their diff unless it runs a command, opens a connection, handles a secret or
loosens a permission. Past 10 files it orders them by risk (auth, policies and migrations
first, client code last), splits them into slices of at most 8 and dispatches a read-only
subagent per slice, up to `auditMaxSlices`; files past the budget are judged from their diff
and named as `over budget`. It confirms the subagents' leads itself, never applies a `low`
finding (recorded only), maps the entry points, and ends its findings file with a
`## Coverage` section (files read and skipped, each entry point, each checklist item) whether
or not it found anything. Slice subagents are told to stay read-only and the auditor checks
the tree is still clean after they report; that detects worktree edits, it does not enforce
the limit (workers run with `bypassPermissions`). `check N audit` answers
`NONE no-coverage: <why>` until the section has its `files:` and `read whole:` lines, the
sentinel's `files_read` + `files_over_budget` reach `files_to_read`, and `read whole:` lists
at least `files_read` paths. Those numbers are self-reported: the gate proves the record is
complete and consistent, not that the files were read. `restart` keeps the findings file for
a resumed session and clears it for a fresh one.

## Models

Each role's model is a `launch.sh` flag. Omit a flag to keep its default.

| Flag | Role | Default |
|---|---|---|
| `--orchestrator-model M` | orchestrator session | `fable` |
| `--worker-model M` | plan worker (code implementer) | `sonnet` |
| `--review-model M` | security auditor and code-quality reviewer | `sonnet` |

The security auditor has no flag of its own: it always runs on the reviewer's model, so the
ledger's `.models` has no `audit` entry.

`M` is anything `claude --model` accepts: an alias (`fable`, `opus`, `sonnet`, `haiku`) or a
full id (`claude-opus-5-5`). The chosen set is pinned in the ledger (`.models`) at launch;
`--resume` rejects model flags. Worker sentinels are checked against the model's family, so
a full id and its on-screen name (`Opus 5.5`) match.

## Execution approach

`launch.sh --execution MODE` picks how a plan worker executes its plan. Omit it to keep the
default.

| Mode | Superpowers skill | The plan worker |
|---|---|---|
| `linear` (default; alias `native`) | `superpowers:executing-plans` | implements every task itself, inline, in its one session |
| `subagent` (alias `sub-agent`) | `superpowers:subagent-driven-development` | is a controller: a fresh subagent per task, a review after each |

The mode is pinned in the ledger (`.execution`) at launch; `--resume` rejects the flag, and a
ledger written before the flag existed runs `linear`. Each mode's rules are one file,
`templates/execution-<mode>.tmpl.md`, rendered into the plan brief and appended to the plan
worker's system prompt so they survive `/compact`. Subagents share the run's worktree and
branch; the worker stays the only session the orchestrator talks to and the only writer of
the sentinel. The audit and review stages are the same in both modes. A repo's `planStyle` must not
name an execution approach — it is appended in every mode.

## Layout

| Path | What |
|---|---|
| `scripts/launch.sh` | The launcher. Creates the worktree, writes the ledger, starts the orchestrator. |
| `scripts/stage.sh` | Orchestrator helpers: spawn, prompt-wait, check, restart, fail, done, ledger. |
| `scripts/lib.sh` | Shared helpers. Sourced, never executed. |
| `scripts/render.sh` | `{{KEY}}` template renderer. |
| `scripts/prep-default.sh` | Default worktree prep (copies env files and plans; no install). |
| `templates/` | Orchestrator, plan, audit and review brief templates, plus one `execution-<mode>` rules file per execution approach. |
| `review-standards.default.md` | Fallback review bar when the repo supplies none. |
| `security-standards.default.md` | Fallback security-audit bar when the repo supplies none. |
| `tests/` | Plain-bash assertion suite plus a fake `herdr`. Run `tests/run.sh`. |

## Repo profile

The engine reads `.claude/herd.config.json` from the repository root. Every field is optional;
absent fields fall back to engine defaults and sequential behavior. `version` must be `1`.

| Key | Default | Meaning |
|---|---|---|
| `planDirs` | `["docs/superpowers/plans"]` | Where plans live. |
| `specDirs` | `["docs/superpowers/specs"]` | Where specs live. |
| `worktreeDir` | `.claude/worktrees` | Where run worktrees are created. |
| `runsDir` | `.claude/herd-runs` | Where run state is written. Gitignore it. |
| `defaultBase` | current branch | Base branch when `--base` is not passed. |
| `prepScript` | `scripts/prep-default.sh` | Worktree prep. Receives `ROOT WORKTREE PLAN...`. |
| `testCommand` | none | Verification command the audit and review stages run after their fixes; `{{BASE}}` in it becomes the run's base branch. Unset: they use the checks the repo's own docs define. |
| `reviewStandards` | `review-standards.default.md` | The review bar. |
| `securityStandards` | `security-standards.default.md` | The security-audit bar. |
| `auditMaxSlices` | `5` | How many slice subagents (8 files each) one audit may dispatch to read files whole. Higher: deeper and dearer. Files past the budget are judged from their diff and listed as `over budget`; auth, policy, migration and entry-point files are never dropped. |
| `disallowedTools` | `["Bash(git push)", "Bash(git push:*)"]` | Extra `--disallowedTools` for workers. |
| `planStyle` | none | Optional output style appended to plan workers' system prompt. |

## Rules

- The engine root is resolved at every invocation from the live install. A path stored in a
  ledger is provenance only and is never used to locate a script.
- Never merge, push, rebase, or run database migrations from a worker or the orchestrator.
- Run state lives in `<runsDir>/<slug>/`; the ledger `run.json` is the only durable memory.
- A ledger written before the audit stage existed gets `.plans[].audit` on `--resume`:
  `pending` while that plan's review has not started, `skipped` otherwise — an audit never
  runs after a review of the same plan.
