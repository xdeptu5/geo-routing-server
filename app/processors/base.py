import base64
import hashlib
import json
import logging
import re
import urllib.request
from abc import ABC
from pathlib import Path
from typing import List, Optional, Set, Tuple
from app.downloader import Downloader

logger = logging.getLogger("geo-routing-server")

def deeplink_filename_for(file_name: str) -> str:
    """Единый контракт именования файлов диплинков: <БАЗА В ВЕРХНЕМ РЕГИСТРЕ>.DEEPLINK.

    Именно так имя формирует publisher (happ.py/incy.py) и именно так его ищет
    remnawave.py. Каталог раздачи чувствителен к регистру, поэтому расходиться
    нельзя: remnawave иначе не находит файл и не публикует диплинк в сквад.
    """
    base_name = Path(file_name).name.rsplit(".", 1)[0].upper()
    return f"{base_name}.DEEPLINK"

class BaseProcessor(ABC):
    """Базовый класс процессора для клиентов маршрутизации."""
    
    # Подклассы переопределяют:
    CLIENT_NAME: str = ""
    FALLBACK_FILES: List[str] = ["DEFAULT.JSON", "JSONSUB.JSON", "WHITELIST.JSON"]
    
    def __init__(
        self,
        downloader: Downloader,
        storage_dir: Path,
        token: str,
        domain: str,
        preset_name: Optional[str] = None,
    ):
        self.downloader = downloader
        self.storage_dir = storage_dir
        self.token = token
        self.domain = domain
        self.client_dir = storage_dir / token
        self.is_fallback_discovery: bool = False

        from app.config import Config
        self.preset_name = (preset_name or Config.PRIMARY_PRESET).lower()
        if preset_name and preset_name.lower() != Config.PRIMARY_PRESET.lower():
            self.preset_prefix = preset_name.upper()
            self.target_base_dir = self.client_dir / self.preset_prefix
        else:
            self.preset_prefix = ""
            self.target_base_dir = self.client_dir

        from app.processors.geo import GeoManager
        self.geo_manager = GeoManager(downloader)

    @staticmethod
    def is_safe_config_filename(name: str) -> bool:
        """Accept a plain JSON filename and reject paths or hidden files."""
        return bool(re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]*\.json", name, re.IGNORECASE))

    @staticmethod
    def build_deeplink(client: str, payload: dict) -> str:
        """Encode a routing object using the URL scheme accepted by the client."""
        compact_json = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
        encoded = base64.b64encode(compact_json.encode("utf-8")).decode("ascii")
        return f"{client.lower()}://routing/onadd/{encoded}\n"

    @staticmethod
    def decode_deeplink(deeplink: str, client: str) -> dict:
        """Decode a generated deeplink for tests and internal validation."""
        prefix = f"{client.lower()}://routing/onadd/"
        if not deeplink.startswith(prefix):
            raise ValueError("deeplink client prefix does not match")
        return json.loads(base64.b64decode(deeplink[len(prefix):].strip()).decode("utf-8"))

    @classmethod
    def parse_rule_payload(cls, raw_bytes: bytes, client: str) -> dict:
        """Парсит полученные данные правила — чистый JSON либо deeplink onadd/base64.

        Принимает обе формы схемы (как и Downloader._validate_content для kind="rule"):
        "<client>://routing/onadd/<b64>" и "<client>://autorouting/onadd/<b64>"
        (последнюю использует Incy: "incy://autorouting/onadd/..."). Раньше здесь
        матчилась только форма "routing/onadd", поэтому содержимое, уже принятое
        загрузчиком как валидное правило, здесь могло не распарситься.
        Base64 допускается как в обычном, так и в URL-safe алфавите (с символами
        '-'/'_'), с паддингом '=' или без него.
        """
        text = raw_bytes.decode("utf-8", errors="replace").strip()
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                return data
        except Exception:
            pass

        pattern = rf"{client.lower()}://(?:routing|autorouting)/onadd/([A-Za-z0-9+/_-]+=*)"
        match = re.search(pattern, text)
        if match:
            b64_str = match.group(1)
            padded = b64_str + "=" * (-len(b64_str) % 4)
            decoder = base64.urlsafe_b64decode if ("-" in b64_str or "_" in b64_str) else base64.b64decode
            decoded_json = decoder(padded).decode("utf-8")
            data = json.loads(decoded_json)
            if isinstance(data, dict):
                return data

        raise ValueError(f"Could not parse {client} rule payload as JSON or deeplink")
        
    # ------------------------------------------------------------------
    # Конвейер обработки клиента. Общий для Happ и Incy; различия — в двух
    # точках расширения ниже, которые переопределяет подкласс.
    # ------------------------------------------------------------------

    def _extra_rule_files(self) -> Set[str]:
        """Правила, которые нужно сгенерировать сверх списка пресета."""
        return set()

    def _should_publish_deeplink(self) -> bool:
        from app.config import Config

        return Config.should_serve_deeplink(self.CLIENT_NAME)

    def process(self) -> bool:
        """Гео-базы и правила клиента. Возвращает True, если всё опубликовано."""
        from app.config import Config

        client = self.CLIENT_NAME
        target_dir = self.target_base_dir / client
        rules_enabled = Config.client_enabled(client, "rules")
        # Базы раздаются с этого сервера, только если модуль баз включён и
        # они не вынесены на внешний узел (PUBLIC_GEO_BASE_URL)
        geo_local = Config.client_enabled(client, "geo") and not Config.PUBLIC_GEO_BASE_URL
        success = True

        default_rule = self._load_default_rule() if (geo_local or rules_enabled) else None

        if geo_local and (Config.SERVE_GEOIP or Config.SERVE_GEOSITE):
            if not self.geo_manager.sync_client_geo(
                client, target_dir, default_rule,
                preset=self.preset_name, key_prefix=self.preset_prefix,
            ):
                success = False
        else:
            self._remove_local_geo_databases(target_dir)

        if rules_enabled:
            published, rules_ok = self._publish_rules(target_dir, default_rule, geo_local)
            success = success and rules_ok
            # Устаревшие файлы удаляются только при полном успехе прогона:
            # при частичном сбое можно потерять ещё актуальные правила
            self._cleanup_obsolete_files(target_dir, published, published_ok=success)

        return success

    def _load_default_rule(self) -> Optional[dict]:
        """Основное правило пресета: из него берутся upstream-ссылки на гео-базы."""
        from app.config import Config

        client = self.CLIENT_NAME
        url = Config.get_default_rule_url(client, preset=self.preset_name)
        # Ключи кэша не менять: иначе после обновления всё скачается заново
        if self.preset_name == "geogaga":
            cache_key = f"{client}_{client}_{self.preset_name}"
        else:
            cache_key = f"{client}_DEFAULT_orig_{self.preset_name}"
        try:
            return self.parse_rule_payload(self.downloader.fetch(url, cache_key, kind="rule"), client)
        except Exception as e:
            logger.warning(f"Could not load default rule for {client} ({self.preset_name}) from {url}: {e}")
            return None

    def _geo_urls(self, default_rule: Optional[dict], geo_local: bool) -> Tuple[str, str]:
        """Ссылки на гео-базы, которые записываются в правила. '' — не менять."""
        from app.config import Config

        client = self.CLIENT_NAME
        external = Config.get_external_geo_url(client, preset=self.preset_name)
        if external:
            # Внешний узел уже раздаёт базы — ссылка на него нужна независимо от SERVE_GEO*
            return f"{external}/geoip.dat", f"{external}/geosite.dat"
        if geo_local:
            base = f"{Config.get_base_url(self.token, preset=self.preset_name)}/{client}"
            return (
                f"{base}/geoip.dat" if Config.SERVE_GEOIP else "",
                f"{base}/geosite.dat" if Config.SERVE_GEOSITE else "",
            )
        # Базы не раздаются с этого сервера — оставляем исходные upstream-ссылки
        upstream = default_rule or {}
        return (
            upstream.get("Geoipurl") or Config.get_preset_geoip_url(self.preset_name) or "",
            upstream.get("Geositeurl") or Config.get_preset_geosite_url(self.preset_name) or "",
        )

    def _rule_files(self) -> List[str]:
        from app.config import Config

        files = Config.get_active_rules(self._discover_config_files(), client=self.CLIENT_NAME, preset=self.preset_name)
        extra = self._extra_rule_files()
        # Для geogaga и vahellame правило у клиента одно — дополнительные не добавляются
        if extra and self.preset_name not in ("geogaga", "vahellame"):
            by_name = {name.upper(): name for name in files}
            for name in extra:
                by_name.setdefault(name, name)
            files = sorted(by_name.values(), key=str.upper)
        return files

    def _publish_rules(self, target_dir: Path, default_rule: Optional[dict], geo_local: bool) -> Tuple[Set[str], bool]:
        """Скачивает правила, подставляет ссылки на базы и публикует .JSON/.DEEPLINK."""
        from app.config import Config
        from app.publisher import Publisher

        client = self.CLIENT_NAME
        logger.info(f"Processing {client} rule files ({self.preset_name})...")
        geoip_url, geosite_url = self._geo_urls(default_rule, geo_local)
        serve_json = Config.should_serve_json(client)
        serve_deeplink = self._should_publish_deeplink()
        published: Set[str] = set()
        success = True

        for file_name in self._rule_files():
            if not self.is_safe_config_filename(file_name):
                logger.error(f"Skipping unsafe filename: {file_name}")
                continue
            logger.info(f"  Processing {file_name} for {client} ({self.preset_name})...")
            file_key = file_name.rsplit(".", 1)[0].upper()
            url = Config.get_rule_url(client, file_name, preset=self.preset_name)
            try:
                raw_bytes = self.downloader.fetch(url, f"{client}_{file_key}_{self.preset_name}", kind="rule")
                data = self.parse_rule_payload(raw_bytes, client)
                if geoip_url:
                    data["Geoipurl"] = geoip_url
                if geosite_url:
                    data["Geositeurl"] = geosite_url
                if not data.get("LastUpdated"):
                    # Стабильная отметка версии: меняется только вместе с содержимым
                    data["LastUpdated"] = str(int(hashlib.md5(raw_bytes).hexdigest()[:8], 16))

                if serve_json:
                    content = json.dumps(data, indent=2, ensure_ascii=False)
                    if not Publisher.publish_file(target_dir, file_name, content, key_prefix=self.preset_prefix):
                        success = False
                        continue
                    published.add(file_name)
                if serve_deeplink:
                    name = deeplink_filename_for(file_name)
                    if Publisher.publish_file(target_dir, name, self.build_deeplink(client, data), key_prefix=self.preset_prefix):
                        published.add(name)
                    else:
                        success = False
            except Exception as e:
                logger.error(f"Failed to process {file_name} for {client} ({self.preset_name}): {e}")
                success = False

        return published, success

    def _discover_config_files(self) -> List[str]:
        """Получает список JSON файлов из GitHub API репозитория для данного клиента."""
        from app.config import Config
        api_url = Config.get_github_contents_url(self.CLIENT_NAME, preset=self.preset_name)
        if not api_url:
            logger.warning(
                f"GitHub API discovery недоступен для {self.CLIENT_NAME} ({self.preset_name}) "
                "(источник не из GitHub Contents API); "
                "очистка устаревших файлов будет идти строго по опубликованному набору"
            )
            self.is_fallback_discovery = True
            return Config.get_display_rules([], client=self.CLIENT_NAME, preset=self.preset_name)

        try:
            req = urllib.request.Request(
                api_url, 
                headers={"User-Agent": "geo-routing-server", "Accept": "application/vnd.github.v3+json"}
            )
            with urllib.request.urlopen(req, timeout=15) as res:
                items = json.loads(res.read().decode("utf-8"))
                discovered = [
                    item["name"] for item in items
                    if item.get("type") == "file" and self.is_safe_config_filename(item.get("name", ""))
                ]
                if discovered:
                    self.is_fallback_discovery = False
                    return sorted(discovered)
        except Exception as e:
            logger.warning(f"GitHub API discovery failed for {self.CLIENT_NAME} ({self.preset_name}) ({e}), using fallback file list")
            
        self.is_fallback_discovery = True
        return Config.get_display_rules([], client=self.CLIENT_NAME, preset=self.preset_name)

    def _remove_local_geo_databases(self, target_dir: Path) -> None:
        """Удаляет устаревшие локальные geoip.dat/geosite.dat из каталога клиента.

        Нужно, когда geo-базы больше не раздаются локально: раздача выключена
        (SERVE_GEOIP/SERVE_GEOSITE) либо базы публикуются во внешнем хранилище
        (PUBLIC_GEO_BASE_URL) — иначе остатки от прошлой конфигурации висят вечно.
        """
        if not target_dir.is_dir():
            return

        for filename in ("geoip.dat", "geosite.dat"):
            old_file = target_dir / filename
            if old_file.is_file():
                try:
                    old_file.unlink()
                    logger.info(f"  Removed stale {self.CLIENT_NAME} geo file: {filename}")
                except OSError as e:
                    logger.warning(f"  Could not remove stale geo file {old_file}: {e}")

    def _cleanup_obsolete_files(
        self, target_dir: Path, valid_filenames: Set[str], published_ok: bool = True
    ) -> None:
        """Удаляет неактуальные JSON и DEEPLINK файлы, которых больше нет в источниках.

        Безопасность очистки:
        - published_ok — флаг полного успеха прогона: process() передаёт сюда
          результат публикации, и при частичном провале загрузки/публикации
          ничего не удаляется (иначе можно потерять ещё актуальные правила);
          по умолчанию True — прямые вызовы чистят, как и раньше;
        - имена сравниваются регистронезависимо с ОБЕИХ сторон: публикуемые имена
          (.JSON/.DEEPLINK) не всегда совпадают по регистру со списком из источников,
          из-за чего строгое сравнение могло удалить актуальный файл;
        - для пресетов geogaga и vahellame очистка опирается на реально опубликованные
          файлы сессии (published_files / published_registry), не пропуская очистку;
        - в fallback-режиме discovery очистка работает по уже опубликованному набору.
        """
        if not target_dir.is_dir():
            return

        from app.publisher import Publisher

        preset = self.preset_name

        # Для пресетов geogaga и vahellame (а также как страховка для других пресетов)
        # учитываем реальный список опубликованных файлов сессии из Publisher.published_registry
        expected_prefix = f"{self.preset_prefix}/" if self.preset_prefix else ""
        session_published = {
            info.filename
            for key, info in Publisher.published_registry.items()
            if (
                key.startswith(f"{expected_prefix}{target_dir.name}/")
                or key.startswith(f"{expected_prefix}{self.CLIENT_NAME}/")
            )
        }
        effective_valid = set(valid_filenames) | session_published

        if not published_ok:
            logger.info(
                f"Skipping obsolete files cleanup for {self.CLIENT_NAME}: "
                f"the current set was not published successfully"
            )
            return

        if not effective_valid:
            logger.warning(
                f"Skipping obsolete files cleanup for {self.CLIENT_NAME}: "
                f"nothing was published this run"
            )
            return

        if preset in ("geogaga", "vahellame"):
            logger.info(
                f"Running cleanup for preset {preset} ({self.CLIENT_NAME}) "
                f"based on actual published session files: {sorted(effective_valid)}"
            )
        elif self.is_fallback_discovery:
            logger.info(
                f"Fallback file discovery for {self.CLIENT_NAME}: running conservative "
                f"cleanup by the successfully published set"
            )

        valid_names_lower = {name.lower() for name in effective_valid}

        for path in target_dir.iterdir():
            if not path.is_file():
                continue
            name_lower = path.name.lower()
            if name_lower.endswith(".json") or name_lower.endswith(".deeplink"):
                if name_lower not in valid_names_lower:
                    try:
                        path.unlink(missing_ok=True)
                        logger.info(f"  Removed obsolete {self.CLIENT_NAME} file: {path.name}")
                    except Exception as e:
                        logger.warning(f"  Could not remove obsolete file {path.name}: {e}")
