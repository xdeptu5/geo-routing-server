"""Тесты app/config.py: пресеты, фильтрация правил, токен, URL, форматы."""
import pytest
from app.config import Config

@pytest.mark.parametrize('preset', ['geogaga', 'vahellame', 'hydraponique'])
@pytest.mark.parametrize('client', ['HAPP', 'INCY', ''])
def test_get_display_rules_never_returns_empty_list(monkeypatch, preset, client):
    """Список для баннера/сводки не должен быть пустым.

    main.py строит баннер ссылок из Config.get_display_rules(): пустой список
    означал бы баннер без единой ссылки (регрессия из ревью).
    """
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', preset)
    monkeypatch.setattr(Config, 'ROUTING_RULES', [])
    rules = Config.get_display_rules([], client=client)
    assert rules, f'get_display_rules([], preset={preset!r}) returned an empty list'
    assert all((r.upper().endswith('.JSON') for r in rules))

def test_get_display_rules_uses_fallback_for_empty_discovery(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', [])
    assert Config.get_display_rules()
    rules = Config.get_display_rules([], client='INCY')
    assert rules
    assert all((r.upper().endswith('.JSON') for r in rules))

def test_get_display_rules_respects_routing_rules(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', ['JSONSUB', 'WHITELIST'])
    rules = Config.get_display_rules([], client='HAPP')
    assert rules
    assert any((r.upper().startswith('JSONSUB') for r in rules))
    assert any((r.upper().startswith('WHITELIST') for r in rules))

def test_geogaga_preset_returns_single_client_rule(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'geogaga')
    monkeypatch.setattr(Config, 'ROUTING_RULES', [])
    assert Config.get_active_rules([], client='HAPP') == ['HAPP.JSON']
    assert Config.get_active_rules([], client='INCY') == ['INCY.JSON']
    assert Config.get_active_rules([], client='incy') == ['INCY.JSON']
    assert Config.get_active_rules([], client='') == ['HAPP.JSON']
    assert Config.get_active_rules(['OTHER.JSON'], client='HAPP') == ['HAPP.JSON']

def test_vahellame_preset_returns_whitelist_rule(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'vahellame')
    monkeypatch.setattr(Config, 'ROUTING_RULES', [])
    assert Config.get_active_rules([], client='HAPP') == ['WHITELIST.JSON']
    assert Config.get_active_rules(['WHITELIST.JSON'], client='INCY') == ['WHITELIST.JSON']

def test_routing_rules_adds_missing_rules_as_json(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', ['JSONSUB'])
    assert Config.get_active_rules([], client='HAPP') == ['JSONSUB.JSON']

def test_routing_rules_prefer_discovered_case(monkeypatch):
    """Совпадающее правило берётся из обнаруженных с исходным регистром."""
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', ['JSONSUB', 'WHITELIST'])
    assert Config.get_active_rules(['jsonsub.json'], client='HAPP') == ['jsonsub.json', 'WHITELIST.JSON']

def test_routing_rules_order_follows_config(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', ['WHITELIST', 'JSONSUB'])
    assert Config.get_active_rules(['JSONSUB.JSON'], client='HAPP') == ['WHITELIST.JSON', 'JSONSUB.JSON']

def test_empty_routing_rules_pass_through_discovered(monkeypatch):
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', [])
    assert Config.get_active_rules(['A.JSON', 'b.json'], client='HAPP') == ['A.JSON', 'b.json']

def test_empty_routing_rules_with_empty_discovery_returns_preset_defaults(monkeypatch):
    """Дефект #15: при ROUTING_RULES=ALL и пустом списке файлов возвращается дефолтный список пресета."""
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'hydraponique')
    monkeypatch.setattr(Config, 'ROUTING_RULES', [])
    assert Config.get_active_rules([], client='HAPP') == ['DEFAULT.JSON', 'JSONSUB.JSON', 'WHITELIST.JSON']
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'geogaga')
    assert Config.get_active_rules([], client='HAPP') == ['HAPP.JSON']
    assert Config.get_active_rules([], client='INCY') == ['INCY.JSON']
    monkeypatch.setattr(Config, 'ROUTING_SOURCE_PRESET', 'vahellame')
    assert Config.get_active_rules([], client='HAPP') == ['WHITELIST.JSON']

@pytest.mark.parametrize(('fmt', 'client', 'serve_json', 'serve_deeplink'), [('CLIENT_OPTIMIZED', 'HAPP', False, True), ('CLIENT_OPTIMIZED', 'INCY', True, False), ('CLIENT_OPTIMIZED', 'happ', False, True), ('OPTIMIZED', 'HAPP', False, True), ('OPTIMIZED', 'INCY', True, False), ('ALL', 'HAPP', True, True), ('ALL', 'INCY', True, True), ('JSON', 'HAPP', True, False), ('JSON', 'INCY', True, False), ('DEEPLINK', 'HAPP', False, True), ('DEEPLINK', 'INCY', False, True)])
def test_serve_formats_matrix(monkeypatch, fmt, client, serve_json, serve_deeplink):
    monkeypatch.setattr(Config, 'SERVE_FORMATS', fmt)
    assert Config.should_serve_json(client) is serve_json
    assert Config.should_serve_deeplink(client) is serve_deeplink

def test_token_from_env_is_stripped_and_validated(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    monkeypatch.setenv('ROUTING_TOKEN', '  abc-def_123  ')
    assert Config.get_token() == 'abc-def_123'

def test_token_env_wins_over_token_file(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    (tmp_path / 'token.txt').write_text('file_token_42\n', encoding='utf-8')
    monkeypatch.setenv('ROUTING_TOKEN', 'env_token_99')
    assert Config.get_token() == 'env_token_99'

def test_token_falls_back_to_token_file(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    monkeypatch.delenv('ROUTING_TOKEN', raising=False)
    (tmp_path / 'token.txt').write_text('file_token_42\n', encoding='utf-8')
    assert Config.get_token() == 'file_token_42'

def test_token_placeholder_is_rejected_for_public_serving(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    monkeypatch.setenv('ROUTING_TOKEN', 'change_me_to_random_secret_token')
    with pytest.raises(SystemExit):
        Config.get_token()

def test_token_placeholder_allowed_for_deeplink_only_mode(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP_DEEPLINK', 'HAPP_LOCAL'])
    monkeypatch.setenv('ROUTING_TOKEN', 'change_me_to_random_secret_token')
    assert Config.get_token() == 'local'

def test_token_rejects_short_value(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    monkeypatch.setenv('ROUTING_TOKEN', 'abc')
    with pytest.raises(SystemExit):
        Config.get_token()

def test_token_rejects_path_traversal_chars(monkeypatch, tmp_path):
    """Точки в токене запрещены: защита от path traversal и скрытых файлов."""
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    monkeypatch.setenv('ROUTING_TOKEN', 'ab..cd')
    with pytest.raises(SystemExit):
        Config.get_token()

def test_token_rejects_empty_value(monkeypatch, tmp_path):
    monkeypatch.setattr(Config, 'BASE_DIR', tmp_path)
    monkeypatch.setattr(Config, 'ENABLED_CLIENTS', ['HAPP', 'INCY'])
    monkeypatch.delenv('ROUTING_TOKEN', raising=False)
    with pytest.raises(SystemExit):
        Config.get_token()

def test_base_url(monkeypatch):
    monkeypatch.setattr(Config, 'DOMAIN', 'geo.example.com')
    assert Config.get_base_url('secret123') == 'https://geo.example.com/secret123'

def test_validate_http_url():
    assert Config._validate_http_url('geo.example.com/x') == 'https://geo.example.com/x'
    assert Config._validate_http_url('  http://a.example/x  ') == 'http://a.example/x'
    assert Config._validate_http_url('https://a.example/x') == 'https://a.example/x'
    assert Config._validate_http_url('') == ''
    assert Config._validate_http_url('   ') == ''

@pytest.mark.parametrize(('public_base', 'client', 'expected'), [('', 'HAPP', ''), ('https://geo-node.example.com/tok', 'HAPP', 'https://geo-node.example.com/tok/HAPP'), ('https://geo-node.example.com/tok', 'incy', 'https://geo-node.example.com/tok/INCY'), ('https://geo-node.example.com/tok/happ', 'INCY', 'https://geo-node.example.com/tok/INCY'), ('https://geo-node.example.com/tok/INCY', 'HAPP', 'https://geo-node.example.com/tok/HAPP')])
def test_get_external_geo_url(monkeypatch, public_base, client, expected):
    monkeypatch.setattr(Config, 'PUBLIC_GEO_BASE_URL', public_base)
    assert Config.get_external_geo_url(client) == expected

def test_source_presets_shape():
    assert {'geogaga', 'vahellame', 'hydraponique'} <= set(Config.SOURCE_PRESETS)
    for key, preset in Config.SOURCE_PRESETS.items():
        for field in ('name', 'description', 'routing_repo', 'geoip_url', 'geosite_url', 'rules_format'):
            assert preset.get(field), f'{key}: preset is missing {field}'
        assert preset['routing_repo'].startswith('https://')
        assert preset['geoip_url'].endswith('.dat')
        assert preset['geosite_url'].endswith('.dat')

def test_enabled_clients_parsing(config_with_env):
    cfg = config_with_env(ENABLED_CLIENTS=' happ , ,incy ')
    assert cfg.ENABLED_CLIENTS == ['HAPP', 'INCY']
    cfg = config_with_env(ENABLED_CLIENTS='')
    assert cfg.ENABLED_CLIENTS == []

def test_routing_rules_parsing(config_with_env):
    cfg = config_with_env(ROUTING_RULES='jsonsub.json, WHITELIST')
    assert cfg.ROUTING_RULES == ['JSONSUB', 'WHITELIST']
    cfg = config_with_env(ROUTING_RULES='ALL')
    assert cfg.ROUTING_RULES == []
    cfg = config_with_env(ROUTING_RULES='')
    assert cfg.ROUTING_RULES == []

def test_domain_normalization(config_with_env):
    cfg = config_with_env(DOMAIN='https://Geo.Example.com/')
    assert cfg.DOMAIN == 'Geo.Example.com'
    cfg = config_with_env(DOMAIN='geo2.example.com')
    assert cfg.DOMAIN == 'geo2.example.com'

def test_bool_and_schedule_defaults(config_with_env):
    cfg = config_with_env()
    assert cfg.SERVE_FORMATS == 'CLIENT_OPTIMIZED'
    assert cfg.SERVE_GEOIP is True
    assert cfg.SERVE_GEOSITE is True
    assert cfg.SCHEDULE == '0 10 * * *'
    assert cfg.SYNC_ON_START is True
    cfg = config_with_env(SYNC_ON_START='no', SERVE_GEOIP='false', SERVE_GEOSITE='0', SERVE_FORMATS=' json ')
    assert cfg.SYNC_ON_START is False
    assert cfg.SERVE_GEOIP is False
    assert cfg.SERVE_GEOSITE is False
    assert cfg.SERVE_FORMATS == 'JSON'

def test_public_geo_base_url_autoscheme(config_with_env):
    cfg = config_with_env(PUBLIC_GEO_BASE_URL='geo-node.example.com/tok/')
    assert cfg.PUBLIC_GEO_BASE_URL == 'https://geo-node.example.com/tok'
    cfg = config_with_env(PUBLIC_GEO_BASE_URL='http://node.example/tok')
    assert cfg.PUBLIC_GEO_BASE_URL == 'http://node.example/tok'
    cfg = config_with_env()
    assert cfg.PUBLIC_GEO_BASE_URL == ''