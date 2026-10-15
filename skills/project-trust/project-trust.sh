#!/bin/sh
# Проставляет hasTrustDialogAccepted=true проекту в ~/.claude.json.
# Использование: project-trust.sh <путь-к-проекту>   (без аргумента — текущий каталог)
# Печатает "путь: старое -> true"; идемпотентен. Зависимость: jq.
set -eu

f="$HOME/.claude.json"
proj=$(cd "${1:-.}" && pwd)
tmp="$f.tmp.$$"

old=$(jq -r --arg p "$proj" '.projects[$p].hasTrustDialogAccepted // "absent"' "$f")
jq --arg p "$proj" '.projects[$p].hasTrustDialogAccepted = true' "$f" > "$tmp"
mv "$tmp" "$f"
echo "$proj: $old -> true"
