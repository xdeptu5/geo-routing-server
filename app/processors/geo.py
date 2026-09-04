import hashlib
import logging
from pathlib import Path
from typing import Dict, Optional
from app.config import Config
from app.downloader import Downloader, DownloadError
from app.publisher import Publisher

logger = logging.getLogger("geo-routing-server")

class GeoManager:
    """Управление загрузкой и публикацией geo-баз (geoip.dat и geosite.dat)."""
    
    def __init__(self, downloader: Downloader, custom_geo_dir: Path):
        self.downloader = downloader
        self.custom_geo_dir = custom_geo_dir
        self._memory_cache: Dict[str, bytes] = {}
        
    def resolve_and_fetch(self, client: str, geo_type: str, default_json_data: Optional[dict] = None) -> bytes:
        """
        Резолвит источник geo-базы с учетом приоритетов и возвращает байты содержимого.
        Приоритет:
        1. Локальный файл в custom_geo/<client>/<geo_type>.dat или custom_geo/<geo_type>.dat
        2. Кастомный URL из конфигурации (GEOIP_SOURCE_URL / GEOSITE_SOURCE_URL)
        3. URL из DEFAULT.JSON репозитория
        4. Fallback URL на GitHub Releases
        """
        # 1. Проверяем локальные файлы
        local_candidates = [
            self.custom_geo_dir / client / f"{geo_type}.dat",
            self.custom_geo_dir / f"{geo_type}.dat"
        ]
        for candidate in local_candidates:
            if candidate.is_file() and candidate.stat().st_size >= 1024:
                logger.info(f"  Using local {geo_type} file for {client} from {candidate}")
                return candidate.read_bytes()

        # 2. Кастомный URL из .env
        custom_url = Config.GEOIP_SOURCE_URL if geo_type == "geoip" else Config.GEOSITE_SOURCE_URL
        if custom_url:
            if custom_url in self._memory_cache:
                logger.info(f"  Reusing already downloaded {geo_type} for {client}")
                return self._memory_cache[custom_url]
            logger.info(f"  Downloading {geo_type} for {client} from custom URL: {custom_url}")
            url_hash = hashlib.sha256(custom_url.encode("utf-8")).hexdigest()[:8]
            try:
                data = self.downloader.fetch(custom_url, f"geo_{geo_type}_custom_{url_hash}", kind="binary")
                self._memory_cache[custom_url] = data
                return data
            except DownloadError as e:
                logger.warning(f"  Failed to download {geo_type} from custom URL ({e}), falling back to repository/fallback...")

        # 3. Извлечение URL из DEFAULT.JSON
        url = None
        if default_json_data:
            key = "Geoipurl" if geo_type == "geoip" else "Geositeurl"
            url = default_json_data.get(key)

        if url:
            if url in self._memory_cache:
                logger.info(f"  Reusing already downloaded {geo_type} for {client}")
                return self._memory_cache[url]
            logger.info(f"  Downloading {geo_type} for {client} from repository source: {url}")
            try:
                data = self.downloader.fetch(url, f"global_{geo_type}", kind="binary")
                self._memory_cache[url] = data
                return data
            except DownloadError as e:
                logger.warning(f"  Failed to download from primary source ({e}), trying fallback...")

        # 4. Fallback на GitHub Releases
        fallback_url = f"https://github.com/hydraponique/roscomvpn-{geo_type}/releases/latest/download/{geo_type}.dat"
        if fallback_url in self._memory_cache:
            logger.info(f"  Reusing fallback {geo_type} for {client}")
            return self._memory_cache[fallback_url]
        logger.info(f"  Downloading {geo_type} for {client} from fallback: {fallback_url}")
        data = self.downloader.fetch(fallback_url, f"global_{geo_type}_fallback", kind="binary")
        self._memory_cache[fallback_url] = data
        return data

    def sync_client_geo(self, client: str, target_dir: Path, default_json_data: Optional[dict] = None) -> bool:
        """Синхронизирует geoip.dat и geosite.dat с их sha256 для указанного клиента."""
        logger.info(f"Processing {client} GEO databases...")
        success = True
        
        for geo_type in ("geoip", "geosite"):
            try:
                content = self.resolve_and_fetch(client, geo_type, default_json_data)
                filename = f"{geo_type}.dat"
                if not Publisher.publish_geo_with_checksum(target_dir, filename, content):
                    success = False
            except Exception as e:
                logger.error(f"  Error processing {geo_type} for {client}: {e}")
                success = False
                
        return success
