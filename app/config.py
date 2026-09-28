import os
import re
import sys
from pathlib import Path
from typing import List, Optional
from urllib.parse import quote, urlparse

def _calc_preset_fn(env_preset: str, presets: dict) -> str:
    p = env_preset.strip().lower()
    if p in presets:
        return p
    return "geogaga"


def _calc_presets_fn(env_preset: str, presets: dict) -> list[str]:
    raw_items = [p.strip().lower() for p in env_preset.split(",") if p.strip()]
    result = []
    for p in raw_items:
        if p in presets:
            if p not in result:
                result.append(p)
    if result:
        return result
    return [_calc_preset_fn(env_preset, presets)]


class Config:
    """Конфигурация приложения, загружаемая из переменных окружения и файлов."""
    
    BASE_DIR = Path(os.getenv("BASE_DIR", "/app"))
    STORAGE_DIR = Path(os.getenv("STORAGE_DIR", str(BASE_DIR / "www")))
    CACHE_DIR = Path(os.getenv("CACHE_DIR", str(BASE_DIR / ".cache")))
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
    def get_active_rules(cls, discovered_rules: List[str], client: str = "", preset: Optional[str] = None) -> List[str]:
        """Возвращает отфильтрованный список правил для генерации с учетом пресета."""
        p = (preset or cls.ROUTING_SOURCE_PRESET).lower()
        c = client.upper() if client else "HAPP"

        if p == "geogaga":
            return [f"{c}.JSON"]
        if p == "vahellame":
            return ["WHITELIST.JSON"]

        if not cls.ROUTING_RULES:
            if not discovered_rules:
                return ["DEFAULT.JSON", "JSONSUB.JSON", "WHITELIST.JSON"]
            return discovered_rules
        discovered_dict = {r.upper().removesuffix(".JSON"): r for r in discovered_rules}
        active = []
        for r in cls.ROUTING_RULES:
            if r in discovered_dict:
                active.append(discovered_dict[r])
            else:
                active.append(f"{r}.JSON")
        return active or discovered_rules or ["DEFAULT.JSON", "JSONSUB.JSON", "WHITELIST.JSON"]

    @classmethod
    def get_display_rules(cls, discovered_rules: list[str] | None = None, client: str = "", preset: Optional[str] = None) -> list[str]:
        """Список правил для баннера/сводки: пресет и ROUTING_RULES из конфигурации.

        В отличие от get_active_rules([]) не возвращает пустой список, когда
        discovery не выполнялся: без явно заданных ROUTING_RULES берётся
        стандартный набор правил (совпадает с BaseProcessor.FALLBACK_FILES).
        """
        p = (preset or cls.ROUTING_SOURCE_PRESET).lower()
        fallback = ["HAPP.JSON" if client.upper() != "INCY" else "INCY.JSON"] if p == "geogaga" else (
            ["WHITELIST.JSON"] if p == "vahellame" else ["DEFAULT.JSON", "JSONSUB.JSON", "WHITELIST.JSON"]
        )
        candidates = list(discovered_rules) if discovered_rules else list(cls.ROUTING_RULES or fallback)
        return cls.get_active_rules(candidates, client=client, preset=p)

    # Внешний URL к гео-базам (если базы отдаются с другого сервера)
    _raw_public_geo = os.getenv("PUBLIC_GEO_BASE_URL", "").strip().rstrip("/")
    if _raw_public_geo and not _raw_public_geo.startswith(("http://", "https://")):
        _raw_public_geo = f"https://{_raw_public_geo}"
    PUBLIC_GEO_BASE_URL = _raw_public_geo
    
    @classmethod
    def get_external_geo_url(cls, client: str, preset: Optional[str] = None) -> str:
        """
        Возвращает публичный URL к внешним базам для конкретного клиента.
        Если указан корень (https://domain/token) -> добавит /{client}
        Если указан путь с /HAPP или /INCY -> заменит на нужного клиента.
        """
        raw = cls.PUBLIC_GEO_BASE_URL.rstrip("/")
        if not raw:
            return ""
        p_suffix = f"/{preset.upper()}" if preset and preset.lower() != cls.PRIMARY_PRESET.lower() else ""
        if raw.upper().endswith("/HAPP") or raw.upper().endswith("/INCY"):
            root = raw.rsplit("/", 1)[0]
            return f"{root}{p_suffix}/{client.upper()}"
        return f"{raw}{p_suffix}/{client.upper()}"
    
    @staticmethod
    def _validate_http_url(url: str) -> str:
        """Валидирует URL, нормализуя схему https:// при необходимости."""
        clean = url.strip()
        if clean:
            if not clean.startswith(("http://", "https://")):
                clean = f"https://{clean}"
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

    _calc_preset = staticmethod(_calc_preset_fn)
    _calc_presets = staticmethod(_calc_presets_fn)

    ACTIVE_PRESETS = _calc_presets_fn(
        os.getenv("ROUTING_SOURCE_PRESET", ""),
        SOURCE_PRESETS
    )
    PRIMARY_PRESET = ACTIVE_PRESETS[0]
    ROUTING_SOURCE_PRESET = PRIMARY_PRESET
    _active_preset = SOURCE_PRESETS.get(PRIMARY_PRESET, SOURCE_PRESETS["geogaga"])

    GEOIP_SOURCE_URL = _active_preset["geoip_url"]
    GEOSITE_SOURCE_URL = _active_preset["geosite_url"]
    ROUTING_SOURCE_REPO = _active_preset["routing_repo"].rstrip("/")

    @classmethod
    def get_preset_info(cls, preset: Optional[str] = None) -> dict:
        p = (preset or cls.ROUTING_SOURCE_PRESET).lower()
        return cls.SOURCE_PRESETS.get(p, cls.SOURCE_PRESETS.get(cls.PRIMARY_PRESET, cls.SOURCE_PRESETS["geogaga"]))

    @classmethod
    def get_preset_geoip_url(cls, preset: Optional[str] = None) -> str:
        """Возвращает дефолтный URL geoip для пресета."""
        return cls.get_preset_info(preset)["geoip_url"]

    @classmethod
    def get_preset_geosite_url(cls, preset: Optional[str] = None) -> str:
        """Возвращает дефолтный URL geosite для пресета."""
        return cls.get_preset_info(preset)["geosite_url"]

    @classmethod
    def get_preset_repo(cls, preset: Optional[str] = None) -> str:
        """Возвращает URL репозитория правил для пресета."""
        p = preset.lower() if preset else cls.ROUTING_SOURCE_PRESET.lower()
        info = cls.get_preset_info(p)
        return info.get("routing_repo", cls.ROUTING_SOURCE_REPO).rstrip("/")

    @classmethod
    def get_source_preset(cls) -> str:
        return cls.ROUTING_SOURCE_PRESET

    @classmethod
    def get_rule_url(cls, client: str, file_name: str, preset: Optional[str] = None) -> str:
        """Возвращает URL для загрузки правила с учетом пресета или кастомного репозитория."""
        p = (preset or cls.ROUTING_SOURCE_PRESET).lower()
        repo = cls.get_preset_repo(p)
        if p == "geogaga":
            return f"{repo}/{client.lower()}.json"
        elif p == "vahellame":
            return f"https://vahellame.github.io/russia-whitelist-routing/{client.lower()}/"
        else:
            return f"{repo}/{client}/{file_name}"

    @classmethod
    def get_default_rule_url(cls, client: str, preset: Optional[str] = None) -> str:
        """Возвращает URL дефолтного правила для извлечения upstream-метаданных."""
        return cls.get_rule_url(client, "DEFAULT.JSON", preset=preset)
    
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
    def get_base_url(cls, token: str, preset: Optional[str] = None) -> str:
        """Формирует базовый публичный HTTPS URL с учетом пресета."""
        if preset and preset.lower() != cls.PRIMARY_PRESET.lower():
            return f"https://{cls.DOMAIN}/{token}/{preset.upper()}"
        return f"https://{cls.DOMAIN}/{token}"

    @classmethod
    def get_github_contents_url(cls, client: str, preset: Optional[str] = None) -> str:
        """Возвращает URL GitHub Contents API для raw.githubusercontent.com источника.

        Раскладка каталогов согласуется с get_rule_url:
        - geogaga   — плоская ({repo}/{client}.json): listing каталога источника;
        - vahellame — JSON-правило лежит в profiles/;
        - прочие    — {repo}/{client}/{file}: к пути источника добавляется каталог клиента.
        Custom sources вне GitHub нельзя безопасно сопоставить с Contents API,
        поэтому discovery для них отключается (возвращается пустая строка).
        """
        p = (preset or cls.ROUTING_SOURCE_PRESET).lower()
        repo = cls.get_preset_repo(p)
        parsed = urlparse(repo)
        if parsed.scheme != "https" or parsed.hostname != "raw.githubusercontent.com":
            return ""

        parts = [part for part in parsed.path.split("/") if part]
        if len(parts) < 3:
            return ""

        owner, repo_name, ref = parts[:3]
        source_path = parts[3:]
        if p == "geogaga":
            content_path = "/".join(source_path)
        elif p == "vahellame":
            content_path = "/".join([*source_path, "profiles"])
        else:
            content_path = "/".join([*source_path, client])
        quoted_path = quote(content_path, safe="/")
        quoted_ref = quote(ref, safe="")
        return (
            f"https://api.github.com/repos/{owner}/{repo_name}/contents/"
            f"{quoted_path}?ref={quoted_ref}"
        )
