#!/usr/bin/env bash
# test_permission_mode.sh — red-green тесты для bin/permission-mode.
#
# Стратегия изоляции (БЕЗ боя): CLAUDE_SETTINGS=<tmp>/settings.json на tmp-копии.
# НЕ правит боевой ~/.claude/settings.json.
#
# Запуск: bash tests/test_permission_mode.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/permission-mode"

PASS=0
FAIL=0
FAILED_TESTS=()

WORK=""
SETTINGS_TEST=""

setup() {
  WORK="$(mktemp -d)"
  SETTINGS_TEST="$WORK/settings.json"
  # реалистичный settings.json с разными ключами (проверяем, что не трогаем чужое)
  cat >"$SETTINGS_TEST" <<'JSON'
{
  "env": { "FOO": "bar", "API_TOKEN": "secret" },
  "permissions": {
    "allow": ["Bash(sleep:*)"],
    "ask": ["Bash(gh pr merge:*)"],
    "defaultMode": "auto"
  },
  "hooks": { "SessionStart": [] },
  "model": "claude-opus-4-8"
}
JSON
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# --- helpers ----------------------------------------------------------------
run_cli() { CLAUDE_SETTINGS="$SETTINGS_TEST" "$CLI" "$@"; }
cur_val() { jq -r '.permissions.disableAutoMode // "absent"' "$SETTINGS_TEST"; }

assert_exit() {
  local expected="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expected" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$desc: ожидался exit $expected, получили $got"); fi
}

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$desc: ожидалось [$expected], получили [$actual]"); fi
}

# --- тесты ------------------------------------------------------------------

# 1. --check exit 0 + print "off" когда disableAutoMode отсутствует.
t1_check_off_when_absent() {
  setup
  local out; out="$(run_cli --check 2>/dev/null)"; local rc=$?
  assert_eq 0 "$rc" "t1: --check exit 0"
  # вывод содержит off (не on)
  if printf '%s' "$out" | grep -qi 'off'; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("t1: --check должен говорить off, получили [$out]"); fi
  teardown
}

# 2. --check print "on" когда disableAutoMode: "disable".
t2_check_on_when_set() {
  setup
  jq '.permissions.disableAutoMode = "disable"' "$SETTINGS_TEST" >"$SETTINGS_TEST.t" && mv "$SETTINGS_TEST.t" "$SETTINGS_TEST"
  local out; out="$(run_cli --check 2>/dev/null)"
  if printf '%s' "$out" | grep -qi 'on'; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("t2: --check должен говорить on, получили [$out]"); fi
  teardown
}

# 3. --on → записывает "disable", .bak создаётся, exit 0.
t3_on_sets_and_baks() {
  setup
  run_cli --on >/dev/null 2>&1; local rc=$?
  assert_eq 0 "$rc" "t3: --on exit 0"
  assert_eq "disable" "$(cur_val)" "t3: disableAutoMode = disable"
  [ -f "$SETTINGS_TEST.bak" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_TESTS+=("t3: .bak не создан"); }
  teardown
}

# 4. --on НЕ трогает другие ключи (env/allow/ask/defaultMode/hooks/model).
t4_on_preserves_others() {
  setup
  run_cli --on >/dev/null 2>&1
  assert_eq "bar"    "$(jq -r '.env.FOO' "$SETTINGS_TEST")"           "t4: env.FOO сохранён"
  assert_eq "secret" "$(jq -r '.env.API_TOKEN' "$SETTINGS_TEST")"     "t4: env.API_TOKEN сохранён"
  assert_eq "Bash(sleep:*)" "$(jq -r '.permissions.allow[0]' "$SETTINGS_TEST")" "t4: allow сохранён"
  assert_eq "auto"   "$(jq -r '.permissions.defaultMode' "$SETTINGS_TEST")"    "t4: defaultMode НЕ тронут"
  assert_eq "claude-opus-4-8" "$(jq -r '.model' "$SETTINGS_TEST")"    "t4: model сохранён"
  teardown
}

# 5. --on idempotent — повторный не меняет/не падает.
t5_on_idempotent() {
  setup
  run_cli --on >/dev/null 2>&1
  local bak1; bak1=$(stat -f "%m" "$SETTINGS_TEST.bak" 2>/dev/null)
  run_cli --on >/dev/null 2>&1; local rc=$?
  assert_eq 0 "$rc" "t5: повторный --on exit 0"
  assert_eq "disable" "$(cur_val)" "t5: значение стабильно"
  teardown
}

# 6. --off → удаляет ключ, .bak, exit 0.
t6_off_removes() {
  setup
  run_cli --on  >/dev/null 2>&1   # сначала включим
  run_cli --off >/dev/null 2>&1; local rc=$?
  assert_eq 0 "$rc" "t6: --off exit 0"
  assert_eq "absent" "$(cur_val)" "t6: ключ удалён"
  teardown
}

# 7. --off когда ключа нет → exit 0 (no-op), файл не меняется.
t7_off_noop_when_absent() {
  setup
  local before; before=$(cat "$SETTINGS_TEST")
  run_cli --off >/dev/null 2>&1; local rc=$?
  assert_eq 0 "$rc" "t7: --off без ключа exit 0"
  assert_eq "$before" "$(cat "$SETTINGS_TEST")" "t7: файл не изменился"
  teardown
}

# 8. невалидный JSON → отбой (exit ≠0), файл НЕ тронут.
t8_invalid_json_guard() {
  setup
  echo '{bad json' >"$SETTINGS_TEST"
  local before; before=$(cat "$SETTINGS_TEST")
  run_cli --on >/dev/null 2>&1; local rc=$?
  if [ "$rc" != "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t8: --on на невалидном JSON должен фейлить, exit=$rc"); fi
  assert_eq "$before" "$(cat "$SETTINGS_TEST")" "t8: невалидный файл не тронут"
  teardown
}

# 9. без jq → die с подсказкой (exit ≠0).
t9_no_jq() {
  setup
  PATH="/dev/null" run_cli --check >/dev/null 2>&1; local rc=$?
  if [ "$rc" != "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t9: без jq должен фейлить, exit=$rc"); fi
  teardown
}

# --- раннер -----------------------------------------------------------------
for t in t1_check_off_when_absent t2_check_on_when_set t3_on_sets_and_baks \
         t4_on_preserves_others t5_on_idempotent t6_off_removes \
         t7_off_noop_when_absent t8_invalid_json_guard t9_no_jq; do
  "$t"
done

echo
echo "==============================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================================="
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
