import html
import json
import logging
import re
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Union
from app.config import Config
from app.publisher import PublishedFileInfo

logger = logging.getLogger("geo-routing-server")

class TelegramNotifier:
    """Короткие Telegram-уведомления без спама, с поддержкой тем (Thread ID)."""
    
    @staticmethod
    def _send_message(
        text: str,
        bot_token: Optional[str] = None,
        chat_id: Optional[str] = None,
        thread_id: Optional[str] = None,
    ) -> bool:
        # Явные значения передаёт меню настроек: оно проверяет только что
        # введённые данные, которых ещё нет в окружении процесса.
        bot_token = Config.TELEGRAM_BOT_TOKEN if bot_token is None else bot_token
        chat_id = Config.TELEGRAM_CHAT_ID if chat_id is None else chat_id
        thread_id = Config.TELEGRAM_THREAD_ID if thread_id is None else thread_id
        
        if not bot_token or not chat_id:
            return False
            
        url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
        # Обрезаем сообщение до 4000 символов для соблюдения лимитов Telegram API (4096)
        if len(text) <= 4000:
            safe_text = text
        else:
            safe_text = text[:3900]
            # Обрезка могла разорвать HTML-сущность посередине (например "&amp;" -> "&am") —
            # Telegram с parse_mode=HTML не распознает такой обрубок как текст и отклонит
            # сообщение целиком. Все сущности html.escape() заканчиваются на ';', поэтому
            # незавершенный хвост без ';' безопасно удаляем.
            safe_text = re.sub(r"&#?[A-Za-z0-9]*$", "", safe_text)
            # Обрезка могла разорвать HTML-тег посередине — убираем незавершенный хвост "<тег..."
            safe_text = re.sub(r"<[^<>]*$", "", safe_text)
            # ...и закрываем открытые теги, иначе Telegram отклонит сообщение с parse_mode=HTML
            for tag in ("code", "i", "b"):
                while safe_text.count(f"<{tag}>") > safe_text.count(f"</{tag}>"):
                    safe_text += f"</{tag}>"
            safe_text += "\n\n<i>[...текст обрезан из-за лимита Telegram...]</i>"
        
        payload: Dict[str, Any] = {
            "chat_id": chat_id,
            "text": safe_text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
            "link_preview_options": {"is_disabled": True}
        }
        
        # Поддержка топиков/тем в супергруппах
        if thread_id:
            try:
                payload["message_thread_id"] = int(thread_id)
            except ValueError:
                logger.warning(f"Invalid TELEGRAM_THREAD_ID: {thread_id}")
        
        try:
            req = urllib.request.Request(
                url,
                data=json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"}
            )
            with urllib.request.urlopen(req, timeout=10) as res:
                return res.getcode() == 200
        except Exception as e:
            logger.warning(f"Failed to send Telegram notification: {e}")
            return False

    # --------------------------------------------------------------------------
    # Тексты сообщений: коротко, только то, что изменилось, и что делать
    # --------------------------------------------------------------------------

    @staticmethod
    def _title(icon: str, text: str) -> str:
        """Заголовок с доменом — только если сервер раздаёт файлы и домен настоящий."""
        from app.validators import is_valid_domain

        domain = Config.DOMAIN or ""
        serves = not (Config.ENABLED_CLIENTS and set(Config.ENABLED_CLIENTS).issubset(Config.RULES_ONLY_MODULES))
        where = ""
        if serves and is_valid_domain(domain) and domain != "geo.example.com":
            where = f" · {html.escape(domain)}"
        return f"{icon} <b>{text}</b>{where}"

    @staticmethod
    def _when() -> str:
        return f"<i>{datetime.now(timezone.utc):%d.%m %H:%M} UTC</i>"

    @staticmethod
    def _size(size_bytes: int) -> str:
        if size_bytes >= 1024 * 1024:
            return f"{size_bytes / 1024 / 1024:.1f} МБ"
        return f"{max(1, round(size_bytes / 1024))} КБ"

    @classmethod
    def alert_failure(cls, problems: Union[str, List[str]], partial: bool = False) -> None:
        """Одно сообщение на синхронизацию: что сломалось и что делать.

        partial — часть файлов обновилась, остальное раздаётся в прежней версии.
        """
        items = [problems] if isinstance(problems, str) else list(problems)
        items = [" ".join(str(p).split()) for p in items if str(p).strip()] or ["причина в логах"]
        shown = [html.escape(p if len(p) <= 200 else p[:197] + "…") for p in items[:3]]
        if len(items) > 3:
            shown.append(f"и ещё {len(items) - 3}")
        title = "Синхронизация прошла с ошибками" if partial else "Синхронизация не удалась"
        effect = "Остальное обновлено." if partial else "Клиенты получают прежние версии файлов."
        text = "\n".join([
            cls._title("⚠️" if partial else "❌", title),
            *[f"• {p}" for p in shown],
            "",
            f"{effect} Подробности: <code>geoserver logs</code>",
            cls._when(),
        ])
        cls._send_message(text)

    @classmethod
    def notify_changes(cls, token: str, registry: Dict[str, PublishedFileInfo], any_changed: bool) -> None:
        """Сообщение об обновлении — только если TELEGRAM_NOTIFY_SUCCESS включён
        и файлы реально изменились (без спама при 304 Not Modified)."""
        if not Config.TELEGRAM_NOTIFY_SUCCESS or not any_changed:
            return
        updated = [info for info in registry.values() if info.is_updated]
        if not updated:
            return

        # Один и тот же файл публикуется для нескольких клиентов — показываем один раз
        geo: Dict[str, int] = {}
        rules: Dict[str, None] = {}
        for info in updated:
            if info.filename.endswith(".dat"):
                geo.setdefault(info.filename, info.size_bytes)
            else:
                rules.setdefault(info.filename.rsplit(".", 1)[0].upper(), None)

        lines = [cls._title("✅", "Обновлено")]
        if geo:
            lines.append("🗺 " + ", ".join(f"{name} ({cls._size(size)})" for name, size in sorted(geo.items())))
        if rules:
            lines.append("📚 Правила: " + ", ".join(html.escape(r) for r in rules))
        from app.remnawave import RemnawaveSync
        if rules and RemnawaveSync.is_configured():
            lines.append("🔗 Сквады Remnawave получили новые правила")
        lines.append(cls._when())
        cls._send_message("\n".join(lines))

    @classmethod
    def send_test_message(
        cls,
        bot_token: Optional[str] = None,
        chat_id: Optional[str] = None,
        thread_id: Optional[str] = None,
    ) -> bool:
        """Тестовое сообщение для проверки настроек бота."""
        what = "ошибки синхронизации и обновления баз" if Config.TELEGRAM_NOTIFY_SUCCESS else "ошибки синхронизации"
        text = "\n".join([
            cls._title("🔔", "Уведомления работают"),
            f"Сюда будут приходить: {what}.",
        ])
        return cls._send_message(text, bot_token=bot_token, chat_id=chat_id, thread_id=thread_id)
