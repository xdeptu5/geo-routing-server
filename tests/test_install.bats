#!/usr/bin/env bats
# =============================================================================
# bats-core тесты для install.sh
# Запуск: bats tests/test_install.bats
# =============================================================================

setup() {
    # Переходим в корень репозитория
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    cd "$REPO_ROOT"
    INSTALL_SH="$REPO_ROOT/install.sh"
}

# ── Вспомогательная функция: загружаем install.sh без выполнения main() ──────
load_functions() {
    # Подавляем set -euo pipefail чтобы source не падал при незаданных vars
    # shellcheck disable=SC1090
    set +euo pipefail
    source "$INSTALL_SH" 2>/dev/null || true
    set -euo pipefail
}

# =============================================================================
# 1. Синтаксис install.sh
# =============================================================================
@test "install.sh: синтаксис bash -n проходит без ошибок" {
    run bash -n "$INSTALL_SH"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 2. check_root() — не-root → exit 1
# =============================================================================
@test "check_root: завершается с кодом 1 при запуске без root" {
    if [ "$(id -u)" -eq 0 ]; then
        skip "Тест запущен от root — check_root пройдёт, а не упадёт"
    fi
    run bash -c "source '$INSTALL_SH' 2>/dev/null; check_root"
    [ "$status" -ne 0 ]
}

# =============================================================================
# 3. check_dependencies() — docker доступен в CI
# =============================================================================
@test "docker: доступен в PATH (CI-среда)" {
    run docker --version
    [ "$status" -eq 0 ]
}

@test "docker compose: v2 плагин доступен" {
    run docker compose version
    [ "$status" -eq 0 ]
}

# =============================================================================
# 4. openssl rand — генерация токена (используется на строке 655)
# =============================================================================
@test "openssl rand -hex 16: генерирует 32-символьный hex-токен" {
    run openssl rand -hex 16
    [ "$status" -eq 0 ]
    # Токен должен быть ровно 32 символа (16 байт × 2)
    [ "${#output}" -eq 32 ]
    # Только hex-символы
    [[ "$output" =~ ^[0-9a-f]+$ ]]
}

@test "openssl rand: токен содержит только безопасные символы [A-Za-z0-9._-]" {
    # install.sh использует hex — он только [0-9a-f], что подмножество безопасных
    token="$(openssl rand -hex 16)"
    [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]]
}

# =============================================================================
# 5. grep-парсинг .env (паттерн из install.sh строки 525, 529)
# =============================================================================
@test "grep .env: читает ROUTING_TOKEN из простого файла" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "ROUTING_TOKEN=mysecrettoken123" > "$tmpfile"
    run bash -c "grep '^ROUTING_TOKEN=' '$tmpfile' | cut -d'=' -f2-"
    [ "$status" -eq 0 ]
    [ "$output" = "mysecrettoken123" ]
    rm -f "$tmpfile"
}

@test "grep .env: игнорирует закомментированные строки" {
    local tmpfile
    tmpfile="$(mktemp)"
    printf "# ROUTING_TOKEN=ignored\nROUTING_TOKEN=real_value\n" > "$tmpfile"
    run bash -c "grep '^ROUTING_TOKEN=' '$tmpfile' | cut -d'=' -f2-"
    [ "$status" -eq 0 ]
    [ "$output" = "real_value" ]
    rm -f "$tmpfile"
}

@test "grep .env: возвращает пустую строку если ключ отсутствует" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "OTHER_VAR=value" > "$tmpfile"
    run bash -c "grep '^ROUTING_TOKEN=' '$tmpfile' | cut -d'=' -f2- || true"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    rm -f "$tmpfile"
}

@test "grep .env: значение с = внутри сохраняется полностью (JWT-токены)" {
    local tmpfile
    tmpfile="$(mktemp)"
    echo "REMNAWAVE_TOKEN=eyJhbGciOiJIUzI1NiJ9.payload.signature==" > "$tmpfile"
    run bash -c "grep '^REMNAWAVE_TOKEN=' '$tmpfile' | cut -d'=' -f2-"
    [ "$status" -eq 0 ]
    [ "$output" = "eyJhbGciOiJIUzI1NiJ9.payload.signature==" ]
    rm -f "$tmpfile"
}

# =============================================================================
# 6. Nginx regex — скрытые файлы блокируются
# =============================================================================
@test "nginx regex: путь /. соответствует паттерну блокировки" {
    # Паттерн из nginx-internal.conf: location ~ /\.
    # Проверяем что bash-regex эквивалентен
    paths_blocked=("/.env" "/.git" "/.cache" "/.htaccess" "/.gitignore")
    for p in "${paths_blocked[@]}"; do
        [[ "$p" =~ /\. ]] || {
            echo "FAIL: '$p' не соответствует паттерну /\\." >&3
            return 1
        }
    done
}

@test "nginx regex: обычные пути НЕ блокируются паттерном /\\." {
    paths_ok=("/health" "/mytoken/HAPP/JSONSUB.JSON" "/data.dat" "/token123/file.json")
    for p in "${paths_ok[@]}"; do
        if [[ "$p" =~ /\. ]]; then
            echo "FAIL: '$p' ложно заблокирован паттерном /\\." >&3
            return 1
        fi
    done
}

# =============================================================================
# 7. compose.yaml — присутствует и валиден
# =============================================================================
@test "compose.yaml: файл существует в репозитории" {
    [ -f "$REPO_ROOT/compose.yaml" ]
}

@test "compose.yaml: содержит обязательные ключи" {
    run bash -c "grep -q 'ROUTING_TOKEN' '$REPO_ROOT/compose.yaml'"
    [ "$status" -eq 0 ]
    run bash -c "grep -q 'DOMAIN' '$REPO_ROOT/compose.yaml'"
    [ "$status" -eq 0 ]
    run bash -c "grep -q 'ENABLED_CLIENTS' '$REPO_ROOT/compose.yaml'"
    [ "$status" -eq 0 ]
}

@test "compose.yaml: содержит healthcheck endpoint" {
    run bash -c "grep -q '/health' '$REPO_ROOT/compose.yaml'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 8. .env.example — присутствует и содержит обязательные переменные
# =============================================================================
@test ".env.example: файл существует" {
    [ -f "$REPO_ROOT/.env.example" ]
}

@test ".env.example: содержит ROUTING_TOKEN" {
    run bash -c "grep -q 'ROUTING_TOKEN' '$REPO_ROOT/.env.example'"
    [ "$status" -eq 0 ]
}

@test ".env.example: содержит CF Zero Trust переменные" {
    run bash -c "grep -q 'CLOUDFLARE_ZERO_TRUST' '$REPO_ROOT/.env.example'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 9. Dockerfile — существует и имеет базовую структуру
# =============================================================================
@test "Dockerfile: файл существует" {
    [ -f "$REPO_ROOT/Dockerfile" ]
}

@test "Dockerfile: содержит HEALTHCHECK инструкцию" {
    run bash -c "grep -qi 'HEALTHCHECK' '$REPO_ROOT/Dockerfile'"
    [ "$status" -eq 0 ]
}

# =============================================================================
# 10. Структура Python тестов
# =============================================================================
@test "tests/: директория содержит все ожидаемые файлы тестов" {
    [ -f "$REPO_ROOT/tests/__init__.py" ]
    [ -f "$REPO_ROOT/tests/mock_servers.py" ]
    [ -f "$REPO_ROOT/tests/test_remnawave.py" ]
    [ -f "$REPO_ROOT/tests/test_downloader.py" ]
    [ -f "$REPO_ROOT/tests/test_processors.py" ]
    [ -f "$REPO_ROOT/tests/test_config_and_security.py" ]
    [ -f "$REPO_ROOT/tests/test_property_based.py" ]
}

@test "Python: модули приложения имеют корректный синтаксис" {
    run bash -c "
        for f in app/config.py app/downloader.py app/notifier.py \
                  app/publisher.py app/remnawave.py app/main.py \
                  app/processors/base.py app/processors/happ.py app/processors/incy.py; do
            python3 -m py_compile \"$REPO_ROOT/\$f\" || exit 1
        done
    "
    [ "$status" -eq 0 ]
}

@test "install.sh: prev_cf_id и prev_cf_secret объявлены (нет unbound variable под set -u)" {
    run bash -c "grep -q 'local prev_cf_id=' '$INSTALL_SH' && grep -q 'local prev_cf_secret=' '$INSTALL_SH'"
    [ "$status" -eq 0 ]
}

@test "install.sh: функции is_port_in_use и find_free_port объявлены" {
    run bash -c "grep -q 'is_port_in_use()' '$INSTALL_SH' && grep -q 'find_free_port()' '$INSTALL_SH'"
    [ "$status" -eq 0 ]
}

@test "find_free_port: возвращает валидное число порта" {
    run bash -c "source '$INSTALL_SH' 2>/dev/null; find_free_port 8080"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^[0-9]+$ ]]
    [ "$output" -ge 8080 ]
}

@test "create_cli_shortcut: содержит проверку на непустой файл ! -s" {
    run bash -c "grep -q '! -s' '$INSTALL_SH'"
    [ "$status" -eq 0 ]
}



