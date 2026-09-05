import hashlib
import json
import logging
import os
from typing import Set
from app.processors.base import BaseProcessor
from app.processors.geo import GeoManager
from app.config import Config
from app.publisher import Publisher
from app.remnawave import RemnawaveSync

logger = logging.getLogger("geo-routing-server")

class HappProcessor(BaseProcessor):
    """Модульный обработчик файлов HAPP: гео-базы, модификация JSON и генерация DEEPLINK."""
    
    CLIENT_NAME = "HAPP"
    
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.geo_manager = GeoManager(self.downloader, Config.CUSTOM_GEO_DIR)

    def process(self) -> bool:
        client = self.CLIENT_NAME
        target_dir = self.client_dir / client
        success = True
        
        # Определяем, какие подмодули активны для HAPP
        clients_set = set(Config.ENABLED_CLIENTS)
        needs_geo = "HAPP" in clients_set or "HAPP_GEO" in clients_set
        needs_deeplink = "HAPP" in clients_set or "HAPP_DEEPLINK" in clients_set or "HAPP_LOCAL" in clients_set
        
        default_json_data = None
        try:
            url = f"{Config.ROUTING_SOURCE_REPO}/{client}/DEFAULT.JSON"
            raw_bytes = self.downloader.fetch(url, f"{client}_DEFAULT_orig", kind="json")
            default_json_data = json.loads(raw_bytes.decode("utf-8"))
        except Exception as e:
            logger.warning(f"Could not load {client}/DEFAULT.JSON from repo: {e}")

        # 1. Синхронизируем geo-базы (только если включен модуль geo-баз)
        if needs_geo:
            logger.info("Processing HAPP GEO databases...")
            if not self.geo_manager.sync_client_geo(client, target_dir, default_json_data):
                success = False

        # 2. Генерируем JSON и DEEPLINK для Remnawave / клиентов (только если включен deeplink модуль)
        if needs_deeplink:
            logger.info("Processing HAPP configuration and DEEPLINK files...")
            config_files = self._discover_config_files()
            
            # Если настроены конкретные сквады Remnawave, генерируем ТОЛЬКО запрошенные правила
            squads = RemnawaveSync.load_squad_configs()
            configured_rules = set()
            for sq in squads:
                r = sq.get("rule", "").strip().upper()
                if r:
                    r_name = r.split("/")[-1]
                    configured_rules.add(r_name if r_name.endswith(".JSON") else f"{r_name}.JSON")
            global_rule = os.getenv("REMNAWAVE_GLOBAL_RULE", "").strip().upper()
            if global_rule:
                g_name = global_rule.split("/")[-1]
                configured_rules.add(g_name if g_name.endswith(".JSON") else f"{g_name}.JSON")

            if configured_rules:
                discovered_by_rule = {file_name.upper(): file_name for file_name in config_files}
                for rule_name in configured_rules:
                    discovered_by_rule.setdefault(rule_name, rule_name)
                config_files = sorted(discovered_by_rule.values(), key=str.upper)
            
            # Определяем ссылки на geo-базы, которые нужно зашить в правила
            base_public_url = Config.get_base_url(self.token)
            ext_geo_url = Config.get_external_geo_url(client)
            if ext_geo_url:
                # Указан валидный внешний сервер geo-баз
                geoip_url = f"{ext_geo_url}/geoip.dat"
                geosite_url = f"{ext_geo_url}/geosite.dat"
            elif needs_geo:
                # Базы раздаются с этого же локального сервера
                geoip_url = f"{base_public_url}/{client}/geoip.dat"
                geosite_url = f"{base_public_url}/{client}/geosite.dat"
            else:
                # Базы не раздаются локально — берем исходные upstream URL
                geoip_url = (default_json_data or {}).get("Geoipurl") or Config.GEOIP_SOURCE_URL or ""
                geosite_url = (default_json_data or {}).get("Geositeurl") or Config.GEOSITE_SOURCE_URL or ""
            
            published_files: Set[str] = set()
            
            for file_name in config_files:
                if not self.is_safe_config_filename(file_name):
                    logger.error(f"Skipping unsafe filename: {file_name}")
                    continue
                    
                logger.info(f"  Processing {file_name} for HAPP...")
                file_key = file_name.rsplit(".", 1)[0].upper()
                url = f"{Config.ROUTING_SOURCE_REPO}/{client}/{file_name}"
                
                try:
                    raw_bytes = self.downloader.fetch(url, f"{client}_{file_key}", kind="json")
                    data = json.loads(raw_bytes.decode("utf-8"))
                    if not isinstance(data, dict):
                        logger.error(f"Invalid JSON format for {file_name} (expected object): {type(data)}")
                        success = False
                        continue
                    
                    if geoip_url:
                        data["Geoipurl"] = geoip_url
                    if geosite_url:
                        data["Geositeurl"] = geosite_url
                    
                    if not data.get("LastUpdated"):
                        content_hash = int(hashlib.md5(raw_bytes).hexdigest()[:8], 16)
                        data["LastUpdated"] = str(content_hash)
                        
                    # Форматированный JSON для отдачи по HTTP
                    json_content = json.dumps(data, indent=2, ensure_ascii=False)
                    if not Publisher.publish_file(target_dir, file_name, json_content):
                        success = False
                        continue
                    published_files.add(file_name)
                        
                    # Генерируем компактный DEEPLINK (happ://routing/onadd/<base64>) без пробелов (сокращение размера заголовка на 40%)
                    deeplink_content = self.build_deeplink(client, data)
                    
                    deeplink_filename = f"{file_name.rsplit('.', 1)[0]}.DEEPLINK"
                    if Publisher.publish_file(target_dir, deeplink_filename, deeplink_content):
                        published_files.add(deeplink_filename)
                    else:
                        success = False
                        
                except Exception as e:
                    logger.error(f"Failed to process {file_name} for HAPP: {e}")
                    success = False
                    
            if success:
                self._cleanup_obsolete_files(target_dir, published_files)
                
        return success
