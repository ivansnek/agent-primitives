#!/usr/bin/env bash
# usage: scripts/check-generic.sh [PATH...]
# Fails when a tracked file (git ls-files, optionally limited to PATH...) contains a generic
# leak: a multi-tenancy word (any case) or an absolute home-directory path. Prints file:line:match
# per hit; exit 1 on any hit, 0 when clean. Untracked files (e.g. docs/superpowers/) are ignored.
# Patterns are assembled from split literals so this file never matches itself.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

WORDS='te''nant'
HOMES='/Us''ers/[^/ ]+/|/ho''me/[^/ ]+/'

scan() {   # FLAGS PATTERN PATH...
  local flags="$1" pattern="$2"; shift 2
  git ls-files -z -- "$@" | xargs -0 grep -nHE $flags -- "$pattern" 2>/dev/null || true
}

hits="$(scan -i "$WORDS" "$@"; scan '' "$HOMES" "$@")"
if [ -n "$hits" ]; then
  printf '%s\n' "$hits"
  exit 1
fi
