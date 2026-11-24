#!/usr/bin/env bash
# The engine package must contain no repository-specific knowledge (plan Global Constraints).
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"

# Scan $HERD itself, not a crawled-up "package root": the crawl depth from HERD to the
# packages/herd directory only holds in the source monorepo (packages/herd/.apm/skills/
# herd-engine, 3 levels down). After `apm install` the engine deploys 2 levels below the
# CONSUMER's own root (<root>/.claude/skills/herd-engine) — the same depth mismatch
# herd_engine_version works around — so a fixed "../../.." crawl scans the whole consumer
# repo instead of the engine. $HERD covers every file that actually ships with the engine.
hits="$(grep -rniE 'te''nant|supabase|zodroute|pnpm --filter|check:i18n|Test Execution Policy' \
  "$HERD" --include='*.sh' --include='*.md' --include='*.json' --include='*.yml' \
  | grep -v '/tests/' || true)"
assert_eq "$hits" "" "the engine ships no repo-specific string"

# The default review standards are repo-agnostic.
assert_no_file "$HERD/review-standards.md" "repo-specific review standards do not ship with the engine"
assert_file "$HERD/review-standards.default.md" "the engine ships a default review bar"

finish
