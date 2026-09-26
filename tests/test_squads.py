"""Тесты для app/squads.py: управление сквадами Remnawave, squads.json, миграция."""

import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from app.squads import SquadManager, get_default_squads_path


@pytest.fixture
def squads_file(tmp_path):
    return tmp_path / "squads.json"


@pytest.fixture
def manager(squads_file):
    return SquadManager(file_path=squads_file)


# ------------------------------------------------------------------------------
# 1. Инициализация и пути
# ------------------------------------------------------------------------------

def test_init_custom_path(tmp_path):
    custom = tmp_path / "custom_squads.json"
    mgr = SquadManager(file_path=custom)
    assert mgr.file_path == custom


def test_init_default_path_with_env(monkeypatch, tmp_path):
    env_file = tmp_path / "env_squads.json"
    monkeypatch.setenv("SQUADS_FILE", str(env_file))
    assert get_default_squads_path() == env_file
    mgr = SquadManager()
    assert mgr.file_path == env_file


def test_init_default_path_fallback(monkeypatch):
    monkeypatch.delenv("SQUADS_FILE", raising=False)
    default_p = get_default_squads_path()
    assert isinstance(default_p, Path)


# ------------------------------------------------------------------------------
# 2. list_squads и get_squad
# ------------------------------------------------------------------------------

def test_list_squads_empty_when_file_not_exists(manager):
    assert manager.list_squads() == []


def test_list_squads_empty_when_file_is_empty(manager, squads_file):
    squads_file.write_text("", encoding="utf-8")
    assert manager.list_squads() == []


def test_list_squads_corrupted_json(manager, squads_file):
    squads_file.write_text("{not a json", encoding="utf-8")
    assert manager.list_squads() == []


def test_list_squads_non_list_json(manager, squads_file):
    squads_file.write_text('{"uuid": "123"}', encoding="utf-8")
    assert manager.list_squads() == []


def test_get_squad_not_found(manager):
    assert manager.get_squad("non-existent-uuid") is None


def test_get_squad_case_insensitive(manager):
    manager.add_squad("ABCDEF-1234", "WHITELIST.JSON", name="Alpha")
    found = manager.get_squad("abcdef-1234")
    assert found is not None
    assert found["uuid"] == "abcdef-1234"
    assert found["name"] == "Alpha"
    assert found["rule"] == "WHITELIST.JSON"


# ------------------------------------------------------------------------------
# 3. add_squad
# ------------------------------------------------------------------------------

def test_add_squad_creates_file_and_normalizes(manager, squads_file):
    sq = manager.add_squad("ABCDEF-1234", "whitelist", name=" Alpha Squad ")
    assert sq["uuid"] == "abcdef-1234"
    assert sq["rule"] == "WHITELIST.JSON"
    assert sq["name"] == "Alpha Squad"

    assert squads_file.is_file()
    data = json.loads(squads_file.read_text(encoding="utf-8"))
    assert data == [
        {
            "uuid": "abcdef-1234",
            "rule": "WHITELIST.JSON",
            "name": "Alpha Squad",
        }
    ]


def test_add_squad_without_name(manager, squads_file):
    sq = manager.add_squad("uuid-123", "JSONSUB.JSON")
    assert sq == {"uuid": "uuid-123", "rule": "JSONSUB.JSON"}
    data = json.loads(squads_file.read_text(encoding="utf-8"))
    assert data == [{"uuid": "uuid-123", "rule": "JSONSUB.JSON"}]


def test_add_squad_updates_existing(manager):
    manager.add_squad("uuid-1", "RULE1.JSON", name="First")
    # Обновление правила, сохраняя имя
    manager.add_squad("uuid-1", "RULE2.JSON")
    sq = manager.get_squad("uuid-1")
    assert sq["rule"] == "RULE2.JSON"
    assert sq["name"] == "First"

    # Обновление имени
    manager.add_squad("uuid-1", "RULE2.JSON", name="Updated First")
    sq2 = manager.get_squad("uuid-1")
    assert sq2["name"] == "Updated First"


def test_add_squad_invalid_uuid(manager):
    with pytest.raises(ValueError, match="Недопустимый формат UUID"):
        manager.add_squad("invalid uuid with spaces!", "RULE.JSON")

    with pytest.raises(ValueError, match="Недопустимый формат UUID"):
        manager.add_squad("", "RULE.JSON")


def test_add_squad_invalid_rule(manager):
    with pytest.raises(ValueError, match="Имя правила не может быть пустым"):
        manager.add_squad("valid-uuid", "")


# ------------------------------------------------------------------------------
# 4. remove_squad
# ------------------------------------------------------------------------------

def test_remove_squad_success(manager):
    manager.add_squad("uuid-1", "RULE1.JSON")
    manager.add_squad("uuid-2", "RULE2.JSON")
    assert len(manager.list_squads()) == 2

    assert manager.remove_squad("uuid-1") is True
    assert len(manager.list_squads()) == 1
    assert manager.get_squad("uuid-1") is None
    assert manager.get_squad("uuid-2") is not None


def test_remove_squad_non_existent(manager):
    manager.add_squad("uuid-1", "RULE1.JSON")
    assert manager.remove_squad("uuid-missing") is False
    assert len(manager.list_squads()) == 1


# ------------------------------------------------------------------------------
# 5. migrate_from_env
# ------------------------------------------------------------------------------

def test_migrate_from_env_success(manager, tmp_path):
    env_content = """
# Тестовый .env файл
ROUTING_TOKEN=secret123
SQUAD_1_UUID=11111111-aaaa
SQUAD_1_RULE=whitelist.json
SQUAD_1_NAME="Primary Squad"

REMNAWAVE_SQUAD_2_UUID=22222222-bbbb
REMNAWAVE_SQUAD_2_RULE=jsonsub
REMNAWAVE_SQUAD_2_NAME='Secondary Squad'

# Старый формат SQUAD_3_URL
SQUAD_3_UUID=33333333-cccc
SQUAD_3_URL=https://example.com/custom.deeplink

# Невалидный UUID должен быть пропущен
SQUAD_4_UUID=bad uuid spaces
SQUAD_4_RULE=ignore.json
"""
    env_file = tmp_path / ".env.test"
    env_file.write_text(env_content, encoding="utf-8")

    migrated = manager.migrate_from_env(env_file)
    assert len(migrated) == 3

    assert manager.get_squad("11111111-aaaa") == {
        "uuid": "11111111-aaaa",
        "rule": "WHITELIST.JSON",
        "name": "Primary Squad",
    }
    assert manager.get_squad("22222222-bbbb") == {
        "uuid": "22222222-bbbb",
        "rule": "JSONSUB.JSON",
        "name": "Secondary Squad",
    }
    assert manager.get_squad("33333333-cccc") == {
        "uuid": "33333333-cccc",
        "rule": "CUSTOM.JSON",
    }


def test_migrate_from_env_missing_file(manager, tmp_path):
    missing_env = tmp_path / "non_existent.env"
    migrated = manager.migrate_from_env(missing_env)
    assert migrated == []


# ------------------------------------------------------------------------------
# 6. sync_squads_to_remnawave
# ------------------------------------------------------------------------------

def test_sync_squads_empty_returns_true(manager):
    assert manager.sync_squads_to_remnawave() is True


def test_sync_squads_with_mock_client(manager, tmp_path):
    manager.add_squad("uuid-1", "WHITELIST.JSON", name="Squad 1")
    mock_client = MagicMock()
    mock_client.sync_squads.return_value = True

    happ_dir = tmp_path / "HAPP"
    happ_dir.mkdir()

    result = manager.sync_squads_to_remnawave(remnawave_client=mock_client, www_dir=tmp_path)
    assert result is True
    mock_client.sync_squads.assert_called_once()
    args, kwargs = mock_client.sync_squads.call_args
    assert args[0] == [{"uuid": "uuid-1", "rule": "WHITELIST.JSON", "name": "Squad 1"}]
    assert args[1] == happ_dir


def test_sync_squads_delegates_to_remnawave_sync(manager, tmp_path):
    manager.add_squad("uuid-1", "WHITELIST.JSON")
    happ_dir = tmp_path / "HAPP"
    happ_dir.mkdir()

    with patch("app.remnawave.RemnawaveSync.sync_squads", return_value=True) as mock_sync:
        res = manager.sync_squads_to_remnawave(www_dir=happ_dir)
        assert res is True
        mock_sync.assert_called_once()
