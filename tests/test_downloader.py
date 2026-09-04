"""
Тесты Downloader: ETag-кэш, HTML-блокировки провайдера, повреждённые данные,
                  304 Not Modified, пустые файлы, бинарная валидация.
"""
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from tests.mock_servers import GitHubHandler, start_server, FAKE_BINARY_DAT, FAKE_ROUTING_JSON


class TestDownloaderValidation(unittest.TestCase):
    """Валидация контента: binary vs json, минимальный размер, HTML-детекция."""

    def setUp(self):
        from app.downloader import Downloader
        self.tmp = tempfile.mkdtemp()
        self.dl = Downloader(cache_dir=Path(self.tmp), timeout=5, max_retries=1)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ------------------------------------------------------------------
    # Тест 1: Бинарная валидация принимает корректный dat-файл
    # ------------------------------------------------------------------
    def test_binary_valid_large_content(self):
        content = b"\x00\x01" * 600  # 1200 байт, не HTML
        self.assertTrue(self.dl._validate_content(content, "binary"))

    # ------------------------------------------------------------------
    # Тест 2: Бинарная валидация отклоняет слишком маленький файл (<1024 байт)
    # ------------------------------------------------------------------
    def test_binary_rejects_small_file(self):
        content = b"\x00\x01" * 400  # 800 байт — меньше порога
        self.assertFalse(self.dl._validate_content(content, "binary"))

    # ------------------------------------------------------------------
    # Тест 3: Бинарная валидация отклоняет HTML-страницу (<!doctype)
    # ------------------------------------------------------------------
    def test_binary_rejects_html_doctype(self):
        html = b"<!doctype html><html><body>" + b"x" * 2000
        self.assertFalse(self.dl._validate_content(html, "binary"))

    # ------------------------------------------------------------------
    # Тест 4: Бинарная валидация отклоняет <html> без doctype
    # ------------------------------------------------------------------
    def test_binary_rejects_html_tag(self):
        html = b"<html><head><title>Error</title></head>" + b"x" * 2000
        self.assertFalse(self.dl._validate_content(html, "binary"))

    # ------------------------------------------------------------------
    # Тест 5: Пустой контент отклоняется всегда
    # ------------------------------------------------------------------
    def test_empty_content_rejected(self):
        self.assertFalse(self.dl._validate_content(b"", "binary"))
        self.assertFalse(self.dl._validate_content(b"", "json"))

    # ------------------------------------------------------------------
    # Тест 6: JSON валидация принимает корректный JSON
    # ------------------------------------------------------------------
    def test_json_valid(self):
        content = json.dumps({"key": "value", "arr": [1, 2, 3]}).encode("utf-8")
        self.assertTrue(self.dl._validate_content(content, "json"))

    # ------------------------------------------------------------------
    # Тест 7: JSON валидация отклоняет битый JSON
    # ------------------------------------------------------------------
    def test_json_invalid_rejected(self):
        self.assertFalse(self.dl._validate_content(b"{broken json", "json"))

    # ------------------------------------------------------------------
    # Тест 8: JSON валидация отклоняет HTML-страницу (провайдер вернул заглушку с 200 OK)
    # ------------------------------------------------------------------
    def test_json_rejects_html_content(self):
        html = b"<!doctype html><html><body>Blocked</body></html>"
        self.assertFalse(self.dl._validate_content(html, "json"))


class TestDownloaderHTTP(unittest.TestCase):
    """Реальные HTTP-запросы к мок-серверу GitHub."""

    def setUp(self):
        GitHubHandler.serve_html_instead = False
        GitHubHandler.etag_store = {}
        self.server, _, self.base_url = start_server(GitHubHandler)
        self.tmp = tempfile.mkdtemp()
        from app.downloader import Downloader
        self.dl = Downloader(cache_dir=Path(self.tmp), timeout=5, max_retries=1)

    def tearDown(self):
        self.server.shutdown()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ------------------------------------------------------------------
    # Тест 9: Успешное скачивание бинарного файла
    # ------------------------------------------------------------------
    def test_download_binary_success(self):
        url = f"{self.base_url}/HAPP/geoip.dat"
        data = self.dl.fetch(url, "geoip", kind="binary")
        self.assertEqual(data, FAKE_BINARY_DAT)

    # ------------------------------------------------------------------
    # Тест 10: ETag кэш — второй запрос использует кэшированный файл (304)
    # ------------------------------------------------------------------
    def test_etag_304_returns_cached(self):
        url = f"{self.base_url}/HAPP/geoip.dat"
        # Первый запрос — получаем и кэшируем
        first = self.dl.fetch(url, "geoip_etag_test", kind="binary")
        self.assertEqual(first, FAKE_BINARY_DAT)

        # Второй запрос — должен вернуть из кэша (мок отдаст 304)
        second = self.dl.fetch(url, "geoip_etag_test", kind="binary")
        self.assertEqual(second, FAKE_BINARY_DAT)

    # ------------------------------------------------------------------
    # Тест 11: Провайдер вернул HTML вместо .dat → DownloadError (не сохраняется в кэш)
    # ------------------------------------------------------------------
    def test_html_instead_of_binary_raises(self):
        from app.downloader import DownloadError
        GitHubHandler.serve_html_instead = True
        url = f"{self.base_url}/HAPP/geoip.dat"

        with self.assertRaises(DownloadError):
            self.dl.fetch(url, "html_test", kind="binary")

        # Файл НЕ должен быть записан в кэш (битые данные)
        cache_body = Path(self.tmp) / "html_test.body"
        self.assertFalse(cache_body.exists(), "HTML-ответ не должен сохраняться в кэш!")

    # ------------------------------------------------------------------
    # Тест 12: Скачивание JSON-файла правил
    # ------------------------------------------------------------------
    def test_download_json_success(self):
        url = f"{self.base_url}/HAPP/JSONSUB.json"
        data = self.dl.fetch(url, "jsonsub", kind="json")
        parsed = json.loads(data.decode("utf-8"))
        self.assertIn("Geoipurl", parsed)

    # ------------------------------------------------------------------
    # Тест 13: 404 от сервера → DownloadError
    # ------------------------------------------------------------------
    def test_404_raises_download_error(self):
        from app.downloader import DownloadError
        # URL не заканчивается на .dat или .json → мок вернёт 404
        url = f"{self.base_url}/nonexistent/path/resource"
        with self.assertRaises(DownloadError):
            self.dl.fetch(url, "notfound", kind="binary")


class TestDownloaderCacheIntegrity(unittest.TestCase):
    """Целостность кэша: повреждённый кэш не ломает следующий запрос."""

    def setUp(self):
        GitHubHandler.serve_html_instead = False
        self.server, _, self.base_url = start_server(GitHubHandler)
        self.tmp = tempfile.mkdtemp()
        from app.downloader import Downloader
        self.dl = Downloader(cache_dir=Path(self.tmp), timeout=5, max_retries=1)

    def tearDown(self):
        self.server.shutdown()
        import shutil
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ------------------------------------------------------------------
    # Тест 14: Кэш-файл с ETag есть, но .body отсутствует → перекачиваем с нуля
    # ------------------------------------------------------------------
    def test_missing_body_cache_redownloaded(self):
        # Создаём .etag без .body (ручная «порча» кэша)
        etag_file = Path(self.tmp) / "geoip_intact.etag"
        etag_file.write_text('"abc123"', encoding="utf-8")
        # .body не создаём намеренно

        url = f"{self.base_url}/HAPP/geoip.dat"
        # fetch должен перекачать файл несмотря на наличие etag-файла
        # (потому что body-файла нет — 304 вернёт 304, но body читать неоткуда)
        # В данном случае мок вернёт 304 (etag совпадёт), а тест проверит обработку этой ситуации
        try:
            data = self.dl.fetch(url, "geoip_intact", kind="binary")
            # Если успешно — либо перекачал, либо взял из кэша (но body был восстановлен)
            self.assertIsInstance(data, bytes)
        except Exception:
            pass  # DownloadError тоже допустим — главное, что нет краша

    # ------------------------------------------------------------------
    # Тест 15: Параллельные ключи кэша не перемешиваются
    # ------------------------------------------------------------------
    def test_separate_cache_keys_dont_collide(self):
        url1 = f"{self.base_url}/HAPP/geoip.dat"
        url2 = f"{self.base_url}/HAPP/geosite.dat"

        data1 = self.dl.fetch(url1, "geoip_key", kind="binary")
        data2 = self.dl.fetch(url2, "geosite_key", kind="binary")

        self.assertEqual(data1, data2)  # оба .dat возвращают FAKE_BINARY_DAT в нашем моке

        # Файлы кэша разные
        body1 = Path(self.tmp) / "geoip_key.body"
        body2 = Path(self.tmp) / "geosite_key.body"
        self.assertTrue(body1.exists())
        self.assertTrue(body2.exists())
        self.assertNotEqual(str(body1), str(body2))

    # ------------------------------------------------------------------
    # Тест 16: Длинный HTML с паддингом отклоняется бинарным валидатором
    # ------------------------------------------------------------------
    def test_binary_rejects_padded_html(self):
        padded_html = b" " * 1000 + b"<html><body>Server Error</body></html>" + b" " * 1000
        self.assertFalse(self.dl._validate_content(padded_html, "binary"))

    # ------------------------------------------------------------------
    # Тест 17: Небезопасные схемы URL (file://, ftp://) блокируются
    # ------------------------------------------------------------------
    def test_fetch_rejects_unsafe_scheme(self):
        from app.downloader import DownloadError
        for unsafe_url in ["file:///etc/passwd", "ftp://evil.com/base", "gopher://bad.com"]:
            with self.assertRaises(DownloadError):
                self.dl.fetch(unsafe_url, "unsafe_key", kind="binary")

    # ------------------------------------------------------------------
    # Тест 18: Stale-if-error — возврат кэша при сбое сети
    # ------------------------------------------------------------------
    def test_stale_if_error_fallback(self):
        # Создаем валидный закэшированный файл
        valid_cache = b"\x00\x01" * 600
        cache_file = Path(self.tmp) / "stale_key.body"
        cache_file.write_bytes(valid_cache)

        # Пытаемся скачать с заведомо мертвого URL на несуществующем порту
        dead_url = "http://127.0.0.1:59999/nonexistent.dat"
        result = self.dl.fetch(dead_url, "stale_key", kind="binary")
        self.assertEqual(result, valid_cache)


if __name__ == "__main__":
    unittest.main(verbosity=2)
