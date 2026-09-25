"""Тесты app/remnawave.py: нормализация URL, сквады, чтение диплинков."""

import pytest

from app.config import Config
from app.remnawave import RemnawaveSync


@pytest.fixture(autouse=True)
def _clean_remnawave_env(monkeypatch):
    for key in (
        "REMNAWAVE_BASE_URL",
        "REMNAWAVE_TOKEN",
        "REMNAWAVE_GLOBAL_RULE",
        "GITHUB_RAW_URL",
        "CLOUDFLARE_ZERO_TRUST_CLIENT_ID",
        "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET",
        "CF_ACCESS_CLIENT_ID",
        "CF_ACCESS_CLIENT_SECRET",
    ):
        monkeypatch.delenv(key, raising=False)


# ------------------------------------------------------------------------------
# get_api_url: любые входные формы дают одинаковый результат
# ------------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("", ""),
        ("https://panel.example.com", "https://panel.example.com/api"),
        ("https://panel.example.com/", "https://panel.example.com/api"),
        ("https://panel.example.com/api", "https://panel.example.com/api"),
        ("https://panel.example.com/api/", "https://panel.example.com/api"),
        ("http://remnawave:3000", "http://remnawave:3000/api"),
        ("http://remnawave:3000/", "http://remnawave:3000/api"),
        ("http://remnawave:3000/api", "http://remnawave:3000/api"),
        ("  https://panel.example.com  ", "https://panel.example.com/api"),
    ],
)
def test_get_api_url_normalization(monkeypatch, value, expected):
    monkeypatch.setenv("REMNAWAVE_BASE_URL", value)
    assert RemnawaveSync.get_api_url() == expected


def test_is_configured(monkeypatch):
    assert RemnawaveSync.is_configured() is False

    monkeypatch.setenv("REMNAWAVE_BASE_URL", "https://panel.example.com")
    assert RemnawaveSync.is_configured() is False

    monkeypatch.setenv("REMNAWAVE_BASE_URL", "https://panel.example.com")
    monkeypatch.setenv("REMNAWAVE_TOKEN", "  ")
    assert RemnawaveSync.is_configured() is False

    monkeypatch.setenv("REMNAWAVE_TOKEN", "jwt-token")
    assert RemnawaveSync.is_configured() is True


def test_get_headers(monkeypatch):
    monkeypatch.setenv("REMNAWAVE_BASE_URL", "http://remnawave:3000/api")
    monkeypatch.setenv("REMNAWAVE_TOKEN", "secret-jwt")
    headers = RemnawaveSync._get_headers()
    assert headers["Authorization"] == "Bearer secret-jwt"
    # HTTP-эндпоинт требует подмены схемы за обратным прокси
    assert headers["X-Forwarded-Proto"] == "https"

    monkeypatch.setenv("REMNAWAVE_BASE_URL", "https://panel.example.com/api")
    headers = RemnawaveSync._get_headers()
    assert "X-Forwarded-Proto" not in headers


def test_get_headers_cloudflare_service_token(monkeypatch):
    monkeypatch.setenv("REMNAWAVE_BASE_URL", "https://panel.example.com/api")
    monkeypatch.setenv("REMNAWAVE_TOKEN", "secret-jwt")
    headers = RemnawaveSync._get_headers()
    assert "CF-Access-Client-Id" not in headers

    monkeypatch.setenv("CLOUDFLARE_ZERO_TRUST_CLIENT_ID", "id.access")
    monkeypatch.setenv("CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET", "secret")
    headers = RemnawaveSync._get_headers()
    assert headers["CF-Access-Client-Id"] == "id.access"
    assert headers["CF-Access-Client-Secret"] == "secret"


# ------------------------------------------------------------------------------
# load_squad_configs / get_squad_name
# ------------------------------------------------------------------------------

def test_load_squad_configs_parses_env(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    monkeypatch.setenv("SQUAD_1_UUID", "ABCDEF12-3456")
    monkeypatch.setenv("SQUAD_1_NAME", "Main squad")
    monkeypatch.setenv("SQUAD_1_RULE", "whitelist.json")

    squads = RemnawaveSync.load_squad_configs()
    assert squads == [
        {"uuid": "abcdef12-3456", "rule": "WHITELIST.JSON", "name": "Main squad"},
    ]


def test_load_squad_configs_uses_remnawave_prefix(monkeypatch):
    monkeypatch.setenv("REMNAWAVE_SQUAD_1_UUID", "ABCDEF12-3456")
    monkeypatch.setenv("REMNAWAVE_SQUAD_1_RULE", "HAPP.JSON")
    squads = RemnawaveSync.load_squad_configs()
    assert squads == [{"uuid": "abcdef12-3456", "rule": "HAPP.JSON"}]


def test_load_squad_configs_default_rule(monkeypatch):
    """Без явного RULE используется правило по умолчанию для текущего пресета."""
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    monkeypatch.setenv("SQUAD_1_UUID", "abcdef12-3456")
    squads = RemnawaveSync.load_squad_configs()
    assert squads == [{"uuid": "abcdef12-3456", "rule": "HAPP.JSON"}]


def test_load_squad_configs_legacy_url_format(monkeypatch):
    monkeypatch.setenv("SQUAD_1_UUID", "abcdef12-3456")
    monkeypatch.setenv("SQUAD_1_URL", "https://geo.example.com/tok/HAPP/WHITELIST.DEEPLINK")
    squads = RemnawaveSync.load_squad_configs()
    assert squads == [{"uuid": "abcdef12-3456", "rule": "WHITELIST.JSON"}]


def test_load_squad_configs_skips_invalid(monkeypatch):
    monkeypatch.setenv("SQUAD_1_UUID", "not a valid uuid!")
    monkeypatch.setenv("SQUAD_2_UUID", "")
    monkeypatch.setenv("SQUAD_3_UUID", "abcdef12-3456")
    monkeypatch.setenv("SQUAD_3_NAME", "Valid")
    assert RemnawaveSync.load_squad_configs() == [
        {"uuid": "abcdef12-3456", "name": "Valid", "rule": "HAPP.JSON"},
    ]


def test_load_squad_configs_empty(monkeypatch):
    assert RemnawaveSync.load_squad_configs() == []


def test_get_squad_name_from_env(monkeypatch):
    monkeypatch.setenv("SQUAD_1_UUID", "ABCDEF12-3456")
    monkeypatch.setenv("SQUAD_1_NAME", "Main squad")
    # регистр UUID не важен
    assert RemnawaveSync.get_squad_name("abcdef12-3456") == "Main squad"
    assert RemnawaveSync.get_squad_name("ABCDEF12-3456") == "Main squad"
    assert RemnawaveSync.get_squad_name("unknown-uuid") == ""


# ------------------------------------------------------------------------------
# _read_deeplink_content
# ------------------------------------------------------------------------------

def test_read_deeplink_content_found(tmp_path):
    happ_dir = tmp_path / "HAPP"
    happ_dir.mkdir()
    (happ_dir / "HAPP.DEEPLINK").write_text(
        "happ://routing/onadd/eyJhIjoxfQ==\n", encoding="utf-8"
    )

    content = RemnawaveSync._read_deeplink_content(happ_dir, "HAPP.JSON")
    assert content == "happ://routing/onadd/eyJhIjoxfQ=="


def test_read_deeplink_content_is_case_insensitive(tmp_path):
    """Имя файла сводится к `<БАЗА В ВЕРХНЕМ РЕГИСТРЕ>.DEEPLINK`.

    Так пишет publisher (см. base.deeplink_filename_for), а запрос идёт по
    правилу из конфигурации — регистр может разойтись, например когда файл
    создан старой версией или имя пришло из источника в другом регистре.
    Точное совпадение всегда приоритетнее, регистронезависимый поиск — страховка.
    """
    happ_dir = tmp_path / "HAPP"
    happ_dir.mkdir()
    (happ_dir / "whitelist.DEEPLINK").write_text("happ://routing/onadd/Zm9v\n", encoding="utf-8")

    assert RemnawaveSync._read_deeplink_content(happ_dir, "WHITELIST.JSON") == "happ://routing/onadd/Zm9v"

    (happ_dir / "JSONSUB.DEEPLINK").write_text("happ://routing/onadd/YmFy\n", encoding="utf-8")
    assert RemnawaveSync._read_deeplink_content(happ_dir, "jsonsub.json") == "happ://routing/onadd/YmFy"


def test_read_deeplink_content_missing_file(tmp_path):
    happ_dir = tmp_path / "HAPP"
    happ_dir.mkdir()
    assert RemnawaveSync._read_deeplink_content(happ_dir, "HAPP.JSON") is None
    assert RemnawaveSync._read_deeplink_content(tmp_path / "missing", "HAPP.JSON") is None


def test_read_deeplink_content_rejects_bad_rule_name(tmp_path):
    happ_dir = tmp_path / "HAPP"
    happ_dir.mkdir()
    (happ_dir / "HAPP.DEEPLINK").write_text("happ://routing/onadd/Zm9v\n", encoding="utf-8")

    assert RemnawaveSync._read_deeplink_content(happ_dir, "bad name.json") is None
    assert RemnawaveSync._read_deeplink_content(happ_dir, "..") is None
    assert RemnawaveSync._read_deeplink_content(happ_dir, "../../etc/passwd") is None
