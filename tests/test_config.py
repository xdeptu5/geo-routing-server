"""Тесты app/config.py: пресеты, фильтрация правил, токен, URL, форматы."""

import pytest

from app.config import Config


# ------------------------------------------------------------------------------
# get_active_rules: выбор правил для генерации
# ------------------------------------------------------------------------------

@pytest.mark.parametrize("preset", ["geogaga", "vahellame", "hydraponique", "custom"])
@pytest.mark.parametrize("client", ["HAPP", "INCY", ""])
def test_get_display_rules_never_returns_empty_list(monkeypatch, preset, client):
    """Список для баннера/сводки не должен быть пустым.

    main.py строит баннер ссылок из Config.get_display_rules(): пустой список
    означал бы баннер без единой ссылки (регрессия из ревью).
    """
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", preset)
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    rules = Config.get_display_rules([], client=client)
    assert rules, f"get_display_rules([], preset={preset!r}) returned an empty list"
    assert all(r.upper().endswith(".JSON") for r in rules)


def test_get_display_rules_uses_fallback_for_empty_discovery(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    assert Config.get_display_rules()  # без аргументов — то же самое
    rules = Config.get_display_rules([], client="INCY")
    assert rules
    assert all(r.upper().endswith(".JSON") for r in rules)


def test_get_display_rules_respects_routing_rules(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_RULES", ["JSONSUB", "WHITELIST"])
    rules = Config.get_display_rules([], client="HAPP")
    assert rules
    assert any(r.upper().startswith("JSONSUB") for r in rules)
    assert any(r.upper().startswith("WHITELIST") for r in rules)


def test_geogaga_preset_returns_single_client_rule(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    assert Config.get_active_rules([], client="HAPP") == ["HAPP.JSON"]
    assert Config.get_active_rules([], client="INCY") == ["INCY.JSON"]
    assert Config.get_active_rules([], client="incy") == ["INCY.JSON"]
    assert Config.get_active_rules([], client="") == ["HAPP.JSON"]
    # пресет игнорирует список обнаруженных файлов
    assert Config.get_active_rules(["OTHER.JSON"], client="HAPP") == ["HAPP.JSON"]


def test_vahellame_preset_returns_whitelist_rule(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "vahellame")
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    assert Config.get_active_rules([], client="HAPP") == ["WHITELIST.JSON"]
    assert Config.get_active_rules(["WHITELIST.JSON"], client="INCY") == ["WHITELIST.JSON"]


def test_routing_rules_adds_missing_rules_as_json(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_RULES", ["JSONSUB"])
    assert Config.get_active_rules([], client="HAPP") == ["JSONSUB.JSON"]


def test_routing_rules_prefer_discovered_case(monkeypatch):
    """Совпадающее правило берётся из обнаруженных с исходным регистром."""
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_RULES", ["JSONSUB", "WHITELIST"])
    assert Config.get_active_rules(["jsonsub.json"], client="HAPP") == [
        "jsonsub.json",
        "WHITELIST.JSON",
    ]


def test_routing_rules_order_follows_config(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_RULES", ["WHITELIST", "JSONSUB"])
    assert Config.get_active_rules(["JSONSUB.JSON"], client="HAPP") == [
        "WHITELIST.JSON",
        "JSONSUB.JSON",
    ]


def test_empty_routing_rules_pass_through_discovered(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_RULES", [])
    assert Config.get_active_rules(["A.JSON", "b.json"], client="HAPP") == ["A.JSON", "b.json"]


# ------------------------------------------------------------------------------
# SERVE_FORMATS: что публикуется для каждого клиента
# ------------------------------------------------------------------------------

@pytest.mark.parametrize(
    ("fmt", "client", "serve_json", "serve_deeplink"),
    [
        ("CLIENT_OPTIMIZED", "HAPP", False, True),
        ("CLIENT_OPTIMIZED", "INCY", True, False),
        ("CLIENT_OPTIMIZED", "happ", False, True),
        ("OPTIMIZED", "HAPP", False, True),
        ("OPTIMIZED", "INCY", True, False),
        ("ALL", "HAPP", True, True),
        ("ALL", "INCY", True, True),
        ("JSON", "HAPP", True, False),
        ("JSON", "INCY", True, False),
        ("DEEPLINK", "HAPP", False, True),
        ("DEEPLINK", "INCY", False, True),
    ],
)
def test_serve_formats_matrix(monkeypatch, fmt, client, serve_json, serve_deeplink):
    monkeypatch.setattr(Config, "SERVE_FORMATS", fmt)
    assert Config.should_serve_json(client) is serve_json
    assert Config.should_serve_deeplink(client) is serve_deeplink


# ------------------------------------------------------------------------------
# Токен
# ------------------------------------------------------------------------------

def test_token_from_env_is_stripped_and_validated(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setenv("ROUTING_TOKEN", "  abc-def_123  ")
    assert Config.get_token() == "abc-def_123"


def test_token_env_wins_over_token_file(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    (tmp_path / "token.txt").write_text("file_token_42\n", encoding="utf-8")
    monkeypatch.setenv("ROUTING_TOKEN", "env_token_99")
    assert Config.get_token() == "env_token_99"


def test_token_falls_back_to_token_file(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.delenv("ROUTING_TOKEN", raising=False)
    (tmp_path / "token.txt").write_text("file_token_42\n", encoding="utf-8")
    assert Config.get_token() == "file_token_42"


def test_token_placeholder_is_rejected_for_public_serving(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setenv("ROUTING_TOKEN", "change_me_to_random_secret_token")
    with pytest.raises(SystemExit):
        Config.get_token()


def test_token_placeholder_allowed_for_deeplink_only_mode(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP_DEEPLINK", "HAPP_LOCAL"])
    monkeypatch.setenv("ROUTING_TOKEN", "change_me_to_random_secret_token")
    assert Config.get_token() == "local"


def test_token_rejects_short_value(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setenv("ROUTING_TOKEN", "abc")
    with pytest.raises(SystemExit):
        Config.get_token()


def test_token_rejects_path_traversal_chars(monkeypatch, tmp_path):
    """Точки в токене запрещены: защита от path traversal и скрытых файлов."""
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setenv("ROUTING_TOKEN", "ab..cd")
    with pytest.raises(SystemExit):
        Config.get_token()


def test_token_rejects_empty_value(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, "BASE_DIR", tmp_path)
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.delenv("ROUTING_TOKEN", raising=False)
    with pytest.raises(SystemExit):
        Config.get_token()


# ------------------------------------------------------------------------------
# URL: базовый URL, внешние geo-базы, GitHub Contents API, пресеты
# ------------------------------------------------------------------------------

def test_base_url(monkeypatch):
    monkeypatch.setattr(Config, "DOMAIN", "geo.example.com")
    assert Config.get_base_url("secret123") == "https://geo.example.com/secret123"


def test_validate_http_url():
    assert Config._validate_http_url("geo.example.com/x") == "https://geo.example.com/x"
    assert Config._validate_http_url("  http://a.example/x  ") == "http://a.example/x"
    assert Config._validate_http_url("https://a.example/x") == "https://a.example/x"
    assert Config._validate_http_url("") == ""
    assert Config._validate_http_url("   ") == ""


@pytest.mark.parametrize(
    ("public_base", "client", "expected"),
    [
        ("", "HAPP", ""),
        ("https://geo-node.example.com/tok", "HAPP", "https://geo-node.example.com/tok/HAPP"),
        ("https://geo-node.example.com/tok", "incy", "https://geo-node.example.com/tok/INCY"),
        ("https://geo-node.example.com/tok/happ", "INCY", "https://geo-node.example.com/tok/INCY"),
        ("https://geo-node.example.com/tok/INCY", "HAPP", "https://geo-node.example.com/tok/HAPP"),
    ],
)
def test_get_external_geo_url(monkeypatch, public_base, client, expected):
    monkeypatch.setattr(Config, "PUBLIC_GEO_BASE_URL", public_base)
    assert Config.get_external_geo_url(client) == expected


@pytest.mark.parametrize(
    ("env_preset", "env_repo", "expected"),
    [
        ("geogaga", "", "geogaga"),
        ("Vahellame", "", "vahellame"),
        ("custom", "", "custom"),
        ("", "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main", "hydraponique"),
        ("", "https://raw.githubusercontent.com/vahellame/russia-whitelist-routing/main", "vahellame"),
        ("", "https://example.com/rules", "custom"),
        ("", "", "geogaga"),
        ("unknown", "", "geogaga"),
        ("unknown", "https://example.com/rules", "custom"),
    ],
)
def test_calc_preset(env_preset, env_repo, expected):
    assert Config._calc_preset(env_preset, env_repo, Config.SOURCE_PRESETS) == expected


def test_source_presets_shape():
    assert {"geogaga", "vahellame", "hydraponique"} <= set(Config.SOURCE_PRESETS)
    for key, preset in Config.SOURCE_PRESETS.items():
        for field in ("name", "description", "routing_repo", "geoip_url", "geosite_url", "rules_format"):
            assert preset.get(field), f"{key}: preset is missing {field}"
        assert preset["routing_repo"].startswith("https://")
        assert preset["geoip_url"].endswith(".dat")
        assert preset["geosite_url"].endswith(".dat")


def test_rule_urls_per_preset(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_REPO", "https://raw.githubusercontent.com/owner/repo/main")
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")
    assert Config.get_rule_url("HAPP", "HAPP.JSON") == "https://raw.githubusercontent.com/owner/repo/main/happ.json"
    assert Config.get_default_rule_url("HAPP") == "https://raw.githubusercontent.com/owner/repo/main/happ.json"

    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "vahellame")
    assert Config.get_rule_url("HAPP", "WHITELIST.JSON") == "https://vahellame.github.io/russia-whitelist-routing/happ/"

    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "custom")
    assert Config.get_rule_url("INCY", "DEFAULT.JSON") == "https://raw.githubusercontent.com/owner/repo/main/INCY/DEFAULT.JSON"
    assert Config.get_default_rule_url("INCY") == "https://raw.githubusercontent.com/owner/repo/main/INCY/DEFAULT.JSON"


@pytest.mark.parametrize("preset", ["geogaga", "vahellame"])
def test_github_contents_url_layout_matches_preset(monkeypatch, preset):
    """Раскладка Contents API согласуется с get_rule_url для встроенных пресетов.

    geogaga:   плоский {repo}/{client}.json  -> listing каталога источника;
    vahellame: правило лежит в profiles/     -> listing .../profiles.
    """
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", preset)
    monkeypatch.setattr(Config, "ROUTING_SOURCE_REPO", Config.SOURCE_PRESETS[preset]["routing_repo"])
    url = Config.get_github_contents_url("HAPP")
    assert url.startswith("https://api.github.com/repos/")

    if preset == "geogaga":
        # bratishkadrugoimamysynishka/geogaga-client-flavor, ветка release, каталог routing
        assert url == (
            "https://api.github.com/repos/bratishkadrugoimamysynishka/"
            "geogaga-client-flavor/contents/routing?ref=release"
        )
    else:
        # vahellame/russia-whitelist-routing, ветка main, каталог profiles
        assert url == (
            "https://api.github.com/repos/vahellame/russia-whitelist-routing/"
            "contents/profiles?ref=main"
        )


def test_github_contents_url_for_github_source(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "custom")
    monkeypatch.setattr(
        Config,
        "ROUTING_SOURCE_REPO",
        "https://raw.githubusercontent.com/owner/repo/my-branch/sub/dir",
    )
    assert (
        Config.get_github_contents_url("HAPP")
        == "https://api.github.com/repos/owner/repo/contents/sub/dir/HAPP?ref=my-branch"
    )


def test_github_contents_url_quotes_ref(monkeypatch):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "hydraponique")
    monkeypatch.setattr(Config, "ROUTING_SOURCE_REPO", "https://raw.githubusercontent.com/owner/repo/feature branch")
    assert (
        Config.get_github_contents_url("INCY")
        == "https://api.github.com/repos/owner/repo/contents/INCY?ref=feature%20branch"
    )


@pytest.mark.parametrize(
    "repo",
    [
        "https://example.com/rules",
        "http://raw.githubusercontent.com/owner/repo/main",
        "https://raw.githubusercontent.com/owner/repo",
        "https://github.com/owner/repo/raw/main",
    ],
)
def test_github_contents_url_rejects_unsupported_sources(monkeypatch, repo):
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "custom")
    monkeypatch.setattr(Config, "ROUTING_SOURCE_REPO", repo)
    assert Config.get_github_contents_url("HAPP") == ""


# ------------------------------------------------------------------------------
# Парсинг переменных окружения (требует перезагрузки модуля)
# ------------------------------------------------------------------------------

def test_enabled_clients_parsing(config_with_env):
    cfg = config_with_env(ENABLED_CLIENTS=" happ , ,incy ")
    assert cfg.ENABLED_CLIENTS == ["HAPP", "INCY"]
    cfg = config_with_env(ENABLED_CLIENTS="")
    assert cfg.ENABLED_CLIENTS == []


def test_routing_rules_parsing(config_with_env):
    cfg = config_with_env(ROUTING_RULES="jsonsub.json, WHITELIST")
    assert cfg.ROUTING_RULES == ["JSONSUB", "WHITELIST"]
    cfg = config_with_env(ROUTING_RULES="ALL")
    assert cfg.ROUTING_RULES == []
    cfg = config_with_env(ROUTING_RULES="")
    assert cfg.ROUTING_RULES == []


def test_domain_normalization(config_with_env):
    cfg = config_with_env(DOMAIN="https://Geo.Example.com/")
    assert cfg.DOMAIN == "Geo.Example.com"
    cfg = config_with_env(DOMAIN="geo2.example.com")
    assert cfg.DOMAIN == "geo2.example.com"


def test_bool_and_schedule_defaults(config_with_env):
    cfg = config_with_env()
    assert cfg.SERVE_FORMATS == "CLIENT_OPTIMIZED"
    assert cfg.SERVE_GEOIP is True
    assert cfg.SERVE_GEOSITE is True
    assert cfg.SCHEDULE == "0 10 * * *"
    assert cfg.SYNC_ON_START is True

    cfg = config_with_env(SYNC_ON_START="no", SERVE_GEOIP="false", SERVE_GEOSITE="0", SERVE_FORMATS=" json ")
    assert cfg.SYNC_ON_START is False
    assert cfg.SERVE_GEOIP is False
    assert cfg.SERVE_GEOSITE is False
    assert cfg.SERVE_FORMATS == "JSON"


def test_public_geo_base_url_autoscheme(config_with_env):
    cfg = config_with_env(PUBLIC_GEO_BASE_URL="geo-node.example.com/tok/")
    assert cfg.PUBLIC_GEO_BASE_URL == "https://geo-node.example.com/tok"
    cfg = config_with_env(PUBLIC_GEO_BASE_URL="http://node.example/tok")
    assert cfg.PUBLIC_GEO_BASE_URL == "http://node.example/tok"
    cfg = config_with_env()
    assert cfg.PUBLIC_GEO_BASE_URL == ""


def test_preset_selection_from_env(config_with_env):
    cfg = config_with_env(ROUTING_SOURCE_PRESET="vahellame")
    assert cfg.ROUTING_SOURCE_PRESET == "vahellame"
    assert cfg.GEOIP_SOURCE_URL.startswith("https://github.com/vahellame/")

    cfg = config_with_env(
        ROUTING_SOURCE_PRESET="",
        ROUTING_SOURCE_REPO="https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main",
    )
    assert cfg.ROUTING_SOURCE_PRESET == "hydraponique"
    assert cfg.ROUTING_SOURCE_REPO == "https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main"

    cfg = config_with_env(
        ROUTING_SOURCE_PRESET="",
        ROUTING_SOURCE_REPO="https://example.com/rules",
        GEOIP_SOURCE_URL="example.com/custom/geoip.dat",
    )
    assert cfg.ROUTING_SOURCE_PRESET == "custom"
    assert cfg.GEOIP_SOURCE_URL == "https://example.com/custom/geoip.dat"


def test_default_preset_is_geogaga(config_with_env):
    cfg = config_with_env()
    assert cfg.ROUTING_SOURCE_PRESET == "geogaga"
    assert cfg.ROUTING_SOURCE_REPO == Config.SOURCE_PRESETS["geogaga"]["routing_repo"]
    assert cfg.GEOIP_SOURCE_URL == Config.SOURCE_PRESETS["geogaga"]["geoip_url"]
