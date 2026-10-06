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

    def __init__(self, downloader: Downloader):
        self.downloader = downloader
        
    def resolve_and_fetch(
        self,
        client: str,
        geo_type: str,
        default_json_data: Optional[dict] = None,
        preset: Optional[str] = None,
    ) -> bytes:
        """
        Резолвит источник geo-базы с учетом приоритетов и возвращает байты содержимого.
        Приоритет:
        1) Проверить локальный DEFAULT.JSON (если есть Geoipurl/Geositeurl) -> скачать.
        2) Иначе использовать URL пресета (geogaga/vahellame/hydraponique)
        3) Если загрузка не удалась -> fallback на официальные релизы GitHub (v2fly/meta-rules-dat / runetfreedom)
        """
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
                # Ключ диск-кэша (ETag + stale-if-error) должен включать сам URL:
                # Geoipurl/Geositeurl берутся из DEFAULT.JSON разных клиентов
                # (HAPP/INCY) и разных пресетов и могут указывать на разные
                # источники. С постоянным ключом "global_{geo_type}" второй
                # fetch отправлял чужой ETag и при сетевой ошибке получал
                # stale-if-error контент от совсем другого URL (например,
                # базу другого пресета) — молча и без ошибки в логах.
                data = self.downloader.fetch(
                    url,
                    f"global_{geo_type}_{self.downloader._safe_cache_key(url)}",
                    kind="binary",
                    trusted_url=False,
                )
                self._memory_cache[url] = data
                return data
            except DownloadError as e:
                logger.warning(f"  Failed to download from primary source ({e}), trying preset fallback...")

        # в) Иначе используем URL пресета (geogaga/vahellame/hydraponique)
        fallback_url = Config.get_preset_geoip_url(preset) if geo_type == "geoip" else Config.get_preset_geosite_url(preset)
        if not fallback_url:
            fallback_url = f"https://github.com/bratishkadrugoimamysynishka/geogaga-client-flavor/releases/latest/download/{geo_type}.dat"
        if fallback_url in self._memory_cache:
            logger.info(f"  Reusing preset {geo_type} for {client}")
            return self._memory_cache[fallback_url]

        active_p = (preset or Config.PRIMARY_PRESET).lower()
        logger.info(f"  Downloading {geo_type} for {client} from preset ({active_p}): {fallback_url}")
        try:
            data = self.downloader.fetch(
                fallback_url,
                f"global_{geo_type}_{active_p}",
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

    def sync_client_geo(
        self,
        client: str,
        target_dir: Path,
        default_json_data: Optional[dict] = None,
        preset: Optional[str] = None,
        key_prefix: str = "",
    ) -> bool:
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
                content = self.resolve_and_fetch(client, geo_type, default_json_data, preset=preset)
                if not Publisher.publish_file(target_dir, filename, content, key_prefix=key_prefix):
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
