FROM alpine:3.21

RUN apk add --no-cache \
    python3 \
    nginx \
    ca-certificates \
    curl

WORKDIR /app

# Настройка встроенного Nginx и перенаправление логов в stdout/stderr
COPY nginx-internal.conf /etc/nginx/http.d/default.conf
RUN mkdir -p /app/www /app/.cache /app/custom_geo /run/nginx /var/log/nginx && \
    ln -sf /dev/stdout /var/log/nginx/access.log && \
    ln -sf /dev/stderr /var/log/nginx/error.log

# Копирование исходного кода приложения
COPY app /app/app

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod 755 /usr/local/bin/docker-entrypoint.sh

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -f http://127.0.0.1:80/health || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
