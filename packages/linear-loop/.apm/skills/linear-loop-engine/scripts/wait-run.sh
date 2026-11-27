#!/usr/bin/env bash
# usage: scripts/wait-run.sh HERD_RUN_JSON ORCH_NAME
# Watches one herd run until it needs the loop orchestrator. Meant to run in the background.
#   DONE (0) | FAILED <failed stage> (2) | ORCH-GONE (4): not finished and its orchestrator
#   absent on two polls in a row | STUCK created (7) | STUCK stale (7): updated_at not moving.
# A missing or unreadable ledger counts as status "created". Both STUCK limits are measured from
# what this process has seen.
#   LOOP_POLL_SECONDS (30), LOOP_CREATED_LIMIT_SECONDS (600), LOOP_STALE_LIMIT_SECONDS (21600)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ $# -eq 2 ] || herd_die "loop: usage: wait-run.sh HERD_RUN_JSON ORCH_NAME"
RUN_JSON="$1"; ORCH="$2"
POLL="${LOOP_POLL_SECONDS:-30}"
CREATED_LIMIT="${LOOP_CREATED_LIMIT_SECONDS:-600}"
STALE_LIMIT="${LOOP_STALE_LIMIT_SECONDS:-21600}"
herd_require jq

created_since=""; updated=""; updated_since=""; gone=0
while :; do
  # one read per poll, so the three values belong to the same version of the file
  if snap="$(jq -ers 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end
        | [.status // "created", .failed_stage // "unknown", .updated_at // "-"] | map(tostring) | .[]' \
        "$RUN_JSON" 2>/dev/null)"; then
    { IFS= read -r status; IFS= read -r stage; IFS= read -r seen; } <<<"$snap"
  else
    status=created; seen=""
  fi
  case "$status" in
    done) echo "DONE"; exit 0 ;;
    failed) echo "FAILED $stage"; exit 2 ;;
  esac

  case "$status" in
    created|running) if herd_agent_live "$ORCH"; then gone=0; else gone=$((gone + 1)); fi ;;
    *) gone=0 ;;
  esac
  [ "$gone" -lt 2 ] || { echo "ORCH-GONE"; exit 4; }

  if [ "$status" = created ]; then
    created_since="${created_since:-$SECONDS}"
    [ $((SECONDS - created_since)) -lt "$CREATED_LIMIT" ] || { echo "STUCK created"; exit 7; }
  else
    created_since=""
  fi
  if [ -n "$seen" ]; then                      # an unreadable poll says nothing about movement
    [ "$seen" = "$updated" ] || { updated="$seen"; updated_since="$SECONDS"; }
    [ $((SECONDS - updated_since)) -lt "$STALE_LIMIT" ] || { echo "STUCK stale"; exit 7; }
  fi
  sleep "$POLL"
done
