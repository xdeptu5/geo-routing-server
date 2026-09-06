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

# Повышайте версию при каждом изменении install.sh. GitHub Actions это проверяет.
SCRIPT_VERSION="1.1.4"
CHECKED_REMOTE_VER=""
UPDATE_AVAILABLE=false
CHECKED_REMOTE_IMG_DIGEST=""
IMAGE_UPDATE_AVAILABLE=false

CONFIG_FILE_RECORD="/etc/geo-routing-server.conf"
LANG_RECORD="/etc/geo-routing-server.lang"
UI_LANG=""

handle_error() {
    local code=$?
    local line=$1
    trap - ERR
    [ "$code" -eq 0 ] && return 0
    if [ "$code" -eq 130 ] || [ "$code" -eq 143 ]; then
        # A cancelled nested dialog must return to the program, not close the user's shell.
        if [ "${NONINTERACTIVE:-false}" != true ]; then
            printf '\n[i] Действие отменено.\n' >&2
            main_menu
            exit 0
        fi
        return 0
    fi
    if [ "${UI_LANG:-ru}" = "en" ]; then
        printf '\n[!] Operation failed (code %s, line %s).\n' "$code" "$line" >&2
        printf 'Review the error above. Run geoserver to inspect the installation or retry.\n' >&2
    else
        printf '\n[!] Операция завершилась с ошибкой (код %s, строка %s).\n' "$code" "$line" >&2
        printf 'Проверьте сообщение выше. Запустите geoserver для проверки установки или повторного действия.\n' >&2
    fi
    exit "$code"
}

trap 'handle_error $LINENO' ERR

# ==============================================================================
# TUI КОМПОНЕНТЫ И ХЕЛПЕРЫ ВВОДА
# ==============================================================================

# Нумерованный выбор. stdout содержит только индекс действия, начиная с нуля.
# EOF и отмена без отдельного пункта возвращают 130, не выбирая действие.
tui_select() {
    local prompt_title="$1" default_idx="${2:-0}"
    shift 2
    local raw_items=("$@") action_count=0
    local visual_items=() is_header=() action_num=() visual_to_action=()
    local line v_idx

    for line in "${raw_items[@]}"; do
        v_idx=${#visual_items[@]}
        visual_items+=("$line")
        if [[ "$line" == HEADER:* ]]; then
            is_header+=(1); action_num+=(0); visual_to_action+=(-1)
        else
            is_header+=(0)
            action_count=$((action_count + 1))
            action_num+=("$action_count")
            visual_to_action+=("$((action_count - 1))")
        fi
    done
    [ "$action_count" -gt 0 ] || return 130
    if ! [[ "$default_idx" =~ ^[0-9]+$ ]] || [ "$default_idx" -ge "$action_count" ]; then default_idx=0; fi

    # Server terminals keep the old direct navigation: arrows or j/k, Enter, and digits.
    if [ ! -t 0 ]; then
        printf '%b\n' "$prompt_title" >&2
        for v_idx in "${!visual_items[@]}"; do
            if [ "${is_header[v_idx]}" -eq 1 ]; then
                printf '\n  %s\n' "${visual_items[v_idx]#HEADER:}" >&2
            else
                printf '  %d) %b\n' "${action_num[v_idx]}" "${visual_items[v_idx]}" >&2
            fi
        done
        local fallback_pick=""
        IFS= read -r fallback_pick || true
        fallback_pick="${fallback_pick:-$((default_idx + 1))}"
        if [[ "$fallback_pick" =~ ^[0-9]+$ ]] && [ "$fallback_pick" -ge 1 ] && [ "$fallback_pick" -le "$action_count" ]; then
            printf '%s\n' "$((fallback_pick - 1))"
        else
            printf '%s\n' "$default_idx"
        fi
        return 0
    fi

    local selected="$default_idx" input_buf="" key rest candidate
    local total_visual_lines=${#visual_items[@]}
    tput civis >&2 2>/dev/null || true
    _tui_restore_cursor() { tput cnorm >&2 2>/dev/null || true; }
    draw_tui_menu() {
        printf '%b\n' "$prompt_title" >&2
        for v_idx in "${!visual_items[@]}"; do
            if [ "${is_header[v_idx]}" -eq 1 ]; then
                printf '\n  \033[0;36m── %s ──\033[0m\n' "${visual_items[v_idx]#HEADER:}" >&2
            elif [ "${visual_to_action[v_idx]}" -eq "$selected" ]; then
                printf '  \033[1;36m▸ %d) %s\033[0m\n' "${action_num[v_idx]}" "${visual_items[v_idx]}" >&2
            else
                printf '    \033[2m%d)\033[0m %s\n' "${action_num[v_idx]}" "${visual_items[v_idx]}" >&2
            fi
        done
        if [ -n "$input_buf" ]; then
            printf '  \033[2mВведено: %s; Enter — подтвердить. Стрелки ↑/↓ — выбор.\033[0m\n' "$input_buf" >&2
        else
            printf '  \033[2mСтрелки ↑/↓ или j/k — выбор; Enter — подтвердить; цифра — пункт.\033[0m\n' >&2
        fi
    }
    clear_tui_menu() {
        local rows=$((total_visual_lines + 2)) row
        printf '\033[%dA' "$rows" >&2
        for ((row=0; row<rows; row++)); do
            printf '\033[2K\r' >&2
            [ "$row" -lt $((rows - 1)) ] && printf '\033[1B' >&2
        done
        printf '\033[%dA' $((rows - 1)) >&2
    }

    draw_tui_menu
    while true; do
        key=""
        IFS= read -rsn1 key 2>/dev/null || { _tui_restore_cursor; return 130; }
        if [ "$key" = $'\x1b' ]; then IFS= read -rsn2 -t 0.1 rest 2>/dev/null || true; key="$key$rest"; fi
        case "$key" in
            $'\x1b[A'|$'\x1bOA'|k|K) input_buf=""; selected=$(((selected - 1 + action_count) % action_count)) ;;
            $'\x1b[B'|$'\x1bOB'|j|J) input_buf=""; selected=$(((selected + 1) % action_count)) ;;
            ''|' ') break ;;
            $'\x7f'|$'\x08') input_buf="${input_buf%?}" ;;
            0|q|Q) selected=$((action_count - 1)); break ;;
            [1-9])
                candidate="${input_buf}${key}"
                if [[ "$candidate" =~ ^[0-9]+$ ]] && [ "$candidate" -ge 1 ] && [ "$candidate" -le "$action_count" ]; then
                    input_buf="$candidate"; selected=$((candidate - 1))
                elif [ "$key" -le "$action_count" ]; then
                    input_buf="$key"; selected=$((key - 1))
                fi
                ;;
            $'\x03') _tui_restore_cursor; return 130 ;;
        esac
        clear_tui_menu
        draw_tui_menu
    done
    clear_tui_menu
    _tui_restore_cursor
    printf '%s\n' "$selected"
}

# Секреты не выводятся в терминал. Пустая строка сохраняет текущее значение.
tui_secret() {
    local prompt_label="$1" current_val="${2:-}" secret_input="" input_source=/dev/stdin
    if [ ! -t 0 ] && [ "${NONINTERACTIVE:-false}" != true ] && ( : </dev/tty ) 2>/dev/null; then
        input_source=/dev/tty
    fi
    if [ "${UI_LANG:-ru}" = en ]; then
        printf '%b (hidden input, Enter = keep, - = clear, q = cancel): ' "$prompt_label" >&2
    else
        printf '%b (ввод скрыт, Enter = сохранить, - = очистить, q = отмена): ' "$prompt_label" >&2
    fi
    if ! IFS= read -rs secret_input < "$input_source"; then
        printf '\n' >&2
        return 130
    fi
    printf '\n' >&2
    case "$secret_input" in
        q|Q) return 130 ;;
        -) printf '\n'; return 0 ;;
    esac
    printf '%s\n' "${secret_input:-$current_val}"
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
        out=$(docker exec -e "REMNAWAVE_BASE_URL=$base_url" -e "REMNAWAVE_TOKEN=$token" \
            -e "CLOUDFLARE_ZERO_TRUST_CLIENT_ID=$cf_id" -e "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=$cf_secret" \
            -e CF_ACCESS_CLIENT_ID= -e CF_ACCESS_CLIENT_SECRET= geo-routing-server python3 -c "
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

check_script_version() {
    [ "${SCRIPT_CHECK_STATUS:-unchecked}" != unchecked ] && return 0
    SCRIPT_CHECK_STATUS=unavailable
    UPDATE_AVAILABLE=false
    CHECKED_REMOTE_VER=$(curl -fsSL --connect-timeout 2 --max-time 5 \
        "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" 2>/dev/null |
        sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' | head -n 1 || true)
    [[ "$CHECKED_REMOTE_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { CHECKED_REMOTE_VER=""; return 0; }
    SCRIPT_CHECK_STATUS=current
    local highest
    highest=$(printf '%s\n%s\n' "${SCRIPT_VERSION#v}" "$CHECKED_REMOTE_VER" | sort -V | tail -n 1)
    if [ "$CHECKED_REMOTE_VER" != "${SCRIPT_VERSION#v}" ] && [ "$highest" = "$CHECKED_REMOTE_VER" ]; then
        SCRIPT_CHECK_STATUS=available
        UPDATE_AVAILABLE=true
    fi
}

check_docker_image_version() {
    [ "${IMAGE_CHECK_STATUS:-unchecked}" != unchecked ] && return 0
    IMAGE_CHECK_STATUS=unavailable
    IMAGE_UPDATE_AVAILABLE=false
    command -v docker >/dev/null 2>&1 || return 0
    local image_ref token local_digests
    image_ref=$(docker inspect --format '{{.Config.Image}}' geo-routing-server 2>/dev/null || true)
    if [ -n "$image_ref" ] && [ "$image_ref" != ghcr.io/xdeptu5/geo-routing-server:latest ]; then
        IMAGE_CHECK_STATUS=custom
        return 0
    fi
    token=$(curl -fsSL --max-time 3 'https://ghcr.io/token?scope=repository:xdeptu5/geo-routing-server:pull' 2>/dev/null |
        sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
    [ -n "$token" ] || return 0
    CHECKED_REMOTE_IMG_DIGEST=$(curl -fsSI --max-time 3 -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
        https://ghcr.io/v2/xdeptu5/geo-routing-server/manifests/latest 2>/dev/null |
        awk 'tolower($1)=="docker-content-digest:" {print $2}' | tr -d '\r\n' || true)
    [[ "$CHECKED_REMOTE_IMG_DIGEST" =~ ^sha256:[a-f0-9]{64}$ ]] || return 0
    # Compare the deployed image, not a possibly newer local :latest tag.
    local deployed_id
    deployed_id=$(docker inspect --format '{{.Image}}' geo-routing-server 2>/dev/null || true)
    [ -n "$deployed_id" ] || { IMAGE_CHECK_STATUS=not_installed; return 0; }
    local_digests=$(docker image inspect --format '{{range .RepoDigests}}{{.}} {{end}}' "$deployed_id" 2>/dev/null || true)
    [ -n "$local_digests" ] || return 0
    case "$local_digests" in
        *"@$CHECKED_REMOTE_IMG_DIGEST"*) IMAGE_CHECK_STATUS=current ;;
        *) IMAGE_CHECK_STATUS=available; IMAGE_UPDATE_AVAILABLE=true ;;
    esac
}

component_status_label() {
    local state="${1:-unchecked}"
    if [ "${UI_LANG:-ru}" = en ]; then
        case "$state" in
            current) printf 'up to date' ;;
            available) printf 'update available' ;;
            unavailable) printf 'check unavailable' ;;
            not_installed) printf 'not installed' ;;
            custom) printf 'custom image' ;;
            *) printf 'not checked' ;;
        esac
    else
        case "$state" in
            current) printf 'актуален' ;;
            available) printf 'доступно обновление' ;;
            unavailable) printf 'проверка недоступна' ;;
            not_installed) printf 'не установлен' ;;
            custom) printf 'свой образ' ;;
            *) printf 'не проверено' ;;
        esac
    fi
}

print_header() {
    if [ -t 1 ] && [ "${NONINTERACTIVE:-false}" != true ]; then
        clear 2>/dev/null || true
    fi
    printf '\n%bGEO ROUTING SERVER%b  v%s\n' "${CYAN}${BOLD}" "$NC" "$SCRIPT_VERSION"
    if [ "${UI_LANG:-ru}" = en ]; then
        printf '  Script: %s • Docker: %s\n\n' "$(component_status_label "${SCRIPT_CHECK_STATUS:-unchecked}")" "$(component_status_label "${IMAGE_CHECK_STATUS:-unchecked}")"
    else
        printf '  Скрипт: %s • Docker: %s\n\n' "$(component_status_label "${SCRIPT_CHECK_STATUS:-unchecked}")" "$(component_status_label "${IMAGE_CHECK_STATUS:-unchecked}")"
    fi
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

canonicalize_install_dir() {
    local raw_path="${1:-}"
    [ -n "$raw_path" ] || return 1
    [[ "$raw_path" != *$'\n'* && "$raw_path" != *$'\r'* ]] || return 1
    [[ "$raw_path" =~ ^/[a-zA-Z0-9_./-]+$ ]] || return 1

    if command -v realpath &>/dev/null; then
        realpath -m -- "$raw_path"
    elif command -v readlink &>/dev/null; then
        readlink -m -- "$raw_path"
    else
        return 1
    fi
}

is_protected_install_dir() {
    case "${1:-}" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 0
            ;;
    esac
    return 1
}

has_project_marker() {
    local target_dir="${1:-}"
    [ -n "$target_dir" ] || return 1
    [ -f "$target_dir/.geo-routing-server-install" ] && return 0

    local compose_file=""
    [ -f "$target_dir/compose.yaml" ] && compose_file="$target_dir/compose.yaml"
    [ -z "$compose_file" ] && [ -f "$target_dir/docker-compose.yml" ] && compose_file="$target_dir/docker-compose.yml"
    if [ -n "$compose_file" ]; then
        if grep -qE '^[[:space:]]*container_name:[[:space:]]*geo-routing-server[[:space:]]*$' "$compose_file" 2>/dev/null; then
            return 0
        fi
        if grep -q "geo-routing-server" "$compose_file" 2>/dev/null; then
            return 0
        fi
    fi
    [ -f "$target_dir/.env" ] && grep -q '^ROUTING_TOKEN=' "$target_dir/.env" 2>/dev/null && return 0
    [ -f "$target_dir/install.sh" ] && grep -q "geo-routing-server" "$target_dir/install.sh" 2>/dev/null && return 0

    local base_name
    base_name="$(basename "$target_dir")"
    if [ "$base_name" = "geo-routing-server" ] && ! is_protected_install_dir "$target_dir"; then
        return 0
    fi

    return 1
}

prepare_install_dir() {
    local canonical_dir
    canonical_dir="$(canonicalize_install_dir "${1:-}")" || return 1
    is_protected_install_dir "$canonical_dir" && return 1
    [ ! -e "$canonical_dir" ] || [ -d "$canonical_dir" ] || return 1

    if [ -d "$canonical_dir" ] && [ -n "$(find "$canonical_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        has_project_marker "$canonical_dir" || return 1
    fi

    mkdir -p -- "$canonical_dir" || return 1
    : > "$canonical_dir/.geo-routing-server-install" || return 1
    chmod 600 "$canonical_dir/.geo-routing-server-install" || return 1
    echo "$canonical_dir"
}

reset_install_dir() {
    local canonical_dir
    canonical_dir="$(canonicalize_install_dir "${1:-}")" || return 1
    is_protected_install_dir "$canonical_dir" && return 1
    [ ! -e "$canonical_dir" ] && return 0
    [ -d "$canonical_dir" ] || return 1

    # Если каталог пустой — удаляем без лишних проверок маркера
    if [ -z "$(find "$canonical_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        rmdir "$canonical_dir" 2>/dev/null || rm -rf -- "$canonical_dir"
        return 0
    fi

    has_project_marker "$canonical_dir" || return 1
    rm -rf -- "$canonical_dir"
}

secure_env_file() {
    local env_file="${1:-}"
    [ -f "$env_file" ] || return 1
    chmod 600 -- "$env_file"
}

validate_cron_field() {
    local field="${1:-}"
    local min="$2"
    local max="$3"
    [[ "$field" =~ ^[0-9*/,-]+$ ]] || return 1

    local part base step start end
    local parts=()
    IFS=',' read -r -a parts <<< "$field"
    for part in "${parts[@]}"; do
        base="$part"
        step=""
        if [[ "$part" == */* ]]; then
            base="${part%%/*}"
            step="${part#*/}"
            [[ "$step" =~ ^[0-9]+$ ]] && [ "$step" -ge 1 ] && [ "$step" -le "$max" ] || return 1
            [[ "$base" != */* ]] || return 1
        fi

        if [ "$base" = "*" ]; then
            continue
        elif [[ "$base" =~ ^[0-9]+$ ]]; then
            [ "$base" -ge "$min" ] && [ "$base" -le "$max" ] || return 1
        elif [[ "$base" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            [ "$start" -ge "$min" ] && [ "$start" -le "$max" ] || return 1
            [ "$end" -ge "$min" ] && [ "$end" -le "$max" ] && [ "$start" -le "$end" ] || return 1
        else
            return 1
        fi
    done
}

validate_cron_schedule() {
    local schedule="${1:-}"
    [[ "$schedule" != *$'\n'* && "$schedule" != *$'\r'* && "$schedule" != *$'\t'* ]] || return 1
    [[ "$schedule" =~ ^[0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+\ [0-9*/,-]+$ ]] || return 1

    local fields=()
    read -r -a fields <<< "$schedule"
    [ "${#fields[@]}" -eq 5 ] || return 1
    validate_cron_field "${fields[0]}" 0 59 || return 1
    validate_cron_field "${fields[1]}" 0 23 || return 1
    validate_cron_field "${fields[2]}" 1 31 || return 1
    validate_cron_field "${fields[3]}" 1 12 || return 1
    validate_cron_field "${fields[4]}" 0 7
}

# Поиск существующей установки по Docker или конфигурационным файлам
detect_existing_dir() {
    if [ -f "$CONFIG_FILE_RECORD" ]; then
        local saved_dir canonical_dir
        saved_dir="$(tr -d '\r\n' < "$CONFIG_FILE_RECORD")"
        canonical_dir="$(canonicalize_install_dir "$saved_dir" 2>/dev/null || true)"
        if [ -n "$canonical_dir" ] && ! is_protected_install_dir "$canonical_dir" && [ -d "$canonical_dir" ] && { [ -f "$canonical_dir/compose.yaml" ] || [ -f "$canonical_dir/docker-compose.yml" ]; }; then
            echo "$canonical_dir"
            return
        fi
    fi

    # Проверяем, запущен ли контейнер в Docker и где лежит его compose
    if command -v docker &>/dev/null; then
        local docker_workdir canonical_dir
        docker_workdir="$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' geo-routing-server 2>/dev/null || true)"
        canonical_dir="$(canonicalize_install_dir "$docker_workdir" 2>/dev/null || true)"
        if [ -n "$canonical_dir" ] && ! is_protected_install_dir "$canonical_dir" && [ -d "$canonical_dir" ] && { [ -f "$canonical_dir/compose.yaml" ] || [ -f "$canonical_dir/docker-compose.yml" ]; }; then
            echo "$canonical_dir"
            return
        fi
    fi

    # Проверяем текущую папку PWD
    if [ -f "$PWD/compose.yaml" ] || [ -f "$PWD/docker-compose.yml" ]; then
        local cf="$PWD/compose.yaml"
        [ -f "$PWD/docker-compose.yml" ] && cf="$PWD/docker-compose.yml"
        if grep -qE 'geo-routing-server' "$cf" 2>/dev/null; then
            echo "$PWD"
            return
        fi
    fi

    # Проверяем стандартные каталоги
    if [ -f "/opt/stacks/geo-routing-server/compose.yaml" ] || [ -f "/opt/stacks/geo-routing-server/docker-compose.yml" ]; then
        echo "/opt/stacks/geo-routing-server"
        return
    fi

    if [ -f "/opt/geo-routing-server/compose.yaml" ] || [ -f "/opt/geo-routing-server/docker-compose.yml" ]; then
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
        local saved_dir canonical_dir
        saved_dir="$(tr -d '\r\n' < "$CONFIG_FILE_RECORD")"
        canonical_dir="$(canonicalize_install_dir "$saved_dir" 2>/dev/null || true)"
        if [ -n "$canonical_dir" ] && ! is_protected_install_dir "$canonical_dir"; then
            echo "$canonical_dir"
        else
            echo "/opt/geo-routing-server"
        fi
    else
        echo "/opt/geo-routing-server"
    fi
}

save_install_dir() {
    local canonical_dir
    canonical_dir="$(canonicalize_install_dir "${1:-}")" || return 1
    is_protected_install_dir "$canonical_dir" && return 1
    printf '%s\n' "$canonical_dir" > "$CONFIG_FILE_RECORD"
}

create_cli_shortcut() {
    local target_dir="$1" wrapper_script="/usr/local/bin/geoserver"
    local wrapper_tmp
    mkdir -p /usr/local/bin || return 1
    wrapper_tmp=$(mktemp /usr/local/bin/.geoserver.XXXXXX) || return 1
    {
        printf '#!/usr/bin/env bash\n'
        printf 'TARGET_SCRIPT=%q\n' "$target_dir/install.sh"
        cat <<'WRAPPER'
set -euo pipefail
if [ ! -s "$TARGET_SCRIPT" ]; then
    printf '%s\n' 'Management script is missing; restoring from GitHub...' >&2
    script_tmp=$(mktemp "${TARGET_SCRIPT}.XXXXXX")
    trap 'rm -f -- "$script_tmp"' EXIT
    curl -fsSL --connect-timeout 5 --max-time 30 \
        https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh -o "$script_tmp"
    bash -n "$script_tmp"
    grep -q '^SCRIPT_VERSION="[0-9]' "$script_tmp"
    chmod 755 "$script_tmp"
    mv -- "$script_tmp" "$TARGET_SCRIPT"
    trap - EXIT
fi
exec bash "$TARGET_SCRIPT" "$@"
WRAPPER
    } > "$wrapper_tmp"
    bash -n "$wrapper_tmp" || { rm -f -- "$wrapper_tmp"; return 1; }
    chmod 755 "$wrapper_tmp"
    mv -- "$wrapper_tmp" "$wrapper_script"
    ln -sf "$wrapper_script" /usr/bin/geoserver 2>/dev/null || true
}

# Existing installations from older releases may have no geoserver command yet.
# A direct launch of install.sh repairs that compatibility path automatically.
ensure_cli_shortcut() {
    local target_dir="$1"
    [ "$(id -u)" -eq 0 ] || return 0
    [ -f "$target_dir/install.sh" ] || return 0
    grep -q "Geo Routing Server" "$target_dir/install.sh" 2>/dev/null || return 0
    create_cli_shortcut "$target_dir"
}

pause_menu() {
    [ "${NONINTERACTIVE:-false}" = true ] && return 0
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
        else
        echo -e "${RED}[!] Ошибка синхронизации. Проверьте логи: geoserver logs${NC}\n"
    fi
    pause_menu
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
    echo -e "\n${DIM}💎 Поддержать проект / Donations: https://github.com/xdeptu5/geo-routing-server#donate${NC}"
    pause_menu
}

proxy_print_snippet() {
    local kind="$1" domain="$2" upstream="$3" token="$4"
    case "$kind" in
        nginx)
            cat <<EOF
Nginx: ${domain}
# HTTP upstream; add this location to your existing HTTPS server block.
# Keep your existing listen 443 / ssl_certificate configuration.
location / {
    proxy_pass http://${upstream};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
}
# For an existing website, use location /${token}/ instead of location /.
# Validate and reload: nginx -t && nginx -s reload
EOF
            ;;
        caddy)
            cat <<EOF
Caddy: dedicated subdomain
${domain} {
    reverse_proxy ${upstream}
}
# Existing website: add inside its existing domain block:
handle /${token}/* {
    reverse_proxy ${upstream}
}
# Keep the token prefix: use handle, not handle_path.
EOF
            ;;
        npm)
            cat <<EOF
Nginx Proxy Manager:
  Domain Names: ${domain}
  Scheme: http
  Forward Hostname / IP: ${upstream%:*}
  Forward Port: ${upstream##*:}
  SSL: select/request certificate, enable Force SSL.
  Existing Proxy Host: Custom Locations -> Location /${token}/
  Use the same upstream host and port for that location.
EOF
            ;;
    esac
}

show_proxy_snippets() {
    local is_menu="${1:-false}" target_dir env_file
    target_dir="$(get_install_dir)"
    env_file="$target_dir/.env"
    [ -f "$env_file" ] || { printf '%s\n' 'Configuration .env not found.' >&2; return 1; }
    local domain port token clients bind upstream choice location
    domain=$(wizard_env_get "$env_file" DOMAIN geo.example.com)
    port=$(wizard_env_get "$env_file" HTTP_PORT 8080)
    token=$(wizard_env_get "$env_file" ROUTING_TOKEN TOKEN)
    clients=$(wizard_env_get "$env_file" ENABLED_CLIENTS HAPP,INCY)
    bind=$(wizard_env_get "$env_file" HTTP_BIND 127.0.0.1)
    if [ "$clients" = HAPP_DEEPLINK ] || [ "$clients" = HAPP_LOCAL ]; then
        printf '%s\n' 'HAPP_DEEPLINK: public reverse proxy is optional / публичный прокси не требуется.'
        pause_menu
        return 0
    fi
    choice=$(tui_select "Прокси / Reverse proxy:" 0 "Nginx" "Caddy" "Nginx Proxy Manager" "Все варианты / All" "Назад / Back") || return 0
    [ "$choice" = 4 ] && return 0
    location=$(tui_select "Где работает прокси? / Where does the proxy run?" 0 \
        "На этом сервере / On this host" \
        "В Docker, общая сеть / Docker, shared network" \
        "На другом сервере / Another host" "Назад / Back") || return 0
    case "$location" in
        0)
            case "$bind" in 0.0.0.0) bind=127.0.0.1 ;; ::) bind='[::1]' ;; esac
            upstream="${bind}:${port}"
            ;;
        1)
            upstream="geo-routing-server:80"
            printf '%s\n' 'Подключите оба контейнера к общей Docker-сети. / Both containers must share a Docker network.'
            ;;
        2)
            printf '%s\n' 'Укажите доступный с прокси адрес этого сервера. HTTP_BIND должен разрешать это подключение.'
            read -r -p 'Upstream host:port (q = cancel): ' upstream || return 0
            [ "$upstream" != q ] && [ -n "$upstream" ] || return 0
            [[ "$upstream" =~ ^[A-Za-z0-9.:[\]_-]+:[0-9]+$ ]] || { printf '%s\n' 'Invalid host:port.' >&2; return 1; }
            ;;
        *) return 0 ;;
    esac
    case "$choice" in
        0) proxy_print_snippet nginx "$domain" "$upstream" "$token" ;;
        1) proxy_print_snippet caddy "$domain" "$upstream" "$token" ;;
        2) proxy_print_snippet npm "$domain" "$upstream" "$token" ;;
        3)
            local kind
            for kind in nginx caddy npm; do
                proxy_print_snippet "$kind" "$domain" "$upstream" "$token"
                printf '\n'
            done
            ;;
    esac
    pause_menu
}


# Section settings are prepared in memory; only confirmed changes reach .env.
integration_text() {
    if [ "${UI_LANG:-ru}" = en ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

integration_read() {
    local label="$1" current="${2:-}" value
    printf '%s [%s] (Enter = %s, - = %s, q = %s): ' "$label" "$current" \
        "$(integration_text 'сохранить' 'keep')" "$(integration_text 'очистить' 'clear')" \
        "$(integration_text 'отмена' 'cancel')" >&2
    IFS= read -r value || return 1
    case "$value" in q|Q) return 1 ;; -) value="" ;; '') value="$current" ;; esac
    printf '%s' "$value"
}

integration_confirm() {
    local pick
    pick=$(tui_select "$(integration_text 'Сохранить и применить изменения?' 'Save and apply changes?')" 0 \
        "$(integration_text 'Отмена — оставить текущие настройки' 'Cancel — keep current settings')" \
        "$(integration_text 'Сохранить и применить' 'Save and apply')") || return 1
    [ "$pick" = 1 ]
}

integration_apply_env() {
    local target_dir="$1" patch="$2" env_file="$1/.env" draft backup was_running=false
    draft=$(mktemp "$target_dir/.env.draft.XXXXXX") || return 1
    if ! wizard_merge_env "$env_file" "$patch" "$draft"; then rm -f -- "$draft"; return 1; fi
    chmod 600 "$draft" || { rm -f -- "$draft"; return 1; }
    if ! (cd "$target_dir" && docker compose --env-file "$draft" config --quiet); then
        rm -f -- "$draft"
        integration_text 'Ошибка конфигурации. Рабочий .env не изменён.' 'Invalid configuration. The working .env was not changed.'; echo
        return 1
    fi
    backup="$target_dir/.env.backup"
    cp -p -- "$env_file" "$backup" || { rm -f -- "$draft"; return 1; }
    chmod 600 "$backup" || { rm -f -- "$draft"; return 1; }
    [ "$(docker inspect -f '{{.State.Running}}' geo-routing-server 2>/dev/null || true)" = true ] && was_running=true
    mv -- "$draft" "$env_file" || return 1
    INTEGRATION_APPLIED_RUNNING=false
    if [ "$was_running" = true ]; then
        if ! (cd "$target_dir" && docker compose up -d) || ! wait_for_container_health; then
            cp -p -- "$backup" "$env_file"
            integration_text 'Новые настройки не применены. Восстановлен прежний .env; возврат контейнера к прежним настройкам...' 'New settings failed. Previous .env restored; restoring the container...'; echo
            if ! (cd "$target_dir" && docker compose up -d); then
                integration_text 'Не удалось восстановить контейнер. Проверьте логи Docker Compose.' 'Could not restore the container. Check Docker Compose logs.'; echo
            fi
            return 1
        fi
        INTEGRATION_APPLIED_RUNNING=true
        integration_text 'Настройки сохранены, контейнер прошёл проверку состояния.' 'Settings saved; container health check passed.'; echo
    else
        integration_text 'Настройки сохранены. Контейнер оставлен остановленным; они применятся при запуске.' 'Settings saved. Container remains stopped; settings will apply on start.'; echo
    fi
}

configure_remnawave() {
    local target_dir env_file action input_base input_token input_cf_id input_cf_secret cf_pick
    target_dir="$(get_install_dir)"; env_file="$target_dir/.env"
    [ -f "$env_file" ] || { integration_text 'Сначала установите сервер.' 'Install the server first.'; echo; return 0; }
    print_header
    action=$(tui_select 'Remnawave API' 0 \
        "$(integration_text 'Настроить интеграцию' 'Configure integration')" \
        "$(integration_text 'Отключить интеграцию (сохранить сквады)' 'Disable integration (keep squads)')") || return 0
    local patch
    patch=$(mktemp "$target_dir/.env.patch.XXXXXX") || return 1
    if [ "$action" = 1 ]; then
        printf 'REMNAWAVE_TOKEN=\n' > "$patch"
        if integration_confirm; then integration_apply_env "$target_dir" "$patch" || true; fi
        rm -f -- "$patch"; pause_menu; return 0
    fi
    # No working file is changed while the user is answering questions.
    input_base=$(integration_read REMNAWAVE_BASE_URL "$(wizard_env_get "$env_file" REMNAWAVE_BASE_URL 'http://remnawave:3000/api')") || { rm -f -- "$patch"; return 0; }
    while [[ ! "$input_base" =~ ^https?://[^[:space:]]+$ ]]; do
        integration_text 'Введите полный адрес http:// или https://.' 'Enter a full http:// or https:// URL.'; echo
        input_base=$(integration_read REMNAWAVE_BASE_URL "$input_base") || { rm -f -- "$patch"; return 0; }
    done
    input_token=$(tui_secret REMNAWAVE_TOKEN "$(wizard_env_get "$env_file" REMNAWAVE_TOKEN)") || { rm -f -- "$patch"; return 0; }
    if [ -z "$input_token" ]; then integration_text 'Для подключения нужен токен. Для отключения используйте отдельный пункт.' 'A token is required. Use the disable option to turn integration off.'; echo; rm -f -- "$patch"; return 0; fi
    input_cf_id=$(wizard_env_get "$env_file" CLOUDFLARE_ZERO_TRUST_CLIENT_ID)
    input_cf_secret=$(wizard_env_get "$env_file" CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET)
    local cf_default=0
    [ -n "$input_cf_id" ] && cf_default=1
    cf_pick=$(tui_select 'Cloudflare Zero Trust' "$cf_default" \
        "$(integration_text 'Прямое подключение — отключить Service Token' 'Direct connection — disable Service Token')" \
        'Service Token') || { rm -f -- "$patch"; return 0; }
    if [ "$cf_pick" = 1 ]; then
        input_cf_id=$(tui_secret CLOUDFLARE_ZERO_TRUST_CLIENT_ID "$input_cf_id") || { rm -f -- "$patch"; return 0; }
        input_cf_secret=$(tui_secret CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET "$input_cf_secret") || { rm -f -- "$patch"; return 0; }
        if [ -z "$input_cf_id" ] || [ -z "$input_cf_secret" ]; then
            integration_text 'Нужны оба значения Service Token.' 'Both Service Token values are required.'; echo; rm -f -- "$patch"; return 0
        fi
    else input_cf_id=""; input_cf_secret=""; fi
    local ext_squads_raw existing_squads count_squads
    ext_squads_raw=$(fetch_remnawave_external_squads "$input_base" "$input_token" "$input_cf_id" "$input_cf_secret")
    if [ -n "$ext_squads_raw" ]; then printf '%s\n' "$ext_squads_raw"; else
        integration_text 'Список сквадов недоступен. Можно указать UUID вручную; подключение пока не подтверждено.' 'Squad list unavailable. Enter UUIDs manually; connectivity is not confirmed yet.'; echo
    fi
    existing_squads=$(grep -c '^REMNAWAVE_SQUAD_[0-9]*_UUID=.' "$env_file" || true)
    count_squads=$(integration_read "$(integration_text 'Количество внешних сквадов (0 = удалить привязки)' 'External squad count (0 = remove mappings)')" "$existing_squads") || { rm -f -- "$patch"; return 0; }
    while [[ ! "$count_squads" =~ ^[0-9]{1,3}$ ]] || [ "$((10#${count_squads:-0}))" -gt 100 ]; do
        integration_text 'Укажите число от 0 до 100.' 'Enter a number from 0 to 100.'; echo
        count_squads=$(integration_read 'Squads' "$existing_squads") || { rm -f -- "$patch"; return 0; }
    done
    count_squads=$((10#$count_squads))
    # Empty only known squad fields; preserve global rule and future REMNAWAVE keys.
    local key
    while IFS='=' read -r key _; do
        [[ "$key" =~ ^REMNAWAVE_SQUAD_[0-9]+_(UUID|NAME|RULE)$ ]] && printf '%s=\n' "$key" >> "$patch"
    done < "$env_file"
    local i sq_uuid sq_name sq_rule pick def_idx
    for ((i=1; i<=count_squads; i++)); do
        sq_uuid=$(integration_read "Squad #$i UUID" "$(wizard_env_get "$env_file" "REMNAWAVE_SQUAD_${i}_UUID")") || { rm -f -- "$patch"; return 0; }
        while [[ ! "$sq_uuid" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]; do
            integration_text 'Нужен UUID внешнего сквада.' 'An external squad UUID is required.'; echo
            sq_uuid=$(integration_read "Squad #$i UUID" "$sq_uuid") || { rm -f -- "$patch"; return 0; }
        done
        sq_name=$(printf '%s\n' "$ext_squads_raw" | awk -F '|' -v uuid="$sq_uuid" 'tolower($1)==tolower(uuid) {print $2; exit}')
        [ -n "$sq_name" ] || sq_name=$(wizard_env_get "$env_file" "REMNAWAVE_SQUAD_${i}_NAME")
        sq_rule=$(wizard_env_get "$env_file" "REMNAWAVE_SQUAD_${i}_RULE" JSONSUB.JSON)
        def_idx=3
        case "$sq_rule" in JSONSUB.JSON) def_idx=0 ;; WHITELIST.JSON) def_idx=1 ;; DEFAULT.JSON) def_idx=2 ;; esac
        pick=$(tui_select "Squad #$i" "$def_idx" JSONSUB.JSON WHITELIST.JSON DEFAULT.JSON "$(integration_text 'Свой файл' 'Custom file')") || { rm -f -- "$patch"; return 0; }
        case "$pick" in 0) sq_rule=JSONSUB.JSON ;; 1) sq_rule=WHITELIST.JSON ;; 2) sq_rule=DEFAULT.JSON ;;
            3) sq_rule=$(integration_read 'JSON filename' "$sq_rule") || { rm -f -- "$patch"; return 0; } ;;
        esac
        sq_rule="${sq_rule^^}"
        [[ "$sq_rule" = *.JSON ]] || sq_rule="${sq_rule}.JSON"
        if [[ ! "$sq_rule" =~ ^[A-Z0-9][A-Z0-9_.-]*\.JSON$ ]]; then
            integration_text 'Недопустимое имя JSON-файла.' 'Invalid JSON filename.'; echo; rm -f -- "$patch"; return 0
        fi
        wizard_env_put "$patch" "REMNAWAVE_SQUAD_${i}_UUID" "$sq_uuid"
        wizard_env_put "$patch" "REMNAWAVE_SQUAD_${i}_NAME" "$sq_name"
        wizard_env_put "$patch" "REMNAWAVE_SQUAD_${i}_RULE" "$sq_rule"
        printf '%s → %s\n' "$sq_uuid" "$sq_rule"
    done
    wizard_env_put "$patch" REMNAWAVE_BASE_URL "$input_base"
    wizard_env_put "$patch" REMNAWAVE_TOKEN "$input_token"
    wizard_env_put "$patch" CLOUDFLARE_ZERO_TRUST_CLIENT_ID "$input_cf_id"
    wizard_env_put "$patch" CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET "$input_cf_secret"
    wizard_env_put "$patch" CF_ACCESS_CLIENT_ID ''
    wizard_env_put "$patch" CF_ACCESS_CLIENT_SECRET ''
    local current_clients
    current_clients=$(wizard_env_get "$env_file" ENABLED_CLIENTS HAPP,INCY)
    if [[ ",${current_clients^^}," != *,HAPP,* && ",${current_clients^^}," != *,HAPP_DEEPLINK,* ]]; then
        integration_text 'Будет включена генерация Happ для правил Remnawave.' 'Happ generation will be enabled for Remnawave rules.'; echo
        wizard_env_put "$patch" ENABLED_CLIENTS "${current_clients:+$current_clients,}HAPP"
    fi
    printf 'Remnawave: %s; squads: %s; Cloudflare: %s\n' "$input_base" "$count_squads" "$cf_pick"
    if integration_confirm && integration_apply_env "$target_dir" "$patch"; then
        integration_text 'Передачу правил проверьте в статусе синхронизации. Для немедленной передачи выберите «Синхронизировать сейчас».' 'Check synchronization status for rule delivery. Select Sync now for immediate delivery.'; echo
    fi
    rm -f -- "$patch"; pause_menu; return 0
}

install_latest_management_script() {
    local target_dir="$1"
    local candidate=""
    local new_version=""

    mkdir -p "$target_dir" || return 1
    candidate=$(mktemp "$target_dir/.install.sh.XXXXXX") || return 1
    if ! curl -fsSL --connect-timeout 5 --max-time 20 \
        "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" \
        -o "$candidate" 2>/dev/null; then
        rm -f "$candidate"
        return 1
    fi

    if ! bash -n "$candidate" 2>/dev/null; then
        rm -f "$candidate"
        return 1
    fi

    new_version=$(grep -E '^SCRIPT_VERSION=' "$candidate" | head -n 1 | cut -d'"' -f2 || true)
    if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        rm -f "$candidate"
        return 1
    fi

    if [ "$new_version" = "$SCRIPT_VERSION" ]; then
        rm -f "$candidate"
        return 2
    fi

    local highest_version
    highest_version=$(printf '%s\n%s\n' "$SCRIPT_VERSION" "$new_version" | sort -V | tail -n 1)
    if [ "$highest_version" != "$new_version" ]; then
        rm -f "$candidate"
        return 3
    fi

    if ! chmod +x "$candidate"; then rm -f "$candidate"; return 1; fi
    if [ -f "$target_dir/install.sh" ]; then
        if ! cp -p "$target_dir/install.sh" "$target_dir/install.sh.bak"; then rm -f "$candidate"; return 1; fi
    fi
    if ! mv "$candidate" "$target_dir/install.sh"; then rm -f "$candidate"; return 1; fi
    create_cli_shortcut "$target_dir" || return 1
    rm -f /tmp/.geoserver_ver_cache 2>/dev/null || true
    printf '%s' "$new_version"
}

update_message() {
    if [ "${UI_LANG:-ru}" = en ]; then printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}

reset_update_checks() {
    CHECKED_REMOTE_VER=""
    CHECKED_REMOTE_IMG_DIGEST=""
    UPDATE_AVAILABLE=false
    IMAGE_UPDATE_AVAILABLE=false
    SCRIPT_CHECK_STATUS=unchecked
    IMAGE_CHECK_STATUS=unchecked
}

update_script_only() {
    local target_dir new_v result=0
    target_dir="$(get_install_dir)"
    update_message '[>] Обновление скрипта управления...' '[>] Updating management script...'
    if new_v=$(install_latest_management_script "$target_dir"); then
        update_message "[+] Скрипт обновлён: v${SCRIPT_VERSION#v} → v$new_v" "[+] Script updated: v${SCRIPT_VERSION#v} → v$new_v"
        reset_update_checks
        if [ "${NONINTERACTIVE:-false}" != true ]; then
            pause_menu
            exec bash "$target_dir/install.sh" "--lang=${UI_LANG:-ru}" menu
        fi
    else
        result=$?
        case "$result" in
            2) update_message "[+] Скрипт актуален: v${SCRIPT_VERSION#v}" "[+] Script is up to date: v${SCRIPT_VERSION#v}"; result=0 ;;
            3) update_message '[!] Версия на GitHub старее. Замена отменена.' '[!] GitHub version is older. Replacement cancelled.' ;;
            *) update_message '[!] Не удалось скачать, проверить или сохранить скрипт.' '[!] Could not download, validate or save the script.' ;;
        esac
    fi
    reset_update_checks
    [ "${NONINTERACTIVE:-false}" = true ] || pause_menu
    return "$result"
}

wait_for_container_health() {
    local attempt health_status
    for attempt in {1..30}; do
        health_status=$(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' geo-routing-server 2>/dev/null || true)
        case "$health_status" in
            'running healthy'|'running none') return 0 ;;
            *unhealthy*|exited*|dead*|'') return 1 ;;
        esac
        sleep 2
    done
    return 1
}

wait_for_initial_sync() {
    local attempt sync_status sync_on_start
    sync_on_start=$(docker exec geo-routing-server printenv SYNC_ON_START 2>/dev/null || true)
    case "${sync_on_start,,}" in ""|true|1|yes) ;; *) return 0 ;; esac
    for attempt in {1..45}; do
        sync_status=$(docker exec geo-routing-server sh -c 'cat "/app/www/${ROUTING_TOKEN:-local}/.sync-status.json"' 2>/dev/null || true)
        case "$sync_status" in
            *'"state":"success"'*) return 0 ;;
            *'"state":"failed"'*) return 1 ;;
        esac
        sleep 2
    done
    return 2
}

# Compose selects the existing project configuration, including legacy names and overrides.
update_project() {
    local component="${1:-all}" target_dir new_v="" script_result=0
    target_dir="$(get_install_dir)"
    if [ "$component" = all ]; then
        if new_v=$(install_latest_management_script "$target_dir"); then
            update_message "[+] Скрипт обновлён: v${SCRIPT_VERSION#v} → v$new_v" "[+] Script updated: v${SCRIPT_VERSION#v} → v$new_v"
        else
            script_result=$?
            case "$script_result" in
                2) script_result=0; update_message '[+] Скрипт актуален.' '[+] Script is up to date.' ;;
                *) update_message '[!] Скрипт не обновлён; продолжаем обновление образа.' '[!] Script not updated; continuing with image update.' ;;
            esac
        fi
    fi
    local old_img_id running configured_images new_img_id
    old_img_id=$(docker inspect --format '{{.Image}}' geo-routing-server 2>/dev/null || true)
    running=$(docker inspect --format '{{.State.Running}}' geo-routing-server 2>/dev/null || true)
    update_message '[>] Загрузка образа из текущей конфигурации Compose...' '[>] Pulling image from the current Compose configuration...'
    if ! (cd "$target_dir" && docker compose config --quiet && docker compose pull); then
        update_message '[!] Образ не загружен. Состояние контейнера не изменено.' '[!] Image pull failed. Container state is unchanged.'
        return 1
    fi
    configured_images=$(cd "$target_dir" && docker compose config --images geo-routing-server) || return 1
    new_img_id=$(docker image inspect --format '{{.Id}}' "${configured_images%%$'\n'*}" 2>/dev/null || true)
    if [ "$running" != true ]; then
        update_message '[+] Образ загружен. Контейнер оставлен остановленным; запустите geoserver start.' '[+] Image pulled. Container remains stopped; run geoserver start.'
    elif [ -n "$new_img_id" ] && [ "$old_img_id" = "$new_img_id" ]; then
        update_message '[+] Контейнер уже использует актуальный образ.' '[+] Container already uses the current image.'
    else
        if ! (cd "$target_dir" && docker compose up -d); then
            update_message '[!] Не удалось применить образ. Проверьте geoserver logs.' '[!] Could not apply image. Check geoserver logs.'
            return 1
        fi
        if ! wait_for_container_health; then
            update_message '[!] Контейнер не готов. Проверьте geoserver logs.' '[!] Container is not ready. Check geoserver logs.'
            return 1
        fi
        if ! wait_for_initial_sync; then
            update_message '[!] Контейнер запущен, но успех синхронизации не подтверждён. Проверьте geoserver logs.' '[!] Container started, but sync success was not confirmed. Check geoserver logs.'
            return 1
        fi
        update_message '[+] Образ применён, контейнер готов.' '[+] Image applied, container ready.'
    fi
    reset_update_checks
    if [ "${NONINTERACTIVE:-false}" != true ]; then
        pause_menu
        if [ "$component" = all ] && [ -n "$new_v" ]; then
            exec bash "$target_dir/install.sh" "--lang=${UI_LANG:-ru}" menu
        fi
    fi
    return "$script_result"
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
    if [ "$(docker inspect --format '{{.State.Running}}' geo-routing-server 2>/dev/null || true)" = true ]; then
        echo -e "${YELLOW}[*] Перезапуск контейнера...${NC}"
        docker compose restart
    else
        echo -e "${YELLOW}[*] Запуск контейнера с текущей конфигурацией...${NC}"
        docker compose up -d
    fi
    if wait_for_container_health; then
        echo -e "${GREEN}[+] Контейнер запущен и готов.${NC}\n"
    else
        echo -e "${RED}[!] Контейнер не подтвердил готовность. Проверьте логи.${NC}\n"
        return 1
    fi
    pause_menu
}

stop_server() {
    local target_dir
    target_dir="$(get_install_dir)"
    cd "$target_dir"
    echo -e "${YELLOW}[*] Остановка контейнера...${NC}"
    docker compose stop
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

send_telegram_test_action() {
    local target_dir
    target_dir="$(get_install_dir)"
    local env_file="$target_dir/.env"

    local token=""
    local chat=""
    local thread=""
    if [ -f "$env_file" ]; then
        token=$(grep "^TELEGRAM_BOT_TOKEN=" "$env_file" | cut -d'=' -f2- || true)
        chat=$(grep "^TELEGRAM_CHAT_ID=" "$env_file" | cut -d'=' -f2- || true)
        thread=$(grep "^TELEGRAM_THREAD_ID=" "$env_file" | cut -d'=' -f2- || true)
    fi

    if [ -z "$token" ] || [ -z "$chat" ]; then
        echo -e "\n${RED}${BOLD}[!] Telegram-уведомления не настроены!${NC}"
        echo -e "Сначала укажите токен бота и Chat ID в пункте настройки.\n"
        pause_menu
        return 0
    fi

    echo -e "\n${BLUE}[*] Проверка отправки тестового сообщения...${NC}"
    test_telegram "$token" "$chat" "$thread" || true
    pause_menu
    return 0
}

configure_telegram() {
    local target_dir env_file action current_token current_chat current_thread current_notify
    local input_token input_chat input_thread input_notify succ_pick patch
    target_dir="$(get_install_dir)"; env_file="$target_dir/.env"
    [ -f "$env_file" ] || { integration_text 'Сначала установите сервер.' 'Install the server first.'; echo; return 0; }
    print_header
    current_token=$(wizard_env_get "$env_file" TELEGRAM_BOT_TOKEN)
    current_chat=$(wizard_env_get "$env_file" TELEGRAM_CHAT_ID)
    current_thread=$(wizard_env_get "$env_file" TELEGRAM_THREAD_ID)
    current_notify=$(wizard_env_get "$env_file" TELEGRAM_NOTIFY_SUCCESS false)
    printf '%s: %s\n' "$(integration_text 'Telegram' 'Telegram')" "$([ -n "$current_token" ] && integration_text 'настроен' 'configured' || integration_text 'не настроен' 'not configured')"
    action=$(tui_select "$(integration_text 'Действие:' 'Action:')" 0 \
        "$(integration_text 'Настроить уведомления' 'Configure notifications')" \
        "$(integration_text 'Отключить уведомления' 'Disable notifications')" \
        "$(integration_text 'Назад' 'Back')") || return 0
    [ "$action" != 2 ] || return 0
    patch=$(mktemp "$target_dir/.env.patch.XXXXXX") || return 1
    if [ "$action" = 1 ]; then
        wizard_env_put "$patch" TELEGRAM_BOT_TOKEN ''
        wizard_env_put "$patch" TELEGRAM_CHAT_ID ''
        wizard_env_put "$patch" TELEGRAM_THREAD_ID ''
        wizard_env_put "$patch" TELEGRAM_NOTIFY_SUCCESS false
    else
        input_token=$(tui_secret TELEGRAM_BOT_TOKEN "$current_token") || { rm -f -- "$patch"; return 0; }
        input_chat=$(integration_read TELEGRAM_CHAT_ID "$current_chat") || { rm -f -- "$patch"; return 0; }
        input_thread=$(integration_read TELEGRAM_THREAD_ID "$current_thread") || { rm -f -- "$patch"; return 0; }
        if [ -z "$input_token" ] || [ -z "$input_chat" ]; then
            integration_text 'Нужны токен бота и Chat ID.' 'Bot token and Chat ID are required.'; echo
            rm -f -- "$patch"; pause_menu; return 0
        fi
        local succ_default=0
        [ "$current_notify" = true ] && succ_default=1
        succ_pick=$(tui_select "$(integration_text 'Сообщать об успешном обновлении баз?' 'Notify after a successful database update?')" "$succ_default" \
            "$(integration_text 'Нет, только ошибки' 'No, errors only')" \
            "$(integration_text 'Да' 'Yes')") || { rm -f -- "$patch"; return 0; }
        input_notify=false; [ "$succ_pick" = 1 ] && input_notify=true
        wizard_env_put "$patch" TELEGRAM_BOT_TOKEN "$input_token"
        wizard_env_put "$patch" TELEGRAM_CHAT_ID "$input_chat"
        wizard_env_put "$patch" TELEGRAM_THREAD_ID "$input_thread"
        wizard_env_put "$patch" TELEGRAM_NOTIFY_SUCCESS "$input_notify"
    fi
    if integration_confirm; then integration_apply_env "$target_dir" "$patch" || true; fi
    rm -f -- "$patch"
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

        # Удаляем каталог проекта
        if [ -n "$target_dir" ] && [ -d "$target_dir" ]; then
            if ! reset_install_dir "$target_dir"; then
                local bname
                bname="$(basename "$target_dir")"
                if [ "$bname" = "geo-routing-server" ] && ! is_protected_install_dir "$target_dir"; then
                    rm -rf -- "$target_dir"
                else
                    echo -e "${YELLOW}[!] Каталог $target_dir не имеет маркера geo-routing-server. Каталог сохранён.${NC}"
                fi
            fi
        fi

        rm -f "$CONFIG_FILE_RECORD" "$LANG_RECORD"
        rm -f /usr/local/bin/geoserver /usr/bin/geoserver /usr/local/bin/grs /usr/bin/grs /usr/local/bin/geo-server /usr/bin/geo-server
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

# Read dotenv values without executing configuration as shell code.
wizard_env_get() {
    local file="$1" key="$2" fallback="${3-}"
    if [ ! -f "$file" ]; then printf '%s' "$fallback"; return 0; fi
    local value
    if ! value=$(awk -v key="$key" 'index($0,key "=")==1 {v=substr($0,length(key)+2); sub(/\r$/,"",v); found=1} END {if(found) print v; else exit 1}' "$file"); then
        printf '%s' "$fallback"
        return 0
    fi
    if [[ "$value" == \"*\" || "$value" == \'*\' ]]; then value="${value:1:${#value}-2}"; fi
    printf '%s' "$value"
}

# Patch exact keys; retain unknown settings, comments and intentional empty values.
wizard_merge_env() {
    local original="$1" patch="$2" output="$3"
    [ -f "$original" ] || original=/dev/null
    awk 'FILENAME==ARGV[1] {p=index($0,"="); if(p>1){k=substr($0,1,p-1); if(!(k in values)) order[++count]=k; values[k]=$0} next}
        {line=$0; sub(/\r$/,"",line); p=index(line,"="); k=substr(line,1,p-1); if(p>1 && k in values){if(!seen[k]++) print values[k]} else print line}
        END {for(i=1;i<=count;i++){k=order[i]; if(!seen[k]) print values[k]}}' "$patch" "$original" > "$output"
}

wizard_env_put() {
    local output="" key value
    if [ "$#" -eq 3 ]; then output="$1"; key="$2"; value="${3-}"; else key="$1"; value="${2-}"; fi
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
    # Escape dotenv metacharacters only when required; keep ordinary values readable.
    if [[ "$value" =~ ^[a-zA-Z0-9_./,:@%+?=\ -]*$ ]]; then
        if [ -n "$output" ]; then printf '%s=%s\n' "$key" "$value" >> "$output"; else printf '%s=%s\n' "$key" "$value"; fi
    else
        value="${value//\'/\\\'}"
        if [ -n "$output" ]; then printf "%s='%s'\n" "$key" "$value" >> "$output"; else printf "%s='%s'\n" "$key" "$value"; fi
    fi
}

wizard_choose_port() {
    local proposed="${prev_port:-8080}" input_port
    while true; do
        read -r -p "  ▸ HTTP-порт [$proposed]: " input_port || return 130
        HTTP_PORT="${input_port:-$proposed}"
        if [[ ! "$HTTP_PORT" =~ ^[0-9]{1,5}$ ]] || ((10#$HTTP_PORT < 1 || 10#$HTTP_PORT > 65535)); then
            echo "[!] Порт должен быть от 1 до 65535."
            continue
        fi
        HTTP_PORT=$((10#$HTTP_PORT))
        if is_port_in_use "$HTTP_PORT" && ! docker port geo-routing-server 80/tcp 2>/dev/null | grep -qE ":${HTTP_PORT}$"; then
            echo "[!] Порт занят. Другие контейнеры автоматически не останавливаются."
            proposed="$(find_free_port 8081)"
            continue
        fi
        return 0
    done
}

wizard_advanced() {
    local choice key value current label hint
    while true; do
        choice=$(tui_select "Дополнительные параметры\nОбычной установке они не нужны. Стрелки — выбор, Enter — открыть, 0 — назад." 7 \
            "Где слушать HTTP (обычно 127.0.0.1)" \
            "Синхронизировать данные при запуске контейнера" \
            "Какие файлы отдавать клиентам" \
            "Свой источник правил маршрутизации" \
            "Свой источник GeoIP" \
            "Свой источник GeoSite" \
            "Geo-базы находятся на другом сервере" \
            "Назад без изменений") || return 130
        case "$choice" in
            0) key=HTTP_BIND; label="Адрес HTTP-сервера"; hint="Оставьте 127.0.0.1, если прокси работает на этом же сервере." ;;
            1) key=SYNC_ON_START ;;
            2) key=SERVE_FORMATS; label="Форматы для клиентов"; hint="Обычно CLIENT_OPTIMIZED: Happ получает .DEEPLINK, Incy — .JSON." ;;
            3) key=ROUTING_SOURCE_REPO; label="URL источника правил"; hint="Меняйте только для собственного репозитория с правилами." ;;
            4) key=GEOIP_SOURCE_URL; label="URL файла GeoIP"; hint="Необязательно. Пусто — используется источник из правил." ;;
            5) key=GEOSITE_SOURCE_URL; label="URL файла GeoSite"; hint="Необязательно. Пусто — используется источник из правил." ;;
            6) key=PUBLIC_GEO_BASE_URL; label="Адрес другого Geo-сервера"; hint="Укажите URL с токеном, только если GeoIP/GeoSite отдаются другим сервером." ;;
            *) WIZARD_ADVANCED_CANCELLED=true; return 0 ;;
        esac
        current="${!key}"
        if [ "$key" = SYNC_ON_START ]; then
            local default=0
            [ "$current" = false ] && default=1
            choice=$(tui_select "Синхронизировать при запуске контейнера?" "$default" \
                "Да — сразу загрузить свежие данные" \
                "Нет — ждать ручной или плановой синхронизации" \
                "Назад к дополнительным параметрам") || return 130
            case "$choice" in
                0) value=true ;;
                1) value=false ;;
                *) continue ;;
            esac
        else
            echo "  $hint"
            read -r -p "  ▸ $label [$current]: " value || return 130
            value="${value:-$current}"
            if [ "$value" = - ]; then
                case "$key" in GEOIP_SOURCE_URL|GEOSITE_SOURCE_URL|PUBLIC_GEO_BASE_URL) value="" ;; *) echo "[!] Значение обязательно."; continue ;; esac
            fi
            if [[ "$value" == *$'\r'* || "$value" == *$'\n'* ]]; then echo "[!] Значение должно занимать одну строку."; continue; fi
            case "$key" in
                HTTP_BIND) [[ "$value" =~ ^[a-zA-Z0-9.:_-]+$ ]] || { echo "[!] Неверный адрес привязки."; continue; } ;;
                SERVE_FORMATS) [[ "$value" =~ ^(CLIENT_OPTIMIZED|OPTIMIZED|ALL|JSON|DEEPLINK)$ ]] || { echo "[!] Неверный список форматов."; continue; } ;;
                *URL|ROUTING_SOURCE_REPO) [ -z "$value" ] || [[ "$value" =~ ^https?://[^[:space:]]+$ ]] || { echo "[!] Укажите HTTP(S) URL."; continue; } ;;
            esac
        fi
        printf -v "$key" '%s' "$value"
    done
}

wizard_write_patch() {
    local key
    for key in "${wizard_keys[@]}"; do wizard_env_put "$key" "${!key}" || return 1; done
    if [ "$wizard_change_remna" = true ]; then
        # Empty obsolete mappings explicitly; unrelated Remnawave tuning survives.
        if [ -f "$scan_env" ]; then
            while IFS='=' read -r key _; do
                case "$key" in REMNAWAVE_SQUAD_*|REMNAWAVE_BASE_URL|REMNAWAVE_TOKEN|CLOUDFLARE_ZERO_TRUST_CLIENT_ID|CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET) printf '%s=\n' "$key" ;; esac
            done < "$scan_env"
        fi
        printf '%s' "$REMNA_BLOCK"
    fi
}

wizard_render_compose() {
    cat <<'COMPOSE'
# Generated by geoserver. Regeneration requires confirmation in the installer.
services:
  geo-routing-server:
    image: ghcr.io/xdeptu5/geo-routing-server:latest
    container_name: geo-routing-server
    restart: unless-stopped
    env_file:
      - .env
    ports:
      - "${HTTP_BIND:-127.0.0.1}:${HTTP_PORT:-8080}:80"
    volumes:
      - routing_data:/app/www
      - ./.cache:/app/.cache
      - ./custom_geo:/app/custom_geo:ro
COMPOSE
    if [ -n "$EXT_NETWORK" ]; then
        printf '    networks:\n      - default\n      - external_service\n'
    fi
    cat <<'COMPOSE'
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
volumes:
  routing_data:
COMPOSE
    if [ -n "$EXT_NETWORK" ]; then
        printf 'networks:\n  external_service:\n    name: %s\n    external: true\n' "$EXT_NETWORK"
    fi
}

wizard_apply() {
    local compose_choice=1 compose_name=compose.yaml choice
    if [ -n "$comp_scan" ]; then
        compose_name="$(basename "$comp_scan")"
        compose_choice=$(tui_select "Compose уже существует. Как применить настройки?" 0 \
            "Сохранить существующий Compose (тома, сети, параметры)" \
            "Создать Compose заново по выбранным настройкам (с резервной копией)" \
            "Отмена") || return 130
        [ "$compose_choice" = 2 ] && return 0
        if [ "$compose_choice" = 0 ] && [ "$EXT_NETWORK" != "$prev_ext_network" ]; then
            echo "[!] Для изменения сети нужен новый Compose либо ручная правка существующего. Настройки не применены."
            return 1
        fi
    fi
    if [ -n "$EXT_NETWORK" ] && [[ ! "$EXT_NETWORK" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        echo "[!] Неверное имя Docker-сети."
        return 1
    fi
    echo
    printf '  Каталог: %s\n  Клиенты: %s\n  Правила: %s\n  Базы: GeoIP=%s, GeoSite=%s\n  HTTP: %s:%s\n  Расписание: %s\n  Синхронизация при старте: %s\n  Docker-сеть: %s\n' \
        "$INSTALL_DIR" "$ENABLED_CLIENTS" "$ROUTING_RULES" "$SERVE_GEOIP" "$SERVE_GEOSITE" "$HTTP_BIND" "$HTTP_PORT" "$SCHEDULE" "$SYNC_ON_START" "${EXT_NETWORK:-стандартная}"
    echo "  Токены и пароли скрыты. До применения рабочие файлы не менялись."
    choice=$(tui_select "Применить настройки и запустить контейнер?" 0 "Применить" "Отмена") || return 130
    [ "$choice" = 0 ] || return 0

    local stage backup
    stage=$(mktemp -d) || return 1
    chmod 700 "$stage"
    if ! wizard_write_patch > "$stage/patch" || ! wizard_merge_env "$scan_env" "$stage/patch" "$stage/.env"; then
        rm -rf -- "$stage"
        return 1
    fi
    chmod 600 "$stage/.env" "$stage/patch"
    if [ "$compose_choice" != 0 ]; then
        wizard_render_compose > "$stage/$compose_name" || { rm -rf -- "$stage"; return 1; }
    fi
    local validation_dir="$stage" validation_compose="$stage/$compose_name"
    if [ "$compose_choice" = 0 ]; then
        validation_dir="$INSTALL_DIR"
        validation_compose="$comp_scan"
    fi
    if ! docker compose --project-directory "$validation_dir" --env-file "$stage/.env" -f "$validation_compose" config --quiet; then
        echo "[!] Compose не прошёл проверку. Рабочие файлы не изменены."
        rm -rf -- "$stage"
        return 1
    fi
    if ! INSTALL_DIR=$(prepare_install_dir "$INSTALL_DIR"); then rm -rf -- "$stage"; return 1; fi
    backup="$INSTALL_DIR/.backup-$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -m 700 "$backup" || { rm -rf -- "$stage"; return 1; }
    [ ! -f "$INSTALL_DIR/.env" ] || cp -p "$INSTALL_DIR/.env" "$backup/.env" || return 1
    if [ "$compose_choice" != 0 ] && [ -f "$INSTALL_DIR/$compose_name" ]; then
        cp -p "$INSTALL_DIR/$compose_name" "$backup/$compose_name" || return 1
    fi
    if [ -n "$EXT_NETWORK" ] && ! docker network inspect "$EXT_NETWORK" >/dev/null 2>&1; then
        if ! docker network create "$EXT_NETWORK"; then rm -rf -- "$stage"; return 1; fi
    fi
    cp "$stage/.env" "$INSTALL_DIR/.env.new" && chmod 600 "$INSTALL_DIR/.env.new" && \
        mv "$INSTALL_DIR/.env.new" "$INSTALL_DIR/.env" || { rm -rf -- "$stage"; return 1; }
    if [ "$compose_choice" != 0 ]; then
        cp "$stage/$compose_name" "$INSTALL_DIR/$compose_name.new" && \
            mv "$INSTALL_DIR/$compose_name.new" "$INSTALL_DIR/$compose_name" || { rm -rf -- "$stage"; return 1; }
    fi
    rm -rf -- "$stage"
    mkdir -p "$INSTALL_DIR/custom_geo"
    chmod 755 "$INSTALL_DIR" "$INSTALL_DIR/custom_geo"
    save_install_dir "$INSTALL_DIR"
    if [ -f "$0" ] && grep -q "Geo Routing Server" "$0"; then
        [ "$(readlink -f "$0")" = "$(readlink -f "$INSTALL_DIR/install.sh")" ] || cp "$0" "$INSTALL_DIR/install.sh"
    else
        curl -fsSL "https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh" -o "$INSTALL_DIR/install.sh" || echo "[!] Не удалось сохранить скрипт управления."
    fi
    [ ! -f "$INSTALL_DIR/install.sh" ] || chmod +x "$INSTALL_DIR/install.sh"
    create_cli_shortcut "$INSTALL_DIR"
    local -a compose=(docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/$compose_name")
    local was_running=false had_existing_install=false
    [ -n "$scan_env" ] || [ -n "$comp_scan" ] && had_existing_install=true
    [ "$(docker inspect --format '{{.State.Running}}' geo-routing-server 2>/dev/null || true)" = true ] && was_running=true
    if [ "$had_existing_install" = true ] && [ "$was_running" = false ]; then
        echo "[+] Настройки сохранены. Контейнер оставлен остановленным; запустите его через geoserver start."
        return 0
    fi
    if ! "${compose[@]}" pull; then
        echo "[!] Образ не загружен. Настройки сохранены; запуск не выполнен."
        echo "  Резервная копия: $backup"
        return 1
    fi
    if ! "${compose[@]}" up -d; then
        echo "[!] Контейнер не запущен. Резервная копия: $backup"
        choice=$(tui_select "Восстановить предыдущую конфигурацию?" 0 "Восстановить файлы" "Оставить новые файлы для исправления") || return 130
        if [ "$choice" = 0 ]; then
            [ ! -f "$backup/.env" ] || cp -p "$backup/.env" "$INSTALL_DIR/.env"
            [ ! -f "$backup/$compose_name" ] || cp -p "$backup/$compose_name" "$INSTALL_DIR/$compose_name"
            echo "  Предыдущие файлы восстановлены. Запустите контейнер после проверки причины ошибки."
        fi
        return 1
    fi
    echo "[+] Настройки сохранены, команда запуска выполнена."
    if ! wait_for_container_health; then
        echo "[!] Контейнер ещё не подтвердил готовность. Проверьте статус и логи в geoserver."
        return 1
    fi
    if [ "$SYNC_ON_START" = true ]; then
        if ! wait_for_initial_sync; then echo "[!] Сервис работает, но стартовая синхронизация не подтверждена. Проверьте логи."; fi
    fi
    echo "[+] Контейнер готов. Управление: geoserver"
    [ "$NEEDS_PUBLIC_DOMAIN" != true ] || show_proxy_snippets false
    show_links
    return 0
}


wizard_choose_mode() {
    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 2: Выбор сценария работы сервера
    # ────────────────────────────────────────────────────────────────────────
    ui_step "2" "Сценарий и режим работы сервера"
    local default_role_idx=0
    [ -z "$prev_remna_token" ] && default_role_idx=1
    case "$prev_clients" in
        "HAPP_DEEPLINK") default_role_idx=3 ;;
        "INCY") [ -n "$prev_public_geo" ] && default_role_idx=4 ;;
        "INCY_GEO") default_role_idx=2 ;;
        "HAPP_GEO"|"HAPP_GEO,INCY_GEO") default_role_idx=2 ;;
        *) : ;;
    esac

    local role_idx
    role_idx=$(tui_select "Выберите режим работы сервера:" "$default_role_idx" \
        "Раздача правил и Geo-баз + синхронизация с Remnawave" \
        "Раздача правил и Geo-баз (обычный вариант, без Remnawave)" \
        "Только базы (раздача geoip.dat и geosite.dat без правил)" \
        "Только Remnawave (автообновление сквадов, базы на внешнем сервере)" \
        "Только Incy (раздача подписки JSON, базы на внешнем сервере)") || return 130

    server_role=$((role_idx + 1))
    PUBLIC_GEO_BASE_URL=""
    ROUTING_SOURCE_REPO="$prev_routing_repo"
    NEEDS_PUBLIC_DOMAIN=true
    config_remna=false

    local default_client_idx=0
    case "$prev_clients" in HAPP|HAPP_GEO) default_client_idx=1 ;; INCY|INCY_GEO) default_client_idx=2 ;; esac
    case "$server_role" in
        2)
            local client_idx
            client_idx=$(tui_select "Выберите поддерживаемых клиентов:" "$default_client_idx" \
                "Happ и Incy" \
                "Только Happ" \
                "Только Incy") || return 130
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
            client_idx=$(tui_select "Формат баз:" "$default_client_idx" \
                "Happ и Incy" \
                "Только Happ" \
                "Только Incy") || return 130
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
            client_idx=$(tui_select "Поддерживаемые клиенты:" "$default_client_idx" \
                "Happ и Incy" \
                "Только Happ" \
                "Только Incy") || return 130
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
            read -r -p "$prompt_str" input_geo_url || return 130
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
                conf_tok_idx=$(tui_select "Сервер действительно настроен без токена?" 0 "Нет, ввести заново" "Да, продолжить без токена") || return 130
                if [ "$conf_tok_idx" -eq 0 ]; then
                    continue
                fi
            fi

            break
        done
        echo -e "${GREEN}[+] Базы: $PUBLIC_GEO_BASE_URL${NC}\n"
    fi

    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 2.1: Состав отдаваемых файлов и правил
    # ────────────────────────────────────────────────────────────────────────
    ROUTING_RULES="${prev_rules:-JSONSUB,WHITELIST}"
    SERVE_FORMATS="${prev_formats:-CLIENT_OPTIMIZED}"
    SERVE_GEOIP="${prev_serve_geoip:-true}"
    SERVE_GEOSITE="${prev_serve_geosite:-true}"

    if [ "$server_role" != "3" ]; then
        echo -e "${CYAN}${BOLD}[*] Настройка состава правил и форматов файлов:${NC}"
        local default_rules_idx=0
        case "$prev_rules" in
            "JSONSUB") default_rules_idx=1 ;;
            "ALL"|"DEFAULT,JSONSUB,WHITELIST") default_rules_idx=2 ;;
            "JSONSUB,WHITELIST") default_rules_idx=0 ;;
            *) default_rules_idx=3 ;;
        esac

        local rules_idx
        rules_idx=$(tui_select "Какие правила генерировать и отдавать?" "$default_rules_idx" \
            "JSONSUB и WHITELIST (маршрут подписок + белый список)" \
            "Только JSONSUB (только маршрут подписок)" \
            "Все правила источника (DEFAULT, JSONSUB, WHITELIST)" \
            "Ввести список правил вручную (через запятую)") || return 130

        case "$rules_idx" in
            1) ROUTING_RULES="JSONSUB" ;;
            2) ROUTING_RULES="ALL" ;;
            3)
                read -r -p "  ▸ Введите имена правил через запятую [${prev_rules:-JSONSUB,WHITELIST}]: " custom_rules || return 130
                ROUTING_RULES="${custom_rules:-${prev_rules:-JSONSUB,WHITELIST}}"
                ROUTING_RULES="$(echo "$ROUTING_RULES" | tr -d ' ')"
                ;;
            *) ROUTING_RULES="JSONSUB,WHITELIST" ;;
        esac
        echo -e "  ${GREEN}[+] Правила: ${BOLD}$ROUTING_RULES${NC}\n"
    fi

    if [ "$server_role" != "4" ]; then
        local default_geo_idx=0
        if [ "$prev_serve_geoip" = "true" ] && [ "$prev_serve_geosite" = "false" ]; then
            default_geo_idx=1
        elif [ "$prev_serve_geoip" = "false" ] && [ "$prev_serve_geosite" = "true" ]; then
            default_geo_idx=2
        elif [ "$prev_serve_geoip" = "false" ] && [ "$prev_serve_geosite" = "false" ]; then
            default_geo_idx=3
        fi

        local geo_pick
        geo_pick=$(tui_select "Раздача баз GeoIP и GeoSite:" "$default_geo_idx" \
            "Обе базы (geoip.dat и geosite.dat)" \
            "Только geoip.dat" \
            "Только geosite.dat" \
            "Не раздавать базы (только правила)") || return 130

        case "$geo_pick" in
            1) SERVE_GEOIP="true"; SERVE_GEOSITE="false" ;;
            2) SERVE_GEOIP="false"; SERVE_GEOSITE="true" ;;
            3) SERVE_GEOIP="false"; SERVE_GEOSITE="false" ;;
            *) SERVE_GEOIP="true"; SERVE_GEOSITE="true" ;;
        esac
        echo -e "  ${GREEN}[+] Geo-базы: GeoIP=$SERVE_GEOIP, GeoSite=$SERVE_GEOSITE${NC}\n"
    else
        SERVE_GEOIP="false"
        SERVE_GEOSITE="false"
    fi

    return 0
}

wizard_public_connection() {
    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 3: Публичный домен и токен (если нужен домен)
    # ────────────────────────────────────────────────────────────────────────
    DOMAIN="${prev_domain:-local}"
    ROUTING_TOKEN="${prev_token:-local}"
    HTTP_PORT="${prev_port:-8080}"

    if [ "$NEEDS_PUBLIC_DOMAIN" = true ]; then
        ui_step "3" "Публичный домен для HTTPS"
        echo -e "  ${DIM}Имя хоста, по которому клиенты будут скачивать правила и базы.${NC}"
        echo -e "  ${DIM}💡 Подходит как отдельный субдомен (geo.example.com), так и${NC}"
        echo -e "  ${DIM}   СУЩЕСТВУЮЩИЙ домен с сайтом — трафик изолирован в пути /<TOKEN>/${NC}"
        read -r -p "  ▸ Домен [${prev_domain:-geo.example.com}]: " input_domain || return 130
        DOMAIN="${input_domain:-${prev_domain:-geo.example.com}}"
        DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]' | sed -e 's~^https\?://~~' -e 's~/*$~~')"
        echo -e "  ${GREEN}[+] Домен: ${BOLD}$DOMAIN${NC}\n"

        # ШАГ 4: Токен
        ui_step "4" "Секретный URL-токен авторизации"
        local auto_token
        if [ -n "$prev_token" ] && [ "$prev_token" != "local" ]; then
            auto_token="$prev_token"
            echo "  Текущий токен сохранится при Enter."
        else
            auto_token="$(openssl rand -hex 16)"
            echo "  Сгенерирован новый токен."
        fi
        
        read -r -s -p "  ▸ Секретный токен [Enter = сохранить]: " input_token || return 130
        ROUTING_TOKEN="${input_token:-$auto_token}"
        ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        while [[ ! "$ROUTING_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || [ "${#ROUTING_TOKEN}" -lt 8 ]; do
            echo -e "  ${RED}[!] Токен должен быть длиной не менее 8 символов (буквы, цифры, дефис, подчеркивание)${NC}"
            read -r -p "  ▸ Введите корректный токен [${auto_token}]: " input_token || return 130
            ROUTING_TOKEN="${input_token:-$auto_token}"
            ROUTING_TOKEN="$(echo "$ROUTING_TOKEN" | tr -d '[:space:]/\\')"
        done
        echo -e "  ${GREEN}[+] Токен сохранён.${NC}"

        # ШАГ 5: Локальный порт
        ui_step "5" "Локальный порт веб-сервера"
        echo -e "  ${DIM}Локальный порт для реверс-прокси (Nginx, Caddy, NPM) на 127.0.0.1${NC}"

        wizard_choose_port || return $?
    else
        HTTP_PORT="${prev_port:-8080}"
    fi
    return 0
}

wizard_remnawave() {
    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 6: Интеграция с Remnawave (если применима)
    # ────────────────────────────────────────────────────────────────────────
    REMNA_BLOCK=""
    if [ "$config_remna" = true ]; then
        ui_step "6" "Прямая интеграция с Remnawave API"

        local remna_proceed=true
        if [ "$server_role" != "1" ] && [ "$server_role" != "4" ]; then
            local remna_conf_idx
            remna_conf_idx=$(tui_select "Настроить отправку правил Happ в сквады Remnawave?" 0 "Да" "Нет") || return 130
            [ "$remna_conf_idx" -ne 0 ] && remna_proceed=false
        fi

        if [ "$remna_proceed" = true ]; then
            if detect_remnawave_running; then
                echo -e "  ${CYAN}[i] Обнаружен локальный контейнер Remnawave в Docker.${NC}"
            fi

            read -r -p "  ▸ URL API панели Remnawave [${prev_remna_base:-http://remnawave:3000/api}]: " r_base || return 130
            r_base="${r_base:-${prev_remna_base:-http://remnawave:3000/api}}"

            local r_token
            r_token=$(tui_secret "JWT токен администратора Remnawave" "$prev_remna_token") || return 130

            local existing_squads=0
            if [ -n "$scan_env" ] && [ -f "$scan_env" ]; then
                existing_squads=$(grep -c "^REMNAWAVE_SQUAD_.*_UUID=" "$scan_env" || true)
            fi
            local default_sq_count="${existing_squads:-1}"
            [ "$default_sq_count" -le 0 ] && default_sq_count=1
            read -r -p "  ▸ Сколько сквадов привязать? [${default_sq_count}]: " r_count || return 130
            r_count="${r_count:-$default_sq_count}"
            while [[ ! "$r_count" =~ ^[0-9]+$ ]] || [ "${#r_count}" -gt 3 ] || [ "$r_count" -gt 100 ]; do
                read -r -p "  ▸ Число сквадов от 0 до 100: " r_count || return 130
            done
            
            REMNA_BLOCK="REMNAWAVE_BASE_URL=${r_base}
REMNAWAVE_TOKEN=${r_token}
"
            echo -e "\n${CYAN}${BOLD}[i] Источник правил:${NC} ${CYAN}https://github.com/hydraponique/roscomvpn-routing${NC}"
            echo -e "${YELLOW}${BOLD}[!] ВНИМАНИЕ:${NC} ${YELLOW}В панели Remnawave используйте вкладку ${GREEN}${BOLD}«Внешние сквады»${NC}${YELLOW} (External Squads)!${NC}"
            echo -e "${YELLOW}    Не используйте «Внутренние сквады» — они не поддерживают маршрутизацию подписок Happ.${NC}"

            echo -e "${BLUE}[*] Загрузка списка внешних сквадов из Remnawave...${NC}"
            local ext_squads_raw
            ext_squads_raw=$(fetch_remnawave_external_squads "$r_base" "$r_token") || ext_squads_raw=""
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
                    prev_s_uuid=$(wizard_env_get "$scan_env" "REMNAWAVE_SQUAD_${i}_UUID" "")
                    prev_s_name=$(wizard_env_get "$scan_env" "REMNAWAVE_SQUAD_${i}_NAME" "")
                    prev_s_rule=$(wizard_env_get "$scan_env" "REMNAWAVE_SQUAD_${i}_RULE" "")
                fi
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
                read -r -p "  ▸ UUID внешнего сквада [${s_hint}]: " s_uuid || return 130
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
                    "JSONSUB.JSON") def_rule_idx=0 ;;
                    *) def_rule_idx=3 ;;
                esac

                local s_rule_pick
                s_rule_pick=$(tui_select "  Правило для сквада #$i:" "$def_rule_idx" \
                    "JSONSUB.JSON" \
                    "WHITELIST.JSON" \
                    "DEFAULT.JSON" \
                    "Свой файл из репозитория") || return 130

                local s_rule="JSONSUB.JSON"
                case "$s_rule_pick" in
                    1) s_rule="WHITELIST.JSON" ;;
                    2) s_rule="DEFAULT.JSON" ;;
                    3)
                        read -r -p "  Имя файла [например, CUSTOM.JSON]: " custom_s_rule || return 130
                        custom_s_rule="${custom_s_rule:-${prev_s_rule:-JSONSUB.JSON}}"
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
REMNAWAVE_SQUAD_${i}_NAME=\"${s_name}\"
REMNAWAVE_SQUAD_${i}_RULE=${s_rule}
"
            done

            local cf_def_idx=0
            [ -n "$prev_cf_id" ] && cf_def_idx=1
            local cf_choice_idx
            cf_choice_idx=$(tui_select "Remnawave защищена Cloudflare Zero Trust?" "$cf_def_idx" \
                "Нет (прямой доступ)" \
                "Да (Service Token)") || return 130

            if [ "$cf_choice_idx" -eq 1 ]; then
                local r_cf_id
                r_cf_id=$(tui_secret "CLOUDFLARE_ZERO_TRUST_CLIENT_ID" "$prev_cf_id") || return 130

                local r_cf_secret
                r_cf_secret=$(tui_secret "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET" "$prev_cf_secret") || return 130

                if [ -n "$r_cf_id" ] && [ -n "$r_cf_secret" ]; then
                    REMNA_BLOCK="${REMNA_BLOCK}CLOUDFLARE_ZERO_TRUST_CLIENT_ID=${r_cf_id}
CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=${r_cf_secret}
"
                fi
            fi

            echo -e "${GREEN}[+] Интеграция с Remnawave настроена.${NC}\n"
        fi
    fi

    return 0
}

wizard_network() {
    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 7: Docker-сеть (умный автодетект и сохранение)
    # ────────────────────────────────────────────────────────────────────────
    EXT_NETWORK="$prev_ext_network"
    NEEDS_NETWORK=true

    if [ -n "$REMNA_BLOCK" ]; then
        NEEDS_NETWORK=true
    fi

    if [ "$NEEDS_NETWORK" = true ]; then
        ui_step "7" "Подключение к Docker-сети"
        
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
        elif [ "$config_remna" = true ]; then
            net_options+=("remnawave-network (создать / подключить)")
        else
            net_options+=("Не подключать к внешней сети")
        fi

        # 2. Добавляем остальные обнаруженные сети
        for onet in "${other_nets[@]}"; do
            [ -n "$remna_found_net" ] && [ "$onet" = "$remna_found_net" ] && [ -z "$prev_ext_network" ] && continue
            net_options+=("$onet")
        done

        # 3. Варианты ручного ввода и пропуска
        net_options+=("Ввести другое имя сети" "Не подключать к внешней сети")

        local net_pick_idx
        net_pick_idx=$(tui_select "Docker-сеть для обратного прокси или Remnawave:" 0 "${net_options[@]}") || return 130
        local chosen_net="${net_options[$net_pick_idx]}"

        if [ "$chosen_net" = "Не подключать к внешней сети" ]; then
            echo -e "${DIM}Пропущено. Используется стандартная сеть.${NC}\n"
            EXT_NETWORK=""
        elif [ "$chosen_net" = "Ввести другое имя сети" ]; then
            read -r -p "Имя Docker-сети: " input_custom_net || return 130
            EXT_NETWORK="${input_custom_net:-remnawave-network}"
            echo -e "${GREEN}[+] Сеть: $EXT_NETWORK${NC}\n"
        else
            EXT_NETWORK="$(echo "$chosen_net" | awk '{print $1}')"
            echo -e "${GREEN}[+] Сеть: $EXT_NETWORK${NC}\n"
        fi
    fi

    return 0
}

wizard_schedule() {
    # ────────────────────────────────────────────────────────────────────────
    # ШАГ 8: Расписание обновления (Cron)
    # ────────────────────────────────────────────────────────────────────────
    ui_step "8" "Расписание автоматического обновления"
    local def_sched_idx=0
    case "${prev_schedule:-0 10 * * *}" in
        "0 */6 * * *") def_sched_idx=1 ;;
        "0 */12 * * *") def_sched_idx=2 ;;
        "0 10 * * *") def_sched_idx=0 ;;
        *) def_sched_idx=3 ;;
    esac

    local sched_idx
    sched_idx=$(tui_select "Как часто обновлять базы и правила?" "$def_sched_idx" \
        "Раз в сутки в 10:00 UTC / 13:00 МСК (по умолчанию)" \
        "Каждые 6 часов (4 раза в день)" \
        "Каждые 12 часов (2 раза в день)" \
        "Указать свое cron-расписание") || return 130

    SCHEDULE="0 10 * * *"
    case "$sched_idx" in
        1) SCHEDULE="0 */6 * * *" ;;
        2) SCHEDULE="0 */12 * * *" ;;
        3)
            read -r -p "  ▸ Введите cron-выражение [${prev_schedule:-0 10 * * *}]: " custom_sched || return 130
            SCHEDULE="${custom_sched:-${prev_schedule:-0 10 * * *}}"
            while ! validate_cron_schedule "$SCHEDULE"; do
                echo "[!] Неверное cron-выражение. Введите пять полей."
                read -r -p "  ▸ Расписание [$prev_schedule]: " custom_sched || return 130
                SCHEDULE="${custom_sched:-$prev_schedule}"
            done
            ;;
        *) SCHEDULE="0 10 * * *" ;;
    esac
    echo -e "  ${GREEN}[+] Расписание: ${BOLD}$SCHEDULE${NC}\n"

    # ────────────────────────────────────────────────────────────────────────
    return 0
}

wizard_telegram() {
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
            "Отключить Telegram-уведомления") || return 130

        case "$tg_opt_idx" in
            0)
                TG_BOT_TOKEN="$prev_tg_token"
                TG_CHAT_ID="$prev_tg_chat"
                TG_THREAD_ID="$prev_tg_thread"
                TG_NOTIFY_SUCCESS="${prev_tg_notify:-false}"
                echo -e "  ${GREEN}[+] Сохранены текущие настройки Telegram (Chat ID: ${tg_chat_hint}).${NC}\n"
                ;;
            1)
                TG_BOT_TOKEN=$(tui_secret "TELEGRAM_BOT_TOKEN" "$prev_tg_token") || return 130
                
                read -r -p "  ▸ TELEGRAM_CHAT_ID [${prev_tg_chat:-пропустить}]: " input_chat || return 130
                TG_CHAT_ID="${input_chat:-$prev_tg_chat}"

                read -r -p "  ▸ TELEGRAM_THREAD_ID (ID темы) [${prev_tg_thread:-нет}]: " input_thread || return 130
                TG_THREAD_ID="${input_thread:-$prev_tg_thread}"

                local tg_succ_idx
                local def_succ=0
                [ "${prev_tg_notify:-false}" = "true" ] && def_succ=1
                tg_succ_idx=$(tui_select "Присылать уведомление при успешном выходе новых баз?" "$def_succ" \
                    "Нет (только критические ошибки)" \
                    "Да (отчёт о каждом обновлении)") || return 130
                [ "$tg_succ_idx" -eq 1 ] && TG_NOTIFY_SUCCESS="true" || TG_NOTIFY_SUCCESS="false"

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
            "Настроить Telegram бота") || return 130

        if [ "$tg_opt_idx" -eq 1 ]; then
            TG_BOT_TOKEN=$(tui_secret "TELEGRAM_BOT_TOKEN" "") || return 130
            
            read -r -p "  ▸ TELEGRAM_CHAT_ID [пропустить]: " input_chat || return 130
            TG_CHAT_ID="${input_chat:-}"

            read -r -p "  ▸ TELEGRAM_THREAD_ID (ID темы) [нет]: " input_thread || return 130
            TG_THREAD_ID="${input_thread:-}"

            local tg_succ_idx
            tg_succ_idx=$(tui_select "Присылать уведомление при успешном выходе новых баз?" 0 \
                "Нет (только критические ошибки)" \
                "Да (отчёт о каждом обновлении)") || return 130
            [ "$tg_succ_idx" -eq 1 ] && TG_NOTIFY_SUCCESS="true" || TG_NOTIFY_SUCCESS="false"

            echo -e "  ${GREEN}[+] Telegram настроен.${NC}\n"
        else
            echo -e "  ${DIM}Уведомления Telegram отключены.${NC}\n"
        fi
    fi

    return 0
}

install_wizard() {
    local wizard_section="${1:-full}"
    print_header
    check_root
    check_dependencies
    local existing_detected
    existing_detected="$(detect_existing_dir)"
    local current_suggested_dir="${existing_detected:-/opt/geo-routing-server}"

    if [ "$wizard_section" = full ]; then
        ui_step "1" "Каталог установки"
        read -r -p "  ▸ Каталог [$current_suggested_dir]: " input_dir || return 130
        INSTALL_DIR="${input_dir:-$current_suggested_dir}"
    else
        INSTALL_DIR="$(get_install_dir)"
    fi
    if ! INSTALL_DIR="$(canonicalize_install_dir "$INSTALL_DIR")" || is_protected_install_dir "$INSTALL_DIR"; then
        echo "[!] Укажите абсолютный отдельный каталог установки."
        return 1
    fi
    if [ -e "$INSTALL_DIR" ] && { [ ! -d "$INSTALL_DIR" ] || ! has_project_marker "$INSTALL_DIR"; }; then
        echo "[!] Каталог не принадлежит geo-routing-server."
        return 1
    fi

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
    local prev_rules="JSONSUB,WHITELIST"
    local prev_formats="CLIENT_OPTIMIZED"
    local prev_serve_geoip="true"
    local prev_serve_geosite="true"

    local scan_env=""
    if [ -f "$INSTALL_DIR/.env" ]; then
        scan_env="$INSTALL_DIR/.env"

    fi

    if [ -n "$scan_env" ]; then
        echo -e "${CYAN}[i] Загружены текущие настройки ($scan_env)${NC}\n"
        prev_domain="$(wizard_env_get "$scan_env" DOMAIN "$prev_domain")"
        prev_token="$(wizard_env_get "$scan_env" ROUTING_TOKEN "$prev_token")"
        prev_clients="$(wizard_env_get "$scan_env" ENABLED_CLIENTS "$prev_clients")"
        prev_rules="$(wizard_env_get "$scan_env" ROUTING_RULES "$prev_rules")"
        prev_formats="$(wizard_env_get "$scan_env" SERVE_FORMATS "$prev_formats")"
        prev_serve_geoip="$(wizard_env_get "$scan_env" SERVE_GEOIP "$prev_serve_geoip")"
        prev_serve_geosite="$(wizard_env_get "$scan_env" SERVE_GEOSITE "$prev_serve_geosite")"
        prev_port="$(wizard_env_get "$scan_env" HTTP_PORT "$prev_port")"
        prev_remna_base="$(wizard_env_get "$scan_env" REMNAWAVE_BASE_URL "$prev_remna_base")"
        prev_remna_token="$(wizard_env_get "$scan_env" REMNAWAVE_TOKEN "$prev_remna_token")"
        prev_tg_token="$(wizard_env_get "$scan_env" TELEGRAM_BOT_TOKEN "$prev_tg_token")"
        prev_tg_chat="$(wizard_env_get "$scan_env" TELEGRAM_CHAT_ID "$prev_tg_chat")"
        prev_tg_thread="$(wizard_env_get "$scan_env" TELEGRAM_THREAD_ID "$prev_tg_thread")"
        prev_tg_notify="$(wizard_env_get "$scan_env" TELEGRAM_NOTIFY_SUCCESS "$prev_tg_notify")"
        prev_public_geo="$(wizard_env_get "$scan_env" PUBLIC_GEO_BASE_URL "$prev_public_geo")"
        prev_cf_id="$(wizard_env_get "$scan_env" CLOUDFLARE_ZERO_TRUST_CLIENT_ID "")"
        prev_cf_secret="$(wizard_env_get "$scan_env" CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET "")"
        prev_routing_repo="$(wizard_env_get "$scan_env" ROUTING_SOURCE_REPO "$prev_routing_repo")"
        prev_schedule="$(wizard_env_get "$scan_env" SCHEDULE "$prev_schedule")"
        prev_ext_network="$(wizard_env_get "$scan_env" DOCKER_NETWORK "$(wizard_env_get "$scan_env" EXT_NETWORK "")")"
    fi

    # Если в .env сеть не сохранена, проверяем существующий compose.yaml
    local comp_scan=""
    if [ -f "$INSTALL_DIR/compose.yaml" ]; then
        comp_scan="$INSTALL_DIR/compose.yaml"
    elif [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
        comp_scan="$INSTALL_DIR/docker-compose.yml"
    fi

    if [ -z "$prev_ext_network" ] && [ -n "$comp_scan" ]; then
        local comp_net
        comp_net=$(awk '
            /^[[:space:]]*name:[[:space:]]*/ { n=$0; sub(/^[[:space:]]*name:[[:space:]]*/, "", n); gsub(/["'\'' ]/, "", n); last_name=n }
            /^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$/ { s=$0; gsub(/^[[:space:]]*|:[[:space:]]*$/, "", s); last_sec=s }
            /external:[[:space:]]*true/ {
                if (last_name != "") { print last_name; exit }
                if (last_sec != "" && last_sec != "default") { print last_sec; exit }
            }
        ' "$comp_scan" 2>/dev/null || true)
        if [ -z "$comp_net" ]; then
            comp_net=$(awk '
                /^[[:space:]]*-[[:space:]]+default/ { next }
                /^[[:space:]]*-[[:space:]]+[a-zA-Z0-9_-]+/ {
                    val=$0; sub(/^[[:space:]]*-[[:space:]]+/, "", val); gsub(/["'\'' ]/, "", val)
                    if (val != "" && val != "default") { print val; exit }
                }
            ' "$comp_scan" 2>/dev/null || true)
        fi
        [ -n "$comp_net" ] && [ "$comp_net" != "default" ] && prev_ext_network="$comp_net"
    fi

    # Автоисправление, если из-за бага парсера старой версии скрипта в .env попало "name<сеть>"
    if [[ "$prev_ext_network" =~ ^name([a-zA-Z0-9_-]+)$ ]]; then
        local fixed_candidate="${BASH_REMATCH[1]}"
        if command -v docker &>/dev/null && docker network inspect "$fixed_candidate" &>/dev/null; then
            prev_ext_network="$fixed_candidate"
        fi
    fi
    # A mount such as "routing_data:/app/www" is a volume, never a Docker network.
    if [ -n "$prev_ext_network" ] && [[ ! "$prev_ext_network" =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
        prev_ext_network=""
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


    local DOMAIN="$prev_domain" ROUTING_TOKEN="$prev_token" ENABLED_CLIENTS="$prev_clients"
    local HTTP_PORT="$prev_port" SCHEDULE="$prev_schedule" EXT_NETWORK="$prev_ext_network"
    local HTTP_BIND SYNC_ON_START GEOIP_SOURCE_URL GEOSITE_SOURCE_URL
    HTTP_BIND="$(wizard_env_get "$scan_env" HTTP_BIND 127.0.0.1)"
    SYNC_ON_START="$(wizard_env_get "$scan_env" SYNC_ON_START true)"
    GEOIP_SOURCE_URL="$(wizard_env_get "$scan_env" GEOIP_SOURCE_URL '')"
    GEOSITE_SOURCE_URL="$(wizard_env_get "$scan_env" GEOSITE_SOURCE_URL '')"
    local ROUTING_RULES="$prev_rules" SERVE_FORMATS="$prev_formats"
    local SERVE_GEOIP="$prev_serve_geoip" SERVE_GEOSITE="$prev_serve_geosite"
    local PUBLIC_GEO_BASE_URL="$prev_public_geo" ROUTING_SOURCE_REPO="$prev_routing_repo"
    local TELEGRAM_BOT_TOKEN="$prev_tg_token" TELEGRAM_CHAT_ID="$prev_tg_chat"
    local TELEGRAM_THREAD_ID="$prev_tg_thread" TELEGRAM_NOTIFY_SUCCESS="$prev_tg_notify"
    local TG_BOT_TOKEN="$prev_tg_token" TG_CHAT_ID="$prev_tg_chat" TG_THREAD_ID="$prev_tg_thread" TG_NOTIFY_SUCCESS="$prev_tg_notify"
    local DOCKER_NETWORK="$prev_ext_network" REMNA_BLOCK="" config_remna=false server_role=1 NEEDS_PUBLIC_DOMAIN=true NEEDS_NETWORK=false
    [ "$ENABLED_CLIENTS" != HAPP_DEEPLINK ] || NEEDS_PUBLIC_DOMAIN=false
    local wizard_change_remna=false
    local -a wizard_keys=()
    if [ "$wizard_section" != full ] && [ -z "$scan_env" ]; then echo "[!] Сначала выполните установку."; return 1; fi
    case "$wizard_section" in
        full)
            wizard_choose_mode || return $?
            wizard_public_connection || return $?
            if [ "$config_remna" = true ]; then
                wizard_remnawave || return $?
                wizard_network || return $?
            else
                EXT_NETWORK=""
            fi
            wizard_schedule || return $?
            wizard_telegram || return $?
            wizard_change_remna=true
            local advanced_choice
            advanced_choice=$(tui_select "Основные настройки собраны:" 0 "Перейти к проверке и применению" "Дополнительные настройки") || return 130
            [ "$advanced_choice" != 1 ] || wizard_advanced || return $?
            wizard_keys=(DOMAIN ROUTING_TOKEN ENABLED_CLIENTS ROUTING_RULES SERVE_FORMATS SERVE_GEOIP SERVE_GEOSITE PUBLIC_GEO_BASE_URL ROUTING_SOURCE_REPO HTTP_BIND HTTP_PORT SCHEDULE SYNC_ON_START TELEGRAM_BOT_TOKEN TELEGRAM_CHAT_ID TELEGRAM_THREAD_ID TELEGRAM_NOTIFY_SUCCESS DOCKER_NETWORK GEOIP_SOURCE_URL GEOSITE_SOURCE_URL)
            ;;
        files)
            wizard_choose_mode || return $?
            if [ "$NEEDS_PUBLIC_DOMAIN" = true ] && { [ "$DOMAIN" = local ] || [ -z "$ROUTING_TOKEN" ]; }; then
                wizard_public_connection || return $?
                wizard_keys+=(DOMAIN ROUTING_TOKEN HTTP_PORT)
            fi
            wizard_remnawave || return $?
            if [ "$config_remna" = true ]; then
                wizard_network || return $?
                wizard_keys+=(DOCKER_NETWORK)
            fi
            wizard_change_remna=true
            wizard_keys+=(ENABLED_CLIENTS ROUTING_RULES SERVE_GEOIP SERVE_GEOSITE PUBLIC_GEO_BASE_URL)
            ;;
        network)
            wizard_public_connection || return $?
            wizard_network || return $?
            wizard_keys=(DOMAIN ROUTING_TOKEN HTTP_PORT DOCKER_NETWORK)
            ;;
        schedule)
            wizard_schedule || return $?
            wizard_keys=(SCHEDULE)
            ;;
        advanced)
            WIZARD_ADVANCED_CANCELLED=false
            wizard_advanced || return $?
            [ "$WIZARD_ADVANCED_CANCELLED" = true ] && return 0
            wizard_keys=(HTTP_BIND SYNC_ON_START SERVE_FORMATS ROUTING_SOURCE_REPO GEOIP_SOURCE_URL GEOSITE_SOURCE_URL PUBLIC_GEO_BASE_URL)
            ;;
        *) echo "[!] Неизвестный раздел: $wizard_section"; return 1 ;;
    esac
    TELEGRAM_BOT_TOKEN="$TG_BOT_TOKEN" TELEGRAM_CHAT_ID="$TG_CHAT_ID"
    TELEGRAM_THREAD_ID="$TG_THREAD_ID" TELEGRAM_NOTIFY_SUCCESS="$TG_NOTIFY_SUCCESS"
    DOCKER_NETWORK="$EXT_NETWORK"
    wizard_apply
}

# ==============================================================================
# ПОДМЕНЮ НАСТРОЕК, УПРАВЛЕНИЯ И СИСТЕМЫ
# ==============================================================================

configure_settings_menu() {
    install_wizard
}

configure_integrations_menu() {
    while true; do
        print_header
        local choice
        if [ "${UI_LANG:-ru}" = "en" ]; then
            choice=$(tui_select "Integration Settings:" 0 \
                "Configure Remnawave API sync" \
                "Configure / Change Telegram notifications" \
                "Send Telegram test message" \
                "Back to main menu") || return 0
        else
            choice=$(tui_select "Настройки интеграций:" 0 \
                "Настроить прямую синхронизацию с Remnawave" \
                "Настроить / Изменить Telegram-уведомления" \
                "Отправить тестовое уведомление в Telegram" \
                "Назад в главное меню") || return 0
        fi
        case "$choice" in
            0) configure_remnawave ;;
            1) configure_telegram ;;
            2) send_telegram_test_action ;;
            *) return 0 ;;
        esac
    done
}

manage_container_menu() {
    while true; do
        print_header
        local choice
        if [ "${UI_LANG:-ru}" = "en" ]; then
            choice=$(tui_select "Container Management:" 0 \
                "Start / restart container" \
                "Stop container" \
                "Back to main menu") || return 0
        else
            choice=$(tui_select "Управление контейнером:" 0 \
                "Запустить / перезапустить контейнер" \
                "Остановить контейнер" \
                "Назад в главное меню") || return 0
        fi
        case "$choice" in
            0) restart_server; return 0 ;;
            1) stop_server; return 0 ;;
            *) return 0 ;;
        esac
    done
}

update_server_menu() {
    while true; do
        print_header
        local img_status script_status
        img_status=$(component_status_label "${IMAGE_CHECK_STATUS:-unchecked}")
        script_status=$(component_status_label "${SCRIPT_CHECK_STATUS:-unchecked}")
        local choice
        if [ "${UI_LANG:-ru}" = "en" ]; then
            choice=$(tui_select "Server Component Updates:" 0 \
                "Update everything (Docker image & script)" \
                "Update Docker image ($img_status)" \
                "Update management script ($script_status)" \
                "Back to main menu") || return 0
        else
            choice=$(tui_select "Обновление компонентов сервера:" 0 \
                "Обновить всё сразу (Docker-образ и скрипт)" \
                "Обновить только Docker-образ ($img_status)" \
                "Обновить только скрипт управления ($script_status)" \
                "Назад в главное меню") || return 0
        fi
        case "$choice" in
            0)
                update_project all
                return 0
                ;;
            1)
                update_project image
                return 0
                ;;
            2)
                update_script_only
                return 0
                ;;
            *) return 0 ;;
        esac
    done
}

system_advanced_menu() {
    while true; do
        print_header
        local choice
        if [ "${UI_LANG:-ru}" = "en" ]; then
            choice=$(tui_select "Advanced System Options:" 0 \
                "Change language / Сменить язык (RU/EN)" \
                "Show installation directory and system info" \
                "Completely remove geo-routing-server" \
                "Back to main menu") || return 0
        else
            choice=$(tui_select "Дополнительные опции:" 0 \
                "Сменить язык / Change language (RU/EN)" \
                "Показать каталог установки и системную информацию" \
                "Полностью удалить geo-routing-server" \
                "Назад в главное меню") || return 0
        fi
        case "$choice" in
            0)
                if [ "${UI_LANG:-ru}" = "ru" ]; then
                    UI_LANG="en"
                else
                    UI_LANG="ru"
                fi
                echo "$UI_LANG" > "$LANG_RECORD" 2>/dev/null || true
                echo -e "${GREEN}[+] Language / Язык: $UI_LANG${NC}"
                sleep 1
                ;;
            1)
                local target_dir
                target_dir="$(get_install_dir)"
                echo -e "\n  ${CYAN}[i] Каталог установки: ${BOLD}$target_dir${NC}"
                echo -e "  ${CYAN}[i] Команда вызова:    ${BOLD}/usr/local/bin/geoserver${NC}"
                echo -e "  ${CYAN}[i] Версия скрипта:    ${BOLD}v$SCRIPT_VERSION${NC}\n"
                pause_menu
                ;;
            2)
                uninstall_project
                return 0
                ;;
            *) return 0 ;;
        esac
    done
}

# ==============================================================================
# ГЛАВНОЕ МЕНЮ
# ==============================================================================

main_menu() {
    check_script_version 2>/dev/null || true
    check_docker_image_version 2>/dev/null || true
    while true; do
        print_header
        local target_dir
        target_dir="$(get_install_dir)"
        
        local status_msg=""
        local sync_msg=""
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^geo-routing-server$"; then
            status_msg="${GREEN}[+] Работает${NC}"
            local sync_status
            sync_status=$(docker exec geo-routing-server sh -c 'cat "/app/www/${ROUTING_TOKEN:-local}/.sync-status.json"' 2>/dev/null || true)
            case "$sync_status" in
                *'"state":"success"'*) sync_msg="${GREEN}[+] Успешна${NC}" ;;
                *'"state":"failed"'*) sync_msg="${RED}[-] Ошибка${NC}" ;;
                *'"state":"running"'*) sync_msg="${YELLOW}[~] Выполняется${NC}" ;;
                *) sync_msg="${YELLOW}[~] Нет данных${NC}" ;;
            esac
        else
            status_msg="${RED}[-] Остановлен${NC}"
            sync_msg="${DIM}—${NC}"
        fi

        if [ "${UI_LANG:-ru}" = en ]; then
            status_msg="${status_msg/Работает/Running}"
            status_msg="${status_msg/Остановлен/Stopped}"
            sync_msg="${sync_msg/Успешна/Successful}"
            sync_msg="${sync_msg/Ошибка/Failed}"
            sync_msg="${sync_msg/Выполняется/Running}"
            sync_msg="${sync_msg/Нет данных/No data}"
        fi

        local env_file="$target_dir/.env"
        local modules_ru="—"
        local modules_en="—"
        local integrations_ru=""
        local integrations_en=""
        local rules_val="" formats_val=""
        local domain_val=""
        local token_val=""
        local is_local=0

        if [ -f "$env_file" ]; then
            local clients
            clients=$(grep "^ENABLED_CLIENTS=" "$env_file" | cut -d'=' -f2- || echo "")
            local ext_geo
            ext_geo=$(grep "^PUBLIC_GEO_BASE_URL=" "$env_file" | cut -d'=' -f2- || echo "")
            domain_val=$(grep "^DOMAIN=" "$env_file" | cut -d'=' -f2- || echo "")
            token_val=$(grep "^ROUTING_TOKEN=" "$env_file" | cut -d'=' -f2- || echo "")

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
                    modules_ru="Incy (Autorouting, внешние базы)"
                    modules_en="Incy (Autorouting, external geo)"
                else
                    modules_ru="Incy (Autorouting) + Раздача Geo-баз"
                    modules_en="Incy (Autorouting) + Geo-databases"
                fi
            elif [[ "$clients" =~ HAPP ]] && [[ "$clients" =~ INCY ]]; then
                if [ -n "$ext_geo" ]; then
                    modules_ru="Happ + Incy (внешние базы)"
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

            rules_val=$(grep "^ROUTING_RULES=" "$env_file" | cut -d'=' -f2- || echo "")
            formats_val=$(grep "^SERVE_FORMATS=" "$env_file" | cut -d'=' -f2- || echo "")
        fi

        local full_mod_ru="$modules_ru"
        local full_mod_en="$modules_en"
        if [ -n "$rules_val" ]; then
            full_mod_ru="${modules_ru} (${YELLOW}правила: ${rules_val}${NC})"
            full_mod_en="${modules_en} (${YELLOW}rules: ${rules_val}${NC})"
        fi

        local upd_label_ru="Обновить сервис (образ и скрипт)"
        local upd_label_en="Update service (image & script)"
        if [ "$IMAGE_UPDATE_AVAILABLE" = true ] || [ "$UPDATE_AVAILABLE" = true ]; then
            upd_label_ru="Обновить сервис (образ и скрипт) [доступно обновление!]"
            upd_label_en="Update service (image & script) [update available!]"
        fi

        if [ "${UI_LANG:-ru}" = "en" ]; then
            echo -e "  Status: $status_msg • Sync: $sync_msg"
            echo -e "  Modules: ${GREEN}$full_mod_en${NC}"
            if [ "$is_local" -eq 0 ] && [ -n "$domain_val" ] && [ "$domain_val" != "geo.example.com" ]; then
                if [ -n "$token_val" ] && [ "$token_val" != "local" ]; then
                    echo -e "  Base URL: ${CYAN}https://${domain_val}/${token_val}${NC}"
                else
                    echo -e "  Public domain: ${CYAN}$domain_val${NC}"
                fi
            fi
            if [ -n "$integrations_en" ]; then
                echo -e "  Integrations: ${YELLOW}$integrations_en${NC}"
            fi
            echo ""

            local en_options=(
                "Status and public links"
                "Synchronize now"
                "Guided setup / reconfigure server"
                "Integrations: Remnawave and Telegram"
                "Reverse-proxy configs (Caddy / Nginx / NPM)"
                "$upd_label_en"
                "View container logs"
                "Container management (start / restart / stop)"
                "Language and advanced actions"
                "Exit"
            )

            local menu_idx
            menu_idx=$(tui_select "Choose an action:" 0 "${en_options[@]}") || return 0
        else
            echo -e "  Статус: $status_msg • Синхронизация: $sync_msg"
            echo -e "  Модули: ${GREEN}$full_mod_ru${NC}"
            if [ "$is_local" -eq 0 ] && [ -n "$domain_val" ] && [ "$domain_val" != "geo.example.com" ]; then
                if [ -n "$token_val" ] && [ "$token_val" != "local" ]; then
                    echo -e "  Базовый URL: ${CYAN}https://${domain_val}/${token_val}${NC}"
                else
                    echo -e "  Публичный домен: ${CYAN}$domain_val${NC}"
                fi
            fi
            if [ -n "$integrations_ru" ]; then
                echo -e "  Интеграции: ${YELLOW}$integrations_ru${NC}"
            fi
            echo ""

            local ru_options=(
                "Статус и ссылки"
                "Синхронизировать сейчас"
                "Пошаговая настройка / перенастройка сервера"
                "Интеграции: Remnawave и Telegram"
                "Конфиги обратного прокси (Caddy / Nginx / NPM)"
                "$upd_label_ru"
                "Посмотреть логи контейнера"
                "Управление контейнером (запуск / перезапуск / стоп)"
                "Язык и дополнительные действия"
                "Выход"
            )

            local menu_idx
            menu_idx=$(tui_select "Выберите действие:" 0 "${ru_options[@]}") || return 0
        fi

        case "$menu_idx" in
            0) show_links ;;
            1) run_sync_now ;;
            2) install_wizard ;;
            3) configure_integrations_menu ;;
            4) show_proxy_snippets true ;;
            5) update_server_menu ;;
            6) view_logs ;;
            7) manage_container_menu ;;
            8) system_advanced_menu ;;
            9) return 0 ;;
            *) return 0 ;;
        esac
    done
}

cli_container_action() {
    local action="$1" target_dir
    target_dir="$(get_install_dir)"
    case "$action" in
        status) (cd "$target_dir" && docker compose ps --all) ;;
        stop) (cd "$target_dir" && docker compose stop) ;;
        start)
            (cd "$target_dir" && docker compose up -d) || return 1
            wait_for_container_health || return 1
            ;;
        restart)
            (cd "$target_dir" && docker compose restart) || return 1
            wait_for_container_health || return 1
            ;;
    esac
}

main() {
    local command="" argument
    local -a language_args=()
    for argument in "$@"; do
        case "$argument" in
            --lang=en|--lang=ru|--en|--ru) language_args+=("$argument") ;;
            *)
                if [ -n "$command" ]; then
                    printf 'Unexpected argument: %s\n' "$argument" >&2
                    return 2
                fi
                command="$argument"
                ;;
        esac
    done
    case "$command" in
        --help|-h|help)
            cat <<'HELP'
Usage: geoserver [command] [--lang=ru|--lang=en]
  menu          Open management menu (default for an existing installation)
  install       Install or reconfigure interactively
  status        Show container state, including stopped containers
  start         Start with the current Compose configuration
  restart       Restart the container
  stop          Stop without removing containers or data
  logs          Follow container logs (Ctrl+C to exit)
  sync          Run synchronization now
  update        Update script and image; keep a stopped container stopped
  update-image  Update only the image configured in Compose
  update-script Update only the management script
  uninstall     Confirm removal interactively
HELP
            return 0
            ;;
        status|start|restart|stop|update|update-image|update-script|logs|--logs|-l|sync|--sync|-s)
            NONINTERACTIVE=true
            UI_LANG=ru
            if [ -f "$LANG_RECORD" ]; then UI_LANG=$(tr -d '[:space:]' < "$LANG_RECORD"); fi
            for argument in "${language_args[@]}"; do
                case "$argument" in --lang=en|--en) UI_LANG=en ;; *) UI_LANG=ru ;; esac
            done
            case "$command" in
                status|start|restart|stop) cli_container_action "$command" ;;
                update) update_project all ;;
                update-image) update_project image ;;
                update-script) update_script_only ;;
                logs|--logs|-l) view_logs ;;
                sync|--sync|-s) run_sync_now ;;
            esac
            return $?
            ;;
        ''|menu|--menu|-m|install|reconfigure|--reconfigure|-r|uninstall|--uninstall|-u) ;;
        *) printf 'Unknown command: %s. Run geoserver help.\n' "$command" >&2; return 2 ;;
    esac
    detect_or_ask_language "${language_args[@]}"
    case "$command" in
        --uninstall|-u|uninstall) uninstall_project; return $? ;;
        --reconfigure|-r|reconfigure|install) install_wizard; main_menu; return $? ;;
        --menu|-m|menu) main_menu; return $? ;;
    esac

    local target_dir
    target_dir="$(get_install_dir)"
    
    # 1. Если compose-файл существует — это готовая рабочая установка
    if [ -d "$target_dir" ] && { [ -f "$target_dir/compose.yaml" ] || [ -f "$target_dir/docker-compose.yml" ]; }; then
        if ! ensure_cli_shortcut "$target_dir"; then
            echo -e "${YELLOW}[!] Не удалось создать команду geoserver. Запустите скрипт через root/sudo.${NC}"
        fi
        main_menu
    # 2. Если каталога нет, либо в нем нет файла .env с токеном — это чистая установка!
    elif [ ! -d "$target_dir" ] || [ ! -f "$target_dir/.env" ] || ! grep -q '^ROUTING_TOKEN=' "$target_dir/.env" 2>/dev/null; then
        install_wizard
        main_menu
    # 3. Иначе: каталог есть, в нем есть .env c токеном, но нет compose-файла -> действительно незавершенная установка
    else
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
                if ! reset_install_dir "$target_dir"; then
                    echo -e "${RED}[!] Каталог не подтверждён как установка geo-routing-server; очистка отменена.${NC}"
                    return 1
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
    fi
}

if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
    main "$@"
fi
