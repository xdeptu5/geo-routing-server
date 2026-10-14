"""Характеризационные тесты HappProcessor и IncyProcessor.

Фиксируют, какие файлы публикуются и что в них, при разных ENABLED_CLIENTS,
SERVE_FORMATS, пресетах, внешних базах и привязках сквадов. Написаны до
объединения общего кода процессоров в BaseProcessor, чтобы рефакторинг не
изменил поведение.
"""

import json

import pytest

import app.config as config_module
from app.downloader import Downloader
from app.processors.base import BaseProcessor
from app.processors.geo import GeoManager
from app.processors.happ import HappProcessor
from app.processors.incy import IncyProcessor
from app.publisher import Publisher

TOKEN = "proc_token_1234"
GEO = b"G" * 2048


@pytest.fixture
def world(monkeypatch, tmp_path):
    """Изолированное окружение: Config, поддельный загрузчик, пустые кэши."""
    cfg = config_module.Config
    storage = tmp_path / "www"
    defaults = {
        "STORAGE_DIR": storage,
        "CACHE_DIR": tmp_path / ".cache",
        "DOMAIN": "geo.example.com",
        "PRIMARY_PRESET": "geogaga",
        "ROUTING_SOURCE_PRESET": "geogaga",
        "ACTIVE_PRESETS": ["geogaga"],
        "ROUTING_RULES": [],
        "ENABLED_CLIENTS": ["HAPP", "INCY"],
        "SERVE_FORMATS": "CLIENT_OPTIMIZED",
        "SERVE_GEOIP": True,
        "SERVE_GEOSITE": True,
        "PUBLIC_GEO_BASE_URL": "",
    }
    for key, value in defaults.items():
        monkeypatch.setattr(cfg, key, value)
    monkeypatch.setenv("SQUADS_FILE", str(tmp_path / "squads.json"))
    for key in ("REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN", "REMNAWAVE_GLOBAL_RULE", "GITHUB_RAW_URL"):
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(GeoManager, "_memory_cache", {})
    monkeypatch.setattr(BaseProcessor, "_discover_config_files", lambda self: [])
    Publisher.reset_session()

    downloader = Downloader(tmp_path / ".cache")
    fetched = []

    def fake_fetch(url, cache_key, kind="binary", trusted_url=True):
        fetched.append((url, kind))
        if kind == "binary":
            return GEO
        return json.dumps({
            "Name": url.rsplit("/", 1)[-1] or "rule",
            "Geoipurl": "https://upstream/geoip.dat",
            "Geositeurl": "https://upstream/geosite.dat",
        }).encode("utf-8")

    monkeypatch.setattr(downloader, "fetch", fake_fetch)

    class World:
        def set(self, **values):
            for key, value in values.items():
                monkeypatch.setattr(cfg, key, value)

        def run(self, cls, preset=None):
            return cls(downloader, storage, TOKEN, cfg.DOMAIN, preset_name=preset).process()

        def files(self, client, sub=""):
            base = storage / TOKEN / sub / client if sub else storage / TOKEN / client
            return sorted(p.name for p in base.iterdir()) if base.is_dir() else []

        def read(self, client, name, sub=""):
            base = storage / TOKEN / sub / client if sub else storage / TOKEN / client
            text = (base / name).read_text(encoding="utf-8")
            if name.endswith(".DEEPLINK"):
                return BaseProcessor.decode_deeplink(text, client)
            return json.loads(text)

    w = World()
    w.fetched = fetched
    w.storage = storage
    w.tmp = tmp_path
    return w


LOCAL_HAPP = f"https://geo.example.com/{TOKEN}/HAPP"
LOCAL_INCY = f"https://geo.example.com/{TOKEN}/INCY"


# ------------------------------------------------------------------------------
# Happ
# ------------------------------------------------------------------------------

def test_happ_default_geogaga(world):
    assert world.run(HappProcessor) is True
    assert world.files("HAPP") == ["HAPP.DEEPLINK", "geoip.dat", "geosite.dat"]
    rule = world.read("HAPP", "HAPP.DEEPLINK")
    assert rule["Geoipurl"] == f"{LOCAL_HAPP}/geoip.dat"
    assert rule["Geositeurl"] == f"{LOCAL_HAPP}/geosite.dat"
    assert rule["LastUpdated"]


def test_happ_all_formats(world):
    world.set(SERVE_FORMATS="ALL")
    assert world.run(HappProcessor) is True
    assert world.files("HAPP") == ["HAPP.DEEPLINK", "HAPP.JSON", "geoip.dat", "geosite.dat"]


def test_happ_json_only_still_publishes_deeplink_for_remnawave(world, monkeypatch):
    world.set(SERVE_FORMATS="JSON")
    assert world.run(HappProcessor) is True
    assert world.files("HAPP") == ["HAPP.JSON", "geoip.dat", "geosite.dat"]

    monkeypatch.setenv("REMNAWAVE_BASE_URL", "http://panel/api")
    monkeypatch.setenv("REMNAWAVE_TOKEN", "jwt")
    Publisher.reset_session()
    assert world.run(HappProcessor) is True
    assert "HAPP.DEEPLINK" in world.files("HAPP")


def test_happ_deeplink_only_with_external_geo(world):
    world.set(ENABLED_CLIENTS=["HAPP_DEEPLINK"], PUBLIC_GEO_BASE_URL="https://node.example.com/tok")
    assert world.run(HappProcessor) is True
    assert world.files("HAPP") == ["HAPP.DEEPLINK"]
    rule = world.read("HAPP", "HAPP.DEEPLINK")
    assert rule["Geoipurl"] == "https://node.example.com/tok/HAPP/geoip.dat"


def test_happ_geo_only(world):
    world.set(ENABLED_CLIENTS=["HAPP_GEO"])
    assert world.run(HappProcessor) is True
    assert world.files("HAPP") == ["geoip.dat", "geosite.dat"]


def test_happ_geo_disabled_keeps_upstream_urls(world):
    world.set(SERVE_GEOIP=False, SERVE_GEOSITE=False)
    assert world.run(HappProcessor) is True
    assert world.files("HAPP") == ["HAPP.DEEPLINK"]
    rule = world.read("HAPP", "HAPP.DEEPLINK")
    assert rule["Geoipurl"] == "https://upstream/geoip.dat"


def test_happ_hydraponique_adds_rules_from_squads(world):
    world.set(PRIMARY_PRESET="hydraponique", ROUTING_SOURCE_PRESET="hydraponique",
              ACTIVE_PRESETS=["hydraponique"], ROUTING_RULES=["JSONSUB"])
    (world.tmp / "squads.json").write_text(json.dumps([
        {"uuid": "a1", "rule": "CUSTOM.JSON"},
        {"uuid": "a2", "rule": "GEOGAGA/HAPP.JSON"},  # префикс другого пресета — не этому процессору
    ]), encoding="utf-8")
    assert world.run(HappProcessor) is True
    rules = [f for f in world.files("HAPP") if f.endswith(".DEEPLINK")]
    assert rules == ["CUSTOM.DEEPLINK", "JSONSUB.DEEPLINK"]


def test_happ_secondary_preset_paths(world):
    world.set(PRIMARY_PRESET="hydraponique", ROUTING_SOURCE_PRESET="hydraponique",
              ACTIVE_PRESETS=["hydraponique", "geogaga"])
    assert world.run(HappProcessor, preset="geogaga") is True
    assert world.files("HAPP", sub="GEOGAGA") == ["HAPP.DEEPLINK", "geoip.dat", "geosite.dat"]
    rule = world.read("HAPP", "HAPP.DEEPLINK", sub="GEOGAGA")
    assert rule["Geoipurl"] == f"https://geo.example.com/{TOKEN}/GEOGAGA/HAPP/geoip.dat"


def test_happ_cleanup_removes_obsolete_only_on_success(world, monkeypatch):
    world.set(SERVE_FORMATS="ALL")
    assert world.run(HappProcessor) is True
    stale = world.storage / TOKEN / "HAPP" / "OLD.DEEPLINK"
    stale.write_text("x", encoding="utf-8")
    Publisher.reset_session()
    assert world.run(HappProcessor) is True
    assert not stale.exists()

    stale.write_text("x", encoding="utf-8")
    monkeypatch.setattr(Publisher, "publish_file", classmethod(lambda cls, *a, **k: False))
    Publisher.reset_session()
    assert world.run(HappProcessor) is False
    assert stale.exists()


# ------------------------------------------------------------------------------
# Incy
# ------------------------------------------------------------------------------

def test_incy_default_geogaga(world):
    assert world.run(IncyProcessor) is True
    assert world.files("INCY") == ["INCY.JSON", "geoip.dat", "geosite.dat"]
    rule = world.read("INCY", "INCY.JSON")
    assert rule["Geoipurl"] == f"{LOCAL_INCY}/geoip.dat"


def test_incy_all_formats(world):
    world.set(SERVE_FORMATS="ALL")
    assert world.run(IncyProcessor) is True
    assert world.files("INCY") == ["INCY.DEEPLINK", "INCY.JSON", "geoip.dat", "geosite.dat"]
    assert world.read("INCY", "INCY.DEEPLINK")["Geoipurl"] == f"{LOCAL_INCY}/geoip.dat"


def test_incy_does_not_publish_deeplink_for_remnawave(world, monkeypatch):
    monkeypatch.setenv("REMNAWAVE_BASE_URL", "http://panel/api")
    monkeypatch.setenv("REMNAWAVE_TOKEN", "jwt")
    assert world.run(IncyProcessor) is True
    assert "INCY.DEEPLINK" not in world.files("INCY")


def test_incy_geo_only(world):
    world.set(ENABLED_CLIENTS=["INCY_GEO"])
    assert world.run(IncyProcessor) is True
    assert world.files("INCY") == ["geoip.dat", "geosite.dat"]


def test_incy_geo_only_with_external_geo_skips_downloads(world):
    world.set(ENABLED_CLIENTS=["INCY_GEO"], PUBLIC_GEO_BASE_URL="https://node.example.com/tok")
    assert world.run(IncyProcessor) is True
    assert world.files("INCY") == []
    assert world.fetched == []


def test_incy_ignores_squad_rules(world):
    world.set(PRIMARY_PRESET="hydraponique", ROUTING_SOURCE_PRESET="hydraponique",
              ACTIVE_PRESETS=["hydraponique"], ROUTING_RULES=["JSONSUB"])
    (world.tmp / "squads.json").write_text(json.dumps([{"uuid": "a1", "rule": "CUSTOM.JSON"}]), encoding="utf-8")
    assert world.run(IncyProcessor) is True
    assert [f for f in world.files("INCY") if f.endswith(".JSON")] == ["JSONSUB.JSON"]


def test_unparseable_rule_marks_failure(world, monkeypatch):
    def broken_fetch(self, url, cache_key, kind="binary", trusted_url=True):
        return GEO if kind == "binary" else b"not json and not a deeplink"

    monkeypatch.setattr(Downloader, "fetch", broken_fetch)
    storage = world.storage
    downloader = Downloader(world.tmp / ".cache2")
    assert IncyProcessor(downloader, storage, TOKEN, "geo.example.com").process() is False


# ------------------------------------------------------------------------------
# Общие функции, на которые опираются процессоры
# ------------------------------------------------------------------------------

@pytest.mark.parametrize("modules,client,feature,expected", [
    (["HAPP"], "HAPP", None, True),
    (["HAPP"], "HAPP", "geo", True),
    (["HAPP_GEO"], "HAPP", "rules", False),
    (["HAPP_DEEPLINK"], "HAPP", "rules", True),
    (["HAPP_DEEPLINK"], "HAPP", "geo", False),
    (["HAPP_LOCAL"], "happ", "rules", True),
    (["INCY_GEO"], "INCY", "rules", False),
    (["INCY_GEO"], "HAPP", None, False),
    (["UNKNOWN"], "HAPP", None, False),
])
def test_client_enabled(monkeypatch, modules, client, feature, expected):
    monkeypatch.setattr(config_module.Config, "ENABLED_CLIENTS", modules)
    assert config_module.Config.client_enabled(client, feature) is expected


@pytest.mark.parametrize("raw,expected", [
    ("GEOGAGA/HAPP.JSON", ("GEOGAGA", "HAPP.JSON")),
    ("geogaga:happ", ("GEOGAGA", "HAPP.JSON")),
    ("whitelist.deeplink", (None, "WHITELIST.JSON")),
    ("https://geo.example.com/tok/HAPP/JSONSUB.JSON", (None, "JSONSUB.JSON")),
    ("", (None, "")),
])
def test_split_squad_rule(raw, expected):
    from app.squads import split_squad_rule

    assert split_squad_rule(raw) == expected
