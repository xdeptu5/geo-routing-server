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
    cat > /usr/local/bin/geo-server <<EOF
#!/usr/bin/env bash
bash "$target_dir/install.sh" "\$@"
EOF
    chmod +x /usr/local/bin/geo-server
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
    echo -e "${GREEN}${BOLD}📋 Публичные ссылки и заголовок для VPN-панелей:${NC}"
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
        rm -f /usr/local/bin/geo-server
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

    echo -e "${BOLD}--- [1/5] Выбор каталога установки ---${NC}"
    echo -e "Вы можете указать стандартную папку или путь для Portainer / стеков."
    read -r -p "Каталог установки [Enter = /opt/geo-routing-server]: " input_dir
    INSTALL_DIR="${input_dir:-/opt/geo-routing-server}"
    mkdir -p "$INSTALL_DIR"
    save_install_dir "$INSTALL_DIR"
    echo -e "${GREEN}✓ Каталог: $INSTALL_DIR${NC}\n"

    echo -e "${BOLD}--- [2/5] Настройка публичного домена ---${NC}"
    read -r -p "Введите домен для HTTPS (например, geo.example.com): " input_domain
    while [ -z "${input_domain:-}" ]; do
        echo -e "${RED}Домен не может быть пустым!${NC}"
        read -r -p "Введите домен: " input_domain
    done
    DOMAIN="$input_domain"
    echo -e "${GREEN}✓ Домен: $DOMAIN${NC}\n"

    echo -e "${BOLD}--- [3/5] Настройка секретного URL-токена ---${NC}"
    auto_token="$(openssl rand -hex 16)"
    echo -e "Сгенерирован случайный токен: ${CYAN}${BOLD}${auto_token}${NC}"
    read -r -p "Введите свой токен или нажмите Enter для использования сгенерированного: " input_token
    ROUTING_TOKEN="${input_token:-$auto_token}"
    echo -e "${GREEN}✓ Токен сохранён.${NC}\n"

    echo -e "${BOLD}--- [4/5] Выбор активных клиентов ---${NC}"
    echo "1) HAPP + INCY (Раздавать базы и конфиги для обоих клиентов)"
    echo "2) Только INCY (Базы + JSON + DEEPLINK)"
    echo "3) Только HAPP (Только geoip.dat и geosite.dat)"
    read -r -p "Выберите вариант [1-3, Enter = 1]: " client_choice
    client_choice="${client_choice:-1}"
    case "$client_choice" in
        2) ENABLED_CLIENTS="INCY" ;;
        3) ENABLED_CLIENTS="HAPP" ;;
        *) ENABLED_CLIENTS="HAPP,INCY" ;;
    esac
    echo -e "${GREEN}✓ Клиенты: $ENABLED_CLIENTS${NC}\n"

    echo -e "${BOLD}--- [5/5] Настройка локального порта ---${NC}"
    read -r -p "Локальный порт для Caddy / Nginx [Enter = 8080]: " input_port
    HTTP_PORT="${input_port:-8080}"
    echo -e "${GREEN}✓ Порт: $HTTP_PORT${NC}\n"

    echo -e "${BLUE}📦 Создание файлов конфигурации...${NC}"

    # Создание .env
    cat > "$INSTALL_DIR/.env" <<EOF
DOMAIN=${DOMAIN}
ROUTING_TOKEN=${ROUTING_TOKEN}
ENABLED_CLIENTS=${ENABLED_CLIENTS}
HTTP_BIND=127.0.0.1
HTTP_PORT=${HTTP_PORT}
SCHEDULE=40 8 * * *
SYNC_ON_START=true
EOF

    # Создание compose.yaml
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
      SCHEDULE: "\${SCHEDULE:-40 8 * * *}"
      SYNC_ON_START: "\${SYNC_ON_START:-true}"
      GEOIP_SOURCE_URL: "\${GEOIP_SOURCE_URL:-}"
      GEOSITE_SOURCE_URL: "\${GEOSITE_SOURCE_URL:-}"
      ROUTING_SOURCE_REPO: "\${ROUTING_SOURCE_REPO:-https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main}"
      TELEGRAM_BOT_TOKEN: "\${TELEGRAM_BOT_TOKEN:-}"
      TELEGRAM_CHAT_ID: "\${TELEGRAM_CHAT_ID:-}"
      TELEGRAM_NOTIFY_SUCCESS: "\${TELEGRAM_NOTIFY_SUCCESS:-false}"
    ports:
      - "\${HTTP_BIND:-127.0.0.1}:\${HTTP_PORT:-${HTTP_PORT}}:80"
    volumes:
      - routing_data:/app/www
      - ./.cache:/app/.cache
      - ./custom_geo:/app/custom_geo:ro
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  routing_data:
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
    echo -e "Быстрый вызов меню в терминале: команда ${CYAN}${BOLD}geo-server${NC}\n"
    
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
        echo "3) 🚀 Обновить сервер до последней версии"
        echo "4) 📜 Посмотреть логи контейнера"
        echo "5) 🔄 Перезапустить сервер"
        echo "6) 🛑 Остановить сервер"
        echo "7) 🗑️ Удалить проект с сервера"
        echo "0) 🚪 Выход"
        echo ""
        read -r -p "Введите номер [0-7]: " menu_choice

        case "$menu_choice" in
            1) run_sync_now ;;
            2) show_links ;;
            3) update_project ;;
            4) view_logs ;;
            5) restart_server ;;
            6) stop_server ;;
            7) uninstall_project ;;
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
