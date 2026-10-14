#!/usr/bin/env bash
# ==============================================================================
# Geo Routing Server — установка и управление на хосте
# GitHub: https://github.com/xdeptu5/geo-routing-server
#
# Скрипт делает только то, что возможно лишь на хосте: выбор каталога,
# установку команды geoserver, запуск/остановку/обновление/удаление контейнера.
# Мастер установки и все настройки .env выполняет CLI внутри образа
# (python -m app.cli setup / config ...) в разовом контейнере, куда каталог
# установки монтируется в /host. Так правила проверки и меню существуют в
# одном экземпляре и покрыты тестами.
#
# Контракт с CLI: код возврата 100 у `config ...` означает «изменения
# сохранены» — скрипт применяет их (`docker compose up -d`) и открывает
# раздел снова.
# ==============================================================================

set -euo pipefail

SCRIPT_VERSION="1.7.3"
CONFIG_RECORD="/etc/geo-routing-server.conf"
DEFAULT_INSTALL_DIR="/opt/geo-routing-server"
IMAGE_REPO="ghcr.io/xdeptu5/geo-routing-server"
DOCKER_IMAGE="${IMAGE_REPO}:latest"
INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh"
SERVICE="geo-routing-server"
# Минимальная версия контракта CLI в образе, которая нужна этому скрипту
REQUIRED_CLI_API=2
APPLY_RC=100
# 1 — install.sh на диске новее кода этой сессии (см. reopen_if_script_replaced)
SCRIPT_REPLACED=0
# Служебные строки Compose про разовый контейнер и предупреждение о томе без меток
# (в обоих форматах: `WARN[0000] ...` в терминале и `level=warning msg=...` без него)
COMPOSE_NOISE_RE='^(.*volume .* already exists but was not created by Docker Compose.*|[[:space:]]*Container [^[:space:]]+-run-[0-9a-f]+[[:space:]]+(Creating|Created|Starting|Started|Stopping|Stopped|Removing|Removed)[[:space:]]*$)'

# Переопределения для тестов и разработки: локальный образ и пропуск pull
IMAGE="${GRS_IMAGE:-$DOCKER_IMAGE}"

C_RESET="\033[0m"
C_BOLD="\033[1m"
C_WHITE="\033[1;37m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_YELLOW="\033[1;33m"
C_CYAN="\033[1;36m"
C_GRAY="\033[38;5;244m"
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

pause() {
    echo ""
    read -r -p "Нажмите Enter для возврата в меню..." _ || true
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}[!] Для выполнения этой команды требуются права root.${C_RESET}"
        echo -e "    Пожалуйста, запустите: ${C_BOLD}sudo geoserver${C_RESET} или ${C_BOLD}sudo bash install.sh${C_RESET}"
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

is_container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$SERVICE" 2>/dev/null || true)" = "true" ]
}

check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v docker >/dev/null 2>&1 || missing+=("docker")
    if [ -z "$(detect_compose)" ]; then
        missing+=("docker-compose-plugin")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${C_RED}[!] Не найдены обязательные компоненты: ${missing[*]}${C_RESET}"
        echo -e "${C_YELLOW}Установите Docker и Docker Compose перед продолжением.${C_RESET}"
        exit 1
    fi
    # Наличие бинаря docker не означает, что демон запущен
    if ! docker info >/dev/null 2>&1; then
        echo -e "${C_RED}[!] Docker установлен, но демон недоступен (docker info завершился с ошибкой).${C_RESET}"
        echo -e "${C_YELLOW}Запустите демон (systemctl start docker) либо добавьте пользователя в группу docker: sudo usermod -aG docker \$USER${C_RESET}"
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Каталог установки
# ------------------------------------------------------------------------------

# Абсолютный нормализованный путь (как `realpath -m`: компоненты могут не
# существовать). У BusyBox (Alpine) `realpath` не знает -m: печатает путь,
# но завершается ошибкой, и запасная ветка `|| echo` раньше дописывала путь
# второй раз — каталог становился двумя строками и проходил мимо проверки
# защищённых каталогов. Поэтому без GNU realpath путь разбирается здесь.
abs_path() {
    local p="${1:-}"
    [ -n "$p" ] || return 0
    [[ "$p" == /* ]] || p="$(pwd)/$p"
    if realpath -m / >/dev/null 2>&1; then
        realpath -m -- "$p"
        return
    fi
    local -a parts=() out=()
    local part
    IFS=/ read -ra parts <<< "$p"
    for part in "${parts[@]}"; do
        case "$part" in
            ""|.) ;;
            ..) [ ${#out[@]} -gt 0 ] && unset 'out[${#out[@]}-1]' ;;
            *) out+=("$part") ;;
        esac
    done
    local joined
    joined="$(IFS=/; printf '%s' "${out[*]}")"
    printf '/%s\n' "$joined"
}

# Защищённые системные каталоги: запрет установки и удаления
is_protected_dir() {
    local p="${1:-}"
    [ -n "$p" ] || return 0
    local real
    real="$(abs_path "$p")"
    [ -n "$real" ] || real="$p"
    [ "$real" != "/" ] && real="${real%/}"

    case "$real" in
        ""|"/"|"/root"|"/opt"|"/etc"|"/usr"|"/bin"|"/sbin"|"/lib"|"/lib64"|"/var"|"/tmp"|"/dev"|"/proc"|"/sys"|"/run"|"/home")
            return 0
            ;;
    esac

    if [ -n "${HOME:-}" ]; then
        local real_home
        real_home="$(abs_path "$HOME")"
        [ -n "$real_home" ] && real_home="${real_home%/}"
        if [ "$real" = "$real_home" ]; then
            return 0
        fi
    fi
    return 1
}

# Каталог принадлежит проекту: рядом лежит compose.yaml с нашим сервисом
has_our_compose() {
    local dir="$1"
    [ -n "$dir" ] && [ -d "$dir" ] || return 1
    local compose_file=""
    if [ -f "$dir/compose.yaml" ]; then
        compose_file="$dir/compose.yaml"
    elif [ -f "$dir/docker-compose.yml" ]; then
        compose_file="$dir/docker-compose.yml"
    else
        return 1
    fi
    grep -q "geo-routing-server" "$compose_file" 2>/dev/null
}

# Полный маркер установки (нужен перед удалением): наш compose и .env с нашими ключами
is_project_dir() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    ! is_protected_dir "$dir" || return 1
    has_our_compose "$dir" || return 1
    [ -f "$dir/.env" ] || return 1
    grep -qE '^(GEO_ROUTING_|ROUTING_SOURCE_|ROUTING_TOKEN=|ENABLED_CLIENTS=)' "$dir/.env" 2>/dev/null
}

get_install_dir() {
    if [ -f "$CONFIG_RECORD" ]; then
        local saved_dir
        # Убираем только \r: путь может содержать пробелы
        saved_dir="$(head -n 1 "$CONFIG_RECORD" 2>/dev/null | tr -d '\r')"
        if [ -n "$saved_dir" ] && [ -d "$saved_dir" ] && ! is_protected_dir "$saved_dir"; then
            echo "$saved_dir"
            return 0
        fi
    fi
    local cwd
    cwd="$(pwd)"
    if has_our_compose "$cwd" && ! is_protected_dir "$cwd"; then
        echo "$cwd"
        return 0
    fi
    if [ -d "/opt/stacks/geo-routing-server" ] && ! is_protected_dir "/opt/stacks/geo-routing-server"; then
        echo "/opt/stacks/geo-routing-server"
        return 0
    fi
    echo "$DEFAULT_INSTALL_DIR"
}

save_install_dir() {
    mkdir -p "$(dirname "$CONFIG_RECORD")"
    echo "$1" > "$CONFIG_RECORD"
}

# Спрашивает каталог установки и приводит его к абсолютному пути.
# Относительный путь или буквальный "~/geo" (read не раскрывает '~') иначе
# сохранились бы как есть, и geoserver из другого cwd не нашёл бы установку.
ask_install_dir() {
    local default_dir="$1" input_dir="" dir=""
    while true; do
        read -r -p "      Путь [Enter = ${default_dir}]: " input_dir || input_dir=""
        dir="${input_dir:-$default_dir}"
        case "$dir" in
            \~) dir="$HOME" ;;
            \~/*) dir="${HOME}/${dir#\~/}" ;;
        esac
        dir="$(abs_path "$dir")"
        if is_protected_dir "$dir"; then
            echo -e "      ${C_RED}[!] '${dir}' — системный или домашний каталог, установка туда запрещена.${C_RESET}" >&2
            continue
        fi
        echo "$dir"
        return 0
    done
}

create_cli_shortcut() {
    local install_dir="$1"
    local bin_path="/usr/local/bin/geoserver"
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}[!] Нет прав для записи в ${bin_path} — запустите от root.${C_RESET}"
        return 1
    fi
    cat > "$bin_path" <<EOF
#!/usr/bin/env bash
exec bash "$install_dir/install.sh" "\$@"
EOF
    chmod 755 "$bin_path" 2>/dev/null || true
}

# Сохраняет install.sh в каталог установки.
# При запуске `bash <(curl ...)` $0 — уже вычитанный пайп /dev/fd/N, и `cp`
# дал бы пустой файл, поэтому копируем только непустой обычный файл, иначе
# скачиваем свежую копию.
persist_install_script() {
    local target_dir="$1"
    local target="${target_dir}/install.sh"
    mkdir -p "$target_dir" 2>/dev/null || true
    if [ -f "$0" ] && [ -r "$0" ] && [ -s "$0" ] \
        && [ "$(realpath "$0" 2>/dev/null || true)" != "$(realpath "$target" 2>/dev/null || true)" ]; then
        cp "$0" "$target" 2>/dev/null || true
    fi
    if [ ! -s "$target" ]; then
        curl -fsSL --connect-timeout 10 --max-time 30 "$INSTALL_SCRIPT_URL" -o "$target" 2>/dev/null || true
    fi
    if [ -s "$target" ]; then
        # 755 явно, не "+x": на базе 0600 "+x" даёт 0711, и файл не читается без root
        chmod 755 "$target" 2>/dev/null || true
        return 0
    fi
    echo -e "${C_YELLOW}[!] Не удалось сохранить install.sh в ${target_dir} (команда geoserver может не работать).${C_RESET}"
    return 1
}

# ------------------------------------------------------------------------------
# Вызов CLI в образе
# ------------------------------------------------------------------------------

# Сведения о хосте, которых нет в контейнере: Docker-сети и занятые порты.
# Передаются только если удалось их получить — иначе CLI не делает выводов.
host_facts_args() {
    local nets ports
    if nets="$(docker network ls --format '{{.Name}}' </dev/null 2>/dev/null)"; then
        printf '%s\n' "-e" "GRS_HOST_NETWORKS=$(printf '%s' "$nets" | paste -sd, -)"
    fi
    if command -v ss >/dev/null 2>&1; then
        ports="$(ss -tlnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u | paste -sd, -)"
        printf '%s\n' "-e" "GRS_HOST_PORTS=${ports}"
    fi
}

# CLI в свежем образе, без стека (мастер первой установки: compose.yaml ещё нет)
cli_image() {
    local dir="$1"
    shift
    local -a args=(--rm -i)
    if [ -t 0 ] && [ -t 1 ]; then args=(--rm -it); fi
    local -a facts=()
    mapfile -t facts < <(host_facts_args)
    docker run "${args[@]}" -v "$dir:/host" ${facts[@]+"${facts[@]}"} \
        --entrypoint python3 "$IMAGE" -m app.cli "$@"
}

# CLI в разовом контейнере стека: тот же образ, том данных, сети и свежий .env.
# Работает и при остановленном или падающем основном контейнере.
#
# Важно: `docker compose run` и `docker run -i` пересылают в контейнер ВЕСЬ
# stdin из пайпа, даже если команда его не читает. Вызовы без ввода поэтому
# идут с `</dev/null`, иначе они «съедают» ответы, предназначенные следующему
# интерактивному шагу (например, при `printf ... | geoserver config schedule`).
cli_stack() {
    local dir compose_cmd
    dir="$(get_install_dir)"
    compose_cmd="$(detect_compose)"
    if [ -z "$compose_cmd" ]; then
        echo -e "${C_RED}[!] Docker Compose не найден.${C_RESET}"
        return 1
    fi
    local -a tty=()
    if ! { [ -t 0 ] && [ -t 1 ]; }; then tty=(-T); fi
    local -a facts=()
    mapfile -t facts < <(host_facts_args)
    # stderr чистим от служебного вывода Compose про разовый контейнер
    # (Creating/Created/...) и от повторяющегося предупреждения о томе без
    # меток — о нём один раз сообщает `geoserver status` (check_volume_labels).
    # Только переносимые флаги grep: на хостах с BusyBox (Alpine) нет
    # --line-buffered, и grep, упав сразу, обрывал бы stderr самому Compose.
    (cd "$dir" && $compose_cmd run --rm --no-deps ${tty[@]+"${tty[@]}"} \
        --entrypoint python3 -v "$dir:/host" ${facts[@]+"${facts[@]}"} \
        "$SERVICE" -m app.cli "$@") 2> >(grep -vE "$COMPOSE_NOISE_RE" >&2 || true)
}

# Команды только для чтения (status, proxy): в работающем контейнере — через
# exec, без создания разового контейнера; иначе — через cli_stack.
cli_read() {
    if is_container_running; then
        local -a tty=()
        if ! { [ -t 0 ] && [ -t 1 ]; }; then tty=(-T); fi
        compose_in exec ${tty[@]+"${tty[@]}"} "$SERVICE" python3 -m app.cli "$@"
    else
        cli_stack "$@"
    fi
}

# Том данных, созданный не через Compose (перенос с другого сервера, восстановление
# из бэкапа, ручной `docker volume create`), работает, но Compose предупреждает о
# нём при каждом запуске. Сообщаем один раз и говорим, как исправить.
data_volume_name() {
    local dir project
    dir="$(get_install_dir)"
    project="$(sed -n 's/^name:[[:space:]]*//p' "$dir/compose.yaml" 2>/dev/null | head -1 | tr -d "\"'")"
    [ -n "$project" ] || project="$(basename "$dir")"
    echo "${project}_routing_data"
}

# 0 — том создан Compose (есть метка проекта); 1 — без меток; 2 — тома нет
volume_label_state() {
    local label
    label="$(docker volume inspect -f '{{index .Labels "com.docker.compose.project"}}' "$1" </dev/null 2>/dev/null)" || return 2
    [ -n "$label" ] && [ "$label" != "<no value>" ]
}

check_volume_labels() {
    local volume rc=0
    volume="$(data_volume_name)"
    volume_label_state "$volume" || rc=$?
    if [ "$rc" -eq 1 ]; then
        echo -e "${C_GRAY}[i] Том ${volume} создан не через Docker Compose (например, после переноса или восстановления).${C_RESET}"
        echo -e "${C_GRAY}    На работу это не влияет, но Compose предупреждает о нём при каждом запуске. Исправить: ${C_BOLD}geoserver repair-volume${C_RESET}"
        echo ""
    fi
}

# Пересоздаёт том данных с метками Compose, сохраняя содержимое. Метки у
# существующего тома поменять нельзя, поэтому: копия во временный том →
# сверка → новый том через `compose create` → копия обратно → сверка → запуск.
# При любой ошибке временный том с данными остаётся и называется в сообщении.
cmd_repair_volume() {
    local volume backup image rc=0
    volume="$(data_volume_name)"
    volume_label_state "$volume" || rc=$?
    if [ "$rc" -eq 2 ]; then
        echo -e "${C_RED}[!] Том ${volume} не найден.${C_RESET}"
        return 1
    fi
    if [ "$rc" -eq 0 ]; then
        echo -e "${C_GREEN}[✓] Том ${volume} уже создан Docker Compose — исправлять нечего.${C_RESET}"
        return 0
    fi
    image="${IMAGE_REPO}:$(current_image_tag)"
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        echo -e "${C_RED}[!] Образ ${image} не найден локально — сначала: geoserver update-image${C_RESET}"
        return 1
    fi
    echo -e "Том ${C_BOLD}${volume}${C_RESET} будет пересоздан с метками Docker Compose."
    echo -e "Данные копируются во временный том и сверяются; контейнер на это время остановится."
    local ans=""
    read -r -p "Продолжить? [y/N]: " ans || ans=""
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Отмена."; return 1; }

    # Число файлов и суммарный размер — достаточная сверка полноты копии
    volume_digest() {
        docker run --rm -v "$1:/v:ro" --entrypoint sh "$image" -c \
            'cd /v && echo "$(find . | wc -l) $(du -s . | cut -f1)"' </dev/null
    }
    copy_volume() {
        docker run --rm -v "$1:/from:ro" -v "$2:/to" --entrypoint sh "$image" -c 'cp -a /from/. /to/' </dev/null
    }

    backup="${volume}_backup_$(date +%Y%m%d%H%M%S)"
    local before after
    echo -e "${C_YELLOW}[*] Остановка контейнера...${C_RESET}"
    compose_in down </dev/null || return 1
    before="$(volume_digest "$volume")" || return 1
    echo -e "${C_YELLOW}[*] Копирование данных во временный том ${backup}...${C_RESET}"
    if ! docker volume create "$backup" >/dev/null || ! copy_volume "$volume" "$backup" \
        || [ "$(volume_digest "$backup")" != "$before" ]; then
        echo -e "${C_RED}[!] Копия не совпала с оригиналом — исходный том не тронут. Запуск: geoserver start${C_RESET}"
        return 1
    fi
    echo -e "${C_YELLOW}[*] Пересоздание тома...${C_RESET}"
    if ! docker volume rm "$volume" >/dev/null || ! compose_in create </dev/null \
        || ! copy_volume "$backup" "$volume" || [ "$(volume_digest "$volume")" != "$before" ]; then
        echo -e "${C_RED}[!] Ошибка на этапе пересоздания. Данные целы во временном томе ${C_BOLD}${backup}${C_RESET}${C_RED} — не удаляйте его.${C_RESET}"
        echo -e "    Восстановление: docker run --rm -v ${backup}:/from -v ${volume}:/to ${image} sh -c 'cp -a /from/. /to/'"
        return 1
    fi
    after="$(volume_digest "$volume")"
    docker volume rm "$backup" >/dev/null || true
    apply_changes || return 1
    rc=0
    volume_label_state "$volume" || rc=$?
    if [ "$rc" -eq 0 ]; then
        echo -e "${C_GREEN}[✓] Том пересоздан с метками Compose, данные на месте (${after% *} файлов). Предупреждение больше не появится.${C_RESET}"
    else
        echo -e "${C_YELLOW}[!] Данные на месте, но метки у тома так и не появились — проверьте версию Docker Compose.${C_RESET}"
        return 1
    fi
}

# Образ, установленный до v1.6.0, не знает подкоманд config/setup
require_new_image() {
    local api
    api="$(cli_stack version </dev/null 2>/dev/null | sed -n 's/.*cli-api \([0-9][0-9]*\).*/\1/p' || true)"
    if [ -z "$api" ] || [ "$api" -lt "$REQUIRED_CLI_API" ]; then
        echo -e "${C_YELLOW}[!] Образ контейнера старее этой версии geoserver и не поддерживает настройку из меню.${C_RESET}"
        echo -e "    Обновите образ: ${C_BOLD}geoserver update-image${C_RESET} (или пункт 9 → 2)."
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Docker Compose
# ------------------------------------------------------------------------------

compose_in() {
    local dir compose_cmd
    dir="$(get_install_dir)"
    compose_cmd="$(detect_compose)"
    if [ -z "$compose_cmd" ]; then
        echo -e "${C_RED}[!] Docker Compose не найден.${C_RESET}"
        return 1
    fi
    # stderr не перенаправлять: Compose определяет по нему терминал. Через пайп
    # он переключается на «сырой» вывод (каждый слой образа отдельной строкой)
    # и меняет формат предупреждений. Причину предупреждения о томе без меток
    # устраняет `geoserver repair-volume`, а не фильтр.
    (cd "$dir" && $compose_cmd "$@")
}

# `up -d` возвращает 0, даже если контейнер сразу падает (например, из-за
# невалидного токена), поэтому ждём реального состояния: running без рестартов.
wait_for_container_ready() {
    local tries=0 status="" restarts=""
    while [ "$tries" -lt 25 ]; do
        status="$(docker inspect -f '{{.State.Status}}' "$SERVICE" 2>/dev/null || true)"
        restarts="$(docker inspect -f '{{.RestartCount}}' "$SERVICE" 2>/dev/null || echo 0)"
        if [ "$status" = "running" ]; then
            sleep 2
            status="$(docker inspect -f '{{.State.Status}}' "$SERVICE" 2>/dev/null || true)"
            restarts="$(docker inspect -f '{{.RestartCount}}' "$SERVICE" 2>/dev/null || echo 0)"
            if [ "$status" = "running" ] && [ "${restarts:-0}" -lt 2 ] 2>/dev/null; then
                return 0
            fi
        fi
        if [ "${restarts:-0}" -ge 3 ] 2>/dev/null; then
            return 1
        fi
        tries=$((tries + 1))
        sleep 1
    done
    return 1
}

report_start_failure() {
    echo -e "${C_RED}[!] Контейнер ${SERVICE} не запустился или падает с перезапуском.${C_RESET}"
    echo -e "${C_YELLOW}Последние логи контейнера:${C_RESET}"
    docker logs --tail 30 "$SERVICE" 2>&1 || true
}

# Применяет .env и compose.yaml: compose пересоздаёт контейнер, если они изменились
apply_changes() {
    echo -e "${C_YELLOW}[*] Применение настроек...${C_RESET}"
    if ! compose_in up -d </dev/null; then
        echo -e "${C_RED}[!] Настройки сохранены, но Docker Compose завершился с ошибкой выше.${C_RESET}"
        return 1
    fi
    if ! wait_for_container_ready; then
        report_start_failure
        return 1
    fi
    echo -e "${C_GREEN}[✓] Настройки применены.${C_RESET}"
}

get_container_status() {
    if is_container_running; then
        local state=""
        state="$(compose_in ps --format '{{.Status}}' </dev/null 2>/dev/null | head -1 || true)"
        echo -e "${C_GREEN}● Работает${C_RESET}${state:+ ${C_GRAY}($state)${C_RESET}}"
    else
        echo -e "${C_RED}○ Остановлен${C_RESET}"
    fi
}

# ------------------------------------------------------------------------------
# Команды
# ------------------------------------------------------------------------------

config_section() {
    local section="$1"
    require_new_image || { pause; return 0; }
    while true; do
        local rc=0
        cli_stack config "$section" --host-dir /host || rc=$?
        if [ "$rc" -eq "$APPLY_RC" ]; then
            apply_changes || { pause; return 0; }
            continue
        fi
        return 0
    done
}

# geoserver config set KEY VALUE / get KEY — без меню, для скриптов
cmd_config_key() {
    require_new_image || return 1
    local rc=0
    cli_stack config "$@" --host-dir /host </dev/null || rc=$?
    if [ "$rc" -eq "$APPLY_RC" ]; then
        apply_changes
        return $?
    fi
    return "$rc"
}

cmd_status() {
    local dir
    dir="$(get_install_dir)"
    print_banner
    echo -e "  ${C_WHITE}Каталог:${C_RESET} $dir"
    echo -e "  ${C_WHITE}Статус:${C_RESET}  $(get_container_status)"
    echo ""
    if [ ! -f "$dir/.env" ]; then
        echo -e "${C_YELLOW}Файл конфигурации (.env) не найден. Выполните установку: geoserver install${C_RESET}"
        return 0
    fi
    if [ ! -r "$dir/.env" ]; then
        echo -e "${C_YELLOW}Файл $dir/.env доступен только root. Запустите: ${C_BOLD}sudo geoserver status${C_RESET}"
        return 0
    fi
    check_volume_labels
    cli_read status </dev/null || echo -e "${C_YELLOW}[!] Не удалось получить сводку. Проверьте: geoserver logs${C_RESET}"
}

cmd_sync() {
    if ! is_container_running; then
        echo -e "\n${C_RED}[!] Контейнер ${SERVICE} не запущен.${C_RESET}"
        echo -e "${C_YELLOW}Запустите сервис перед синхронизацией: ${C_BOLD}geoserver start${C_RESET}\n"
        return 1
    fi
    echo -e "\n${C_YELLOW}[*] Запуск синхронизации баз и правил...${C_RESET}"
    # В работающем контейнере, а не в разовом: там общая блокировка от
    # параллельного запуска с синхронизацией по расписанию.
    if compose_in exec -T "$SERVICE" python3 -m app.cli sync </dev/null; then
        echo -e "\n${C_GREEN}[✓] Синхронизация завершена.${C_RESET}\n"
    else
        echo -e "\n${C_RED}[!] Синхронизация завершилась с ошибкой. Проверьте логи: geoserver logs${C_RESET}\n"
        return 1
    fi
}

cmd_logs() {
    echo -e "${C_CYAN}[i] Логи в реальном времени (Ctrl+C для выхода)...${C_RESET}\n"
    compose_in logs -f --tail=100 "$SERVICE" || true
}

# Пересоздаёт контейнер: в отличие от `compose restart`, подхватывает изменения .env
cmd_restart() {
    echo -e "${C_YELLOW}[*] Перезапуск контейнера с текущими настройками...${C_RESET}"
    if ! compose_in up -d --force-recreate </dev/null; then
        echo -e "${C_RED}[!] Не удалось перезапустить контейнер (см. ошибку Docker Compose выше).${C_RESET}"
        return 1
    fi
    if ! wait_for_container_ready; then
        report_start_failure
        return 1
    fi
    echo -e "${C_GREEN}[✓] Контейнер перезапущен.${C_RESET}"
}

cmd_stop() {
    if compose_in stop </dev/null; then
        echo -e "${C_YELLOW}[✓] Сервис остановлен.${C_RESET}"
    else
        echo -e "${C_RED}[!] Не удалось остановить сервис (см. ошибку Docker Compose выше).${C_RESET}"
        return 1
    fi
}

cmd_start() {
    apply_changes
}

# Тег образа в compose.yaml: "latest" или версия вида 1.7.0
current_image_tag() {
    local compose_file
    compose_file="$(get_install_dir)/compose.yaml"
    sed -n "s#^[[:space:]]*image:[[:space:]]*${IMAGE_REPO}:\([^[:space:]]*\).*#\1#p" "$compose_file" 2>/dev/null | head -1
}

# Меняет тег нашего образа в compose.yaml. Правка в bash, а не через CLI
# образа: откат должен работать и тогда, когда текущий образ её не умеет.
set_image_tag() {
    local tag="$1" compose_file
    compose_file="$(get_install_dir)/compose.yaml"
    if ! grep -qE "^[[:space:]]*image:[[:space:]]*${IMAGE_REPO}:" "$compose_file" 2>/dev/null; then
        echo -e "${C_RED}[!] В compose.yaml не найден образ ${IMAGE_REPO} — укажите версию вручную (geoserver config).${C_RESET}"
        return 1
    fi
    sed -i "s#^\([[:space:]]*image:[[:space:]]*\)${IMAGE_REPO}:[^[:space:]]*#\1${IMAGE_REPO}:${tag}#" "$compose_file"
}

# geoserver update-image [ВЕРСИЯ]
#   без версии  — свежий образ текущего тега (обычно latest);
#   1.7.0       — закрепиться на версии или откатиться к ней;
#   latest      — снять закрепление.
cmd_update() {
    local target="${1:-}"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    if [ -z "$compose_cmd" ]; then
        echo -e "\n${C_RED}[!] Docker Compose не найден.${C_RESET}\n"
        return 1
    fi
    if [ -n "$target" ] && ! [[ "$target" =~ ^([0-9]+\.[0-9]+\.[0-9]+|latest)$ ]]; then
        echo -e "${C_RED}[!] Версия должна быть вида 1.7.0 или latest, получено: '${target}'.${C_RESET}"
        return 2
    fi
    local compose_file previous_tag backup=""
    compose_file="$(get_install_dir)/compose.yaml"
    previous_tag="$(current_image_tag)"
    if [ -n "$target" ] && [ "$target" != "$previous_tag" ]; then
        backup="${compose_file}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -p "$compose_file" "$backup"
        set_image_tag "$target" || return 1
        echo -e "${C_GRAY}[i] Образ: ${previous_tag:-?} → ${target}${C_RESET}"
    fi
    # До v1.5.2 привязки сквадов лежали в /app/squads.json — в слое контейнера.
    # `up --force-recreate` уничтожает этот слой, поэтому копируем файл в том,
    # пока старый контейнер ещё работает. Существующий .squads.json не трогаем.
    if is_container_running; then
        compose_in exec -T "$SERVICE" sh -c \
            '[ -s /app/squads.json ] && [ ! -e /app/www/.squads.json ] && cp -p /app/squads.json /app/www/.squads.json && echo "[i] squads.json сохранён в томе данных"' \
            </dev/null 2>/dev/null || true
    fi
    echo -e "\n${C_YELLOW}[*] Загрузка образа...${C_RESET}"
    if [ -z "${GRS_SKIP_PULL:-}" ] && ! compose_in pull </dev/null; then
        echo -e "${C_RED}[!] Не удалось загрузить образ (см. ошибку выше).${C_RESET}"
        if [ -n "$backup" ]; then
            # Версии нет в реестре или сеть недоступна — возвращаем прежний тег,
            # чтобы следующий `up` не пытался запустить несуществующий образ
            mv -f "$backup" "$compose_file"
            echo -e "${C_YELLOW}    compose.yaml возвращён к прежней версии (${previous_tag:-?}). Доступные версии: https://github.com/xdeptu5/geo-routing-server/pkgs/container/geo-routing-server${C_RESET}"
        fi
        echo ""
        return 1
    fi
    if ! compose_in up -d --force-recreate </dev/null; then
        echo -e "${C_RED}[!] Обновление не применено: Docker Compose завершился с ошибкой выше.${C_RESET}\n"
        return 1
    fi
    if ! wait_for_container_ready; then
        report_start_failure
        return 1
    fi
    local running_version
    running_version="$(compose_in exec -T "$SERVICE" python3 -m app.cli version </dev/null 2>/dev/null | awk '{print $2}' || true)"
    echo -e "${C_GREEN}[✓] Образ обновлён: $(current_image_tag)${running_version:+ (версия ${running_version})}.${C_RESET}\n"
}

cmd_update_script() {
    local install_dir
    install_dir="$(get_install_dir)"
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${C_RED}[!] Обновление скрипта требует права root (запись в ${install_dir}/install.sh и /usr/local/bin/geoserver).${C_RESET}"
        echo -e "    Запустите: ${C_BOLD}sudo geoserver update-script${C_RESET}"
        return 1
    fi

    echo -e "\n${C_YELLOW}[*] Проверка обновлений скрипта на GitHub...${C_RESET}"
    local tmp_script
    tmp_script=$(mktemp "${install_dir}/.install.sh.XXXXXX" 2>/dev/null || mktemp "/tmp/.install.sh.XXXXXX")
    if ! curl -fsSL -H "Cache-Control: no-cache" --connect-timeout 10 --max-time 30 "${INSTALL_SCRIPT_URL}?t=$(date +%s)" -o "$tmp_script" 2>/dev/null; then
        rm -f "$tmp_script"
        echo -e "${C_RED}[!] Не удалось загрузить скрипт с GitHub. Проверьте интернет-соединение.${C_RESET}"
        return 1
    fi
    if ! bash -n "$tmp_script" 2>/dev/null; then
        rm -f "$tmp_script"
        echo -e "${C_RED}[!] Загруженный файл повреждён или содержит синтаксические ошибки.${C_RESET}"
        return 1
    fi
    local remote_ver
    remote_ver=$(grep -E '^SCRIPT_VERSION=' "$tmp_script" 2>/dev/null | head -1 | cut -d'"' -f2 || true)
    if [ -z "$remote_ver" ]; then
        rm -f "$tmp_script"
        echo -e "${C_RED}[!] Не удалось определить версию в загруженном файле.${C_RESET}"
        return 1
    fi
    echo -e "  Текущая версия:   ${C_WHITE}v${SCRIPT_VERSION}${C_RESET}"
    echo -e "  Версия на GitHub: ${C_GREEN}v${remote_ver}${C_RESET}"
    if [ -f "$install_dir/install.sh" ] && cmp -s "$install_dir/install.sh" "$tmp_script" 2>/dev/null; then
        rm -f "$tmp_script"
        if [ "$remote_ver" != "$SCRIPT_VERSION" ]; then
            # Файл на диске уже новый (обновлён раньше), а работает старый код,
            # загруженный при запуске этой сессии меню
            echo -e "\n${C_GREEN}[✓] На диске уже v${remote_ver}; эта сессия запущена со старой версией v${SCRIPT_VERSION}.${C_RESET}\n"
            SCRIPT_REPLACED=1
        else
            echo -e "\n${C_GREEN}[✓] Скрипт уже актуален (v${remote_ver}).${C_RESET}\n"
        fi
        return 0
    fi
    # 755 явно: mktemp создаёт 0600, и "+x" дал бы 0711 — файл не читался бы без root
    chmod 755 "$tmp_script"
    mkdir -p "$install_dir"
    mv -f "$tmp_script" "$install_dir/install.sh"
    create_cli_shortcut "$install_dir"
    SCRIPT_REPLACED=1
    echo -e "${C_GREEN}[✓] Скрипт управления обновлён: v${SCRIPT_VERSION} → v${remote_ver}.${C_RESET}\n"
}

# Bash читает скрипт по ходу выполнения, а функции этой сессии уже загружены
# из старой версии. После обновления скрипта меню перезапускается новой, иначе
# оно продолжает работать старым кодом и показывать старую версию.
reopen_if_script_replaced() {
    if [ "$SCRIPT_REPLACED" = "1" ] && [ -t 0 ]; then
        echo -e "${C_CYAN}[i] Перезапуск меню с новой версией скрипта...${C_RESET}"
        sleep 1
        exec bash "$(get_install_dir)/install.sh" update
    fi
}

menu_updates() {
    while true; do
        print_banner
        echo -e "  ${C_WHITE}Раздел:${C_RESET} Центр обновлений"
        hr 50
        local running_version=""
        if is_container_running; then
            running_version="$(compose_in exec -T "$SERVICE" python3 -m app.cli version </dev/null 2>/dev/null | awk '{print $2}' || true)"
        fi
        echo -e "  Скрипт:  v${SCRIPT_VERSION}"
        echo -e "  Образ:   $(current_image_tag)${running_version:+ (работает версия ${running_version})}"
        echo ""
        echo "   1) Обновить всё (скрипт управления, затем Docker-образ)"
        echo "   2) Обновить только Docker-образ"
        echo "   3) Обновить только скрипт управления"
        echo "   4) Закрепить или откатить версию образа"
        echo "   0) Назад"
        echo ""
        read -r -p "Выберите действие [0-4]: " choice || return 0
        case "$choice" in
            1)
                # Сначала скрипт: новый скрипт знает, как сохранить данные
                # старого контейнера перед пересозданием.
                cmd_update_script || true
                bash "$(get_install_dir)/install.sh" update-image || true
                pause
                reopen_if_script_replaced
                ;;
            2) cmd_update || true; pause ;;
            3) cmd_update_script || true; pause; reopen_if_script_replaced ;;
            4)
                local version=""
                read -r -p "Версия (например 1.7.0; latest — снять закрепление) [Enter = отмена]: " version || version=""
                if [ -n "$version" ]; then cmd_update "$version" || true; pause; fi
                ;;
            0|q|exit) return 0 ;;
        esac
    done
}

cmd_edit() {
    local env_file
    env_file="$(get_install_dir)/.env"
    local editor="${EDITOR:-}"
    if [ -z "$editor" ]; then
        if command -v nano >/dev/null 2>&1; then
            editor="nano"
        elif command -v vi >/dev/null 2>&1; then
            editor="vi"
        else
            echo -e "${C_RED}[!] Редактор nano или vi не найден.${C_RESET}"
            return 1
        fi
    fi
    "$editor" "$env_file"
    local ans=""
    read -r -p "Применить изменения и перезапустить контейнер? [Y/n]: " ans || ans="n"
    if [[ "${ans:-y}" =~ ^[Yy]$ ]]; then
        apply_changes
    fi
}

cmd_uninstall() {
    local install_dir
    install_dir="$(get_install_dir)"

    if [ -z "$install_dir" ] || is_protected_dir "$install_dir"; then
        echo -e "${C_RED}[!] Недопустимый или защищённый системный каталог: '${install_dir}' — удаление отменено.${C_RESET}"
        return 1
    fi
    local target
    target="$(abs_path "$install_dir")"
    [ -n "$target" ] || target="$install_dir"
    [ "$target" != "/" ] && target="${target%/}"
    if is_protected_dir "$target"; then
        echo -e "${C_RED}[!] '$target' — защищённый системный каталог, удаление запрещено.${C_RESET}"
        return 1
    fi
    if ! is_project_dir "$target"; then
        echo -e "${C_RED}[!] Каталог $target не содержит маркеров установки Geo Routing Server${C_RESET}"
        echo -e "${C_RED}    (нет compose.yaml с сервисом или .env с нашими ключами) — удаление отменено.${C_RESET}"
        return 1
    fi

    print_banner
    echo -e "${C_RED}${C_BOLD}[!] ВНИМАНИЕ: полное удаление Geo Routing Server${C_RESET}"
    echo -e "${C_GRAY}Будут остановлены контейнеры, удалены тома Docker и конфигурация.${C_RESET}"
    echo -e "${C_WHITE}Каталог, который будет удалён: ${C_BOLD}${target}${C_RESET}\n"
    local confirm=""
    read -r -p "Вы уверены, что хотите удалить сервис? [y/N, Enter = отмена]: " confirm || confirm=""
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${C_GRAY}Отмена удаления.${C_RESET}"
        return 1
    fi

    echo -e "\n${C_YELLOW}[*] Остановка сервиса и очистка томов Docker...${C_RESET}"
    local compose_cmd
    compose_cmd="$(detect_compose)"
    if [ -d "$target" ] && [ -n "$compose_cmd" ]; then
        (cd "$target" && $compose_cmd down -v 2>/dev/null || true)
    fi
    if [ -d "$target/.git" ]; then
        # Каталог git-клона (README предлагает его для локальной сборки):
        # удаляем только файлы, созданные установщиком, а не исходники и историю.
        echo -e "${C_YELLOW}[!] В '$target' обнаружен git-репозиторий — удаляются только файлы установщика: .env*, compose.yaml*, .cache/${C_RESET}"
        rm -f -- "$target/.env" "$target"/.env.bak* "$target/compose.yaml" "$target"/compose.yaml.bak*
        rm -rf -- "$target/.cache"
    else
        rm -rf -- "$target"
    fi
    rm -f "$CONFIG_RECORD" "/usr/local/bin/geoserver"
    echo -e "${C_GREEN}[✓] Geo Routing Server удалён (${target}).${C_RESET}\n"
}

cmd_help() {
    echo -e "${C_BOLD}Использование:${C_RESET} geoserver [команда]"
    echo ""
    echo "  status                 Статус сервиса и ссылки для клиентов"
    echo "  sync                   Синхронизировать базы и правила сейчас"
    echo "  logs                   Логи контейнера (Ctrl+C для выхода)"
    echo "  config                 Открыть .env в редакторе и применить"
    echo "  config <раздел>        Раздел настроек: clients, schedule, telegram, remnawave"
    echo "  config set KEY VALUE   Изменить один параметр (с проверкой) и применить"
    echo "  config get KEY         Показать значение параметра"
    echo "  squads [...]           Сквады Remnawave (list, add, remove, sync, migrate)"
    echo "  proxy                  Готовые конфиги Caddy и Nginx"
    echo "  restart                Пересоздать контейнер с текущими настройками"
    echo "  start / stop           Запуск / остановка"
    echo "  update                 Центр обновлений"
    echo "  update-image [ВЕРСИЯ]  Обновить образ; ВЕРСИЯ (1.7.0) — закрепить или откатить, latest — снять"
    echo "  update-script          Обновить этот скрипт"
    echo "  update-all             Обновить скрипт, затем образ"
    echo "  cli [...]              Прямой вызов python -m app.cli"
    echo "  repair-volume          Пересоздать том данных с метками Compose (убирает WARN о томе)"
    echo "  install                Повторно запустить мастер установки"
    echo "  uninstall              Удалить сервис"
    echo ""
    echo -e "Без аргументов ${C_BOLD}geoserver${C_RESET} открывает интерактивное меню."
}

# ------------------------------------------------------------------------------
# Установка
# ------------------------------------------------------------------------------

wizard_install() {
    print_banner
    check_root
    check_dependencies

    echo -e "${C_WHITE}${C_BOLD}Первоначальная настройка${C_RESET}\n"
    echo -e "${C_CYAN}Каталог установки${C_RESET}"
    local install_dir
    install_dir="$(ask_install_dir "$(get_install_dir)")"
    mkdir -p "$install_dir"
    save_install_dir "$install_dir"

    if [ -n "${GRS_IMAGE:-}" ] && docker image inspect "$IMAGE" >/dev/null 2>&1; then
        echo -e "${C_GRAY}[i] Используется локальный образ ${IMAGE}${C_RESET}"
    else
        echo -e "\n${C_YELLOW}[*] Загрузка образа ${IMAGE}...${C_RESET}"
        if ! docker pull "$IMAGE"; then
            echo -e "${C_RED}[!] Не удалось загрузить образ (см. ошибку выше).${C_RESET}"
            return 1
        fi
    fi

    # Вопросы мастера, проверка ответов, .env и compose.yaml — в CLI образа
    if ! cli_image "$install_dir" setup --host-dir /host --image "$IMAGE"; then
        echo -e "${C_RED}[!] Установка прервана: настройки не сохранены.${C_RESET}"
        return 1
    fi

    persist_install_script "$install_dir" || true
    if ! create_cli_shortcut "$install_dir"; then
        echo -e "      ${C_YELLOW}[!] Команда geoserver не создана.${C_RESET}"
    fi

    echo -e "\n${C_YELLOW}[*] Запуск сервиса...${C_RESET}"
    if ! apply_changes; then
        echo -e "${C_YELLOW}Проверьте настройки (geoserver config) и запустите установку заново.${C_RESET}"
        return 1
    fi

    echo -e "\n${C_GREEN}${C_BOLD}  Geo Routing Server установлен и запущен.${C_RESET}\n"
    cli_read status </dev/null || true
    echo ""
    cli_read proxy </dev/null || true
    echo -e "${C_CYAN}Для управления сервером используйте команду: ${C_BOLD}geoserver${C_RESET}\n"
}

# ------------------------------------------------------------------------------
# Главное меню
# ------------------------------------------------------------------------------

main_menu() {
    while true; do
        print_banner
        echo -e "  ${C_WHITE}Каталог:${C_RESET} $(get_install_dir)"
        echo -e "  ${C_WHITE}Статус:${C_RESET}  $(get_container_status)"
        hr 54
        echo ""
        echo "  1) Статус и ссылки для клиентов"
        echo "  2) Синхронизировать сейчас"
        echo "  3) Логи контейнера"
        echo "  4) Remnawave и сквады"
        echo "  5) Расписание синхронизации"
        echo "  6) Telegram-уведомления"
        echo "  7) Клиенты, источник правил, гео-базы"
        echo "  8) Конфиги Caddy / Nginx"
        echo "  9) Центр обновлений"
        echo " 10) Перезапустить контейнер"
        if is_container_running; then
            echo " 11) Остановить контейнер"
        else
            echo " 11) Запустить контейнер"
        fi
        echo " 12) Редактировать .env"
        echo " 13) Удалить сервис"
        echo "  0) Выход"
        echo ""
        local choice=""
        read -r -p "  Выберите действие [0-13]: " choice || exit 0

        case "$choice" in
            1) cmd_status || true; pause ;;
            2) cmd_sync || true; pause ;;
            3) cmd_logs ;;
            4) config_section remnawave ;;
            5) config_section schedule ;;
            6) config_section telegram ;;
            7) config_section clients ;;
            8) cli_read proxy </dev/null || true; pause ;;
            9) menu_updates ;;
            10) cmd_restart || true; pause ;;
            11)
                if is_container_running; then cmd_stop || true; else cmd_start || true; fi
                pause
                ;;
            12) cmd_edit || true ;;
            13)
                # 0 — удалено, выходим; 1 — отмена, остаёмся в меню
                if cmd_uninstall; then exit 0; fi
                pause
                ;;
            0|q|exit) clear 2>/dev/null || true; exit 0 ;;
        esac
    done
}

main() {
    local cmd="${1:-}"
    [ $# -gt 0 ] && shift
    case "$cmd" in
        status|info)                 cmd_status ;;
        sync)                        cmd_sync ;;
        logs)                        cmd_logs ;;
        restart)                     cmd_restart ;;
        stop)                        cmd_stop ;;
        start)                       cmd_start ;;
        update)                      menu_updates ;;
        update-image)                cmd_update "$@" ;;
        update-script|self-update)   cmd_update_script ;;
        update-all)                  cmd_update_script && bash "$(get_install_dir)/install.sh" update-image ;;
        proxy)                       cli_read proxy </dev/null ;;
        squads)                      cli_stack squads "$@" ;;
        cli)                         cli_stack "$@" ;;
        config|edit)
            case "${1:-}" in
                "")                                cmd_edit ;;
                set|get)                           cmd_config_key "$@" ;;
                clients|schedule|telegram|remnawave) config_section "$1" ;;
                *) echo -e "${C_RED}Неизвестный раздел: $1${C_RESET}"; cmd_help; return 1 ;;
            esac
            ;;
        repair-volume)               cmd_repair_volume ;;
        uninstall)                   cmd_uninstall ;;
        install|setup)               wizard_install ;;
        help|-h|--help)              cmd_help ;;
        "")
            local dir
            dir="$(get_install_dir)"
            if [ -f "$dir/.env" ] && { [ -f "$dir/compose.yaml" ] || [ -f "$dir/docker-compose.yml" ]; }; then
                main_menu
            else
                wizard_install
            fi
            ;;
        *)
            echo -e "${C_RED}Неизвестная команда: $cmd${C_RESET}\n"
            cmd_help
            return 1
            ;;
    esac
}

main "$@"
