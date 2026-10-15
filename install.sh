#!/usr/bin/env bash
# install.sh — установка claude-tools на машину.
#
# Делает:
#   1. Проверяет jq (нужен hookctl и хуку).
#   2. chmod +x на hookctl и git-branch-guard.sh.
#   3. symlink hookctl в ~/bin (он уже в PATH у этого пользователя).
#   4. symlink скиллов /fix, /hooks, /issue-planner и /test-categories в ~/.claude/skills/.
#   5. Первый regenerate: включает git-branch-guard в ~/.claude/settings.json
#      (SessionStart и прочие чужие хуки сохраняются — см. модель hookctl).
#
# Безопасность: боевой settings.json правится только через hookctl (бэкап .bak),
# ничего не затирается вручную.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 1. jq ------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  echo "✗ jq не найден. Установите: brew install jq" >&2
  exit 1
fi
echo "✓ jq: $(jq --version)"

# --- 2. права на исполнение -------------------------------------------------
chmod +x "$SCRIPT_DIR/bin/hookctl"
chmod +x "$SCRIPT_DIR/bin/merge-guard"
chmod +x "$SCRIPT_DIR/hooks/git-branch-guard.sh"
echo "✓ chmod +x bin/hookctl bin/merge-guard hooks/git-branch-guard.sh"

# --- 3. symlink в ~/bin -----------------------------------------------------
INSTALL_DIR="$HOME/bin"
mkdir -p "$INSTALL_DIR"
LINK="$INSTALL_DIR/hookctl"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  rm -f "$LINK"
fi
ln -s "$SCRIPT_DIR/bin/hookctl" "$LINK"
echo "✓ symlink: $LINK -> $SCRIPT_DIR/bin/hookctl"

LINK="$INSTALL_DIR/merge-guard"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
  rm -f "$LINK"
fi
ln -s "$SCRIPT_DIR/bin/merge-guard" "$LINK"
echo "✓ symlink: $LINK -> $SCRIPT_DIR/bin/merge-guard"

case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "  ⚠ $INSTALL_DIR не в PATH. Добавьте в ~/.zshrc: export PATH=\"$INSTALL_DIR:\$PATH\"" ;;
esac

# --- 4. скиллы в ~/.claude/skills -------------------------------------------
# Симлинки (как и ~/bin/hookctl выше): репо живёт в фиксированном месте, поэтому
# живая связь с skills/ полезнее копии — правка скилла видна сразу, без переустановки.
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"
# Не удаляем пользовательский каталог с таким именем: установка должна быть
# обратимой и не терять чужой skill при последующей ошибке. Симлинк можно
# безопасно заменить на управляемый репозиторием.
TEST_CATEGORIES_TARGET="$SKILLS_DIR/test-categories"
if [ -e "$TEST_CATEGORIES_TARGET" ] && [ ! -L "$TEST_CATEGORIES_TARGET" ]; then
  echo "✗ $TEST_CATEGORIES_TARGET уже существует как каталог/файл; удалите или перенесите его вручную" >&2
  exit 1
fi
for skill in fix hooks issue-planner project-trust test-categories; do
  TARGET="$SKILLS_DIR/$skill"
  # Убираем что угодно на этом месте: устаревший symlink или старую копию-каталог.
  if [ -L "$TARGET" ] || [ -e "$TARGET" ]; then
    rm -rf "$TARGET"
  fi
  ln -s "$SCRIPT_DIR/skills/$skill" "$TARGET"
  echo "✓ skill symlink: $TARGET -> $SCRIPT_DIR/skills/$skill"
done

# --- 5. первый regenerate ---------------------------------------------------
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
if [ ! -f "$SETTINGS" ]; then
  echo "✗ settings.json не найден: $SETTINGS" >&2
  exit 1
fi

echo
echo "Включаю git-branch-guard в $SETTINGS ..."
"$SCRIPT_DIR/bin/hookctl" enable git-branch-guard

echo
echo "✓ Готово. Проверка:"
echo "  hookctl list"
echo "  hookctl status"
echo "  jq '.hooks.PreToolUse' \"$SETTINGS\""
echo
echo "Теперь при git push --delete / --force, gh pr close --delete-branch, git branch -D"
echo "Claude Code спросит подтверждение."
