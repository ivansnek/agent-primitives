#!/usr/bin/env bash
# usage: bash tests/test-progress.sh
# progress.sh: run.json (+ pause file and log) -> PROGRESS.md.
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"

# ---- the brief's cases ----------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"
"$LOOP/scripts/progress.sh" "$run"; p="$(cat "$run/PROGRESS.md")"
assert_contains "$p" "# linear-loop eng-1-loop" "title"
assert_contains "$p" "Status: running" "status line"
assert_contains "$p" "| 1 | ENG-10" "first unit row"
assert_not_contains "$p" "## Waiting for you" "no pause section when not paused"
printf 'Which auth provider?\n' > "$run/pause-01.md"
jq --arg f "$run/pause-01.md" '.status="waiting-human" | .pause={seq:1,unit:"ENG-12",kind:"advisor",file:$f,asked_at:"2026-01-01T00:00:00Z"}' "$run/run.json" > "$run/t" && mv "$run/t" "$run/run.json"
jq '.units[1].title="a | b \"q\" $x"' "$run/run.json" > "$run/t" && mv "$run/t" "$run/run.json"
"$LOOP/scripts/progress.sh" "$run"; p="$(cat "$run/PROGRESS.md")"
assert_contains "$p" "## Waiting for you" "pause section"
assert_contains "$p" "Which auth provider?" "pause text inlined"
assert_contains "$p" 'a \| b "q" $x' "title pipes escaped, rest verbatim"
assert_exit 1 "$LOOP/scripts/progress.sh" /nonexistent

# ---- helpers --------------------------------------------------------------------
edit() { jq "$@" "$run/run.json" > "$run/t" && mv "$run/t" "$run/run.json"; }
render() { "$LOOP/scripts/progress.sh" "$run" && p="$(cat "$run/PROGRESS.md")"; }
has_line() { if grep -qxF -- "$1" "$run/PROGRESS.md"; then pass; else fail "$2: no line '$1' in: $p"; fi; }
headings() { grep '^## ' "$run/PROGRESS.md" | tr '\n' ';'; }

# ---- whole document ---------------------------------------------------------------
r="$(make_repo)"; run="$(make_loop_run "$r")"; render
assert_eq "$p" '# linear-loop eng-1-loop

Status: running · base dev · stack tip dev · updated 2026-01-01T00:00:00Z

## Units

| # | Issue | Kind | Phase | Branch | Spec | Plan | ADRs |
|---|---|---|---|---|---|---|---|
| 1 | ENG-10 CSV export | epic-design | pending | - | - | - | - |
| 2 | ENG-12 Export schema | issue | pending | - | - | - | - |
| 3 | ENG-11 Export service | issue | pending | - | - | - | - |

## Log (last 20)

```
```' "clean run: exact layout"
assert_eq "$(jq -r .design_worktree "$run/run.json" | xargs -I{} git -C {} rev-parse --abbrev-ref HEAD)" "HEAD" "fixture: design worktree is real and detached"

# ---- filled cells -----------------------------------------------------------------
edit '.units[1] |= (.branch="feat/eng-12" | .spec="docs/s.md" | .plan="docs/p.md" | .adrs=["docs/adr/0001-a.md","docs/adr/0002-b|c.md"])'
render
has_line '| 2 | ENG-12 Export schema | issue | pending | feat/eng-12 | docs/s.md | docs/p.md | docs/adr/0001-a.md, docs/adr/0002-b\|c.md |' "paths and ADR list"

# ---- hostile titles: verbatim, one row each, nothing expanded -------------------------
marker="$run/expanded"
t="\$(touch $marker) \`touch $marker\` {{FOO}} & \$HOME %s \\n <b> *x*"
edit --arg t "$t" '.units[1].title=$t'
render
has_line "| 2 | ENG-12 $t | issue | pending | feat/eng-12 | docs/s.md | docs/p.md | docs/adr/0001-a.md, docs/adr/0002-b\\|c.md |" "hostile title verbatim"
assert_no_file "$marker" "title never shell-expanded"
edit '.units[1].title="one\ntwo\r\nthree\tfour five" | .units[2].title="back\\|slash | end\\"'
render
has_line '| 2 | ENG-12 one two three four five | issue | pending | feat/eng-12 | docs/s.md | docs/p.md | docs/adr/0001-a.md, docs/adr/0002-b\|c.md |' "newlines and control characters become one space"
has_line '| 3 | ENG-11 back\\\|slash \| end\ | issue | pending | - | - | - | - |' "a backslash before a pipe cannot unescape it"
assert_eq "$(grep -c '^|' "$run/PROGRESS.md")" "5" "header, rule and one line per unit"
edit '.units[2].title=null'; render
has_line '| 3 | ENG-11 | issue | pending | - | - | - | - |' "missing title"

# ---- pause --------------------------------------------------------------------------
printf '## Options\n\n1. $(echo no) `a` | {{B}}\nlast line without newline' > "$run/pause-02.md"
edit --arg f "$run/pause-02.md" '.status="waiting-human" | .pause={seq:2,unit:null,kind:"map",file:$f,asked_at:"2026-01-02T00:00:00Z"}'
render
assert_eq "$(headings)" '## Waiting for you;## Options;## Units;## Log (last 20);' "section order"
has_line 'Kind: map · unit - · asked 2026-01-02T00:00:00Z' "pause facts; no unit"
assert_contains "$p" '## Options

1. $(echo no) `a` | {{B}}
last line without newline

## Units' "full pause text, verbatim"
rm "$run/pause-02.md"; assert_exit 0 "$LOOP/scripts/progress.sh" "$run"; render
assert_contains "$p" "(pause file missing: $run/pause-02.md)" "a missing pause file is reported, not fatal"

# ---- skipped --------------------------------------------------------------------------
edit '.pause=null | .skipped=[{id:"ENG-41",reason:"completed"},{id:"ENG-42",reason:"all-children-done"}]'
render
assert_eq "$(headings)" '## Units;## Skipped;## Log (last 20);' "skipped sits between units and log"
has_line '- ENG-41: completed' "skipped entry"
has_line '- ENG-42: all-children-done' "second skipped entry"

# ---- log tail -------------------------------------------------------------------------
for i in $(seq 1 25); do printf 'entry-%02d $x {{Y}}\n' "$i"; done > "$run/orchestrator.log"
render
assert_eq "$(grep -c '^entry-' "$run/PROGRESS.md")" "20" "20 lines"
assert_not_contains "$p" "entry-05" "older lines dropped"
has_line 'entry-06 $x {{Y}}' "tail starts at the 20th line from the end"
has_line 'entry-25 $x {{Y}}' "newest line kept"
printf '```\n````` five\nno newline' > "$run/orchestrator.log"; render
assert_contains "$p" '## Log (last 20)

``````
```
````` five
no newline
``````' "fence outgrows any backtick run in the log"
rm "$run/orchestrator.log"; assert_exit 0 "$LOOP/scripts/progress.sh" "$run"

# ---- writing ------------------------------------------------------------------------
cp "$run/run.json" "$run.ledger"
printf 'hand edit\n' > "$run/PROGRESS.md"; render
assert_not_contains "$p" "hand edit" "regenerated from the ledger, old content ignored"
assert_eq "$(cat "$run/run.json")" "$(cat "$run.ledger")" "ledger untouched"
assert_eq "$(ls "$run" | grep -c PROGRESS)" "1" "no temp file left"
assert_eq "$(find "$run/PROGRESS.md" -perm 644 | wc -l | tr -d ' ')" "1" "readable by others, as a plain file would be"
assert_eq "$(cd "$run/.." && "$LOOP/scripts/progress.sh" eng-1-loop/ && echo ok)" "ok" "relative run dir"

# ---- failures leave the previous file alone ---------------------------------------------
before="$(cat "$run/PROGRESS.md")"
for bad in 'not json' '' '[]' '{"slug":"x","units":"nope"}' '{"slug":"x"}' '{"units":[1]}'; do
  printf '%s' "$bad" > "$run/run.json"
  out="$("$LOOP/scripts/progress.sh" "$run" 2>&1)" && rc=0 || rc=$?
  assert_eq "$rc" 1 "bad ledger '$bad' exits 1"
  assert_contains "$out" "herd: error: loop:" "bad ledger '$bad': error prefix"
done
assert_eq "$(cat "$run/PROGRESS.md")" "$before" "previous PROGRESS.md kept"
assert_eq "$(ls -A "$run" | grep -c PROGRESS)" "1" "no temp file left after a failure"
rm "$run/run.json"
assert_contains "$("$LOOP/scripts/progress.sh" "$run" 2>&1 || true)" "herd: error: loop: no ledger" "no ledger"
assert_exit 1 "$LOOP/scripts/progress.sh"
finish
