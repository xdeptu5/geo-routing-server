"""Тесты app/validators.py: единые правила ввода для мастера, меню и приложения."""

import re
from pathlib import Path

import pytest

from app import __version__
from app.validators import (
    generate_token,
    human_schedule,
    is_valid_cron,
    is_valid_docker_network,
    is_valid_domain,
    is_valid_token,
    normalize_domain,
    normalize_public_url,
    normalize_remnawave_url,
    parse_port,
    schedule_every_hours,
    schedule_from_time,
)

REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("token,ok", [
    ("abcd", True),
    ("a1b2-c3_d4", True),
    ("abc", False),
    ("ab.cd", False),
    ("../etc", False),
    ("change_me_to_random_secret_token", False),
    ("", False),
])
def test_token(token, ok):
    assert is_valid_token(token) is ok


def test_generated_token_is_valid_and_random():
    first, second = generate_token(), generate_token()
    assert is_valid_token(first) and len(first) == 32
    assert first != second


@pytest.mark.parametrize("raw,expected", [
    ("geo.example.com", "geo.example.com"),
    ("https://geo.example.com/path", "geo.example.com"),
    ("  HTTP://geo.example.com  ", "geo.example.com"),
])
def test_normalize_domain(raw, expected):
    assert normalize_domain(raw) == expected


def test_domain_validation():
    assert is_valid_domain("geo.example.com")
    assert is_valid_domain("1.2.3.4:8443")
    assert not is_valid_domain("")
    assert not is_valid_domain("bad domain")


@pytest.mark.parametrize("raw,expected", [
    ("8080", 8080), ("08080", 8080), ("1", 1), ("65535", 65535),
    ("0", None), ("65536", None), ("abc", None), ("", None), ("123456", None),
])
def test_parse_port(raw, expected):
    assert parse_port(raw) == expected


@pytest.mark.parametrize("name,ok", [
    ("remnawave-network", True), ("net_1.a", True),
    ('bad"name', False), ("-lead", False), ("", False),
])
def test_docker_network(name, ok):
    assert is_valid_docker_network(name) is ok


@pytest.mark.parametrize("expr,ok", [
    ("0 12 * * *", True), ("0 */6 * * *", True), ("*/5 1-3 * * 1,5", True),
    ("12:00", False), ("0 12 * *", False), ("a b c d e", False), ("", False),
])
def test_cron(expr, ok):
    assert is_valid_cron(expr) is ok


@pytest.mark.parametrize("value,expected", [
    ("14:30", "30 14 * * *"), ("04:05", "5 4 * * *"), ("9", "0 9 * * *"),
    ("08:00", "0 8 * * *"), ("24:00", None), ("12:60", None), ("x", None),
])
def test_schedule_from_time(value, expected):
    assert schedule_from_time(value) == expected


@pytest.mark.parametrize("value,expected", [
    ("1", "0 * * * *"), ("6", "0 */6 * * *"), ("24", "0 0 * * *"),
    ("0", None), ("25", None), ("x", None),
])
def test_schedule_every_hours(value, expected):
    assert schedule_every_hours(value) == expected


def test_human_schedule_handles_leading_zero_hours():
    # bash-версия падала на "08" (восьмеричное число)
    assert human_schedule("0 08 * * *") == "ежедневно в 08:00 UTC"
    assert human_schedule("0 */4 * * *") == "каждые 4 ч."
    assert human_schedule("5 4 1 * *") == "5 4 1 * *"


def test_url_normalizers():
    assert normalize_remnawave_url("https://panel/") == "https://panel/api"
    assert normalize_remnawave_url("https://panel/API") == "https://panel/API"
    assert normalize_remnawave_url("") == ""
    assert normalize_public_url("node.example.com/tok/") == "https://node.example.com/tok"


def test_script_and_app_versions_match():
    """install.sh и образ выпускаются одной версией."""
    script = (REPO_ROOT / "install.sh").read_text(encoding="utf-8")
    match = re.search(r'^SCRIPT_VERSION="([^"]+)"', script, re.MULTILINE)
    assert match and match.group(1) == __version__


def test_entrypoint_uses_shared_token_rules():
    """Правила токена не дублируются в docker-entrypoint.sh."""
    entrypoint = (REPO_ROOT / "docker-entrypoint.sh").read_text(encoding="utf-8")
    assert "Config.get_token()" in entrypoint
    assert "A-Za-z0-9_-" not in entrypoint
