#!/usr/bin/env bash
# Runs every repo-level tests/test-*.sh, then the herd engine suite. Exit 1 if any failed.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rc=0
for t in test-*.sh; do
  printf '== %s\n' "$t"
  bash "$t" || rc=1
done
bash ../packages/herd/.apm/skills/herd-engine/tests/run.sh || rc=1
exit "$rc"
