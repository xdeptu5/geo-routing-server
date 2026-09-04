<div align="center">

# 🚀 Geo Routing Server

**Self-Hosted сервер для независимой раздачи geo-баз (`geoip.dat`, `geosite.dat`) и правил маршрутизации (`HAPP`, `INCY`) с защитой от блокировок CDN и GitHub.**

[![Docker Multi-Arch](https://img.shields.io/badge/docker-amd64%20%7C%20arm64-blue?logo=docker)](https://github.com/xdeptu5/geo-routing-server)
[![GitHub Container Registry](https://img.shields.io/badge/image-ghcr.io%2Fxdeptu5%2Fgeo--routing--server-blue?logo=github)](https://github.com/xdeptu5/geo-routing-server/pkgs/container/geo-routing-server)
[![Python 3.12](https://img.shields.io/badge/python-3.12-yellow?logo=python)](https://www.python.org)
[![Nginx Internal](https://img.shields.io/badge/webserver-nginx%20alpine-green?logo=nginx)](https://nginx.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-orange.svg)](./LICENSE)
[![Zero Dependencies](https://img.shields.io/badge/dependencies-standard%20library-brightgreen)](https://github.com/xdeptu5/geo-routing-server)

</div>

---

## 📌 Возможности

* 🛡️ **Полная автономность:** базы `geoip.dat`, `geosite.dat` и правила раздаются напрямую с вашего VPS — клиенты не зависят от доступности GitHub или сторонних CDN.
* 📱 **Поддержка Happ и Incy:** генерация Base64-диплинков для Happ (`.DEEPLINK`) и динамических JSON-правил подписки для Incy (`.JSON`).
* ⚡ **Нативная интеграция с Remnawave API:** прямое автообновление правил сквадов без сторонних скриптов (поддерживается до 10+ сквадов и Cloudflare Zero Trust).
* 🔒 **Безопасность:** закрытый доступ по секретному URL-токену (`/<ROUTING_TOKEN>/...`). Без токена сервер не отвечает сканерам.
* 🚀 **ETag-кэширование (304 Not Modified):** базы загружаются только при реальных изменениях у источника.
* 📁 **Гибкость источников:** официальный репозиторий [roscomvpn-routing](https://github.com/hydraponique/roscomvpn-routing), кастомные URL или локальные базы в `./custom_geo/`.
* 🤖 **Telegram-уведомления:** мгновенные алерты об ошибках и отчёты о новых базах (с поддержкой топиков).
* 📦 **Zero Dependencies:** один контейнер (Alpine + Python 3 + Nginx), архитектуры `amd64` и `arm64`.

---

## 📖 Архитектура

```text
 ┌───────────────────────────────────────────────────────────┐
 │   Источники: roscomvpn-routing / Custom URLs / ./custom_geo/│
 └─────────────────────────────┬─────────────────────────────┘
                               │ (ETag 304, SHA-256, atomic write)
                               ▼
 ┌───────────────────────────────────────────────────────────┐
 │   Docker [ geo-routing-server ]                           │
 │   • Планировщик crond (обновление по расписанию)          │
 │   • Python-ядро (подмена URL на локальные, генерация)     │
 │   • Nginx (отдача статики с поддержкой ETag)              │
 │   • Нативная отправка правил в Remnawave API              │
 └─────────────────────────────┬─────────────────────────────┘
                               │ (127.0.0.1:8080 -> HTTPS Прокси)
                               ▼
 ┌───────────────────────────────────────────────────────────┐
 │   Клиенты и Панели:                                       │
 │   • Incy: заголовок подписки autorouting (pull JSON)      │
 │   • Happ: импорт диплинка или автопатч сквада Remnawave   │
 │   • Базы: скачивание geoip.dat / geosite.dat по HTTPS     │
 └───────────────────────────────────────────────────────────┘
```

---

## 🚀 Быстрый запуск

### Способ 1. Автоматический мастер установки (Рекомендуется)

Скрипт настроит Docker, запросит сценарий, домен, токен и выведет готовые конфиги:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xdeptu5/geo-routing-server/main/install.sh)
```

> **Управление:** После установки доступно меню управления командой `geo-server` (или `geoserver`). Повторный запуск скрипта открывает то же меню и никогда не перезаписывает данные без подтверждения.

---

### Способ 2. Запуск через Docker Compose (Ручной / Dockge / Portainer / 1Panel)

1. Создайте `compose.yaml`:
   ```yaml
   services:
     geo-routing-server:
       image: ghcr.io/xdeptu5/geo-routing-server:latest
       container_name: geo-routing-server
       restart: unless-stopped
       env_file:
         - .env
       ports:
         - "127.0.0.1:8080:80"
       volumes:
         - routing_data:/app/www
         - ./.cache:/app/.cache
         - ./custom_geo:/app/custom_geo:ro
       healthcheck:
         test: ["CMD", "curl", "-f", "http://127.0.0.1:80/health"]
         interval: 30s
         timeout: 5s
         retries: 3
         start_period: 10s

   volumes:
     routing_data:
   ```

2. Создайте файл `.env` на основе [`.env.example`](./.env.example):
   ```env
   DOMAIN=geo.example.com
   ROUTING_TOKEN=change_me_to_random_secret_token
   ENABLED_CLIENTS=HAPP,INCY
   HTTP_PORT=8080
   SCHEDULE=0 10 * * *
   SYNC_ON_START=true
   ```

3. Запустите:
   ```bash
   docker compose up -d
   ```

Ссылки и статус отображаются в логах: `docker compose logs`.

---

## 🗺️ Сценарии развертывания

Вся настройка задаётся через переменные в файле `.env`:

### 1. Универсальный сервер раздачи (Pull-модель)
Сервер раздает базы (geoip/geosite) для Happ и Incy, а также JSON-подписку для Incy по HTTPS. Панели (Remnawave, Marzban, 3x-ui) и клиенты забирают файлы по ссылкам:
```env
DOMAIN=geo.example.com
ROUTING_TOKEN=секретный_токен
ENABLED_CLIENTS=HAPP,INCY
```

### 2. Сервер раздачи + синхронизация с Remnawave API для Happ
Всё из Сценария 1 + сервер сам отправляет правила Happ в сквады Remnawave:
```env
DOMAIN=geo.example.com
ROUTING_TOKEN=секретный_токен
ENABLED_CLIENTS=HAPP,INCY
REMNAWAVE_BASE_URL=http://remnawave:3000/api
REMNAWAVE_TOKEN=jwt_токен_администратора
REMNAWAVE_SQUAD_1_UUID=uuid_первого_сквада
REMNAWAVE_SQUAD_1_RULE=JSONSUB.JSON
REMNAWAVE_SQUAD_2_UUID=uuid_второго_сквада
REMNAWAVE_SQUAD_2_RULE=WHITELIST.JSON
```

### 3. Быстрый узел раздачи geo-баз (например, VPS в РФ)
Сервер только раздает файлы `geoip.dat` и `geosite.dat` на максимальной скорости:
```env
DOMAIN=ru-node.example.com
ROUTING_TOKEN=секретный_токен
ENABLED_CLIENTS=HAPP_GEO,INCY_GEO
```

### 4. Контейнер синхронизации Remnawave (базы на внешнем узле)
Работает в Docker на сервере с Remnawave. **Публичный домен и открытые порты не требуются.** Сервер берет базы с гео-узла (Сценарий 3) и передаёт диплинки в сквады Remnawave через API:
```env
ENABLED_CLIENTS=HAPP_DEEPLINK
PUBLIC_GEO_BASE_URL=https://ru-node.example.com/секретный_токен
REMNAWAVE_BASE_URL=http://remnawave:3000/api
REMNAWAVE_TOKEN=jwt_токен_администратора
REMNAWAVE_SQUAD_1_UUID=uuid_сквада
REMNAWAVE_SQUAD_1_RULE=JSONSUB.JSON
```

### 5. Сервер правил Incy (с базами на внешнем узле)
Раздает по HTTPS JSON-правила для Incy, а адреса баз внутри правил ведут на внешний гео-узел:
```env
DOMAIN=geo.example.com
ROUTING_TOKEN=секретный_токен
ENABLED_CLIENTS=INCY
PUBLIC_GEO_BASE_URL=https://ru-node.example.com/секретный_токен
```

---

## 📱 Подключение клиентов

### HAPP
Happ принимает правила через Base64-диплинк `happ://routing/onadd/<base64>`.
* **С Remnawave:** правила обновляются в сквадах автоматически через API (Сценарии 2 и 4).
* **Вручную / другие панели:** скопируйте ссылку на сгенерированный файл:
  ```text
  https://<DOMAIN>/<ROUTING_TOKEN>/HAPP/<RULE>.DEEPLINK
  ```
  Примеры:
  * `https://geo.example.com/<ROUTING_TOKEN>/HAPP/JSONSUB.DEEPLINK`
  * `https://geo.example.com/<ROUTING_TOKEN>/HAPP/WHITELIST.DEEPLINK`

### INCY
Клиент Incy динамически скачивает JSON-правила по HTTPS. В панели (Remnawave, Marzban, 3x-ui) добавьте заголовок профиля подписки:
* **Header Name:** `autorouting`
* **Header Value:**
  ```text
  incy://autorouting/onadd/https://<DOMAIN>/<ROUTING_TOKEN>/INCY/<RULE>.JSON
  ```
  Примеры:
  * `incy://autorouting/onadd/https://geo.example.com/<ROUTING_TOKEN>/INCY/JSONSUB.JSON`
  * `incy://autorouting/onadd/https://geo.example.com/<ROUTING_TOKEN>/INCY/WHITELIST.JSON`

---

## ⚙️ Сводная таблица параметров (`.env`)

| Переменная | По умолчанию | Описание |
| :--- | :--- | :--- |
| `DOMAIN` | `geo.example.com` | Домен для HTTPS-прокси (не нужен в режиме `HAPP_DEEPLINK`) |
| `ROUTING_TOKEN` | — | **Обязательно** для раздачи файлов (`[A-Za-z0-9._-]+`) |
| `ENABLED_CLIENTS` | `HAPP,INCY` | Модули: `HAPP,INCY`, `HAPP`, `INCY`, `HAPP_GEO`, `INCY_GEO`, `HAPP_DEEPLINK` |
| `PUBLIC_GEO_BASE_URL` | *пусто* | Внешний URL баз (`https://geo-node.example.com/<token>`) |
| `HTTP_BIND` | `127.0.0.1` | IP привязки внутреннего веб-сервера |
| `HTTP_PORT` | `8080` | Порт для реверс-прокси |
| `SCHEDULE` | `0 10 * * *` | Расписание автообновления (cron UTC, дефолт 10:00 UTC) |
| `SYNC_ON_START` | `true` | Выполнять синхронизацию при запуске контейнера |
| `GEOIP_SOURCE_URL` | *пусто* | Кастомный источник `geoip.dat` |
| `GEOSITE_SOURCE_URL` | *пусто* | Кастомный источник `geosite.dat` |
| `ROUTING_SOURCE_REPO` | *roscomvpn* | Репозиторий правил GitHub |
| **Telegram** | | |
| `TELEGRAM_BOT_TOKEN` | *пусто* | Токен бота Telegram для алертов |
| `TELEGRAM_CHAT_ID` | *пусто* | ID чата / группы |
| `TELEGRAM_THREAD_ID` | *пусто* | ID темы/топика в супергруппе |
| `TELEGRAM_NOTIFY_SUCCESS`| `false` | Уведомлять при каждом успешном обновлении |
| **Remnawave API** | | |
| `REMNAWAVE_BASE_URL` | *пусто* | URL API панели (например, `http://remnawave:3000/api`) |
| `REMNAWAVE_TOKEN` | *пусто* | JWT-токен администратора панели |
| `REMNAWAVE_SQUAD_N_UUID` | *пусто* | UUID сквада N (N = 1..10+) |
| `REMNAWAVE_SQUAD_N_RULE` | `JSONSUB.JSON` | Имя правила для сквада N (`JSONSUB.JSON`, `WHITELIST.JSON`) |
| `REMNAWAVE_GLOBAL_RULE` | *пусто* | Глобальное правило для всех подписок |
| `CLOUDFLARE_ZERO_TRUST_CLIENT_ID` | *пусто* | Client ID сервисного токена Cloudflare Zero Trust |
| `CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET` | *пусто* | Client Secret сервисного токена Cloudflare Zero Trust |

---

## 🌐 Настройка HTTPS Реверс-Прокси

Выделите поддомен (например, `geo.example.com`). При установке через скрипт готовый блок генерируется автоматически (пункт меню 3).

**Caddy:**
```caddy
geo.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

**Nginx:**
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

---

## 🛠️ Управление и команды

| Действие | Команда | Описание |
|---|---|---|
| **Главное меню** | `geo-server` *(или `geoserver`)* | Интерактивное управление, смена параметров, логи |
| **Принудительная синхронизация** | `docker exec geo-routing-server run-routing-sync` | Запуск немедленного обновления |
| **Просмотр логов** | `docker compose logs -f` | Мониторинг в реальном времени |
| **Обновление образа** | `docker compose pull && docker compose up -d` | Загрузка свежей версии контейнера |
| **Статус** | `docker compose ps` | Проверка работы контейнера |

> 📁 **Кастомные базы:** Локальные файлы `geoip.dat` и `geosite.dat` можно положить в папку `./custom_geo/` — сервер подхватит их автоматически вместо загрузки из сети.

---

## ❓ FAQ

<details>
<summary><b>Почему при переходе на https://geo.example.com/ возвращается 404?</b></summary>
Это защита от автоматических сканеров: без секретного токена сервер скрывает дерево файлов. Доступ работает только по полному пути: <code>https://geo.example.com/&lt;ROUTING_TOKEN&gt;/...</code>
</details>

<details>
<summary><b>Что будет при повторном запуске install.sh?</b></summary>
Скрипт определит существующую установку и откроет меню <code>geo-server</code>. Конфигурация и данные никогда не перезаписываются без явного подтверждения.
</details>

---

## 💎 Поддержать проект (Donations)

* **USDT / TRX (TRC20):** `TKw6b3ZszCM2983sLuFAvqxtt2M8hpNW51`
* **TON:** `UQB19xcTuQ1jFEq0Pi3xaABnN8JaGEXAeuGa2rXFRUUdi8Nk`
* **USDT / BNB (BEP20):** `0xFdc848534deA4f010c95df92045ABDa5f6a1559b`

---

## 📄 Лицензия

Распространяется под свободной лицензией [MIT](./LICENSE).