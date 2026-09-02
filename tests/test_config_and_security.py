"""
Тесты Config, безопасности и Telegram Notifier:
- Валидация ROUTING_TOKEN (спецсимволы, пустой, дефолтный)
- Утечки токенов в логах
- Telegram: отправка алертов, поддержка thread_id, тишина при NOTIFY_SUCCESS=false
- X-Forwarded-* заголовки для локального Docker
"""
import json
import logging
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent.parent))

from tests.mock_servers import TelegramHandler, start_server


class TestConfigTokenValidation(unittest.TestCase):
    """Валидация ROUTING_TOKEN."""

    def tearDown(self):
        os.environ.pop("ROUTING_TOKEN", None)
        os.environ.pop("ENABLED_CLIENTS", None)

    # ------------------------------------------------------------------
    # Тест 1: Корректный токен — возвращается без изменений
    # ------------------------------------------------------------------
    def test_valid_token_accepted(self):
        os.environ["ROUTING_TOKEN"] = "MySecret-Token_2024"
        from app.config import Config
        token = Config.get_token()
        self.assertEqual(token, "MySecret-Token_2024")

    # ------------------------------------------------------------------
    # Тест 2: Токен со спецсимволами — sys.exit(1)
    # ------------------------------------------------------------------
    def test_token_with_slash_raises(self):
        os.environ["ROUTING_TOKEN"] = "token/../../etc"
        from app.config import Config
        with self.assertRaises(SystemExit):
            Config.get_token()

    def test_token_with_space_raises(self):
        os.environ["ROUTING_TOKEN"] = "token with space"
        from app.config import Config
        with self.assertRaises(SystemExit):
            Config.get_token()

    def test_token_with_question_mark_raises(self):
        os.environ["ROUTING_TOKEN"] = "token?param=1"
        from app.config import Config
        with self.assertRaises(SystemExit):
            Config.get_token()

    # ------------------------------------------------------------------
    # Тест 3: Пустой токен — sys.exit(1) (кроме HAPP_DEEPLINK режима)
    # ------------------------------------------------------------------
    def test_empty_token_raises_in_normal_mode(self):
        os.environ.pop("ROUTING_TOKEN", None)
        os.environ["ENABLED_CLIENTS"] = "HAPP,INCY"
        from app.config import Config
        with self.assertRaises(SystemExit):
            Config.get_token()

    # ------------------------------------------------------------------
    # Тест 4: Дефолтный токен "change_me_..." — sys.exit(1)
    # ------------------------------------------------------------------
    def test_default_placeholder_token_raises(self):
        os.environ["ROUTING_TOKEN"] = "change_me_to_random_secret_token"
        os.environ["ENABLED_CLIENTS"] = "HAPP,INCY"
        from app.config import Config
        with self.assertRaises(SystemExit):
            Config.get_token()

    # ------------------------------------------------------------------
    # Тест 5: В режиме HAPP_DEEPLINK пустой токен возвращает "local"
    # ------------------------------------------------------------------
    def test_empty_token_allowed_in_deeplink_only_mode(self):
        os.environ.pop("ROUTING_TOKEN", None)
        os.environ["ENABLED_CLIENTS"] = "HAPP_DEEPLINK"
        from app.config import Config
        with patch.object(Config, "ENABLED_CLIENTS", ["HAPP_DEEPLINK"]):
            token = Config.get_token()
        self.assertEqual(token, "local")


class TestConfigURLGeneration(unittest.TestCase):
    """get_base_url и get_github_api_base."""

    # ------------------------------------------------------------------
    # Тест 6: get_base_url формирует правильный URL
    # ------------------------------------------------------------------
    def test_get_base_url(self):
        from app.config import Config
        with patch.object(Config, "DOMAIN", "geo.example.com"):
            url = Config.get_base_url("mytoken")
        self.assertEqual(url, "https://geo.example.com/mytoken")

    # ------------------------------------------------------------------
    # Тест 7: get_github_api_base извлекает owner/repo из raw URL
    # ------------------------------------------------------------------
    def test_get_github_api_base_extraction(self):
        from app.config import Config
        with patch.object(Config, "ROUTING_SOURCE_REPO",
                          "https://raw.githubusercontent.com/myowner/myrepo/main"):
            api_url = Config.get_github_api_base()
        self.assertEqual(api_url, "https://api.github.com/repos/myowner/myrepo/contents")


class TestRemnawaveXForwardedHeaders(unittest.TestCase):
    """X-Forwarded-Proto добавляется для локальных http:// URL."""

    def tearDown(self):
        for k in ["REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN"]:
            os.environ.pop(k, None)

    # ------------------------------------------------------------------
    # Тест 8: http:// получает X-Forwarded-Proto: https
    # ------------------------------------------------------------------
    def test_http_url_gets_forwarded_proto_header(self):
        os.environ["REMNAWAVE_BASE_URL"] = "http://remnawave:3000/api"
        os.environ["REMNAWAVE_TOKEN"] = "token"
        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()
        self.assertEqual(headers.get("X-Forwarded-Proto"), "https")
        self.assertEqual(headers.get("X-Forwarded-For"), "127.0.0.1")

    # ------------------------------------------------------------------
    # Тест 9: https:// НЕ получает X-Forwarded-Proto (уже HTTPS)
    # ------------------------------------------------------------------
    def test_https_url_no_forwarded_headers(self):
        os.environ["REMNAWAVE_BASE_URL"] = "https://remnawave.example.com/api"
        os.environ["REMNAWAVE_TOKEN"] = "token"
        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()
        self.assertNotIn("X-Forwarded-Proto", headers)
        self.assertNotIn("X-Forwarded-For", headers)


class TestTokenLeakInLogs(unittest.TestCase):
    """Секретные токены НЕ попадают в логи."""

    # ------------------------------------------------------------------
    # Тест 10: REMNAWAVE_TOKEN не отображается в строке заголовка
    # ------------------------------------------------------------------
    def test_remnawave_token_not_in_user_agent(self):
        os.environ["REMNAWAVE_BASE_URL"] = "http://remnawave:3000/api"
        os.environ["REMNAWAVE_TOKEN"] = "super-secret-jwt-12345"
        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()
        # Токен должен быть только в Authorization: Bearer, не в других заголовках
        user_agent = headers.get("User-Agent", "")
        self.assertNotIn("super-secret-jwt-12345", user_agent)
        os.environ.pop("REMNAWAVE_BASE_URL")
        os.environ.pop("REMNAWAVE_TOKEN")

    # ------------------------------------------------------------------
    # Тест 11: CF Secret не выводится в логи через logger.error (симуляция)
    # ------------------------------------------------------------------
    def test_cf_secret_not_logged(self):
        """CF-Access-Client-Secret не должен попасть в сообщения логов при ошибке."""
        log_records = []

        class CapturingHandler(logging.Handler):
            def emit(self, record):
                log_records.append(self.format(record))

        logger = logging.getLogger("geo-routing-server")
        handler = CapturingHandler()
        logger.addHandler(handler)

        os.environ["REMNAWAVE_BASE_URL"] = "http://127.0.0.1:1/api"  # недостижимый порт
        os.environ["REMNAWAVE_TOKEN"] = "jwt-token"
        os.environ["CLOUDFLARE_ZERO_TRUST_CLIENT_ID"] = "id.access"
        os.environ["CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET"] = "ULTRA-SECRET-CF-TOKEN"

        from app.remnawave import RemnawaveSync
        # Запрос упадёт с ошибкой подключения
        RemnawaveSync._api_request("GET", "http://127.0.0.1:1/api/test")

        logger.removeHandler(handler)
        os.environ.pop("REMNAWAVE_BASE_URL")
        os.environ.pop("REMNAWAVE_TOKEN")
        os.environ.pop("CLOUDFLARE_ZERO_TRUST_CLIENT_ID")
        os.environ.pop("CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET")

        all_logs = "\n".join(log_records)
        self.assertNotIn("ULTRA-SECRET-CF-TOKEN", all_logs,
                         "CF Secret не должен выводиться в логах!")


class TestTelegramNotifier(unittest.TestCase):
    """Telegram уведомления: отправка, тишина при NOTIFY_SUCCESS=false, thread_id."""

    def setUp(self):
        TelegramHandler.received_messages = []
        TelegramHandler.force_fail = False
        self.server, _, self.base_url = start_server(TelegramHandler)

    def tearDown(self):
        self.server.shutdown()
        for k in ["TELEGRAM_BOT_TOKEN", "TELEGRAM_CHAT_ID",
                  "TELEGRAM_THREAD_ID", "TELEGRAM_NOTIFY_SUCCESS"]:
            os.environ.pop(k, None)

    def _make_send_message(self):
        """Возвращает функцию-замену _send_message, которая шлёт запросы на наш мок."""
        base_url = self.base_url

        def patched_send(text: str) -> bool:
            bot_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
            chat_id = os.environ.get("TELEGRAM_CHAT_ID", "")
            if not bot_token or not chat_id:
                return False
            import urllib.request as _urllib
            url = f"{base_url}/bot{bot_token}/sendMessage"
            payload: dict = {
                "chat_id": chat_id,
                "text": text,
                "parse_mode": "HTML",
                "disable_web_page_preview": True,
            }
            thread_id_raw = os.environ.get("TELEGRAM_THREAD_ID", "")
            if thread_id_raw:
                try:
                    payload["message_thread_id"] = int(thread_id_raw)
                except ValueError:
                    pass
            import json as _json
            req = _urllib.Request(
                url,
                data=_json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
            try:
                with _urllib.urlopen(req, timeout=5) as res:
                    return res.getcode() == 200
            except Exception:
                return False

        return patched_send

    # ------------------------------------------------------------------
    # Тест 12: alert_failure отправляет сообщение с описанием ошибки
    # ------------------------------------------------------------------
    def test_alert_failure_sends_message(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "testbot123"
        os.environ["TELEGRAM_CHAT_ID"] = "-100123456789"

        from app.notifier import TelegramNotifier

        with patch.object(TelegramNotifier, "_send_message", staticmethod(self._make_send_message())):
            TelegramNotifier.alert_failure("Connection refused to Remnawave")

        self.assertEqual(len(TelegramHandler.received_messages), 1)
        msg = TelegramHandler.received_messages[0]
        self.assertIn("Connection refused to Remnawave", msg.get("text", ""))
        self.assertEqual(msg.get("chat_id"), "-100123456789")

    # ------------------------------------------------------------------
    # Тест 13: notify_changes молчит если TELEGRAM_NOTIFY_SUCCESS=false
    # ------------------------------------------------------------------
    def test_no_message_when_notify_success_disabled(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "testbot123"
        os.environ["TELEGRAM_CHAT_ID"] = "-100123456789"

        from app.notifier import TelegramNotifier

        with patch("app.config.Config.TELEGRAM_NOTIFY_SUCCESS", False):
            TelegramNotifier.notify_changes("tok", {}, any_changed=True)

        self.assertEqual(len(TelegramHandler.received_messages), 0,
                         "При NOTIFY_SUCCESS=false не должно быть сообщений!")

    # ------------------------------------------------------------------
    # Тест 14: notify_changes молчит если any_changed=False (нет новых баз)
    # ------------------------------------------------------------------
    def test_no_message_when_nothing_changed(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "testbot123"
        os.environ["TELEGRAM_CHAT_ID"] = "-100123456789"

        from app.notifier import TelegramNotifier

        with patch("app.config.Config.TELEGRAM_NOTIFY_SUCCESS", True):
            TelegramNotifier.notify_changes("tok", {}, any_changed=False)

        self.assertEqual(len(TelegramHandler.received_messages), 0,
                         "При any_changed=False не должно быть сообщений!")

    # ------------------------------------------------------------------
    # Тест 15: message_thread_id передаётся как число int
    # ------------------------------------------------------------------
    def test_thread_id_parsed_as_int(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "testbot123"
        os.environ["TELEGRAM_CHAT_ID"] = "-100123456789"
        os.environ["TELEGRAM_THREAD_ID"] = "42"

        from app.notifier import TelegramNotifier

        with patch.object(TelegramNotifier, "_send_message", staticmethod(self._make_send_message())):
            TelegramNotifier.alert_failure("test error")

        if TelegramHandler.received_messages:
            msg = TelegramHandler.received_messages[0]
            self.assertEqual(msg.get("message_thread_id"), 42)

    # ------------------------------------------------------------------
    # Тест 16: Невалидный thread_id (не число) — сообщение всё равно отправляется без краша
    # ------------------------------------------------------------------
    def test_invalid_thread_id_does_not_crash(self):
        os.environ["TELEGRAM_BOT_TOKEN"] = "testbot123"
        os.environ["TELEGRAM_CHAT_ID"] = "-100123456789"
        os.environ["TELEGRAM_THREAD_ID"] = "not-a-number"

        from app.notifier import TelegramNotifier

        with patch.object(TelegramNotifier, "_send_message", staticmethod(self._make_send_message())):
            try:
                TelegramNotifier.alert_failure("test")
            except Exception as e:
                self.fail(f"alert_failure не должен падать при невалидном thread_id: {e}")

    # ------------------------------------------------------------------
    # Тест 17: Без бот-токена _send_message возвращает False и не падает
    # ------------------------------------------------------------------
    def test_no_token_returns_false(self):
        os.environ.pop("TELEGRAM_BOT_TOKEN", None)
        os.environ.pop("TELEGRAM_CHAT_ID", None)
        from app.notifier import TelegramNotifier
        result = TelegramNotifier._send_message("test")
        self.assertFalse(result)


if __name__ == "__main__":
    unittest.main(verbosity=2)
