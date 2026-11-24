#!/usr/bin/env bash
# scripts/check-generic.sh: flags generic leaks in tracked files only.
# Forbidden words are built from split literals so this file never contains them.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/packages/herd/.apm/skills/herd-engine/tests/assert.sh"
CHECK="$REPO_ROOT/scripts/check-generic.sh"

WORD="te""nant"
# fixture_repo -> prints a temp git repo holding a copy of the check script.
fixture_repo() {
  local r; r="$(mktemp -d "${TMPDIR:-/tmp}/check-generic.XXXXXX")"
  git -C "$r" init -q -b main
  mkdir -p "$r/scripts"
  [ -f "$CHECK" ] && cp "$CHECK" "$r/scripts/check-generic.sh"
  git -C "$r" add -A 2>/dev/null || true
  printf '%s\n' "$r"
}
track() { git -C "$1" add -- "$2"; }      # REPO REL
run_check() { (cd "$1" && shift && bash scripts/check-generic.sh "$@"); }

# clean: plain code and a lowercase features/users path are not leaks.
r="$(fixture_repo)"
mkdir -p "$r/apps/web/src/features/users"
printf 'const users = 1\n// see apps/web/src/features/users/x.ts\n' > "$r/apps/web/src/features/users/x.ts"
track "$r" apps/web/src/features/users/x.ts
assert_exit 0 run_check "$r"

# word: the forbidden word in a tracked file.
r="$(fixture_repo)"; printf 'scope by %s\n' "$WORD" > "$r/a.md"; track "$r" a.md
assert_exit 1 run_check "$r"

# case variant: upper-case identifier is still caught.
r="$(fixture_repo)"; printf 'const %s_ID = 1\n' "TE""NANT" > "$r/a.ts"; track "$r" a.ts
assert_exit 1 run_check "$r"

# macOS home path.
r="$(fixture_repo)"; printf 'path=%s\n' "/Us""ers/bob/project" > "$r/a.sh"; track "$r" a.sh
assert_exit 1 run_check "$r"

# linux home path.
r="$(fixture_repo)"; printf 'path=%s\n' "/ho""me/bob/project" > "$r/a.sh"; track "$r" a.sh
assert_exit 1 run_check "$r"

# untracked working notes are ignored.
r="$(fixture_repo)"; mkdir -p "$r/docs/superpowers"
printf '%s notes\n' "$WORD" > "$r/docs/superpowers/n.md"
assert_exit 0 run_check "$r"

# path arg restricts the scan.
r="$(fixture_repo)"; mkdir -p "$r/x" "$r/y"
printf '%s\n' "$WORD" > "$r/x/bad.md"; printf 'fine\n' > "$r/y/ok.md"
track "$r" x/bad.md; track "$r" y/ok.md
assert_exit 0 run_check "$r" y
assert_exit 1 run_check "$r" x

# hits are printed as file:line:match.
r="$(fixture_repo)"; printf 'ok\n%s here\n' "$WORD" > "$r/a.md"; track "$r" a.md
out="$(run_check "$r" 2>&1 || true)"
assert_contains "$out" "a.md:2:" "hit printed as file:line"

finish
