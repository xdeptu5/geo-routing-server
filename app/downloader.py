import json
import logging
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Optional

logger = logging.getLogger("geo-routing-server")

class DownloadError(Exception):
    """Ошибка загрузки данных."""
    pass

class Downloader:
    """HTTP-загрузчик с поддержкой ETag-кэширования, повторных попыток и валидации."""
    
    def __init__(self, cache_dir: Path, timeout: int = 60, max_retries: int = 3):
        self.cache_dir = cache_dir
        self.timeout = timeout
        self.max_retries = max_retries
        self.cache_dir.mkdir(parents=True, exist_ok=True)
        
    def _validate_content(self, content: bytes, kind: str) -> bool:
        if not content:
            return False
            
        if kind == "json":
            try:
                json.loads(content.decode("utf-8"))
                return True
            except Exception:
                return False
                
        if kind == "binary":
            # Проверяем минимальный размер и отсутствие HTML ошибок
            if len(content) < 1024:
                return False
            snippet = content[:512].lower()
            if b"<!doctype" in snippet or b"<html" in snippet:
                return False
            return True
            
        return True

    def fetch(self, url: str, cache_key: str, kind: str = "binary") -> bytes:
        """
        Загружает данные по URL с использованием ETag кэша.
        Возвращает байтовое содержимое файла.
        """
        safe_cache_key = cache_key.replace("/", "_")
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
        for attempt in range(1, self.max_retries + 1):
            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=self.timeout) as response:
                    status = response.getcode()
                    res_headers = response.headers
                    body = response.read()
                    
                    if status == 200:
                        if not self._validate_content(body, kind):
                            raise DownloadError(f"Downloaded content from {url} failed validation ({kind})")
                            
                        # Обновляем кэш
                        cache_body_file.write_bytes(body)
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
                    raise DownloadError(f"HTTP 304 received from {url}, but cache is missing or invalid")
                else:
                    last_error = f"HTTP {e.code}: {e.reason}"
            except Exception as e:
                last_error = str(e)
                
            time.sleep(attempt * 1.5)
            
        raise DownloadError(f"Failed to download {url} after {self.max_retries} attempts. Last error: {last_error}")
