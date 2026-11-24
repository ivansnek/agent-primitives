#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
source "$HERD/scripts/lib.sh"

r="$(make_repo)"

# No config at all -> defaults, no failure.
assert_eq "$(herd_config_file "$r")" "" "no config file -> empty path"
assert_exit 0 herd_config_check "$r"
assert_eq "$(herd_config_get "$r" .defaultBase dev)" "dev" "missing config -> default"
assert_eq "$(herd_config_array "$r" .disallowedTools)" "" "missing config -> empty array"

# A version 1 config.
mkdir -p "$r/.claude"
cat > "$r/.claude/herd.config.json" <<'EOF'
{
  "version": 1,
  "defaultBase": "main",
  "runsDir": ".claude/herd-runs",
  "planStyle": "caveman",
  "disallowedTools": ["Bash(pnpm db:reset)", "Bash(git push)"]
}
EOF
assert_contains "$(herd_config_file "$r")" ".claude/herd.config.json" "config file found"
assert_exit 0 herd_config_check "$r"
assert_eq "$(herd_config_get "$r" .defaultBase dev)" "main" "config value wins over default"
assert_eq "$(herd_config_get "$r" .worktreeDir .claude/worktrees)" ".claude/worktrees" "absent key -> default"
assert_eq "$(herd_config_array "$r" .disallowedTools | wc -l | tr -d ' ')" "2" "array reads every element"
assert_contains "$(herd_config_array "$r" .disallowedTools)" "Bash(pnpm db:reset)" "array element verbatim"

# An unknown version is a loud failure, never a silent default.
printf '{"version": 99}\n' > "$r/.claude/herd.config.json"
assert_exit 1 herd_config_check "$r"
out="$(herd_config_check "$r" 2>&1)" || true
assert_contains "$out" "herd.config.json version 99" "unknown version names the version"

# Malformed JSON is also a loud failure.
printf '{not json\n' > "$r/.claude/herd.config.json"
assert_exit 1 herd_config_check "$r"

finish
