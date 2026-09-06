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
        # Обрезаем сообщение до 4000 символов для соблюдения лимитов Telegram API
        safe_text = text if len(text) <= 4000 else text[:3900] + "\n\n<i>[...текст обрезан из-за лимита Telegram...]</i>"
        
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

    @classmethod
    def alert_failure(cls, error_msg: str) -> None:
        """Отправляет алерт при ошибке синхронизации."""
        now_str = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        safe_domain = html.escape(Config.DOMAIN)
        safe_msg = html.escape(str(error_msg))
        text = (
            f"⚠️ <b>[Geo Routing Server] Ошибка синхронизации!</b>\n\n"
            f"🌐 <b>Домен:</b> <code>{safe_domain}</code>\n"
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
        safe_domain = html.escape(Config.DOMAIN)
        base_url = html.escape(Config.get_base_url(token))
        
        # Собираем информацию о geo-файлах
        geo_lines = []
        for key, info in registry.items():
            if info.filename.endswith(".dat"):
                size_kb = round(info.size_bytes / 1024, 1)
                short_hash = info.sha256[:12]
                status_icon = "🆕" if info.is_updated else "▫️"
                safe_key = html.escape(key)
                geo_lines.append(f"{status_icon} <code>{safe_key}</code>: {size_kb} KB (<code>{short_hash}...</code>)")
                
        geo_block = "\n".join(geo_lines) if geo_lines else "—"
        
        # Формируем информацию о правилах и интеграциях
        info_lines = []
        rules = Config.ROUTING_RULES if Config.ROUTING_RULES else ["JSONSUB"]
        
        # 1. Интеграция с Remnawave API (если настроена)
        from app.remnawave import RemnawaveSync
        if RemnawaveSync.is_configured():
            info_lines.append("⚡ <b>Remnawave API:</b> сквады маршрутизации синхронизированы")
        elif "HAPP" in Config.ENABLED_CLIENTS:
            happ_rules = [f"• <b>{r}:</b> <code>{base_url}/HAPP/{r}.DEEPLINK</code>" for r in rules]
            happ_block = "\n".join(happ_rules)
            info_lines.append(f"📱 <b>Happ (диплинки правил):</b>\n{happ_block}")

        # 2. Ссылки на заголовок autorouting для Incy
        if "INCY" in Config.ENABLED_CLIENTS:
            incy_rules = [f"• <b>{r}:</b> <code>incy://autorouting/onadd/{base_url}/INCY/{r}.JSON</code>" for r in rules]
            incy_block = "\n".join(incy_rules)
            info_lines.append(f"🔗 <b>Autorouting Header (Incy):</b>\n{incy_block}")
            
        extra_block = ("\n\n" + "\n\n".join(info_lines)) if info_lines else ""
        
        text = (
            f"🚀 <b>[Geo Routing Server] Вышли обновленные базы!</b>\n\n"
            f"🌐 <b>Домен:</b> <code>{safe_domain}</code>\n"
            f"⏱ <b>Время:</b> {now_str}\n\n"
            f"📊 <b>Geo-базы:</b>\n{geo_block}"
            f"{extra_block}"
        )
        cls._send_message(text)

    @classmethod
    def send_test_message(cls) -> bool:
        """Отправляет тестовое уведомление для проверки настроек бота."""
        safe_domain = html.escape(Config.DOMAIN)
        text = (
            f"🔔 <b>[Geo Routing Server] Тестовое уведомление</b>\n\n"
            f"🌐 <b>Домен:</b> <code>{safe_domain}</code>\n"
            f"✅ Связь с Telegram Bot API успешно установлена!\n"
            f"Бот готов присылать отчёты об обновлениях баз и предупреждения об ошибках."
        )
        return cls._send_message(text)

