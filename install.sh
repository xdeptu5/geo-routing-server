#!/usr/bin/env bash
# ==============================================================================
# Geo Routing Server — Интерактивный установщик и менеджер управления
# GitHub: https://github.com/xdeptu5/geo-routing-server
# ==============================================================================

set -euo pipefail

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

# ==============================================================================
# TUI КОМПОНЕНТЫ И ХЕЛПЕРЫ ВВОДА
# ==============================================================================

# Интерактивный TUI-селектор со стрелками ↑/↓, Enter и быстрыми цифрами
tui_select() {
    local prompt_title="$1"
    local default_idx="${2:-0}"
    shift 2
    local options=("$@")
    local count=${#options[@]}
    local selected=$default_idx

    # Fallback для неинтерактивного режима (пайпы, CI, тесты)
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        echo -e "$prompt_title" >&2
        for i in "${!options[@]}"; do
            echo -e "  $((i+1))) ${options[i]}" >&2
        done
        local fallback_pick=""
        read -r -p "> " fallback_pick || true
        fallback_pick="${fallback_pick:-$((default_idx + 1))}"
        if [[ "$fallback_pick" =~ ^[0-9]+$ ]] && [ "$fallback_pick" -ge 1 ] && [ "$fallback_pick" -le "$count" ]; then
            echo "$((fallback_pick - 1))"
        else
            echo "$default_idx"
        fi
        return 0
    fi

    # Скрываем курсор
    tput civis 2>/dev/null || printf "\033[?25l" >&2

    cleanup_tui_cursor() {
        tput cnorm 2>/dev/null || printf "\033[?25h" >&2
    }
    trap cleanup_tui_cursor EXIT INT TERM

    draw_tui_menu() {
        echo -e "$prompt_title" >&2
        for i in "${!options[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                printf "  \033[1;36m▸\033[0m \033[1;37;44m %s \033[0m\n" "${options[i]}" >&2
            else
                printf "    \033[0;37m%s\033[0m\n" "${options[i]}" >&2
            fi
        done
        printf "  \033[2m[↑/↓] Выбор   [Enter] Подтвердить   [1-%d] Быстрый ввод\033[0m\n" "$count" >&2
    }

    draw_tui_menu

    while true; do
        local key=""
        IFS= read -rsn1 key 2>/dev/null || true
        if [ "$key" = $'\x1b' ]; then
            local rest=""
            read -rsn2 -t 0.1 rest 2>/dev/null || true
            key="$key$rest"
        fi

        case "$key" in
            $'\x1b[A'|$'\x1bOA'|'k'|'K') # Вверх
                selected=$(( (selected - 1 + count) % count ))
                ;;
            $'\x1b[B'|$'\x1bOB'|'j'|'J') # Вниз
                selected=$(( (selected + 1) % count ))
                ;;
            "") # Enter
                break
                ;;
            " ") # Пробел
                break
                ;;
            [1-9]) # Быстрый выбор по цифре
                local num_pick=$((key - 1))
                if [ "$num_pick" -lt "$count" ]; then
                    selected=$num_pick
                    break
                fi
                ;;
            $'\x03') # Ctrl+C
                cleanup_tui_cursor
                exit 130
                ;;
        esac

        # Стираем меню для перерисовки
        local lines_to_clear=$((count + 2))
        printf "\033[%dA" "$lines_to_clear" >&2
        for ((l=0; l<lines_to_clear; l++)); do
            printf "\033[2K\r" >&2
            if [ "$l" -lt $((lines_to_clear - 1)) ]; then
                printf "\033[1B" >&2
            fi
        done
        printf "\033[%dA" $((lines_to_clear - 1)) >&2
        draw_tui_menu
    done

    # После подтверждения очищаем меню на экране
    local total_lines=$((count + 2))
    printf "\033[%dA" "$total_lines" >&2
    for ((l=0; l<total_lines; l++)); do
        printf "\033[2K\r" >&2
        if [ "$l" -lt $((total_lines - 1)) ]; then
            printf "\033[1B" >&2
        fi
    done
    printf "\033[%dA" $((total_lines - 1)) >&2

    cleanup_tui_cursor
    trap - EXIT INT TERM

    echo "$selected"
}

# Ввод с маскированием паролей и токенов (не оставляет секреты на экране)
tui_secret() {
    local prompt_label="$1"
    local current_val="${2:-}"
    local prompt_text="${prompt_label}"
    if [ -n "$current_val" ]; then
        prompt_text="${prompt_label} [Enter = сохранить текущий]: "
    else
        prompt_text="${prompt_label}: "
    fi

    local secret_input=""
    if [ -t 0 ]; then
        read -rs -p "$(echo -e "$prompt_text")" secret_input
        echo "" >&2
    else
        read -r secret_input || true
    fi
    secret_input="${secret_input:-$current_val}"
    echo "$secret_input"
}

# Умный поиск активных сетей Docker
detect_docker_networks() {
    if ! command -v docker &>/dev/null; then
        return
    fi
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -vE '^(bridge|host|none)$' || true
}

# Проверка, запущен ли контейнер Remnawave на этом же сервере
detect_remnawave_running() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "remna" && return 0
    return 1
}

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
        local lang_idx
        lang_idx=$(tui_select "\n${BOLD}Language / Выберите язык:${NC}" 0 "Русский (RU)" "English (EN)")
        if [ "$lang_idx" -eq 1 ]; then
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

    read -r -p "REMNAWAVE_BASE_URL [${current_base:-http://remnawave:3000/api}]: " input_base
    input_base="${input_base:-${current_base:-http://remnawave:3000/api}}"

    local input_token
    input_token=$(tui_secret "JWT токен администратора Remnawave" "$current_token")

    local existing_squads=0
    if [ -f "$env_file" ]; then
        existing_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$env_file" || true)
    fi
    local default_squads="${existing_squads:-1}"
    [ "$default_squads" -le 0 ] && default_squads=1
    read -r -p "Сколько сквадов привязать? [${default_squads}]: " count_squads
    count_squads="${count_squads:-$default_squads}"

    echo -e "\n${CYAN}${BOLD}[i] Источник правил:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}"

    local squads_env=""
    for ((i=1; i<=count_squads; i++)); do
        local prev_sq_uuid=""
        local prev_sq_rule=""
        if [ -f "$env_file" ]; then
            prev_sq_uuid=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$env_file" | cut -d'=' -f2- || true)
            prev_sq_rule=$(grep "^REMNAWAVE_SQUAD_${i}_RULE=" "$env_file" | cut -d'=' -f2- || true)
        fi
        echo -e "\n${CYAN}── Сквад #$i ──${NC}"
        local sq_hint="из панели Remnawave → Сквады"
        [ -n "$prev_sq_uuid" ] && sq_hint="$prev_sq_uuid"
        read -r -p "  UUID сквада [${sq_hint}]: " sq_uuid
        sq_uuid="${sq_uuid:-$prev_sq_uuid}"

        local def_rule_idx=0
        case "${prev_sq_rule:-JSONSUB.JSON}" in
            "WHITELIST.JSON") def_rule_idx=1 ;;
            "DEFAULT.JSON") def_rule_idx=2 ;;
            *) def_rule_idx=0 ;;
        esac

        local rule_pick
        rule_pick=$(tui_select "  Правило для сквада #$i:" "$def_rule_idx" \
            "JSONSUB.JSON" \
            "WHITELIST.JSON" \
            "DEFAULT.JSON" \
            "Свой файл из репозитория")

        local sq_rule="JSONSUB.JSON"
        case "$rule_pick" in
            1) sq_rule="WHITELIST.JSON" ;;
            2) sq_rule="DEFAULT.JSON" ;;
            3)
                read -r -p "  Имя файла [например, CUSTOM.JSON]: " custom_rule
                custom_rule="${custom_rule:-JSONSUB.JSON}"
                if [[ ! "$custom_rule" =~ \.[Jj][Ss][Oo][Nn]$ ]]; then
                    custom_rule="${custom_rule}.JSON"
                fi
                sq_rule="$(echo "$custom_rule" | tr '[:lower:]' '[:upper:]')"
                ;;
            *) sq_rule="${prev_sq_rule:-JSONSUB.JSON}" ;;
        esac
        echo -e "  ${GREEN}[+] Сквад #$i: ${sq_uuid} → ${sq_rule}${NC}"

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

    local cf_def_idx=0
    [ -n "$current_cf_id" ] && cf_def_idx=1
    local cf_choice_idx
    cf_choice_idx=$(tui_select "Remnawave защищена Cloudflare Zero Trust?" "$cf_def_idx" \
        "Нет (прямое подключение)" \
        "Да (Service Token)")

    local cf_env=""
    if [ "$cf_choice_idx" -eq 1 ]; then
        local input_cf_id
        input_cf_id=$(tui_secret "CLOUDFLARE_ZERO_TRUST_CLIENT_ID" "$current_cf_id")

        local input_cf_secret
        input_cf_secret=$(tui_secret "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET" "$current_cf_secret")

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

    local input_token
    input_token=$(tui_secret "TELEGRAM_BOT_TOKEN" "$current_token")

    read -r -p "TELEGRAM_CHAT_ID [${current_chat:-пропустить}]: " input_chat
    input_chat="${input_chat:-$current_chat}"

    read -r -p "TELEGRAM_THREAD_ID (ID темы/топика) [${current_thread:-нет}]: " input_thread
    input_thread="${input_thread:-$current_thread}"

    local succ_def_idx=0
    [ "$current_notify" = "true" ] && succ_def_idx=1
    local succ_pick
    succ_pick=$(tui_select "Присылать уведомление при выходе новых баз?" "$succ_def_idx" \
        "Нет (только критические ошибки)" \
        "Да (отчёт о каждом обновлении)")
    local input_notify="false"
    [ "$succ_pick" -eq 1 ] && input_notify="true"

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

        # Безопасное удаление каталога проекта с защитой системных папок
        if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
            case "$target_dir" in
                /|/root|/home|/opt|/var|/usr|/etc|/bin|/sbin|/tmp)
                    echo -e "${YELLOW}[!] Каталог $target_dir является системным. Удаляются только файлы проекта...${NC}"
                    rm -f "$target_dir/compose.yaml" "$target_dir/.env" "$target_dir/.env.backup" "$target_dir/.sync.lock" 2>/dev/null || true
                    rm -rf "$target_dir/custom_geo" 2>/dev/null || true
                    ;;
                *)
                    if [ -f "$target_dir/compose.yaml" ] && grep -q "geo-routing-server" "$target_dir/compose.yaml" 2>/dev/null; then
                        rm -rf "$target_dir"
                    elif [ -f "$target_dir/.env" ] && grep -q "ROUTING_TOKEN" "$target_dir/.env" 2>/dev/null; then
                        rm -rf "$target_dir"
                    else
                        echo -e "${YELLOW}[!] В каталоге $target_dir не обнаружен маркер проекта. Удаляются только файлы проекта...${NC}"
                        rm -f "$target_dir/compose.yaml" "$target_dir/.env" "$target_dir/.env.backup" 2>/dev/null || true
                    fi
                    ;;
            esac
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

    echo -e "${BOLD}--- [Шаг 1] Каталог установки ---${NC}"
    if [ -n "$existing_detected" ]; then
        echo -e "${YELLOW}[i] Найдена существующая установка: ${BOLD}$existing_detected${NC}"
    fi
    echo -e "${DIM}Папка, куда будут сохранены файлы compose.yaml и .env${NC}"
    read -r -p "Укажите свой путь или нажмите Enter по умолчанию [${current_suggested_dir}]: " input_dir
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
        echo -e "${CYAN}[i] Загружены текущие настройки ($scan_env)${NC}\n"
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
    echo -e "${BOLD}--- [Шаг 2] Сценарий работы ---${NC}"
    local default_role_idx=0
    case "$prev_clients" in
        "HAPP_DEEPLINK") default_role_idx=3 ;;
        "INCY"|"INCY_GEO") [ -n "$prev_public_geo" ] && default_role_idx=4 || default_role_idx=1 ;;
        "HAPP_GEO"|"HAPP_GEO,INCY_GEO") default_role_idx=2 ;;
        *) default_role_idx=0 ;;
    esac

    local role_idx
    role_idx=$(tui_select "Выберите режим работы сервера:" "$default_role_idx" \
        "Всё в одном (раздача баз + Incy + автообновление Remnawave)" \
        "Сервер раздачи (базы geoip/geosite + подписка Incy)" \
        "Только базы (раздача geoip.dat и geosite.dat без правил)" \
        "Только Remnawave (автообновление сквадов, базы на внешнем сервере)" \
        "Только Incy (раздача подписки JSON, базы на внешнем сервере)")

    local server_role=$((role_idx + 1))
    PUBLIC_GEO_BASE_URL=""
    ROUTING_SOURCE_REPO="$prev_routing_repo"
    NEEDS_PUBLIC_DOMAIN=true
    local config_remna=false

    case "$server_role" in
        2)
            local client_idx
            client_idx=$(tui_select "Выберите поддерживаемых клиентов:" 0 \
                "Happ и Incy" \
                "Только Happ" \
                "Только Incy")
            case "$client_idx" in
                1) ENABLED_CLIENTS="HAPP" ;;
                2) ENABLED_CLIENTS="INCY" ;;
                *) ENABLED_CLIENTS="HAPP,INCY" ;;
            esac
            NEEDS_PUBLIC_DOMAIN=true
            config_remna=false
            ;;
        3)
            local client_idx
            client_idx=$(tui_select "Формат баз:" 0 \
                "Happ и Incy" \
                "Только Happ" \
                "Только Incy")
            case "$client_idx" in
                1) ENABLED_CLIENTS="HAPP_GEO" ;;
                2) ENABLED_CLIENTS="INCY_GEO" ;;
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
            local client_idx
            client_idx=$(tui_select "Поддерживаемые клиенты:" 0 \
                "Happ и Incy" \
                "Только Happ" \
                "Только Incy")
            case "$client_idx" in
                1) ENABLED_CLIENTS="HAPP" ;;
                2) ENABLED_CLIENTS="INCY" ;;
                *) ENABLED_CLIENTS="HAPP,INCY" ;;
            esac
            NEEDS_PUBLIC_DOMAIN=true
            config_remna=true
            ;;
    esac
    echo -e "${GREEN}[+] Режим: $ENABLED_CLIENTS${NC}\n"

    # Если базы на внешнем сервере (варианты 4 и 5)
    if [ "$server_role" = "4" ] || [ "$server_role" = "5" ]; then
        local prompt_str="Адрес сервера с базами (например, https://geo.example.com/секретный_токен): "
        if [ -n "$prev_public_geo" ]; then
            prompt_str="Адрес сервера с базами [${prev_public_geo}]: "
        fi

        while true; do
            read -r -p "$prompt_str" input_geo_url
            input_geo_url="$(echo "$input_geo_url" | tr -d '[:space:]"' | tr -d "'")"
            PUBLIC_GEO_BASE_URL="${input_geo_url:-$prev_public_geo}"
            
            if [ -z "$PUBLIC_GEO_BASE_URL" ]; then
                echo -e "${RED}[!] Укажите адрес сервера раздачи баз!${NC}"
                continue
            fi

            # Автоматически добавляем https://, если указан без схемы
            if [[ ! "$PUBLIC_GEO_BASE_URL" =~ ^https?:// ]]; then
                PUBLIC_GEO_BASE_URL="https://${PUBLIC_GEO_BASE_URL}"
            fi

            # Удаляем хвостовые слеши
            while [[ "$PUBLIC_GEO_BASE_URL" == */ ]]; do
                PUBLIC_GEO_BASE_URL="${PUBLIC_GEO_BASE_URL%/}"
            done

            # Если скопирована ссылка на файл, отрезаем имя файла
            case "$PUBLIC_GEO_BASE_URL" in
                *[gG][eE][oO][iI][pP].[dD][aA][tT])
                    PUBLIC_GEO_BASE_URL="${PUBLIC_GEO_BASE_URL%/*}"
                    ;;
                *[gG][eE][oO][sS][iI][tT][eE].[dD][aA][tT])
                    PUBLIC_GEO_BASE_URL="${PUBLIC_GEO_BASE_URL%/*}"
                    ;;
            esac

            while [[ "$PUBLIC_GEO_BASE_URL" == */ ]]; do
                PUBLIC_GEO_BASE_URL="${PUBLIC_GEO_BASE_URL%/}"
            done

            # Проверяем наличие токена в пути (хотя бы один слеш после хоста)
            local no_proto="${PUBLIC_GEO_BASE_URL#*://}"
            local path_part="${no_proto#*/}"
            if [ "$path_part" = "$no_proto" ] || [ -z "$path_part" ]; then
                echo -e "${YELLOW}[!] Указан адрес без токена (${PUBLIC_GEO_BASE_URL}).${NC}"
                local conf_tok_idx
                conf_tok_idx=$(tui_select "Сервер действительно настроен без токена?" 0 "Нет, ввести заново" "Да, продолжить без токена")
                if [ "$conf_tok_idx" -eq 0 ]; then
                    continue
                fi
            fi

            break
        done
        echo -e "${GREEN}[+] Базы: $PUBLIC_GEO_BASE_URL${NC}\n"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 3: Публичный домен и токен (если нужен домен)
    # ────────────────────────────────────────────────────────────────────────
    DOMAIN="local"
    ROUTING_TOKEN="local"
    HTTP_PORT="8080"

    if [ "$NEEDS_PUBLIC_DOMAIN" = true ]; then
        echo -e "${BOLD}--- [Шаг 3] Публичный домен для HTTPS ---${NC}"
        read -r -p "Введите домен [${prev_domain:-geo.example.com}]: " input_domain
        DOMAIN="${input_domain:-${prev_domain:-geo.example.com}}"
        DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]' | sed -e 's~^https\?://~~' -e 's~/*$~~')"
        echo -e "${GREEN}[+] Домен: $DOMAIN${NC}\n"

        # ШАГ 4: Токен
        echo -e "${BOLD}--- [Шаг 4] Секретный URL-токен ---${NC}"
        local auto_token
        if [ -n "$prev_token" ] && [ "$prev_token" != "local" ]; then
            auto_token="$prev_token"
            echo -e "Текущий токен: ${CYAN}${BOLD}${auto_token}${NC}"
        else
            auto_token="$(openssl rand -hex 16)"
            echo -e "Сгенерирован токен: ${CYAN}${BOLD}${auto_token}${NC}"
        fi
        
        read -r -p "Секретный токен [${auto_token}]: " input_token
        ROUTING_TOKEN="${input_token:-$auto_token}"
        ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        while [[ ! "$ROUTING_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || [ "${#ROUTING_TOKEN}" -lt 8 ]; do
            echo -e "${RED}[!] Токен должен быть длиной не менее 8 символов (буквы, цифры, дефис, подчеркивание)${NC}"
            read -r -p "Введите корректный токен [${auto_token}]: " input_token
            ROUTING_TOKEN="${input_token:-$auto_token}"
            ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        done
        echo -e "${GREEN}[+] Токен сохранён.${NC}"
        echo -e "${CYAN}${BOLD}[i] Базовый URL:${NC} ${CYAN}https://${DOMAIN}/${ROUTING_TOKEN}${NC}\n"

        # ШАГ 5: Локальный порт
        echo -e "${BOLD}--- [Шаг 5] Локальный порт веб-сервера ---${NC}"
        local suggested_port="${prev_port:-8080}"
        if is_port_in_use "$suggested_port"; then
            local free_p
            free_p="$(find_free_port 8081)"
            echo -e "${YELLOW}[!] Порт $suggested_port занят. Предлагаем свободный порт: ${BOLD}${free_p}${NC}"
            suggested_port="$free_p"
        fi
        read -r -p "Порт [${suggested_port}]: " input_port
        HTTP_PORT="${input_port:-$suggested_port}"
        while is_port_in_use "$HTTP_PORT"; do
            echo -e "${RED}[!] Порт $HTTP_PORT занят другим процессом!${NC}"
            local next_free
            next_free="$(find_free_port $((HTTP_PORT + 1)))"
            read -r -p "Введите другой порт [${next_free}]: " input_port
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

        local remna_proceed=true
        if [ "$server_role" != "1" ] && [ "$server_role" != "4" ]; then
            local remna_conf_idx
            remna_conf_idx=$(tui_select "Настроить отправку правил Happ в сквады Remnawave?" 0 "Да" "Нет")
            [ "$remna_conf_idx" -ne 0 ] && remna_proceed=false
        fi

        if [ "$remna_proceed" = true ]; then
            if detect_remnawave_running; then
                echo -e "${CYAN}[i] Обнаружен локальный контейнер Remnawave в Docker.${NC}"
            fi

            read -r -p "URL API панели Remnawave [${prev_remna_base:-http://remnawave:3000/api}]: " r_base
            r_base="${r_base:-${prev_remna_base:-http://remnawave:3000/api}}"

            local r_token
            r_token=$(tui_secret "JWT токен администратора Remnawave" "$prev_remna_token")

            local existing_squads=0
            if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                existing_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$scan_env" || true)
            fi
            local default_sq_count="${existing_squads:-1}"
            [ "$default_sq_count" -le 0 ] && default_sq_count=1
            read -r -p "Сколько сквадов привязать? [${default_sq_count}]: " r_count
            r_count="${r_count:-$default_sq_count}"
            
            REMNA_BLOCK="REMNAWAVE_BASE_URL=${r_base}
REMNAWAVE_TOKEN=${r_token}
"
            echo -e "\n${CYAN}${BOLD}[i] Источник правил:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}"

            for ((i=1; i<=r_count; i++)); do
                local prev_s_uuid=""
                local prev_s_rule=""
                if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                    prev_s_uuid=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$scan_env" | cut -d'=' -f2- || true)
                    prev_s_rule=$(grep "^REMNAWAVE_SQUAD_${i}_RULE=" "$scan_env" | cut -d'=' -f2- || true)
                fi
                echo -e "\n${CYAN}── Сквад #$i ──${NC}"
                local s_hint="из панели Remnawave → Сквады"
                [ -n "$prev_s_uuid" ] && s_hint="$prev_s_uuid"
                read -r -p "  UUID сквада [${s_hint}]: " s_uuid
                s_uuid="${s_uuid:-$prev_s_uuid}"

                local def_rule_idx=0
                case "${prev_s_rule:-JSONSUB.JSON}" in
                    "WHITELIST.JSON") def_rule_idx=1 ;;
                    "DEFAULT.JSON") def_rule_idx=2 ;;
                    *) def_rule_idx=0 ;;
                esac

                local s_rule_pick
                s_rule_pick=$(tui_select "  Правило для сквада #$i:" "$def_rule_idx" \
                    "JSONSUB.JSON" \
                    "WHITELIST.JSON" \
                    "DEFAULT.JSON" \
                    "Свой файл из репозитория")

                local s_rule="JSONSUB.JSON"
                case "$s_rule_pick" in
                    1) s_rule="WHITELIST.JSON" ;;
                    2) s_rule="DEFAULT.JSON" ;;
                    3)
                        read -r -p "  Имя файла [например, CUSTOM.JSON]: " custom_s_rule
                        custom_s_rule="${custom_s_rule:-JSONSUB.JSON}"
                        if [[ ! "$custom_s_rule" =~ \.[Jj][Ss][Oo][Nn]$ ]]; then
                            custom_s_rule="${custom_s_rule}.JSON"
                        fi
                        s_rule="$(echo "$custom_s_rule" | tr '[:lower:]' '[:upper:]')"
                        ;;
                    *) s_rule="JSONSUB.JSON" ;;
                esac
                echo -e "  ${GREEN}[+] Сквад #$i: ${s_uuid} → ${s_rule}${NC}"

                REMNA_BLOCK="${REMNA_BLOCK}REMNAWAVE_SQUAD_${i}_UUID=${s_uuid}
REMNAWAVE_SQUAD_${i}_RULE=${s_rule}
"
            done

            local cf_def_idx=0
            [ -n "$prev_cf_id" ] && cf_def_idx=1
            local cf_choice_idx
            cf_choice_idx=$(tui_select "Remnawave защищена Cloudflare Zero Trust?" "$cf_def_idx" \
                "Нет (прямой доступ)" \
                "Да (Service Token)")

            if [ "$cf_choice_idx" -eq 1 ]; then
                local r_cf_id
                r_cf_id=$(tui_secret "CLOUDFLARE_ZERO_TRUST_CLIENT_ID" "$prev_cf_id")

                local r_cf_secret
                r_cf_secret=$(tui_secret "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET" "$prev_cf_secret")

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

            echo -e "${GREEN}[+] Интеграция с Remnawave настроена.${NC}\n"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 7: Docker-сеть (умный автодетект)
    # ────────────────────────────────────────────────────────────────────────
    EXT_NETWORK=""
    NEEDS_NETWORK=false

    if [ -n "$REMNA_BLOCK" ]; then
        NEEDS_NETWORK=true
    fi

    if [ "$NEEDS_NETWORK" = true ]; then
        echo -e "${BOLD}--- [Шаг 7] Подключение к Docker-сети ---${NC}"
        
        # Получаем список сетей Docker
        local detected_nets
        detected_nets=$(detect_docker_networks)
        local net_options=()
        local remna_found_net=""

        if [ -n "$detected_nets" ]; then
            while IFS= read -r net_name; do
                [ -z "$net_name" ] && continue
                if [[ "$net_name" =~ remna ]]; then
                    remna_found_net="$net_name"
                fi
                net_options+=("$net_name")
            done <<< "$detected_nets"
        fi

        # Если не нашли remnawave-network в списке, добавим ее как вариант
        if [ -z "$remna_found_net" ]; then
            net_options=("remnawave-network" "${net_options[@]}")
        fi
        net_options+=("Ввести другое имя сети" "Не подключать к внешней сети")

        local net_pick_idx
        net_pick_idx=$(tui_select "Выберите Docker-сеть для связи с Remnawave:" 0 "${net_options[@]}")
        local chosen_net="${net_options[$net_pick_idx]}"

        if [ "$chosen_net" = "Не подключать к внешней сети" ]; then
            echo -e "${DIM}Пропущено. Используется стандартная сеть.${NC}\n"
        elif [ "$chosen_net" = "Ввести другое имя сети" ]; then
            read -r -p "Имя Docker-сети: " input_custom_net
            EXT_NETWORK="${input_custom_net:-remnawave-network}"
            if ! docker network inspect "$EXT_NETWORK" &>/dev/null; then
                echo -e "${YELLOW}[*] Создаём Docker-сеть $EXT_NETWORK...${NC}"
                docker network create "$EXT_NETWORK" || true
            fi
            echo -e "${GREEN}[+] Сеть: $EXT_NETWORK${NC}\n"
        else
            EXT_NETWORK="$chosen_net"
            if ! docker network inspect "$EXT_NETWORK" &>/dev/null; then
                echo -e "${YELLOW}[*] Создаём Docker-сеть $EXT_NETWORK...${NC}"
                docker network create "$EXT_NETWORK" || true
            fi
            echo -e "${GREEN}[+] Сеть: $EXT_NETWORK${NC}\n"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 8: Расписание обновления (Cron)
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Шаг 8] Расписание автоматического обновления ---${NC}"
    local def_sched_idx=0
    case "${prev_schedule:-0 10 * * *}" in
        "0 */6 * * *") def_sched_idx=1 ;;
        "0 */12 * * *") def_sched_idx=2 ;;
        "0 10 * * *") def_sched_idx=0 ;;
        *) def_sched_idx=3 ;;
    esac

    local sched_idx
    sched_idx=$(tui_select "Как часто обновлять базы и правила?" "$def_sched_idx" \
        "Раз в сутки в 10:00 UTC / 13:00 МСК (Рекомендуется)" \
        "Каждые 6 часов (4 раза в день)" \
        "Каждые 12 часов (2 раза в день)" \
        "Указать свое cron-расписание")

    SCHEDULE="0 10 * * *"
    case "$sched_idx" in
        1) SCHEDULE="0 */6 * * *" ;;
        2) SCHEDULE="0 */12 * * *" ;;
        3)
            read -r -p "Введите cron-выражение [${prev_schedule:-0 10 * * *}]: " custom_sched
            SCHEDULE="${custom_sched:-${prev_schedule:-0 10 * * *}}"
            ;;
        *) SCHEDULE="0 10 * * *" ;;
    esac
    echo -e "${GREEN}[+] Расписание: $SCHEDULE${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 9: Telegram (опционально)
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Последний шаг] Telegram-уведомления ---${NC}"
    local def_tg_idx=0
    [ -n "$prev_tg_token" ] && def_tg_idx=1

    local tg_opt_idx
    tg_opt_idx=$(tui_select "Настроить Telegram-уведомления об ошибках/обновлениях?" "$def_tg_idx" \
        "Пропустить (без Telegram)" \
        "Настроить Telegram бота")

    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_THREAD_ID=""
    TG_NOTIFY_SUCCESS="false"

    if [ "$tg_opt_idx" -eq 1 ]; then
        TG_BOT_TOKEN=$(tui_secret "TELEGRAM_BOT_TOKEN" "$prev_tg_token")
        
        read -r -p "TELEGRAM_CHAT_ID [${prev_tg_chat:-пропустить}]: " input_chat
        TG_CHAT_ID="${input_chat:-$prev_tg_chat}"

        read -r -p "TELEGRAM_THREAD_ID (ID темы) [${prev_tg_thread:-нет}]: " input_thread
        TG_THREAD_ID="${input_thread:-$prev_tg_thread}"

        local tg_succ_idx
        tg_succ_idx=$(tui_select "Присылать уведомление при успешном выходе новых баз?" 0 \
            "Нет (только критические ошибки)" \
            "Да (отчёт о каждом обновлении)")
        [ "$tg_succ_idx" -eq 1 ] && TG_NOTIFY_SUCCESS="true" || TG_NOTIFY_SUCCESS="false"

        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            test_telegram "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$TG_THREAD_ID" || true
        fi
        echo -e "${GREEN}[+] Telegram настроен.${NC}\n"
    else
        echo -e "${DIM}Уведомления Telegram отключены.${NC}\n"
    fi

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
    chmod 600 "$INSTALL_DIR/.env"
    [ -f "$INSTALL_DIR/.env.backup" ] && chmod 600 "$INSTALL_DIR/.env.backup" 2>/dev/null || true

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
        
        local status_msg=""
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^geo-routing-server$"; then
            status_msg="${GREEN}[+] Запущен и активен${NC}"
        else
            status_msg="${RED}[-] Остановлен или не найден${NC}"
        fi

        if [ "${UI_LANG:-ru}" = "en" ]; then
            echo -e "Project directory: ${CYAN}$target_dir${NC}"
            echo -e "Container status:  $status_msg\n"

            local en_options=(
                "Sync geo-databases right now"
                "Show public links and autorouting header"
                "Show reverse-proxy configs (Caddy / Nginx / NPM)"
                "Configure Remnawave API sync"
                "Configure Telegram notifications"
                "Reconfigure server (run wizard)"
                "Update Docker image (pull & restart)"
                "Update management script from GitHub"
                "View container logs"
                "Restart server"
                "Stop server"
                "Uninstall project from server"
                "Сменить язык / Change language (RU/EN)"
                "Exit"
            )

            local menu_idx
            menu_idx=$(tui_select "Choose an action:" 0 "${en_options[@]}")
        else
            echo -e "Каталог проекта:  ${CYAN}$target_dir${NC}"
            echo -e "Статус сервера:   $status_msg\n"

            local ru_options=(
                "Синхронизировать базы прямо сейчас"
                "Показать публичные ссылки и диплинки"
                "Готовые конфиги для Caddy / Nginx / NPM"
                "Настроить прямую синхронизацию с Remnawave"
                "Настроить / Изменить Telegram-уведомления"
                "Перенастроить сервер (мастер установки)"
                "Обновить Docker-образ сервера"
                "Обновить скрипт управления из GitHub"
                "Посмотреть логи контейнера"
                "Перезапустить сервер"
                "Остановить сервер"
                "Удалить проект с сервера"
                "Сменить язык / Change language (RU/EN)"
                "Выход"
            )

            local menu_idx
            menu_idx=$(tui_select "Выберите действие:" 0 "${ru_options[@]}")
        fi

        case "$menu_idx" in
            0) run_sync_now ;;
            1) show_links ;;
            2) show_proxy_snippets; read -r -p "Нажмите Enter для возврата в меню..." ;;
            3) configure_remnawave ;;
            4) configure_telegram ;;
            5) install_wizard ;;
            6) update_project ;;
            7) update_script_only ;;
            8) view_logs ;;
            9) restart_server ;;
            10) stop_server ;;
            11) uninstall_project ;;
            12)
                if [ "${UI_LANG:-ru}" = "ru" ]; then
                    UI_LANG="en"
                else
                    UI_LANG="ru"
                fi
                echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
                echo -e "${GREEN}[+] Language / Язык: $UI_LANG${NC}"
                sleep 1
                ;;
            13) exit 0 ;;
            *) echo -e "${RED}[!] Неверный пункт меню${NC}"; sleep 1 ;;
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
        local init_idx
        if [ "${UI_LANG:-ru}" = "en" ]; then
            init_idx=$(tui_select "${YELLOW}[!] Incomplete installation detected in $target_dir${NC}" 0 \
                "Resume / reconfigure installation" \
                "Reset and start fresh (clean all files)" \
                "Completely uninstall project from server")
        else
            init_idx=$(tui_select "${YELLOW}[!] Обнаружена незавершенная установка в $target_dir${NC}" 0 \
                "Продолжить настройку (сохранить старые данные)" \
                "Очистить все файлы и начать с чистого листа" \
                "Полностью удалить проект с сервера")
        fi
        case "$init_idx" in
            1) 
                if [ -n "$target_dir" ] && [ "$target_dir" != "/" ] && [ "$target_dir" != "/root" ] && [ -d "$target_dir" ]; then
                    rm -rf "$target_dir"
                fi
                install_wizard
                ;;
            2) uninstall_project ;;
            *) install_wizard ;;
        esac
    else
        install_wizard
    fi
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    main "$@"
fi
