import hashlib
import logging
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Tuple, Union

logger = logging.getLogger("geo-routing-server")

# Кэш SHA-256 по (путь, размер, mtime_ns): не перечитываем geo-базы (десятки МБ) на каждом прогоне
_sha256_cache: Dict[str, Tuple[int, int, str]] = {}

@dataclass
class PublishedFileInfo:
    filename: str
    size_bytes: int
    sha256: str
    is_updated: bool

class Publisher:
    """Атомарная публикация файлов и управление правами доступа."""
    
    # Хранилище информации об опубликованных в текущей сессии файлах
    published_registry: Dict[str, PublishedFileInfo] = {}
    any_file_changed: bool = False

    @classmethod
    def reset_session(cls) -> None:
        cls.published_registry.clear()
        cls.any_file_changed = False

    @staticmethod
    def ensure_dir(path: Path) -> None:
        """Создает директорию и выставляет права 0755."""
        path.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(path, 0o755)
        except Exception:
            pass

    @staticmethod
    def _sha256_file(path: Path) -> str:
        """SHA-256 файла. Кэшируется по (размер, mtime_ns): файл перечитывается только если он менялся."""
        cache_key = str(path)
        stat = None
        try:
            stat = path.stat()
            cached = _sha256_cache.get(cache_key)
            if cached is not None and cached[0] == stat.st_size and cached[1] == stat.st_mtime_ns:
                return cached[2]
        except OSError:
            # Не смогли получить stat — хешируем как раньше, без кэша
            stat = None

        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        hexdigest = digest.hexdigest()
        if stat is not None:
            _sha256_cache[cache_key] = (stat.st_size, stat.st_mtime_ns, hexdigest)
        return hexdigest

    @classmethod
    def publish_file(cls, dest_dir: Path, filename: str, content: Union[str, bytes]) -> bool:
        """
        Атомарно публикует файл:
        - Проверяет безопасность пути назначения (защита от path traversal)
        - Проверяет изменения через stat() и sha256 фактического файла
        - Записывает во временный файл в целевой директории
        - Выполняет fsync для исключения повреждения данных при сбоях питания
        - Выставляет права 0644
        - Атомарно перемещает (os.replace)
        """
        cls.ensure_dir(dest_dir)
        target_path = (dest_dir / filename).resolve()
        
        # Защита от Path Traversal
        try:
            if not target_path.is_relative_to(dest_dir.resolve()):
                logger.error(f"Refusing to publish outside dest_dir: {filename}")
                return False
        except AttributeError:
            # Python < 3.9 fallback
            if not str(target_path).startswith(str(dest_dir.resolve())):
                logger.error(f"Refusing to publish outside dest_dir: {filename}")
                return False
        
        raw_data = content.encode("utf-8") if isinstance(content, str) else content
        if not raw_data:
            logger.error(f"Refusing to publish empty file: {filename}")
            return False
            
        sha256_hash = hashlib.sha256(raw_data).hexdigest()
        is_updated = True

        # Если файл уже существует и идентичен, не меняем mtime
        if target_path.is_file():
            try:
                # 1. Быстрая проверка: если размер отличается, файл изменился
                if target_path.stat().st_size != len(raw_data):
                    is_updated = True
                else:
                    # Sidecar может отстать после частичного сбоя записи пары файлов.
                    is_updated = cls._sha256_file(target_path) != sha256_hash
            except Exception:
                is_updated = True

        if is_updated:
            # mkstemp может упасть (например, в имени файла есть подкаталог) — возвращаем False, а не исключение
            try:
                temp_fd, temp_path = tempfile.mkstemp(prefix=f".{filename}.", dir=str(dest_dir))
            except Exception as e:
                logger.error(f"Failed to create temp file for {filename}: {e}")
                return False
            try:
                with os.fdopen(temp_fd, "wb") as f:
                    f.write(raw_data)
                    f.flush()
                    os.fsync(f.fileno())
                os.chmod(temp_path, 0o644)
                os.replace(temp_path, target_path)
                # Файл только что записан — кладем его хеш в кэш, чтобы не перечитывать заново
                try:
                    st = target_path.stat()
                    _sha256_cache[str(target_path)] = (st.st_size, st.st_mtime_ns, sha256_hash)
                except OSError:
                    pass
                logger.info(f"  Updated: {filename}")
                cls.any_file_changed = True
            except Exception as e:
                logger.error(f"Failed to publish {filename}: {e}")
                if os.path.exists(temp_path):
                    try:
                        os.unlink(temp_path)
                    except Exception:
                        pass
                return False
        else:
            logger.debug(f"  Unchanged: {filename}")

        file_key = f"{dest_dir.name}/{filename}"
        cls.published_registry[file_key] = PublishedFileInfo(
            filename=filename,
            size_bytes=len(raw_data),
            sha256=sha256_hash,
            is_updated=is_updated
        )
        return True
