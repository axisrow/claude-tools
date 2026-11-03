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

Зависимости: **`jq`** (нужен и `hookctl`, и bash-хукам) и **`node`** (нужен node-хукам
`hooks/auto-continue.mjs` и `hooks/auto-continue-sf-child.mjs`). Без jq `install.sh` падает, а
`git-branch-guard.sh` тихо `exit 0` (лучше пропустить, чем крашнуть сессию). Без node
auto-continue-хуки не запускаются (install.sh предупреждает).

`install.sh` правит боевой `~/.claude/settings.json` только через `hookctl enable` (с
бэкапом `.bak`) — никогда не правь `settings.json` вручную.

## Команды разработки

Это bash + jq-проект (плюс node-хуки auto-continue: `hooks/auto-continue.mjs`,
`hooks/auto-continue-sf-child.mjs`, общий модуль `hooks/auto-continue-common.mjs`) без
сборки/линта в привычном смысле. Проверка после правок:

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

Тесты (новые утилиты/хуки):

```bash
bash tests/test_timeout_fix.sh                  # red-green тесты bin/timeout-fix (на моках)
bash tests/test_permission_mode.sh              # red-green тесты bin/permission-mode (на tmp-копии settings.json)
bash tests/test_permissions_audit.sh            # red-green тесты bin/permissions-audit (audit/cleanup, tmp-копия settings.json)
bash tests/test_one_command_at_a_time.sh        # red-green тесты хука compound-команд (через jq-pipe)
bash tests/test_auto_continue.sh                # red-green тесты Stop-хука auto-continue (HOME изолирован)
```

`test_timeout_fix.sh` / `test_permission_mode.sh` гоняют CLI на tmp-копии `settings.json`
(`CLAUDE_SETTINGS`) — боевой файл НЕ трогается. `test_timeout_fix.sh` additionally изолирует
`HOME` (fakehome) и мокает `brew`/`gtimeout` через PATH-подмену.
`test_one_command_at_a_time.sh` гоняет хук через `echo '{...}' | jq-pipe | hook` — **запускать через
`bash`** (хук использует bash 3.2 массивы/substr, через `zsh` спотыкается).

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

### `bin/` — CLI-утилиты этого репо

- **`hookctl`** — контроллер реестра хуков (см. выше).
- **`merge-guard`** — branch protection на GitHub, см. пункт в «Конвенции» ниже.
- **`timeout-fix`** — фикс бага `timeout`/`gtimeout` на macOS (claude-tools#2 →
  anthropics/claude-code #3361 / #10600 / #79056).
- **`permission-mode`** — отключение auto-классификатора Claude Code
  (`disableAutoMode: "disable"`), atomic-правка `settings.json`.
- **`permissions-audit`** — аудит + чистка `permissions.allow`: широкие паттерны
  (`Bash(git:*)`/`Bash(*)`), секреты в `env`, deprecated/compound мусор; конфиг —
  `permissions-audit.conf`.

Все читают/пишут `~/.claude/settings.json` только атомарно (tmp-файл + `mv`, с бэкапом
`.bak`), уважая `SETTINGS`/`CLAUDE_SETTINGS` для тестов.

### Скиллы (`skills/*/SKILL.md`)

Тонкие обёртки над CLI для вызова из сессии Claude Code. Специфичные для этого репо
(симлинкуются `install.sh`):

- **`/hooks`** — парсит `$ARGUMENTS` (`list|status|on <id>|off <id>|edit [id]|add`,
  понимает русские синонимы) и вызывает соответствующий `hookctl …`. Показывает вывод
  дословно.
- **`/fix`** — самостоятельный TDD-конвейер багфикса (красный тест → минимальный фикс →
  зелёный → mutation → линт → коммит с проверкой **committed ≠ staged** → PR с зелёным CI,
  **без мержа**). Нейтральный по языку, Python-дефолт (pytest/ruff/mutmut).
- **`/issue-planner`** — разбивает GitHub-эпик на нативные sub-issues с оценками (LOC +
  размер S/M/L/XL + минуты кода **и** ревью отдельно). Драйвер `subissue.sh` (обёртка над
  `gh` + GraphQL `addSubIssue`) вызывается по **абсолютному** пути
  `~/.claude/skills/issue-planner/subissue.sh` — работает благодаря симлинку из install.sh,
  не через `PROJECT_DIR`.

Каталог также содержит `skills/cleanup-procs/` и `skills/fewer-permission-prompts/` —
это **общие пользовательские скиллы** (управление системными процессами / произвольным
проектом), не специфичные для claude-tools и не связанные с его архитектурой.

## Конвенции

- Хуки намеренно **простые**: «всегда спрашивать», без сети и `gh`, без парсинга веток.
  Лучше один лишний диалог, чем закрытый PR. При расширении списка паттернов в
  `git-branch-guard.sh` сохраняй этот принцип и нормализуй команду (`tr -s ' \t'`)
  перед матчингом — паттерны обязаны срабатывать на `git  push   origin --force`.
- Хук сначала проверяет первое слово (`git|gh`), отсеивая алиасы/обёртки.
- Русские комментарии и пользовательский текст — норма проекта (включая `statusMessage`).
- При добавлении хука: скрипт в `hooks/` (chmod +x), запись в `registry.json`, затем
  `hookctl edit` (regenerate встроен) или `hookctl enable <id>`. Новый хук заводи с
  `"enabled": false` — пусть пользователь включит вручную после ручного тестирования
  (см. принцип ниже), не навязывай включение по умолчанию.
- **`one-command-at-a-time.sh` — минимальный V1 (эвристический).** Парсер bash-команд со стеком
  контекстов; непокрытые конструкции (heredoc/arithmetic/`[[ ]]`/case/ANSI-C) → `ambiguous` → `ask`.
  Не пытайся покрыть всё сразу — расширяй **только по реальным false-positives** из живой сессии
  (TDD: тест-first под замеченную боль). Если парсер обрастает исключениями — переходи на
  `bashlex`/`mvdan/sh`. Known limitations (`bash -c`, `eval`, `ssh`, одиночный `&`) — в README.
- **`bin/merge-guard` — branch protection на GitHub.** Массово включает
  `required_pull_request_reviews` на default-ветке всех личных репо через `gh api`. Не хук, а CLI:
  вызывается вручную (`merge-guard enable` / `disable` / `status`). PATCH при наличии защиты (сохраняет
  status checks и прочие rules), PUT при отсутствии. Forks/archived пропускаются. Idempotent.
  См. claude-tools#12.
- **Сначала ручное тестирование, потом автоматизация.** Любая новая CLI-утилита/фикс
  сначала прогоняется вручную на боевой системе и проверяется end-to-end, и только
  **после** подтверждения, что поведение верное, добавляется в `install.sh` / автоматические
  шаги. Не внедрять в установщик непроверенный код. Тесты (см. `tests/`) гоняются на
  моках без боя; они не заменяют ручного прогона перед интеграцией в `install.sh`.
