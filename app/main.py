import logging
import sys
from datetime import datetime, timezone
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

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%dT%H:%M:%SZ",
        handlers=[logging.StreamHandler(sys.stdout)]
    )

def acquire_lock(lock_path: Path):
    """Блокировка от параллельного запуска нескольких синхронизаций."""
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_file = open(lock_path, "w")
    if HAS_FCNTL:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, IOError):
            print("ERROR: Another sync process is already running!", file=sys.stderr)
            sys.exit(1)
    return lock_file

def print_summary_banner(token: str):
    """Выводит аккуратный блок с готовыми ссылками и заголовками для панелей."""
    base_url = Config.get_base_url(token)
    
    banner = f"""
===============================================================================
* Geo Routing Server Ready! Public Endpoints:
-------------------------------------------------------------------------------
[HAPP]
  - GeoIP:     {base_url}/HAPP/geoip.dat
  - GeoSite:   {base_url}/HAPP/geosite.dat

[INCY]
  - GeoIP:     {base_url}/INCY/geoip.dat
  - GeoSite:   {base_url}/INCY/geosite.dat
  - JSON:      {base_url}/INCY/DEFAULT.JSON
               {base_url}/INCY/JSONSUB.JSON
               {base_url}/INCY/WHITELIST.JSON
  - DEEPLINK:  {base_url}/INCY/DEFAULT.DEEPLINK
               {base_url}/INCY/JSONSUB.DEEPLINK
               {base_url}/INCY/WHITELIST.DEEPLINK

[PANEL AUTOROUTING HEADERS] (Remnawave / Marzban / 3x-ui)
  - Header Name:  autorouting
  - Header Value: incy://autorouting/onadd/{base_url}/INCY/JSONSUB.JSON
===============================================================================
"""
    print(banner, flush=True)

def main():
    setup_logging()
    logger = logging.getLogger("geo-routing-server")
    
    logger.info("Starting geo-routing-server synchronization...")
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
    
    # 5. Запускаем процессоры клиентов
    processors = [
        HappProcessor(downloader, Config.STORAGE_DIR, token, Config.DOMAIN),
        IncyProcessor(downloader, Config.STORAGE_DIR, token, Config.DOMAIN),
    ]
    
    failures = 0
    for processor in processors:
        try:
            if not processor.process():
                failures += 1
        except Exception as e:
            logger.error(f"Processor {processor.__class__.__name__} encountered unhandled exception: {e}")
            failures += 1
            
    if failures > 0:
        err_text = f"Synchronization finished with {failures} failed processor(s)"
        logger.error(err_text)
        TelegramNotifier.alert_failure(err_text)
        sys.exit(1)
        
    logger.info("Synchronization completed successfully.")
    print_summary_banner(token)
    TelegramNotifier.notify_changes(token, Publisher.published_registry, Publisher.any_file_changed)

if __name__ == "__main__":
    main()
