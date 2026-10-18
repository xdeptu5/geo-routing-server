"""Тесты подкоманд CLI, которые вызывает install.sh: version, setup, config."""

import builtins

from app import CLI_API, __version__
from app.cli import main
from app.envfile import EnvFile
from app.hostconfig import APPLY


def test_version_reports_cli_api(capsys):
    assert main(["version"]) == 0
    out = capsys.readouterr().out.strip()
    assert out == f"geo-routing-server {__version__} cli-api {CLI_API}"
    # install.sh разбирает именно этот формат
    assert f"cli-api {CLI_API}" in out


def test_config_set_get_roundtrip(tmp_path, capsys):
    (tmp_path / ".env").write_text("DOMAIN=old.example.com\n", encoding="utf-8")
    assert main(["config", "set", "DOMAIN", "new.example.com", "--host-dir", str(tmp_path)]) == APPLY
    capsys.readouterr()
    assert main(["config", "get", "DOMAIN", "--host-dir", str(tmp_path)]) == 0
    assert capsys.readouterr().out.strip() == "new.example.com"


def test_config_set_requires_key_and_value(tmp_path):
    (tmp_path / ".env").write_text("DOMAIN=x\n", encoding="utf-8")
    assert main(["config", "set", "DOMAIN", "--host-dir", str(tmp_path)]) == 2
    assert main(["config", "get", "--host-dir", str(tmp_path)]) == 2


def test_setup_subcommand_writes_files(tmp_path, monkeypatch):
    answers = iter(["", "", "geo.test", "", "", ""])
    monkeypatch.setattr(builtins, "input", lambda prompt="": next(answers))
    monkeypatch.delenv("GRS_HOST_NETWORKS", raising=False)
    assert main(["setup", "--host-dir", str(tmp_path), "--image", "img:1"]) == 0
    assert EnvFile(tmp_path / ".env").get("ENABLED_CLIENTS") == "HAPP,INCY"
    assert (tmp_path / "compose.yaml").is_file()


def test_config_section_back(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("DOMAIN=x\n", encoding="utf-8")
    monkeypatch.setattr(builtins, "input", lambda prompt="": "0")
    assert main(["config", "schedule", "--host-dir", str(tmp_path)]) == 0
