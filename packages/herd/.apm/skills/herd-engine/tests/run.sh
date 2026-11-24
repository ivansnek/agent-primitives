#!/usr/bin/env bash
# Runs every tests/test-*.sh in this directory. Exit 1 if any file reports a failure.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
rc=0
for t in test-*.sh; do
  printf '== %s\n' "$t"
  bash "$t" || rc=1
done
exit "$rc"
