---
name: project-trust
description: Проставляет hasTrustDialogAccepted=true проекту в ~/.claude.json — снимает диалог доверия при старте Claude Code. Используй когда пользователь просит «прими trust для проекта», «добавь проект в доверенные», «убери диалог доверия», или явно зовёт /project-trust.
---

# project-trust: trust для проекта без диалога

1. Запиши скрипт ниже в `/tmp/project-trust.py` (Write, не инлайн).
2. `python3 /tmp/project-trust.py <абсолютный путь проекта>` — путь как видит его
   оболочка, без слэша на конце.
3. Скрипт печатает `путь: старое -> True`; идемпотентен, повторный прогон безвреден.

```python
import json, os, sys

proj = os.path.abspath(sys.argv[1])
path = os.path.expanduser('~/.claude.json')
with open(path) as f:
    data = json.load(f)
projects = data.setdefault('projects', {})
old = projects.get(proj, {}).get('hasTrustDialogAccepted')
projects.setdefault(proj, {})['hasTrustDialogAccepted'] = True
with open(path + '.tmp', 'w') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
os.replace(path + '.tmp', path)  # атомарная замена: без частичного файла
print(f'{proj}: {old} -> True')
```

Ограничения (не упрощать):

- Запущенная сессия Claude Code держит `~/.claude.json` в памяти и переписывает
  его при своих изменениях — правка из-под живой сессии может быть затёрта.
  Надёжно: править до запуска claude в этом проекте (или из сессии в другом
  каталоге) и проверить результат на следующем старте — диалога быть не должно.
- `~/.claude.json` = настройки и история всех проектов: ничего не удалять и не
  реформатировать сверх записи одного булевого поля, в git не коммитить.
- Если после записи диалог всё равно появляется — путь в `projects` не совпал
  (симлинк, другой регистр): посмотри фактический ключ соседнего доверенного
  проекта и повтори с ним.
