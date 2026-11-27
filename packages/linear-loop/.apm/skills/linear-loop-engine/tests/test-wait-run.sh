#!/usr/bin/env bash
# usage: bash tests/test-wait-run.sh
# wait-run.sh: the outcomes of watching one herd run.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"

# ---- the brief's cases ----------------------------------------------------------
use_fake_herdr; d="$(mktemp -d)"; j="$d/run.json"; export LOOP_POLL_SECONDS=0
live() { printf '{"result":{"agents":[{"name":"x-orch"}]}}\n' > "$FAKE_HERDR_STATE/agents.json"; }
w() { "$LOOP/scripts/wait-run.sh" "$j" x-orch; }
live; printf '{"status":"done","updated_at":"a"}' > "$j";                      assert_eq "$(w)" "DONE" "done"
printf '{"status":"failed","failed_stage":"plan-1","updated_at":"a"}' > "$j"
out="$(w)" && rc=0 || rc=$?;                                                   assert_eq "$out $rc" "FAILED plan-1 2" "failed"
printf '{"status":"running","updated_at":"a"}' > "$j"; rm "$FAKE_HERDR_STATE/agents.json"
out="$(w)" && rc=0 || rc=$?;                                                   assert_eq "$out $rc" "ORCH-GONE 4" "dead orchestrator"
live; out="$(LOOP_STALE_LIMIT_SECONDS=0 w)" && rc=0 || rc=$?;                  assert_eq "$out $rc" "STUCK stale 7" "no ledger movement"
rm "$j"; out="$(LOOP_CREATED_LIMIT_SECONDS=0 w)" && rc=0 || rc=$?;             assert_eq "$out $rc" "STUCK created 7" "missing ledger is not a crash"
printf 'not json' > "$j"; out="$(LOOP_CREATED_LIMIT_SECONDS=0 w)" && rc=0 || rc=$?; assert_eq "$out $rc" "STUCK created 7" "half-written ledger is not a crash"

# ---- more ------------------------------------------------------------------------
for body in '' '[1]' '"x"' '{"status":"running"} {"status":' '{"status":"created","updated_at":"a"}'; do
  printf '%s' "$body" > "$j"; out="$(LOOP_CREATED_LIMIT_SECONDS=0 w)" && rc=0 || rc=$?
  assert_eq "$out $rc" "STUCK created 7" "counts as created: $body"
done
rm "$FAKE_HERDR_STATE/agents.json"
out="$(w)" && rc=0 || rc=$?;                                                   assert_eq "$out $rc" "ORCH-GONE 4" "created with no orchestrator"
# one poll without the agent is not enough: the herd run finishes before the second
real="$HERDR_BIN"; printf '{"status":"running","updated_at":"a"}' > "$j"
cat > "$d/herdr" <<EOF2
#!/usr/bin/env bash
n=\$(( \$(cat "$d/polls" 2>/dev/null || echo 0) + 1 )); echo "\$n" > "$d/polls"
case "\$n" in
  1) ;;
  2) printf '{"result":{"agents":[{"name":"x-orch"}]}}\n' > "$FAKE_HERDR_STATE/agents.json" ;;
  3) rm "$FAKE_HERDR_STATE/agents.json"; printf '{"status":"done","updated_at":"b"}' > "$j.next" ;;
  *) ;;
esac
[ "\$n" != 3 ] || mv "$j.next" "$j"
exec "$real" "\$@"
EOF2
chmod +x "$d/herdr"
out="$(HERDR_BIN="$d/herdr" w)" && rc=0 || rc=$?
assert_eq "$out $rc" "DONE 0" "absences that are not consecutive do not end the watch"
assert_eq "$(cat "$d/polls")" 3 "an absent, live, absent sequence kept watching"
assert_exit 1 "$LOOP/scripts/wait-run.sh" "$j"
assert_contains "$("$LOOP/scripts/wait-run.sh" 2>&1 || true)" "herd: error: loop: usage: wait-run.sh" "usage"
finish
