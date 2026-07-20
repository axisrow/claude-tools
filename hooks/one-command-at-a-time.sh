#!/usr/bin/env bash
# one-command-at-a-time.sh — PreToolUse-хук для Claude Code.
#
# Правило: «Одна bash-команда за один раз — не смешивать». Модель должна вызывать по одной
# команде за Bash-call, а не лепить `cmd1 && cmd2`, `a; b`, `a || b`, `a | b`. Смешивать —
# дурной тон. Хук перехватывает compound-команду ДО выполнения и просит подтверждения (ask).
#
# Вход (stdin): JSON с .tool_input.command (как у git-branch-guard.sh).
# Выход: compound/ambiguous → JSON с permissionDecision:"ask" + reason; clean → тихо exit 0.
#
# Алгоритм: посимвольный обход команды со СТЕКОМ контекстов (SQ/DQ/CS/BT/SS). Операторы
# &&/||/;/|/newline ловятся ТОЛЬКО когда стек пуст или верхушка = CS/BT/SS (subshell исполняет
# compound). Это quote-aware: операторы внутри кавычек игнорируются.
#
# Это МИНИМАЛЬНЫЙ V1 (эвристический guardrail, не security boundary):
#   - поддерживает: escapes, внешние кавычки, $()/backticks (рекурсивно), одиночную ( subshell,
#     # комментарий.
#   - НЕ поддерживает (→ ambiguous → ask): heredoc, arithmetic $(( ))/(( )), [[ ]] conditional,
#     case/esac, ANSI-C $'...', ${...}.
#   - НЕ ловит (known limitation): bash -c '...', eval, ssh host '...' (compound в строковом
#     аргументе); одиночный & (background).
# Расширяем V1 по реальным false-positives (см. README). Если парсер начнёт обрастать
# исключениями — переход на bashlex/mvdan/sh.
set -uo pipefail

# jq нет → пропустить (не ломать сессию), как в git-branch-guard.sh.
command -v jq >/dev/null 2>&1 || exit 0

CMD="$(jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$CMD" ] && exit 0

REASON_COMPOUND='Одна bash-команда за один раз — не смешивать (&&/;/||/|). Смешивать команды — дурной тон: вызывай по одной команде за Bash-call.'
REASON_AMBIGUOUS='Парсер хука встретил конструкцию, которую пока не умеет разбирать (heredoc / arithmetic / [[ ]] / case / $'"'"'). Проверь команду вручную: если в ней несколько команд через &&/;/||/| — вызови их по одной.'

ask() {
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}'
  exit 0
}

# --- стек контекстов (bash 3.2, индексный массив) ---------------------------
# Метки: SQ (одинарная) | DQ (двойная) | CS ($() ) | BT (backtick) | SS (одиночная ( subshell)
STACK=()
# Параллельный depth-счётчик для CS/SS: unclosed ( и ).
# ИНВАРИАНТ: длина PAREN_DEPTH всегда равна числу CS+SS фреймов в STACK. Синхронизация
# инкапсулирована в stack_push_cs/ss и stack_close_paren ниже; любое рассинхронизирование = тихий баг.
PAREN_DEPTH=()
TOP=""   # кэш верхушки стека; обновляется в push/pop. НЕ читать стек через $() в цикле — fork.

stack_push() { STACK+=("$1"); TOP="$1"; }
stack_push_cs() { stack_push CS; PAREN_DEPTH+=("1"); }   # $( ...
stack_push_ss() { stack_push SS; PAREN_DEPTH+=("1"); }   # одиночная ( subshell
stack_pop() {
  local n=${#STACK[@]}
  [ "$n" -eq 0 ] && return 1
  unset 'STACK[n-1]'
  n=$((n-1))
  if [ "$n" -eq 0 ]; then TOP=""; else TOP="${STACK[n-1]}"; fi
}
stack_close_paren() {
  # Закрытие CS/SS по балансу скобок: декремент depth, pop при достижении 0.
  local n=${#PAREN_DEPTH[@]}
  local d="${PAREN_DEPTH[n-1]}"
  d=$((d-1))
  if [ "$d" -le 0 ]; then
    unset 'PAREN_DEPTH[n-1]'
    stack_pop
  else
    PAREN_DEPTH[n-1]="$d"
  fi
}

# Контекст исполняет shell-операторы (→ compound), если стек пуст или верхушка = CS/BT/SS.
# Function-call в bash НЕ порождает subprocess (только $() форкает) — безопасно для горячего цикла.
is_live() {
  [ -z "$TOP" ] && return 0
  case "$TOP" in CS|BT|SS) return 0 ;; esac
  return 1
}

# --- парсер: выставляет глобальную VERDICT (clean|compound|ambiguous) -------
# Без `set -e` намеренно: внутри parse() используются `&& return`/`[ ] && ...`, которые
# -e сломал бы (как в git-branch-guard.sh он есть, но там нет такого парсера).
VERDICT="clean"

parse() {
  local S="$1"
  local N=${#S}
  local i=0
  local c c1
  local escape=0          # 1 = предыдущий символ был неэкранированный \
  local word_start=1      # 1 = в начале слова (для детекции # комментария)
  local NL=$'\n'

  while [ "$i" -lt "$N" ]; do
    c="${S:i:1}"
    # c1 (следующий символ) — лениво, только в ветках где нужен; c2 — прямо в проверке $((.

    # --- escape: \ + следующий символ (кроме внутри SQ) ---
    if [ "$escape" = "1" ]; then
      escape=0
      word_start=0
      i=$((i+1))
      continue
    fi

    # Контекст SQ: всё literal, escape не работает, закрывает только '.
    if [ "$TOP" = "SQ" ]; then
      [ "$c" = "'" ] && stack_pop
      i=$((i+1))
      continue
    fi

    # Контекст DQ: внутри разбираем $(`/backticks, escape над " ` $ \.
    if [ "$TOP" = "DQ" ]; then
      case "$c" in
        '\') escape=1; i=$((i+1)); continue ;;
        '"') stack_pop; i=$((i+1)); continue ;;
        '`') stack_push BT; word_start=1; i=$((i+1)); continue ;;
        '$')
          c1="${S:i+1:1}"
          case "$c1" in
            '(') stack_push_cs; word_start=1; i=$((i+2)); continue ;;
            '{') VERDICT="ambiguous"; return 0 ;;   # ${...} → V1 ambiguous
            *)   i=$((i+1)); continue ;;
          esac
          ;;
      esac
      i=$((i+1))
      continue
    fi

    # Контекст CS/BT/SS/empty — shell-активный. Операторы исполняются (→ compound) если is_live.
    case "$c" in
      '\') escape=1; word_start=0; i=$((i+1)); continue ;;
      "'") stack_push SQ; word_start=1; i=$((i+1)); continue ;;
      '"') stack_push DQ; word_start=1; i=$((i+1)); continue ;;
      '`') stack_push BT; word_start=1; i=$((i+1)); continue ;;
      '$')
        c1="${S:i+1:1}"
        case "$c1" in
          "'") VERDICT="ambiguous"; return 0 ;;   # ANSI-C $'...'
          '"') VERDICT="ambiguous"; return 0 ;;   # locale $"..."
          '(')
            if [ "${S:i+2:1}" = "(" ]; then VERDICT="ambiguous"; return 0; fi   # arithmetic $((...))
            stack_push_cs; word_start=1; i=$((i+2)); continue ;;
          '{') VERDICT="ambiguous"; return 0 ;;   # ${...} → V1 ambiguous
          *)  word_start=0; i=$((i+1)); continue ;;
        esac
        ;;
      '(')
        # Одиночная ( — subshell. '((' подряд → arithmetic → ambiguous.
        if [ "${S:i-1:1}" = "(" ]; then VERDICT="ambiguous"; return 0; fi
        stack_push_ss; word_start=1; i=$((i+1)); continue ;;
      ')')
        # Закрытие CS/SS по балансу скобок.
        if [ "$TOP" = "CS" ] || [ "$TOP" = "SS" ]; then stack_close_paren; fi
        word_start=0; i=$((i+1)); continue ;;
      '<')
        if [ "${S:i+1:1}" = "<" ]; then VERDICT="ambiguous"; return 0; fi   # heredoc << / <<-
        word_start=0; i=$((i+1)); continue ;;
      '[')
        if [ "${S:i+1:1}" = "[" ]; then VERDICT="ambiguous"; return 0; fi   # [[ ]] conditional
        word_start=0; i=$((i+1)); continue ;;
      '#')
        # Комментарий — только в начале слова.
        if [ "$word_start" = "1" ]; then
          while [ "$i" -lt "$N" ] && [ "${S:i:1}" != "$NL" ]; do i=$((i+1)); done
          continue
        fi
        word_start=0; i=$((i+1)); continue ;;
      ' '|$'\t')
        word_start=1; i=$((i+1)); continue ;;
      "$NL")
        word_start=1
        if is_live; then VERDICT="compound"; return 0; fi
        i=$((i+1)); continue ;;
      '&')
        c1="${S:i+1:1}"
        if [ "$c1" = "&" ]; then
          if is_live; then VERDICT="compound"; return 0; fi
          i=$((i+2)); continue
        fi
        # одиночный & — known limitation, НЕ ловим.
        word_start=0; i=$((i+1)); continue ;;
      '|')
        # Одиночный | и || — оба compound (в отличие от &, где одиночный — known limitation).
        if is_live; then VERDICT="compound"; return 0; fi
        if [ "${S:i+1:1}" = "|" ]; then i=$((i+2)); else i=$((i+1)); fi
        word_start=0; continue ;;
      ';')
        if is_live; then VERDICT="compound"; return 0; fi
        word_start=1; i=$((i+1)); continue ;;
      *)
        word_start=0; i=$((i+1)); continue ;;
    esac
  done
}

parse "$CMD"

case "$VERDICT" in
  clean)    exit 0 ;;
  compound) ask "$REASON_COMPOUND" ;;
  ambiguous) ask "$REASON_AMBIGUOUS" ;;
esac
