#!/usr/bin/env bash
# git-branch-guard.sh — PreToolUse-хук для Claude Code.
#
# Перехватывает опасные git/gh-операции ДО выполнения и просит подтверждения
# у человека (permissionDecision: "ask"). Харнесс исполняет этот скрипт, не агент,
# поэтому правило нельзя «забыть».
#
# Вход (stdin): JSON с .tool_input.command (см. доку Claude Code по hooks).
# Выход: если команда матчит опасный паттерн — JSON с permissionDecision:"ask"
#         и reason; иначе тихо exit 0 (пропустить).
#
# Логика намеренно простая: всегда спрашивать. Без сети, без gh, без парсинга веток.
# Полный список паттернов — в README.md проекта claude-tools.
set -euo pipefail

# Если jq нет — пропустить (не ломать сессию). Лучше пропустить, чем крашнуть хук.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Читаем команду. tool_input может отсутствовать на не-Bash вызовах — тогда пропускаем.
CMD="$(jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$CMD" ] && exit 0

# Нормализуем: сжимаем повторы пробелов/табов, чтобы паттерны сработали на
# командах вроде "git  push   origin --force".
CMD_NORM="$(printf '%s' "$CMD" | tr -s ' \t' ' ')"
# Первое слово — чтобы отличить алиас/обёртку от настоящего git/gh.
FIRST="${CMD_NORM%% *}"

# Если это не git/gh (возможно через sudo/env/путь) — не наше.
case "$FIRST" in
  git|gh) : ;;
  *) exit 0 ;;
esac

# Функция: вернуть ask-решение с причиной и выйти.
ask() {
  local reason="$1"
  jq -nc \
    --arg reason "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"ask",permissionDecisionReason:$reason}}'
  exit 0
}

# Список опасных паттернов. Каждый — причина для человека.
# Порядок: от самых разрушительных к менее.

# 1. Удаление remote-ветки через push --delete  →  ЗАКРЫВАЕТ PR на GitHub.
if printf '%s' "$CMD_NORM" | grep -Eq 'git push .+ --delete( |$)'; then
  ask "git push --delete: удаление remote-ветки. Если на ней открыт PR — GitHub закроет его. Подтвердить?"
fi

# 2. Удаление remote-ветки через push :branch  (git push origin :feat/x)
if printf '%s' "$CMD_NORM" | grep -Eq 'git push [^ ]+ +:[^/ ]+'; then
  ask "git push :branch: удаление remote-ветки. Может закрыть открытый PR. Подтвердить?"
fi

# 3. Force-push  →  переписывает head, ломает PR, сбрасывает ревью.
#    Ловим --force и -f в git push (но не короткий -f у других подкоманд).
if printf '%s' "$CMD_NORM" | grep -Eq 'git push .+ --force( |$)'; then
  ask "git push --force: переписывает историю ветки, ломает открытый PR и сбрасывает ревью. Подтвердить?"
fi
if printf '%s' "$CMD_NORM" | grep -Eq 'git push .+ -f( |$)'; then
  ask "git push -f: переписывает историю ветки, ломает открытый PR и сбрасывает ревью. Подтвердить?"
fi

# 4. gh pr close --delete-branch  →  закрыть PR И удалить ветку одним выстрелом.
if printf '%s' "$CMD_NORM" | grep -Eq 'gh pr close .+ --delete-branch'; then
  ask "gh pr close --delete-branch: закрывает PR и удаляет ветку. Подтвердить?"
fi

# 5. git branch -D / -d  →  удаление локальной ветки.
#    PR не закрывает, но если локальная ветка — единственный источник коммитов, работа теряется.
if printf '%s' "$CMD_NORM" | grep -Eq 'git branch -[Dd]( |$)'; then
  ask "git branch -D/-d: удаление локальной ветки. Если в ней есть незапушенные коммиты — можно потерять работу. Подтвердить?"
fi

# Ничего не матчит — пропустить тихо.
exit 0
