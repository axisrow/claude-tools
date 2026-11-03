#!/usr/bin/env bash
# red-green тесты Stop-хука auto-continue (фикстуры-транскрипты, боевой HOME изолирован).
# Запуск: bash tests/test_auto_continue.sh
set -u

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/auto-continue.mjs"
WORK="$(mktemp -d /tmp/ac-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
# homedir() хука уважает $HOME: state/log лягут в $WORK/.claude, боевые не тронутся
export HOME="$WORK"

PASS=0
FAIL=0

# expect_block <label> — ожидаем ровно block-JSON
expect_block() {
  local out
  out="$(printf '%s' "$STDIN" | node "$HOOK")"
  if [ "$out" = '{"decision":"block","reason":"Continue task"}' ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL(block): $1 -> '$out'"
  fi
}

# expect_allow <label> — ожидаем пустой stdout
expect_allow() {
  local out
  out="$(printf '%s' "$STDIN" | node "$HOOK")"
  if [ -z "$out" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL(allow): $1 -> '$out'"
  fi
}

# fixture <file> <lines...> — записать jsonl
fixture() {
  local f="$1"
  shift
  : > "$f"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$f"; done
}

# Строки фикстур. Cut — реальная форма синтетической строки из корпуса
# (анонимизирована, поля сохранены): канонический carrier model:'<synthetic>'.
CUT='{"parentUuid":"p1","isSidechain":false,"type":"assistant","uuid":"u1","timestamp":"2026-10-30T06:47:06.230Z","message":{"id":"4c79f576-0224-4753-97bb-c0a06c06b4b5","model":"<synthetic>","role":"assistant","stop_reason":"stop_sequence","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"API Error: The response stopped arriving. The response above may be incomplete."}]},"apiError":"stream_idle_timeout","error":"server_error","truncatedAfterOutput":true,"isApiErrorMessage":true,"session_id":"t"}'
CUT2='{"isSidechain":false,"type":"assistant","uuid":"u2","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: Connection lost mid-response. The response above may be incomplete."}]}}'
CUT_STR='{"isSidechain":false,"type":"assistant","uuid":"u3","message":{"model":"<synthetic>","content":"API Error: The response stopped arriving. The response above may be incomplete."}}'
REAL='{"isSidechain":false,"type":"assistant","uuid":"u4","message":{"model":"glm-5.3-flash","content":[{"type":"text","text":"Recovered, continuing the work."}]}}'
SIDECHAIN_CUT='{"isSidechain":true,"type":"assistant","uuid":"u5","message":{"model":"<synthetic>","content":[{"type":"text","text":"API Error: The response stopped arriving. The response above may be incomplete."}]}}'
BIG_TOOL_RESULT='{"isSidechain":false,"type":"user","isMeta":true,"uuid":"u6","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tv1","content":"x"}]}}'
BOOKKEEPING='{"type":"system","uuid":"s1","subtype":"turn_duration"}'
USER_PROMPT='{"isSidechain":false,"type":"user","isMeta":false,"uuid":"u7","message":{"role":"user","content":"do the thing"}}'
INTERRUPT='{"isSidechain":false,"type":"user","isMeta":true,"uuid":"u8","message":{"role":"user","content":"[Request interrupted by user]"}}'

# 1. один cut в хвосте -> block, раунд записан в state
fixture "$WORK/t1.jsonl" "$USER_PROMPT" "$CUT" "$BOOKKEEPING"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t1.jsonl","session_id":"s1"}'
expect_block "1: single cut blocks"
if [ "$(jq -r '.count' "$WORK/.claude/claude-autocontinue-state/s1.json" 2>/dev/null)" = '1' ]; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL: 1b: state rounds=1 not persisted"
fi

# 2. кап: 2-й и 3-й блокируются, 4-й — нет (MAX_ROUNDS=3)
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t1.jsonl","session_id":"s1"}'
expect_block "2a: second cut blocks (rounds=2)"
expect_block "2b: third cut blocks (rounds=3)"
expect_allow "2c: fourth cut capped (rounds=3, allow)"

# 3. TTL: бустджет протух -> снова блокирует
printf '{"count":3,"ts":%s}' "$(( ($(date +%s) - 660) * 1000 ))" > "$WORK/.claude/claude-autocontinue-state/s1.json"
expect_block "3: stale budget refreshes (TTL)"

# 4. реальный assistant новее cut -> allow (серия кончилась)
fixture "$WORK/t4.jsonl" "$USER_PROMPT" "$CUT" "$REAL"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t4.jsonl","session_id":"s4"}'
expect_allow "4: real assistant ends series"

# 4b. реальный ЧАСТИЧНЫЙ ответ между cut (корпусный паттерн 12/17) -> block,
#     кап раундов (не строк) ограничивает цикл: 3 блока -> allow
fixture "$WORK/t4b.jsonl" "$USER_PROMPT" "$CUT" "$REAL" "$CUT2" "$BOOKKEEPING"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t4b.jsonl","session_id":"s4b"}'
expect_block "4b-1: partial-between-cuts still triggers (rounds=1)"
expect_block "4b-2: same tail blocks again (rounds=2)"
expect_block "4b-3: same tail blocks again (rounds=3)"
expect_allow "4b-4: same tail capped — rounds bound the loop"

# 5. sidechain-only cut -> allow
fixture "$WORK/t5.jsonl" "$USER_PROMPT" "$SIDECHAIN_CUT"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t5.jsonl","session_id":"s5"}'
expect_allow "5: sidechain cut ignored"

# 6. обычная остановка -> allow
fixture "$WORK/t6.jsonl" "$USER_PROMPT" "$REAL"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t6.jsonl","session_id":"s6"}'
expect_allow "6: normal stop allows"

# 7. Esc-интерпрет в хвосте -> allow (явное намерение пользователя)
fixture "$WORK/t7.jsonl" "$USER_PROMPT" "$CUT" "$INTERRUPT"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t7.jsonl","session_id":"s7"}'
expect_allow "7: interrupt marker allows"

# 8. off-маркер сессии -> allow
fixture "$WORK/t8.jsonl" "$USER_PROMPT" "$CUT"
mkdir -p "$WORK/.claude/claude-autocontinue-off"
: > "$WORK/.claude/claude-autocontinue-off/s8"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t8.jsonl","session_id":"s8"}'
expect_allow "8: off-marker allows"

# 9. другое событие -> allow
fixture "$WORK/t9.jsonl" "$USER_PROMPT" "$CUT"
STDIN='{"hook_event_name":"PreToolUse","transcript_path":"'"$WORK"'/t9.jsonl","session_id":"s9"}'
expect_allow "9: non-Stop event allows"

# 10. нет transcript_path / файла -> allow
STDIN='{"hook_event_name":"Stop","session_id":"s10"}'
expect_allow "10a: no transcript_path allows"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/missing.jsonl","session_id":"s10"}'
expect_allow "10b: missing file allows"

# 11. string-content форма -> block
fixture "$WORK/t11.jsonl" "$USER_PROMPT" "$CUT_STR"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t11.jsonl","session_id":"s11"}'
expect_block "11: string content shape blocks"

# 12. мегабайтный tool_result в хвосте -> дёшево, block (парс только assistant-строк)
fixture "$WORK/t12.jsonl" "$USER_PROMPT" "$BIG_TOOL_RESULT" "$CUT"
STDIN='{"hook_event_name":"Stop","transcript_path":"'"$WORK"'/t12.jsonl","session_id":"s12"}'
expect_block "12: walk skips non-assistant lines"

# --- StopFailure-ветка (sf): launcher + detached ребёнок в dry-run ----------
SF_HOOK="$(dirname "$HOOK")/auto-continue-sf.sh"
LOG="$WORK/.claude/claude-autocontinue.log"
export AUTOCONTINUE_DRY_RUN=1
export AUTOCONTINUE_CONFIRM_MS=300

# ожидание записи от detached-ребёнка (до ~4 c)
await_log() {
  local i
  for i in $(seq 1 40); do
    grep -qE "$1" "$LOG" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

mkdir -p "$WORK/fakeworktree"

# 13. StopFailure + cut-хвост -> ребёнок логирует sf-dry с маппингом ao=<basename cwd>
fixture "$WORK/t13.jsonl" "$USER_PROMPT" "$CUT" "$BOOKKEEPING"
STDIN='{"hook_event_name":"StopFailure","transcript_path":"'"$WORK"'/t13.jsonl","session_id":"sfsessio-long-id","cwd":"'"$WORK"'/fakeworktree"}'
printf '%s' "$STDIN" | bash "$SF_HOOK"
if await_log "kind=sf-dry session=sfsessio ao=fakeworktree cutUuid=u1"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL(sf): 13: dry ao-send not logged"
fi

# 14. newest assistant не из семьи -> sf-notfamily
fixture "$WORK/t14.jsonl" "$USER_PROMPT" "$REAL"
STDIN='{"hook_event_name":"StopFailure","transcript_path":"'"$WORK"'/t14.jsonl","session_id":"sfnofam1","cwd":"'"$WORK"'/fakeworktree"}'
printf '%s' "$STDIN" | bash "$SF_HOOK"
if await_log "kind=sf-notfamily session=sfnofam1"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL(sf): 14: notfamily not logged"
fi

# 15. свежий промпт новее cut -> sf-hasinput (не дублируем steer)
fixture "$WORK/t15.jsonl" "$USER_PROMPT" "$CUT" "$USER_PROMPT"
STDIN='{"hook_event_name":"StopFailure","transcript_path":"'"$WORK"'/t15.jsonl","session_id":"sfhasin1","cwd":"'"$WORK"'/fakeworktree"}'
printf '%s' "$STDIN" | bash "$SF_HOOK"
if await_log "kind=sf-hasinput session=sfhasin1"; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "FAIL(sf): 15: hasinput not logged"
fi

# 16. чужое событие -> ребёнок не спавнится, записи нет
STDIN='{"hook_event_name":"PreToolUse","transcript_path":"'"$WORK"'/t13.jsonl","session_id":"sfnope01","cwd":"'"$WORK"'/fakeworktree"}'
printf '%s' "$STDIN" | bash "$SF_HOOK"
sleep 0.6
if grep -qE "session=sfnope01" "$LOG" 2>/dev/null; then
  FAIL=$((FAIL + 1))
  echo "FAIL(sf): 16: child spawned on wrong event"
else
  PASS=$((PASS + 1))
fi

echo
echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]