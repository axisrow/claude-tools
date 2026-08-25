---
name: issue-planner
description: >
  Разбить большой GitHub-эпик на нативные sub-issues с калиброванными оценками
  (LOC + размер S/M/L/XL + минуты). Use when asked to decompose an epic, split
  an issue into sub-issues, create sub-tasks for an issue, estimate issue size,
  triage issues into an epic, or break down a large GitHub issue into trackable
  child issues. Драйвер subissue.sh обёртывает gh + GraphQL addSubIssue.
---

# Split epic into sub-issues + estimate

Разбивает один большой GitHub-эпик на **нативные sub-issues** (иерархия
parent/child через GraphQL `addSubIssue`, не просто чек-лист) и проставляет
каждой откалиброванную оценку. «Приложение», которое драйвит этот скил — это
GitHub Issues API через `gh`: REST для create/label/comment, GraphQL для
native-привязки.

Скил глобальный. Драйвер: `~/.claude/skills/issue-planner/subissue.sh`.
В примерах ниже `OWNER REPO` — это `axisrow tg_content_factory`; для другого
проекта подставить его owner/repo (или `gh repo view --json owner,name`).

## Prerequisites

```bash
gh --version          # 2.92.0 в этой сессии; нужен gh с поддержкой `gh api graphql`
gh auth status        # должен быть Logged in (иначе gh auth login)
```

Никаких apt-пакетов — `gh` уже стоит. `jq` НЕ нужен (используется `gh --jq`).

## Workflow (агентский путь)

### 1. Триаж: прочитать эпик и понять декомпозицию

```bash
gh issue view <EPIC> --json number,title,labels,body,comments
```

Если область незнакома — запустить параллельных **Explore**-агентов, чтобы
свериться с кодом (что уже сделано в main, какие файлы трогать, сколько слоёв
для parity). Это даёт основу под декомпозицию И под оценки.

### 2. Probe: поддерживает ли репозиторий native sub-issues

**Запускать ПЕРВЫМ.** Read-only.

```bash
bash ~/.claude/skills/issue-planner/subissue.sh probe axisrow tg_content_factory <EPIC>
# native_subissues=SUPPORTED
# epic_node_id=I_kwDO...        ← понадобится для create
# current_subissue_count=N
```

Если `addSubIssue` нет в схеме — скрипт упадёт с понятным сообщением; тогда
fallback: чек-лист `- [ ] ...` в теле эпика вместо отдельных issues.

### 3. Оценка: снять калибровку и посчитать размеры

Открыть [estimate.md](estimate.md). Снять веса PR с git (там команду),
перевести каждую подзадачу в **LOC → S/M/L/XL → минуты (код)**, затем оценить
**цикл review** (Шаг 3.1 в estimate.md: база по размеру + ×2 если задача touch
credentials/atomic/concurrency/marker-parsing/network). Оценки — из истории
репозитория, НЕ из головы. Review занимает 44–75% времени кода по факту — без
него оценка систематически занижена.

**Лимит PR ≤ 1000 строк (HARD, Шаг 2.1 в estimate.md):** если оценка подзадачи →
PR > 1000 строк — разбить на части ≤1000 каждая, излишек в follow-up issue,
уведомить пользователя в комментарии к эпику.

### 4. Подготовить лейблы (один раз)

```bash
gh label create epic            --color 5319E7 --description "Требует декомпозиции" 2>/dev/null || true
gh label create priority/high   --color D93F0B 2>/dev/null || true
gh label create priority/medium --color FBCA04 2>/dev/null || true
gh label create priority/low    --color 0E8A16 2>/dev/null || true
gh issue edit <EPIC> --add-label epic
```

### 5. Написать тела sub-issues

По одному `.md`-файлу на подзадачу. Каждое тело: **Что сделать** (шаги) ·
**Файлы** (конкретные пути!) · **Эталон** (ссылка на образец-PR, где уместно) ·
блок **Оценка** (из шага 3) · приоритет. Шаблон блока «Оценка» — в estimate.md.

### 6. Создать и привязать каждую sub-issue

Сухой прогон сначала (ничего не создаёт, валидирует лейбл+тело+parent):

```bash
EPIC_ID=$(bash ~/.claude/skills/issue-planner/subissue.sh probe axisrow tg_content_factory <EPIC> | sed -n 's/epic_node_id=//p')

bash ~/.claude/skills/issue-planner/subissue.sh \
  create axisrow tg_content_factory "$EPIC_ID" priority/high "Заголовок" body1.md --dry-run
```

Затем создать (убрать `--dry-run`):

```bash
bash ~/.claude/skills/issue-planner/subissue.sh \
  create axisrow tg_content_factory "$EPIC_ID" priority/high "Заголовок" body1.md
# #946  [priority/high]  Заголовок
```

### 7. Сводный комментарий в эпик

Таблица всех sub-issues (номер · подзадача · LOC · размер · минуты · приоритет)
+ суммарная оценка + рекомендованный порядок (фундамент → параллельные слои →
cleanup). Запостить: `gh issue comment <EPIC> --body-file summary.md`.

### 8. Verify

```bash
bash ~/.claude/skills/issue-planner/subissue.sh count axisrow tg_content_factory <EPIC>
# должно совпасть с числом созданных sub-issues
```

## Драйвер: subissue.sh

Команды (все, кроме `create` без `--dry-run`, read-only):

| Команда | Что делает |
|---------|------------|
| `probe OWNER REPO EPIC` | native-support? + epic node-id + текущий счётчик |
| `node OWNER REPO N` | node-id одной ишью |
| `create OWNER REPO PARENT_ID LABEL TITLE BODY_FILE [--dry-run]` | создать issue + привязать как sub-issue |
| `count OWNER REPO EPIC` | счётчик sub-issues (верификация) |

## Gotchas

- **Native sub-issue ≠ чек-лист.** Привязка делается мутацией `addSubIssue`
  (вход: `issueId` parent + `subIssueId` child, оба — GraphQL node-id вида
  `I_kwDO...`, НЕ номера). Скрипт сам резолвит номер→node-id.
- **`gh issue create` печатает URL**, номер достаётся как `basename "$URL"`.
- **`--add-label` для несуществующего лейбла молча не сработает** — создавать
  лейблы заранее (шаг 4). `--dry-run` в `create` это проверяет.
- **Калибровка дрейфует.** Веса PR в estimate.md — снимок на 2026-06; перед
  серьёзным триажем пересчитать командой из estimate.md.
- **gh glob в zsh:** `ls .claude/skills/*/SKILL.md` падает с `no matches found`
  если скилов нет и рвёт скрипт под `set -e` — проверять существование явно.
- **Оценка в минутах, не часах** — задачи исполняет агент; узкое место не
  печать, а итерации тестов/линта (см. estimate.md).
- **Review ≠ бесплатно.** Каждый PR гоняет `/cycle-review` (local `/review` +
  Codex adversarial, до clean). По факту 44–75% времени кода. Оценивай отдельной
  строкой (Шаг 3.1 в estimate.md): база по размеру ×2 при touch
  credentials/atomic/concurrency/marker-parsing/network. Сумма в эпике — по
  «итого», не по «код».
- **PR > 1000 строк запрещён (HARD).** Большой PR невозможно осмысленно
  отревьюить (reviewer пропускает баги) + ломает параллельную работу. Если оценка
  подзадачи ведёт к PR > 1000 — разбить на части ≤1000 (по слоям или
  вертикально: ядро → интеграция), излишек в follow-up issue, уведомить
  пользователя. Порог hard, не рекомендация (Шаг 2.1 в estimate.md).

## Troubleshooting

| Симптом | Фикс |
|---------|------|
| `addSubIssue mutation NOT in GraphQL schema` | Репо/аккаунт без native sub-issues → fallback на чек-лист в теле эпика |
| `label '...' does not exist` (в dry-run) | Создать лейбл (шаг 4) перед `create` |
| `HTTP 403` / `Resource not accessible` | `gh auth status`; нужны права на issues:write в репо |
| `count` меньше ожидаемого | Какой-то `create` упал на привязке — перепроверить вывод; node-id parent корректен? |
