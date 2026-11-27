#!/usr/bin/env bash
# usage: scripts/loop.sh RUN_DIR COMMAND [ARGS]
# Orchestrator helpers.
#   ledger get JQ | ledger set JQ JSON | ledger set-str JQ STRING
#   unit ID | unit-set ID JQ_PATH JSON | unit-set-str ID JQ_PATH STRING | next | map-apply MAP_JSON
#   pause KIND UNIT|- FILE | unpause | note TEXT | ruling TEXT
#   linear-has ID KEY | linear-mark ID KEY   (KEY: started | review | comment:<tag>)
#   add-units ID SLICES_JSON | fail REASON | done
#   unit-start ID | restart ID | finish-agent ID | bump ID COUNTER | check-bs ID | archive ID
#   outbox-next ID | inbox-write ID NN FILE | inbox-delivered ID NN | adr-next
#   prompt-wait NAME TEXT [TIMEOUT_MS] | wait NAME [TIMEOUT_MS] | screen NAME [LINES] | keys NAME KEY...
#   exec ID | exec-resume ID | herd-status ID | unit-done ID | unit-skip ID
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

# ---- one unit's files ----------------------------------------------------------
unit_ctx() {                 # ID -> sets I, UNIT (the ledger's id), USLUG, UDIR
  I="$(uidx "$1")" || exit 1
  UNIT="$(unit_get "$I" .id)"
  USLUG="$(loop_uslug "$UNIT")" || exit 1                # the only thing that names the directory
  UDIR="$RUN_DIR/units/$USLUG"
}
nn_ok() { [[ "$1" =~ ^[0-9][0-9]$ ]] || herd_die "loop: message number must be two digits: $1"; }

# ---- outbox / inbox ------------------------------------------------------------
outbox_next() {              # ID -> FAILED | DONE | ASK NN KIND PATH | PENDING-DELIVERY NN PATH | NONE
  unit_ctx "$1"
  if [ -f "$UDIR/bs.failed" ]; then echo FAILED; return; fi
  if [ -f "$UDIR/bs.done" ]; then echo DONE; return; fi
  local f nn="" kind
  for f in "$UDIR"/outbox/[0-9][0-9].md; do              # glob order: the last one is the highest
    if [ -f "$f" ]; then nn="${f##*/}"; nn="${nn%.md}"; fi
  done
  if [ -z "$nn" ]; then echo NONE; return; fi
  if [ ! -f "$UDIR/inbox/$nn.md" ]; then
    kind="$(sed -n '1s/^kind:[[:space:]]*//p' "$UDIR/outbox/$nn.md" | sed 's/[[:space:]]*$//')"
    case "$kind" in question|approaches|playback|breakdown|spec-ready) ;; *) kind=unknown ;; esac
    printf 'ASK %s %s %s\n' "$nn" "$kind" "$UDIR/outbox/$nn.md"
  elif [ ! -f "$UDIR/inbox/$nn.delivered" ]; then
    printf 'PENDING-DELIVERY %s %s\n' "$nn" "$UDIR/inbox/$nn.md"
  else
    echo NONE
  fi
}
inbox_write() {              # ID NN FILE -> inbox path
  local nn="$2" file="$3" tmp
  nn_ok "$nn"; unit_ctx "$1"
  [ -f "$UDIR/outbox/$nn.md" ] || herd_die "loop: no message to answer: $UDIR/outbox/$nn.md"
  [ -f "$file" ] || herd_die "loop: no answer file: $file"
  mkdir -p "$UDIR/inbox"
  tmp="$(mktemp "$UDIR/inbox/.$nn.XXXXXX")"
  # the marker goes before the new text arrives: a rewritten answer is sent again
  if ! { cat -- "$file" > "$tmp" && rm -f "$UDIR/inbox/$nn.delivered" && mv "$tmp" "$UDIR/inbox/$nn.md"; }; then
    rm -f "$tmp"; herd_die "loop: could not write $UDIR/inbox/$nn.md"
  fi
  log "answered $UNIT message $nn"
  printf '%s\n' "$UDIR/inbox/$nn.md"
}
inbox_delivered() {          # ID NN
  nn_ok "$2"; unit_ctx "$1"
  [ -f "$UDIR/inbox/$2.md" ] || herd_die "loop: no answer to deliver: $UDIR/inbox/$2.md"
  : > "$UDIR/inbox/$2.delivered"
}

# ---- ADRs and artifacts ----------------------------------------------------------
adr_next() {                 # -> NNNN, one above the stack tip and the drafts in the main checkout
  local root adr wt d f base max=0
  root="$(L .root)"; adr="$(loop_adr_dir "$root")" || exit 1
  wt="$(L '.design_worktree // ""')"
  for d in ${wt:+"$wt/$adr"} "$root/$adr"; do
    for f in "$d"/[0-9][0-9][0-9][0-9]-*.md; do
      [ -f "$f" ] || continue
      base="${f##*/}"
      if (( 10#${base:0:4} > max )); then max=$(( 10#${base:0:4} )); fi    # 10#: 0008 is not octal
    done
  done
  printf '%04d\n' "$(( max + 1 ))"
}
# For a path an agent named. True only for a regular file really inside ROOT/DIR: relative, no
# "..", not a symlink, and no directory on the way that leads elsewhere.
file_under() {               # ROOT DIR REL
  local root="$1" dir="${2#./}" rel="$3" base real
  case "$rel" in /*|..|../*|*/..|*/../*|*[[:cntrl:]]*) return 1 ;; esac
  case "$rel" in "$dir"/?*) ;; *) return 1 ;; esac
  [ -f "$root/$rel" ] && [ ! -L "$root/$rel" ] || return 1
  base="$(cd "$root/$dir" 2>/dev/null && pwd -P)" || return 1
  real="$(cd "$(dirname "$root/$rel")" 2>/dev/null && pwd -P)" || return 1
  case "$real/" in "$base"/*) return 0 ;; esac
  return 1
}
unit_files() {               # INDEX ADR_DIR -> "<allowed dir><TAB><path>" for its spec, plan and ADRs
  jq -r --argjson i "$1" --arg adr "$2" '
    .units[$i] | ["docs/superpowers/specs", .spec], ["docs/superpowers/plans", .plan], ((.adrs // [])[] | [$adr, .])
    | select(.[1] != null) | @tsv' "$RUN_JSON"
}
archive() {                  # ID: copy spec, plan and ADRs to units/<uslug>/artifacts/
  local root adr dir rel item items=()
  unit_ctx "$1"
  root="$(L .root)"; adr="$(loop_adr_dir "$root")" || exit 1
  # The ledger's paths came from an agent, so each is checked again.
  while IFS= read -r item; do items+=("$item"); done < <(unit_files "$I" "$adr")
  # all checked before the first copy (@tsv escapes tabs and newlines, so such a path fails too)
  for item in ${items[@]+"${items[@]}"}; do
    dir="${item%%$'\t'*}"; rel="${item#*$'\t'}"
    file_under "$root" "$dir" "$rel" || herd_die "loop: cannot archive $rel: not a file under $root/$dir"
  done
  for item in ${items[@]+"${items[@]}"}; do
    rel="${item#*$'\t'}"
    mkdir -p "$(dirname "$UDIR/artifacts/$rel")"
    rm -f "$UDIR/artifacts/$rel"
    cp -- "$root/$rel" "$UDIR/artifacts/$rel" || herd_die "loop: could not archive $rel"
  done
}

# ---- the brainstormer's sentinel ---------------------------------------------------
sentinel_value() {           # FILE KEY -> the first "KEY: value" line's value, trimmed
  sed -n "/^$2:/{s/^$2:[[:space:]]*//;s/[[:space:]]*\$//;p;q;}" "$1"
}
not_done() { printf 'NONE %s\n' "$(printf '%s' "$1" | tr -d '[:cntrl:]')"; exit 3; }
# A refusal never changes the ledger: the orchestrator decides what a bad sentinel means.
check_bs() {                 # ID -> DONE (0) | FAILED + text (2) | NONE why (3)
  local root adr want line spec plan adrs a list=() found=() adrs_json
  unit_ctx "$1"
  root="$(L .root)"; adr="$(loop_adr_dir "$root")" || exit 1
  adr="${adr#./}"
  if [ -f "$UDIR/bs.failed" ]; then echo FAILED; cat "$UDIR/bs.failed"; exit 2; fi
  if [ ! -f "$UDIR/bs.done" ]; then
    echo NONE
    "$HERDR_BIN" agent read "$(unit_get "$I" .agent)" --source visible 2>/dev/null || true
    exit 3
  fi
  want="$(herd_model_family "$(L .models.brainstorm)")"
  line="$(head -1 "$UDIR/bs.done" | tr '[:upper:]' '[:lower:]')"
  case "$line" in model:*"$want"*) ;; *) echo "FAILED model-mismatch"; exit 2 ;; esac
  spec="$(sentinel_value "$UDIR/bs.done" spec)"
  plan="$(sentinel_value "$UDIR/bs.done" plan)"
  adrs="$(sentinel_value "$UDIR/bs.done" adrs)"
  [ -n "$spec" ] && [ -n "$plan" ] && [ -n "$adrs" ] || not_done bad-sentinel
  file_under "$root" docs/superpowers/specs "$spec" || not_done spec-missing
  if [ "$(unit_get "$I" .kind)" = epic-design ]; then
    [ "$plan" = none ] || not_done unexpected-plan
    plan=""
  else
    file_under "$root" docs/superpowers/plans "$plan" || not_done plan-missing
    grep -qF -- "$spec" "$root/$plan" || not_done plan-does-not-cite-spec
  fi
  if [ "$adrs" != none ]; then
    IFS=, read -ra list <<<"$adrs"                       # read, not word splitting: no globbing
    for a in ${list[@]+"${list[@]}"}; do
      a="${a#"${a%%[![:space:]]*}"}"; a="${a%"${a##*[![:space:]]}"}"
      [ -n "$a" ] || continue
      file_under "$root" "$adr" "$a" || not_done "adr-missing: $a"
      found+=("$a")
    done
  fi
  adrs_json="$(jq -nc '$ARGS.positional' --args ${found[@]+"${found[@]}"})"
  write "brainstorm gate passed: $UNIT" \
    '.units[$i] |= (.spec = $spec | .plan = (if $plan == "" then null else $plan end) | .adrs = $adrs)' \
    --argjson i "$I" --arg spec "$spec" --arg plan "$plan" --argjson adrs "$adrs_json"
  archive "$UNIT"
  echo DONE
}

# ---- the brainstormer session --------------------------------------------------------
# unit-start force-checks-out and cleans this directory, so it must be provably the disposable
# one: this run's own <root>/.claude/worktrees/<slug>-design, a linked worktree of this repo,
# never the main checkout or the run's root.
design_worktree() {          # -> canonical path, or dies
  local wt real root list
  wt="$(L '.design_worktree // ""')"
  [ -n "$wt" ] || herd_die "loop: design worktree is not set in the ledger"
  real="$(cd "$wt" 2>/dev/null && pwd -P)" || herd_die "loop: design worktree is missing: $wt"
  root="$(cd "$(L .root)" 2>/dev/null && pwd -P)" || herd_die "loop: design worktree check failed, no repo root: $(L .root)"
  [ "$real" != "$root" ] || herd_die "loop: design worktree is the repo root: $wt"
  [ "$real" = "$root/.claude/worktrees/$SLUG-design" ] \
    || herd_die "loop: design worktree is not this run's $root/.claude/worktrees/$SLUG-design: $wt"
  [ "$(git -C "$real" rev-parse --show-toplevel 2>/dev/null)" = "$real" ] \
    || herd_die "loop: design worktree is not the top of a git worktree: $wt"
  list="$(git -C "$root" worktree list --porcelain | sed -n 's/^worktree //p' | sed 1d)"   # 1st = main checkout
  grep -qxF -- "$real" <<<"$list" || herd_die "loop: design worktree is not a linked worktree of $root: $wt"
  printf '%s\n' "$real"
}
render_brief() {             # (after unit_ctx) -> brief path
  local root wt adr next kind kind_rules prior="" rulings=none other s out="$UDIR/brief.md"
  root="$(L .root)"; wt="$(L .design_worktree)"
  adr="$(loop_adr_dir "$root")" || exit 1
  next="$(adr_next)" || exit 1
  kind="$(unit_get "$I" .kind)"
  case "$kind" in
    issue) kind_rules="This unit is an \`issue\`: a spec, then a plan. It gets a plan, however small the ticket, because execution needs a plan file. Once the inbox approves the spec, invoke \`superpowers:writing-plans\` and write the plan. The plan is not sent for approval. The plan must contain the spec's repo-relative path. If the inbox approves a breakdown instead, this unit becomes an epic design: write only a short design doc (shared decisions, boundaries between children, what each child owns, ADR drafts), send it as \`spec-ready\`, and after approval write no plan and put \`plan: none\` in the sentinel." ;;
    epic-design) kind_rules="This unit is an \`epic-design\`: it stops at the approved design doc. Write a short design doc only: shared decisions, boundaries between children, what each child owns, ADR drafts. Do not invoke \`superpowers:writing-plans\`, write no plan and execute nothing. After the inbox approves the doc, write the sentinel with \`plan: none\`." ;;
    *) herd_die "loop: unknown unit kind: $kind" ;;
  esac
  while IFS= read -r other; do
    s="$(loop_uslug "$other")" || exit 1
    [ ! -d "$RUN_DIR/units/$s/artifacts" ] || prior="$prior${prior:+$'\n'}$RUN_DIR/units/$s/artifacts"
  done < <(jq -r --argjson i "$I" '.units[$i].order as $o | .units | sort_by(.order)[] | select(.order < $o) | .id' "$RUN_JSON")
  [ ! -f "$RUN_DIR/rulings.md" ] || rulings="$RUN_DIR/rulings.md"
  mkdir -p "$UDIR/outbox" "$UDIR/inbox"
  # Paths, never file contents: no ticket text goes into the brief, and render.sh would refuse
  # a {{KEY}} found inside any value.
  "$HERD_SCRIPTS_DIR/render.sh" "$LOOP_TEMPLATES_DIR/brainstorm-brief.tmpl.md" \
    SLUG="$SLUG" UNIT_ID="$UNIT" KIND="$kind" MODEL="$(L .models.brainstorm)" ROOT="$root" \
    DESIGN_WORKTREE="$wt" ISSUE_FILE="$UDIR/issue.md" OUTBOX="$UDIR/outbox" INBOX="$UDIR/inbox" \
    SPEC_DIR="$root/docs/superpowers/specs" PLAN_DIR="$root/docs/superpowers/plans" \
    ADR_DIR_MAIN="$root/$adr" ADR_DIR_TIP="$wt/$adr" ADR_NEXT="$next" \
    ADR_TEMPLATE="$LOOP_TEMPLATES_DIR/adr.default.md" PRIOR_ARTIFACTS="${prior:-none}" RULINGS="$rulings" \
    SENTINEL_DONE="$UDIR/bs.done" SENTINEL_FAILED="$UDIR/bs.failed" KIND_RULES="$kind_rules" > "$out" \
    || herd_die "loop: could not render the brief: $out"
  printf '%s\n' "$out"
}
start_agent() {              # NAME PANE [extra claude args...]
  local name="$1" pane="$2"; shift 2
  herd_worker_flags "$(L .models.brainstorm)" "$(L .root)"
  # appended to herd's flags, which end in --disallowedTools: the brainstormer writes no git state
  HERD_FLAGS+=("Bash(git commit:*)" "Bash(git add:*)" "Bash(git checkout:*)" "Bash(git switch:*)"
    "Bash(git stash:*)" "Bash(git reset:*)")
  herd_agent_start "$name" "$pane" -- "$@" "${HERD_FLAGS[@]}" >/dev/null
}
record_session() {           # NAME (after unit_ctx)
  local sid; sid="$(herd_agent_session_id "$1")"
  [ -z "$sid" ] || write "" '.units[$i].session_id = $s' --argjson i "$I" --arg s "$sid"
}
unit_start() {               # ID -> brief path
  local name wt tip sha ws brief tab_json pane tab
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR  # they would redirect "git -C" below
  unit_ctx "$1"
  [ -f "$UDIR/issue.md" ] || herd_die "loop: write the issue snapshot first: $UDIR/issue.md"
  name="$(unit_get "$I" .agent)"
  ! herd_agent_live "$name" || herd_die "loop: $name is already live (finish-agent $UNIT first, or wait for it)"
  wt="$(design_worktree)" || exit 1
  tip="$(L '.stack_tip // ""')"
  sha="$(git -C "$wt" rev-parse --verify -q --end-of-options "$tip^{commit}")" \
    || herd_die "loop: stack tip is not a commit: $tip"
  ws="$(L .workspace_id)"
  { git -C "$wt" checkout -q -f --detach "$sha" && git -C "$wt" clean -q -f -d; } >&2 \
    || herd_die "loop: design worktree could not be reset to $tip: $wt"
  rm -f "$UDIR/bs.done" "$UDIR/bs.failed"                # stale sentinels from an earlier attempt
  brief="$(render_brief)" || exit 1
  tab_json="$("$HERDR_BIN" tab create --workspace "$ws" --cwd "$wt" --label "bs-$USLUG" --no-focus)"
  pane="$(herd_json_field "$tab_json" '.result.root_pane.pane_id')"; tab="$(herd_json_field "$tab_json" '.result.tab.tab_id')"
  [ -n "$pane" ] && [ -n "$tab" ] || herd_die "loop: unexpected tab create response: $tab_json"
  if ! start_agent "$name" "$pane"; then
    "$HERDR_BIN" tab close "$tab" >/dev/null 2>&1 || true          # don't strand the tab we just created
    herd_die "loop: could not start $name in $pane"
  fi
  write "started $name in $pane" \
    '.units[$i] |= (.pane = $pane | .tab = $tab | .session_id = null | .base = $base | .phase = "brainstorming")' \
    --argjson i "$I" --arg pane "$pane" --arg tab "$tab" --arg base "$tip"
  record_session "$name"
  printf '%s\n' "$brief"
}
restart_unit() {             # ID -> brief path | RESTART-LIMIT (6)
  local name pane sid restarts brief
  unit_ctx "$1"
  name="$(unit_get "$I" .agent)"; pane="$(unit_get "$I" '.pane // ""')"; sid="$(unit_get "$I" '.session_id // ""')"
  restarts="$(unit_get "$I" '.restarts // 0')"
  [ "$restarts" -lt 2 ] || { echo "RESTART-LIMIT"; exit 6; }
  [ -n "$pane" ] || herd_die "loop: $UNIT has no pane (unit-start it first)"
  if herd_agent_live "$name"; then herd_agent_exit "$name" || herd_die "loop: could not exit $name"; fi
  rm -f "$UDIR/bs.done" "$UDIR/bs.failed"      # a stale sentinel would speak for the previous attempt
  brief="$(render_brief)" || exit 1            # the design worktree is left as it is
  if [ -n "$sid" ] && start_agent "$name" "$pane" --resume "$sid"; then :
  else
    start_agent "$name" "$pane" || herd_die "loop: could not restart $name"
    write "" '.units[$i].session_id = null' --argjson i "$I"
  fi
  write "restarted $name (restart $(( restarts + 1 )))" '.units[$i].restarts = $n' \
    --argjson i "$I" --argjson n "$(( restarts + 1 ))"
  record_session "$name"
  printf '%s\n' "$brief"
}
finish_agent() {             # ID
  local name tab
  unit_ctx "$1"
  name="$(unit_get "$I" .agent)"; tab="$(unit_get "$I" '.tab // ""')"
  herd_agent_exit "$name" || herd_log "loop: $name did not exit cleanly; closing its tab anyway"
  if [ -n "$tab" ]; then "$HERDR_BIN" tab close "$tab" >/dev/null 2>&1 || true; fi
  log "finished $name (tab ${tab:-unknown})"
}
bump() {                     # ID COUNTER -> new count
  [[ "$2" =~ ^[a-z_]+$ ]] || herd_die "loop: counter must be [a-z_]+: $2"
  unit_ctx "$1"
  write "" '.units[$i].recovery[$c] = ((.units[$i].recovery[$c] // 0) + 1)' --argjson i "$I" --arg c "$2"
  jq -r --argjson i "$I" --arg c "$2" '.units[$i].recovery[$c]' "$RUN_JSON"
}

# ---- parent chains ---------------------------------------------------------------
# A parent that collapsed into its only child has no unit, so its own parent is known only to
# map.json. A missing or unreadable map ends the chain there.
CHAIN_DEF='def chain($id):               # ID -> its ancestors, nearest first; a loop ends the walk
  ($map + (reduce .units[] as $u ({}; .[$u.id | ascii_upcase] = (($u.parent // "") | ascii_upcase)))) as $P
  | [$id | ascii_upcase]
  | until(($P[.[-1]] // "") as $p | $p == "" or any(.[]; . == $p); . + [$P[.[-1]]])
  | .[1:];'
map_parents() {              # -> {"ID": "PARENT ID"} from map.json, or {}
  local out
  out="$(jq -sc '[.[0].issues[]? | objects | select((.id | type) == "string" and (.parent | type) == "string")
           | {key: (.id | ascii_upcase), value: (.parent | ascii_upcase)}] | from_entries' \
    "$RUN_DIR/map.json" 2>/dev/null)" || out='{}'
  printf '%s\n' "$out"
}

# ---- execution (one herd run per issue unit) --------------------------------------
herd_ledger() {              # (after unit_ctx) -> the unit's herd ledger path
  printf '%s/.claude/herd-runs/%s/run.json\n' "$(L .root)" "$USLUG"
}
exec_line() { printf 'HERD-RUN %s ORCH %s-orch\n' "$(herd_ledger)" "$USLUG"; }
# herd finds the repo from the cwd and reports on stdout, which is ours: its report goes to stderr.
herd_launch() {              # launch.sh args...; exits with herd's status when it fails
  local root; root="$(L .root)"
  ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    cd "$root" && "$HERD_SCRIPTS_DIR/launch.sh" "$@" ) >&2 || exit $?
}
carry() {                    # ROOT WORKTREE REL: copy if missing; never through a link out of the worktree
  local dest="$2/$3" top dir real
  top="$(cd "$2" 2>/dev/null && pwd -P)" || return 1
  dir="$(dirname "$dest")"
  while [ ! -e "$dir" ] && [ ! -L "$dir" ]; do dir="$(dirname "$dir")"; done
  real="$(cd "$dir" 2>/dev/null && pwd -P)" || return 1
  case "$real/" in "$top"/*) ;; *) return 1 ;; esac
  if [ -e "$dest" ] || [ -L "$dest" ]; then return 0; fi
  mkdir -p "$(dirname "$dest")" && cp -- "$1/$3" "$dest"
}
# What exec and exec-resume share. A launch happens between the two halves.
exec_prepare() {             # (after unit_ctx) refuses what cannot be executed; sets PLAN, EPICS, ITEMS
  local root adr item dir rel e
  EPICS=(); ITEMS=()
  root="$(L .root)"; adr="$(loop_adr_dir "$root")" || exit 1
  [ "$(unit_get "$I" .kind)" = issue ] || herd_die "loop: $UNIT is not an issue unit: only those are executed"
  PLAN="$(unit_get "$I" '.plan // ""')"
  [ -n "$PLAN" ] && [ -n "$(unit_get "$I" '.spec // ""')" ] || herd_die "loop: $UNIT needs a spec and a plan before exec"
  # finished epic designs above this unit that no branch carries yet
  while IFS= read -r e; do EPICS+=("$e"); done < <(jq -r --argjson i "$I" --argjson map "$(map_parents)" "$CHAIN_DEF"'
    chain(.units[$i].id) as $up
    | .units | to_entries[]
    | select(.value.kind == "epic-design" and .value.phase == "done" and .value.carried_by == null
             and (.value.id | ascii_upcase | IN($up[])))
    | .key' "$RUN_JSON")
  # everything is checked before the launch: after it, exec cannot be run again (the branch exists)
  for e in "$I" ${EPICS[@]+"${EPICS[@]}"}; do
    while IFS= read -r item; do
      dir="${item%%$'\t'*}"; rel="${item#*$'\t'}"
      file_under "$root" "$dir" "$rel" || herd_die "loop: cannot carry $rel: not a file under $root/$dir"
      ITEMS+=("$e"$'\t'"$item")
    done < <(unit_files "$e" "$adr")
  done
}
exec_record() {              # LOG_NOTE (after exec_prepare and a launch) carries the files, records the run
  local root wt item dir rel e ok carried_json carried=()
  root="$(L .root)"
  # herd is running now: a copy that fails is logged, and the run is recorded all the same
  wt="$root/.claude/worktrees/$USLUG"
  for e in "$I" ${EPICS[@]+"${EPICS[@]}"}; do
    ok=1
    for item in ${ITEMS[@]+"${ITEMS[@]}"}; do
      [ "${item%%$'\t'*}" = "$e" ] || continue
      item="${item#*$'\t'}"; dir="${item%%$'\t'*}"; rel="${item#*$'\t'}"
      [ "$dir" != docs/superpowers/plans ] || continue          # herd brings the plan itself
      if ! carry "$root" "$wt" "$rel"; then
        ok=0; log "$UNIT: not carried $rel into $wt"; herd_log "loop: warning: not carried $rel into $wt"
      fi
    done
    if [ "$e" != "$I" ] && [ "$ok" = 1 ]; then carried+=("$(unit_get "$e" .id)"); fi
  done
  carried_json="$(jq -nc '$ARGS.positional' --args ${carried[@]+"${carried[@]}"})"
  write "executing $UNIT on feat/$USLUG ($1)" \
    '.units[$i] |= (.herd_slug = $slug | .branch = "feat/" + $slug | .phase = "executing")
     | .units |= map(if .id | IN($carried[]) then .carried_by = $unit else . end)' \
    --argjson i "$I" --arg slug "$USLUG" --arg unit "$UNIT" --argjson carried "$carried_json"
}
exec_unit() {                # ID -> HERD-RUN line
  local tip flag v flags=()
  unit_ctx "$1"
  exec_prepare
  tip="$(L '.stack_tip // ""')"
  [ -n "$tip" ] || herd_die "loop: no stack tip in the ledger"
  for flag in worker_model:--worker-model review_model:--review-model execution:--execution; do
    v="$(L ".herd.${flag%%:*} // \"\"")"
    [ -z "$v" ] || flags+=("${flag#*:}" "$v")
  done

  herd_launch --slug "$USLUG" --base "$tip" ${flags[@]+"${flags[@]}"} "$PLAN"
  exec_record "base $tip"
  exec_line
}
# A unit with no branch is one whose exec launch failed part way (or was cut off before the
# ledger write): once herd resumes it, it is recorded here as exec would have.
exec_resume() {              # ID -> HERD-RUN line
  local phase
  unit_ctx "$1"
  if [ -n "$(unit_get "$I" '.branch // ""')" ]; then
    herd_launch --resume "$USLUG"
  else
    phase="$(unit_get "$I" .phase)"
    case "$phase" in done|skipped) herd_die "loop: $UNIT is $phase and was never recorded: not resuming it" ;; esac
    exec_prepare
    herd_launch --resume "$USLUG"
    exec_record "resumed"
  fi
  exec_line
}
herd_status() {              # ID -> "<status> [<failed stage>]" | missing
  local j; unit_ctx "$1"; j="$(herd_ledger)"
  if [ ! -f "$j" ]; then echo missing; return; fi
  jq -er '[.status, .failed_stage // empty] | join(" ")' "$j" 2>/dev/null || herd_die "loop: unreadable herd ledger: $j"
}

# ---- unit end ----------------------------------------------------------------------
# Deleting is the exception: "delete" is printed only when every check positively passed; any
# other output, and any git failure, keeps the file.
copy_verdict() {             # ROOT BRANCH DIR REL -> "delete", or why the main-checkout copy stays
  local root="$1" branch="$2" dir="$3" rel="$4" ref="refs/heads/$2" real top rc shipped here
  file_under "$root" "$dir" "$rel" || { echo "not a regular file under $dir"; return; }
  real="$(cd "$root" && pwd -P)" && top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" && [ "$top" = "$real" ] \
    || { echo "git error: $root is not confirmed as the top of a checkout"; return; }
  # icase: on a case-insensitive disk another spelling names the same tracked file
  rc=0; git -C "$root" ls-files --error-unmatch -- ":(icase,literal)$rel" >/dev/null 2>&1 || rc=$?
  case "$rc" in 1) ;; 0) echo tracked; return ;; *) echo "git error: ls-files exit $rc"; return ;; esac
  rc=0; git -C "$root" check-ignore -q -- "$rel" >/dev/null 2>&1 || rc=$?
  case "$rc" in 1) ;; 0) echo ignored; return ;; *) echo "git error: check-ignore exit $rc"; return ;; esac
  git -C "$root" cat-file -e "$ref:$rel" 2>/dev/null || { echo "not on $branch (or git error)"; return; }
  shipped="$(git -C "$root" rev-parse --verify -q "$ref:$rel" 2>/dev/null)" && [ -n "$shipped" ] \
    || { echo "git error: rev-parse"; return; }
  here="$(git -C "$root" hash-object --no-filters -- "$rel" 2>/dev/null)" && [ -n "$here" ] \
    || { echo "git error: hash-object"; return; }
  [ "$here" = "$shipped" ] || { echo "differs from $branch: it holds work that never shipped"; return; }
  echo delete
}
cleanup() {                  # BRANCH (after unit_ctx): drop the main-checkout copies the branch now holds
  local branch="$1" root adr e item dir rel verdict
  root="$(L .root)"; adr="$(loop_adr_dir "$root")" || exit 1
  while IFS= read -r e; do
    while IFS= read -r item; do
      dir="${item%%$'\t'*}"; rel="${item#*$'\t'}"
      verdict="$(copy_verdict "$root" "$branch" "$dir" "$rel")" || verdict="check failed"
      if [ "$verdict" != delete ]; then log "$UNIT cleanup: kept $rel: $verdict"
      elif rm -f -- "$root/$rel"; then log "$UNIT cleanup: deleted $root/$rel (untracked, on $branch)"
      else log "$UNIT cleanup: kept $rel: could not delete it"
      fi
    done < <(unit_files "$e" "$adr")
  done < <(jq -r --argjson i "$I" --arg unit "$UNIT" '
    $i, (.units | to_entries[] | select(.value.kind == "epic-design" and .value.carried_by == $unit) | .key)' "$RUN_JSON")
}
unit_done() {                # ID -> DONE <stack tip>
  local branch status j
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR  # they would redirect "git -C" in cleanup
  unit_ctx "$1"
  if [ "$(unit_get "$I" .kind)" != issue ]; then
    write "unit done: $UNIT" '.units[$i].phase = "done"' --argjson i "$I"
  # a repeat must not pull the stack tip back below units finished since
  elif [ "$(unit_get "$I" .phase)" != done ]; then
    branch="$(unit_get "$I" '.branch // ""')"
    [ -n "$branch" ] || herd_die "loop: $UNIT has not been executed (no branch in the ledger)"
    j="$(herd_ledger)"
    status="$(jq -r '.status // "unknown"' "$j" 2>/dev/null)" || status=missing
    [ "$status" = done ] || herd_die "loop: $UNIT: herd run is not done (${status:-unknown}): $j"
    herd_agent_exit "$USLUG-orch" || herd_log "loop: $USLUG-orch did not exit; leaving it"
    cleanup "$branch"
    write "unit done: $UNIT, stack tip $branch" '.units[$i].phase = "done" | .stack_tip = $b' \
      --argjson i "$I" --arg b "$branch"
  fi
  printf 'DONE %s\n' "$(L .stack_tip)"
}
unit_skip() {                # ID -> DEPENDENTS <ids...>
  local deps
  unit_ctx "$1"
  deps="$(jq -r --arg id "$UNIT" --argjson map "$(map_parents)" "$CHAIN_DEF"'
    ($id | ascii_upcase) as $x | . as $run
    | [.units | sort_by(.order)[]
       | select(.phase != "done" and .phase != "skipped" and (.id | ascii_upcase) != $x)
       | .id as $u
       | select(any((.blocked_by // [])[]; ascii_upcase == $x) or any($run | chain($u)[]; . == $x))
       | $u] | join(" ")' "$RUN_JSON")"
  # an unfinished carrier never ships what it carried: the next child to execute takes it
  write "skipped $UNIT" \
    '(.units[$i].phase == "done") as $shipped
     | .units[$i].phase = "skipped"
     | if $shipped then . else .units |= map(if .carried_by == $unit then .carried_by = null else . end) end' \
    --argjson i "$I" --arg unit "$UNIT"
  printf 'DEPENDENTS%s\n' "${deps:+ $deps}"
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
  unit-start) need $# 1 "unit-start ID"; unit_start "$1" ;;
  restart) need $# 1 "restart ID"; restart_unit "$1" ;;
  finish-agent) need $# 1 "finish-agent ID"; finish_agent "$1" ;;
  bump) need $# 2 "bump ID COUNTER"; bump "$1" "$2" ;;
  check-bs) need $# 1 "check-bs ID"; check_bs "$1" ;;
  archive) need $# 1 "archive ID"; archive "$1" ;;
  outbox-next) need $# 1 "outbox-next ID"; outbox_next "$1" ;;
  inbox-write) need $# 3 "inbox-write ID NN FILE"; inbox_write "$1" "$2" "$3" ;;
  inbox-delivered) need $# 2 "inbox-delivered ID NN"; inbox_delivered "$1" "$2" ;;
  adr-next) adr_next ;;
  exec) need $# 1 "exec ID"; exec_unit "$1" ;;
  exec-resume) need $# 1 "exec-resume ID"; exec_resume "$1" ;;
  herd-status) need $# 1 "herd-status ID"; herd_status "$1" ;;
  unit-done) need $# 1 "unit-done ID"; unit_done "$1" ;;
  unit-skip) need $# 1 "unit-skip ID"; unit_skip "$1" ;;
  prompt-wait) need $# 2 "prompt-wait NAME TEXT [TIMEOUT_MS]"; herd_agent_prompt_wait "$@" ;;
  wait) need $# 1 "wait NAME [TIMEOUT_MS]"; herd_agent_wait "$@" ;;
  screen) need $# 1 "screen NAME [LINES]"; herd_agent_screen "$@" ;;
  keys) need $# 2 "keys NAME KEY..."; herd_agent_keys "$@" ;;
  *) herd_die "loop: unknown command: $CMD" ;;
esac
