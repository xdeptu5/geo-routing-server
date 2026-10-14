import os
from typing import Set

from app.config import Config
from app.processors.base import BaseProcessor
from app.remnawave import RemnawaveSync
from app.squads import split_squad_rule


class HappProcessor(BaseProcessor):
    """Happ: гео-базы, правила .JSON и диплинки .DEEPLINK (в том числе для сквадов Remnawave)."""

    CLIENT_NAME = "HAPP"

    def _extra_rule_files(self) -> Set[str]:
        """Правила из привязок сквадов и глобального правила Remnawave.

        GITHUB_RAW_URL — старое имя REMNAWAVE_GLOBAL_RULE (его же учитывает
        RemnawaveSync.sync()). Правило с префиксом другого пресета этому
        процессору не нужно.
        """
        my_prefix = self.preset_prefix or Config.PRIMARY_PRESET.upper()
        wanted = [sq.get("rule", "") for sq in RemnawaveSync.load_squad_configs()]
        wanted.append(os.getenv("REMNAWAVE_GLOBAL_RULE", "").strip() or os.getenv("GITHUB_RAW_URL", "").strip())
        rules = set()
        for raw_rule in wanted:
            prefix, rule_name = split_squad_rule(raw_rule)
            if rule_name and (prefix is None or prefix == my_prefix):
                rules.add(rule_name)
        return rules

    def _should_publish_deeplink(self) -> bool:
        # Remnawave читает диплинки из файлов, даже если клиентам раздаётся только JSON
        return Config.should_serve_deeplink(self.CLIENT_NAME) or RemnawaveSync.is_configured()
