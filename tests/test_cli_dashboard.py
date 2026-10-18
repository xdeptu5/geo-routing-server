"""Тесты служебных команд для install.sh: шапка меню, ожидание синхронизации, выбор сквадов."""

import builtins
import json
import os
import time
from unittest.mock import patch

import pytest

from app.cli import cmd_squads_pick, cmd_wait_sync, dashboard_lines
from app.config import Config
from app.squads import SquadManager

UUID_A = "11111111-1111-4111-8111-111111111111"
UUID_B = "22222222-2222-4222-8222-222222222222"


def info(**over):
    base = {
        "enabled_clients": ["HAPP", "INCY"],
        "domain": "geo.test",
        "status": "success",
        "last_sync": "2026-10-18T10:00:00+00:00",
        "remnawave_ok": True,
        "remnawave": {"configured": False, "squads_count": 0},
    }
    base.update(over)
    return base


def hint(lines):
    return next((line for line in lines if line.startswith("💡")), "")


def test_dashboard_serving_mode_ok():
    lines = dashboard_lines(info(), "0 10 * * *")
    assert "geo.test" in lines[0]
    assert "✅ 18.10 10:00 UTC" in lines[1]
    assert "не подключена" in lines[2]
    assert "пункт 1" in hint(lines)


@pytest.mark.parametrize("over, expected", [
    ({"domain": "geo.example.com"}, "DOMAIN"),
    ({"enabled_clients": ["HAPP_DEEPLINK"], "domain": ""}, "нужна панель"),
    ({"remnawave": {"configured": True, "squads_count": 0}}, "привяжите сквады"),
    ({"remnawave": {"configured": True, "squads_count": 2}, "remnawave_ok": False}, "не отвечает"),
    ({"status": "failed"}, "логах"),
])
def test_dashboard_next_step_hint(over, expected):
    assert expected in hint(dashboard_lines(info(**over), "0 10 * * *"))


def test_dashboard_rules_only_mode_hides_domain():
    lines = dashboard_lines(info(enabled_clients=["HAPP_DEEPLINK"], domain="geo.test",
                                 remnawave={"configured": True, "squads_count": 1}), "0 10 * * *")
    assert "geo.test" not in lines[0]
    assert "сквадов: 1" in lines[2]
    assert hint(lines) == ""


@pytest.fixture
def status_dir(tmp_path, monkeypatch):
    monkeypatch.setattr(Config, "STORAGE_DIR", tmp_path)
    monkeypatch.setattr("app.cli.get_safe_token", lambda: "tok")
    (tmp_path / "tok").mkdir()
    return tmp_path / "tok"


def write_state(folder, state, mtime=None):
    path = folder / ".sync-status.json"
    path.write_text(json.dumps({"state": state}), encoding="utf-8")
    if mtime is not None:
        os.utime(path, (mtime, mtime))


def test_wait_sync_reports_result(status_dir):
    write_state(status_dir, "success")
    assert cmd_wait_sync(since=time.time() - 60, timeout=5) == 0
    write_state(status_dir, "partial")
    assert cmd_wait_sync(since=time.time() - 60, timeout=5) == 1


def test_wait_sync_ignores_old_result(status_dir, monkeypatch):
    write_state(status_dir, "success", mtime=time.time() - 3600)
    monkeypatch.setattr("time.sleep", lambda _s: None)
    assert cmd_wait_sync(since=time.time() - 60, timeout=0) == 2


@pytest.fixture
def squads(tmp_path, monkeypatch):
    monkeypatch.setenv("SQUADS_FILE", str(tmp_path / "squads.json"))
    monkeypatch.setattr("app.cli.RemnawaveSync.is_configured", classmethod(lambda cls: True))
    return SquadManager()


def feed(monkeypatch, *lines):
    queue = list(lines)
    monkeypatch.setattr(builtins, "input", lambda prompt="": queue.pop(0))


def test_pick_binds_selected_squads_and_syncs(squads, monkeypatch):
    remote = [{"uuid": UUID_A, "name": "Main"}, {"uuid": UUID_B, "name": "VIP"}]
    feed(monkeypatch, "2")
    with patch("app.cli.fetch_external_squads", return_value=remote), \
            patch.object(SquadManager, "sync_squads_to_remnawave", return_value=True) as sync:
        assert cmd_squads_pick(squads) == 0
    bound = squads.list_squads()
    assert [s["uuid"] for s in bound] == [UUID_B]
    sync.assert_called_once()


def test_pick_skip_and_bad_number_change_nothing(squads, monkeypatch, capsys):
    remote = [{"uuid": UUID_A, "name": "Main"}]
    # неверный номер переспрашивается, затем Enter — пропустить
    for answers in ([""], ["5", ""]):
        feed(monkeypatch, *answers)
        with patch("app.cli.fetch_external_squads", return_value=remote):
            assert cmd_squads_pick(squads) == 2
    assert "Нет сквада с номером 5" in capsys.readouterr().out
    assert squads.list_squads() == []


def test_pick_rule_first_then_squads_in_rounds(squads, monkeypatch, capsys):
    """Сначала правило, потом его сквады; второй заход — другое правило другим сквадам."""
    remote = [{"uuid": UUID_A, "name": "Main"}, {"uuid": UUID_B, "name": "VIP"}]
    monkeypatch.setattr(Config, "get_display_rules", classmethod(lambda cls, **kw: ["HAPP.JSON", "WHITELIST.JSON"]))
    # правило 1 → сквад 1, ещё? y → правило 2 → сквад 2, ещё? Enter
    feed(monkeypatch, "1", "1", "y", "2", "2", "")
    with patch("app.cli.fetch_external_squads", return_value=remote), \
            patch.object(SquadManager, "sync_squads_to_remnawave", return_value=True) as sync:
        assert cmd_squads_pick(squads) == 0
    rules = {s["uuid"]: s["rule"] for s in squads.list_squads()}
    assert rules == {UUID_A: "HAPP.JSON", UUID_B: "WHITELIST.JSON"}
    sync.assert_called_once()
    out = capsys.readouterr().out
    assert out.count("Какое правило выдать?") == 2


def test_pick_ctrl_c_after_first_round_keeps_and_applies(squads, monkeypatch):
    remote = [{"uuid": UUID_A, "name": "Main"}]
    queue = ["1", "1"]  # правило 1, сквад 1, затем Ctrl+C на вопросе «ещё?»

    def fake_input(prompt=""):
        if not queue:
            raise KeyboardInterrupt
        return queue.pop(0)

    monkeypatch.setattr(builtins, "input", fake_input)
    monkeypatch.setattr(Config, "get_display_rules", classmethod(lambda cls, **kw: ["HAPP.JSON", "WHITELIST.JSON"]))
    with patch("app.cli.fetch_external_squads", return_value=remote), \
            patch.object(SquadManager, "sync_squads_to_remnawave", return_value=True) as sync:
        assert cmd_squads_pick(squads) == 0
    assert [s["uuid"] for s in squads.list_squads()] == [UUID_A]
    sync.assert_called_once()


def test_pick_without_api_connection(squads, capsys):
    with patch("app.cli.fetch_external_squads", return_value=None):
        assert cmd_squads_pick(squads) == 1
    assert "Нет связи" in capsys.readouterr().out


def test_rules_only_mode_reads_status_from_local_dir(monkeypatch):
    """В режиме «только сквады» токена нет, синхронизация пишет в www/local."""
    from app.cli import get_safe_token

    monkeypatch.delenv("ROUTING_TOKEN", raising=False)
    monkeypatch.setattr(Config, "BASE_DIR", Config.STORAGE_DIR / "nonexistent")
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP_DEEPLINK"])
    assert get_safe_token() == "local"
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    assert get_safe_token() != "local"
