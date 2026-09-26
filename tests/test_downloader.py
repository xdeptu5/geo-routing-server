"""Тесты app/downloader.py: валидация контента и URL (без сети)."""

import pytest

from app.downloader import DownloadError, Downloader

HAPP_DEEPLINK = b"happ://routing/onadd/eyJHZW9pcHVybCI6ImEifQ==\n"
INCY_ROUTING_DEEPLINK = b"incy://routing/onadd/eyJHZW9pcHVybCI6ImEifQ==\n"
INCY_AUTOROUTING_DEEPLINK = b"incy://autorouting/onadd/aHR0cHM6Ly9leGFtcGxlLmNvbQ==\n"
VALID_JSON = b'{"Outbounds": [], "Geoipurl": "https://example.com/geoip.dat"}'
HTML_ERROR = (
    b"<!DOCTYPE html>\n<html><head><title>404 Not Found</title></head>"
    b"<body><h1>404 Not Found</h1></body></html>"
)


@pytest.fixture
def downloader(tmp_path):
    return Downloader(tmp_path / "cache")


# ------------------------------------------------------------------------------
# _validate_content
# ------------------------------------------------------------------------------

@pytest.mark.parametrize("kind", ["rule", "json"])
def test_validate_content_accepts_json(downloader, kind):
    assert downloader._validate_content(VALID_JSON, kind) is True
    assert downloader._validate_content(b'{"a": 1}', kind) is True


@pytest.mark.parametrize(
    "content", [HAPP_DEEPLINK, INCY_ROUTING_DEEPLINK, INCY_AUTOROUTING_DEEPLINK]
)
def test_validate_content_accepts_known_deeplinks(downloader, content):
    """Источники отдают правила в виде happ://routing/onadd/ и incy://autorouting/onadd/..."""
    assert downloader._validate_content(content, "rule") is True


@pytest.mark.parametrize("kind", ["rule", "json"])
def test_validate_content_rejects_html(downloader, kind):
    assert downloader._validate_content(HTML_ERROR, kind) is False
    assert downloader._validate_content(b"<html><body>oops</body></html>", kind) is False


def test_validate_content_rejects_garbage_rule(downloader):
    assert downloader._validate_content(b"lorem ipsum dolor sit amet, not a rule", "rule") is False
    assert downloader._validate_content(b"\x00\xff\xfe broken bytes", "rule") is False


def test_validate_content_rejects_empty(downloader):
    for kind in ("rule", "json", "binary"):
        assert downloader._validate_content(b"", kind) is False


def test_validate_content_binary_rules(downloader):
    # слишком маленький файл — отклоняем
    assert downloader._validate_content(b"x" * 512, "binary") is False
    # обычный бинарник нужного размера — принимаем
    assert downloader._validate_content(b"x" * 2048, "binary") is True
    # HTML-заглушка нужного размера — отклоняем
    assert downloader._validate_content(HTML_ERROR * 16, "binary") is False


# ------------------------------------------------------------------------------
# fetch: схема URL отклоняется до любого сетевого обращения
# ------------------------------------------------------------------------------

@pytest.mark.parametrize("url", ["file:///etc/passwd", "ftp://example.com/x", "gopher://example.com/"])
def test_fetch_rejects_unsafe_scheme(downloader, url):
    with pytest.raises(DownloadError):
        downloader.fetch(url, "key", kind="rule")


# ------------------------------------------------------------------------------
# _validate_untrusted_url: без DNS-запросов (только литералы IP и подмена)
# ------------------------------------------------------------------------------

@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/rules.json",   # loopback
        "http://10.0.0.5/rules.json",    # RFC1918
        "http://192.168.1.1/rules.json", # RFC1918
        "http://169.254.1.1/rules.json", # link-local
    ],
)
def test_untrusted_url_rejects_private_addresses(downloader, url):
    with pytest.raises(DownloadError):
        downloader._validate_untrusted_url(url)


def test_untrusted_url_rejects_credentials(downloader):
    with pytest.raises(DownloadError):
        downloader._validate_untrusted_url("https://user:pass@example.com/x")


def test_untrusted_url_rejects_invalid_port(downloader):
    with pytest.raises(DownloadError):
        downloader._validate_untrusted_url("https://example.com:99999/x")


def test_untrusted_url_rejects_unsafe_scheme(downloader):
    with pytest.raises(DownloadError):
        downloader._validate_untrusted_url("file:///etc/passwd")


def test_untrusted_url_returns_preferred_ipv4(downloader, monkeypatch):
    """Среди разрешённых адресов предпочитается IPv4 (VPS без IPv6-роутинга)."""
    import socket as socket_module

    def fake_getaddrinfo(host, port, **kwargs):
        return [
            (socket_module.AF_INET6, socket_module.SOCK_STREAM, 6, "", ("2606:4700::1111", port, 0, 0)),
            (socket_module.AF_INET, socket_module.SOCK_STREAM, 6, "", ("93.184.216.34", port)),
        ]

    monkeypatch.setattr(socket_module, "getaddrinfo", fake_getaddrinfo)
    assert downloader._validate_untrusted_url("https://example.com/x") == "93.184.216.34"


# ------------------------------------------------------------------------------
# fetch: ретраи, break на 4xx и sleep только при attempt < max_retries
# ------------------------------------------------------------------------------

@pytest.mark.parametrize("status_code", [400, 401, 403, 404, 410])
def test_fetch_breaks_immediately_on_permanent_client_errors(downloader, monkeypatch, status_code):
    import urllib.error
    import urllib.request

    call_count = 0
    sleep_calls = []

    def fake_urlopen(req, timeout=None):
        nonlocal call_count
        call_count += 1
        raise urllib.error.HTTPError(
            url=req.full_url if hasattr(req, "full_url") else str(req),
            code=status_code,
            msg=f"Client Error {status_code}",
            hdrs={},
            fp=None,
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr("time.sleep", lambda delay: sleep_calls.append(delay))

    with pytest.raises(DownloadError) as exc_info:
        downloader.fetch("https://example.com/file.json", "test_key", kind="json", trusted_url=True)

    assert "after 1 attempt(s)" in str(exc_info.value)
    assert call_count == 1
    assert len(sleep_calls) == 0


def test_fetch_sleeps_only_if_attempt_less_than_max_retries(downloader, monkeypatch):
    import urllib.error
    import urllib.request

    call_count = 0
    sleep_calls = []

    def fake_urlopen(req, timeout=None):
        nonlocal call_count
        call_count += 1
        raise urllib.error.HTTPError(
            url="https://example.com/test",
            code=500,
            msg="Internal Server Error",
            hdrs={},
            fp=None,
        )

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    monkeypatch.setattr("time.sleep", lambda delay: sleep_calls.append(delay))

    downloader.max_retries = 3
    with pytest.raises(DownloadError) as exc_info:
        downloader.fetch("https://example.com/test", "test_key", kind="json", trusted_url=True)

    assert "after 3 attempt(s)" in str(exc_info.value)
    assert call_count == 3
    # sleep вызывается только между попытками (1 -> 2, 2 -> 3), на 3-й попытке sleep не вызывается
    assert len(sleep_calls) == 2

