import hashlib
import logging
import os
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional, Union

logger = logging.getLogger("geo-routing-server")

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

    @classmethod
    def publish_file(cls, dest_dir: Path, filename: str, content: Union[str, bytes]) -> bool:
        """
        Атомарно публикует файл:
        - Записывает во временный файл в целевой директории
        - Выставляет права 0644
        - Атомарно перемещает (os.replace)
        """
        cls.ensure_dir(dest_dir)
        target_path = dest_dir / filename
        
        raw_data = content.encode("utf-8") if isinstance(content, str) else content
        if not raw_data:
            logger.error(f"Refusing to publish empty file: {filename}")
            return False
            
        sha256_hash = hashlib.sha256(raw_data).hexdigest()
        is_updated = True

        # Если файл уже существует и идентичен, не меняем mtime
        if target_path.is_file():
            try:
                if target_path.read_bytes() == raw_data:
                    is_updated = False
            except Exception:
                pass

        if is_updated:
            temp_fd, temp_path = tempfile.mkstemp(prefix=f".{filename}.", dir=str(dest_dir))
            try:
                with os.fdopen(temp_fd, "wb") as f:
                    f.write(raw_data)
                os.chmod(temp_path, 0o644)
                os.replace(temp_path, target_path)
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

    @classmethod
    def publish_geo_with_checksum(cls, dest_dir: Path, filename: str, content: bytes) -> bool:
        """Публикует бинарную базу и создает рядом <filename>.sha256."""
        if not cls.publish_file(dest_dir, filename, content):
            return False
            
        checksum = hashlib.sha256(content).hexdigest()
        checksum_filename = f"{filename}.sha256"
        return cls.publish_file(dest_dir, checksum_filename, f"{checksum}\n")
