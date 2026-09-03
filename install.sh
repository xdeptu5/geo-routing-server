#!/usr/bin/env bash
# ==============================================================================
# Geo Routing Server — Интерактивный установщик и менеджер управления
# GitHub: https://github.com/xdeptu5/geo-routing-server
# ==============================================================================

set -euo pipefail

# Цвета для терминала
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CONFIG_FILE_RECORD="/etc/geo-routing-server.conf"
LANG_RECORD="/etc/geo-routing-server.lang"
UI_LANG=""

handle_error() {
    local code=$?
    local line=$1
    [ "$code" -eq 0 ] && return
    trap '' ERR

    echo -e "\n${RED}${BOLD}===============================================================================${NC}"
    if [ "${UI_LANG:-ru}" = "en" ]; then
        echo -e "${RED}[!] An error occurred during execution (exit code $code, line $line).${NC}"
        echo -e "${YELLOW}What would you like to do?${NC}"
        echo "  1) Open management menu (geoserver)"
        echo "  2) Start installation again from scratch (clean files)"
        echo "  3) Completely uninstall project from server"
        echo "  4) Exit to shell"
        read -r -p "Select option [1-4, Enter = 1]: " err_choice
    else
        echo -e "${RED}[!] Произошла ошибка во время выполнения (код $code, строка $line).${NC}"
        echo -e "${YELLOW}Что вы хотите сделать?${NC}"
        echo "  1) Открыть главное меню управления (geoserver)"
        echo "  2) Начать настройку заново (с чистого листа)"
        echo "  3) Полностью удалить проект с сервера"
        echo "  4) Выйти в терминал"
        read -r -p "Выберите вариант [1-4, Enter = 1]: " err_choice
    fi
    err_choice="${err_choice:-1}"
    case "$err_choice" in
        1) 
            trap 'handle_error $LINENO' ERR
            main_menu 
            ;;
        2) 
            local target_dir
            target_dir="$(get_install_dir)"
            if [ -n "$target_dir" ] && [ "$target_dir" != "/" ] && [ "$target_dir" != "/root" ] && [ -d "$target_dir" ]; then
                rm -rf "$target_dir" 2>/dev/null || true
            fi
            trap 'handle_error $LINENO' ERR
            install_wizard
            ;;
        3) uninstall_project ;;
        *) exit "$code" ;;
    esac
}

trap 'handle_error $LINENO' ERR

detect_or_ask_language() {
    for arg in "$@"; do
        if [ "$arg" = "--lang=en" ] || [ "$arg" = "--en" ]; then
            UI_LANG="en"
            echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
            return
        elif [ "$arg" = "--lang=ru" ] || [ "$arg" = "--ru" ]; then
            UI_LANG="ru"
            echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
            return
        fi
    done

    if [ -f "$LANG_RECORD" ]; then
        UI_LANG="$(cat "$LANG_RECORD" 2>/dev/null | tr -d '[:space:]')"
    fi
    
    if [ -z "${UI_LANG:-}" ]; then
        echo -e "\n${BOLD}Language / Выберите язык:${NC}"
        echo -e "  1) Русский (RU) [Enter]"
        echo -e "  2) English (EN)"
        read -r -p "> " lang_choice
        if [ "$lang_choice" = "2" ] || [[ "$lang_choice" =~ ^[Ee][Nn]$ ]]; then
            UI_LANG="en"
        else
            UI_LANG="ru"
        fi
        echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
    fi
}

print_header() {
    clear || true
    echo -e "${CYAN}${BOLD}"
    echo "==============================================================================="
    echo "                      * GEO ROUTING SERVER MANAGER                            "
    echo "==============================================================================="
    echo -e "${NC}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}[!] Ошибка: Запустите скрипт с правами root или через sudo!${NC}"
        exit 1
    fi
}

check_dependencies() {
    echo -e "${BLUE}[*] Проверка системных зависимостей...${NC}"
    
    for cmd in curl openssl; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${YELLOW}[!] Утилита $cmd не найдена, устанавливаем...${NC}"
            if command -v apt-get &> /dev/null; then
                apt-get update -y && apt-get install -y "$cmd"
            elif command -v yum &> /dev/null; then
                yum install -y "$cmd"
            elif command -v apk &> /dev/null; then
                apk add --no-cache "$cmd"
            fi
        fi
    done

    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}[!] Docker не установлен! Установить официальный Docker автоматически? [Y/n]${NC}"
        read -r -p "> " install_docker
        install_docker=${install_docker:-Y}
        if [[ "$install_docker" =~ ^[YyДд]$ ]]; then
            echo -e "${BLUE}[*] Установка Docker...${NC}"
            curl -fsSL https://get.docker.com | sh
            systemctl enable --now docker || true
        else
            echo -e "${RED}[!] Для работы сервера необходим Docker. Прерывание установки.${NC}"
            exit 1
        fi
    fi

    if ! docker compose version &> /dev/null; then
        echo -e "${RED}[!] Ошибка: Плагин 'docker compose' не найден. Обновите Docker.${NC}"
        exit 1
    fi

    echo -e "${GREEN}[+] Все зависимости готовы к работе.${NC}\n"
}

is_port_in_use() {
    local port="$1"
    if command -v ss &>/dev/null; then
        ss -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    elif command -v netstat &>/dev/null; then
        netstat -tuln 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" && return 0
    elif command -v lsof &>/dev/null; then
        lsof -iTCP:"${port}" -sTCP:LISTEN -P -n &>/dev/null && return 0
    fi
    return 1
}

find_free_port() {
    local p="${1:-8080}"
    while is_port_in_use "$p"; do
        p=$((p + 1))
    done
    echo "$p"
}

# Поиск существующей установки по Docker или конфигурационным файлам
detect_existing_dir() {
    if [ -f "$CONFIG_FILE_RECORD" ]; then
        local saved_dir
        saved_dir="$(cat "$CONFIG_FILE_RECORD" | tr -d '[:space:]')"
        if [ -n "$saved_dir" ] && [ -d "$saved_dir" ] && [ -f "$saved_dir/compose.yaml" ]; then
            echo "$saved_dir"
            return
        fi
    fi

    # Проверяем, запущен ли контейнер в Docker и где лежит его compose
    if command -v docker &>/dev/null; then
        local docker_workdir
        docker_workdir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' geo-routing-server 2>/dev/null || true)"
        if [ -n "$docker_workdir" ] && [ -d "$docker_workdir" ] && [ -f "$docker_workdir/compose.yaml" ]; then
            save_install_dir "$docker_workdir"
            echo "$docker_workdir"
            return
        fi
    fi

    # Проверяем стандартную папку
    if [ -f "/opt/geo-routing-server/compose.yaml" ]; then
        save_install_dir "/opt/geo-routing-server"
        echo "/opt/geo-routing-server"
        return
    fi

    echo ""
}

get_install_dir() {
    local detected
    detected="$(detect_existing_dir)"
    if [ -n "$detected" ]; then
        echo "$detected"
    elif [ -f "$CONFIG_FILE_RECORD" ]; then
        cat "$CONFIG_FILE_RECORD" | tr -d '[:space:]'
    else
        echo "/opt/geo-routing-server"
    fi
}

save_install_dir() {
    echo "$1" > "$CONFIG_FILE_RECORD"
}

create_cli_shortcut() {
    local target_dir="$1"
    local wrapper_script="/usr/local/bin/geo-server"
    
    cat > "$wrapper_script" <<EOF
#!/usr/bin/env bash
TARGET_SCRIPT="$target_dir/install.sh"
if [ ! -s "\$TARGET_SCRIPT" ]; then
    mkdir -p "$target_dir"
    curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "\$TARGET_SCRIPT" 2>/dev/null || true
    chmod +x "\$TARGET_SCRIPT" 2>/dev/null || true
fi
bash "\$TARGET_SCRIPT" "\$@"
EOF
    chmod +x "$wrapper_script"
    
    ln -sf "$wrapper_script" /usr/bin/geo-server 2>/dev/null || true
    ln -sf "$wrapper_script" /usr/local/bin/geoserver 2>/dev/null || true
    ln -sf "$wrapper_script" /usr/bin/geoserver 2>/dev/null || true
}

run_sync_now() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Запуск принудительной синхронизации баз...${NC}"
    docker exec geo-routing-server run-routing-sync || {
        echo -e "${RED}[!] Ошибка запуска синхронизации. Проверьте запущен ли контейнер: docker compose ps${NC}"
    }
    echo ""
    read -r -p "Нажмите Enter для продолжения..."
}

show_links() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${GREEN}${BOLD}[i] Публичные ссылки и интеграции:${NC}"
    docker exec geo-routing-server python3 -c "
from app.config import Config
from app.main import print_summary_banner
print_summary_banner(Config.get_token())
" || {
        echo -e "${YELLOW}[!] Не удалось получить ссылки напрямую из контейнера. Проверьте логи: docker compose logs${NC}"
    }
    echo -e "\n${DIM}💎 Поддержать проект / Donations: https://github.com/xdeptu5/geo-routing-server#-%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D0%BF%D1%80%D0%BE%D0%B5%D0%BA%D1%82-donations${NC}\n"
    read -r -p "Нажмите Enter для продолжения..."
}

show_proxy_snippets() {
    local target_dir
    target_dir="$(get_install_dir)"
    local env_file="$target_dir/.env"

    local domain="geo.example.com"
    local port="8080"
    local clients="HAPP,INCY"

    if [ -f "$env_file" ]; then
        domain=$(grep "^DOMAIN=" "$env_file" | cut -d'=' -f2- || echo "geo.example.com")
        port=$(grep "^HTTP_PORT=" "$env_file" | cut -d'=' -f2- || echo "8080")
        clients=$(grep "^ENABLED_CLIENTS=" "$env_file" | cut -d'=' -f2- || echo "HAPP,INCY")
    fi

    if [ "$clients" = "HAPP_DEEPLINK" ] || [ "$clients" = "HAPP_LOCAL" ]; then
        echo -e "${GREEN}${BOLD}[i] Режим «Только генератор для Remnawave»: сервер работает локально внутри Docker-сети.${NC}"
        echo -e "Настройка внешнего реверс-прокси не требуется, если вы не планируете открывать сервер наружу.\n"
        return 0
    fi

    echo -e "${CYAN}${BOLD}===============================================================================${NC}"
    echo -e "${YELLOW}${BOLD}  ГОТОВЫЕ КОНФИГУРАЦИИ ДЛЯ ВАШЕГО РЕВЕРС-ПРОКСИ (HTTPS)${NC}"
    echo -e "${CYAN}${BOLD}===============================================================================${NC}"
    echo -e "Чтобы ссылки стали доступны по безопасному HTTPS, добавьте один из блоков:\n"

    echo -e "${GREEN}${BOLD}[ ВАРИАНТ 1: CADDY ]${NC} (добавьте в /etc/caddy/Caddyfile):"
    echo -e "${CYAN}-------------------------------------------------------------------------------${NC}"
    echo -e "${BOLD}${domain} {${NC}"
    echo -e "    ${BOLD}reverse_proxy 127.0.0.1:${port}${NC}"
    echo -e "${BOLD}}${NC}"
    echo -e "${CYAN}-------------------------------------------------------------------------------${NC}"
    echo -e "После сохранения примените: ${YELLOW}sudo systemctl reload caddy${NC}\n"

    echo -e "${GREEN}${BOLD}[ ВАРИАНТ 2: NGINX ]${NC} (в конфигурацию вашего сайта с SSL):"
    echo -e "${CYAN}-------------------------------------------------------------------------------${NC}"
    echo -e "${BOLD}server {${NC}"
    echo -e "    ${BOLD}server_name ${domain};${NC}\n"
    echo -e "    ${BOLD}location / {${NC}"
    echo -e "        ${BOLD}proxy_pass http://127.0.0.1:${port};${NC}"
    echo -e "        ${BOLD}proxy_set_header Host \$host;${NC}"
    echo -e "        ${BOLD}proxy_set_header X-Real-IP \$remote_addr;${NC}"
    echo -e "        ${BOLD}proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;${NC}"
    echo -e "        ${BOLD}proxy_set_header X-Forwarded-Proto \$scheme;${NC}"
    echo -e "    ${BOLD}}${NC}"
    echo -e "${BOLD}}${NC}"
    echo -e "${CYAN}-------------------------------------------------------------------------------${NC}"
    echo -e "После сохранения примените: ${YELLOW}sudo nginx -t && sudo nginx -s reload${NC}\n"

    echo -e "${GREEN}${BOLD}[ ВАРИАНТ 3: NGINX PROXY MANAGER (GUI) ]${NC}:"
    echo -e "Forward Hostname / IP: ${BOLD}127.0.0.1${NC}"
    echo -e "Forward Port:          ${BOLD}${port}${NC}"
    echo -e "SSL:                   ${BOLD}Request a new SSL Certificate (Force SSL: ON)${NC}"
    echo -e "${CYAN}===============================================================================${NC}\n"
}

configure_remnawave() {
    local target_dir
    target_dir="$(get_install_dir)"
    local env_file="$target_dir/.env"

    print_header
    echo -e "${BOLD}[>] Прямая интеграция с Remnawave API (без сторонних сервисов)${NC}\n"

    local current_base=""
    local current_token=""
    local current_clients=""
    if [ -f "$env_file" ]; then
        current_base=$(grep "^REMNAWAVE_BASE_URL=" "$env_file" | cut -d'=' -f2- || true)
        current_token=$(grep "^REMNAWAVE_TOKEN=" "$env_file" | cut -d'=' -f2- || true)
        current_clients=$(grep "^ENABLED_CLIENTS=" "$env_file" | cut -d'=' -f2- || echo "HAPP,INCY")
        if [[ ! "$current_clients" =~ HAPP ]]; then
            echo -e "${YELLOW}[!] Сервер сейчас настроен только для Incy (ENABLED_CLIENTS=${current_clients}).${NC}"
            echo -e "${GREEN}[*] Автоматически добавляем Happ в список клиентов для генерации правил...${NC}\n"
            sed -i "s/^ENABLED_CLIENTS=.*/ENABLED_CLIENTS=${current_clients},HAPP/" "$env_file"
        fi
    fi

    read -r -p "REMNAWAVE_BASE_URL [Enter = ${current_base:-http://remnawave:3000/api}]: " input_base
    input_base="${input_base:-${current_base:-http://remnawave:3000/api}}"

    local r_token_hint="пропустить"
    [ -n "$current_token" ] && r_token_hint="оставить текущий"
    read -r -p "REMNAWAVE_TOKEN (JWT токен панели) [Enter = $r_token_hint]: " input_token
    input_token="${input_token:-$current_token}"

    local existing_squads=0
    if [ -f "$env_file" ]; then
        existing_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$env_file" || true)
    fi
    local default_squads="${existing_squads:-1}"
    [ "$default_squads" -le 0 ] && default_squads=1
    read -r -p "Сколько сквадов хотите привязать? [1-10, Enter = $default_squads]: " count_squads
    count_squads="${count_squads:-$default_squads}"

    echo -e "\n${CYAN}${BOLD}[i] Источник правил маршрутизации:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}"
    echo -e "${DIM}Сервер берет готовые правила из папки HAPP этого репозитория.${NC}"
    echo -e "Доступные варианты правил:"
    echo -e "  ${BOLD}1) JSONSUB.JSON${NC}   — Обход блокировок ${DIM}(сайты из реестра РКН через VPN, остальные напрямую)${NC} [Рекомендуется]"
    echo -e "  ${BOLD}2) WHITELIST.JSON${NC} — Белый список ${DIM}(весь интернет через VPN, кроме незаблокированных сервисов РФ)${NC}"
    echo -e "  ${BOLD}3) DEFAULT.JSON${NC}   — Базовое стандартное правило"
    echo -e "  ${DIM}(или введите имя любого другого .JSON файла из репозитория)${NC}"

    local squads_env=""
    for ((i=1; i<=count_squads; i++)); do
        local prev_sq_uuid=""
        local prev_sq_rule=""
        if [ -f "$env_file" ]; then
            prev_sq_uuid=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$env_file" | cut -d'=' -f2- || true)
            prev_sq_rule=$(grep "^REMNAWAVE_SQUAD_${i}_RULE=" "$env_file" | cut -d'=' -f2- || true)
        fi
        echo -e "\n${CYAN}--- Настройка Сквада #$i ---${NC}"
        local sq_hint="из панели Remnawave → Сквады"
        [ -n "$prev_sq_uuid" ] && sq_hint="Enter = оставить $prev_sq_uuid"
        read -r -p "UUID сквада $i [$sq_hint]: " sq_uuid
        sq_uuid="${sq_uuid:-$prev_sq_uuid}"

        echo -e "  Правило маршрутизации для сквада $i:"
        echo -e "    ${BOLD}1)${NC} Обход блокировок (JSONSUB.JSON) — сайты из реестра РКН через VPN, остальные напрямую [Enter]"
        echo -e "    ${BOLD}2)${NC} Белый список (WHITELIST.JSON)  — весь интернет через VPN, кроме РФ"
        echo -e "    ${BOLD}3)${NC} Свой файл из репозитория       — указать нестандартный .json"
        read -r -p "  Выберите [1-3, Enter = 1]: " rule_pick
        rule_pick="${rule_pick:-1}"
        local sq_rule="${prev_sq_rule:-JSONSUB.JSON}"
        case "$rule_pick" in
            2) sq_rule="WHITELIST.JSON" ;;
            3)
                read -r -p "  Введите имя файла [например, DEFAULT.JSON]: " custom_rule
                custom_rule="${custom_rule:-JSONSUB.JSON}"
                if [[ ! "$custom_rule" =~ \.[Jj][Ss][Oo][Nn]$ ]]; then
                    custom_rule="${custom_rule}.JSON"
                fi
                sq_rule="$(echo "$custom_rule" | tr '[:lower:]' '[:upper:]')"
                ;;
            *) sq_rule="${prev_sq_rule:-JSONSUB.JSON}" ;;
        esac
        squads_env="${squads_env}REMNAWAVE_SQUAD_${i}_UUID=${sq_uuid}
REMNAWAVE_SQUAD_${i}_RULE=${sq_rule}
"
    done

    local current_cf_id=""
    local current_cf_secret=""
    if [ -f "$env_file" ]; then
        current_cf_id=$(grep "^CLOUDFLARE_ZERO_TRUST_CLIENT_ID=" "$env_file" | cut -d'=' -f2- || true)
        current_cf_secret=$(grep "^CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=" "$env_file" | cut -d'=' -f2- || true)
    fi

    local cf_prompt="y/N"
    [ -n "$current_cf_id" ] && cf_prompt="Y/n"
    echo -e "\n${CYAN}Опционально: если Remnawave защищена Cloudflare Zero Trust (Service Token):${NC}"
    read -r -p "Использовать Cloudflare Zero Trust для подключения к панели? [$cf_prompt]: " cf_choice
    if [ -n "$current_cf_id" ]; then
        cf_choice="${cf_choice:-Y}"
    else
        cf_choice="${cf_choice:-N}"
    fi

    local cf_env=""
    if [[ "$cf_choice" =~ ^[YyДд]$ ]]; then
        read -r -p "CLOUDFLARE_ZERO_TRUST_CLIENT_ID [Enter = ${current_cf_id:-пропустить}]: " input_cf_id
        input_cf_id="${input_cf_id:-$current_cf_id}"

        read -r -p "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET [Enter = ${current_cf_secret:-пропустить}]: " input_cf_secret
        input_cf_secret="${input_cf_secret:-$current_cf_secret}"

        if [ -n "$input_cf_id" ] && [ -n "$input_cf_secret" ]; then
            cf_env="CLOUDFLARE_ZERO_TRUST_CLIENT_ID=${input_cf_id}
CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=${input_cf_secret}
"
        fi
    elif [ -n "$current_cf_id" ] && [ -n "$current_cf_secret" ]; then
        cf_env="CLOUDFLARE_ZERO_TRUST_CLIENT_ID=${current_cf_id}
CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=${current_cf_secret}
"
    fi

    # Удаляем старые записи из .env и сохраняем новые
    if [ -f "$env_file" ]; then
        sed -i '/^REMNAWAVE_/d' "$env_file"
        sed -i '/^CLOUDFLARE_ZERO_TRUST_/d' "$env_file"
        cat >> "$env_file" <<EOF
REMNAWAVE_BASE_URL=${input_base}
REMNAWAVE_TOKEN=${input_token}
${cf_env}${squads_env}
EOF
        echo -e "\n${GREEN}[+] Настройки Remnawave сохранены! Перезапускаем контейнер...${NC}"
        cd "$target_dir"
        docker compose up -d
        local remna_net="remnawave-network"
        if docker network inspect "$remna_net" &>/dev/null; then
            if ! docker inspect geo-routing-server --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q "$remna_net"; then
                docker network connect "$remna_net" geo-routing-server 2>/dev/null || true
            fi
        fi
        docker exec geo-routing-server run-routing-sync 2>/dev/null || true
        echo -e "${GREEN}[+] Готово! Правила обновлены и отправлены в Remnawave.${NC}\n"
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

update_script_only() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Скачивание последней версии скрипта управления из GitHub...${NC}"
    
    if curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$target_dir/install.sh.new" 2>/dev/null; then
        mv "$target_dir/install.sh.new" "$target_dir/install.sh"
        chmod +x "$target_dir/install.sh"
        create_cli_shortcut "$target_dir"
        echo -e "${GREEN}[+] Скрипт управления (меню и CLI) успешно обновлён!${NC}\n"
    else
        echo -e "${RED}[!] Не удалось загрузить скрипт. Проверьте интернет-соединение.${NC}\n"
    fi
    read -r -p "Нажмите Enter для перезапуска меню..."
    exec bash "$target_dir/install.sh"
}

update_project() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Обновление Docker-образа сервера до последней версии...${NC}"
    
    # Также обновляем сам скрипт
    if curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$target_dir/install.sh.new" 2>/dev/null; then
        mv "$target_dir/install.sh.new" "$target_dir/install.sh"
        chmod +x "$target_dir/install.sh"
        create_cli_shortcut "$target_dir"
    fi

    cd "$target_dir"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}[+] Контейнер и скрипт успешно обновлены до последней версии!${NC}\n"
    read -r -p "Нажмите Enter для перезапуска меню..."
    exec bash "$target_dir/install.sh"
}

view_logs() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Просмотр последних логов (Ctrl+C для выхода):${NC}\n"
    cd "$target_dir"
    docker compose logs -f --tail 100
}

restart_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}[*] Перезапуск контейнера...${NC}"
    docker compose restart
    echo -e "${GREEN}[+] Контейнер успешно перезапущен.${NC}\n"
    read -r -p "Нажмите Enter для продолжения..."
}

stop_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}[*] Остановка контейнера...${NC}"
    docker compose down
    echo -e "${GREEN}[+] Контейнер остановлен.${NC}\n"
    read -r -p "Нажмите Enter для продолжения..."
}

test_telegram() {
    local bot_token="$1"
    local chat_id="$2"
    local thread_id="${3:-}"

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        echo -e "${RED}[!] Ошибка: Токен бота или Chat ID не заданы!${NC}"
        return 1
    fi

    echo -e "${BLUE}[*] Отправка тестового сообщения в Telegram...${NC}"
    local data_params=(
        -d "chat_id=${chat_id}"
        -d "text=<b>[Geo Routing Server]</b> Тестовое уведомление успешно доставлено!"
        -d "parse_mode=HTML"
    )

    if [ -n "$thread_id" ]; then
        data_params+=(-d "message_thread_id=${thread_id}")
    fi

    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" "${data_params[@]}" || true)
    
    if echo "$response" | grep -q '"ok":true'; then
        echo -e "${GREEN}[+] Тестовое сообщение успешно получено в Telegram!${NC}"
        return 0
    else
        echo -e "${RED}[!] Ошибка отправки: $response${NC}"
        return 1
    fi
}

configure_telegram() {
    local target_dir
    target_dir="$(get_install_dir)"
    local env_file="$target_dir/.env"

    print_header
    echo -e "${BOLD}[>] Настройка Telegram-уведомлений${NC}\n"

    local current_token=""
    local current_chat=""
    local current_thread=""
    local current_notify="false"

    if [ -f "$env_file" ]; then
        current_token=$(grep "^TELEGRAM_BOT_TOKEN=" "$env_file" | cut -d'=' -f2- || true)
        current_chat=$(grep "^TELEGRAM_CHAT_ID=" "$env_file" | cut -d'=' -f2- || true)
        current_thread=$(grep "^TELEGRAM_THREAD_ID=" "$env_file" | cut -d'=' -f2- || true)
        current_notify=$(grep "^TELEGRAM_NOTIFY_SUCCESS=" "$env_file" | cut -d'=' -f2- || true)
    fi

    echo -e "Текущий BOT_TOKEN:  ${CYAN}${current_token:-не задан}${NC}"
    echo -e "Текущий CHAT_ID:    ${CYAN}${current_chat:-не задан}${NC}"
    echo -e "Текущий THREAD_ID:  ${CYAN}${current_thread:-не задан (основной чат)}${NC}"
    echo -e "Уведомлять при выходе новых баз: ${CYAN}${current_notify:-false}${NC}\n"

    local tg_token_hint="пропустить"
    [ -n "$current_token" ] && tg_token_hint="оставить текущий"
    read -r -p "Введите TELEGRAM_BOT_TOKEN [Enter = $tg_token_hint]: " input_token
    input_token="${input_token:-$current_token}"

    local tg_chat_hint="пропустить"
    [ -n "$current_chat" ] && tg_chat_hint="оставить текущий"
    read -r -p "Введите TELEGRAM_CHAT_ID [Enter = $tg_chat_hint]: " input_chat
    input_chat="${input_chat:-$current_chat}"

    read -r -p "Введите TELEGRAM_THREAD_ID (ID темы/топика, если есть) [Enter = ${current_thread:-нет}]: " input_thread
    input_thread="${input_thread:-$current_thread}"

    read -r -p "Присылать уведомление при выходе новых баз? [y/N]: " input_notify
    if [[ "$input_notify" =~ ^[YyДд]$ ]]; then
        input_notify="true"
    else
        input_notify="false"
    fi

    if [ -n "$input_token" ] && [ -n "$input_chat" ]; then
        test_telegram "$input_token" "$input_chat" "$input_thread" || true
    fi

    if [ -f "$env_file" ]; then
        sed -i '/^TELEGRAM_BOT_TOKEN=/d' "$env_file"
        sed -i '/^TELEGRAM_CHAT_ID=/d' "$env_file"
        sed -i '/^TELEGRAM_THREAD_ID=/d' "$env_file"
        sed -i '/^TELEGRAM_NOTIFY_SUCCESS=/d' "$env_file"
        
        cat >> "$env_file" <<EOF
TELEGRAM_BOT_TOKEN=${input_token}
TELEGRAM_CHAT_ID=${input_chat}
TELEGRAM_THREAD_ID=${input_thread}
TELEGRAM_NOTIFY_SUCCESS=${input_notify}
EOF
        echo -e "\n${GREEN}[+] Настройки Telegram сохранены в .env!${NC}"
        echo -e "${YELLOW}[*] Перезапускаем контейнер для применения настроек...${NC}"
        cd "$target_dir"
        docker compose up -d
        echo -e "${GREEN}[+] Контейнер перезапущен с новыми параметрами.${NC}\n"
    else
        echo -e "${RED}[!] Файл .env не найден в $target_dir${NC}"
    fi

    read -r -p "Нажмите Enter для продолжения..."
}

uninstall_project() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${RED}${BOLD}[!] ВНИМАНИЕ: Вы действительно хотите удалить Geo Routing Server? [y/N]${NC}"
    if [ -n "$target_dir" ]; then
        echo -e "${DIM}Будут удалены: контейнер, тома данных, каталог $target_dir и команда geo-server.${NC}"
    fi
    read -r -p "> " confirm
    if [[ "$confirm" =~ ^[YyДд]$ ]]; then
        echo -e "${YELLOW}[*] Остановка и удаление контейнеров...${NC}"
        if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
            (cd "$target_dir" && docker compose down -v --remove-orphans 2>/dev/null) || true
        fi
        # Принудительное удаление контейнера на случай, если compose.yaml был поврежден
        docker rm -f geo-routing-server 2>/dev/null || true

        # Безопасное удаление каталога проекта
        if [ -n "$target_dir" ] && [ "$target_dir" != "/" ] && [ "$target_dir" != "/root" ] && [ "$target_dir" != "/home" ] && [ -d "$target_dir" ]; then
            rm -rf "$target_dir"
        fi

        rm -f "$CONFIG_FILE_RECORD" "$LANG_RECORD"
        rm -f /usr/local/bin/geo-server /usr/bin/geo-server /usr/local/bin/geoserver /usr/bin/geoserver
        echo -e "${GREEN}[+] Проект полностью удалён с сервера.${NC}"
        exit 0
    else
        echo "Удаление отменено."
        sleep 1
    fi
}

# ==============================================================================
# МАСТЕР УСТАНОВКИ / ПЕРЕКОНФИГУРАЦИИ
# ==============================================================================

install_wizard() {
    print_header
    check_root
    check_dependencies

    local existing_detected
    existing_detected="$(detect_existing_dir)"
    local current_suggested_dir="${existing_detected:-/opt/geo-routing-server}"

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 1: Каталог установки
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Шаг 1] Каталог установки ---${NC}"
    if [ -n "$existing_detected" ]; then
        echo -e "${YELLOW}[i] Обнаружена существующая установка в: ${BOLD}$existing_detected${NC}"
        echo -e "Вы можете обновить конфигурацию в этой же папке или выбрать новую."
    else
        echo -e "Укажите папку для проекта. ${DIM}Подходит любая: /opt/, стеки Arcane, Portainer, Dockge, 1Panel и др.${NC}"
    fi
    
    read -r -p "Каталог [Enter = $current_suggested_dir]: " input_dir
    input_dir="$(echo "$input_dir" | tr -d '\r' | sed 's/[^a-zA-Z0-9_\/\.-]//g')"
    INSTALL_DIR="${input_dir:-$current_suggested_dir}"
    INSTALL_DIR="$(echo "$INSTALL_DIR" | tr -d '\r' | sed 's/[^a-zA-Z0-9_\/\.-]//g')"
    mkdir -p "$INSTALL_DIR"
    save_install_dir "$INSTALL_DIR"
    echo -e "${GREEN}[+] Каталог: $INSTALL_DIR${NC}\n"

    # Считываем текущие настройки из существующего .env (в целевой папке или ранее обнаруженной)
    local prev_domain="geo.example.com"
    local prev_token=""
    local prev_clients="HAPP,INCY"
    local prev_port="8080"
    local prev_remna_base="http://remnawave:3000/api"
    local prev_remna_token=""
    local prev_tg_token=""
    local prev_tg_chat=""
    local prev_tg_thread=""
    local prev_tg_notify="false"
    local prev_public_geo=""
    local prev_cf_id=""
    local prev_cf_secret=""
    local prev_routing_repo="https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main"
    local prev_schedule="0 10 * * *"

    local scan_env=""
    if [ -f "$INSTALL_DIR/.env" ]; then
        scan_env="$INSTALL_DIR/.env"
    elif [ -n "$existing_detected" ] && [ -f "$existing_detected/.env" ]; then
        scan_env="$existing_detected/.env"
    fi

    if [ -n "$scan_env" ]; then
        echo -e "${CYAN}[i] Найдены существующие настройки ($scan_env) — они будут предложены по умолчанию.${NC}\n"
        prev_domain="$(grep "^DOMAIN=" "$scan_env" | cut -d'=' -f2- || echo "$prev_domain")"
        prev_token="$(grep "^ROUTING_TOKEN=" "$scan_env" | cut -d'=' -f2- || echo "$prev_token")"
        prev_clients="$(grep "^ENABLED_CLIENTS=" "$scan_env" | cut -d'=' -f2- || echo "$prev_clients")"
        prev_port="$(grep "^HTTP_PORT=" "$scan_env" | cut -d'=' -f2- || echo "$prev_port")"
        prev_remna_base="$(grep "^REMNAWAVE_BASE_URL=" "$scan_env" | cut -d'=' -f2- || echo "$prev_remna_base")"
        prev_remna_token="$(grep "^REMNAWAVE_TOKEN=" "$scan_env" | cut -d'=' -f2- || echo "$prev_remna_token")"
        prev_tg_token="$(grep "^TELEGRAM_BOT_TOKEN=" "$scan_env" | cut -d'=' -f2- || echo "$prev_tg_token")"
        prev_tg_chat="$(grep "^TELEGRAM_CHAT_ID=" "$scan_env" | cut -d'=' -f2- || echo "$prev_tg_chat")"
        prev_tg_thread="$(grep "^TELEGRAM_THREAD_ID=" "$scan_env" | cut -d'=' -f2- || echo "$prev_tg_thread")"
        prev_tg_notify="$(grep "^TELEGRAM_NOTIFY_SUCCESS=" "$scan_env" | cut -d'=' -f2- || echo "$prev_tg_notify")"
        prev_public_geo="$(grep "^PUBLIC_GEO_BASE_URL=" "$scan_env" | cut -d'=' -f2- || echo "$prev_public_geo")"
        prev_cf_id="$(grep "^CLOUDFLARE_ZERO_TRUST_CLIENT_ID=" "$scan_env" | cut -d'=' -f2- || true)"
        prev_cf_secret="$(grep "^CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=" "$scan_env" | cut -d'=' -f2- || true)"
        prev_routing_repo="$(grep "^ROUTING_SOURCE_REPO=" "$scan_env" | cut -d'=' -f2- || echo "$prev_routing_repo")"
        prev_schedule="$(grep "^SCHEDULE=" "$scan_env" | cut -d'=' -f2- || echo "$prev_schedule")"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 2: Выбор сценария работы сервера
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Шаг 2] Выберите сценарий работы сервера ---${NC}"
    echo -e "${CYAN}${BOLD}[i] Источник правил:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}\n"
    echo -e "  ${BOLD}1)${NC} Всё в одном (раздача баз и правил + автопатч Remnawave API) [Enter — Рекомендуется]"
    echo -e "     ${DIM}Раздает базы и правила по HTTPS + сам отправляет правила в API сквадов Remnawave.${NC}"
    echo ""
    echo -e "  ${BOLD}2)${NC} Сервер раздачи баз и правил (Pull-модель для любых панелей и клиентов)"
    echo -e "     ${DIM}Раздает базы geoip/geosite, диплинки Happ и JSON для Incy с вашего домена.${NC}"
    echo -e "     ${DIM}Подходит для Remnawave, Marzban, 3x-ui. API-токен панели серверу не нужен.${NC}"
    echo ""
    echo -e "  ${BOLD}3)${NC} Только узел раздачи geo-баз (чистые файлы geoip.dat и geosite.dat)"
    echo -e "     ${DIM}Сервер только раздает базы по HTTPS (например, быстрый узел в РФ). Без правил и Remnawave.${NC}"
    echo ""
    echo -e "  ${BOLD}4)${NC} Только апдейтер сквадов Remnawave (домен на этой машине НЕ нужен)"
    echo -e "     ${DIM}Базы уже на другом сервере (или GitHub). Сервер работает локально в Docker${NC}"
    echo -e "     ${DIM}и только отправляет правила в API Remnawave.${NC}"
    echo ""
    echo -e "  ${BOLD}5)${NC} Раздача JSON для Incy (базы на внешнем сервере)"
    echo -e "     ${DIM}Сервер раздает только JSON подписки для Incy, а базы скачиваются с внешнего узла.${NC}"
    echo ""
    read -r -p "Выберите вариант [1-5, Enter = 1]: " server_role
    server_role="${server_role:-1}"

    PUBLIC_GEO_BASE_URL=""
    ROUTING_SOURCE_REPO="$prev_routing_repo"
    NEEDS_PUBLIC_DOMAIN=true
    local config_remna=false

    case "$server_role" in
        2)
            echo -e "\n${BOLD}Для каких приложений готовить правила?${NC}"
            echo -e "  ${BOLD}1)${NC} Happ и Incy (Оба) [Enter]"
            echo -e "  ${BOLD}2)${NC} Только Happ"
            echo -e "  ${BOLD}3)${NC} Только Incy"
            read -r -p "Выберите [1-3, Enter = 1]: " app_pick
            app_pick="${app_pick:-1}"
            case "$app_pick" in
                2) ENABLED_CLIENTS="HAPP" ;;
                3) ENABLED_CLIENTS="INCY" ;;
                *) ENABLED_CLIENTS="HAPP,INCY" ;;
            esac
            NEEDS_PUBLIC_DOMAIN=true
            config_remna=false
            ;;
        3)
            echo -e "\n${BOLD}Для каких приложений раздавать базы?${NC}"
            echo -e "  ${BOLD}1)${NC} Happ и Incy (Оба) [Enter]"
            echo -e "  ${BOLD}2)${NC} Только Happ"
            echo -e "  ${BOLD}3)${NC} Только Incy"
            read -r -p "Выберите [1-3, Enter = 1]: " app_pick
            app_pick="${app_pick:-1}"
            case "$app_pick" in
                2) ENABLED_CLIENTS="HAPP_GEO" ;;
                3) ENABLED_CLIENTS="INCY_GEO" ;;
                *) ENABLED_CLIENTS="HAPP_GEO,INCY_GEO" ;;
            esac
            NEEDS_PUBLIC_DOMAIN=true
            config_remna=false
            ;;
        4)
            ENABLED_CLIENTS="HAPP_DEEPLINK"
            NEEDS_PUBLIC_DOMAIN=false
            config_remna=true
            ;;
        5)
            ENABLED_CLIENTS="INCY"
            NEEDS_PUBLIC_DOMAIN=true
            config_remna=false
            ;;
        *)
            echo -e "\n${BOLD}Для каких приложений готовить правила?${NC}"
            echo -e "  ${BOLD}1)${NC} Happ и Incy (Оба) [Enter]"
            echo -e "  ${BOLD}2)${NC} Только Happ"
            echo -e "  ${BOLD}3)${NC} Только Incy"
            read -r -p "Выберите [1-3, Enter = 1]: " app_pick
            app_pick="${app_pick:-1}"
            case "$app_pick" in
                2) ENABLED_CLIENTS="HAPP" ;;
                3) ENABLED_CLIENTS="INCY" ;;
                *) ENABLED_CLIENTS="HAPP,INCY" ;;
            esac
            NEEDS_PUBLIC_DOMAIN=true
            config_remna=true
            ;;
    esac
    echo -e "${GREEN}[+] Режим: $ENABLED_CLIENTS${NC}\n"

    # Если базы на внешнем сервере (варианты 4 и 5)
    if [ "$server_role" = "4" ] || [ "$server_role" = "5" ]; then
        echo -e "${BOLD}--- Адрес внешнего сервера с базами ---${NC}"
        echo -e "${DIM}Пример: https://geo.example.com/секретный_токен${NC}"
        echo -e "${DIM}Сервер автоматически подставит путь /HAPP/ или /INCY/ для каждого клиента.${NC}\n"

        while true; do
            read -r -p "URL к базам [Enter = ${prev_public_geo:-обязательно}]: " input_geo_url
            PUBLIC_GEO_BASE_URL="${input_geo_url:-$prev_public_geo}"
            PUBLIC_GEO_BASE_URL="$(echo "$PUBLIC_GEO_BASE_URL" | sed 's:/*$::')"
            if [[ "$PUBLIC_GEO_BASE_URL" =~ ^https?:// ]]; then
                break
            fi
            echo -e "${RED}[!] URL должен начинаться с https:// (например: https://geo.example.com/секретный_токен)${NC}"
        done
        echo -e "${GREEN}[+] Базы берутся с: $PUBLIC_GEO_BASE_URL${NC}\n"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 3: Публичный домен и токен (если нужен домен)
    # ────────────────────────────────────────────────────────────────────────
    DOMAIN="local"
    ROUTING_TOKEN="local"
    HTTP_PORT="8080"

    if [ "$NEEDS_PUBLIC_DOMAIN" = true ]; then
        echo -e "${BOLD}--- [Шаг 3] Публичный домен для HTTPS ---${NC}"
        echo -e "${DIM}Домен, на который вы направите реверс-прокси (Caddy / Nginx / NPM).${NC}"
        read -r -p "Введите домен [Enter = ${prev_domain:-geo.example.com}]: " input_domain
        DOMAIN="${input_domain:-${prev_domain:-geo.example.com}}"
        DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]' | sed -e 's~^https\?://~~' -e 's~/*$~~')"
        echo -e "${GREEN}[+] Домен: $DOMAIN${NC}\n"

        # ШАГ 4: Токен
        echo -e "${BOLD}--- [Шаг 4] Секретный URL-токен ---${NC}"
        echo -e "${DIM}Токен — секретная часть URL, которая защищает ваши файлы от сканеров.${NC}"
        
        local auto_token
        if [ -n "$prev_token" ] && [ "$prev_token" != "local" ]; then
            auto_token="$prev_token"
            echo -e "Используется токен: ${CYAN}${BOLD}${auto_token}${NC}"
        else
            auto_token="$(openssl rand -hex 16)"
            echo -e "Сгенерирован случайный токен: ${CYAN}${BOLD}${auto_token}${NC}"
        fi
        
        read -r -p "Введите свой токен или нажмите Enter для подтверждения: " input_token
        ROUTING_TOKEN="${input_token:-$auto_token}"
        ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        while [[ ! "$ROUTING_TOKEN" =~ ^[A-Za-z0-9._-]+$ ]]; do
            echo -e "${RED}[!] Токен может содержать только латинские буквы, цифры, точку, дефис и подчеркивание!${NC}"
            read -r -p "Введите корректный токен [Enter = ${auto_token}]: " input_token
            ROUTING_TOKEN="${input_token:-$auto_token}"
            ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        done
        echo -e "${GREEN}[+] Токен сохранён.${NC}"
        echo -e "${CYAN}${BOLD}[i] Базовый URL сервера:${NC} ${CYAN}https://${DOMAIN}/${ROUTING_TOKEN}${NC}"
        echo -e "${DIM}    • Путь для Happ: /HAPP/ (geoip.dat, geosite.dat)${NC}"
        echo -e "${DIM}    • Путь для Incy: /INCY/ (geoip.dat, geosite.dat, JSONSUB.JSON)${NC}\n"

        # ШАГ 5: Локальный порт
        echo -e "${BOLD}--- [Шаг 5] Локальный порт веб-сервера ---${NC}"
        echo -e "${DIM}На этот порт ваш реверс-прокси будет перенаправлять трафик.${NC}"
        local suggested_port="${prev_port:-8080}"
        if is_port_in_use "$suggested_port"; then
            local free_p
            free_p="$(find_free_port 8081)"
            echo -e "${YELLOW}[!] Порт $suggested_port уже занят на сервере. Предлагаем свободный порт: ${BOLD}${free_p}${NC}"
            suggested_port="$free_p"
        fi
        read -r -p "Порт [Enter = ${suggested_port}]: " input_port
        HTTP_PORT="${input_port:-$suggested_port}"
        while is_port_in_use "$HTTP_PORT"; do
            echo -e "${RED}[!] Порт $HTTP_PORT уже занят другим процессом на сервере!${NC}"
            local next_free
            next_free="$(find_free_port $((HTTP_PORT + 1)))"
            read -r -p "Введите другой порт [Enter = ${next_free}]: " input_port
            HTTP_PORT="${input_port:-$next_free}"
        done
        echo -e "${GREEN}[+] Порт: $HTTP_PORT${NC}\n"
    else
        local default_local_port="${prev_port:-8080}"
        if is_port_in_use "$default_local_port"; then
            default_local_port="$(find_free_port 8081)"
        fi
        HTTP_PORT="$default_local_port"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 6: Интеграция с Remnawave (если применима)
    # ────────────────────────────────────────────────────────────────────────
    REMNA_BLOCK=""
    if [ "$config_remna" = true ]; then
        echo -e "${BOLD}--- [Шаг 6] Прямая интеграция с Remnawave ---${NC}"
        echo -e "${DIM}Сервер сам отправляет правила маршрутизации прямо в API вашей панели Remnawave.${NC}\n"

        local remna_choice="Y"
        if [ "$server_role" != "1" ] && [ "$server_role" != "4" ]; then
            local default_remna_prompt="y/N"
            [ -n "$prev_remna_token" ] && default_remna_prompt="Y/n"
            read -r -p "Настроить отправку правил Happ в сквады Remnawave? [$default_remna_prompt]: " remna_choice
            if [ -n "$prev_remna_token" ]; then
                remna_choice="${remna_choice:-Y}"
            else
                remna_choice="${remna_choice:-N}"
            fi
        fi

        if [[ "$remna_choice" =~ ^[YyДд]$ ]]; then
            echo ""
            read -r -p "URL API панели Remnawave [Enter = ${prev_remna_base:-http://remnawave:3000/api}]: " r_base
            r_base="${r_base:-${prev_remna_base:-http://remnawave:3000/api}}"
            local r_token_hint="пропустить"
            [ -n "$prev_remna_token" ] && r_token_hint="сохранить текущий"
            read -r -p "JWT токен администратора [Enter = $r_token_hint]: " r_token
            r_token="${r_token:-$prev_remna_token}"
            echo ""

            local existing_squads=0
            if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                existing_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$scan_env" || true)
            fi
            local default_sq_count="${existing_squads:-1}"
            [ "$default_sq_count" -le 0 ] && default_sq_count=1
            read -r -p "Сколько сквадов привязать? [1-10, Enter = $default_sq_count]: " r_count
            r_count="${r_count:-$default_sq_count}"
            
            REMNA_BLOCK="REMNAWAVE_BASE_URL=${r_base}
REMNAWAVE_TOKEN=${r_token}
"
            echo -e "\n${CYAN}${BOLD}[i] Источник правил маршрутизации:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}"
            echo -e "${DIM}Сервер берет готовые правила из папки HAPP этого репозитория.${NC}"
            echo -e "Доступные варианты правил:"
            echo -e "  ${BOLD}1) JSONSUB.JSON${NC}   — Обход блокировок ${DIM}(сайты из реестра РКН через VPN, остальные напрямую)${NC} [Рекомендуется]"
            echo -e "  ${BOLD}2) WHITELIST.JSON${NC} — Белый список ${DIM}(весь интернет через VPN, кроме незаблокированных сервисов РФ)${NC}"
            echo -e "  ${BOLD}3) DEFAULT.JSON${NC}   — Базовое стандартное правило"
            echo -e "  ${DIM}(или введите имя любого другого .JSON файла из репозитория)${NC}"

            for ((i=1; i<=r_count; i++)); do
                local prev_s_uuid=""
                local prev_s_rule=""
                if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                    prev_s_uuid=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$scan_env" | cut -d'=' -f2- || true)
                    prev_s_rule=$(grep "^REMNAWAVE_SQUAD_${i}_RULE=" "$scan_env" | cut -d'=' -f2- || true)
                fi
                echo -e "\n${CYAN}── Сквад #$i ──${NC}"
                local s_hint="из панели Remnawave → Сквады"
                [ -n "$prev_s_uuid" ] && s_hint="Enter = оставить $prev_s_uuid"
                read -r -p "  UUID сквада [$s_hint]: " s_uuid
                s_uuid="${s_uuid:-$prev_s_uuid}"

                echo -e "  Правило маршрутизации для сквада $i:"
                echo -e "    ${BOLD}1)${NC} Обход блокировок (JSONSUB.JSON) — сайты из реестра РКН через VPN, остальные напрямую [Enter]"
                echo -e "    ${BOLD}2)${NC} Белый список (WHITELIST.JSON)  — весь интернет через VPN, кроме РФ"
                echo -e "    ${BOLD}3)${NC} Свой файл из репозитория       — указать нестандартный .json"
                read -r -p "  Выберите [1-3, Enter = 1]: " s_rule_pick
                s_rule_pick="${s_rule_pick:-1}"
                local s_rule="${prev_s_rule:-JSONSUB.JSON}"
                case "$s_rule_pick" in
                    2) s_rule="WHITELIST.JSON" ;;
                    3)
                        read -r -p "  Введите имя файла [например, DEFAULT.JSON]: " custom_s_rule
                        custom_s_rule="${custom_s_rule:-JSONSUB.JSON}"
                        if [[ ! "$custom_s_rule" =~ \.[Jj][Ss][Oo][Nn]$ ]]; then
                            custom_s_rule="${custom_s_rule}.JSON"
                        fi
                        s_rule="$(echo "$custom_s_rule" | tr '[:lower:]' '[:upper:]')"
                        ;;
                    *) s_rule="JSONSUB.JSON" ;;
                esac
                REMNA_BLOCK="${REMNA_BLOCK}REMNAWAVE_SQUAD_${i}_UUID=${s_uuid}
REMNAWAVE_SQUAD_${i}_RULE=${s_rule}
"
            done

            local cf_prompt="y/N"
            [ -n "$prev_cf_id" ] && cf_prompt="Y/n"
            echo -e "\n${CYAN}Опционально: если Remnawave защищена Cloudflare Zero Trust (Service Token):${NC}"
            read -r -p "Использовать Cloudflare Zero Trust для подключения к панели? [$cf_prompt]: " cf_choice
            if [ -n "$prev_cf_id" ]; then
                cf_choice="${cf_choice:-Y}"
            else
                cf_choice="${cf_choice:-N}"
            fi

            if [[ "$cf_choice" =~ ^[YyДд]$ ]]; then
                read -r -p "CLOUDFLARE_ZERO_TRUST_CLIENT_ID [Enter = ${prev_cf_id:-пропустить}]: " r_cf_id
                r_cf_id="${r_cf_id:-$prev_cf_id}"

                read -r -p "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET [Enter = ${prev_cf_secret:-пропустить}]: " r_cf_secret
                r_cf_secret="${r_cf_secret:-$prev_cf_secret}"

                if [ -n "$r_cf_id" ] && [ -n "$r_cf_secret" ]; then
                    REMNA_BLOCK="${REMNA_BLOCK}CLOUDFLARE_ZERO_TRUST_CLIENT_ID=${r_cf_id}
CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=${r_cf_secret}
"
                fi
            elif [ -n "$prev_cf_id" ] && [ -n "$prev_cf_secret" ]; then
                REMNA_BLOCK="${REMNA_BLOCK}CLOUDFLARE_ZERO_TRUST_CLIENT_ID=${prev_cf_id}
CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=${prev_cf_secret}
"
            fi

            echo -e "\n${GREEN}[+] Интеграция с Remnawave настроена.${NC}\n"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 7: Docker-сеть (только если есть смысл)
    # ────────────────────────────────────────────────────────────────────────
    EXT_NETWORK=""
    NEEDS_NETWORK=false

    if [ -n "$REMNA_BLOCK" ]; then
        NEEDS_NETWORK=true
    fi

    if [ "$NEEDS_NETWORK" = true ]; then
        echo -e "${BOLD}--- [Шаг 7] Подключение к Docker-сети ---${NC}"
        echo -e "${DIM}Нужно, если Remnawave и этот сервер запущены на одной машине через Docker.${NC}"
        echo -e "${DIM}Объединение в общую сеть позволяет им общаться напрямую без открытия портов наружу.${NC}"
        echo -e "${DIM}Если не уверены — нажмите Enter (пропустить).${NC}"
        read -r -p "Подключить к Docker-сети? [y/N]: " net_choice
        if [[ "$net_choice" =~ ^[YyДд]$ ]]; then
            read -r -p "Имя сети [Enter = remnawave-network]: " input_net
            EXT_NETWORK="${input_net:-remnawave-network}"
            if ! docker network inspect "$EXT_NETWORK" &>/dev/null; then
                echo -e "${YELLOW}[*] Сеть $EXT_NETWORK не найдена. Создаём...${NC}"
                docker network create "$EXT_NETWORK" || true
            fi
            echo -e "${GREEN}[+] Сеть: $EXT_NETWORK${NC}\n"
        else
            echo -e "${DIM}Пропущено. Используется стандартная изолированная сеть.${NC}\n"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 8: Расписание обновления (Cron)
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Шаг 8] Расписание автоматического обновления ---${NC}"
    echo -e "${DIM}Как часто обновлять базы и отправлять правила в сквады?${NC}\n"
    echo -e "  ${BOLD}1)${NC} Раз в сутки в 10:00 UTC / 13:00 МСК [Enter — Рекомендуется]"
    echo -e "     ${DIM}(Гарантированно после утреннего обновления репозитория roscomvpn-routing)${NC}"
    echo -e "  ${BOLD}2)${NC} Каждые 6 часов (4 раза в день)"
    echo -e "  ${BOLD}3)${NC} Каждые 12 часов (2 раза в день)"
    echo -e "  ${BOLD}4)${NC} Указать свое cron-расписание"
    echo ""
    read -r -p "Выберите вариант [1-4, Enter = 1]: " sched_choice
    sched_choice="${sched_choice:-1}"

    SCHEDULE="0 10 * * *"
    case "$sched_choice" in
        2) SCHEDULE="0 */6 * * *" ;;
        3) SCHEDULE="0 */12 * * *" ;;
        4)
            read -r -p "Введите cron-выражение [Enter = ${prev_schedule:-0 10 * * *}]: " custom_sched
            SCHEDULE="${custom_sched:-${prev_schedule:-0 10 * * *}}"
            ;;
        *) SCHEDULE="0 10 * * *" ;;
    esac
    echo -e "${GREEN}[+] Расписание: $SCHEDULE${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 9: Telegram (всегда опционален)
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Последний шаг] Telegram-уведомления (опционально) ---${NC}"
    echo -e "${DIM}Бот будет присылать алерты при ошибках синхронизации и (по желанию) отчёты о новых базах.${NC}"
    
    local default_tg_prompt="y/N"
    [ -n "$prev_tg_token" ] && default_tg_prompt="Y/n"
    read -r -p "Настроить Telegram? [$default_tg_prompt]: " tg_choice
    if [ -n "$prev_tg_token" ]; then
        tg_choice="${tg_choice:-Y}"
    fi

    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_THREAD_ID=""
    TG_NOTIFY_SUCCESS="false"

    if [[ "$tg_choice" =~ ^[YyДд]$ ]]; then
        read -r -p "TELEGRAM_BOT_TOKEN [Enter = ${prev_tg_token:-пропустить}]: " TG_BOT_TOKEN
        TG_BOT_TOKEN="${TG_BOT_TOKEN:-$prev_tg_token}"

        read -r -p "TELEGRAM_CHAT_ID [Enter = ${prev_tg_chat:-пропустить}]: " TG_CHAT_ID
        TG_CHAT_ID="${TG_CHAT_ID:-$prev_tg_chat}"

        read -r -p "TELEGRAM_THREAD_ID (ID темы) [Enter = ${prev_tg_thread:-нет}]: " TG_THREAD_ID
        TG_THREAD_ID="${TG_THREAD_ID:-$prev_tg_thread}"

        read -r -p "Присылать уведомление при выходе новых баз? [y/N]: " tg_success
        if [[ "$tg_success" =~ ^[YyДд]$ ]]; then
            TG_NOTIFY_SUCCESS="true"
        else
            TG_NOTIFY_SUCCESS="false"
        fi

        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            test_telegram "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$TG_THREAD_ID" || true
        fi
    fi
    echo -e "${GREEN}[+] Telegram настроен.${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ГЕНЕРАЦИЯ КОНФИГУРАЦИИ
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}[*] Создание файлов конфигурации...${NC}"

    # Создаём резервную копию старого .env при переконфигурации
    if [ -f "$INSTALL_DIR/.env" ]; then
        cp "$INSTALL_DIR/.env" "$INSTALL_DIR/.env.backup" 2>/dev/null || true
    fi

    # Формируем .env — записываем только заполненные значения
    {
        echo "DOMAIN=${DOMAIN}"
        echo "ROUTING_TOKEN=${ROUTING_TOKEN}"
        echo "ENABLED_CLIENTS=${ENABLED_CLIENTS}"
        [ -n "$PUBLIC_GEO_BASE_URL" ] && echo "PUBLIC_GEO_BASE_URL=${PUBLIC_GEO_BASE_URL}"
        [ -n "$ROUTING_SOURCE_REPO" ] && echo "ROUTING_SOURCE_REPO=${ROUTING_SOURCE_REPO}"
        [ -n "$REMNA_BLOCK" ] && printf '%s' "$REMNA_BLOCK"
        echo "HTTP_BIND=127.0.0.1"
        echo "HTTP_PORT=${HTTP_PORT}"
        echo "SCHEDULE=${SCHEDULE}"
        echo "SYNC_ON_START=true"
        [ -n "$TG_BOT_TOKEN" ] && echo "TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}"
        [ -n "$TG_CHAT_ID" ] && echo "TELEGRAM_CHAT_ID=${TG_CHAT_ID}"
        [ -n "$TG_THREAD_ID" ] && echo "TELEGRAM_THREAD_ID=${TG_THREAD_ID}"
        echo "TELEGRAM_NOTIFY_SUCCESS=${TG_NOTIFY_SUCCESS}"
    } > "$INSTALL_DIR/.env"

    local networks_block=""
    local top_networks_block=""

    if [ -n "$EXT_NETWORK" ]; then
        networks_block="    networks:
      - default
      - ${EXT_NETWORK}"
        top_networks_block="networks:
  ${EXT_NETWORK}:
    name: ${EXT_NETWORK}
    external: true"
    fi

    cat > "$INSTALL_DIR/compose.yaml" <<EOF
services:
  geo-routing-server:
    image: ghcr.io/xdeptu5/geo-routing-server:latest
    container_name: geo-routing-server
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "\${HTTP_BIND:-127.0.0.1}:\${HTTP_PORT:-${HTTP_PORT}}:80"
    volumes:
      - routing_data:/app/www
      - ./.cache:/app/.cache
      - ./custom_geo:/app/custom_geo:ro
${networks_block}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  routing_data:

${top_networks_block}
EOF

    mkdir -p "$INSTALL_DIR/custom_geo"
    touch "$INSTALL_DIR/custom_geo/.gitkeep"

    # Сохраняем скрипт установщика в каталог проекта для работы команды geo-server
    if [[ "$0" =~ ^/dev/fd/ || "$0" =~ ^/proc/ ]] || [ ! -s "$0" ]; then
        curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$INSTALL_DIR/install.sh" 2>/dev/null || true
    else
        cp "$0" "$INSTALL_DIR/install.sh" 2>/dev/null || true
    fi
    chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    create_cli_shortcut "$INSTALL_DIR"

    echo -e "${BLUE}[*] Загрузка и запуск контейнера Geo Routing Server...${NC}"
    cd "$INSTALL_DIR"
    docker compose pull 2>/dev/null || true
    while true; do
        local up_output=""
        local up_exit=0
        set +e
        up_output=$(docker compose up -d 2>&1)
        up_exit=$?
        set -e

        if [ "$up_exit" -eq 0 ]; then
            echo "$up_output"
            break
        fi

        echo "$up_output"
        if echo "$up_output" | grep -qi "port is already allocated"; then
            echo -e "\n${YELLOW}[!] Порт $HTTP_PORT уже занят другим процессом на сервере!${NC}"
            local new_free_port
            new_free_port="$(find_free_port $((HTTP_PORT + 1)))"
            read -r -p "Введите другой свободный порт [Enter = $new_free_port]: " new_port
            new_port="${new_port:-$new_free_port}"
            HTTP_PORT="$new_port"
            sed -i "s/^HTTP_PORT=.*/HTTP_PORT=${HTTP_PORT}/" "$INSTALL_DIR/.env"
            sed -i "s/HTTP_PORT:-[0-9]*/HTTP_PORT:-${HTTP_PORT}/" "$INSTALL_DIR/compose.yaml"
            echo -e "${BLUE}[*] Повторная попытка запуска на порту $HTTP_PORT...${NC}\n"
        else
            echo -e "${RED}[!] Не удалось запустить контейнер. Проверьте вывод ошибки выше.${NC}"
            exit 1
        fi
    done

    echo -e "\n${GREEN}${BOLD}===============================================================================${NC}"
    echo -e "${GREEN}${BOLD}  НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
    echo -e "${GREEN}${BOLD}===============================================================================${NC}"
    echo -e "Каталог проекта: ${CYAN}${INSTALL_DIR}${NC}"
    echo -e "Быстрый вызов меню в терминале: команда ${CYAN}${BOLD}geo-server${NC} (или ${CYAN}${BOLD}geoserver${NC})\n"
    
    if [ "$NEEDS_PUBLIC_DOMAIN" = true ]; then
        show_proxy_snippets
    fi
    show_links
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

main_menu() {
    while true; do
        print_header
        local target_dir
        target_dir="$(get_install_dir)"
        
        if [ "${UI_LANG:-ru}" = "en" ]; then
            echo -e "Project directory: ${CYAN}$target_dir${NC}"
            if docker ps --format '{{.Names}}' | grep -q "^geo-routing-server$"; then
                echo -e "Container status: ${GREEN}[+] Running & Active${NC}\n"
            else
                echo -e "Container status: ${RED}[-] Stopped or Not Found${NC}\n"
            fi

            echo -e "${BOLD}Choose an action:${NC}"
            printf " %-4s %s\n" "1)"  "Sync geo-databases right now"
            printf " %-4s %s\n" "2)"  "Show public links and autorouting header"
            printf " %-4s %s\n" "3)"  "Show ready reverse-proxy configs (Caddy / Nginx / NPM)"
            printf " %-4s %s\n" "4)"  "Configure Remnawave API sync"
            printf " %-4s %s\n" "5)"  "Configure Telegram notifications"
            printf " %-4s %s\n" "6)"  "Reconfigure server (run wizard)"
            printf " %-4s %s\n" "7)"  "Update Docker image (pull & restart)"
            printf " %-4s %s\n" "8)"  "Update management script from GitHub"
            printf " %-4s %s\n" "9)"  "View container logs"
            printf " %-4s %s\n" "10)" "Restart server"
            printf " %-4s %s\n" "11)" "Stop server"
            printf " %-4s %s\n" "12)" "Uninstall project from server"
            printf " %-4s %s\n" "13)" "Сменить язык / Change language (RU/EN)"
            printf " %-4s %s\n" "0)"  "Exit"
            echo ""
            read -r -p "Enter choice [0-13]: " menu_choice
        else
            echo -e "Каталог проекта: ${CYAN}$target_dir${NC}"
            if docker ps --format '{{.Names}}' | grep -q "^geo-routing-server$"; then
                echo -e "Статус контейнера: ${GREEN}[+] Запущен и активен${NC}\n"
            else
                echo -e "Статус контейнера: ${RED}[-] Остановлен или не существует${NC}\n"
            fi

            echo -e "${BOLD}Выберите действие:${NC}"
            printf " %-4s %s\n" "1)"  "Синхронизировать базы прямо сейчас"
            printf " %-4s %s\n" "2)"  "Показать публичные ссылки и заголовок autorouting"
            printf " %-4s %s\n" "3)"  "Показать готовые конфиги для Caddy / Nginx / NPM"
            printf " %-4s %s\n" "4)"  "Настроить прямую синхронизацию с Remnawave API"
            printf " %-4s %s\n" "5)"  "Настроить / Изменить Telegram-уведомления"
            printf " %-4s %s\n" "6)"  "Перенастроить сервер заново (мастер установки)"
            printf " %-4s %s\n" "7)"  "Обновить Docker-образ сервера (pull & restart)"
            printf " %-4s %s\n" "8)"  "Обновить скрипт управления (меню и CLI из GitHub)"
            printf " %-4s %s\n" "9)"  "Посмотреть логи контейнера"
            printf " %-4s %s\n" "10)" "Перезапустить сервер"
            printf " %-4s %s\n" "11)" "Остановить сервер"
            printf " %-4s %s\n" "12)" "Удалить проект с сервера"
            printf " %-4s %s\n" "13)" "Сменить язык / Change language (RU/EN)"
            printf " %-4s %s\n" "0)"  "Выход"
            echo ""
            read -r -p "Введите номер [0-13]: " menu_choice
        fi

        case "$menu_choice" in
            1) run_sync_now ;;
            2) show_links ;;
            3) show_proxy_snippets; read -r -p "Нажмите Enter для возврата в меню..." ;;
            4) configure_remnawave ;;
            5) configure_telegram ;;
            6) install_wizard ;;
            7) update_project ;;
            8) update_script_only ;;
            9) view_logs ;;
            10) restart_server ;;
            11) stop_server ;;
            12) uninstall_project ;;
            13)
                if [ "${UI_LANG:-ru}" = "ru" ]; then
                    UI_LANG="en"
                else
                    UI_LANG="ru"
                fi
                echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
                echo -e "${GREEN}[+] Language / Язык: $UI_LANG${NC}"
                sleep 1
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}[!] Неверный пункт меню / Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

main() {
    case "${1:-}" in
        --help|-h|help)
            echo "Usage: geo-server [command]"
            echo "Commands:"
            echo "  menu          Open management menu"
            echo "  install       Run installer wizard"
            echo "  uninstall     Uninstall project and remove all data"
            echo "  logs          View container logs"
            echo "  sync          Force run routing sync"
            exit 0
            ;;
    esac

    detect_or_ask_language "$@"

    case "${1:-}" in
        --uninstall|-u|uninstall)
            uninstall_project
            exit 0
            ;;
        --reconfigure|-r|reconfigure|install)
            install_wizard
            exit 0
            ;;
        --menu|-m|menu)
            main_menu
            exit 0
            ;;
        --logs|-l|logs)
            view_logs
            exit 0
            ;;
        --sync|-s|sync)
            run_sync_now
            exit 0
            ;;
    esac

    local target_dir
    target_dir="$(get_install_dir)"
    
    if [ -d "$target_dir" ] && [ -f "$target_dir/compose.yaml" ]; then
        main_menu
    elif [ -d "$target_dir" ]; then
        print_header
        if [ "${UI_LANG:-ru}" = "en" ]; then
            echo -e "${YELLOW}[!] An incomplete or previous installation was detected in $target_dir${NC}\n"
            echo "  1) Run installer wizard (resume / reconfigure)"
            echo "  2) Reset and start fresh (clean all files)"
            echo "  3) Completely uninstall project from server"
            read -r -p "Select option [1-3, Enter = 1]: " init_choice
        else
            echo -e "${YELLOW}[!] Обнаружена незавершенная или прерванная установка в $target_dir${NC}\n"
            echo "  1) Начать установку заново (сохранив старые данные)"
            echo "  2) Очистить все файлы и начать с чистого листа"
            echo "  3) Полностью удалить проект с сервера"
            read -r -p "Выберите вариант [1-3, Enter = 1]: " init_choice
        fi
        init_choice="${init_choice:-1}"
        case "$init_choice" in
            2) 
                if [ -n "$target_dir" ] && [ "$target_dir" != "/" ] && [ "$target_dir" != "/root" ] && [ -d "$target_dir" ]; then
                    rm -rf "$target_dir"
                fi
                install_wizard
                ;;
            3) uninstall_project ;;
            *) install_wizard ;;
        esac
    else
        install_wizard
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
