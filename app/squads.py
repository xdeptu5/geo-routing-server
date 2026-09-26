"""Модуль управления сквадами Remnawave (squads.json)."""

import json
import logging
import os
import re
import tempfile
from pathlib import Path
from typing import Any, Dict, List, Optional, Union

from app.config import Config

logger = logging.getLogger("geo-routing-server")


def get_default_squads_path() -> Path:
    """Определяет стандартный путь к squads.json:

    1. Переменная окружения SQUADS_FILE (если задана)
    2. Config.BASE_DIR / 'squads.json' (если Config.BASE_DIR существует)
    3. /app/squads.json (если родительская директория /app существует)
    4. squads.json в текущей рабочей директории
    """
    env_path = os.getenv("SQUADS_FILE", "").strip()
    if env_path:
        return Path(env_path)

    base_dir = getattr(Config, "BASE_DIR", None)
    if base_dir:
        cand_config = Path(base_dir) / "squads.json"
        if cand_config.is_file() or cand_config.parent.is_dir():
            return cand_config

    app_path = Path("/app/squads.json")
    if app_path.is_file() or app_path.parent.is_dir():
        return app_path

    return Path("squads.json")


class SquadManager:
    """Управление привязками сквадов Remnawave в структурированном файле squads.json."""

    UUID_REGEX = re.compile(r"^[A-Za-z0-9_-]+$")

    def __init__(self, file_path: Optional[Union[str, Path]] = None):
        if file_path:
            self.file_path = Path(file_path)
        else:
            self.file_path = get_default_squads_path()

    def list_squads(self) -> List[Dict[str, Any]]:
        """Возвращает список всех сохраненных сквадов."""
        if not self.file_path.is_file():
            return []
        try:
            content = self.file_path.read_text(encoding="utf-8").strip()
            if not content:
                return []
            data = json.loads(content)
            if not isinstance(data, list):
                logger.error(
                    f"[SquadManager] {self.file_path} содержит некорректный корневой JSON (ожидался список)"
                )
                return []
            results = []
            for item in data:
                if isinstance(item, dict) and "uuid" in item and "rule" in item:
                    sq: Dict[str, Any] = {
                        "uuid": str(item["uuid"]).strip().lower(),
                        "rule": str(item["rule"]).strip().upper(),
                    }
                    if item.get("name"):
                        sq["name"] = str(item["name"]).strip()
                    results.append(sq)
            return results
        except Exception as e:
            logger.error(f"[SquadManager] Ошибка чтения {self.file_path}: {e}")
            return []

    def get_squad(self, uuid: str) -> Optional[Dict[str, Any]]:
        """Возвращает данные сквада по UUID или None, если не найден."""
        uuid_clean = str(uuid).strip().lower()
        for squad in self.list_squads():
            if squad["uuid"] == uuid_clean:
                return dict(squad)
        return None

    def add_squad(
        self, uuid: str, rule: str, name: Optional[str] = None
    ) -> Dict[str, Any]:
        """Добавляет новый сквад или обновляет существующий по UUID."""
        uuid_clean = str(uuid).strip().lower()
        if not uuid_clean or not self.UUID_REGEX.match(uuid_clean):
            raise ValueError(f"Недопустимый формат UUID: '{uuid}'")

        rule_raw = str(rule).strip()
        if not rule_raw:
            raise ValueError("Имя правила не может быть пустым")

        rule_clean = Path(rule_raw).name.upper()
        if rule_clean.endswith(".DEEPLINK"):
            rule_clean = rule_clean.removesuffix(".DEEPLINK") + ".JSON"
        elif not rule_clean.endswith(".JSON"):
            rule_clean = f"{rule_clean}.JSON"

        squads = self.list_squads()
        updated = False
        target_squad: Optional[Dict[str, Any]] = None

        for sq in squads:
            if sq["uuid"] == uuid_clean:
                sq["rule"] = rule_clean
                if name is not None:
                    if str(name).strip():
                        sq["name"] = str(name).strip()
                    else:
                        sq.pop("name", None)
                target_squad = sq
                updated = True
                break

        if not updated:
            new_sq: Dict[str, Any] = {"uuid": uuid_clean, "rule": rule_clean}
            if name is not None and str(name).strip():
                new_sq["name"] = str(name).strip()
            squads.append(new_sq)
            target_squad = new_sq

        self._save(squads)
        return dict(target_squad)

    def remove_squad(self, uuid: str) -> bool:
        """Удаляет сквад по UUID. Возвращает True, если сквад был удален, иначе False."""
        uuid_clean = str(uuid).strip().lower()
        squads = self.list_squads()
        initial_len = len(squads)
        squads = [s for s in squads if s["uuid"] != uuid_clean]
        if len(squads) < initial_len:
            self._save(squads)
            return True
        return False

    def migrate_from_env(
        self, env_path: Optional[Union[str, Path]] = None
    ) -> List[Dict[str, Any]]:
        """Миграция существующих привязок REMNAWAVE_SQUAD_* и SQUAD_* из .env в squads.json."""
        if env_path:
            target_env = Path(env_path)
        else:
            candidates = [
                Path(".env"),
                Config.BASE_DIR / ".env" if hasattr(Config, "BASE_DIR") else Path("/app/.env"),
            ]
            target_env = next((p for p in candidates if p.is_file()), Path(".env"))

        if not target_env.is_file():
            logger.warning(f"[SquadManager] Файл .env не найден по пути {target_env}")
            return []

        env_vars: Dict[str, str] = {}
        try:
            with open(target_env, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    if "=" in line:
                        k, v = line.split("=", 1)
                        k = k.strip()
                        v = v.strip()
                        if len(v) >= 2 and (
                            (v.startswith('"') and v.endswith('"'))
                            or (v.startswith("'") and v.endswith("'"))
                        ):
                            v = v[1:-1]
                        env_vars[k] = v
        except Exception as e:
            logger.error(f"[SquadManager] Ошибка чтения {target_env}: {e}")
            return []

        indices = set()
        squad_re = re.compile(r"^(?:REMNAWAVE_)?SQUAD_(\d+)_(?:UUID|RULE|NAME|URL)$")
        for k in env_vars:
            m = squad_re.match(k)
            if m:
                indices.add(int(m.group(1)))

        migrated = []
        for idx in sorted(indices):
            uuid = env_vars.get(f"REMNAWAVE_SQUAD_{idx}_UUID") or env_vars.get(
                f"SQUAD_{idx}_UUID", ""
            )
            uuid = uuid.strip()
            if not uuid or not self.UUID_REGEX.match(uuid):
                continue
            rule = env_vars.get(f"REMNAWAVE_SQUAD_{idx}_RULE") or env_vars.get(
                f"SQUAD_{idx}_RULE", ""
            )
            name = env_vars.get(f"REMNAWAVE_SQUAD_{idx}_NAME") or env_vars.get(
                f"SQUAD_{idx}_NAME", ""
            )
            old_url = env_vars.get(f"SQUAD_{idx}_URL", "").strip()
            if not rule and old_url:
                rule = (
                    old_url.split("/")[-1]
                    .replace(".DEEPLINK", ".JSON")
                    .replace(".json", ".JSON")
                )
            rule = rule.strip() if rule else "JSONSUB.JSON"

            sq = self.add_squad(
                uuid=uuid, rule=rule, name=name.strip() if name.strip() else None
            )
            migrated.append(sq)

        return migrated

    def sync_squads_to_remnawave(
        self,
        remnawave_client: Any = None,
        www_dir: Optional[Union[str, Path]] = None,
    ) -> bool:
        """Применение привязок через существующий RemnawaveSync."""
        from app.remnawave import RemnawaveSync

        client = remnawave_client if remnawave_client is not None else RemnawaveSync
        squads = self.list_squads()
        if not squads:
            logger.info("[SquadManager] Список сквадов пуст, синхронизация не требуется.")
            return True

        if www_dir:
            w_path = Path(www_dir)
            if (w_path / "HAPP").is_dir():
                happ_dir = w_path / "HAPP"
            elif w_path.name.upper() == "HAPP":
                happ_dir = w_path
            elif any(w_path.glob("*.DEEPLINK")) or any(w_path.glob("*.JSON")):
                happ_dir = w_path
            else:
                happ_dir = w_path / "HAPP"
        else:
            try:
                token = Config.get_token()
                happ_dir = Config.STORAGE_DIR / token / "HAPP"
            except Exception:
                happ_dir = Config.STORAGE_DIR / "HAPP"

        if hasattr(client, "sync_squads") and callable(client.sync_squads):
            return client.sync_squads(squads, happ_dir)
        elif hasattr(client, "sync") and callable(client.sync):
            try:
                token = Config.get_token()
            except Exception:
                token = ""
            return client.sync(token)
        else:
            return RemnawaveSync.sync_squads(squads, happ_dir, client=client)

    def _save(self, squads: List[Dict[str, Any]]) -> None:
        """Атомарно сохраняет список сквадов в JSON-файл с предварительной валидацией."""
        if not isinstance(squads, list):
            raise ValueError("Данные сквадов должны быть списком словарей")

        validated = []
        for item in squads:
            if not isinstance(item, dict):
                raise ValueError("Элемент сквада должен быть словарем")
            uuid = str(item.get("uuid", "")).strip().lower()
            rule = str(item.get("rule", "")).strip()
            name = item.get("name")
            if not uuid or not self.UUID_REGEX.match(uuid):
                raise ValueError(f"Недопустимый формат UUID: '{uuid}'")
            if not rule:
                raise ValueError(f"Имя правила не может быть пустым для сквада {uuid}")
            rule_clean = Path(rule).name.upper()
            if rule_clean.endswith(".DEEPLINK"):
                rule_clean = rule_clean.removesuffix(".DEEPLINK") + ".JSON"
            elif not rule_clean.endswith(".JSON"):
                rule_clean = f"{rule_clean}.JSON"
            entry: Dict[str, Any] = {"uuid": uuid, "rule": rule_clean}
            if name is not None and str(name).strip():
                entry["name"] = str(name).strip()
            validated.append(entry)

        serialized = json.dumps(validated, indent=2, ensure_ascii=False)
        json.loads(serialized)

        self.file_path.parent.mkdir(parents=True, exist_ok=True)
        temp_fd, temp_path = tempfile.mkstemp(
            prefix=".squads.", suffix=".tmp", dir=str(self.file_path.parent)
        )
        try:
            with os.fdopen(temp_fd, "w", encoding="utf-8") as f:
                f.write(serialized)
                f.flush()
                os.fsync(f.fileno())
            os.replace(temp_path, self.file_path)
            try:
                os.chmod(self.file_path, 0o600)
            except OSError:
                pass
        except Exception:
            if os.path.exists(temp_path):
                try:
                    os.unlink(temp_path)
                except OSError:
                    pass
            raise
