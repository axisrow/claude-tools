#!/usr/bin/env bash
# test_merge_guard.sh — red-green тесты для bin/merge-guard.
#
# Стратегия изоляции (БЕЗ боя): `gh` мокается через PATH-подмену (fakebin/gh).
# Мок — bash-скрипт, диспетчеризующий по аргументам (-i --silent <path> для
# GET-проверок статуса, -X PUT/PATCH/POST/DELETE для write-операций) и по
# переменным окружения GH_MOCK_* (какой HTTP-статус отдавать на какой путь).
# jq берётся из системы. bash 3.2-safe (без ассоциативных массивов).
#
# Запуск: bash tests/test_merge_guard.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MG="$PROJECT_DIR/bin/merge-guard"

PASS=0
FAIL=0
FAILED_TESTS=()

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
    FAILED_TESTS+=("$desc: pattern [$pattern] not in $file")
  fi
}

assert_nomatch() {
  local pattern="$1" file="$2" desc="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$desc: pattern [$pattern] SHOULD NOT be in $file but is")
  else
    PASS=$((PASS+1))
  fi
}

assert_eq() {
  local expected="$1" actual="$2" desc="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$desc: expected=[$expected] actual=[$actual]")
  fi
}

# --- фикстуры -----------------------------------------------------------------
WORK=""
setup() {
  WORK="$(mktemp -d)"
  FAKEBIN="$WORK/fakebin"; mkdir -p "$FAKEBIN"
  GH_LOG="$WORK/gh_calls.log"; : >"$GH_LOG"
  ln -sf "$(command -v jq)" "$FAKEBIN/jq"
}

teardown() {
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
}

# Мок gh. Диспетчеризация по под-команде api и аргументам.
# Поведение задаётся через env-переменные (читаются мок-скриптом изнутри):
#   GH_MOCK_REVIEWS_STATUS   — HTTP-статус для .../protection/required_pull_request_reviews (GET)
#   GH_MOCK_PROTECTION_STATUS — HTTP-статус для .../protection (GET)
#   GH_MOCK_WRITE_EXIT       — exit code для write-операций (PUT/PATCH/POST/DELETE), default 0
#   GH_MOCK_REPOS            — многострочный список repo full_name для user/repos (list_repos)
#   GH_MOCK_DEFAULT_BRANCH   — default_branch для repos/{repo}
make_gh() {
  cat >"$FAKEBIN/gh" <<'MOCKEOF'
#!/usr/bin/env bash
LOG="${GH_MOCK_LOG:?}"
echo "$*" >> "$LOG"

if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  exit 0
fi

if [ "$1" != "api" ]; then
  echo "gh-mock: unsupported subcommand: $1" >&2
  exit 2
fi
shift

METHOD="GET"
ENDPOINT=""
INCLUDE=0
JQ_EXPR=""
NEXT_IS_METHOD=0
NEXT_IS_JQ=0
for arg in "$@"; do
  if [ "$NEXT_IS_METHOD" = "1" ]; then METHOD="$arg"; NEXT_IS_METHOD=0; continue; fi
  if [ "$NEXT_IS_JQ" = "1" ]; then JQ_EXPR="$arg"; NEXT_IS_JQ=0; continue; fi
  case "$arg" in
    -X) NEXT_IS_METHOD=1 ;;
    --jq|-q) NEXT_IS_JQ=1 ;;
    -i) INCLUDE=1 ;;
    --silent|--paginate) : ;;
    -*) : ;;
    *) [ -z "$ENDPOINT" ] && ENDPOINT="$arg" ;;
  esac
done

# Применяет --jq к телу ответа, если оно было передано (имитация реального gh api --jq).
apply_jq() {
  # apply_jq <json-body>
  if [ -n "$JQ_EXPR" ]; then
    printf '%s' "$1" | jq -r "$JQ_EXPR"
  else
    printf '%s\n' "$1"
  fi
}

status_line() {
  # status_line <code>
  case "$1" in
    200) echo "HTTP/2.0 200 OK" ;;
    404) echo "HTTP/2.0 404 Not Found" ;;
    403) echo "HTTP/2.0 403 Forbidden" ;;
    *) echo "HTTP/2.0 $1 Error" ;;
  esac
}

case "$ENDPOINT" in
  user/repos)
    [ "$METHOD" != "GET" ] && { echo "gh-mock: list_repos must use GET, got $METHOD" >&2; exit 1; }
    printf '%s\n' "${GH_MOCK_REPOS:-}"
    exit 0
    ;;
  repos/*/branches/*/protection/required_pull_request_reviews)
    case "$METHOD" in
      GET)
        code="${GH_MOCK_REVIEWS_STATUS:-200}"
        [ "$INCLUDE" = "1" ] && status_line "$code"
        [ "$code" = "200" ] && exit 0 || exit 1
        ;;
      PATCH|DELETE)
        exit "${GH_MOCK_WRITE_EXIT:-0}"
        ;;
      *) echo "gh-mock: unexpected method $METHOD for reviews sub-endpoint" >&2; exit 2 ;;
    esac
    ;;
  repos/*/branches/*/protection/enforce_admins)
    case "$METHOD" in
      GET)
        # Реальный GitHub: этот sub-endpoint 200 и при true, и при false
        # (404 только когда protection нет вообще) — мок отражает это:
        # GH_MOCK_ENFORCE_ADMINS_HTTP управляет HTTP-ошибками (404/403/пусто),
        # GH_MOCK_ENFORCE_ADMINS_ENABLED — значением .enabled при HTTP 200.
        http="${GH_MOCK_ENFORCE_ADMINS_HTTP:-200}"
        if [ "$http" != "200" ]; then
          exit 1
        fi
        apply_jq "{\"enabled\": ${GH_MOCK_ENFORCE_ADMINS_ENABLED:-true}}"
        exit 0
        ;;
      POST)
        exit "${GH_MOCK_WRITE_EXIT:-0}"
        ;;
      *) echo "gh-mock: unexpected method $METHOD for enforce_admins sub-endpoint" >&2; exit 2 ;;
    esac
    ;;
  repos/*/branches/*/protection/required_status_checks)
    case "$METHOD" in
      GET)
        code="${GH_MOCK_RSC_STATUS:-200}"
        [ "$INCLUDE" = "1" ] && status_line "$code"
        if [ "$code" = "200" ]; then
          # GH_MOCK_RSC_CONTEXTS — csv контекстов; strict фиксирован true.
          contexts_json="$(printf '%s' "${GH_MOCK_RSC_CONTEXTS:-}" | awk -F, '{printf "["; sep=""; for(i=1;i<=NF;i++){if($i!=""){printf "%s\"%s\"", sep, $i; sep=","}} print "]"}')"
          printf '{"strict": true, "contexts": %s}\n' "$contexts_json"
          exit 0
        fi
        exit 1
        ;;
      PATCH)
        exit "${GH_MOCK_WRITE_EXIT:-0}"
        ;;
      *) echo "gh-mock: unexpected method $METHOD for required_status_checks" >&2; exit 2 ;;
    esac
    ;;
  repos/*/branches/*/protection)
    case "$METHOD" in
      GET)
        code="${GH_MOCK_PROTECTION_STATUS:-200}"
        [ "$INCLUDE" = "1" ] && status_line "$code"
        [ "$code" = "200" ] && exit 0 || exit 1
        ;;
      PUT)
        # захватываем payload из stdin в отдельный файл для проверки enforce_admins
        cat > "${GH_MOCK_PUT_PAYLOAD_FILE:-/dev/null}"
        exit "${GH_MOCK_WRITE_EXIT:-0}"
        ;;
      *) echo "gh-mock: unexpected method $METHOD for protection endpoint" >&2; exit 2 ;;
    esac
    ;;
  repos/*/contents/.github/workflows/require-review-comment.yml)
    case "$METHOD" in
      GET)
        code="${GH_MOCK_GATE_FILE_STATUS:-404}"
        [ "$INCLUDE" = "1" ] && status_line "$code"
        if [ "$code" = "200" ]; then
          printf '{"content": "%s"}\n' "${GH_MOCK_GATE_FILE_CONTENT:-}"
          exit 0
        fi
        exit 1
        ;;
      PUT)
        exit "${GH_MOCK_WRITE_EXIT:-0}"
        ;;
      *) echo "gh-mock: unexpected method $METHOD for gate workflow file" >&2; exit 2 ;;
    esac
    ;;
  repos/*)
    apply_jq "{\"default_branch\": \"${GH_MOCK_DEFAULT_BRANCH:-main}\"}"
    exit 0
    ;;
  *)
    echo "gh-mock: unhandled endpoint: $ENDPOINT (method $METHOD)" >&2
    exit 2
    ;;
esac
MOCKEOF
  chmod +x "$FAKEBIN/gh"
}

run_mg() { GH_MOCK_LOG="$GH_LOG" PATH="$FAKEBIN:$PATH" "$MG" "$@"; }

# --- тесты ----------------------------------------------------------------

# 1. list_repos обязан звать GET, не POST (regression: -f без -X GET switches to POST).
t1_list_repos_uses_get() {
  setup; make_gh
  GH_MOCK_REPOS="owner/repo-a" run_mg status >/dev/null 2>&1
  assert_exit 0 "t1: status без REPO не падает (list_repos использует GET)" -- \
    env GH_MOCK_LOG="$GH_LOG" GH_MOCK_REPOS="owner/repo-a" PATH="$FAKEBIN:$PATH" "$MG" status
  teardown
}

# 2. check_reviews_enabled: 200 → enable_repo видит idempotent skip (уже включена).
t2_reviews_enabled_on_200() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=200 run_mg enable owner/repo-a 2>&1)"
  assert_match "уже включена" <(echo "$out") "t2: 200 на reviews sub-endpoint → уже включена (idempotent skip)"
  teardown
}

# 3. check_reviews_enabled: 404 (не 403) → enable продолжает (не 'уже включена').
t3_reviews_disabled_on_404_not_403() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=404 GH_MOCK_PROTECTION_STATUS=200 run_mg enable owner/repo-a 2>&1)"
  assert_nomatch "уже включена" <(echo "$out") "t3: 404 на reviews → не 'уже включена', продолжает"
  teardown
}

# 4. check_reviews_enabled: 403 (не 200, не 404) → fail-closed, ОШИБКА, не PUT/PATCH.
t4_reviews_403_fails_closed() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=403 run_mg enable owner/repo-a 2>&1)"
  assert_match "ОШИБКА" <(echo "$out") "t4: 403 на reviews sub-endpoint → ОШИБКА (fail-closed), не тихий skip"
  assert_nomatch "PUT\|PATCH" <(echo "$out") "t4: 403 на reviews → не доходит до PUT/PATCH"
  teardown
}

# 5. check_protection_exists: 403 (не 404) на protection → enable НЕ идёт в деструктивный PUT.
t5_protection_403_no_destructive_put() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=404 GH_MOCK_PROTECTION_STATUS=403 run_mg enable owner/repo-a 2>&1)"
  assert_match "ОШИБКА" <(echo "$out") "t5: 403 на protection → ОШИБКА (fail-closed)"
  assert_nomatch "PUT %" <(echo "$out") "t5: 403 на protection → НЕ идёт в PUT (деструктивная запись предотвращена)"
  teardown
}

# 6. check_protection_exists: 404 (точно нет) → enable идёт по PUT-ветке (создаёт защиту).
t6_protection_404_goes_to_put() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=404 GH_MOCK_PROTECTION_STATUS=404 run_mg enable owner/repo-a 2>&1)"
  assert_match "PUT" <(echo "$out") "t6: 404 на protection → PUT-ветка (создаёт новую защиту)"
  teardown
}

# 7. enable_repo (PUT-ветка, защиты нет) шлёт enforce_admins: true в payload.
t7_put_payload_enforce_admins_true() {
  setup; make_gh
  local payload_file="$WORK/put_payload.json"
  GH_MOCK_REVIEWS_STATUS=404 GH_MOCK_PROTECTION_STATUS=404 \
    GH_MOCK_PUT_PAYLOAD_FILE="$payload_file" \
    run_mg enable owner/repo-a >/dev/null 2>&1
  local enforce
  enforce="$(jq -r '.enforce_admins' "$payload_file" 2>/dev/null)"
  assert_eq "true" "$enforce" "t7: PUT payload enforce_admins должен быть true (иначе admin обходит защиту)"
  teardown
}

# 8. enable_repo (PATCH-ветка, защита уже есть) тоже включает enforce_admins
#    отдельным POST на enforce_admins sub-endpoint.
t8_patch_branch_calls_enforce_admins() {
  setup; make_gh
  GH_MOCK_REVIEWS_STATUS=404 GH_MOCK_PROTECTION_STATUS=200 \
    run_mg enable owner/repo-a >/dev/null 2>&1
  assert_match "enforce_admins" "$GH_LOG" "t8: PATCH-ветка тоже дёргает enforce_admins endpoint"
  teardown
}

# 9. disable_repo: reviews API error (403) → ОШИБКА, не тихий "не включены".
t9_disable_403_fails_closed() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=403 run_mg disable owner/repo-a 2>&1)"
  assert_match "ОШИБКА" <(echo "$out") "t9: disable при 403 на reviews → ОШИБКА (fail-closed), не 'не включены'"
  teardown
}

# 10. status_repo: reviews 403 → выводит предупреждение об ошибке, не 'защита отсутствует'.
t10_status_403_shows_error_not_absent() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=403 run_mg status owner/repo-a 2>&1)"
  assert_nomatch "защита отсутствует" <(echo "$out") "t10: status при 403 НЕ должен утверждать 'защита отсутствует'"
  teardown
}

# 11. status_repo: reviews=200 → 'reviews обязателен', без похода на protection endpoint.
t11_status_reviews_enabled() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=200 run_mg status owner/repo-a 2>&1)"
  assert_match "reviews обязателен" <(echo "$out") "t11: status при reviews=200 → 'reviews обязателен'"
  teardown
}

# 12. Idempotent-skip НЕ должен пропускать enforce_admins: если reviews уже
#     включены (200), но enforce_admins.enabled=false в теле (реальный GitHub:
#     этот sub-endpoint 200 и при true, и при false — 404 бывает только когда
#     protection нет вообще) — enable_repo обязан дожать enforce_admins POST-ом,
#     а не молча вернуть "уже включена". Regression-тест на cycle-3 находку
#     Codex: код неправильно трактовал HTTP 200 как enforce_admins=true.
t12_idempotent_skip_still_fixes_enforce_admins() {
  setup; make_gh
  GH_MOCK_REVIEWS_STATUS=200 GH_MOCK_ENFORCE_ADMINS_HTTP=200 GH_MOCK_ENFORCE_ADMINS_ENABLED=false \
    run_mg enable owner/repo-a >/dev/null 2>&1
  assert_match "X POST repos/owner/repo-a/branches/main/protection/enforce_admins" "$GH_LOG" \
    "t12: reviews=200 но enforce_admins body {enabled:false} (тоже HTTP 200!) → всё равно шлёт POST enforce_admins"
  teardown
}

# 13. Настоящий idempotent-skip: reviews=200 И enforce_admins.enabled=true —
#     тогда действительно ничего не долается (нет лишних write-вызовов).
t13_true_idempotent_skip_when_both_enabled() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=200 GH_MOCK_ENFORCE_ADMINS_HTTP=200 GH_MOCK_ENFORCE_ADMINS_ENABLED=true \
    run_mg enable owner/repo-a 2>&1)"
  assert_match "уже включена" <(echo "$out") "t13: reviews=200 и enforce_admins.enabled=true → настоящий idempotent skip"
  teardown
}

# 14. check_enforce_admins_enabled: настоящая ошибка API (404 — protection
#     нет вообще) должна прерывать enable_repo fail-closed, а не молча
#     трактоваться как false (это отдельная ветка от t6/t5, где enable_repo
#     уже проверил, что protection существует через check_protection_exists —
#     но enforce_admins-запрос теоретически может словить свою ошибку,
#     например rate-limit, независимо от протекшна).
t14_enforce_admins_api_error_fails_closed() {
  setup; make_gh
  local out
  out="$(GH_MOCK_REVIEWS_STATUS=200 GH_MOCK_ENFORCE_ADMINS_HTTP=403 run_mg enable owner/repo-a 2>&1)"
  assert_match "ОШИБКА" <(echo "$out") "t14: enforce_admins API error (403) → ОШИБКА, fail-closed"
  teardown
}

# --- rollout: гейт «есть комментарий на PR» -----------------------------------

make_config() {
  # make_config <file> [EXCLUDE]
  local file="$1" exclude="${2:-}"
  cat > "$file" <<EOF
CHECK_NAME=merge-guard/review-comment
MIN_COMMENTS=1
REPOS=all
EXCLUDE=$exclude
EOF
}

# 15. rollout на репо без protection: заливает workflow-файл И создаёт защиту
#     через PUT (с required_status_checks, без required reviews).
t15_rollout_no_protection_creates_put() {
  setup; make_gh
  local cfg="$WORK/merge-guard.conf"
  make_config "$cfg"
  local out
  out="$(GH_MOCK_PROTECTION_STATUS=404 GH_MOCK_GATE_FILE_STATUS=404 \
    run_mg rollout --config "$cfg" --repo owner/repo-a 2>&1)"
  assert_match "залит" <(echo "$out") "t15: rollout заливает workflow-файл"
  assert_match "создаю защиту" <(echo "$out") "t15: rollout без protection идёт в PUT (создаёт защиту)"
  assert_match "X PUT repos/owner/repo-a/contents/.github/workflows/require-review-comment.yml" "$GH_LOG" \
    "t15: workflow-файл заливается через Contents API"
  assert_match "X PUT repos/owner/repo-a/branches/main/protection" "$GH_LOG" \
    "t15: protection создаётся через PUT"
  teardown
}

# 16. rollout на репо с защитой, где контекста ещё нет: PATCH
#     required_status_checks (добавляет контекст, сохраняя существующие).
t16_rollout_existing_protection_patches_rsc() {
  setup; make_gh
  local cfg="$WORK/merge-guard.conf"
  make_config "$cfg"
  local out
  out="$(GH_MOCK_PROTECTION_STATUS=200 GH_MOCK_RSC_STATUS=200 GH_MOCK_RSC_CONTEXTS="other-check" \
    GH_MOCK_GATE_FILE_STATUS=404 run_mg rollout --config "$cfg" --repo owner/repo-a 2>&1)"
  assert_match "добавлен" <(echo "$out") "t16: rollout добавляет контекст в required checks"
  assert_match "X PATCH repos/owner/repo-a/branches/main/protection/required_status_checks" "$GH_LOG" \
    "t16: PATCH required_status_checks (не PUT protection)"
  assert_nomatch "X PUT repos/owner/repo-a/branches/main/protection" "$GH_LOG" \
    "t16: существующая защита не перезаписывается PUT-ом"
  teardown
}

# 17. Idempotency: контекст уже в required checks → skip, без PATCH.
t17_rollout_existing_context_skips() {
  setup; make_gh
  local cfg="$WORK/merge-guard.conf"
  make_config "$cfg"
  local out
  out="$(GH_MOCK_PROTECTION_STATUS=200 GH_MOCK_RSC_STATUS=200 GH_MOCK_RSC_CONTEXTS="merge-guard/review-comment" \
    GH_MOCK_GATE_FILE_STATUS=404 run_mg rollout --config "$cfg" --repo owner/repo-a 2>&1)"
  assert_match "idempotent skip" <(echo "$out") "t17: контекст уже есть → idempotent skip"
  assert_nomatch "X PATCH repos/.*/required_status_checks" "$GH_LOG" \
    "t17: при уже включённом контексте PATCH не шлётся"
  teardown
}

# 18. Workflow-файл есть, но отличается от шаблона → перезаливается.
t18_rollout_different_file_reuploads() {
  setup; make_gh
  local cfg="$WORK/merge-guard.conf"
  make_config "$cfg"
  local out
  out="$(GH_MOCK_PROTECTION_STATUS=404 GH_MOCK_GATE_FILE_STATUS=200 \
    GH_MOCK_GATE_FILE_CONTENT="$(printf 'old-content' | base64)" \
    run_mg rollout --config "$cfg" --repo owner/repo-a 2>&1)"
  assert_match "залит" <(echo "$out") "t18: отличающийся workflow-файл перезаливается"
  assert_match "X PUT repos/owner/repo-a/contents/.github/workflows/require-review-comment.yml" "$GH_LOG" \
    "t18: PUT contents при отличии файла"
  teardown
}

# 19. --dry-run: показывает план, но не пишет (нет write-вызовов в логе).
t19_rollout_dry_run_no_writes() {
  setup; make_gh
  local cfg="$WORK/merge-guard.conf"
  make_config "$cfg"
  local out
  out="$(GH_MOCK_PROTECTION_STATUS=404 GH_MOCK_GATE_FILE_STATUS=404 \
    run_mg rollout --config "$cfg" --dry-run --repo owner/repo-a 2>&1)"
  assert_match "DRY-RUN" <(echo "$out") "t19: dry-run помечает прогон"
  assert_match "\[dry-run\]" <(echo "$out") "t19: dry-run показывает, что сделал бы"
  assert_nomatch "X PUT" "$GH_LOG" "t19: dry-run не делает write-вызовов"
  teardown
}

# 20. EXCLUDE из конфига отфильтровывает репо из списка.
t20_rollout_exclude_filters() {
  setup; make_gh
  local cfg="$WORK/merge-guard.conf"
  make_config "$cfg" "owner/b"
  local out
  out="$(GH_MOCK_REPOS="owner/a
owner/b" GH_MOCK_PROTECTION_STATUS=404 GH_MOCK_GATE_FILE_STATUS=404 \
    run_mg rollout --config "$cfg" 2>&1)"
  assert_match "owner/a" <(echo "$out") "t20: неисключённое репо обрабатывается"
  assert_nomatch "owner/b" <(echo "$out") "t20: исключённое репо не обрабатывается"
  teardown
}

# --- раннер -----------------------------------------------------------------
run_all() {
  for t in t1_list_repos_uses_get t2_reviews_enabled_on_200 t3_reviews_disabled_on_404_not_403 \
           t4_reviews_403_fails_closed t5_protection_403_no_destructive_put t6_protection_404_goes_to_put \
           t7_put_payload_enforce_admins_true t8_patch_branch_calls_enforce_admins \
           t9_disable_403_fails_closed t10_status_403_shows_error_not_absent t11_status_reviews_enabled \
           t12_idempotent_skip_still_fixes_enforce_admins t13_true_idempotent_skip_when_both_enabled \
           t14_enforce_admins_api_error_fails_closed \
           t15_rollout_no_protection_creates_put t16_rollout_existing_protection_patches_rsc \
           t17_rollout_existing_context_skips t18_rollout_different_file_reuploads \
           t19_rollout_dry_run_no_writes t20_rollout_exclude_filters; do
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
