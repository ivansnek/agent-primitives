#!/usr/bin/env bash
# usage: scripts/progress.sh RUN_DIR
# Regenerates RUN_DIR/PROGRESS.md from run.json, the pause file and orchestrator.log, replacing
# it atomically. PROGRESS.md is output only: it is never read, and nothing else is written.
# Ledger strings are untrusted (issue titles come from Linear): they pass through jq as data,
# never through the shell, and every table cell is forced onto one line with its pipes escaped.
# A missing pause file or log is not an error; a missing or invalid ledger is, and leaves the
# previous PROGRESS.md as it was.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || herd_die "loop: usage: progress.sh RUN_DIR"
run="${1%/}"
[ -f "$run/run.json" ] || herd_die "loop: no ledger: $run/run.json"
# read once, so every section describes the same state of the ledger
ledger="$(cat -- "$run/run.json")"
jq -es 'length == 1 and (.[0] | type == "object" and (.units | type) == "array")' <<<"$ledger" >/dev/null 2>&1 \
  || herd_die "loop: no ledger (not a run.json with a units array): $run/run.json"

# line: any value on one line. cell: also safe between table pipes; backslashes in front of a
# pipe are doubled so that they cannot cancel its escape.
JQ_DEFS='
def line: if . == null or . == "" then "-" else tostring | gsub("[\u0000-\u001f\u007f\u0085  ]+"; " ") end;
def cell: line | gsub("(?<b>\\\\*)\\|"; .b + .b + "\\|");'
q() { jq -r "$JQ_DEFS $1" <<<"$ledger" || herd_die "loop: could not render the ledger: $run/run.json"; }

tmp="$(mktemp "$run/PROGRESS.md.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

{
  q '"# linear-loop \(.slug | line)",
     "",
     "Status: \(.status | line) · base \(.base | line) · stack tip \(.stack_tip | line) · updated \(.updated_at | line)",
     ""'

  if [ "$(q '.pause != null')" = true ]; then
    q '"## Waiting for you",
       "",
       (.pause | "Kind: \(.kind | line) · unit \(.unit | line) · asked \(.asked_at | line)"),
       ""'
    # the ledger can name the pause file a moment before it exists
    file="$(q '.pause.file // ""')"
    if [ -f "$file" ]; then
      cat -- "$file"
      [ -z "$(tail -c 1 -- "$file")" ] || printf '\n'
    else
      printf '(pause file missing: %s)\n' "${file:--}"
    fi
    printf '\n'
  fi

  q '"## Units",
     "",
     "| # | Issue | Kind | Phase | Branch | Spec | Plan | ADRs |",
     "|---|---|---|---|---|---|---|---|",
     (.units | to_entries[] | .key as $i | .value
      | [ (.order // ($i + 1)),
          ([.id, .title] | map(select(. != null and . != "")) | join(" ")),
          .kind, .phase, .branch, .spec, .plan,
          ((.adrs // []) | join(", ")) ]
      | "| " + (map(cell) | join(" | ")) + " |"),
     "",
     (if (.skipped // []) | length > 0
      then "## Skipped", "", (.skipped[] | "- \(.id | line): \(.reason | line)"), ""
      else empty end)'

  log=""
  [ ! -f "$run/orchestrator.log" ] || log="$(tail -n 20 -- "$run/orchestrator.log")"
  # a fence longer than any backtick run in the tail, so no log line can close it
  fence="$(printf '%s' "$log" | LC_ALL=C awk 'BEGIN { n = 2 }
    { s = $0; while (match(s, /`+/)) { if (RLENGTH > n) n = RLENGTH; s = substr(s, RSTART + RLENGTH) } }
    END { for (i = 0; i <= n; i++) printf "`" }')"
  printf '## Log (last 20)\n\n%s\n' "$fence"
  [ -z "$log" ] || printf '%s\n' "$log"
  printf '%s\n' "$fence"
} > "$tmp"

chmod 644 "$tmp"          # mktemp makes it private
mv -- "$tmp" "$run/PROGRESS.md"
