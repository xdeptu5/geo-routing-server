"""Тесты app/publisher.py: атомарная публикация и обнаружение изменений."""

import stat
import sys

import pytest

from app.publisher import Publisher


@pytest.fixture(autouse=True)
def _reset_session():
    Publisher.reset_session()
    yield
    Publisher.reset_session()


@pytest.fixture
def dest(tmp_path):
    path = tmp_path / "www"
    path.mkdir()
    return path


def _only_files(directory):
    return sorted(p.name for p in directory.iterdir())


def test_publish_creates_file_with_content_and_mode(dest):
    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 1}') is True
    target = dest / "HAPP.JSON"
    assert target.read_text(encoding="utf-8") == '{"a": 1}'
    if sys.platform != "win32":
        assert stat.S_IMODE(target.stat().st_mode) == 0o644
    # во время публикации не остаётся временных файлов
    assert _only_files(dest) == ["HAPP.JSON"]


def test_publish_accepts_bytes(dest):
    assert Publisher.publish_file(dest, "geoip.dat", b"\x00\x01\x02") is True
    assert (dest / "geoip.dat").read_bytes() == b"\x00\x01\x02"


def test_publish_registers_file_and_flags_change(dest):
    assert Publisher.publish_file(dest, "HAPP.JSON", "{}") is True
    info = Publisher.published_registry[f"{dest.name}/HAPP.JSON"]
    assert info.filename == "HAPP.JSON"
    assert info.size_bytes == 2
    assert info.is_updated is True
    assert Publisher.any_file_changed is True


def test_publish_identical_content_is_unchanged(dest):
    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 1}') is True
    Publisher.reset_session()

    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 1}') is True
    info = Publisher.published_registry[f"{dest.name}/HAPP.JSON"]
    assert info.is_updated is False
    assert Publisher.any_file_changed is False
    assert _only_files(dest) == ["HAPP.JSON"]


def test_publish_identical_content_keeps_mtime(dest):
    import os

    target = dest / "HAPP.JSON"
    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 1}') is True
    os.utime(target, (1_000_000_000, 1_000_000_000))

    Publisher.reset_session()
    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 1}') is True
    assert int(target.stat().st_mtime) == 1_000_000_000


def test_publish_detects_changed_content_same_size(dest):
    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 1}') is True
    Publisher.reset_session()

    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": 2}') is True
    assert Publisher.published_registry[f"{dest.name}/HAPP.JSON"].is_updated is True
    assert Publisher.any_file_changed is True
    assert (dest / "HAPP.JSON").read_text(encoding="utf-8") == '{"a": 2}'
    assert _only_files(dest) == ["HAPP.JSON"]


def test_publish_detects_changed_content_other_size(dest):
    assert Publisher.publish_file(dest, "HAPP.JSON", "{}") is True
    Publisher.reset_session()

    assert Publisher.publish_file(dest, "HAPP.JSON", '{"a": [1, 2, 3]}') is True
    assert Publisher.published_registry[f"{dest.name}/HAPP.JSON"].is_updated is True
    assert Publisher.any_file_changed is True


def test_publish_rejects_empty_content(dest):
    assert Publisher.publish_file(dest, "HAPP.JSON", "") is False
    assert Publisher.publish_file(dest, "EMPTY.BIN", b"") is False
    assert _only_files(dest) == []
    assert Publisher.published_registry == {}


def test_publish_rejects_path_traversal(dest, tmp_path):
    assert Publisher.publish_file(dest, "../evil.txt", "x") is False
    assert not (tmp_path / "evil.txt").exists()
    assert Publisher.publish_file(dest, "/etc/hosts", "x") is False
    assert Publisher.publish_file(dest, "sub/../..//escape.json", "x") is False
    assert _only_files(dest) == []


def test_publish_creates_missing_directory(tmp_path):
    dest = tmp_path / "nested" / "www"
    assert Publisher.publish_file(dest, "HAPP.JSON", "{}") is True
    assert (dest / "HAPP.JSON").is_file()
    if sys.platform != "win32":
        assert stat.S_IMODE(dest.stat().st_mode) == 0o755
