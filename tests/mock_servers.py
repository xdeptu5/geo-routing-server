"""
Mock HTTP-серверы для имитации внешних API без реальной сети.
Используются во всех тестах: Remnawave, GitHub, Telegram.
"""
import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Dict, List, Optional


# ---------------------------------------------------------------------------
# Утилита: запустить сервер в фоновом потоке и вернуть его адрес + объект
# ---------------------------------------------------------------------------

def start_server(handler_cls) -> tuple:
    """Поднимает HTTPServer на случайном порту. Возвращает (server, thread, base_url)."""
    server = HTTPServer(("127.0.0.1", 0), handler_cls)
    port = server.server_address[1]
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base_url = f"http://127.0.0.1:{port}"
    return server, thread, base_url


# ---------------------------------------------------------------------------
# Мок-сервер Remnawave API
# ---------------------------------------------------------------------------

class RemnawaveHandler(BaseHTTPRequestHandler):
    """
    Притворяется Remnawave API.
    Поведение управляется атрибутами класса (настраиваются в тестах).
    """

    # Настройки поведения (изменяются из тест-методов через cls.*)
    require_cf_headers: bool = False
    cf_expected_id: str = ""
    cf_expected_secret: str = ""
    force_status: Optional[int] = None          # если не None — всегда отвечает этим кодом
    received_requests: List[Dict[str, Any]] = []  # журнал входящих запросов
    squad_data: Dict[str, Any] = {}              # данные сквадов по UUID
    subscription_settings: Dict[str, Any] = {}  # данные /subscription-settings

    def log_message(self, fmt, *args):  # заглушаем стандартный вывод
        pass

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b""

    def _send_json(self, code: int, payload: Any) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _check_cf_headers(self) -> bool:
        if not self.__class__.require_cf_headers:
            return True
        cf_id = self.headers.get("CF-Access-Client-Id", "")
        cf_secret = self.headers.get("CF-Access-Client-Secret", "")
        return (
            cf_id == self.__class__.cf_expected_id
            and cf_secret == self.__class__.cf_expected_secret
        )

    def _record_request(self, method: str, body: bytes) -> None:
        self.__class__.received_requests.append({
            "method": method,
            "path": self.path,
            "headers": dict(self.headers),
            "body": json.loads(body) if body else None,
        })

    def do_GET(self):
        if self.__class__.force_status is not None:
            self._send_json(self.__class__.force_status, {"error": "forced"})
            return

        if not self._check_cf_headers():
            self._send_json(403, {"error": "cf access denied"})
            return

        self._record_request("GET", b"")

        # /api/subscription-settings
        if "/subscription-settings" in self.path:
            data = self.__class__.subscription_settings or {
                "uuid": "global-uuid-001",
                "customResponseHeaders": {}
            }
            self._send_json(200, {"response": data})
            return

        # /api/external-squads/<uuid>
        parts = self.path.rstrip("/").split("/")
        if "external-squads" in parts:
            uuid = parts[-1]
            data = self.__class__.squad_data.get(uuid, {
                "uuid": uuid,
                "responseHeadersAdd": {},
                "responseHeadersRemove": []
            })
            self._send_json(200, {"response": data})
            return

        self._send_json(404, {"error": "not found"})

    def do_PATCH(self):
        if self.__class__.force_status is not None:
            self._send_json(self.__class__.force_status, {"error": "forced"})
            return

        if not self._check_cf_headers():
            self._send_json(403, {"error": "cf access denied"})
            return

        body = self._read_body()
        self._record_request("PATCH", body)
        self._send_json(200, {"response": json.loads(body) if body else {}})


# ---------------------------------------------------------------------------
# Мок-сервер GitHub (раздаёт JSON-правила и бинарные dat-файлы)
# ---------------------------------------------------------------------------

FAKE_ROUTING_JSON = json.dumps({
    "Geoipurl": "https://example.com/geoip.dat",
    "Geositeurl": "https://example.com/geosite.dat",
    "LastUpdated": "1234567890",
    "rules": []
}, ensure_ascii=False).encode("utf-8")

FAKE_BINARY_DAT = b"\x00\x01" * 600   # >1024 байт, не HTML


class GitHubHandler(BaseHTTPRequestHandler):
    """Имитирует raw.githubusercontent.com и api.github.com."""

    etag_store: Dict[str, str] = {}  # cache_key -> etag
    serve_html_instead: bool = False  # для теста «провайдер вернул HTML»

    def log_message(self, fmt, *args):
        pass

    def _send_bytes(self, code: int, body: bytes, content_type: str, etag: str = "") -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        if etag:
            self.send_header("ETag", etag)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]

        # GitHub API listing: /repos/.../contents/HAPP → список файлов
        if "/contents/" in path:
            client = path.rstrip("/").split("/")[-1]
            listing = [
                {"name": "JSONSUB.JSON", "type": "file"},
                {"name": "WHITELIST.JSON", "type": "file"},
                {"name": "DEFAULT.JSON", "type": "file"},
            ]
            body = json.dumps(listing).encode("utf-8")
            self._send_bytes(200, body, "application/json")
            return

        # binary .dat файл
        if path.endswith(".dat"):
            if self.__class__.serve_html_instead:
                html = b"<!doctype html><html><body>blocked</body></html>"
                self._send_bytes(200, html, "text/html")
                return

            client_etag = self.headers.get("If-None-Match", "")
            server_etag = '"abc123"'
            if client_etag == server_etag:
                self.send_response(304)
                self.end_headers()
                return
            self._send_bytes(200, FAKE_BINARY_DAT, "application/octet-stream", etag=server_etag)
            return

        # JSON routing-файл
        if path.endswith(".json") or path.endswith(".JSON"):
            self._send_bytes(200, FAKE_ROUTING_JSON, "application/json", etag='"json-etag-v1"')
            return

        # Всё остальное — 404 (urllib поднимет HTTPError)
        self.send_response(404)
        self.send_header("Content-Length", "9")
        self.end_headers()
        self.wfile.write(b"not found")


# ---------------------------------------------------------------------------
# Мок-сервер Telegram Bot API
# ---------------------------------------------------------------------------

class TelegramHandler(BaseHTTPRequestHandler):
    """Притворяется api.telegram.org. Записывает все полученные сообщения."""

    received_messages: List[Dict[str, Any]] = []
    force_fail: bool = False

    def log_message(self, fmt, *args):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
        except Exception:
            payload = {}

        self.__class__.received_messages.append(payload)

        if self.__class__.force_fail:
            self.send_response(500)
            self.end_headers()
            return

        resp = json.dumps({"ok": True, "result": {"message_id": 42}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(resp)))
        self.end_headers()
        self.wfile.write(resp)
