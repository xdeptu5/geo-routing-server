<div align="center">

# 🚀 Geo Routing Server

**Автономный сервер для автоматической синхронизации, валидации, модификации и безопасной публикации geo-баз и конфигураций маршрутизации (`HAPP`, `INCY`).**

[![Docker Multi-Arch](https://img.shields.io/badge/docker-amd64%20%7C%20arm64-blue?logo=docker)](https://github.com/xdeptu5/geo-routing-server)
[![GitHub Container Registry](https://img.shields.io/badge/image-ghcr.io%2Fxdeptu5%2Fgeo--routing--server-blue?logo=github)](https://github.com/xdeptu5/geo-routing-server/pkgs/container/geo-routing-server)
[![Python 3.12](https://img.shields.io/badge/python-3.12-yellow?logo=python)](https://www.python.org)
[![Nginx Internal](https://img.shields.io/badge/webserver-nginx%20alpine-green?logo=nginx)](https://nginx.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-orange.svg)](./LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-standard%20library-brightgreen)](https://github.com/xdeptu5/geo-routing-server)

</div>

---

## 📖 Обзор и Архитектура

**Geo Routing Server** решает проблему независимого, быстрого и защищённого обновления правил маршрутизации и geo-баз для мобильных клиентов и VPN-панелей. Контейнер объединяет в себе планировщик фоновых задач и легковесный внутренний веб-сервер, избавляя администратора от ручной настройки прав доступа к папкам на сервере.

```text
 ┌───────────────────────────────────────────────────────────┐
 │   Источники данных:                                       │
 │   • GitHub Репозиторий (JSON-шаблоны)                     │
 │   • jsDelivr / GitHub Releases / Custom URLs              │
 │   • Локальные базы (директория ./custom_geo/)             │
 └─────────────────────────────┬─────────────────────────────┘
                               │  (ETag 304, SHA-256, atomic write)
                               ▼
 ┌───────────────────────────────────────────────────────────┐
 │   Docker Контейнер [ geo-routing-server ]                 │
 │   • Планировщик crond (автообновление по расписанию)      │
 │   • Python-ядро (валидация JSON, подмена URL, DEEPLINK)   │
 │   • Внутренний Nginx (быстрая отдача статики и кэш)       │
 └─────────────────────────────┬─────────────────────────────┘
                               │  (Локальный HTTP: 127.0.0.1:8080)
                               ▼
 ┌───────────────────────────────────────────────────────────┐
 │   Внешний Реверс-Прокси с SSL (HTTPS)                     │
 │   • Caddy / Nginx / Traefik / Cloudflare Tunnel           │
 └─────────────────────────────┬─────────────────────────────┘
                               │  (Защищённый HTTPS-трафик с токеном)
                               ▼
 ┌───────────────────────────────────────────────────────────┐
 │   Клиенты и Панели:                                       │
 │   • HAPP, INCY (мобильные клиенты)                        │
 │   • Remnawave / Marzban / 3x-ui (автороутинг в подписках) │
 └───────────────────────────────────────────────────────────┘
```

---

## ✨ Ключевые возможности

* 📦 **All-in-One автономность**: веб-сервер и планировщик внутри одного образа — никаких проблем с `chmod`, `chown` и `www-data` на хосте.
* 🔒 **Безопасность по умолчанию**: доступ к файлам защищён случайным закрытым URL-токеном (`/<ROUTING_TOKEN>/...`). Трафик изолирован для отдачи через HTTPS.
* 🚀 **Кэширование ETag (304 Not Modified)**: базы скачиваются заново только при реальном обновлении на стороне источника.
* 📁 **Гибкость источников**: поддержка официальных репозиториев, произвольных ссылок или локальных скомпилированных баз (`./custom_geo/`).
* 🤖 **Умные уведомления в Telegram**: мгновенные алерты при сбоях и отчёты о новых базах без ежедневного спама.
* ⚡ **Мгновенный старт (`SYNC_ON_START=true`)**: файлы генерируются сразу при первом запуске контейнера.
* 🛡️ **Zero External Dependencies**: код написан на стандартной библиотеке Python. Сборка занимает 2 секунды.
* 🐳 **Готовый Docker-образ**: доступен в GitHub Container Registry (`ghcr.io/xdeptu5/geo-routing-server:latest`) с поддержкой `linux/amd64` и `linux/arm64`.

---

## 🚀 Быстрый запуск

Вы можете запустить проект **двумя способами**:

### Способ А. Из готового предсобранного образа (Без клонирования репозитория)

1. Создайте папку и файл `compose.yaml`:
   ```yaml
   services:
     geo-routing-server:
       image: ghcr.io/xdeptu5/geo-routing-server:latest
       container_name: geo-routing-server
       restart: unless-stopped
       environment:
         TZ: UTC
         SCHEDULE: "40 8 * * *"
         DOMAIN: "geo.example.com"
         ROUTING_TOKEN: "ВАШ_СЕКРЕТНЫЙ_ТОКЕН"
         SYNC_ON_START: "true"
       ports:
         - "127.0.0.1:8080:80"
       volumes:
         - routing_data:/app/www
         - ./.cache:/app/.cache
         - ./custom_geo:/app/custom_geo:ro

   volumes:
     routing_data:
   ```
2. Запустите:
   ```bash
   docker compose up -d
   ```

---

### Способ Б. Локальная сборка из исходников

1. Клонируйте репозиторий:
   ```bash
   git clone https://github.com/xdeptu5/geo-routing-server.git
   cd geo-routing-server
   ```
2. Создайте файл конфигурации `.env`:
   ```bash
   cp .env.example .env
   ```
   Отредактируйте `.env`, указав ваш публичный домен и токен:
   ```env
   DOMAIN=geo.example.com
   ROUTING_TOKEN=change_me_to_random_secret_token
   HTTP_BIND=127.0.0.1
   HTTP_PORT=8080
   SCHEDULE=40 8 * * *
   SYNC_ON_START=true
   ```
3. Запустите сборку и контейнер:
   ```bash
   docker compose up -d --build
   ```

---

### Получение готовых ссылок
Посмотрите логи контейнера:
```bash
docker compose logs
```
Сразу после запуска контейнер выведет блок со всеми готовыми ссылками и строкой для подписок.

---

## ⚙️ Сводная таблица параметров (`.env`)

| Переменная | По умолчанию | Описание |
| :--- | :--- | :--- |
| `DOMAIN` | `geo.example.com` | Публичный домен (поддомен), на котором настроен ваш HTTPS-прокси |
| `ROUTING_TOKEN` | — | **Обязательно.** Секретный URL-сегмент (`[A-Za-z0-9._-]+`) |
| `HTTP_BIND` | `127.0.0.1` | Локальный интерфейс привязки внутреннего веб-сервера |
| `HTTP_PORT` | `8080` | Локальный порт для проксирования с хоста |
| `SCHEDULE` | `40 8 * * *` | Расписание автообновления в формате cron (UTC) |
| `SYNC_ON_START` | `true` | Выполнять ли синхронизацию сразу при старте контейнера |
| `GEOIP_SOURCE_URL` | *пусто* | Кастомная ссылка на `geoip.dat` (если нужно переопределить) |
| `GEOSITE_SOURCE_URL` | *пусто* | Кастомная ссылка на `geosite.dat` (если нужно переопределить) |
| `ROUTING_SOURCE_REPO` | *официальный* | URL репозитория с шаблонами JSON-конфигов |
| `TELEGRAM_BOT_TOKEN` | *пусто* | Токен бота Telegram для алертов (опционально) |
| `TELEGRAM_CHAT_ID` | *пусто* | ID чата Telegram для получения уведомлений |
| `TELEGRAM_NOTIFY_SUCCESS`| `false` | Присылать отчеты в Telegram при выходе новых версий баз |
| `DOCKER_PROXY_NETWORK` | `proxy_network` | Имя общей Docker-сети при работе прокси в контейнере |

---

## 🌐 Настройка HTTPS Реверс-Прокси

Рекомендуется использовать **отдельный чистый поддомен** (например, `geo.example.com`), чтобы исключить пересечения путей с панелями подписок.

---

### Вариант 1. Caddy на хосте (Быстро и просто)

В `/etc/caddy/Caddyfile` добавьте:

```caddy
geo.example.com {
    reverse_proxy 127.0.0.1:8080
}
```
Примените изменения: `sudo systemctl reload caddy`.

---

### Вариант 2. Nginx на хосте

В конфигурацию вашего виртуального хоста Nginx с SSL добавьте:

```nginx
server {
    server_name geo.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```
Примените изменения: `sudo nginx -t && sudo nginx -s reload`.

---

### Вариант 3. Реверс-прокси в Docker (Caddy, Traefik, NPM)
Если ваш прокси-сервер запущен в соседнем Docker-контейнере:
1. Раскомментируйте блок `networks` в [`compose.yaml`](./compose.yaml).
2. Направьте трафик прямо на имя контейнера:
   * **Caddy**: `reverse_proxy geo-routing-server:80`
   * **Nginx**: `proxy_pass http://geo-routing-server:80;`
   * **Nginx Proxy Manager**: Forward Host: `geo-routing-server`, Forward Port: `80`.

---

## 📱 Интеграция с VPN-панелями (Remnawave, Marzban, 3x-ui)

Чтобы мобильный клиент Incy автоматически получал правила маршрутизации при обновлении подписки, добавьте в настройках вашей панели кастомный заголовок подписки:

* **Имя заголовка (Header Name):** `autorouting`
* **Значение заголовка (Header Value):**
  ```text
  incy://autorouting/onadd/https://geo.example.com/<ROUTING_TOKEN>/INCY/JSONSUB.JSON
  ```

---

## 📁 Кастомные базы и локальные файлы

### Использование собственных локальных файлов
Если вы собираете базы вручную или сторонним генератором, положите готовые файлы в папку `./custom_geo/`:
```text
custom_geo/
├── geoip.dat
└── geosite.dat
```
Сервис автоматически подхватит локальные файлы вместо загрузки из сети, рассчитает для них SHA-256 и опубликует в раздачу.

---

## 🤖 Telegram-уведомления

* 🔴 **Алерты об ошибках (`alert_failure`)**: приходят всегда при возникновении сетевых сбоев, недоступности источников или повреждении файлов.
* 🟢 **Отчеты о новых базах (`notify_changes`)**: при `TELEGRAM_NOTIFY_SUCCESS=true` сообщение отправляется **только при реальном обновлении баз** (при неизменившихся хэшах бот соблюдает тишину).

---

## 🛠️ Управление и полезные команды

* **Принудительно запустить синхронизацию прямо сейчас:**
  ```bash
  docker exec geo-routing-server run-routing-sync
  ```
* **Просмотреть логи работы и готовые ссылки:**
  ```bash
  docker compose logs -f
  ```
* **Проверить статус здоровья контейнера:**
  ```bash
  docker compose ps
  ```
* **Обновить проект до последней версии:**
  ```bash
  git pull && docker compose up -d --build
  ```

---

## ❓ Часто задаваемые вопросы (FAQ)

<details>
<summary><b>1. Безопасно ли хранить токен в .env?</b></summary>
Да, файл <code>.env</code> включён в <code>.gitignore</code> и никогда не попадает в систему контроля версий. Токен используется как Capability URL и защищён HTTPS-шифрованием от перехвата в сети.
</details>

<details>
<summary><b>2. Как связать сервер с Remnawave или Marzban?</b></summary>
Лучше всего выделить отдельный поддомен (например, <code>geo.example.com</code>) и указать сформированную ссылку в заголовке <code>autorouting</code> в панели подписок.
</details>

<details>
<summary><b>3. Как запустить сервис без клонирования репозитория?</b></summary>
Вы можете просто использовать готовый Docker-образ <code>ghcr.io/xdeptu5/geo-routing-server:latest</code> (см. раздел "Быстрый запуск -> Способ А").
</details>

<details>
<summary><b>4. Почему при открытии https://geo.example.com/ возвращается 404?</b></summary>
Это сделано намеренно для безопасности. Без указания корректного секретного токена веб-сервер скрывает структуру файлов от сканеров.
</details>

---

## 📄 Лицензия

Проект распространяется под свободной лицензией [MIT](./LICENSE).
