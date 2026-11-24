#!/usr/bin/env bash
# Every turbo-fullstack skill: frontmatter name matches its dir, opens with the "repo wins"
# header line, and its description keeps the anchor term that makes it fire.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/packages/herd/.apm/skills/herd-engine/tests/assert.sh"
SKILLS="$REPO_ROOT/packages/turbo-fullstack/.apm/skills"
HEADER='> Paths below are the conventional Turbo layout, and named helpers are examples. Where this repo'"'"'s `CLAUDE.md`/`AGENTS.md` names a different layout or overrides a rule here, the repo wins.'

frontmatter() { awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$1"; }   # FILE
fm_field() { frontmatter "$1" | sed -n "s/^$2: *//p" | head -1; }                      # FILE KEY
first_after_h1() { awk 'h && NF {print; exit} /^# / {h=1}' "$1"; }                     # FILE

while IFS='|' read -r skill anchor; do
  f="$SKILLS/$skill/SKILL.md"
  assert_file "$f" "$skill exists"
  [ -f "$f" ] || continue
  assert_eq "$(fm_field "$f" name)" "$skill" "$skill: frontmatter name"
  assert_eq "$(first_after_h1 "$f")" "$HEADER" "$skill: header line"
  assert_contains "$(fm_field "$f" description)" "$anchor" "$skill: description anchor"
done <<'EOF'
add-api-endpoint|ZodRoute
backend-patterns|NestJS
execute-code-review|review
frontend-performance|React
i18n-workflow|i18n
mobile-patterns|Expo
shared-feature-modules|web and mobile
web-frontend-patterns|apps/web
web-offline-pwa|service worker
EOF

assert_eq "$(ls "$SKILLS" | wc -l | tr -d ' ')" "9" "exactly 9 skills ship"
assert_not_contains "$(cat "$SKILLS/execute-code-review/SKILL.md")" "apm_modules/" "no hardcoded standards path"

# Final-review fixes: content rules the rewrite must keep.
all="$(cat "$SKILLS"/*/SKILL.md)"
# Spec: never tell Claude to create a helper, test or package the repo lacks.
assert_not_contains "$all" "is the moment to create" "no instruction to create the shared features package"
assert_not_contains "$all" "Enforce it with a static scan test" "no instruction to add an href scan test"
assert_not_contains "$all" "enforce it with a test that scans" "no instruction to add a camera scan test"
assert_not_contains "$all" "Route all photos through one picker helper" "no instruction to add a picker helper"
# RLS is unconditional on Supabase: the anon key ships in every client bundle.
backend="$(cat "$SKILLS/backend-patterns/SKILL.md")"
assert_not_contains "$backend" "when the database is reachable outside the API" "RLS not made conditional"
assert_contains "$backend" "Postgres RLS (DB)" "RLS enforced alongside guards"
# Spec: tenancy rules are deleted, not reworded as another isolation rule.
assert_not_contains "$all" "scopeId" "no scope slot in query keys"
assert_not_contains "$all" "scope pinning" "no scope-pinning outbox rule"
assert_not_contains "$all" "per account" "no per-account opt-out"
assert_contains "$(cat "$SKILLS/web-frontend-patterns/SKILL.md")" "query keys include every parameter the data depends on" "spec wording for query keys"

finish
