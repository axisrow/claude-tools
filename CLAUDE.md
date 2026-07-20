# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Что это

`claude-tools` — коллекция своих Claude Code хуков, скиллов и CLI-утилит. Главная боль,
которую решает репозиторий: агент, удаляя/переписывая git-ветки, случайно закрывает PR на GitHub
(PR живёт на ветке). Правила в CLAUDE.md не лечат — агент их игнорирует. Лечит **хук,
исполняемый харнессом**, а не агентом: он перехватывает опасную git-команду **до**
выполнения и спрашивает человека.

## Позиционирование

Этот репо — **коллекция локальных фиксов известных upstream-багов Claude Code, которые
Anthropic не чинит или закрывает по инерции ботов** (stale / not_planned / duplicate +
lock). Каждый фикс-утилита должен **ссылаться на upstream issues как доказательство, что
боль реальная**, а не выдуманная — цепочка «наш фикс → внутренний ишью → апстрим-ишью».
Пример: `bin/timeout-fix` (модель зовёт несуществующий `timeout`/`gtimeout` на macOS) →
claude-tools#2 → anthropics/claude-code #3361 / #10600 / #79056. При добавлении нового
фикса: убедись, что upstream-проблема задокументирована и связана, и не дублируй в репо
то, что Anthropic уже починил.

## Установка / развёртывание

```bash
bash install.sh            # проверит jq, chmod +x, symlink ~/bin/hookctl, включит git-branch-guard
```

Зависимость единственная: **`jq`** (нужен и `hookctl`, и хукам). Без него `install.sh`
падает, а `git-branch-guard.sh` тихо `exit 0` (лучше пропустить, чем крашнуть сессию).

`install.sh` правит боевой `~/.claude/settings.json` только через `hookctl enable` (с
бэкапом `.bak`) — никогда не правь `settings.json` вручную.

## Команды разработки

Это bash + jq-проект без сборки/тестов/линта в привычном смысле. Проверка после правок:

```bash
hookctl list                                              # реестр: id, event, enabled
hookctl status                                            # сверить реестр с settings.json
hookctl enable git-branch-guard                           # применить regenerate
jq '.hooks.PreToolUse' "$HOME/.claude/settings.json"      # увидеть запись с command из claude-tools/
jq empty "$HOME/.claude/settings.json"                    # валидность JSON

# Ручной тест хука (имитация того, что харнесс скармливает на stdin):
PROJECT_DIR="$HOME/Projects/claude-tools"   # каталог, куда клонирован репо
echo '{"tool_input":{"command":"git push origin --delete feat/x"}}' \
  | "$PROJECT_DIR/hooks/git-branch-guard.sh"
# Ожидается: JSON с permissionDecision:"ask" и причиной

# Прогнать хук против набора команд и проверить, какие срабатывают:
for c in "git push origin --delete x" "git push -f origin main" "git push origin new" "git status"; do
  printf '%s\n' "$c" | jq -ncR --arg cmd "$c" '{tool_input:{command:$cmd}}' \
    | "$PROJECT_DIR/hooks/git-branch-guard.sh" >/dev/null 2>&1 \
    && echo "ASK:   $c" || echo "pass:  $c"
done
```

`SETTINGS`/`CLAUDE_SETTINGS` (env) переопределяет путь к settings.json — полезно для
тестов hookctl на копии.

Тесты (новые утилиты):

```bash
bash tests/test_timeout_fix.sh            # red-green тесты bin/timeout-fix (на моках)
```

Тесты гоняют CLI на tmp-копии `settings.json` (`CLAUDE_SETTINGS`) и изолированном
`HOME` (fakehome), мокая `brew`/`gtimeout` через PATH-подмену. Реальный `brew install`
в тестах НЕ запускается — это работа ручного прогона (см. принцип выше).

## Архитектура (big picture)

Три роли, разделённые намеренно:

1. **`registry.json`** — источник правды для **своих** хуков (id, event, matcher, command,
   enabled, timeout, statusMessage). Единственное место, где описаны хуки этого проекта.
2. **`hooks/*.sh`** — исполняемые PreToolUse/PostToolUse-скрипты. Читают stdin-JSON
   (`.tool_input.command`), при матче печатают JSON с `permissionDecision` (`ask` —
   спросить, `deny` — жёсткий запрет) и `permissionDecisionReason`, иначе тихо `exit 0`.
3. **`bin/hookctl`** — контроллер: мержит реестр в `~/.claude/settings.json`.

### Гибридная модель hookctl (читать перед правкой jq-программы)

`hookctl` — **гибрид реестра и мержа**. На каждом `enable/disable/add/edit` он
**перестраивает** секцию `hooks` в `~/.claude/settings.json` (функция `regenerate()`):

- **(A)** удаляет из settings.json только записи, чей `command` содержит маркер
  `OUR_MARKER = "/claude-tools/"` — это граница «свой/чужой»;
- **(B)** достраивает включённые (`enabled:true`) хуки из реестра, **группируя по
  `event` → `matcher`** (матчеры объединяются в одну группу; отсутствие matcher = `"*"`),
  собирая `{type:"command", command, timeout?, statusMessage?}` с фильтрацией null-полей;
- **(C)** **сливает**: чужие группы события (например `SessionStart` context-heal) остаются
  нетронутыми, наши добавляются/замещаются через `reduce`;
- все прочие ключи settings.json (`env`, `permissions`, `model`, `enabledPlugins` …)
  сохраняются;
- перед записью — `jq empty` валидация + бэкап `settings.json.bak`, атомарная замена через `mv`.

Формат Claude Code hooks: `hooks: { "<Event>": [ {matcher?, hooks:[{type,command,...}]}, ... ] }`.

**PROJECT_DIR как маркер** — контракт всего механизма. `hookctl` вычисляет `PROJECT_DIR`
по своему расположению (`bin/hookctl` → родительский каталог) и распознаёт «свои» хуки по
`command`, начинающемуся с `PROJECT_DIR/`. Любой другой `command` считается чужим и не
трогается. В реестре `command` хранится **относительно** `PROJECT_DIR` (portable); в
`settings.json` hookctl вписывает абсолютный путь (`PROJECT_DIR + command`). Если меняешь
эту логику — `regenerate` перестанет узнавать свои же хуки и начнёт их дублировать.

`hookctl` запускается через symlink `~/bin/hookctl`, поэтому в начале скрипта стоит
**разрешение symlink через `readlink`** в цикле — без него `BASH_SOURCE` указал бы на
`~/bin`, и реестр искался бы в `~/registry.json`.

### Скиллы (`skills/*/SKILL.md`)

Тонкие обёртки над CLI для вызова из сессии Claude Code:

- **`/hooks`** — парсит `$ARGUMENTS` (`list|status|on <id>|off <id>|edit [id]|add`,
  понимает русские синонимы) и вызывает соответствующий `hookctl …`. Показывает вывод
  дословно.
- **`/fix`** — самостоятельный TDD-конвейер багфикса (красный тест → минимальный фикс →
  зелёный → mutation → линт → коммит с проверкой **committed ≠ staged** → PR с зелёным CI,
  **без мержа**). Нейтральный по языку, Python-дефолт (pytest/ruff/mutmut).

## Конвенции

- Хуки намеренно **простые**: «всегда спрашивать», без сети и `gh`, без парсинга веток.
  Лучше один лишний диалог, чем закрытый PR. При расширении списка паттернов в
  `git-branch-guard.sh` сохраняй этот принцип и нормализуй команду (`tr -s ' \t'`)
  перед матчингом — паттерны обязаны срабатывать на `git  push   origin --force`.
- Хук сначала проверяет первое слово (`git|gh`), отсеивая алиасы/обёртки.
- Русские комментарии и пользовательский текст — норма проекта (включая `statusMessage`).
- При добавлении хука: скрипт в `hooks/` (chmod +x), запись в `registry.json`, затем
  `hookctl edit` (regenerate встроен) или `hookctl enable <id>`.
- **Сначала ручное тестирование, потом автоматизация.** Любая новая CLI-утилита/фикс
  сначала прогоняется вручную на боевой системе и проверяется end-to-end, и только
  **после** подтверждения, что поведение верное, добавляется в `install.sh` / автоматические
  шаги. Не внедрять в установщик непроверенный код. Тесты (см. `tests/`) гоняются на
  моках без боя; они не заменяют ручного прогона перед интеграцией в `install.sh`.
