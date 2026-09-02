import base64
import hashlib
import json
import logging
import os
import re
import urllib.request
from typing import Set
from app.processors.base import BaseProcessor
from app.processors.geo import GeoManager
from app.config import Config
from app.publisher import Publisher

logger = logging.getLogger("geo-routing-server")

class IncyProcessor(BaseProcessor):
    """Обработчик файлов для клиента INCY (geo-базы, модификация JSON, DEEPLINK и автоочистка)."""
    
    CLIENT_NAME = "INCY"
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.geo_manager = GeoManager(self.downloader, Config.CUSTOM_GEO_DIR)

    def process(self) -> bool:
        client = self.CLIENT_NAME
        target_dir = self.client_dir / client
        success = True
        
        # 1. Скачиваем DEFAULT.JSON для извлечения исходных ссылок на geo-базы
        default_json_data = None
        try:
            url = f"{Config.ROUTING_SOURCE_REPO}/{client}/DEFAULT.JSON"
            raw_bytes = self.downloader.fetch(url, f"{client}_DEFAULT_orig", kind="json")
            default_json_data = json.loads(raw_bytes.decode("utf-8"))
        except Exception as e:
            logger.warning(f"Could not load {client}/DEFAULT.JSON from repo: {e}")
            
        # 2. Синхронизируем geoip.dat и geosite.dat
        if not self.geo_manager.sync_client_geo(client, target_dir, default_json_data):
            success = False
            
        # 3. Синхронизируем и модифицируем JSON конфигурации
        logger.info(f"Processing {client} configuration files...")
        config_files = self._discover_config_files()
        
        base_public_url = Config.get_base_url(self.token)
        geoip_public_url = f"{base_public_url}/{client}/geoip.dat"
        geosite_public_url = f"{base_public_url}/{client}/geosite.dat"
        
        published_files: Set[str] = set()
        
        for file_name in config_files:
            # Защита от небезопасных имен файлов
            if not re.match(r"^[A-Za-z0-9._-]+\.json$", file_name, re.IGNORECASE):
                logger.error(f"Skipping unsafe filename: {file_name}")
                continue
                
            logger.info(f"  Processing {file_name}...")
            file_key = file_name.rsplit(".", 1)[0].upper()
            url = f"{Config.ROUTING_SOURCE_REPO}/{client}/{file_name}"
            
            try:
                raw_bytes = self.downloader.fetch(url, f"{client}_{file_key}", kind="json")
                data = json.loads(raw_bytes.decode("utf-8"))
                
                # Подменяем ссылки на локальные
                data["Geoipurl"] = geoip_public_url
                data["Geositeurl"] = geosite_public_url
                
                # Сохраняем стабильный LastUpdated
                if not data.get("LastUpdated"):
                    content_hash = int(hashlib.md5(raw_bytes).hexdigest()[:8], 16)
                    data["LastUpdated"] = str(content_hash)
                    
                # Форматируем и публикуем модифицированный JSON
                json_content = json.dumps(data, indent=2, ensure_ascii=False)
                if not Publisher.publish_file(target_dir, file_name, json_content):
                    success = False
                    continue
                published_files.add(file_name)
                    
                # Генерируем DEEPLINK (схема incy://routing/onadd/<base64>)
                b64_payload = base64.b64encode(json_content.encode("utf-8")).decode("ascii")
                prefix = client.lower()
                deeplink_content = f"{prefix}://routing/onadd/{b64_payload}\n"
                
                deeplink_filename = f"{file_name.rsplit('.', 1)[0]}.DEEPLINK"
                if Publisher.publish_file(target_dir, deeplink_filename, deeplink_content):
                    published_files.add(deeplink_filename)
                else:
                    success = False
                    
            except Exception as e:
                logger.error(f"Failed to process {file_name}: {e}")
                success = False
                
        # 4. Удаляем старые файлы, если они больше не существуют
        if success:
            self._cleanup_obsolete_files(target_dir, published_files)
            
        return success
