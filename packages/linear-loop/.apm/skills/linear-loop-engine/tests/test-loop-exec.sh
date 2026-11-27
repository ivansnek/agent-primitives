#!/usr/bin/env bash
# usage: bash tests/test-loop-exec.sh
# loop.sh execution: exec, exec-resume, herd-status, unit-done (and its cleanup), unit-skip.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
export HERD_POLL_SECONDS=0

# ---- the brief's cases ----------------------------------------------------------
use_fake_herdr; r="$(make_repo)"; run="$(make_loop_run "$r")"; L() { "$LOOP/scripts/loop.sh" "$run" "$@"; }
spec=docs/superpowers/specs/2026-09-04-sample-feature-design.md; plan=docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md
mkdir -p "$r/docs/adr"; printf '# 0001\n' > "$r/docs/adr/0001-x.md"; printf '# epic\n' > "$r/docs/superpowers/specs/epic.md"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" exec ENG-12                        # no spec/plan yet
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" exec ENG-10                        # epic-design never executes
L unit-set ENG-10 . "$(L unit ENG-10 | jq '.phase="done" | .spec="docs/superpowers/specs/epic.md"')"
L unit-set ENG-12 . "$(L unit ENG-12 | jq --arg s "$spec" --arg p "$plan" '.spec=$s | .plan=$p | .adrs=["docs/adr/0001-x.md"]')"
L ledger set .herd '{"worker_model":"opus","review_model":null,"execution":"subagent"}'
out="$(L exec ENG-12)"; wt="$r/.claude/worktrees/eng-12"
assert_eq "$out" "HERD-RUN $r/.claude/herd-runs/eng-12/run.json ORCH eng-12-orch" "exec line"
assert_eq "$(jq -r '.base + " " + .models.plan + " " + .execution' "$r/.claude/herd-runs/eng-12/run.json")" "dev opus subagent" "base and herd flags passed through"
assert_eq "$(jq -r .models.review "$r/.claude/herd-runs/eng-12/run.json")" "sonnet" "unset herd flag keeps herd's default"
assert_file "$wt/docs/adr/0001-x.md" "ADR carried into the worktree"; assert_file "$wt/$spec" "spec carried"
assert_file "$wt/docs/superpowers/specs/epic.md" "epic design carried by the first executing child"
assert_eq "$(L unit ENG-10 | jq -r .carried_by)" "ENG-12" "carried_by recorded"
assert_eq "$(L unit ENG-12 | jq -r '.phase + " " + .branch')" "executing feat/eng-12" "unit recorded"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" exec ENG-12                        # branch exists now: herd refuses, loop passes it on
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-done ENG-12                   # herd run not done
# simulate the plan worker's commit, then Review Focus 5
git -C "$wt" add -A && git -C "$wt" -c user.email=t@t -c user.name=t commit -qm work
jq '.status="done"' "$r/.claude/herd-runs/eng-12/run.json" > "$r/t" && mv "$r/t" "$r/.claude/herd-runs/eng-12/run.json"
printf 'tracked\n' > "$r/docs/adr/0002-tracked.md"; git -C "$r" add docs/adr/0002-tracked.md; git -C "$r" -c user.email=t@t -c user.name=t commit -qm t
printf 'ignored/\n' > "$r/.gitignore"; mkdir -p "$r/ignored"; printf 'i\n' > "$r/ignored/0003.md"; printf 'n\n' > "$r/docs/adr/0004-not-on-branch.md"
L unit-set ENG-12 .adrs '["docs/adr/0001-x.md","docs/adr/0002-tracked.md","ignored/0003.md","docs/adr/0004-not-on-branch.md"]'
assert_eq "$(L unit-done ENG-12)" "DONE feat/eng-12" "unit done"
assert_eq "$(jq -r .stack_tip "$run/run.json")" "feat/eng-12" "stack tip advanced"
assert_no_file "$r/docs/adr/0001-x.md" "untracked copy that reached the branch is removed"
assert_no_file "$r/$spec" "spec copy removed"; assert_no_file "$r/docs/superpowers/specs/epic.md" "carried epic design removed"
assert_file "$r/docs/adr/0002-tracked.md" "tracked file kept"; assert_file "$r/ignored/0003.md" "ignored file kept"
assert_file "$r/docs/adr/0004-not-on-branch.md" "file that never reached the branch kept"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt eng-12-orch /exit" "finished herd orchestrator exited"
# next unit stacks on it; skip reports dependents
L unit-set ENG-11 .blocked_by '["ENG-12"]'
assert_eq "$(L unit-skip ENG-12)" "DEPENDENTS ENG-11" "dependents listed"
assert_eq "$(L unit-done ENG-10)" "DONE feat/eng-12" "epic-design done leaves the stack tip alone"
assert_eq "$(L herd-status ENG-11)" "missing" "no herd run yet"

# ---- helpers --------------------------------------------------------------------
fresh() {                    # a loop with ENG-12 ready to execute, ENG-10's design done
  use_fake_herdr; r="$(make_repo)"; run="$(make_loop_run "$r")"; wt="$r/.claude/worktrees/eng-12"; hj="$r/.claude/herd-runs/eng-12/run.json"
  mkdir -p "$r/docs/adr"; printf '# 0001\n' > "$r/docs/adr/0001-x.md"; printf '# epic\n' > "$r/docs/superpowers/specs/epic.md"
  printf '# epic adr\n' > "$r/docs/adr/0009-epic.md"
  L unit-set ENG-10 . "$(L unit ENG-10 | jq '.phase="done" | .spec="docs/superpowers/specs/epic.md" | .adrs=["docs/adr/0009-epic.md"]')"
  L unit-set ENG-12 . "$(L unit ENG-12 | jq --arg s "$spec" --arg p "$plan" '.spec=$s | .plan=$p | .adrs=["docs/adr/0001-x.md"]')"
}
commit_wt() { git -C "$wt" add -A && git -C "$wt" -c user.email=t@t -c user.name=t commit -qm work; }
herd_done() { jq '.status="done"' "$hj" > "$r/t" && mv "$r/t" "$hj"; }
led() { jq -r "$1" "$run/run.json"; }
err() { "$LOOP/scripts/loop.sh" "$run" "$@" 2>&1 || true; }
logged() { cat "$run/orchestrator.log"; }

# ---- exec refuses before launching ----------------------------------------------
fresh
for bad in ../outside.md "$r/$spec" docs/superpowers/specs/missing.md docs/superpowers/specs/../../../x.md; do
  L unit-set-str ENG-12 .spec "$bad"
  assert_contains "$(err exec ENG-12)" "herd: error: loop: cannot carry" "exec refuses spec $bad"
done
L unit-set-str ENG-12 .spec "$spec"; L unit-set-str ENG-10 .spec docs/superpowers/specs/gone.md
assert_contains "$(err exec ENG-12)" "herd: error: loop: cannot carry docs/superpowers/specs/gone.md" "epic design checked too"
assert_no_file "$hj" "nothing launched"; assert_eq "$(led '.units[1].phase')" pending "nothing recorded"

# ---- a failed launch: exit code and herd's line pass through --------------------
fresh; L ledger set-str .stack_tip nope; cp "$run/run.json" "$r/before.json"
assert_contains "$(err exec ENG-12)" "herd: error: base ref not found: nope" "herd's error line"
if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "failed launch recorded something"; fi
assert_eq "$(L exec ENG-12 2>/dev/null || true)" "" "nothing on stdout when herd fails"
assert_contains "$(err exec-resume ENG-12)" "herd: error: no run ledger at" "resume passes herd's error on"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" exec-resume ENG-12

# ---- carry: copy-if-missing, only done and uncarried epics ----------------------
fresh; mkdir -p "$r/docs/adr"; printf 'base\n' > "$r/docs/adr/0001-x.md"
git -C "$r" add docs/adr/0001-x.md; git -C "$r" -c user.email=t@t -c user.name=t commit -qm adr
printf 'draft\n' > "$r/docs/adr/0001-x.md"; L unit-set ENG-10 .phase '"spec-review"'
L exec ENG-12 >/dev/null 2>&1
assert_eq "$(cat "$wt/docs/adr/0001-x.md")" "base" "an existing file in the worktree is not overwritten"
assert_no_file "$wt/docs/superpowers/specs/epic.md" "unfinished epic design not carried"
assert_eq "$(led '.units[0].carried_by')" null "not marked carried"
assert_eq "$(led '.units[1].herd_slug')" eng-12 "herd slug recorded"
assert_eq "$(jq -r '.models.plan + " " + .execution' "$hj")" "sonnet linear" "no herd flags when .herd is null"
: > "$FAKE_HERDR_LOG"
assert_eq "$(L exec-resume ENG-12 2>/dev/null)" "HERD-RUN $hj ORCH eng-12-orch" "exec-resume line"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt eng-12-orch Resume the herd run" "herd resumed"
assert_eq "$(L herd-status ENG-12)" "created" "status, no failed stage"
jq '.status="failed" | .failed_stage="plan-1"' "$hj" > "$r/t" && mv "$r/t" "$hj"
assert_eq "$(L herd-status eng-12)" "failed plan-1" "status and failed stage"
assert_contains "$(err unit-done ENG-12)" "herd: error: loop: ENG-12: herd run is not done (failed)" "unit-done needs done"
fresh; L unit-set-str ENG-10 .carried_by ENG-11; L exec ENG-12 >/dev/null 2>&1
assert_no_file "$wt/docs/superpowers/specs/epic.md" "already carried: not copied again"
assert_eq "$(led '.units[0].carried_by')" ENG-11 "carrier unchanged"

# a symlinked directory on the branch must not lead a copy out of the worktree
fresh; mkdir -p "$r/elsewhere"; git -C "$r" checkout -q -b linked
ln -s "$r/elsewhere" "$r/docs/link"; git -C "$r" add docs/link; git -C "$r" -c user.email=t@t -c user.name=t commit -qm link
git -C "$r" checkout -q dev; mkdir -p "$r/docs/link"; printf 'a\n' > "$r/docs/link/0002.md"
printf '{"version":1,"adrDir":"docs/link"}' > "$r/.claude/linear-loop.config.json"
L ledger set-str .stack_tip linked; L unit-set ENG-12 .adrs '["docs/link/0002.md"]'; L unit-set ENG-10 .adrs '[]'
assert_eq "$(L exec ENG-12 2>/dev/null)" "HERD-RUN $hj ORCH eng-12-orch" "launched run is still reported"
assert_no_file "$r/elsewhere/0002.md" "no write through the symlink"
assert_contains "$(logged)" "not carried docs/link/0002.md" "failed copy logged"
assert_eq "$(led '.units[1].phase')" executing "unit recorded despite the failed copy"

# ---- cleanup keeps everything it cannot prove safe ------------------------------
fresh; printf 'ignored-adr.md\n' > "$r/.gitignore"; L exec ENG-12 >/dev/null 2>&1
for f in same differs ignored-adr tracked Case; do printf '%s\n' "$f" > "$wt/docs/adr/$f.md"; cp "$wt/docs/adr/$f.md" "$r/docs/adr/$f.md"; done
mkdir -p "$(dirname "$wt/$plan")"; cp "$r/$plan" "$wt/$plan"
git -C "$wt" add -f -A && git -C "$wt" -c user.email=t@t -c user.name=t commit -qm work; herd_done
printf 'later edit\n' >> "$r/docs/adr/differs.md"
git -C "$r" add docs/adr/tracked.md
mv "$r/docs/adr/Case.md" "$r/docs/adr/case.md"; git -C "$r" add docs/adr/case.md
printf 'out\n' > "$r/outside.md"; ln -s "$r/outside.md" "$r/docs/adr/link.md"
L unit-set ENG-12 .adrs "$(jq -nc --arg abs "$r/docs/adr/same.md" '["docs/adr/differs.md","docs/adr/ignored-adr.md","docs/adr/tracked.md",
  "docs/adr/Case.md",$abs,"docs/adr/../adr/same.md","../outside.md","outside.md","docs/adr/link.md","docs/adr/missing.md"]')"
assert_eq "$(L unit-done ENG-12 2>/dev/null)" "DONE feat/eng-12" "keeps are not failures"
for f in differs ignored-adr tracked same; do assert_file "$r/docs/adr/$f.md" "$f kept"; done
assert_file "$r/docs/adr/case.md" "a tracked file named in another case is kept"
assert_file "$r/outside.md" "nothing outside the allowed dirs"; assert_file "$r/docs/adr/link.md" "symlink kept"
assert_contains "$(logged)" "kept docs/adr/differs.md: differs from feat/eng-12" "differs"
assert_contains "$(logged)" "kept docs/adr/ignored-adr.md: ignored" "ignored"
assert_contains "$(logged)" "kept docs/adr/tracked.md: tracked" "tracked"
assert_contains "$(logged)" "kept docs/adr/../adr/same.md: not a regular file under" "dot-dot"
assert_contains "$(logged)" "kept $r/docs/adr/same.md: not a regular file under" "absolute"
assert_contains "$(logged)" "kept ../outside.md: not a regular file under" "parent"
assert_contains "$(logged)" "kept docs/adr/missing.md: not a regular file under" "missing"
assert_no_file "$r/$plan" "an unchanged plan that reached the branch is removed"
assert_contains "$(logged)" "deleted $r/$plan" "deletion logged"
assert_contains "$(logged)" "deleted $r/docs/superpowers/specs/epic.md" "carried spec deleted"
assert_no_file "$r/docs/adr/0009-epic.md" "carried epic ADR removed"

# any git failure means keep
for broken in ls-files check-ignore cat-file rev-parse hash-object; do
  fresh; L exec ENG-12 >/dev/null 2>&1; commit_wt; herd_done
  mkdir -p "$r/shim"; printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" != %s ] || exit 128; done\nexec "%s" "$@"\n' "$broken" "$(command -v git)" > "$r/shim/git"; chmod +x "$r/shim/git"
  out="$(PATH="$r/shim:$PATH" L unit-done ENG-12 2>/dev/null)"
  assert_eq "$out" "DONE feat/eng-12" "unit done with broken git $broken"
  assert_file "$r/$spec" "kept when git $broken fails"; assert_file "$r/docs/adr/0001-x.md" "kept when git $broken fails (adr)"
  assert_contains "$(logged)" "kept $spec: " "keep logged ($broken)"
done

# running unit-done again must not move the stack back
fresh; L exec ENG-12 >/dev/null 2>&1; commit_wt; herd_done; L unit-done ENG-12 >/dev/null
L ledger set-str .stack_tip feat/eng-11
assert_eq "$(L unit-done ENG-12)" "DONE feat/eng-11" "second unit-done changes nothing"
assert_eq "$(led .stack_tip)" feat/eng-11 "stack tip stays"
fresh; mkdir -p "$(dirname "$hj")"; printf '{"status":"done"}' > "$hj"
assert_contains "$(err unit-done ENG-12)" "herd: error: loop: ENG-12 has not been executed" "a leftover herd run is not this unit's"

# ---- a launch that failed half way: exec-resume records the unit --------------------
fresh; : > "$FAKE_HERDR_STATE/agent-start-fails"
assert_contains "$(err exec ENG-12)" "retry with --resume eng-12" "herd asks for a resume"
assert_file "$hj" "herd left its run behind"
assert_eq "$(led '.units[1] | .phase + " " + (.branch | tostring)')" "pending null" "failed launch records nothing"
assert_contains "$(err exec ENG-12)" "herd: error: branch already exists" "exec cannot run again"
cp "$run/run.json" "$r/before.json"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" exec-resume ENG-12
if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "failed resume recorded something"; fi
assert_no_file "$wt/$spec" "failed resume carries nothing"
rm "$FAKE_HERDR_STATE/agent-start-fails"
assert_eq "$(L exec-resume eng-12 2>/dev/null)" "HERD-RUN $hj ORCH eng-12-orch" "resume line"
assert_eq "$(led '.units[1] | .phase + " " + .branch + " " + .herd_slug')" "executing feat/eng-12 eng-12" "resume records the unit"
assert_file "$wt/$spec" "resume carries the spec"; assert_file "$wt/docs/adr/0001-x.md" "and the ADR"
assert_file "$wt/docs/superpowers/specs/epic.md" "and the pending epic design"
assert_file "$wt/docs/adr/0009-epic.md" "and its ADR"
assert_eq "$(led '.units[0].carried_by')" ENG-12 "resume sets carried_by"
commit_wt; herd_done
assert_eq "$(L unit-done ENG-12 2>/dev/null)" "DONE feat/eng-12" "unit-done after a resumed launch"
assert_no_file "$r/$spec" "and cleans up"; assert_no_file "$r/docs/superpowers/specs/epic.md" "carried design too"

# a recorded unit is only resumed: no carry, no ledger write
fresh; L exec ENG-12 >/dev/null 2>&1; rm "$wt/$spec"; L unit-set ENG-12 .phase '"failed"'; cp "$run/run.json" "$r/before.json"
assert_eq "$(L exec-resume ENG-12 2>/dev/null)" "HERD-RUN $hj ORCH eng-12-orch" "recorded unit resumes"
if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "resume of a recorded unit wrote the ledger"; fi
assert_no_file "$wt/$spec" "recorded unit: nothing carried again"

# an unrecorded unit that exec would refuse, or that is finished, is not resumed at all
refused() {                  # JQ_PATH JSON MESSAGE
  fresh; : > "$FAKE_HERDR_STATE/agent-start-fails"; L exec ENG-12 >/dev/null 2>&1 || true
  rm "$FAKE_HERDR_STATE/agent-start-fails"; L unit-set ENG-12 "$1" "$2"
  cp "$run/run.json" "$r/before.json"; : > "$FAKE_HERDR_LOG"
  assert_contains "$(err exec-resume ENG-12)" "herd: error: loop: $3" "exec-resume refuses $1=$2"
  if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "refused resume wrote the ledger ($1=$2)"; fi
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "agent start" "herd not resumed ($1=$2)"
}
refused .kind '"epic-design"' "ENG-12 is not an issue unit"
refused .spec null "ENG-12 needs a spec and a plan"
refused .plan null "ENG-12 needs a spec and a plan"
refused .spec '"../x.md"' "cannot carry ../x.md"
refused .phase '"done"' "ENG-12 is done"
refused .phase '"skipped"' "ENG-12 is skipped"

# ---- killed before the ledger write: herd's run is adopted without --resume ---------
killed() {                   # a launched herd run the loop ledger knows nothing about
  fresh; cp "$run/run.json" "$r/unrecorded.json"; L exec ENG-12 >/dev/null 2>&1
  cp "$r/unrecorded.json" "$run/run.json"; rm "$wt/$spec" "$wt/docs/adr/0001-x.md" "$wt/docs/superpowers/specs/epic.md"
  : > "$FAKE_HERDR_LOG"
}
orch_live() { printf '{"result":{"agents":[{"name":"eng-12-orch"}]}}\n' > "$FAKE_HERDR_STATE/agents.json"; }
adopted() {                  # STATE
  assert_eq "$(L exec-resume eng-12 2>/dev/null || true)" "HERD-RUN $hj ORCH eng-12-orch" "$1: same line"
  assert_eq "$(led '.units[1] | .phase + " " + .branch + " " + .herd_slug')" "executing feat/eng-12 eng-12" "$1: recorded"
  assert_file "$wt/$spec" "$1: spec carried"; assert_file "$wt/docs/adr/0001-x.md" "$1: ADR carried"
  assert_file "$wt/docs/superpowers/specs/epic.md" "$1: epic design carried"
  assert_eq "$(led '.units[0].carried_by')" ENG-12 "$1: carried_by"
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "agent start" "$1: herd not resumed"
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "tab create" "$1: no new tab"
}
killed; orch_live; adopted "live orchestrator"
rm "$FAKE_HERDR_STATE/agents.json"; commit_wt; herd_done
assert_eq "$(L unit-done ENG-12 2>/dev/null || true)" "DONE feat/eng-12" "unit-done after adopting a live run"
killed; herd_done; adopted "finished run"
commit_wt
assert_eq "$(L unit-done ENG-12 2>/dev/null || true)" "DONE feat/eng-12" "unit-done after adopting a finished run"
killed; herd_done; orch_live; adopted "finished run, orchestrator still up"

# a leftover run under the same slug is never recorded, whatever its state
for field in '.base="other"' '.plans[0].path="/elsewhere/plan.md"' '.plans += .plans' 'del(.plans)' garbage; do
  for state in live done idle; do
    killed
    if [ "$field" = garbage ]; then printf 'not json' > "$hj"; else jq "$field" "$hj" > "$r/t" && mv "$r/t" "$hj"; fi
    case "$state" in live) orch_live ;; done) [ "$field" = garbage ] || herd_done ;; esac
    cp "$run/run.json" "$r/before.json"
    assert_contains "$(err exec-resume ENG-12)" "herd: error: loop: ENG-12: the herd run at $hj is not this unit's" "mismatch $field $state"
    if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "mismatched run recorded ($field $state)"; fi
    assert_no_file "$wt/$spec" "mismatch carries nothing ($field $state)"
    assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "agent start" "mismatch not resumed ($field $state)"
  done
done
# the existing refusals come first
for change in '.phase "done" ENG-12 is done' '.phase "skipped" ENG-12 is skipped' '.kind "epic-design" ENG-12 is not an issue unit' '.spec null ENG-12 needs a spec' '.adrs ["docs/adr/gone.md"] cannot carry docs/adr/gone.md'; do
  read -r path value message <<<"$change"
  killed; orch_live; L unit-set ENG-12 "$path" "$value"; cp "$run/run.json" "$r/before.json"
  assert_contains "$(err exec-resume ENG-12)" "herd: error: loop: $message" "live run, refused: $change"
  if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "refused adoption wrote the ledger ($change)"; fi
done

# ---- a failed herd run leaves its orchestrator live: exec-resume exits it first ------------
herd_failed() { jq '.status="failed" | .failed_stage="plan-1"' "$hj" > "$r/t" && mv "$r/t" "$hj"; }
exits_ok() {                 # a herdr whose eng-12-orch goes away on /exit
  printf '#!/usr/bin/env bash\ncase "$*" in "agent prompt eng-12-orch /exit") rm -f "$FAKE_HERDR_STATE/agents.json" ;; esac\nexec "%s" "$@"\n' \
    "$TESTS_DIR/fake-herdr" > "$r/herdr"; chmod +x "$r/herdr"
}
line_of() { { grep -nF -- "$1" "$FAKE_HERDR_LOG" || true; } | head -1 | cut -d: -f1; }
exited_then_resumed() {      # LABEL: /exit sent to eng-12-orch, then herd's resume started it again
  local x s
  x="$(line_of "agent prompt eng-12-orch /exit")"; s="$(line_of "agent start eng-12-orch")"
  if [ -n "$x" ] && [ -n "$s" ] && [ "$x" -lt "$s" ]; then pass; else fail "$1: no /exit before the resume (exit '${x}', start '${s}')"; fi
  assert_contains "$(cat "$FAKE_HERDR_LOG")" "agent prompt eng-12-orch Resume the herd run" "$1: herd resumed"
}
# recorded unit (the exec-failed "continue" path)
fresh; L exec ENG-12 >/dev/null 2>&1; herd_failed; orch_live; exits_ok; : > "$FAKE_HERDR_LOG"
assert_eq "$(HERDR_BIN="$r/herdr" L exec-resume ENG-12 2>/dev/null || true)" "HERD-RUN $hj ORCH eng-12-orch" "failed + live: resumed"
exited_then_resumed "recorded, failed, live"
# the orchestrator will not exit: no blind resume, a loop: error, nothing written
fresh; L exec ENG-12 >/dev/null 2>&1; herd_failed; orch_live; cp "$run/run.json" "$r/before.json"; : > "$FAKE_HERDR_LOG"
out="$(err exec-resume ENG-12)"
assert_contains "$out" "herd: error: loop: ENG-12: the failed herd run's orchestrator eng-12-orch did not exit" "exit failure is a loop error"
assert_not_contains "$out" "still live" "herd's resume was not called"
assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "agent start" "no resume after a failed exit"
if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "failed exit wrote the ledger"; fi
# not failed: a live orchestrator is never exited, herd refuses as before
fresh; L exec ENG-12 >/dev/null 2>&1; orch_live; : > "$FAKE_HERDR_LOG"
assert_contains "$(err exec-resume ENG-12)" "herd: error: agent eng-12-orch is still live" "running + live: herd refuses"
assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "/exit" "running + live: not exited"
# unrecorded unit: exited and resumed only once every refusal check has passed
killed; herd_failed; orch_live; exits_ok
assert_eq "$(HERDR_BIN="$r/herdr" L exec-resume ENG-12 2>/dev/null || true)" "HERD-RUN $hj ORCH eng-12-orch" "unrecorded, failed + live: same line"
exited_then_resumed "unrecorded, failed, live"
assert_eq "$(led '.units[1] | .phase + " " + .branch')" "executing feat/eng-12" "unrecorded, failed + live: recorded"
assert_contains "$(logged)" "executing ENG-12 on feat/eng-12 (resumed)" "recorded as resumed, not adopted"
killed; herd_failed; orch_live; cp "$run/run.json" "$r/before.json"
assert_contains "$(err exec-resume ENG-12)" "herd: error: loop: ENG-12: the failed herd run's orchestrator eng-12-orch did not exit" "unrecorded: exit failure is a loop error"
assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "agent start" "unrecorded: no resume after a failed exit"
if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "unrecorded: failed exit wrote the ledger"; fi
for change in '.phase "done" ENG-12 is done' '.spec null ENG-12 needs a spec' '.kind "epic-design" ENG-12 is not an issue unit'; do
  read -r path value message <<<"$change"
  killed; herd_failed; orch_live; exits_ok; L unit-set ENG-12 "$path" "$value"
  assert_contains "$(HERDR_BIN="$r/herdr" err exec-resume ENG-12)" "herd: error: loop: $message" "failed + live, refused first: $change"
  assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "/exit" "refused: orchestrator not exited ($change)"
done
killed; jq '.base="other" | .status="failed"' "$hj" > "$r/t" && mv "$r/t" "$hj"; orch_live; exits_ok
assert_contains "$(HERDR_BIN="$r/herdr" err exec-resume ENG-12)" "is not this unit's" "failed + live, not this unit's run: refused"
assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "/exit" "not this unit's run: orchestrator not exited"

# ---- unit-skip ------------------------------------------------------------------
fresh; L exec ENG-12 >/dev/null 2>&1
assert_eq "$(L unit-skip eng-12)" "DEPENDENTS" "empty line still printed"
assert_eq "$(led '.units[1].phase + " " + .stack_tip')" "skipped dev" "skipped, stack unchanged"
assert_eq "$(led '.units[0].carried_by')" null "a skipped carrier gives the epic design back"
fresh; L unit-set ENG-11 .blocked_by '["ENG-12"]'; L unit-set ENG-11 .parent null
assert_eq "$(L unit-skip ENG-10)" "DEPENDENTS ENG-12" "children only"
assert_eq "$(L unit-skip ENG-12)" "DEPENDENTS ENG-11" "blocked_by"
L unit-set ENG-11 .phase '"done"'; assert_eq "$(L unit-skip ENG-12)" "DEPENDENTS" "finished units are not dependents"
# transitive through units: ENG-11 under ENG-12 under ENG-10
fresh; L unit-set-str ENG-11 .parent ENG-12
assert_eq "$(L unit-skip ENG-10)" "DEPENDENTS ENG-12 ENG-11" "grandchildren, in order"

# ---- a collapsed parent (ENG-15: no unit, between ENG-12 and the epic) ------------
collapsed() { fresh; L unit-set-str ENG-12 .parent ENG-15; L unit-set-str ENG-11 .parent ENG-12; }
map() { printf '{"given":["ENG-10"],"issues":[{"id":"eng-15","parent":"eng-10"},{"id":"ENG-12","parent":"ENG-15"}]}' > "$run/map.json"; }
collapsed; map; L exec ENG-12 >/dev/null 2>&1
assert_file "$wt/docs/superpowers/specs/epic.md" "epic design carried through a collapsed parent"
assert_file "$wt/docs/adr/0009-epic.md" "and its ADR"
assert_eq "$(led '.units[0].carried_by')" ENG-12 "carried_by through a collapsed parent"
collapsed; map; assert_eq "$(L unit-skip ENG-10)" "DEPENDENTS ENG-12 ENG-11" "descendants through a collapsed parent"
collapsed; L exec ENG-12 >/dev/null 2>&1
assert_no_file "$wt/docs/superpowers/specs/epic.md" "no map: the chain ends at the collapsed parent"
assert_eq "$(led '.units[1].phase')" executing "no map is tolerated"
for body in absent 'not json' '[]' '{"issues":[3,{"id":"ENG-15"}]}' '{"issues":[{"id":"ENG-15","parent":"ENG-12"}]}'; do
  collapsed; [ "$body" = absent ] || printf '%s' "$body" > "$run/map.json"
  assert_eq "$(L unit-skip ENG-10)" "DEPENDENTS" "tolerated map: $body"
done

for c in exec exec-resume herd-status unit-done unit-skip; do
  assert_contains "$(err $c)" "herd: error: loop: usage: loop.sh RUN_DIR $c" "missing argument: $c"
done
finish
