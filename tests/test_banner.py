"""Тесты баннера app/main.py: ссылки в баннере соответствуют README/nginx."""

import pytest

from app.config import Config
from app.main import print_summary_banner
from app.remnawave import RemnawaveSync

TOKEN = "secret123"
BASE = f"https://geo.example.com/{TOKEN}"


@pytest.fixture
def banner_env(monkeypatch):
    """Чистая конфигурация: HAPP+INCY, без Remnawave API, без внешних баз."""
    for key in ("REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN", "REMNAWAVE_GLOBAL_RULE"):
        monkeypatch.delenv(key, raising=False)
    assert RemnawaveSync.is_configured() is False

    monkeypatch.setattr(Config, "DOMAIN", "geo.example.com")
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setattr(Config, "SERVE_FORMATS", "CLIENT_OPTIMIZED")
    monkeypatch.setattr(Config, "SERVE_GEOIP", True)
    monkeypatch.setattr(Config, "SERVE_GEOSITE", True)
    monkeypatch.setattr(Config, "PUBLIC_GEO_BASE_URL", "")
    return monkeypatch


def _out(capsys):
    return capsys.readouterr().out


def test_banner_geogaga_happ_deeplink(banner_env, capsys):
    banner_env.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    banner_env.setattr(Config, "ROUTING_RULES", [])

    print_summary_banner(TOKEN)
    out = _out(capsys)

    # ссылка на диплинк в точности соответствует README и nginx-allowlist
    assert f"{BASE}/HAPP/HAPP.DEEPLINK" in out
    # CLIENT_OPTIMIZED: Happ не должен получить .JSON
    assert f"{BASE}/HAPP/HAPP.JSON" not in out
    # локальные geo-базы раздаются по токену
    assert f"{BASE}/HAPP/geoip.dat" in out
    assert f"{BASE}/HAPP/geosite.dat" in out


def test_banner_geogaga_incy_autorouting_header(banner_env, capsys):
    banner_env.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    banner_env.setattr(Config, "ROUTING_RULES", [])

    print_summary_banner(TOKEN)
    out = _out(capsys)

    assert "Header Name:  autorouting" in out
    assert f"incy://autorouting/onadd/{BASE}/INCY/INCY.JSON" in out
    assert f"{BASE}/INCY/geoip.dat" in out


def _happ_rule_links(out):
    return [
        line
        for line in out.splitlines()
        if f"{BASE}/HAPP/" in line and (".DEEPLINK" in line or ".JSON" in line)
    ]


@pytest.mark.parametrize("preset", ["geogaga", "vahellame"])
def test_banner_lists_rules_for_builtin_presets(banner_env, capsys, preset):
    """Баннер показывает хотя бы одно правило для встроенных пресетов."""
    banner_env.setattr(Config, "ROUTING_SOURCE_PRESET", preset)
    banner_env.setattr(Config, "ROUTING_RULES", [])

    print_summary_banner(TOKEN)
    out = _out(capsys)

    assert _happ_rule_links(out), f"banner has no HAPP rule links for preset {preset!r}"
    assert "•" in out


@pytest.mark.parametrize("preset", ["hydraponique", "custom"])
def test_banner_lists_rules_when_discovery_is_empty(banner_env, capsys, preset):
    """Пустое обнаружение правил не должно давать пустой баннер.

    get_active_rules([], ...) обязан возвращать хотя бы правило по умолчанию,
    иначе блок ссылок в баннере пуст (регрессия из ревью).
    """
    banner_env.setattr(Config, "ROUTING_SOURCE_PRESET", preset)
    banner_env.setattr(Config, "ROUTING_RULES", [])

    print_summary_banner(TOKEN)
    out = _out(capsys)

    assert _happ_rule_links(out), f"banner has no HAPP rule links for preset {preset!r}"


def test_banner_external_geo_urls(banner_env, capsys):
    banner_env.setattr(Config, "PUBLIC_GEO_BASE_URL", "https://geo-node.example.com/ext_tok")
    banner_env.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    banner_env.setattr(Config, "ROUTING_RULES", [])

    print_summary_banner(TOKEN)
    out = _out(capsys)

    assert "https://geo-node.example.com/ext_tok/HAPP/geoip.dat" in out
    assert "https://geo-node.example.com/ext_tok/INCY/geosite.dat" in out
    # локальные ссылки на базы не должны смешиваться с внешними
    assert f"{BASE}/HAPP/geoip.dat" not in out


def test_banner_no_active_clients(banner_env, capsys):
    banner_env.setattr(Config, "ENABLED_CLIENTS", ["UNKNOWN"])
    print_summary_banner(TOKEN)
    out = _out(capsys)
    assert "No active clients configured in ENABLED_CLIENTS." in out
