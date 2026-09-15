import os
import re
import sys
from pathlib import Path
from typing import List
from urllib.parse import quote, urlparse

class Config:
    """Конфигурация приложения, загружаемая из переменных окружения и файлов."""
    
    BASE_DIR = Path(os.getenv("BASE_DIR", "/app"))
    STORAGE_DIR = Path(os.getenv("STORAGE_DIR", str(BASE_DIR / "www")))
    CACHE_DIR = Path(os.getenv("CACHE_DIR", str(BASE_DIR / ".cache")))
    CUSTOM_GEO_DIR = Path(os.getenv("CUSTOM_GEO_DIR", str(BASE_DIR / "custom_geo")))
    LOCK_FILE = BASE_DIR / ".sync.lock"
    
    DOMAIN = re.sub(r"^https?://", "", os.getenv("DOMAIN", "geo.example.com").strip()).rstrip("/")
    SCHEDULE = os.getenv("SCHEDULE", "0 10 * * *").strip()
    SYNC_ON_START = os.getenv("SYNC_ON_START", "true").lower() in ("true", "1", "yes")
    
    # Список активных модулей: HAPP, HAPP_DEEPLINK, HAPP_GEO, INCY, INCY_GEO
    ENABLED_CLIENTS: List[str] = [
        c.strip().upper() 
        for c in os.getenv("ENABLED_CLIENTS", "HAPP,INCY").split(",") 
        if c.strip()
    ]
    
    # Список правил маршрутизации: JSONSUB, WHITELIST, DEFAULT или пусто / ALL для всех
    _raw_rules = os.getenv("ROUTING_RULES", "").strip()
    ROUTING_RULES: List[str] = [
        r.strip().upper().removesuffix(".JSON")
        for r in _raw_rules.split(",")
        if r.strip()
    ] if _raw_rules and _raw_rules.upper() != "ALL" else []

    # Выборочная раздача файлов geo-баз (geoip.dat, geosite.dat)
    SERVE_GEOIP = os.getenv("SERVE_GEOIP", "true").lower() in ("true", "1", "yes")
    SERVE_GEOSITE = os.getenv("SERVE_GEOSITE", "true").lower() in ("true", "1", "yes")

    # Форматы правил: CLIENT_OPTIMIZED (Happ -> .DEEPLINK, Incy -> .JSON), ALL, JSON, DEEPLINK
    SERVE_FORMATS = os.getenv("SERVE_FORMATS", "CLIENT_OPTIMIZED").strip().upper()

    @classmethod
    def should_serve_json(cls, client: str) -> bool:
        """Проверяет, нужно ли публиковать .JSON файл для клиента."""
        fmt = cls.SERVE_FORMATS
        if fmt == "DEEPLINK":
            return False
        if fmt in ("CLIENT_OPTIMIZED", "OPTIMIZED"):
            return client.upper() != "HAPP"
        return True

    @classmethod
    def should_serve_deeplink(cls, client: str) -> bool:
        """Проверяет, нужно ли публиковать .DEEPLINK файл для клиента."""
        fmt = cls.SERVE_FORMATS
        if fmt == "JSON":
            return False
        if fmt in ("CLIENT_OPTIMIZED", "OPTIMIZED"):
            return client.upper() != "INCY"
        return True

    @classmethod
    def get_active_rules(cls, discovered_rules: List[str]) -> List[str]:
        """Возвращает отфильтрованный список правил для генерации."""
        if not cls.ROUTING_RULES:
            return discovered_rules
        discovered_dict = {r.upper().removesuffix(".JSON"): r for r in discovered_rules}
        active = []
        for r in cls.ROUTING_RULES:
            if r in discovered_dict:
                active.append(discovered_dict[r])
            else:
                active.append(f"{r}.JSON")
        return active or discovered_rules

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
    
    @staticmethod
    def _validate_http_url(url: str) -> str:
        """Валидирует URL, разрешая только http:// и https:// схемы."""
        clean = url.strip()
        if clean and clean.startswith(("http://", "https://")):
            return clean
        return ""

    SOURCE_PRESETS = {
        "geogaga": {
            "name": "GeoGaga (Client Flavor)",
            "description": "Сбалансированный Split-tunneling, легкие базы, рабочие CDN (Рекомендуется)",
            "routing_repo": "https://raw.githubusercontent.com/bratishkadrugoimamysynishka/geogaga-client-flavor/release/routing",
            "geoip_url": "https://github.com/bratishkadrugoimamysynishka/geogaga-client-flavor/releases/latest/download/geoip.dat",
            "geosite_url": "https://github.com/bratishkadrugoimamysynishka/geogaga-client-flavor/releases/latest/download/geosite.dat",
            "rules_format": "geogaga",
        },
        "vahellame": {
            "name": "vahellame (Whitelist)",
            "description": "Строгий белый список для жестких ограничений ТСПУ",
            "routing_repo": "https://raw.githubusercontent.com/vahellame/russia-whitelist-routing/main",
            "geoip_url": "https://github.com/vahellame/russia-whitelist-geoip/releases/latest/download/geoip.dat",
            "geosite_url": "https://github.com/vahellame/russia-whitelist-geosite/releases/latest/download/geosite.dat",
            "rules_format": "vahellame",
        },
        "hydraponique": {
            "name": "hydraponique (Legacy)",
            "description": "Классический источник roscomvpn-routing",
            "routing_repo": "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main",
            "geoip_url": "https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat",
            "geosite_url": "https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat",
            "rules_format": "hydraponique",
        },
    }

    def _calc_preset(env_preset: str, env_repo: str, presets: dict) -> str:
        preset = env_preset.strip().lower()
        if preset in presets or preset == "custom":
            return preset
        if "hydraponique" in env_repo:
            return "hydraponique"
        elif "vahellame" in env_repo:
            return "vahellame"
        elif env_repo:
            return "custom"
        return "geogaga"

    ROUTING_SOURCE_PRESET = _calc_preset(
        os.getenv("ROUTING_SOURCE_PRESET", ""),
        os.getenv("ROUTING_SOURCE_REPO", ""),
        SOURCE_PRESETS
    )
    _active_preset = SOURCE_PRESETS.get(ROUTING_SOURCE_PRESET, SOURCE_PRESETS["geogaga"])

    _custom_geoip = _validate_http_url(os.getenv("GEOIP_SOURCE_URL", ""))
    _custom_geosite = _validate_http_url(os.getenv("GEOSITE_SOURCE_URL", ""))
    _custom_repo = _validate_http_url(os.getenv("ROUTING_SOURCE_REPO", ""))

    GEOIP_SOURCE_URL = _custom_geoip or _active_preset["geoip_url"]
    GEOSITE_SOURCE_URL = _custom_geosite or _active_preset["geosite_url"]
    ROUTING_SOURCE_REPO = (_custom_repo or _active_preset["routing_repo"]).rstrip("/")

    @classmethod
    def get_source_preset(cls) -> str:
        return cls.ROUTING_SOURCE_PRESET

    @classmethod
    def get_rule_url(cls, client: str, file_name: str) -> str:
        """Возвращает URL для загрузки правила с учетом пресета или кастомного репозитория."""
        preset = cls.ROUTING_SOURCE_PRESET
        if preset == "geogaga":
            return f"{cls.ROUTING_SOURCE_REPO}/{client.lower()}.json"
        elif preset == "vahellame":
            return f"https://vahellame.github.io/russia-whitelist-routing/{client.lower()}/"
        else:
            return f"{cls.ROUTING_SOURCE_REPO}/{client}/{file_name}"

    @classmethod
    def get_default_rule_url(cls, client: str) -> str:
        """Возвращает URL дефолтного правила для извлечения upstream-метаданных."""
        return cls.get_rule_url(client, "DEFAULT.JSON")
    
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
        is_only_local = bool(cls.ENABLED_CLIENTS) and set(cls.ENABLED_CLIENTS).issubset({"HAPP_DEEPLINK", "HAPP_LOCAL"})
        
        if not token or token == "change_me_to_random_secret_token":
            if is_only_local:
                return "local"
            print("ERROR: ROUTING_TOKEN is not configured! Please set a valid secret token in .env or token.txt", file=sys.stderr)
            sys.exit(1)
            
        # Строгая валидация токена: только безопасные URL-символы (буквы, цифры, дефис, подчёркивание)
        # Точки исключены для защиты от path traversal (. и ..) и скрытых файлов
        if len(token) < 4 or not re.match(r"^[A-Za-z0-9_-]+$", token):
            print("ERROR: ROUTING_TOKEN must be at least 4 characters and contain only A-Z, a-z, 0-9, '_', '-'", file=sys.stderr)
            sys.exit(1)
            
        return token

    @classmethod
    def get_base_url(cls, token: str) -> str:
        """Формирует базовый публичный HTTPS URL."""
        return f"https://{cls.DOMAIN}/{token}"

    @classmethod
    def get_github_contents_url(cls, client: str) -> str:
        """Возвращает URL GitHub Contents API для raw.githubusercontent.com источника.

        Custom sources outside GitHub нельзя безопасно сопоставить с Contents API,
        поэтому discovery для них отключается.
        """
        if cls.ROUTING_SOURCE_PRESET in ("geogaga", "vahellame"):
            return ""

        parsed = urlparse(cls.ROUTING_SOURCE_REPO)
        if parsed.scheme != "https" or parsed.hostname != "raw.githubusercontent.com":
            return ""

        parts = [part for part in parsed.path.split("/") if part]
        if len(parts) < 3:
            return ""

        owner, repo, ref = parts[:3]
        source_path = parts[3:]
        content_path = "/".join([*source_path, client])
        quoted_path = quote(content_path, safe="/")
        quoted_ref = quote(ref, safe="")
        return (
            f"https://api.github.com/repos/{owner}/{repo}/contents/"
            f"{quoted_path}?ref={quoted_ref}"
        )
