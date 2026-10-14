"""Тесты app/composefile.py: compose.yaml для установки через install.sh."""

import pytest

from app import composefile

yaml = pytest.importorskip("yaml")


def test_render_without_network_matches_repo_service_shape():
    data = yaml.safe_load(composefile.render("img:1"))
    service = data["services"]["geo-routing-server"]
    assert service["image"] == "img:1"
    assert service["env_file"] == [".env"]
    assert service["ports"] == ["${HTTP_BIND:-127.0.0.1}:${HTTP_PORT:-8080}:80"]
    assert "routing_data:/app/www" in service["volumes"]
    assert "networks" not in service and "networks" not in data
    assert service["cap_drop"] == ["ALL"]


def test_render_with_network():
    data = yaml.safe_load(composefile.render("img:1", "remnawave-network"))
    assert data["services"]["geo-routing-server"]["networks"] == ["default", "remnawave"]
    assert data["networks"]["remnawave"] == {"external": True, "name": "remnawave-network"}


def test_render_rejects_bad_network():
    with pytest.raises(ValueError):
        composefile.render("img", 'bad"net')


def test_write_backs_up_only_on_change(tmp_path):
    assert composefile.write(tmp_path, "img:1") is None
    assert composefile.write(tmp_path, "img:1") is None
    backup = composefile.write(tmp_path, "img:1", "net")
    assert backup is not None and backup.name.startswith("compose.yaml.bak.")
    assert composefile.current_image(tmp_path) == "img:1"


def test_template_matches_repository_compose_yaml():
    """compose.yaml из репозитория (ручная установка) и шаблон мастера описывают один сервис."""
    from pathlib import Path

    repo = yaml.safe_load((Path(__file__).resolve().parents[1] / "compose.yaml").read_text(encoding="utf-8"))
    generated = yaml.safe_load(composefile.render(composefile.DEFAULT_IMAGE))
    assert repo == generated
