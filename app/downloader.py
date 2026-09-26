import http.client
import ipaddress
import json
import logging
import random
import socket
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

logger = logging.getLogger("geo-routing-server")

class DownloadError(Exception):
    """Ошибка загрузки данных."""
    pass


# 4xx-статусы, при которых повторы еще имеют смысл; остальные 4xx прекращают попытки сразу
_RETRYABLE_HTTP_STATUS = {408, 425, 429}
# Экспоненциальная задержка между попытками (сек): 1.5, 3, 6, ... с потолком
_RETRY_BASE_DELAY = 1.5
_RETRY_MAX_DELAY = 30.0
# Максимальная пауза по Retry-After (сек), чтобы сервер не остановил прогон на часы
_RETRY_AFTER_MAX = 60.0


class _PublicOnlyRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Проверяет каждый адрес до выполнения перенаправления."""

    def __init__(self, validate_url):
        super().__init__()
        self._validate_url = validate_url

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        self._validate_url(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _pin_connection(connection, resolved_ip: str):
    """Подменяет повторное DNS-разрешение подключением к проверенному IP."""
    create_connection = connection._create_connection

    def connect_to_resolved_ip(address, timeout, source_address):
        return create_connection((resolved_ip, address[1]), timeout, source_address)

    connection._create_connection = connect_to_resolved_ip
    return connection


class _PublicOnlyHTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, resolve_url):
        super().__init__()
        self._resolve_url = resolve_url

    def http_open(self, req):
        resolved_ip = self._resolve_url(req.full_url)

        def connection_factory(host, **kwargs):
            return _pin_connection(http.client.HTTPConnection(host, **kwargs), resolved_ip)

        return self.do_open(connection_factory, req)


class _PublicOnlyHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, resolve_url):
        super().__init__()
        self._resolve_url = resolve_url

    def https_open(self, req):
        resolved_ip = self._resolve_url(req.full_url)

        def connection_factory(host, **kwargs):
            return _pin_connection(http.client.HTTPSConnection(host, **kwargs), resolved_ip)

        return self.do_open(connection_factory, req, context=self._context)


class Downloader:
    """HTTP-загрузчик с поддержкой ETag-кэширования, повторных попыток и валидации."""
    
    # Лимит загружаемых данных (150 МБ для баз данных, 10 МБ для JSON)
    MAX_BINARY_SIZE = 150 * 1024 * 1024
    MAX_JSON_SIZE = 10 * 1024 * 1024
    
    def __init__(self, cache_dir: Path, timeout: int = 60, max_retries: int = 3):
        self.cache_dir = cache_dir
        self.timeout = timeout
        self.max_retries = max_retries
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _safe_cache_key(cache_key: str) -> str:
        return cache_key.replace("/", "_").replace("\\", "_")
        
    def _validate_content(self, content: bytes, kind: str) -> bool:
        if not content:
            return False
            
        if kind in ("json", "rule"):
            try:
                json.loads(content.decode("utf-8"))
                return True
            except Exception:
                if kind == "rule":
                    text = content.decode("utf-8", errors="replace")
                    # Источники отдают правило либо как JSON, либо как ссылку onadd.
                    # Incy использует префикс autorouting (incy://autorouting/onadd/...),
                    # поэтому проверяем обе формы — иначе такие правила отбраковываются.
                    if "://routing/onadd/" in text or "://autorouting/onadd/" in text:
                        return True
                return False
                
        if kind == "binary":
            # Проверяем минимальный размер и отсутствие HTML ошибок
            if len(content) < 1024:
                return False
            snippet = content[:4096].lower()
            if b"<!doctype" in snippet or b"<html" in snippet or b"<head" in snippet or b"<body" in snippet:
                return False
            return True
            
        return True

    def _validate_untrusted_url(self, url: str) -> str:
        """Отклоняет URL, которые ведут в локальные или служебные сети."""
        try:
            parsed = urlparse(url)
            port = parsed.port
        except ValueError as exc:
            raise DownloadError(f"Rejected malformed URL: {url}") from exc

        if parsed.scheme not in ("http", "https"):
            raise DownloadError(f"Rejected unsafe URL scheme '{parsed.scheme}': {url}")
        if not parsed.hostname or parsed.username is not None or parsed.password is not None:
            raise DownloadError(f"Rejected malformed URL: {url}")

        lookup_port = port or (443 if parsed.scheme == "https" else 80)
        try:
            addresses = socket.getaddrinfo(
                parsed.hostname,
                lookup_port,
                type=socket.SOCK_STREAM,
            )
        except OSError as exc:
            raise DownloadError(f"Could not resolve URL host '{parsed.hostname}': {exc}") from exc

        if not addresses:
            raise DownloadError(f"Could not resolve URL host '{parsed.hostname}'")

        valid_ips = []
        for address in addresses:
            ip_text = address[4][0]
            try:
                resolved_ip = ipaddress.ip_address(ip_text)
            except ValueError as exc:
                raise DownloadError(f"Rejected invalid resolved address '{ip_text}'") from exc
            if not resolved_ip.is_global:
                raise DownloadError(
                    f"Rejected URL resolving to private or reserved address '{ip_text}': {url}"
                )
            valid_ips.append(resolved_ip)

        # Предпочитаем IPv4 для надежной совместимости на VPS без настроенной IPv6-маршрутизации
        ipv4_candidates = [str(ip) for ip in valid_ips if ip.version == 4]
        if ipv4_candidates:
            return ipv4_candidates[0]
        return str(valid_ips[0])

    @staticmethod
    def _retry_after_seconds(error: urllib.error.HTTPError) -> Optional[float]:
        """Пауза из заголовка Retry-After (секунды или HTTP-дата), либо None, если заголовка нет."""
        hdrs = getattr(error, "headers", None) or getattr(error, "hdrs", None)
        if hdrs is None:
            return None
        try:
            raw = hdrs.get("Retry-After")
        except Exception:
            return None
        if raw is None:
            return None
        raw = str(raw).strip()
        if not raw:
            return None
        try:
            seconds = float(raw)
        except ValueError:
            try:
                target = parsedate_to_datetime(raw)
                seconds = (target - datetime.now(timezone.utc)).total_seconds()
            except Exception:
                return None
        return max(0.0, min(seconds, _RETRY_AFTER_MAX))

    def fetch(
        self,
        url: str,
        cache_key: str,
        kind: str = "binary",
        trusted_url: bool = True,
    ) -> bytes:
        """
        Загружает данные по URL с использованием ETag кэша.
        trusted_url разрешает адреса локальной сети для источников, заданных администратором.
        Возвращает байтовое содержимое файла.
        """
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https"):
            raise DownloadError(f"Rejected unsafe URL scheme '{parsed.scheme}': {url}")

        opener = None
        if not trusted_url:
            self._validate_untrusted_url(url)
            opener = urllib.request.build_opener(
                urllib.request.ProxyHandler({}),
                _PublicOnlyRedirectHandler(self._validate_untrusted_url),
                _PublicOnlyHTTPHandler(self._validate_untrusted_url),
                _PublicOnlyHTTPSHandler(self._validate_untrusted_url),
            )

        max_allowed_size = self.MAX_JSON_SIZE if kind in ("json", "rule") else self.MAX_BINARY_SIZE
        safe_cache_key = self._safe_cache_key(cache_key)
        cache_body_file = self.cache_dir / f"{safe_cache_key}.body"
        cache_etag_file = self.cache_dir / f"{safe_cache_key}.etag"
        
        etag: Optional[str] = None
        if cache_etag_file.is_file():
            try:
                etag = cache_etag_file.read_text(encoding="utf-8").strip()
            except Exception:
                etag = None
                
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (geo-routing-server)",
            "Accept": "*/*"
        }
        if etag:
            headers["If-None-Match"] = etag
            
        last_error = None
        retry_after: Optional[float] = None
        attempts_made = 0

        for attempt in range(1, self.max_retries + 1):
            attempts_made = attempt
            try:
                if not trusted_url:
                    self._validate_untrusted_url(url)
                req = urllib.request.Request(url, headers=headers)
                open_request = opener.open if opener is not None else urllib.request.urlopen
                with open_request(req, timeout=self.timeout) as response:
                    status = response.getcode()
                    res_headers = response.headers
                    
                    # Читаем чанками с контролем максимального размера (защита от OOM DoS)
                    chunks = []
                    bytes_read = 0
                    while True:
                        chunk = response.read(65536)
                        if not chunk:
                            break
                        bytes_read += len(chunk)
                        if bytes_read > max_allowed_size:
                            raise DownloadError(
                                f"Response from {url} exceeded maximum allowed size ({max_allowed_size} bytes)"
                            )
                        chunks.append(chunk)
                    body = b"".join(chunks)
                    
                    if status == 200:
                        if not self._validate_content(body, kind):
                            raise DownloadError(f"Downloaded content from {url} failed validation ({kind})")
                            
                        # Атомарно обновляем кэш
                        tmp_body = cache_body_file.with_name(f".{cache_body_file.name}.tmp")
                        tmp_body.write_bytes(body)
                        tmp_body.replace(cache_body_file)
                        
                        new_etag = res_headers.get("ETag")
                        if new_etag:
                            cache_etag_file.write_text(new_etag.strip(), encoding="utf-8")
                        else:
                            cache_etag_file.unlink(missing_ok=True)
                            
                        return body
                        
            except urllib.error.HTTPError as e:
                if e.code == 304:
                    # 304 Not Modified — используем кэшированную копию
                    if cache_body_file.is_file():
                        cached_data = cache_body_file.read_bytes()
                        if self._validate_content(cached_data, kind):
                            return cached_data
                    # Кэш поврежден или отсутствует — удаляем битый ETag и пробуем скачать заново без If-None-Match
                    cache_etag_file.unlink(missing_ok=True)
                    cache_body_file.unlink(missing_ok=True)
                    headers.pop("If-None-Match", None)
                    logger.warning(f"HTTP 304 from {url}, but cache was invalid. Cleared cache, retrying full fetch...")
                    last_error = f"Cache invalidated on 304 for {url}"
                elif e.code in (400, 401, 403, 404, 410) or (400 <= e.code < 500 and e.code not in _RETRYABLE_HTTP_STATUS):
                    # Постоянные ошибки клиента (HTTP 400, 401, 403, 404, 410):
                    # правило не появится само, немедленно прерываем ретраи
                    last_error = f"HTTP {e.code}: {e.reason}"
                    logger.warning(
                        f"HTTP {e.code} ({e.reason}) from {url}: "
                        f"permanent client error, stopping retries."
                    )
                    break
                else:
                    # 5xx и 408/425/429 — временные ошибки, повторяем
                    last_error = f"HTTP {e.code}: {e.reason}"
                    if e.code == 429:
                        retry_after = self._retry_after_seconds(e)
            except Exception as e:
                # Таймауты, сетевые сбои и прочие временные ошибки — повторяем
                last_error = str(e)

            # sleep() вызывается только если attempt < max_retries (на последней попытке спать не нужно)
            if attempt < self.max_retries:
                if retry_after is not None:
                    delay = retry_after
                    logger.info(f"Rate limited (429) on {url}, waiting Retry-After={delay:.1f}s")
                else:
                    delay = min(_RETRY_BASE_DELAY * (2 ** (attempt - 1)), _RETRY_MAX_DELAY)
                    delay *= random.uniform(0.5, 1.5)  # джиттер, чтобы клиенты не повторяли синхронно
                retry_after = None
                time.sleep(delay)
            
        # Stale-if-error: если сеть недоступна, но есть валидный кэш
        if cache_body_file.is_file():
            try:
                cached_data = cache_body_file.read_bytes()
                if self._validate_content(cached_data, kind):
                    logger.warning(
                        f"Failed to fetch fresh data from {url} ({last_error}). "
                        f"Using cached copy (stale-if-error)."
                    )
                    return cached_data
            except Exception:
                pass

        # attempts_made, а не max_retries: при раннем выходе (например, 404) попыток было меньше
        raise DownloadError(f"Failed to download {url} after {attempts_made} attempt(s). Last error: {last_error}")
