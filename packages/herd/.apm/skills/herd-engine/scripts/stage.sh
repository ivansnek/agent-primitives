#!/usr/bin/env bash
# Orchestrator helpers (spec §8). usage: stage.sh RUN_DIR COMMAND [ARGS]
#   spawn-plan N | spawn-audit N | spawn-review N | prompt-wait NAME TEXT [TIMEOUT_MS] | wait NAME [TIMEOUT_MS]
#   check N plan|audit|review | screen NAME [LINES] | keys NAME KEY... | restart N plan|audit|review
#   finish-agent NAME | fail STAGE REASON | done | note TEXT | bump N plan|audit|review COUNTER
#   ledger get JQ | ledger set JQ JSON | ledger set-str JQ STRING
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
RUN_DIR="${1:?usage: stage.sh RUN_DIR COMMAND [ARGS]}"; CMD="${2:?usage: stage.sh RUN_DIR COMMAND [ARGS]}"; shift 2
RUN_JSON="$RUN_DIR/run.json"; [ -f "$RUN_JSON" ] || herd_die "no ledger: $RUN_JSON"
LOG="$RUN_DIR/orchestrator.log"

L() { herd_ledger_get "$RUN_JSON" "$1"; }
S() { herd_ledger_set "$RUN_JSON" "$1" "$2"; }
SS() { herd_ledger_set_str "$RUN_JSON" "$1" "$2"; }
SLUG="$(L .slug)"; WT="$(L .worktree)"; WS="$(L .workspace_id)"; BASE="$(L .base)"; BRANCH="$(L .branch)"
ROOT_REPO="$(L .root)"
EXECUTION="$(herd_execution_mode "$(herd_ledger_execution "$RUN_JSON")")"   # dies on a hand-edited ledger value
TOTAL="$(L '.plans | length')"

note() { printf '%s %s\n' "$(herd_now)" "$*" >> "$LOG"; }
idx() {                      # N -> zero-based index, validated
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le "$TOTAL" ] || herd_die "plan index out of range: $1 (1..$TOTAL)"
  echo $(( $1 - 1 ))
}
kind_ok() { case "$1" in plan|audit|review) ;; *) herd_die "kind must be plan, audit or review: $1" ;; esac; }
agent_of() { L ".plans[$1].$2.agent"; }          # IDX KIND
sentinel() { echo "$RUN_DIR/$2-$1"; }            # N KIND -> path prefix (…/plan-N, …/audit-N or …/review-N)

exit_agent() { herd_agent_exit "$1"; }   # NAME -> 0 once no live agent has the name

start_worker() {             # IDX KIND PANE [extra claude args...]
  local i="$1" kind="$2" pane="$3"; shift 3
  local name model sid; name="$(agent_of "$i" "$kind")"; model="$(herd_stage_model "$RUN_JSON" "$kind")"
  herd_worker_flags "$model" "$ROOT_REPO"
  # Appended to the system prompt, plan workers only, so it survives /compact: the run's pinned
  # execution rules, then the repo profile's style when it configures one. As a file, not
  # inline: herdr types this command into the pane and the tty drops it past 1024 bytes while
  # the shell is still starting (see herd_pane_wait_prompt / herd_write_plan_append). Written in
  # THIS shell, not a $( ) substitution: a write failure inside a substitution would be lost,
  # leaving an empty --append-system-prompt-file argument and no error anywhere.
  local append=() append_file="$RUN_DIR/plan-append.txt" append_text style_text
  if [ "$kind" = plan ]; then
    append_text="$(herd_execution_rules "$EXECUTION" "$WT" "$BRANCH")" || return 1
    style_text="$(herd_plan_style "$ROOT_REPO")"
    [ -z "$style_text" ] || append_text="$append_text"$'\n\n'"$style_text"
    herd_write_plan_append "$append_file" "$append_text" >/dev/null || return 1
    append=(--append-system-prompt-file "$append_file")
  fi
  herd_agent_start "$name" "$pane" -- "$@" "${HERD_FLAGS[@]}" "${append[@]}" >/dev/null || return 1
  sid="$(herd_agent_session_id "$name")"
  if [ -n "$sid" ]; then SS ".plans[$i].$kind.session_id" "$sid"; fi
}

render_brief() {             # N KIND -> prints brief path
  local n="$1" kind="$2" i; i="$(idx "$n")"
  local plan_path title out rules standards verify; plan_path="$(L ".plans[$i].path")"; title="$(L ".plans[$i].title")"
  out="$(sentinel "$n" "$kind").brief.md"
  if [ "$kind" = plan ]; then
    rules="$(herd_execution_rules "$EXECUTION" "$WT" "$BRANCH")" || herd_die "could not render the $EXECUTION execution rules"
    "$HERD_SCRIPTS_DIR/render.sh" "$HERD_TEMPLATES_DIR/plan-brief.tmpl.md" SLUG="$SLUG" N="$n" TOTAL="$TOTAL" \
      PLAN_PATH="$plan_path" PLAN_TITLE="$title" PLAN_BASENAME="$(basename "$plan_path" .md)" \
      WORKTREE="$WT" BRANCH="$BRANCH" BASE="$BASE" MODEL="$(herd_stage_model "$RUN_JSON" plan)" \
      EXECUTION="$EXECUTION" EXECUTION_RULES="$rules" \
      SENTINEL_DONE="$(sentinel "$n" plan).done" SENTINEL_FAILED="$(sentinel "$n" plan).failed" > "$out"
  elif [ "$kind" = audit ]; then
    # resolved here, not inline: a failing $( ) inside render.sh's arguments is ignored and
    # would render the brief with an empty standards path
    standards="$(herd_security_standards "$ROOT_REPO")"; verify="$(herd_verify_text "$ROOT_REPO" "$BASE")"
    "$HERD_SCRIPTS_DIR/render.sh" "$HERD_TEMPLATES_DIR/audit-brief.tmpl.md" SLUG="$SLUG" N="$n" TOTAL="$TOTAL" \
      PLAN_TITLE="$title" WORKTREE="$WT" BRANCH="$BRANCH" BASE="$BASE" MODEL="$(herd_stage_model "$RUN_JSON" audit)" \
      RANGE="$(L ".plans[$i].audit.head_before")..HEAD" STANDARDS="$standards" VERIFY="$verify" \
      MAX_SLICES="$(herd_audit_max_slices "$ROOT_REPO")" FINDINGS="$(sentinel "$n" audit).findings.md" \
      SENTINEL_DONE="$(sentinel "$n" audit).done" SENTINEL_FAILED="$(sentinel "$n" audit).failed" > "$out"
  else
    standards="$(herd_review_standards "$ROOT_REPO")"; verify="$(herd_verify_text "$ROOT_REPO" "$BASE")"
    "$HERD_SCRIPTS_DIR/render.sh" "$HERD_TEMPLATES_DIR/review-brief.tmpl.md" SLUG="$SLUG" N="$n" TOTAL="$TOTAL" \
      PLAN_TITLE="$title" WORKTREE="$WT" BRANCH="$BRANCH" BASE="$BASE" MODEL="$(herd_stage_model "$RUN_JSON" review)" \
      RANGE="$(L ".plans[$i].review.head_before")..HEAD" STANDARDS="$standards" VERIFY="$verify" \
      FINDINGS="$(sentinel "$n" review).findings.md" AUDIT_FINDINGS="$(sentinel "$n" audit).findings.md" \
      SENTINEL_DONE="$(sentinel "$n" review).done" SENTINEL_FAILED="$(sentinel "$n" review).failed" > "$out"
  fi
  printf '%s\n' "$out"
}

spawn() {                    # N KIND
  local n="$1" kind="$2" i; i="$(idx "$n")"
  local name label tab_json pane tab; name="$(agent_of "$i" "$kind")"; label="$kind-$n"
  ! herd_agent_live "$name" || herd_die "agent $name is already live (finish-agent $name first, or wait for it)"
  rm -f "$(sentinel "$n" "$kind").done" "$(sentinel "$n" "$kind").failed"    # stale sentinels from a failed attempt
  # a fresh agent starts its findings over; a stale file would pass for this attempt's record
  # (restart keeps it: a resumed session may already have written it)
  rm -f "$(sentinel "$n" "$kind").findings.md"
  tab_json="$("$HERDR_BIN" tab create --workspace "$WS" --cwd "$WT" --label "$label" --no-focus)"
  pane="$(herd_json_field "$tab_json" '.result.root_pane.pane_id')"; tab="$(herd_json_field "$tab_json" '.result.tab.tab_id')"
  [ -n "$pane" ] && [ -n "$tab" ] || herd_die "unexpected tab create response: $tab_json"
  SS ".plans[$i].$kind.pane" "$pane"; SS ".plans[$i].$kind.tab" "$tab"
  if [ "$kind" = plan ]; then
    # stamp once only: re-spawning a dead worker must keep the ORIGINAL head, or the commits it
    # already made fall outside both the no-new-commit gate below and the review range.
    [ "$(L ".plans[$i].plan.head_before")" != null ] \
      || SS ".plans[$i].plan.head_before" "$(git -C "$WT" rev-parse HEAD)"
  else
    # audit and review both judge the whole phase: the plan's commits, plus (for the review)
    # the audit's security fixes, which get a code-quality pass like everything else.
    SS ".plans[$i].$kind.head_before" "$(L ".plans[$i].plan.head_before")"
  fi
  if ! start_worker "$i" "$kind" "$pane"; then
    "$HERDR_BIN" tab close "$tab" >/dev/null 2>&1 || true          # don't strand the tab we just created
    herd_die "could not start $name in $pane"
  fi
  S ".plans[$i].$kind.status" '"running"'; SS ".plans[$i].$kind.started_at" "$(herd_now)"
  S ".plans[$i].$kind.attempts" "$(( $(L ".plans[$i].$kind.attempts") + 1 ))"
  S .status '"running"'
  note "spawned $name in $pane ($kind $n)"
  render_brief "$n" "$kind"
}

# Why audit N's coverage record cannot be trusted yet, or nothing when it can. Checks the
# record's shape and the sentinel's own numbers against each other; it cannot prove the files
# were read, only that the auditor's claims are complete and consistent. The sentinel was
# written by an agent that read untrusted code, so every number is validated before arithmetic.
audit_coverage_gap() {       # N -> reason on stdout, empty when acceptable
  local findings done_f cov field v ftr="" fr="" fob="" rw part listed=0
  findings="$(sentinel "$1" audit).findings.md"; done_f="$(sentinel "$1" audit).done"
  [ -f "$findings" ] || { echo "no findings file"; return 0; }
  cov="$(sed -n '/^## Coverage/,$p' "$findings")"
  [ -n "$cov" ] || { echo "no ## Coverage section"; return 0; }
  # anchored and scoped to the Coverage section: a finding's own `files:` line does not count
  grep -q '^files:[[:space:]]*[^[:space:]]' <<<"$cov" || { echo "Coverage has no files: line"; return 0; }
  grep -q '^read whole:' <<<"$cov" || { echo "Coverage has no read whole: line"; return 0; }
  for field in files_to_read files_read files_over_budget; do
    v="$(sed -n "/^$field:/{s/^$field:[[:space:]]*//;s/[[:space:]]*\$//;p;q;}" "$done_f")"
    [[ "$v" =~ ^[0-9]+$ ]] || { echo "sentinel $field is missing or not a number"; return 0; }
    case "$field" in files_to_read) ftr="$v" ;; files_read) fr="$v" ;; files_over_budget) fob="$v" ;; esac
  done
  if (( 10#$fr + 10#$fob < 10#$ftr )); then
    echo "files_read $fr + files_over_budget $fob < files_to_read $ftr"; return 0
  fi
  rw="$(sed -n '/^read whole:/{s/^read whole:[[:space:]]*//;p;q;}' <<<"$cov")"
  local parts=(); IFS=, read -ra parts <<<"$rw"      # read, not word splitting: no glob expansion
  for part in ${parts[@]+"${parts[@]}"}; do
    part="${part#"${part%%[![:space:]]*}"}"; part="${part%"${part##*[![:space:]]}"}"
    [ -z "$part" ] || [ "$part" = none ] || listed=$(( listed + 1 ))
  done
  if (( listed < 10#$fr )); then
    echo "sentinel says files_read $fr but the read whole: line lists $listed"; return 0
  fi
}

do_fail() {                  # STAGE REASON
  S .status '"failed"'; SS .failed_stage "$1"
  note "FAIL $1: $2"
  herd_notify "herd $SLUG failed at $1" "$2" request
}

case "$CMD" in
  spawn-plan) spawn "${1:?N}" plan ;;
  spawn-audit) spawn "${1:?N}" audit; i="$(idx "$1")"; echo "RANGE $(L ".plans[$i].audit.head_before")..HEAD" ;;
  spawn-review) spawn "${1:?N}" review; i="$(idx "$1")"; echo "RANGE $(L ".plans[$i].review.head_before")..HEAD" ;;
  prompt-wait) herd_agent_prompt_wait "$@" ;;
  wait) herd_agent_wait "$@" ;;
  check)
    n="${1:?N}"; kind="${2:?plan|audit|review}"; kind_ok "$kind"; i="$(idx "$n")"
    name="$(agent_of "$i" "$kind")"; done_f="$(sentinel "$n" "$kind").done"; failed_f="$(sentinel "$n" "$kind").failed"
    want="$(herd_stage_model "$RUN_JSON" "$kind")"
    if [ -f "$done_f" ]; then
      model_line="$(head -1 "$done_f")"
      lc_line="$(printf '%s' "$model_line" | tr '[:upper:]' '[:lower:]')"   # sentinel may echo the on-screen "Sonnet 4.5"
      lc_want="$(herd_model_family "$want")"                             # full id claude-opus-5-5 -> opus
      case "$lc_line" in
        model:*"$lc_want"*) ;;
        *) do_fail "$kind-$n:model-mismatch" "sentinel says '$model_line', expected $want"; echo "FAILED model-mismatch: $model_line"; exit 2 ;;
      esac
      # A clean audit is only as good as its record of what was read: without a complete,
      # self-consistent Coverage record `no findings` is unverifiable, so the stage is not finished.
      if [ "$kind" = audit ]; then
        gap="$(audit_coverage_gap "$n")"
        if [ -n "$gap" ]; then echo "NONE no-coverage: $gap"; exit 3; fi
      fi
      dirty="$(git -C "$WT" status --porcelain)"
      if [ -n "$dirty" ]; then echo "NONE dirty-tree"; printf '%s\n' "$dirty" | head -20; exit 3; fi
      head="$(git -C "$WT" rev-parse HEAD)"
      if [ "$kind" = plan ] && [ "$head" = "$(L ".plans[$i].plan.head_before")" ]; then echo "NONE no-new-commit"; exit 3; fi
      SS ".plans[$i].$kind.head_after" "$head"; S ".plans[$i].$kind.status" '"done"'; SS ".plans[$i].$kind.finished_at" "$(herd_now)"
      note "$kind $n DONE at $head"
      case "$kind" in
        plan) herd_notify "herd $SLUG: plan $n/$TOTAL done" "security audit next" done ;;
        audit) herd_notify "herd $SLUG: security audit $n/$TOTAL done" "review next" done ;;
        review) herd_notify "herd $SLUG: review $n/$TOTAL done" "$([ "$n" -lt "$TOTAL" ] && echo "plan $((n + 1)) next" || echo "run complete")" done ;;
      esac
      echo "DONE $head"; exit 0
    fi
    if [ -f "$failed_f" ]; then
      S ".plans[$i].$kind.status" '"failed"'; note "$kind $n FAILED sentinel"
      echo "FAILED"; cat "$failed_f"; exit 2
    fi
    echo "NONE"
    "$HERDR_BIN" agent read "$name" --source visible 2>/dev/null || true
    exit 3 ;;
  screen) herd_agent_screen "$@" ;;
  keys) herd_agent_keys "$@" ;;
  restart)
    n="${1:?N}"; kind="${2:?plan|audit|review}"; kind_ok "$kind"; i="$(idx "$n")"
    name="$(agent_of "$i" "$kind")"; pane="$(L ".plans[$i].$kind.pane")"; sid="$(L ".plans[$i].$kind.session_id")"
    restarts="$(L ".plans[$i].$kind.restarts")"
    [ "$restarts" -lt 2 ] || { echo "RESTART-LIMIT"; exit 6; }
    rm -f "$(sentinel "$n" "$kind").done" "$(sentinel "$n" "$kind").failed"  # stale sentinel would make check pass on the previous attempt
    if herd_agent_live "$name"; then exit_agent "$name" || herd_die "could not exit $name"; fi
    # A resumed session keeps its findings file: it may already have written it. A fresh one
    # has no memory of it, and a stale file would pass check on the previous attempt's record.
    start_fresh() { rm -f "$(sentinel "$n" "$kind").findings.md"; start_worker "$i" "$kind" "$pane"; }
    if [ -n "$sid" ] && [ "$sid" != null ] && start_worker "$i" "$kind" "$pane" --resume "$sid"; then :
    else start_fresh || herd_die "could not restart $name"
    fi
    S ".plans[$i].$kind.restarts" "$(( restarts + 1 ))"
    note "restarted $name (restart $(( restarts + 1 )))"
    render_brief "$n" "$kind" ;;
  finish-agent)
    name="${1:?NAME}"
    tab="$(jq -r --arg n "$name" '.plans[] | (.plan, .audit, .review) | select(. != null and .agent == $n) | .tab // empty' "$RUN_JSON")"
    exit_agent "$name" || herd_log "$name did not exit cleanly; closing its tab anyway"
    if [ -n "$tab" ]; then "$HERDR_BIN" tab close "$tab" >/dev/null 2>&1 || true; fi
    note "finished $name (tab ${tab:-unknown})" ;;
  fail) do_fail "${1:?STAGE}" "${2:-no reason given}" ;;
  done)
    S .status '"done"'; note "RUN DONE"
    herd_notify "herd $SLUG done" "$TOTAL plan(s) + security audits + reviews on $BRANCH — not merged" done ;;
  note) note "$*" ;;
  bump)
    n="${1:?N}"; kind="${2:?plan|audit|review}"; counter="${3:?COUNTER}"; kind_ok "$kind"; i="$(idx "$n")"
    [[ "$counter" =~ ^[a-z_]+$ ]] || herd_die "counter must be [a-z_]+: $counter"
    v="$(( $(L ".plans[$i].$kind.recovery.$counter // 0") + 1 ))"
    S ".plans[$i].$kind.recovery.$counter" "$v"; echo "$v" ;;
  ledger)
    case "${1:-}" in
      get) L "${2:?JQ}" ;;
      set) S "${2:?JQ}" "${3:?JSON}" ;;
      set-str) SS "${2:?JQ}" "${3:?STRING}" ;;
      *) herd_die "ledger get JQ | set JQ JSON | set-str JQ STRING" ;;
    esac ;;
  *) herd_die "unknown command: $CMD" ;;
esac
