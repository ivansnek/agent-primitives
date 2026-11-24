# agent-primitives

[APM](https://github.com/microsoft/apm) packages for Claude Code: a plan-execution engine and a
skill pack for pnpm + Turbo full-stack monorepos.

| Package | What it is |
|---|---|
| `packages/herd` | Generic plan-execution engine. `/execute-plans` runs [superpowers](https://github.com/obra/superpowers) plans in herdr-managed Claude Code sessions, with security-audit and code-review stages. Contains no repo-specific knowledge; a repo adapts it through `.claude/herd.config.json`. |
| `packages/turbo-fullstack` | Skills for a pnpm + Turbo monorepo with a NestJS API, Next.js web apps, an Expo mobile app and Supabase (API endpoints, backend patterns, web and mobile patterns, offline PWA, shared feature modules, i18n, frontend performance, on-demand code review), plus `herd-preset/`: an example herd config, worktree prep script and review standards for that stack. |

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) and [APM](https://github.com/microsoft/apm)
- For `herd`: `herdr`, `git`, `jq`, bash 4.4 or newer (macOS ships 3.2 at `/bin/bash`: `brew install bash`), and plans written with the superpowers `writing-plans` skill

## Install

Add the packages you want to your repo's `apm.yml`. `herd` works on its own; `turbo-fullstack`'s `execute-code-review` skill and `herd-preset/` build on `herd`, so install both to use them:

```yaml
dependencies:
  apm:
    - git: https://github.com/ivansnek/agent-primitives.git
      path: packages/herd
      ref: main
    - git: https://github.com/ivansnek/agent-primitives.git
      path: packages/turbo-fullstack
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

## Your layout wins

The `turbo-fullstack` skills write paths the conventional Turbo way (`apps/api`, `apps/web`,
`apps/mobile`, `packages/shared`, `packages/i18n`, …), package names as `@<scope>/…`, and name
helpers as examples. If your repo differs — say your web app is `apps/admin`, or a rule does
not apply — state it in `CLAUDE.md` / `AGENTS.md`; the skills defer to it.

If your repo already has a local skill with the same name as one of these, keep one of the two.

## Development

```bash
bash tests/run.sh            # repo tests + the herd engine suite
scripts/check-generic.sh     # tracked files carry no repo-specific leaks
```

## License

MIT
