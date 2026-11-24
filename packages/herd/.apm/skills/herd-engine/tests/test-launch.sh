#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
use_fake_herdr
r="$(make_repo)"; cd "$r"
plan=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md
run="$r/.claude/herd-runs/sample-feature"

# dry run: prints the commands, creates nothing
out="$("$HERD/scripts/launch.sh" --dry-run "$plan" 2>&1)"
assert_contains "$out" "worktree create --cwd $r --branch feat/sample-feature --base dev --path $r/.claude/worktrees/sample-feature --label herd:sample-feature --no-focus" "dry-run prints worktree create with --cwd"
assert_contains "$out" "agent start sample-feature-orch --kind claude --pane <root_pane> --timeout 120000 -- --model fable --permission-mode bypassPermissions" "dry-run prints orchestrator start"
assert_no_file "$run/run.json" "dry-run writes no ledger"
assert_no_file "$r/.claude/worktrees/sample-feature" "dry-run creates no worktree"
assert_contains "$out" "DRY-RUN: execution=linear" "dry-run prints the default execution mode"
assert_eq "$(cat "$FAKE_HERDR_LOG")" "$(printf 'workspace list\nagent list')" "dry-run only runs read-only preflight calls"

# preflight failures
assert_exit 1 "$HERD/scripts/launch.sh" --base nope "$plan"

# base: --base, else the profile's defaultBase, else the current branch
rb="$(make_repo)"; git -C "$rb" branch release; git -C "$rb" checkout -q -b wip
printf '{"version":1,"defaultBase":"release"}\n' > "$rb/.claude/herd.config.json"
out="$(cd "$rb" && "$HERD/scripts/launch.sh" --dry-run "$plan" 2>&1)"
assert_contains "$out" "--base release --path" "defaultBase wins over the current branch"
out="$(cd "$rb" && "$HERD/scripts/launch.sh" --dry-run --base dev "$plan" 2>&1)"
assert_contains "$out" "--base dev --path" "--base wins over defaultBase"
printf '{"version":1,"defaultBase":"nope"}\n' > "$rb/.claude/herd.config.json"
assert_exit 1 sh -c "cd '$rb' && '$HERD/scripts/launch.sh' --dry-run '$plan'"
assert_exit 1 "$HERD/scripts/launch.sh" docs/nope.md
assert_exit 1 "$HERD/scripts/launch.sh" --slug Bad "$plan"
assert_exit 1 "$HERD/scripts/launch.sh"

# real launch (fake herdr)
out="$("$HERD/scripts/launch.sh" "$plan" 2>&1)"
assert_file "$run/run.json" "ledger written"
assert_eq "$(jq -r .branch "$run/run.json")" feat/sample-feature "ledger branch"
assert_eq "$(jq -r .base "$run/run.json")" dev "ledger base defaults to current branch"
assert_eq "$(jq -r .workspace_id "$run/run.json")" wT "ledger workspace id"
assert_eq "$(jq -r .orchestrator_pane "$run/run.json")" wT:p1 "ledger orchestrator pane"
assert_eq "$(jq -r .herd_dir "$run/run.json")" "$HERD" "ledger herd dir"
assert_eq "$(jq -r .status "$run/run.json")" created "ledger status"
assert_eq "$(jq -r '.plans | length' "$run/run.json")" 1 "ledger plan count"
assert_eq "$(jq -r '.plans[0].path' "$run/run.json")" "$r/.claude/worktrees/sample-feature/$plan" "plan path points into the worktree"
assert_eq "$(jq -r '.plans[0].title' "$run/run.json")" "Sample Feature — Phase 1: Shell" "plan title"
assert_eq "$(jq -r '.plans[0].plan.agent' "$run/run.json")" sample-feature-plan-1 "plan agent name"
assert_eq "$(jq -r '.plans[0].review.agent' "$run/run.json")" sample-feature-rev-1 "review agent name"
assert_eq "$(jq -r '.plans[0].audit.agent' "$run/run.json")" sample-feature-audit-1 "audit agent name"
assert_eq "$(jq -r '.plans[0].audit.status' "$run/run.json")" pending "audit stage starts pending"
assert_eq "$(jq -r '.plans[0] | keys_unsorted | join(" ")' "$run/run.json")" "index path title plan audit review" "audit sits between plan and review"
assert_eq "$(jq -r 'has("models") and (.models | has("audit") | not)' "$run/run.json")" true "the audit pins no model of its own"
assert_eq "$(jq -r '.models | "\(.orchestrator) \(.plan) \(.review)"' "$run/run.json")" "fable sonnet sonnet" "models pinned"
assert_eq "$(jq -r .execution "$run/run.json")" linear "execution defaults to linear and is pinned"
assert_contains "$(cat "$run/orchestrator.md")" "Plan execution: \`linear\`" "orchestrator brief names the default execution mode"
assert_eq "$(jq -r 'has("review_args")' "$run/run.json")" false "no /code-review args in the ledger"
assert_file "$run/orchestrator.md" "orchestrator brief rendered"
assert_contains "$(cat "$run/orchestrator.md")" "$HERD/scripts/stage.sh $run" "orchestrator brief has absolute helper path"
assert_not_contains "$(cat "$run/orchestrator.md")" "{{" "orchestrator brief fully rendered"
assert_contains "$(cat "$run/orchestrator.md")" "$HERD/security-standards.default.md" "orchestrator brief names the security standard the auditor gets"
assert_contains "$(cat "$run/orchestrator.md")" "$HERD/review-standards.default.md" "orchestrator brief names the review standard the reviewer gets"
assert_file "$r/.claude/worktrees/sample-feature/.git" "worktree created"
log="$(cat "$FAKE_HERDR_LOG")"
assert_contains "$log" "agent start sample-feature-orch --kind claude --pane wT:p1 --timeout 120000 -- --model fable --permission-mode bypassPermissions" "orchestrator started with fable"
assert_contains "$log" "agent prompt sample-feature-orch Read $run/orchestrator.md and follow it exactly. Run dir: $run" "orchestrator prompted"
assert_contains "$out" "/execute-plans --resume sample-feature" "report mentions resume"
assert_contains "$out" "feat/sample-feature" "report mentions branch"
assert_contains "$out" "execution     linear" "report names the execution mode"

# second launch refuses (branch/worktree/ledger exist)
assert_exit 1 "$HERD/scripts/launch.sh" "$plan"

# resume: refuses while the orchestrator is live, then opens a new tab
printf '{"result":{"agents":[{"name":"sample-feature-orch"}]}}' > "$FAKE_HERDR_STATE/agents.json"
assert_exit 1 "$HERD/scripts/launch.sh" --resume sample-feature
rm "$FAKE_HERDR_STATE/agents.json"
jq '.status = "failed"' "$run/run.json" > "$run/tmp.json" && mv "$run/tmp.json" "$run/run.json"
out="$("$HERD/scripts/launch.sh" --resume sample-feature 2>&1)"
assert_eq "$(jq -r .orchestrator_pane "$run/run.json")" wT:p2 "resume records the new pane"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab create --workspace wT --cwd $r/.claude/worktrees/sample-feature --label orchestrator --no-focus" "resume opens a tab in the run workspace"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt sample-feature-orch Resume the herd run: read $run/orchestrator.md" "resume prompt"
assert_contains "$(cat "$run/orchestrator.md")" "$HERD/review-standards.default.md" "resume re-renders the orchestrator brief from the current template"
jq '.status = "done"' "$run/run.json" > "$run/tmp.json" && mv "$run/tmp.json" "$run/run.json"
assert_exit 1 "$HERD/scripts/launch.sh" --resume sample-feature
assert_exit 1 "$HERD/scripts/launch.sh" --resume unknown-slug

# model flags: pinned in the ledger, used for the orchestrator, rendered into its brief
r2="$(make_repo)"; cd "$r2"; run2="$r2/.claude/herd-runs/sample-feature"
out="$("$HERD/scripts/launch.sh" --dry-run --orchestrator-model opus --worker-model claude-opus-5-5 "$plan" 2>&1)"
assert_contains "$out" "models orchestrator=opus plan=claude-opus-5-5 review=sonnet" "dry-run prints chosen models, review defaults"
assert_contains "$out" "-- --model opus --permission-mode" "dry-run orchestrator uses the chosen model"
assert_exit 1 "$HERD/scripts/launch.sh" --worker-model --slug x "$plan"
assert_exit 1 "$HERD/scripts/launch.sh" --review-model 'so net' "$plan"
: > "$FAKE_HERDR_LOG"
out="$("$HERD/scripts/launch.sh" --orchestrator-model opus --worker-model claude-haiku-4-5 --review-model opus "$plan" 2>&1)"
assert_eq "$(jq -r '.models | "\(.orchestrator) \(.plan) \(.review)"' "$run2/run.json")" "opus claude-haiku-4-5 opus" "custom models pinned"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent start sample-feature-orch --kind claude --pane wT:p1 --timeout 120000 -- --model opus --permission-mode bypassPermissions" "orchestrator started with the chosen model"
assert_contains "$(cat "$run2/orchestrator.md")" "must be the \`haiku\` family" "orchestrator brief names the chosen plan model"
assert_contains "$out" "sample-feature-plan-N (claude-haiku-4-5) / sample-feature-audit-N (opus) / sample-feature-rev-N (opus)" "report names the chosen models; the auditor runs on the review model"
assert_contains "$(cat "$run2/orchestrator.md")" "\`sample-feature-audit-N\` (\`opus\`)" "orchestrator brief names the auditor on the review model"
jq '.status = "failed"' "$run2/run.json" > "$run2/tmp.json" && mv "$run2/tmp.json" "$run2/run.json"
assert_exit 1 "$HERD/scripts/launch.sh" --resume sample-feature --worker-model sonnet
: > "$FAKE_HERDR_LOG"; out="$("$HERD/scripts/launch.sh" --resume sample-feature 2>&1)"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "--timeout 120000 -- --model opus --permission-mode" "resume restarts the orchestrator on the pinned model"
assert_contains "$(cat "$run2/orchestrator.md")" "must be the \`haiku\` family" "resume re-renders with the pinned plan model"

# execution flag: validated, pinned in the ledger, rendered into the orchestrator brief, frozen on resume
r3="$(make_repo)"; cd "$r3"; run3="$r3/.claude/herd-runs/sample-feature"
out="$("$HERD/scripts/launch.sh" --dry-run --execution subagent "$plan" 2>&1)"
assert_contains "$out" "DRY-RUN: execution=subagent" "dry-run prints the chosen execution mode"
assert_contains "$("$HERD/scripts/launch.sh" --dry-run --execution native "$plan" 2>&1)" "execution=linear" "native is an alias of linear"
assert_contains "$("$HERD/scripts/launch.sh" --dry-run --execution sub-agent "$plan" 2>&1)" "execution=subagent" "sub-agent is an alias of subagent"
assert_exit 1 "$HERD/scripts/launch.sh" --execution parallel "$plan"
assert_exit 1 "$HERD/scripts/launch.sh" --execution --slug x "$plan"
assert_exit 1 "$HERD/scripts/launch.sh" "$plan" --execution
assert_no_file "$run3/run.json" "a rejected execution mode launches nothing"
out="$("$HERD/scripts/launch.sh" --execution subagent "$plan" 2>&1)"
assert_eq "$(jq -r .execution "$run3/run.json")" subagent "chosen execution mode pinned"
assert_contains "$(cat "$run3/orchestrator.md")" "Plan execution: \`subagent\`" "orchestrator brief names the chosen execution mode"
assert_contains "$out" "execution     subagent" "report names the chosen execution mode"
jq '.status = "failed"' "$run3/run.json" > "$run3/tmp.json" && mv "$run3/tmp.json" "$run3/run.json"
assert_exit 1 "$HERD/scripts/launch.sh" --resume sample-feature --execution linear
out="$("$HERD/scripts/launch.sh" --resume sample-feature 2>&1)"
assert_contains "$(cat "$run3/orchestrator.md")" "Plan execution: \`subagent\`" "resume re-renders with the pinned execution mode"
assert_contains "$out" "execution     subagent" "resume report names the pinned execution mode"
# a run launched before the flag existed has no .execution: it resumes as linear
jq 'del(.execution) | .status = "failed"' "$run3/run.json" > "$run3/tmp.json" && mv "$run3/tmp.json" "$run3/run.json"
out="$("$HERD/scripts/launch.sh" --resume sample-feature 2>&1)"
assert_contains "$(cat "$run3/orchestrator.md")" "Plan execution: \`linear\`" "a pre-flag ledger resumes as linear"

# a ledger from before the audit stage: resume backfills .audit, never after a started review
r4="$(make_repo)"; cd "$r4"; run4="$r4/.claude/herd-runs/sample-feature"
plan2=docs/superpowers/plans/2026-09-05-sample-feature-phase-2-api.md
printf '# Sample Feature — Phase 2: API — Implementation Plan\n' > "$plan2"
"$HERD/scripts/launch.sh" "$plan" "$plan2" >/dev/null 2>&1
jq '.plans |= map(del(.audit)) | .status = "failed" | .plans[0].plan.status = "done" | .plans[0].review.status = "running"' \
  "$run4/run.json" > "$run4/tmp.json" && mv "$run4/tmp.json" "$run4/run.json"
"$HERD/scripts/launch.sh" --dry-run --resume sample-feature >/dev/null 2>&1
assert_eq "$(jq -r '.plans[0] | has("audit")' "$run4/run.json")" false "dry-run resume leaves the ledger alone"
"$HERD/scripts/launch.sh" --resume sample-feature >/dev/null 2>&1
assert_eq "$(jq -r '.plans[0].audit.status' "$run4/run.json")" skipped "resume skips the audit of a plan whose review already started"
assert_eq "$(jq -r '.plans[1].audit.status' "$run4/run.json")" pending "resume backfills a pending audit for a plan not yet reviewed"
assert_eq "$(jq -r '.plans[1].audit.agent' "$run4/run.json")" sample-feature-audit-2 "backfilled audit agent name"
assert_eq "$(jq -r '.plans[0].review.status' "$run4/run.json")" running "backfill leaves existing stages untouched"
before="$(jq -c '.plans' "$run4/run.json")"
jq '.status = "failed"' "$run4/run.json" > "$run4/tmp.json" && mv "$run4/tmp.json" "$run4/run.json"
"$HERD/scripts/launch.sh" --resume sample-feature >/dev/null 2>&1
assert_eq "$(jq -c '.plans' "$run4/run.json")" "$before" "backfill is idempotent"
cd "$r"

# Guard (spec §5.4): no engine script may resolve a path out of the ledger's herd_dir.
# Reading it for display is fine; using it to build a path is the bug this prevents.
bad="$(grep -nE '\$\(.*ledger.*get.*\.herd_dir|L "?\.herd_dir' "$HERD/scripts/"*.sh || true)"
assert_eq "$bad" "" "no script resolves from the ledger's herd_dir"

# D16: the launcher's own report and the orchestrator template must name /execute-plans.
assert_eq "$(grep -c 'herd-plans' "$HERD/scripts/launch.sh" || true)" "0" "launch.sh names no /herd-plans"
assert_eq "$(grep -c 'herd-plans' "$HERD/templates/orchestrator.tmpl.md" || true)" "0" "orchestrator template names no /herd-plans"
assert_contains "$(cat "$HERD/scripts/launch.sh")" "/execute-plans --resume" "launch.sh report names /execute-plans"

finish
