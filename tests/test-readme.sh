#!/usr/bin/env bash
# README and CI state what a consumer needs to run herd.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/packages/herd/.apm/skills/herd-engine/tests/assert.sh"
readme="$(cat "$REPO_ROOT/README.md")"
ci="$(cat "$REPO_ROOT/.github/workflows/test.yml")"
assert_contains "$readme" "bash 4.4" "README states the bash floor"
assert_contains "$readme" ".claude/worktrees" "README says to gitignore run worktrees"
assert_contains "$readme" "execute-code-review" "README says which package needs which"
assert_contains "$ci" "brew install bash" "CI runs the suite on bash >= 4.4"
finish
