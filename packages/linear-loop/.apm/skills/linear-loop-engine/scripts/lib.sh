#!/usr/bin/env bash
# usage: source scripts/lib.sh
# Shared helpers for the linear-loop scripts, on top of herd's lib.sh. Never execute it.
# Callers run under `set -euo pipefail`.

LOOP_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="$(cd "$LOOP_SCRIPTS_DIR/.." && pwd)"          # the engine root: scripts/ templates/ tests/
LOOP_TEMPLATES_DIR="$LOOP_DIR/templates"

# The herd engine this one builds on. A set HERD_ENGINE_DIR is authoritative: a wrong one must
# fail, not silently run some other herd. Unset: the deployed layout (sibling skill), then the
# source monorepo. Prints the absolute engine root, or fails.
loop_find_herd() {                                                   # -> absolute path
  local d candidates
  if [ -n "${HERD_ENGINE_DIR:-}" ]; then candidates=("$HERD_ENGINE_DIR")
  else candidates=("$LOOP_DIR/../herd-engine" "$LOOP_DIR/../../../../herd/.apm/skills/herd-engine"); fi
  for d in "${candidates[@]}"; do
    if [ -f "$d/scripts/lib.sh" ]; then (cd "$d" && pwd); return; fi
  done
  return 1
}
# herd_die is not loaded until herd's lib.sh is, hence the literal prefix.
if ! HERD_ENGINE_DIR="$(loop_find_herd)"; then
  printf 'herd: error: loop: herd engine not found (install the herd package, or set HERD_ENGINE_DIR)\n' >&2
  exit 1
fi
source "$HERD_ENGINE_DIR/scripts/lib.sh"

# This engine's version, as "linear-loop@<version>". Same file-based rule as herd_engine_version.
loop_engine_version() {
  local f="$LOOP_DIR/ENGINE_VERSION" v=""
  [ -f "$f" ] && v="$(head -1 "$f" | tr -d '[:space:]')"
  printf 'linear-loop@%s\n' "${v:-unknown}"
}

# Dies unless the resolved herd engine is at least HERD_MIN_VERSION.
loop_require_herd() {
  local min found
  min="$(head -1 "$LOOP_DIR/HERD_MIN_VERSION" | tr -d '[:space:]')"
  [ -n "$min" ] || herd_die "loop: no minimum herd version in $LOOP_DIR/HERD_MIN_VERSION"
  found="$(herd_engine_version)"; found="${found#herd@}"
  # the numeric check comes first: sort -V ranks a word like "unknown" above any version
  [[ "$found" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    && [ "$(printf '%s\n%s\n' "$min" "$found" | sort -V | head -1)" = "$min" ] \
    || herd_die "loop: herd engine $found is older than $min"
}

# ---- repo profile (.claude/linear-loop.config.json) ----------------------------
# Every field is optional; `version` is required when the file exists, as in herd.
LOOP_CONFIG_VERSION=1

loop_config_file() {                                                 # ROOT -> path or ""
  local f="$1/.claude/linear-loop.config.json"
  [ -f "$f" ] && printf '%s\n' "$f"
  return 0
}
loop_config_check() {                                                # ROOT -> 0 ok, dies otherwise
  local f v; f="$(loop_config_file "$1")"
  [ -n "$f" ] || return 0
  jq -e . "$f" >/dev/null 2>&1 || herd_die "loop: linear-loop.config.json is not valid JSON: $f"
  v="$(jq -r '.version // empty' "$f" 2>/dev/null)" || v=""
  [ -n "$v" ] || herd_die "loop: linear-loop.config.json has no version: $f"
  [ "$v" = "$LOOP_CONFIG_VERSION" ] \
    || herd_die "loop: linear-loop.config.json version $v is not supported (this engine reads version $LOOP_CONFIG_VERSION): $f"
  # has(), not //: a present null, false or "" is a wrong value, not an absent key
  jq -e 'if has("linearWrites") then .linearWrites | . == "none" or . == "comments" or . == "status" else true end' \
    "$f" >/dev/null 2>&1 || herd_die "loop: linearWrites must be none, comments or status: $f"
  jq -e 'if has("advisorMaxRevisions") then .advisorMaxRevisions | type == "number" and (tostring | test("^[0-9]+$")) else true end' \
    "$f" >/dev/null 2>&1 || herd_die "loop: advisorMaxRevisions must be a non-negative integer: $f"
}
loop_config_get() {                                                  # ROOT JQ_PATH DEFAULT
  local f v; f="$(loop_config_file "$1")"
  if [ -z "$f" ]; then printf '%s\n' "$3"; return 0; fi
  v="$(jq -r "$2 // empty" "$f" 2>/dev/null)"
  printf '%s\n' "${v:-$3}"
}

loop_runs_dir() {                                                    # ROOT -> absolute path
  local dir; dir="$(loop_config_get "$1" .runsDir .claude/loop-runs)"
  case "$dir" in /*) : ;; *) dir="$1/$dir" ;; esac
  printf '%s\n' "${dir%/}"
}
# Repo-relative on purpose: the same path is used in the main checkout and in every worktree.
loop_adr_dir() {                                                     # ROOT -> repo-relative path
  local dir; dir="$(loop_config_get "$1" .adrDir docs/adr)"
  case "$dir" in /*|*..*) herd_die "loop: adrDir must be a path inside the repo, relative and without '..': $dir" ;; esac
  while [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
  printf '%s\n' "$dir"
}

# ---- naming --------------------------------------------------------------------
# The unit slug names branches, directories and agents, so it is validated strictly.
loop_uslug() {                                                       # ID -> eng-12
  local s; s="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  [[ "$s" =~ ^[a-z][a-z0-9]*-[0-9]+$ ]] || herd_die "loop: invalid issue id '$1' (need a Linear identifier like ABC-12)"
  printf '%s\n' "$s"
}
loop_nn() { printf '%02d\n' "$((10#$1))"; }                          # N -> 03 (10#: 08 is not octal)
