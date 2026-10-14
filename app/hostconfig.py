"""Мастер установки и разделы настроек, которые правят .env на хосте.

Запускается install.sh в разовом контейнере, куда каталог установки смонтирован
в /host. Контейнер не может сам применить изменения (пересоздать себя), поэтому
контракт с хостом такой:

* код возврата 0   — пользователь вышел из раздела, ничего применять не нужно;
* код возврата 100 (APPLY) — изменения сохранены: хост выполняет
  `docker compose up -d` и открывает раздел снова;
* прочие коды — ошибка или отмена.

Сведения о хосте, которых нет внутри контейнера, install.sh передаёт через
переменные окружения GRS_HOST_NETWORKS (Docker-сети через запятую) и
GRS_HOST_PORTS (занятые TCP-порты через запятую).
"""

import os
from pathlib import Path
from typing import Callable, Dict, List, Optional, Set, Tuple

from app import composefile
from app.envfile import EnvFile
from app.ui import Cancelled, Colors, ask, confirm, pause, supports_color
from app.validators import (
    DEFAULT_SCHEDULE,
    generate_token,
    human_schedule,
    is_valid_cron,
    is_valid_docker_network,
    is_valid_domain,
    is_valid_token,
    normalize_domain,
    normalize_public_url,
    normalize_remnawave_url,
    parse_port,
    schedule_every_hours,
    schedule_from_time,
)

APPLY = 100

CLIENT_CHOICES: List[Tuple[str, str]] = [
    ("HAPP,INCY", "Happ и Incy (рекомендуется)"),
    ("HAPP", "Только Happ"),
    ("INCY", "Только Incy"),
    ("HAPP_DEEPLINK", "Только обновление сквадов Remnawave (базы на внешнем узле)"),
]

# (значение ROUTING_SOURCE_PRESET, ROUTING_RULES по умолчанию, подпись)
PRESET_CHOICES: List[Tuple[str, str, str]] = [
    ("geogaga", "HAPP", "GeoGaga — сбалансированная маршрутизация для РФ (рекомендуется)"),
    ("hydraponique", "JSONSUB,WHITELIST", "hydraponique — классический набор DEFAULT/JSONSUB/WHITELIST"),
    ("vahellame", "WHITELIST", "vahellame — строгий белый список"),
    ("hydraponique,geogaga", "JSONSUB,WHITELIST", "Мульти-пресет: hydraponique + geogaga одновременно"),
]

FORMAT_CHOICES: List[Tuple[str, str]] = [
    ("CLIENT_OPTIMIZED", "Happ — .DEEPLINK, Incy — .JSON (рекомендуется)"),
    ("ALL", "Оба формата для обоих клиентов"),
    ("JSON", "Только .JSON"),
    ("DEEPLINK", "Только .DEEPLINK"),
]

# Ключи, которые мастер задаёт сам; остальные переносятся из прежнего .env как есть.
WIZARD_KEYS = (
    "DOMAIN", "ROUTING_TOKEN", "ENABLED_CLIENTS", "ROUTING_SOURCE_PRESET",
    "ROUTING_RULES", "SERVE_FORMATS", "SERVE_GEOIP", "SERVE_GEOSITE",
    "PUBLIC_GEO_BASE_URL", "HTTP_BIND", "HTTP_PORT", "SCHEDULE", "SYNC_ON_START",
    "REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN", "DOCKER_NETWORK",
)


class HostContext:
    def __init__(self, host_dir: Path, image: Optional[str] = None):
        self.host_dir = Path(host_dir)
        self.env = EnvFile(self.host_dir / ".env")
        self.image = image or composefile.current_image(self.host_dir) or composefile.DEFAULT_IMAGE
        self.c = Colors(supports_color())
        self.networks = _split_env_list("GRS_HOST_NETWORKS")
        ports = _split_env_list("GRS_HOST_PORTS") or set()
        self.busy_ports = {int(p) for p in ports if p.isdigit()}

    def network_known(self, name: str) -> Optional[bool]:
        """True/False, если список сетей хоста передан; None — неизвестно."""
        return None if self.networks is None else name in self.networks

    def header(self, title: str) -> None:
        c = self.c
        print(f"\n{c.CYAN}{'─' * 56}{c.RESET}")
        print(f"{c.BOLD}{c.WHITE}{title}{c.RESET}")
        print(f"{c.CYAN}{'─' * 56}{c.RESET}")

    def ok(self, text: str) -> None:
        print(f"{self.c.GREEN}[✓] {text}{self.c.RESET}")

    def warn(self, text: str) -> None:
        print(f"{self.c.YELLOW}[!] {text}{self.c.RESET}")

    def err(self, text: str) -> None:
        print(f"{self.c.RED}[!] {text}{self.c.RESET}")


def _split_env_list(name: str) -> Optional[Set[str]]:
    raw = os.getenv(name)
    if raw is None:
        return None
    return {item.strip() for item in raw.split(",") if item.strip()}


def _choose(ctx: HostContext, options: List[str], default: int, allow_back: bool = True) -> Optional[int]:
    """Нумерованный выбор. Возвращает индекс (0-based) или None для «назад»."""
    for i, label in enumerate(options, 1):
        print(f"  {i}) {label}")
    if allow_back:
        print("  0) Назад")
    hint = f"[1-{len(options)}, Enter = {default + 1}]" if default >= 0 else f"[0-{len(options)}]"
    while True:
        answer = ask(f"Выберите {hint}: ", str(default + 1) if default >= 0 else "")
        if allow_back and answer in ("0", ""):
            if answer == "0" or default < 0:
                return None
        if answer.isdigit() and 1 <= int(answer) <= len(options):
            return int(answer) - 1
        ctx.warn("Неверный выбор, попробуйте снова.")


def _mask(secret: str) -> str:
    if len(secret) <= 10:
        return "*" * len(secret)
    return f"{secret[:6]}…{secret[-4:]}"


def _check_network(ctx: HostContext, name: str) -> str:
    """Возвращает допустимое имя сети или '' (с предупреждением)."""
    if not name:
        return ""
    if not is_valid_docker_network(name):
        ctx.err(f"Недопустимое имя сети '{name}' (разрешены буквы, цифры, '_', '.', '-'). Сеть не будет подключена.")
        return ""
    if ctx.network_known(name) is False:
        ctx.warn(f"Сеть '{name}' не найдена в Docker. Создайте её перед запуском: docker network create {name}")
    return name


# ------------------------------------------------------------------------------
# Мастер установки
# ------------------------------------------------------------------------------

def run_setup(host_dir: Path, image: Optional[str] = None) -> int:
    ctx = HostContext(host_dir, image)
    c = ctx.c
    env = ctx.env
    prev = env.as_dict() if env.exists else {}
    try:
        if env.exists:
            backup = env.backup()
            print(f"{c.GRAY}[i] Найден существующий .env — сохранена резервная копия: {backup.name}{c.RESET}")

        # 1. Домен
        print(f"\n{c.CYAN}[1/5] Публичный домен сервера{c.RESET}")
        print(f"{c.GRAY}      Домен с HTTPS, на который клиенты будут обращаться за файлами{c.RESET}")
        def_domain = normalize_domain(prev.get("DOMAIN", ""))
        if not is_valid_domain(def_domain):
            def_domain = "geo.example.com"
        while True:
            domain = normalize_domain(ask(f"      Домен [Enter = {def_domain}]: ", def_domain))
            if is_valid_domain(domain):
                break
            ctx.err(f"Некорректный домен '{domain}'. Пример: geo.example.com")

        # 2. Токен
        print(f"\n{c.CYAN}[2/5] Секретный URL-токен доступа{c.RESET}")
        prev_token = prev.get("ROUTING_TOKEN", "")
        if is_valid_token(prev_token):
            def_token, prompt = prev_token, "      Токен [Enter = оставить текущий]: "
        else:
            def_token = generate_token()
            prompt = f"      Токен [Enter = сгенерировать {def_token}]: "
        while True:
            token = ask(prompt, def_token)
            if is_valid_token(token):
                break
            ctx.err("Токен: минимум 4 символа из A-Z, a-z, 0-9, '_' или '-'.")

        # 3. Клиенты
        print(f"\n{c.CYAN}[3/5] Клиенты{c.RESET}")
        prev_clients = prev.get("ENABLED_CLIENTS", "").replace(" ", "").upper()
        values = [v for v, _ in CLIENT_CHOICES]
        labels = [label for _, label in CLIENT_CHOICES]
        if prev_clients in ("", "INCY,HAPP"):
            prev_clients = "HAPP,INCY" if prev_clients else ""
        if prev_clients and prev_clients not in values:
            # Нестандартная комбинация (HAPP_GEO, INCY_GEO и т.п.) — не теряем её по Enter
            values.append(prev_clients)
            labels.append(f"Оставить текущее значение: {prev_clients}")
        default = values.index(prev_clients) if prev_clients in values else 0
        clients = values[_choose(ctx, labels, default, allow_back=False)]

        # 4. Источник правил
        print(f"\n{c.CYAN}[4/5] Источник правил и гео-баз{c.RESET}")
        prev_preset = prev.get("ROUTING_SOURCE_PRESET", "").replace(" ", "").lower()
        preset_values = [p for p, _, _ in PRESET_CHOICES]
        default = preset_values.index(prev_preset) if prev_preset in preset_values else 0
        idx = _choose(ctx, [label for _, _, label in PRESET_CHOICES], default, allow_back=False)
        preset, rules, _ = PRESET_CHOICES[idx]
        if preset == prev_preset and prev.get("ROUTING_RULES"):
            rules = prev["ROUTING_RULES"]

        # 5. Порт
        print(f"\n{c.CYAN}[5/5] Локальный HTTP-порт для обратного прокси{c.RESET}")
        def_port = parse_port(prev.get("HTTP_PORT", "")) or 8080
        while True:
            port = parse_port(ask(f"      Порт [Enter = {def_port}]: ", str(def_port)))
            if port:
                break
            ctx.err("Порт должен быть числом от 1 до 65535.")
        if port in ctx.busy_ports and str(port) != prev.get("HTTP_PORT", ""):
            ctx.warn(f"Порт {port} уже занят на сервере.")

        # Remnawave (необязательно)
        remna_url = normalize_remnawave_url(prev.get("REMNAWAVE_BASE_URL", ""))
        remna_token = prev.get("REMNAWAVE_TOKEN", "")
        network = prev.get("DOCKER_NETWORK", "")
        has_prev = bool(remna_url and remna_token)
        print()
        question = (
            "Перенастроить интеграцию с Remnawave? [y/N, Enter = оставить текущую]: "
            if has_prev else "Настроить интеграцию с Remnawave сейчас? [y/N]: "
        )
        if confirm(question):
            remna_url, remna_token, network = _ask_remnawave(ctx, remna_url, remna_token, network)
        elif not has_prev:
            remna_url = remna_token = ""
    except Cancelled:
        print("Отмена: настройки не изменены.")
        return 1

    new = EnvFile(env.path)
    new.lines = [
        "# ==============================================================================",
        "# GEO ROUTING SERVER CONFIGURATION",
        "# ==============================================================================",
    ]
    values_map: Dict[str, str] = {
        "DOMAIN": domain,
        "ROUTING_TOKEN": token,
        "ENABLED_CLIENTS": clients,
        "ROUTING_SOURCE_PRESET": preset,
        "ROUTING_RULES": rules,
        "SERVE_FORMATS": prev.get("SERVE_FORMATS", "CLIENT_OPTIMIZED"),
        "SERVE_GEOIP": prev.get("SERVE_GEOIP", "true"),
        "SERVE_GEOSITE": prev.get("SERVE_GEOSITE", "true"),
        "PUBLIC_GEO_BASE_URL": prev.get("PUBLIC_GEO_BASE_URL", ""),
        "HTTP_BIND": prev.get("HTTP_BIND", "127.0.0.1"),
        "HTTP_PORT": str(port),
        "SCHEDULE": prev.get("SCHEDULE", DEFAULT_SCHEDULE),
        "SYNC_ON_START": prev.get("SYNC_ON_START", "true"),
    }
    for key, value in values_map.items():
        if value:
            new.set(key, value)
    if remna_url and remna_token:
        new.lines += ["", "# Remnawave API"]
        new.set("REMNAWAVE_BASE_URL", remna_url)
        new.set("REMNAWAVE_TOKEN", remna_token)
    if network:
        new.set("DOCKER_NETWORK", network)
    carried = {k: v for k, v in prev.items() if k not in WIZARD_KEYS}
    if carried:
        new.lines += ["", "# Перенесено из прежнего .env"]
        for key, value in carried.items():
            new.set(key, value)
    new.save()
    ok_path = new.path
    print(f"\n{c.GREEN}[✓] Конфигурация сохранена: {ok_path.name}{c.RESET}")

    backup = composefile.write(ctx.host_dir, ctx.image, network)
    if backup:
        print(f"{c.GRAY}[i] Прежний compose.yaml сохранён: {backup.name}{c.RESET}")
    ctx.ok("compose.yaml готов")
    return 0


def _ask_remnawave(ctx: HostContext, url: str, token: str, network: str) -> Tuple[str, str, str]:
    """Спрашивает URL, токен и сеть панели. Пустой токен — интеграция не сохраняется."""
    def_url = url or "http://remnawave:3000/api"
    url = normalize_remnawave_url(ask(f"  ▸ URL API панели [Enter = {def_url}]: ", def_url))
    hint = "Enter = оставить текущий" if token else "обязательно"
    token = ask(f"  ▸ JWT-токен администратора [{hint}]: ", token)
    print(f"{ctx.c.GRAY}    Если панель в Docker на этом сервере, укажите её сеть — тогда адрес"
          f" http://remnawave:3000 будет доступен из контейнера.{ctx.c.RESET}")
    net_hint = f"Enter = {network}" if network else "Enter = не подключать"
    network = _check_network(ctx, ask(f"  ▸ Docker-сеть панели [{net_hint}]: ", network))
    if not token:
        ctx.warn("Токен Remnawave не указан — интеграция не будет сохранена.")
        return "", "", network
    return url, token, network


# ------------------------------------------------------------------------------
# Разделы настроек
# ------------------------------------------------------------------------------

def _save(ctx: HostContext, message: str) -> int:
    if not ctx.env.changed:
        print("Изменений нет.")
        return 0
    ctx.env.save()
    ctx.ok(f"{message} Применяем…")
    return APPLY


def section_clients(ctx: HostContext) -> int:
    env, c = ctx.env, ctx.c
    while True:
        ctx.header("Клиенты, форматы и гео-базы")
        preset = env.get("ROUTING_SOURCE_PRESET", "geogaga")
        print(f"  Клиенты:          {c.GREEN}{env.get('ENABLED_CLIENTS', 'HAPP,INCY')}{c.RESET}")
        print(f"  Источник правил:  {c.CYAN}{preset}{c.RESET}  (правила: {env.get('ROUTING_RULES', 'все')})")
        print(f"  Форматы:          {env.get('SERVE_FORMATS', 'CLIENT_OPTIMIZED')}")
        print(f"  Раздача GeoIP:    {env.get('SERVE_GEOIP', 'true')}")
        print(f"  Раздача GeoSite:  {env.get('SERVE_GEOSITE', 'true')}")
        print(f"  Внешние базы:     {env.get('PUBLIC_GEO_BASE_URL') or 'нет — раздаются с этого сервера'}")
        print()
        choice = _choose(ctx, [
            "Выбрать клиентов",
            "Выбрать источник правил",
            "Выбрать форматы файлов",
            "Включить / выключить раздачу geoip.dat",
            "Включить / выключить раздачу geosite.dat",
            "Внешний URL гео-баз (PUBLIC_GEO_BASE_URL)",
        ], default=-1)
        if choice is None:
            return 0
        if choice == 0:
            idx = _choose(ctx, [label for _, label in CLIENT_CHOICES], -1)
            if idx is not None:
                env.set("ENABLED_CLIENTS", CLIENT_CHOICES[idx][0])
                if _save(ctx, "Клиенты сохранены."):
                    return APPLY
        elif choice == 1:
            idx = _choose(ctx, [label for _, _, label in PRESET_CHOICES], -1)
            if idx is not None:
                value, rules, _ = PRESET_CHOICES[idx]
                env.set("ROUTING_SOURCE_PRESET", value)
                env.set("ROUTING_RULES", rules)
                if _save(ctx, "Источник правил сохранён."):
                    return APPLY
        elif choice == 2:
            idx = _choose(ctx, [label for _, label in FORMAT_CHOICES], -1)
            if idx is not None:
                env.set("SERVE_FORMATS", FORMAT_CHOICES[idx][0])
                if _save(ctx, "Форматы сохранены."):
                    return APPLY
        elif choice in (3, 4):
            key = "SERVE_GEOIP" if choice == 3 else "SERVE_GEOSITE"
            env.set(key, "false" if env.get(key, "true").lower() == "true" else "true")
            if _save(ctx, f"{key}={env.get(key)}."):
                return APPLY
        elif choice == 5:
            current = env.get("PUBLIC_GEO_BASE_URL")
            print(f"{c.GRAY}Пример: https://geo-node.example.com/<токен узла>. 'none' — раздавать базы с этого сервера.{c.RESET}")
            value = ask(f"URL [Enter = оставить {current or 'без изменений'}]: ")
            if not value:
                continue
            if value.lower() in ("none", "clear", "-"):
                env.delete("PUBLIC_GEO_BASE_URL")
            else:
                env.set("PUBLIC_GEO_BASE_URL", normalize_public_url(value))
            if _save(ctx, "Внешний URL баз сохранён."):
                return APPLY


def section_schedule(ctx: HostContext) -> int:
    env, c = ctx.env, ctx.c
    while True:
        current = env.get("SCHEDULE", DEFAULT_SCHEDULE)
        ctx.header("Расписание синхронизации")
        print(f"  Сейчас: {c.GREEN}{human_schedule(current)}{c.RESET} {c.GRAY}({current}, время UTC){c.RESET}\n")
        choice = _choose(ctx, [
            "Ежедневно в заданное время (ЧЧ:ММ)",
            "Каждые N часов",
            "Ежедневно в 10:00 UTC (13:00 МСК) — по умолчанию",
            "Ежедневно в 12:00 UTC (15:00 МСК)",
            "Каждые 6 часов",
            "Каждые 12 часов",
            "Своё cron-выражение",
        ], default=-1)
        if choice is None:
            return 0
        new: Optional[str] = None
        if choice == 0:
            value = ask("Время UTC, например 04:30 [Enter = отмена]: ")
            new = schedule_from_time(value) if value else None
            if value and not new:
                ctx.err("Неверный формат. Используйте ЧЧ:ММ, например 14:30.")
        elif choice == 1:
            value = ask("Каждые сколько часов [1-24, Enter = отмена]: ")
            new = schedule_every_hours(value) if value else None
            if value and not new:
                ctx.err("Введите число от 1 до 24.")
        elif choice == 6:
            value = ask("Cron (минута час день месяц день-недели) [Enter = отмена]: ")
            if value and is_valid_cron(value):
                new = " ".join(value.split())
            elif value:
                ctx.err("Нужно ровно 5 полей через пробел, например: 0 12 * * *")
        else:
            new = {2: "0 10 * * *", 3: "0 12 * * *", 4: "0 */6 * * *", 5: "0 */12 * * *"}[choice]
        if new:
            env.set("SCHEDULE", new)
            if _save(ctx, f"Расписание: {human_schedule(new)} ({new})."):
                return APPLY


def section_telegram(ctx: HostContext, sender: Optional[Callable[..., bool]] = None) -> int:
    env, c = ctx.env, ctx.c
    if sender is None:
        from app.notifier import TelegramNotifier
        sender = TelegramNotifier.send_test_message
    while True:
        token = env.get("TELEGRAM_BOT_TOKEN")
        chat = env.get("TELEGRAM_CHAT_ID")
        thread = env.get("TELEGRAM_THREAD_ID")
        notify = env.get("TELEGRAM_NOTIFY_SUCCESS", "false").lower() == "true"
        ctx.header("Telegram-уведомления")
        configured = bool(token and chat)
        if configured:
            print(f"  Статус:   {c.GREEN}включены{c.RESET}")
            print(f"  Бот:      {_mask(token)}")
            print(f"  Chat ID:  {chat}" + (f"   тема: {thread}" if thread else ""))
            print(f"  Отчёты:   {'все, включая успешные обновления' if notify else 'только ошибки'}\n")
            choice = _choose(ctx, [
                "Отправить тестовое сообщение",
                "Изменить бота / чат / тему",
                "Переключить отчёты об успешных обновлениях",
                "Отключить уведомления",
            ], default=-1)
        else:
            print(f"  Статус:   {c.GRAY}выключены{c.RESET}\n")
            choice = _choose(ctx, ["Настроить уведомления"], default=-1)
            if choice == 0:
                choice = 1
        if choice is None:
            return 0
        if choice == 0:
            print("Отправка…")
            if sender(bot_token=token, chat_id=chat, thread_id=thread):
                ctx.ok("Сообщение доставлено.")
            else:
                ctx.err("Не удалось отправить: проверьте токен бота, Chat ID и что бот добавлен в чат.")
            pause()
        elif choice == 1:
            new_token = ask(f"Bot Token от @BotFather [Enter = {'оставить' if token else 'отмена'}]: ", token)
            new_chat = ask(f"Chat ID [Enter = {'оставить' if chat else 'отмена'}]: ", chat)
            if not new_token or not new_chat:
                print("Отмена: нужны и токен, и Chat ID.")
                continue
            new_thread = ask(f"ID темы в супергруппе [Enter = {thread or 'нет'}, '-' = убрать]: ", thread)
            env.set("TELEGRAM_BOT_TOKEN", new_token)
            env.set("TELEGRAM_CHAT_ID", new_chat)
            if new_thread and new_thread != "-":
                env.set("TELEGRAM_THREAD_ID", new_thread)
            else:
                env.delete("TELEGRAM_THREAD_ID")
            if _save(ctx, "Telegram настроен."):
                return APPLY
        elif choice == 2:
            env.set("TELEGRAM_NOTIFY_SUCCESS", "false" if notify else "true")
            if _save(ctx, "Режим отчётов изменён."):
                return APPLY
        elif choice == 3:
            if confirm("Отключить Telegram-уведомления? [y/N]: "):
                for key in ("TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_THREAD_ID"):
                    env.delete(key)
                if _save(ctx, "Уведомления отключены."):
                    return APPLY


def section_remnawave(ctx: HostContext) -> int:
    env, c = ctx.env, ctx.c
    while True:
        url = env.get("REMNAWAVE_BASE_URL")
        token = env.get("REMNAWAVE_TOKEN")
        network = env.get("DOCKER_NETWORK")
        ctx.header("Интеграция с Remnawave")
        if not (url and token):
            print("  Сервис может сам обновлять правила Happ во внешних сквадах панели.\n")
            choice = _choose(ctx, ["Подключить панель"], default=-1)
            if choice is None:
                return 0
            url, token, network = _ask_remnawave(ctx, url, token, network)
            if not token:
                continue
            env.set("REMNAWAVE_BASE_URL", url)
            env.set("REMNAWAVE_TOKEN", token)
            _set_network(ctx, network)
            print(f"{c.GRAY}Дальше: создайте во внешних сквадах панели нужный сквад и привяжите его"
                  f" к правилу в этом же разделе.{c.RESET}")
            if _save(ctx, "Remnawave подключена."):
                return APPLY

        print(f"  Статус:   {c.GREEN}подключено{c.RESET}")
        print(f"  API:      {url}")
        print(f"  Токен:    {_mask(token)}")
        print(f"  Сеть:     {network or 'не подключена'}\n")
        choice = _choose(ctx, [
            "Сквады: список, добавление, удаление",
            "Синхронизировать сквады сейчас",
            "Изменить URL, токен или Docker-сеть",
            "Отключить интеграцию",
        ], default=-1)
        if choice is None:
            return 0
        if choice == 0:
            from app.cli import menu_squads
            from app.squads import SquadManager
            menu_squads(SquadManager())
        elif choice == 1:
            from app.squads import SquadManager
            if SquadManager().sync_squads_to_remnawave():
                ctx.ok("Сквады синхронизированы.")
            else:
                ctx.err("Синхронизация завершилась с ошибкой — подробности выше.")
            pause()
        elif choice == 2:
            url, token, network = _ask_remnawave(ctx, url, token, network)
            if not token:
                continue
            env.set("REMNAWAVE_BASE_URL", url)
            env.set("REMNAWAVE_TOKEN", token)
            _set_network(ctx, network)
            if _save(ctx, "Параметры Remnawave сохранены."):
                return APPLY
        elif choice == 3:
            if confirm("Отключить интеграцию с Remnawave? Привязки сквадов сохранятся. [y/N]: "):
                env.delete("REMNAWAVE_BASE_URL")
                env.delete("REMNAWAVE_TOKEN")
                if _save(ctx, "Интеграция отключена."):
                    return APPLY


def _set_network(ctx: HostContext, network: str) -> None:
    """Сохраняет DOCKER_NETWORK и пересобирает compose.yaml, если сеть изменилась."""
    previous = ctx.env.get("DOCKER_NETWORK")
    if network:
        ctx.env.set("DOCKER_NETWORK", network)
    else:
        ctx.env.delete("DOCKER_NETWORK")
    if network != previous:
        backup = composefile.write(ctx.host_dir, ctx.image, network)
        ctx.env.changed = True
        if backup:
            print(f"{ctx.c.GRAY}[i] compose.yaml обновлён, прежний сохранён: {backup.name}{ctx.c.RESET}")


SECTIONS = {
    "clients": section_clients,
    "schedule": section_schedule,
    "telegram": section_telegram,
    "remnawave": section_remnawave,
}


def run_section(name: str, host_dir: Path, image: Optional[str] = None) -> int:
    if not (Path(host_dir) / ".env").is_file():
        print(f"Файл .env не найден в {host_dir}. Сначала выполните установку.")
        return 1
    ctx = HostContext(host_dir, image)
    try:
        return SECTIONS[name](ctx)
    except Cancelled:
        # Изменения сохраняются только целиком через _save(); незавершённая
        # правка при Ctrl+C отбрасывается, файл на диске не тронут.
        return 0


# ------------------------------------------------------------------------------
# Неинтерактивная правка: geoserver config set KEY VALUE
# ------------------------------------------------------------------------------

_SETTERS: Dict[str, Callable[[str], Optional[str]]] = {
    "DOMAIN": lambda v: (lambda d: d if is_valid_domain(d) else None)(normalize_domain(v)),
    "ROUTING_TOKEN": lambda v: v if is_valid_token(v) else None,
    "HTTP_PORT": lambda v: (lambda p: str(p) if p else None)(parse_port(v)),
    "SCHEDULE": lambda v: " ".join(v.split()) if is_valid_cron(v) else None,
    "REMNAWAVE_BASE_URL": lambda v: normalize_remnawave_url(v) or None,
    "PUBLIC_GEO_BASE_URL": lambda v: normalize_public_url(v) or None,
    "DOCKER_NETWORK": lambda v: v if is_valid_docker_network(v) else None,
}


def config_set(host_dir: Path, key: str, value: str, image: Optional[str] = None) -> int:
    ctx = HostContext(host_dir, image)
    if not ctx.env.exists:
        print(f"Файл .env не найден в {host_dir}.")
        return 1
    key = key.strip().upper()
    normalized = _SETTERS.get(key, lambda v: v)(value.strip())
    if normalized is None:
        ctx.err(f"Недопустимое значение для {key}: {value!r}")
        return 2
    if key == "DOCKER_NETWORK":
        _set_network(ctx, normalized)
    else:
        ctx.env.set(key, normalized)
    return _save(ctx, f"{key} сохранён.")
