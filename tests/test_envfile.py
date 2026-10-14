"""Тесты app/envfile.py: правка .env без потери комментариев и с корректными кавычками."""

import os
import stat

import pytest

from app.envfile import EnvFile


@pytest.fixture
def env_path(tmp_path):
    path = tmp_path / ".env"
    path.write_text(
        "# комментарий\n"
        "DOMAIN=geo.example.com\n"
        'ROUTING_TOKEN="quoted123"\n'
        "SCHEDULE=0 10 * * * # ежедневно\n"
        "DUP=first\n"
        "DUP=second\n"
        "SINGLE='a $b'\n",
        encoding="utf-8",
    )
    return path


def test_get_handles_quotes_comments_and_duplicates(env_path):
    env = EnvFile(env_path)
    assert env.get("DOMAIN") == "geo.example.com"
    assert env.get("ROUTING_TOKEN") == "quoted123"
    assert env.get("SCHEDULE") == "0 10 * * *"
    assert env.get("DUP") == "first"
    assert env.get("SINGLE") == "a $b"
    assert env.get("MISSING", "def") == "def"


def test_set_replaces_first_and_drops_duplicates(env_path):
    env = EnvFile(env_path)
    env.set("DUP", "new")
    env.save()
    text = env_path.read_text(encoding="utf-8")
    assert text.count("DUP=") == 1 and "DUP=new" in text
    assert text.startswith("# комментарий\n")


def test_set_appends_new_key_and_tracks_changes(env_path):
    env = EnvFile(env_path)
    env.set("DOMAIN", "geo.example.com")
    assert env.changed is False
    env.set("NEW_KEY", "v")
    assert env.changed is True


@pytest.mark.parametrize("value,line", [
    ("plain", "K=plain"),
    ("has $dollar", "K='has $dollar'"),
    ("a #b", "K='a #b'"),
    (" spaced", "K=' spaced'"),
    ("it's $x", 'K="it\'s $$x"'),
])
def test_values_are_quoted_only_when_needed(tmp_path, value, line):
    env = EnvFile(tmp_path / ".env")
    env.set("K", value)
    env.save()
    assert (tmp_path / ".env").read_text(encoding="utf-8").strip() == line
    assert EnvFile(tmp_path / ".env").get("K") == value


def test_multiline_value_is_truncated(tmp_path):
    env = EnvFile(tmp_path / ".env")
    env.set("K", "one\ntwo")
    assert env.get("K") == "one"


def test_delete_and_save_permissions(env_path):
    env = EnvFile(env_path)
    env.delete("DUP")
    env.save()
    assert "DUP" not in env_path.read_text(encoding="utf-8")
    if os.name == "posix":
        assert stat.S_IMODE(env_path.stat().st_mode) == 0o600


def test_backup_and_bom(tmp_path):
    path = tmp_path / ".env"
    path.write_bytes("﻿DOMAIN=x\n".encode("utf-8"))
    env = EnvFile(path)
    assert env.get("DOMAIN") == "x"
    backup = env.backup()
    assert backup.name.startswith(".env.bak.") and backup.read_bytes() == path.read_bytes()
