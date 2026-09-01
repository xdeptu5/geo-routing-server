import json
import logging
from app.processors.base import BaseProcessor
from app.processors.geo import GeoManager
from app.config import Config

logger = logging.getLogger("routing-manager")

class HappProcessor(BaseProcessor):
    """Обработчик файлов для клиента HAPP (синхронизация geoip и geosite)."""
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.geo_manager = GeoManager(self.downloader, Config.CUSTOM_GEO_DIR)
        
    def process(self) -> bool:
        client = "HAPP"
        target_dir = self.client_dir / client
        
        # Скачиваем DEFAULT.JSON для извлечения актуальных ссылок на базы
        default_json_data = None
        try:
            url = f"{Config.ROUTING_SOURCE_REPO}/{client}/DEFAULT.JSON"
            raw_bytes = self.downloader.fetch(url, f"{client}_DEFAULT_orig", kind="json")
            default_json_data = json.loads(raw_bytes.decode("utf-8"))
        except Exception as e:
            logger.warning(f"Could not load {client}/DEFAULT.JSON from repo: {e}")
            
        return self.geo_manager.sync_client_geo(client, target_dir, default_json_data)
