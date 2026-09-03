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
 │   • Правила маршрутизации: hydraponique/roscomvpn-routing │
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

* 📦 **All-in-One**: веб-сервер и планировщик внутри одного образа — никаких проблем с правами доступа `chmod`/`chown`.
* 🔒 **Безопасность по умолчанию**: доступ защищён секретным URL-токеном (`/<ROUTING_TOKEN>/...`), трафик через HTTPS.
* ⚡ **Нативная интеграция с Remnawave**: мгновенный патч правил сквадов напрямую в API панели — без сторонних контейнеров-апдейтеров.
* 🚀 **ETag-кэширование (304 Not Modified)**: базы скачиваются только при реальном обновлении на стороне источников.
* 📁 **Гибкость источников**: официальные репозитории, произвольные URL или локальные базы (`./custom_geo/`).
* 🤖 **Telegram-уведомления**: мгновенные алерты при сбоях и отчёты о новых базах (с поддержкой тем/топиков в супергруппах).
* 🛡️ **Zero Dependencies**: написан исключительно на стандартной библиотеке Python 3.
* 🐳 **Multi-arch образ**: `ghcr.io/xdeptu5/geo-routing-server:latest` (`linux/amd64` + `linux/arm64`).

---

## 🚀 Быстрый запуск

### Способ 1. Автоматическая установка и менеджер (Интерактивный мастер)

Универсальный скрипт установки и управления. Проверит Docker, спросит режим работы, домен, токен, Telegram, настроит прямую интеграцию с Remnawave и выдаст готовые конфиги прокси:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh)
```

> **Совет:** После установки вы в любой момент можете вызвать удобное интерактивное меню управления сервером командой:
> ```bash
> geo-server
> ```
> *(или `geoserver`). Повторный запуск скрипта установки также откроет меню управления и никогда не перезапишет ваши данные без подтверждения.*

---

### Способ 2. Запуск через Docker Compose (Arcane / Portainer / Dockge / 1Panel)

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

### Способ 3. Локальная сборка из исходников (Для разработчиков)

```bash
git clone https://github.com/xdeptu5/geo-routing-server.git
cd geo-routing-server
cp .env.example .env   # отредактируйте домен и токен
docker compose up -d --build
```

После запуска посмотрите готовые ссылки и статус: `docker compose logs`

---

## ⚙️ Сводная таблица параметров (`.env`)

| Переменная | По умолчанию | Описание |
| :--- | :--- | :--- |
| `DOMAIN` | `geo.example.com` | Публичный домен для HTTPS-прокси |
| `ROUTING_TOKEN` | — | **Обязательно.** Секретный URL-сегмент (`[A-Za-z0-9._-]+`) |
| `ENABLED_CLIENTS` | `HAPP,INCY` | Активные модули: `HAPP` (полный), `HAPP_DEEPLINK` (только Remnawave), `HAPP_GEO` (только базы), `INCY` |
| `PUBLIC_GEO_BASE_URL` | *пусто* | Внешний URL к гео-базам (если базы отдаются с другого сервера) |
| `HTTP_BIND` | `127.0.0.1` | Локальный интерфейс привязки внутреннего веб-сервера |
| `HTTP_PORT` | `8080` | Локальный порт для проксирования с хоста |
| `SCHEDULE` | `40 8 * * *` | Расписание автообновления в формате cron (UTC) |
| `SYNC_ON_START` | `true` | Выполнять ли синхронизацию сразу при старте контейнера |
| `GEOIP_SOURCE_URL` | *пусто* | Кастомная ссылка на `geoip.dat` (переопределяет источник) |
| `GEOSITE_SOURCE_URL` | *пусто* | Кастомная ссылка на `geosite.dat` (переопределяет источник) |
| `ROUTING_SOURCE_REPO` | *официальный* | URL репозитория с исходными JSON-шаблонами правил |
| **Telegram** | | |
| `TELEGRAM_BOT_TOKEN` | *пусто* | Токен бота Telegram для алертов (опционально) |
| `TELEGRAM_CHAT_ID` | *пусто* | ID чата / группы для получения уведомлений |
| `TELEGRAM_THREAD_ID` | *пусто* | ID темы / топика в супергруппе с включёнными темами |
| `TELEGRAM_NOTIFY_SUCCESS`| `false` | Присылать отчёт в Telegram при выходе обновлённых баз |
| **Remnawave API** | | |
| `REMNAWAVE_BASE_URL` | *пусто* | URL API панели Remnawave (например, `http://remnawave:3000/api`) |
| `REMNAWAVE_TOKEN` | *пусто* | JWT-токен администратора из настроек панели Remnawave |
| `REMNAWAVE_SQUAD_N_UUID` | *пусто* | UUID сквада N (N = 1, 2, 3…) для автоматического патча |
| `REMNAWAVE_SQUAD_N_RULE` | `JSONSUB.JSON` | Имя JSON-правила для сквада N (`JSONSUB.JSON`, `WHITELIST.JSON`) |
| `REMNAWAVE_GLOBAL_RULE` | *пусто* | Глобальное правило для всех подписок панели (опционально) |
| `CLOUDFLARE_ZERO_TRUST_CLIENT_ID` | *пусто* | Client ID сервисного токена Cloudflare Zero Trust (если панель за туннелем) |
| `CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET` | *пусто* | Client Secret сервисного токена Cloudflare Zero Trust |

---

## 📱 Интеграция с VPN-панелями

### 1. HAPP / Remnawave (Нативная интеграция)

Сервер **напрямую отправляет** свежие правила в API Remnawave в момент обновления баз — без задержек и без сторонних апдейтеров. Поддерживаются как локальные панели внутри Docker-сети, так и удалённые панели за **Cloudflare Zero Trust Tunnel**.

В `.env` укажите URL панели, токен и UUID сквадов:
```env
REMNAWAVE_BASE_URL=https://remna.example.com/api
REMNAWAVE_TOKEN=ваш_jwt_токен_из_панели

# (Опционально) Если панель находится на другом сервере за Cloudflare Access / Zero Trust:
# CLOUDFLARE_ZERO_TRUST_CLIENT_ID=ef901e38c8f40a4f1eb83fb9a66898e3.access
# CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET=73ad856d7639e0e77bc757c08a8c95781...

# Привязка правил к сквадам (группам пользователей):
REMNAWAVE_SQUAD_1_UUID=23c97b42-289d-490a-ad73-bd17ab426657
REMNAWAVE_SQUAD_1_RULE=JSONSUB.JSON

REMNAWAVE_SQUAD_2_UUID=aae87204-e36a-41cb-8f7c-485742bf556c
REMNAWAVE_SQUAD_2_RULE=WHITELIST.JSON
```

> **Альтернатива:** Если вы используете сторонний [Remnawave-Routing-update](https://github.com/lifeindarkside/Remnawave-Routing-update), направьте его на локальные ссылки: `SQUAD_1_URL=http://geo-routing-server/HAPP/JSONSUB.DEEPLINK`

### 2. INCY (Автороутинг в заголовке подписки)

В настройках панели (Remnawave / Marzban / 3x-ui) добавьте заголовок:

* **Header Name:** `autorouting`
* **Header Value:**
  ```text
  incy://autorouting/onadd/https://geo.example.com/<ROUTING_TOKEN>/INCY/JSONSUB.JSON
  ```

---

## 🌐 Настройка HTTPS Реверс-Прокси

Рекомендуется выделить **отдельный поддомен** (например, `geo.example.com`). После установки команда `geo-server` (пункт 3) сгенерирует готовые блоки конфигураций.

<details>
<summary><b>Caddy на хосте</b></summary>

```caddy
geo.example.com {
    reverse_proxy 127.0.0.1:8080
}
```
Примените изменения: `sudo systemctl reload caddy`
</details>

<details>
<summary><b>Nginx на хосте</b></summary>

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
Примените изменения: `sudo nginx -t && sudo nginx -s reload`
</details>

<details>
<summary><b>Nginx Proxy Manager / Контейнерный прокси</b></summary>

* **NPM (GUI):** Forward Host `127.0.0.1`, Forward Port `8080`, SSL → Force SSL: ON.
* **Caddy в Docker:** `reverse_proxy geo-routing-server:80` (подключите оба контейнера к одной Docker-сети).
* **Nginx в Docker:** `proxy_pass http://geo-routing-server:80;`
</details>

---

## 🛠️ Управление и полезные команды

| Действие | Команда | Описание |
|---|---|---|
| **Главное меню управления** | `geo-server` *(или `geoserver`)* | Интерактивное меню настройки, логов и синхронизации |
| **Синхронизация баз вручную** | `docker exec geo-routing-server run-routing-sync` | Принудительное немедленное обновление |
| **Просмотр логов** | `docker compose logs -f` | Мониторинг работы в реальном времени |
| **Обновление образа** | `docker compose pull && docker compose up -d` | Скачивание и запуск свежей версии контейнера |
| **Статус контейнера** | `docker compose ps` | Проверка здоровья (healthcheck) |

> 📁 **Кастомные базы:** Собственные локальные файлы можно положить в папку `./custom_geo/` (`geoip.dat`, `geosite.dat`) — сервер автоматически подхватит их и рассчитает SHA-256 вместо загрузки из сети.

---

## ❓ Часто задаваемые вопросы (FAQ)

<details>
<summary><b>Безопасно ли хранить токен в .env?</b></summary>
Да. Файл <code>.env</code> добавлен в <code>.gitignore</code> и никогда не попадёт в git. Токен работает как закрытый Capability URL и передаётся по защищённому HTTPS.
</details>

<details>
<summary><b>Что произойдёт при повторном запуске install.sh?</b></summary>
Скрипт автоматически определит существующую установку, откроет интерактивное меню <code>geo-server</code> и <b>никогда не перезапишет конфигурации</b>. Если вы захотите изменить параметры (домен, порт, сквады Remnawave), выберите пункт <i>«6) Перенастроить сервер заново»</i> — скрипт сохранит текущие значения как подсказки по умолчанию.
</details>

<details>
<summary><b>Как связать сервер с Remnawave?</b></summary>
Укажите <code>REMNAWAVE_BASE_URL</code> и <code>REMNAWAVE_TOKEN</code> в <code>.env</code> — сервер будет автоматически отправлять свежие диплинки в сквады сразу после обновления баз (см. раздел «Интеграция с VPN-панелями»).
</details>

<details>
<summary><b>Как запустить без клонирования репозитория?</b></summary>
Используйте официальный образ <code>ghcr.io/xdeptu5/geo-routing-server:latest</code> (см. Способ 2 в разделе «Быстрый запуск»).
</details>

<details>
<summary><b>Почему при открытии https://geo.example.com/ возвращается 404?</b></summary>
Это сделано намеренно для безопасности: без указания секретного URL-токена сервер скрывает список файлов от автоматических сканеров.
</details>

---

## 💎 Поддержать проект (Donations)

Если проект оказался для вас полезным, вы можете поддержать его дальнейшую разработку:

### 🪙 USDT / TRX (Tron — TRC20)
```text
TKw6b3ZszCM2983sLuFAvqxtt2M8hpNW51
```

### 💎 TON (The Open Network)
```text
UQB19xcTuQ1jFEq0Pi3xaABnN8JaGEXAeuGa2rXFRUUdi8Nk
```

### 🟡 USDT / BNB (BNB Smart Chain — BEP20)
```text
0xFdc848534deA4f010c95df92045ABDa5f6a1559b
```

---

## 📄 Лицензия

Проект распространяется под свободной лицензией [MIT](./LICENSE).
