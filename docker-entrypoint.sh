#!/bin/sh
set -eu

: "${SCHEDULE:?SCHEDULE must be set}"
SYNC_ON_START="${SYNC_ON_START:-true}"

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
python3 -m app.main
RUNNER

chmod 755 /usr/local/bin/run-routing-sync

# Настройка расписания cron
printf '%s %s\n' "$SCHEDULE" '/usr/local/bin/run-routing-sync' > /etc/crontabs/root

echo "[geo-routing-server] starting internal web server (nginx) on port 80..."
nginx

echo "[geo-routing-server] container initialized at $(date -u '+%Y-%m-%dT%H:%M:%SZ'); schedule=${SCHEDULE}; timezone=${TZ:-UTC}"

# Выполняем первоначальную синхронизацию при старте контейнера, если включено
if [ "$SYNC_ON_START" = "true" ] || [ "$SYNC_ON_START" = "1" ] || [ "$SYNC_ON_START" = "yes" ]; then
    echo "[geo-routing-server] SYNC_ON_START is enabled, running initial sync now..."
    /usr/local/bin/run-routing-sync || echo "[geo-routing-server] initial sync finished with warning/error (will retry on schedule)"
fi

cleanup() {
    echo "[geo-routing-server] Shutting down cleanly..."
    if [ -n "${CRON_PID:-}" ]; then
        kill -TERM "$CRON_PID" 2>/dev/null || true
    fi
    nginx -s quit 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

echo "[geo-routing-server] crond scheduler active, listening for tasks..."
crond -f -l 8 -L /dev/stdout &
CRON_PID=$!
wait "$CRON_PID"
