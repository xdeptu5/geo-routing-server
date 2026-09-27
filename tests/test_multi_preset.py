"""Тесты поддержки нескольких одновременных пресетов (multi-preset)."""

import json

import app.config as config_module
from app.downloader import Downloader
from app.main import get_summary_banner_text
from app.processors.happ import HappProcessor
from app.publisher import Publisher
from app.remnawave import RemnawaveSync
from app.cli import get_status_info


TOKEN = "test_multi_token_1234"


def test_calc_presets_parsing():
    """Проверка парсинга нескольких пресетов из строки ROUTING_SOURCE_PRESET."""
    presets_dict = config_module.Config.SOURCE_PRESETS
    
    # Несколько пресетов через запятую
    assert config_module.Config._calc_presets("hydraponique,geogaga", "", presets_dict) == ["hydraponique", "geogaga"]
    assert config_module.Config._calc_presets("vahellame, hydraponique, geogaga", "", presets_dict) == ["vahellame", "hydraponique", "geogaga"]
    
    # Удаление дубликатов с сохранением порядка
    assert config_module.Config._calc_presets("hydraponique, hydraponique, geogaga", "", presets_dict) == ["hydraponique", "geogaga"]
    
    # Одиночный пресет
    assert config_module.Config._calc_presets("geogaga", "", presets_dict) == ["geogaga"]
    assert config_module.Config._calc_presets("hydraponique", "", presets_dict) == ["hydraponique"]
    
    # Fallback при пустом значении
    assert config_module.Config._calc_presets("", "", presets_dict) == ["geogaga"]


def test_config_base_url_with_presets(monkeypatch):
    """Проверка формирования базового URL для первичного и вторичных пресетов."""
    cfg = config_module.Config
    monkeypatch.setattr(cfg, "DOMAIN", "test.example.com")
    monkeypatch.setattr(cfg, "PRIMARY_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_SOURCE_PRESET", "hydraponique")
    
    # Первичный пресет не содержит подкаталога пресета в URL (обратная совместимость)
    assert cfg.get_base_url(TOKEN) == f"https://test.example.com/{TOKEN}"
    assert cfg.get_base_url(TOKEN, preset="hydraponique") == f"https://test.example.com/{TOKEN}"
    
    # Вторичный пресет содержит верхнерегистровый префикс
    assert cfg.get_base_url(TOKEN, preset="geogaga") == f"https://test.example.com/{TOKEN}/GEOGAGA"
    assert cfg.get_base_url(TOKEN, preset="vahellame") == f"https://test.example.com/{TOKEN}/VAHELLAME"


def test_config_rule_and_geo_urls_with_presets():
    """Проверка разделения URL правил и баз для разных пресетов."""
    cfg = config_module.Config
    # Правило для geogaga
    geogaga_url = cfg.get_rule_url("HAPP", "HAPP.JSON", preset="geogaga")
    assert "geogaga-client-flavor" in geogaga_url
    assert geogaga_url.endswith("happ.json")
    
    # Правило для hydraponique
    hydra_url = cfg.get_rule_url("HAPP", "JSONSUB.JSON", preset="hydraponique")
    assert "roscomvpn-routing" in hydra_url
    assert hydra_url.endswith("HAPP/JSONSUB.JSON")
    
    # Geo-базы пресетов
    assert "geogaga-client-flavor" in cfg.get_preset_geoip_url("geogaga")
    assert "roscomvpn-geoip" in cfg.get_preset_geoip_url("hydraponique")


def test_concurrent_processors_execution(monkeypatch, tmp_path):
    """Тест одновременного запуска HappProcessor для primary и secondary пресетов."""
    storage_dir = tmp_path / "www"
    cache_dir = tmp_path / ".cache"
    custom_geo_dir = tmp_path / "custom_geo"
    cfg = config_module.Config
    
    monkeypatch.setattr(cfg, "STORAGE_DIR", storage_dir)
    monkeypatch.setattr(cfg, "CACHE_DIR", cache_dir)
    monkeypatch.setattr(cfg, "CUSTOM_GEO_DIR", custom_geo_dir)
    monkeypatch.setattr(cfg, "DOMAIN", "multi.example.com")
    monkeypatch.setattr(cfg, "PRIMARY_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_RULES", [])
    monkeypatch.setattr(cfg, "ACTIVE_PRESETS", ["hydraponique", "geogaga"])
    monkeypatch.setattr(cfg, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setattr(cfg, "SERVE_FORMATS", "ALL")
    monkeypatch.setattr(cfg, "SERVE_GEOIP", True)
    monkeypatch.setattr(cfg, "SERVE_GEOSITE", True)
    monkeypatch.setattr(cfg, "PUBLIC_GEO_BASE_URL", "")

    Publisher.reset_session()
    downloader = Downloader(cache_dir)
    
    # Мокаем скачивание правил и баз
    def mock_fetch(url, cache_key, kind="rule", trusted_url=False):
        if kind == "binary":
            return b"fake_geo_dat_content"
        # Для правил возвращаем валидный JSON конфига
        return json.dumps({
            "Routing": {"Rules": []},
            "Geoipurl": "",
            "Geositeurl": "",
        }).encode("utf-8")
        
    monkeypatch.setattr(downloader, "fetch", mock_fetch)

    # 1. Запуск первичного процессора (hydraponique)
    p_primary = HappProcessor(downloader, storage_dir, TOKEN, "multi.example.com", preset_name=None)
    monkeypatch.setattr(p_primary, "_discover_config_files", lambda: ["JSONSUB.JSON"])
    assert p_primary.process() is True

    # 2. Запуск вторичного процессора (geogaga)
    p_secondary = HappProcessor(downloader, storage_dir, TOKEN, "multi.example.com", preset_name="geogaga")
    monkeypatch.setattr(p_secondary, "_discover_config_files", lambda: ["HAPP.JSON"])
    assert p_secondary.process() is True

    # Проверяем пути первичного пресета (без префикса GEOGAGA)
    primary_happ_dir = storage_dir / TOKEN / "HAPP"
    assert (primary_happ_dir / "geoip.dat").is_file()
    assert (primary_happ_dir / "JSONSUB.JSON").is_file()
    assert (primary_happ_dir / "JSONSUB.DEEPLINK").is_file()
    
    # Проверяем пути вторичного пресета (в подкаталоге GEOGAGA)
    secondary_happ_dir = storage_dir / TOKEN / "GEOGAGA" / "HAPP"
    assert (secondary_happ_dir / "geoip.dat").is_file()
    assert (secondary_happ_dir / "HAPP.JSON").is_file()
    assert (secondary_happ_dir / "HAPP.DEEPLINK").is_file()

    # Проверяем зашитые URL в диплинках
    primary_dl_payload = HappProcessor.decode_deeplink((primary_happ_dir / "JSONSUB.DEEPLINK").read_text(), "HAPP")
    assert primary_dl_payload["Geoipurl"] == f"https://multi.example.com/{TOKEN}/HAPP/geoip.dat"

    sec_dl_payload = HappProcessor.decode_deeplink((secondary_happ_dir / "HAPP.DEEPLINK").read_text(), "HAPP")
    assert sec_dl_payload["Geoipurl"] == f"https://multi.example.com/{TOKEN}/GEOGAGA/HAPP/geoip.dat"


def test_remnawave_rule_lookup_across_presets(monkeypatch, tmp_path):
    """Тест поиска диплинка для сквадов Remnawave в мульти-пресетном режиме."""
    storage_dir = tmp_path / "www"
    token_dir = storage_dir / TOKEN
    primary_happ_dir = token_dir / "HAPP"
    sec_happ_dir = token_dir / "GEOGAGA" / "HAPP"
    primary_happ_dir.mkdir(parents=True, exist_ok=True)
    sec_happ_dir.mkdir(parents=True, exist_ok=True)
    cfg = config_module.Config

    monkeypatch.setattr(cfg, "STORAGE_DIR", storage_dir)
    monkeypatch.setattr(cfg, "PRIMARY_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ACTIVE_PRESETS", ["hydraponique", "geogaga"])

    # Создаем файлы диплинков
    (primary_happ_dir / "JSONSUB.DEEPLINK").write_text("happ://routing/onadd/primary_jsonsub\n", encoding="utf-8")
    (sec_happ_dir / "HAPP.DEEPLINK").write_text("happ://routing/onadd/secondary_geogaga_happ\n", encoding="utf-8")

    # 1. Поиск прямого правила из первичного пресета
    content1 = RemnawaveSync._read_deeplink_content(primary_happ_dir, "JSONSUB.JSON")
    assert content1 == "happ://routing/onadd/primary_jsonsub"

    # 2. Поиск с явным указанием вторичного пресета: "GEOGAGA/HAPP.JSON"
    content2 = RemnawaveSync._read_deeplink_content(primary_happ_dir, "GEOGAGA/HAPP.JSON")
    assert content2 == "happ://routing/onadd/secondary_geogaga_happ"

    # 3. Поиск с явным указанием через двоеточие: "GEOGAGA:HAPP.JSON"
    content3 = RemnawaveSync._read_deeplink_content(primary_happ_dir, "GEOGAGA:HAPP.JSON")
    assert content3 == "happ://routing/onadd/secondary_geogaga_happ"

    # 4. Автопоиск: правило "HAPP.JSON" отсутствует в primary_happ_dir, но есть во вторичном
    content4 = RemnawaveSync._read_deeplink_content(primary_happ_dir, "HAPP.JSON")
    assert content4 == "happ://routing/onadd/secondary_geogaga_happ"


def test_banner_displays_all_active_presets(monkeypatch, tmp_path):
    """Тест вывода баннера со всеми активными пресетами."""
    storage_dir = tmp_path / "www"
    cfg = config_module.Config
    monkeypatch.setattr(cfg, "STORAGE_DIR", storage_dir)
    monkeypatch.setattr(cfg, "DOMAIN", "multi.example.com")
    monkeypatch.setattr(cfg, "PRIMARY_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_RULES", [])
    monkeypatch.setattr(cfg, "ACTIVE_PRESETS", ["hydraponique", "geogaga"])
    monkeypatch.setattr(cfg, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setattr(cfg, "SERVE_FORMATS", "ALL")
    monkeypatch.setattr(cfg, "SERVE_GEOIP", True)
    monkeypatch.setattr(cfg, "SERVE_GEOSITE", True)
    monkeypatch.setattr(cfg, "PUBLIC_GEO_BASE_URL", "")

    banner = get_summary_banner_text(TOKEN, storage_dir)

    # Присутствует первичный пресет [HAPP] и [INCY]
    assert "[HAPP]" in banner
    assert "[INCY]" in banner
    assert f"https://multi.example.com/{TOKEN}/HAPP/geoip.dat" in banner

    # Присутствует вторичный пресет с его заголовком и изолированными URL
    assert "GeoGaga" in banner
    assert f"https://multi.example.com/{TOKEN}/GEOGAGA/HAPP/geoip.dat" in banner
    assert f"https://multi.example.com/{TOKEN}/GEOGAGA/INCY/geoip.dat" in banner


def test_cli_status_info_multi_preset(monkeypatch, tmp_path):
    """Тест json-структуры статуса CLI при нескольких пресетах."""
    storage_dir = tmp_path / "www"
    cfg = config_module.Config
    monkeypatch.setattr(cfg, "STORAGE_DIR", storage_dir)
    monkeypatch.setattr(cfg, "DOMAIN", "multi.example.com")
    monkeypatch.setattr(cfg, "PRIMARY_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ROUTING_RULES", [])
    monkeypatch.setattr(cfg, "ACTIVE_PRESETS", ["hydraponique", "geogaga"])
    monkeypatch.setattr(cfg, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setenv("ROUTING_TOKEN", TOKEN)

    info = get_status_info()
    assert info["primary_preset"] == "hydraponique"
    assert info["active_presets"] == ["hydraponique", "geogaga"]
    assert "secondary_presets" in info["links"]
    assert "geogaga" in info["links"]["secondary_presets"]
    
    sec_links = info["links"]["secondary_presets"]["geogaga"]
    assert sec_links["happ"]["geo"]["geoip"] == f"https://multi.example.com/{TOKEN}/GEOGAGA/HAPP/geoip.dat"


def test_remnawave_sync_multi_preset_squads(monkeypatch, tmp_path):
    """Тест синхронизации сквадов Remnawave при нескольких пресетах:
    Squad 1 использует основное правило (JSONSUB.JSON),
    Squad 2 использует правило вторичного пресета (GEOGAGA/HAPP.JSON).
    """
    token_dir = tmp_path / TOKEN
    primary_happ = token_dir / "HAPP"
    primary_happ.mkdir(parents=True)
    sec_happ = token_dir / "GEOGAGA" / "HAPP"
    sec_happ.mkdir(parents=True)

    (primary_happ / "JSONSUB.DEEPLINK").write_text("happ://routing/onadd/primary_sub\n", encoding="utf-8")
    (sec_happ / "HAPP.DEEPLINK").write_text("happ://routing/onadd/secondary_geogaga\n", encoding="utf-8")

    cfg = config_module.Config
    monkeypatch.setattr(cfg, "PRIMARY_PRESET", "hydraponique")
    monkeypatch.setattr(cfg, "ACTIVE_PRESETS", ["hydraponique", "geogaga"])
    monkeypatch.setenv("REMNAWAVE_BASE_URL", "https://panel.example.com")
    monkeypatch.setenv("REMNAWAVE_TOKEN", "test-token")

    squad_1_uuid = "11111111-1111-1111-1111-111111111111"
    squad_2_uuid = "22222222-2222-2222-2222-222222222222"
    squads = [
        {"uuid": squad_1_uuid, "rule": "JSONSUB.JSON", "name": "Squad Primary"},
        {"uuid": squad_2_uuid, "rule": "GEOGAGA/HAPP.JSON", "name": "Squad Secondary"},
    ]

    patched_squads = {}

    def fake_api_request(method, url, payload=None):
        if method == "GET" and url.endswith("/external-squads"):
            return {
                "response": [
                    {
                        "uuid": squad_1_uuid,
                        "name": "Squad Primary",
                        "responseHeadersAdd": {},
                        "responseHeadersRemove": [],
                    },
                    {
                        "uuid": squad_2_uuid,
                        "name": "Squad Secondary",
                        "responseHeadersAdd": {},
                        "responseHeadersRemove": [],
                    },
                ]
            }
        if method == "PATCH" and url.endswith("/external-squads"):
            sq_uuid = payload.get("uuid")
            header_val = payload.get("responseHeadersAdd", {}).get(RemnawaveSync.ROUTING_HEADER)
            patched_squads[sq_uuid] = header_val
            return {}
        return None

    monkeypatch.setattr(RemnawaveSync, "_api_request", fake_api_request)

    res = RemnawaveSync.sync_squads(squads, primary_happ)
    assert res is True
    assert RemnawaveSync.last_errors == []

    # Squad 1 должен получить диплинк из primary happ_dir
    assert patched_squads[squad_1_uuid] == "happ://routing/onadd/primary_sub"
    # Squad 2 должен получить диплинк из вторичного пресета (GEOGAGA)
    assert patched_squads[squad_2_uuid] == "happ://routing/onadd/secondary_geogaga"
