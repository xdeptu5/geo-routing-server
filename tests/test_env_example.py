"""Тесты согласованности .env.example с кодом (app/config.py, app/main.py, compose.yaml).

Публичный контракт — имена переменных: каждый переменной, которую читает
приложение, должно соответствовать упоминание в .env.example (активное или
закомментированное).
"""

import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

# Внутренние каталоги контейнера — переопределять их через .env не нужно.
INTERNAL_VARS = {"BASE_DIR", "STORAGE_DIR", "CACHE_DIR", "CUSTOM_GEO_DIR"}

REQUIRED_ACTIVE_VARS = {
    "DOMAIN",
    "ROUTING_TOKEN",
    "ENABLED_CLIENTS",
    "ROUTING_RULES",
    "ROUTING_SOURCE_PRESET",
    "SERVE_FORMATS",
    "SERVE_GEOIP",
    "SERVE_GEOSITE",
    "HTTP_BIND",
    "HTTP_PORT",
    "SCHEDULE",
    "SYNC_ON_START",
}


@pytest.fixture(scope="module")
def env_example_text():
    return (REPO_ROOT / ".env.example").read_text(encoding="utf-8")


def _extract_keys(text, commented_only=False, active_only=False):
    keys = set()
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        is_comment = stripped.startswith("#")
        if active_only and is_comment:
            continue
        if commented_only and not is_comment:
            continue
        candidate = stripped.lstrip("#").strip() if is_comment else stripped
        match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)=", candidate)
        if match:
            keys.add(match.group(1))
    return keys


def test_required_variables_are_active(env_example_text):
    active = _extract_keys(env_example_text, active_only=True)
    missing = REQUIRED_ACTIVE_VARS - active
    assert not missing, f".env.example is missing active variables: {sorted(missing)}"


def test_every_config_variable_is_documented(env_example_text):
    """Каждая переменная из app/config.py и app/main.py описана в .env.example."""
    sources = ""
    for rel in ("app/config.py", "app/main.py"):
        sources += (REPO_ROOT / rel).read_text(encoding="utf-8")
    read_by_app = set(re.findall(r'os\.getenv\(\s*"([A-Z0-9_]+)"', sources))
    documented = _extract_keys(env_example_text)
    undocumented = (read_by_app - INTERNAL_VARS) - documented
    assert not undocumented, f"variables read by the app but not in .env.example: {sorted(undocumented)}"


def test_every_compose_variable_is_documented(env_example_text):
    compose = (REPO_ROOT / "compose.yaml").read_text(encoding="utf-8")
    compose_vars = set(re.findall(r"\$\{([A-Z_]+)", compose))
    documented = _extract_keys(env_example_text)
    undocumented = compose_vars - documented
    assert not undocumented, f"variables used by compose.yaml but not in .env.example: {sorted(undocumented)}"


def test_env_example_has_no_unknown_active_variables(env_example_text):
    """Активные строки не должны задавать переменные, которые никто не читает."""
    allowed = INTERNAL_VARS | {
        # читаются приложением или compose.yaml (проверяется выше)
        "DOMAIN", "ROUTING_TOKEN", "ENABLED_CLIENTS", "ROUTING_RULES",
        "ROUTING_SOURCE_PRESET", "ROUTING_SOURCE_REPO", "SERVE_FORMATS",
        "SERVE_GEOIP", "SERVE_GEOSITE", "PUBLIC_GEO_BASE_URL",
        "GEOIP_SOURCE_URL", "GEOSITE_SOURCE_URL", "SCHEDULE", "SYNC_ON_START",
        "HTTP_BIND", "HTTP_PORT", "DOCKER_NETWORK",
        "TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID", "TELEGRAM_THREAD_ID",
        "TELEGRAM_NOTIFY_SUCCESS",
        "REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN", "REMNAWAVE_GLOBAL_RULE",
        "CLOUDFLARE_ZERO_TRUST_CLIENT_ID", "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET",
    }
    active = _extract_keys(env_example_text, active_only=True)
    unknown = active - allowed
    assert not unknown, f"active variables in .env.example nobody reads: {sorted(unknown)}"


def test_routing_token_example_is_valid_format(env_example_text):
    """Значение ROUTING_TOKEN в шаблоне должно проходить валидацию Config.get_token."""
    match = re.search(r"^ROUTING_TOKEN=(.+)$", env_example_text, re.MULTILINE)
    assert match, "ROUTING_TOKEN is missing"
    token = match.group(1).strip()
    # дефолт-плейсхолдер — единственное допустимое «ненастоящее» значение
    assert token == "change_me_to_random_secret_token" or re.fullmatch(r"[A-Za-z0-9_-]{4,}", token)
