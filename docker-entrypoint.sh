#!/bin/sh
set -eu

SCHEDULE="${SCHEDULE:-0 10 * * *}"
SYNC_ON_START="${SYNC_ON_START:-true}"

# Правила токена (формат, заглушка из .env.example, режим без раздачи файлов
# HAPP_DEEPLINK) живут в одном месте — Config.get_token(). При ошибке он
# печатает причину в stderr и завершает процесс с кодом 1, а `set -e`
# останавливает контейнер.
ROUTING_TOKEN_EFFECTIVE="$(cd /app && python3 -c 'from app.config import Config; print(Config.get_token())')"
export ROUTING_TOKEN="$ROUTING_TOKEN_EFFECTIVE"

# Nginx may serve only the current token tree. Old trees remain in the volume
# for recovery but become unreachable after a token rotation.
# GEOGAGA/VAHELLAME/HYDRAPONIQUE are the root symlinks for secondary presets
# in multi-preset mode (app/main.py ensure_internal_symlinks); they must stay
# allowed here too, or requests to them get a bare 404 before ever reaching
# nginx-internal.conf's IP-restricted `location ~ ^/(HAPP|INCY|...)/` block.
printf 'location ~ ^/(?!health(?:/|$)|HAPP(?:/|$)|INCY(?:/|$)|GEOGAGA(?:/|$)|VAHELLAME(?:/|$)|HYDRAPONIQUE(?:/|$)|%s(?:/|$))[^/]+(?:/|$) { return 404; }\n' \
    "$ROUTING_TOKEN_EFFECTIVE" > /etc/nginx/token-access.conf

# Пути без токена на публичном порту 80 закрыты (доступны на внутреннем 81).
# Потребители из Docker-сети, которые до v1.7.0 ходили на них по
# порту 80, могут временно вернуть прежнее поведение этим флагом.
case "$(printf '%s' "${INTERNAL_ACCESS_ON_PORT_80:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes)
        echo "[geo-routing-server] WARNING: INTERNAL_ACCESS_ON_PORT_80=true — пути без токена открыты на порту 80 (переходный режим)" >&2
        echo 'include /etc/nginx/snippets/grs-internal-paths.conf;' > /etc/nginx/grs-public-internal-paths.conf
        ;;
    *)
        echo 'return 404;' > /etc/nginx/grs-public-internal-paths.conf
        ;;
esac

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
# Имена сигналов в POSIX sh пишутся без префикса SIG (иначе SC3048).
trap 'cleanup 0' TERM INT

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

# Настройка расписания cron (с перенаправлением вывода в stdout контейнера)
printf '%s %s > /proc/1/fd/1 2>&1\n' "$SCHEDULE" '/usr/local/bin/run-routing-sync' > /etc/crontabs/root

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
