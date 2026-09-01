from abc import ABC, abstractmethod
from pathlib import Path
from app.downloader import Downloader

class BaseProcessor(ABC):
    """Базовый класс процессора для клиентов маршрутизации."""
    
    def __init__(self, downloader: Downloader, storage_dir: Path, token: str, domain: str):
        self.downloader = downloader
        self.storage_dir = storage_dir
        self.token = token
        self.domain = domain
        self.client_dir = storage_dir / token
        
    @abstractmethod
    def process(self) -> bool:
        """Основной метод обработки. Возвращает True в случае успеха."""
        pass
