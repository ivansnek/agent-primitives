#!/usr/bin/env bash
# usage: bash tests/test-loop-brainstorm.sh
# loop.sh brainstorm commands: unit-start/restart, the outbox/inbox protocol, ADR numbering,
# the bs.done gate, archive, and the brainstormer brief.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
export HERD_START_RETRY_SECONDS=0 HERD_POLL_SECONDS=0

# ---- the brief's cases ----------------------------------------------------------
use_fake_herdr; r="$(make_repo)"; run="$(make_loop_run "$r")"; L() { "$LOOP/scripts/loop.sh" "$run" "$@"; }
u="$run/units/eng-12"; mkdir -p "$u"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-start ENG-12          # no issue.md yet
printf '# Title with {{FOO}} and "quotes"\n' > "$u/issue.md"
brief="$(L unit-start ENG-12)"
assert_eq "$brief" "$u/brief.md" "brief path"
assert_eq "$(grep -c '{{' "$brief" || true)" "0" "no placeholder left, hostile title never rendered in"
assert_contains "$(cat "$brief")" "$u/issue.md" "brief points at the issue file"
assert_contains "$(cat "$brief")" "superpowers:brainstorming" "brief names the skill"
assert_contains "$(cat "$brief")" "never commit" "brief forbids git writes"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "Bash(git commit:*)" "git commit denied to the brainstormer"
assert_contains "$(cat "$brief")" "kind: question | approaches | playback | breakdown | spec-ready" "brief states the outbox kinds"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent start eng-1-loop-bs-eng-12 --kind claude" "brainstormer started"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "--label bs-eng-12" "own tab"
assert_eq "$(L unit ENG-12 | jq -r '.phase + " " + .session_id + " " + .base')" "brainstorming sess-test-1 dev" "unit recorded"
# outbox protocol + Review Focus 3
assert_eq "$(L outbox-next ENG-12)" "NONE" "empty outbox"
mkdir -p "$u/outbox"; printf 'kind: question\nWhich DB?\n' > "$u/outbox/01.md"
assert_eq "$(L outbox-next ENG-12)" "ASK 01 question $u/outbox/01.md" "unanswered message"
printf 'ANSWER: postgres\n' > "$r/a.md"; L inbox-write ENG-12 01 "$r/a.md" >/dev/null
assert_eq "$(L outbox-next ENG-12)" "PENDING-DELIVERY 01 $u/inbox/01.md" "answered but not delivered survives a crash"
L inbox-delivered ENG-12 01; assert_eq "$(L outbox-next ENG-12)" "NONE" "delivered"
printf 'no kind line\n' > "$u/outbox/02.md"; assert_contains "$(L outbox-next ENG-12)" "ASK 02 unknown" "missing kind"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" inbox-write ENG-12 07 "$r/a.md"
# Review Focus 4: ADR numbering
assert_eq "$(L adr-next)" "0001" "no adr dir anywhere"
wt="$(jq -r .design_worktree "$run/run.json")"; mkdir -p "$wt/docs/adr" "$r/docs/adr"
: > "$wt/docs/adr/0003-a.md"; : > "$r/docs/adr/0005-b.md"; : > "$r/docs/adr/README.md"
assert_eq "$(L adr-next)" "0006" "max of stack tip and main drafts, plus one"
# check-bs gate
out="$(L check-bs ENG-12)" && rc=0 || rc=$?; assert_eq "$rc" 3 "no sentinel"
spec=docs/superpowers/specs/2026-09-04-sample-feature-design.md; plan=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md
printf 'model: claude-fable-5-2\nspec: %s\nplan: %s\nadrs: docs/adr/0005-b.md\n' "$spec" "$plan" > "$u/bs.done"
assert_eq "$(L check-bs ENG-12)" "DONE" "gate passes"
assert_eq "$(L unit ENG-12 | jq -r '.spec + " " + .plan + " " + .adrs[0]')" "$spec $plan docs/adr/0005-b.md" "paths recorded"
assert_file "$u/artifacts/$spec" "spec archived"; assert_file "$u/artifacts/docs/adr/0005-b.md" "adr archived"
assert_eq "$(L outbox-next ENG-12)" "DONE" "sentinel wins over outbox"
printf 'model: claude-sonnet-5-5\nspec: %s\nplan: %s\nadrs: none\n' "$spec" "$plan" > "$u/bs.done"
out="$(L check-bs ENG-12)" && rc=0 || rc=$?; assert_eq "$rc" 2 "wrong model family fails"
printf 'model: fable\nspec: %s\nplan: %s\nadrs: docs/adr/0009-nope.md\n' "$spec" "$plan" > "$u/bs.done"
assert_contains "$(L check-bs ENG-12 || true)" "NONE adr-missing: docs/adr/0009-nope.md" "missing adr"
printf '# plan without the spec path\n' > "$r/docs/superpowers/plans/x.md"
printf 'model: fable\nspec: %s\nplan: docs/superpowers/plans/x.md\nadrs: none\n' "$spec" > "$u/bs.done"
assert_contains "$(L check-bs ENG-12 || true)" "NONE plan-does-not-cite-spec" "plan must cite its spec"
# epic-design: no plan
mkdir -p "$run/units/eng-10"; printf 'model: fable\nspec: %s\nplan: none\nadrs: none\n' "$spec" > "$run/units/eng-10/bs.done"
assert_eq "$(L check-bs ENG-10)" "DONE" "epic-design passes without a plan"
# restart limit
printf '{"result":{"agents":[]}}\n' > "$FAKE_HERDR_STATE/agents.json"
L restart ENG-12 >/dev/null; L restart ENG-12 >/dev/null
out="$(L restart ENG-12)" && rc=0 || rc=$?; assert_eq "$out $rc" "RESTART-LIMIT 6" "two restarts, then refuse"
assert_eq "$(L bump ENG-12 context)" "1" "recovery counter"

# ---- helpers --------------------------------------------------------------------
fresh() {
  use_fake_herdr; r="$(make_repo)"; run="$(make_loop_run "$r")"; u="$run/units/eng-12"
  wt="$r/.claude/worktrees/eng-1-loop-design"; mkdir -p "$u"; printf '# t\n' > "$u/issue.md"
}
led() { jq -r "$1" "$run/run.json"; }
edit() { jq "$@" "$run/run.json" > "$run/t" && mv "$run/t" "$run/run.json"; }
err() { "$LOOP/scripts/loop.sh" "$run" "$@" 2>&1 || true; }
out_rc() { local o rc=0; o="$("$LOOP/scripts/loop.sh" "$run" "$@" 2>/dev/null)" || rc=$?; printf '%s|%s' "$o" "$rc"; }
logged() { grep -c -- "$1" "$FAKE_HERDR_LOG" || true; }
live() { printf '{"result":{"agents":[{"name":"eng-1-loop-bs-eng-12"}]}}\n' > "$FAKE_HERDR_STATE/agents.json"; }

# ---- unit-start -----------------------------------------------------------------
fresh; rm "$u/issue.md"
assert_contains "$(err unit-start ENG-12)" "herd: error: loop: write the issue snapshot first: $u/issue.md" "no issue.md"
printf '# t\n' > "$u/issue.md"; live
assert_contains "$(err unit-start ENG-12)" "loop: eng-1-loop-bs-eng-12 is already live" "live agent refused"
assert_eq "$(logged 'tab create')" 0 "no tab for a live agent"
rm "$FAKE_HERDR_STATE/agents.json"
# the design worktree is reset to the stack tip; stale sentinels go; stdout is the path alone
git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m two
git -C "$r" branch feat/eng-10; edit '.stack_tip = "feat/eng-10"'
mkdir -p "$wt/junk/deep"; : > "$wt/junk/deep/f"; : > "$u/bs.done"; : > "$u/bs.failed"
assert_eq "$(L unit-start eng-12)" "$u/brief.md" "stdout is the brief path only, even when clean removes files"
assert_no_file "$wt/junk" "untracked files cleaned"
assert_eq "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$r" rev-parse feat/eng-10)" "worktree at the stack tip"
assert_eq "$(git -C "$wt" rev-parse --abbrev-ref HEAD)" HEAD "worktree detached"
assert_no_file "$u/bs.done" "stale done removed"; assert_no_file "$u/bs.failed" "stale failed removed"
assert_file "$r/.env.local" "main checkout untouched"
assert_eq "$(L unit ENG-12 | jq -r '.base + " " + .pane + " " + .tab')" "feat/eng-10 wT:p2 wT:t2" "pane, tab and base recorded"
start="$(grep 'agent start' "$FAKE_HERDR_LOG")"
assert_eq "$(grep -o -- '--disallowedTools' <<<"$start" | wc -l | tr -d ' ')" 1 "one --disallowedTools list"
for p in 'git push' 'git commit' 'git add' 'git checkout' 'git switch' 'git stash' 'git reset'; do
  assert_contains "$start" "Bash($p:*)" "$p denied"
done
assert_contains "$start" "--model fable --permission-mode bypassPermissions" "brainstorm model"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab create --workspace wL --cwd $wt --label bs-eng-12 --no-focus" "tab in the design worktree"
# a start failure leaves no tab and no phase change
fresh; : > "$FAKE_HERDR_STATE/agent-start-fails"
assert_contains "$(err unit-start ENG-12)" "loop: could not start eng-1-loop-bs-eng-12" "start failure"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab close wT:t2" "stranded tab closed"
assert_eq "$(led '.units[1].phase')" pending "phase unchanged"
# an unknown stack tip is refused before anything is reset
fresh; edit '.stack_tip = "no-such-branch"'; : > "$wt/canary"
assert_contains "$(err unit-start ENG-12)" "loop: stack tip" "unknown tip"; assert_file "$wt/canary"

# inherited git environment cannot redirect the reset to another checkout
fresh; : > "$r/canary"
GIT_DIR="$r/.git" GIT_WORK_TREE="$r" L unit-start ENG-12 >/dev/null
assert_file "$r/canary" "GIT_DIR ignored"; assert_eq "$(git -C "$r" rev-parse --abbrev-ref HEAD)" dev "main still on dev"

# ---- design worktree refusals: nothing destructive may run anywhere else ---------
fresh; mkdir -p "$r/sub"; : > "$r/canary"; : > "$r/sub/canary"
other="$(make_repo)"; : > "$other/canary"; ln -s "$r" "$r.link"
for bad in "" "$r" "$r/" "$r/sub" "$r/.claude" "$other" "$r.link" "$r/missing"; do
  edit --arg w "$bad" '.design_worktree = $w'
  assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-start ENG-12
  assert_contains "$(err unit-start ENG-12)" "herd: error: loop: design worktree" "refused: '$bad'"
done
assert_file "$r/canary" "root canary survives"; assert_file "$r/sub/canary"; assert_file "$other/canary"
assert_file "$r/.env.local"; assert_eq "$(logged 'tab create')" 0 "no tab on refusal"
assert_eq "$(git -C "$r" rev-parse --abbrev-ref HEAD)" dev "main checkout not detached"
# the main checkout is refused even when the run's root is itself a linked worktree
edit --arg w "$r" --arg root "$wt" '.design_worktree = $w | .root = $root'
assert_contains "$(err unit-start ENG-12)" "herd: error: loop: design worktree" "main checkout refused from a linked root"
assert_file "$r/canary"

# another linked worktree of this repo (a herd unit's, say) is not the design worktree
fresh; herd_wt="$r/.claude/worktrees/eng-9"
git -C "$r" worktree add -q -b feat/eng-9 "$herd_wt" dev; : > "$herd_wt/fix.txt"
L ledger set-str .design_worktree "$herd_wt"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-start ENG-12
assert_contains "$(err unit-start ENG-12)" "herd: error: loop: design worktree is not this run's" "other linked worktree refused"
assert_file "$herd_wt/fix.txt" "herd worktree's untracked file survives"
assert_eq "$(git -C "$herd_wt" rev-parse --abbrev-ref HEAD)" feat/eng-9 "herd worktree stays on its branch"
assert_eq "$(logged 'tab create')" 0 "no tab on refusal"

# ---- the brief ------------------------------------------------------------------
fresh; mkdir -p "$run/units/eng-10/artifacts" "$run/units/eng-11/artifacts"; printf 'r {{X}}\n' > "$run/rulings.md"
b="$(cat "$(L unit-start ENG-12)")"
assert_contains "$b" "$run/units/eng-10/artifacts" "earlier unit's artifacts listed"
assert_not_contains "$b" "$run/units/eng-11/artifacts" "later unit's artifacts not listed"
assert_contains "$b" "gets a plan, however small the ticket" "every issue unit gets a plan"
assert_contains "$b" "ADRs already there, in both folders" "ADR format source"
assert_contains "$b" "$run/rulings.md" "rulings by path"
for s in "$u/outbox" "$u/inbox" "$u/bs.done" "$u/bs.failed" "$r/docs/superpowers/specs" "$r/docs/superpowers/plans" \
  "$r/docs/adr" "$wt/docs/adr" "0001" "$LOOP/templates/adr.default.md" "superpowers:writing-plans" \
  "caveman:caveman" "model-mismatch" "/compact" "visual companion" "spike" "builder check" "subagent" \
  "advisor's call" "Architecture decisions" "blocked_by" "earlier slices" "LAST action" "untracked" \
  "read-only" "must contain the spec's repo-relative path" "Never ask in the terminal" "Do not offer or start execution" \
  "plan is not sent for approval" "status to accepted" "adrs: <comma-separated"; do
  assert_contains "$b" "$s" "brief states $s"
done
fresh; mkdir -p "$run/units/eng-10"; printf '# e\n' > "$run/units/eng-10/issue.md"
b="$(cat "$(L unit-start ENG-10)")"
assert_eq "$(grep -c '{{' <<<"$b" || true)" 0 "epic brief fully rendered"
assert_contains "$b" "plan: none" "epic: no plan"
assert_contains "$b" "Do not invoke \`superpowers:writing-plans\`" "epic: no writing-plans"
assert_eq "$(grep -A1 "Earlier units' artifacts:" <<<"$b" | tail -1)" none "no earlier artifacts"

# ---- outbox / inbox hostile input -----------------------------------------------
fresh; mkdir -p "$u/outbox" "$u/inbox"; c="$r/pwned"
printf 'kind: $(touch %s)\n' "$c" > "$u/outbox/01.md"
assert_eq "$(L outbox-next ENG-12)" "ASK 01 unknown $u/outbox/01.md" "hostile kind"
printf 'kind: spec-ready\r\n' > "$u/outbox/09.md"; : > "$u/outbox/99 x.md"; : > "$u/outbox/zz.md"; : > "$u/outbox/100.md"
assert_eq "$(L outbox-next ENG-12)" "ASK 09 spec-ready $u/outbox/09.md" "highest NN.md only; CRLF tolerated"
: > "$u/outbox/10.md"; assert_eq "$(L outbox-next ENG-12)" "ASK 10 unknown $u/outbox/10.md" "empty file"
for nn in 1 ../x 001 "a[\$(touch $c)]"; do
  assert_contains "$(err inbox-write ENG-12 "$nn" "$u/issue.md")" "loop: message number must be two digits" "bad NN $nn"
  assert_exit 1 "$LOOP/scripts/loop.sh" "$run" inbox-delivered ENG-12 "$nn"
done
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" inbox-delivered ENG-12 09
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" inbox-write ENG-12 09 "$r/nope.md"
assert_eq "$(L inbox-write ENG-12 09 "$u/issue.md")" "$u/inbox/09.md" "inbox path printed"
assert_eq "$(ls -A "$u/inbox")" "09.md" "no temp file left"
# a rewritten answer has not been delivered, whatever happened to the one it replaces
L inbox-delivered ENG-12 10 2>/dev/null || true
L inbox-write ENG-12 10 "$u/issue.md" >/dev/null; L inbox-delivered ENG-12 10
assert_eq "$(L outbox-next ENG-12)" "NONE" "delivered answer"
printf 'correction\n' > "$r/fix.md"; L inbox-write ENG-12 10 "$r/fix.md" >/dev/null
assert_eq "$(L outbox-next ENG-12)" "PENDING-DELIVERY 10 $u/inbox/10.md" "rewrite is pending again"
assert_no_file "$u/inbox/10.delivered" "stale delivery marker removed"
: > "$u/bs.failed"; : > "$u/bs.done"; assert_eq "$(L outbox-next ENG-12)" "FAILED" "failed wins"
assert_no_file "$c" "nothing executed"

# ---- adr-next --------------------------------------------------------------------
fresh; mkdir -p "$r/docs/adr"; : > "$r/docs/adr/0008-a.md"; : > "$r/docs/adr/12345-x.md"; : > "$r/docs/adr/0099.md"
assert_eq "$(L adr-next)" "0009" "leading zeros are decimal; only NNNN-*.md count"
printf '{"version":1,"adrDir":"decisions"}' > "$r/.claude/linear-loop.config.json"; mkdir -p "$wt/decisions"; : > "$wt/decisions/0010-b.md"
assert_eq "$(L adr-next)" "0011" "configured adrDir"

# ---- check-bs gate ----------------------------------------------------------------
fresh; spec=docs/superpowers/specs/2026-09-04-sample-feature-design.md
plan=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md
sent() { printf 'model: %s\nspec: %s\nplan: %s\nadrs: %s\n' "${4:-Fable 5}" "$1" "$2" "$3" > "$u/bs.done"; }
printf 'on screen\n' > "$FAKE_HERDR_STATE/screen.txt"
assert_eq "$(out_rc check-bs ENG-12)" "NONE"$'\n'"on screen|3" "no sentinel shows the screen"
printf 'model: fable\nreason: stuck $(x)\n' > "$u/bs.failed"; sent "$spec" "$plan" none
assert_eq "$(out_rc check-bs ENG-12)" "FAILED"$'\n''model: fable'$'\n''reason: stuck $(x)|2' "failed wins, text shown"
rm "$u/bs.failed"
cp "$run/run.json" "$r/before.json"
sent "$spec" "$plan" none claude-opus-5-5; assert_eq "$(out_rc check-bs ENG-12)" "FAILED model-mismatch|2" "mismatch text"
printf 'model: fable\nspec: %s\nplan: %s\n' "$spec" "$plan" > "$u/bs.done"
assert_eq "$(out_rc check-bs ENG-12)" "NONE bad-sentinel|3" "missing key"
mkdir -p "$r/docs/adr"; : > "$r/docs/adr/0001-a.md"; : > "$r/outside.md"; printf '%s\n' "$spec" > "$r/outside-plan.md"
ln -s "$r/outside.md" "$r/docs/superpowers/specs/link.md"; ln -s "$r" "$r/docs/superpowers/specs/dir"
for s in none "$r/$spec" docs/superpowers/specs/../../../outside.md outside.md docs/superpowers/specs/link.md \
  docs/superpowers/specs/dir/outside.md docs/superpowers/specs/nope.md docs/superpowers/specs; do
  sent "$s" "$plan" none; assert_eq "$(out_rc check-bs ENG-12)" "NONE spec-missing|3" "spec rejected: $s"
done
for p in none "$r/$plan" docs/superpowers/plans/../../../outside-plan.md outside-plan.md; do
  sent "$spec" "$p" none; assert_eq "$(out_rc check-bs ENG-12)" "NONE plan-missing|3" "plan rejected: $p"
done
for a in "$r/docs/adr/0001-a.md" docs/adr/../../outside.md outside.md 'docs/adr/*.md' 'docs/adr/0001-a.md, ../x'; do
  sent "$spec" "$plan" "$a"; assert_contains "$(out_rc check-bs ENG-12)" "NONE adr-missing: " "adr rejected: $a"
done
# the why is quoted into a prompt: its foreign part keeps only [A-Za-z0-9 ._/:-], anything else is _
sent "$spec" "$plan" 'docs/adr/$(id)`w`"q";é.md'
assert_eq "$(out_rc check-bs ENG-12)" 'NONE adr-missing: docs/adr/__id__w__q____.md|3' "adr-missing why is restricted to safe characters"
sent "$spec" "$plan" "docs/adr/a\\b'c{d}.md"
assert_eq "$(out_rc check-bs ENG-12)" 'NONE adr-missing: docs/adr/a_b_c_d_.md|3' "backslash, quote and braces replaced"
c="$r/pwned"; sent "\$(touch $c)" "$plan" none; L check-bs ENG-12 >/dev/null || true; assert_no_file "$c" "nothing executed"
if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "a refused sentinel changed the ledger"; fi
sent "$spec" none none; assert_eq "$(out_rc check-bs ENG-12)" "NONE plan-missing|3" "issue needs a plan"
mkdir -p "$run/units/eng-10"; printf 'model: fable\nspec: %s\nplan: %s\nadrs: none\n' "$spec" "$plan" > "$run/units/eng-10/bs.done"
assert_eq "$(out_rc check-bs ENG-10)" "NONE unexpected-plan|3" "epic-design takes no plan"
: > "$r/docs/adr/0002-b.md"; sent "$spec" "$plan" 'docs/adr/0001-a.md, docs/adr/0002-b.md'; L unit-set ENG-12 .phase '"spec-review"'
assert_eq "$(L check-bs ENG-12)" DONE "two adrs"
assert_eq "$(L unit ENG-12 | jq -c '[.adrs, .phase]')" '[["docs/adr/0001-a.md","docs/adr/0002-b.md"],"spec-review"]' "adrs recorded, phase left alone"
printf 'model: fable\nspec: %s\nplan: none\nadrs: none\n' "$spec" > "$run/units/eng-10/bs.done"; L check-bs ENG-10 >/dev/null
assert_eq "$(L unit ENG-10 | jq -c '[.plan, .adrs]')" '[null,[]]' "epic: null plan"

# ---- archive ----------------------------------------------------------------------
printf '# changed\n' > "$r/$spec"; L archive ENG-12
assert_eq "$(cat "$u/artifacts/$spec")" "# changed" "archive overwrites"
assert_file "$u/artifacts/$plan"; assert_file "$u/artifacts/docs/adr/0002-b.md"
for s in ../outside.md "$r/outside.md" docs/superpowers/specs/../../../outside.md docs/superpowers/specs/link.md; do
  L unit-set-str ENG-12 .spec "$s"
  assert_contains "$(err archive ENG-12)" "herd: error: loop: cannot archive" "archive refuses $s"
done

# ---- restart, finish-agent, bump, herd pass-throughs --------------------------------
fresh; assert_contains "$(err restart ENG-12)" "loop: ENG-12 has no pane" "restart before start"
L unit-start ENG-12 >/dev/null; : > "$wt/keep"; : > "$u/bs.failed"; : > "$u/bs.done"; rm "$u/brief.md"; : > "$FAKE_HERDR_LOG"
assert_eq "$(L restart ENG-12)" "$u/brief.md" "restart prints the brief"
assert_file "$u/brief.md"; assert_file "$wt/keep" "restart leaves the worktree alone"
assert_no_file "$u/bs.failed"; assert_no_file "$u/bs.done"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "--pane wT:p2 --timeout 120000 -- --resume sess-test-1 --model fable" "resumed in the same pane"
assert_eq "$(grep -o -- '--disallowedTools' "$FAKE_HERDR_LOG" | wc -l | tr -d ' ')" 1 "restart: one list"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "Bash(git reset:*)" "restart keeps the denials"
assert_eq "$(led '.units[1].restarts')" 1 "restart counted"
# resume fails, fresh works
real="$HERDR_BIN"; printf '#!/usr/bin/env bash\ncase "$*" in "agent start"*--resume*) printf "%%s\\n" "$*" >> "$FAKE_HERDR_LOG"; exit 1 ;; esac\nexec "%s" "$@"\n' "$real" > "$r/herdr"; chmod +x "$r/herdr"
: > "$FAKE_HERDR_LOG"; HERDR_BIN="$r/herdr" L restart ENG-12 >/dev/null 2>&1
assert_contains "$(grep 'agent start' "$FAKE_HERDR_LOG" | tail -1)" "-- --model fable" "fresh session after a failed resume"
assert_eq "$(led '.units[1].restarts')" 2 "counted"
fresh; L unit-start ENG-12 >/dev/null; live; : > "$u/bs.done"
assert_contains "$(err restart ENG-12)" "loop: could not exit eng-1-loop-bs-eng-12" "an agent that will not exit"
assert_eq "$(led '.units[1].restarts')" 0 "not counted"
: > "$FAKE_HERDR_LOG"; L finish-agent ENG-12 2>/dev/null
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt eng-1-loop-bs-eng-12 /exit" "agent exited"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "tab close wT:t2" "tab closed"
assert_eq "$(L bump ENG-12 api_error) $(L bump ENG-12 api_error)" "1 2" "bump counts"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" bump ENG-12 'x"]|.slug="y'
assert_eq "$(led .slug)" eng-1-loop "counter is not jq code"
assert_eq "$(L prompt-wait eng-1-loop-bs-eng-12 'go')" "SETTLED idle" "prompt-wait"
assert_eq "$(L wait eng-1-loop-bs-eng-12)" "SETTLED idle" "wait"
assert_eq "$(out_rc wait nobody)" "GONE|4" "wait exit code"
printf 'scr\n' > "$FAKE_HERDR_STATE/screen.txt"; assert_eq "$(L screen eng-1-loop-bs-eng-12 5)" scr "screen"
L keys eng-1-loop-bs-eng-12 esc enter; assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent send-keys eng-1-loop-bs-eng-12 esc enter" "keys"
for c in unit-start outbox-next "inbox-write ENG-12 01" "inbox-delivered ENG-12" prompt-wait wait screen "keys x" "bump ENG-12" restart check-bs archive finish-agent; do
  assert_contains "$(err $c)" "herd: error: loop: usage: loop.sh RUN_DIR ${c%% *}" "missing argument: $c"
done
finish
