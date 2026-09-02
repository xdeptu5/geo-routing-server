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

print_header() {
    clear || true
    echo -e "${CYAN}${BOLD}"
    echo "==============================================================================="
    echo "                      🚀 GEO ROUTING SERVER MANAGER                            "
    echo "==============================================================================="
    echo -e "${NC}"
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Ошибка: Запустите скрипт с правами root или через sudo!${NC}"
        exit 1
    fi
}

check_dependencies() {
    echo -e "${BLUE}🔍 Проверка системных зависимостей...${NC}"
    
    for cmd in curl openssl; do
        if ! command -v "$cmd" &> /dev/null; then
            echo -e "${YELLOW}Утилита $cmd не найдена, устанавливаем...${NC}"
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
        echo -e "${YELLOW}Docker не установлен! Установить официальный Docker автоматически? [Y/n]${NC}"
        read -r -p "> " install_docker
        install_docker=${install_docker:-Y}
        if [[ "$install_docker" =~ ^[YyДд]$ ]]; then
            echo -e "${BLUE}Установка Docker...${NC}"
            curl -fsSL https://get.docker.com | sh
            systemctl enable --now docker || true
        else
            echo -e "${RED}Для работы сервера необходим Docker. Прерывание установки.${NC}"
            exit 1
        fi
    fi

    if ! docker compose version &> /dev/null; then
        echo -e "${RED}Ошибка: Плагин 'docker compose' не найден. Обновите Docker.${NC}"
        exit 1
    fi

    echo -e "${GREEN}✓ Все зависимости готовы к работе.${NC}\n"
}

get_install_dir() {
    if [ -f "$CONFIG_FILE_RECORD" ]; then
        cat "$CONFIG_FILE_RECORD"
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
bash "$target_dir/install.sh" "\$@"
EOF
    chmod +x "$wrapper_script"
    
    ln -sf "$wrapper_script" /usr/bin/geo-server 2>/dev/null || true
    ln -sf "$wrapper_script" /usr/local/bin/geoserver 2>/dev/null || true
    ln -sf "$wrapper_script" /usr/bin/geoserver 2>/dev/null || true
}

run_sync_now() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}🔄 Запуск принудительной синхронизации баз...${NC}"
    docker exec -it geo-routing-server run-routing-sync || {
        echo -e "${RED}Ошибка запуска синхронизации. Проверьте запущен ли контейнер: docker compose ps${NC}"
    }
    echo ""
    read -r -p "Нажмите Enter для продолжения..."
}

show_links() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${GREEN}${BOLD}📋 Публичные ссылки и интеграции:${NC}"
    docker exec -it geo-routing-server python3 -c "
from app.config import Config
from app.main import print_summary_banner
print_summary_banner(Config.get_token())
" || {
        echo -e "${YELLOW}Не удалось получить ссылки напрямую из контейнера. Проверьте логи: docker compose logs${NC}"
    }
    echo ""
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
        echo -e "${GREEN}${BOLD}ℹ️ Режим «Только генератор для Remnawave»: сервер работает локально внутри Docker-сети.${NC}"
        echo -e "Настройка внешнего реверс-прокси не требуется, если вы не планируете открывать сервер наружу.\n"
        return 0
    fi

    echo -e "${CYAN}${BOLD}===============================================================================${NC}"
    echo -e "${YELLOW}${BOLD}💡 ГОТОВЫЕ КОНФИГУРАЦИИ ДЛЯ ВАШЕГО РЕВЕРС-ПРОКСИ (HTTPS)${NC}"
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
    echo -e "${BOLD}⚡ Прямая интеграция с Remnawave API (без сторонних сервисов)${NC}\n"

    local current_base=""
    local current_token=""
    if [ -f "$env_file" ]; then
        current_base=$(grep "^REMNAWAVE_BASE_URL=" "$env_file" | cut -d'=' -f2- || true)
        current_token=$(grep "^REMNAWAVE_TOKEN=" "$env_file" | cut -d'=' -f2- || true)
    fi

    read -r -p "REMNAWAVE_BASE_URL [Enter = ${current_base:-http://remnawave:3000/api}]: " input_base
    input_base="${input_base:-${current_base:-http://remnawave:3000/api}}"

    read -r -p "REMNAWAVE_TOKEN (JWT токен панели) [Enter = оставить]: " input_token
    input_token="${input_token:-$current_token}"

    read -r -p "Сколько сквадов хотите привязать? [1-5, Enter = 1]: " count_squads
    count_squads="${count_squads:-1}"

    local squads_env=""
    for ((i=1; i<=count_squads; i++)); do
        echo -e "\n${CYAN}--- Настройка Сквада #$i ---${NC}"
        read -r -p "UUID сквада $i: " sq_uuid
        read -r -p "Правило для сквада $i [Enter = JSONSUB.JSON]: " sq_rule
        sq_rule="${sq_rule:-JSONSUB.JSON}"
        squads_env="${squads_env}REMNAWAVE_SQUAD_${i}_UUID=${sq_uuid}
REMNAWAVE_SQUAD_${i}_RULE=${sq_rule}
"
    done

    # Удаляем старые записи из .env и сохраняем новые
    if [ -f "$env_file" ]; then
        sed -i '/^REMNAWAVE_/d' "$env_file"
        cat >> "$env_file" <<EOF
REMNAWAVE_BASE_URL=${input_base}
REMNAWAVE_TOKEN=${input_token}
${squads_env}
EOF
        echo -e "\n${GREEN}✓ Настройки Remnawave сохранены! Перезапускаем контейнер...${NC}"
        cd "$target_dir"
        docker compose up -d
        echo -e "${GREEN}✓ Готово! Теперь правила будут отправляться в Remnawave автоматически.${NC}\n"
    fi
    read -r -p "Нажмите Enter для продолжения..."
}

update_project() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}🚀 Обновление Docker-образа до последней версии...${NC}"
    cd "$target_dir"
    docker compose pull
    docker compose up -d
    echo -e "${GREEN}✓ Сервер успешно обновлён!${NC}\n"
    read -r -p "Нажмите Enter для продолжения..."
}

view_logs() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}📜 Просмотр последних логов (Ctrl+C для выхода):${NC}\n"
    cd "$target_dir"
    docker compose logs -f --tail 100
}

restart_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}Перезапуск контейнера...${NC}"
    docker compose restart
    echo -e "${GREEN}✓ Контейнер успешно перезапущен.${NC}\n"
    read -r -p "Нажмите Enter для продолжения..."
}

stop_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}Остановка контейнера...${NC}"
    docker compose down
    echo -e "${GREEN}✓ Контейнер остановлен.${NC}\n"
    read -r -p "Нажмите Enter для продолжения..."
}

test_telegram() {
    local bot_token="$1"
    local chat_id="$2"
    local thread_id="${3:-}"

    if [ -z "$bot_token" ] || [ -z "$chat_id" ]; then
        echo -e "${RED}Ошибка: Токен бота или Chat ID не заданы!${NC}"
        return 1
    fi

    echo -e "${BLUE}Отправка тестового сообщения в Telegram...${NC}"
    local data_params=(
        -d "chat_id=${chat_id}"
        -d "text=🔔 <b>[Geo Routing Server]</b> Тестовое уведомление успешно доставлено!"
        -d "parse_mode=HTML"
    )

    if [ -n "$thread_id" ]; then
        data_params+=(-d "message_thread_id=${thread_id}")
    fi

    local response
    response=$(curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" "${data_params[@]}" || true)
    
    if echo "$response" | grep -q '"ok":true'; then
        echo -e "${GREEN}✓ Тестовое сообщение успешно получено в Telegram!${NC}"
        return 0
    else
        echo -e "${RED}Ошибка отправки: $response${NC}"
        return 1
    fi
}

configure_telegram() {
    local target_dir
    target_dir="$(get_install_dir)"
    local env_file="$target_dir/.env"

    print_header
    echo -e "${BOLD}🔔 Настройка Telegram-уведомлений${NC}\n"

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

    read -r -p "Введите TELEGRAM_BOT_TOKEN [Enter = оставить текущий]: " input_token
    input_token="${input_token:-$current_token}"

    read -r -p "Введите TELEGRAM_CHAT_ID [Enter = оставить текущий]: " input_chat
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
        echo -e "\n${GREEN}✓ Настройки Telegram сохранены в .env!${NC}"
        echo -e "${YELLOW}Перезапускаем контейнер для применения настроек...${NC}"
        cd "$target_dir"
        docker compose up -d
        echo -e "${GREEN}✓ Контейнер перезапущен с новыми параметрами.${NC}\n"
    else
        echo -e "${RED}Файл .env не найден в $target_dir${NC}"
    fi

    read -r -p "Нажмите Enter для продолжения..."
}

uninstall_project() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${RED}${BOLD}⚠️ ВНИМАНИЕ: Вы действительно хотите удалить Geo Routing Server? [y/N]${NC}"
    read -r -p "> " confirm
    if [[ "$confirm" =~ ^[YyДд]$ ]]; then
        cd "$target_dir" || true
        docker compose down -v || true
        rm -rf "$target_dir"
        rm -f "$CONFIG_FILE_RECORD"
        rm -f /usr/local/bin/geo-server /usr/bin/geo-server /usr/local/bin/geoserver /usr/bin/geoserver
        echo -e "${GREEN}✓ Проект полностью удалён с сервера.${NC}"
        exit 0
    else
        echo "Удаление отменено."
        sleep 1
    fi
}

# ==============================================================================
# МАСТЕР УСТАНОВКИ
# ==============================================================================

install_wizard() {
    print_header
    check_root
    check_dependencies

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 1: Каталог установки
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Шаг 1] Каталог установки ---${NC}"
    echo -e "Укажите папку для проекта. ${DIM}Подходит любая: /opt/, стеки Arcane, Portainer, Dockge, 1Panel и др.${NC}"
    read -r -p "Каталог [Enter = /opt/geo-routing-server]: " input_dir
    INSTALL_DIR="${input_dir:-/opt/geo-routing-server}"
    mkdir -p "$INSTALL_DIR"
    save_install_dir "$INSTALL_DIR"
    echo -e "${GREEN}✓ Каталог: $INSTALL_DIR${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 2: Режим работы сервера
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Шаг 2] Что будет делать этот сервер? ---${NC}"
    echo ""
    echo -e "  ${BOLD}1)${NC} Полный сервер ${DIM}— раздаёт geo-базы и правила для HAPP и INCY (всё-в-одном)${NC}"
    echo -e "  ${BOLD}2)${NC} Только INCY ${DIM}— раздаёт geo-базы и автороутинг только для клиента Incy${NC}"
    echo -e "  ${BOLD}3)${NC} Для панели Remnawave ${DIM}— только отправка правил маршрутизации (самый лёгкий вариант)${NC}"
    echo -e "  ${BOLD}4)${NC} Публичный сервер geo-баз ${DIM}— только раздача файлов geoip.dat / geosite.dat${NC}"
    echo -e "  ${BOLD}5)${NC} HAPP полный ${DIM}— и правила для Remnawave, и раздача geo-баз${NC}"
    echo ""
    read -r -p "Выберите вариант [1-5, Enter = 1]: " client_choice
    client_choice="${client_choice:-1}"
    
    PUBLIC_GEO_BASE_URL=""
    NEEDS_PUBLIC_DOMAIN=true  # нужен ли публичный домен и порт

    case "$client_choice" in
        2) ENABLED_CLIENTS="INCY" ;;
        3) 
            ENABLED_CLIENTS="HAPP_DEEPLINK"
            NEEDS_PUBLIC_DOMAIN=false
            echo -e "\n${CYAN}Опционально: если geo-базы раздаются с другого вашего сервера, укажите его URL.${NC}"
            echo -e "${DIM}Пример: https://geo-node.example.com/secret_token/HAPP${NC}"
            read -r -p "URL к внешним geo-базам [Enter = пропустить]: " input_geo_url
            PUBLIC_GEO_BASE_URL="${input_geo_url:-}"
            ;;
        4) ENABLED_CLIENTS="HAPP_GEO" ;;
        5) ENABLED_CLIENTS="HAPP" ;;
        *) ENABLED_CLIENTS="HAPP,INCY" ;;
    esac
    echo -e "${GREEN}✓ Режим: $ENABLED_CLIENTS${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 3: Интеграция с Remnawave (только если выбран HAPP-модуль)
    # ────────────────────────────────────────────────────────────────────────
    REMNA_BLOCK=""
    if [[ "$ENABLED_CLIENTS" =~ HAPP ]]; then
        echo -e "${BOLD}--- [Шаг 3] Прямая интеграция с Remnawave ---${NC}"
        echo -e "${DIM}Сервер может сам отправлять правила маршрутизации прямо в API вашей панели Remnawave.${NC}"
        echo -e "${DIM}Вам не нужны сторонние контейнеры-апдейтеры — всё работает из коробки.${NC}\n"
        read -r -p "Настроить интеграцию с Remnawave? [y/N]: " remna_choice
        if [[ "$remna_choice" =~ ^[YyДд]$ ]]; then
            echo ""
            read -r -p "URL API панели Remnawave [Enter = http://remnawave:3000/api]: " r_base
            r_base="${r_base:-http://remnawave:3000/api}"
            read -r -p "JWT токен администратора (из панели Remnawave → Настройки → API): " r_token
            echo ""
            read -r -p "Сколько сквадов (групп пользователей) привязать? [1-5, Enter = 1]: " r_count
            r_count="${r_count:-1}"
            
            REMNA_BLOCK="REMNAWAVE_BASE_URL=${r_base}
REMNAWAVE_TOKEN=${r_token}
"
            for ((i=1; i<=r_count; i++)); do
                echo -e "\n${CYAN}── Сквад #$i ──${NC}"
                read -r -p "  UUID сквада (из панели Remnawave → Группы): " s_uuid
                read -r -p "  Какое правило отправлять? [Enter = JSONSUB.JSON]: " s_rule
                s_rule="${s_rule:-JSONSUB.JSON}"
                REMNA_BLOCK="${REMNA_BLOCK}REMNAWAVE_SQUAD_${i}_UUID=${s_uuid}
REMNAWAVE_SQUAD_${i}_RULE=${s_rule}
"
            done
            echo -e "\n${GREEN}✓ Интеграция с Remnawave настроена.${NC}\n"
        else
            echo -e "${DIM}Пропущено. Вы сможете настроить это позже через меню: geo-server → пункт 4${NC}\n"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 4: Публичный домен (только если нужен)
    # ────────────────────────────────────────────────────────────────────────
    DOMAIN="local"
    ROUTING_TOKEN="local"
    HTTP_PORT="8080"

    if [ "$NEEDS_PUBLIC_DOMAIN" = true ]; then
        echo -e "${BOLD}--- [Шаг 4] Публичный домен для HTTPS ---${NC}"
        echo -e "${DIM}Домен, на который вы направите реверс-прокси (Caddy / Nginx / NPM).${NC}"
        read -r -p "Введите домен (например, geo.example.com): " input_domain
        DOMAIN="${input_domain:-geo.example.com}"
        echo -e "${GREEN}✓ Домен: $DOMAIN${NC}\n"

        # ШАГ 5: Токен
        echo -e "${BOLD}--- [Шаг 5] Секретный URL-токен ---${NC}"
        echo -e "${DIM}Токен — секретная часть URL, которая защищает ваши файлы от сканеров.${NC}"
        echo -e "${DIM}Пример ссылки: https://${DOMAIN}/${NC}${CYAN}<ТОКЕН>${NC}${DIM}/HAPP/geoip.dat${NC}"
        auto_token="$(openssl rand -hex 16)"
        echo -e "Сгенерирован случайный токен: ${CYAN}${BOLD}${auto_token}${NC}"
        read -r -p "Введите свой или нажмите Enter: " input_token
        ROUTING_TOKEN="${input_token:-$auto_token}"
        echo -e "${GREEN}✓ Токен сохранён.${NC}\n"

        # ШАГ 6: Порт
        echo -e "${BOLD}--- [Шаг 6] Локальный порт ---${NC}"
        echo -e "${DIM}На этот порт ваш реверс-прокси будет перенаправлять трафик.${NC}"
        read -r -p "Порт [Enter = 8080]: " input_port
        HTTP_PORT="${input_port:-8080}"
        echo -e "${GREEN}✓ Порт: $HTTP_PORT${NC}\n"
    else
        echo -e "${DIM}ℹ️ Шаги «Домен», «Токен» и «Порт» пропущены — в локальном режиме они не нужны.${NC}\n"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 7: Docker-сеть (только если есть смысл)
    # ────────────────────────────────────────────────────────────────────────
    EXT_NETWORK=""
    NEEDS_NETWORK=false

    # Сеть нужна, если: используется HAPP (для Remnawave) ИЛИ пользователь явно настроил Remnawave
    if [[ "$ENABLED_CLIENTS" =~ HAPP ]] || [ -n "$REMNA_BLOCK" ]; then
        NEEDS_NETWORK=true
    fi

    if [ "$NEEDS_NETWORK" = true ]; then
        echo -e "${BOLD}--- [Шаг 7] Подключение к Docker-сети ---${NC}"
        echo -e "${DIM}Если Remnawave или ваш реверс-прокси работает в Docker, подключите контейнер к их общей сети.${NC}"
        read -r -p "Подключить к внешней Docker-сети? [y/N]: " net_choice
        if [[ "$net_choice" =~ ^[YyДд]$ ]]; then
            read -r -p "Имя сети [Enter = remnawave-network]: " input_net
            EXT_NETWORK="${input_net:-remnawave-network}"
            if ! docker network inspect "$EXT_NETWORK" &>/dev/null; then
                echo -e "${YELLOW}Сеть $EXT_NETWORK не найдена. Создаём...${NC}"
                docker network create "$EXT_NETWORK" || true
            fi
            echo -e "${GREEN}✓ Сеть: $EXT_NETWORK${NC}\n"
        else
            echo -e "${DIM}Пропущено. Используется стандартная изолированная сеть.${NC}\n"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 8: Telegram (всегда опционален)
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BOLD}--- [Последний шаг] Telegram-уведомления (опционально) ---${NC}"
    echo -e "${DIM}Бот будет присылать алерты при ошибках синхронизации и (по желанию) отчёты о новых базах.${NC}"
    read -r -p "Настроить Telegram? [y/N]: " tg_choice
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_THREAD_ID=""
    TG_NOTIFY_SUCCESS="false"

    if [[ "$tg_choice" =~ ^[YyДд]$ ]]; then
        read -r -p "TELEGRAM_BOT_TOKEN: " TG_BOT_TOKEN
        read -r -p "TELEGRAM_CHAT_ID (например, -1001234567890): " TG_CHAT_ID
        read -r -p "TELEGRAM_THREAD_ID (ID темы/топика, если чат с темами) [Enter = пропустить]: " TG_THREAD_ID
        read -r -p "Присылать уведомление при выходе новых баз? [y/N]: " tg_success
        if [[ "$tg_success" =~ ^[YyДд]$ ]]; then
            TG_NOTIFY_SUCCESS="true"
        fi
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            test_telegram "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$TG_THREAD_ID" || true
        fi
    fi
    echo -e "${GREEN}✓ Telegram настроен.${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ГЕНЕРАЦИЯ КОНФИГУРАЦИИ
    # ────────────────────────────────────────────────────────────────────────
    echo -e "${BLUE}📦 Создание файлов конфигурации...${NC}"

    # Формируем .env — записываем только заполненные значения
    {
        echo "DOMAIN=${DOMAIN}"
        echo "ROUTING_TOKEN=${ROUTING_TOKEN}"
        echo "ENABLED_CLIENTS=${ENABLED_CLIENTS}"
        [ -n "$PUBLIC_GEO_BASE_URL" ] && echo "PUBLIC_GEO_BASE_URL=${PUBLIC_GEO_BASE_URL}"
        [ -n "$REMNA_BLOCK" ] && printf '%s' "$REMNA_BLOCK"
        echo "HTTP_BIND=127.0.0.1"
        echo "HTTP_PORT=${HTTP_PORT}"
        echo "SCHEDULE=40 8 * * *"
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
    environment:
      DOMAIN: "\${DOMAIN:-${DOMAIN}}"
      ROUTING_TOKEN: "\${ROUTING_TOKEN:-${ROUTING_TOKEN}}"
      ENABLED_CLIENTS: "\${ENABLED_CLIENTS:-${ENABLED_CLIENTS}}"
      PUBLIC_GEO_BASE_URL: "\${PUBLIC_GEO_BASE_URL:-}"
      SCHEDULE: "\${SCHEDULE:-40 8 * * *}"
      SYNC_ON_START: "\${SYNC_ON_START:-true}"
      GEOIP_SOURCE_URL: "\${GEOIP_SOURCE_URL:-}"
      GEOSITE_SOURCE_URL: "\${GEOSITE_SOURCE_URL:-}"
      ROUTING_SOURCE_REPO: "\${ROUTING_SOURCE_REPO:-https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main}"
      TELEGRAM_BOT_TOKEN: "\${TELEGRAM_BOT_TOKEN:-}"
      TELEGRAM_CHAT_ID: "\${TELEGRAM_CHAT_ID:-}"
      TELEGRAM_THREAD_ID: "\${TELEGRAM_THREAD_ID:-}"
      TELEGRAM_NOTIFY_SUCCESS: "\${TELEGRAM_NOTIFY_SUCCESS:-false}"
      REMNAWAVE_BASE_URL: "\${REMNAWAVE_BASE_URL:-}"
      REMNAWAVE_TOKEN: "\${REMNAWAVE_TOKEN:-}"
      REMNAWAVE_GLOBAL_RULE: "\${REMNAWAVE_GLOBAL_RULE:-}"
      REMNAWAVE_SQUAD_1_UUID: "\${REMNAWAVE_SQUAD_1_UUID:-}"
      REMNAWAVE_SQUAD_1_RULE: "\${REMNAWAVE_SQUAD_1_RULE:-}"
      REMNAWAVE_SQUAD_2_UUID: "\${REMNAWAVE_SQUAD_2_UUID:-}"
      REMNAWAVE_SQUAD_2_RULE: "\${REMNAWAVE_SQUAD_2_RULE:-}"
      REMNAWAVE_SQUAD_3_UUID: "\${REMNAWAVE_SQUAD_3_UUID:-}"
      REMNAWAVE_SQUAD_3_RULE: "\${REMNAWAVE_SQUAD_3_RULE:-}"
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

    cp "$0" "$INSTALL_DIR/install.sh" 2>/dev/null || true
    chmod +x "$INSTALL_DIR/install.sh" 2>/dev/null || true
    create_cli_shortcut "$INSTALL_DIR"

    echo -e "${BLUE}🚀 Запуск контейнера Geo Routing Server...${NC}"
    cd "$INSTALL_DIR"
    docker compose up -d

    echo -e "\n${GREEN}${BOLD}===============================================================================${NC}"
    echo -e "${GREEN}${BOLD}🎉 УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
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
        echo -e "Каталог проекта: ${CYAN}$target_dir${NC}"
        
        if docker ps --format '{{.Names}}' | grep -q "^geo-routing-server$"; then
            echo -e "Статус контейнера: ${GREEN}● Запущен и активен${NC}\n"
        else
            echo -e "Статус контейнера: ${RED}○ Остановлен или не существует${NC}\n"
        fi

        echo -e "${BOLD}Выберите действие:${NC}"
        echo "1) 🔄 Синхронизировать базы прямо сейчас"
        echo "2) 📋 Показать публичные ссылки и заголовок autorouting"
        echo "3) 🌐 Показать готовые конфиги для Caddy / Nginx / NPM"
        echo "4) ⚡ Настроить прямую синхронизацию с Remnawave API"
        echo "5) 🔔 Настроить / Изменить Telegram-уведомления"
        echo "6) 🚀 Обновить сервер до последней версии"
        echo "7) 📜 Посмотреть логи контейнера"
        echo "8) ♻️ Перезапустить сервер"
        echo "9) 🛑 Остановить сервер"
        echo "10) 🗑️ Удалить проект с сервера"
        echo "0) 🚪 Выход"
        echo ""
        read -r -p "Введите номер [0-10]: " menu_choice

        case "$menu_choice" in
            1) run_sync_now ;;
            2) show_links ;;
            3) show_proxy_snippets; read -r -p "Нажмите Enter для возврата в меню..." ;;
            4) configure_remnawave ;;
            5) configure_telegram ;;
            6) update_project ;;
            7) view_logs ;;
            8) restart_server ;;
            9) stop_server ;;
            10) uninstall_project ;;
            0) exit 0 ;;
            *) echo -e "${RED}Неверный пункт меню${NC}"; sleep 1 ;;
        esac
    done
}

main() {
    local target_dir
    target_dir="$(get_install_dir)"
    
    if [ -f "$target_dir/compose.yaml" ]; then
        main_menu
    else
        install_wizard
    fi
}

main "$@"
