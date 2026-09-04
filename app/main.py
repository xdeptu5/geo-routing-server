import logging
import os
import sys
from pathlib import Path

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
            tmp_link = storage_dir / f".{client}.tmp_link"
            try:
                if tmp_link.is_symlink() or tmp_link.exists():
                    tmp_link.unlink()
                tmp_link.symlink_to(target, target_is_directory=True)
                os.replace(tmp_link, link)
            except Exception:
                try:
                    if link.is_symlink() or link.is_file():
                        link.unlink()
                    link.symlink_to(target, target_is_directory=True)
                except Exception:
                    pass

def print_summary_banner(token: str):
    """Выводит чистый, аккуратный блок со ссылками строго под выбранные модули."""
    base_url = Config.get_base_url(token)
    clients_set = set(Config.ENABLED_CLIENTS)
    
    sections = []
    
    # HAPP блок
    happ_geo = "HAPP" in clients_set or "HAPP_GEO" in clients_set
    happ_deeplink = "HAPP" in clients_set or "HAPP_DEEPLINK" in clients_set or "HAPP_LOCAL" in clients_set
    
    if happ_geo or happ_deeplink:
        happ_lines = ["[HAPP]"]
        if RemnawaveSync.is_configured():
            happ_lines.append("  - Прямая интеграция с Remnawave API: АКТИВНА (автопатч сквадов без сторонних сервисов)")
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
        elif happ_deeplink:
            remna_base = os.getenv("REMNAWAVE_BASE_URL", "").strip()
            remna_token = os.getenv("REMNAWAVE_TOKEN", "").strip()
            if remna_base and not remna_token:
                happ_lines.append("  [!] Remnawave API: указан URL, но отсутствует REMNAWAVE_TOKEN")
                happ_lines.append("      Автопатч не активен. Введите токен через команду: geoserver -> пункт 4")
            else:
                happ_lines.append("  - Правила Happ (диплинки happ://routing/onadd/...):")
                happ_lines.append(f"      • JSONSUB:   {base_url}/HAPP/JSONSUB.DEEPLINK")
                happ_lines.append(f"      • WHITELIST: {base_url}/HAPP/WHITELIST.DEEPLINK")
        if happ_geo:
            ext_geo = Config.get_external_geo_url("HAPP")
            if ext_geo:
                happ_lines.append(f"""  - Внешние ссылки на базы:
      GeoIP:     {ext_geo}/geoip.dat
      GeoSite:   {ext_geo}/geosite.dat""")
            else:
                happ_lines.append(f"""  - Публичные HTTPS ссылки на базы (для клиентов с токеном):
      GeoIP:     {base_url}/HAPP/geoip.dat
      GeoSite:   {base_url}/HAPP/geosite.dat""")
        sections.append("\n".join(happ_lines))

    # INCY блок
    if "INCY" in clients_set or "INCY_GEO" in clients_set:
        incy_lines = ["[INCY]"]
        ext_geo = Config.get_external_geo_url("INCY")
        if ext_geo:
            incy_lines.append(f"""  - Внешние ссылки на базы:
      GeoIP:     {ext_geo}/geoip.dat
      GeoSite:   {ext_geo}/geosite.dat""")
        else:
            incy_lines.append(f"""  - Публичные HTTPS ссылки на базы (для клиентов с токеном):
      GeoIP:     {base_url}/INCY/geoip.dat
      GeoSite:   {base_url}/INCY/geosite.dat""")
        if "INCY" in clients_set:
            incy_lines.append(f"""  - Заголовок подписки (Remnawave / Marzban Autorouting):
      Header Name:  autorouting
      Header Value: incy://autorouting/onadd/{base_url}/INCY/<RULE>.JSON

      Примеры:
      • JSONSUB:   incy://autorouting/onadd/{base_url}/INCY/JSONSUB.JSON
      • WHITELIST: incy://autorouting/onadd/{base_url}/INCY/WHITELIST.JSON""")
        sections.append("\n".join(incy_lines))

    body = "\n\n".join(sections) if sections else "No active clients configured in ENABLED_CLIENTS."

    banner = f"""
===============================================================================
* Geo Routing Server Ready! Endpoints & Integrations:
-------------------------------------------------------------------------------
{body}
===============================================================================
"""
    print(banner, flush=True)

def main():
    setup_logging()
    logger = logging.getLogger("geo-routing-server")
    
    logger.info("Starting geo-routing-server synchronization...")
    logger.info(f"Active enabled modules: {', '.join(Config.ENABLED_CLIENTS)}")
    Publisher.reset_session()
    
    # 1. Читаем токен и настройки
    token = Config.get_token()
    
    # 2. Захватываем блокировку
    _lock = acquire_lock(Config.LOCK_FILE)
    
    # 3. Гарантируем права на базовые директории
    Publisher.ensure_dir(Config.STORAGE_DIR)
    Publisher.ensure_dir(Config.STORAGE_DIR / token)
    Publisher.ensure_dir(Config.CACHE_DIR)
    
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
        logger.warning("No valid processors active. Please check ENABLED_CLIENTS in .env")
        return
        
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

    if remna_ok and failures == 0:
        logger.info("Synchronization completed successfully.")
        print_summary_banner(token)
        TelegramNotifier.notify_changes(token, Publisher.published_registry, Publisher.any_file_changed)
    else:
        logger.warning("Synchronization completed with warnings/errors.")
        print_summary_banner(token)
        if failures > 0:
            sys.exit(1)

if __name__ == "__main__":
    main()
