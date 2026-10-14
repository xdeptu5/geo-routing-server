# Разработка

## Структура

| Путь | Что внутри |
| :--- | :--- |
| `app/main.py` | Точка входа синхронизации: запуск процессоров, статус, сводка ссылок |
| `app/config.py` | Конфигурация из переменных окружения, пресеты источников |
| `app/downloader.py` | HTTP-загрузка с ETag-кэшем, ретраями и stale-if-error |
| `app/publisher.py` | Атомарная публикация файлов |
| `app/processors/` | Конвейер клиента в `base.py` (гео-базы, правила, публикация, очистка); `happ.py` и `incy.py` задают только отличия |
| `app/remnawave.py`, `app/squads.py` | Интеграция с Remnawave API и хранение привязок сквадов |
| `app/cli.py` | CLI внутри контейнера (`python -m app.cli`) |
| `app/hostconfig.py` | Мастер установки и разделы настроек `.env` (`setup`, `config ...`) |
| `app/validators.py` | Единые правила проверки ввода: токен, домен, порт, cron, сеть |
| `app/envfile.py`, `app/composefile.py` | Правка `.env` и генерация `compose.yaml` |
| `install.sh` | Тонкая обёртка на хосте: каталог, запуск, обновление, удаление |
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

# Интеграционные тесты install.sh (поддельный docker, настоящий CLI).
# Пишут в /etc и /usr/local/bin — только в одноразовом контейнере:
docker run --rm -v "$PWD:/repo:ro" -w /repo python:3.12-slim bash tests/shell/run.sh
```

Тестам `compose.yaml` нужен PyYAML (`pip install PyYAML==6.0.3`); самому приложению внешние зависимости не нужны.

### Как install.sh вызывает CLI

`install.sh` не задаёт вопросов и не проверяет ввод сам: он запускает `python -m app.cli setup` или `config <раздел>` в разовом контейнере (`docker compose run --rm`), смонтировав каталог установки в `/host`. Код возврата `100` значит «изменения сохранены»: скрипт выполняет `docker compose up -d` и открывает раздел снова.

Два правила, которые легко нарушить:
- `docker compose run` и `docker run -i` забирают **весь** stdin из пайпа, даже если команда его не читает. Вызовы, которым ввод не нужен, должны идти с `</dev/null`. Иначе они «съедят» ответы следующего интерактивного шага. Поддельный `tests/shell/docker` ведёт себя так же, поэтому тесты это ловят.
- Если `install.sh` начинает вызывать новую подкоманду, повысьте `CLI_API` в `app/__init__.py` и `REQUIRED_CLI_API` в `install.sh`. Тогда скрипт попросит обновить образ, а не упадёт на неизвестной команде.

Тесты не ходят в сеть, не запускают Docker и не читают `.env`: переменные окружения в них изолированы.

## CI

`.github/workflows/docker.yml` запускается на push в `main`, на теги, pull request и вручную:

| Задача | Что делает |
| :--- | :--- |
| Python: ruff + pytest | `ruff check app tests`, `python -m compileall app`, `python -m pytest -q` |
| Shellcheck | `shellcheck -S warning` для `install.sh`, `docker-entrypoint.sh` и `tests/shell/*` |
| install.sh: integration tests | `tests/shell/run.sh` в чистом контейнере `python:3.12-slim` |
| Build and publish | Сборка и публикация образа. Только для push, тегов и ручного запуска, после успешных проверок |

## Версия установщика

Скрипт и образ выпускаются одной версией: `SCRIPT_VERSION` в `install.sh` и `__version__` в `app/__init__.py` должны совпадать (это проверяет тест). Любое изменение `install.sh` должно повышать версию, иначе CI упадёт. Для мелких правок без новой версии добавьте в сообщение коммита `[no-bump]`. При выпуске обновите `CHANGELOG.md` и строку версии в `README.md`.

### Теги образа

Каждый push в `main` публикует `:latest` и `:sha-<коммит>`. Первый коммит с новой версией из `app/__init__.py` дополнительно публикует **неизменяемый** тег `:X.Y.Z`, а CI ставит git-тег `vX.Y.Z`. Следующие коммиты с той же версией этот тег не перезаписывают. На нём пользователи закрепляются и к нему откатываются (`geoserver update-image X.Y.Z`), поэтому любое изменение поведения, которое должно попасть в закрепляемую версию, требует новой версии.
