#!/bin/sh
set -eu

: "${SCHEDULE:?SCHEDULE must be set}"
SYNC_ON_START="${SYNC_ON_START:-true}"

# Генерация системного скрипта для ручного запуска и cron
cat > /usr/local/bin/run-routing-sync <<'RUNNER'
#!/bin/sh
set -eu
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

echo "[geo-routing-server] crond scheduler active, listening for tasks..."
exec crond -f -l 8 -L /dev/stdout
