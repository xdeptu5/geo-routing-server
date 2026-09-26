"""Тесты для app/cli.py: CLI интерфейс, команды status, sync, proxy, squads, menu."""

import json
from unittest.mock import patch

import pytest

from app.cli import (
    cmd_menu,
    cmd_proxy,
    cmd_squads,
    cmd_squads_add,
    cmd_squads_remove,
    cmd_status,
    main,
)
from app.config import Config
from app.squads import SquadManager


@pytest.fixture
def temp_squads(tmp_path, monkeypatch):
    """Изолирует файл squads.json для тестов CLI."""
    squads_file = tmp_path / "squads.json"
    monkeypatch.setenv("SQUADS_FILE", str(squads_file))
    return squads_file


@pytest.fixture
def mock_storage(tmp_path, monkeypatch):
    storage_dir = tmp_path / "www"
    storage_dir.mkdir()
    monkeypatch.setattr(Config, "STORAGE_DIR", storage_dir)
    return storage_dir


# ------------------------------------------------------------------------------
# 1. proxy
# ------------------------------------------------------------------------------

def test_cli_proxy_output(monkeypatch, capsys):
    monkeypatch.setattr(Config, "DOMAIN", "mygeo.test")
    monkeypatch.setenv("HTTP_PORT", "9090")
    monkeypatch.setenv("ROUTING_TOKEN", "mysecret123")
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "geogaga")

    ret = cmd_proxy()
    assert ret == 0
    out = capsys.readouterr().out
    assert "mygeo.test" in out
    assert "9090" in out
    assert "mysecret123" in out
    assert "location /mysecret123/ {" in out
    assert "handle /mysecret123/* {" in out
    assert "bittorrent" in out


def test_cli_proxy_without_token(monkeypatch, capsys):
    monkeypatch.setattr(Config, "DOMAIN", "mygeo.test")
    monkeypatch.setenv("HTTP_PORT", "8080")
    monkeypatch.delenv("ROUTING_TOKEN", raising=False)
    monkeypatch.setattr(Config, "ROUTING_SOURCE_PRESET", "vahellame")

    ret = cmd_proxy()
    assert ret == 0
    out = capsys.readouterr().out
    assert "mygeo.test" in out
    assert "location ~ ^/[A-Za-z0-9_-]{16,64}/(HAPP|INCY)/ {" in out
    assert "bittorrent" not in out


# ------------------------------------------------------------------------------
# 2. status
# ------------------------------------------------------------------------------

def test_cli_status_reads_summary_file(tmp_path, monkeypatch, capsys):
    summary_file = tmp_path / ".sync-summary.txt"
    summary_file.write_text("CACHED SYNC SUMMARY", encoding="utf-8")
    monkeypatch.setattr(Config, "STORAGE_DIR", tmp_path)
    monkeypatch.setenv("ROUTING_TOKEN", "tok12345")

    ret = cmd_status()
    assert ret == 0
    out = capsys.readouterr().out
    assert "CACHED SYNC SUMMARY" in out


def test_cli_status_fallback_generates_banner(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(Config, "STORAGE_DIR", tmp_path)
    monkeypatch.setenv("ROUTING_TOKEN", "tok12345")
    monkeypatch.setattr(Config, "DOMAIN", "fallback.test")

    ret = cmd_status()
    assert ret == 0
    out = capsys.readouterr().out
    assert "Geo Routing Server Ready!" in out
    assert "fallback.test/tok12345" in out


def test_cli_status_json(capsys, temp_squads):
    ret = main(["status", "--json"])
    assert ret == 0
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert "status" in data
    assert "base_url" in data
    assert "links" in data
    assert "squads" in data
    assert "remnawave" in data


def test_cli_status_reads_sync_status_file(capsys, temp_squads, mock_storage, monkeypatch):
    token = "test_token_123"
    monkeypatch.setenv("ROUTING_TOKEN", token)
    token_dir = mock_storage / token
    token_dir.mkdir(parents=True)
    status_file = token_dir / ".sync-status.json"
    status_file.write_text(
        json.dumps({
            "state": "success",
            "recorded_at": "2026-09-26T12:00:00Z",
            "failed_processors": 0,
            "remnawave_ok": True,
        }),
        encoding="utf-8",
    )

    ret = main(["status", "--json"])
    assert ret == 0
    captured = capsys.readouterr()
    data = json.loads(captured.out)
    assert data["status"] == "success"
    assert data["last_sync"] == "2026-09-26T12:00:00Z"
    assert data["failed_processors"] == 0


# ------------------------------------------------------------------------------
# 3. sync
# ------------------------------------------------------------------------------

def test_cli_sync():
    with patch("app.main.main") as mock_main:
        ret = main(["sync"])
        assert ret == 0
        mock_main.assert_called_once()


# ------------------------------------------------------------------------------
# 4. squads
# ------------------------------------------------------------------------------

def test_cli_squads_unconfigured(monkeypatch, capsys):
    monkeypatch.delenv("REMNAWAVE_BASE_URL", raising=False)
    monkeypatch.delenv("REMNAWAVE_TOKEN", raising=False)

    ret = cmd_squads()
    assert ret == 1
    out = capsys.readouterr().out
    assert "not configured" in out


def test_cli_squads_list_empty(capsys, temp_squads):
    ret = main(["squads", "list"])
    assert ret == 0
    out = capsys.readouterr().out
    assert "Нет привязанных сквадов" in out


def test_cli_squads_add_and_list(capsys, temp_squads):
    ret = main([
        "squads",
        "add",
        "--uuid",
        "1111-2222-3333",
        "--rule",
        "WHITELIST",
        "--name",
        "Alpha Squad",
    ])
    assert ret == 0
    out = capsys.readouterr().out
    assert "Сквад успешно сохранен" in out
    assert "WHITELIST.JSON" in out

    ret = main(["squads", "list"])
    assert ret == 0
    list_out = capsys.readouterr().out
    assert "Alpha Squad" in list_out
    assert "1111-2222-3333" in list_out


def test_cli_squads_add_invalid_uuid(capsys, temp_squads):
    ret = main([
        "squads",
        "add",
        "--uuid",
        "invalid spaces!",
        "--rule",
        "WHITELIST",
    ])
    assert ret == 1
    err = capsys.readouterr().err
    assert "Ошибка: Недопустимый формат UUID" in err


def test_cli_squads_remove(capsys, temp_squads):
    main(["squads", "add", "--uuid", "uuid-to-remove", "--rule", "JSONSUB.JSON"])
    capsys.readouterr()

    ret = main(["squads", "remove", "uuid-to-remove"])
    assert ret == 0
    out = capsys.readouterr().out
    assert "успешно удален" in out

    ret = main(["squads", "remove", "uuid-to-remove"])
    assert ret == 1


def test_cli_squads_migrate(capsys, temp_squads, tmp_path):
    env_content = """
SQUAD_1_UUID=migrated-uuid-1
SQUAD_1_RULE=HAPP.JSON
SQUAD_1_NAME="Migrated Squad"
"""
    env_file = tmp_path / ".env"
    env_file.write_text(env_content, encoding="utf-8")

    ret = main(["squads", "migrate", "--env-path", str(env_file)])
    assert ret == 0
    out = capsys.readouterr().out
    assert "Успешно мигрировано сквадов: 1" in out
    assert "migrated-uuid-1" in out

    mgr = SquadManager(file_path=temp_squads)
    sq = mgr.get_squad("migrated-uuid-1")
    assert sq is not None
    assert sq["name"] == "Migrated Squad"


def test_cli_squads_sync_success(capsys, temp_squads):
    with patch.object(SquadManager, "sync_squads_to_remnawave", return_value=True):
        ret = main(["squads", "sync"])
        assert ret == 0
        out = capsys.readouterr().out
        assert "Синхронизация сквадов успешно завершена" in out


def test_cli_squads_sync_failure(capsys, temp_squads):
    with patch.object(SquadManager, "sync_squads_to_remnawave", return_value=False):
        ret = main(["squads", "sync"])
        assert ret == 1
        err = capsys.readouterr().err
        assert "Ошибка синхронизации сквадов с Remnawave API" in err


# ------------------------------------------------------------------------------
# 5. Интерактивные функции и menu
# ------------------------------------------------------------------------------

def test_cli_interactive_squads_add(capsys, temp_squads, monkeypatch):
    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    inputs = iter(["interactive-uuid-1", "custom_rule", "Interactive Name"])
    monkeypatch.setattr("builtins.input", lambda prompt="": next(inputs))

    mgr = SquadManager(file_path=temp_squads)
    ret = cmd_squads_add(manager=mgr)
    assert ret == 0

    sq = mgr.get_squad("interactive-uuid-1")
    assert sq is not None
    assert sq["rule"] == "CUSTOM_RULE.JSON"
    assert sq["name"] == "Interactive Name"


def test_cli_interactive_squads_remove(capsys, temp_squads, monkeypatch):
    mgr = SquadManager(file_path=temp_squads)
    mgr.add_squad("remove-me-uuid", "JSONSUB.JSON", name="To Remove")

    monkeypatch.setattr("sys.stdin.isatty", lambda: True)
    monkeypatch.setattr("builtins.input", lambda prompt="": "1")

    ret = cmd_squads_remove(manager=mgr)
    assert ret == 0
    assert mgr.get_squad("remove-me-uuid") is None


def test_cli_menu_exit(capsys, temp_squads, monkeypatch):
    inputs = iter(["0"])
    monkeypatch.setattr("builtins.input", lambda prompt="": next(inputs))

    ret = cmd_menu()
    assert ret == 0
    out = capsys.readouterr().out
    assert "Geo Routing Server — Интерактивное меню" in out
    assert "До свидания!" in out


def test_cli_menu_runs_status_then_exit(capsys, temp_squads, monkeypatch):
    inputs = iter(["1", "", "0"])
    monkeypatch.setattr("builtins.input", lambda prompt="": next(inputs))

    ret = cmd_menu()
    assert ret == 0
    out = capsys.readouterr().out
    assert "Geo Routing Server Ready!" in out
    assert "До свидания!" in out


def test_cli_main_dispatch():
    with patch("app.cli.cmd_proxy", return_value=0) as mock_proxy:
        ret = main(["proxy"])
        assert ret == 0
        mock_proxy.assert_called_once()

    ret_help = main([])
    assert ret_help == 0
