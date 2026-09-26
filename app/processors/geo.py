import logging
from pathlib import Path
from typing import Dict, Optional
from app.config import Config
from app.downloader import Downloader, DownloadError
from app.publisher import Publisher

logger = logging.getLogger("geo-routing-server")

class GeoManager:
    """Управление загрузкой и публикацией geo-баз (geoip.dat и geosite.dat)."""
    
    _memory_cache: Dict[str, bytes] = {}

    OFFICIAL_FALLBACK_URLS: Dict[str, list[str]] = {
        "geoip": [
            "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat",
            "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geoip.dat",
            "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat",
        ],
        "geosite": [
            "https://github.com/v2fly/domain-list-community/releases/latest/download/geosite.dat",
            "https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download/geosite.dat",
            "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat",
        ],
    }

    def __init__(self, downloader: Downloader, custom_geo_dir: Path):
        self.downloader = downloader
        self.custom_geo_dir = custom_geo_dir
        
    def resolve_and_fetch(self, client: str, geo_type: str, default_json_data: Optional[dict] = None) -> bytes:
        """
        Резолвит источник geo-базы с учетом приоритетов и возвращает байты содержимого.
        Приоритет:
        0. Локальный файл в custom_geo/<client>/<geo_type>.dat или custom_geo/<geo_type>.dat
        1. а) Пользовательский URL из .env (GEOIP_SOURCE_URL / GEOSITE_SOURCE_URL), заданный явно
        2. б) Иначе проверить локальный DEFAULT.JSON (если есть)
        3. в) Иначе использовать URL пресета (geogaga/vahellame)
        4. г) Если загрузка не удалась -> fallback на официальные релизы GitHub (v2fly/meta-rules-dat / runetfreedom)
        """
        # 0. Проверяем локальные файлы в custom_geo
        local_candidates = [
            self.custom_geo_dir / client / f"{geo_type}.dat",
            self.custom_geo_dir / f"{geo_type}.dat"
        ]
        for candidate in local_candidates:
            if candidate.is_file():
                content = candidate.read_bytes()
                if self.downloader._validate_content(content, "binary"):
                    logger.info(f"  Using local {geo_type} file for {client} from {candidate}")
                    return content
                logger.warning(f"  Ignoring invalid local {geo_type} file: {candidate}")

        # а) Пользовательский URL из .env (ветка срабатывает только если задан явно)
        custom_url = Config.GEOIP_SOURCE_URL_EXPLICIT if geo_type == "geoip" else Config.GEOSITE_SOURCE_URL_EXPLICIT
        if custom_url:
            if custom_url in self._memory_cache:
                logger.info(f"  Reusing already downloaded {geo_type} for {client}")
                return self._memory_cache[custom_url]
            logger.info(f"  Downloading {geo_type} for {client} from custom URL: {custom_url}")
            try:
                data = self.downloader.fetch(
                    custom_url,
                    f"geo_{geo_type}_custom",
                    kind="binary",
                    trusted_url=True,
                )
                self._memory_cache[custom_url] = data
                return data
            except DownloadError as e:
                logger.warning(f"  Failed to download {geo_type} from custom URL ({e}), falling back to preset/official sources...")

        # б) Иначе проверяем URL из DEFAULT.JSON
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
                data = self.downloader.fetch(
                    url,
                    f"global_{geo_type}",
                    kind="binary",
                    trusted_url=False,
                )
                self._memory_cache[url] = data
                return data
            except DownloadError as e:
                logger.warning(f"  Failed to download from primary source ({e}), trying preset fallback...")

        # в) Иначе используем URL пресета (geogaga/vahellame)
        preset_urls = Config.SOURCE_PRESETS.get(Config.ROUTING_SOURCE_PRESET, {})
        fallback_url = preset_urls.get("geoip_url" if geo_type == "geoip" else "geosite_url", "")
        if not fallback_url:
            fallback_url = f"https://github.com/bratishkadrugoimamysynishka/geogaga-client-flavor/releases/latest/download/{geo_type}.dat"
        if fallback_url in self._memory_cache:
            logger.info(f"  Reusing preset {geo_type} for {client}")
            return self._memory_cache[fallback_url]

        logger.info(f"  Downloading {geo_type} for {client} from preset: {fallback_url}")
        try:
            data = self.downloader.fetch(
                fallback_url,
                f"global_{geo_type}_fallback",
                kind="binary",
                trusted_url=False,
            )
            self._memory_cache[fallback_url] = data
            return data
        except DownloadError as e:
            logger.warning(f"  Failed to download from preset fallback {fallback_url} ({e}), trying official GitHub releases...")

        # г) Fallback на официальные релизы GitHub (v2fly / meta-rules-dat / runetfreedom)
        official_fallbacks = self.OFFICIAL_FALLBACK_URLS.get(geo_type, [])
        last_error = None
        for official_url in official_fallbacks:
            if official_url in self._memory_cache:
                logger.info(f"  Reusing official fallback {geo_type} for {client}")
                return self._memory_cache[official_url]
            logger.info(f"  Downloading {geo_type} for {client} from official release: {official_url}")
            try:
                data = self.downloader.fetch(
                    official_url,
                    f"global_{geo_type}_official_{self.downloader._safe_cache_key(official_url)}",
                    kind="binary",
                    trusted_url=False,
                )
                self._memory_cache[official_url] = data
                return data
            except DownloadError as e:
                logger.warning(f"  Failed to download from official fallback {official_url}: {e}")
                last_error = e

        raise DownloadError(
            f"Failed to resolve and fetch {geo_type} for {client} from all available sources. Last error: {last_error}"
        )

    def sync_client_geo(self, client: str, target_dir: Path, default_json_data: Optional[dict] = None) -> bool:
        """Синхронизирует geoip.dat и geosite.dat для указанного клиента."""
        logger.info(f"Processing {client} GEO databases...")
        success = True
        
        for geo_type in ("geoip", "geosite"):
            filename = f"{geo_type}.dat"
            is_enabled = Config.SERVE_GEOIP if geo_type == "geoip" else Config.SERVE_GEOSITE
            if not is_enabled:
                disabled_file = target_dir / filename
                if disabled_file.is_file():
                    try:
                        disabled_file.unlink()
                        logger.info(f"  Removed disabled {filename} for {client}")
                    except OSError:
                        pass
                continue

            try:
                content = self.resolve_and_fetch(client, geo_type, default_json_data)
                if not Publisher.publish_file(target_dir, filename, content):
                    success = False
                # Очищаем устаревшие .sha256 файлы, если они остались от старых версий
                old_sha = target_dir / f"{filename}.sha256"
                if old_sha.is_file():
                    try:
                        old_sha.unlink()
                    except OSError:
                        pass
            except Exception as e:
                logger.error(f"  Error processing {geo_type} for {client}: {e}")
                success = False
                
        return success
