import base64
import json
import logging
import re
import urllib.request
from abc import ABC, abstractmethod
from pathlib import Path
from typing import List, Set
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
    
    def __init__(self, downloader: Downloader, storage_dir: Path, token: str, domain: str):
        self.downloader = downloader
        self.storage_dir = storage_dir
        self.token = token
        self.domain = domain
        self.client_dir = storage_dir / token
        self.is_fallback_discovery: bool = False

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
        """Парсит полученные данные правила — чистый JSON либо deeplink onadd/base64."""
        text = raw_bytes.decode("utf-8", errors="replace").strip()
        try:
            data = json.loads(text)
            if isinstance(data, dict):
                return data
        except Exception:
            pass

        pattern = rf"{client.lower()}://routing/onadd/([A-Za-z0-9+/=]+)"
        match = re.search(pattern, text)
        if match:
            b64_str = match.group(1)
            decoded_json = base64.b64decode(b64_str).decode("utf-8")
            data = json.loads(decoded_json)
            if isinstance(data, dict):
                return data

        raise ValueError(f"Could not parse {client} rule payload as JSON or deeplink")
        
    @abstractmethod
    def process(self) -> bool:
        """Основной метод обработки. Возвращает True в случае успеха."""
        pass

    def _discover_config_files(self) -> List[str]:
        """Получает список JSON файлов из GitHub API репозитория для данного клиента."""
        from app.config import Config
        api_url = Config.get_github_contents_url(self.CLIENT_NAME)
        if not api_url:
            logger.warning(
                f"GitHub API discovery недоступен для {self.CLIENT_NAME} (источник не из GitHub Contents API); "
                "очистка устаревших файлов будет идти строго по опубликованному набору"
            )
            self.is_fallback_discovery = True
            return list(self.FALLBACK_FILES)

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
            logger.warning(f"GitHub API discovery failed for {self.CLIENT_NAME} ({e}), using fallback file list")
            
        self.is_fallback_discovery = True
        return list(self.FALLBACK_FILES)

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

        from app.config import Config
        from app.publisher import Publisher

        preset = Config.ROUTING_SOURCE_PRESET

        # Для пресетов geogaga и vahellame (а также как страховка для других пресетов)
        # учитываем реальный список опубликованных файлов сессии из Publisher.published_registry
        session_published = {
            info.filename
            for key, info in Publisher.published_registry.items()
            if key.startswith(f"{target_dir.name}/") or key.startswith(f"{self.CLIENT_NAME}/")
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
