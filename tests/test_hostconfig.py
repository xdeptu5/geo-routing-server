"""Тесты app/hostconfig.py: мастер установки и разделы настроек .env.

Ввод пользователя подаётся построчно через подмену input(); пустая строка
означает Enter.
"""

import builtins

import pytest

from app import hostconfig
from app.envfile import EnvFile
from app.hostconfig import APPLY, config_set, run_section, run_setup

yaml = pytest.importorskip("yaml")


@pytest.fixture
def answers(monkeypatch):
    """Подаёт заготовленные ответы; при их нехватке тест падает, а не зависает."""
    queue = []

    def fake_input(prompt=""):
        if not queue:
            raise AssertionError(f"Неожиданный вопрос: {prompt!r}")
        return queue.pop(0)

    monkeypatch.setattr(builtins, "input", fake_input)
    monkeypatch.delenv("GRS_HOST_NETWORKS", raising=False)
    monkeypatch.delenv("GRS_HOST_PORTS", raising=False)

    def feed(*lines):
        queue.extend(lines)
        return queue

    yield feed
    assert not queue, f"Не все ответы использованы: {queue}"


def read_env(host):
    return EnvFile(host / ".env")


# ------------------------------------------------------------------------------
# Мастер установки
# ------------------------------------------------------------------------------

def test_fresh_install_with_defaults(tmp_path, answers):
    answers("", "", "", "", "", "")  # домен, токен, клиенты, пресет, порт, Remnawave
    assert run_setup(tmp_path, "img:test") == 0
    env = read_env(tmp_path)
    assert env.get("DOMAIN") == "geo.example.com"
    assert len(env.get("ROUTING_TOKEN")) == 32
    assert env.get("ENABLED_CLIENTS") == "HAPP,INCY"
    assert env.get("ROUTING_SOURCE_PRESET") == "geogaga"
    assert env.get("HTTP_PORT") == "8080"
    assert env.get("REMNAWAVE_TOKEN") == ""
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text(encoding="utf-8"))
    assert compose["services"]["geo-routing-server"]["image"] == "img:test"


def test_invalid_answers_are_asked_again(tmp_path, answers):
    answers("bad domain", "geo.test", "abc", "goodtoken", "9", "2", "2", "99999", "8443", "")
    assert run_setup(tmp_path, "img") == 0
    env = read_env(tmp_path)
    assert env.get("DOMAIN") == "geo.test"
    assert env.get("ROUTING_TOKEN") == "goodtoken"
    assert env.get("ENABLED_CLIENTS") == "HAPP"
    assert env.get("ROUTING_SOURCE_PRESET") == "hydraponique"
    assert env.get("ROUTING_RULES") == "JSONSUB,WHITELIST"
    assert env.get("HTTP_PORT") == "8443"


def test_rerun_keeps_previous_values_and_backs_up(tmp_path, answers):
    (tmp_path / ".env").write_text(
        'DOMAIN="old.example.com"\n'
        "ROUTING_TOKEN='keepme123'\n"
        "ENABLED_CLIENTS=HAPP_GEO,INCY_GEO\n"
        "ROUTING_SOURCE_PRESET=vahellame\n"
        "HTTP_PORT=9000\n"
        "TELEGRAM_BOT_TOKEN=123:abc\n"
        "REMNAWAVE_BASE_URL=http://remnawave:3000/api\n"
        "REMNAWAVE_TOKEN=jwt\n"
        "DOCKER_NETWORK=remnawave-network\n",
        encoding="utf-8",
    )
    (tmp_path / "compose.yaml").write_text("services: {}\n", encoding="utf-8")
    answers("", "", "", "", "", "")
    assert run_setup(tmp_path, "img") == 0
    env = read_env(tmp_path)
    assert env.get("DOMAIN") == "old.example.com"
    assert env.get("ROUTING_TOKEN") == "keepme123"
    assert env.get("ENABLED_CLIENTS") == "HAPP_GEO,INCY_GEO"
    assert env.get("ROUTING_SOURCE_PRESET") == "vahellame"
    assert env.get("HTTP_PORT") == "9000"
    assert env.get("TELEGRAM_BOT_TOKEN") == "123:abc"
    assert env.get("REMNAWAVE_TOKEN") == "jwt"
    assert env.get("DOCKER_NETWORK") == "remnawave-network"
    assert list(tmp_path.glob(".env.bak.*"))
    assert list(tmp_path.glob("compose.yaml.bak.*"))
    compose = yaml.safe_load((tmp_path / "compose.yaml").read_text(encoding="utf-8"))
    assert compose["networks"]["remnawave"]["name"] == "remnawave-network"


def test_placeholder_token_is_replaced(tmp_path, answers):
    (tmp_path / ".env").write_text("ROUTING_TOKEN=change_me_to_random_secret_token\n", encoding="utf-8")
    answers("", "", "", "", "", "")
    assert run_setup(tmp_path, "img") == 0
    token = read_env(tmp_path).get("ROUTING_TOKEN")
    assert token != "change_me_to_random_secret_token" and len(token) == 32


def test_setup_with_remnawave_and_unknown_network(tmp_path, answers, monkeypatch, capsys):
    monkeypatch.setenv("GRS_HOST_NETWORKS", "bridge,host")
    answers("", "", "", "", "", "y", "https://panel.example.com", "jwt-token", "remnawave-network")
    assert run_setup(tmp_path, "img") == 0
    env = read_env(tmp_path)
    assert env.get("REMNAWAVE_BASE_URL") == "https://panel.example.com/api"
    assert env.get("DOCKER_NETWORK") == "remnawave-network"
    assert "не найдена в Docker" in capsys.readouterr().out


def test_cancel_leaves_files_untouched(tmp_path, monkeypatch):
    (tmp_path / ".env").write_text("DOMAIN=keep\n", encoding="utf-8")

    def interrupt(prompt=""):
        raise KeyboardInterrupt

    monkeypatch.setattr(builtins, "input", interrupt)
    assert run_setup(tmp_path, "img") == 1
    assert (tmp_path / ".env").read_text(encoding="utf-8") == "DOMAIN=keep\n"
    assert not (tmp_path / "compose.yaml").exists()


# ------------------------------------------------------------------------------
# Разделы настроек
# ------------------------------------------------------------------------------

@pytest.fixture
def installed(tmp_path):
    (tmp_path / ".env").write_text(
        "DOMAIN=geo.example.com\nROUTING_TOKEN=tok12345\nENABLED_CLIENTS=HAPP,INCY\n",
        encoding="utf-8",
    )
    return tmp_path


def test_section_requires_env(tmp_path):
    assert run_section("clients", tmp_path) == 1


def test_back_without_changes_returns_zero(installed, answers):
    answers("0")
    assert run_section("clients", installed) == 0


def test_clients_preset_change_requests_apply(installed, answers):
    answers("2", "3")  # источник правил -> vahellame
    assert run_section("clients", installed) == APPLY
    env = read_env(installed)
    assert env.get("ROUTING_SOURCE_PRESET") == "vahellame"
    assert env.get("ROUTING_RULES") == "WHITELIST"


def test_clients_toggle_and_external_url(installed, answers):
    answers("4")
    assert run_section("clients", installed) == APPLY
    assert read_env(installed).get("SERVE_GEOIP") == "false"
    answers("6", "geo-node.example.com/tok")
    assert run_section("clients", installed) == APPLY
    assert read_env(installed).get("PUBLIC_GEO_BASE_URL") == "https://geo-node.example.com/tok"
    answers("6", "none")
    assert run_section("clients", installed) == APPLY
    assert read_env(installed).get("PUBLIC_GEO_BASE_URL") == ""


def test_same_value_is_not_reported_as_change(installed, answers):
    answers("1", "1", "0")  # клиенты -> HAPP,INCY (уже стоит) -> назад
    assert run_section("clients", installed) == 0


def test_schedule_variants(installed, answers):
    answers("1", "08:15")
    assert run_section("schedule", installed) == APPLY
    assert read_env(installed).get("SCHEDULE") == "15 8 * * *"
    answers("7", "12:00", "7", "0 */3 * * *")
    assert run_section("schedule", installed) == APPLY
    assert read_env(installed).get("SCHEDULE") == "0 */3 * * *"


def test_telegram_configure_test_and_disable(installed, answers, monkeypatch):
    answers("1", "123:abc", "-100500", "")
    assert run_section("telegram", installed) == APPLY
    env = read_env(installed)
    assert env.get("TELEGRAM_BOT_TOKEN") == "123:abc" and env.get("TELEGRAM_CHAT_ID") == "-100500"

    sent = {}

    def fake_send(**kwargs):
        sent.update(kwargs)
        return True

    ctx = hostconfig.HostContext(installed)
    answers("1", "", "0")  # тест, Enter после результата, назад
    assert hostconfig.section_telegram(ctx, sender=fake_send) == 0
    assert sent == {"bot_token": "123:abc", "chat_id": "-100500", "thread_id": ""}

    answers("4", "y")
    assert run_section("telegram", installed) == APPLY
    assert read_env(installed).get("TELEGRAM_BOT_TOKEN") == ""


def test_remnawave_connect_writes_network_into_compose(installed, answers):
    answers("1", "", "jwt-token", "remnawave-network")
    assert run_section("remnawave", installed, "img") == APPLY
    env = read_env(installed)
    assert env.get("REMNAWAVE_BASE_URL") == "http://remnawave:3000/api"
    assert env.get("DOCKER_NETWORK") == "remnawave-network"
    compose = yaml.safe_load((installed / "compose.yaml").read_text(encoding="utf-8"))
    assert compose["networks"]["remnawave"]["name"] == "remnawave-network"


def test_remnawave_connect_without_token_saves_nothing(installed, answers):
    answers("1", "", "", "", "0")
    assert run_section("remnawave", installed) == 0
    assert read_env(installed).get("REMNAWAVE_BASE_URL") == ""


def test_remnawave_disconnect(installed, answers):
    env = read_env(installed)
    env.set("REMNAWAVE_BASE_URL", "http://p/api")
    env.set("REMNAWAVE_TOKEN", "jwt")
    env.save()
    answers("4", "y")
    assert run_section("remnawave", installed) == APPLY
    assert read_env(installed).get("REMNAWAVE_TOKEN") == ""


def test_ctrl_c_discards_partial_edit(installed, monkeypatch):
    calls = iter(["1"])  # начинаем настройку Telegram, затем Ctrl+C

    def fake_input(prompt=""):
        try:
            return next(calls)
        except StopIteration:
            raise KeyboardInterrupt

    monkeypatch.setattr(builtins, "input", fake_input)
    before = (installed / ".env").read_text(encoding="utf-8")
    assert run_section("telegram", installed) == 0
    assert (installed / ".env").read_text(encoding="utf-8") == before


# ------------------------------------------------------------------------------
# config set
# ------------------------------------------------------------------------------

def test_config_set_validates_and_normalizes(installed):
    assert config_set(installed, "domain", "https://new.example.com/x") == APPLY
    assert read_env(installed).get("DOMAIN") == "new.example.com"
    assert config_set(installed, "HTTP_PORT", "99999") == 2
    assert config_set(installed, "ROUTING_TOKEN", "change_me_to_random_secret_token") == 2
    assert config_set(installed, "SCHEDULE", "0  6 * * *") == APPLY
    assert read_env(installed).get("SCHEDULE") == "0 6 * * *"
    assert config_set(installed, "SCHEDULE", "0 6 * * *") == 0
    assert config_set(installed, "CUSTOM_KEY", "anything") == APPLY
