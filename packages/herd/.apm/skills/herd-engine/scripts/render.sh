#!/usr/bin/env bash
# usage: render.sh TEMPLATE KEY=VALUE [KEY=VALUE ...]  > output
# Replaces every {{KEY}} in TEMPLATE. Exit 2: bad template or key. Exit 3: a {{PLACEHOLDER}} is left.
set -euo pipefail
shopt -u patsub_replacement 2>/dev/null || true   # keep '&' literal in values (bash >= 5.2)
tpl="${1:?usage: render.sh TEMPLATE KEY=VALUE...}"; shift
[ -f "$tpl" ] || { printf 'render: no template %s\n' "$tpl" >&2; exit 2; }
content="$(cat "$tpl"; printf x)"; content="${content%x}"   # preserve trailing newlines
for kv in "$@"; do
  key="${kv%%=*}"; val="${kv#*=}"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || { printf 'render: bad key %s\n' "$key" >&2; exit 2; }
  content="${content//"{{$key}}"/$val}"
done
if left="$(printf '%s' "$content" | grep -oE '\{\{[A-Z][A-Z0-9_]*\}\}' | sort -u)"; then
  printf 'render: unreplaced placeholders in %s: %s\n' "$tpl" "$(printf '%s' "$left" | tr '\n' ' ')" >&2
  exit 3
fi
printf '%s' "$content"
