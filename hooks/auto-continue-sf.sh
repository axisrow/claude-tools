#!/usr/bin/env bash
# StopFailure launcher для auto-continue: CC убивает StopFailure-процессы через
# ~10-50 мс (anthropics/claude-code#101420), поэтому здесь только чтение stdin и
# спавн detached-ребёнка (perl-setsid — новая process session, killpg хука его
# не достаёт). Никакого jq в критичном окне: весь разбор и медленная работа
# (проверка хвоста, бюджет, ao send --steer) — в auto-continue-sf-child.mjs.
#
# Почему StopFailure, а не Stop: с ~CC 2.1.235 Stop на API-error-терминациях
# не файрится вовсе (anthropics/claude-code#87972, регрессия), StopFailure —
# observational (decision игнорируется). См. claude-tools#24.
# Тесты: bash tests/test_auto_continue.sh (секция sf, AUTOCONTINUE_DRY_RUN=1).
set -u

IN=$(cat)
[ -n "$IN" ] || exit 0

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# setsid внутри perl (в macOS нет util-linux setsid); </dev/null отцепляет stdin
perl -e 'use POSIX qw(setsid); setsid(); exec @ARGV' \
  node "$DIR/auto-continue-sf-child.mjs" "$IN" \
  </dev/null >/dev/null 2>&1 &
exit 0
