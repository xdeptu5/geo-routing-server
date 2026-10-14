from app.processors.base import BaseProcessor


class IncyProcessor(BaseProcessor):
    """Incy: гео-базы и правила .JSON (диплинки .DEEPLINK — если включены в SERVE_FORMATS)."""

    CLIENT_NAME = "INCY"
