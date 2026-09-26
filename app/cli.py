"""CLI инструмент управления Geo Routing Server."""

import argparse
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any, Dict, Optional

from app.config import Config
from app.remnawave import RemnawaveSync
from app.squads import SquadManager

# Fix Windows console encoding if needed
for stream in (sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        try:
            stream.reconfigure(encoding="utf-8")
        except Exception:
            pass

logger = logging.getLogger("geo-routing-server")


def supports_color() -> bool:
    """Проверяет, поддерживает ли текущий терминал ANSI цвета."""
    if os.getenv("NO_COLOR"):
        return False
    if not hasattr(sys.stdout, "isatty"):
        return False
    return sys.stdout.isatty()


class Colors:
    """Управление ANSI-цветами для терминала."""

    def __init__(self, enabled: bool):
        self.RESET = "\033[0m" if enabled else ""
        self.BOLD = "\033[1m" if enabled else ""
        self.RED = "\033[31m" if enabled else ""
        self.GREEN = "\033[32m" if enabled else ""
        self.YELLOW = "\033[33m" if enabled else ""
        self.BLUE = "\033[34m" if enabled else ""
        self.MAGENTA = "\033[35m" if enabled else ""
        self.CYAN = "\033[36m" if enabled else ""
        self.WHITE = "\033[37m" if enabled else ""
        self.GRAY = "\033[90m" if enabled else ""


def get_safe_token() -> str:
    """Безопасно извлекает токен без принудительного вызова sys.exit."""
    token = os.getenv("ROUTING_TOKEN", "").strip()
    if token and token != "change_me_to_random_secret_token":
        return token
    token_file = getattr(Config, "BASE_DIR", Path("/app")) / "token.txt"
    if token_file.is_file():
        try:
            content = token_file.read_text(encoding="utf-8").strip()
            if content and content != "change_me_to_random_secret_token":
                return content
        except Exception:
            pass
    return token or "change_me_to_random_secret_token"


def find_status_files(token: str) -> tuple[Optional[Path], Optional[Path]]:
    """Находит файлы .sync-status.json и .sync-summary.txt."""
    status_candidates = [
        Config.STORAGE_DIR / token / ".sync-status.json",
        Config.STORAGE_DIR / ".sync-status.json",
        getattr(Config, "BASE_DIR", Path("/app")) / ".sync-status.json",
        Path(".sync-status.json"),
    ]
    summary_candidates = [
        Config.STORAGE_DIR / token / ".sync-summary.txt",
        Config.STORAGE_DIR / ".sync-summary.txt",
        getattr(Config, "BASE_DIR", Path("/app")) / ".sync-summary.txt",
        Path(".sync-summary.txt"),
    ]
    status_file = next((p for p in status_candidates if p.is_file()), None)
    summary_file = next((p for p in summary_candidates if p.is_file()), None)
    return status_file, summary_file


def get_status_info(manager: Optional[SquadManager] = None) -> Dict[str, Any]:
    """Формирует полную сводку о текущем состоянии сервера и ссылках."""
    token = get_safe_token()
    base_url = Config.get_base_url(token)
    clients_set = set(Config.ENABLED_CLIENTS)
    status_file, summary_file = find_status_files(token)

    sync_status = {}
    if status_file:
        try:
            sync_status = json.loads(status_file.read_text(encoding="utf-8"))
        except Exception:
            pass

    summary_text = ""
    if summary_file:
        try:
            summary_text = summary_file.read_text(encoding="utf-8")
        except Exception:
            pass

    mgr = manager or SquadManager()
    squads = mgr.list_squads()

    happ_rules = [
        r.removesuffix(".JSON") for r in Config.get_display_rules(client="HAPP")
    ]
    incy_rules = [
        r.removesuffix(".JSON") for r in Config.get_display_rules(client="INCY")
    ]

    links: Dict[str, Any] = {"happ": {}, "incy": {}}

    # HAPP ссылки
    if any(c in clients_set for c in ("HAPP", "HAPP_DEEPLINK", "HAPP_LOCAL", "HAPP_GEO")):
        if Config.should_serve_deeplink("HAPP"):
            links["happ"]["deeplinks"] = [
                {"rule": r, "url": f"{base_url}/HAPP/{r}.DEEPLINK"} for r in happ_rules
            ]
        if Config.should_serve_json("HAPP"):
            links["happ"]["json"] = [
                {"rule": r, "url": f"{base_url}/HAPP/{r}.JSON"} for r in happ_rules
            ]
        ext_geo = Config.get_external_geo_url("HAPP")
        if ext_geo:
            links["happ"]["geo"] = {
                "geoip": f"{ext_geo}/geoip.dat",
                "geosite": f"{ext_geo}/geosite.dat",
                "external": True,
            }
        elif Config.SERVE_GEOIP or Config.SERVE_GEOSITE:
            links["happ"]["geo"] = {
                "geoip": f"{base_url}/HAPP/geoip.dat" if Config.SERVE_GEOIP else None,
                "geosite": f"{base_url}/HAPP/geosite.dat" if Config.SERVE_GEOSITE else None,
                "external": False,
            }

    # INCY ссылки
    if any(c in clients_set for c in ("INCY", "INCY_GEO")):
        if Config.should_serve_json("INCY"):
            links["incy"]["autorouting_headers"] = [
                {
                    "rule": r,
                    "header": f"incy://autorouting/onadd/{base_url}/INCY/{r}.JSON",
                }
                for r in incy_rules
            ]
            links["incy"]["json"] = [
                {"rule": r, "url": f"{base_url}/INCY/{r}.JSON"} for r in incy_rules
            ]
        if Config.should_serve_deeplink("INCY"):
            links["incy"]["deeplinks"] = [
                {"rule": r, "url": f"{base_url}/INCY/{r}.DEEPLINK"} for r in incy_rules
            ]
        ext_geo = Config.get_external_geo_url("INCY")
        if ext_geo:
            links["incy"]["geo"] = {
                "geoip": f"{ext_geo}/geoip.dat",
                "geosite": f"{ext_geo}/geosite.dat",
                "external": True,
            }
        elif Config.SERVE_GEOIP or Config.SERVE_GEOSITE:
            links["incy"]["geo"] = {
                "geoip": f"{base_url}/INCY/geoip.dat" if Config.SERVE_GEOIP else None,
                "geosite": f"{base_url}/INCY/geosite.dat" if Config.SERVE_GEOSITE else None,
                "external": False,
            }

    return {
        "status": sync_status.get("state", "not_run"),
        "last_sync": sync_status.get("recorded_at"),
        "failed_processors": sync_status.get("failed_processors", 0),
        "remnawave_ok": sync_status.get("remnawave_ok", True),
        "domain": Config.DOMAIN,
        "base_url": base_url,
        "token": token,
        "routing_source_preset": Config.ROUTING_SOURCE_PRESET,
        "enabled_clients": Config.ENABLED_CLIENTS,
        "remnawave": {
            "configured": RemnawaveSync.is_configured(),
            "api_url": RemnawaveSync.get_api_url(),
            "squads_count": len(squads),
        },
        "squads": squads,
        "links": links,
        "summary": summary_text or None,
    }


def cmd_status(json_mode: bool = False, manager: Optional[SquadManager] = None) -> int:
    """Выводит актуальный статус сервиса и сводку публичных ссылок."""
    token = get_safe_token()
    _status_file, summary_file = find_status_files(token)

    if json_mode:
        info = get_status_info(manager)
        print(json.dumps(info, indent=2, ensure_ascii=False))
        return 0

    # 1. Если есть файл .sync-summary.txt, выводим его
    if summary_file and summary_file.is_file():
        try:
            text = summary_file.read_text(encoding="utf-8").strip()
            if text:
                print(text)
                return 0
        except OSError:
            pass

    # 2. Если файла сводки нет, генерируем на лету
    from app.main import print_summary_banner

    print_summary_banner(token)
    return 0


def cmd_proxy() -> int:
    """Выводит готовые конфигурационные сниппеты для Caddy и Nginx."""
    domain = Config.DOMAIN
    port = os.getenv("HTTP_PORT", "8080")
    token = get_safe_token()
    preset = Config.ROUTING_SOURCE_PRESET

    print(f"📋 Конфигурация Reverse Proxy для домена {domain}\n")
    print("1. Для Nginx (внутри блока server { ... }):")
    print("─" * 55)
    print("Вариант А (Выделенный поддомен — на домене только geo-routing-server):")
    print(f"""location / {{
    proxy_pass http://127.0.0.1:{port};
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}}
""")
    print("Вариант Б (Общий домен с другим сайтом/сервисом — корень '/' занят):")
    print("Проксирует только геобазы по токену, не затрагивая корень '/':")
    if token and token != "change_me_to_random_secret_token":
        print(f"""location /{token}/ {{
    proxy_pass http://127.0.0.1:{port};
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}}
""")
    else:
        print(f"""location ~ ^/[A-Za-z0-9_-]{{16,64}}/(HAPP|INCY)/ {{
    proxy_pass http://127.0.0.1:{port};
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
}}
""")

    print("2. Для Caddy (добавьте в Caddyfile):")
    print("─" * 55)
    print("Вариант А (Выделенный поддомен):")
    print(f"""{domain} {{
    reverse_proxy 127.0.0.1:{port}
}}
""")
    if token and token != "change_me_to_random_secret_token":
        print(f"Вариант Б (Общий домен — внутри существующего блока {domain} {{ ... }}):")
        print(f"""handle /{token}/* {{
    reverse_proxy 127.0.0.1:{port}
}}
""")

    if preset == "geogaga":
        print("3. Outbound-правила Xray (GeoGaga Server-Flavor: анти-DMCA, Torrent, SMTP):")
        print("─" * 55)
        print("""Опционально: для защиты вашего VPN-сервера от абуз (BitTorrent, спам, локальные утечки)
добавьте правила в секцию "routing": { "rules": [...] } конфигурации Xray:

  {
    "type": "field",
    "protocol": ["bittorrent"],
    "outboundTag": "blocked"
  },
  {
    "type": "field",
    "port": "25, 465, 587",
    "outboundTag": "blocked"
  },
  {
    "type": "field",
    "ip": ["geoip:private"],
    "outboundTag": "blocked"
  }
""")

    return 0


def cmd_sync() -> int:
    """Запускает процесс синхронизации geo-routing-server."""
    from app.main import main as app_main

    try:
        app_main()
        return 0
    except SystemExit as e:
        return e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
    except Exception as e:
        print(f"Sync error: {e}", file=sys.stderr)
        return 1


def cmd_squads() -> int:
    """Выводит список внешних сквадов из Remnawave API или текущих привязок."""
    if not RemnawaveSync.is_configured():
        print("Remnawave integration is not configured (missing REMNAWAVE_BASE_URL or REMNAWAVE_TOKEN).")
        return 1

    print(f"Connecting to Remnawave API at: {RemnawaveSync.get_api_url()}")
    all_squads = RemnawaveSync.fetch_all_squad_names()
    if not all_squads:
        print("No external squads retrieved from Remnawave API (or connection error).")
    else:
        print(f"Found {len(all_squads)} squads:")
        for uuid, name in all_squads.items():
            print(f"  • {name} ({uuid})")

    configured = RemnawaveSync.load_squad_configs()
    if configured:
        print("\nLocally configured squad bindings:")
        for idx, sq in enumerate(configured, 1):
            u = sq.get("uuid", "")
            r = sq.get("rule", "")
            n = sq.get("name", RemnawaveSync.get_squad_name(u) or f"Squad #{idx}")
            print(f"  {idx}) {n} ({u[:8]}...) -> {r}")
    return 0


def cmd_squads_list(manager: Optional[SquadManager] = None) -> int:
    """Выводит список сконфигурированных сквадов."""
    mgr = manager or SquadManager()
    squads = mgr.list_squads()
    c = Colors(supports_color())
    if not squads:
        print(f"{c.GRAY}Нет привязанных сквадов.{c.RESET}")
        return 0
    print(f"\n{c.BOLD}{c.WHITE}Привязки сквадов Remnawave (всего: {len(squads)}):{c.RESET}")
    for idx, sq in enumerate(squads, 1):
        name = sq.get("name") or "Без имени"
        print(
            f"  {idx}. {c.WHITE}{name}{c.RESET} ({c.GRAY}{sq['uuid']}{c.RESET}) → {c.GREEN}{sq['rule']}{c.RESET}"
        )
    print()
    return 0


def cmd_squads_add(
    uuid: Optional[str] = None,
    rule: Optional[str] = None,
    name: Optional[str] = None,
    manager: Optional[SquadManager] = None,
) -> int:
    """Добавляет или обновляет сквад Remnawave."""
    mgr = manager or SquadManager()
    c = Colors(supports_color())

    if not uuid:
        if sys.stdin.isatty():
            try:
                uuid = input("UUID сквада: ").strip()
            except (KeyboardInterrupt, EOFError):
                print("\nОтмена.")
                return 1
        else:
            print("Ошибка: аргумент --uuid обязателен.", file=sys.stderr)
            return 1

    if not rule:
        default_rule = (
            Config.get_active_rules([], "HAPP")[0]
            if Config.get_active_rules([], "HAPP")
            else "JSONSUB.JSON"
        )
        if sys.stdin.isatty():
            try:
                entered = input(f"Правило [{default_rule}]: ").strip()
                rule = entered or default_rule
            except (KeyboardInterrupt, EOFError):
                print("\nОтмена.")
                return 1
        else:
            rule = default_rule

    if name is None and sys.stdin.isatty():
        try:
            n_in = input("Имя сквада (опционально, Enter для пропуска): ").strip()
            name = n_in if n_in else None
        except (KeyboardInterrupt, EOFError):
            print("\nОтмена.")
            return 1

    try:
        sq = mgr.add_squad(uuid=uuid, rule=rule, name=name)
        info_name = f" ({sq.get('name')})" if sq.get("name") else ""
        print(
            f"{c.GREEN}[✓] Сквад успешно сохранен:{c.RESET} {sq['uuid']} → {sq['rule']}{info_name}"
        )
        return 0
    except ValueError as e:
        print(f"{c.RED}Ошибка: {e}{c.RESET}", file=sys.stderr)
        return 1


def cmd_squads_remove(
    uuid: Optional[str] = None,
    manager: Optional[SquadManager] = None,
) -> int:
    """Удаляет сквад Remnawave по UUID."""
    mgr = manager or SquadManager()
    c = Colors(supports_color())

    if not uuid:
        squads = mgr.list_squads()
        if not squads:
            print(f"{c.GRAY}Нет привязанных сквадов для удаления.{c.RESET}")
            return 0
        if sys.stdin.isatty():
            print("Список сквадов:")
            for idx, sq in enumerate(squads, 1):
                name = sq.get("name") or "Без имени"
                print(f"  {idx}) {name} ({sq['uuid']})")
            try:
                val = input("\nВведите UUID или номер сквада для удаления: ").strip()
                if val.isdigit() and 1 <= int(val) <= len(squads):
                    uuid = squads[int(val) - 1]["uuid"]
                else:
                    uuid = val
            except (KeyboardInterrupt, EOFError):
                print("\nОтмена.")
                return 1
        else:
            print("Ошибка: аргумент UUID обязателен.", file=sys.stderr)
            return 1

    if mgr.remove_squad(uuid):
        print(f"{c.GREEN}[✓] Сквад '{uuid}' успешно удален.{c.RESET}")
        return 0
    else:
        print(f"{c.YELLOW}Сквад с UUID '{uuid}' не найден.{c.RESET}")
        return 1


def cmd_squads_sync(manager: Optional[SquadManager] = None) -> int:
    """Синхронизирует сквады с API Remnawave."""
    mgr = manager or SquadManager()
    c = Colors(supports_color())
    print("Применение привязок сквадов в Remnawave API...")
    ok = mgr.sync_squads_to_remnawave()
    if ok:
        print(f"{c.GREEN}[✓] Синхронизация сквадов успешно завершена!{c.RESET}")
        return 0
    else:
        print(f"{c.RED}[✗] Ошибка синхронизации сквадов с Remnawave API.{c.RESET}", file=sys.stderr)
        return 1


def cmd_squads_migrate(
    env_path: Optional[str] = None,
    manager: Optional[SquadManager] = None,
) -> int:
    """Мигрирует привязки сквадов из .env в squads.json."""
    mgr = manager or SquadManager()
    c = Colors(supports_color())
    migrated = mgr.migrate_from_env(env_path)
    if migrated:
        print(f"{c.GREEN}[✓] Успешно мигрировано сквадов: {len(migrated)}{c.RESET}")
        for sq in migrated:
            name = sq.get("name") or "Без имени"
            print(f"  • {name} ({sq['uuid']}) → {sq['rule']}")
        return 0
    else:
        print(f"{c.GRAY}Привязок сквадов в .env не найдено (или файл отсутствует).{c.RESET}")
        return 0


def menu_squads(mgr: SquadManager) -> None:
    """Подменю управления сквадами Remnawave."""
    c = Colors(supports_color())
    while True:
        print(f"\n{c.CYAN}{'-'*55}{c.RESET}")
        print(f"{c.BOLD}{c.WHITE}⚡ Управление сквадами Remnawave{c.RESET}")
        print(f"{c.CYAN}{'-'*55}{c.RESET}")
        print("  1) 📋 Список привязок")
        print("  2) ➕ Добавить / изменить сквад")
        print("  3) ❌ Удалить сквад")
        print("  4) 🔄 Синхронизировать с Remnawave API")
        print("  5) 📥 Миграция существующих привязок из .env")
        print("  0) ⬅️ Назад в главное меню")
        print(f"{c.CYAN}{'-'*55}{c.RESET}")

        try:
            choice = input(f"{c.BOLD}Выберите действие [0-5]: {c.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            break

        if choice == "1":
            cmd_squads_list(mgr)
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "2":
            cmd_squads_add(manager=mgr)
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "3":
            cmd_squads_remove(manager=mgr)
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "4":
            cmd_squads_sync(mgr)
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "5":
            env_file = input("Путь к .env [Enter = .env]: ").strip() or None
            cmd_squads_migrate(env_path=env_file, manager=mgr)
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "0":
            break
        else:
            print(f"{c.YELLOW}Неверный выбор, попробуйте снова.{c.RESET}")


def cmd_menu(manager: Optional[SquadManager] = None) -> int:
    """Интерактивное TUI-меню с цветным ANSI-оформлением."""
    mgr = manager or SquadManager()
    c = Colors(supports_color())

    while True:
        print(f"\n{c.CYAN}{'='*60}{c.RESET}")
        print(f"{c.BOLD}{c.WHITE}* Geo Routing Server — Интерактивное меню{c.RESET}")
        print(f"{c.CYAN}{'='*60}{c.RESET}")
        print("  1) 📊 Статус и ссылки")
        print("  2) 🔄 Запуск синхронизации")
        print("  3) ⚡ Настройка сквадов Remnawave")
        print("  4) 📋 Сниппеты Caddy / Nginx")
        print("  0) 🚪 Выход")
        print(f"{c.CYAN}{'-'*60}{c.RESET}")

        try:
            choice = input(f"{c.BOLD}Выберите действие [0-4]: {c.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nВыход.")
            break

        if choice == "1":
            cmd_status(json_mode=False, manager=mgr)
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "2":
            try:
                ans = input("Запустить синхронизацию правил прямо сейчас? [Y/n]: ").strip().lower()
                if ans in ("", "y", "yes", "д", "да"):
                    cmd_sync()
            except (KeyboardInterrupt, EOFError):
                pass
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "3":
            menu_squads(mgr)
        elif choice == "4":
            cmd_proxy()
            try:
                input(f"{c.GRAY}Нажмите Enter, чтобы продолжить...{c.RESET}")
            except (KeyboardInterrupt, EOFError):
                pass
        elif choice == "0":
            print("До свидания!")
            break
        else:
            print(f"{c.YELLOW}Неверный выбор, попробуйте снова.{c.RESET}")

    return 0


def build_parser() -> argparse.ArgumentParser:
    """Создает парсер командной строки argparse."""
    parser = argparse.ArgumentParser(
        prog="geo-routing-server",
        description="CLI инструмент управления Geo Routing Server",
    )
    subparsers = parser.add_subparsers(dest="command", help="Команда для выполнения")

    # status
    p_status = subparsers.add_parser("status", help="Статус синхронизации и валидные ссылки")
    p_status.add_argument("--json", action="store_true", help="Вывод в формате JSON")

    # sync
    subparsers.add_parser("sync", help="Запустить полную синхронизацию правил")

    # proxy
    subparsers.add_parser("proxy", help="Сниппеты конфигурации Caddy и Nginx")

    # squads
    p_squads = subparsers.add_parser("squads", help="Управление сквадами Remnawave")
    squads_sub = p_squads.add_subparsers(dest="squads_command", help="Действие со сквадами")

    squads_sub.add_parser("list", help="Список настроенных сквадов")

    p_sq_add = squads_sub.add_parser("add", help="Добавить или изменить сквад")
    p_sq_add.add_argument("--uuid", help="UUID сквада")
    p_sq_add.add_argument("--rule", help="Имя правила (например, JSONSUB.JSON)")
    p_sq_add.add_argument("--name", help="Читаемое имя сквада")

    p_sq_rm = squads_sub.add_parser("remove", help="Удалить сквад")
    p_sq_rm.add_argument("uuid_pos", nargs="?", help="UUID сквада (позиционный)")
    p_sq_rm.add_argument("--uuid", dest="uuid_opt", help="UUID сквада (опция)")

    squads_sub.add_parser("sync", help="Применить привязки сквадов в Remnawave API")

    p_sq_mig = squads_sub.add_parser("migrate", help="Мигрировать сквады из .env в squads.json")
    p_sq_mig.add_argument("--env-path", help="Путь к файлу .env")

    # menu
    subparsers.add_parser("menu", help="Интерактивное TUI-меню")

    return parser


def main(args: Optional[list[str]] = None) -> int:
    """Точка входа CLI."""
    parser = build_parser()
    parsed_args = parser.parse_args(args)

    if not parsed_args.command:
        if sys.stdin.isatty():
            return cmd_menu()
        parser.print_help()
        return 0

    if parsed_args.command == "status":
        return cmd_status(json_mode=parsed_args.json)

    if parsed_args.command == "sync":
        return cmd_sync()

    if parsed_args.command == "proxy":
        return cmd_proxy()

    if parsed_args.command == "menu":
        return cmd_menu()

    if parsed_args.command == "squads":
        sq_cmd = parsed_args.squads_command
        if not sq_cmd:
            if RemnawaveSync.is_configured():
                return cmd_squads()
            return cmd_squads_list()
        elif sq_cmd == "list":
            return cmd_squads_list()
        elif sq_cmd == "add":
            return cmd_squads_add(
                uuid=parsed_args.uuid, rule=parsed_args.rule, name=parsed_args.name
            )
        elif sq_cmd == "remove":
            uuid = parsed_args.uuid_opt or parsed_args.uuid_pos
            return cmd_squads_remove(uuid=uuid)
        elif sq_cmd == "sync":
            return cmd_squads_sync()
        elif sq_cmd == "migrate":
            return cmd_squads_migrate(env_path=parsed_args.env_path)
        else:
            parser.print_help()
            return 1

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
