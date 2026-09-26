import logging
import os
import sys
import json
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# Fix Windows console encoding if needed
if hasattr(sys.stdout, "reconfigure"):
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except Exception:
        pass

# Cross-platform file locking
try:
    import fcntl
    HAS_FCNTL = True
except ImportError:
    HAS_FCNTL = False

from app.config import Config
from app.downloader import Downloader
from app.notifier import TelegramNotifier
from app.processors.happ import HappProcessor
from app.processors.incy import IncyProcessor
from app.publisher import Publisher
from app.remnawave import RemnawaveSync

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        handlers=[logging.StreamHandler(sys.stdout)]
    )

def acquire_lock(lock_path: Path):
    """Блокировка от параллельного запуска нескольких синхронизаций без усечения файла до flock."""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lock_path), os.O_CREAT | os.O_RDWR, 0o600)
    lock_file = os.fdopen(fd, "r+", encoding="utf-8")
    if HAS_FCNTL:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, IOError):
            print("ERROR: Another sync process is already running!", file=sys.stderr)
            sys.exit(1)
    return lock_file

def ensure_internal_symlinks(storage_dir: Path, token: str):
    """Создает атомарные симлинки в корне www для прямого доступа из внутренней Docker-сети."""
    for client in ("HAPP", "INCY"):
        target = storage_dir / token / client
        link = storage_dir / client
        if target.is_dir():
            rel_target = Path(token) / client
            tmp_link = storage_dir / f".{client}.tmp_link"
            try:
                if tmp_link.is_symlink() or tmp_link.exists():
                    tmp_link.unlink()
                tmp_link.symlink_to(rel_target, target_is_directory=True)
                os.replace(tmp_link, link)
            except Exception:
                try:
                    if link.is_symlink() or link.is_file():
                        link.unlink()
                    link.symlink_to(rel_target, target_is_directory=True)
                except Exception:
                    pass

def write_sync_status(
    storage_dir: Path,
    token: str,
    state: str,
    failures: int = 0,
    remnawave_ok: bool = True,
    errors: Optional[list[str]] = None,
    rules: Optional[list[str]] = None,
    generated_files: Optional[list[str]] = None,
):
    """Сохраняет метаданные синхронизации (.sync-status.json) атомарно."""
    status_file = storage_dir / token / ".sync-status.json"
    now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
    
    if errors is None:
        errors = list(RemnawaveSync.last_errors) if hasattr(RemnawaveSync, "last_errors") else []
    if rules is None:
        rules = [r for r in Config.get_display_rules()]
    if generated_files is None:
        generated_files = sorted(list(Publisher.published_registry.keys()))

    payload = {
        "timestamp": now_iso,
        "status": state,
        "state": state,
        "recorded_at": now_iso,
        "generated_files": generated_files,
        "errors": errors,
        "rules": rules,
        "failed_processors": failures,
        "remnawave_ok": remnawave_ok,
    }
    temp_fd, temp_path = tempfile.mkstemp(prefix=".sync-status.", dir=str(status_file.parent))
    try:
        with os.fdopen(temp_fd, "w", encoding="utf-8") as status_handle:
            json.dump(payload, status_handle, ensure_ascii=False, indent=2)
            status_handle.flush()
            os.fsync(status_handle.fileno())
        os.replace(temp_path, status_file)
        os.chmod(status_file, 0o600)
    except OSError as error:
        logger = logging.getLogger("geo-routing-server")
        logger.warning(f"Could not write sync status: {error}")
        try:
            os.unlink(temp_path)
        except OSError:
            pass

def get_summary_banner_text(token: str, storage_dir: Optional[Path] = None) -> str:
    """Формирует готовый текстовый отчет со всеми ссылками для клиентов (Happ, Incy, Sing-box).

    Проверяет реально опубликованные файлы на диске, если они есть.
    """
    base_url = Config.get_base_url(token)
    clients_set = set(Config.ENABLED_CLIENTS)
    target_base = storage_dir or Config.STORAGE_DIR
    happ_dir = target_base / token / "HAPP"
    incy_dir = target_base / token / "INCY"

    # Файлы правил HAPP: проверяем реально опубликованные, иначе fallback на Config
    if happ_dir.is_dir():
        happ_rules = sorted({
            p.name.rsplit(".", 1)[0].upper()
            for p in happ_dir.iterdir()
            if p.is_file() and (p.name.upper().endswith(".JSON") or p.name.upper().endswith(".DEEPLINK"))
        })
    else:
        happ_rules = []
    if not happ_rules:
        happ_rules = [r.removesuffix(".JSON") for r in Config.get_display_rules(client="HAPP")]

    # Файлы правил INCY: проверяем реально опубликованные, иначе fallback на Config
    if incy_dir.is_dir():
        incy_rules = sorted({
            p.name.rsplit(".", 1)[0].upper()
            for p in incy_dir.iterdir()
            if p.is_file() and (p.name.upper().endswith(".JSON") or p.name.upper().endswith(".DEEPLINK"))
        })
    else:
        incy_rules = []
    if not incy_rules:
        incy_rules = [r.removesuffix(".JSON") for r in Config.get_display_rules(client="INCY")]

    sections = []

    # HAPP блок
    happ_geo = "HAPP" in clients_set or "HAPP_GEO" in clients_set
    happ_deeplink = "HAPP" in clients_set or "HAPP_DEEPLINK" in clients_set or "HAPP_LOCAL" in clients_set

    if happ_geo or happ_deeplink:
        happ_lines = ["[HAPP]"]
        if RemnawaveSync.is_configured():
            happ_lines.append("  - Прямая интеграция с Remnawave API: АКТИВНА (автопатч сквадов без сторонних сервисов)")
            squads = []
            try:
                squads = RemnawaveSync.load_squad_configs()
                RemnawaveSync.fetch_all_squad_names()
                for sq in squads:
                    u = sq.get('uuid', '')
                    rule = sq.get('rule', '')
                    s_name = RemnawaveSync.get_squad_name(u) or sq.get('name')
                    if s_name:
                        happ_lines.append(f"      Сквад '{s_name}' ({u}) -> {rule}")
                    else:
                        happ_lines.append(f"      Сквад {u} -> {rule}")
            except Exception:
                pass
            if not squads and not os.getenv("REMNAWAVE_GLOBAL_RULE"):
                happ_lines.append("      [i] Сквады ещё не привязаны. Добавьте сквад через: geoserver -> пункт 4")
                if Config.should_serve_deeplink("HAPP"):
                    happ_lines.append("  - Доступные диплинки правил (ручной импорт):")
                    for r in happ_rules:
                        happ_lines.append(f"      • {r}:   {base_url}/HAPP/{r}.DEEPLINK")
        elif happ_deeplink:
            remna_base = os.getenv("REMNAWAVE_BASE_URL", "").strip()
            remna_token = os.getenv("REMNAWAVE_TOKEN", "").strip()
            if remna_base and not remna_token:
                happ_lines.append("  [!] Remnawave API: указан URL, но отсутствует REMNAWAVE_TOKEN")
                happ_lines.append("      Автопатч не активен. Введите токен через команду: geoserver -> пункт 4")
            else:
                if Config.should_serve_deeplink("HAPP"):
                    happ_lines.append("  - Правила Happ (диплинки happ://routing/onadd/...):")
                    for r in happ_rules:
                        happ_lines.append(f"      • {r}:   {base_url}/HAPP/{r}.DEEPLINK")
                if Config.should_serve_json("HAPP"):
                    happ_lines.append("  - Файлы правил JSON:")
                    for r in happ_rules:
                        happ_lines.append(f"      • {r}:   {base_url}/HAPP/{r}.JSON")

        ext_geo_happ = Config.get_external_geo_url("HAPP")
        if ext_geo_happ:
            geo_lines = [
                "  - Внешние ссылки на базы (для клиентов):",
                f"      GeoIP:     {ext_geo_happ}/geoip.dat",
                f"      GeoSite:   {ext_geo_happ}/geosite.dat"
            ]
            happ_lines.append("\n".join(geo_lines))
        elif happ_geo and (Config.SERVE_GEOIP or Config.SERVE_GEOSITE):
            geo_lines = ["  - Публичные HTTPS ссылки на базы (для клиентов с токеном):"]
            if Config.SERVE_GEOIP:
                geo_lines.append(f"      GeoIP:     {base_url}/HAPP/geoip.dat")
            if Config.SERVE_GEOSITE:
                geo_lines.append(f"      GeoSite:   {base_url}/HAPP/geosite.dat")
            happ_lines.append("\n".join(geo_lines))

        sections.append("\n".join(happ_lines))

    # INCY блок
    if "INCY" in clients_set or "INCY_GEO" in clients_set:
        incy_lines = ["[INCY]"]
        ext_geo_incy = Config.get_external_geo_url("INCY")

        if ext_geo_incy:
            geo_lines = [
                "  - Внешние ссылки на базы (для клиентов):",
                f"      GeoIP:     {ext_geo_incy}/geoip.dat",
                f"      GeoSite:   {ext_geo_incy}/geosite.dat"
            ]
            incy_lines.append("\n".join(geo_lines))
        elif Config.SERVE_GEOIP or Config.SERVE_GEOSITE:
            geo_lines = ["  - Публичные HTTPS ссылки на базы (для клиентов с токеном):"]
            if Config.SERVE_GEOIP:
                geo_lines.append(f"      GeoIP:     {base_url}/INCY/geoip.dat")
            if Config.SERVE_GEOSITE:
                geo_lines.append(f"      GeoSite:   {base_url}/INCY/geosite.dat")
            incy_lines.append("\n".join(geo_lines))

        if "INCY" in clients_set and Config.should_serve_json("INCY"):
            rule_examples = "\n".join([f"      • {r}:   incy://autorouting/onadd/{base_url}/INCY/{r}.JSON" for r in incy_rules])
            incy_lines.append(f"""  - Заголовок подписки (Remnawave / Marzban Autorouting):
      Header Name:  autorouting
      Header Value: incy://autorouting/onadd/{base_url}/INCY/<RULE>.JSON

      Примеры:
{rule_examples}""")

        if "INCY" in clients_set and Config.should_serve_deeplink("INCY"):
            dl_examples = "\n".join([f"      • {r}:   {base_url}/INCY/{r}.DEEPLINK" for r in incy_rules])
            incy_lines.append(f"""  - Deep-link файлы для Incy:
{dl_examples}""")

        sections.append("\n".join(incy_lines))

    body = "\n\n".join(sections) if sections else "No active clients configured in ENABLED_CLIENTS."

    return f"""
===============================================================================
* Geo Routing Server Ready! Endpoints & Integrations:
-------------------------------------------------------------------------------
{body}
===============================================================================
"""

def print_summary_banner(token: str, storage_dir: Optional[Path] = None) -> str:
    """Выводит баннер со сводкой ссылок и интеграций."""
    banner = get_summary_banner_text(token, storage_dir)
    print(banner, flush=True)
    return banner

def write_sync_summary(storage_dir: Path, token: str, summary_text: str) -> None:
    """Атомарно сохраняет текстовую сводку (.sync-summary.txt) со всеми ссылками."""
    for parent in [storage_dir, storage_dir / token]:
        try:
            parent.mkdir(parents=True, exist_ok=True)
            summary_file = parent / ".sync-summary.txt"
            temp_fd, temp_path = tempfile.mkstemp(prefix=".sync-summary.", dir=str(parent))
            with os.fdopen(temp_fd, "w", encoding="utf-8") as f:
                f.write(summary_text)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_path, summary_file)
            try:
                os.chmod(summary_file, 0o644)
            except Exception:
                pass
        except OSError as error:
            logger = logging.getLogger("geo-routing-server")
            logger.debug(f"Could not write sync summary to {parent}: {error}")

def main():
    setup_logging()
    logger = logging.getLogger("geo-routing-server")
    
    logger.info("Starting geo-routing-server synchronization...")
    logger.info(f"Active enabled modules: {', '.join(Config.ENABLED_CLIENTS)}")
    preset_name = Config.SOURCE_PRESETS.get(Config.ROUTING_SOURCE_PRESET, {}).get("name", "Custom")
    logger.info(f"Routing source preset: {Config.ROUTING_SOURCE_PRESET} ({preset_name})")
    Publisher.reset_session()
    
    # 1. Читаем токен и настройки
    token = Config.get_token()
    
    # 2. Захватываем блокировку
    _lock = acquire_lock(Config.LOCK_FILE)
    
    # 3. Гарантируем права на базовые директории
    Publisher.ensure_dir(Config.STORAGE_DIR)
    Publisher.ensure_dir(Config.STORAGE_DIR / token)
    Publisher.ensure_dir(Config.CACHE_DIR)
    write_sync_status(Config.STORAGE_DIR, token, "running")
    
    # 4. Инициализируем загрузчик
    downloader = Downloader(Config.CACHE_DIR)
    
    # 5. Инициализируем активные процессоры
    clients_set = set(Config.ENABLED_CLIENTS)
    active_processors = []
    
    if any(k in clients_set for k in ("HAPP", "HAPP_DEEPLINK", "HAPP_LOCAL", "HAPP_GEO")):
        active_processors.append(HappProcessor(downloader, Config.STORAGE_DIR, token, Config.DOMAIN))
        
    if any(k in clients_set for k in ("INCY", "INCY_GEO")):
        active_processors.append(IncyProcessor(downloader, Config.STORAGE_DIR, token, Config.DOMAIN))
            
    if not active_processors:
        # Ранний выход при провале старта: фиксируем статус ошибки и выходим с
        # ненулевым кодом, иначе упавший контейнер выглядит «работающим»
        # (в .sync-status.json остался бы running, а код возврата был бы 0)
        logger.error("No valid processors active. Please check ENABLED_CLIENTS in .env")
        write_sync_status(Config.STORAGE_DIR, token, "failed")
        sys.exit(1)
        
    failures = 0
    for processor in active_processors:
        try:
            if not processor.process():
                failures += 1
        except Exception as e:
            logger.error(f"Processor {processor.__class__.__name__} encountered unhandled exception: {e}")
            failures += 1
            
    # Создаем симлинки для локальных сервисов в Docker
    ensure_internal_symlinks(Config.STORAGE_DIR, token)
    
    # Прямая нативная синхронизация с Remnawave API (если настроена)
    remna_ok = True
    if RemnawaveSync.is_configured():
        if not RemnawaveSync.sync(token):
            remna_ok = False
            err_details = "\n• ".join(RemnawaveSync.last_errors) if RemnawaveSync.last_errors else "Не удалось обновить сквады в Remnawave API"
            logger.warning(f"[Remnawave] Synchronization with Remnawave API completed with errors:\n{err_details}")
            TelegramNotifier.alert_failure(f"Ошибка Remnawave API:\n• {err_details}")
    
    if failures > 0:
        err_text = f"Synchronization finished with {failures} failed processor(s)"
        logger.error(err_text)
        TelegramNotifier.alert_failure(err_text)

    all_errors = list(RemnawaveSync.last_errors) if hasattr(RemnawaveSync, "last_errors") else []
    if failures > 0:
        all_errors.append(f"Synchronization finished with {failures} failed processor(s)")

    rules_list = [r for r in Config.get_display_rules()]
    published_files = sorted(list(Publisher.published_registry.keys()))

    if remna_ok and failures == 0:
        write_sync_status(
            Config.STORAGE_DIR,
            token,
            "success",
            failures=0,
            remnawave_ok=True,
            errors=[],
            rules=rules_list,
            generated_files=published_files,
        )
        logger.info("Synchronization completed successfully.")
        banner = print_summary_banner(token, Config.STORAGE_DIR)
        write_sync_summary(Config.STORAGE_DIR, token, banner)
        TelegramNotifier.notify_changes(token, Publisher.published_registry, Publisher.any_file_changed)
    else:
        # Частичная синхронизация (если часть файлов опубликована) или полный сбой
        status_state = "partial" if published_files else "failed"
        write_sync_status(
            Config.STORAGE_DIR,
            token,
            status_state,
            failures=failures,
            remnawave_ok=remna_ok,
            errors=all_errors,
            rules=rules_list,
            generated_files=published_files,
        )
        logger.warning(f"Synchronization completed with warnings/errors (status: {status_state}).")
        banner = print_summary_banner(token, Config.STORAGE_DIR)
        write_sync_summary(Config.STORAGE_DIR, token, banner)
        sys.exit(1)

if __name__ == "__main__":
    main()
