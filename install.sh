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
    
    # Проверка curl и openssl
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

    # Проверка Docker
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

    # Проверка Docker Compose
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
    
    # Дополнительные симлинки для гарантированного доступа из любой оболочки
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

    # Если включен только локальный генератор Remnawave, прокси настраивать не обязательно
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

    # Обновляем .env файл
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

install_wizard() {
    print_header
    check_root
    check_dependencies

    echo -e "${BOLD}--- [1/7] Выбор каталога установки ---${NC}"
    echo -e "Вы можете указать стандартную папку или каталог ваших стеков (Arcane, Portainer, Dockge, 1Panel и др.)."
    read -r -p "Каталог установки [Enter = /opt/geo-routing-server]: " input_dir
    INSTALL_DIR="${input_dir:-/opt/geo-routing-server}"
    mkdir -p "$INSTALL_DIR"
    save_install_dir "$INSTALL_DIR"
    echo -e "${GREEN}✓ Каталог: $INSTALL_DIR${NC}\n"

    echo -e "${BOLD}--- [2/7] Выбор активных модулей ---${NC}"
    echo "1) HAPP + INCY (Полный сервер всё-в-одном: базы + автороутинг + диплинки)"
    echo "2) Только INCY (Автороутинг + Geo-базы для Incy)"
    echo "3) HAPP: Только генератор для Remnawave (локальные диплинки, без раздачи баз)"
    echo "4) HAPP: Только публичная раздача Geo-баз (Geo Node)"
    echo "5) HAPP: Полный (локальный генератор + раздача баз)"
    read -r -p "Выберите вариант [1-5, Enter = 1]: " client_choice
    client_choice="${client_choice:-1}"
    
    PUBLIC_GEO_BASE_URL=""
    case "$client_choice" in
        2) ENABLED_CLIENTS="INCY" ;;
        3) 
            ENABLED_CLIENTS="HAPP_DEEPLINK"
            echo -e "\n${CYAN}Опционально: укажите URL к внешнему серверу баз (если базы на другом сервере).${NC}"
            read -r -p "PUBLIC_GEO_BASE_URL [Enter = использовать исходные источники]: " input_geo_url
            PUBLIC_GEO_BASE_URL="${input_geo_url:-}"
            ;;
        4) ENABLED_CLIENTS="HAPP_GEO" ;;
        5) ENABLED_CLIENTS="HAPP" ;;
        *) ENABLED_CLIENTS="HAPP,INCY" ;;
    esac
    echo -e "${GREEN}✓ Режим: $ENABLED_CLIENTS${NC}\n"

    echo -e "${BOLD}--- [3/7] Настройка публичного домена ---${NC}"
    read -r -p "Введите домен для HTTPS (например, geo.example.com): " input_domain
    DOMAIN="${input_domain:-geo.example.com}"
    echo -e "${GREEN}✓ Домен: $DOMAIN${NC}\n"

    echo -e "${BOLD}--- [4/7] Настройка секретного URL-токена ---${NC}"
    auto_token="$(openssl rand -hex 16)"
    echo -e "Сгенерирован случайный токен: ${CYAN}${BOLD}${auto_token}${NC}"
    read -r -p "Введите свой токен или нажмите Enter для использования сгенерированного: " input_token
    ROUTING_TOKEN="${input_token:-$auto_token}"
    echo -e "${GREEN}✓ Токен сохранён.${NC}\n"

    echo -e "${BOLD}--- [5/7] Настройка локального порта ---${NC}"
    read -r -p "Локальный порт для Caddy / Nginx [Enter = 8080]: " input_port
    HTTP_PORT="${input_port:-8080}"
    echo -e "${GREEN}✓ Порт: $HTTP_PORT${NC}\n"

    echo -e "${BOLD}--- [6/7] Подключение к общей Docker-сети (Remnawave / Прокси) ---${NC}"
    read -r -p "Подключить к внешней Docker-сети (например, remnawave-network)? [y/N]: " net_choice
    EXT_NETWORK=""
    if [[ "$net_choice" =~ ^[YyДд]$ ]]; then
        read -r -p "Введите имя внешней Docker-сети [Enter = remnawave-network]: " input_net
        EXT_NETWORK="${input_net:-remnawave-network}"
        if ! docker network inspect "$EXT_NETWORK" &>/dev/null; then
            echo -e "${YELLOW}Сеть $EXT_NETWORK не найдена. Создаём...${NC}"
            docker network create "$EXT_NETWORK" || true
        fi
        echo -e "${GREEN}✓ Сеть: $EXT_NETWORK${NC}\n"
    else
        echo -e "${CYAN}Используется стандартная изолированная сеть.${NC}\n"
    fi

    echo -e "${BOLD}--- [7/7] Настройка Telegram-уведомлений (Опционально) ---${NC}"
    read -r -p "Хотите настроить Telegram-уведомления об ошибках и обновлениях? [y/N]: " tg_choice
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_THREAD_ID=""
    TG_NOTIFY_SUCCESS="false"

    if [[ "$tg_choice" =~ ^[YyДд]$ ]]; then
        read -r -p "Введите TELEGRAM_BOT_TOKEN: " TG_BOT_TOKEN
        read -r -p "Введите TELEGRAM_CHAT_ID (например, -1001234567890 или 123456789): " TG_CHAT_ID
        read -r -p "Введите TELEGRAM_THREAD_ID (ID темы/топика, если чат с темами) [Enter = пропустить]: " TG_THREAD_ID
        read -r -p "Присылать уведомление при выходе новых баз? [y/N]: " tg_success
        if [[ "$tg_success" =~ ^[YyДд]$ ]]; then
            TG_NOTIFY_SUCCESS="true"
        fi
        if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
            test_telegram "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$TG_THREAD_ID" || true
        fi
    fi
    echo -e "${GREEN}✓ Telegram настроен.${NC}\n"

    echo -e "${BLUE}📦 Создание файлов конфигурации...${NC}"

    # Создание .env
    cat > "$INSTALL_DIR/.env" <<EOF
DOMAIN=${DOMAIN}
ROUTING_TOKEN=${ROUTING_TOKEN}
ENABLED_CLIENTS=${ENABLED_CLIENTS}
PUBLIC_GEO_BASE_URL=${PUBLIC_GEO_BASE_URL}
HTTP_BIND=127.0.0.1
HTTP_PORT=${HTTP_PORT}
SCHEDULE=40 8 * * *
SYNC_ON_START=true
TELEGRAM_BOT_TOKEN=${TG_BOT_TOKEN}
TELEGRAM_CHAT_ID=${TG_CHAT_ID}
TELEGRAM_THREAD_ID=${TG_THREAD_ID}
TELEGRAM_NOTIFY_SUCCESS=${TG_NOTIFY_SUCCESS}
EOF

    # Формирование compose.yaml с учетом внешней сети
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
      PUBLIC_GEO_BASE_URL: "\${PUBLIC_GEO_BASE_URL:-${PUBLIC_GEO_BASE_URL}}"
      SCHEDULE: "\${SCHEDULE:-40 8 * * *}"
      SYNC_ON_START: "\${SYNC_ON_START:-true}"
      GEOIP_SOURCE_URL: "\${GEOIP_SOURCE_URL:-}"
      GEOSITE_SOURCE_URL: "\${GEOSITE_SOURCE_URL:-}"
      ROUTING_SOURCE_REPO: "\${ROUTING_SOURCE_REPO:-https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main}"
      TELEGRAM_BOT_TOKEN: "\${TELEGRAM_BOT_TOKEN:-}"
      TELEGRAM_CHAT_ID: "\${TELEGRAM_CHAT_ID:-}"
      TELEGRAM_THREAD_ID: "\${TELEGRAM_THREAD_ID:-}"
      TELEGRAM_NOTIFY_SUCCESS: "\${TELEGRAM_NOTIFY_SUCCESS:-false}"
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

    # Копируем сам скрипт в каталог для последующего вызова
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
    
    show_proxy_snippets
    show_links
}

main_menu() {
    while true; do
        print_header
        local target_dir
        target_dir="$(get_install_dir)"
        echo -e "Каталог проекта: ${CYAN}$target_dir${NC}"
        
        # Проверка статуса контейнера
        if docker ps --format '{{.Names}}' | grep -q "^geo-routing-server$"; then
            echo -e "Статус контейнера: ${GREEN}● Запущен и активен${NC}\n"
        else
            echo -e "Статус контейнера: ${RED}○ Остановлен или не существует${NC}\n"
        fi

        echo -e "${BOLD}Выберите действие:${NC}"
        echo "1) 🔄 Синхронизировать базы прямо сейчас"
        echo "2) 📋 Показать публичные ссылки и заголовок autorouting"
        echo "3) 🌐 Показать готовые конфиги для Caddy / Nginx / NPM"
        echo "4) 🔔 Настроить / Изменить Telegram-уведомления (с тестом темы/топика)"
        echo "5) 🚀 Обновить сервер до последней версии"
        echo "6) 📜 Посмотреть логи контейнера"
        echo "7) 🔄 Перезапустить сервер"
        echo "8) 🛑 Остановить сервер"
        echo "9) 🗑️ Удалить проект с сервера"
        echo "0) 🚪 Выход"
        echo ""
        read -r -p "Введите номер [0-9]: " menu_choice

        case "$menu_choice" in
            1) run_sync_now ;;
            2) show_links ;;
            3) show_proxy_snippets; read -r -p "Нажмите Enter для возврата в меню..." ;;
            4) configure_telegram ;;
            5) update_project ;;
            6) view_logs ;;
            7) restart_server ;;
            8) stop_server ;;
            9) uninstall_project ;;
            0) exit 0 ;;
            *) echo -e "${RED}Неверный пункт меню${NC}"; sleep 1 ;;
        esac
    done
}

# Точка входа: если проект уже установлен, открываем меню, иначе мастер установки
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
