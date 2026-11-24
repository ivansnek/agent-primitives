#!/usr/bin/env bash
# usage: prep-worktree.sh ROOT WORKTREE PLAN_PATH_IN_WORKTREE...
# Copies env files and untracked plan/spec files from ROOT into WORKTREE (never overwrites),
# then installs dependencies and builds the packages Jest/Vitest link from dist/.
# HERD_PREP_SKIP_INSTALL=1 skips install + build (tests).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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

# 2. plans + the specs they cite
for plan in "$@"; do
  rel="${plan#"$WT"/}"
  copy_if_missing "$rel"
  [ -f "$WT/$rel" ] || herd_die "plan missing in both checkouts: $rel"
  { grep -oE 'docs/superpowers/specs/[A-Za-z0-9._-]+\.md' "$WT/$rel" || true; } | sort -u | while read -r spec; do
    copy_if_missing "$spec"
  done
done

# 3. no install step in the default prep. A repo that needs one supplies its own script
#    via .claude/herd.config.json -> prepScript; see packages/turbo-fullstack/herd-preset/prep-worktree.sh.
herd_log "prep done (default: copy only): $WT"
