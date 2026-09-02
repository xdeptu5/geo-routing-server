<div align="center">

# 🚀 Geo Routing Server

**Self-Hosted сервер для независимой раздачи, автообновления и публикации geo-баз и правил маршрутизации (`HAPP`, `INCY`) с вашего собственного сервера.**

[![Docker Multi-Arch](https://img.shields.io/badge/docker-amd64%20%7C%20arm64-blue?logo=docker)](https://github.com/xdeptu5/geo-routing-server)
[![GitHub Container Registry](https://img.shields.io/badge/image-ghcr.io%2Fxdeptu5%2Fgeo--routing--server-blue?logo=github)](https://github.com/xdeptu5/geo-routing-server/pkgs/container/geo-routing-server)
[![Python 3.12](https://img.shields.io/badge/python-3.12-yellow?logo=python)](https://www.python.org)
[![Nginx Internal](https://img.shields.io/badge/webserver-nginx%20alpine-green?logo=nginx)](https://nginx.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-orange.svg)](./LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-standard%20library-brightgreen)](https://github.com/xdeptu5/geo-routing-server)

</div>

---

## 🎯 Зачем нужен этот проект?

Когда мобильные клиенты (Happ, Incy) или VPN-панели скачивают гео-базы и конфиги маршрутизации напрямую из публичных репозиториев GitHub или CDN, они регулярно сталкиваются с **блокировками провайдеров, замедлениями и сбоями доступности**.

**Geo Routing Server** превращает ваш VPS в **собственный независимый сервер раздачи geo-файлов (Self-Hosted Geo Hub)**:
* 🛡️ **Полная независимость**: Все базы `geoip.dat`, `geosite.dat`, правила и диплинки раздаются напрямую с **вашего собственного сервера и домена**.
* ⚡ **Стабильность 24/7**: Клиенты пользователей получают обновления напрямую от вас — без риска блокировок CDN или публичного GitHub.
* 🔒 **Контроль и безопасность**: Доступ к раздаче защищён персональным URL-токеном, а внутренние сервисы (например, Remnawave) могут забирать диплинки локально через Docker-сеть.

---

## 📖 Архитектура

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
 │   • Нативная интеграция с Remnawave API (автопатч сквадов)│
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

* 📦 **All-in-One**: веб-сервер и планировщик внутри одного образа — никаких `chmod`, `chown` и `www-data`.
* 🔒 **Безопасность по умолчанию**: доступ защищён секретным URL-токеном (`/<ROUTING_TOKEN>/...`), трафик через HTTPS.
* ⚡ **Нативная интеграция с Remnawave**: автоматический патч правил сквадов напрямую в API панели — без сторонних контейнеров-апдейтеров.
* 🚀 **ETag-кэширование (304 Not Modified)**: базы скачиваются только при реальном обновлении.
* 📁 **Гибкость источников**: официальные репозитории, произвольные URL или локальные базы (`./custom_geo/`).
* 🤖 **Telegram-уведомления**: алерты при сбоях и отчёты о новых базах (без ежедневного спама).
* 🛡️ **Zero Dependencies**: только стандартная библиотека Python, сборка за 2 секунды.
* 🐳 **Multi-arch образ**: `ghcr.io/xdeptu5/geo-routing-server:latest` (`linux/amd64` + `linux/arm64`).

---

## 🚀 Быстрый запуск

### Способ 1. Автоматическая установка (Интерактивный мастер)

Скрипт проверит Docker, спросит режим работы, домен, токен, Telegram, интеграцию с Remnawave и покажет готовые конфиги для прокси:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh)
```

> **Совет:** После установки вызывайте меню управления командой:
> ```bash
> geo-server
> ```

---

### Способ 2. Запуск через панели (Arcane / Portainer / Dockge / 1Panel) или вручную

1. Создайте `compose.yaml`:
   ```yaml
   services:
     geo-routing-server:
       image: ghcr.io/xdeptu5/geo-routing-server:latest
       container_name: geo-routing-server
       restart: unless-stopped
       environment:
         DOMAIN: "geo.example.com"
         ROUTING_TOKEN: "ВАШ_СЕКРЕТНЫЙ_ТОКЕН"
         ENABLED_CLIENTS: "HAPP,INCY"
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
2. Запустите: `docker compose up -d`

---

### Способ 3. Локальная сборка из исходников

```bash
git clone https://github.com/xdeptu5/geo-routing-server.git
cd geo-routing-server
cp .env.example .env   # отредактируйте домен и токен
docker compose up -d --build
```

После запуска посмотрите готовые ссылки: `docker compose logs`

---

## ⚙️ Сводная таблица параметров (`.env`)

| Переменная | По умолчанию | Описание |
| :--- | :--- | :--- |
| `DOMAIN` | `geo.example.com` | Публичный домен для HTTPS-прокси |
| `ROUTING_TOKEN` | — | **Обязательно.** Секретный URL-сегмент (`[A-Za-z0-9._-]+`) |
| `ENABLED_CLIENTS` | `HAPP,INCY` | Активные модули: `HAPP` (полный), `HAPP_DEEPLINK` (только Remnawave), `HAPP_GEO` (только базы), `INCY` |
| `PUBLIC_GEO_BASE_URL` | *пусто* | Внешний URL к гео-базам (если базы на другом сервере) |
| `HTTP_BIND` | `127.0.0.1` | Локальный интерфейс привязки |
| `HTTP_PORT` | `8080` | Локальный порт для проксирования |
| `SCHEDULE` | `40 8 * * *` | Расписание автообновления (cron, UTC) |
| `SYNC_ON_START` | `true` | Синхронизация при старте контейнера |
| `GEOIP_SOURCE_URL` | *пусто* | Кастомная ссылка на `geoip.dat` |
| `GEOSITE_SOURCE_URL` | *пусто* | Кастомная ссылка на `geosite.dat` |
| `ROUTING_SOURCE_REPO` | *официальный* | URL репозитория с JSON-шаблонами |
| **Telegram** | | |
| `TELEGRAM_BOT_TOKEN` | *пусто* | Токен бота для алертов |
| `TELEGRAM_CHAT_ID` | *пусто* | ID чата / группы |
| `TELEGRAM_THREAD_ID` | *пусто* | ID темы в супергруппе |
| `TELEGRAM_NOTIFY_SUCCESS`| `false` | Отчёты при выходе новых баз |
| **Remnawave API** | | |
| `REMNAWAVE_BASE_URL` | *пусто* | URL API панели (например, `http://remnawave:3000/api`) |
| `REMNAWAVE_TOKEN` | *пусто* | JWT-токен администратора |
| `REMNAWAVE_SQUAD_N_UUID` | *пусто* | UUID сквада N для автопатча правил |
| `REMNAWAVE_SQUAD_N_RULE` | `JSONSUB.JSON` | JSON-правило для сквада N |
| `REMNAWAVE_GLOBAL_RULE` | *пусто* | Глобальное правило для всех подписок |

---

## 📱 Интеграция с VPN-панелями

### HAPP / Remnawave (Нативная интеграция)

Сервер **напрямую отправляет** свежие правила в API Remnawave в момент обновления баз — без сторонних контейнеров и задержек.

В `.env` укажите URL панели, токен и UUID сквадов:
```env
REMNAWAVE_BASE_URL=http://remnawave:3000/api
REMNAWAVE_TOKEN=ваш_jwt_токен_из_панели

REMNAWAVE_SQUAD_1_UUID=23c97b42-289d-490a-ad73-bd17ab426657
REMNAWAVE_SQUAD_1_RULE=JSONSUB.JSON

REMNAWAVE_SQUAD_2_UUID=aae87204-e36a-41cb-8f7c-485742bf556c
REMNAWAVE_SQUAD_2_RULE=WHITELIST.JSON
```

> **Альтернатива:** Если используете [Remnawave-Routing-update](https://github.com/lifeindarkside/Remnawave-Routing-update), направьте его на `SQUAD_1_URL=http://geo-routing-server/HAPP/JSONSUB.DEEPLINK`

### INCY (Автороутинг в заголовке подписки)

В настройках панели (Remnawave / Marzban / 3x-ui) добавьте заголовок:

* **Header Name:** `autorouting`
* **Header Value:** `incy://autorouting/onadd/https://geo.example.com/<ROUTING_TOKEN>/INCY/JSONSUB.JSON`

---

## 🌐 Настройка HTTPS Реверс-Прокси

Рекомендуется **отдельный поддомен** (например, `geo.example.com`). После установки команда `geo-server` → пункт 3 покажет готовые конфиги.

<details>
<summary><b>Caddy</b></summary>

```caddy
geo.example.com {
    reverse_proxy 127.0.0.1:8080
}
```
`sudo systemctl reload caddy`
</details>

<details>
<summary><b>Nginx</b></summary>

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
`sudo nginx -t && sudo nginx -s reload`
</details>

<details>
<summary><b>Nginx Proxy Manager / Docker-прокси</b></summary>

* **NPM (GUI):** Forward Host `127.0.0.1`, Forward Port `8080`, SSL → Force SSL: ON.
* **Caddy в Docker:** `reverse_proxy geo-routing-server:80` (подключите оба контейнера к общей сети).
* **Nginx в Docker:** `proxy_pass http://geo-routing-server:80;`
</details>

---

## 🛠️ Управление

| Действие | Команда |
|---|---|
| Интерактивное меню | `geo-server` |
| Принудительная синхронизация | `docker exec geo-routing-server run-routing-sync` |
| Просмотр логов | `docker compose logs -f` |
| Обновление до последней версии | `docker compose pull && docker compose up -d` |
| Статус контейнера | `docker compose ps` |

Собственные локальные базы можно положить в `./custom_geo/` (`geoip.dat`, `geosite.dat`) — сервер подхватит их автоматически вместо загрузки из сети.

---

## ❓ FAQ

<details>
<summary><b>Безопасно ли хранить токен в .env?</b></summary>
Да. Файл <code>.env</code> включён в <code>.gitignore</code> и не попадает в git. Токен используется как Capability URL и защищён HTTPS.
</details>

<details>
<summary><b>Как связать сервер с Remnawave?</b></summary>
Укажите <code>REMNAWAVE_BASE_URL</code> и <code>REMNAWAVE_TOKEN</code> в <code>.env</code> — сервер будет автоматически патчить правила сквадов при каждом обновлении баз (см. раздел «Интеграция с VPN-панелями»).
</details>

<details>
<summary><b>Как запустить без клонирования репозитория?</b></summary>
Используйте готовый образ <code>ghcr.io/xdeptu5/geo-routing-server:latest</code> (см. Способ 2 в «Быстрый запуск»).
</details>

<details>
<summary><b>Почему https://geo.example.com/ возвращает 404?</b></summary>
Намеренно: без секретного токена в URL веб-сервер скрывает файлы от сканеров.
</details>

---

## 📄 Лицензия

[MIT](./LICENSE)
