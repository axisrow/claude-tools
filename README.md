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
- **`hooks/auto-continue.mjs`** — Stop-хук (node): при обрыве стрима семейства
  «API Error: … The response above may be incomplete.» автоматически продолжает работу
  (block + «Continue task»), кап — 3 раунда за 10-минутный бюджет на сессию. См. ниже.
- **`bin/hookctl`** — управление хуками в `~/.claude/settings.json` (реестр + мерж).
- **`bin/timeout-fix`** — локальный фикс бага `timeout`/`gtimeout` на macOS (ставит coreutils,
  добавляет gnubin в PATH, поднимает `BASH_MAX_TIMEOUT_MS`). См. ниже.
- **`bin/permission-mode`** — отключение auto-классификатора (`disableAutoMode: "disable"`).
  Безопасная atomic-правка `settings.json`. См. ниже.
- **`bin/permissions-audit`** — аудит + чистка `permissions.allow`: детектит слишком широкие
  паттерны (`Bash(git:*)`/`Bash(*)`) и секреты в `env`, чистит deprecated/compound мусор. См. ниже.
- **`bin/merge-guard`** — массовое включение/отключение branch protection (require reviews) на
  всех личных GitHub-репо. Запрет мерджа без ревью на стороне GitHub. См. ниже.
- **`registry.json`** — источник правды для своих хуков.
- **`skills/hooks/`** — slash-скилл `/hooks` (обёртка над hookctl).
- **`skills/fix/`** — slash-скилл `/fix` (багфикс по строгому TDD).
- **`skills/issue-planner/`** — slash-скилл `/issue-planner` (разбивка эпика на sub-issues
  с оценками кода и ревью, драйвер `subissue.sh` поверх `gh` GraphQL).
- **`skills/test-categories/`** — переносимый скилл `/test-categories` для безопасной категоризации тестов и live-действий.
- **`tests/`** — bash-тесты (без фреймворка) для утилит `bin/`.

## Установка

Как плагин (все скиллы разом, доступны как `/tools:<имя>`):

```
/plugin install tools --marketplace axisrow/claude-tools
```

Классически, через symlink (хуки + CLI-утилиты + скиллы):

```bash
cd /path/to/claude-tools   # куда клонирован репо
bash install.sh
```

`install.sh` проверит `jq`, сделает `chmod +x`, symlink `~/bin/hookctl` и `~/bin/merge-guard`, симлинкнет
скиллы `/fix`, `/hooks`, `/issue-planner` и `/test-categories` в `~/.claude/skills/`, включит
`git-branch-guard`. Боевой
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

## hooks/auto-continue — авто-продолжение после обрыва стрима

Когда CC останавливается с «API Error: … The response above may be incomplete.»
(stopped arriving / Connection lost / computer went to sleep — до 58% всех API-ошибок
корпуса), сессия встаёт до ручного «continue». Хук на Stop читает хвост транскрипта:
если новейшая main-chain assistant-строка — синтетический API error семейства
(`model === '<synthetic>'` + суффикс), блокирует остановку с reason **«Continue task»** —
CC подставляет его как инструкцию и продолжает.

Upstream-боль не починена: [anthropics/claude-code#105804](https://github.com/anthropics/claude-code/issues/105804),
[#104603](https://github.com/anthropics/claude-code/issues/104603), [#103058](https://github.com/anthropics/claude-code/issues/103058).
См. [axisrow/claude-tools#24](https://github.com/axisrow/claude-tools/issues/24).

**Кап**: 3 блока за 10-минутный бюджет на сессию (state `~/.claude/claude-autocontinue-state/<session>.json`;
бюджет протухает — счётчик свежий). Нельзя считать раунды по строкам транскрипта: обрыв
середине ответа оставляет реальную частичную assistant-строку над cut-строкой (корпус:
12 из 17 пар соседних cut'ов) — сбрасывает любую строковую серию. Стейт — единственный
владелец счётчика: блок, который не удалось записать, не доставляется.

**Stop-ветка пока не срабатывает на обрывах**: с ~CC 2.1.235 Stop на API-error-терминациях
не файрится вовсе (регрессия [anthropics/claude-code#87972](https://github.com/anthropics/claude-code/issues/87972),
подтверждена эмпирически 2026-11-03: на живых нормальных остановках хук вызывается, на
обрывах — нет). Заработает сам, когда Anthropic починит.

**StopFailure-ветка (auto-continue-sf)** — работает сегодня: на API-error CC файрит
`StopFailure`, но его вывод игнорируется, а процесс убивают за ~10–50 мс
([#101420](https://github.com/anthropics/claude-code/issues/101420)). Поэтому хук —
bash-launcher, который за эти миллисекунды спавнит detached-ребёнка (perl-setsid уводит
из process group). Ребёнок через 12 с верифицирует: сессия всё ещё стоит на cut-семействе,
нового ввода не было, бюджет не исчерпан → шлёт воркеру `ao send --message "Continue task" --steer`
(AO-сессия = `basename(cwd)`; `--client-message-id autocont-<cutUuid>` дедуплицирует
повторы). **Бюджет общий со Stop-веткой** (3 раунда / 10 мин, state-файл) — цикл
steer'ов на flappy-провайдере ограничен в обеих ветках. Steer уходит только idle
AO-воркеру из `~/.ao/data/worktrees/` (занятый воркер = чужая сессия, не наша
застрявшая). Не-AO директории, чужие ошибки (429/ECONNRESET) и не-семейные тексты —
skip. Dry-run: `AUTOCONTINUE_DRY_RUN=1`.

**Отпускает** (silent allow): обычная остановка; Esc-интерп `[Request interrupted …]` в хвосте;
per-session kill switch — `mkdir -p ~/.claude/claude-autocontinue-off && : > ~/.claude/claude-autocontinue-off/<session-id>`;
другие API-ошибки (429/ECONNRESET — ретрай не всегда лечит); любые свои ошибки (fail-open).

Лог: `~/.claude/claude-autocontinue.log` — Stop-ветка: `kind=block|cap|nostate`;
sf-ветка: `kind=ao-send|sf-cap|sf-off|sf-hasinput|sf-notfamily|sf-noassistant|sf-nonao|sf-busy|sf-noao|sf-dry|nostate|sf-error`.
Включение:

```bash
hookctl enable auto-continue
hookctl enable auto-continue-sf
```

Требует **node** (оба node-файла: `auto-continue.mjs` и `auto-continue-sf-child.mjs`).
Тесты: `bash tests/test_auto_continue.sh` (30 проверок: block/cap/TTL/interrupt/off-marker/
string-content/quote-in-tool_result/однострочный транскрипт + sf dry-cap-off-hasinput,
HOME изолирован).

## Конвенция permission-паттернов (Правило 2 из issue #4)

Не точечный хук, а **конвенция** для `permissions.allow` в `~/.claude/settings.json`:

| Хорошо | Плохо | Почему |
|---|---|---|
| `Bash(git add:*)`, `Bash(git diff:*)`, `Bash(git status)`, `Bash(git log:*)` | `Bash(git:*)` | Широкий паттерн разрешает **все** git-подкоманды — включая опасные `push --delete`/`branch -D`/`clean -fd`. Scoped-паттерны пропускают только безопасные. |

Claude Code проверяет каждую subcommand compound против rules
([docs/permissions](https://code.claude.com/docs/en/permissions#compound-commands)), но широкий
паттерн всё равно покрывает опасные подкоманды. Автоматический аудит широких паттернов —
follow-up (issue #6, `bin/permissions-audit`).

## bin/permission-mode — отключение auto-классификатора

Auto-режим Claude Code (`permissions.defaultMode: "auto"`) гоняет **каждый** tool-call через
LLM-классификатор на основном бэкенде сессии — жжёт токены, добавляет задержку, а при
недоступности классификатора блокирует действие (`glm-5-turbo[1m] is temporarily unavailable, so
auto mode cannot determine the safety`). В `/settings` GUI одной кнопки это не выключить.
См. [axisrow/claude-tools#5](https://github.com/axisrow/claude-tools/issues/5),
upstream [anthropics/claude-code#69002](https://github.com/anthropics/claude-code/issues/69002).

`bin/permission-mode` — безопасная обёртка: выставляет `permissions.disableAutoMode: "disable"`
в `~/.claude/settings.json` (atomic-правка + `.bak` + валидация, как `bin/timeout-fix`).

```bash
bin/permission-mode --check     # показать состояние (on/off), read-only
bin/permission-mode --on        # запретить auto-режим (disableAutoMode: "disable")
bin/permission-mode --off       # разрешить обратно (убрать disableAutoMode)
```

Запрещает auto-режим — CC откатится к стандартным запросам подтверждения (permission rules
продолжают работать). **НЕ трогает** `defaultMode`/`allow`/`ask`. После `--on`/`--off` —
перезапусти Claude Code. Тесты: `bash tests/test_permission_mode.sh`.

## bin/permissions-audit — аудит и чистка permissions

Широкие wildcard-паттерны (`Bash(git:*)`/`Bash(node:*)`/`Bash(*)`) разрешают **все** подкоманды —
включая опасные `git push --delete` (закрывает PR), `git clean -fd`, arbitrary node. Scoped-паттерны
(`Bash(git add:*)`) безопаснее. `Bash(*:*)` — вообще полный wildcard. Параллельно `permissions.allow`
обрастает мусором (compound `&&`, deprecated `cd`/`claude`, дубли). См. [axisrow/claude-tools#6](https://github.com/axisrow/claude-tools/issues/6).

```bash
bin/permissions-audit audit      # аудит (read-only, default): широкие паттерны + deprecated + секреты
bin/permissions-audit cleanup    # удалить deprecated/compound + дедуп (atomic, .bak)
```

**audit** репортит: `Bash(<cmd>:*)` для опасных команд (git/gh/node/npm/...) → warn + scoped-альтернатива;
`Bash(*)`/`Bash(*:*)` → error; compound/deprecated → warn; секрет в `env` (`*TOKEN*`/`*KEY*`/...) → warn
(**значение НЕ печатается**). Exit 0 если чисто, 1 если есть проблемы.

**cleanup** удаляет deprecated/compound и дедуплит (atomic + `.bak`, fail-closed как `permission-mode`).
**НЕ делает merge** (сворачивание дубли в wildcard) — это отдельный плагин `permissions-optimizer`.

Конфиг: `permissions-audit.conf` рядом (опасные команды + scoped-альтернативы + deprecated-regex);
переопределить через `PERMISSIONS_AUDIT_CONF`. Правила заимствованы из `permissions-optimizer`.
Тесты: `bash tests/test_permissions_audit.sh` (22 кейса: audit/cleanup, изоляция через `CLAUDE_SETTINGS`).


## bin/merge-guard — защита от мержа PR без ревью

Claude Code агент может смержить PR через `gh pr merge` без человеческого ревью, если
репозиторий не имеет branch protection. `git-branch-guard.sh` перехватывает опасные
git-операции локально, но `gh pr merge` не попадает под его паттерны. Единственный надёжный
способ запретить мердж без ревью — **branch protection на стороне GitHub**. См.
[axisrow/claude-tools#12](https://github.com/axisrow/claude-tools/issues/12).

```bash
merge-guard enable  [REPO]   # включить required_pull_request_reviews
merge-guard disable [REPO]   # отключить reviews (не трогает остальные rules)
merge-guard status  [REPO]   # показать статус (read-only)
```

Действует на default-ветку (обычно main/master). Без аргумента REPO — все личные репо
(owner, без forks/archived). Idempotent: повторный `enable`/`disable` безопасен. Существующие
branch protection rules (required_status_checks, restrictions) **сохраняются** — используется
PATCH при наличии защиты, не PUT.

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
│   ├── merge-guard          # защита от мержа PR без ревью (branch protection)
│   ├── permission-mode      # отключение auto-классификатора
│   ├── permissions-audit    # аудит + чистка permissions.allow
│   └── timeout-fix          # фикс бага timeout на macOS
├── permissions-audit.conf   # конфиг: опасные команды + scoped + deprecated-regex
├── hooks/
│   ├── git-branch-guard.sh
│   ├── one-command-at-a-time.sh   # «одна команда за раз»
│   ├── auto-continue.mjs          # авто-продолжение после обрыва стрима (node, Stop)
│   ├── auto-continue-common.mjs   # общий carrier/reader для обеих веток
│   ├── auto-continue-sf.sh        # StopFailure launcher -> detached ребёнок
│   └── auto-continue-sf-child.mjs # верификация хвоста + ao send --steer (node)
├── tests/
│   ├── test_timeout_fix.sh
│   ├── test_permission_mode.sh
│   ├── test_permissions_audit.sh
│   ├── test_one_command_at_a_time.sh
│   └── test_auto_continue.sh
└── skills/
    ├── hooks/SKILL.md             # /hooks
    ├── fix/SKILL.md               # /fix
    ├── issue-planner/             # /issue-planner
    │   ├── SKILL.md
    │   ├── estimate.md
    │   └── subissue.sh
    └── test-categories/SKILL.md   # /test-categories
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
