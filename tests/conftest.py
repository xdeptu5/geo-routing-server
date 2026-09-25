"""Общие фикстуры для тестов.

Правила тестов:
* без сети (никаких HTTP/DNS-запросов);
* без Docker и без чтения `.env` — все настройки задаются через monkeypatch
  и переменные окружения, а файлы пишутся только в tmp-каталоги pytest.
"""

import importlib
import os
import re
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

# Переменные окружения, которые читает приложение (app/config.py, app/main.py).
CONFIG_ENV_KEYS = (
    "BASE_DIR",
    "STORAGE_DIR",
    "CACHE_DIR",
    "CUSTOM_GEO_DIR",
    "DOMAIN",
    "ROUTING_TOKEN",
    "ENABLED_CLIENTS",
    "ROUTING_RULES",
    "ROUTING_SOURCE_PRESET",
    "ROUTING_SOURCE_REPO",
    "SERVE_FORMATS",
    "SERVE_GEOIP",
    "SERVE_GEOSITE",
    "PUBLIC_GEO_BASE_URL",
    "GEOIP_SOURCE_URL",
    "GEOSITE_SOURCE_URL",
    "SCHEDULE",
    "SYNC_ON_START",
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CHAT_ID",
    "TELEGRAM_THREAD_ID",
    "TELEGRAM_NOTIFY_SUCCESS",
    "REMNAWAVE_BASE_URL",
    "REMNAWAVE_TOKEN",
    "REMNAWAVE_GLOBAL_RULE",
    "GITHUB_RAW_URL",
    "CLOUDFLARE_ZERO_TRUST_CLIENT_ID",
    "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET",
    "CF_ACCESS_CLIENT_ID",
    "CF_ACCESS_CLIENT_SECRET",
)

# SQUAD_N_* / REMNAWAVE_SQUAD_N_* читаются динамически через os.environ.
_SQUAD_ENV_RE = re.compile(r"^(?:REMNAWAVE_)?SQUAD_\d+_(?:UUID|RULE|NAME|URL)$")


@pytest.fixture(autouse=True)
def _isolate_remnawave_state(monkeypatch):
    """Очищает кэши Remnawave и переменные сквадов до и после каждого теста."""
    from app.remnawave import RemnawaveSync

    for key in [k for k in list(os.environ) if _SQUAD_ENV_RE.match(k)]:
        monkeypatch.delenv(key, raising=False)

    RemnawaveSync.cached_squad_names.clear()
    RemnawaveSync.last_errors = []
    yield
    RemnawaveSync.cached_squad_names.clear()
    RemnawaveSync.last_errors = []


@pytest.fixture
def clean_env(monkeypatch):
    """Удаляет переменные конфигурации приложения из окружения."""
    for key in CONFIG_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    return monkeypatch


@pytest.fixture
def config_with_env(clean_env):
    """Перезагружает app.config с заданным окружением и возвращает свежий Config.

    Класс Config вычисляет значения при импорте, поэтому для проверки
    парсинга переменных модуль нужно перезагрузить. Окружение и сам модуль
    восстанавливаются после теста.
    """
    import app.config as config_module

    def _load(**env):
        # каждая загрузка начинается с чистого окружения
        for key in CONFIG_ENV_KEYS:
            clean_env.delenv(key, raising=False)
        for key, value in env.items():
            clean_env.setenv(key, str(value))
        importlib.reload(config_module)
        return config_module.Config

    yield _load
    importlib.reload(config_module)
