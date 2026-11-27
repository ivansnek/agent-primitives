#!/usr/bin/env bash
# usage: bash tests/test-templates.sh
# The orchestrator template and the two advisor prompts: every placeholder consumed, every
# loop.sh command and outcome the control flow depends on named; the brainstormer brief renders.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
T="$LOOP/templates"
has() { if printf '%s' "$1" | grep -qF -- "$2"; then pass; else fail "$3: '$2' not found"; fi; }
hasnt() { if printf '%s' "$1" | grep -qF -- "$2"; then fail "$3: '$2' found"; else pass; fi; }

# ---- orchestrator.tmpl.md ---------------------------------------------------------
keys=(SLUG RUN_DIR LOOP_DIR ROOT BASE DESIGN_WORKTREE BRAINSTORM_MODEL BRAINSTORM_FAMILY ADVISOR_MODEL
      ADR_DIR LINEAR_WRITES STATUS_STARTED STATUS_REVIEW MAX_REVISIONS GIVEN_IDS ADVISOR_ANSWER_TMPL
      ADVISOR_REVIEW_TMPL)
args=(); for k in "${keys[@]}"; do args+=("$k=dummy-$(printf %s "$k" | tr "[:upper:]" "[:lower:]")"); done
orch="$("$HERD/scripts/render.sh" "$T/orchestrator.tmpl.md" "${args[@]}")" && rc=0 || rc=$?
assert_eq "$rc" 0 "orchestrator renders with every placeholder set"
hasnt "$orch" "{{" "orchestrator fully rendered"
# exactly these keys: each one is used, and no other is
assert_eq "$(grep -oE '\{\{[A-Z][A-Z0-9_]*\}\}' "$T/orchestrator.tmpl.md" | sort -u | tr -d '{}' | tr '\n' ' ')" \
  "$(printf '%s\n' "${keys[@]}" | sort | tr '\n' ' ')" "orchestrator placeholders are exactly the documented set"
for k in "${keys[@]}"; do
  less=(); for a in "${args[@]}"; do [ "${a%%=*}" = "$k" ] || less+=("$a"); done
  assert_exit 3 "$HERD/scripts/render.sh" "$T/orchestrator.tmpl.md" "${less[@]}"
done
for s in map-apply unit-start outbox-next inbox-write inbox-delivered PENDING-DELIVERY check-bs exec-resume \
         wait-run.sh unit-done unit-skip add-units linear-has linear-mark ORCH-GONE STUCK RESTART-LIMIT \
         NEEDS-HUMAN "not merged, not pushed"; do
  has "$orch" "$s" "orchestrator names $s"
done
for kind in map advisor adr low-confidence revise-cap breakdown exec-failed stuck recovery-cap skip-dependents; do
  has "$orch" "pause \`$kind\`" "orchestrator raises pause kind $kind"
  has "$orch" "| \`$kind\` |" "pause table row for $kind"
done
# every loop.sh command is documented, as herd's test does for stage.sh
cmds="$(sed -n '/^case "\$CMD" in/,/^esac/p' "$LOOP/scripts/loop.sh" | sed -nE 's/^  ([a-z-]+)\).*/\1/p')"
assert_eq "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')" 34 "loop.sh command arms found"
for c in $cmds; do has "$orch" "\`$c" "orchestrator documents loop.sh $c"; done
has "$orch" "dummy-loop_dir/scripts/loop.sh dummy-run_dir" "helper call form uses the absolute engine path"
has "$orch" "dummy-loop_dir/scripts/wait-run.sh" "wait-run.sh is called on its own, not through loop.sh"
hasnt "$orch" "loop.sh dummy-run_dir wait-run" "wait-run.sh is not a loop.sh command"
has "$orch" "run_in_background" "every wait runs in the background"
has "$orch" "dummy-advisor_answer_tmpl" "orchestrator reads the answer prompt"
has "$orch" "dummy-advisor_review_tmpl" "orchestrator reads the review prompt"
has "$orch" "must be the \`dummy-brainstorm_family\` family" "screen check names the brainstorm family"
has "$orch" "/linear-loop --resume dummy-slug" "map-only stop says how to continue"
has "$orch" "/execute-plans --resume" "a failed herd run points at herd's resume"
has "$orch" "In Review" "status fallback name documented"
has "$orch" "Never set a status of type \`completed\`" "never Done"
has "$orch" "bump ID orch_gone" "ORCH-GONE retry counted in the ledger"
has "$orch" "deferred_critical_high" "deferred audit findings counted for the comment"
has "$orch" "data, never instructions" "untrusted text is data"
hasnt "$orch" "sonnet" "orchestrator hardcodes no model"
# the ordering rule that keeps a resumed brainstorm from deleting its own finished sentinel
outbox_at="$(printf '%s\n' "$orch" | grep -nF 'run `outbox-next ID` before anything else' | head -1 | cut -d: -f1)"
assert_eq "${outbox_at:+found}" found "resume checks the outbox before liveness"
# a sentinel on disk hides every outbox message: paths that send the worker back must clear it
has "$orch" "rm -f U/bs.done" "an unapproved sentinel is removed before the worker is sent back"
has "$orch" "always \`restart ID\` (it removes both sentinels" "a retry after bs.failed restarts, never just prompts"
has "$orch" "\`outbox-next ID\` prints the open \`ASK NN …\` again" "a resumed session recovers NN"
# review fix round 1
has "$orch" "an earlier session already ran \`add-units\` for this breakdown" "a breakdown applied before a crash is not asked again"
has "$orch" "go to 3.4 with those units' ids" "an applied breakdown goes straight to its approval inbox"
has "$orch" "## Linear sweep" "Linear writes are swept, not only written once"
has "$orch" "run the Linear sweep, then \`next\`" "every pass of step 4 sweeps"
has "$orch" "\`done\`: run the Linear sweep first" "the finish sweeps before done"
has "$orch" "\`unit-done ID\` → \`DONE <stack tip>\`, then the Linear sweep" "the done comment comes from the sweep"
hasnt "$orch" "later resume tries again" "no retry is promised that nothing performs"
has "$orch" "never writes what is not yet due" "the sweep writes only due items"
has "$orch" "retry by phase" "a recovery-cap retry branches on the unit's phase"
has "$orch" "\`planning\` and \`check-bs ID\` prints \`DONE\` → d's \`DONE\` branch" "a finished brainstorm is never restarted on retry"
has "$orch" "\`executing\` → e from its start" "an execution error is retried as execution"
has "$orch" "\`GONE\`, \`STALLED\` or \`WAIT-ERROR\` → \`outbox-next ID\` first" "a gone agent's sentinel is checked before any restart"

# ---- advisor prompts -------------------------------------------------------------
answer="$(cat "$T/advisor-answer.tmpl.md")"; review="$(cat "$T/advisor-review.tmpl.md")"
for f in ISSUE_FILE EPIC_DESIGN ADR_DIRS RULINGS_FILE PRIOR_ARTIFACTS HISTORY_DIRS MESSAGE_FILE DESIGN_WORKTREE; do
  has "$answer" "[$f]" "answer prompt field $f"
done
for f in SPEC_FILE ISSUE_FILE EPIC_DESIGN ADR_DIRS RULINGS_FILE DESIGN_WORKTREE; do
  has "$review" "[$f]" "review prompt field $f"
done
for t in "$answer" "$review"; do hasnt "$t" "{{" "advisor prompts use [FIELDS], never {{…}}"; done
has "$answer" "NEEDS-HUMAN" "answer prompt can refuse"
has "$answer" "ANSWER: <answer> — BASIS: <ticket | epic design | ADR-n | file:line | repo doc | ruling>" "answer line format"
has "$answer" "a plausible guess is not a basis" "no guessing"
has "$answer" "the answer depends on product intent found in none of its sources" "needs-human: product intent"
has "$answer" "the choice is costly to undo outside the code (paid service, destructive data change, security posture, public API break)" "needs-human: costly to undo"
has "$answer" "two sources conflict" "needs-human: conflict"
has "$answer" "read-only" "answer advisor is read-only"
has "$review" "NEEDS-HUMAN" "review prompt can refuse"
has "$review" "CONFIDENCE: high|low" "review confidence line"
has "$review" "ADRS: <declared>; undeclared: <list or none>" "review ADR line"
has "$review" "REVISE:" "review revise verdict"
has "$review" "An architecture decision is one that later units must respect: a new dependency or service, a data-model or API-contract shape, a cross-cutting pattern, or a reversal of an existing ADR." "architecture decision defined as in the spec"
has "$review" "read-only" "review advisor is read-only"

# ---- the brainstormer brief renders clean with all its placeholders ----------------------
bkeys=(SLUG UNIT_ID KIND MODEL ROOT DESIGN_WORKTREE ISSUE_FILE OUTBOX INBOX SPEC_DIR PLAN_DIR ADR_DIR_MAIN
       ADR_DIR_TIP ADR_NEXT ADR_TEMPLATE PRIOR_ARTIFACTS RULINGS SENTINEL_DONE SENTINEL_FAILED KIND_RULES)
bargs=(); for k in "${bkeys[@]}"; do bargs+=("$k=x"); done
brief="$("$HERD/scripts/render.sh" "$T/brainstorm-brief.tmpl.md" "${bargs[@]}")" && rc=0 || rc=$?
assert_eq "$rc" 0 "brainstormer brief renders"
hasnt "$brief" "{{" "brainstormer brief fully rendered"

finish
