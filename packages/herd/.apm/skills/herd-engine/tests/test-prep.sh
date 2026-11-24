#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
source "$HERD/scripts/lib.sh"
use_fake_herdr
r="$(make_repo)"; cd "$r"
plan=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md
"$HERD/scripts/launch.sh" "$plan" >/dev/null 2>&1
wt="$r/.claude/worktrees/sample-feature"
assert_no_file "$wt/$plan" "untracked plan is absent from a fresh worktree"

HERD_PREP_SKIP_INSTALL=1 "$HERD/scripts/prep-default.sh" "$r" "$wt" "$wt/$plan"
assert_file "$wt/$plan" "plan copied"
assert_file "$wt/docs/superpowers/specs/2026-09-04-sample-feature-design.md" "spec referenced by the plan copied"
assert_file "$wt/.env.local" "root .env.local copied"
assert_file "$wt/.env.keys" "root .env.keys copied"
assert_eq "$(cat "$wt/apps/web/.env.local")" "WEB=1" "apps/* env copied"

printf 'CHANGED=1\n' > "$wt/.env.local"
HERD_PREP_SKIP_INSTALL=1 "$HERD/scripts/prep-default.sh" "$r" "$wt" "$wt/$plan"
assert_eq "$(cat "$wt/.env.local")" "CHANGED=1" "prep never overwrites an existing file"

assert_exit 1 env HERD_PREP_SKIP_INSTALL=1 "$HERD/scripts/prep-default.sh" "$r" "$r/nope" "$wt/$plan"
assert_exit 1 env HERD_PREP_SKIP_INSTALL=1 "$HERD/scripts/prep-default.sh" "$r" "$wt" "$wt/docs/superpowers/plans/missing.md"

r2="$(make_repo)"
assert_contains "$(herd_prep_script "$r2")" "scripts/prep-default.sh" "no config -> default prep"
mkdir -p "$r2/.claude" "$r2/tools"
printf '#!/usr/bin/env bash\necho custom-prep\n' > "$r2/tools/my-prep.sh"; chmod +x "$r2/tools/my-prep.sh"
printf '{"version":1,"prepScript":"tools/my-prep.sh"}\n' > "$r2/.claude/herd.config.json"
assert_eq "$(herd_prep_script "$r2")" "$r2/tools/my-prep.sh" "config prepScript resolves against the repo root"
printf '{"version":1,"prepScript":"tools/missing.sh"}\n' > "$r2/.claude/herd.config.json"
assert_exit 1 herd_prep_script "$r2"

finish
