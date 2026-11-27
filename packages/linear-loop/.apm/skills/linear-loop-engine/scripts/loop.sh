#!/usr/bin/env bash
# usage: scripts/loop.sh RUN_DIR COMMAND [ARGS]
# Orchestrator helpers.
#   ledger get JQ | ledger set JQ JSON | ledger set-str JQ STRING
#   unit ID | unit-set ID JQ_PATH JSON | unit-set-str ID JQ_PATH STRING | next | map-apply MAP_JSON
#   pause KIND UNIT|- FILE | unpause | note TEXT | ruling TEXT
#   linear-has ID KEY | linear-mark ID KEY   (KEY: started | review | comment:<tag>)
#   add-units ID SLICES_JSON | fail REASON | done
# Every ledger write bumps updated_at and re-renders PROGRESS.md. Unit text (titles, rulings,
# notes) is untrusted: it reaches jq through --arg/--argjson/files only. JQ and JQ_PATH
# arguments are the caller's own code.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
USAGE="loop: usage: loop.sh RUN_DIR COMMAND [ARGS]"
[ $# -ge 2 ] || herd_die "$USAGE"
RUN_DIR="${1%/}"; CMD="$2"; shift 2
[ -f "$RUN_DIR/run.json" ] || herd_die "loop: no ledger: $RUN_DIR/run.json"
RUN_DIR="$(cd "$RUN_DIR" && pwd)"            # paths recorded in the ledger must be absolute
RUN_JSON="$RUN_DIR/run.json"
LOG="$RUN_DIR/orchestrator.log"

L() { herd_ledger_get "$RUN_JSON" "$1"; }
need() {                     # COUNT MIN SYNOPSIS
  [ "$1" -ge "$2" ] || herd_die "loop: usage: loop.sh RUN_DIR $3"
}
SLUG="$(L .slug)"

# A unit as the ledger first holds it. Input: the fields a map or a slice provides.
UNIT_DEF='def new_unit($slug):
  {id, uuid, title, kind, parent, blocked_by, order,
   phase: "pending", agent: ($slug + "-bs-" + (.id | ascii_downcase)), session_id: null, pane: null, tab: null,
   restarts: 0, revisions: 0, recovery: {}, no_breakdown: false,
   spec: null, plan: null, adrs: [], herd_slug: null, branch: null, base: null, carried_by: null,
   linear: {started: false, review: false, comments: []}};'
# Unit ids name branches, directories and agents: the rule of loop_uslug, anchored to the whole string.
ID_DEF='def valid_id: ascii_downcase | test("\\A[a-z][a-z0-9]*-[0-9]+\\z");'

# Never fatal: it runs after the change is saved, and the caller's notification and output must
# still happen.
render() {
  "$LOOP_SCRIPTS_DIR/progress.sh" "$RUN_DIR" || herd_log "loop: warning: could not render PROGRESS.md in $RUN_DIR"
}
# What a ledger must hold to be written: every shape progress.sh dereferences.
LEDGER_OK='length == 1 and (.[0] | type == "object"
  and (.units | type) == "array"
  and all(.units[]; type == "object" and (.id | type) == "string"
        and (.title | type | IN("null", "string"))
        and (.adrs | . == null or (type == "array" and all(.[]; type == "string"))))
  and ([.units[].id | ascii_upcase] | length == (unique | length))
  and (.skipped | . == null or (type == "array" and all(.[]; type == "object")))
  and (.pause | type | IN("null", "object")))'
log() {                      # TEXT -> one line in the log
  local text="$*"
  text="${text//$'\r'/ }"
  printf '%s %s\n' "$(herd_now)" "${text//$'\n'/ }" >> "$LOG"
}
# The only way this script writes the ledger: one atomic jq write, an optional log line, a fresh
# PROGRESS.md. The filter sees $now. A result that fails LEDGER_OK is refused.
write() {                    # LOG_TEXT|"" FILTER [jq args...]
  local text="$1" filter="$2" tmp; shift 2
  tmp="$(mktemp "$RUN_JSON.XXXXXX")"
  if jq "$@" --arg now "$(herd_now)" "($filter) | .updated_at = \$now" "$RUN_JSON" > "$tmp" \
     && jq -es "$LEDGER_OK" "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$RUN_JSON"
  else
    rm -f "$tmp"; herd_die "loop: ledger write failed (ledger unchanged): $RUN_JSON"
  fi
  [ -z "$text" ] || log "$text"
  render
}
json_str() { jq -n --arg s "$1" '$s'; }                              # STRING -> JSON string

# ---- units ---------------------------------------------------------------------
uidx() {                     # ID (any case) -> index in .units
  local i
  i="$(jq -r --arg id "$1" '[.units[].id | ascii_upcase] | index($id | ascii_upcase) // empty' "$RUN_JSON")"
  [ -n "$i" ] || herd_die "loop: no such unit: $1"
  printf '%s\n' "$i"
}
unit_get() {                 # INDEX JQ_PATH -> raw value
  jq -r --argjson i "$1" ".units[\$i] | $2" "$RUN_JSON"
}
unit_set() {                 # ID JQ_PATH JSON  (the path is relative to the unit; "." is all of it)
  local i; i="$(uidx "$1")" || exit 1
  write "" ".units[\$i] |= ($2 = \$v)" --argjson i "$i" --argjson v "$3"
}

# ---- map -----------------------------------------------------------------------
map_apply() {                # MAP_JSON -> "OK n", or PROBLEM lines and exit 3
  local file="$1" dest="$RUN_DIR/map.json" out bad count problems
  [ -f "$file" ] || herd_die "loop: no map file: $file"
  [ "$file" -ef "$dest" ] || cp -- "$file" "$dest"       # the orchestrator may write it in place
  out="$("$LOOP_SCRIPTS_DIR/order.sh" "$dest")" || exit 1
  bad="$(jq -r "$ID_DEF"' first(.units[].id | select(valid_id | not) | @json) // empty' <<<"$out")"
  [ -z "$bad" ] || herd_die "loop: invalid issue id $bad (need a Linear identifier like ABC-12)"
  count="$(jq '.units | length' <<<"$out")"
  problems="$(jq -r '.problems[] | "PROBLEM \(.type) \(.ids | join(",")) \(.detail)"
    | gsub("[\u0000-\u001f]+"; " ")' <<<"$out")"
  write "map applied: $count unit(s), $(jq '.problems | length' <<<"$out") problem(s)" \
    "$UNIT_DEF"'
     .slug as $slug
     | .units = [$o[0].units[] | new_unit($slug)]
     | .skipped = $o[0].skipped
     | if ($o[0].problems | length) == 0 then .status = (if .map_only then "mapped" else "running" end) else . end' \
    --slurpfile o <(printf '%s\n' "$out")
  if [ -n "$problems" ]; then printf '%s\n' "$problems"; exit 3; fi
  printf 'OK %s\n' "$count"
}

# ---- breakdown -----------------------------------------------------------------
add_units() {                # ID SLICES_JSON -> "OK n"
  local i id file="$2" why count
  i="$(uidx "$1")" || exit 1
  id="$(unit_get "$i" .id)"
  [ "$(unit_get "$i" '.no_breakdown == true')" = false ] || herd_die "loop: $id cannot be split again"
  [ -f "$file" ] || herd_die "loop: no slices file: $file"
  # Empty output = acceptable; otherwise the first reason. A blocker must already be satisfied
  # when its slice runs: an earlier slice, or a unit ordered no later than the split one.
  why="$(jq -rs --slurpfile run "$RUN_JSON" --arg id "$id" "$ID_DEF"'
    if length != 1 or (.[0] | type) != "array" or (.[0] | length) == 0 then "slices must be a non-empty JSON array"
    elif any(.[0][]; type != "object" or (.id | type) != "string" or (.uuid | type) != "string"
          or (.title | type) != "string" or (.blocked_by | type) != "array" or any(.blocked_by[]; type != "string"))
      then "every slice needs string id, uuid and title, and a blocked_by array of ids"
    else (.[0] | map(.id |= ascii_upcase | .blocked_by |= map(ascii_upcase))) as $s
      | (reduce $run[0].units[] as $u ({}; .[$u.id | ascii_upcase] = $u.order)) as $order
      | $order[$id | ascii_upcase] as $at
      | first(
          ($s[] | select(.id | valid_id | not) | "invalid issue id \(.id | @json)"),
          ($s[] | .id as $x | select($order | has($x)) | "slice \($x) is already a unit"),
          (range($s | length) as $n | $s[$n].id as $x | select(any($s[:$n][]; .id == $x)) | "slice \($x) is listed twice"),
          (range($s | length) as $n | $s[$n].id as $x | $s[$n].blocked_by[] as $b
           | select((any($s[:$n][]; .id == $b) or (($order | has($b)) and $order[$b] <= $at)) | not)
           | "slice \($x) is blocked by \($b | @json), which is not an earlier slice or unit"))
    end' "$file" 2>/dev/null)" || herd_die "loop: slices are not valid JSON: $file"
  [ -z "$why" ] || herd_die "loop: $why: $file"
  count="$(jq length "$file")"
  write "split $id into $count slice(s)" \
    "$UNIT_DEF"'
     .slug as $slug
     | (.units | sort_by(.order)) as $u
     | ($u | map(.id) | index($id)) as $at
     | $u[$at] as $split
     | [$s[0][] | {id: (.id | ascii_upcase), uuid, title, kind: "issue", parent: $id,
                   blocked_by: (.blocked_by | map(ascii_upcase)), order: 0}
        | new_unit($slug) | .no_breakdown = ($split.parent != null)] as $new
     | .units = ($u[:$at] + [$split | .kind = "epic-design"] + $new + $u[$at + 1:]
                 | to_entries | map(.value + {order: (.key + 1)}))' \
    --arg id "$id" --slurpfile s "$file"
  printf 'OK %s\n' "$count"
}

# ---- human pause ---------------------------------------------------------------
pause() {                    # KIND UNIT|- FILE -> pause file path
  local kind="$1" unit="$2" file="$3" i id="" unit_json=null seq dest
  case "$kind" in
    map|advisor|adr|low-confidence|revise-cap|breakdown|exec-failed|stuck|recovery-cap|skip-dependents) ;;
    *) herd_die "loop: unknown pause kind: $kind" ;;
  esac
  # a second pause would lose the first question and the phase to go back to
  [ "$(L '.pause == null')" = true ] || herd_die "loop: already paused (unpause first): $(L '.pause.file')"
  if [ "$unit" != - ]; then
    i="$(uidx "$unit")" || exit 1
    id="$(unit_get "$i" .id)"; unit_json="$(json_str "$id")"
  fi
  [ -f "$file" ] || herd_die "loop: no pause file: $file"
  seq="$(( $(L '.pause_seq') + 1 ))"
  dest="$RUN_DIR/pause-$(loop_nn "$seq").md"
  [ "$file" -ef "$dest" ] || cp -- "$file" "$dest"
  write "paused ($kind ${id:--}): $dest" \
    '.pause_seq = $seq
     | .status = "waiting-human"
     | .pause = {seq: $seq, unit: $unit, kind: $kind, file: $file, asked_at: $now}
     | .units |= map(if .id == $unit and .phase != "awaiting-human"
                     then .resume_phase = .phase | .phase = "awaiting-human" else . end)' \
    --argjson seq "$seq" --argjson unit "$unit_json" --arg kind "$kind" --arg file "$dest"
  herd_notify "linear-loop $SLUG: needs you" "$kind ${id:--}" request
  printf '%s\n' "$dest"
}
unpause() {
  [ "$(L '.pause != null')" = true ] || herd_die "loop: not paused"
  # a phase set while paused (a skip, say) is a decision: only a still-waiting unit goes back
  write "unpaused" \
    '.pause.unit as $unit
     | .pause = null
     | .status = "running"
     | .units |= map(if .id == $unit and has("resume_phase")
                     then (if .phase == "awaiting-human" then .phase = .resume_phase else . end) | del(.resume_phase)
                     else . end)'
}
ruling() {                   # TEXT -> a bullet every later advisor is given
  local file="$RUN_DIR/rulings.md" nl=$'\n'
  [ -f "$file" ] || printf '# Human rulings\n\n' > "$file"
  printf -- '- %s %s\n' "$(herd_now)" "${1//$nl/$nl  }" >> "$file"
}

# ---- Linear write-back record ----------------------------------------------------
linear_key() {               # KEY -> dies unless it is one the ledger records
  case "$1" in started|review|comment:?*) ;; *) herd_die "loop: linear key must be started, review or comment:<tag>: $1" ;; esac
}
linear_has() {               # ID KEY -> exit 0 recorded, 1 not
  local i; i="$(uidx "$1")" || exit 1
  linear_key "$2"
  case "$2" in
    comment:*) jq -e --argjson i "$i" --arg t "${2#comment:}" \
                 '.units[$i].linear.comments // [] | any(. == $t)' "$RUN_JSON" >/dev/null ;;
    *) jq -e --argjson i "$i" --arg k "$2" '.units[$i].linear[$k] == true' "$RUN_JSON" >/dev/null ;;
  esac
}
linear_mark() {              # ID KEY
  local i; i="$(uidx "$1")" || exit 1
  linear_key "$2"
  case "$2" in
    comment:*) write "" '.units[$i].linear.comments |= ((. // []) | if any(. == $t) then . else . + [$t] end)' \
                 --argjson i "$i" --arg t "${2#comment:}" ;;
    *) write "" '.units[$i].linear[$k] = true' --argjson i "$i" --arg k "$2" ;;
  esac
}

# ---- run end -------------------------------------------------------------------
run_fail() {                 # REASON
  write "RUN FAILED: $1" '.status = "failed" | .failed_reason = $reason' --arg reason "$1"
  herd_notify "linear-loop $SLUG failed" "$1" request
}
run_done() {
  write "RUN DONE" '.status = "done"'
  herd_notify "linear-loop $SLUG done" "branches are ready, not merged, not pushed" done
}

case "$CMD" in
  ledger)
    case "${1:-}" in
      get) need $# 2 "ledger get JQ"; L "$2" ;;
      set) need $# 3 "ledger set JQ JSON"; write "" "$2 = \$v" --argjson v "$3" ;;
      set-str) need $# 3 "ledger set-str JQ STRING"; write "" "$2 = \$v" --arg v "$3" ;;
      *) herd_die "loop: ledger get JQ | set JQ JSON | set-str JQ STRING" ;;
    esac ;;
  unit) need $# 1 "unit ID"; i="$(uidx "$1")"; unit_get "$i" . ;;
  unit-set) need $# 3 "unit-set ID JQ_PATH JSON"; unit_set "$1" "$2" "$3" ;;
  unit-set-str) need $# 3 "unit-set-str ID JQ_PATH STRING"; unit_set "$1" "$2" "$(json_str "$3")" ;;
  next) L '[.units[] | select(.phase != "done" and .phase != "skipped")] | sort_by(.order) | .[0].id // "NONE"' ;;
  map-apply) need $# 1 "map-apply MAP_JSON"; map_apply "$1" ;;
  add-units) need $# 2 "add-units ID SLICES_JSON"; add_units "$1" "$2" ;;
  pause) need $# 3 "pause KIND UNIT|- FILE"; pause "$1" "$2" "$3" ;;
  unpause) unpause ;;
  note) need $# 1 "note TEXT"; log "$*"; render ;;
  ruling) need $# 1 "ruling TEXT"; ruling "$*" ;;
  linear-has) need $# 2 "linear-has ID KEY"; linear_has "$1" "$2" ;;
  linear-mark) need $# 2 "linear-mark ID KEY"; linear_mark "$1" "$2" ;;
  fail) need $# 1 "fail REASON"; run_fail "$*" ;;
  done) run_done ;;
  *) herd_die "loop: unknown command: $CMD" ;;
esac
