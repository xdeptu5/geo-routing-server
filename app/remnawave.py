import json
import logging
import os
import re
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path
from typing import Dict, List, Optional, Any
from app.config import Config
from app.processors.base import deeplink_filename_for

logger = logging.getLogger("geo-routing-server")

class RemnawaveSync:
    """Прямая нативная синхронизация правил маршрутизации с Remnawave API без сторонних сервисов."""

    ROUTING_HEADER = "routing"

    class _AuthorizedRedirectHandler(urllib.request.HTTPRedirectHandler):
        """Разрешает авторизованные redirect только внутри исходного origin."""

        @staticmethod
        def _origin(url: str) -> tuple[str, str, Optional[int]]:
            parsed = urllib.parse.urlsplit(url)
            default_port = 443 if parsed.scheme.lower() == "https" else 80
            return parsed.scheme.lower(), (parsed.hostname or "").lower(), parsed.port or default_port

        def redirect_request(self, req, fp, code, msg, headers, newurl):
            protected_headers = (
                "Authorization",
                "CF-Access-Client-Id",
                "CF-Access-Client-Secret",
            )
            has_credentials = any(req.has_header(header) for header in protected_headers)
            if has_credentials and self._origin(req.full_url) != self._origin(newurl):
                raise urllib.error.HTTPError(
                    newurl,
                    code,
                    "Refusing to forward credentials across origins",
                    headers,
                    fp,
                )
            return super().redirect_request(req, fp, code, msg, headers, newurl)

    @classmethod
    def get_api_url(cls) -> str:
        """Нормализует базовый URL Remnawave, гарантируя наличие суффикса /api.

        Толерантно к записи в .env: 'https://host', 'https://host/',
        'https://host/api' и 'https://host/api/' дают одинаковый результат.
        """
        raw = os.getenv("REMNAWAVE_BASE_URL", "").strip().rstrip("/")
        if not raw:
            return ""
        if not re.search(r"/api$", raw, flags=re.IGNORECASE):
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
        # Пустой объект {} — валидное тело запроса и должен уходить в него;
        # None означает «тела нет». Проверка через `if payload` превращала {} в None
        data = json.dumps(payload).encode("utf-8") if payload is not None else None
        
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            opener = urllib.request.build_opener(cls._AuthorizedRedirectHandler())
            with opener.open(req, timeout=15) as res:
                content = res.read().decode("utf-8")
                return json.loads(content) if content else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="ignore")
            logger.error(f"[Remnawave API] HTTP {e.code} on {method} {url}: {err_body}")
            if "A188" in err_body or "Get external squad by UUID error" in err_body:
                uuid_hint = url.rstrip("/").split("/")[-1]
                logger.error(
                    f"[Remnawave] Ошибка Remnawave A188: Сквад '{uuid_hint}' не найден во ВНЕШНИХ сквадах!\n"
                    f"   -> Убедитесь, что в панели Remnawave вы используете раздел: Сквады -> ВНЕШНИЕ сквады (External Squads).\n"
                    f"   -> Не используйте 'Внутренние сквады' (Internal Squads) — правила Happ работают только для внешних сквадов."
                )
            return None
        except Exception as e:
            logger.error(f"[Remnawave API] Connection error on {method} {url}: {e}")
            return None

    UUID_REGEX = re.compile(r"^[A-Za-z0-9_-]+$")
    cached_squad_names: Dict[str, str] = {}
    last_errors: List[str] = []

    @classmethod
    def get_squad_name(cls, squad_uuid: str) -> str:
        """Возвращает читаемое имя сквада, если доступно."""
        squad_uuid = (squad_uuid or "").lower()
        if squad_uuid in cls.cached_squad_names:
            return cls.cached_squad_names[squad_uuid]
        for k, v in os.environ.items():
            m = re.match(r"^(?:REMNAWAVE_)?SQUAD_(\d+)_UUID$", k)
            if m and (v or "").strip().lower() == squad_uuid:
                idx = m.group(1)
                name = (os.getenv(f"REMNAWAVE_SQUAD_{idx}_NAME") or os.getenv(f"SQUAD_{idx}_NAME") or "").strip()
                if name:
                    cls.cached_squad_names[squad_uuid] = name
                    return name
        return ""

    @classmethod
    def fetch_all_squad_names(cls) -> Dict[str, str]:
        """Запрашивает имена всех доступных внешних сквадов из Remnawave API."""
        if not cls.is_configured():
            return cls.cached_squad_names
        try:
            url = f"{cls.get_api_url()}/external-squads"
            res = cls._api_request("GET", url)
            if res is not None:
                raw = res.get("response", res.get("data", []))
                if isinstance(raw, dict):
                    raw = raw.get("externalSquads", raw.get("items", []))
                if isinstance(raw, list):
                    for s in raw:
                        if isinstance(s, dict) and "uuid" in s:
                            u = str(s["uuid"]).lower()
                            if "name" in s and s["name"]:
                                cls.cached_squad_names[u] = s["name"]
        except Exception:
            pass
        return cls.cached_squad_names

    @classmethod
    def load_squad_configs(cls) -> List[Dict[str, str]]:
        """Загружает список сконфигурированных сквадов: сначала из squads.json, а при его отсутствии — из переменных окружения."""
        try:
            from app.squads import SquadManager
            manager = SquadManager()
            file_squads = manager.list_squads()
            if file_squads:
                for s in file_squads:
                    if s.get("name") and s.get("uuid"):
                        cls.cached_squad_names[s["uuid"].lower()] = s["name"]
                return file_squads
        except Exception:
            pass

        squads = []
        found_indices = set()
        for k in os.environ:
            m = re.match(r"^(?:REMNAWAVE_)?SQUAD_(\d+)_UUID$", k)
            if m:
                found_indices.add(int(m.group(1)))
        
        for i in sorted(found_indices):
            uuid = os.getenv(f"REMNAWAVE_SQUAD_{i}_UUID", "").strip() or os.getenv(f"SQUAD_{i}_UUID", "").strip()
            rule = os.getenv(f"REMNAWAVE_SQUAD_{i}_RULE", "").strip() or os.getenv(f"SQUAD_{i}_RULE", "").strip()
            name = os.getenv(f"REMNAWAVE_SQUAD_{i}_NAME", "").strip() or os.getenv(f"SQUAD_{i}_NAME", "").strip()
            
            # Поддержка старого формата SQUAD_i_URL
            old_url = os.getenv(f"SQUAD_{i}_URL", "").strip()
            if not rule and old_url:
                rule = old_url.split("/")[-1].replace(".DEEPLINK", ".JSON").replace(".json", ".JSON")
            
            if not uuid:
                continue
                
            if not cls.UUID_REGEX.match(uuid):
                logger.warning(f"[Remnawave] Skipping invalid UUID format for squad #{i}: '{uuid}'")
                continue
                
            default_rule = Config.get_active_rules([], "HAPP")[0] if Config.get_active_rules([], "HAPP") else "HAPP.JSON"
            rule = rule.split("/")[-1] if rule else default_rule
            squad_item = {
                "uuid": uuid.lower(),
                "rule": rule.upper()
            }
            if name:
                squad_item["name"] = name
                cls.cached_squad_names[uuid.lower()] = name
            squads.append(squad_item)
        return squads

    @classmethod
    def _read_deeplink_content(cls, happ_dir: Path, rule_name: str) -> Optional[str]:
        """Читает сгенерированный файл .DEEPLINK для указанного правила.

        Имя файла берётся из общего контракта именования (deeplink_filename_for):
        <БАЗА В ВЕРХНЕМ РЕГИСТРЕ>.DEEPLINK — ровно так же его пишет publisher.
        """
        base_name = Path(rule_name).name.rsplit(".", 1)[0].upper()
        if not re.match(r"^[A-Za-z0-9_.-]+$", base_name):
            logger.error(f"[Remnawave] Invalid rule name format: {rule_name}")
            return None
        deeplink_path = (happ_dir / deeplink_filename_for(rule_name)).resolve()
        try:
            if not deeplink_path.is_relative_to(happ_dir.resolve()):
                logger.error(f"[Remnawave] Path traversal detected in rule: {rule_name}")
                return None
        except AttributeError:
            if not str(deeplink_path).startswith(str(happ_dir.resolve()) + os.sep):
                logger.error(f"[Remnawave] Path traversal detected in rule: {rule_name}")
                return None
        if deeplink_path.is_file():
            try:
                return deeplink_path.read_text(encoding="utf-8").strip()
            except Exception as e:
                logger.error(f"Failed to read deeplink file {deeplink_path}: {e}")
                return None

        # Регистр имени файла задаёт источник, а правило из конфигурации обычно
        # приходит в верхнем регистре: если точное имя не найдено, ищем файл,
        # отличающийся только регистром (например, записанный старой версией).
        target_name = deeplink_path.name.lower()
        try:
            variants = [p for p in happ_dir.iterdir() if p.is_file() and p.name.lower() == target_name]
        except OSError:
            variants = []
        if len(variants) == 1:
            logger.info(
                f"[Remnawave] Файл {deeplink_path.name} найден в другом регистре: {variants[0].name}"
            )
            try:
                return variants[0].read_text(encoding="utf-8").strip()
            except Exception as e:
                logger.error(f"Failed to read deeplink file {variants[0]}: {e}")
        elif len(variants) > 1:
            logger.warning(
                f"[Remnawave] Несколько файлов совпадают с {deeplink_path.name} по регистру: "
                f"{sorted(v.name for v in variants)} — уточните имя правила"
            )
        return None

    @classmethod
    def sync(cls, token: str) -> bool:
        """Синхронизирует сгенерированные HAPP диплинки с API Remnawave."""
        if not cls.is_configured():
            return True

        base_api_url = cls.get_api_url()
        happ_dir = Config.STORAGE_DIR / token / "HAPP"
        
        logger.info("[Remnawave] Starting direct Remnawave API synchronization...")
        
        cls.last_errors = []
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
                if settings_data is not None:
                    data = settings_data.get("response", settings_data)
                    settings_uuid = data.get("uuid")
                    current_headers = data.get("customResponseHeaders", {}) or {}
                    
                    if current_headers.get(cls.ROUTING_HEADER) != deeplink:
                        current_headers[cls.ROUTING_HEADER] = deeplink
                        patch_payload = {
                            "uuid": settings_uuid,
                            "customResponseHeaders": current_headers
                        }
                        if cls._api_request("PATCH", settings_url, patch_payload) is not None:
                            logger.info("[Remnawave] Successfully updated global subscription-settings routing header!")
                        else:
                            cls.last_errors.append("Не удалось обновить глобальные subscription-settings в Remnawave")
                            success = False
                    else:
                        logger.info("[Remnawave] Global subscription-settings routing is already up to date.")
                else:
                    logger.error("[Remnawave] Failed to fetch subscription-settings from Remnawave API")
                    cls.last_errors.append("Не удалось загрузить subscription-settings из Remnawave API")
                    success = False
            else:
                error = f"Настроенный файл {deeplink_filename_for(rule_file)} не найден в {happ_dir}"
                logger.error(f"[Remnawave] {error}")
                cls.last_errors.append(error)
                success = False

        # 2. Синхронизация сквадов (External Squads)
        if squads:
            if not cls.sync_squads(squads, happ_dir):
                success = False

        return success

    @classmethod
    def sync_squads(
        cls,
        squads: List[Dict[str, str]],
        happ_dir: Path,
        client: Any = None,
    ) -> bool:
        """Синхронизирует список сквадов с Remnawave API."""
        api_client = client if client is not None else cls
        api_req = getattr(api_client, "_api_request", cls._api_request)
        is_conf = getattr(api_client, "is_configured", cls.is_configured)

        if not is_conf():
            logger.warning("[Remnawave] API is not configured, skipping squad sync.")
            return True

        base_api_url = getattr(api_client, "get_api_url", cls.get_api_url)()
        cls.last_errors = []
        success = True

        # Опрашиваем список всех существующих внешних сквадов для валидации и ускорения
        known_squads: Dict[str, Dict[str, Any]] = {}
        ext_squads_url = f"{base_api_url}/external-squads"
        all_ext_res = api_req("GET", ext_squads_url)
        if all_ext_res is not None:
            raw_squads = all_ext_res.get("response", all_ext_res.get("data", []))
            if isinstance(raw_squads, dict):
                raw_squads = raw_squads.get("externalSquads", raw_squads.get("items", []))
            if isinstance(raw_squads, list):
                for s in raw_squads:
                    if isinstance(s, dict) and "uuid" in s:
                        u = str(s["uuid"]).lower()
                        known_squads[u] = s
                        if "name" in s and s["name"]:
                            cls.cached_squad_names[u] = s["name"]

                logger.info(f"[Remnawave] Найдено внешних сквадов в панели: {len(known_squads)}")
                if known_squads:
                    names_preview = ", ".join([f"'{s.get('name', 'Без имени')}' ({u})" for u, s in known_squads.items()])
                    logger.info(f"[Remnawave] Доступные внешние сквады: {names_preview}")
                else:
                    logger.warning(
                        "[Remnawave] В панели Remnawave список внешних сквадов пуст! "
                        "Создайте сквад в меню: Сквады -> Внешние сквады (External Squads)."
                    )

        for squad in squads:
            squad_uuid = squad["uuid"]
            rule_name = squad["rule"]
            s_name = cls.get_squad_name(squad_uuid) or squad.get("name")
            s_desc = f"Squad '{s_name}' ({squad_uuid})" if s_name else f"Squad '{squad_uuid}'"
            deeplink = cls._read_deeplink_content(happ_dir, rule_name)

            # Если диплинк не найден, проверяем fallback на дефолтное правило пресета
            if not deeplink:
                default_rule = Config.get_active_rules([], "HAPP")[0] if Config.get_active_rules([], "HAPP") else "HAPP.JSON"
                if default_rule.upper() != rule_name.upper():
                    fb_deeplink = cls._read_deeplink_content(happ_dir, default_rule)
                    if fb_deeplink:
                        logger.warning(
                            f"[Remnawave] Файл правила '{rule_name}' для {s_desc} не найден. "
                            f"Текущий пресет '{Config.ROUTING_SOURCE_PRESET}' — автоматически используем {deeplink_filename_for(default_rule)}"
                        )
                        deeplink = fb_deeplink

            if not deeplink:
                deeplink_name = deeplink_filename_for(rule_name)
                error = f"Настроенный файл {deeplink_name} для {s_desc} не найден в {happ_dir}"
                logger.error(f"[Remnawave] {error}")
                cls.last_errors.append(error)
                success = False
                continue

            if all_ext_res is not None and squad_uuid not in known_squads:
                err_msg = f"{s_desc} не найден во внешних сквадах (возможно, удалён в панели)"
                logger.error(
                    f"[Remnawave] {err_msg}!\n"
                    f"   -> Проверьте: в панели Remnawave должен быть создан сквад в меню 'Внешние сквады' (не 'Внутренние').\n"
                    f"   -> Доступные внешние сквады в панели: {list(known_squads.keys())}"
                )
                cls.last_errors.append(err_msg)
                success = False
                continue

            squad_data = None
            if known_squads and squad_uuid in known_squads and "responseHeadersAdd" in known_squads[squad_uuid]:
                squad_data = known_squads[squad_uuid]
            else:
                squad_url = f"{base_api_url}/external-squads/{squad_uuid}"
                squad_res = api_req("GET", squad_url)
                if squad_res is None:
                    cls.last_errors.append(f"Не удалось получить данные для {s_desc}")
                    success = False
                    continue
                squad_data = squad_res.get("response", squad_res)

            headers_add = squad_data.get("responseHeadersAdd", {}) or {}
            headers_remove = squad_data.get("responseHeadersRemove", []) or []

            current_routing = headers_add.get(cls.ROUTING_HEADER, "")
            if current_routing != deeplink:
                headers_add[cls.ROUTING_HEADER] = deeplink
                filtered_remove = [h for h in headers_remove if str(h).lower() != cls.ROUTING_HEADER]

                patch_payload = {
                    "uuid": squad_uuid,
                    "responseHeadersAdd": headers_add,
                    "responseHeadersRemove": filtered_remove,
                }
                patch_url = f"{base_api_url}/external-squads"
                if api_req("PATCH", patch_url, patch_payload) is not None:
                    logger.info(f"[Remnawave] Successfully updated {s_desc} with rule '{rule_name}'!")
                else:
                    cls.last_errors.append(f"Не удалось отправить PATCH для {s_desc}")
                    success = False
            else:
                logger.info(f"[Remnawave] {s_desc} routing is already up to date.")

        return success
