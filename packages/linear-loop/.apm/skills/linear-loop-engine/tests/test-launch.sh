#!/usr/bin/env bash
# usage: bash tests/test-launch.sh
# launch.sh: preflight, dry run, a new run, resume.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
use_fake_herdr; r="$(make_repo)"; cd "$r"; run="$r/.claude/loop-runs/eng-1-loop"; LA="$LOOP/scripts/launch.sh"
out="$("$LA" --dry-run ENG-1 2>&1)"
assert_contains "$out" "DRY-RUN: git worktree add --detach $r/.claude/worktrees/eng-1-loop-design dev" "dry-run: design worktree"
assert_contains "$out" "agent start eng-1-loop-loop --kind claude --pane <root_pane> --timeout 120000 -- --model fable --permission-mode bypassPermissions --remote-control eng-1-loop" "dry-run: remote control on the orchestrator"
assert_no_file "$run/run.json" "dry-run writes nothing"
assert_exit 1 "$LA"; assert_exit 1 "$LA" "ENG 1"; assert_exit 1 "$LA" --base nope ENG-1; assert_exit 1 "$LA" --slug Bad ENG-1
assert_exit 1 env HERD_ENGINE_DIR=/nonexistent "$LA" --dry-run ENG-1
printf '{"version":9}\n' > "$r/.claude/linear-loop.config.json"; assert_exit 1 "$LA" --dry-run ENG-1; rm "$r/.claude/linear-loop.config.json"
# Review Focus 1
out="$("$LA" --map-only --worker-model opus --execution sub-agent eng-1 ENG-7 ENG-1 2>&1)"
assert_eq "$(jq -c .given "$run/run.json")" '["ENG-1","ENG-7"]' "ids uppercased and de-duplicated"
assert_eq "$(jq -r '.status + " " + (.map_only|tostring) + " " + .stack_tip' "$run/run.json")" "created true dev" "ledger basics"
assert_eq "$(jq -c .herd "$run/run.json")" '{"worker_model":"opus","review_model":null,"execution":"subagent"}' "herd flags stored, alias normalised"
assert_eq "$(jq -c '.models' "$run/run.json")" '{"orchestrator":"fable","brainstorm":"fable","advisor":"fable"}' "model defaults"
assert_eq "$(jq -c '[.units, .skipped, .pause]' "$run/run.json")" '[[],[],null]' "empty map"
assert_file "$r/.claude/worktrees/eng-1-loop-design/.git" "design worktree created"
assert_file "$run/orchestrator.md" "brief rendered"; assert_file "$run/PROGRESS.md" "progress rendered"
assert_eq "$(grep -c '{{' "$run/orchestrator.md" || true)" 0 "no placeholder left"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "workspace create --cwd $r --label loop:eng-1-loop --no-focus" "own workspace"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "--remote-control eng-1-loop" "remote control flag"
assert_contains "$out" "PROGRESS.md" "report names the progress file"
assert_exit 1 "$LA" ENG-1                                                    # ledger exists
# resume
assert_exit 1 "$LA" --resume eng-1-loop ENG-2; assert_exit 1 "$LA" --resume eng-1-loop --worker-model opus; assert_exit 1 "$LA" --resume nope
rm -rf "$r/.claude/worktrees/eng-1-loop-design"; git -C "$r" worktree prune; : > "$FAKE_HERDR_LOG"
"$LA" --resume eng-1-loop >/dev/null
assert_eq "$(jq -r .map_only "$run/run.json")" false "resume clears map-only"
assert_file "$r/.claude/worktrees/eng-1-loop-design/.git" "design worktree restored"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "--remote-control eng-1-loop" "resume keeps remote control"
assert_contains "$(cat "$FAKE_HERDR_LOG")" "Resume the linear-loop run" "resume prompt"
printf '{"result":{"agents":[{"name":"eng-1-loop-loop"}]}}\n' > "$FAKE_HERDR_STATE/agents.json"; assert_exit 1 "$LA" --resume eng-1-loop
jq '.status="done"' "$run/run.json" > "$r/t" && mv "$r/t" "$run/run.json"; rm "$FAKE_HERDR_STATE/agents.json"; assert_exit 1 "$LA" --resume eng-1-loop

# ---- beyond the brief -------------------------------------------------------------
use_fake_herdr; r="$(make_repo)"; cd "$r"; run="$r/.claude/loop-runs/eng-2-loop"; wt="$r/.claude/worktrees/eng-2-loop-design"
msg() { "$LA" "$@" 2>&1 || true; }
assert_contains "$(msg)" "herd: error: loop: usage" "no ids: usage"
assert_contains "$(msg --base)" "herd: error: loop: --base needs a value" "flag without value"
assert_contains "$(msg --nope ENG-2)" "herd: error: loop: unknown option" "unknown option"
assert_exit 1 "$LA" --dry-run ENG-2 "../x-1"
assert_exit 1 "$LA" --dry-run --worker-model '-x' ENG-2
assert_exit 1 "$LA" --dry-run --execution parallel ENG-2
printf '{"version":1,"adrDir":"/abs"}\n' > "$r/.claude/linear-loop.config.json"
assert_exit 1 "$LA" --dry-run ENG-2
rm "$r/.claude/linear-loop.config.json"
printf '{"result":{"agents":[{"name":"eng-2-loop-loop"}]}}\n' > "$FAKE_HERDR_STATE/agents.json"
assert_contains "$(msg ENG-2)" "eng-2-loop-loop is already live" "live orchestrator refused"
rm "$FAKE_HERDR_STATE/agents.json"
mkdir -p "$wt"; assert_contains "$(msg ENG-2)" "design worktree path already exists" "worktree path refused"; rmdir "$wt"
assert_no_file "$run" "refusals create nothing"

# a failed workspace create leaves nothing that would block the next try
broken="$FAKE_HERDR_STATE/broken-herdr"
printf '#!/usr/bin/env bash\n[ "$1 $2" != "workspace create" ] || exit 1\nexec "%s" "$@"\n' "$HERDR_BIN" > "$broken"; chmod +x "$broken"
assert_exit 1 env HERDR_BIN="$broken" "$LA" ENG-2
assert_no_file "$run" "workspace failure: run dir removed"
assert_no_file "$wt" "workspace failure: design worktree removed"

# config, models and --base reach the ledger and the brief
git -C "$r" branch other
printf '{"version":1,"statusStarted":"Doing it","linearWrites":"comments","advisorMaxRevisions":0,"adrDir":"design/adr/"}\n' \
  > "$r/.claude/linear-loop.config.json"
printf '{"version":1,"defaultBase":"other"}\n' > "$r/.claude/herd.config.json"
out="$("$LA" --orchestrator-model opus --brainstorm-model claude-sonnet-5-5 --advisor-model haiku ENG-2 eng-3)"
assert_eq "$(jq -r '.base + " " + .stack_tip + " " + (.map_only|type) + " " + (.map_only|tostring)' "$run/run.json")" \
  "other other boolean false" "herd defaultBase; map_only is a boolean"
assert_eq "$(jq -c .herd "$run/run.json")" '{"worker_model":null,"review_model":null,"execution":null}' "ungiven herd flags are null"
assert_eq "$(jq -r '[.slug, .root, .design_worktree, .workspace_id, .orchestrator_pane, .engine_version, (.pause_seq|tostring), (.failed_reason|tostring)] | join(" ")' "$run/run.json")" \
  "eng-2-loop $r $wt wL wL:p1 linear-loop@0.1.0 0 null" "ledger fields"
assert_eq "$(jq 'keys | length' "$run/run.json")" 21 "every ledger key"
brief="$(cat "$run/orchestrator.md")"
assert_contains "$brief" "Given issues, in this order: ENG-2 ENG-3" "given ids rendered"
assert_contains "$brief" "Brainstormers run \`claude-sonnet-5-5\` (family \`sonnet\`); advisors run \`haiku\`" "models rendered"
assert_contains "$brief" "Linear writes \`comments\` · started status \`Doing it\`" "writes and status rendered"
assert_contains "$brief" "\`none\` (empty or \`none\` = not set) · spec revise rounds 0" "unset status and zero rounds"
assert_contains "$brief" "ADR folder \`design/adr\`" "adr dir rendered"
assert_contains "$brief" "$LOOP/scripts/loop.sh $run <command>" "engine dir rendered"
assert_contains "$brief" "$LOOP/templates/advisor-review.tmpl.md" "advisor prompt rendered"
log="$(cat "$FAKE_HERDR_LOG")"
assert_contains "$log" "--pane wL:p1 --timeout 120000 -- --model opus --permission-mode bypassPermissions --remote-control eng-2-loop" "start command"
assert_contains "$log" "agent prompt eng-2-loop-loop Read $run/orchestrator.md and follow it exactly. Run dir: $run" "first prompt"
for s in "mapped by the orchestrator in Phase 0" "eng-2-loop-loop (opus)" "claude.ai/code or the Claude mobile app" \
         "$run/PROGRESS.md" "herdr agent send-keys eng-2-loop-loop ctrl+c" "/linear-loop --resume eng-2-loop"; do
  assert_contains "$out" "$s" "report: $s"
done
assert_eq "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$r" rev-parse other)" "design worktree at base"

# resume refusals
for flag in "--base dev" "--slug x" "--map-only" "--orchestrator-model opus" "--brainstorm-model opus" \
            "--advisor-model opus" "--review-model opus" "--execution linear"; do
  # shellcheck disable=SC2086
  assert_contains "$(msg --resume eng-2-loop $flag)" "--resume takes no" "resume refuses $flag"
done
assert_exit 1 "$LA" --resume ../eng-2-loop
cp "$run/run.json" "$r/keep.json"
jq '.root="/elsewhere"' "$r/keep.json" > "$run/run.json"
assert_contains "$(msg --resume eng-2-loop)" "belongs to /elsewhere" "resume from another checkout refused"
cp "$r/keep.json" "$run/run.json"

# resume dry run changes nothing
jq '.map_only=true' "$run/run.json" > "$r/t" && mv "$r/t" "$run/run.json"
rm -rf "$wt"; rm "$run/orchestrator.md"; cp "$run/run.json" "$r/before.json"; printf 'wake check ok\n' >> "$run/orchestrator.log"
: > "$FAKE_HERDR_LOG"
out="$("$LA" --dry-run --resume eng-2-loop)"
assert_contains "$out" "DRY-RUN: git worktree add --force --detach $wt other" "resume dry-run: worktree"
assert_contains "$out" "DRY-RUN: set map_only false" "resume dry-run: ledger"
assert_contains "$out" "--remote-control eng-2-loop" "resume dry-run: start"
assert_eq "$(cmp "$r/before.json" "$run/run.json" && echo same)" same "resume dry-run leaves the ledger"
assert_no_file "$run/orchestrator.md" "resume dry-run renders nothing"
assert_no_file "$wt" "resume dry-run adds nothing"
assert_not_contains "$(cat "$FAKE_HERDR_LOG")" "tab create" "resume dry-run opens no tab"

# resume: deleted but still registered worktree, new tab, re-render, log kept
"$LA" --resume eng-2-loop >/dev/null
assert_file "$wt/.git" "stale registration: worktree restored"
assert_eq "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$r" rev-parse other)" "restored at the stack tip"
assert_file "$run/orchestrator.md" "resume re-renders the brief"
assert_contains "$(cat "$run/orchestrator.md")" "Given issues, in this order: ENG-2 ENG-3" "re-render from the ledger"
assert_contains "$(cat "$run/orchestrator.log")" "wake check ok" "resume keeps the log"
assert_eq "$(jq -r '.orchestrator_pane + " " + (.map_only|type)' "$run/run.json")" "wT:p2 boolean" "new pane recorded"
log="$(cat "$FAKE_HERDR_LOG")"
assert_contains "$log" "tab create --workspace wL --cwd $r --label orchestrator --no-focus" "new tab in the workspace"
assert_contains "$log" "--model opus --permission-mode bypassPermissions --remote-control eng-2-loop" "model pinned"

# a failed start keeps the run for --resume
: > "$FAKE_HERDR_STATE/agent-start-fails"
out="$(HERD_START_RETRY_SECONDS=0 msg ENG-4)"
assert_contains "$out" "--resume eng-4-loop" "start failure points at resume"
assert_file "$r/.claude/loop-runs/eng-4-loop/run.json" "start failure keeps the ledger"
rm "$FAKE_HERDR_STATE/agent-start-fails"

# the prompt file (source layout only: a deployed install renames it)
p="$LOOP/../../prompts/linear-loop.prompt.md"
case "$LOOP" in */.apm/skills/*)
  assert_file "$p" "prompt ships"
  prompt="$(cat "$p" 2>/dev/null || true)"
  assert_contains "$prompt" "disable-model-invocation: true" "prompt: user-invoked only"
  assert_contains "$prompt" "argument-hint:" "prompt: argument hint"
  assert_contains "$prompt" "launch.sh \$ARGUMENTS" "prompt: passes arguments through"
;; esac
finish
