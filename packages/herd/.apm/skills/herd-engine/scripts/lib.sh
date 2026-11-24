#!/usr/bin/env bash
# Shared helpers for the herd scripts (.claude/herd/*). Source it; never execute it.
# Callers run under `set -euo pipefail`.

HERD_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERD_DIR="$(cd "$HERD_SCRIPTS_DIR/.." && pwd)"          # the engine root: scripts/ templates/ tests/
HERD_TEMPLATES_DIR="$HERD_DIR/templates"
HERDR_BIN="${HERDR_BIN:-herdr}"

# The installed engine's version, as "herd@<version>". Read from ENGINE_VERSION, a plain text
# file shipped inside the engine's own skill-resource tree (not crawled from apm.yml via
# relative ".." segments: after `apm install` the deployed skill directory sits at a DIFFERENT
# depth than in the source monorepo, and the package's own apm.yml is not deployed alongside
# it at all — only the raw apm_modules/_local/<pkg>/apm.yml is, which is not reachable by
# walking up from the installed skill dir. A file inside the skill resources travels with it
# at any install depth). "herd@unknown" when absent. Recorded in the ledger as PROVENANCE
# ONLY — see herd_engine_dir below.
herd_engine_version() {
  local f="$HERD_DIR/ENGINE_VERSION" v=""
  [ -f "$f" ] && v="$(head -1 "$f" | tr -d '[:space:]')"
  printf 'herd@%s\n' "${v:-unknown}"
}

# The engine root, resolved fresh from THIS file's location on every invocation. Installed
# package roots are version-addressed, so a path captured at launch points into a directory
# the next update deletes — and --resume is exactly the path that re-renders the orchestrator
# from the current template. Never resolve a script from run.json's herd_dir.
herd_engine_dir() { printf '%s\n' "$HERD_DIR"; }

herd_log() { printf 'herd: %s\n' "$*" >&2; }
herd_die() { printf 'herd: error: %s\n' "$*" >&2; exit 1; }
herd_require() { command -v "$1" >/dev/null 2>&1 || herd_die "missing required tool: $1"; }
herd_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

herd_validate_slug() {
  [[ "$1" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || herd_die "invalid slug '$1' (need ^[a-z][a-z0-9-]{0,19}$)"
}

# Default model per role. A launch flag overrides one; the chosen set is pinned in the ledger.
HERD_DEFAULT_ORCHESTRATOR_MODEL=fable
HERD_DEFAULT_PLAN_MODEL=sonnet
HERD_DEFAULT_REVIEW_MODEL=sonnet

# A claude --model value: an alias (fable, opus, sonnet, haiku) or a full id (claude-opus-5-5).
# Strict on purpose: herdr types the value into a shell pane, and a leading alphanumeric stops
# `--worker-model --slug x` from swallowing the next flag.
herd_validate_model() {                                              # FLAG VALUE
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || herd_die "invalid model for $1: '$2' (an alias like sonnet, or an id like claude-opus-5-5)"
}

# The family a model value names (fable/opus/sonnet/haiku), lowercased; the value itself when it
# names none. The sentinel gate matches on this, so `claude-opus-5-5` accepts "Opus 5.5".
herd_model_family() {                                                # MODEL -> family
  local m; m="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$m" in
    *fable*) echo fable ;; *opus*) echo opus ;; *sonnet*) echo sonnet ;; *haiku*) echo haiku ;;
    *) printf '%s\n' "$m" ;;
  esac
}

# How a plan worker executes its plan, after the two superpowers execution skills:
#   linear   — superpowers:executing-plans: the worker implements every task itself, inline.
#   subagent — superpowers:subagent-driven-development: the worker is a controller that
#              dispatches a fresh subagent per task and reviews each one.
# A launch flag picks one; it is pinned in the ledger like the models. Each mode's rules are
# one file, templates/execution-<mode>.tmpl.md — a new mode is that file plus a case below.
HERD_DEFAULT_EXECUTION=linear

# The canonical mode a flag value names. Strict for the same reason as herd_validate_model:
# the result selects a template file and is rendered into every brief.
herd_execution_mode() {                                              # VALUE -> linear|subagent
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    linear|native) echo linear ;;
    subagent|sub-agent) echo subagent ;;
    *) herd_die "invalid execution mode '$1' (linear or subagent)" ;;
  esac
}

# The mode a run is pinned to. A ledger written before the flag existed has no .execution;
# that run was launched under the only behavior there was, linear.
herd_ledger_execution() {                                            # FILE -> linear|subagent
  jq -r --arg d "$HERD_DEFAULT_EXECUTION" '.execution // $d' "$1"
}

# The rules a plan worker follows under MODE, rendered. One text, used twice: as a section of
# the plan brief, and appended to the worker's system prompt so it survives /compact.
herd_execution_rules() {                                             # MODE WORKTREE BRANCH -> text
  "$HERD_SCRIPTS_DIR/render.sh" "$HERD_TEMPLATES_DIR/execution-$1.tmpl.md" WORKTREE="$2" BRANCH="$3"
}

# Slug from a plan path: drop the YYYY-MM-DD- prefix and any -phase-N… suffix,
# lowercase, squash everything else to '-', keep 20 chars.
herd_slug_from_plan() {
  local base
  base="$(basename "$1" .md)"
  base="$(printf '%s' "$base" | sed -E 's/^[0-9]{4}-[0-9]{2}-[0-9]{2}-//; s/-phase-[0-9]+.*$//')"
  base="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
  base="$(printf '%s' "${base:0:20}" | sed -E 's/-+$//')"
  herd_validate_slug "$base"
  printf '%s\n' "$base"
}

# "# Title — Implementation Plan" -> "Title"
herd_plan_title() {
  sed -n '1{s/^# *//; s/ *— *Implementation Plan *$//; s/ *- *Implementation Plan *$//; p;}' "$1"
}

# ---- ledger (run.json) ---------------------------------------------------------
herd_ledger_get() { jq -r "$2" "$1"; }                               # FILE JQ_PATH
herd_ledger_set() {                                                  # FILE JQ_PATH JSON_VALUE (atomic)
  local file="$1" path="$2" value="$3" tmp
  tmp="$(mktemp "${file}.XXXXXX")"
  # never mv a partial/empty tmp over the ledger: a failed jq must leave run.json intact
  # and report failure (errexit is off inside a function called in a `||` list, e.g. stage.sh start_worker)
  if jq --argjson v "$value" --arg now "$(herd_now)" "${path} = \$v | .updated_at = \$now" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"; herd_log "ledger write failed: $path"; return 1
  fi
}
herd_ledger_set_str() { herd_ledger_set "$1" "$2" "$(jq -Rn --arg s "$3" '$s')"; }   # FILE JQ_PATH STRING

# ---- repo profile (.claude/herd.config.json) -----------------------------------
# Every field is optional. An absent file means engine defaults and sequential behavior.
# An unknown `version` is a loud failure: silently defaulting would run a repo under a
# contract it did not agree to.
HERD_CONFIG_VERSION=1

herd_config_file() {                                                 # ROOT -> path or ""
  local f="$1/.claude/herd.config.json"
  [ -f "$f" ] && printf '%s\n' "$f"
  return 0
}
herd_config_check() {                                                # ROOT -> 0 ok, dies otherwise
  local f; f="$(herd_config_file "$1")"
  [ -n "$f" ] || return 0
  jq -e . "$f" >/dev/null 2>&1 || herd_die "herd.config.json is not valid JSON: $f"
  local v; v="$(jq -r '.version // empty' "$f")"
  [ -n "$v" ] || herd_die "herd.config.json has no version: $f"
  [ "$v" = "$HERD_CONFIG_VERSION" ] \
    || herd_die "herd.config.json version $v is not supported (this engine reads version $HERD_CONFIG_VERSION): $f"
}
herd_config_get() {                                                  # ROOT JQ_PATH DEFAULT
  local f; f="$(herd_config_file "$1")"
  if [ -z "$f" ]; then printf '%s\n' "$3"; return 0; fi
  local v; v="$(jq -r "$2 // empty" "$f" 2>/dev/null)"
  printf '%s\n' "${v:-$3}"
}
herd_config_array() {                                                # ROOT JQ_PATH -> one per line
  local f; f="$(herd_config_file "$1")"
  [ -n "$f" ] || return 0
  jq -r "($2 // []) | .[]" "$f" 2>/dev/null || true
}

# The prep script a run must use: the repo's prepScript when configured, else the engine
# default. A configured path is resolved against the repo root and must exist — a missing
# prep script is a launch-time failure, not a twenty-minute-later one.
herd_prep_script() { herd_config_path "$1" prepScript "$HERD_SCRIPTS_DIR/prep-default.sh"; }   # ROOT -> absolute path

# A file path from the repo profile: KEY's value resolved against ROOT (it must exist), else DEFAULT.
herd_config_path() {                                                 # ROOT KEY DEFAULT -> absolute path
  local root="$1" key="$2" rel; rel="$(herd_config_get "$root" ".$key" "")"
  if [ -z "$rel" ]; then printf '%s\n' "$3"; return 0; fi
  case "$rel" in /*) : ;; *) rel="$root/$rel" ;; esac
  [ -f "$rel" ] || herd_die "$key not found: $rel"
  printf '%s\n' "$rel"
}

# ---- herdr ---------------------------------------------------------------------
herd_json_field() { printf '%s' "$1" | jq -r "$2 // empty"; }         # JSON JQ_PATH -> value or ""
herd_server_running() { "$HERDR_BIN" workspace list >/dev/null 2>&1; }
herd_agent_live() {                                                  # NAME -> exit 0 if a live agent has that name
  "$HERDR_BIN" agent list 2>/dev/null | jq -e --arg n "$1" '.result.agents[] | select(.name == $n)' >/dev/null 2>&1
}
herd_agent_session_id() {                                            # NAME -> claude session id or "" (polls 15 s)
  local i v
  for i in $(seq 1 15); do
    v="$("$HERDR_BIN" agent get "$1" 2>/dev/null | jq -r '.result.agent.agent_session.value // empty')"
    if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
    sleep 1
  done
  printf '\n'
}
# The pane's interactive shell prompt. `herdr agent start` TYPES its command into the pane and
# documents that the pane must already be at that prompt. Override if the prompt is not zsh's `❯`.
HERD_SHELL_PROMPT="${HERD_SHELL_PROMPT:-❯}"

# Block until PANE is at an interactive shell prompt, ready to be typed into. Two signals, because
# neither alone is sufficient:
#   - no foreground process besides the shell — catches a pane being reused by `stage.sh restart`,
#     whose previous agent is still exiting (its prompt glyph is already in the scrollback there, so
#     wait-output alone would match the stale one and return immediately);
#   - the prompt glyph on screen — catches a fresh pane still sourcing .zshrc, where the shell IS
#     the foreground process but has not armed ZLE yet.
# Typing before this point silently loses input: until zsh puts the tty in raw mode the line stays
# canonical, and macOS discards everything past MAX_CANON. Measured 2026-09-09 on Darwin 25.5: a
# 1000-byte pre-shell write arrives whole, an 1100-byte one arrives as exactly 1024. A worker
# command cut at 1024 ends mid-quote, leaving zsh in a `quote>` continuation where every retry
# types into the open quote instead of running anything.
herd_pane_wait_prompt() {                                            # PANE [TIMEOUT_MS] -> 0 when ready
  local pane="$1" timeout="${2:-30000}" deadline info busy
  deadline=$(( $(date +%s) + timeout / 1000 ))
  while :; do
    info="$("$HERDR_BIN" pane process-info --pane "$pane" 2>/dev/null || true)"
    busy=1
    if [ -n "$info" ]; then
      busy="$(printf '%s' "$info" | jq '[.result.process_info.foreground_processes[]?
        | select(.name | test("^-?(zsh|bash|sh|fish)$") | not)] | length' 2>/dev/null || echo 1)"
    fi
    [ "$busy" = 0 ] && break
    [ "$(date +%s)" -lt "$deadline" ] \
      || { herd_log "pane $pane still had a foreground process after ${timeout}ms"; return 1; }
    sleep 1
  done
  "$HERDR_BIN" pane wait-output "$pane" --match "$HERD_SHELL_PROMPT" --source visible \
    --timeout "$timeout" >/dev/null 2>&1 \
    || { herd_log "pane $pane never showed the prompt ('$HERD_SHELL_PROMPT') within ${timeout}ms"; return 1; }
}

# Start a claude session in PANE. Waits for the shell prompt first (herd_pane_wait_prompt) and
# retries, because a fresh pane's shell needs a moment.
# herd_agent_start NAME PANE -- <claude args...>
herd_agent_start() {
  local name="$1" pane="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local attempt out
  for attempt in 1 2 3 4 5; do
    if [ "$attempt" -gt 1 ]; then
      # A previous attempt can leave zsh mid-command (an unterminated quote from a truncated line).
      # Clear the line buffer, or every later attempt just types into that open quote and times out.
      "$HERDR_BIN" pane send-keys "$pane" ctrl+c >/dev/null 2>&1 || true
    fi
    if ! herd_pane_wait_prompt "$pane"; then
      herd_log "agent start $name attempt $attempt: pane $pane was not at a shell prompt"
      sleep "${HERD_START_RETRY_SECONDS:-3}"
      continue
    fi
    if out="$("$HERDR_BIN" agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "$@" 2>&1)"; then
      printf '%s\n' "$out"; return 0
    fi
    herd_log "agent start $name attempt $attempt failed: $out"
    sleep "${HERD_START_RETRY_SECONDS:-3}"
  done
  return 1
}
# Sets HERD_FLAGS=(...): the claude flags every worker session gets. The engine's own minimum
# is git-write denial — everything else is repo policy, because the engine does not know what
# a repository's destructive commands are called.
herd_worker_flags() {                                                # MODEL ROOT
  local model="$1" root="${2:-}"
  HERD_FLAGS=(--model "$model" --permission-mode bypassPermissions
    --disallowedTools "Bash(git push)" "Bash(git push:*)")
  if [ -n "$root" ]; then
    local t
    while IFS= read -r t; do [ -n "$t" ] && HERD_FLAGS+=("$t"); done < <(herd_config_array "$root" .disallowedTools)
  fi
}

# The output style appended to PLAN workers' system prompt, from the repo profile. Empty when
# the repo configures none — style is an operator preference, not an engine property. (How the
# plan is executed is the engine's: see herd_execution_rules.)
herd_plan_style() {                                                  # ROOT -> text or ""
  local root="$1" name; name="$(herd_config_get "$root" .planStyle "")"
  [ -n "$name" ] || return 0
  printf '%s\n' "$name"
}

# The review bar a review stage is held to: the repo's when configured, else the engine default.
herd_review_standards() { herd_config_path "$1" reviewStandards "$HERD_DIR/review-standards.default.md"; }   # ROOT -> absolute path

# The security bar an audit stage is held to: the repo's when configured, else the engine default.
herd_security_standards() { herd_config_path "$1" securityStandards "$HERD_DIR/security-standards.default.md"; }   # ROOT -> absolute path

# How many slice subagents one audit may dispatch to read files whole (8 files per slice).
# Past it the lowest-risk files are judged from their diff. A repo raises it for sensitive
# code or lowers it to spend less; a value that is not a positive integer is the default.
HERD_DEFAULT_AUDIT_MAX_SLICES=5
herd_audit_max_slices() {                                            # ROOT -> integer
  local n; n="$(herd_config_get "$1" .auditMaxSlices "$HERD_DEFAULT_AUDIT_MAX_SLICES")"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || n="$HERD_DEFAULT_AUDIT_MAX_SLICES"
  printf '%s\n' "$n"
}

# How an audit or review stage verifies its own fixes: the repo's testCommand when configured
# (a literal {{BASE}} in it becomes the run's base branch), else the repo's documented checks.
# A repo with no checks at all must not fail every stage, so the fallback says "none
# configured" is a valid verification result.
herd_verify_text() {                                                 # ROOT BASE -> one paragraph
  local cmd; cmd="$(herd_config_get "$1" .testCommand "")"; cmd="${cmd//"{{BASE}}"/"${2:-}"}"
  if [ -n "$cmd" ]; then
    printf 'Run `%s` in the worktree and make it green; it is the repo'"'"'s configured verification command. Also run any narrower checks the repo'"'"'s own docs (`CLAUDE.md`, `AGENTS.md`, README) require for the files you touched.\n' "$cmd"
  else
    printf 'This repo configures no verification command (`testCommand` in `.claude/herd.config.json`). Use the typecheck, lint and test commands the repo'"'"'s own docs (`CLAUDE.md`, `AGENTS.md`, README) or package manifest define, scoped to the files you touched. If the repo defines none, record `- none configured -> n/a` under `verification:`; that is not a failure.\n'
  fi
}

# The model a stage runs on. The security audit has no model of its own: it runs on the code
# reviewer's, so `--review-model` sets both and a ledger from before the audit stage still works.
herd_stage_model() {                                                 # RUN_JSON KIND -> model
  case "$2" in
    plan) herd_ledger_get "$1" .models.plan ;;
    audit|review) herd_ledger_get "$1" .models.review ;;
    *) herd_die "no model for stage kind: $2" ;;
  esac
}

# The ledger record of one stage, fresh. jq definition shared by launch and the resume backfill.
HERD_JQ_STAGE='def stage($slug; $index; kind): {status:"pending", agent:($slug + "-" + kind + "-" + ($index|tostring)),
  pane:null, tab:null, session_id:null, head_before:null, head_after:null, attempts:0, restarts:0, recovery:{},
  started_at:null, finished_at:null};'

# Give every plan of a ledger written before the audit stage existed an `.audit` record. Its
# status is `pending` only while the plan's review has not started: an audit must never run
# after (or alongside) a review of the same plan, so a later one is recorded as `skipped`.
herd_ledger_backfill_audit() {                                       # FILE
  local file="$1" plans
  [ "$(jq 'all(.plans[]; has("audit"))' "$file")" = false ] || return 0
  plans="$(jq "$HERD_JQ_STAGE"'
      .slug as $slug | .plans | map(if has("audit") then . else
        .audit = (stage($slug; .index; "audit")
          + {status: (if .review.status == "pending" then "pending" else "skipped" end)})
      end)' "$file")" || { herd_log "ledger audit backfill failed: $file"; return 1; }
  herd_ledger_set "$file" .plans "$plans"
}

# Write a plan worker's system-prompt append TEXT (execution rules, then the repo's style) to
# FILE so it can be passed as --append-system-prompt-file. Inline, a ~620-byte style pushed a
# plan worker's command line to 1229 bytes — past the canonical-mode limit
# herd_pane_wait_prompt describes. The file keeps the typed command short, so losing the
# prompt race stays harmless instead of corrupting the line.
# Returns non-zero rather than dying: the caller (stage.sh start_worker) is inside spawn's
# `if ! start_worker`, whose failure branch closes the tab it just created. An exit here would
# strand that tab.
herd_write_plan_append() {                                           # FILE TEXT -> prints FILE
  printf '%s\n' "$2" > "$1" \
    || { herd_log "could not write the plan worker's system-prompt append to $1"; return 1; }
  printf '%s\n' "$1"
}
herd_notify() {                                                      # TITLE [BODY] [SOUND]
  if [ -n "${2:-}" ]; then "$HERDR_BIN" notification show "$1" --body "$2" --sound "${3:-done}" >/dev/null 2>&1 || true
  else "$HERDR_BIN" notification show "$1" --sound "${3:-done}" >/dev/null 2>&1 || true; fi
}
