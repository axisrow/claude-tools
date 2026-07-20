#!/usr/bin/env bash
# test_timeout_fix.sh — red-green тесты для bin/timeout-fix.
#
# Стратегия изоляции (БЕЗ боя):
#   - CLAUDE_SETTINGS=<tmp>/settings.json — копия, правка env без боя.
#   - HOME=<tmp>/fakehome — изолирует ~/.zshrc от боевого.
#   - brew/gtimeout мокаются через PATH-подмену (fakebin/brew, fakebin/gtimeout).
#     Поэтому bin/timeout-fix обязан звать brew/gtimeout/jq ПО ИМЕНИ (через PATH),
#     а не абсолютным путём.
#
# Запуск: bash tests/test_timeout_fix.sh
# Exit: 0 — все зелёные; 1 — есть падения.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FIX="$PROJECT_DIR/bin/timeout-fix"

# --- счётчики ---------------------------------------------------------------
PASS=0
FAIL=0
FAILED_TESTS=()

# --- asserts ----------------------------------------------------------------
assert_exit() {
  # assert_exit <expected_code> <description> -- <cmd...>
  local expected="$1" desc="$2"; shift 3
  "$@" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$expected" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$desc: ожидался exit $expected, получили $got")
  fi
}

assert_match() {
  # assert_match <pattern> <file> <description>
  local pattern="$1" file="$2" desc="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    local msg="$desc: pattern [$pattern] not in $file"
    FAILED_TESTS+=("$msg")
  fi
}

assert_nomatch() {
  # assert_nomatch <pattern> <file> <description>
  local pattern="$1" file="$2" desc="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    FAIL=$((FAIL+1))
    local msg="$desc: pattern [$pattern] SHOULD NOT be in $file but is"
    FAILED_TESTS+=("$msg")
  else
    PASS=$((PASS+1))
  fi
}

assert_eq() {
  # assert_eq <expected> <actual> <description>
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    local msg="$desc: expected=[$expected] actual=[$actual]"
    FAILED_TESTS+=("$msg")
  fi
}

# --- фикстуры ---------------------------------------------------------------
WORK=""
setup() {
  WORK="$(mktemp -d)"
  HOME="$WORK/home"; mkdir -p "$HOME"
  ZSHRC_TEST="$HOME/.zshrc"; : >"$ZSHRC_TEST"
  SETTINGS_TEST="$WORK/settings.json"
  echo '{}' >"$SETTINGS_TEST"
  FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# env-значение по умолчанию (должно совпадать с DESIRED_TIMEOUT_MS в timeout-fix)
DESIRED=600000

# Моки brew/gtimeout. make_brew <installed:1|0> — кладёт fakebin/brew,
# эмулируя `brew list coreutils` (exit 0 если установлен, 1 если нет) и
# `brew --prefix coreutils`. API: 1=установлен → brew list вернёт exit 0.
make_brew() {
  local installed="$1"
  local list_exit=1
  [ "$installed" = "1" ] && list_exit=0
  cat >"$FAKEBIN/brew" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "list coreutils") exit ${list_exit} ;;
  "--prefix coreutils") echo "$WORK/coreutils-prefix" ;;
  *) echo "brew-mock: unexpected \$*" >&2; exit 2 ;;
esac
EOF
  chmod +x "$FAKEBIN/brew"
  # gnubin-директория с timeout/gtimeout — имитация после brew install
  mkdir -p "$WORK/coreutils-prefix/libexec/gnubin"
}

# Мок gtimeout (имитация, что coreutils установлен).
make_gtimeout() {
  cat >"$FAKEBIN/gtimeout" <<'EOF'
#!/usr/bin/env bash
echo "gtimeout-mock: $*"
EOF
  chmod +x "$FAKEBIN/gtimeout"
}

# PATH с fakebin впереди (brew/gtimeout моки видны), jq берётся из системы.
path_with_fakes() { echo "$FAKEBIN:$PATH"; }
# PATH без fakebin — симуляция «brew отсутствует».
path_without_brew() {
  local p=":$PATH:"
  p="${p//:$FAKEBIN:/:}"
  p="${p#:}"; p="${p%:}"
  echo "$p"
}

# Хелпер: settings.json с заданным env.BASH_MAX_TIMEOUT_MS (или без него).
seed_env_timeout() {
  local v="${1:-}"
  if [ -n "$v" ]; then
    jq --arg v "$v" '.env = {BASH_MAX_TIMEOUT_MS: $v}' "$SETTINGS_TEST" >"$SETTINGS_TEST.tmp" \
      && mv "$SETTINGS_TEST.tmp" "$SETTINGS_TEST"
  fi
}

# Хелпер: уже настроенный gnubin в zshrc (как будто timeout-fix уже отработал).
seed_gnubin_in_zshrc() {
  echo "export PATH=\"$WORK/coreutils-prefix/libexec/gnubin:\$PATH\"  # claude-tools/timeout-fix" >>"$ZSHRC_TEST"
}

# Обёртка запуска timeout-fix с тестовым окружением.
run_fix() {
  CLAUDE_SETTINGS="$SETTINGS_TEST" ZSHRC="$ZSHRC_TEST" "$FIX" "$@"
}

# --- тесты (12 red-first кейсов) -------------------------------------------

# 1. check exit 0, когда всё уже настроено.
t1_all_ok_check() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout "$DESIRED"
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" assert_exit 0 "t1: check когда всё ок" -- run_fix --check
  teardown
}

# 2. check exit 1, когда coreutils не установлен.
t2_no_coreutils_check() {
  setup
  make_brew 0                      # brew есть, coreutils нет
  seed_env_timeout "$DESIRED"
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" assert_exit 1 "t2: check coreutils не установлен" -- run_fix --check
  teardown
}

# 3. check exit 1, когда env.BASH_MAX_TIMEOUT_MS отсутствует.
t3_no_env_check() {
  setup
  make_brew 1; make_gtimeout
  # env НЕ seeded
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" assert_exit 1 "t3: check env отсутствует" -- run_fix --check
  teardown
}

# 4. check exit 1, когда env < 600000.
t4_low_env_check() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout 120000          # меньше дефолта
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" assert_exit 1 "t4: check env < 600000" -- run_fix --check
  teardown
}

# 5. check exit 1, когда gnubin НЕ в zshrc.
t5_no_gnubin_check() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout "$DESIRED"
  # zshrc пустой — gnubin не прописан
  PATH="$(path_with_fakes)" assert_exit 1 "t5: check gnubin не в zshrc" -- run_fix --check
  teardown
}

# 6. run с уже установленным coreutils — НЕ зовёт brew install повторно (idempotent).
t6_run_no_brew_reinstall() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout "$DESIRED"
  seed_gnubin_in_zshrc
  # Если бы run звал `brew install coreutils`, мок-brew упал бы на неизвестной подкоманде
  # (в make_brew есть только list/prefix). Зелёный exit = brew install не вызывался.
  PATH="$(path_with_fakes)" assert_exit 0 "t6: run не переустанавливает coreutils" -- run_fix
  teardown
}

# 7. run с отсутствующим env → записывает 600000, создаёт .bak, exit 0.
t7_run_sets_env() {
  setup
  make_brew 1; make_gtimeout
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" run_fix >/dev/null 2>&1
  assert_eq 0 "$?" "t7: run exit"
  assert_match "$DESIRED" "$SETTINGS_TEST" "t7: env записан"
  # .bak — снапшот ДО правки (исходный '{}'), в нём НЕТ нового ключа, но файл существует.
  if [ -f "$SETTINGS_TEST.bak" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t7: .bak не создан"); fi
  teardown
}

# 8. run повторно (всё ок) → ничего не меняет, exit 0 (idempotent на settings + zshrc).
t8_run_idempotent() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout "$DESIRED"
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" run_fix >/dev/null 2>&1
  PATH="$(path_with_fakes)" run_fix >/dev/null 2>&1
  assert_eq 0 "$?" "t8: повторный run exit"
  # строка gnubin не задвоилась
  assert_eq 1 "$(grep -c 'claude-tools/timeout-fix' "$ZSHRC_TEST")" "t8: zshrc без дублей"
  teardown
}

# 9. run без brew в PATH → фейлит с понятным сообщением (exit ≠ 0), без трейса.
t9_run_no_brew() {
  setup
  # brew не замокан; PATH = только fakebin (jq берём из PATH-fallback ниже).
  # Чтобы jq был доступен, но brew — нет: кладём symlink jq в fakebin, brew не кладём.
  local real_jq; real_jq="$(command -v jq)"
  ln -sf "$real_jq" "$FAKEBIN/jq"
  seed_env_timeout "$DESIRED"
  seed_gnubin_in_zshrc
  PATH="$FAKEBIN" run_fix >/dev/null 2>&1
  local code=$?
  if [ "$code" != "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t9: run без brew должен фейлить, exit=$code"); fi
  teardown
}

# 10. run без jq → фейлит с подсказкой.
t10_run_no_jq() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout "$DESIRED"
  seed_gnubin_in_zshrc
  # PATH без директорий с jq — эмуляция отсутствия jq.
  PATH="$FAKEBIN" run_fix >/dev/null 2>&1
  local code=$?
  if [ "$code" != "0" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); FAILED_TESTS+=("t10: run без jq должен фейлить, exit=$code"); fi
  teardown
}

# 11. Запись в zshrc idempotent: повторный run не дублирует строку gnubin.
t11_zshrc_no_dup() {
  setup
  make_brew 1; make_gtimeout
  seed_env_timeout "$DESIRED"
  PATH="$(path_with_fakes)" run_fix >/dev/null 2>&1
  PATH="$(path_with_fakes)" run_fix >/dev/null 2>&1
  assert_eq 1 "$(grep -c 'claude-tools/timeout-fix' "$ZSHRC_TEST")" "t11: zshrc ровно одна строка gnubin"
  teardown
}

# 12. --value 900000 → записывает 900000 вместо дефолта.
t12_custom_value() {
  setup
  make_brew 1; make_gtimeout
  seed_gnubin_in_zshrc
  PATH="$(path_with_fakes)" run_fix --value 900000 >/dev/null 2>&1
  assert_match "900000" "$SETTINGS_TEST" "t12: --value переопределяет дефолт"
  teardown
}

# --- раннер ----------------------------------------------------------------
run_all() {
  for t in t1_all_ok_check t2_no_coreutils_check t3_no_env_check t4_low_env_check \
           t5_no_gnubin_check t6_run_no_brew_reinstall t7_run_sets_env \
           t8_run_idempotent t9_run_no_brew t10_run_no_jq t11_zshrc_no_dup \
           t12_custom_value; do
    "$t"
  done
}

run_all

echo
echo "==============================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================================="
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
