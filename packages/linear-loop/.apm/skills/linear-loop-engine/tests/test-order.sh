#!/usr/bin/env bash
# usage: bash tests/test-order.sh
# order.sh: map.json -> ordered units, skipped issues and problems. One fixture per case.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
o() { "$LOOP/scripts/order.sh" "$LOOP/tests/fixtures/$1.json"; }
ids() { jq -c '[.units[] | .id + ":" + .kind]'; }

# ---- the brief's cases ----------------------------------------------------------
assert_eq "$(o map-plain | ids)" '["ENG-2:issue","ENG-1:issue"]' "blocker first even when given second"
assert_eq "$(o map-epic | ids)" '["ENG-10:epic-design","ENG-12:issue","ENG-11:issue","ENG-13:issue"]' "epic: design unit, then children by relation then createdAt"
assert_eq "$(o map-epic | jq -c '[.units[].order]')" '[1,2,3,4]' "order contiguous"
assert_eq "$(o map-epic | jq -r '.units[1].parent')" 'ENG-10' "child keeps parent"
assert_eq "$(o map-one-child | ids)" '["ENG-21:issue"]' "one active child: no epic-design unit"
assert_eq "$(o map-childless-epic | ids)" '["ENG-30:issue"]' "childless epic is a plain issue"
assert_eq "$(o map-done | jq -c '[.skipped[].id]')" '["ENG-41"]' "completed child skipped"
assert_eq "$(o map-done | jq -c '.units[0].blocked_by')" '[]' "relation to a completed issue dropped"
assert_eq "$(o map-epic-children-done | jq -c '[(.units | length), (.skipped[] | select(.id=="ENG-80") | .reason)]')" '[0,"all-children-done"]' "open epic with only finished children is not rebuilt"
assert_eq "$(o map-case-dup | ids)" '["ENG-1:issue"]' "mixed case and duplicates collapse"
assert_eq "$(o map-external | jq -c '[.problems[] | .type, .ids]')" '["external",["ENG-50","OPS-9"]]' "active outside blocker reported"
assert_eq "$(o map-external-done | jq -c '.problems')" '[]' "completed outside blocker is fine"
assert_eq "$(o map-cycle | jq -r '.problems[0].type')" 'cycle' "cycle reported"
assert_eq "$(o map-all-done | jq -r '.problems[0].type')" 'empty' "nothing to do reported"
assert_eq "$(o map-group-dep | ids)" '["ENG-70:issue","ENG-60:epic-design","ENG-61:issue","ENG-62:issue"]' "an epic waits for an issue one of its children needs"
assert_eq "$(o map-child-given-with-parent | jq '.units | length')" '3' "child given alongside its parent is not duplicated"
assert_exit 1 "$LOOP/scripts/order.sh" /nonexistent.json

# ---- output shape -----------------------------------------------------------------
assert_eq "$(o map-epic | jq -c '.units[3]')" \
  '{"id":"ENG-13","uuid":"u13","title":"Wire the export button","kind":"issue","parent":"ENG-10","blocked_by":["ENG-11"],"order":4}' "unit fields"
assert_eq "$(o map-epic | jq -c '[.units[0].parent, .skipped, .problems]')" '[null,[],[]]' "clean map: root has no parent, nothing skipped, no problems"
assert_eq "$(o map-one-child | jq -c '[.units[0].parent, .skipped]')" '["ENG-20",[{"id":"ENG-22","reason":"completed"}]]' "collapsed parent: child keeps it; finished sibling skipped"
assert_eq "$(o map-epic-children-done | jq -c '[.skipped[] | .id + ":" + .reason]')" '["ENG-80:all-children-done","ENG-81:completed","ENG-82:canceled"]' "skipped in tree order with reasons"
assert_eq "$(o map-epic-children-done | jq -c '[.problems[].type]')" '["empty"]' "finished epic leaves nothing to do"
assert_eq "$(o map-all-done | jq -c '.skipped')" '[{"id":"ENG-1","reason":"completed"}]' "completed given issue skipped"
assert_eq "$(o map-external | jq -c '[.units[0].blocked_by, .problems[0].detail != ""]')" '[[],true]' "outside blocker is not a blocked_by entry"
assert_eq "$(o map-external-done | jq -c '[.skipped, .units[0].blocked_by]')" '[[],[]]' "outside issues are never listed as skipped"
assert_eq "$(o map-case-dup | jq -c '[.units[0].blocked_by, .problems]')" '[[],[]]' "self relation dropped, ids normalised"
assert_eq "$(o map-child-given-with-parent | ids)" '["ENG-100:epic-design","ENG-101:issue","ENG-102:issue"]' "child given first still sits in its parent's group"

# ---- cycles -------------------------------------------------------------------------
assert_eq "$(o map-cycle | jq -c '[.problems[] | .type, .ids]')" '["cycle",["ENG-90","ENG-91"]]' "cycle ids are the cycle only, not its dependents"
assert_eq "$(o map-cycle | jq -c '[.units[].id]')" '["ENG-91","ENG-90","ENG-92"]' "cyclic edges ignored, other edges kept"
assert_eq "$(o map-group-cycle | jq -c '[.problems[] | .type, .ids]')" '["cycle",["ENG-131","ENG-132","ENG-140"]]' "epic group and an issue needing each other is a cycle"
assert_eq "$(o map-group-cycle | ids)" '["ENG-130:epic-design","ENG-131:issue","ENG-132:issue","ENG-140:issue"]' "group cycle: tiebreak order"
assert_eq "$(o map-epic-self | jq -c '[.problems[] | .type, .ids]')" '["cycle",["ENG-150","ENG-152"]]' "epic blocked by its own child is a cycle"
assert_eq "$(o map-epic-self | jq -c '[.units[] | .id + ":" + (.blocked_by | join(","))]')" '["ENG-150:ENG-152","ENG-151:ENG-150","ENG-152:"]' "child blocked by its epic is satisfied by structure"

# ---- nesting, inactive parents, collapsed parents -----------------------------------
assert_eq "$(o map-nested | ids)" '["ENG-210:issue","ENG-200:epic-design","ENG-201:epic-design","ENG-204:issue","ENG-203:issue","ENG-202:issue"]' "nested epics: relations lift to every level"
assert_eq "$(o map-nested | jq -c '[.units[] | .id + "<" + (.parent // "-") + "|" + (.blocked_by | join(","))]')" \
  '["ENG-210<-|","ENG-200<-|","ENG-201<ENG-200|ENG-210","ENG-204<ENG-201|","ENG-203<ENG-201|","ENG-202<ENG-200|ENG-204"]' "nested: parents and de-duplicated blockers"
assert_eq "$(o map-inactive-parent | ids)" '["ENG-111:issue","ENG-112:issue","ENG-120:epic-design","ENG-124:issue","ENG-122:issue","ENG-123:issue"]' "open work under a closed issue still runs"
assert_eq "$(o map-inactive-parent | jq -c '[.units[] | .parent]')" '[null,null,null,"ENG-120","ENG-120","ENG-120"]' "parent skips closed ancestors"
assert_eq "$(o map-inactive-parent | jq -c '[.skipped[] | .id + ":" + .reason]')" '["ENG-110:completed","ENG-121:completed","ENG-125:all-children-done","ENG-126:completed"]' "inactive parent skipped"
assert_eq "$(o map-inactive-parent | jq -c '[.units[5].blocked_by, .problems]')" '[[],[]]' "blocker with all children done dropped"
assert_eq "$(o map-done-sibling | ids)" '["ENG-161:issue"]' "a sibling with only finished children does not count as active"
assert_eq "$(o map-passthrough | jq -c '[.units[] | .id + "<" + (.parent // "-") + "|" + (.blocked_by | join(","))]')" \
  '["ENG-175<-|","ENG-171<ENG-170|ENG-175","ENG-180<-|ENG-171"]' "collapsed parent: its relations move to the child unit"
assert_eq "$(o map-passthrough | jq -c '[.problems[] | .type, .ids]')" '["external",["ENG-170","OPS-20"]]' "collapsed parent's outside blocker reported"
assert_eq "$(o map-id-tiebreak | ids)" '["ENG-300:epic-design","ENG-999:issue","ENG-1000:issue"]' "id tiebreak is numeric"
assert_eq "$(o map-unknown | jq -c '[[.units[].id], [.problems[] | .type, .ids]]')" '[["ENG-1"],["unknown-id",["ENG-404"]]]' "unknown given id reported"

# ---- determinism: input array order never matters ---------------------------------
t="$(mktemp -d "${TMPDIR:-/tmp}/loop-order.XXXXXX")"
for f in "$LOOP"/tests/fixtures/map-*.json; do
  n="$(basename "$f" .json)"
  jq '.issues |= (reverse | map(.blockedBy |= reverse))' "$f" > "$t/$n.json"
  assert_eq "$("$LOOP/scripts/order.sh" "$t/$n.json")" "$(o "$n")" "$n: same output for reversed input arrays"
done

# ---- malformed input exits 1; problems are data and exit 0 -------------------------
assert_exit 0 "$LOOP/scripts/order.sh" "$LOOP/tests/fixtures/map-cycle.json"
assert_exit 1 "$LOOP/scripts/order.sh"
printf 'not json\n' > "$t/bad.json";                                         assert_exit 1 "$LOOP/scripts/order.sh" "$t/bad.json"
printf '{"given":"ENG-1","issues":[]}\n' > "$t/bad.json";                   assert_exit 1 "$LOOP/scripts/order.sh" "$t/bad.json"
printf '{"given":["ENG-1"]}\n' > "$t/bad.json";                             assert_exit 1 "$LOOP/scripts/order.sh" "$t/bad.json"
printf '{"given":["ENG-1"],"issues":[{"statusType":"started"}]}\n' > "$t/bad.json"; assert_exit 1 "$LOOP/scripts/order.sh" "$t/bad.json"
printf '{"given":[],"issues":[]}\n{"given":[],"issues":[]}\n' > "$t/bad.json"; assert_exit 1 "$LOOP/scripts/order.sh" "$t/bad.json"
printf '{"given":["A-1"],"issues":[{"id":"A-1","statusType":"started","parent":"A-2"},{"id":"A-2","statusType":"started","parent":"a-1"}]}\n' > "$t/bad.json"
assert_exit 1 "$LOOP/scripts/order.sh" "$t/bad.json"
assert_contains "$("$LOOP/scripts/order.sh" "$t/bad.json" 2>&1)" "herd: error: loop:" "error prefix"
printf '{"given":["ENG-404"],"issues":[]}\n' > "$t/only-unknown.json"
assert_eq "$("$LOOP/scripts/order.sh" "$t/only-unknown.json" | jq -c '[.problems[].type]')" '["unknown-id"]' "unknown ids alone: no extra empty problem"
printf '{"given":["A-1"],"issues":[{"id":"A-1","statusType":"started","parent":null,"blockedBy":["B-7"]}]}\n' > "$t/m.json"
assert_eq "$("$LOOP/scripts/order.sh" "$t/m.json" | jq -c '[.problems[] | .type, .ids]')" '["external",["A-1","B-7"]]' "blocker missing from issues is external"
printf '{"given":["A-2","A-5","A-1"],"issues":[{"id":"A-1","statusType":"started","parent":null,"createdAt":"1"},{"id":"A-2","statusType":"started","parent":"A-1","createdAt":"2"},{"id":"A-3","statusType":"started","parent":"A-1","createdAt":"3"},{"id":"A-5","statusType":"started","parent":null,"createdAt":"5"}]}\n' > "$t/m.json"
assert_eq "$("$LOOP/scripts/order.sh" "$t/m.json" | jq -c '[.units[].id]')" '["A-5","A-1","A-2","A-3"]' "a group sits at its root's position in given, not its child's"
printf '{"given":["A-1"],"issues":[{"id":"A-1","statusType":"started","title":"first"},{"id":"a-1","statusType":"completed","title":"second"}]}\n' > "$t/m.json"
assert_eq "$("$LOOP/scripts/order.sh" "$t/m.json" | jq -c '[.units[].title]')" '["first"]' "duplicate issue id: first wins"
printf '{"given":["A-1"],"issues":[{"id":"A-1","statusType":"someNewType"}]}\n' > "$t/m.json"
assert_eq "$("$LOOP/scripts/order.sh" "$t/m.json" | jq -c '[.units[].id]')" '["A-1"]' "unknown statusType counts as active"
rm -rf "$t"
finish
