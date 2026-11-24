#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/assert.sh"
t="$(mktemp)"
printf 'Hello {{NAME}}, {{NAME}} & {{OTHER}}\nline2 {{OTHER}}\n' > "$t"
out="$("$HERD/scripts/render.sh" "$t" NAME=world 'OTHER=a&b/c')"
assert_eq "$out" "$(printf 'Hello world, world & a&b/c\nline2 a&b/c')" "render replaces every occurrence, keeps & and / literal"
assert_exit 3 "$HERD/scripts/render.sh" "$t" NAME=world
assert_exit 2 "$HERD/scripts/render.sh" /nonexistent NAME=x
assert_exit 2 "$HERD/scripts/render.sh" "$t" lower=x
finish
