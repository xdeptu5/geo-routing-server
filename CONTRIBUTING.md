# Разработка

## Структура

| Путь | Что внутри |
| :--- | :--- |
| `app/main.py` | Точка входа синхронизации: запуск процессоров, статус, сводка ссылок |
| `app/config.py` | Конфигурация из переменных окружения, пресеты источников |
| `app/downloader.py` | HTTP-загрузка с ETag-кэшем, ретраями и stale-if-error |
| `app/publisher.py` | Атомарная публикация файлов |
| `app/processors/` | Обработка правил и гео-баз для Happ и Incy |
| `app/remnawave.py`, `app/squads.py` | Интеграция с Remnawave API и хранение привязок сквадов |
| `app/cli.py` | CLI внутри контейнера (`python -m app.cli`) |
| `install.sh` | Установщик и меню `geoserver` на хосте |
| `docker-entrypoint.sh`, `nginx-internal.conf` | Запуск контейнера и внутренний веб-сервер |

Приложение использует только стандартную библиотеку Python.

## Проверки

Все команды запускаются из корня репозитория. Версии зафиксированы и совпадают с CI: Python 3.12, `ruff==0.16.9`, `pytest==9.1.1`.

```bash
ruff check app tests                                    # линтер (конфиг — ruff.toml)
python -m pytest -q                                     # юнит-тесты
python -m compileall app                                # синтаксис модулей
bash -n install.sh docker-entrypoint.sh                 # синтаксис shell-скриптов
shellcheck -S warning install.sh docker-entrypoint.sh   # статический анализ
```

Тесты не ходят в сеть, не запускают Docker и не читают `.env`: переменные окружения в них изолированы.

## CI

`.github/workflows/docker.yml` запускается на push в `main`, на теги, pull request и вручную:

| Задача | Что делает |
| :--- | :--- |
| Python: ruff + pytest | `ruff check app`, `python -m compileall app`, `python -m pytest -q` |
| Shellcheck | `shellcheck -S warning` для `install.sh` и `docker-entrypoint.sh` |
| Build and publish | Сборка и публикация образа. Только для push, тегов и ручного запуска, после успешных проверок |

## Версия установщика

Любое изменение `install.sh` должно повышать `SCRIPT_VERSION`, иначе CI упадёт. Для мелких правок без новой версии добавьте в сообщение коммита `[no-bump]`. При выпуске версии обновите `CHANGELOG.md` и строку версии в `README.md`.
