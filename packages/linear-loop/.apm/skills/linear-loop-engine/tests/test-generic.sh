#!/usr/bin/env bash
# usage: bash tests/test-generic.sh
# The engine ships nothing install-specific: no Linear tool prefix, no home path, no status name
# except the documented "In Review" fallback.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
shipped() { grep -rnE "$1" "$LOOP" | grep -v '/tests/' || true; }

assert_eq "$(shipped 'mcp__|/Us''ers/|/ho''me/')" "" "no tool prefix or home path ships"
assert_eq "$(shipped 'In Prog''ress')" "" "no started-status name ships"
assert_eq "$(shipped 'In Rev''iew' | cut -d: -f1 | grep -vE '/(templates/orchestrator\.tmpl\.md|SKILL\.md)$' || true)" "" \
  "the review-status fallback name appears only where it is documented"
# the fallback is documented where the orchestrator resolves the status
assert_contains "$(cat "$LOOP/templates/orchestrator.tmpl.md" 2>/dev/null)" "named \`In Rev""iew\`" \
  "orchestrator documents the review-status fallback"

finish
