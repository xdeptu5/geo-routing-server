"""Тесты предупреждений о давности и ошибках синхронизации (geoserver status)."""

import json
from datetime import datetime, timedelta, timezone

import pytest

from app.cli import sync_warnings
from app.main import write_sync_status
from app.validators import schedule_interval_hours

NOW = datetime(2026, 10, 15, 12, 0, tzinfo=timezone.utc)


def iso(hours_ago: float) -> str:
    return (NOW - timedelta(hours=hours_ago)).isoformat(timespec="seconds")


@pytest.mark.parametrize("cron,hours", [
    ("0 10 * * *", 24), ("0 */6 * * *", 6), ("0 * * * *", 1), ("0 6,18 * * *", 12), ("bad", 24),
])
def test_schedule_interval_hours(cron, hours):
    assert schedule_interval_hours(cron) == hours


def test_fresh_success_has_no_warnings():
    status = {"state": "success", "recorded_at": iso(3), "last_success_at": iso(3)}
    assert sync_warnings(status, "0 10 * * *", NOW) == []


def test_no_status_file_has_no_warnings():
    assert sync_warnings({}, "0 10 * * *", NOW) == []


def test_stale_success_is_reported_relative_to_schedule():
    daily = {"state": "success", "recorded_at": iso(50), "last_success_at": iso(50)}
    assert any("2 дн. назад" in w for w in sync_warnings(daily, "0 10 * * *", NOW))
    hourly = {"state": "success", "recorded_at": iso(5), "last_success_at": iso(5)}
    assert sync_warnings(hourly, "0 10 * * *", NOW) == []
    assert any("5 ч. назад" in w for w in sync_warnings(hourly, "0 * * * *", NOW))


def test_failure_after_old_success():
    status = {
        "state": "failed", "recorded_at": iso(1), "last_success_at": iso(80),
        "errors": ["GitHub недоступен"],
    }
    warnings = sync_warnings(status, "0 10 * * *", NOW)
    assert any("с ошибкой: GitHub недоступен" in w for w in warnings)
    assert any("3 дн. назад" in w for w in warnings)


def test_never_succeeded():
    status = {"state": "failed", "recorded_at": iso(1), "errors": []}
    assert any("Ни одной успешной" in w for w in sync_warnings(status, "0 10 * * *", NOW))


def test_stuck_running():
    assert any("не завершилась" in w for w in sync_warnings(
        {"state": "running", "recorded_at": iso(5), "last_success_at": iso(6)}, "0 */6 * * *", NOW))
    assert sync_warnings({"state": "running", "recorded_at": iso(0.2), "last_success_at": iso(6)}, "0 */6 * * *", NOW) == []


def test_old_status_file_without_last_success_field():
    # .sync-status.json от версий до 1.7.0
    assert sync_warnings({"state": "success", "recorded_at": iso(2)}, "0 10 * * *", NOW) == []


def test_last_success_survives_failed_runs(tmp_path):
    token = "tok12345"
    (tmp_path / token).mkdir()
    status_file = tmp_path / token / ".sync-status.json"
    write_sync_status(tmp_path, token, "success", errors=[], rules=[], generated_files=[])
    first = json.loads(status_file.read_text(encoding="utf-8"))["last_success_at"]
    assert first
    write_sync_status(tmp_path, token, "running", errors=[], rules=[], generated_files=[])
    write_sync_status(tmp_path, token, "failed", errors=["x"], rules=[], generated_files=[])
    data = json.loads(status_file.read_text(encoding="utf-8"))
    assert data["state"] == "failed" and data["last_success_at"] == first
