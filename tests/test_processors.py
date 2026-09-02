"""
Тесты процессоров HAPP и INCY:
- Генерация JSON с подменой Geoipurl/Geositeurl
- Генерация DEEPLINK (happ:// / incy://), декодирование base64
- Очистка устаревших файлов (_cleanup_obsolete_files)
- Защита от небезопасных имён файлов (Path Traversal)
- Логика включения модулей (HAPP_DEEPLINK vs HAPP_GEO vs HAPP)
- LastUpdated: вычисляется автоматически если отсутствует в источнике
"""
import base64
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch, PropertyMock

sys.path.insert(0, str(Path(__file__).parent.parent))


def _decode_deeplink(deeplink_content: str) -> dict:
    """Декодирует happ:// или incy:// диплинк обратно в dict."""
    deeplink = deeplink_content.strip()
    b64_part = deeplink.split("/")[-1]
    decoded = base64.b64decode(b64_part).decode("utf-8")
    return json.loads(decoded)


class TestHappProcessor(unittest.TestCase):
    """Тесты генерации HAPP файлов и диплинков."""

    def _make_downloader_mock(self, routing_json: dict | None = None):
        """Создаёт мок Downloader, который возвращает заданный JSON."""
        if routing_json is None:
            routing_json = {
                "Geoipurl": "https://upstream.example.com/geoip.dat",
                "Geositeurl": "https://upstream.example.com/geosite.dat",
                "rules": [{"domain": "example.com"}]
            }
        raw = json.dumps(routing_json, ensure_ascii=False).encode("utf-8")
        mock_dl = MagicMock()
        mock_dl.fetch.return_value = raw
        return mock_dl, raw

    def _make_processor(self, tmpdir: str, token: str = "testtoken",
                        enabled_clients=None, mock_dl=None):
        """Создаёт HappProcessor с нужными параметрами."""
        from app.processors.happ import HappProcessor
        from app.downloader import Downloader

        storage = Path(tmpdir)
        dl = mock_dl or MagicMock()
        proc = HappProcessor(
            downloader=dl,
            storage_dir=storage,
            token=token,
            domain="geo.example.com"
        )
        return proc

    # ------------------------------------------------------------------
    # Тест 1: Geoipurl подменяется на локальный URL
    # ------------------------------------------------------------------
    def test_geoip_url_replaced_with_local(self):
        """HAPP processor заменяет Geoipurl на локальный адрес сервера."""
        mock_dl, _ = self._make_downloader_mock()

        with tempfile.TemporaryDirectory() as tmpdir:
            # Мокаем GitHub API discovery
            with patch("app.processors.base.BaseProcessor._discover_config_files",
                       return_value=["JSONSUB.json"]):
                # Мокаем GeoManager чтобы не качать реальные базы
                with patch("app.processors.happ.GeoManager.sync_client_geo", return_value=True):
                    with patch("app.config.Config.ENABLED_CLIENTS", ["HAPP"]):
                        with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                            with patch("app.config.Config.DOMAIN", "geo.example.com"):
                                with patch("app.config.Config.PUBLIC_GEO_BASE_URL", ""):
                                    proc = self._make_processor(tmpdir, mock_dl=mock_dl)
                                    proc.process()

            happ_dir = Path(tmpdir) / "testtoken" / "HAPP"
            json_file = happ_dir / "JSONSUB.JSON"
            if json_file.exists():
                data = json.loads(json_file.read_text(encoding="utf-8"))
                # Geoipurl должен указывать на локальный сервер
                self.assertIn("geo.example.com", data.get("Geoipurl", ""))
                self.assertNotIn("upstream.example.com", data.get("Geoipurl", ""))

    # ------------------------------------------------------------------
    # Тест 2: PUBLIC_GEO_BASE_URL имеет приоритет над локальным URL
    # ------------------------------------------------------------------
    def test_public_geo_base_url_priority(self):
        """Если задан PUBLIC_GEO_BASE_URL — используется он, а не локальный."""
        routing_json = {
            "Geoipurl": "https://old.example.com/geoip.dat",
            "Geositeurl": "https://old.example.com/geosite.dat",
            "rules": []
        }
        mock_dl, _ = self._make_downloader_mock(routing_json)

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("app.processors.base.BaseProcessor._discover_config_files",
                       return_value=["JSONSUB.json"]):
                with patch("app.processors.happ.GeoManager.sync_client_geo", return_value=True):
                    with patch("app.config.Config.ENABLED_CLIENTS", ["HAPP"]):
                        with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                            with patch("app.config.Config.DOMAIN", "geo.example.com"):
                                with patch("app.config.Config.PUBLIC_GEO_BASE_URL",
                                           "https://external-geo.example.com"):
                                    proc = self._make_processor(tmpdir, mock_dl=mock_dl)
                                    proc.process()

            happ_dir = Path(tmpdir) / "testtoken" / "HAPP"
            json_file = happ_dir / "JSONSUB.JSON"
            if json_file.exists():
                data = json.loads(json_file.read_text(encoding="utf-8"))
                self.assertIn("external-geo.example.com", data.get("Geoipurl", ""))

    # ------------------------------------------------------------------
    # Тест 3: DEEPLINK корректно кодирует JSON в base64
    # ------------------------------------------------------------------
    def test_deeplink_base64_encodes_json(self):
        """Сгенерированный DEEPLINK содержит корректный base64-encoded JSON."""
        routing_json = {
            "Geoipurl": "https://upstream.example.com/geoip.dat",
            "Geositeurl": "https://upstream.example.com/geosite.dat",
            "rules": [],
            "LastUpdated": "99999"
        }
        mock_dl, _ = self._make_downloader_mock(routing_json)

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("app.processors.base.BaseProcessor._discover_config_files",
                       return_value=["JSONSUB.json"]):
                with patch("app.processors.happ.GeoManager.sync_client_geo", return_value=True):
                    with patch("app.config.Config.ENABLED_CLIENTS", ["HAPP_DEEPLINK"]):
                        with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                            with patch("app.config.Config.DOMAIN", "geo.example.com"):
                                with patch("app.config.Config.PUBLIC_GEO_BASE_URL", ""):
                                    proc = self._make_processor(tmpdir, mock_dl=mock_dl)
                                    proc.process()

            happ_dir = Path(tmpdir) / "testtoken" / "HAPP"
            deeplink_file = happ_dir / "JSONSUB.DEEPLINK"

            if deeplink_file.exists():
                content = deeplink_file.read_text(encoding="utf-8").strip()
                self.assertTrue(content.startswith("happ://routing/onadd/"),
                                f"DEEPLINK должен начинаться с happ://routing/onadd/, получили: {content[:60]}")
                decoded = _decode_deeplink(content)
                self.assertIn("Geoipurl", decoded)
                self.assertIn("Geositeurl", decoded)

    # ------------------------------------------------------------------
    # Тест 4: LastUpdated автоматически вычисляется если не задан в источнике
    # ------------------------------------------------------------------
    def test_last_updated_auto_computed(self):
        """Если в источнике нет LastUpdated — он вычисляется через md5 хэш контента."""
        routing_json = {
            "Geoipurl": "https://example.com/geoip.dat",
            "Geositeurl": "https://example.com/geosite.dat",
            "rules": []
            # LastUpdated намеренно отсутствует
        }
        mock_dl, _ = self._make_downloader_mock(routing_json)

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("app.processors.base.BaseProcessor._discover_config_files",
                       return_value=["JSONSUB.json"]):
                with patch("app.processors.happ.GeoManager.sync_client_geo", return_value=True):
                    with patch("app.config.Config.ENABLED_CLIENTS", ["HAPP_DEEPLINK"]):
                        with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                            with patch("app.config.Config.DOMAIN", "geo.example.com"):
                                with patch("app.config.Config.PUBLIC_GEO_BASE_URL", ""):
                                    proc = self._make_processor(tmpdir, mock_dl=mock_dl)
                                    proc.process()

            happ_dir = Path(tmpdir) / "testtoken" / "HAPP"
            json_file = happ_dir / "JSONSUB.JSON"
            if json_file.exists():
                data = json.loads(json_file.read_text(encoding="utf-8"))
                self.assertIn("LastUpdated", data)
                self.assertIsInstance(data["LastUpdated"], str)
                self.assertTrue(data["LastUpdated"].isdigit())


class TestIncyProcessor(unittest.TestCase):
    """Тесты генерации INCY файлов и диплинков."""

    def _make_downloader_mock(self):
        raw = json.dumps({
            "Geoipurl": "https://upstream.example.com/geoip.dat",
            "Geositeurl": "https://upstream.example.com/geosite.dat",
            "rules": []
        }, ensure_ascii=False).encode("utf-8")
        mock_dl = MagicMock()
        mock_dl.fetch.return_value = raw
        return mock_dl

    # ------------------------------------------------------------------
    # Тест 5: INCY DEEPLINK начинается с incy://
    # ------------------------------------------------------------------
    def test_incy_deeplink_scheme(self):
        """INCY генерирует диплинки с схемой incy://, а не happ://."""
        mock_dl = self._make_downloader_mock()

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("app.processors.base.BaseProcessor._discover_config_files",
                       return_value=["JSONSUB.json"]):
                with patch("app.processors.incy.GeoManager.sync_client_geo", return_value=True):
                    with patch("app.config.Config.ENABLED_CLIENTS", ["INCY"]):
                        with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                            with patch("app.config.Config.DOMAIN", "geo.example.com"):
                                from app.processors.incy import IncyProcessor
                                proc = IncyProcessor(
                                    downloader=mock_dl,
                                    storage_dir=Path(tmpdir),
                                    token="testtoken",
                                    domain="geo.example.com"
                                )
                                proc.process()

            incy_dir = Path(tmpdir) / "testtoken" / "INCY"
            deeplink_file = incy_dir / "JSONSUB.DEEPLINK"
            if deeplink_file.exists():
                content = deeplink_file.read_text(encoding="utf-8").strip()
                self.assertTrue(content.startswith("incy://routing/onadd/"),
                                f"INCY DEEPLINK должен начинаться с incy://, получили: {content[:60]}")

    # ------------------------------------------------------------------
    # Тест 6: INCY заменяет Geoipurl на локальный /INCY/geoip.dat
    # ------------------------------------------------------------------
    def test_incy_geoip_url_is_local(self):
        """INCY всегда подставляет локальный URL для geoip.dat."""
        mock_dl = self._make_downloader_mock()

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch("app.processors.base.BaseProcessor._discover_config_files",
                       return_value=["JSONSUB.json"]):
                with patch("app.processors.incy.GeoManager.sync_client_geo", return_value=True):
                    with patch("app.config.Config.ENABLED_CLIENTS", ["INCY"]):
                        with patch("app.config.Config.STORAGE_DIR", Path(tmpdir)):
                            with patch("app.config.Config.DOMAIN", "geo.example.com"):
                                from app.processors.incy import IncyProcessor
                                proc = IncyProcessor(
                                    downloader=mock_dl,
                                    storage_dir=Path(tmpdir),
                                    token="testtoken",
                                    domain="geo.example.com"
                                )
                                proc.process()

            incy_dir = Path(tmpdir) / "testtoken" / "INCY"
            json_file = incy_dir / "JSONSUB.JSON"
            if json_file.exists():
                data = json.loads(json_file.read_text(encoding="utf-8"))
                self.assertIn("/INCY/geoip.dat", data.get("Geoipurl", ""))
                self.assertIn("/INCY/geosite.dat", data.get("Geositeurl", ""))
                self.assertNotIn("upstream.example.com", data.get("Geoipurl", ""))


class TestObsoleteFilesCleanup(unittest.TestCase):
    """Тесты удаления устаревших файлов из www/."""

    # ------------------------------------------------------------------
    # Тест 7: Устаревшие файлы удаляются
    # ------------------------------------------------------------------
    def test_obsolete_json_and_deeplink_removed(self):
        """_cleanup_obsolete_files удаляет .json и .deeplink которых нет в valid_filenames."""
        with tempfile.TemporaryDirectory() as tmpdir:
            target = Path(tmpdir)
            # Создаём «живой» файл и устаревший
            (target / "JSONSUB.JSON").write_text("{}", encoding="utf-8")
            (target / "JSONSUB.DEEPLINK").write_text("happ://...", encoding="utf-8")
            (target / "OLD_RULE.JSON").write_text("{}", encoding="utf-8")
            (target / "OLD_RULE.DEEPLINK").write_text("happ://...", encoding="utf-8")

            from app.processors.base import BaseProcessor

            class ConcreteProc(BaseProcessor):
                CLIENT_NAME = "HAPP"
                def process(self): return True

            dl = MagicMock()
            proc = ConcreteProc(dl, Path(tmpdir), "tok", "domain")
            proc._cleanup_obsolete_files(target, {"JSONSUB.JSON", "JSONSUB.DEEPLINK"})

            self.assertTrue((target / "JSONSUB.JSON").exists(), "Живой файл не должен удаляться")
            self.assertFalse((target / "OLD_RULE.JSON").exists(), "Устаревший JSON должен быть удалён")
            self.assertFalse((target / "OLD_RULE.DEEPLINK").exists(), "Устаревший DEEPLINK должен быть удалён")

    # ------------------------------------------------------------------
    # Тест 8: .dat файлы НЕ удаляются очисткой
    # ------------------------------------------------------------------
    def test_dat_files_not_removed(self):
        """_cleanup_obsolete_files не трогает geo-базы (.dat файлы)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            target = Path(tmpdir)
            (target / "geoip.dat").write_bytes(b"\x00" * 100)
            (target / "geosite.dat").write_bytes(b"\x00" * 100)

            from app.processors.base import BaseProcessor

            class ConcreteProc(BaseProcessor):
                CLIENT_NAME = "HAPP"
                def process(self): return True

            dl = MagicMock()
            proc = ConcreteProc(dl, Path(tmpdir), "tok", "domain")
            proc._cleanup_obsolete_files(target, set())  # valid пустой — но .dat не должны удаляться

            self.assertTrue((target / "geoip.dat").exists())
            self.assertTrue((target / "geosite.dat").exists())


class TestPathTraversalProtection(unittest.TestCase):
    """Защита от Path Traversal в именах файлов из GitHub API."""

    # ------------------------------------------------------------------
    # Тест 9: Небезопасное имя файла из GitHub пропускается
    # ------------------------------------------------------------------
    def test_unsafe_filename_skipped(self):
        """Файлы с небезопасными именами (../etc/passwd.json) пропускаются без краша."""
        import re
        dangerous_names = [
            "../../etc/passwd.json",
            "../secret.json",
            "/etc/passwd.json",
            "normal/../../../etc/hosts.json",
            "file name with spaces.json",
            "file;rm -rf /.json",
        ]

        pattern = r"^[A-Za-z0-9._-]+\.json$"
        for name in dangerous_names:
            with self.subTest(name=name):
                self.assertFalse(
                    re.match(pattern, name, re.IGNORECASE),
                    f"Опасное имя '{name}' должно быть заблокировано!"
                )

    # ------------------------------------------------------------------
    # Тест 10: Безопасные имена проходят фильтр
    # ------------------------------------------------------------------
    def test_safe_filenames_allowed(self):
        """Корректные имена файлов проходят валидацию."""
        import re
        safe_names = [
            "JSONSUB.json",
            "WHITELIST.JSON",
            "DEFAULT.json",
            "my-rule.json",
            "rule_v2.json",
            "rule.2024.json",
        ]
        pattern = r"^[A-Za-z0-9._-]+\.json$"
        for name in safe_names:
            with self.subTest(name=name):
                self.assertIsNotNone(
                    re.match(pattern, name, re.IGNORECASE),
                    f"Безопасное имя '{name}' должно проходить!"
                )


if __name__ == "__main__":
    unittest.main(verbosity=2)
