"""Тесты app/processors/base.py: диплинки, безопасность имён, автоочистка."""

from pathlib import Path

import pytest

from app.processors.base import BaseProcessor


class _DummyProcessor(BaseProcessor):
    CLIENT_NAME = "HAPP"

    def process(self) -> bool:
        return True


@pytest.fixture
def processor(tmp_path):
    return _DummyProcessor(downloader=None, storage_dir=tmp_path, token="tok", domain="example.com")


# ------------------------------------------------------------------------------
# Диплинки: кодирование / декодирование / парсинг
# ------------------------------------------------------------------------------

def test_build_and_decode_deeplink_roundtrip():
    payload = {"Geoipurl": "https://geo.example.com/tok/geoip.dat", "Name": "тест"}
    deeplink = BaseProcessor.build_deeplink("HAPP", payload)
    assert deeplink.startswith("happ://routing/onadd/")
    assert deeplink.endswith("\n")
    assert BaseProcessor.decode_deeplink(deeplink, "HAPP") == payload


def test_build_deeplink_compact_json():
    deeplink = BaseProcessor.build_deeplink("INCY", {"a": 1, "b": 2})
    body = deeplink.split("://routing/onadd/", 1)[1].strip()
    import base64
    import json

    decoded = base64.b64decode(body).decode("utf-8")
    assert decoded == '{"a":1,"b":2}'  # без пробелов — компактный JSON
    assert json.loads(decoded) == {"a": 1, "b": 2}


def test_decode_deeplink_rejects_foreign_prefix():
    deeplink = BaseProcessor.build_deeplink("HAPP", {"a": 1})
    with pytest.raises(ValueError):
        BaseProcessor.decode_deeplink(deeplink, "INCY")


def test_parse_rule_payload_plain_json():
    raw = b'{"Outbounds": []}'
    assert BaseProcessor.parse_rule_payload(raw, "HAPP") == {"Outbounds": []}


def test_parse_rule_payload_from_deeplink():
    payload = {"Outbounds": ["vless"]}
    deeplink = BaseProcessor.build_deeplink("HAPP", payload)
    assert BaseProcessor.parse_rule_payload(deeplink.encode("utf-8"), "HAPP") == payload


def test_parse_rule_payload_rejects_garbage():
    with pytest.raises(ValueError):
        BaseProcessor.parse_rule_payload(b"<html>not a rule</html>", "HAPP")


# ------------------------------------------------------------------------------
# Имена файлов правил
# ------------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["HAPP.JSON", "whitelist.json", "a.json", "JSONSUB-2.json"])
def test_is_safe_config_filename_accepts(name):
    assert BaseProcessor.is_safe_config_filename(name) is True


@pytest.mark.parametrize(
    "name",
    [".hidden.json", "../evil.json", "sub/evil.json", "sub\\evil.json", "evil.json.bak", "no-extension", ""],
)
def test_is_safe_config_filename_rejects(name):
    assert BaseProcessor.is_safe_config_filename(name) is False


# ------------------------------------------------------------------------------
# _cleanup_obsolete_files
# ------------------------------------------------------------------------------

def _make_dir(base: Path, names):
    base.mkdir(parents=True, exist_ok=True)
    for name in names:
        (base / name).write_text("{}", encoding="utf-8")
    return base


def test_cleanup_removes_obsolete_and_keeps_current(processor, tmp_path):
    target = _make_dir(tmp_path / "HAPP", ["HAPP.JSON", "HAPP.DEEPLINK", "OLD.JSON", "readme.txt", "geoip.dat"])
    (target / "subdir").mkdir()
    (target / "subdir" / "nested.json").write_text("{}", encoding="utf-8")

    processor._cleanup_obsolete_files(target, {"HAPP.JSON", "HAPP.DEEPLINK"})

    assert sorted(p.name for p in target.iterdir()) == [
        "HAPP.DEEPLINK",
        "HAPP.JSON",
        "geoip.dat",
        "readme.txt",
        "subdir",
    ]
    # файлы внутри подкаталогов не трогаются
    assert (target / "subdir" / "nested.json").is_file()


def test_cleanup_is_case_insensitive(processor, tmp_path):
    """Актуальные файлы должны переживать очистку независимо от регистра.

    Регистр имени файла задаёт источник (GitHub API), а множество актуальных
    имён — результат публикации; расхождение регистра не должно удалять
    актуальные файлы.
    """
    target = _make_dir(tmp_path / "HAPP", ["whitelist.json", "whitelist.DEEPLINK", "old.json"])

    processor._cleanup_obsolete_files(target, {"WHITELIST.JSON", "WHITELIST.DEEPLINK"})

    assert (target / "whitelist.json").is_file()
    assert (target / "whitelist.DEEPLINK").is_file()
    assert not (target / "old.json").exists()


def test_cleanup_mixed_case_valid_names(processor, tmp_path):
    target = _make_dir(tmp_path / "HAPP", ["JSONSUB.JSON", "JSONSUB.DEEPLINK", "obsolete.json"])
    processor._cleanup_obsolete_files(target, {"jsonsub.json", "jsonsub.deeplink"})
    assert (target / "JSONSUB.JSON").is_file()
    assert (target / "JSONSUB.DEEPLINK").is_file()
    assert not (target / "obsolete.json").exists()


def test_cleanup_skipped_on_fallback_discovery(processor, tmp_path):
    target = _make_dir(tmp_path / "HAPP", ["ANY.JSON", "OTHER.DEEPLINK"])
    processor.is_fallback_discovery = True
    processor._cleanup_obsolete_files(target, set())
    assert sorted(p.name for p in target.iterdir()) == ["ANY.JSON", "OTHER.DEEPLINK"]


def test_cleanup_handles_missing_directory(processor, tmp_path):
    # не должно падать
    processor._cleanup_obsolete_files(tmp_path / "missing", {"A.JSON"})
