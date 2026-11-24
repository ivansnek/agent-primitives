#!/usr/bin/env bash
# packages/turbo-fullstack/herd-preset/prep-worktree.sh: generic pnpm + Turbo worktree prep.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/packages/herd/.apm/skills/herd-engine/tests/assert.sh"
PREP="$REPO_ROOT/packages/turbo-fullstack/herd-preset/prep-worktree.sh"
PLAN=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md

# Fake pnpm: logs its arguments, succeeds.
FAKE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/fake-pnpm.XXXXXX")"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$PNPM_LOG"\n' > "$FAKE_BIN/pnpm"; chmod +x "$FAKE_BIN/pnpm"
export PATH="$FAKE_BIN:$PATH"

# setup -> sets $r (root) and $wt (fresh worktree), $PNPM_LOG (empty log).
setup() {
  r="$(make_repo)"; wt="$r/wt"
  git -C "$r" worktree add -q "$wt"
  PNPM_LOG="$r/pnpm.log"; export PNPM_LOG; : > "$PNPM_LOG"
}

# copies: plan, cited spec, env files.
setup
HERD_PREP_SKIP_INSTALL=1 "$PREP" "$r" "$wt" "$wt/$PLAN" 2>/dev/null
assert_file "$wt/$PLAN" "plan copied"
assert_file "$wt/docs/superpowers/specs/2026-09-04-sample-feature-design.md" "cited spec copied"
assert_file "$wt/.env.local" "root .env.local copied"
assert_eq "$(cat "$wt/apps/web/.env.local")" "WEB=1" "apps/* env copied"

# supabase pins: version pins copied, project link files not.
setup
mkdir -p "$r/supabase/.temp"
printf 'v1\n' > "$r/supabase/.temp/storage-version"; printf 'ref\n' > "$r/supabase/.temp/project-ref"
HERD_PREP_SKIP_INSTALL=1 "$PREP" "$r" "$wt" "$wt/$PLAN" 2>/dev/null
assert_file "$wt/supabase/.temp/storage-version" "supabase version pin copied"
assert_no_file "$wt/supabase/.temp/project-ref" "supabase project link not copied"

# no supabase dir: fine.
setup
assert_exit 0 env HERD_PREP_SKIP_INSTALL=1 "$PREP" "$r" "$wt" "$wt/$PLAN"

# default build: install then build every workspace package that has a build script.
setup
assert_exit 0 "$PREP" "$r" "$wt" "$wt/$PLAN"
log="$(cat "$PNPM_LOG")"
assert_contains "$log" "install --frozen-lockfile" "frozen install"
assert_contains "$log" "-r --filter ./packages/* run --if-present build" "default build filter"

# custom filter.
setup
assert_exit 0 env HERD_PREP_BUILD_FILTER=@x/core "$PREP" "$r" "$wt" "$wt/$PLAN"
assert_contains "$(cat "$PNPM_LOG")" "--filter @x/core" "custom build filter"

# turbo.json present but turbo not installed: die.
setup
printf '{}\n' > "$wt/turbo.json"
assert_exit 1 "$PREP" "$r" "$wt" "$wt/$PLAN"

# turbo.json present and turbo installed: ok.
setup
printf '{}\n' > "$wt/turbo.json"
mkdir -p "$wt/node_modules/.bin"; printf '#!/bin/sh\n' > "$wt/node_modules/.bin/turbo"; chmod +x "$wt/node_modules/.bin/turbo"
assert_exit 0 "$PREP" "$r" "$wt" "$wt/$PLAN"

# the Supabase pin comment keeps its concrete failure (final-review fix).
assert_contains "$(cat "$PREP")" "42P10" "supabase pin gotcha keeps the concrete error"

# no hardcoded workspace scope.
assert_not_contains "$(cat "$PREP")" "@ram""car" "no hardcoded package scope"

finish
