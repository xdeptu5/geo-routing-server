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
    if [ "$code" -eq 130 ] || [ "$code" -eq 143 ]; then
        tput cnorm 2>/dev/null || true
        echo ""
        exit "$code"
    fi
    trap '' ERR

    echo -e "\n${RED}${BOLD}===============================================================================${NC}"
    if [ "${UI_LANG:-ru}" = "en" ]; then
        echo -e "${RED}[!] An error occurred during execution (exit code $code, line $line).${NC}"
        echo -e "${YELLOW}What would you like to do?${NC}"
        echo "  1) Open management menu (geoserver)"
        echo "  2) Start setup again from scratch"
        echo "  3) Completely remove geo-routing-server"
        echo "  4) Exit to shell"
        read -r -p "Select option [1-4, Enter = 1]: " err_choice
    else
        echo -e "${RED}[!] Произошла ошибка во время выполнения (код $code, строка $line).${NC}"
        echo -e "${YELLOW}Что вы хотите сделать?${NC}"
        echo "  1) Открыть главное меню управления (geoserver)"
        echo "  2) Начать настройку заново (с чистого листа)"
        echo "  3) Полностью удалить geo-routing-server"
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
    local raw_items=("$@")

    # Разделяем пункты на визуальные строки и доступные для выбора действия
    local action_count=0
    local visual_items=()
    local is_header=()
    local action_num=()
    local action_to_visual=()
    local visual_to_action=()

    for line in "${raw_items[@]}"; do
        local v_idx=${#visual_items[@]}
        visual_items+=("$line")
        if [[ "$line" =~ ^HEADER:(.*) ]]; then
            is_header+=(1)
            action_num+=(0)
            visual_to_action+=(-1)
        else
            is_header+=(0)
            action_count=$((action_count + 1))
            action_num+=($action_count)
            action_to_visual+=($v_idx)
            visual_to_action+=($((action_count - 1)))
        fi
    done

    # Защита: если нет действий
    if [ "$action_count" -eq 0 ]; then
        echo "0"
        return 0
    fi

    local selected=$default_idx
    if [ "$selected" -ge "$action_count" ] || [ "$selected" -lt 0 ]; then
        selected=0
    fi

    # Определяем источник интерактивного терминального ввода
    local tty_in=""
    if [ -t 0 ]; then
        tty_in="/dev/stdin"
    elif [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
        tty_in="/dev/tty"
    fi

    # Fallback только для чисто неинтерактивного окружения (CI, тесты без tty)
    if [ -z "$tty_in" ]; then
        echo -e "$prompt_title" >&2
        for v in "${!visual_items[@]}"; do
            if [ "${is_header[v]}" -eq 1 ]; then
                local title="${visual_items[v]#HEADER:}"
                echo -e "\n  --- $title ---" >&2
            else
                echo -e "  ${action_num[v]}) ${visual_items[v]}" >&2
            fi
        done
        local fallback_pick=""
        read -r -p "> " fallback_pick || true
        fallback_pick="${fallback_pick:-$((default_idx + 1))}"
        if [[ "$fallback_pick" =~ ^[0-9]+$ ]] && [ "$fallback_pick" -ge 1 ] && [ "$fallback_pick" -le "$action_count" ]; then
            echo "$((fallback_pick - 1))"
        else
            echo "$default_idx"
        fi
        return 0
    fi

    # Скрываем курсор
    tput civis >&2 2>/dev/null || printf "\033[?25l" >&2

    cleanup_tui_cursor() {
        tput cnorm >&2 2>/dev/null || printf "\033[?25h" >&2
    }
    trap cleanup_tui_cursor EXIT INT TERM

    local num_fmt="%d"
    [ "$action_count" -ge 10 ] && num_fmt="%2d"
    local input_buf=""
    local total_visual_lines=${#visual_items[@]}

    draw_tui_menu() {
        echo -e "$prompt_title" >&2
        for v in "${!visual_items[@]}"; do
            if [ "${is_header[v]}" -eq 1 ]; then
                local title="${visual_items[v]#HEADER:}"
                local title_len=${#title}
                local right_dashes_count=$(( 51 - title_len ))
                [ "$right_dashes_count" -lt 3 ] && right_dashes_count=3
                local right_dashes=""
                for ((d=0; d<right_dashes_count; d++)); do
                    right_dashes="${right_dashes}─"
                done
                printf "  \033[0;36m── \033[1;37m%s \033[0;36m%s\033[0m\n" "$title" "$right_dashes" >&2
            else
                local num="${action_num[v]}"
                local act_idx="${visual_to_action[v]}"
                local text="${visual_items[v]}"
                if [ "$act_idx" -eq "$selected" ]; then
                    printf "  \033[1;36m▸ \033[1;37m${num_fmt})\033[1;36m %s\033[0m\n" "$num" "$text" >&2
                else
                    printf "    \033[2m${num_fmt})\033[0m \033[0;37m%s\033[0m\n" "$num" "$text" >&2
                fi
            fi
        done

        if [ -n "$input_buf" ]; then
            if [ "${UI_LANG:-ru}" = "en" ]; then
                printf "  \033[1;33m[Input: %s]\033[0m \033[2m[Enter] Confirm   [Backspace] Clear   [↑/↓] Navigate\033[0m\n" "$input_buf" >&2
            else
                printf "  \033[1;33m[Введено: %s]\033[0m \033[2m[Enter] Подтвердить   [Backspace] Стереть   [↑/↓] Выбор\033[0m\n" "$input_buf" >&2
            fi
        else
            if [ "${UI_LANG:-ru}" = "en" ]; then
                printf "  \033[2m[↑/↓] Navigate   [Enter] Select   [1-%d] Number\033[0m\n" "$action_count" >&2
            else
                printf "  \033[2m[↑/↓] Выбор   [Enter] Подтвердить   [1-%d] Номер пункта\033[0m\n" "$action_count" >&2
            fi
        fi
    }

    draw_tui_menu

    while true; do
        local key=""
        IFS= read -rsn1 key < "$tty_in" 2>/dev/null || true
        if [ "$key" = $'\x1b' ]; then
            local rest=""
            read -rsn2 -t 0.1 rest < "$tty_in" 2>/dev/null || true
            key="$key$rest"
        fi

        case "$key" in
            $'\x1b[A'|$'\x1bOA'|'k'|'K') # Вверх
                input_buf=""
                selected=$(( (selected - 1 + action_count) % action_count ))
                ;;
            $'\x1b[B'|$'\x1bOB'|'j'|'J') # Вниз
                input_buf=""
                selected=$(( (selected + 1) % action_count ))
                ;;
            "") # Enter
                break
                ;;
            " ") # Пробел
                break
                ;;
            $'\x7f'|$'\x08') # Backspace
                if [ -n "$input_buf" ]; then
                    input_buf="${input_buf%?}"
                    if [ -n "$input_buf" ] && [ "$input_buf" -ge 1 ] && [ "$input_buf" -le "$action_count" ]; then
                        selected=$((input_buf - 1))
                    fi
                fi
                ;;
            [0-9]) # Накопление номера пункта (без автотаймаута, подтверждение по Enter)
                local candidate="${input_buf}${key}"
                candidate="$(echo "$candidate" | sed 's/^0*//')"
                if [ -n "$candidate" ] && [ "$candidate" -ge 1 ] && [ "$candidate" -le "$action_count" ]; then
                    input_buf="$candidate"
                    selected=$((candidate - 1))
                elif [ "$key" -ge 1 ] && [ "$key" -le "$action_count" ]; then
                    input_buf="$key"
                    selected=$((key - 1))
                fi
                ;;
            $'\x03') # Ctrl+C
                cleanup_tui_cursor
                exit 130
                ;;
        esac

        # Стираем меню для перерисовки
        local lines_to_clear=$((total_visual_lines + 2))
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
    local total_lines=$((total_visual_lines + 2))
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

    selected="$(echo "$selected" | tr -cd '0-9')"
    echo "$selected"
}

# Ввод с маскированием паролей и токенов (не оставляет секреты на экране)
tui_secret() {
    local prompt_label="$1"
    local current_val="${2:-}"
    local prompt_text=""
    if [ -n "$current_val" ]; then
        prompt_text="${prompt_label} (ввод скрыт, Enter = оставить прежний): "
    else
        prompt_text="${prompt_label} (ввод скрыт, вставьте и нажмите Enter): "
    fi

    local tty_in=""
    if [ -t 0 ]; then
        tty_in="/dev/stdin"
    elif [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
        tty_in="/dev/tty"
    fi

    local secret_input=""
    if [ -n "$tty_in" ]; then
        read -rs -p "$(echo -e "$prompt_text")" secret_input < "$tty_in"
        echo "" >&2
    else
        read -r secret_input || true
    fi
    secret_input="${secret_input:-$current_val}"

    # Визуальное подтверждение для пользователя
    if [ -n "$secret_input" ]; then
        if [ "$secret_input" = "$current_val" ] && [ -n "$current_val" ]; then
            echo -e "  ${GREEN}[+] Токен сохранён (без изменений)${NC}" >&2
        else
            echo -e "  ${GREEN}[+] Токен принят (${#secret_input} симв.)${NC}" >&2
        fi
    else
        echo -e "  ${YELLOW}[i] Токен не указан${NC}" >&2
    fi

    echo "$secret_input"
}

# Умный поиск активных сетей Docker
detect_docker_networks() {
    if ! command -v docker &>/dev/null; then
        return
    fi
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -vE '^(bridge|host|none|geo-routing-server_default)$' || true
}

# Проверка, запущен ли контейнер Remnawave на этом же сервере
detect_remnawave_running() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qi "remna" && return 0
    return 1
}

# Загрузка списка внешних сквадов из Remnawave в формате "UUID|NAME"
fetch_remnawave_external_squads() {
    local base_url="${1:-}"
    local token="${2:-}"
    local cf_id="${3:-}"
    local cf_secret="${4:-}"

    # 1. Если запущен контейнер geo-routing-server, вызываем Python внутри контейнера
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^geo-routing-server$"; then
        local out
        out=$(docker exec geo-routing-server python3 -c "
from app.remnawave import RemnawaveSync
res = RemnawaveSync._api_request('GET', RemnawaveSync.get_api_url() + '/external-squads')
if res:
    raw = res.get('response', res.get('data', []))
    if isinstance(raw, dict):
        raw = raw.get('externalSquads', raw.get('items', []))
    if isinstance(raw, list):
        for s in raw:
            if isinstance(s, dict) and 'uuid' in s:
                u = str(s['uuid']).lower()
                n = str(s.get('name', '')).strip()
                print(f'{u}|{n}')
" 2>/dev/null || true)
        if [ -n "$out" ]; then
            echo "$out"
            return 0
        fi
    fi

    # 2. Если контейнер ещё не запущен, пробуем через curl с хоста
    if [ -n "$base_url" ] && [ -n "$token" ] && command -v curl &>/dev/null; then
        local api_url="${base_url%/}"
        [[ "$api_url" != */api ]] && api_url="${api_url}/api"

        local curl_headers=(-H "Authorization: Bearer $token" -H "Accept: application/json")
        [ -n "$cf_id" ] && curl_headers+=(-H "CF-Access-Client-Id: $cf_id")
        [ -n "$cf_secret" ] && curl_headers+=(-H "CF-Access-Client-Secret: $cf_secret")

        local json_res
        json_res=$(curl -s -f -m 3 "${curl_headers[@]}" "${api_url}/external-squads" 2>/dev/null || true)
        if [ -n "$json_res" ] && command -v python3 &>/dev/null; then
            python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    raw = data.get('response', data.get('data', []))
    if isinstance(raw, dict):
        raw = raw.get('externalSquads', raw.get('items', []))
    if isinstance(raw, list):
        for s in raw:
            if isinstance(s, dict) and 'uuid' in s:
                u = str(s['uuid']).lower()
                n = str(s.get('name', '')).strip()
                print(f'{u}|{n}')
except Exception:
    pass
" "$json_res" 2>/dev/null || true
        fi
    fi
}

# Автоматическая синхронизация названий сквадов в .env при переименовании в Remnawave
refresh_squad_names_in_env() {
    local target_dir
    target_dir="$(get_install_dir)"
    local env_file="$target_dir/.env"
    [ ! -f "$env_file" ] && return 0

    local remna_base remna_token cf_id cf_secret
    remna_base=$(grep "^REMNAWAVE_BASE_URL=" "$env_file" | cut -d'=' -f2- || true)
    remna_token=$(grep "^REMNAWAVE_TOKEN=" "$env_file" | cut -d'=' -f2- || true)
    cf_id=$(grep "^CLOUDFLARE_ZERO_TRUST_CLIENT_ID=" "$env_file" | cut -d'=' -f2- || true)
    cf_secret=$(grep "^CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=" "$env_file" | cut -d'=' -f2- || true)
    [ -z "$remna_base" ] || [ -z "$remna_token" ] && return 0

    local ext_squads_raw
    ext_squads_raw=$(fetch_remnawave_external_squads "$remna_base" "$remna_token" "$cf_id" "$cf_secret")
    [ -z "$ext_squads_raw" ] && return 0

    local count_squads
    count_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$env_file" || true)
    [ "$count_squads" -le 0 ] && return 0

    for ((i=1; i<=count_squads; i++)); do
        local u old_n live_n
        u=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$env_file" | cut -d'=' -f2- || true)
        old_n=$(grep "^REMNAWAVE_SQUAD_${i}_NAME=" "$env_file" | cut -d'=' -f2- || true)
        [ -z "$u" ] && continue
        live_n=$(echo "$ext_squads_raw" | grep -i "^${u}|" | cut -d'|' -f2- || true)
        if [ -n "$live_n" ] && [ "$live_n" != "$old_n" ]; then
            local escaped_live
            escaped_live=$(printf '%s\n' "$live_n" | sed -e 's/[\/&]/\\&/g')
            if grep -q "^REMNAWAVE_SQUAD_${i}_NAME=" "$env_file"; then
                sed -i "s/^REMNAWAVE_SQUAD_${i}_NAME=.*/REMNAWAVE_SQUAD_${i}_NAME=${escaped_live}/" "$env_file"
            else
                sed -i "/^REMNAWAVE_SQUAD_${i}_UUID=/a REMNAWAVE_SQUAD_${i}_NAME=${escaped_live}" "$env_file"
            fi
        fi
    done
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
    if [ "${UI_LANG:-ru}" = "en" ]; then
        echo "╭─────────────────────────────────────────────────────────────────────────────╮"
        echo "│                         GEO ROUTING SERVER MANAGER                          │"
        echo "│           Automated routing rules & geo-databases for Happ & Incy           │"
        echo "╰─────────────────────────────────────────────────────────────────────────────╯"
    else
        echo "╭─────────────────────────────────────────────────────────────────────────────╮"
        echo "│                         GEO ROUTING SERVER MANAGER                          │"
        echo "│            Автоматическая маршрутизация и гео-базы для Happ & Incy          │"
        echo "╰─────────────────────────────────────────────────────────────────────────────╯"
    fi
    echo -e "${NC}"
}

ui_step() {
    local step_str="$1"
    local title="$2"
    local total_len=75
    local prefix="  ◆ [Шаг $step_str] $title "
    local pre_len=${#prefix}
    local dashes_cnt=$(( total_len - pre_len ))
    [ "$dashes_cnt" -lt 3 ] && dashes_cnt=3
    local dashes=""
    for ((d=0; d<dashes_cnt; d++)); do dashes="${dashes}─"; done
    echo -e "\n\033[1;36m${prefix}\033[0;36m${dashes}\033[0m"
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
if [ ! -s "\$TARGET_SCRIPT" ] || ! grep -q "Geo Routing Server" "\$TARGET_SCRIPT" 2>/dev/null; then
    mkdir -p "$target_dir"
    curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "\$TARGET_SCRIPT" 2>/dev/null || true
    chmod +x "\$TARGET_SCRIPT" 2>/dev/null || true
fi
exec bash "\$TARGET_SCRIPT" "\$@"
EOF
    chmod +x "$wrapper_script"
    
    ln -sf "$wrapper_script" /usr/bin/geo-server 2>/dev/null || true
    ln -sf "$wrapper_script" /usr/local/bin/geoserver 2>/dev/null || true
    ln -sf "$wrapper_script" /usr/bin/geoserver 2>/dev/null || true
}

pause_menu() {
    local prompt_msg="${1:-}"
    if [ -z "$prompt_msg" ]; then
        if [ "${UI_LANG:-ru}" = "en" ]; then
            prompt_msg="Press Enter to return to main menu..."
        else
            prompt_msg="Нажмите Enter для возврата в главное меню..."
        fi
    fi

    echo -e "\n${YELLOW}${BOLD}${prompt_msg}${NC}"
    if [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; then
        read -r _ < /dev/tty || true
    elif [ -t 0 ]; then
        read -r _ || true
    fi
}

run_sync_now() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Запуск внеочередной синхронизации правил и баз...${NC}"
    if docker exec geo-routing-server python3 -m app.main; then
        echo -e "${GREEN}[+] Синхронизация успешно выполнена!${NC}\n"
        refresh_squad_names_in_env 2>/dev/null || true
    else
        echo -e "${RED}[!] Ошибка синхронизации. Проверьте логи: geo-server logs${NC}\n"
    fi
    pause_menu
}

show_links() {
    local target_dir
    target_dir="$(get_install_dir)"
    refresh_squad_names_in_env 2>/dev/null || true
    echo -e "${GREEN}${BOLD}[i] Публичные ссылки и интеграции:${NC}"
    docker exec geo-routing-server python3 -c "
from app.config import Config
from app.main import print_summary_banner
print_summary_banner(Config.get_token())
" || {
        echo -e "${YELLOW}[!] Не удалось получить ссылки напрямую из контейнера. Проверьте логи: docker compose logs${NC}"
    }
    echo -e "\n${DIM}💎 Поддержать проект / Donations: https://github.com/xdeptu5/geo-routing-server#-%D0%BF%D0%BE%D0%B4%D0%B4%D0%B5%D1%80%D0%B6%D0%B0%D1%82%D1%8C-%D0%BF%D1%80%D0%BE%D0%B5%D0%BA%D1%82-donations${NC}"
    pause_menu
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
        pause_menu
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
    pause_menu
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
    echo -e "${YELLOW}${BOLD}[!] ВНИМАНИЕ:${NC} ${YELLOW}В панели Remnawave используйте вкладку ${GREEN}${BOLD}«Внешние сквады»${NC}${YELLOW} (External Squads)!${NC}"
    echo -e "${YELLOW}    Не используйте «Внутренние сквады» — они не поддерживают маршрутизацию подписок Happ.${NC}"

    echo -e "${BLUE}[*] Загрузка списка внешних сквадов из Remnawave...${NC}"
    local ext_squads_raw
    ext_squads_raw=$(fetch_remnawave_external_squads "$input_base" "$input_token")
    if [ -n "$ext_squads_raw" ]; then
        echo -e "${GREEN}[+] В Remnawave обнаружены следующие внешние сквады:${NC}"
        while IFS='|' read -r su sn; do
            [ -z "$su" ] && continue
            echo -e "      • ${BOLD}${sn:-Без имени}${NC} (${DIM}${su}${NC})"
        done <<< "$ext_squads_raw"
    fi

    local squads_env=""
    for ((i=1; i<=count_squads; i++)); do
        local prev_sq_uuid=""
        local prev_sq_name=""
        local prev_sq_rule=""
        if [ -f "$env_file" ]; then
            prev_sq_uuid=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$env_file" | cut -d'=' -f2- || true)
            prev_sq_name=$(grep "^REMNAWAVE_SQUAD_${i}_NAME=" "$env_file" | cut -d'=' -f2- || true)
            prev_sq_rule=$(grep "^REMNAWAVE_SQUAD_${i}_RULE=" "$env_file" | cut -d'=' -f2- || true)
        if [ -n "$prev_sq_uuid" ] && [ -n "$ext_squads_raw" ]; then
            local live_match
            live_match=$(echo "$ext_squads_raw" | grep -i "^${prev_sq_uuid}|" | cut -d'|' -f2- || true)
            [ -n "$live_match" ] && prev_sq_name="$live_match"
        fi

        local header_title=""
        [ -n "$prev_sq_name" ] && header_title=": ${BOLD}${prev_sq_name}${NC}${CYAN}"
        echo -e "\n${CYAN}── Сквад #$i${header_title} ──${NC}"
        local sq_hint="панель Remnawave → Сквады → Внешние сквады"
        if [ -n "$prev_sq_uuid" ]; then
            if [ -n "$prev_sq_name" ]; then
                sq_hint="${prev_sq_name} (${prev_sq_uuid})"
            else
                sq_hint="$prev_sq_uuid"
            fi
        fi
        read -r -p "  ▸ UUID внешнего сквада [${sq_hint}]: " sq_uuid
        sq_uuid="${sq_uuid:-$prev_sq_uuid}"

        local sq_name="$prev_sq_name"
        if [ -n "$ext_squads_raw" ]; then
            local matched_name
            matched_name=$(echo "$ext_squads_raw" | grep -i "^${sq_uuid}|" | cut -d'|' -f2- || true)
            [ -n "$matched_name" ] && sq_name="$matched_name"
        fi

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
        local s_display_label="${sq_uuid}"
        [ -n "$sq_name" ] && s_display_label="'${sq_name}' (${sq_uuid})"
        echo -e "  ${GREEN}[+] Сквад #$i: ${s_display_label} → ${sq_rule}${NC}"

        squads_env="${squads_env}REMNAWAVE_SQUAD_${i}_UUID=${sq_uuid}
REMNAWAVE_SQUAD_${i}_NAME=${sq_name}
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
        local saved_net
        saved_net=$(grep "^DOCKER_NETWORK=" "$env_file" | cut -d'=' -f2- || true)
        local remna_net="${saved_net:-remnawave-network}"
        if docker network inspect "$remna_net" &>/dev/null; then
            if ! docker inspect geo-routing-server --format '{{json .NetworkSettings.Networks}}' 2>/dev/null | grep -q "$remna_net"; then
                docker network connect "$remna_net" geo-routing-server 2>/dev/null || true
            fi
        fi
        docker exec geo-routing-server run-routing-sync 2>/dev/null || true
        echo -e "${GREEN}[+] Готово! Правила обновлены и отправлены в Remnawave.${NC}\n"
    fi
    pause_menu
}

update_script_only() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Скачивание последней версии скрипта управления из GitHub...${NC}"
    
    if curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$target_dir/install.sh.new" 2>/dev/null; then
        if bash -n "$target_dir/install.sh.new" 2>/dev/null; then
            mv "$target_dir/install.sh.new" "$target_dir/install.sh"
            chmod +x "$target_dir/install.sh"
            create_cli_shortcut "$target_dir"
            echo -e "${GREEN}[+] Скрипт управления (меню и CLI) успешно обновлён!${NC}\n"
        else
            rm -f "$target_dir/install.sh.new"
            echo -e "${RED}[!] Скачанный скрипт содержит ошибки синтаксиса. Обновление отменено.${NC}\n"
        fi
    else
        echo -e "${RED}[!] Не удалось загрузить скрипт. Проверьте интернет-соединение.${NC}\n"
    fi
    pause_menu "Нажмите Enter для перезапуска меню..."
    exec bash "$target_dir/install.sh"
}

update_project() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Загрузка и обновление Docker-образа...${NC}"
    
    # Также обновляем сам скрипт с проверкой целостности
    if curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$target_dir/install.sh.new" 2>/dev/null; then
        if bash -n "$target_dir/install.sh.new" 2>/dev/null; then
            mv "$target_dir/install.sh.new" "$target_dir/install.sh"
            chmod +x "$target_dir/install.sh"
            create_cli_shortcut "$target_dir"
        else
            rm -f "$target_dir/install.sh.new"
        fi
    fi

    # Удаляем устаревший симлинк, чтобы избежать конфликтов и предупреждений compose
    rm -f "$target_dir/docker-compose.yml" 2>/dev/null || true

    cd "$target_dir"
    set +e
    local pull_out
    pull_out=$(docker compose pull 2>&1)
    local pull_status=$?
    set -e

    if [ "$pull_status" -ne 0 ]; then
        echo -e "\n${RED}[!] Ошибка при загрузке нового Docker-образа:${NC}"
        echo "$pull_out"
        echo -e "\n${YELLOW}[i] Текущий контейнер продолжает работу без изменений.${NC}"
        pause_menu
        return 1
    fi

    docker compose up -d
    echo -e "${GREEN}[+] Контейнер и скрипт успешно обновлены до последней версии!${NC}\n"
    pause_menu "Нажмите Enter для перезапуска меню..."
    exec bash "$target_dir/install.sh"
}

view_logs() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${BLUE}[*] Просмотр последних логов (нажмите Ctrl+C для возврата в меню):${NC}\n"
    cd "$target_dir"
    (
        trap 'exit 0' INT TERM
        docker compose logs -f --tail 100 2>&1 || true
    ) || true
    pause_menu
}

restart_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}[*] Перезапуск контейнера...${NC}"
    docker compose restart
    echo -e "${GREEN}[+] Контейнер успешно перезапущен.${NC}\n"
    pause_menu
}

stop_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}[*] Остановка контейнера...${NC}"
    docker compose down
    echo -e "${GREEN}[+] Контейнер остановлен.${NC}\n"
    pause_menu
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

    pause_menu
}

uninstall_project() {
    local target_dir
    target_dir="$(get_install_dir)"
    echo -e "${RED}${BOLD}[!] ВНИМАНИЕ: Удаление geo-routing-server${NC}"
    if [ -n "$target_dir" ]; then
        echo -e "${DIM}Будут удалены: контейнер, тома данных, каталог $target_dir и команда geoserver.${NC}\n"
    fi
    local conf_idx
    conf_idx=$(tui_select "Вы действительно хотите удалить geo-routing-server?" 0 \
        "Отмена (вернуться в главное меню)" \
        "Да, удалить контейнер и все файлы")

    if [ "$conf_idx" -eq 1 ]; then
        echo -e "${YELLOW}[*] Остановка и удаление контейнеров...${NC}"
        if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
            (cd "$target_dir" && docker compose down -v --remove-orphans 2>/dev/null) || true
        fi
        # Принудительное удаление контейнера на случай, если compose.yaml был поврежден
        docker rm -f geo-routing-server 2>/dev/null || true

        # Безопасное удаление каталога установки с защитой системных папок
        if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
            case "$target_dir" in
                /|/root|/home|/opt|/var|/usr|/etc|/bin|/sbin|/tmp)
                    echo -e "${YELLOW}[!] Каталог $target_dir является системным. Удаляются только файлы geo-routing-server...${NC}"
                    rm -f "$target_dir/compose.yaml" "$target_dir/docker-compose.yml" "$target_dir/.env" "$target_dir/.env.backup" "$target_dir/.sync.lock" 2>/dev/null || true
                    rm -rf "$target_dir/custom_geo" 2>/dev/null || true
                    ;;
                *)
                    if [ -f "$target_dir/compose.yaml" ] && grep -q "geo-routing-server" "$target_dir/compose.yaml" 2>/dev/null; then
                        rm -rf "$target_dir"
                    elif [ -f "$target_dir/.env" ] && grep -q "ROUTING_TOKEN" "$target_dir/.env" 2>/dev/null; then
                        rm -rf "$target_dir"
                    else
                        echo -e "${YELLOW}[!] В каталоге $target_dir не обнаружен маркер geo-routing-server. Удаляются только файлы конфигурации...${NC}"
                        rm -f "$target_dir/compose.yaml" "$target_dir/docker-compose.yml" "$target_dir/.env" "$target_dir/.env.backup" 2>/dev/null || true
                    fi
                    ;;
            esac
        fi

        rm -f "$CONFIG_FILE_RECORD" "$LANG_RECORD"
        rm -f /usr/local/bin/geo-server /usr/bin/geo-server /usr/local/bin/geoserver /usr/bin/geoserver
        echo -e "${GREEN}[+] geo-routing-server успешно удалён.${NC}"
        exit 0
    else
        echo -e "\n${GREEN}[+] Удаление отменено. Возврат в меню...${NC}"
        sleep 1
        return 0
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

    ui_step "1/8" "Каталог установки"
    if [ -n "$existing_detected" ]; then
        echo -e "  ${YELLOW}[i] Обнаружена существующая установка: ${BOLD}$existing_detected${NC}"
    fi
    echo -e "  ${DIM}Каталог, куда будут сохранены файлы compose.yaml и .env${NC}"
    read -r -p "  ▸ Путь [Enter = ${current_suggested_dir}]: " input_dir
    input_dir="$(echo "$input_dir" | tr -d '\r' | sed 's/[^a-zA-Z0-9_\/\.-]//g')"
    INSTALL_DIR="${input_dir:-$current_suggested_dir}"
    INSTALL_DIR="$(echo "$INSTALL_DIR" | tr -d '\r' | sed 's/[^a-zA-Z0-9_\/\.-]//g')"
    mkdir -p "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR" 2>/dev/null || true
    save_install_dir "$INSTALL_DIR"
    echo -e "  ${GREEN}[+] Каталог сохранён: ${BOLD}$INSTALL_DIR${NC}\n"

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
    local prev_ext_network=""

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
        prev_ext_network="$(grep -E '^(DOCKER_NETWORK|EXT_NETWORK)=' "$scan_env" | cut -d'=' -f2- || true)"
    fi

    # Если в .env сеть не сохранена, проверяем существующий compose.yaml
    local comp_scan=""
    if [ -f "$INSTALL_DIR/compose.yaml" ]; then
        comp_scan="$INSTALL_DIR/compose.yaml"
    elif [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        comp_scan="$INSTALL_DIR/docker-compose.yml"
    elif [ -n "$existing_detected" ] && [ -f "$existing_detected/compose.yaml" ]; then
        comp_scan="$existing_detected/compose.yaml"
    elif [ -n "$existing_detected" ] && [ -f "$existing_detected/docker-compose.yml" ]; then
        comp_scan="$existing_detected/docker-compose.yml"
    fi

    if [ -z "$prev_ext_network" ] && [ -n "$comp_scan" ]; then
        local comp_net
        comp_net=$(awk '/external:\s*true/{print prev} {gsub(/[: ]/, "", $0); prev=$0}' "$comp_scan" 2>/dev/null || true)
        [ -n "$comp_net" ] && [ "$comp_net" != "default" ] && prev_ext_network="$comp_net"
    fi

    # Если в compose.yaml не найдено, проверяем подключённые сети живого контейнера geo-routing-server
    if [ -z "$prev_ext_network" ] && command -v docker &>/dev/null; then
        local c_nets
        c_nets=$(docker inspect geo-routing-server --format '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' 2>/dev/null || true)
        if [ -n "$c_nets" ]; then
            while IFS= read -r cn; do
                [ -z "$cn" ] && continue
                if [[ ! "$cn" =~ (bridge|host|none|_default$) ]]; then
                    prev_ext_network="$cn"
                    break
                fi
            done <<< "$c_nets"
        fi
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 2: Выбор сценария работы сервера
    # ────────────────────────────────────────────────────────────────────────
    ui_step "2/8" "Сценарий и режим работы сервера"
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
    echo -e "  ${GREEN}[+] Выбранный режим: ${BOLD}$ENABLED_CLIENTS${NC}\n"

    # Если базы на внешнем сервере (варианты 4 и 5)
    if [ "$server_role" = "4" ] || [ "$server_role" = "5" ]; then
        local prompt_str="  ▸ Адрес сервера с базами (например, https://geo.example.com/секретный_токен): "
        if [ -n "$prev_public_geo" ]; then
            prompt_str="  ▸ Адрес сервера с базами [${prev_public_geo}]: "
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
        ui_step "3/8" "Публичный домен для HTTPS"
        echo -e "  ${DIM}Имя хоста, по которому клиенты будут скачивать правила и базы${NC}"
        read -r -p "  ▸ Домен [${prev_domain:-geo.example.com}]: " input_domain
        DOMAIN="${input_domain:-${prev_domain:-geo.example.com}}"
        DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]' | sed -e 's~^https\?://~~' -e 's~/*$~~')"
        echo -e "  ${GREEN}[+] Домен: ${BOLD}$DOMAIN${NC}\n"

        # ШАГ 4: Токен
        ui_step "4/8" "Секретный URL-токен авторизации"
        local auto_token
        if [ -n "$prev_token" ] && [ "$prev_token" != "local" ]; then
            auto_token="$prev_token"
            echo -e "  Текущий токен: ${CYAN}${BOLD}${auto_token}${NC}"
        else
            auto_token="$(openssl rand -hex 16)"
            echo -e "  Сгенерирован токен: ${CYAN}${BOLD}${auto_token}${NC}"
        fi
        
        read -r -p "  ▸ Секретный токен [${auto_token}]: " input_token
        ROUTING_TOKEN="${input_token:-$auto_token}"
        ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        while [[ ! "$ROUTING_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || [ "${#ROUTING_TOKEN}" -lt 8 ]; do
            echo -e "  ${RED}[!] Токен должен быть длиной не менее 8 символов (буквы, цифры, дефис, подчеркивание)${NC}"
            read -r -p "  ▸ Введите корректный токен [${auto_token}]: " input_token
            ROUTING_TOKEN="${input_token:-$auto_token}"
            ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        done
        echo -e "  ${GREEN}[+] Токен сохранён.${NC}"
        echo -e "  ${CYAN}${BOLD}[i] Базовый URL:${NC} ${CYAN}https://${DOMAIN}/${ROUTING_TOKEN}${NC}\n"

        # ШАГ 5: Локальный порт
        ui_step "5/8" "Локальный порт веб-сервера"
        local suggested_port="${prev_port:-8080}"
        if is_port_in_use "$suggested_port"; then
            local free_p
            free_p="$(find_free_port 8081)"
            echo -e "  ${YELLOW}[!] Порт $suggested_port занят. Предлагаем свободный порт: ${BOLD}${free_p}${NC}"
            suggested_port="$free_p"
        fi
        read -r -p "  ▸ Порт веб-сервера [${suggested_port}]: " input_port
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
        ui_step "6/8" "Прямая интеграция с Remnawave API"

        local remna_proceed=true
        if [ "$server_role" != "1" ] && [ "$server_role" != "4" ]; then
            local remna_conf_idx
            remna_conf_idx=$(tui_select "Настроить отправку правил Happ в сквады Remnawave?" 0 "Да" "Нет")
            [ "$remna_conf_idx" -ne 0 ] && remna_proceed=false
        fi

        if [ "$remna_proceed" = true ]; then
            if detect_remnawave_running; then
                echo -e "  ${CYAN}[i] Обнаружен локальный контейнер Remnawave в Docker.${NC}"
            fi

            read -r -p "  ▸ URL API панели Remnawave [${prev_remna_base:-http://remnawave:3000/api}]: " r_base
            r_base="${r_base:-${prev_remna_base:-http://remnawave:3000/api}}"

            local r_token
            r_token=$(tui_secret "JWT токен администратора Remnawave" "$prev_remna_token")

            local existing_squads=0
            if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                existing_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$scan_env" || true)
            fi
            local default_sq_count="${existing_squads:-1}"
            [ "$default_sq_count" -le 0 ] && default_sq_count=1
            read -r -p "  ▸ Сколько сквадов привязать? [${default_sq_count}]: " r_count
            r_count="${r_count:-$default_sq_count}"
            
            REMNA_BLOCK="REMNAWAVE_BASE_URL=${r_base}
REMNAWAVE_TOKEN=${r_token}
"
            echo -e "\n${CYAN}${BOLD}[i] Источник правил:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}"
            echo -e "${YELLOW}${BOLD}[!] ВНИМАНИЕ:${NC} ${YELLOW}В панели Remnawave используйте вкладку ${GREEN}${BOLD}«Внешние сквады»${NC}${YELLOW} (External Squads)!${NC}"
            echo -e "${YELLOW}    Не используйте «Внутренние сквады» — они не поддерживают маршрутизацию подписок Happ.${NC}"

            echo -e "${BLUE}[*] Загрузка списка внешних сквадов из Remnawave...${NC}"
            local ext_squads_raw
            ext_squads_raw=$(fetch_remnawave_external_squads "$r_base" "$r_token")
            if [ -n "$ext_squads_raw" ]; then
                echo -e "${GREEN}[+] В Remnawave обнаружены следующие внешние сквады:${NC}"
                while IFS='|' read -r su sn; do
                    [ -z "$su" ] && continue
                    echo -e "      • ${BOLD}${sn:-Без имени}${NC} (${DIM}${su}${NC})"
                done <<< "$ext_squads_raw"
            fi

            for ((i=1; i<=r_count; i++)); do
                local prev_s_uuid=""
                local prev_s_name=""
                local prev_s_rule=""
                if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                    prev_s_uuid=$(grep "^REMNAWAVE_SQUAD_${i}_UUID=" "$scan_env" | cut -d'=' -f2- || true)
                    prev_s_name=$(grep "^REMNAWAVE_SQUAD_${i}_NAME=" "$scan_env" | cut -d'=' -f2- || true)
                    prev_s_rule=$(grep "^REMNAWAVE_SQUAD_${i}_RULE=" "$scan_env" | cut -d'=' -f2- || true)
                if [ -n "$prev_s_uuid" ] && [ -n "$ext_squads_raw" ]; then
                    local live_match
                    live_match=$(echo "$ext_squads_raw" | grep -i "^${prev_s_uuid}|" | cut -d'|' -f2- || true)
                    [ -n "$live_match" ] && prev_s_name="$live_match"
                fi

                local s_header_title=""
                [ -n "$prev_s_name" ] && s_header_title=": ${BOLD}${prev_s_name}${NC}${CYAN}"
                echo -e "\n${CYAN}── Сквад #$i${s_header_title} ──${NC}"
                local s_hint="панель Remnawave → Сквады → Внешние сквады"
                if [ -n "$prev_s_uuid" ]; then
                    if [ -n "$prev_s_name" ]; then
                        s_hint="${prev_s_name} (${prev_s_uuid})"
                    else
                        s_hint="$prev_s_uuid"
                    fi
                fi
                read -r -p "  ▸ UUID внешнего сквада [${s_hint}]: " s_uuid
                s_uuid="${s_uuid:-$prev_s_uuid}"

                local s_name="$prev_s_name"
                if [ -n "$ext_squads_raw" ]; then
                    local matched_name
                    matched_name=$(echo "$ext_squads_raw" | grep -i "^${s_uuid}|" | cut -d'|' -f2- || true)
                    [ -n "$matched_name" ] && s_name="$matched_name"
                fi

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
                local s_display_label="${s_uuid}"
                [ -n "$s_name" ] && s_display_label="'${s_name}' (${s_uuid})"
                echo -e "  ${GREEN}[+] Сквад #$i: ${s_display_label} → ${s_rule}${NC}"

                REMNA_BLOCK="${REMNA_BLOCK}REMNAWAVE_SQUAD_${i}_UUID=${s_uuid}
REMNAWAVE_SQUAD_${i}_NAME=${s_name}
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
    # ШАГ 7: Docker-сеть (умный автодетект и сохранение)
    # ────────────────────────────────────────────────────────────────────────
    EXT_NETWORK=""
    NEEDS_NETWORK=false

    if [ -n "$REMNA_BLOCK" ]; then
        NEEDS_NETWORK=true
    fi

    if [ "$NEEDS_NETWORK" = true ]; then
        ui_step "7/8" "Подключение к Docker-сети"
        
        # Получаем список сетей Docker
        local detected_nets
        detected_nets=$(detect_docker_networks)
        local net_options=()
        local remna_found_net=""
        local other_nets=()

        if [ -n "$detected_nets" ]; then
            while IFS= read -r net_name; do
                [ -z "$net_name" ] && continue
                [[ "$net_name" =~ geo-routing-server_default$ ]] && continue
                
                if [ -n "$prev_ext_network" ] && [ "$net_name" = "$prev_ext_network" ]; then
                    continue
                fi
                if [[ "$net_name" =~ remna ]]; then
                    remna_found_net="$net_name"
                fi
                other_nets+=("$net_name")
            done <<< "$detected_nets"
        fi

        # 1. Если ранее сеть уже была настроена, ставим её на 1-е место с пометкой (сохранена)
        if [ -n "$prev_ext_network" ]; then
            net_options+=("${prev_ext_network} (текущая сохранённая)")
            echo -e "  ${CYAN}[i] Ранее настроенная Docker-сеть: ${BOLD}${prev_ext_network}${NC}"
        elif [ -n "$remna_found_net" ]; then
            net_options+=("${remna_found_net} (обнаружена Remnawave)")
        else
            net_options+=("remnawave-network (создать / подключить)")
        fi

        # 2. Добавляем остальные обнаруженные сети
        for onet in "${other_nets[@]}"; do
            [ -n "$remna_found_net" ] && [ "$onet" = "$remna_found_net" ] && [ -z "$prev_ext_network" ] && continue
            net_options+=("$onet")
        done

        # 3. Варианты ручного ввода и пропуска
        net_options+=("Ввести другое имя сети" "Не подключать к внешней сети")

        local net_pick_idx
        net_pick_idx=$(tui_select "Выберите Docker-сеть для связи с Remnawave:" 0 "${net_options[@]}")
        local chosen_net="${net_options[$net_pick_idx]}"

        if [ "$chosen_net" = "Не подключать к внешней сети" ]; then
            echo -e "${DIM}Пропущено. Используется стандартная сеть.${NC}\n"
            EXT_NETWORK=""
        elif [ "$chosen_net" = "Ввести другое имя сети" ]; then
            read -r -p "Имя Docker-сети: " input_custom_net
            EXT_NETWORK="${input_custom_net:-remnawave-network}"
            if ! docker network inspect "$EXT_NETWORK" &>/dev/null; then
                echo -e "${YELLOW}[*] Создаём Docker-сеть $EXT_NETWORK...${NC}"
                docker network create "$EXT_NETWORK" || true
            fi
            echo -e "${GREEN}[+] Сеть: $EXT_NETWORK${NC}\n"
        else
            EXT_NETWORK="$(echo "$chosen_net" | awk '{print $1}')"
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
    ui_step "8/8" "Расписание автоматического обновления"
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
            read -r -p "  ▸ Введите cron-выражение [${prev_schedule:-0 10 * * *}]: " custom_sched
            SCHEDULE="${custom_sched:-${prev_schedule:-0 10 * * *}}"
            ;;
        *) SCHEDULE="0 10 * * *" ;;
    esac
    echo -e "  ${GREEN}[+] Расписание: ${BOLD}$SCHEDULE${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 9: Telegram (опционально)
    # ────────────────────────────────────────────────────────────────────────
    ui_step "Дополнительно" "Telegram-уведомления"
    
    TG_BOT_TOKEN=""
    TG_CHAT_ID=""
    TG_THREAD_ID=""
    TG_NOTIFY_SUCCESS="false"

    if [ -n "$prev_tg_token" ]; then
        local tg_chat_hint="${prev_tg_chat:-настроен}"
        local tg_opt_idx
        tg_opt_idx=$(tui_select "Telegram-уведомления уже настроены. Что сделать?" 0 \
            "Оставить текущие настройки Telegram (Chat ID: ${tg_chat_hint})" \
            "Изменить настройки Telegram бота" \
            "Отключить Telegram-уведомления")

        case "$tg_opt_idx" in
            0)
                TG_BOT_TOKEN="$prev_tg_token"
                TG_CHAT_ID="$prev_tg_chat"
                TG_THREAD_ID="$prev_tg_thread"
                TG_NOTIFY_SUCCESS="${prev_tg_notify:-false}"
                echo -e "  ${GREEN}[+] Сохранены текущие настройки Telegram (Chat ID: ${tg_chat_hint}).${NC}\n"
                ;;
            1)
                TG_BOT_TOKEN=$(tui_secret "TELEGRAM_BOT_TOKEN" "$prev_tg_token")
                
                read -r -p "  ▸ TELEGRAM_CHAT_ID [${prev_tg_chat:-пропустить}]: " input_chat
                TG_CHAT_ID="${input_chat:-$prev_tg_chat}"

                read -r -p "  ▸ TELEGRAM_THREAD_ID (ID темы) [${prev_tg_thread:-нет}]: " input_thread
                TG_THREAD_ID="${input_thread:-$prev_tg_thread}"

                local tg_succ_idx
                local def_succ=0
                [ "${prev_tg_notify:-false}" = "true" ] && def_succ=1
                tg_succ_idx=$(tui_select "Присылать уведомление при успешном выходе новых баз?" "$def_succ" \
                    "Нет (только критические ошибки)" \
                    "Да (отчёт о каждом обновлении)")
                [ "$tg_succ_idx" -eq 1 ] && TG_NOTIFY_SUCCESS="true" || TG_NOTIFY_SUCCESS="false"

                if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
                    test_telegram "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$TG_THREAD_ID" || true
                fi
                echo -e "  ${GREEN}[+] Telegram настроен.${NC}\n"
                ;;
            2)
                echo -e "  ${DIM}Уведомления Telegram отключены.${NC}\n"
                ;;
        esac
    else
        local tg_opt_idx
        tg_opt_idx=$(tui_select "Настроить Telegram-уведомления об ошибках/обновлениях?" 0 \
            "Пропустить (без Telegram)" \
            "Настроить Telegram бота")

        if [ "$tg_opt_idx" -eq 1 ]; then
            TG_BOT_TOKEN=$(tui_secret "TELEGRAM_BOT_TOKEN" "")
            
            read -r -p "  ▸ TELEGRAM_CHAT_ID [пропустить]: " input_chat
            TG_CHAT_ID="${input_chat:-}"

            read -r -p "  ▸ TELEGRAM_THREAD_ID (ID темы) [нет]: " input_thread
            TG_THREAD_ID="${input_thread:-}"

            local tg_succ_idx
            tg_succ_idx=$(tui_select "Присылать уведомление при успешном выходе новых баз?" 0 \
                "Нет (только критические ошибки)" \
                "Да (отчёт о каждом обновлении)")
            [ "$tg_succ_idx" -eq 1 ] && TG_NOTIFY_SUCCESS="true" || TG_NOTIFY_SUCCESS="false"

            if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
                test_telegram "$TG_BOT_TOKEN" "$TG_CHAT_ID" "$TG_THREAD_ID" || true
            fi
            echo -e "  ${GREEN}[+] Telegram настроен.${NC}\n"
        else
            echo -e "  ${DIM}Уведомления Telegram отключены.${NC}\n"
        fi
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
        [ -n "$EXT_NETWORK" ] && echo "DOCKER_NETWORK=${EXT_NETWORK}"
    } > "$INSTALL_DIR/.env"
    chmod 644 "$INSTALL_DIR/.env" 2>/dev/null || true
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
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:80/health"]
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

    # Совместимость с веб-панелями управления Docker (Arcane, Dockge, Portainer)
    chmod 755 "$INSTALL_DIR" 2>/dev/null || true
    chmod 755 "$INSTALL_DIR/custom_geo" 2>/dev/null || true
    chmod 644 "$INSTALL_DIR/compose.yaml" 2>/dev/null || true
    chmod 644 "$INSTALL_DIR/.env" 2>/dev/null || true
    [ -f "$INSTALL_DIR/.env.backup" ] && chmod 600 "$INSTALL_DIR/.env.backup" 2>/dev/null || true
    rm -f "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || true

    # Сохраняем скрипт установщика в каталог проекта для работы команды geo-server
    if [ -f "$0" ] && grep -q "Geo Routing Server" "$0" 2>/dev/null; then
        cp "$0" "$INSTALL_DIR/install.sh" 2>/dev/null || true
    else
        curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$INSTALL_DIR/install.sh" 2>/dev/null || true
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

    echo -e "\n\033[1;32m╭─────────────────────────────────────────────────────────────────────────────╮\033[0m"
    echo -e "\033[1;32m│                     ✓ НАСТРОЙКА УСПЕШНО ЗАВЕРШЕНА!                          │\033[0m"
    echo -e "\033[1;32m╰─────────────────────────────────────────────────────────────────────────────╯\033[0m"
    echo -e "  Каталог установки:             ${CYAN}${BOLD}${INSTALL_DIR}${NC}"
    echo -e "  Команда управления из консоли: ${CYAN}${BOLD}geoserver${NC} (или ${CYAN}${BOLD}geo-server${NC})\n"
    
    if [ "$NEEDS_PUBLIC_DOMAIN" = true ]; then
        show_proxy_snippets
    fi
    show_links
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

main_menu() {
    refresh_squad_names_in_env 2>/dev/null || true
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

        local env_file="$target_dir/.env"
        local modules_ru="—"
        local modules_en="—"
        local integrations_ru=""
        local integrations_en=""
        local domain_val=""
        local is_local=0

        if [ -f "$env_file" ]; then
            local clients
            clients=$(grep "^ENABLED_CLIENTS=" "$env_file" | cut -d'=' -f2- || echo "")
            local ext_geo
            ext_geo=$(grep "^PUBLIC_GEO_BASE_URL=" "$env_file" | cut -d'=' -f2- || echo "")
            domain_val=$(grep "^DOMAIN=" "$env_file" | cut -d'=' -f2- || echo "")

            if [ "$clients" = "HAPP_DEEPLINK" ] || [ "$clients" = "HAPP_LOCAL" ]; then
                is_local=1
                modules_ru="Happ (генератор для Remnawave)"
                modules_en="Happ (Remnawave rule generator)"
            elif [ "$clients" = "HAPP_GEO" ] || [ "$clients" = "INCY_GEO" ] || [ "$clients" = "HAPP_GEO,INCY_GEO" ]; then
                modules_ru="Раздача GeoIP / GeoSite баз"
                modules_en="GeoIP / GeoSite binary distribution"
            elif [ "$clients" = "HAPP" ]; then
                modules_ru="Happ (диплинки) + Раздача Geo-баз"
                modules_en="Happ (deeplinks) + Geo-databases"
            elif [ "$clients" = "INCY" ]; then
                if [ -n "$ext_geo" ]; then
                    modules_ru="Incy (Autorouting, внешние Geo-базы)"
                    modules_en="Incy (Autorouting, external geo)"
                else
                    modules_ru="Incy (Autorouting) + Раздача Geo-баз"
                    modules_en="Incy (Autorouting) + Geo-databases"
                fi
            elif [[ "$clients" =~ HAPP ]] && [[ "$clients" =~ INCY ]]; then
                if [ -n "$ext_geo" ]; then
                    modules_ru="Happ + Incy (внешние Geo-базы)"
                    modules_en="Happ + Incy (external geo)"
                else
                    modules_ru="Happ + Incy + Раздача Geo-баз"
                    modules_en="Happ + Incy + Geo-databases"
                fi
            elif [ -n "$clients" ]; then
                modules_ru="$clients"
                modules_en="$clients"
            fi

            local remna_base
            remna_base=$(grep "^REMNAWAVE_BASE_URL=" "$env_file" | cut -d'=' -f2- || echo "")
            local remna_tok
            remna_tok=$(grep "^REMNAWAVE_TOKEN=" "$env_file" | cut -d'=' -f2- || echo "")
            local int_ru=()
            local int_en=()

            if [ -n "$remna_base" ] && [ -n "$remna_tok" ]; then
                local sq_cnt=0
                sq_cnt=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$env_file" || true)
                if [ "$sq_cnt" -gt 0 ]; then
                    int_ru+=("Remnawave ($sq_cnt сквад.)")
                    int_en+=("Remnawave ($sq_cnt squads)")
                else
                    int_ru+=("Remnawave API")
                    int_en+=("Remnawave API")
                fi
            fi

            local tg_tok
            tg_tok=$(grep "^TELEGRAM_BOT_TOKEN=" "$env_file" | cut -d'=' -f2- || echo "")
            local tg_chat
            tg_chat=$(grep "^TELEGRAM_CHAT_ID=" "$env_file" | cut -d'=' -f2- || echo "")
            if [ -n "$tg_tok" ] && [ -n "$tg_chat" ]; then
                int_ru+=("Telegram")
                int_en+=("Telegram")
            fi

            if [ ${#int_ru[@]} -gt 0 ]; then
                integrations_ru=$(IFS=" • "; echo "${int_ru[*]}")
                integrations_en=$(IFS=" • "; echo "${int_en[*]}")
            fi
        fi

        if [ "${UI_LANG:-ru}" = "en" ]; then
            echo -e "Installation directory: ${CYAN}$target_dir${NC}"
            echo -e "Container status:       $status_msg"
            echo -e "Active modules:         ${GREEN}$modules_en${NC}"
            if [ "$is_local" -eq 0 ] && [ -n "$domain_val" ] && [ "$domain_val" != "geo.example.com" ]; then
                echo -e "Public domain:          ${CYAN}$domain_val${NC}"
            fi
            if [ -n "$integrations_en" ]; then
                echo -e "Integrations:           ${YELLOW}$integrations_en${NC}"
            fi
            echo ""

            local en_options=(
                "HEADER:General & Information"
                "Sync geo-databases right now"
                "Show public links and autorouting header"
                "Show reverse-proxy configs (Caddy / Nginx / NPM)"
                "HEADER:Settings & Integrations"
                "Configure Remnawave API sync"
                "Configure Telegram notifications"
                "Reconfigure parameters (run wizard)"
                "HEADER:Container Management"
                "View container logs"
                "Restart container"
                "Stop container"
                "Update Docker image (pull & recreate)"
                "Update management script from GitHub"
                "HEADER:System"
                "Change language / Сменить язык (RU/EN)"
                "Completely remove geo-routing-server"
                "Exit"
            )

            local menu_idx
            menu_idx=$(tui_select "Choose an action:" 0 "${en_options[@]}")
        else
            echo -e "Каталог установки: ${CYAN}$target_dir${NC}"
            echo -e "Статус контейнера: $status_msg"
            echo -e "Активные модули:   ${GREEN}$modules_ru${NC}"
            if [ "$is_local" -eq 0 ] && [ -n "$domain_val" ] && [ "$domain_val" != "geo.example.com" ]; then
                echo -e "Публичный домен:   ${CYAN}$domain_val${NC}"
            fi
            if [ -n "$integrations_ru" ]; then
                echo -e "Интеграции:        ${YELLOW}$integrations_ru${NC}"
            fi
            echo ""

            local ru_options=(
                "HEADER:Основное и ссылки"
                "Синхронизировать базы прямо сейчас"
                "Показать публичные ссылки и диплинки"
                "Готовые конфиги для Caddy / Nginx / NPM"
                "HEADER:Настройки и интеграции"
                "Настроить прямую синхронизацию с Remnawave"
                "Настроить / Изменить Telegram-уведомления"
                "Перенастроить параметры (мастер настройки)"
                "HEADER:Управление контейнером"
                "Посмотреть логи контейнера"
                "Перезапустить контейнер"
                "Остановить контейнер"
                "Обновить Docker-образ (pull & recreate)"
                "Обновить скрипт управления из GitHub"
                "HEADER:Система"
                "Сменить язык / Change language (RU/EN)"
                "Полностью удалить geo-routing-server"
                "Выход"
            )

            local menu_idx
            menu_idx=$(tui_select "Выберите действие:" 0 "${ru_options[@]}")
        fi

        case "$menu_idx" in
            0) run_sync_now ;;
            1) show_links ;;
            2) show_proxy_snippets ;;
            3) configure_remnawave ;;
            4) configure_telegram ;;
            5) install_wizard ;;
            6) view_logs ;;
            7) restart_server ;;
            8) stop_server ;;
            9) update_project ;;
            10) update_script_only ;;
            11)
                if [ "${UI_LANG:-ru}" = "ru" ]; then
                    UI_LANG="en"
                else
                    UI_LANG="ru"
                fi
                echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
                echo -e "${GREEN}[+] Language / Язык: $UI_LANG${NC}"
                sleep 1
                ;;
            12) uninstall_project ;;
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
            main_menu
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
                "Completely remove geo-routing-server")
        else
            init_idx=$(tui_select "${YELLOW}[!] Обнаружена незавершенная установка в $target_dir${NC}" 0 \
                "Продолжить настройку (сохранить старые данные)" \
                "Очистить все файлы и начать с чистого листа" \
                "Полностью удалить geo-routing-server")
        fi
        case "$init_idx" in
            0) 
                install_wizard
                main_menu
                ;;
            1) 
                if [ -n "$target_dir" ] && [ "$target_dir" != "/" ] && [ "$target_dir" != "/root" ] && [ -d "$target_dir" ]; then
                    rm -rf "$target_dir"
                fi
                install_wizard
                main_menu
                ;;
            2) 
                uninstall_project
                exit 0
                ;;
            *) 
                install_wizard
                main_menu
                ;;
        esac
    else
        install_wizard
        main_menu
    fi
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    main "$@"
fi
