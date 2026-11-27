#!/usr/bin/env bash
# usage: source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
# Sourced by every tests/test-*.sh. herd's assertions + fixtures, plus LOOP. Never execute directly.
set -euo pipefail
LOOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The same resolution scripts/lib.sh uses, repeated so the tests do not depend on the code
# under test: HERD_ENGINE_DIR when set, else the deployed layout, else the source layout.
if [ -z "${HERD_ENGINE_DIR:-}" ]; then
  for d in "$LOOP/../herd-engine" "$LOOP/../../../../herd/.apm/skills/herd-engine"; do
    if [ -f "$d/scripts/lib.sh" ]; then HERD_ENGINE_DIR="$(cd "$d" && pwd)"; break; fi
  done
fi
[ -f "${HERD_ENGINE_DIR:-}/tests/assert.sh" ] \
  || { printf 'herd test helpers not found (set HERD_ENGINE_DIR)\n' >&2; exit 1; }
source "$HERD_ENGINE_DIR/tests/assert.sh"     # sets TESTS_DIR and HERD to herd's own dirs
export HERD_ENGINE_DIR

# make_loop_run REPO [SLUG] -> prints the run dir of a mapped, running loop on branch dev:
# three pending units (ENG-10 epic-design, then its children ENG-12 and ENG-11, in the order
# order.sh gives fixtures/map-epic.json), a real detached design worktree, an empty log.
make_loop_run() {
  local root="$1" slug="${2:-eng-1-loop}" run wt
  run="$root/.claude/loop-runs/$slug"; wt="$root/.claude/worktrees/$slug-design"
  mkdir -p "$run"
  git -C "$root" worktree add -q --detach "$wt" dev >/dev/null
  jq -n --arg slug "$slug" --arg root "$root" --arg loop "$LOOP" --arg wt "$wt" '
    def unit($id; $title; $kind; $parent; $order):
      ($id | ascii_downcase) as $u
      | {id: $id, uuid: ("u" + ($u | ltrimstr("eng-"))), title: $title, kind: $kind, parent: $parent,
         blocked_by: [], order: $order, phase: "pending", agent: ($slug + "-bs-" + $u),
         session_id: null, pane: null, tab: null, restarts: 0, revisions: 0, recovery: {},
         no_breakdown: false, spec: null, plan: null, adrs: [], herd_slug: null, branch: null,
         base: null, carried_by: null, linear: {started: false, review: false, comments: []}};
    {slug: $slug, root: $root, loop_dir: $loop, engine_version: "linear-loop@0.1.0",
     base: "dev", stack_tip: "dev", design_worktree: $wt,
     workspace_id: "wL", orchestrator_pane: "wL:p1",
     models: {orchestrator: "fable", brainstorm: "fable", advisor: "fable"},
     herd: {worker_model: null, review_model: null, execution: null},
     given: ["ENG-10"], map_only: false,
     status: "running", failed_reason: null,
     pause: null, pause_seq: 0,
     units: [unit("ENG-10"; "CSV export"; "epic-design"; null; 1),
             unit("ENG-12"; "Export schema"; "issue"; "ENG-10"; 2),
             unit("ENG-11"; "Export service"; "issue"; "ENG-10"; 3)],
     skipped: [],
     created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"}' > "$run/run.json"
  : > "$run/orchestrator.log"
  printf '%s\n' "$run"
}
