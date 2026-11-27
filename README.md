# agent-primitives

[APM](https://github.com/microsoft/apm) packages for Claude Code: a plan-execution engine, a
Linear-to-branch loop built on it, and a skill pack for pnpm + Turbo full-stack monorepos.

| Package | What it is |
|---|---|
| `packages/herd` | Generic plan-execution engine. `/execute-plans` runs [superpowers](https://github.com/obra/superpowers) plans in herdr-managed Claude Code sessions, with security-audit and code-review stages. Contains no repo-specific knowledge; a repo adapts it through `.claude/herd.config.json`. |
| `packages/linear-loop` | Built on `herd`. `/linear-loop` takes Linear issues and epics, one at a time in dependency order, from ticket to a reviewed local branch: brainstorm answered by advisor agents, spec, plan, herd execution. It asks you only when nobody else can decide, and never merges or pushes. |
| `packages/turbo-fullstack` | Skills for a pnpm + Turbo monorepo with a NestJS API, Next.js web apps, an Expo mobile app and Supabase (API endpoints, backend patterns, web and mobile patterns, offline PWA, shared feature modules, i18n, frontend performance, on-demand code review), plus `herd-preset/`: an example herd config, worktree prep script and review standards for that stack. |

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) and [APM](https://github.com/microsoft/apm)
- For `herd`: `herdr`, `git`, `jq`, bash 4.4 or newer (macOS ships 3.2 at `/bin/bash`: `brew install bash`), and plans written with the superpowers `writing-plans` skill
- For `linear-loop`: everything `herd` needs, the `herd` package (0.7.0 or newer), Linear tools available to Claude Code, and the superpowers `brainstorming` skill. Its briefs also ask for the `caveman` skill, and carry the output rules for when it is missing

## Install

Add the packages you want to your repo's `apm.yml`. `herd` works on its own; `linear-loop`, and `turbo-fullstack`'s `execute-code-review` skill and `herd-preset/`, build on `herd`, so install it with them:

```yaml
dependencies:
  apm:
    - git: https://github.com/ivansnek/agent-primitives.git
      path: packages/herd
      ref: main
    - git: https://github.com/ivansnek/agent-primitives.git
      path: packages/turbo-fullstack
      ref: main
    - git: https://github.com/ivansnek/agent-primitives.git
      path: packages/linear-loop
      ref: main
```

Then run `apm install`. Skills and prompts deploy into `.claude/`; each package's folder (including
`herd-preset/`) lands under `apm_modules/ivansnek/agent-primitives/packages/`.

## Configure herd

1. Copy the preset: `cp apm_modules/ivansnek/agent-primitives/packages/turbo-fullstack/herd-preset/herd.config.json .claude/herd.config.json`
2. Adjust it: `defaultBase`, `testCommand`, `disallowedTools`. Every key is optional; the full
   list is in the `herd-engine` skill (`.claude/skills/herd-engine/SKILL.md` → "Repo profile").
3. Add `.claude/herd-runs` and `.claude/worktrees` (or your `runsDir` and `worktreeDir`) to
   `.gitignore`; otherwise `git add -A` in the main checkout stages the run worktrees.

The preset's `prepScript` installs with `pnpm install --frozen-lockfile` and builds the workspace
packages matching `HERD_PREP_BUILD_FILTER` (default `./packages/*`). Point `prepScript` and
`reviewStandards` at your own files to customize them.

Optional: `planStyle` appends an output style to every plan worker's system prompt, e.g.

```json
"planStyle": "Output style: terse. Drop filler and progress narration; code, commit messages and sentinel files keep their exact required shape."
```

## Configure linear-loop

1. Optionally add `.claude/linear-loop.config.json`. Every key is optional; `version` is required
   when the file exists:

   ```json
   {"version": 1, "adrDir": "docs/adr", "linearWrites": "status", "advisorMaxRevisions": 2}
   ```

   | Key | Default | Meaning |
   |---|---|---|
   | `adrDir` | `docs/adr` | The ADR folder: where architecture decisions are written and read. Relative, inside the repo. |
   | `runsDir` | `.claude/loop-runs` | Where run state is written. |
   | `statusStarted` | none (first status of type `started`) | Linear status set when a unit starts. |
   | `statusReview` | none (`In Review`, if the team has it) | Linear status set when a unit's branch is ready. |
   | `linearWrites` | `"status"` | `"none"`, `"comments"`, or `"status"` (comments and status). Sub-issues of a split you approve are created either way. |
   | `advisorMaxRevisions` | `2` | Spec revise rounds before you are asked. |

2. Add `.claude/loop-runs` (or your `runsDir`), `.claude/herd-runs` and `.claude/worktrees` to
   `.gitignore`.
3. ADRs go to `adrDir` (default `docs/adr`), following the format of the ones already there. An
   empty or missing folder starts with a short default format.
4. Remote Control: the orchestrator session appears in claude.ai/code and the Claude mobile app under the run's slug.
   Answer its questions there or in the terminal.

Specs, plans, worktrees and herd run state use fixed paths (`docs/superpowers/specs`,
`docs/superpowers/plans`, `.claude/worktrees`, `.claude/herd-runs`); herd's `specDirs`,
`planDirs` and `worktreeDir` keys do not move them. Details are in the `linear-loop-engine`
skill (`.claude/skills/linear-loop-engine/SKILL.md`).

## Run

With the herdr server running, preview the dependency map first:

```
/linear-loop --map-only ENG-1 ENG-7
```

The orchestrator reads the issues, prints the ordered units and stops. Check the list, exit that
session (`herdr agent prompt eng-1-loop /exit`), then run it:

```
/linear-loop --resume eng-1-loop
```

Without `--map-only` the run starts right after mapping. `--resume <slug>` also recovers an
interrupted run, as long as the run's herdr workspace still exists. Finished branches are local
and stacked, each on the one before it; you merge them.

## Your layout wins

The `turbo-fullstack` skills write paths the conventional Turbo way (`apps/api`, `apps/web`,
`apps/mobile`, `packages/shared`, `packages/i18n`, …), package names as `@<scope>/…`, and name
helpers as examples. If your repo differs — say your web app is `apps/admin`, or a rule does
not apply — state it in `CLAUDE.md` / `AGENTS.md`; the skills defer to it.

If your repo already has a local skill with the same name as one of these, keep one of the two.

## Development

```bash
bash tests/run.sh            # repo tests + the herd and linear-loop engine suites
scripts/check-generic.sh     # tracked files carry no repo-specific leaks
```

## License

MIT
