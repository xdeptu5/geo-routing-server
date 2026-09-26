FROM alpine:3.21

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

# Пакеты только те, что нужны в рантайме: python3 — приложение, nginx —
# раздача, ca-certificates — HTTPS к API Remnawave. curl в образе не нужен
# (healthcheck использует встроенный busybox wget, install.sh работает на хосте).
RUN apk add --no-cache \
    python3 \
    nginx \
    ca-certificates

WORKDIR /app

# Настройка встроенного Nginx и перенаправление логов в stdout/stderr
COPY nginx-internal.conf /etc/nginx/http.d/default.conf
RUN mkdir -p /app/www /app/.cache /app/custom_geo /run/nginx /var/log/nginx && \
    chown -R root:nginx /app/www /run/nginx /var/log/nginx && \
    chmod 755 /app/www /run/nginx /var/log/nginx && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Копирование исходного кода приложения
COPY app /app/app

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:80/health || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
