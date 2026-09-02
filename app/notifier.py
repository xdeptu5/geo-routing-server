import html
import json
import logging
import urllib.request
from datetime import datetime, timezone
from typing import Any, Dict
from app.config import Config
from app.publisher import PublishedFileInfo

logger = logging.getLogger("geo-routing-server")

class TelegramNotifier:
    """Умные, информативные Telegram-уведомления без спама с поддержкой топиков (Thread ID)."""
    
    @staticmethod
    def _send_message(text: str) -> bool:
        bot_token = Config.TELEGRAM_BOT_TOKEN
        chat_id = Config.TELEGRAM_CHAT_ID
        thread_id = Config.TELEGRAM_THREAD_ID
        
        if not bot_token or not chat_id:
            return False
            
        url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
        payload: Dict[str, Any] = {
            "chat_id": chat_id,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True
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

    @classmethod
    def alert_failure(cls, error_msg: str) -> None:
        """Отправляет алерт при ошибке синхронизации."""
        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        safe_msg = html.escape(str(error_msg))
        text = (
            f"⚠️ <b>[Geo Routing Server] Ошибка синхронизации!</b>\n\n"
            f"🌐 <b>Домен:</b> <code>{Config.DOMAIN}</code>\n"
            f"⏱ <b>Время:</b> {now_str}\n\n"
            f"❌ <b>Причина ошибки:</b>\n"
            f"<code>{safe_msg}</code>\n\n"
            f"🛡 <i>Ранее опубликованные файлы не повреждены и продолжают раздаваться клиентам.</i>"
        )
        cls._send_message(text)

    @classmethod
    def notify_changes(cls, token: str, registry: Dict[str, PublishedFileInfo], any_changed: bool) -> None:
        """
        Отправляет уведомление об успешном обновлении:
        - Только если TELEGRAM_NOTIFY_SUCCESS включен
        - И только если файлы РЕАЛЬНО изменились (без спама при 304 Not Modified)
        """
        if not Config.TELEGRAM_NOTIFY_SUCCESS or not any_changed:
            return
            
        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        base_url = Config.get_base_url(token)
        
        # Собираем информацию о geo-файлах
        geo_lines = []
        for key, info in registry.items():
            if info.filename.endswith(".dat"):
                size_kb = round(info.size_bytes / 1024, 1)
                short_hash = info.sha256[:12]
                status_icon = "🆕" if info.is_updated else "▫️"
                geo_lines.append(f"{status_icon} <code>{key}</code>: {size_kb} KB (<code>{short_hash}...</code>)")
                
        geo_block = "\n".join(geo_lines) if geo_lines else "—"
        
        # Формируем список ссылок на autorouting
        autorouting_lines = []
        if "INCY" in Config.ENABLED_CLIENTS:
            autorouting_lines.append(f"🔗 <b>Autorouting Header (Remnawave / Marzban):</b>\n<code>incy://autorouting/onadd/{base_url}/INCY/JSONSUB.JSON</code>")
            
        autorouting_block = "\n\n".join(autorouting_lines)
        
        text = (
            f"🚀 <b>[Geo Routing Server] Вышли обновленные базы!</b>\n\n"
            f"🌐 <b>Домен:</b> <code>{Config.DOMAIN}</code>\n"
            f"⏱ <b>Время:</b> {now_str}\n\n"
            f"📊 <b>Geo-базы:</b>\n{geo_block}\n\n"
            f"{autorouting_block}"
        )
        cls._send_message(text)
