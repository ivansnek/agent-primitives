#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
use_fake_herdr
export HERD_POLL_SECONDS=0
r="$(make_repo)"; cd "$r"
mkdir -p "$r/.claude"
printf '{"version":1,"disallowedTools":["Bash(pnpm db:reset)"],"planStyle":"caveman mode is on for this test"}\n' > "$r/.claude/herd.config.json"
plan=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md
"$HERD/scripts/launch.sh" "$plan" >/dev/null 2>&1
run="$r/.claude/herd-runs/sample-feature"; wt="$r/.claude/worktrees/sample-feature"
S() { "$HERD/scripts/stage.sh" "$run" "$@"; }
rc() { local c=0; "$HERD/scripts/stage.sh" "$run" "$@" >/dev/null 2>&1 || c=$?; echo "$c"; }

# stage.sh implements every command the orchestrator template documents
for c in spawn-plan spawn-audit spawn-review prompt-wait wait check screen keys restart finish-agent fail done note bump ledger; do
  assert_contains "$(grep -E "^  $c\)" "$HERD/scripts/stage.sh" || true)" "$c)" "stage.sh implements $c"
done
assert_exit 1 "$HERD/scripts/stage.sh" "$run" nonsense
assert_exit 1 "$HERD/scripts/stage.sh" "$run" spawn-plan 2

# spawn-plan clears stale sentinels and refuses a live agent
printf 'model: x\nreason: stale\n' > "$run/plan-1.failed"
printf '{"result":{"agents":[{"name":"sample-feature-plan-1"}]}}' > "$FAKE_HERDR_STATE/agents.json"
assert_exit 1 "$HERD/scripts/stage.sh" "$run" spawn-plan 1
rm "$FAKE_HERDR_STATE/agents.json"
brief="$(S spawn-plan 1)"
assert_no_file "$run/plan-1.failed" "spawn removes a stale failed sentinel"
assert_eq "$brief" "$run/plan-1.brief.md" "spawn-plan prints the brief path"
assert_file "$brief"
assert_not_contains "$(cat "$brief")" "{{" "brief fully rendered"
assert_contains "$(cat "$brief")" "Plan: \`$wt/$plan\`" "brief points at the worktree plan"
log="$(cat "$FAKE_HERDR_LOG")"
assert_contains "$log" "tab create --workspace wT --cwd $wt --label plan-1 --no-focus" "plan tab created in the run workspace"
assert_contains "$log" "agent start sample-feature-plan-1 --kind claude --pane wT:p2 --timeout 120000 -- --model sonnet --permission-mode bypassPermissions --disallowedTools Bash(git push) Bash(git push:*) Bash(pnpm db:reset)" "plan worker uses sonnet + disallowed tools"
assert_contains "$log" "--append-system-prompt-file $run/plan-append.txt" "plan worker gets its system-prompt append as a file, not inline"
assert_file "$run/plan-append.txt" "spawn writes the plan append file"
assert_contains "$(cat "$run/plan-append.txt")" "caveman mode" "plan append file holds the style text"
assert_contains "$(cat "$run/plan-append.txt")" "Plan execution: \`linear\`" "plan append file pins the execution mode past /compact"
assert_contains "$(cat "$brief")" "Plan execution: \`linear\`" "a default run briefs the worker in linear mode"
assert_contains "$(cat "$brief")" "superpowers:executing-plans" "linear brief names the inline skill"
assert_not_contains "$(cat "$brief")" "Execute the plan with \`superpowers:subagent-driven-development\`" "linear brief does not mandate SDD"
# The pane must be at its interactive shell prompt before herdr types the claude command into it.
wait_line="$(grep -n 'pane wait-output wT:p2' "$FAKE_HERDR_LOG" | head -1 | cut -d: -f1)"
start_line="$(grep -n 'agent start sample-feature-plan-1' "$FAKE_HERDR_LOG" | head -1 | cut -d: -f1)"
ordered=no; [ -n "$wait_line" ] && [ -n "$start_line" ] && [ "$wait_line" -lt "$start_line" ] && ordered=yes
assert_eq "$ordered" yes "spawn waits for the shell prompt before typing the claude command"
assert_eq "$(jq -r '.plans[0].plan.status' "$run/run.json")" running
assert_eq "$(jq -r '.plans[0].plan.pane' "$run/run.json")" wT:p2
assert_eq "$(jq -r '.plans[0].plan.tab' "$run/run.json")" wT:t2
assert_eq "$(jq -r '.plans[0].plan.session_id' "$run/run.json")" sess-test-1
assert_eq "$(jq -r '.plans[0].plan.attempts' "$run/run.json")" 1
assert_eq "$(jq -r '.plans[0].plan.head_before' "$run/run.json")" "$(git -C "$wt" rev-parse HEAD)"
assert_eq "$(jq -r '.status' "$run/run.json")" running "spawn marks the run running"

# prompt-wait / wait
assert_eq "$(rc prompt-wait sample-feature-plan-1 hi)" 4 "prompt-wait GONE when the agent is not live"
printf '{"result":{"agents":[{"name":"sample-feature-plan-1"}]}}' > "$FAKE_HERDR_STATE/agents.json"
assert_eq "$(S prompt-wait sample-feature-plan-1 "hi there" 1000)" "SETTLED idle"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt sample-feature-plan-1 hi there --wait --until idle --until done --until blocked --timeout 1000"
assert_eq "$(S wait sample-feature-plan-1 500)" "SETTLED idle"
touch "$FAKE_HERDR_STATE/stall"
assert_eq "$(rc prompt-wait sample-feature-plan-1 /cost)" 7 "prompt-wait reports STALLED on agent_prompt_stalled"
assert_eq "$(S prompt-wait sample-feature-plan-1 /cost 2>/dev/null || true)" "STALLED"
rm "$FAKE_HERDR_STATE/stall"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent wait sample-feature-plan-1 --until idle --until done --until blocked --timeout 500"

# check: no sentinel -> NONE + screen
printf 'some screen\n' > "$FAKE_HERDR_STATE/screen.txt"
out="$(S check 1 plan)" && c=0 || c=$?
assert_eq "$c" 3; assert_contains "$out" "NONE"; assert_contains "$out" "some screen"
# .done with the right model but a dirty tree -> NONE dirty-tree
printf 'model: claude-sonnet-5\nhead: x\n' > "$run/plan-1.done"; printf 'x\n' > "$wt/new.txt"
out="$(S check 1 plan)" && c=0 || c=$?
assert_eq "$c" 3; assert_contains "$out" "NONE dirty-tree"
# committed -> DONE
git -C "$wt" add -A; git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "feat(sample-feature): phase 1"
out="$(S check 1 plan)" && c=0 || c=$?
assert_eq "$c" 0; assert_eq "$out" "DONE $(git -C "$wt" rev-parse HEAD)"
assert_eq "$(jq -r '.plans[0].plan.status' "$run/run.json")" done
assert_eq "$(jq -r '.plans[0].plan.head_after' "$run/run.json")" "$(git -C "$wt" rev-parse HEAD)"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show herd sample-feature: plan 1/1 done --body security audit next" "check notifies on DONE; the audit comes next"

# spawn-review
out="$(S spawn-review 1)"
assert_contains "$out" "$run/review-1.brief.md"
assert_contains "$out" "RANGE $(jq -r '.plans[0].plan.head_before' "$run/run.json")..HEAD"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab create --workspace wT --cwd $wt --label review-1 --no-focus"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent start sample-feature-rev-1 --kind claude --pane wT:p3 --timeout 120000 -- --model sonnet --permission-mode bypassPermissions" "reviewer uses sonnet"
rev_start="$(grep 'agent start sample-feature-rev-1' "$FAKE_HERDR_LOG")"
assert_not_contains "$rev_start" "--append-system-prompt" "reviewer does NOT get the caveman append"
assert_contains "$(cat "$run/review-1.brief.md")" "$(jq -r '.plans[0].plan.head_before' "$run/run.json")..HEAD" "review brief carries the range"
assert_contains "$(cat "$run/review-1.brief.md")" "$HERD/review-standards.default.md" "review brief points at the standards in the main checkout"
assert_contains "$(cat "$run/review-1.brief.md")" "$run/review-1.findings.md" "review brief points at the findings file in the run dir"
assert_contains "$(cat "$run/review-1.brief.md")" "none configured -> n/a" "review brief carries the fallback verification when no testCommand is set"
assert_eq "$(jq -r '.plans[0].review.tab' "$run/run.json")" wT:t3
# review .done with wrong model -> FAILED + run failed
printf 'model: claude-opus-5\nhead: y\n' > "$run/review-1.done"
out="$(S check 1 review)" && c=0 || c=$?
assert_eq "$c" 2 "model mismatch fails"; assert_eq "$(jq -r .status "$run/run.json")" failed; assert_eq "$(jq -r .failed_stage "$run/run.json")" "review-1:model-mismatch"
# fix the sentinel: review done needs no new commit
printf 'model: claude-sonnet-5\nhead: y\n' > "$run/review-1.done"
jq '.status = "running" | .failed_stage = null' "$run/run.json" > "$run/t.json" && mv "$run/t.json" "$run/run.json"
out="$(S check 1 review)" && c=0 || c=$?
assert_eq "$c" 0 "review done without a new commit is fine"
# .failed sentinel
printf 'model: claude-sonnet-5\nreason: broken\n' > "$run/plan-1.failed"; rm "$run/plan-1.done"
jq '.plans[0].plan.status = "running"' "$run/run.json" > "$run/t.json" && mv "$run/t.json" "$run/run.json"
out="$(S check 1 plan)" && c=0 || c=$?
assert_eq "$c" 2; assert_contains "$out" "FAILED"; assert_contains "$out" "reason: broken"
rm "$run/plan-1.failed"

# bump / note / ledger
assert_eq "$(S bump 1 plan api_error)" 1; assert_eq "$(S bump 1 plan api_error)" 2
assert_eq "$(S ledger get '.plans[0].plan.recovery.api_error')" 2
S note "hello world"; assert_contains "$(cat "$run/orchestrator.log")" "hello world"
S ledger set '.prep.status' '"done"'; assert_eq "$(jq -r .prep.status "$run/run.json")" done
S ledger set-str '.failed_stage' 'x y'; assert_eq "$(jq -r .failed_stage "$run/run.json")" "x y"

# screen / keys
assert_eq "$(S screen sample-feature-plan-1)" "some screen"
S screen sample-feature-plan-1 40 >/dev/null
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent read sample-feature-plan-1 --source recent-unwrapped --lines 40"
S keys sample-feature-plan-1 down enter
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent send-keys sample-feature-plan-1 down enter"

# restart: resumes the recorded session in the same pane, twice at most
rm "$FAKE_HERDR_STATE/agents.json"
assert_eq "$(S restart 1 plan)" "$run/plan-1.brief.md"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent start sample-feature-plan-1 --kind claude --pane wT:p2 --timeout 120000 -- --resume sess-test-1 --model sonnet" "restart resumes the session"
assert_contains "$(grep -- '--resume sess-test-1' "$FAKE_HERDR_LOG")" "--append-system-prompt-file $run/plan-append.txt" "restart re-applies the system-prompt append"
assert_eq "$(jq -r '.plans[0].plan.restarts' "$run/run.json")" 1
S restart 1 plan >/dev/null
assert_eq "$(rc restart 1 plan)" 6 "third restart refused"

# finish-agent closes the tab recorded for that agent
S finish-agent sample-feature-rev-1
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent send-keys sample-feature-rev-1 esc" "finish-agent closes dialogs before /exit"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt sample-feature-rev-1 /exit"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab close wT:t3"

# fail / done
S fail plan-1 "boom"
assert_eq "$(jq -r .status "$run/run.json")" failed; assert_eq "$(jq -r .failed_stage "$run/run.json")" plan-1
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show herd sample-feature failed at plan-1 --body boom --sound request"
S done
assert_eq "$(jq -r .status "$run/run.json")" done
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show herd sample-feature done"

# ---- re-spawn after a dead worker keeps the original range and the original sentinels honest
rm -f "$FAKE_HERDR_STATE/agents.json"
head0="$(jq -r '.plans[0].plan.head_before' "$run/run.json")"
git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "commit the worker made before dying"
S spawn-plan 1 >/dev/null
assert_eq "$(jq -r '.plans[0].plan.head_before' "$run/run.json")" "$head0" "re-spawn keeps the original head_before"

# the sentinel may echo the on-screen capitalization ("Sonnet 4.5"); the model gate is case-insensitive
printf 'model: Sonnet 4.5\nhead: z\n' > "$run/plan-1.done"
out="$(S check 1 plan)" && c=0 || c=$?
assert_eq "$c" 0 "check accepts a capitalized model name"

# restart clears the previous attempt's sentinels, exactly like spawn
S ledger set '.plans[0].plan.restarts' 0
printf 'model: claude-sonnet-5\nhead: stale\n' > "$run/plan-1.done"
printf 'model: claude-sonnet-5\nreason: stale\n' > "$run/plan-1.failed"
S restart 1 plan >/dev/null
assert_no_file "$run/plan-1.done" "restart removes a stale done sentinel"
assert_no_file "$run/plan-1.failed" "restart removes a stale failed sentinel"

# a worker that cannot start must not strand the tab spawn just created
HERD_START_RETRY_SECONDS=0 && export HERD_START_RETRY_SECONDS
touch "$FAKE_HERDR_STATE/agent-start-fails"
assert_eq "$(rc spawn-plan 1)" 1 "spawn fails when the worker cannot start"
rm "$FAKE_HERDR_STATE/agent-start-fails"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab close $(jq -r '.plans[0].plan.tab' "$run/run.json")" "spawn closes its tab when the worker cannot start"

# An unwritable append file must fail the spawn loudly. Writing it in a $( ) substitution instead
# would swallow the failure and start the worker with an empty --append-system-prompt-file.
printf 'stale\n' > "$run/plan-append.txt"; chmod 400 "$run/plan-append.txt"
err="$("$HERD/scripts/stage.sh" "$run" spawn-plan 1 2>&1 >/dev/null)" && c=0 || c=$?
chmod 600 "$run/plan-append.txt"
assert_eq "$c" 1 "spawn fails when the plan append file cannot be written"
assert_contains "$err" "could not write the plan worker's system-prompt append" "spawn says why the append file failed"

# A full model id pins the family: claude-opus-5-5 accepts "Opus 5.5" and rejects a sonnet sentinel.
S ledger set '.models.plan' '"claude-opus-5-5"'
S ledger set '.plans[0].plan.status' '"running"'
git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "opus worker commit"
printf 'model: Opus 5.5\nhead: z\n' > "$run/plan-1.done"
assert_eq "$(rc check 1 plan)" 0 "full-id model accepts the on-screen family name"
S ledger set '.status' '"running"'; S ledger set '.plans[0].plan.status' '"running"'
printf 'model: claude-sonnet-5\nhead: z\n' > "$run/plan-1.done"
assert_eq "$(rc check 1 plan)" 2 "full-id model rejects another family"

# ---- execution mode: a subagent run briefs its plan worker as an SDD controller, in the brief
# and in the system prompt, with no repo config at all (the mode is the engine's, not the profile's)
r2="$(make_repo)"; cd "$r2"
"$HERD/scripts/launch.sh" --execution subagent "$plan" >/dev/null 2>&1
run2="$r2/.claude/herd-runs/sample-feature"; wt2="$r2/.claude/worktrees/sample-feature"
: > "$FAKE_HERDR_LOG"
brief2="$("$HERD/scripts/stage.sh" "$run2" spawn-plan 1)"
assert_not_contains "$(cat "$brief2")" "{{" "subagent brief fully rendered"
assert_contains "$(cat "$brief2")" "Plan execution: \`subagent\`" "subagent run briefs the worker in subagent mode"
assert_contains "$(cat "$brief2")" "Subagents work in \`$wt2\` on branch \`feat/sample-feature\`" "subagent brief pins subagents to the run worktree"
assert_not_contains "$(cat "$brief2")" "Do NOT dispatch a subagent for any task" "subagent brief carries no linear rule"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "--append-system-prompt-file $run2/plan-append.txt" "plan worker gets the execution rules without any repo style"
assert_contains "$(cat "$run2/plan-append.txt")" "superpowers:subagent-driven-development" "append file carries the subagent rules"
assert_not_contains "$(cat "$run2/plan-append.txt")" "caveman" "no repo style, none appended"
"$HERD/scripts/stage.sh" "$run2" spawn-review 1 >/dev/null
assert_not_contains "$(grep 'agent start sample-feature-rev-1' "$FAKE_HERDR_LOG")" "--append-system-prompt" "reviewer gets no execution append"
assert_not_contains "$(cat "$run2/review-1.brief.md")" "subagent-driven-development" "review brief is the same in every execution mode"

# a ledger from before the flag has no .execution: its workers stay linear
jq 'del(.execution)' "$run2/run.json" > "$run2/t.json" && mv "$run2/t.json" "$run2/run.json"
"$HERD/scripts/stage.sh" "$run2" ledger set '.plans[0].plan.restarts' 0
brief2="$("$HERD/scripts/stage.sh" "$run2" restart 1 plan)"
assert_contains "$(cat "$brief2")" "Plan execution: \`linear\`" "a pre-flag ledger briefs linear"
assert_contains "$(cat "$run2/plan-append.txt")" "Plan execution: \`linear\`" "a pre-flag ledger appends the linear rules"
# a ledger value the engine does not know is a loud failure, not a brief with no rules
"$HERD/scripts/stage.sh" "$run2" ledger set-str .execution parallel
assert_exit 1 "$HERD/scripts/stage.sh" "$run2" ledger get .slug

# ---- security audit stage: after the plan, before the review, on the REVIEW model
r3="$(make_repo)"; cd "$r3"
"$HERD/scripts/launch.sh" --worker-model sonnet --review-model claude-opus-5-5 "$plan" >/dev/null 2>&1
run3="$r3/.claude/herd-runs/sample-feature"; wt3="$r3/.claude/worktrees/sample-feature"
S3() { "$HERD/scripts/stage.sh" "$run3" "$@"; }
rc3() { local c=0; "$HERD/scripts/stage.sh" "$run3" "$@" >/dev/null 2>&1 || c=$?; echo "$c"; }
: > "$FAKE_HERDR_LOG"; rm -f "$FAKE_HERDR_STATE/agents.json"
S3 spawn-plan 1 >/dev/null
git -C "$wt3" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "feat(sample-feature): phase 1"
printf 'model: Sonnet 5\nhead: x\n' > "$run3/plan-1.done"
assert_eq "$(rc3 check 1 plan)" 0 "plan done"
printf 'stale\n' > "$run3/audit-1.findings.md"
out="$(S3 spawn-audit 1)"
assert_no_file "$run3/audit-1.findings.md" "spawn clears a failed attempt's findings"
head0="$(jq -r '.plans[0].plan.head_before' "$run3/run.json")"
assert_contains "$out" "$run3/audit-1.brief.md" "spawn-audit prints the brief path"
assert_contains "$out" "RANGE $head0..HEAD" "audit range is the whole phase"
assert_eq "$(jq -r '.plans[0].audit.head_before' "$run3/run.json")" "$head0" "audit head_before is the plan's"
audit_start="$(grep 'agent start sample-feature-audit-1' "$FAKE_HERDR_LOG")"
assert_contains "$audit_start" "-- --model claude-opus-5-5 --permission-mode bypassPermissions" "auditor runs on the review model, not the plan model"
assert_not_contains "$audit_start" "--append-system-prompt" "auditor gets no plan-worker append"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab create --workspace wT --cwd $wt3 --label audit-1 --no-focus" "audit gets its own tab"
brief="$(cat "$run3/audit-1.brief.md")"
assert_not_contains "$brief" "{{" "audit brief fully rendered"
assert_contains "$brief" "$HERD/security-standards.default.md" "audit brief points at the default security standards"
assert_contains "$brief" "$run3/audit-1.findings.md" "audit brief findings file in the run dir"
assert_contains "$brief" "The budget is 5 slices." "audit slice budget defaults to 5"
assert_contains "$brief" "Expected model: \`claude-opus-5-5\`" "audit brief expects the review model"
assert_eq "$(jq -r '.plans[0].audit.status' "$run3/run.json")" running
# the audit's sentinel is gated on the review model's family
printf 'model: Sonnet 5\nhead: y\n' > "$run3/audit-1.done"
assert_eq "$(rc3 check 1 audit)" 2 "audit sentinel from the plan model's family is a mismatch"
assert_eq "$(jq -r .failed_stage "$run3/run.json")" "audit-1:model-mismatch"
S3 ledger set .status '"running"'
printf 'model: Opus 5.5\nhead: y\n' > "$run3/audit-1.done"
out="$(S3 check 1 audit)" && c=0 || c=$?
assert_eq "$c" 3 "an audit with no findings file is not finished"; assert_contains "$out" "NONE no-coverage"
printf 'no findings\n\nlooked fine\n' > "$run3/audit-1.findings.md"
assert_eq "$(rc3 check 1 audit)" 3 "an audit that does not record its coverage is not finished"
assert_eq "$(jq -r '.plans[0].audit.status' "$run3/run.json")" running
no_cov() {                   # LABEL: check must answer NONE no-coverage, stage still running
  local o c=0; o="$(S3 check 1 audit 2>&1)" || c=$?
  assert_eq "$c" 3 "$1"; assert_contains "$o" "NONE no-coverage:" "$1 (reason prefix)"
  assert_eq "$(jq -r '.plans[0].audit.status' "$run3/run.json")" running "$1 (still running)"
}
printf 'no findings\n\n## Coverage\n' > "$run3/audit-1.findings.md"
no_cov "a Coverage heading with nothing under it is not a record"
printf '## S1 — x\nfiles: a.ts:1\n\n## Coverage\nread whole: a.ts\n' > "$run3/audit-1.findings.md"
no_cov "a finding's files: line does not stand in for the Coverage files: line"
printf 'no findings\n\n## Coverage\nfiles: 20 — 20 runtime; 20 read whole\n' > "$run3/audit-1.findings.md"
no_cov "a Coverage record with no read whole: line is not finished"
cov20='no findings\n\n## Coverage\nfiles: 20 — 20 runtime; 3 read whole\nread whole: a.ts, b.ts, c.ts\n'
printf "$cov20" > "$run3/audit-1.findings.md"
no_cov "a sentinel without the coverage counts is not finished"
printf 'model: Opus 5.5\nhead: y\nfiles_to_read: 20\nfiles_read: 3\nfiles_over_budget: 0\n' > "$run3/audit-1.done"
no_cov "3 of 20 read with nothing over budget is not finished"
printf 'model: Opus 5.5\nhead: y\nfiles_to_read: 20\nfiles_read: $(touch pwned)\nfiles_over_budget: 0\n' > "$run3/audit-1.done"
no_cov "a non-numeric count is rejected before any arithmetic"
assert_no_file "$wt3/pwned" "a sentinel count is never evaluated"
printf 'model: Opus 5.5\nhead: y\nfiles_to_read: 20\nfiles_read: 20\nfiles_over_budget: 0\n' > "$run3/audit-1.done"
no_cov "claiming more files read than read whole: lists is not finished"
printf 'model: Opus 5.5\nhead: y\nfiles_to_read: 20\nfiles_read: 3\nfiles_over_budget: 17\n' > "$run3/audit-1.done"
out="$(S3 check 1 audit)" && c=0 || c=$?
assert_eq "$c" 0 "a clean audit needs no new commit"
assert_eq "$(jq -r '.plans[0].audit.status' "$run3/run.json")" done
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show herd sample-feature: security audit 1/1 done --body review next" "audit DONE notifies; review next"
printf 'model: Opus 5.5\nreason: broken\n' > "$run3/audit-1.failed"; rm "$run3/audit-1.done"
out="$(S3 check 1 audit)" && c=0 || c=$?
assert_eq "$c" 2 "audit failed sentinel"; assert_contains "$out" "reason: broken"
rm "$run3/audit-1.failed"
# a phase with nothing to read whole (docs only) can still finish
printf 'no findings\n\n## Coverage\nfiles: 1 — 1 inert; 0 read whole\nread whole: none\n' > "$run3/audit-1.findings.md"
printf 'model: Opus 5.5\nhead: y\nfiles_to_read: 0\nfiles_read: 0\nfiles_over_budget: 0\n' > "$run3/audit-1.done"
assert_eq "$(rc3 check 1 audit)" 0 "an empty read whole: none record passes when nothing had to be read"
rm "$run3/audit-1.done"
# the review that follows covers the audit's fixes too, and points at its findings
S3 spawn-review 1 >/dev/null
assert_contains "$(grep 'agent start sample-feature-rev-1' "$FAKE_HERDR_LOG")" "--model claude-opus-5-5" "reviewer on the review model"
assert_contains "$(cat "$run3/review-1.brief.md")" "$head0..HEAD" "review range still starts at the plan's head"
assert_contains "$(cat "$run3/review-1.brief.md")" "$run3/audit-1.findings.md" "review brief points at the audit findings"
# restart / bump / finish-agent accept the audit stage
printf 'partial\n' > "$run3/audit-1.findings.md"
assert_eq "$(S3 restart 1 audit)" "$run3/audit-1.brief.md" "restart works for the audit"
assert_file "$run3/audit-1.findings.md" "restart keeps findings the resumed session may have written"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent start sample-feature-audit-1 --kind claude --pane $(jq -r '.plans[0].audit.pane' "$run3/run.json") --timeout 120000 -- --resume sess-test-1 --model claude-opus-5-5" "audit restart keeps the review model"
S3 ledger set '.plans[0].audit.session_id' null
printf 'stale\n' > "$run3/audit-1.findings.md"
S3 restart 1 audit >/dev/null
assert_no_file "$run3/audit-1.findings.md" "a fresh restart clears the previous attempt's findings"
assert_eq "$(S3 bump 1 audit context)" 1 "bump works for the audit"
assert_eq "$(S3 bump 1 audit coverage)" 1 "the coverage counter is its own"
S3 finish-agent sample-feature-audit-1
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab close $(jq -r '.plans[0].audit.tab' "$run3/run.json")" "finish-agent closes the audit tab"
assert_exit 1 "$HERD/scripts/stage.sh" "$run3" check 1 security
# a repo's own security standards replace the default
printf '{"version":1,"securityStandards":"docs/security.md","auditMaxSlices":2}\n' > "$r3/.claude/herd.config.json"
printf '# security\n' > "$r3/docs/security.md"
S3 ledger set '.plans[0].audit.restarts' 0
S3 restart 1 audit >/dev/null
assert_contains "$(cat "$run3/audit-1.brief.md")" "$r3/docs/security.md" "audit brief uses the repo's security standards"
assert_contains "$(cat "$run3/audit-1.brief.md")" "The budget is 2 slices." "audit brief uses the repo's slice budget"
printf '{"version":1,"auditMaxSlices":"lots"}\n' > "$r3/.claude/herd.config.json"
S3 ledger set '.plans[0].audit.restarts' 0
S3 restart 1 audit >/dev/null
assert_contains "$(cat "$run3/audit-1.brief.md")" "The budget is 5 slices." "a slice budget that is not a positive integer falls back to the default"

finish
