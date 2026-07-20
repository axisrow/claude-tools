#!/usr/bin/env bash
#
# cleanup_procs.sh — убирает осиротевшие/залежавшиеся фоновые процессы,
# которые плодят Claude Code / agent-orchestrator / Codex сессии и не
# подчищают за собой при завершении.
#
# Главные виновники (по наблюдениям на 24 GB Mac):
#   - context7-mcp        : MCP-сервер документации, переживает свою сессию
#   - app-server-broker   : codex broker, остаётся с PPID=1 после смерти сессии
#   - SkyComputerUseClient: хвосты codex computer-use turn-ended
#
# БЕЗОПАСНОСТЬ:
#   - По умолчанию DRY-RUN: только показывает, ничего не убивает.
#   - Убивает процесс ТОЛЬКО если он старше MIN_AGE_MIN минут (по умолчанию 60),
#     чтобы гарантированно не задеть только что заспавненные живые сессии.
#   - Никогда не трогает собственное дерево процессов (этот скрипт и его родителей).
#   - Шлёт SIGTERM (мягко), не SIGKILL.
#
# Использование:
#   ./cleanup_procs.sh              # dry-run, возраст по умолчанию 60 мин
#   ./cleanup_procs.sh --apply      # реально убить
#   ./cleanup_procs.sh --apply --min-age 30   # порог 30 минут
#   ./cleanup_procs.sh --mem        # только показать сводку по памяти/swap

set -euo pipefail

APPLY=0
MIN_AGE_MIN=60
MEM_ONLY=0

# Паттерны процессов-кандидатов на чистку (расширяй по мере надобности).
PATTERNS=(
  "context7-mcp"
  "app-server-broker"
  "SkyComputerUseClient"
)

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1 ;;
    --min-age)  shift; MIN_AGE_MIN="$1" ;;
    --mem)      MEM_ONLY=1 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "Неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
  shift
done

# --- защита: PID-дерево этого скрипта (нельзя убивать самих себя/родителей) ---
SELF_PID=$$
PROTECTED=" $SELF_PID "
p=$SELF_PID
while [ "$p" -gt 1 ]; do
  pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || break
  [ -z "$pp" ] && break
  PROTECTED="$PROTECTED$pp "
  p=$pp
done

mem_summary() {
  echo "=== Память / swap ==="
  sysctl -n vm.swapusage 2>/dev/null | sed 's/^/swap: /'
  top -l 1 -n 0 2>/dev/null | grep PhysMem
}

# etime → минуты. Форматы ps: SS, MM:SS, HH:MM:SS, D-HH:MM:SS
# Без `read -a` (нет в некоторых окружениях) — чисто parameter expansion.
etime_to_min() {
  local e="$1" days=0 hh=0 mm=0 rest c1 c2
  if [ "${e#*-}" != "$e" ]; then days="${e%%-*}"; rest="${e#*-}"; else rest="$e"; fi
  # Сколько двоеточий в rest → определяем формат
  c1="${rest#*:}"          # после первого ':'
  if [ "$c1" = "$rest" ]; then
    # нет двоеточий → только секунды → 0 минут вклада
    :
  else
    c2="${c1#*:}"          # после второго ':'
    if [ "$c2" = "$c1" ]; then
      # один ':' → MM:SS
      mm="${rest%%:*}"
    else
      # два ':' → HH:MM:SS
      hh="${rest%%:*}"
      mm="${c1%%:*}"
    fi
  fi
  echo $(( 10#${days:-0}*1440 + 10#${hh:-0}*60 + 10#${mm:-0} ))
}

if [ "$MEM_ONLY" -eq 1 ]; then
  mem_summary
  exit 0
fi

echo "=== cleanup_procs.sh ==="
echo "режим: $([ "$APPLY" -eq 1 ] && echo APPLY || echo DRY-RUN), порог возраста: ${MIN_AGE_MIN} мин"
echo ""
mem_summary
echo ""

total_killed=0
total_mb=0

for pat in "${PATTERNS[@]}"; do
  # pid etime rss(KB) — берём процессы по паттерну, исключая grep сам себя.
  # Через временный файл, т.к. macOS-bash 3.2 не имеет mapfile.
  cand=0; cand_mb=0; pids=()
  while read -r pid etime rss _rest; do
    [ -z "$pid" ] && continue
    [[ "$PROTECTED" == *" $pid "* ]] && continue
    age=$(etime_to_min "$etime")
    if [ "$age" -ge "$MIN_AGE_MIN" ]; then
      pids+=("$pid")
      cand=$((cand+1))
      cand_mb=$((cand_mb + rss/1024))
    fi
  done < <(ps -axo pid,etime,rss,command 2>/dev/null | grep "[${pat:0:1}]${pat:1}" || true)
  printf "  %-22s кандидатов: %3d  (~%d MB)\n" "$pat" "$cand" "$cand_mb"
  if [ "$APPLY" -eq 1 ] && [ "$cand" -gt 0 ]; then
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    total_killed=$((total_killed + cand))
    total_mb=$((total_mb + cand_mb))
  fi
done

echo ""
if [ "$APPLY" -eq 1 ]; then
  echo "Отправлен SIGTERM: $total_killed процессам (~${total_mb} MB RSS освобождено)."
  sleep 3
  echo ""
  echo "=== Память после чистки ==="
  mem_summary
else
  echo "DRY-RUN — ничего не убито. Повтори с --apply, чтобы применить."
fi
