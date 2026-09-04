import json
import logging
import os
import re
import urllib.request
import urllib.error
from pathlib import Path
from typing import Dict, List, Optional, Any
from app.config import Config

logger = logging.getLogger("geo-routing-server")

class RemnawaveSync:
    """Прямая нативная синхронизация правил маршрутизации с Remnawave API без сторонних сервисов."""

    ROUTING_HEADER = "routing"

    @classmethod
    def get_api_url(cls) -> str:
        """Нормализует базовый URL Remnawave, гарантируя наличие суффикса /api."""
        raw = os.getenv("REMNAWAVE_BASE_URL", "").strip().rstrip("/")
        if raw and not raw.endswith("/api"):
            raw = f"{raw}/api"
        return raw

    @classmethod
    def is_configured(cls) -> bool:
        base_url = cls.get_api_url()
        token = os.getenv("REMNAWAVE_TOKEN", "").strip()
        return bool(base_url and token)

    @classmethod
    def _get_headers(cls) -> Dict[str, str]:
        token = os.getenv("REMNAWAVE_TOKEN", "").strip()
        base_url = cls.get_api_url()
        
        headers = {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "geo-routing-server",
        }

        # Поддержка Cloudflare Zero Trust / Cloudflare Access Tunnel
        cf_id = os.getenv("CLOUDFLARE_ZERO_TRUST_CLIENT_ID", "").strip() or os.getenv("CF_ACCESS_CLIENT_ID", "").strip()
        cf_secret = os.getenv("CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET", "").strip() or os.getenv("CF_ACCESS_CLIENT_SECRET", "").strip()

        if cf_id and cf_secret:
            headers["CF-Access-Client-Id"] = cf_id
            headers["CF-Access-Client-Secret"] = cf_secret

        if not base_url.startswith("https://"):
            headers["X-Forwarded-Proto"] = "https"
            headers["X-Forwarded-For"] = "127.0.0.1"
        return headers

    @classmethod
    def _api_request(cls, method: str, url: str, payload: Optional[Dict[str, Any]] = None) -> Optional[Dict[str, Any]]:
        headers = cls._get_headers()
        data = json.dumps(payload).encode("utf-8") if payload else None
        
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=15) as res:
                content = res.read().decode("utf-8")
                return json.loads(content) if content else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="ignore")
            logger.error(f"[Remnawave API] HTTP {e.code} on {method} {url}: {err_body}")
            return None
        except Exception as e:
            logger.error(f"[Remnawave API] Connection error on {method} {url}: {e}")
            return None

    UUID_REGEX = re.compile(r"^[A-Za-z0-9_-]+$")

    @classmethod
    def load_squad_configs(cls) -> List[Dict[str, str]]:
        """Загружает список сконфигурированных сквадов из переменных окружения."""
        squads = []
        found_indices = set()
        for k in os.environ:
            m = re.match(r"^(?:REMNAWAVE_)?SQUAD_(\d+)_UUID$", k)
            if m:
                found_indices.add(int(m.group(1)))
        
        for i in sorted(found_indices):
            uuid = os.getenv(f"REMNAWAVE_SQUAD_{i}_UUID", "").strip() or os.getenv(f"SQUAD_{i}_UUID", "").strip()
            rule = os.getenv(f"REMNAWAVE_SQUAD_{i}_RULE", "").strip() or os.getenv(f"SQUAD_{i}_RULE", "").strip()
            
            # Поддержка старого формата SQUAD_i_URL
            old_url = os.getenv(f"SQUAD_{i}_URL", "").strip()
            if not rule and old_url:
                rule = old_url.split("/")[-1].replace(".DEEPLINK", ".JSON").replace(".json", ".JSON")
            
            if not uuid:
                continue
                
            if not cls.UUID_REGEX.match(uuid):
                logger.warning(f"[Remnawave] Skipping invalid UUID format for squad #{i}: '{uuid}'")
                continue
                
            rule = rule.split("/")[-1] if rule else "JSONSUB.JSON"
            squads.append({
                "uuid": uuid.lower(),
                "rule": rule.upper()
            })
        return squads

    @classmethod
    def _read_deeplink_content(cls, happ_dir: Path, rule_name: str) -> Optional[str]:
        """Читает сгенерированный файл .DEEPLINK для указанного правила."""
        base_name = Path(rule_name).name.rsplit(".", 1)[0].upper()
        if not re.match(r"^[A-Za-z0-9_-]+$", base_name):
            logger.error(f"[Remnawave] Invalid rule name format: {rule_name}")
            return None
        deeplink_path = (happ_dir / f"{base_name}.DEEPLINK").resolve()
        try:
            if not deeplink_path.is_relative_to(happ_dir.resolve()):
                logger.error(f"[Remnawave] Path traversal detected in rule: {rule_name}")
                return None
        except AttributeError:
            if not str(deeplink_path).startswith(str(happ_dir.resolve())):
                logger.error(f"[Remnawave] Path traversal detected in rule: {rule_name}")
                return None
        if deeplink_path.is_file():
            try:
                return deeplink_path.read_text(encoding="utf-8").strip()
            except Exception as e:
                logger.error(f"Failed to read deeplink file {deeplink_path}: {e}")
        return None

    @classmethod
    def sync(cls, token: str) -> bool:
        """Синхронизирует сгенерированные HAPP диплинки с API Remnawave."""
        if not cls.is_configured():
            return True

        base_api_url = cls.get_api_url()
        happ_dir = Config.STORAGE_DIR / token / "HAPP"
        
        logger.info("[Remnawave] Starting direct Remnawave API synchronization...")
        
        success = True
        squads = cls.load_squad_configs()
        global_rule = os.getenv("REMNAWAVE_GLOBAL_RULE", "").strip() or os.getenv("GITHUB_RAW_URL", "").strip()
        
        # 1. Синхронизация глобальных настроек подписок (если задано)
        if global_rule:
            rule_file = global_rule.split("/")[-1].replace(".DEEPLINK", ".JSON").upper()
            deeplink = cls._read_deeplink_content(happ_dir, rule_file)
            if deeplink:
                settings_url = f"{base_api_url}/subscription-settings"
                settings_data = cls._api_request("GET", settings_url)
                if settings_data:
                    data = settings_data.get("response", settings_data)
                    settings_uuid = data.get("uuid")
                    current_headers = data.get("customResponseHeaders", {}) or {}
                    
                    if current_headers.get(cls.ROUTING_HEADER) != deeplink:
                        current_headers[cls.ROUTING_HEADER] = deeplink
                        patch_payload = {
                            "uuid": settings_uuid,
                            "customResponseHeaders": current_headers
                        }
                        if cls._api_request("PATCH", settings_url, patch_payload):
                            logger.info("[Remnawave] Successfully updated global subscription-settings routing header!")
                        else:
                            success = False
                    else:
                        logger.info("[Remnawave] Global subscription-settings routing is already up to date.")
                else:
                    logger.error("[Remnawave] Failed to fetch subscription-settings from Remnawave API")
                    success = False
            else:
                logger.warning(f"[Remnawave] Deeplink for global rule {rule_file} not found in {happ_dir}")

        # 2. Синхронизация сквадов (External Squads)
        for squad in squads:
            squad_uuid = squad["uuid"]
            rule_name = squad["rule"]
            deeplink = cls._read_deeplink_content(happ_dir, rule_name)
            
            if not deeplink:
                logger.warning(f"[Remnawave] Deeplink for rule {rule_name} (Squad {squad_uuid}) not found in {happ_dir}")
                continue
                
            squad_url = f"{base_api_url}/external-squads/{squad_uuid}"
            squad_res = cls._api_request("GET", squad_url)
            if not squad_res:
                success = False
                continue
                
            squad_data = squad_res.get("response", squad_res)
            headers_add = squad_data.get("responseHeadersAdd", {}) or {}
            headers_remove = squad_data.get("responseHeadersRemove", []) or []
            
            current_routing = headers_add.get(cls.ROUTING_HEADER, "")
            if current_routing != deeplink:
                headers_add[cls.ROUTING_HEADER] = deeplink
                filtered_remove = [h for h in headers_remove if h.lower() != cls.ROUTING_HEADER]
                
                patch_payload = {
                    "uuid": squad_uuid,
                    "responseHeadersAdd": headers_add,
                    "responseHeadersRemove": filtered_remove
                }
                patch_url = f"{base_api_url}/external-squads"
                if cls._api_request("PATCH", patch_url, patch_payload):
                    logger.info(f"[Remnawave] Successfully updated Squad '{squad_uuid}' with rule '{rule_name}'!")
                else:
                    success = False
            else:
                logger.info(f"[Remnawave] Squad '{squad_uuid}' routing is already up to date.")

        return success
