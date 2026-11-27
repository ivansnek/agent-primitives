#!/usr/bin/env bash
# Launcher for /linear-loop.
# usage: launch.sh [--dry-run] [--map-only] [--base BRANCH] [--slug SLUG] [--orchestrator-model M] [--brainstorm-model M] [--advisor-model M] [--worker-model M] [--review-model M] [--execution linear|subagent] ID [ID ...]
#        launch.sh [--dry-run] --resume SLUG
#   models default to fable (orchestrator, brainstorm, advisor); pinned at launch
#   --worker-model, --review-model and --execution are passed to every herd run, only when given
#   --map-only stops after the dependency map; --resume then runs it
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
USAGE="loop: usage: launch.sh [--dry-run] [--map-only] [--base BRANCH] [--slug SLUG] [--orchestrator-model M] [--brainstorm-model M] [--advisor-model M] [--worker-model M] [--review-model M] [--execution linear|subagent] ID [ID ...] | [--dry-run] --resume SLUG"
DEFAULT_MODEL=fable

DRY_RUN=0; MAP_ONLY=false; RESUME=""; BASE=""; SLUG=""; ARGS=()
ORCH_MODEL=""; BS_MODEL=""; ADVISOR_MODEL=""; WORKER_MODEL=""; REVIEW_MODEL=""; EXECUTION=""
PINNED=""                                  # the first flag given that --resume refuses
while [ $# -gt 0 ]; do
  flag="$1"
  case "$flag" in
    --resume|--base|--slug|--orchestrator-model|--brainstorm-model|--advisor-model|--worker-model|--review-model|--execution)
      [ -n "${2:-}" ] || herd_die "loop: $flag needs a value"
      value="$2"; shift ;;
  esac
  case "$flag" in
    --dry-run|--resume|-h|--help) ;;
    --*) PINNED="${PINNED:-$flag}" ;;
  esac
  case "$flag" in
    --dry-run) DRY_RUN=1 ;;
    --map-only) MAP_ONLY=true ;;
    --resume) RESUME="$value" ;;
    --base) BASE="$value" ;;
    --slug) SLUG="$value" ;;
    --orchestrator-model) herd_validate_model "$flag" "$value"; ORCH_MODEL="$value" ;;
    --brainstorm-model) herd_validate_model "$flag" "$value"; BS_MODEL="$value" ;;
    --advisor-model) herd_validate_model "$flag" "$value"; ADVISOR_MODEL="$value" ;;
    --worker-model) herd_validate_model "$flag" "$value"; WORKER_MODEL="$value" ;;
    --review-model) herd_validate_model "$flag" "$value"; REVIEW_MODEL="$value" ;;
    --execution) EXECUTION="$(herd_execution_mode "$value")" ;;
    -h|--help) sed -n '3,7p' "$0"; exit 0 ;;
    --*) herd_die "loop: unknown option: $flag" ;;
    *) ARGS+=("$flag") ;;
  esac
  shift
done
if [ -n "$RESUME" ]; then
  [ ${#ARGS[@]} -eq 0 ] || herd_die "loop: --resume takes no issue ids: the run's issues are in its ledger"
  # models, herd flags, base and mode were pinned at launch
  [ -z "$PINNED" ] || herd_die "loop: --resume takes no $PINNED: a run keeps what it was launched with (see run.json)"
else
  [ ${#ARGS[@]} -gt 0 ] || herd_die "$USAGE"
fi

# ---------------------------------------------------------------- preflight (read-only)
herd_require jq; herd_require git
loop_require_herd
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || herd_die "loop: not inside a git repository"
loop_config_check "$ROOT"
herd_config_check "$ROOT"            # herd runs read it: fail now, not at the first execution
herd_server_running || herd_die "loop: herdr server is not running (check: herdr status)"
# one assignment per statement: a die inside $(...) must stop the launch
RUNS_DIR="$(loop_runs_dir "$ROOT")"
ADR_DIR="$(loop_adr_dir "$ROOT")"

set_run() {                  # SLUG
  SLUG="$1"; RUN_DIR="$RUNS_DIR/$SLUG"; RUN_JSON="$RUN_DIR/run.json"; ORCH="$SLUG-loop"
}
render_orchestrator() {      # (RUN_JSON written) -> the brief, from the current template
  local base design bs_model advisor_model given writes started review revisions family
  base="$(herd_ledger_get "$RUN_JSON" .base)"
  design="$(herd_ledger_get "$RUN_JSON" .design_worktree)"
  bs_model="$(herd_ledger_get "$RUN_JSON" .models.brainstorm)"
  advisor_model="$(herd_ledger_get "$RUN_JSON" .models.advisor)"
  given="$(herd_ledger_get "$RUN_JSON" '.given | join(" ")')"
  family="$(herd_model_family "$bs_model")"
  writes="$(loop_config_get "$ROOT" .linearWrites status)"
  started="$(loop_config_get "$ROOT" .statusStarted none)"
  review="$(loop_config_get "$ROOT" .statusReview none)"
  revisions="$(loop_config_get "$ROOT" .advisorMaxRevisions 2)"
  "$HERD_SCRIPTS_DIR/render.sh" "$LOOP_TEMPLATES_DIR/orchestrator.tmpl.md" \
    SLUG="$SLUG" RUN_DIR="$RUN_DIR" LOOP_DIR="$LOOP_DIR" ROOT="$ROOT" BASE="$base" DESIGN_WORKTREE="$design" \
    BRAINSTORM_MODEL="$bs_model" BRAINSTORM_FAMILY="$family" ADVISOR_MODEL="$advisor_model" ADR_DIR="$ADR_DIR" \
    LINEAR_WRITES="$writes" STATUS_STARTED="$started" STATUS_REVIEW="$review" MAX_REVISIONS="$revisions" \
    GIVEN_IDS="$given" ADVISOR_ANSWER_TMPL="$LOOP_TEMPLATES_DIR/advisor-answer.tmpl.md" \
    ADVISOR_REVIEW_TMPL="$LOOP_TEMPLATES_DIR/advisor-review.tmpl.md"
}
write_brief() {              # renders beside the target first: a failed render keeps the old brief
  local tmp
  tmp="$(mktemp "$RUN_DIR/orchestrator.md.XXXXXX")"
  if ! render_orchestrator > "$tmp"; then rm -f "$tmp"; herd_die "loop: could not render $RUN_DIR/orchestrator.md"; fi
  chmod 644 "$tmp"; mv "$tmp" "$RUN_DIR/orchestrator.md"
  "$LOOP_SCRIPTS_DIR/progress.sh" "$RUN_DIR"
}
start_orchestrator() {       # PANE MODEL PROMPT
  herd_agent_start "$ORCH" "$1" -- --model "$2" --permission-mode bypassPermissions --remote-control "$SLUG" >/dev/null \
    || herd_die "loop: could not start $ORCH in $1 (run dir kept: $RUN_DIR; retry with --resume $SLUG)"
  "$HERDR_BIN" agent prompt "$ORCH" "$3" >/dev/null \
    || herd_die "loop: could not prompt $ORCH (exit it: herdr agent prompt $ORCH /exit; then --resume $SLUG)"
}
dry_start() {                # PANE MODEL PROMPT
  echo "DRY-RUN: $HERDR_BIN agent start $ORCH --kind claude --pane $1 --timeout 120000 -- --model $2 --permission-mode bypassPermissions --remote-control $SLUG"
  echo "DRY-RUN: $HERDR_BIN agent prompt $ORCH \"$3\""
}

report() {                   # VERB
  local ws units
  ws="$(herd_ledger_get "$RUN_JSON" .workspace_id)"
  units="$(herd_ledger_get "$RUN_JSON" 'if (.units | length) == 0 then "mapped by the orchestrator in Phase 0"
    else "\(.units | length) in the ledger" end')"
  cat <<REPORT
loop: run '$SLUG' $1
  base          $(herd_ledger_get "$RUN_JSON" .base)
  issues        $(herd_ledger_get "$RUN_JSON" '.given | join(" ")')
  units         $units
  workspace     $ws            herdr workspace focus $ws
  orchestrator  $ORCH ($(herd_ledger_get "$RUN_JSON" .models.orchestrator))     herdr agent focus $ORCH
  remote        Remote Control session '$SLUG': open claude.ai/code or the Claude mobile app
  run dir       $RUN_DIR  (run.json ledger, briefs, orchestrator.log)
  progress      $RUN_DIR/PROGRESS.md
  watch         herdr agent list | jq '.result.agents[] | {name, agent_status}'
  abort         herdr agent send-keys $ORCH ctrl+c   then   herdr agent prompt $ORCH /exit
  resume        /linear-loop --resume $SLUG
REPORT
  if [ "$(herd_ledger_get "$RUN_JSON" .map_only)" = true ]; then
    echo "  map only      stops after the dependency map; resume runs it"
  fi
}

# ---------------------------------------------------------------- resume
if [ -n "$RESUME" ]; then
  herd_validate_slug "$RESUME"
  set_run "$RESUME"
  [ -f "$RUN_JSON" ] || herd_die "loop: no ledger: $RUN_JSON"
  status="$(herd_ledger_get "$RUN_JSON" .status)" || herd_die "loop: unreadable ledger: $RUN_JSON"
  [ "$status" != done ] || herd_die "loop: run $SLUG is already done"
  # the brief is rendered with this checkout's paths: they must be the run's
  run_root="$(herd_ledger_get "$RUN_JSON" .root)"
  [ "$run_root" = "$ROOT" ] || herd_die "loop: run $SLUG belongs to $run_root: resume it from there"
  ! herd_agent_live "$ORCH" || herd_die "loop: agent $ORCH is still live; exit it first: herdr agent prompt $ORCH /exit"
  WS="$(herd_ledger_get "$RUN_JSON" .workspace_id)"
  MODEL="$(herd_ledger_get "$RUN_JSON" .models.orchestrator)"
  DESIGN="$(herd_ledger_get "$RUN_JSON" .design_worktree)"
  TIP="$(herd_ledger_get "$RUN_JSON" .stack_tip)"
  PROMPT="Resume the linear-loop run: read $RUN_DIR/orchestrator.md and follow it exactly. Run dir: $RUN_DIR"
  restore=0
  if [ ! -d "$DESIGN" ]; then
    git -C "$ROOT" rev-parse --verify --quiet --end-of-options "$TIP^{commit}" >/dev/null \
      || herd_die "loop: design worktree is gone and the stack tip is not a commit: $TIP"
    restore=1
  fi
  # The orchestrator only reports a failed run and stops, so a resume puts it back where it can
  # go on: at its open question, before the map was final, or in the unit loop.
  restored=""
  if [ "$status" = failed ]; then
    restored="$(jq -r 'if .pause != null then "waiting-human"
      elif all(.units[]; .phase == "pending") then "created" else "running" end' "$RUN_JSON")" \
      || herd_die "loop: unreadable ledger: $RUN_JSON"
  fi

  if [ "$DRY_RUN" = 1 ]; then
    # --force: a directory that was deleted is still registered as a worktree
    [ "$restore" = 0 ] || echo "DRY-RUN: git worktree add --force --detach $DESIGN $TIP"
    echo "DRY-RUN: $HERDR_BIN tab create --workspace $WS --cwd $ROOT --label orchestrator --no-focus"
    [ -z "$restored" ] || echo "DRY-RUN: restore status failed -> $restored and clear failed_reason in $RUN_JSON"
    echo "DRY-RUN: set map_only false in $RUN_JSON"
    echo "DRY-RUN: re-render $RUN_DIR/orchestrator.md from $LOOP_TEMPLATES_DIR/orchestrator.tmpl.md, and PROGRESS.md"
    dry_start "<pane>" "$MODEL" "$PROMPT"
    exit 0
  fi

  if [ "$restore" = 1 ]; then
    git -C "$ROOT" worktree add -q --force --detach "$DESIGN" "$TIP" >&2 \
      || herd_die "loop: could not re-create the design worktree: $DESIGN"
  fi
  tab_json="$("$HERDR_BIN" tab create --workspace "$WS" --cwd "$ROOT" --label orchestrator --no-focus)" \
    || herd_die "loop: could not create a tab in workspace $WS (was it closed?)"
  PANE="$(herd_json_field "$tab_json" '.result.root_pane.pane_id')"
  [ -n "$PANE" ] || herd_die "loop: unexpected tab create response: $tab_json"
  # one write, after everything that can refuse the resume
  ledger="$(jq -c --arg status "$restored" --arg pane "$PANE" '
    (if $status == "" then . else .status = $status | .failed_reason = null end)
    | .map_only = false | .orchestrator_pane = $pane' "$RUN_JSON")" || herd_die "loop: unreadable ledger: $RUN_JSON"
  herd_ledger_set "$RUN_JSON" . "$ledger" || herd_die "loop: could not update $RUN_JSON"
  write_brief
  start_orchestrator "$PANE" "$MODEL" "$PROMPT"
  report resumed
  exit 0
fi

# ---------------------------------------------------------------- new run: preflight
IDS=()
for arg in "${ARGS[@]}"; do
  uslug="$(loop_uslug "$arg")"
  id="$(printf '%s' "$uslug" | tr '[:lower:]' '[:upper:]')"
  for seen in ${IDS[@]+"${IDS[@]}"}; do [ "$seen" != "$id" ] || continue 2; done
  IDS+=("$id")
done
[ -n "$SLUG" ] || SLUG="$(printf '%s' "${IDS[0]}" | tr '[:upper:]' '[:lower:]')-loop"
herd_validate_slug "$SLUG"
set_run "$SLUG"
: "${ORCH_MODEL:=$DEFAULT_MODEL}" "${BS_MODEL:=$DEFAULT_MODEL}" "${ADVISOR_MODEL:=$DEFAULT_MODEL}"
[ -n "$BASE" ] || BASE="$(herd_config_get "$ROOT" .defaultBase "")"
[ -n "$BASE" ] || BASE="$(git branch --show-current)"
[ -n "$BASE" ] || herd_die "loop: detached HEAD: pass --base BRANCH"
git rev-parse --verify --quiet --end-of-options "$BASE^{commit}" >/dev/null || herd_die "loop: base ref not found: $BASE"
DESIGN="$ROOT/.claude/worktrees/$SLUG-design"
[ ! -e "$RUN_JSON" ] || herd_die "loop: run ledger already exists: $RUN_JSON (use --resume $SLUG or pass --slug)"
! herd_agent_live "$ORCH" || herd_die "loop: agent $ORCH is already live"
[ ! -e "$DESIGN" ] && [ ! -L "$DESIGN" ] || herd_die "loop: design worktree path already exists: $DESIGN (pass --slug, or remove it)"
PROMPT="Read $RUN_DIR/orchestrator.md and follow it exactly. Run dir: $RUN_DIR"

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY-RUN: slug=$SLUG base=$BASE issues=${IDS[*]} map_only=$MAP_ONLY"
  echo "DRY-RUN: models orchestrator=$ORCH_MODEL brainstorm=$BS_MODEL advisor=$ADVISOR_MODEL"
  echo "DRY-RUN: mkdir -p $RUN_DIR"
  echo "DRY-RUN: git worktree add --detach $DESIGN $BASE"
  echo "DRY-RUN: $HERDR_BIN workspace create --cwd $ROOT --label loop:$SLUG --no-focus"
  echo "DRY-RUN: write $RUN_JSON, render $RUN_DIR/orchestrator.md and PROGRESS.md"
  dry_start "<root_pane>" "$ORCH_MODEL" "$PROMPT"
  exit 0
fi

# ---------------------------------------------------------------- new run: create
made_run_dir=0; [ -d "$RUN_DIR" ] || made_run_dir=1
mkdir -p "$RUN_DIR"
# Until the ledger exists there is nothing to resume: leave nothing that blocks the next try.
drop_run_dir() { [ "$made_run_dir" = 0 ] || rmdir "$RUN_DIR" 2>/dev/null || true; }
abandon() {                  # MESSAGE
  git -C "$ROOT" worktree remove --force "$DESIGN" >&2 || herd_log "loop: warning: could not remove $DESIGN"
  drop_run_dir
  herd_die "$1"
}
if ! git -C "$ROOT" worktree add -q --detach "$DESIGN" "$BASE" >&2; then
  drop_run_dir
  herd_die "loop: could not create the design worktree: $DESIGN (a deleted one may still be registered: git worktree prune)"
fi
ws_json="$("$HERDR_BIN" workspace create --cwd "$ROOT" --label "loop:$SLUG" --no-focus)" \
  || abandon "loop: could not create the herdr workspace"
WS="$(herd_json_field "$ws_json" '.result.workspace.workspace_id')" || WS=""
PANE="$(herd_json_field "$ws_json" '.result.root_pane.pane_id')" || PANE=""
[ -n "$WS" ] && [ -n "$PANE" ] || abandon "loop: unexpected workspace create response: $ws_json"

given_json="$(jq -nc '$ARGS.positional' --args "${IDS[@]}")"
tmp="$(mktemp "$RUN_JSON.XXXXXX")"
jq -n --arg slug "$SLUG" --arg root "$ROOT" --arg loop_dir "$LOOP_DIR" --arg engine_version "$(loop_engine_version)" \
  --arg base "$BASE" --arg design "$DESIGN" --arg ws "$WS" --arg pane "$PANE" \
  --arg orch "$ORCH_MODEL" --arg bs "$BS_MODEL" --arg advisor "$ADVISOR_MODEL" \
  --arg worker "$WORKER_MODEL" --arg review "$REVIEW_MODEL" --arg execution "$EXECUTION" \
  --argjson given "$given_json" --argjson map_only "$MAP_ONLY" --arg now "$(herd_now)" '
  def given_or_null: if . == "" then null else . end;
  {slug: $slug, root: $root, loop_dir: $loop_dir, engine_version: $engine_version,   # loop_dir: provenance only
   base: $base, stack_tip: $base, design_worktree: $design,
   workspace_id: $ws, orchestrator_pane: $pane,
   models: {orchestrator: $orch, brainstorm: $bs, advisor: $advisor},
   herd: {worker_model: ($worker | given_or_null), review_model: ($review | given_or_null),
          execution: ($execution | given_or_null)},
   given: $given, map_only: $map_only,
   status: "created", failed_reason: null,
   pause: null, pause_seq: 0,
   units: [], skipped: [],
   created_at: $now, updated_at: $now}' > "$tmp" || { rm -f "$tmp"; abandon "loop: could not write $RUN_JSON"; }
chmod 644 "$tmp"; mv "$tmp" "$RUN_JSON"
: > "$RUN_DIR/orchestrator.log"
write_brief
start_orchestrator "$PANE" "$ORCH_MODEL" "$PROMPT"
report launched
