"""Единые правила проверки пользовательского ввода.

Раньше каждое правило существовало в двух экземплярах — в bash (install.sh,
docker-entrypoint.sh) и в Python — и они расходились. Теперь источник истины
здесь: мастер установки, меню настроек и приложение используют одни функции.
"""

import re
import secrets
from typing import Optional

TOKEN_PLACEHOLDER = "change_me_to_random_secret_token"
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{4,}$")
DOMAIN_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]*$")
DOCKER_NETWORK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
CRON_FIELD_RE = re.compile(r"^[0-9*,/-]+$")

DEFAULT_SCHEDULE = "0 10 * * *"


def is_valid_token(value: str) -> bool:
    """Токен для URL: минимум 4 символа A-Z a-z 0-9 _ -, не заглушка из .env.example."""
    value = (value or "").strip()
    return value != TOKEN_PLACEHOLDER and bool(TOKEN_RE.match(value))


def generate_token() -> str:
    return secrets.token_hex(16)


def normalize_domain(value: str) -> str:
    """Убирает схему и путь: 'https://geo.example.com/x' -> 'geo.example.com'."""
    value = (value or "").strip()
    value = re.sub(r"^https?://", "", value, flags=re.IGNORECASE)
    return value.split("/", 1)[0]


def is_valid_domain(value: str) -> bool:
    return bool(value) and bool(DOMAIN_RE.match(value))


def parse_port(value: str) -> Optional[int]:
    value = (value or "").strip()
    if not value.isdigit() or len(value) > 5:
        return None
    port = int(value, 10)
    return port if 1 <= port <= 65535 else None


def is_valid_docker_network(value: str) -> bool:
    return bool(DOCKER_NETWORK_RE.match(value or ""))


def is_valid_cron(expr: str) -> bool:
    """Ровно 5 полей из допустимого алфавита.

    BusyBox crond молча игнорирует некорректную строку, и синхронизация просто
    перестаёт запускаться, поэтому неверный ввод отсекаем до записи в .env.
    """
    fields = (expr or "").split()
    return len(fields) == 5 and all(CRON_FIELD_RE.match(f) for f in fields)


def schedule_from_time(value: str) -> Optional[str]:
    """'14:30' -> '30 14 * * *', '9' -> '0 9 * * *'."""
    match = re.fullmatch(r"([01]?\d|2[0-3])(?::([0-5]\d))?", (value or "").strip())
    if not match:
        return None
    hour = int(match.group(1), 10)
    minute = int(match.group(2) or "0", 10)
    return f"{minute} {hour} * * *"


def schedule_every_hours(value: str) -> Optional[str]:
    value = (value or "").strip()
    if not value.isdigit():
        return None
    hours = int(value, 10)
    if hours == 1:
        return "0 * * * *"
    if hours == 24:
        return "0 0 * * *"
    if 2 <= hours <= 23:
        return f"0 */{hours} * * *"
    return None


def schedule_interval_hours(cron: str) -> int:
    """Примерный интервал между запусками по cron, в часах (по умолчанию сутки)."""
    fields = (cron or DEFAULT_SCHEDULE).split()
    if len(fields) != 5:
        return 24
    hour = fields[1]
    if hour == "*":
        return 1
    step = re.fullmatch(r"\*/(\d+)", hour)
    if step:
        return max(1, int(step.group(1)))
    if "," in hour:
        return max(1, 24 // len(hour.split(",")))
    return 24


def human_schedule(cron: str) -> str:
    cron = (cron or DEFAULT_SCHEDULE).strip()
    known = {
        "0 10 * * *": "ежедневно в 10:00 UTC (13:00 МСК)",
        "0 12 * * *": "ежедневно в 12:00 UTC (15:00 МСК)",
        "0 */6 * * *": "каждые 6 часов",
        "0 */12 * * *": "каждые 12 часов",
        "0 * * * *": "каждый час",
    }
    if cron in known:
        return known[cron]
    fields = cron.split()
    if len(fields) == 5 and fields[2:] == ["*", "*", "*"]:
        minute, hour = fields[0], fields[1]
        if minute.isdigit() and hour.isdigit():
            return f"ежедневно в {int(hour):02d}:{int(minute):02d} UTC"
        step = re.fullmatch(r"\*/(\d+)", hour)
        if minute == "0" and step:
            return f"каждые {step.group(1)} ч."
    return cron


def normalize_remnawave_url(value: str) -> str:
    """'https://panel/' -> 'https://panel/api' (суффикс /api обязателен для API)."""
    value = (value or "").strip().rstrip("/")
    if not value:
        return ""
    if not re.search(r"/api$", value, flags=re.IGNORECASE):
        value = f"{value}/api"
    return value


def normalize_public_url(value: str) -> str:
    value = (value or "").strip().rstrip("/")
    if value and not re.match(r"^https?://", value, flags=re.IGNORECASE):
        value = f"https://{value}"
    return value
