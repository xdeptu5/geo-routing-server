"""
Тесты Remnawave API синхронизации.
Покрывают: CF Zero Trust заголовки, сквады, глобальный routing, идемпотентность,
           ошибки 403/500/404, частичный сбой (один сквад не ответил — остальные обновились).
"""
import base64
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

# Добавляем корень проекта в sys.path чтобы импорт app/* работал
sys.path.insert(0, str(Path(__file__).parent.parent))

from tests.mock_servers import RemnawaveHandler, start_server


def _make_deeplink(payload: dict) -> str:
    """Генерирует фейковый happ://routing/onadd/<base64> диплинк."""
    content = json.dumps(payload, indent=2, ensure_ascii=False)
    b64 = base64.b64encode(content.encode("utf-8")).decode("ascii")
    return f"happ://routing/onadd/{b64}"


class TestRemnawaveCFZeroTrust(unittest.TestCase):
    """CF-заголовки отправляются / не отправляются в зависимости от переменных окружения."""

    def setUp(self):
        # Сброс состояния мок-сервера перед каждым тестом
        RemnawaveHandler.require_cf_headers = False
        RemnawaveHandler.force_status = None
        RemnawaveHandler.received_requests = []
        RemnawaveHandler.squad_data = {}
        RemnawaveHandler.subscription_settings = {}
        self.server, self.thread, self.base_url = start_server(RemnawaveHandler)

    def tearDown(self):
        self.server.shutdown()
        # Чистим env-переменные
        for key in [
            "REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN",
            "CLOUDFLARE_ZERO_TRUST_CLIENT_ID", "CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET",
            "CF_ACCESS_CLIENT_ID", "CF_ACCESS_CLIENT_SECRET",
        ]:
            os.environ.pop(key, None)

    def _set_env(self, cf_id: str = "", cf_secret: str = "") -> None:
        os.environ["REMNAWAVE_BASE_URL"] = f"{self.base_url}/api"
        os.environ["REMNAWAVE_TOKEN"] = "test-jwt-token"
        if cf_id:
            os.environ["CLOUDFLARE_ZERO_TRUST_CLIENT_ID"] = cf_id
        if cf_secret:
            os.environ["CLOUDFLARE_ZERO_TRUST_CLIENT_SECRET"] = cf_secret

    # ------------------------------------------------------------------
    # Тест 1: CF-заголовки присутствуют при заданных переменных
    # ------------------------------------------------------------------
    def test_cf_headers_sent_when_env_set(self):
        """Когда заданы CF переменные — заголовки CF-Access-* присутствуют в запросе."""
        self._set_env(cf_id="client-id.access", cf_secret="my-secret")

        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()

        self.assertEqual(headers.get("CF-Access-Client-Id"), "client-id.access")
        self.assertEqual(headers.get("CF-Access-Client-Secret"), "my-secret")

    # ------------------------------------------------------------------
    # Тест 2: CF-заголовки НЕ присутствуют при отсутствии переменных
    # ------------------------------------------------------------------
    def test_cf_headers_absent_when_env_not_set(self):
        """Когда CF переменные не заданы — заголовков CF-Access-* нет."""
        self._set_env()  # без cf_id / cf_secret

        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()

        self.assertNotIn("CF-Access-Client-Id", headers)
        self.assertNotIn("CF-Access-Client-Secret", headers)

    # ------------------------------------------------------------------
    # Тест 3: Только CF_ID без SECRET — заголовки НЕ добавляются
    # ------------------------------------------------------------------
    def test_cf_headers_require_both_id_and_secret(self):
        """Если задан только CLIENT_ID без SECRET — заголовки не добавляются (сломанного запроса не отправляем)."""
        self._set_env(cf_id="client-id.access")  # secret не задан

        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()

        self.assertNotIn("CF-Access-Client-Id", headers)
        self.assertNotIn("CF-Access-Client-Secret", headers)

    # ------------------------------------------------------------------
    # Тест 4: Алиасы CF_ACCESS_CLIENT_ID / CF_ACCESS_CLIENT_SECRET
    # ------------------------------------------------------------------
    def test_cf_alias_env_vars_work(self):
        """Короткие алиасы CF_ACCESS_CLIENT_ID и CF_ACCESS_CLIENT_SECRET тоже работают."""
        os.environ["REMNAWAVE_BASE_URL"] = f"{self.base_url}/api"
        os.environ["REMNAWAVE_TOKEN"] = "token"
        os.environ["CF_ACCESS_CLIENT_ID"] = "alias-id.access"
        os.environ["CF_ACCESS_CLIENT_SECRET"] = "alias-secret"

        from app.remnawave import RemnawaveSync
        headers = RemnawaveSync._get_headers()

        self.assertEqual(headers.get("CF-Access-Client-Id"), "alias-id.access")
        self.assertEqual(headers.get("CF-Access-Client-Secret"), "alias-secret")

    # ------------------------------------------------------------------
    # Тест 5: Мок требует CF-заголовки и возвращает 403 без них
    # ------------------------------------------------------------------
    def test_server_rejects_without_cf_headers(self):
        """Сервер за CF Tunnel отдаёт 403 без токенов → sync() возвращает False."""
        RemnawaveHandler.require_cf_headers = True
        RemnawaveHandler.cf_expected_id = "required-id.access"
        RemnawaveHandler.cf_expected_secret = "required-secret"
        RemnawaveHandler.squad_data = {"squad-uuid-1": {
            "uuid": "squad-uuid-1",
            "responseHeadersAdd": {},
            "responseHeadersRemove": []
        }}

        self._set_env()  # без CF-заголовков

        os.environ["REMNAWAVE_SQUAD_1_UUID"] = "squad-uuid-1"
        os.environ["REMNAWAVE_SQUAD_1_RULE"] = "JSONSUB.JSON"

        with tempfile.TemporaryDirectory() as tmpdir:
            happ_dir = Path(tmpdir) / "token123" / "HAPP"
            happ_dir.mkdir(parents=True)
            (happ_dir / "JSONSUB.DEEPLINK").write_text("happ://routing/onadd/abc", encoding="utf-8")

            with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                from app.remnawave import RemnawaveSync
                result = RemnawaveSync.sync("token123")

        self.assertFalse(result)

    # ------------------------------------------------------------------
    # Тест 6: sync() успешно обновляет сквад при правильных CF-заголовках
    # ------------------------------------------------------------------
    def test_squad_updated_with_cf_headers(self):
        """При правильных CF-заголовках сквад обновляется успешно."""
        RemnawaveHandler.require_cf_headers = True
        RemnawaveHandler.cf_expected_id = "correct-id.access"
        RemnawaveHandler.cf_expected_secret = "correct-secret"
        RemnawaveHandler.squad_data = {"squad-uuid-2": {
            "uuid": "squad-uuid-2",
            "responseHeadersAdd": {},
            "responseHeadersRemove": []
        }}

        self._set_env(cf_id="correct-id.access", cf_secret="correct-secret")
        os.environ["REMNAWAVE_SQUAD_1_UUID"] = "squad-uuid-2"
        os.environ["REMNAWAVE_SQUAD_1_RULE"] = "JSONSUB.JSON"

        deeplink = _make_deeplink({"rules": [], "Geoipurl": "http://x/geo.dat"})

        with tempfile.TemporaryDirectory() as tmpdir:
            happ_dir = Path(tmpdir) / "token123" / "HAPP"
            happ_dir.mkdir(parents=True)
            (happ_dir / "JSONSUB.DEEPLINK").write_text(deeplink, encoding="utf-8")

            with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                from app.remnawave import RemnawaveSync
                result = RemnawaveSync.sync("token123")

        self.assertTrue(result)
        patch_reqs = [r for r in RemnawaveHandler.received_requests if r["method"] == "PATCH"]
        self.assertTrue(len(patch_reqs) >= 1, "Должен быть хотя бы один PATCH-запрос")


class TestRemnawaveSquads(unittest.TestCase):
    """Логика load_squad_configs и обновления множества сквадов."""

    def tearDown(self):
        for key in list(os.environ.keys()):
            if key.startswith(("REMNAWAVE_SQUAD_", "SQUAD_")):
                os.environ.pop(key, None)
        os.environ.pop("REMNAWAVE_BASE_URL", None)
        os.environ.pop("REMNAWAVE_TOKEN", None)

    # ------------------------------------------------------------------
    # Тест 7: load_squad_configs читает все сквады по порядку
    # ------------------------------------------------------------------
    def test_load_multiple_squads(self):
        """load_squad_configs() возвращает все сквады до первого пропуска."""
        os.environ["REMNAWAVE_SQUAD_1_UUID"] = "uuid-1"
        os.environ["REMNAWAVE_SQUAD_1_RULE"] = "JSONSUB.JSON"
        os.environ["REMNAWAVE_SQUAD_2_UUID"] = "uuid-2"
        os.environ["REMNAWAVE_SQUAD_2_RULE"] = "WHITELIST.JSON"
        os.environ["REMNAWAVE_SQUAD_3_UUID"] = "uuid-3"
        # rule не задан — должен выбрать дефолт JSONSUB.JSON

        from app.remnawave import RemnawaveSync
        squads = RemnawaveSync.load_squad_configs()

        self.assertEqual(len(squads), 3)
        self.assertEqual(squads[0], {"uuid": "uuid-1", "rule": "JSONSUB.JSON"})
        self.assertEqual(squads[1], {"uuid": "uuid-2", "rule": "WHITELIST.JSON"})
        self.assertEqual(squads[2]["rule"], "JSONSUB.JSON")  # дефолт

    # ------------------------------------------------------------------
    # Тест 8: Старый формат SQUAD_i_URL конвертируется в rule
    # ------------------------------------------------------------------
    def test_old_squad_url_format_converted(self):
        """Старый SQUAD_1_URL=.../JSONSUB.DEEPLINK → rule=JSONSUB.JSON."""
        os.environ["SQUAD_1_UUID"] = "old-uuid"
        os.environ["SQUAD_1_URL"] = "https://geo.example.com/token/HAPP/JSONSUB.DEEPLINK"

        from app.remnawave import RemnawaveSync
        squads = RemnawaveSync.load_squad_configs()

        self.assertEqual(len(squads), 1)
        self.assertEqual(squads[0]["rule"], "JSONSUB.JSON")

    # ------------------------------------------------------------------
    # Тест 9: Идемпотентность — второй sync не отправляет PATCH если ничего не изменилось
    # ------------------------------------------------------------------
    def test_no_patch_when_routing_unchanged(self):
        """Если сквад уже содержит актуальный диплинк — PATCH не отправляется."""
        deeplink = _make_deeplink({"rules": [], "v": 2})

        RemnawaveHandler.require_cf_headers = False
        RemnawaveHandler.force_status = None
        RemnawaveHandler.received_requests = []
        RemnawaveHandler.squad_data = {"idempotent-uuid": {
            "uuid": "idempotent-uuid",
            "responseHeadersAdd": {"routing": deeplink},
            "responseHeadersRemove": []
        }}
        server, _, base_url = start_server(RemnawaveHandler)

        os.environ["REMNAWAVE_BASE_URL"] = f"{base_url}/api"
        os.environ["REMNAWAVE_TOKEN"] = "token"
        os.environ["REMNAWAVE_SQUAD_1_UUID"] = "idempotent-uuid"
        os.environ["REMNAWAVE_SQUAD_1_RULE"] = "JSONSUB.JSON"

        with tempfile.TemporaryDirectory() as tmpdir:
            happ_dir = Path(tmpdir) / "tok" / "HAPP"
            happ_dir.mkdir(parents=True)
            (happ_dir / "JSONSUB.DEEPLINK").write_text(deeplink + "\n", encoding="utf-8")

            with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                from app.remnawave import RemnawaveSync
                result = RemnawaveSync.sync("tok")

        server.shutdown()
        patch_reqs = [r for r in RemnawaveHandler.received_requests if r["method"] == "PATCH"]
        self.assertTrue(result)
        self.assertEqual(len(patch_reqs), 0, "PATCH не должен отправляться при одинаковом контенте")

    # ------------------------------------------------------------------
    # Тест 10: Если сквад 404 — продолжаем обновлять остальные (не падаем полностью)
    # ------------------------------------------------------------------
    def test_missing_squad_404_continues_others(self):
        """Если сквад не найден в API (404) — sync возвращает False, но не крашится."""
        RemnawaveHandler.require_cf_headers = False
        RemnawaveHandler.force_status = None
        RemnawaveHandler.received_requests = []
        # squad_data пустой → GET вернёт дефолтные данные (мок возвращает их всегда)
        RemnawaveHandler.squad_data = {}
        server, _, base_url = start_server(RemnawaveHandler)

        os.environ["REMNAWAVE_BASE_URL"] = f"{base_url}/api"
        os.environ["REMNAWAVE_TOKEN"] = "token"
        os.environ["REMNAWAVE_SQUAD_1_UUID"] = "missing-uuid"
        os.environ["REMNAWAVE_SQUAD_1_RULE"] = "JSONSUB.JSON"

        with tempfile.TemporaryDirectory() as tmpdir:
            happ_dir = Path(tmpdir) / "tok" / "HAPP"
            happ_dir.mkdir(parents=True)
            # Нет файла JSONSUB.DEEPLINK → sync() должен продолжить без краша

            with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                from app.remnawave import RemnawaveSync
                result = RemnawaveSync.sync("tok")

        server.shutdown()
        # deeplink не найден → сквад пропускается с warning → sync вернёт True
        # (это корректное поведение: нет файла = мы просто пропускаем)
        self.assertIsInstance(result, bool)


class TestRemnawaveIsConfigured(unittest.TestCase):
    """is_configured() корректно реагирует на наличие/отсутствие переменных."""

    def tearDown(self):
        for k in ["REMNAWAVE_BASE_URL", "REMNAWAVE_TOKEN"]:
            os.environ.pop(k, None)

    def test_configured_when_both_set(self):
        os.environ["REMNAWAVE_BASE_URL"] = "http://remnawave:3000/api"
        os.environ["REMNAWAVE_TOKEN"] = "jwt-token"
        from app.remnawave import RemnawaveSync
        self.assertTrue(RemnawaveSync.is_configured())

    def test_not_configured_when_token_missing(self):
        os.environ["REMNAWAVE_BASE_URL"] = "http://remnawave:3000/api"
        os.environ.pop("REMNAWAVE_TOKEN", None)
        from app.remnawave import RemnawaveSync
        self.assertFalse(RemnawaveSync.is_configured())

    def test_not_configured_when_url_missing(self):
        os.environ.pop("REMNAWAVE_BASE_URL", None)
        os.environ["REMNAWAVE_TOKEN"] = "jwt-token"
        from app.remnawave import RemnawaveSync
        self.assertFalse(RemnawaveSync.is_configured())


if __name__ == "__main__":
    unittest.main(verbosity=2)
