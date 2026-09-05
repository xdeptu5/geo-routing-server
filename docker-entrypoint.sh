#!/bin/sh
set -eu

: "${SCHEDULE:?SCHEDULE must be set}"
SYNC_ON_START="${SYNC_ON_START:-true}"

resolve_routing_token() {
    routing_value="${ROUTING_TOKEN:-}"
    clients="$(printf '%s' "${ENABLED_CLIENTS:-HAPP,INCY}" | tr -d '[:space:]')"

    if [ -z "$routing_value" ] || [ "$routing_value" = "change_me_to_random_secret_token" ]; then
        case ",$clients," in
            ,HAPP_DEEPLINK,|,HAPP_LOCAL,|,HAPP_DEEPLINK,HAPP_LOCAL,|,HAPP_LOCAL,HAPP_DEEPLINK,)
                routing_value="local"
                ;;
            *)
                echo "[geo-routing-server] ROUTING_TOKEN must be configured for public file serving" >&2
                exit 1
                ;;
        esac
    fi

    case "$routing_value" in
        *[!A-Za-z0-9_-]*|???|??|?)
            echo "[geo-routing-server] ROUTING_TOKEN must contain at least four characters from A-Z, a-z, 0-9, '_' or '-'" >&2
            exit 1
            ;;
    esac

    printf '%s' "$routing_value"
}

ROUTING_TOKEN_EFFECTIVE="$(resolve_routing_token)"
export ROUTING_TOKEN="$ROUTING_TOKEN_EFFECTIVE"

# Nginx may serve only the current token tree. Old trees remain in the volume
# for recovery but become unreachable after a token rotation.
printf 'location ~ ^/(?!health(?:/|$)|HAPP(?:/|$)|INCY(?:/|$)|%s(?:/|$))[^/]+(?:/|$) { return 404; }\n' \
    "$ROUTING_TOKEN_EFFECTIVE" > /etc/nginx/token-access.conf

cleanup() {
    status="${1:-0}"
    echo "[geo-routing-server] Shutting down cleanly..."
    if [ -n "${CRON_PID:-}" ]; then
        kill -TERM "$CRON_PID" 2>/dev/null || true
    fi
    if [ -n "${NGINX_PID:-}" ]; then
        kill -QUIT "$NGINX_PID" 2>/dev/null || true
    fi
    wait "${CRON_PID:-}" 2>/dev/null || true
    wait "${NGINX_PID:-}" 2>/dev/null || true
    exit "$status"
}
trap 'cleanup 0' SIGTERM SIGINT

# Сохраняем переменные окружения для cron (BusyBox crond запускается с очищенным окружением)
# Права 0600 исключают чтение секретных токенов другими непривилегированными процессами
export -p > /etc/environment.sh
chmod 600 /etc/environment.sh

# Генерация системного скрипта для ручного запуска и cron
cat > /usr/local/bin/run-routing-sync <<'RUNNER'
#!/bin/sh
set -eu
if [ -f /etc/environment.sh ]; then
    . /etc/environment.sh
fi
cd /app
export PYTHONPATH="/app:${PYTHONPATH:-}"
python3 -m app.main
RUNNER

chmod 755 /usr/local/bin/run-routing-sync

# Настройка расписания cron
printf '%s %s\n' "$SCHEDULE" '/usr/local/bin/run-routing-sync' > /etc/crontabs/root

echo "[geo-routing-server] starting internal web server (nginx) on port 80..."
nginx -g 'daemon off;' &
NGINX_PID=$!

echo "[geo-routing-server] container initialized at $(date -u '+%Y-%m-%dT%H:%M:%SZ'); schedule=${SCHEDULE}; timezone=${TZ:-UTC}"

# Выполняем первоначальную синхронизацию при старте контейнера, если включено
if [ "$SYNC_ON_START" = "true" ] || [ "$SYNC_ON_START" = "1" ] || [ "$SYNC_ON_START" = "yes" ]; then
    echo "[geo-routing-server] SYNC_ON_START is enabled, running initial sync now..."
    /usr/local/bin/run-routing-sync || echo "[geo-routing-server] initial sync finished with warning/error (will retry on schedule)"
fi

echo "[geo-routing-server] crond scheduler active, listening for tasks..."
crond -f -l 8 -L /dev/stdout &
CRON_PID=$!

while :; do
    if ! kill -0 "$NGINX_PID" 2>/dev/null; then
        echo "[geo-routing-server] internal nginx process stopped" >&2
        cleanup 1
    fi
    if ! kill -0 "$CRON_PID" 2>/dev/null; then
        echo "[geo-routing-server] crond scheduler stopped" >&2
        cleanup 1
    fi
    sleep 5 &
    wait $! 2>/dev/null || true
done
