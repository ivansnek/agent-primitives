#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
use_fake_herdr
r="$(make_repo)"
out="$("$HERDR_BIN" worktree create --cwd "$r" --branch feat/x --base dev --path "$r/.claude/worktrees/x" --label l --no-focus)"
assert_eq "$(printf '%s' "$out" | jq -r .result.workspace.workspace_id)" wT "worktree create returns workspace id"
assert_eq "$(printf '%s' "$out" | jq -r .result.root_pane.pane_id)" wT:p1 "worktree create returns root pane"
assert_file "$r/.claude/worktrees/x/.git" "worktree checkout exists"
assert_eq "$(git -C "$r/.claude/worktrees/x" branch --show-current)" feat/x "worktree on the new branch"
t1="$("$HERDR_BIN" tab create --workspace wT --cwd "$r" --label a --no-focus | jq -r .result.root_pane.pane_id)"
t2="$("$HERDR_BIN" tab create --workspace wT --cwd "$r" --label b --no-focus | jq -r .result.tab.tab_id)"
assert_eq "$t1" wT:p2 "tab counter starts after the root pane"
assert_eq "$t2" wT:t3 "tab counter increments"
assert_exit 1 "$HERDR_BIN" worktree create --branch y
assert_eq "$("$HERDR_BIN" agent get any | jq -r .result.agent.agent_session.value)" sess-test-1 "agent get session id"
assert_eq "$("$HERDR_BIN" agent list | jq -r '.result.agents | length')" 0 "agent list empty by default"
printf '{"result":{"agents":[{"name":"z"}]}}' > "$FAKE_HERDR_STATE/agents.json"
assert_eq "$("$HERDR_BIN" agent list | jq -r '.result.agents[0].name')" z "agent list served from state"
printf 'screen text\n' > "$FAKE_HERDR_STATE/screen.txt"
assert_eq "$("$HERDR_BIN" agent read z --source visible)" "screen text" "agent read served from state"
assert_eq "$("$HERDR_BIN" agent prompt z hi --wait | jq -r .result.agent.agent_status)" idle "agent prompt settles idle"
touch "$FAKE_HERDR_STATE/stall"
assert_exit 1 "$HERDR_BIN" agent prompt z hi --wait
assert_contains "$("$HERDR_BIN" agent prompt z hi --wait 2>&1 || true)" agent_prompt_stalled "stall switch reproduces herdr's error"
rm "$FAKE_HERDR_STATE/stall"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "worktree create --cwd $r --branch feat/x" "log records args"
finish
