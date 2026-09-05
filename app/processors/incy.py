import hashlib
import json
import logging
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
        
        clients_set = set(Config.ENABLED_CLIENTS)
        # Базы скачиваются локально только если включен geo-модуль и нет внешнего URL баз
        needs_geo = ("INCY" in clients_set or "INCY_GEO" in clients_set) and not bool(Config.PUBLIC_GEO_BASE_URL)
        needs_routing = "INCY" in clients_set
        
        default_json_data = None
        if needs_geo or needs_routing:
            try:
                url = f"{Config.ROUTING_SOURCE_REPO}/{client}/DEFAULT.JSON"
                raw_bytes = self.downloader.fetch(url, f"{client}_DEFAULT_orig", kind="json")
                default_json_data = json.loads(raw_bytes.decode("utf-8"))
            except Exception as e:
                logger.warning(f"Could not load {client}/DEFAULT.JSON from repo: {e}")
            
        # 1. Синхронизируем geoip.dat и geosite.dat (если базы раздаются локально)
        if needs_geo:
            if Config.SERVE_GEOIP or Config.SERVE_GEOSITE:
                logger.info("Processing INCY GEO databases...")
                if not self.geo_manager.sync_client_geo(client, target_dir, default_json_data):
                    success = False
            else:
                for f in ("geoip.dat", "geosite.dat"):
                    old_f = target_dir / f
                    if old_f.is_file():
                        try:
                            old_f.unlink()
                        except OSError:
                            pass
            
        # 2. Синхронизируем и модифицируем JSON конфигурации (только если нужен роутинг)
        if needs_routing:
            logger.info(f"Processing {client} configuration files...")
            config_files = self._discover_config_files()
            config_files = Config.get_active_rules(config_files)
            
            ext_geo_url = Config.get_external_geo_url(client)
            if ext_geo_url:
                geoip_public_url = f"{ext_geo_url}/geoip.dat" if Config.SERVE_GEOIP else ""
                geosite_public_url = f"{ext_geo_url}/geosite.dat" if Config.SERVE_GEOSITE else ""
            elif needs_geo:
                base_public_url = Config.get_base_url(self.token)
                geoip_public_url = f"{base_public_url}/{client}/geoip.dat" if Config.SERVE_GEOIP else ""
                geosite_public_url = f"{base_public_url}/{client}/geosite.dat" if Config.SERVE_GEOSITE else ""
            else:
                geoip_public_url = (default_json_data or {}).get("Geoipurl") or Config.GEOIP_SOURCE_URL or ""
                geosite_public_url = (default_json_data or {}).get("Geositeurl") or Config.GEOSITE_SOURCE_URL or ""
            
            published_files: Set[str] = set()
            
            for file_name in config_files:
                # Защита от небезопасных имен файлов
                if not self.is_safe_config_filename(file_name):
                    logger.error(f"Skipping unsafe filename: {file_name}")
                    continue
                    
                logger.info(f"  Processing {file_name}...")
                file_key = file_name.rsplit(".", 1)[0].upper()
                url = f"{Config.ROUTING_SOURCE_REPO}/{client}/{file_name}"
                
                try:
                    raw_bytes = self.downloader.fetch(url, f"{client}_{file_key}", kind="json")
                    data = json.loads(raw_bytes.decode("utf-8"))
                    if not isinstance(data, dict):
                        logger.error(f"Invalid JSON format for {file_name} (expected object): {type(data)}")
                        success = False
                        continue
                    
                    # Подменяем ссылки на локальные
                    if geoip_public_url:
                        data["Geoipurl"] = geoip_public_url
                    if geosite_public_url:
                        data["Geositeurl"] = geosite_public_url
                    
                    # Сохраняем стабильный LastUpdated
                    if not data.get("LastUpdated"):
                        content_hash = int(hashlib.md5(raw_bytes).hexdigest()[:8], 16)
                        data["LastUpdated"] = str(content_hash)
                        
                    # Форматируем и публикуем модифицированный JSON, если включена отдача JSON
                    if Config.should_serve_json(client):
                        json_content = json.dumps(data, indent=2, ensure_ascii=False)
                        if not Publisher.publish_file(target_dir, file_name, json_content):
                            success = False
                            continue
                        published_files.add(file_name)
                        
                    # Генерируем компактный DEEPLINK (схема incy://routing/onadd/<base64>) если включено
                    if Config.should_serve_deeplink(client):
                        deeplink_content = self.build_deeplink(client, data)
                        deeplink_filename = f"{file_name.rsplit('.', 1)[0]}.DEEPLINK"
                        if Publisher.publish_file(target_dir, deeplink_filename, deeplink_content):
                            published_files.add(deeplink_filename)
                        else:
                            success = False
                        
                except Exception as e:
                    logger.error(f"Failed to process {file_name}: {e}")
                    success = False
                
        # 4. Удаляем старые файлы, если они больше не существуют
        if success and needs_routing:
            self._cleanup_obsolete_files(target_dir, published_files)
            
        return success
