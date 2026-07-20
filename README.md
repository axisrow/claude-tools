# claude-tools

Свои Claude Code хуки и скиллы. Решает конкретную боль: агент, удаляя/переписывая ветки,
случайно закрывает PR на GitHub (PR живёт на ветке — ветка исчезла, PR закрылся). Правила в
CLAUDE.md не лечат — агент их игнорирует. Лечит **хук, исполняемый харнессом**, а не агентом:
он перехватывает опасную git-команду **до** выполнения и спрашивает человека.

## Что внутри

- **`hooks/git-branch-guard.sh`** — PreToolUse-хук: спрашивает подтверждение перед опасными
  git/gh-операциями.
- **`hooks/one-command-at-a-time.sh`** — PreToolUse-хук: спрашивает подтверждение перед compound-
  командами (`a && b`, `a; b`, `a || b`, `a | b`) — правило «одна bash-команда за раз». См. ниже.
- **`bin/hookctl`** — управление хуками в `~/.claude/settings.json` (реестр + мерж).
- **`bin/timeout-fix`** — локальный фикс бага `timeout`/`gtimeout` на macOS (ставит coreutils,
  добавляет gnubin в PATH, поднимает `BASH_MAX_TIMEOUT_MS`). См. ниже.
- **`registry.json`** — источник правды для своих хуков.
- **`skills/hooks/`** — slash-скилл `/hooks` (обёртка над hookctl).
- **`skills/fix/`** — slash-скилл `/fix` (багфикс по строгому TDD).
- **`tests/`** — bash-тесты (без фреймворка) для утилит `bin/`.

## Установка

```bash
cd /path/to/claude-tools   # куда клонирован репо
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

## hooks/one-command-at-a-time — «одна bash-команда за раз»

Правило: модель должна вызывать по одной команде за Bash-call, а не лепить compound
(`cmd1 && cmd2`, `a; b`, `a || b`, `a | b`). Смешивать — дурной тон. Хук перехватывает compound
ДО выполнения и спрашивает подтверждение (`permissionDecision: "ask"`).

Включение (по умолчанию выключен — сначала протестируй вручную):

```bash
hookctl enable one-command-at-a-time
```

**Что ловит → `ask`** (compound): `a && b`, `a; b`, `a || b`, `a | b`, многострочные команды
(newline как разделитель), compound внутри `$(…)`/backticks/subshell `(…)`.

**Что пропускает** (clean): одиночные команды; операторы внутри кавычек (`grep 'a && b'`,
`jq ".a | .b"`, `git commit -m "x && y"`); escaped-операторы (`echo \;`); `#`-внутри-слова
(`echo foo#bar`).

**Что помечает `ambiguous` → `ask`** (парсер V1 не умеет разбирать, просит проверить вручную):
heredoc (`<<EOF`), arithmetic (`$((…))`/`((…))`), `[[ … ]]`, `case … in`, ANSI-C `$'…'`, `${…}`.

**Known limitations V1** (не ловит — документировано): `bash -c 'a && b'` / `eval` / `ssh host '…'`
(compound скрыт в строковом аргументе); одиночный `&` (background).

**Алгоритм:** посимвольный обход со стеком контекстов (SQ/DQ/`$(`/backtick/subshell) на чистом
bash 3.2 — quote-aware (операторы внутри кавычек игнорируются, внутри `$()` ловятся). Это
**минимальный V1 — эвристический guardrail, не security boundary**: расширяем по реальным
false-positives. Первая цель расширения — heredoc (~1% команд). Если парсер начнёт обрастать
исключениями — переход на [`bashlex`](https://github.com/idank/bashlex) / [`mvdan/sh`](https://github.com/mvdan/sh).

Тесты: `bash tests/test_one_command_at_a_time.sh` (22 кейса: ask/clean/ambiguous).

## Конвенция permission-паттернов (Правило 2 из issue #4)

Не точечный хук, а **конвенция** для `permissions.allow` в `~/.claude/settings.json`:

| Хорошо | Плохо | Почему |
|---|---|---|
| `Bash(git add:*)`, `Bash(git diff:*)`, `Bash(git status)`, `Bash(git log:*)` | `Bash(git:*)` | Широкий паттерн разрешает **все** git-подкоманды — включая опасные `push --delete`/`branch -D`/`clean -fd`. Scoped-паттерны пропускают только безопасные. |

Claude Code проверяет каждую subcommand compound против rules
([docs/permissions](https://code.claude.com/docs/en/permissions#compound-commands)), но широкий
паттерн всё равно покрывает опасные подкоманды. Автоматический аудит широких паттернов —
follow-up (issue #6, `bin/permissions-audit`).

## bin/timeout-fix — фикс бага `timeout` на macOS

Claude Code на macOS упорно обёртывает команды в `timeout N`/`gtimeout N`, которых нет
(coreutils не установлен по умолчанию). Модель жжёт токены на `command not found: timeout`
и иногда галлюцинирует успех. Это upstream-баг ([anthropics/claude-code#3361](https://github.com/anthropics/claude-code/issues/3361),
[#10600](https://github.com/anthropics/claude-code/issues/10600), [#79056](https://github.com/anthropics/claude-code/issues/79056)),
закрытый ботами без фикса.

`bin/timeout-fix` применяет локальный обходный путь (без хука):

1. `brew install coreutils` — ставит `gtimeout` (+ `timeout` через gnubin).
2. Добавляет `$(brew --prefix coreutils)/libexec/gnubin` в `PATH` через `~/.zshrc`, чтобы
   безпрефиксный `timeout` разрешался (Claude Code запускает команды через login `zsh`,
   который грузит `~/.zshrc` — значит фикс доходит до subprocess'ов CC).
3. Ставит `env.BASH_MAX_TIMEOUT_MS=600000` в `~/.claude/settings.json`, чтобы харнесс не
   убивал команду раньше внешнего `timeout`.

```bash
bin/timeout-fix --check       # только диагностика (read-only): что ок, чего не хватает
bin/timeout-fix               # применить недостающее (idempotent, с бэкапами .bak)
bin/timeout-fix --value 900000   # переопределить дефолт 600000
```

**Сайд-эффект шага 2:** добавление `gnubin` в `PATH` меняет `ls`/`cp`/`mv`/`rm` и другие
утилиты на GNU-версии глобально для новых zsh-сессий (BSD → GNU семантика). Откат: удалить
из `~/.zshrc` строку с маркером `# claude-tools/timeout-fix` и перезапустить шелл.

## Тесты

```bash
bash tests/test_timeout_fix.sh    # red-green тесты bin/timeout-fix (на моках, без боя)
```

Тесты гоняют CLI на tmp-копии `settings.json` и изолированном `HOME`, мокая `brew`/`gtimeout`
через PATH-подмену. Реальный `brew install` в тестах **не запускается** — перед интеграцией
в `install.sh` утилита прогоняется вручную на боевой системе (принцип в `CLAUDE.md`).

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
   `command` хранится как путь **относительно каталога `claude-tools/`** (portable).
2. При `enable/disable/add/edit` hookctl **перестраивает** секцию `hooks` в `~/.claude/settings.json`:
   - удаляет только записи, чей `command` ведёт в каталог `claude-tools/` (распознаётся по `PROJECT_DIR`);
   - достраивает включённые хуки из реестра, группируя по event → matcher, склеивая
     `PROJECT_DIR + command` в абсолютный путь для `settings.json`;
   - **сливает** с чужими группами — `SessionStart` (context-mode-cache-heal) и любые другие
     остаются нетронутыми.
3. Все прочие ключи (`env`, `permissions`, `model`, `enabledPlugins` …) сохраняются.
4. Перед записью — валидация `jq empty` + бэкап `settings.json.bak`.

`PROJECT_DIR` вычисляется hookctl по своему расположению (`bin/hookctl` → родительский каталог),
поэтому пути portable и не зависят от `/Users/<user>`. Всё, что исполняется не из этого каталога,
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
├── bin/
│   ├── hookctl              # управление хуками
│   └── timeout-fix          # фикс бага timeout на macOS
├── hooks/
│   ├── git-branch-guard.sh
│   └── one-command-at-a-time.sh   # «одна команда за раз»
├── tests/
│   ├── test_timeout_fix.sh
│   └── test_one_command_at_a_time.sh
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
