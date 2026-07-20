#!/usr/bin/env bash
# test_permissions_audit.sh — red-green тесты для bin/permissions-audit.
#
# Стратегия изоляции (БЕЗ боя): CLAUDE_SETTINGS=<tmp>/settings.json на tmp-копии.
# НЕ правит боевой ~/.claude/settings.json.
#
# Запуск: bash tests/test_permissions_audit.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$PROJECT_DIR/bin/permissions-audit"

PASS=0
FAIL=0
FAILED_TESTS=()
WORK=""
SETTINGS_TEST=""

setup() {
  WORK="$(mktemp -d)"
  SETTINGS_TEST="$WORK/settings.json"
}

teardown() { [ -n "${WORK:-}" ] && rm -rf "$WORK"; }

# --- helpers ----------------------------------------------------------------
run_cli() { CLAUDE_SETTINGS="$SETTINGS_TEST" "$CLI" "$@"; }

# run audit, return stdout
audit_out() { run_cli audit 2>&1; }

assert_exit() {
  local expected="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expected" ]; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$desc: ожидался exit $expected, получили $got"); fi
}

# assert_output_contains <substring> <stdin-fn> <desc>  (stdin-fn prints to stdout)
contains() {
  local needle="$1" haystack="$2" desc="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then PASS=$((PASS+1))
  else FAIL=$((FAIL+1)); FAILED_TESTS+=("$desc: ожидали в выводе [$needle], нет"); fi
}
not_contains() {
  local needle="$1" haystack="$2" desc="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then FAIL=$((FAIL+1)); FAILED_TESTS+=("$desc: НЕ должно быть [$needle] в выводе, но есть"); else PASS=$((PASS+1)); fi
}

seed() { cat >"$SETTINGS_TEST"; }

# --- audit ------------------------------------------------------------------

# 1. Bash(git:*) → warn + scoped-suggest (git add/diff/status/...).
t1_wide_git_warn() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(git:*)","Bash(sleep:*)"]}}
JSON
  local out; out="$(audit_out)"
  contains "git:*" "$out" "t1: репортит git:* как широкий"
  contains "git add" "$out" "t1: scoped-suggest git add"
  assert_exit 1 "t1: exit 1 при warn" run_cli audit
  teardown
}

# 2. Bash(*) / Bash(*:*) → error (полный wildcard).
t2_full_wildcard_error() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(*:*)"]}}
JSON
  local out; out="$(audit_out)"
  contains "*:*" "$out" "t2: репортит *:*"
  assert_exit 1 "t2: exit 1 при error" run_cli audit
  teardown
}

# 3. Bash(ls:*) → info/safe, НЕ warn (ls не в опасном списке).
t3_safe_wildcard_no_warn() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(ls:*)"]}}
JSON
  local out; out="$(audit_out)"
  not_contains "ls" "$out" "t3: ls:* не флагается (safe)"
  teardown
}

# 4. Bash(git add:*) → ok (scoped, не флагается как широкий).
t4_scoped_ok() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(git add:*)","Bash(git diff:*)"]}}
JSON
  local out; out="$(audit_out)"
  not_contains "git add:*" "$out" "t4: scoped git add:* не флагается"
  teardown
}

# 5. deprecated (cd / compound &&) → warn.
t5_deprecated_warn() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(cd /x)","Bash(a && b)","Bash(GIT_SSL_NO_VERIFY=1 git push)"]}}
JSON
  local out; out="$(audit_out)"
  contains "cd" "$out" "t5a: deprecated cd репортится"
  contains "&&" "$out" "t5b: compound && репортится"
  assert_exit 1 "t5: exit 1 при deprecated" run_cli audit
  teardown
}

# 6. env секрет → warn, но ЗНАЧЕНИЕ НЕ печатается.
t6_env_secret_warn_no_value() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(sleep:*)"]},"env":{"ANTHROPIC_AUTH_TOKEN":"sk-very-long-secret-value-1234567890","IS_DEMO":"1"}}
JSON
  local out; out="$(audit_out)"
  contains "ANTHROPIC_AUTH_TOKEN" "$out" "t6a: секрет ANTHROPIC_AUTH_TOKEN репортится (имя)"
  not_contains "sk-very-long-secret-value" "$out" "t6b: ЗНАЧЕНИЕ секрета НЕ печатается"
  not_contains "IS_DEMO" "$out" "t6c: IS_DEMO=1 не секрет (placeholder/короткое)"
  teardown
}

# 7. чистый settings.json → exit 0, без warn.
t7_clean_exit0() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(sleep:*)","Bash(git add:*)"],"ask":["Bash(gh pr merge:*)"]}}
JSON
  assert_exit 0 "t7: чистый → exit 0" run_cli audit
  teardown
}

# --- cleanup ----------------------------------------------------------------

# 8. cleanup удаляет deprecated + compound, .bak, НЕ трогает валидные.
t8_cleanup_removes() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(sleep:*)","Bash(cd /x)","Bash(a && b)","Bash(ruff check *)"]}}
JSON
  run_cli cleanup >/dev/null 2>&1; local rc=$?
  if [ "$rc" = "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t8: cleanup exit 0, получили $rc"); fi
  contains "sleep:*" "$(jq -r '.permissions.allow[]' "$SETTINGS_TEST")" "t8: sleep:* сохранён"
  contains "ruff check *" "$(jq -r '.permissions.allow[]' "$SETTINGS_TEST")" "t8: ruff check * сохранён"
  not_contains "cd /x" "$(jq -r '.permissions.allow[]' "$SETTINGS_TEST")" "t8: cd /x удалён"
  not_contains "a && b" "$(jq -r '.permissions.allow[]' "$SETTINGS_TEST")" "t8: compound удалён"
  [ -f "$SETTINGS_TEST.bak" ] && PASS=$((PASS+1)) || { FAIL=$((FAIL+1)); FAILED_TESTS+=("t8: .bak не создан"); }
  teardown
}

# 9. cleanup дедуплит одинаковые паттерны.
t9_cleanup_dedup() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(sleep:*)","Bash(sleep:*)","Bash(git add:*)"]}}
JSON
  run_cli cleanup >/dev/null 2>&1
  local n; n=$(jq -r '.permissions.allow | length' "$SETTINGS_TEST")
  if [ "$n" = "2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t9: дедуп должен дать 2, получили $n"); fi
  teardown
}

# 10. cleanup idempotent — повторный no-op (или .bak не дублирует проблемы).
t10_cleanup_idempotent() {
  setup
  seed <<'JSON'
{"permissions":{"allow":["Bash(sleep:*)","Bash(cd /x)"]}}
JSON
  run_cli cleanup >/dev/null 2>&1
  local after1; after1=$(jq -r '.permissions.allow[]' "$SETTINGS_TEST" | sort)
  run_cli cleanup >/dev/null 2>&1
  local after2; after2=$(jq -r '.permissions.allow[]' "$SETTINGS_TEST" | sort)
  if [ "$after1" = "$after2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t10: повторный cleanup изменил файл (не idempotent)"); fi
  teardown
}

# --- раннер -----------------------------------------------------------------
for t in t1_wide_git_warn t2_full_wildcard_error t3_safe_wildcard_no_warn \
         t4_scoped_ok t5_deprecated_warn t6_env_secret_warn_no_value t7_clean_exit0 \
         t8_cleanup_removes t9_cleanup_dedup t10_cleanup_idempotent; do
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
