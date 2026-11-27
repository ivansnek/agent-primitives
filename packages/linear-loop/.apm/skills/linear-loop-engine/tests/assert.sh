#!/usr/bin/env bash
# usage: source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
# Sourced by every tests/test-*.sh. herd's assertions + fixtures, plus LOOP. Never execute directly.
set -euo pipefail
LOOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The same resolution scripts/lib.sh uses, repeated so the tests do not depend on the code
# under test: HERD_ENGINE_DIR when set, else the deployed layout, else the source layout.
if [ -z "${HERD_ENGINE_DIR:-}" ]; then
  for d in "$LOOP/../herd-engine" "$LOOP/../../../../herd/.apm/skills/herd-engine"; do
    if [ -f "$d/scripts/lib.sh" ]; then HERD_ENGINE_DIR="$(cd "$d" && pwd)"; break; fi
  done
fi
[ -f "${HERD_ENGINE_DIR:-}/tests/assert.sh" ] \
  || { printf 'herd test helpers not found (set HERD_ENGINE_DIR)\n' >&2; exit 1; }
source "$HERD_ENGINE_DIR/tests/assert.sh"     # sets TESTS_DIR and HERD to herd's own dirs
export HERD_ENGINE_DIR
