#!/usr/bin/env bash
# usage: scripts/order.sh MAP_JSON
# Turns the orchestrator's map.json ({"given":[IDs],"issues":[…]} from Linear) into the ordered
# unit map on stdout: {"units":[…],"skipped":[…],"problems":[…]}. Pure and deterministic: only
# the order of "given" matters, not that of the other arrays (except that, of two issues with the
# same id, the first wins). Problems are data (exit 0); a missing or malformed map exits 1.
#
# Rules: ids are upper-cased; "in run" = given issues and their descendants. completed/canceled
# issues are skipped and dropped from every relation; so is an open issue whose sub-issues are
# all finished (all-children-done). A closed issue is transparent: its open sub-issues take its
# place. A leaf is an `issue` unit; a parent with one live child collapses into that child (its
# relations move with it); two or more make an `epic-design` unit followed by the children,
# contiguous. Each nesting level is ordered by Kahn's algorithm over relations lifted to that
# level, ties by (position of the root in given, createdAt, numeric id). Cyclic edges are reported
# and ignored; every other edge still holds.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ $# -eq 1 ] || herd_die "loop: usage: order.sh MAP_JSON"
map="$1"
[ -f "$map" ] || herd_die "loop: no map file: $map"

# Empty output = well formed; otherwise the reason. Parent links must not loop (the tree walks
# below would not terminate).
CHECK='
def up: if type == "string" then ascii_upcase else . end;
if length != 1 then "expected exactly one JSON document"
else .[0] |
  if type != "object" then "not a JSON object"
  elif (.given | type) != "array" or any(.given[]; type != "string") then "given must be an array of ids"
  elif (.issues | type) != "array" then "issues must be an array"
  elif any(.issues[]; type != "object"
        or (.id | type) != "string" or (.statusType | type) != "string"
        or ((.parent | type) | IN("null", "string") | not)
        or ((.createdAt | type) | IN("null", "string") | not)
        or ((.blockedBy // []) | type != "array" or any(.[]; type != "string")))
    then "every issue needs a string id and statusType; parent and createdAt null or string; blockedBy an array of ids"
  else
    (reduce .issues[] as $i ({}; ($i.id | up) as $k | if has($k) then . else .[$k] = ($i.parent | up) end)) as $P
    | ($P | length) as $n
    | if any($P | keys[]; [limit($n + 1; recurse($P[.] // empty))] | length > $n)
      then "parent links form a loop" else empty end
  end
end'

ORDER='
def up: if type == "string" then ascii_upcase else . end;
def uniq: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
def idkey: if test("^.+-[0-9]+$") then (capture("^(?<p>.+)-(?<n>[0-9]+)$") | [.p, (.n | tonumber)]) else [., -1] end;
# transitive closure of an adjacency list of indexes
def closure: . as $d | reduce range(0; length) as $_ ($d; . as $c | map(. as $row | ($row + [$row[] as $j | $c[$j][]]) | unique));

.[0] as $in
| ($in.given | map(up) | uniq) as $given
| (reduce ($in.issues[] | .id |= up | .parent = (.parent | up) | .blockedBy = ((.blockedBy // []) | map(up) | uniq))
     as $i ({}; if has($i.id) then . else .[$i.id] = $i end)) as $I
| def known($id): $I | has($id);
  def inactive($id): known($id) and ($I[$id].statusType | IN("completed", "canceled"));
  def ckey($id): [($I[$id].createdAt // ""), ($id | idkey)];
  (reduce $I[] as $i ({}; if $i.parent != null and known($i.parent) then .[$i.parent] += [$i.id] else . end)
   | map_values(sort_by(ckey(.)))) as $K
| def kids($id): $K[$id] // [];
  def leaf($id): (kids($id) | length) == 0;
  def desc($id): [$id | recurse(kids(.)[])];          # preorder, self first, children by createdAt
  ($given | map(select(known(.)))) as $known
| [$known[] | . as $g | select(any($known[]; . != $g and any(desc(.)[]; . == $g)) | not)] as $roots
| (reduce $roots[] as $r ({}; reduce desc($r)[] as $d (.; .[$d] = $r))) as $RootOf
| (reduce range(0; $given | length) as $p ({}; .[$given[$p]] = $p)) as $GP
| def inrun($id): $RootOf | has($id);
  # live = active, in run, with an active leaf somewhere at or below it (through closed issues too)
  (reduce ($RootOf | keys[]) as $id ({};
     .[$id] = ((inactive($id) | not) and any(desc($id)[]; (inactive(.) | not) and leaf(.))))) as $Live
| def live($id): $Live[$id] // false;
  def lift($id): [kids($id)[] | if inactive(.) then lift(.)[] elif live(.) then . else empty end];
  # a node and the collapsed single-child parents below it; the last one carries the unit
  def chain($id): if leaf($id) then [$id] else (lift($id) as $L | if ($L | length) == 1 then [$id] + chain($L[0]) else [$id] end) end;
  def rep($id): chain($id) | last;
  def eff($id): [$I[$id].blockedBy[] | select(live(.))];
  def key($id): [$GP[$RootOf[$id]]] + ckey($id);
  def napar($id): $I[$id].parent as $p | if $p == null or (inrun($p) | not) then null elif inactive($p) then napar($p) else $p end;
  def unit($ch; $kind): ($ch | last) as $r
    | {id: $r, uuid: ($I[$r].uuid // null), title: ($I[$r].title // null), kind: $kind, parent: napar($r),
       blocked_by: ([$ch[] | eff(.)[] | rep(.)] | map(select(. != $r)) | unique)};
  # Orders sibling items (node ids) and emits their units, recursing into epic groups.
  def place($items):
    ($items | length) as $n
    | ([range(0; $n) as $x | desc($items[$x])[] | select(live(.)) | {key: ., value: $x}] | from_entries) as $at
    | [range(0; $n) as $x | desc($items[$x])[] | select(live(.)) as $m | eff($m)[] as $b
       | ($at[$b] // null) as $y | select($y != null and $y != $x) | {m: $m, b: $b, x: $x, y: $y}] as $rel
    | [range(0; $n) as $x | [$rel[] | select(.x == $x) | .y] | unique] as $dep
    | ($dep | closure) as $reach
    | [range(0; $n) as $x | [$dep[$x][] | . as $y | select(any($reach[$y][]; . == $x) | not)]] as $keep
    | [range(0; $n) | key($items[.])] as $keys
    | (reduce range(0; $n) as $_ ({placed: [], left: [range(0; $n)]};
         . as $s
         | ([$s.left[] | select(all($keep[.][]; . as $j | any($s.placed[]; . == $j)))] | min_by($keys[.])) as $next
         | .placed += [$next] | .left -= [$next])) as $st
    | [range(0; $n) as $x | ([$x] + [$reach[$x][] as $y | select(any($reach[$y][]; . == $x)) | $y]) | unique
       | select(length > 1)] | unique | sort_by(map($keys[.]) | min) as $sccs
    | [$sccs[] as $c
       | [$rel[] | . as $r | select(any($c[]; . == $r.x) and any($c[]; . == $r.y))] as $cr
       | {type: "cycle", ids: ([$cr[] | .m, .b] | unique | sort_by(idkey)),
          detail: ($cr | sort_by([(.m | idkey), (.b | idkey)]) | map("\(.m) is blocked by \(.b)") | join("; "))}] as $cyc
    | reduce $st.placed[] as $x ({units: [], problems: $cyc};
        chain($items[$x]) as $ch | ($ch | last) as $r
        | if leaf($r) then .units += [unit($ch; "issue")]
          else ([$ch[] as $c | eff($c)[] | . as $b | select($b != $r and any(desc($r)[]; . == $b))
                 | {type: "cycle", ids: [$c, $b], detail: "\($c) is blocked by \($b), which is inside its own group"}]) as $own
            | place(lift($r)) as $sub
            | .units += [unit($ch; "epic-design")] + $sub.units
            | .problems += $own + $sub.problems
          end);

  [$roots[] | if inactive(.) then lift(.)[] elif live(.) then . else empty end] as $top
| place($top) as $res
| ($res.units | to_entries | map(.value + {order: (.key + 1)})) as $u0
| (reduce $u0[] as $u ({}; .[$u.id] = $u.order)) as $ord
| [$roots[] | desc(.)[]] as $pre
| [$pre[] | if inactive(.) then {id: ., reason: $I[.].statusType}
            elif (leaf(.) | not) and (live(.) | not) then {id: ., reason: "all-children-done"}
            else empty end] as $skipped
| [$given[] | select(known(.) | not) | {type: "unknown-id", ids: [.], detail: "\(.) is not in the map"}] as $unknown
| [$pre[] | select(live(.)) as $m | $I[$m].blockedBy | sort_by(idkey)[]
   | select((inrun(.) | not) and (inactive(.) | not))
   | {type: "external", ids: [$m, .],
      detail: ("\($m) is blocked by \(.), which is outside the run and "
               + (if known(.) then "not done" else "not in the map" end)
               + (if rep($m) != $m then " (unit \(rep($m)))" else "" end))}] as $ext
| {units: ($u0 | map(.blocked_by |= sort_by($ord[.]))),
   skipped: $skipped,
   problems: (($unknown + $ext + $res.problems)
              | if length == 0 and ($u0 | length) == 0
                then [{type: "empty", ids: [], detail: "nothing to do: every given issue is done, canceled or unknown"}]
                else . end)}'

why="$(jq -rs "$CHECK" "$map" 2>/dev/null)" || herd_die "loop: map is not valid JSON: $map"
[ -z "$why" ] || herd_die "loop: malformed map ($why): $map"
jq -s "$ORDER" "$map" || herd_die "loop: could not order the map: $map"
