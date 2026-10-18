"""Генерация compose.yaml для установки через install.sh."""

import shutil
from datetime import datetime
from pathlib import Path
from typing import Optional

from app.envfile import write_atomic
from app.validators import is_valid_docker_network

DEFAULT_IMAGE = "ghcr.io/xdeptu5/geo-routing-server:latest"

_SERVICE = """\
name: geo-routing-server

services:
  geo-routing-server:
    image: {image}
    container_name: geo-routing-server
    restart: unless-stopped
    env_file:
      - .env
{networks}{ports}    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
      - SETUID
      - SETGID
      - CHOWN
      - DAC_OVERRIDE
      - KILL
    volumes:
      - routing_data:/app/www
      - ./.cache:/app/.cache
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:80/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  routing_data:
{network_defs}"""


_PORTS = '''    ports:
      - "${HTTP_BIND:-127.0.0.1}:${HTTP_PORT:-8080}:80"
'''


def render(image: str = DEFAULT_IMAGE, network: str = "", publish: bool = True) -> str:
    """publish=False — без проброса порта: режим «только сквады Remnawave» файлы не раздаёт."""
    if network and not is_valid_docker_network(network):
        raise ValueError(f"Недопустимое имя Docker-сети: {network!r}")
    if network:
        networks = "    networks:\n      - default\n      - remnawave\n"
        network_defs = (
            "\nnetworks:\n"
            "  remnawave:\n"
            "    external: true\n"
            f'    name: "{network}"\n'
        )
    else:
        networks = ""
        network_defs = ""
    return _SERVICE.format(image=image, networks=networks, ports=_PORTS if publish else "",
                           network_defs=network_defs)


def write(host_dir: Path, image: str = DEFAULT_IMAGE, network: str = "", publish: bool = True) -> Optional[Path]:
    """Пишет compose.yaml, предварительно сохранив прежний файл. Возвращает путь бэкапа."""
    path = Path(host_dir) / "compose.yaml"
    content = render(image, network, publish)
    backup = None
    if path.is_file():
        if path.read_text(encoding="utf-8") == content:
            return None
        backup = path.with_name(f"compose.yaml.bak.{datetime.now():%Y%m%d-%H%M%S}")
        shutil.copy2(path, backup)
    write_atomic(path, content, 0o644)
    return backup


def current_image(host_dir: Path) -> Optional[str]:
    path = Path(host_dir) / "compose.yaml"
    if not path.is_file():
        return None
    for line in path.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if stripped.startswith("image:"):
            return stripped.split(":", 1)[1].strip().strip('"\'') or None
    return None
