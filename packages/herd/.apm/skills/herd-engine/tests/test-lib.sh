#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
source "$HERD/scripts/lib.sh"

assert_eq "$(herd_slug_from_plan docs/superpowers/plans/2026-09-04-unified-registration-phase-1-web-tab-shell.md)" unified-registration "slug strips date and phase suffix"
assert_eq "$(herd_slug_from_plan 2026-01-01-Very_Long.Feature-Name-With-Many-Words-plan.md)" very-long-feature-na "slug lowercases, squashes, truncates to 20"
assert_eq "$(herd_slug_from_plan simple.md)" simple "slug keeps plain names"
assert_exit 1 herd_slug_from_plan 2026-09-04-123.md
assert_exit 1 herd_validate_slug Upper
assert_exit 0 herd_validate_slug abc-123

r="$(make_repo)"
assert_eq "$(herd_plan_title "$r/docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md")" "Sample Feature — Phase 1: Shell" "plan title drops the Implementation Plan suffix"

j="$r/run.json"; printf '{"a":1,"updated_at":null}\n' > "$j"
herd_ledger_set "$j" '.a' '2'
assert_eq "$(herd_ledger_get "$j" .a)" 2 "ledger set/get json"
herd_ledger_set_str "$j" '.b' 'x y'
assert_eq "$(herd_ledger_get "$j" .b)" "x y" "ledger set_str"
assert_contains "$(herd_ledger_get "$j" .updated_at)" "T" "ledger stamps updated_at"
before="$(cat "$j")"; c=0                          # a failed jq must never mv a partial tmp over the ledger
herd_ledger_set "$j" '.a' 'not-json' 2>/dev/null || c=$?
assert_eq "$c" 1 "ledger set reports failure when jq fails"
assert_eq "$(cat "$j")" "$before" "ledger left intact when jq fails"
assert_eq "$(herd_json_field '{"result":{"tab":{"tab_id":"w1:t2"}}}' '.result.tab.tab_id')" "w1:t2" "json field"
assert_eq "$(herd_json_field '{"result":{}}' '.result.tab.tab_id')" "" "json field missing -> empty"

r3="$(make_repo)"

# Engine minimum with no config: git push is always denied; repo-specific commands are NOT built in.
herd_worker_flags sonnet "$r3"
assert_eq "${HERD_FLAGS[0]} ${HERD_FLAGS[1]}" "--model sonnet" "worker flags model"
assert_eq "${HERD_FLAGS[3]}" bypassPermissions "worker flags permission mode"
flags=" ${HERD_FLAGS[*]} "
assert_contains "$flags" " Bash(git push) " "engine minimum denies the bare git push"
assert_contains "$flags" "Bash(git push:*)" "engine minimum denies push with args"
assert_not_contains "$flags" "pnpm db:reset" "engine carries no repo-specific tool policy"
assert_not_contains "${HERD_FLAGS[*]}" "--append-system-prompt" "style append is not part of the shared worker flags"

# The repo's disallowedTools are appended.
mkdir -p "$r3/.claude"
printf '{"version":1,"disallowedTools":["Bash(pnpm db:reset)","Bash(supabase db:*)"],"planStyle":"terse"}\n' > "$r3/.claude/herd.config.json"
herd_worker_flags sonnet "$r3"
flags=" ${HERD_FLAGS[*]} "
assert_contains "$flags" "Bash(pnpm db:reset)" "repo tool policy is appended"
assert_contains "$flags" "Bash(supabase db:*)" "repo tool policy is appended verbatim"
assert_contains "$flags" " Bash(git push) " "engine minimum survives a repo policy"

# Plan style comes from the repo, not the engine.
assert_eq "$(herd_plan_style "$r3")" "terse" "plan style from config"
r4="$(make_repo)"
assert_eq "$(herd_plan_style "$r4")" "" "no config -> no plan style"

# Review standards fall back to the engine default.
assert_contains "$(herd_review_standards "$r4")" "review-standards.default.md" "default review standards"
printf '{"version":1,"reviewStandards":"docs/standards.md"}\n' > "$r3/.claude/herd.config.json"
printf '# standards\n' > "$r3/docs/standards.md"
assert_eq "$(herd_review_standards "$r3")" "$r3/docs/standards.md" "repo review standards resolve against the root"

# Security standards fall back to the engine default, like the review bar.
assert_contains "$(herd_security_standards "$r4")" "security-standards.default.md" "default security standards"
assert_file "$(herd_security_standards "$r4")" "default security standards ship with the engine"
printf '{"version":1,"securityStandards":"docs/security.md"}\n' > "$r3/.claude/herd.config.json"
printf '# security\n' > "$r3/docs/security.md"
assert_eq "$(herd_security_standards "$r3")" "$r3/docs/security.md" "repo security standards resolve against the root"
printf '{"version":1,"securityStandards":"docs/missing.md"}\n' > "$r3/.claude/herd.config.json"
assert_exit 1 herd_security_standards "$r3"

# Audit/review verification: the repo's testCommand, else the repo's documented checks.
assert_contains "$(herd_verify_text "$r4")" "none configured -> n/a" "no testCommand -> a repo without checks is not a failure"
assert_not_contains "$(herd_verify_text "$r4")" "pnpm" "default verification names no package manager"
printf '{"version":1,"testCommand":"make check"}\n' > "$r3/.claude/herd.config.json"
assert_contains "$(herd_verify_text "$r3")" "Run \`make check\`" "verification runs the configured testCommand"
printf '{"version":1,"testCommand":"BASE={{BASE}} make check"}\n' > "$r3/.claude/herd.config.json"
assert_contains "$(herd_verify_text "$r3" feat/x)" "Run \`BASE=feat/x make check\`" "{{BASE}} in testCommand becomes the run's base"

# The security audit has no model of its own: it runs on the reviewer's.
printf '{"models":{"orchestrator":"fable","plan":"sonnet","review":"claude-opus-5-5"}}\n' > "$j"
assert_eq "$(herd_stage_model "$j" plan)" sonnet "plan stage model"
assert_eq "$(herd_stage_model "$j" review)" claude-opus-5-5 "review stage model"
assert_eq "$(herd_stage_model "$j" audit)" claude-opus-5-5 "audit stage runs on the review model"
assert_exit 1 herd_stage_model "$j" orchestrator

# The style reaches the worker as a file, never inline: herdr TYPES the worker command into the
# pane, and macOS drops canonical-mode input past MAX_CANON (measured 1024 bytes), which cut the
# old 1229-byte inline command mid-quote. Keep the typed command comfortably under that.
sf="$(mktemp -d "${TMPDIR:-/tmp}/herd-style.XXXXXX")/plan-style.txt"
assert_eq "$(herd_write_plan_append "$sf" "terse mode: sentinel files still required")" "$sf" "herd_write_plan_append prints the path it wrote"
assert_contains "$(cat "$sf")" "sentinel" "style file holds the style text"
printf -v typed '%q ' claude "${HERD_FLAGS[@]}" --append-system-prompt-file \
  "/opt/a-fairly-long-user/Documents/Development/Project/repo/.claude/herd-runs/twenty-char-slug-x/plan-style.txt"
assert_eq "$([ "${#typed}" -lt 1024 ] && echo yes || echo no)" yes \
  "typed plan-worker command stays under the 1024-byte canonical limit (is ${#typed})"

assert_eq "$HERD_SHELL_PROMPT" "❯" "shell prompt defaults to the zsh prompt glyph"

v="$(herd_engine_version)"
assert_contains "$v" "herd@" "engine version is namespaced"
assert_not_contains "$v" "unknown" "engine version resolves from the package manifest"

# Model flags: family normalization feeds the sentinel gate; validation guards the pane command.
assert_eq "$(herd_model_family sonnet)" sonnet "family of an alias"
assert_eq "$(herd_model_family claude-opus-5-5)" opus "family of a full id"
assert_eq "$(herd_model_family Haiku)" haiku "family is lowercased"
assert_eq "$(herd_model_family custom-model)" custom-model "unknown family falls back to the value"
assert_eq "$(herd_validate_model --worker-model opus; echo ok)" ok "alias is a valid model"
assert_eq "$(herd_validate_model --worker-model claude-sonnet-5; echo ok)" ok "full id is a valid model"
assert_exit 1 bash -c "source '$HERD/scripts/lib.sh'; herd_validate_model --worker-model '--slug'"
assert_exit 1 bash -c "source '$HERD/scripts/lib.sh'; herd_validate_model --worker-model 'opus; rm -rf /'"

# Execution mode: two canonical values, a default, and one rules file per mode.
assert_eq "$HERD_DEFAULT_EXECUTION" linear "execution defaults to linear"
assert_eq "$(herd_execution_mode linear)" linear "linear is a mode"
assert_eq "$(herd_execution_mode native)" linear "native is linear"
assert_eq "$(herd_execution_mode subagent)" subagent "subagent is a mode"
assert_eq "$(herd_execution_mode Sub-Agent)" subagent "sub-agent is subagent, case-insensitive"
assert_exit 1 bash -c "source '$HERD/scripts/lib.sh'; herd_execution_mode parallel"
assert_exit 1 bash -c "source '$HERD/scripts/lib.sh'; herd_execution_mode --slug"
assert_exit 1 bash -c "source '$HERD/scripts/lib.sh'; herd_execution_mode ''"
printf '{"execution":"subagent"}\n' > "$j"
assert_eq "$(herd_ledger_execution "$j")" subagent "ledger execution read back"
printf '{"slug":"old"}\n' > "$j"
assert_eq "$(herd_ledger_execution "$j")" linear "a ledger from before the flag is linear"
for m in linear subagent; do
  assert_file "$HERD/templates/execution-$m.tmpl.md" "mode $m ships its rules"
  assert_not_contains "$(herd_execution_rules "$m" /wt feat/x)" "{{" "mode $m rules fully rendered"
done
assert_contains "$(herd_execution_rules linear /wt feat/x)" "superpowers:executing-plans" "linear rules name the inline skill"
assert_contains "$(herd_execution_rules subagent /wt feat/x)" "superpowers:subagent-driven-development" "subagent rules name the SDD skill"
assert_contains "$(herd_execution_rules subagent /wt feat/x)" "\`/wt\` on branch \`feat/x\`" "subagent rules pin the worktree and branch"

# agent-talk helpers live in lib.sh (shared with linear-loop)
use_fake_herdr
printf '{"result":{"agents":[{"name":"a1"}]}}\n' > "$FAKE_HERDR_STATE/agents.json"
assert_eq "$(herd_agent_prompt_wait a1 hello 1000)" "SETTLED idle" "prompt_wait settles"
assert_eq "$(herd_agent_wait a1 1000)" "SETTLED idle" "wait settles"
touch "$FAKE_HERDR_STATE/stall"
out="$(herd_agent_prompt_wait a1 hello 1000)" && rc=0 || rc=$?
assert_eq "$out $rc" "STALLED 7" "prompt_wait reports a stall"
rm "$FAKE_HERDR_STATE/stall"; rm "$FAKE_HERDR_STATE/agents.json"
out="$(herd_agent_prompt_wait gone hello 1000)" && rc=0 || rc=$?
assert_eq "$out $rc" "GONE 4" "prompt_wait reports a dead agent"
assert_exit 0 herd_agent_exit gone
assert_contains "$("$HERDR_BIN" workspace create --cwd /x --label l --no-focus)" '"root_pane"' "fake herdr creates workspaces"

finish
