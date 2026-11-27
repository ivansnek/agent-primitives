#!/usr/bin/env bash
# usage: bash tests/test-loop-core.sh
# loop.sh core: ledger, units, map-apply, pause, Linear marks, breakdown, run end.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
use_fake_herdr

# ---- the brief's cases ----------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; L() { "$LOOP/scripts/loop.sh" "$run" "$@"; }
assert_eq "$(L next)" "ENG-10" "next is first pending"
L unit-set eng-10 .phase '"done"'; assert_eq "$(L next)" "ENG-12" "ids are case-insensitive; next skips done"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit NOPE-1
L unit-set ENG-11 . "$(L unit ENG-11 | jq '.revisions=1')"; assert_eq "$(L unit ENG-11 | jq -r '.revisions, .id' | tr '\n' ' ')" "1 ENG-11 " "path . replaces the whole unit"
# Review Focus 2: hostile titles round-trip
t='He said "hi" & $HOME `x` {{FOO}}'; L unit-set-str ENG-12 .title "$t"
assert_eq "$(L unit ENG-12 | jq -r .title)" "$t" "title byte-exact"
assert_contains "$(cat "$run/PROGRESS.md")" '{{FOO}}' "progress renders it verbatim"
# map-apply
run2="$(make_loop_run "$r" other-loop)"; jq '.units=[] | .status="created"' "$run2/run.json" > "$run2/t" && mv "$run2/t" "$run2/run.json"
assert_eq "$("$LOOP/scripts/loop.sh" "$run2" map-apply "$LOOP/tests/fixtures/map-epic.json")" "OK 4" "map applied"
assert_eq "$(jq -r .status "$run2/run.json")" running "status running after a clean map"
assert_eq "$(jq -r '.units[1].agent' "$run2/run.json")" other-loop-bs-eng-12 "agent name"
assert_eq "$(jq -c '.units[1].linear' "$run2/run.json")" '{"started":false,"review":false,"comments":[]}' "unit defaults"
out="$("$LOOP/scripts/loop.sh" "$run2" map-apply "$LOOP/tests/fixtures/map-external.json")" && rc=0 || rc=$?
assert_eq "$rc" 3 "problems exit 3"; assert_contains "$out" "PROBLEM external ENG-50,OPS-9" "problem line"
jq '.map_only=true' "$run2/run.json" > "$run2/t" && mv "$run2/t" "$run2/run.json"
"$LOOP/scripts/loop.sh" "$run2" map-apply "$LOOP/tests/fixtures/map-epic.json" >/dev/null
assert_eq "$(jq -r .status "$run2/run.json")" mapped "map-only stops at mapped"
# pause / unpause
L unit-set ENG-12 .phase '"spec-review"'; printf 'Q?\n' > "$r/q.md"
p="$(L pause adr ENG-12 "$r/q.md")"; assert_eq "$p" "$run/pause-01.md" "pause file path"
assert_eq "$(jq -r '.status + " " + .pause.kind' "$run/run.json")" "waiting-human adr" "paused"
assert_eq "$(L unit ENG-12 | jq -r .phase)" awaiting-human "unit awaits"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show" "human notified"
L unpause; assert_eq "$(L unit ENG-12 | jq -r .phase)" spec-review "phase restored"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unpause
# linear marks are idempotent
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" linear-has ENG-12 started
L linear-mark ENG-12 started; assert_exit 0 "$LOOP/scripts/loop.sh" "$run" linear-has ENG-12 started
L linear-mark ENG-12 comment:done; L linear-mark ENG-12 comment:done
assert_eq "$(L unit ENG-12 | jq -c .linear.comments)" '["done"]' "comment tag recorded once"
# breakdown
printf '[{"id":"ENG-90","uuid":"u","title":"a","blocked_by":[]},{"id":"ENG-91","uuid":"u","title":"b","blocked_by":["ENG-90"]}]' > "$r/s.json"
assert_eq "$(L add-units ENG-11 "$r/s.json")" "OK 2" "slices added"
assert_eq "$(jq -c '[.units[] | .id]' "$run/run.json")" '["ENG-10","ENG-12","ENG-11","ENG-90","ENG-91"]' "inserted after the split unit"
assert_eq "$(L unit ENG-11 | jq -r .kind)" epic-design "split unit becomes epic-design"
assert_eq "$(L unit ENG-90 | jq -r .no_breakdown)" true "slices of a child cannot split again"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" add-units ENG-90 "$r/s.json"
printf '[{"id":"ENG-95","uuid":"u","title":"a","blocked_by":["ENG-96"]},{"id":"ENG-96","uuid":"u","title":"b","blocked_by":[]}]' > "$r/bad.json"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" add-units ENG-12 "$r/bad.json"
L ruling "Use Postgres enums, never check constraints"; assert_contains "$(cat "$run/rulings.md")" "Postgres enums" "ruling kept"

# ---- helpers --------------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"
led() { jq -r "$1" "$run/run.json"; }
snap() { cp "$run/run.json" "$r/before.json"; }
unchanged() { if cmp -s "$run/run.json" "$r/before.json"; then pass; else fail "$1: ledger changed"; fi; }
err() { "$LOOP/scripts/loop.sh" "$run" "$@" 2>&1 || true; }
stale() { jq '.updated_at="2000-01-01T00:00:00Z"' "$run/run.json" > "$run/t" && mv "$run/t" "$run/run.json"; rm -f "$run/PROGRESS.md"; }
wrote() { assert_not_contains "$(led .updated_at)" "2000-01-01" "$1: updated_at bumped"; assert_file "$run/PROGRESS.md" "$1: progress re-rendered"; }

# ---- dispatch and errors ----------------------------------------------------------
assert_contains "$("$LOOP/scripts/loop.sh" /nonexistent next 2>&1 || true)" "herd: error: loop: no ledger: /nonexistent/run.json" "no ledger"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run"
assert_contains "$(err bogus)" "loop: unknown command: bogus" "unknown command"
assert_contains "$(err unit nope-1)" "herd: error: loop: no such unit: nope-1" "unknown unit"
assert_eq "$(cd "$run/.." && "$LOOP/scripts/loop.sh" eng-1-loop next)" "ENG-10" "relative run dir"
for c in unit "unit-set ENG-12 .phase" map-apply "add-units ENG-12" "pause map -" note ruling "linear-has ENG-12" fail "ledger set .x"; do
  assert_contains "$(err $c)" "herd: error: loop: usage: loop.sh RUN_DIR ${c%% *}" "missing argument: $c"
done

# ---- ledger writes ------------------------------------------------------------------
stale; L ledger set .restarted 1; wrote "ledger set"; assert_eq "$(L ledger get .restarted)" 1 "ledger get"
stale; L ledger set-str .base 'a "b" $c'; wrote "ledger set-str"; assert_eq "$(led .base)" 'a "b" $c' "set-str verbatim"
assert_contains "$(cat "$run/PROGRESS.md")" 'a "b" $c' "progress shows the new value"
stale; L unit-set ENG-12 .revisions 2; wrote "unit-set"
stale; L unit-set-str ENG-12 .spec docs/s.md; wrote "unit-set-str"
assert_eq "$(led '.units | map(.revisions) | join(",")')" "0,2,0" "only the addressed unit changed"
snap
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-set ENG-12 .phase 'not json'
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-set ENG-12 . 'null'
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" unit-set NOPE-1 .phase '"done"'
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" ledger set .units '"oops"'
unchanged "refused writes"
assert_eq "$(ls "$run" | grep -c '^run.json')" 1 "no temp ledger left"
L unit-set ENG-10 .phase '"skipped"'; L unit-set ENG-12 .phase '"done"'; L unit-set ENG-11 .phase '"done"'
assert_eq "$(L next)" "NONE" "nothing left"
L unit-set ENG-11 .phase '"failed"'; L unit-set ENG-11 .order 0; L unit-set ENG-10 .phase '"pending"'
assert_eq "$(L next)" "ENG-11" "next follows order, not array position; failed is still open"

# ---- note and ruling ------------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; m="$r/expanded"
rm -f "$run/PROGRESS.md"; L note "saw \$(touch $m) \`touch $m\`"$'\nsecond line'
assert_eq "$(grep -c . "$run/orchestrator.log")" 1 "one log line per note"
assert_contains "$(cat "$run/orchestrator.log")" "Z saw \$(touch $m) \`touch $m\` second line" "note verbatim"
assert_contains "$(cat "$run/PROGRESS.md")" "second line" "note re-renders progress"
L ruling "keep \$(touch $m)"$'\nand more'; L ruling "second ruling"
assert_eq "$(head -1 "$run/rulings.md")" "# Human rulings" "ruling header"
assert_eq "$(grep -c '^# Human rulings' "$run/rulings.md")" 1 "header once"
assert_eq "$(grep -c '^- 20.*Z ' "$run/rulings.md")" 2 "one bullet per ruling"
assert_contains "$(cat "$run/rulings.md")" "Z keep \$(touch $m)"$'\n''  and more' "continuation lines stay inside the bullet"
assert_no_file "$m" "text never shell-expanded"
L ruling every word kept; assert_contains "$(cat "$run/rulings.md")" "Z every word kept" "unquoted ruling"
# --file: text the orchestrator did not author never reaches a command line
hostile='human ruling: `touch '"$m"'` $(touch '"$m"') "q" '"'s'"' \\ \$HOME {{X}}'
printf '%s\n' "$hostile" > "$r/reply.txt"
L note --file "$r/reply.txt"; L ruling --file "$r/reply.txt"
assert_eq "$(tail -1 "$run/orchestrator.log" | cut -d' ' -f2-)" "$hostile" "note --file: byte-exact log line"
assert_eq "$(tail -1 "$run/rulings.md" | cut -d' ' -f3-)" "$hostile" "ruling --file: byte-exact bullet"
printf 'line one\nline two\n' > "$r/multi.txt"; L ruling --file "$r/multi.txt"
assert_contains "$(cat "$run/rulings.md")" "Z line one"$'\n''  line two' "ruling --file keeps continuation lines in the bullet"
L note --file "$r/multi.txt"; assert_eq "$(tail -1 "$run/orchestrator.log" | cut -d' ' -f2-)" "line one line two" "note --file: one line"
assert_no_file "$m" "--file text never shell-expanded"
for c in note ruling fail; do
  assert_contains "$(err $c --file "$r/missing.txt")" "herd: error: loop: no text file: $r/missing.txt" "$c --file: missing file"
  assert_contains "$(err $c --file)" "herd: error: loop: usage: loop.sh RUN_DIR $c" "$c --file without a path"
  assert_contains "$(err $c --file "$r/reply.txt" extra)" "herd: error: loop: usage: loop.sh RUN_DIR $c" "$c --file with extra arguments"
done

# ---- map-apply ----------------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"
jq '.units=[] | .status="created"' "$run/run.json" > "$run/t" && mv "$run/t" "$run/run.json"
cp "$LOOP/tests/fixtures/map-external.json" "$run/map.json"; stale
out="$(L map-apply "$run/map.json")" && rc=0 || rc=$?
assert_eq "$rc" 3 "problems: source may already be RUN_DIR/map.json"
assert_eq "$out" "PROBLEM external ENG-50,OPS-9 ENG-50 is blocked by OPS-9, which is outside the run and not done" "exact problem output"
assert_eq "$(led '.status + " " + (.units | map(.id) | join(","))')" "created ENG-50" "units written, status unchanged"
wrote "map-apply with problems"
assert_eq "$(L map-apply "$LOOP/tests/fixtures/map-epic.json")" "OK 4" "re-applied"
if cmp -s "$run/map.json" "$LOOP/tests/fixtures/map-epic.json"; then pass; else fail "map copied into the run dir"; fi
assert_eq "$(jq -S '.units[1]' "$run/run.json")" "$(jq -nS '{id:"ENG-12",uuid:"u12",title:"Export schema",kind:"issue",parent:"ENG-10",blocked_by:[],order:2,
  phase:"pending",agent:"eng-1-loop-bs-eng-12",session_id:null,pane:null,tab:null,restarts:0,revisions:0,recovery:{},no_breakdown:false,
  spec:null,plan:null,adrs:[],herd_slug:null,branch:null,base:null,carried_by:null,linear:{started:false,review:false,comments:[]}}')" "full unit shape"
L map-apply "$LOOP/tests/fixtures/map-done-sibling.json" >/dev/null || true
assert_eq "$(jq -c .skipped "$run/run.json")" "$("$LOOP/scripts/order.sh" "$LOOP/tests/fixtures/map-done-sibling.json" | jq -c .skipped)" "skipped written"
snap
printf 'nope' > "$r/m.json"; assert_exit 1 "$LOOP/scripts/loop.sh" "$run" map-apply "$r/m.json"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" map-apply "$r/missing.json"
printf '{"given":["../x-1"],"issues":[{"id":"../x-1","statusType":"started"}]}' > "$r/evil.json"
assert_contains "$(err map-apply "$r/evil.json")" "loop: invalid issue id" "ids that cannot name a branch are refused"
unchanged "refused maps"

# ---- pause / unpause ------------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; printf 'Which $(map)?\n' > "$r/q.md"
snap
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" pause nonsense - "$r/q.md"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" pause map NOPE-1 "$r/q.md"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" pause map - "$r/missing.md"
unchanged "refused pauses"; assert_no_file "$run/pause-01.md" "no file for a refused pause"
: > "$FAKE_HERDR_LOG"; stale
assert_eq "$(L pause map - "$r/q.md")" "$run/pause-01.md" "run-level pause"; wrote "pause"
assert_eq "$(jq -c '.pause | del(.asked_at)' "$run/run.json")" "{\"seq\":1,\"unit\":null,\"kind\":\"map\",\"file\":\"$run/pause-01.md\"}" "pause object"
assert_eq "$(led '.pause_seq, (.pause.asked_at | endswith("Z"))' | tr '\n' ' ')" "1 true " "seq and time"
assert_contains "$(cat "$run/PROGRESS.md")" 'Which $(map)?' "question in progress"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show linear-loop eng-1-loop: needs you --body map - --sound request" "notification text"
snap; assert_contains "$(err pause adr ENG-12 "$r/q.md")" "loop: already paused" "one pause at a time"; unchanged "second pause"
stale; L unpause; wrote "unpause"
# a map pause is raised before Phase 0 finished: its unpause goes back there, never to running
assert_eq "$(led '.status, .pause, .pause_seq' | tr '\n' ' ')" "created null 1 " "unpaused after a map pause: created"
assert_eq "$(L pause adr eng-12 "$r/q.md")" "$run/pause-02.md" "sequence advances"
assert_eq "$(led '.pause.unit + " " + .units[1].resume_phase')" "ENG-12 pending" "canonical id and saved phase"
L unpause; assert_eq "$(led '.units[1] | has("resume_phase")')" false "saved phase removed"
assert_eq "$(led .status)" running "unpaused after any other pause: running"
L pause stuck ENG-12 "$r/q.md" >/dev/null; L unit-set ENG-12 .phase '"skipped"'; L unpause
assert_eq "$(led '.units[1] | .phase + " " + (has("resume_phase") | tostring)')" "skipped false" "a decision taken while paused is kept"

# ---- linear marks -----------------------------------------------------------------------
stale; L linear-mark eng-11 review; wrote "linear-mark"
assert_exit 0 "$LOOP/scripts/loop.sh" "$run" linear-has ENG-11 review
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" linear-has ENG-11 comment:done
L linear-mark ENG-11 'comment:a "b" $c'; L linear-mark ENG-11 comment:epic
assert_exit 0 "$LOOP/scripts/loop.sh" "$run" linear-has ENG-11 'comment:a "b" $c'
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" linear-has ENG-11 comment:a
assert_eq "$(led '.units[2].linear.comments | join("|")')" 'a "b" $c|epic' "tags kept in order"
for k in done comment: ''; do
  assert_exit 1 "$LOOP/scripts/loop.sh" "$run" linear-mark ENG-11 "$k"
  assert_contains "$(err linear-has ENG-11 "$k")" "herd: error:" "bad key '$k' is an error"
done

# ---- add-units ---------------------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; snap
refuse() { printf '%s' "$1" > "$r/s.json"; assert_exit 1 "$LOOP/scripts/loop.sh" "$run" add-units ENG-12 "$r/s.json"; }
s() { printf '{"id":"%s","uuid":"u","title":"t","blocked_by":%s}' "$1" "${2:-[]}"; }
refuse "not json"; refuse '[]'; refuse '{}'; refuse '[{"id":"ENG-90"}]'
refuse "[$(s ENG-90 '["ENG-91"]'),$(s ENG-91)]"
refuse "[$(s ENG-90 '["ENG-90"]')]"
refuse "[$(s ENG-90 '["NOPE-1"]')]"
refuse "[$(s ENG-90 '["ENG-11"]')]"        # an existing unit that runs after the slices
refuse "[$(s ENG-90),$(s eng-90)]"
refuse "[$(s eng-11)]"
refuse "[$(s 'x/../y')]"
unchanged "refused slices"
h='He said "hi" $(x) {{Y}}'
jq -n --arg t "$h" '[{id:"eng-90",uuid:"u90",title:$t,blocked_by:["eng-10"]},{id:"ENG-91",uuid:"u91",title:"b",blocked_by:["eng-90"]}]' > "$r/s.json"
stale; assert_eq "$(L add-units eng-12 "$r/s.json")" "OK 2" "added"; wrote "add-units"
assert_eq "$(led '[.units[].id] | join(",")')" "ENG-10,ENG-12,ENG-90,ENG-91,ENG-11" "inserted in the middle"
assert_eq "$(jq -c '[.units[].order]' "$run/run.json")" '[1,2,3,4,5]' "order renumbered"
assert_eq "$(jq -S '.units[2]' "$run/run.json")" "$(jq -nS --arg t "$h" '{id:"ENG-90",uuid:"u90",title:$t,kind:"issue",parent:"ENG-12",blocked_by:["ENG-10"],order:3,
  phase:"pending",agent:"eng-1-loop-bs-eng-90",session_id:null,pane:null,tab:null,restarts:0,revisions:0,recovery:{},no_breakdown:true,
  spec:null,plan:null,adrs:[],herd_slug:null,branch:null,base:null,carried_by:null,linear:{started:false,review:false,comments:[]}}')" "slice shape, ids upper-cased"
assert_eq "$(jq -c '.units[3].blocked_by' "$run/run.json")" '["ENG-90"]' "slice relation"
r="$(make_repo)"; run="$(make_loop_run "$r")"; printf '[%s]' "$(s ENG-90)" > "$r/s.json"
L add-units ENG-10 "$r/s.json" >/dev/null
assert_eq "$(led '.units[1] | .id + " " + (.no_breakdown | tostring)')" "ENG-90 false" "slices of a top-level unit may split once more"
L unit-set ENG-11 .no_breakdown true
assert_contains "$(err add-units eng-11 "$r/s.json")" "herd: error: loop: ENG-11 cannot be split again" "refusal message"

# ---- fail / done ---------------------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; : > "$FAKE_HERDR_LOG"; stale
L fail 'Linear "down" $(x)'; wrote "fail"
assert_eq "$(led '.status + " " + .failed_reason')" 'failed Linear "down" $(x)' "failed with reason"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show linear-loop eng-1-loop" "fail notifies"
assert_exit 1 "$LOOP/scripts/loop.sh" "$run" fail
printf '%s\n' 'Linear unreachable: `x` $(y) "z"' > "$r/why.txt"; L fail --file "$r/why.txt"
assert_eq "$(led .failed_reason)" 'Linear unreachable: `x` $(y) "z"' "fail --file: byte-exact reason"
: > "$FAKE_HERDR_LOG"; stale; L done; wrote "done"
assert_eq "$(led .status)" done "done"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show linear-loop eng-1-loop" "done notifies"

# ---- a write progress.sh could not render is refused ------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; printf 'Q?\n' > "$r/q.md"; snap
bad() {
  assert_exit 1 "$LOOP/scripts/loop.sh" "$run" "$@"
  assert_contains "$(err "$@")" "herd: error: loop: ledger write failed" "refused: $*"
}
bad unit-set-str ENG-12 .adrs docs/adr/1.md
bad unit-set ENG-12 .adrs '[1]'
bad unit-set ENG-12 .adrs '{"a":"b"}'
bad unit-set ENG-12 .adrs false
bad unit-set ENG-12 .title '{"a":"b"}'
bad ledger set .skipped '"x"'
bad ledger set .skipped 3
bad ledger set .skipped '["ENG-1"]'
bad ledger set .pause '"x"'
unchanged "unrenderable writes"
L unit-set ENG-12 .adrs null; L unit-set ENG-12 .title null; L ledger set .skipped null
L ledger set .skipped '[{"id":"ENG-1","reason":"completed"}]'; L unit-set ENG-12 .adrs '["docs/adr/1.md"]'
assert_exit 0 "$LOOP/scripts/progress.sh" "$run"

# ---- a render failure after the write does not undo or silence it -------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; printf 'Q?\n' > "$r/q.md"
mkdir "$run/PROGRESS.md"; chmod 555 "$run/PROGRESS.md"          # progress.sh cannot replace it
assert_exit 1 "$LOOP/scripts/progress.sh" "$run"
: > "$FAKE_HERDR_LOG"
out="$(L pause adr ENG-12 "$r/q.md" 2>"$r/err")" && rc=0 || rc=$?
assert_eq "$out $rc" "$run/pause-01.md 0" "pause still prints the path"
assert_contains "$(cat "$r/err")" "herd: loop: warning: could not render PROGRESS.md" "render failure is reported"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show linear-loop eng-1-loop: needs you" "pause still notifies"
assert_eq "$(led .status)" waiting-human "pause saved"
assert_exit 0 "$LOOP/scripts/loop.sh" "$run" unpause
assert_exit 0 "$LOOP/scripts/loop.sh" "$run" note "still logging"
: > "$FAKE_HERDR_LOG"; assert_exit 0 "$LOOP/scripts/loop.sh" "$run" fail boom
assert_contains "$(cat "$FAKE_HERDR_LOG")" "notification show linear-loop eng-1-loop failed" "fail still notifies"
chmod 755 "$run/PROGRESS.md"
finish
