#!/usr/bin/env bash
# test_one_command_at_a_time.sh — red-green тесты для hooks/one-command-at-a-time.sh.
#
# Хук читает stdin JSON {.tool_input:{command:"..."}} и возвращает:
#   - ask JSON {hookSpecificOutput:{...permissionDecision:"ask",permissionDecisionReason:...}}
#     если команда compound (несколько команд через &&/;/||/|) или ambiguous (heredoc/arith/[[ ]]);
#   - exit 0 (ничего не печатает) если команда clean (одиночная, операторы внутри кавычек).
#
# Стратегия: гоняем хук через echo '{...}' | hook, проверяем exit code + наличие ask-JSON.
# ВАЖНО: тесты запускать через `bash` (НЕ zsh) — хук использует bash 3.2 массивы/substr.
#
# Запуск: bash tests/test_one_command_at_a_time.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$PROJECT_DIR/hooks/one-command-at-a-time.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

# --- helpers ----------------------------------------------------------------
# run_hook <command-string> → stdout=hook-output, exit=$?
# Передаём команду через --arg (несёт \n корректно), а НЕ через stdin -R
# (последний построчно читает и теряет newline — многострочные кейсы тестировались бы как однострочные).
run_hook() {
  jq -nc --arg cmd "$1" '{tool_input:{command:$cmd}}' | "$HOOK" 2>/dev/null
}

# assert_ask <description> <command-string> — ожидаем ask (permissionDecision == "ask")
assert_ask() {
  local desc="$1" cmd="$2"
  local out; out="$(run_hook "$cmd")" || true
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$desc: ожидался ask, получили: [${out:-<пусто>/exit-nonzero}] cmd=[$cmd]")
  fi
}

# assert_pass <description> <command-string> — ожидаем clean (exit 0, пустой вывод)
assert_pass() {
  local desc="$1" cmd="$2"
  local out rc
  out="$(run_hook "$cmd")"; rc=$?
  if [ "$rc" = "0" ] && [ -z "$out" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$desc: ожидался pass (exit 0, пусто), получили rc=$rc out=[$out] cmd=[$cmd]")
  fi
}

# --- ask (compound) ---------------------------------------------------------
assert_ask "top-level &&"            'git push --delete x && echo done'
assert_ask "semicolon"               'echo hi; echo bye'
assert_ask "top-level ||"            'a || b'
assert_ask "top-level pipe"          'jq .a x | jq .b'
assert_ask "cd && cmd (без исключения)" 'cd /x && make'
assert_ask "тройной &&"              'a && b && c'
assert_ask "compound внутри \$()"    'echo "$(a && b)"'
assert_ask "оператор после комментария" 'echo a && echo b # comment'
assert_ask "newline = разделитель"   $'echo a\necho b'
assert_ask "line-continuation \\<NL>&&" $'echo a \\\n&& echo b'
assert_ask "compound в subshell ()"  '(a && b)'
assert_ask "backtick compound"       'echo `a && b`'

# --- pass (clean) -----------------------------------------------------------
assert_pass "одиночная"              'git status'
assert_pass "&& внутри одинарных"    "grep 'a && b' file"
assert_pass "| внутри двойных без subshell" 'echo "a|b"'
assert_pass "&& внутри -m кавычек"   'git commit -m "x && y"'
assert_pass "| внутри jq-кавычек"    'jq ".a | .b" f'
assert_pass "escaped ;"              'echo x \; y'
assert_pass "escaped &&"             'echo x \&\& y'
assert_pass "# внутри слова literal" 'echo foo#bar'

# --- ambiguous (→ ask с причиной ambiguous) ---------------------------------
# V1 не поддерживает heredoc/arithmetic/[[ ]], но ambiguous тоже → ask,
# поэтому проверяем ask (без различения compound/ambiguous на уровне permissionDecision).
assert_ask "heredoc (V1 ambiguous)"  'cat <<EOF
a && b
EOF'
assert_ask "arithmetic (V1 ambiguous)" 'echo $((a || b))'
assert_ask "[[ ]] conditional (V1 ambiguous)" '[[ -f x && -r x ]]'

echo
echo "==============================================="
echo "  PASS: $PASS   FAIL: $FAIL"
echo "==============================================="
if [ "$FAIL" -gt 0 ]; then
  printf '  - %s\n' "${FAILED_TESTS[@]}"
  exit 1
fi
exit 0
