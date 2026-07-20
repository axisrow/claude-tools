---
name: hooks
description: "Управляет Claude Code хуками (PreToolUse/PostToolUse) через hookctl — показать список, включить/выключить, статус, открыть реестр в редакторе. Используй когда пользователь говорит 'покажи хуки' / 'включи хук' / 'выключи git-branch-guard' / 'статус хуков' / 'добавь хук', или явно зовёт /hooks. Источник правды — registry.json в claude-tools; hookctl перестраивает секцию hooks в ~/.claude/settings.json, сохраняя чужие хуки (SessionStart и прочие)."
user-invocable: true
argument-hint: "<list | status | on <id> | off <id> | edit [id] | add>"
---

# /hooks — управление Claude Code хуками

Тонкая обёртка над `hookctl`. Инструмент живёт в проекте `claude-tools`:

- CLI: `~/bin/hookctl` ( symlink на `<claude-tools>/bin/hookctl`)
- Реестр: `<claude-tools>/registry.json` (каталог, куда клонирован репо claude-tools)
- Settings: `~/.claude/settings.json` (секция `hooks`)

## Поведение

`hookctl` — **источник правды для своих хуков**. `enable/disable/add/edit` перестраивают
секцию `hooks` в `~/.claude/settings.json`: удаляют только хуки с `command` из `claude-tools/`,
достраивают включённые из реестра, **сохраняя все чужие хуки** (SessionStart context-heal и любые
другие). Перед записью — валидация и бэкап `settings.json.bak`.

## Маппинг аргументов → hookctl

Парсь `$ARGUMENTS` свободной формой. Первый токен — подкоманда:

| Пользователь пишет | Выполни |
|---|---|
| `list` (пусто / `список` / `покажи`) | `hookctl list` |
| `status` (`статус`) | `hookctl status` |
| `on <id>` (`включи <id>`) | `hookctl enable <id>` |
| `off <id>` (`выключи <id>`) | `hookctl disable <id>` |
| `edit [id]` (`редактируй`) | `hookctl edit [id]` |
| `add` (`добавь`) | `hookctl add` |

`<id>` — идентификатор хука из реестра (например `git-branch-guard`). Узнать id: `hookctl list`.

## Как исполнять

1. Если `$ARGUMENTS` пуст → `hookctl list` (показать реестр).
2. Иначе распарсь подкоманду и id, вызови соответствующую `hookctl ...`.
3. Покажи пользователю вывод дословно.
4. Для `edit` — `hookctl edit` откроет реестр в `$EDITOR` и применит regenerate после закрытия.

## Существующие хуки

- `git-branch-guard` (PreToolUse / Bash) — спрашивает подтверждение перед опасными
  git-операциями: `git push --delete`, `push :branch`, `push --force/-f`,
  `gh pr close --delete-branch`, `git branch -D/-d`. Предотвращает случайное закрытие PR
  из-за удаления head-ветки.
- `one-command-at-a-time` (PreToolUse / Bash, по умолчанию **off**) — спрашивает подтверждение
  перед compound-командами (`a && b`, `a; b`, `a || b`, `a | b`, newline, compound в `$(…)`/
  backtick/subshell). Правило «одна bash-команда за раз». Quote-aware (операторы внутри кавычек
  игнорируются). Непокрытые конструкции (heredoc/arithmetic/`[[ ]]`/case) → `ambiguous` → `ask`.
  Known limitations: `bash -c '…'`/`eval`/`ssh`, одиночный `&`. Включать после ручного теста:
  `hookctl enable one-command-at-a-time`. См. README проекта.
