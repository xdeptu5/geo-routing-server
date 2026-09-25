import hashlib
import json
import logging
import os
from typing import Set
from app.processors.base import BaseProcessor, deeplink_filename_for
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
        # Модуль geo-баз включен для клиента (независимо от места публикации баз)
        geo_enabled = "HAPP" in clients_set or "HAPP_GEO" in clients_set
        # Локальная раздача geo-баз нужна только если внешнее хранилище баз не задано
        needs_geo = geo_enabled and not bool(Config.PUBLIC_GEO_BASE_URL)
        needs_deeplink = "HAPP" in clients_set or "HAPP_DEEPLINK" in clients_set or "HAPP_LOCAL" in clients_set
        
        default_json_data = None
        url = Config.get_default_rule_url(client)
        default_key = f"{client}_{client}" if Config.ROUTING_SOURCE_PRESET == "geogaga" else f"{client}_DEFAULT_orig"
        try:
            raw_bytes = self.downloader.fetch(url, default_key, kind="rule")
            default_json_data = self.parse_rule_payload(raw_bytes, client)
        except Exception as e:
            logger.warning(f"Could not load default rule for {client} from {url}: {e}")

        # 1. Синхронизируем geo-базы (только если включен модуль geo-баз)
        if geo_enabled:
            if Config.PUBLIC_GEO_BASE_URL:
                # Базы публикуются во внешнем хранилище: убираем устаревшие локальные
                # geoip.dat/geosite.dat, оставшиеся от прошлой конфигурации
                self._remove_local_geo_databases(target_dir)
            elif Config.SERVE_GEOIP or Config.SERVE_GEOSITE:
                if not self.geo_manager.sync_client_geo(client, target_dir, default_json_data):
                    success = False

            else:
                # Локальная раздача geo-баз выключена — файлы больше не актуальны
                self._remove_local_geo_databases(target_dir)

        # 2. Генерируем JSON и DEEPLINK для Remnawave / клиентов (только если включен deeplink модуль)
        if needs_deeplink:
            logger.info("Processing HAPP configuration and DEEPLINK files...")
            config_files = self._discover_config_files()
            config_files = Config.get_active_rules(config_files, client="HAPP")
            
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

            if configured_rules and Config.ROUTING_SOURCE_PRESET not in ("geogaga", "vahellame"):
                discovered_by_rule = {file_name.upper(): file_name for file_name in config_files}
                for rule_name in configured_rules:
                    discovered_by_rule.setdefault(rule_name, rule_name)
                config_files = sorted(discovered_by_rule.values(), key=str.upper)
            
            # Определяем ссылки на geo-базы, которые нужно зашить в правила
            base_public_url = Config.get_base_url(self.token)
            ext_geo_url = Config.get_external_geo_url(client)
            if ext_geo_url:
                # Внешний сервер уже раздаёт базы. Его URL должны попадать в
                # диплинк независимо от флагов локальной раздачи SERVE_GEO*.
                geoip_url = f"{ext_geo_url}/geoip.dat"
                geosite_url = f"{ext_geo_url}/geosite.dat"
            elif needs_geo:
                # Базы раздаются с этого же локального сервера
                geoip_url = f"{base_public_url}/{client}/geoip.dat" if Config.SERVE_GEOIP else ""
                geosite_url = f"{base_public_url}/{client}/geosite.dat" if Config.SERVE_GEOSITE else ""
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
                url = Config.get_rule_url(client, file_name)
                
                try:
                    raw_bytes = self.downloader.fetch(url, f"{client}_{file_key}", kind="rule")
                    data = self.parse_rule_payload(raw_bytes, client)
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
                        
                    # Форматированный JSON для отдачи по HTTP (если включена отдача JSON)
                    if Config.should_serve_json(client):
                        json_content = json.dumps(data, indent=2, ensure_ascii=False)
                        if not Publisher.publish_file(target_dir, file_name, json_content):
                            success = False
                            continue
                        published_files.add(file_name)
                        
                    # Генерируем компактный DEEPLINK (happ://routing/onadd/<base64>) без пробелов
                    deeplink_content = self.build_deeplink(client, data)
                    # Единый контракт именования: <БАЗА В ВЕРХНЕМ РЕГИСТРЕ>.DEEPLINK
                    deeplink_filename = deeplink_filename_for(file_name)
                    
                    if Config.should_serve_deeplink(client) or RemnawaveSync.is_configured():
                        if Publisher.publish_file(target_dir, deeplink_filename, deeplink_content):
                            published_files.add(deeplink_filename)
                        else:
                            success = False
                        
                except Exception as e:
                    logger.error(f"Failed to process {file_name} for HAPP: {e}")
                    success = False
                    
            # Очистка выполняется только при полном успехе прогона: при частичном
            # провале загрузки/публикации удалять устаревшие файлы небезопасно
            self._cleanup_obsolete_files(target_dir, published_files, published_ok=success)
                
        return success
