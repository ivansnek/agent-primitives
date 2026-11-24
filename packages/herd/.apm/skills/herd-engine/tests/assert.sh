#!/usr/bin/env bash
# Sourced by every tests/test-*.sh. Assertions + fixtures. Never execute directly.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERD="$(cd "$TESTS_DIR/.." && pwd)"
FAILS=0; PASSES=0
pass() { PASSES=$((PASSES + 1)); }
fail() { FAILS=$((FAILS + 1)); printf '  FAIL: %s\n' "$*" >&2; }
assert_eq() { if [ "$1" = "$2" ]; then pass; else fail "${3:-assert_eq}: expected '$2', got '$1'"; fi; }
assert_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then pass; else fail "${3:-assert_contains}: '$2' not found in: $1"; fi; }
assert_not_contains() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "${3:-assert_not_contains}: '$2' found in: $1"; else pass; fi; }
assert_exit() {                      # assert_exit CODE CMD... (runs CMD in a subshell)
  local want="$1"; shift; local got=0
  ( "$@" ) >/dev/null 2>&1 || got=$?
  if [ "$got" = "$want" ]; then pass; else fail "assert_exit: '$*' exited $got, want $want"; fi
}
assert_file() { if [ -e "$1" ]; then pass; else fail "${2:-assert_file}: missing $1"; fi; }
assert_no_file() { if [ -e "$1" ]; then fail "${2:-assert_no_file}: exists $1"; else pass; fi; }
finish() { printf '%s: %d passed, %d failed\n' "$(basename "$0")" "$PASSES" "$FAILS"; [ "$FAILS" -eq 0 ]; }

# make_repo -> prints a temp git repo (branch dev, one commit) with an UNTRACKED sample plan,
# spec and env files — the same shape as the real checkout at launch time.
make_repo() {
  local r; r="$(mktemp -d "${TMPDIR:-/tmp}/herd-test.XXXXXX")"
  r="$(cd "$r" && pwd -P)"      # canonical: git rev-parse resolves /var -> /private/var on macOS
  git -C "$r" init -q -b dev
  git -C "$r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$r/docs/superpowers/plans" "$r/docs/superpowers/specs" "$r/apps/web" "$r/.claude"
  cat > "$r/docs/superpowers/plans/2026-09-04-sample-feature-phase-1-shell.md" <<'EOF'
# Sample Feature — Phase 1: Shell — Implementation Plan

**Spec:** `docs/superpowers/specs/2026-09-04-sample-feature-design.md`

### Task 1: Something
EOF
  printf '# Sample design\n' > "$r/docs/superpowers/specs/2026-09-04-sample-feature-design.md"
  printf 'ROOT=1\n' > "$r/.env.local"
  printf 'KEYS=1\n' > "$r/.env.keys"
  printf 'WEB=1\n' > "$r/apps/web/.env.local"
  printf '%s\n' "$r"
}

# use_fake_herdr -> route every herdr call to tests/fake-herdr (Task 2) and log it.
use_fake_herdr() {
  FAKE_HERDR_STATE="$(mktemp -d "${TMPDIR:-/tmp}/herd-fake.XXXXXX")"; export FAKE_HERDR_STATE
  FAKE_HERDR_LOG="$FAKE_HERDR_STATE/log"; export FAKE_HERDR_LOG; : > "$FAKE_HERDR_LOG"
  HERDR_BIN="$TESTS_DIR/fake-herdr"; export HERDR_BIN
}
