"""Чтение и правка .env с сохранением комментариев и порядка строк.

Файл правится из разового контейнера, в который каталог установки смонтирован
целиком (не файлом), поэтому атомарная запись через временный файл и rename
работает и видна на хосте.
"""

import os
import re
import shutil
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

_KEY_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def _format_value(value: str) -> str:
    """Кавычки ставятся только там, где без них Compose разберёт значение иначе.

    В env_file Compose подставляет переменные в значения без кавычек и в
    двойных кавычках, а ' #' начинает комментарий. Значение в одинарных
    кавычках берётся буквально, поэтому оно предпочтительно; двойные — только
    если в значении есть сама одинарная кавычка ('$' тогда удваивается).
    """
    value = value.replace("\r", "").split("\n", 1)[0]
    needs_quotes = (
        value != value.strip()
        or " #" in value
        or value.startswith("#")
        or value[:1] in ("'", '"')
        or "$" in value
    )
    if not needs_quotes:
        return value
    if "'" not in value:
        return f"'{value}'"
    escaped = value.replace("\\", "\\\\").replace('"', '\\"').replace("$", "$$")
    return f'"{escaped}"'


class EnvFile:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.lines: List[str] = []
        if self.path.is_file():
            self.lines = self.path.read_text(encoding="utf-8-sig").splitlines()
        self.changed = False

    @property
    def exists(self) -> bool:
        return self.path.is_file()

    def _index(self, key: str) -> List[int]:
        found = []
        for i, line in enumerate(self.lines):
            m = _KEY_RE.match(line)
            if m and m.group(1) == key:
                found.append(i)
        return found

    def get(self, key: str, default: str = "") -> str:
        idx = self._index(key)
        if not idx:
            return default
        raw = _KEY_RE.match(self.lines[idx[0]]).group(2).strip()
        if raw[:1] not in ("'", '"') and " #" in raw:
            # как и Compose: в значении без кавычек ' #' начинает комментарий
            raw = raw.split(" #", 1)[0].rstrip()
        value = _unquote(raw)
        if len(raw) >= 2 and raw[0] == raw[-1] == '"':
            value = value.replace("$$", "$").replace('\\"', '"').replace("\\\\", "\\")
        return value if value != "" else default

    def as_dict(self) -> Dict[str, str]:
        result: Dict[str, str] = {}
        for line in self.lines:
            m = _KEY_RE.match(line)
            if m and m.group(1) not in result:
                result[m.group(1)] = self.get(m.group(1))
        return result

    def set(self, key: str, value: str) -> None:
        """Заменяет первое вхождение и удаляет дубли ключа."""
        new_line = f"{key}={_format_value(str(value))}"
        idx = self._index(key)
        if not idx:
            self.lines.append(new_line)
            self.changed = True
            return
        if self.lines[idx[0]] != new_line or len(idx) > 1:
            self.changed = True
        self.lines[idx[0]] = new_line
        for i in reversed(idx[1:]):
            del self.lines[i]

    def delete(self, key: str) -> None:
        idx = self._index(key)
        for i in reversed(idx):
            del self.lines[i]
        if idx:
            self.changed = True

    def backup(self) -> Optional[Path]:
        if not self.exists:
            return None
        target = self.path.with_name(f"{self.path.name}.bak.{datetime.now():%Y%m%d-%H%M%S}")
        shutil.copy2(self.path, target)
        return target

    def save(self, mode: int = 0o600) -> None:
        write_atomic(self.path, "\n".join(self.lines).rstrip("\n") + "\n", mode)
        self.changed = False


def write_atomic(path: Path, content: str, mode: int) -> None:
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
