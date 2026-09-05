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
        
    @abstractmethod
    def process(self) -> bool:
        """Основной метод обработки. Возвращает True в случае успеха."""
        pass

    def _discover_config_files(self) -> List[str]:
        """Получает список JSON файлов из GitHub API репозитория для данного клиента."""
        from app.config import Config
        configured_files = Config.get_routing_config_files(self.CLIENT_NAME)
        if configured_files:
            invalid_files = [name for name in configured_files if not self.is_safe_config_filename(name)]
            if invalid_files:
                logger.warning(
                    f"Ignoring unsafe configured file names for {self.CLIENT_NAME}: {', '.join(invalid_files)}"
                )
            discovered = sorted({name for name in configured_files if self.is_safe_config_filename(name)}, key=str.upper)
            if discovered:
                self.is_fallback_discovery = False
                return discovered

        api_url = Config.get_github_contents_url(self.CLIENT_NAME)
        if not api_url:
            logger.warning(
                "Skipping GitHub API discovery for unsupported routing source; "
                "obsolete-file cleanup is disabled"
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

    def _cleanup_obsolete_files(self, target_dir: Path, valid_filenames: Set[str]) -> None:
        """Удаляет неактуальные JSON и DEEPLINK файлы, которых больше нет в источниках."""
        if not target_dir.is_dir():
            return

        if self.is_fallback_discovery:
            logger.info(f"Skipping obsolete files cleanup for {self.CLIENT_NAME} due to fallback file discovery")
            return
            
        for path in target_dir.iterdir():
            if not path.is_file():
                continue
            name_lower = path.name.lower()
            if name_lower.endswith(".json") or name_lower.endswith(".deeplink"):
                if path.name not in valid_filenames:
                    try:
                        path.unlink(missing_ok=True)
                        logger.info(f"  Removed obsolete {self.CLIENT_NAME} file: {path.name}")
                    except Exception as e:
                        logger.warning(f"  Could not remove obsolete file {path.name}: {e}")
