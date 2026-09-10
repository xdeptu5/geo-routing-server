#!/usr/bin/env bash
# ==============================================================================
# Geo Routing Server — Скрипт установки и управления
# GitHub: https://github.com/xdeptu5/geo-routing-server
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="1.2.0"
CONFIG_RECORD="/etc/geo-routing-server.conf"
DEFAULT_INSTALL_DIR="/opt/geo-routing-server"
DOCKER_IMAGE="ghcr.io/xdeptu5/geo-routing-server:latest"

# Палитра цветов и стилей оформления
C_RESET="\033[0m"
C_BOLD="\033[1m"
C_DIM="\033[2m"
C_WHITE="\033[1;37m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"
C_BLUE="\033[1;34m"
C_GRAY="\033[38;5;244m"
C_LIGHT_GRAY="\033[38;5;250m"
C_BORDER="\033[38;5;8m"

hr() {
    local len="${1:-52}"
    echo -e "${C_BORDER}$(printf '─%.0s' $(seq 1 "$len"))${C_RESET}"
}

print_banner() {
    clear 2>/dev/null || true
    echo -e "${C_CYAN}${C_BOLD}"
    echo "  ╔══════════════════════════════════════════════════════╗"
    echo "  ║              Geo Routing Server (v${SCRIPT_VERSION})             ║"
    echo "  ║    Автономные Geo-базы и маршрутизация: Happ & Incy  ║"
    echo "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${C_RESET}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}[!] Для выполнения этой команды требуются права root.${C_RESET}"
        echo -e "    Пожалуйста, запустите: ${C_BOLD}sudo geoserver${C_RESET} или ${C_BOLD}sudo bash $0${C_RESET}"
        exit 1
    fi
}

detect_compose() {
    if docker compose version >/dev/null 2>&1; then
        echo "docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        echo "docker-compose"
    else
        echo ""
    fi
}

check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    
    local compose_cmd
    compose_cmd="$(detect_compose)"
    if [ -z "$compose_cmd" ]; then
        missing+=("docker-compose-plugin")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${C_RED}[!] Не найдены обязательные компоненты: ${missing[*]}${C_RESET}"
        echo -e "${C_YELLOW}Установите Docker и Docker Compose перед продолжением.${C_RESET}"
        exit 1
    fi
}

get_install_dir() {
    if [ -f "$CONFIG_RECORD" ]; then
        local saved_dir
        saved_dir="$(head -n 1 "$CONFIG_RECORD" 2>/dev/null | tr -d '[:space:]')"
        if [ -n "$saved_dir" ] && [ -d "$saved_dir" ]; then
            echo "$saved_dir"
            return 0
        fi
    fi
    if [ -f "./compose.yaml" ] || [ -f "./docker-compose.yml" ]; then
        pwd
        return 0
    fi
    if [ -d "/opt/stacks/geo-routing-server" ]; then
        echo "/opt/stacks/geo-routing-server"
        return 0
    fi
    echo "$DEFAULT_INSTALL_DIR"
}

save_install_dir() {
    local dir="$1"
    mkdir -p "$(dirname "$CONFIG_RECORD")"
    echo "$dir" > "$CONFIG_RECORD"
}

create_cli_shortcut() {
    local install_dir="$1"
    local bin_path="/usr/local/bin/geoserver"
    
    cat > "$bin_path" <<EOF
#!/usr/bin/env bash
exec bash "$install_dir/install.sh" "\$@"
EOF
    chmod +x "$bin_path" 2>/dev/null || true
}

get_env_val() {
    local key="$1"
    local file="$2"
    local def="${3:-}"
    if [ -f "$file" ]; then
        local val
        val=$(grep "^${key}=" "$file" 2>/dev/null | cut -d'=' -f2- | tr -d '\r' || true)
        echo "${val:-$def}"
    else
        echo "$def"
    fi
}

set_env_val() {
    local key="$1"
    local val="$2"
    local file="$3"
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$file"
    else
        echo "${key}=${val}" >> "$file"
    fi
}

delete_env_val() {
    local key="$1"
    local file="$2"
    if [ -f "$file" ]; then
        sed -i "/^${key}=/d" "$file"
    fi
}

is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":${port} " && return 0
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln 2>/dev/null | grep -q ":${port} " && return 0
    fi
    return 1
}

generate_compose_yaml() {
    local target_dir="$1"
    local docker_net="${2:-}"

    if [ -n "$docker_net" ]; then
        cat > "$target_dir/compose.yaml" <<EOF
name: geo-routing-server

services:
  geo-routing-server:
    image: ${DOCKER_IMAGE}
    container_name: geo-routing-server
    restart: unless-stopped
    env_file:
      - .env
    networks:
      - default
      - remnawave
    ports:
      - "\${HTTP_BIND:-127.0.0.1}:\${HTTP_PORT:-8080}:80"
    volumes:
      - routing_data:/app/www
      - ./.cache:/app/.cache
      - ./custom_geo:/app/custom_geo:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  routing_data:

networks:
  remnawave:
    external: true
    name: "$docker_net"
EOF
    else
        cat > "$target_dir/compose.yaml" <<EOF
name: geo-routing-server

services:
  geo-routing-server:
    image: ${DOCKER_IMAGE}
    container_name: geo-routing-server
    restart: unless-stopped
    env_file:
      - .env
    # networks:
    #   - remnawave
    ports:
      - "\${HTTP_BIND:-127.0.0.1}:\${HTTP_PORT:-8080}:80"
    volumes:
      - routing_data:/app/www
      - ./.cache:/app/.cache
      - ./custom_geo:/app/custom_geo:ro
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  routing_data:

# networks:
#   remnawave:
#     external: true
#     name: "\${DOCKER_NETWORK:-remnawave-network}"
EOF
    fi
}

get_container_status() {
    local install_dir="$1"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    if [ -n "$compose_cmd" ] && [ -f "$install_dir/compose.yaml" -o -f "$install_dir/docker-compose.yml" ]; then
        local state
        state=$( (cd "$install_dir" && $compose_cmd ps --format "{{.Status}}" 2>/dev/null | head -1) || true)
        if [ -n "$state" ]; then
            echo -e "${C_GREEN}● Работает${C_RESET} ${C_GRAY}($state)${C_RESET}"
            return
        fi
    fi
    echo -e "${C_RED}○ Остановлен${C_RESET}"
}

# ==============================================================================
# ПРЯМЫЕ КОМАНДЫ CLI (Subcommands)
# ==============================================================================

cmd_status() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"

    print_banner
    echo -e "  ${C_WHITE}Каталог:${C_RESET} $install_dir"
    echo -e "  ${C_WHITE}Статус:${C_RESET}  $(get_container_status "$install_dir")"
    echo ""

    if [ ! -f "$env_file" ]; then
        echo -e "${C_YELLOW}Файл конфигурации (.env) не найден. Выполните установку: geoserver install${C_RESET}"
        return 0
    fi

    local domain token clients port schedule
    domain="$(get_env_val "DOMAIN" "$env_file" "geo.example.com")"
    token="$(get_env_val "ROUTING_TOKEN" "$env_file" "")"
    clients="$(get_env_val "ENABLED_CLIENTS" "$env_file" "HAPP,INCY")"
    port="$(get_env_val "HTTP_PORT" "$env_file" "8080")"
    schedule="$(get_env_val "SCHEDULE" "$env_file" "0 10 * * *")"

    echo -e "${C_WHITE}📋 Параметры сервера:${C_RESET}"
    printf "   ${C_LIGHT_GRAY}%-20s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "Домен:" "https://${domain}"
    printf "   ${C_LIGHT_GRAY}%-20s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "Локальный порт:" "127.0.0.1:${port}"
    printf "   ${C_LIGHT_GRAY}%-20s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "Токен:" "${token:0:6}...${token: -4}"
    printf "   ${C_LIGHT_GRAY}%-20s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "Клиенты:" "$clients"
    printf "   ${C_LIGHT_GRAY}%-20s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "Cron расписание:" "$schedule"
    echo ""

    echo -e "${C_GREEN}${C_BOLD}🔗 Публичные ссылки для клиентов:${C_RESET}"
    hr 54

    if [[ "$clients" =~ "INCY" ]]; then
        echo -e "  ${C_CYAN}${C_BOLD}[ Incy ]${C_RESET}"
        echo -e "  • Заголовок подписки (autorouting):"
        echo -e "    ${C_WHITE}incy://autorouting/onadd/https://${domain}/${token}/INCY/JSONSUB.JSON${C_RESET}"
        echo -e "  • GeoIP база:   https://${domain}/${token}/INCY/geoip.dat"
        echo -e "  • GeoSite база: https://${domain}/${token}/INCY/geosite.dat"
        echo ""
    fi

    if [[ "$clients" =~ "HAPP" ]]; then
        echo -e "  ${C_CYAN}${C_BOLD}[ Happ ]${C_RESET}"
        echo -e "  • Диплинк правил: https://${domain}/${token}/HAPP/JSONSUB.DEEPLINK"
        echo -e "  • GeoIP база:     https://${domain}/${token}/HAPP/geoip.dat"
        echo -e "  • GeoSite база:   https://${domain}/${token}/HAPP/geosite.dat"
        echo ""
    fi

    local remna_url
    remna_url="$(get_env_val "REMNAWAVE_BASE_URL" "$env_file" "")"
    if [ -n "$remna_url" ]; then
        echo -e "  ${C_CYAN}${C_BOLD}[ Remnawave Панель ]${C_RESET}"
        echo -e "  • URL API: ${C_WHITE}$remna_url${C_RESET}"
        local i=1
        while true; do
            local sq_uuid sq_rule sq_name
            sq_uuid="$(get_env_val "REMNAWAVE_SQUAD_${i}_UUID" "$env_file" "")"
            [ -z "$sq_uuid" ] && break
            sq_rule="$(get_env_val "REMNAWAVE_SQUAD_${i}_RULE" "$env_file" "JSONSUB.JSON")"
            sq_name="$(get_env_val "REMNAWAVE_SQUAD_${i}_NAME" "$env_file" "Сквад #$i")"
            echo -e "    ✓ ${C_WHITE}${sq_name}${C_RESET} (${sq_uuid:0:8}...) → ${C_GREEN}${sq_rule}${C_RESET}"
            i=$((i + 1))
        done
        echo ""
    fi
}

cmd_sync() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    
    echo -e "\n${C_YELLOW}[*] Запуск принудительной синхронизации баз и правил...${C_RESET}"
    if (cd "$install_dir" && $compose_cmd exec -T geo-routing-server python3 -m app.main); then
        echo -e "\n${C_GREEN}[✓] Синхронизация успешно завершена!${C_RESET}\n"
    else
        echo -e "\n${C_RED}[!] Синхронизация завершилась с ошибкой. Проверьте логи: geoserver logs${C_RESET}\n"
    fi
}

cmd_logs() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    echo -e "${C_CYAN}[i] Просмотр логов в реальном времени (Ctrl+C для выхода)...${C_RESET}\n"
    (cd "$install_dir" && $compose_cmd logs -f --tail=100 geo-routing-server)
}

cmd_restart() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    echo -e "${C_YELLOW}[*] Перезапуск контейнера...${C_RESET}"
    (cd "$install_dir" && $compose_cmd restart)
    echo -e "${C_GREEN}[✓] Контейнер успешно перезапущен.${C_RESET}"
}

cmd_stop() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    (cd "$install_dir" && $compose_cmd stop)
    echo -e "${C_YELLOW}[✓] Сервис остановлен.${C_RESET}"
}

cmd_start() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    (cd "$install_dir" && $compose_cmd up -d)
    echo -e "${C_GREEN}[✓] Сервис запущен.${C_RESET}"
}

cmd_update() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    echo -e "\n${C_YELLOW}[*] Загрузка свежего Docker-образа...${C_RESET}"
    (cd "$install_dir" && $compose_cmd pull && $compose_cmd up -d)
    echo -e "${C_GREEN}[✓] Сервис успешно обновлён до последней версии.${C_RESET}\n"
}

cmd_edit() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"
    local editor="${EDITOR:-}"
    if [ -z "$editor" ]; then
        if command -v nano >/dev/null 2>&1; then
            editor="nano"
        elif command -v vi >/dev/null 2>&1; then
            editor="vi"
        fi
    fi

    if [ -z "$editor" ]; then
        echo -e "${C_RED}[!] Редактор nano или vi не найден.${C_RESET}"
        return 1
    fi

    "$editor" "$env_file"
    echo -e "\n${C_YELLOW}Применить изменения и перезапустить контейнер? [Y/n]: ${C_RESET}"
    read -r ans
    ans="${ans:-y}"
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        cmd_restart
    fi
}

cmd_proxy() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"
    local domain port
    domain="$(get_env_val "DOMAIN" "$env_file" "geo.example.com")"
    port="$(get_env_val "HTTP_PORT" "$env_file" "8080")"

    print_banner
    echo -e "${C_WHITE}📋 Конфигурация Reverse Proxy для домена ${C_CYAN}${domain}${C_RESET}\n"
    
    echo -e "${C_WHITE}${C_BOLD}1. Для Caddy (добавьте в Caddyfile):${C_RESET}"
    hr 45
    echo -e "${C_GREEN}${domain} {
    reverse_proxy 127.0.0.1:${port}
}${C_RESET}"
    echo ""

    echo -e "${C_WHITE}${C_BOLD}2. Для Nginx (внутри блока server):${C_RESET}"
    hr 45
    echo -e "${C_GREEN}location / {
    proxy_pass http://127.0.0.1:${port};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}${C_RESET}"
    echo -e "\n${C_GRAY}Готовые полные примеры доступны в репозитории: Caddyfile.example и nginx.conf.example${C_RESET}\n"
}

cmd_uninstall() {
    local install_dir
    install_dir="$(get_install_dir)"
    local compose_cmd
    compose_cmd="$(detect_compose)"

    print_banner
    echo -e "${C_RED}${C_BOLD}[!] ВНИМАНИЕ: Удаление Geo Routing Server${C_RESET}"
    echo -e "${C_GRAY}Будут остановлены контейнеры и удалены все конфигурационные файлы.${C_RESET}\n"
    read -r -p "Вы абсолютно уверены, что хотите удалить сервис? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${C_GRAY}Отмена удаления.${C_RESET}"
        return 0
    fi

    echo -e "\n${C_YELLOW}[*] Остановка сервиса и очистка томов Docker...${C_RESET}"
    if [ -d "$install_dir" ] && [ -n "$compose_cmd" ]; then
        (cd "$install_dir" && $compose_cmd down -v 2>/dev/null || true)
    fi

    rm -rf "$install_dir"
    rm -f "$CONFIG_RECORD"
    rm -f "/usr/local/bin/geoserver"

    echo -e "${C_GREEN}[✓] Geo Routing Server полностью удалён с сервера.${C_RESET}\n"
}

cmd_help() {
    echo -e "${C_BOLD}Использование:${C_RESET} geoserver [команда]"
    echo ""
    echo "Доступные команды:"
    echo "  status       Статус сервиса и ссылки на базы/диплинки"
    echo "  sync         Принудительная синхронизация баз прямо сейчас"
    echo "  logs         Просмотр логов контейнера (Ctrl+C для выхода)"
    echo "  restart      Перезапуск Docker-контейнера"
    echo "  update       Обновление Docker-образа до актуального"
    echo "  stop / start Остановка и запуск контейнера"
    echo "  config       Редактирование файла .env в редакторе"
    echo "  proxy        Сниппеты для настройки Caddy и Nginx"
    echo "  uninstall    Полное удаление сервиса с сервера"
    echo ""
    echo "Вызов ${C_BOLD}geoserver${C_RESET} без аргументов открывает интерактивную панель управления."
}

# ==============================================================================
# МОДУЛЬНЫЕ НАСТРОЙКИ (В СТИЛЕ DIGNENZZZ)
# ==============================================================================

menu_remnawave() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"

    while true; do
        print_banner
        echo -e "  ${C_WHITE}Раздел:${C_RESET} ⚡ Управление сквадами Remnawave"
        hr 50
        echo ""

        local remna_url remna_token
        remna_url="$(get_env_val "REMNAWAVE_BASE_URL" "$env_file" "")"
        remna_token="$(get_env_val "REMNAWAVE_TOKEN" "$env_file" "")"

        if [ -z "$remna_url" ]; then
            echo -e "${C_YELLOW}Интеграция с Remnawave пока не настроена.${C_RESET}\n"
            echo "  1) Подключить панель Remnawave (URL и API Token)"
            echo "  0) ⬅️ Назад"
            echo ""
            read -r -p "Выберите действие [0-1]: " choice
            case "$choice" in
                1)
                    read -r -p "URL API панели [Enter = http://remnawave:3000/api]: " input_url
                    remna_url="${input_url:-http://remnawave:3000/api}"
                    read -r -p "JWT токен администратора: " remna_token
                    set_env_val "REMNAWAVE_BASE_URL" "$remna_url" "$env_file"
                    set_env_val "REMNAWAVE_TOKEN" "$remna_token" "$env_file"
                    echo -e "${C_GREEN}[✓] Подключение сохранено!${C_RESET}"
                    sleep 1
                    ;;
                *) return 0 ;;
            esac
            continue
        fi

        echo -e "${C_WHITE}📋 Подключение к панели:${C_RESET}"
        printf "   ${C_LIGHT_GRAY}%-15s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "URL API:" "$remna_url"
        printf "   ${C_LIGHT_GRAY}%-15s${C_RESET} ${C_WHITE}%s${C_RESET}\n" "API Token:" "${remna_token:0:6}...${remna_token: -4} (${#remna_token} симв.)"
        echo ""

        echo -e "${C_WHITE}📋 Текущие привязки сквадов:${C_RESET}"
        local count=0
        local i=1
        while true; do
            local sq_uuid sq_rule sq_name
            sq_uuid="$(get_env_val "REMNAWAVE_SQUAD_${i}_UUID" "$env_file" "")"
            [ -z "$sq_uuid" ] && break
            sq_rule="$(get_env_val "REMNAWAVE_SQUAD_${i}_RULE" "$env_file" "JSONSUB.JSON")"
            sq_name="$(get_env_val "REMNAWAVE_SQUAD_${i}_NAME" "$env_file" "Сквад #$i")"
            echo -e "   ${C_WHITE}${i})${C_RESET} ${sq_name} (${C_GRAY}${sq_uuid:0:8}...${C_RESET}) → ${C_GREEN}${sq_rule}${C_RESET}"
            count=$i
            i=$((i + 1))
        done

        if [ "$count" -eq 0 ]; then
            echo -e "   ${C_GRAY}(нет привязанных сквадов)${C_RESET}"
        fi
        echo ""

        echo -e "${C_WHITE}⚙️ Действия:${C_RESET}"
        echo "   1) 🔄 Синхронизировать список сквадов через Remnawave API"
        echo "   2) ✏️ Изменить правило для конкретного сквада"
        echo "   3) ➕ Добавить сквад вручную (по UUID)"
        echo "   4) ❌ Удалить привязку сквада"
        echo "   5) 🔑 Изменить URL или API Token панели"
        echo "   6) 🛡️ Отключить интеграцию с Remnawave"
        echo "   0) ⬅️ Назад"
        echo ""
        read -r -p "Выберите опцию [0-6]: " choice

        case "$choice" in
            1)
                echo -e "\n${C_YELLOW}[*] Запрос списка внешних сквадов из Remnawave API...${C_RESET}"
                local cf_id cf_sec
                cf_id="$(get_env_val "CLOUDFLARE_ZERO_TRUST_CLIENT_ID" "$env_file" "")"
                cf_sec="$(get_env_val "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET" "$env_file" "")"
                
                local curl_args=(-fsSL --max-time 10 -H "Authorization: Bearer $remna_token")
                if [ -n "$cf_id" ] && [ -n "$cf_sec" ]; then
                    curl_args+=(-H "CF-Access-Client-Id: $cf_id" -H "CF-Access-Client-Secret: $cf_sec")
                fi

                local api_resp
                api_resp=$(curl "${curl_args[@]}" "${remna_url%/}/external-squads" 2>/dev/null || true)
                if [ -z "$api_resp" ]; then
                    echo -e "${C_RED}[!] Не удалось получить ответ от API Remnawave. Проверьте URL и токен.${C_RESET}"
                    read -r -p "Нажмите Enter для продолжения..."
                    continue
                fi

                # Парсинг сквадов
                local squad_lines=()
                while IFS= read -r line; do
                    [ -n "$line" ] && squad_lines+=("$line")
                done < <(python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    items = data.get("response", data) if isinstance(data, dict) else data
    if isinstance(items, list):
        for s in items:
            uuid = s.get("uuid", "")
            name = s.get("name", "External Squad")
            if uuid:
                print(f"{uuid}\t{name}")
except Exception:
    pass
' <<< "$api_resp" 2>/dev/null || true)

                if [ ${#squad_lines[@]} -eq 0 ]; then
                    echo -e "${C_YELLOW}[i] Внешние сквады (External Squads) не найдены в панели.${C_RESET}"
                    read -r -p "Нажмите Enter для продолжения..."
                    continue
                fi

                echo -e "\n${C_GREEN}Найдено ${#squad_lines[@]} внешних сквадов в панели:${C_RESET}"
                local idx=1
                for s in "${squad_lines[@]}"; do
                    local u n
                    u=$(echo "$s" | cut -f1)
                    n=$(echo "$s" | cut -f2)
                    echo "  $idx) $n (${u:0:8}...)"
                    idx=$((idx + 1))
                done

                echo ""
                read -r -p "Привязать сквад по номеру [1-${#squad_lines[@]}, Enter для отмены]: " pick_sq
                if [ -n "$pick_sq" ] && [ "$pick_sq" -ge 1 ] && [ "$pick_sq" -le "${#squad_lines[@]}" ] 2>/dev/null; then
                    local sel_line="${squad_lines[$((pick_sq - 1))]}"
                    local sel_uuid sel_name
                    sel_uuid=$(echo "$sel_line" | cut -f1)
                    sel_name=$(echo "$sel_line" | cut -f2)

                    echo -e "\nВыберите правило для сквада ${C_WHITE}$sel_name${C_RESET}:"
                    echo "  1) JSONSUB.JSON (маршрут подписок)"
                    echo "  2) WHITELIST.JSON (белый список)"
                    echo "  3) DEFAULT.JSON"
                    read -r -p "Номер правила [1-3, Enter = 1]: " r_choice
                    local sel_rule="JSONSUB.JSON"
                    [ "$r_choice" = "2" ] && sel_rule="WHITELIST.JSON"
                    [ "$r_choice" = "3" ] && sel_rule="DEFAULT.JSON"

                    local new_idx=$((count + 1))
                    set_env_val "REMNAWAVE_SQUAD_${new_idx}_UUID" "$sel_uuid" "$env_file"
                    set_env_val "REMNAWAVE_SQUAD_${new_idx}_RULE" "$sel_rule" "$env_file"
                    set_env_val "REMNAWAVE_SQUAD_${new_idx}_NAME" "$sel_name" "$env_file"
                    echo -e "${C_GREEN}[✓] Сквад успешно привязан!${C_RESET}"
                    (cd "$install_dir" && $(detect_compose) restart >/dev/null 2>&1 || true)
                    sleep 1
                fi
                ;;
            2)
                # Точечное изменение правила для конкретного сквада — РЕШЕНИЕ ПРОБЛЕМЫ LTE!
                if [ "$count" -eq 0 ]; then
                    echo -e "${C_YELLOW}Нет сквадов для редактирования.${C_RESET}"
                    sleep 1
                    continue
                fi
                read -r -p "Введите номер сквада [1-$count, Enter = отмена]: " pick_num
                if [ -n "$pick_num" ] && [ "$pick_num" -ge 1 ] && [ "$pick_num" -le "$count" ] 2>/dev/null; then
                    local cur_r cur_n
                    cur_r="$(get_env_val "REMNAWAVE_SQUAD_${pick_num}_RULE" "$env_file" "JSONSUB.JSON")"
                    cur_n="$(get_env_val "REMNAWAVE_SQUAD_${pick_num}_NAME" "$env_file" "Сквад #$pick_num")"

                    echo -e "\nТекущее правило для ${C_WHITE}$cur_n${C_RESET}: ${C_GREEN}$cur_r${C_RESET}"
                    echo "Выберите новое правило:"
                    echo "  1) JSONSUB.JSON"
                    echo "  2) WHITELIST.JSON"
                    echo "  3) DEFAULT.JSON"
                    read -r -p "Номер [1-3, Enter = оставить $cur_r]: " new_r_opt
                    local new_rule="$cur_r"
                    [ "$new_r_opt" = "1" ] && new_rule="JSONSUB.JSON"
                    [ "$new_r_opt" = "2" ] && new_rule="WHITELIST.JSON"
                    [ "$new_r_opt" = "3" ] && new_rule="DEFAULT.JSON"

                    set_env_val "REMNAWAVE_SQUAD_${pick_num}_RULE" "$new_rule" "$env_file"
                    echo -e "${C_GREEN}[✓] Правило для '$cur_n' изменено на: $new_rule${C_RESET}"
                    (cd "$install_dir" && $(detect_compose) restart >/dev/null 2>&1 || true)
                    sleep 1
                fi
                ;;
            3)
                read -r -p "Введите UUID сквада из Remnawave: " new_uuid
                if [ -n "$new_uuid" ]; then
                    read -r -p "Название сквада (для себя): " new_name
                    new_name="${new_name:-Сквад}"
                    echo "Выберите правило:"
                    echo "  1) JSONSUB.JSON"
                    echo "  2) WHITELIST.JSON"
                    read -r -p "Номер [1-2, Enter = 1]: " r_opt
                    local r_val="JSONSUB.JSON"
                    [ "$r_opt" = "2" ] && r_val="WHITELIST.JSON"

                    local n_idx=$((count + 1))
                    set_env_val "REMNAWAVE_SQUAD_${n_idx}_UUID" "$new_uuid" "$env_file"
                    set_env_val "REMNAWAVE_SQUAD_${n_idx}_RULE" "$r_val" "$env_file"
                    set_env_val "REMNAWAVE_SQUAD_${n_idx}_NAME" "$new_name" "$env_file"
                    echo -e "${C_GREEN}[✓] Сквад добавлен.${C_RESET}"
                    (cd "$install_dir" && $(detect_compose) restart >/dev/null 2>&1 || true)
                    sleep 1
                fi
                ;;
            4)
                if [ "$count" -eq 0 ]; then continue; fi
                read -r -p "Введите номер сквада для удаления [1-$count, Enter = отмена]: " del_num
                if [ -n "$del_num" ] && [ "$del_num" -ge 1 ] && [ "$del_num" -le "$count" ] 2>/dev/null; then
                    delete_env_val "REMNAWAVE_SQUAD_${del_num}_UUID" "$env_file"
                    delete_env_val "REMNAWAVE_SQUAD_${del_num}_RULE" "$env_file"
                    delete_env_val "REMNAWAVE_SQUAD_${del_num}_NAME" "$env_file"
                    echo -e "${C_GREEN}[✓] Привязка сквада удалена.${C_RESET}"
                    sleep 1
                fi
                ;;
            5)
                read -r -p "Новый URL API [Enter = $remna_url]: " new_url
                new_url="${new_url:-$remna_url}"
                read -r -p "Новый JWT токен [Enter = оставить текущий]: " new_token
                new_token="${new_token:-$remna_token}"
                set_env_val "REMNAWAVE_BASE_URL" "$new_url" "$env_file"
                set_env_val "REMNAWAVE_TOKEN" "$new_token" "$env_file"
                echo -e "${C_GREEN}[✓] Параметры API обновлены.${C_RESET}"
                sleep 1
                ;;
            6)
                read -r -p "Вы уверены, что хотите отключить Remnawave? [y/N]: " conf_dis
                if [[ "$conf_dis" =~ ^[Yy]$ ]]; then
                    delete_env_val "REMNAWAVE_BASE_URL" "$env_file"
                    delete_env_val "REMNAWAVE_TOKEN" "$env_file"
                    echo -e "${C_YELLOW}[✓] Интеграция с Remnawave отключена.${C_RESET}"
                    sleep 1
                fi
                ;;
            0) return 0 ;;
        esac
    done
}

menu_schedule() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"
    local cur_schedule
    cur_schedule="$(get_env_val "SCHEDULE" "$env_file" "0 10 * * *")"

    while true; do
        print_banner
        echo -e "  ${C_WHITE}Раздел:${C_RESET} ⏰ Расписание автоматической синхронизации"
        hr 50
        echo ""
        echo -e "  ${C_WHITE}Текущее расписание:${C_RESET} ${C_GREEN}${cur_schedule}${C_RESET}"
        echo ""
        echo "  1) Раз в сутки в 10:00 UTC (13:00 МСК)"
        echo "  2) Раз в сутки в 12:00 UTC (15:00 МСК)"
        echo "  3) Каждые 6 часов (4 раза в день)"
        echo "  4) Каждые 12 часов (2 раза в день)"
        echo "  5) Ввести своё cron-выражение вручную"
        echo "  0) ⬅️ Назад"
        echo ""
        read -r -p "Выберите опцию [0-5]: " choice

        local new_sched=""
        case "$choice" in
            1) new_sched="0 10 * * *" ;;
            2) new_sched="0 12 * * *" ;;
            3) new_sched="0 */6 * * *" ;;
            4) new_sched="0 */12 * * *" ;;
            5)
                read -r -p "Введите cron-выражение [например: 0 12 * * *]: " input_sched
                new_sched="${input_sched:-$cur_schedule}"
                ;;
            0) return 0 ;;
            *) continue ;;
        esac

        if [ -n "$new_sched" ]; then
            set_env_val "SCHEDULE" "$new_sched" "$env_file"
            echo -e "\n${C_GREEN}[✓] Расписание сохранено: $new_sched${C_RESET}"
            (cd "$install_dir" && $(detect_compose) up -d >/dev/null 2>&1 || true)
            sleep 1
            return 0
        fi
    done
}

menu_telegram() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"

    while true; do
        print_banner
        echo -e "  ${C_WHITE}Раздел:${C_RESET} 🤖 Telegram-уведомления"
        hr 50
        echo ""

        local tg_token tg_chat tg_thread tg_notify
        tg_token="$(get_env_val "TELEGRAM_BOT_TOKEN" "$env_file" "")"
        tg_chat="$(get_env_val "TELEGRAM_CHAT_ID" "$env_file" "")"
        tg_thread="$(get_env_val "TELEGRAM_THREAD_ID" "$env_file" "")"
        tg_notify="$(get_env_val "TELEGRAM_NOTIFY_SUCCESS" "$env_file" "false")"

        if [ -n "$tg_token" ] && [ -n "$tg_chat" ]; then
            echo -e "  ${C_WHITE}Статус:${C_RESET}    ${C_GREEN}● Включены${C_RESET}"
            echo -e "  ${C_WHITE}Chat ID:${C_RESET}   $tg_chat"
            [ -n "$tg_thread" ] && echo -e "  ${C_WHITE}Топик ID:${C_RESET}  $tg_thread"
            echo -e "  ${C_WHITE}Отчёты:${C_RESET}    $([ "$tg_notify" = "true" ] && echo "Все (включая успешные)" || echo "Только при ошибках")"
            echo ""
            echo "  1) 🔔 Отправить тестовое сообщение в Telegram"
            echo "  2) ✏️ Изменить Bot Token / Chat ID"
            echo "  3) 🔕 Переключить отчёты об успешных синхронизациях"
            echo "  4) ❌ Отключить Telegram-уведомления"
            echo "  0) ⬅️ Назад"
        else
            echo -e "  ${C_WHITE}Статус:${C_RESET}    ${C_GRAY}○ Отключены${C_RESET}\n"
            echo "  1) 🔔 Настроить Telegram-уведомления"
            echo "  0) ⬅️ Назад"
        fi
        echo ""
        read -r -p "Выберите опцию: " choice

        case "$choice" in
            1)
                if [ -n "$tg_token" ]; then
                    echo -e "\n${C_YELLOW}[*] Отправка тестового сообщения в Telegram...${C_RESET}"
                    local text="🔔 Тестовое уведомление от Geo Routing Server (${HOSTNAME:-VPS})"
                    local url="https://api.telegram.org/bot${tg_token}/sendMessage"
                    local data="chat_id=${tg_chat}&text=${text}"
                    [ -n "$tg_thread" ] && data="${data}&message_thread_id=${tg_thread}"
                    local resp
                    resp=$(curl -s -X POST "$url" -d "$data" || true)
                    if echo "$resp" | grep -q '"ok":true'; then
                        echo -e "${C_GREEN}[✓] Сообщение успешно доставлено в Telegram!${C_RESET}"
                    else
                        echo -e "${C_RED}[!] Ошибка отправки: $resp${C_RESET}"
                    fi
                    read -r -p "Нажмите Enter для продолжения..."
                else
                    read -r -p "Bot Token (от @BotFather): " input_token
                    read -r -p "Chat ID: " input_chat
                    read -r -p "Thread ID (ID темы/топика, если есть, иначе Enter): " input_thread
                    if [ -n "$input_token" ] && [ -n "$input_chat" ]; then
                        set_env_val "TELEGRAM_BOT_TOKEN" "$input_token" "$env_file"
                        set_env_val "TELEGRAM_CHAT_ID" "$input_chat" "$env_file"
                        [ -n "$input_thread" ] && set_env_val "TELEGRAM_THREAD_ID" "$input_thread" "$env_file"
                        echo -e "${C_GREEN}[✓] Telegram настроен!${C_RESET}"
                        (cd "$install_dir" && $(detect_compose) up -d >/dev/null 2>&1 || true)
                        sleep 1
                    fi
                fi
                ;;
            2)
                read -r -p "Новый Bot Token [Enter = оставить]: " new_tok
                read -r -p "Новый Chat ID [Enter = оставить]: " new_c
                read -r -p "Новый Thread ID [Enter = оставить]: " new_th
                [ -n "$new_tok" ] && set_env_val "TELEGRAM_BOT_TOKEN" "$new_tok" "$env_file"
                [ -n "$new_c" ] && set_env_val "TELEGRAM_CHAT_ID" "$new_c" "$env_file"
                [ -n "$new_th" ] && set_env_val "TELEGRAM_THREAD_ID" "$new_th" "$env_file"
                echo -e "${C_GREEN}[✓] Настройки обновлены.${C_RESET}"
                sleep 1
                ;;
            3)
                local toggled="true"
                [ "$tg_notify" = "true" ] && toggled="false"
                set_env_val "TELEGRAM_NOTIFY_SUCCESS" "$toggled" "$env_file"
                echo -e "${C_GREEN}[✓] Уведомления об успехе: $toggled${C_RESET}"
                sleep 1
                ;;
            4)
                delete_env_val "TELEGRAM_BOT_TOKEN" "$env_file"
                delete_env_val "TELEGRAM_CHAT_ID" "$env_file"
                delete_env_val "TELEGRAM_THREAD_ID" "$env_file"
                echo -e "${C_YELLOW}[✓] Telegram-уведомления отключены.${C_RESET}"
                sleep 1
                ;;
            0) return 0 ;;
        esac
    done
}

menu_clients_bases() {
    local install_dir
    install_dir="$(get_install_dir)"
    local env_file="$install_dir/.env"

    while true; do
        print_banner
        echo -e "  ${C_WHITE}Раздел:${C_RESET} 🌐 Клиенты и Geo-базы"
        hr 50
        echo ""

        local cur_clients cur_geoip cur_geosite cur_rules ext_geo
        cur_clients="$(get_env_val "ENABLED_CLIENTS" "$env_file" "HAPP,INCY")"
        cur_geoip="$(get_env_val "SERVE_GEOIP" "$env_file" "true")"
        cur_geosite="$(get_env_val "SERVE_GEOSITE" "$env_file" "true")"
        cur_rules="$(get_env_val "ROUTING_RULES" "$env_file" "JSONSUB,WHITELIST")"
        ext_geo="$(get_env_val "PUBLIC_GEO_BASE_URL" "$env_file" "")"

        echo -e "  ${C_WHITE}Клиенты:${C_RESET}      ${C_GREEN}$cur_clients${C_RESET}"
        echo -e "  ${C_WHITE}Раздача GeoIP:${C_RESET}   $cur_geoip"
        echo -e "  ${C_WHITE}Раздача GeoSite:${C_RESET} $cur_geosite"
        echo -e "  ${C_WHITE}Список правил:${C_RESET}   $cur_rules"
        echo -e "  ${C_WHITE}Внешние базы:${C_RESET}    ${ext_geo:-локальная раздача (с этого сервера)}"
        echo ""

        echo "  1) Выбрать клиентов (HAPP и INCY / Только HAPP / Только INCY)"
        echo "  2) Включить / выключить отдачу geoip.dat"
        echo "  3) Включить / выключить отдачу geosite.dat"
        echo "  4) Настроить внешний URL баз (PUBLIC_GEO_BASE_URL)"
        echo "  0) ⬅️ Назад"
        echo ""
        read -r -p "Выберите опцию [0-4]: " choice

        case "$choice" in
            1)
                echo ""
                echo "  1) HAPP и INCY (Оба клиента)"
                echo "  2) Только HAPP"
                echo "  3) Только INCY"
                echo "  4) HAPP_DEEPLINK (только апдейтер сквадов Remnawave, базы внешние)"
                read -r -p "Номер [1-4]: " c_opt
                case "$c_opt" in
                    1) set_env_val "ENABLED_CLIENTS" "HAPP,INCY" "$env_file" ;;
                    2) set_env_val "ENABLED_CLIENTS" "HAPP" "$env_file" ;;
                    3) set_env_val "ENABLED_CLIENTS" "INCY" "$env_file" ;;
                    4) set_env_val "ENABLED_CLIENTS" "HAPP_DEEPLINK" "$env_file" ;;
                esac
                echo -e "${C_GREEN}[✓] Сохранено.${C_RESET}"
                sleep 1
                ;;
            2)
                local tog_g="true"
                [ "$cur_geoip" = "true" ] && tog_g="false"
                set_env_val "SERVE_GEOIP" "$tog_g" "$env_file"
                echo -e "${C_GREEN}[✓] SERVE_GEOIP=$tog_g${C_RESET}"
                sleep 1
                ;;
            3)
                local tog_s="true"
                [ "$cur_geosite" = "true" ] && tog_s="false"
                set_env_val "SERVE_GEOSITE" "$tog_s" "$env_file"
                echo -e "${C_GREEN}[✓] SERVE_GEOSITE=$tog_s${C_RESET}"
                sleep 1
                ;;
            4)
                echo -e "${C_GRAY}Если базы отдаются с другого сервера, укажите базовый URL (или Enter чтобы очистить):${C_RESET}"
                read -r -p "URL [Enter = локальные базы]: " in_ext
                if [ -n "$in_ext" ]; then
                    set_env_val "PUBLIC_GEO_BASE_URL" "$in_ext" "$env_file"
                else
                    delete_env_val "PUBLIC_GEO_BASE_URL" "$env_file"
                fi
                echo -e "${C_GREEN}[✓] Сохранено.${C_RESET}"
                sleep 1
                ;;
            0) return 0 ;;
        esac
    done
}

# ==============================================================================
# ПЕРВИЧНАЯ УСТАНОВКА (Быстрый опрос в 4 шага)
# ==============================================================================

wizard_install() {
    print_banner
    check_root
    check_dependencies

    echo -e "${C_WHITE}${C_BOLD}Первоначальная быстрая настройка${C_RESET}\n"

    local default_dir
    default_dir="$(get_install_dir)"
    echo -e "${C_CYAN}[1/5] Каталог установки${C_RESET}"
    read -r -p "      Путь [Enter = ${default_dir}]: " input_dir
    local install_dir="${input_dir:-$default_dir}"
    mkdir -p "$install_dir"
    save_install_dir "$install_dir"

    echo -e "\n${C_CYAN}[2/5] Публичный домен сервера${C_RESET}"
    echo -e "      ${C_GRAY}Домен с настроенным HTTPS или внешний IP-адрес${C_RESET}"
    read -r -p "      Домен [например, geo.example.com]: " input_domain
    local domain="${input_domain:-geo.example.com}"
    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"

    local gen_token
    gen_token="$(openssl rand -hex 16 2>/dev/null || date +%s | md5sum | head -c 24)"
    echo -e "\n${C_CYAN}[3/5] Секретный URL-токен доступа${C_RESET}"
    read -r -p "      Токен [Enter = сгенерировать $gen_token]: " input_token
    local token="${input_token:-$gen_token}"

    echo -e "\n${C_CYAN}[4/5] Поддерживаемые клиенты${C_RESET}"
    echo "      1) Happ и Incy (Рекомендуется)"
    echo "      2) Только Happ"
    echo "      3) Только Incy"
    read -r -p "      Выберите вариант [1-3, Enter = 1]: " client_ans
    local clients="HAPP,INCY"
    case "${client_ans:-1}" in
        2) clients="HAPP" ;;
        3) clients="INCY" ;;
        *) clients="HAPP,INCY" ;;
    esac

    echo -e "\n${C_CYAN}[5/5] Локальный HTTP-порт${C_RESET}"
    read -r -p "      Порт для реверс-прокси [Enter = 8080]: " input_port
    local port="${input_port:-8080}"
    if is_port_in_use "$port"; then
        echo -e "      ${C_YELLOW}[!] Внимание: порт $port уже занят на сервере.${C_RESET}"
    fi

    # Опциональный опрос Remnawave
    local remna_url="" remna_token="" remna_net=""
    echo ""
    read -r -p "Настроить интеграцию с Remnawave прямо сейчас? [y/N]: " r_ans
    if [[ "${r_ans:-n}" =~ ^[Yy]$ ]]; then
        read -r -p "  ▸ URL API панели [Enter = http://remnawave:3000/api]: " input_r_url
        remna_url="${input_r_url:-http://remnawave:3000/api}"
        read -r -p "  ▸ JWT токен администратора Remnawave: " remna_token
        read -r -p "  ▸ Имя внешней Docker-сети [Enter = пропустить]: " remna_net
    fi

    # Генерация .env
    echo -e "\n${C_YELLOW}[*] Сохранение конфигурации в $install_dir/.env...${C_RESET}"
    cat > "$install_dir/.env" <<EOF
# ==============================================================================
# GEO ROUTING SERVER CONFIGURATION
# ==============================================================================
DOMAIN=${domain}
ROUTING_TOKEN=${token}
ENABLED_CLIENTS=${clients}
ROUTING_RULES=JSONSUB,WHITELIST
SERVE_FORMATS=CLIENT_OPTIMIZED
SERVE_GEOIP=true
SERVE_GEOSITE=true

HTTP_BIND=127.0.0.1
HTTP_PORT=${port}
SCHEDULE=0 10 * * *
SYNC_ON_START=true
EOF

    if [ -n "$remna_url" ] && [ -n "$remna_token" ]; then
        cat >> "$install_dir/.env" <<EOF

# Remnawave API Integration
REMNAWAVE_BASE_URL=${remna_url}
REMNAWAVE_TOKEN=${remna_token}
EOF
        if [ -n "$remna_net" ]; then
            echo "DOCKER_NETWORK=${remna_net}" >> "$install_dir/.env"
        fi
    fi

    chmod 600 "$install_dir/.env"

    # Создание compose.yaml
    echo -e "${C_YELLOW}[*] Создание compose.yaml...${C_RESET}"
    generate_compose_yaml "$install_dir" "$remna_net"

    # Сохранение скрипта и CLI ссылки
    cp "$0" "$install_dir/install.sh" 2>/dev/null || true
    chmod +x "$install_dir/install.sh" 2>/dev/null || true
    create_cli_shortcut "$install_dir"

    # Запуск
    local compose_cmd
    compose_cmd="$(detect_compose)"
    echo -e "${C_YELLOW}[*] Запуск сервиса через $compose_cmd...${C_RESET}"
    (cd "$install_dir" && $compose_cmd pull && $compose_cmd up -d)

    echo -e "\n${C_GREEN}${C_BOLD}══════════════════════════════════════════════════════${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}  Geo Routing Server успешно установлен и запущен!   ${C_RESET}"
    echo -e "${C_GREEN}${C_BOLD}══════════════════════════════════════════════════════${C_RESET}\n"

    cmd_status
    cmd_proxy

    echo -e "${C_CYAN}💡 Для управления сервером используйте команду: ${C_BOLD}geoserver${C_RESET}\n"
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

main_menu() {
    while true; do
        local install_dir
        install_dir="$(get_install_dir)"
        local env_file="$install_dir/.env"

        print_banner
        echo -e "  ${C_WHITE}Каталог:${C_RESET} $install_dir"
        echo -e "  ${C_WHITE}Статус:${C_RESET}  $(get_container_status "$install_dir")"
        hr 54
        echo ""
        echo "  1) 📊 Статус сервиса и ссылки для клиентов"
        echo "  2) 🔄 Запустить синхронизацию баз прямо сейчас"
        echo "  3) 📜 Логи контейнера (docker logs)"
        echo "  4) ⚡ Настройка сквадов Remnawave"
        echo "  5) ⏰ Расписание автообновления (Cron)"
        echo "  6) 🤖 Telegram-уведомления"
        echo "  7) 🌐 Клиенты, форматы и Geo-базы"
        echo "  8) 📋 Сниппеты Caddy / Nginx"
        echo "  9) 🚀 Обновить Docker-образ (pull & up)"
        echo " 10) 🔄 Перезапустить контейнер"
        echo " 11) 📝 Редактировать .env напрямую"
        echo " 12) ❌ Удалить сервис (Uninstall)"
        echo "  0) 🚪 Выход"
        echo ""
        read -r -p "  Выберите действие [0-12]: " choice

        case "$choice" in
            1) cmd_status; echo ""; read -r -p "Нажмите Enter для продолжения..." ;;
            2) cmd_sync; echo ""; read -r -p "Нажмите Enter для продолжения..." ;;
            3) cmd_logs ;;
            4) menu_remnawave ;;
            5) menu_schedule ;;
            6) menu_telegram ;;
            7) menu_clients_bases ;;
            8) cmd_proxy; echo ""; read -r -p "Нажмите Enter для продолжения..." ;;
            9) cmd_update; echo ""; read -r -p "Нажмите Enter для продолжения..." ;;
            10) cmd_restart; echo ""; read -r -p "Нажмите Enter для продолжения..." ;;
            11) cmd_edit ;;
            12) cmd_uninstall; exit 0 ;;
            0|q|exit) clear 2>/dev/null || true; exit 0 ;;
            *) sleep 0.5 ;;
        esac
    done
}

# ==============================================================================
# ТОЧКА ВХОДА
# ==============================================================================

main() {
    local cmd="${1:-}"
    case "$cmd" in
        status|info)       cmd_status ;;
        sync)              cmd_sync ;;
        logs)              cmd_logs ;;
        restart)           cmd_restart ;;
        stop)              cmd_stop ;;
        start)             cmd_start ;;
        update)            cmd_update ;;
        proxy)             cmd_proxy ;;
        edit|config)       cmd_edit ;;
        uninstall)         cmd_uninstall ;;
        install|setup)     wizard_install ;;
        help|-h|--help)    cmd_help ;;
        "")
            local dir
            dir="$(get_install_dir)"
            if [ -f "$dir/.env" ] && [ -f "$dir/compose.yaml" -o -f "$dir/docker-compose.yml" ]; then
                main_menu
            else
                wizard_install
            fi
            ;;
        *)
            echo -e "${C_RED}Неизвестная команда: $cmd${C_RESET}\n"
            cmd_help
            exit 1
            ;;
    esac
}

main "$@"
