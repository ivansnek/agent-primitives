#!/usr/bin/env bash
# Launcher for /execute-plans (spec §6).
# usage: launch.sh [--dry-run] [--base BRANCH] [--slug SLUG] [--orchestrator-model M] [--worker-model M] [--review-model M] [--execution linear|subagent] PLAN.md [PLAN.md ...]
#        launch.sh [--dry-run] --resume SLUG
#   models default to fable (orchestrator), sonnet (plan worker), sonnet (reviewer); pinned at launch
#   the security auditor (after each plan, before its review) runs on the reviewer's model
#   execution defaults to linear (the worker implements every task); subagent = a subagent per task; pinned at launch
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0; RESUME=""; BASE=""; SLUG=""; PLANS=()
ORCH_MODEL=""; PLAN_MODEL=""; REVIEW_MODEL=""; EXECUTION=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --resume) RESUME="${2:?--resume needs a slug}"; shift ;;
    --base) BASE="${2:?--base needs a branch}"; shift ;;
    --slug) SLUG="${2:?--slug needs a name}"; shift ;;
    --orchestrator-model) ORCH_MODEL="${2:?--orchestrator-model needs a model}"; herd_validate_model "$1" "$ORCH_MODEL"; shift ;;
    --worker-model) PLAN_MODEL="${2:?--worker-model needs a model}"; herd_validate_model "$1" "$PLAN_MODEL"; shift ;;
    --review-model) REVIEW_MODEL="${2:?--review-model needs a model}"; herd_validate_model "$1" "$REVIEW_MODEL"; shift ;;
    --execution) EXECUTION="$(herd_execution_mode "${2:?--execution needs a mode}")"; shift ;;
    -h|--help) sed -n '3,7p' "$0"; exit 0 ;;
    --*) herd_die "unknown option: $1" ;;
    *) PLANS+=("$1") ;;
  esac
  shift
done

herd_require jq; herd_require git
ROOT="$(git rev-parse --show-toplevel)"
herd_config_check "$ROOT"          # fail at launch, not twenty minutes in
REVIEW_STANDARDS="$(herd_review_standards "$ROOT")"; SECURITY_STANDARDS="$(herd_security_standards "$ROOT")"   # same: checked now, named in the orchestrator brief
RUNS_DIR="$ROOT/.claude/herd-runs"

report() {   # report RUN_JSON
  local j="$1" slug ws wt run_dir branch n
  slug="$(herd_ledger_get "$j" .slug)"; ws="$(herd_ledger_get "$j" .workspace_id)"; wt="$(herd_ledger_get "$j" .worktree)"
  branch="$(herd_ledger_get "$j" .branch)"; run_dir="$(dirname "$j")"; n="$(herd_ledger_get "$j" '.plans | length')"
  local orch_model plan_model review_model execution
  orch_model="$(herd_ledger_get "$j" .models.orchestrator)"; plan_model="$(herd_ledger_get "$j" .models.plan)"
  review_model="$(herd_ledger_get "$j" .models.review)"; execution="$(herd_ledger_execution "$j")"
  cat <<EOF
herd: run '$slug' launched — $n plan(s)
  branch        $branch  (base $(herd_ledger_get "$j" .base))
  worktree      $wt
  workspace     $ws            herdr workspace focus $ws
  orchestrator  $slug-orch ($orch_model)     herdr agent focus $slug-orch
  workers       $slug-plan-N ($plan_model) / $slug-audit-N ($review_model) / $slug-rev-N ($review_model), one tab each
  execution     $execution
  run dir       $run_dir  (run.json ledger, briefs, sentinels, orchestrator.log)
  plans
$(jq -r '.plans[] | "    \(.index). \(.title)"' "$j")
  watch         herdr agent list | jq '.result.agents[] | {name, agent_status}'
  abort         herdr agent send-keys $slug-orch ctrl+c   then   herdr agent prompt $slug-orch /exit
  resume        /execute-plans --resume $slug
EOF
}

# ---------------------------------------------------------------- resume
if [ -n "$RESUME" ]; then
  [ ${#PLANS[@]} -eq 0 ] || herd_die "--resume takes no plan paths"
  # A stage already running would write its sentinel under the old model and fail the gate.
  [ -z "$ORCH_MODEL$PLAN_MODEL$REVIEW_MODEL" ] || herd_die "--resume takes no model flags: models are pinned at launch (see .models in run.json)"
  # Same pin: a worker already mid-plan was briefed under the launch approach.
  [ -z "$EXECUTION" ] || herd_die "--resume takes no --execution: the approach is pinned at launch (see .execution in run.json)"
  herd_validate_slug "$RESUME"
  RUN_DIR="$RUNS_DIR/$RESUME"; RUN_JSON="$RUN_DIR/run.json"
  [ -f "$RUN_JSON" ] || herd_die "no run ledger at $RUN_JSON"
  herd_server_running || herd_die "herdr server is not running (check: herdr status)"
  [ "$(herd_ledger_get "$RUN_JSON" .status)" != done ] || herd_die "run $RESUME is already done"
  ORCH="$RESUME-orch"
  ! herd_agent_live "$ORCH" || herd_die "agent $ORCH is still live; exit it first: herdr agent prompt $ORCH /exit"
  WS="$(herd_ledger_get "$RUN_JSON" .workspace_id)"; WT="$(herd_ledger_get "$RUN_JSON" .worktree)"
  MODEL="$(herd_ledger_get "$RUN_JSON" .models.orchestrator)"
  [ -d "$WT" ] || herd_die "worktree missing: $WT"
  if [ "$DRY_RUN" = 1 ]; then
    echo "DRY-RUN: re-render $RUN_DIR/orchestrator.md from $HERD_TEMPLATES_DIR/orchestrator.tmpl.md"
    echo "DRY-RUN: $HERDR_BIN tab create --workspace $WS --cwd $WT --label orchestrator --no-focus"
    echo "DRY-RUN: $HERDR_BIN agent start $ORCH --kind claude --pane <pane> --timeout 120000 -- --model $MODEL --permission-mode bypassPermissions"
    echo "DRY-RUN: $HERDR_BIN agent prompt $ORCH \"Resume the herd run: read $RUN_DIR/orchestrator.md and follow it exactly. Run dir: $RUN_DIR\""
    exit 0
  fi
  # A run launched before the security audit stage has no .audit records; the current template
  # walks plan -> audit -> review, so give it some (skipped where the review already started).
  herd_ledger_backfill_audit "$RUN_JSON" || herd_die "could not add the audit stage to $RUN_JSON"
  # Re-render from the CURRENT template. A run created before a template change would otherwise
  # resume against stale instructions (e.g. a ledger written when the review stage still ran
  # /code-review) while stage.sh renders its worker briefs from today's templates.
  "$HERD_SCRIPTS_DIR/render.sh" "$HERD_TEMPLATES_DIR/orchestrator.tmpl.md" SLUG="$RESUME" \
    TOTAL="$(herd_ledger_get "$RUN_JSON" '.plans | length')" RUN_DIR="$RUN_DIR" HERD_DIR="$HERD_DIR" \
    PLAN_MODEL="$(herd_ledger_get "$RUN_JSON" .models.plan)" PLAN_FAMILY="$(herd_model_family "$(herd_ledger_get "$RUN_JSON" .models.plan)")" REVIEW_MODEL="$(herd_ledger_get "$RUN_JSON" .models.review)" \
    EXECUTION="$(herd_ledger_execution "$RUN_JSON")" PREP_SCRIPT="$(herd_prep_script "$ROOT")" \
    REVIEW_STANDARDS="$REVIEW_STANDARDS" SECURITY_STANDARDS="$SECURITY_STANDARDS" \
    ROOT="$ROOT" WORKTREE="$WT" BRANCH="$(herd_ledger_get "$RUN_JSON" .branch)" \
    BASE="$(herd_ledger_get "$RUN_JSON" .base)" > "$RUN_DIR/orchestrator.md"
  tab_json="$("$HERDR_BIN" tab create --workspace "$WS" --cwd "$WT" --label orchestrator --no-focus)"
  PANE="$(herd_json_field "$tab_json" '.result.root_pane.pane_id')"
  [ -n "$PANE" ] || herd_die "unexpected tab create response: $tab_json"
  herd_ledger_set_str "$RUN_JSON" .orchestrator_pane "$PANE"
  herd_agent_start "$ORCH" "$PANE" -- --model "$MODEL" --permission-mode bypassPermissions >/dev/null || herd_die "could not start $ORCH in $PANE"
  "$HERDR_BIN" agent prompt "$ORCH" "Resume the herd run: read $RUN_DIR/orchestrator.md and follow it exactly. Run dir: $RUN_DIR" >/dev/null
  report "$RUN_JSON"
  exit 0
fi

# ---------------------------------------------------------------- new run: preflight
[ ${#PLANS[@]} -gt 0 ] || herd_die "usage: launch.sh [--dry-run] [--base BRANCH] [--slug SLUG] [--orchestrator-model M] [--worker-model M] [--review-model M] [--execution linear|subagent] PLAN.md..."
: "${ORCH_MODEL:=$HERD_DEFAULT_ORCHESTRATOR_MODEL}" "${PLAN_MODEL:=$HERD_DEFAULT_PLAN_MODEL}" "${REVIEW_MODEL:=$HERD_DEFAULT_REVIEW_MODEL}"
: "${EXECUTION:=$HERD_DEFAULT_EXECUTION}"
herd_server_running || herd_die "herdr server is not running (check: herdr status)"
[ -n "$BASE" ] || BASE="$(herd_config_get "$ROOT" .defaultBase "")"
[ -n "$BASE" ] || BASE="$(git branch --show-current)"
[ -n "$BASE" ] || herd_die "detached HEAD: pass --base BRANCH"
git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null || herd_die "base ref not found: $BASE"

ABS_PLANS=(); REL_PLANS=(); TITLES=()
for p in "${PLANS[@]}"; do
  [ -f "$p" ] || herd_die "plan not found: $p"
  case "$p" in *.md) ;; *) herd_die "plan must be a .md file: $p" ;; esac
  abs="$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"     # -P: symlink-safe, matches rev-parse
  case "$abs" in "$ROOT"/*) ;; *) herd_die "plan must live inside the repo: $p" ;; esac
  ABS_PLANS+=("$abs"); REL_PLANS+=("${abs#"$ROOT"/}"); TITLES+=("$(herd_plan_title "$abs")")
done
[ -n "$SLUG" ] || SLUG="$(herd_slug_from_plan "${ABS_PLANS[0]}")"
herd_validate_slug "$SLUG"
BRANCH="feat/$SLUG"; WT="$ROOT/.claude/worktrees/$SLUG"; RUN_DIR="$RUNS_DIR/$SLUG"; RUN_JSON="$RUN_DIR/run.json"; ORCH="$SLUG-orch"
! git show-ref --verify --quiet "refs/heads/$BRANCH" || herd_die "branch already exists: $BRANCH (pass --slug, or --resume $SLUG)"
[ ! -e "$WT" ] || herd_die "worktree path already exists: $WT"
[ ! -e "$RUN_JSON" ] || herd_die "run ledger already exists: $RUN_JSON (use --resume $SLUG or pass --slug)"
! herd_agent_live "$ORCH" || herd_die "agent $ORCH is already live"

if [ "$DRY_RUN" = 1 ]; then
  echo "DRY-RUN: slug=$SLUG base=$BASE branch=$BRANCH worktree=$WT run_dir=$RUN_DIR"
  echo "DRY-RUN: models orchestrator=$ORCH_MODEL plan=$PLAN_MODEL review=$REVIEW_MODEL"
  echo "DRY-RUN: execution=$EXECUTION"
  for i in "${!REL_PLANS[@]}"; do echo "DRY-RUN: plan $((i + 1)): ${REL_PLANS[$i]} — ${TITLES[$i]}"; done
  echo "DRY-RUN: $HERDR_BIN worktree create --cwd $ROOT --branch $BRANCH --base $BASE --path $WT --label herd:$SLUG --no-focus"
  echo "DRY-RUN: write $RUN_JSON and render $RUN_DIR/orchestrator.md"
  echo "DRY-RUN: $HERDR_BIN agent start $ORCH --kind claude --pane <root_pane> --timeout 120000 -- --model $ORCH_MODEL --permission-mode bypassPermissions"
  echo "DRY-RUN: $HERDR_BIN agent prompt $ORCH \"Read $RUN_DIR/orchestrator.md and follow it exactly. Run dir: $RUN_DIR\""
  exit 0
fi

# ---------------------------------------------------------------- new run: create
wt_json="$("$HERDR_BIN" worktree create --cwd "$ROOT" --branch "$BRANCH" --base "$BASE" --path "$WT" --label "herd:$SLUG" --no-focus)"
WS="$(herd_json_field "$wt_json" '.result.workspace.workspace_id')"
PANE="$(herd_json_field "$wt_json" '.result.root_pane.pane_id')"
[ -n "$WS" ] && [ -n "$PANE" ] || herd_die "unexpected worktree create response: $wt_json"
[ -d "$WT" ] || herd_die "herdr reported success but $WT does not exist"

mkdir -p "$RUN_DIR"
plans_json="$(for i in "${!ABS_PLANS[@]}"; do
  jq -n --argjson index "$((i + 1))" --arg path "$WT/${REL_PLANS[$i]}" --arg title "${TITLES[$i]}" --arg slug "$SLUG" "$HERD_JQ_STAGE"'
    {index:$index, path:$path, title:$title,
     plan:stage($slug; $index; "plan"), audit:stage($slug; $index; "audit"), review:stage($slug; $index; "rev")}'
done | jq -s '.')"
jq -n --arg slug "$SLUG" --arg root "$ROOT" --arg herd_dir "$HERD_DIR" --arg engine_version "$(herd_engine_version)" \
  --arg worktree "$WT" --arg base "$BASE" \
  --arg orch_model "$ORCH_MODEL" --arg plan_model "$PLAN_MODEL" --arg review_model "$REVIEW_MODEL" --arg execution "$EXECUTION" \
  --arg branch "$BRANCH" --arg ws "$WS" --arg pane "$PANE" --argjson plans "$plans_json" --arg now "$(herd_now)" '{
  slug:$slug, root:$root, herd_dir:$herd_dir, engine_version:$engine_version,   # herd_dir: provenance only, never resolved from
  worktree:$worktree, base:$base, branch:$branch,
  workspace_id:$ws, orchestrator_pane:$pane,
  models:{orchestrator:$orch_model, plan:$plan_model, review:$review_model}, execution:$execution,
  status:"created", failed_stage:null, prep:{status:"pending", finished_at:null},
  plans:$plans, created_at:$now, updated_at:$now}' > "$RUN_JSON"
"$HERD_SCRIPTS_DIR/render.sh" "$HERD_TEMPLATES_DIR/orchestrator.tmpl.md" SLUG="$SLUG" TOTAL="${#ABS_PLANS[@]}" RUN_DIR="$RUN_DIR" \
  HERD_DIR="$HERD_DIR" PREP_SCRIPT="$(herd_prep_script "$ROOT")" ROOT="$ROOT" WORKTREE="$WT" BRANCH="$BRANCH" BASE="$BASE" \
  PLAN_MODEL="$PLAN_MODEL" PLAN_FAMILY="$(herd_model_family "$PLAN_MODEL")" REVIEW_MODEL="$REVIEW_MODEL" \
  EXECUTION="$EXECUTION" REVIEW_STANDARDS="$REVIEW_STANDARDS" SECURITY_STANDARDS="$SECURITY_STANDARDS" > "$RUN_DIR/orchestrator.md"
: > "$RUN_DIR/orchestrator.log"

herd_agent_start "$ORCH" "$PANE" -- --model "$ORCH_MODEL" --permission-mode bypassPermissions >/dev/null || herd_die "could not start $ORCH in $PANE (run dir kept: $RUN_DIR; retry with --resume $SLUG)"
"$HERDR_BIN" agent prompt "$ORCH" "Read $RUN_DIR/orchestrator.md and follow it exactly. Run dir: $RUN_DIR" >/dev/null
report "$RUN_JSON"
