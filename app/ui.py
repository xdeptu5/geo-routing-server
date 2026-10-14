"""Общие помощники терминального интерфейса: цвета и ввод."""

import os
import sys


def supports_color() -> bool:
    """Проверяет, поддерживает ли текущий терминал ANSI цвета."""
    if os.getenv("NO_COLOR"):
        return False
    if not hasattr(sys.stdout, "isatty"):
        return False
    return sys.stdout.isatty()


class Colors:
    """Управление ANSI-цветами для терминала."""

    def __init__(self, enabled: bool):
        self.RESET = "\033[0m" if enabled else ""
        self.BOLD = "\033[1m" if enabled else ""
        self.RED = "\033[31m" if enabled else ""
        self.GREEN = "\033[32m" if enabled else ""
        self.YELLOW = "\033[33m" if enabled else ""
        self.BLUE = "\033[34m" if enabled else ""
        self.MAGENTA = "\033[35m" if enabled else ""
        self.CYAN = "\033[36m" if enabled else ""
        self.WHITE = "\033[37m" if enabled else ""
        self.GRAY = "\033[90m" if enabled else ""


class Cancelled(Exception):
    """Пользователь прервал ввод (Ctrl+C / конец ввода)."""


def ask(prompt: str, default: str = "") -> str:
    """Строка ввода; пустой ответ — значение по умолчанию."""
    try:
        answer = input(prompt).strip()
    except (KeyboardInterrupt, EOFError):
        print()
        raise Cancelled()
    return answer or default


def confirm(prompt: str, default: bool = False) -> bool:
    answer = ask(prompt, "y" if default else "n").lower()
    return answer in ("y", "yes", "д", "да")


def pause() -> None:
    try:
        input("Нажмите Enter, чтобы продолжить...")
    except (KeyboardInterrupt, EOFError):
        print()
