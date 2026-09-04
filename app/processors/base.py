import json
import logging
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
        
    @abstractmethod
    def process(self) -> bool:
        """Основной метод обработки. Возвращает True в случае успеха."""
        pass

    def _discover_config_files(self) -> List[str]:
        """Получает список JSON файлов из GitHub API репозитория для данного клиента."""
        from app.config import Config
        api_url = f"{Config.get_github_api_base()}/{self.CLIENT_NAME}"
        try:
            req = urllib.request.Request(
                api_url, 
                headers={"User-Agent": "geo-routing-server", "Accept": "application/vnd.github.v3+json"}
            )
            with urllib.request.urlopen(req, timeout=15) as res:
                items = json.loads(res.read().decode("utf-8"))
                discovered = [
                    item["name"] for item in items 
                    if item.get("type") == "file" and item["name"].lower().endswith(".json")
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
