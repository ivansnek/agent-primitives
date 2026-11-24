#!/usr/bin/env bash
# usage: prep-worktree.sh ROOT WORKTREE PLAN_PATH_IN_WORKTREE...
# Herd worktree prep for a pnpm (+ Turbo, + Supabase) monorepo. Copies env files, Supabase CLI
# version pins and untracked plan/spec files from ROOT into WORKTREE (never overwrites), then
# installs dependencies and builds the workspace packages tests link from dist/.
#   HERD_PREP_BUILD_FILTER  pnpm --filter selector for the build step (default: ./packages/*)
#   HERD_PREP_SKIP_INSTALL=1 skips install + build (tests).
set -euo pipefail
# The preset script is standalone: it needs only herd_log / herd_die, so define them here
# rather than reaching into the engine package, whose install path is version-addressed.
herd_log() { printf 'herd: %s\n' "$*" >&2; }
herd_die() { printf 'herd: error: %s\n' "$*" >&2; exit 1; }
ROOT="${1:?usage: prep-worktree.sh ROOT WORKTREE PLAN...}"; WT="${2:?usage: prep-worktree.sh ROOT WORKTREE PLAN...}"; shift 2
[ -d "$ROOT" ] || herd_die "root missing: $ROOT"
[ -d "$WT/.git" ] || [ -f "$WT/.git" ] || herd_die "not a git worktree: $WT"
[ $# -gt 0 ] || herd_die "no plan paths given"

copy_if_missing() {   # REL
  local rel="$1"
  if [ -f "$ROOT/$rel" ] && [ ! -e "$WT/$rel" ]; then
    mkdir -p "$WT/$(dirname "$rel")"
    cp "$ROOT/$rel" "$WT/$rel"
    herd_log "copied $rel"
  fi
}

# 1. env files: root, apps/*, packages/*
for f in .env .env.local .env.keys; do copy_if_missing "$f"; done
for dir in "$ROOT"/apps/* "$ROOT"/packages/*; do
  [ -d "$dir" ] || continue
  for f in .env .env.local .env.keys; do copy_if_missing "${dir#"$ROOT"/}/$f"; done
done

# 1b. Supabase CLI service-version pins (supabase/.temp/*-version, *-migration).
# Local Supabase containers and their volume are shared by every checkout (one project_id).
# A linked main checkout keeps gitignored pins in supabase/.temp recording the service versions
# the shared volume was migrated with. A worktree has no pins, so `supabase start` there boots
# the CLI's default service versions against a volume a newer version already migrated, e.g.
# Storage v1.48 against a volume Storage v1.77.5 already migrated (bucketid_objname dropped), and
# every `upsert: true` upload fails with 42P10. Pins only: project-ref / linked-project.json /
# pooler-url would link the worktree to the remote project.
for pin in "$ROOT"/supabase/.temp/*-version "$ROOT"/supabase/.temp/*-migration; do
  [ -f "$pin" ] || continue
  copy_if_missing "supabase/.temp/${pin##*/}"
done

# 2. plans + the specs they cite
for plan in "$@"; do
  rel="${plan#"$WT"/}"
  copy_if_missing "$rel"
  [ -f "$WT/$rel" ] || herd_die "plan missing in both checkouts: $rel"
  { grep -oE 'docs/superpowers/specs/[A-Za-z0-9._-]+\.md' "$WT/$rel" || true; } | sort -u | while read -r spec; do
    copy_if_missing "$spec"
  done
done

# 3. install + build
if [ "${HERD_PREP_SKIP_INSTALL:-0}" != 1 ]; then
  filter="${HERD_PREP_BUILD_FILTER:-./packages/*}"
  herd_log "pnpm install (worktree)"
  (cd "$WT" && pnpm install --frozen-lockfile)
  herd_log "building workspace packages: $filter"
  (cd "$WT" && pnpm -r --filter "$filter" run --if-present build)
  if [ -f "$WT/turbo.json" ]; then
    [ -x "$WT/node_modules/.bin/turbo" ] || herd_die "turbo missing after install"
  fi
fi
herd_log "prep done: $WT"
