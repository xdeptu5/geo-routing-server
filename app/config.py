import os
import re
import sys
from pathlib import Path
from typing import List

class Config:
    """Конфигурация приложения, загружаемая из переменных окружения и файлов."""
    
    BASE_DIR = Path(os.getenv("BASE_DIR", "/app"))
    STORAGE_DIR = Path(os.getenv("STORAGE_DIR", str(BASE_DIR / "www")))
    CACHE_DIR = Path(os.getenv("CACHE_DIR", str(BASE_DIR / ".cache")))
    CUSTOM_GEO_DIR = Path(os.getenv("CUSTOM_GEO_DIR", str(BASE_DIR / "custom_geo")))
    LOCK_FILE = BASE_DIR / ".sync.lock"
    
    DOMAIN = re.sub(r"^https?://", "", os.getenv("DOMAIN", "geo.example.com").strip()).rstrip("/")
    SCHEDULE = os.getenv("SCHEDULE", "40 8 * * *").strip()
    SYNC_ON_START = os.getenv("SYNC_ON_START", "true").lower() in ("true", "1", "yes")
    
    # Список активных модулей: HAPP, HAPP_DEEPLINK, HAPP_GEO, INCY, INCY_GEO
    ENABLED_CLIENTS: List[str] = [
        c.strip().upper() 
        for c in os.getenv("ENABLED_CLIENTS", "HAPP,INCY").split(",") 
        if c.strip()
    ]
    
    # Внешний URL к гео-базам (если базы отдаются с другого сервера)
    _raw_public_geo = os.getenv("PUBLIC_GEO_BASE_URL", "").strip().rstrip("/")
    PUBLIC_GEO_BASE_URL = _raw_public_geo if _raw_public_geo.startswith(("http://", "https://")) else ""
    
    @classmethod
    def get_external_geo_url(cls, client: str) -> str:
        """
        Возвращает публичный URL к внешним базам для конкретного клиента.
        Если указан корень (https://domain/token) -> добавит /{client}
        Если указан путь с /HAPP или /INCY -> заменит на нужного клиента.
        """
        raw = cls.PUBLIC_GEO_BASE_URL.rstrip("/")
        if not raw:
            return ""
        if raw.upper().endswith("/HAPP") or raw.upper().endswith("/INCY"):
            root = raw.rsplit("/", 1)[0]
            return f"{root}/{client.upper()}"
        return f"{raw}/{client.upper()}"
    
    GEOIP_SOURCE_URL = os.getenv("GEOIP_SOURCE_URL", "").strip()
    GEOSITE_SOURCE_URL = os.getenv("GEOSITE_SOURCE_URL", "").strip()
    ROUTING_SOURCE_REPO = os.getenv(
        "ROUTING_SOURCE_REPO", 
        "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main"
    ).strip().rstrip("/")
    
    # Telegram Notifications (опционально)
    TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
    TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()
    TELEGRAM_THREAD_ID = os.getenv("TELEGRAM_THREAD_ID", "").strip()
    TELEGRAM_NOTIFY_SUCCESS = os.getenv("TELEGRAM_NOTIFY_SUCCESS", "false").lower() in ("true", "1", "yes")

    @classmethod
    def get_token(cls) -> str:
        """Получает и строго валидирует секретный токен маршрутизации."""
        token = os.getenv("ROUTING_TOKEN", "").strip()
        token_file = cls.BASE_DIR / "token.txt"
        
        if not token and token_file.is_file():
            try:
                token = token_file.read_text(encoding="utf-8").strip()
            except Exception as e:
                print(f"ERROR: Failed to read token file {token_file}: {e}", file=sys.stderr)
                sys.exit(1)
        
        # Если включен только локальный генератор диплинков HAPP, токен может быть пустым или дефолтным
        is_only_local = cls.ENABLED_CLIENTS == ["HAPP_DEEPLINK"] or cls.ENABLED_CLIENTS == ["HAPP_LOCAL"]
        
        if not token or token == "change_me_to_random_secret_token":
            if is_only_local:
                return "local"
            print("ERROR: ROUTING_TOKEN is not configured! Please set a valid secret token in .env or token.txt", file=sys.stderr)
            sys.exit(1)
            
        # Строгая валидация токена: только безопасные URL-символы
        if not re.match(r"^[A-Za-z0-9._-]+$", token):
            print("ERROR: ROUTING_TOKEN contains illegal characters! Allowed: A-Z, a-z, 0-9, '.', '_', '-'", file=sys.stderr)
            sys.exit(1)
            
        return token

    @classmethod
    def get_base_url(cls, token: str) -> str:
        """Формирует базовый публичный HTTPS URL."""
        return f"https://{cls.DOMAIN}/{token}"

    @classmethod
    def get_github_api_base(cls) -> str:
        """Извлекает GitHub API endpoint из URL сырого репозитория."""
        match = re.search(r"raw\.githubusercontent\.com/([^/]+)/([^/]+)", cls.ROUTING_SOURCE_REPO, re.IGNORECASE)
        if match:
            owner, repo = match.group(1), match.group(2)
            return f"https://api.github.com/repos/{owner}/{repo}/contents"
        return "https://api.github.com/repos/hydraponique/roscomvpn-routing/contents"
