"""Тесты текстов Telegram-уведомлений: коротко, без повторов и с понятной причиной."""

import pytest

from app import notifier
from app.notifier import TelegramNotifier
from app.publisher import PublishedFileInfo


@pytest.fixture
def cfg():
    # Другие тесты перезагружают app.config и app.notifier, поэтому Config
    # берётся в момент теста — тот, что сейчас видит модуль уведомлений
    return notifier.Config


@pytest.fixture
def sent(monkeypatch, cfg):
    Config = cfg
    messages = []
    monkeypatch.setattr(TelegramNotifier, "_send_message",
                        staticmethod(lambda text, **kw: messages.append(text) or True))
    monkeypatch.setattr(Config, "DOMAIN", "geo.test")
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP", "INCY"])
    monkeypatch.setattr(Config, "TELEGRAM_NOTIFY_SUCCESS", True)
    import app.remnawave
    monkeypatch.setattr(app.remnawave.RemnawaveSync, "is_configured", classmethod(lambda cls: False))
    return messages


def info(name, size=2 * 1024 * 1024, updated=True):
    return PublishedFileInfo(filename=name, size_bytes=size, sha256="ab" * 32, is_updated=updated)


def test_changes_show_only_updated_files_once(sent):
    registry = {
        "HAPP/geoip.dat": info("geoip.dat"),
        "INCY/geoip.dat": info("geoip.dat"),
        "HAPP/geosite.dat": info("geosite.dat", updated=False),
        "HAPP/HAPP.DEEPLINK": info("HAPP.DEEPLINK", 1500),
        "INCY/WHITELIST.JSON": info("WHITELIST.JSON", 900),
    }
    TelegramNotifier.notify_changes("tok", registry, any_changed=True)
    text = sent[0]
    assert text.splitlines()[0] == "✅ <b>Обновлено</b> · geo.test"
    assert text.count("geoip.dat") == 1 and "2.0 МБ" in text
    assert "geosite.dat" not in text
    assert "📚 Правила: HAPP, WHITELIST" in text
    assert "http" not in text and "ab" * 6 not in text  # ни ссылок, ни хешей
    assert len(text.splitlines()) <= 5


def test_changes_mention_squads_when_remnawave_configured(sent, monkeypatch):
    import app.remnawave
    monkeypatch.setattr(app.remnawave.RemnawaveSync, "is_configured", classmethod(lambda cls: True))
    TelegramNotifier.notify_changes("tok", {"HAPP/HAPP.DEEPLINK": info("HAPP.DEEPLINK")}, any_changed=True)
    assert "Сквады Remnawave" in sent[0]


def test_no_message_without_changes_or_when_disabled(sent, monkeypatch, cfg):
    Config = cfg
    TelegramNotifier.notify_changes("tok", {"HAPP/geoip.dat": info("geoip.dat", updated=False)}, any_changed=True)
    monkeypatch.setattr(Config, "TELEGRAM_NOTIFY_SUCCESS", False)
    TelegramNotifier.notify_changes("tok", {"HAPP/geoip.dat": info("geoip.dat")}, any_changed=True)
    assert sent == []


def test_rules_only_mode_has_no_placeholder_domain(sent, monkeypatch, cfg):
    Config = cfg
    monkeypatch.setattr(Config, "ENABLED_CLIENTS", ["HAPP_DEEPLINK"])
    monkeypatch.setattr(Config, "DOMAIN", "geo.example.com")
    TelegramNotifier.alert_failure(["Remnawave: HTTP 401"])
    assert "geo.example.com" not in sent[0]


def test_failure_is_one_message_with_reasons_and_next_step(sent):
    problems = [f"Remnawave: ошибка {i}" for i in range(5)]
    TelegramNotifier.alert_failure(problems, partial=True)
    assert len(sent) == 1
    text = sent[0]
    assert text.startswith("⚠️ <b>Синхронизация прошла с ошибками</b>")
    assert text.count("• Remnawave") == 3 and "и ещё 2" in text
    assert "Остальное обновлено" in text and "geoserver logs" in text


def test_failure_escapes_and_shortens_details(sent):
    TelegramNotifier.alert_failure("<b>boom</b> " + "x" * 500)
    text = sent[0]
    assert text.startswith("❌ <b>Синхронизация не удалась</b>")
    assert "&lt;b&gt;boom" in text and "x" * 300 not in text
    assert "прежние версии" in text


def test_test_message_says_what_will_arrive(sent, monkeypatch, cfg):
    Config = cfg
    monkeypatch.setattr(Config, "TELEGRAM_NOTIFY_SUCCESS", False)
    assert TelegramNotifier.send_test_message(bot_token="t", chat_id="1")
    assert "ошибки синхронизации." in sent[0] and len(sent[0].splitlines()) == 2
