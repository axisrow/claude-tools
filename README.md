# claude-tools

Свои Claude Code хуки и скиллы. Решает конкретную боль: агент, удаляя/переписывая ветки,
случайно закрывает PR на GitHub (PR живёт на ветке — ветка исчезла, PR закрылся). Правила в
CLAUDE.md не лечат — агент их игнорирует. Лечит **хук, исполняемый харнессом**, а не агентом:
он перехватывает опасную git-команду **до** выполнения и спрашивает человека.

## Что внутри

- **`hooks/git-branch-guard.sh`** — PreToolUse-хук: спрашивает подтверждение перед опасными
  git/gh-операциями.
- **`bin/hookctl`** — управление хуками в `~/.claude/settings.json` (реестр + мерж).
- **`registry.json`** — источник правды для своих хуков.
- **`skills/hooks/`** — slash-скилл `/hooks` (обёртка над hookctl).
- **`skills/fix/`** — slash-скилл `/fix` (багфикс по строгому TDD).

## Установка

```bash
cd /Users/axisrow/Projects/claude-tools
bash install.sh
```

`install.sh` проверит `jq`, сделает `chmod +x`, symlink `~/bin/hookctl`, симлинкнет
скиллы `/fix` и `/hooks` в `~/.claude/skills/`, включит `git-branch-guard`. Боевой
`~/.claude/settings.json` правится только через `hookctl` (с бэкапом `.bak`); чужие хуки
(`SessionStart` context-heal и др.) сохраняются.

## Какие операции перехватывает git-branch-guard

При любой из них Claude Code **остановится и спросит** (`permissionDecision: "ask"`):

| Операция | Почему опасно |
|---|---|
| `git push --delete <remote> <branch>` | Удаляет remote-ветку → **GitHub закрывает открытый PR** на ней |
| `git push <remote> :<branch>` | То же, другой синтаксис удаления remote-ветки |
| `git push --force` / `-f` | Переписывает head ветки → ломает PR, сбрасывает ревью |
| `gh pr close --delete-branch` | Закрывает PR **и** удаляет ветку одним выстрелом |
| `git branch -D` / `-d` | Удаляет локальную ветку; если в ней незапушенные коммиты — работа теряется |

Логика намеренно простая: **всегда спрашивать**, без сети и `gh`. Лучше один лишний
диалог, чем закрытый PR. Безопасные операции (`git push <new>`, `pull`, `status`, `gh pr view`)
проходят без вопросов.

## Управление хуками

```bash
hookctl list                 # реестр: id, event, enabled
hookctl status               # сверить реестр с ~/.claude/settings.json
hookctl enable  <id>         # включить хук
hookctl disable <id>         # выключить хук
hookctl edit    [id]         # открыть registry.json в $EDITOR + regenerate
hookctl add                  # подсказка по добавлению нового хука
```

Или из сессии Claude Code:

```
/hooks list
/hooks on git-branch-guard
/hooks off git-branch-guard
/hooks status
```

## Как hookctl не ломает чужое (гибридная модель)

`hookctl` — **гибрид реестра и мержа**:

1. `registry.json` — источник правды для **своих** хуков (id, event, matcher, command, enabled).
2. При `enable/disable/add/edit` hookctl **перестраивает** секцию `hooks` в `~/.claude/settings.json`:
   - удаляет только записи, чей `command` ведёт в `claude-tools/` (маркер «наш»);
   - достраивает включённые хуки из реестра, группируя по event → matcher;
   - **сливает** с чужими группами — `SessionStart` (context-mode-cache-heal) и любые другие
     остаются нетронутыми.
3. Все прочие ключи (`env`, `permissions`, `model`, `enabledPlugins` …) сохраняются.
4. Перед записью — валидация `jq empty` + бэкап `settings.json.bak`.

Маркер «свой/чужой» — подстрока `/claude-tools/` в `command`. Всё, что исполняется не отсюда,
считается чужим и не трогается.

## Добавить новый хук

1. Положи скрипт в `hooks/` (chmod +x). PreToolUse-хук читает stdin JSON, достаёт
   `.tool_input.command`, и при матче печатает:
   ```json
   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask",
    "permissionDecisionReason":"причина для человека"}}
   ```
   (`deny` — жёсткий запрет без возможности подтвердить; `ask` — спросить.)
2. Добавь запись в `registry.json` (id, event, matcher, command, enabled).
3. `hookctl edit` (применит regenerate) или `hookctl enable <id>`.

## /fix — багфикс по TDD

`/fix <issue или описание бага>` — конвейер: красный тест → минимальный фикс → зелёный →
mutation → ruff → **коммит с проверкой committed≠staged** → PR с зелёным CI. Не мержит.
Нейтральный по языку, с Python-дефолтом (pytest/ruff/mutmut). См. `skills/fix/SKILL.md`.

## Структура

```
claude-tools/
├── README.md
├── install.sh
├── registry.json
├── bin/hookctl
├── hooks/git-branch-guard.sh
└── skills/
    ├── hooks/SKILL.md      # /hooks
    └── fix/SKILL.md        # /fix
```

## Проверка после установки

```bash
hookctl list                 # [on] git-branch-guard (PreToolUse / Bash)
hookctl status               # свои хуки: найдено 1
jq '.hooks.PreToolUse'  ~/.claude/settings.json   # запись с command из claude-tools/
jq '.hooks.SessionStart' ~/.claude/settings.json  # context-heal на месте
```

В сессии Claude Code попробуй `git push origin --delete <ветка>` — должен всплыть диалог
с причиной. `/hooks off git-branch-guard` — и команда проходит без вопроса.
