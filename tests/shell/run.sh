#!/usr/bin/env bash
# Интеграционные тесты install.sh: настоящий bash-скрипт + настоящий Python CLI,
# поддельные docker/curl (tests/shell/docker, tests/shell/curl).
#
# Скрипт пишет в /etc/geo-routing-server.conf и /usr/local/bin/geoserver,
# поэтому запускается только внутри одноразового контейнера:
#
#   docker run --rm -v "$PWD:/repo" -w /repo python:3.12-slim bash tests/shell/run.sh
set -uo pipefail

if [ ! -f /.dockerenv ] && [ -z "${GRS_ALLOW_HOST_TESTS:-}" ]; then
    echo "tests/shell/run.sh меняет /etc и /usr/local/bin — запускайте его в контейнере (см. заголовок)." >&2
    exit 2
fi

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
export REPO
WORK="$(mktemp -d)"
export STUB_LOG="$WORK/calls.log" STUB_STATE="$WORK/state"
mkdir -p "$STUB_STATE/app/www" "$WORK/bin"
for tool in docker curl; do
    tr -d '\r' < "$REPO/tests/shell/$tool" > "$WORK/bin/$tool"
    chmod 755 "$WORK/bin/$tool"
done
export PATH="$WORK/bin:$PATH"
tr -d '\r' < "$REPO/install.sh" > "$WORK/install.sh"
INSTALL="$WORK/install.sh"
export HOME="$WORK/home"
mkdir -p "$HOME"
cd "$WORK" || exit 1

FAILED=0
PASSED=0
pass() { PASSED=$((PASSED + 1)); echo "  ok   $1"; }
fail() { FAILED=$((FAILED + 1)); echo "  FAIL $1"; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
calls_since() { tail -n +"$(( $1 + 1 ))" "$STUB_LOG"; }
log_len() { wc -l < "$STUB_LOG" 2>/dev/null || echo 0; }
env_get() { grep -m1 "^$1=" "$HOME/geo/.env" | cut -d= -f2-; }
blank() { for _ in $(seq 1 12); do echo; done; }
: > "$STUB_LOG"

echo "== Первая установка: '/opt' отклонён, '~/geo' раскрыт, ответы по умолчанию"
# Буквальная '~' намеренно: install.sh должен раскрыть её сам
# shellcheck disable=SC2088
out="$({ echo /opt; echo "~/geo"; blank; } | bash "$INSTALL" install 2>&1)"; rc=$?
check "установка завершилась успешно" [ "$rc" -eq 0 ]
check "/opt отклонён" grep -q "установка туда запрещена" <<<"$out"
check "каталог записан абсолютным путём" [ "$(cat /etc/geo-routing-server.conf)" = "$HOME/geo" ]
check "запись о каталоге — ровно одна строка" [ "$(wc -l < /etc/geo-routing-server.conf)" -eq 1 ]
check ".env создан с правами 600" [ "$(stat -c %a "$HOME/geo/.env")" = 600 ]
check "токен сгенерирован (32 hex)" grep -Eq '^ROUTING_TOKEN=[0-9a-f]{32}$' "$HOME/geo/.env"
check "compose.yaml создан" grep -q "image: ghcr.io/xdeptu5/geo-routing-server:latest" "$HOME/geo/compose.yaml"
check "install.sh сохранён с правами 755" [ "$(stat -c %a "$HOME/geo/install.sh")" = 755 ]
check "команда geoserver установлена" grep -q "$HOME/geo/install.sh" /usr/local/bin/geoserver
check "контейнер запущен через compose up -d" grep -q "^docker compose up -d$" "$STUB_LOG"
check "мастер получил список сетей хоста" grep -q "GRS_HOST_NETWORKS=bridge,host,none,remnawave-network" "$STUB_LOG"
check "после установки показаны ссылки" grep -q "geo.example.com" <<<"$out"
TOKEN="$(env_get ROUTING_TOKEN)"

echo "== config set: проверка значения и применение"
n=$(log_len)
bash "$INSTALL" config set DOMAIN https://new.example.com/path >/dev/null 2>&1; rc=$?
check "config set вернул 0" [ "$rc" -eq 0 ]
check "домен нормализован" [ "$(env_get DOMAIN)" = "new.example.com" ]
check "изменение применено (up -d)" grep -q "^docker compose up -d$" <(calls_since "$n")
n=$(log_len)
bash "$INSTALL" config set HTTP_PORT 99999 >/dev/null 2>&1; rc=$?
check "недопустимый порт отклонён (rc=2)" [ "$rc" -eq 2 ]
check "без изменений ничего не применяется" bash -c "! grep -q 'compose up' <(tail -n +$((n + 1)) '$STUB_LOG')"
check "config get" [ "$(bash "$INSTALL" config get DOMAIN 2>/dev/null)" = "new.example.com" ]

echo "== Раздел меню: расписание"
n=$(log_len)
printf '1\n04:30\n0\n' | bash "$INSTALL" config schedule >/dev/null 2>&1; rc=$?
check "раздел завершился успешно" [ "$rc" -eq 0 ]
check "расписание сохранено" [ "$(env_get SCHEDULE)" = "30 4 * * *" ]
check "изменение применено" grep -q "^docker compose up -d$" <(calls_since "$n")

echo "== Раздел меню: Remnawave пишет сеть в compose.yaml"
printf '1\n\njwt-token\nremnawave-network\n0\n' | bash "$INSTALL" config remnawave >/dev/null 2>&1
check "токен Remnawave сохранён" [ "$(env_get REMNAWAVE_TOKEN)" = "jwt-token" ]
check "сеть добавлена в compose.yaml" grep -q 'name: "remnawave-network"' "$HOME/geo/compose.yaml"
check "прежний compose.yaml сохранён" bash -c "ls '$HOME/geo'/compose.yaml.bak.* >/dev/null 2>&1"

echo "== Старый образ без CLI API 2"
out="$(printf '0\n' | STUB_OLD_IMAGE=1 bash "$INSTALL" config clients 2>&1)"
check "просит обновить образ" grep -q "geoserver update-image" <<<"$out"

echo "== restart применяет .env (force-recreate)"
n=$(log_len)
bash "$INSTALL" restart >/dev/null 2>&1
check "up -d --force-recreate" grep -q "^docker compose up -d --force-recreate$" <(calls_since "$n")

echo "== update-image сохраняет squads.json старого контейнера"
echo '[{"uuid":"c0a8","rule":"HAPP.JSON"}]' > "$STUB_STATE/app/squads.json"
rm -f "$STUB_STATE/app/www/.squads.json"
GRS_SKIP_PULL=1 bash "$INSTALL" update-image >/dev/null 2>&1; rc=$?
check "обновление успешно" [ "$rc" -eq 0 ]
check "squads.json перенесён в том до пересоздания" cmp -s "$STUB_STATE/app/squads.json" "$STUB_STATE/app/www/.squads.json"
echo '[]' > "$STUB_STATE/app/www/.squads.json"
GRS_SKIP_PULL=1 bash "$INSTALL" update-image >/dev/null 2>&1
check "существующий .squads.json не перезаписан" [ "$(cat "$STUB_STATE/app/www/.squads.json")" = "[]" ]

echo "== Закрепление и откат версии образа"
img() { sed -n 's#^ *image: *##p' "$HOME/geo/compose.yaml"; }
bash "$INSTALL" update-image 1.7.0 >/dev/null 2>&1; rc=$?
check "закрепление на 1.7.0" [ "$rc" -eq 0 ]
check "compose.yaml указывает на :1.7.0" [ "$(img)" = "ghcr.io/xdeptu5/geo-routing-server:1.7.0" ]
bash "$INSTALL" update-image 1.0 >/dev/null 2>&1; rc=$?
check "неверная версия отклонена (rc=2)" [ "$rc" -eq 2 ]
STUB_PULL_FAIL=1 bash "$INSTALL" update-image 9.9.9 >/dev/null 2>&1; rc=$?
check "несуществующая версия — ошибка" [ "$rc" -eq 1 ]
check "compose.yaml возвращён к :1.7.0" [ "$(img)" = "ghcr.io/xdeptu5/geo-routing-server:1.7.0" ]
bash "$INSTALL" update-image latest >/dev/null 2>&1
check "снятие закрепления (latest)" [ "$(img)" = "ghcr.io/xdeptu5/geo-routing-server:latest" ]

echo "== status: exec в работающем контейнере, подсказка про том без меток"
n=$(log_len)
out="$(bash "$INSTALL" status 2>&1)"
check "status выполнен через exec" grep -q "compose exec -T geo-routing-server python3 -m app.cli status" <(calls_since "$n")
check "без разового контейнера" bash -c "! grep -q 'compose run' <(tail -n +$((n + 1)) '$STUB_LOG')"
check "ссылки показаны" grep -q "HAPP" <<<"$out"
check "том с метками — без подсказки" bash -c '! grep -q "создан не через Docker Compose" <<<"$1"' _ "$out"
out="$(STUB_VOLUME_UNLABELED=1 bash "$INSTALL" status 2>&1)"
check "том без меток — подсказка" grep -q "создан не через Docker Compose" <<<"$out"

echo "== Предупреждение о томе не просачивается из up/restart"
out="$(STUB_VOLUME_UNLABELED=1 bash "$INSTALL" restart 2>&1)"
check "restart без WARN о томе" bash -c '! grep -q "was not created by Docker Compose" <<<"$1"' _ "$out"
check "restart отработал" grep -q "Контейнер перезапущен" <<<"$out"

echo "== update-script"
sed 's/^SCRIPT_VERSION=.*/SCRIPT_VERSION="9.9.9"/' "$INSTALL" > "$WORK/remote.sh"
out="$(STUB_SCRIPT="$WORK/remote.sh" bash "$INSTALL" update-script 2>&1)"; rc=$?
check "обновление скрипта успешно" [ "$rc" -eq 0 ]
check "сообщает переход версий" grep -q "v1.[0-9.]* → v9.9.9" <<<"$out"
check "файл на диске заменён" grep -q '^SCRIPT_VERSION="9.9.9"' "$HOME/geo/install.sh"
out="$(STUB_SCRIPT="$WORK/remote.sh" bash "$INSTALL" update-script 2>&1)"
check "старая сессия при новом файле на диске — сказано прямо" grep -q "эта сессия запущена со старой версией" <<<"$out"
out="$(STUB_SCRIPT="$WORK/remote.sh" bash "$HOME/geo/install.sh" update-script 2>&1)"
check "актуальная версия — «уже актуален»" grep -q "Скрипт уже актуален (v9.9.9)" <<<"$out"
cp "$INSTALL" "$HOME/geo/install.sh"

echo "== Повторный запуск мастера сохраняет ответы"
{ echo; blank; } | bash "$INSTALL" install >/dev/null 2>&1
check "токен не изменился" [ "$(env_get ROUTING_TOKEN)" = "$TOKEN" ]
check "сеть Remnawave сохранилась" [ "$(env_get DOCKER_NETWORK)" = "remnawave-network" ]
check "резервная копия .env" bash -c "ls '$HOME/geo'/.env.bak.* >/dev/null 2>&1"

echo "== Удаление в git-клоне не трогает исходники"
mkdir -p "$WORK/clone/.git" && echo src > "$WORK/clone/app.py"
cp "$HOME/geo/.env" "$HOME/geo/compose.yaml" "$WORK/clone/"
echo "$WORK/clone" > /etc/geo-routing-server.conf
echo n | bash "$INSTALL" uninstall >/dev/null 2>&1; rc=$?
check "отмена возвращает 1" [ "$rc" -eq 1 ]
echo y | bash "$INSTALL" uninstall >/dev/null 2>&1; rc=$?
check "подтверждение возвращает 0" [ "$rc" -eq 0 ]
check ".git сохранён" [ -d "$WORK/clone/.git" ]
check "исходники сохранены" [ -f "$WORK/clone/app.py" ]
check ".env удалён" [ ! -f "$WORK/clone/.env" ]
check "compose.yaml удалён" [ ! -f "$WORK/clone/compose.yaml" ]

echo
echo "Итого: $PASSED ok, $FAILED fail"
[ "$FAILED" -eq 0 ]
