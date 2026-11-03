#!/usr/bin/env bash
# StopFailure launcher для auto-continue: CC убивает StopFailure-процессы через
# ~10-50 мс (anthropics/claude-code#101420), поэтому здесь только валидация
# события и спавн detached-ребёнка. perl-setsid уводит ребёнка в новую сессию
# процессов — killpg хука его не достаёт; медленная работа (проверка хвоста
# транскрипта + ao send --steer) целиком в ребёнке auto-continue-sf-child.mjs.
#
# Почему StopFailure, а не Stop: с ~CC 2.1.235 Stop на API-error-терминациях
# не файрится вовсе (anthropics/claude-code#87972, регрессия), StopFailure —
# observational (decision игнорируется). Ребёнок верифицирует хвост по
# каноническому carrier'у и шлёт ao send воркеру — см. claude-tools#24.
# Тесты: bash tests/test_auto_continue.sh (секция sf, AUTOCONTINUE_DRY_RUN=1).
set -u

IN=$(cat)
EV=$(printf '%s' "$IN" | jq -r '.hook_event_name // ""')
[ "$EV" = "StopFailure" ] || exit 0
TP=$(printf '%s' "$IN" | jq -r '.transcript_path // ""')
SID=$(printf '%s' "$IN" | jq -r '.session_id // ""')
CWD=$(printf '%s' "$IN" | jq -r '.cwd // ""')
[ -n "$TP" ] && [ -f "$TP" ] || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# setsid внутри perl (в macOS нет util-linux setsid); </dev/null отцепляет stdin
perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' \
  node "$DIR/auto-continue-sf-child.mjs" "$TP" "$SID" "$CWD" \
  </dev/null >/dev/null 2>&1 &
exit 0
