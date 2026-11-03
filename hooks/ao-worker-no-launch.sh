#!/usr/bin/env bash
# ao-worker-no-launch.sh — PreToolUse-хук Claude Code.
#
# Запрещает запуск AO-демона/десктоп-приложения из worker-сессий AO.
# Инцидент 2026-09-27: репро-воркер поднял второй Electron+демон с тем же
# AO_DATA_DIR → SQLITE_BUSY на общей ~/.ao/data/ao.db → спавн оркестраторов
# завис в «Spawning…», проекты покраснели.
#
# Воркер определяется по env: pty-host ставит AO_SUPERVISED_PROCESS только
# supervised agent-процессам; у основной сессии владельца AO_*-маркеров нет.
#
# Потолок: гард текстовый — непрямые обёртки (npm script/make/launchctl/osascript,
# чей ВНУТРЕННИЙ запуск не виден в строке команды) не матчатся. `env -i` в команде
# обходом НЕ является: хук читает свой env от CLI, а не команды. Гард от случайности,
# не от adversarial — сознательный обход виден в транскрипте.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

# Не AO worker — не наше (основная сессия может запускать AO по задаче владельца).
[ -z "${AO_SUPERVISED_PROCESS:-}" ] && exit 0

INPUT="$(cat)"
CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
[ -z "$CMD" ] && exit 0
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"

CMD_NORM="$(printf '%s' "$CMD" | tr -s ' \t' ' ')"

deny() {
  jq -nc --arg reason "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
  exit 0
}

# 1. Однозначно AO: демон, десктоп-приложение, dev-скилл — откуда угодно.
if printf '%s' "$CMD_NORM" | grep -Eq 'ao daemon|Agent Orchestrator|ao-desktop-dev'; then
  deny "AO worker-сессии нельзя запускать AO-демон/.app: второй инстанс на общем AO_DATA_DIR \
ломает боевой демон (SQLITE_BUSY, инцидент 2026-09-27 «Spawning…»). \
Запуск/репро приложения — только основная сессия владельца."
fi

# 1a. Убийство живого демона/.app — то же самоубийство хоста, что и второй инстанс.
if printf '%s' "$CMD_NORM" | grep -Eq '(pkill|killall|kill)[^\n]*(ao daemon|agent-orchestrator|Agent Orchestrator|pty-host)'; then
  deny "AO worker-сессии нельзя убивать боевой демон/.app/pty-host: это гаснет хост владельца \
(сессии воркеров при этом переживают, но спавны и UI падают). Стоп демона — только владелец."
fi

# 2. Electron этого репо — только если рабочий каталог в agent-orchestrator
#    (чтобы не трогать чужие npm run dev в других проектах).
case "$CWD" in
  *agent-orchestrator*)
    if printf '%s' "$CMD_NORM" | grep -Eq 'electron-forge|node_modules/electron|npx electron|(^|/)electron |npm run dev( |$)'; then
      deny "AO worker-сессии нельзя поднимать Electron этого репо (dev-инстанс = второй демон \
на общем AO_DATA_DIR, инцидент 2026-09-27). Верификацию UI делает основная сессия владельца."
    fi
    ;;
esac

exit 0
