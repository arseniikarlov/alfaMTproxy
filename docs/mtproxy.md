# MTProxy Rollout

Настройка прокси и метрики сохранена в git как воспроизводимый набор:

- `scripts/install-mtproxy-remote.sh` — установка на сервере
- `scripts/deploy-mtproxy.sh` — локальная раскатка по SSH
- `scripts/mtproxy-metric.sh` — локальный просмотр метрики
- `.mtproxy.env.example` — пример конфигурации

## Что хранится в git

- установка `MTProxy` из официального репозитория
- `systemd`-юниты для прокси и сборщика метрики
- отдельный HTTP-дашборд с автообновлением
- watchdog c `systemd timer`, который сам проверяет и переподнимает сервисы
- Telegram-alerting через Bot API при падении и восстановлении
- безопасный updater Telegram-конфига без ежедневного слепого `restart`
- сбор уникальных IP по входящим TCP SYN на порт прокси
- GeoIP city/country enrichment для последних подключений
- команда просмотра метрики
- системная защита `kernel.pid_max = 65535`, чтобы `MTProxy` не падал на высоких PID

В git не кладутся:

- пароль сервера
- текущий сгенерированный `secret`
- реальные приватные ключи

## Первичная настройка

Скопируй пример конфига:

```bash
cp .mtproxy.env.example .mtproxy.env
```

Заполни:

- `MTPROXY_HOST`
- `PUBLIC_HOST`
- `PUBLIC_PORT`
- `INTERNAL_PORT`
- `WORKERS`
- `DASHBOARD_PORT`

Если нужен фиксированный `secret`, можно перед раскаткой задать `MTPROXY_SECRET`.
Если нужен фиксированный токен для веб-дашборда, можно задать `MTPROXY_DASHBOARD_TOKEN`.
Если нужны алерты в Telegram, можно задать:

- `MTPROXY_ALERT_BOT_TOKEN`
- `MTPROXY_ALERT_CHAT_ID`

Если хочешь сохранить ту же ссылку в Telegram при переносе на новый сервер:

- сохрани текущий `secret` отдельно
- пропиши его в локальном `.mtproxy.env` как `MTPROXY_SECRET=...`
- раскатывай новый сервер с тем же значением

Тогда поменяется только `server` в ссылке, а сам `secret` останется прежним.

## Раскатка на новый сервер

Нужен рабочий SSH-доступ по ключу:

```bash
./scripts/deploy-mtproxy.sh root@SERVER_IP
```

Или через `make`:

```bash
make mtproxy-deploy HOST=root@SERVER_IP
```

Если на сервере уже всё установлено, а `apt` занят или ты хочешь обновить только наши скрипты и `systemd`-юниты:

```bash
MTPROXY_SKIP_APT=1 ./scripts/deploy-mtproxy.sh root@SERVER_IP
```

На выходе скрипт печатает:

- готовую ссылку `t.me/proxy`
- ссылку на web-дашборд
- статус watchdog
- путь к safe updater
- текущий снимок метрики

Дашборд открывается по ссылке вида:

```text
http://SERVER_IP:DASHBOARD_PORT/?token=YOUR_DASHBOARD_TOKEN
```

Токен можно передавать один раз в URL: страница сохранит его в `sessionStorage` и уберёт из адресной строки.

## Просмотр метрики

Локально:

```bash
./scripts/mtproxy-metric.sh
./scripts/mtproxy-metric.sh --json
```

Или через `make`:

```bash
make mtproxy-metric
make mtproxy-metric ARGS=--json
```

На сервере:

```bash
mtproxy-unique-stats
mtproxy-unique-stats --json
```

Проверка auto-heal:

```bash
systemctl status mtproxy-watchdog.timer --no-pager
systemctl status mtproxy-watchdog.service --no-pager
journalctl -u mtproxy-watchdog.service -n 50 --no-pager
```

Безопасный update Telegram-конфига:

```bash
/usr/local/bin/mtproxy-update-config
```

Что он делает:

- скачивает `proxy-secret` и `proxy-multi.conf` во временные файлы
- сравнивает их с текущими
- если изменений нет, не трогает `mtproxy`
- если изменился только `proxy-multi.conf`, обновляет файл на диске без `restart`
- если изменился `proxy-secret`, делает `restart` только один раз
- если после такого обновления `mtproxy` не проходит health-check, откатывает старые файлы и поднимает сервис обратно

При заданных `MTPROXY_ALERT_BOT_TOKEN` и `MTPROXY_ALERT_CHAT_ID` watchdog:

- шлёт один alert при переходе в `unhealthy`
- не спамит одинаковым сообщением каждую минуту
- шлёт recovery при возврате в `healthy`

В браузере:

- открой ссылку, которую печатает installer
- страница сама обновляет данные каждые 5 секунд
- API доступно на `/api/metrics`
- для последних IP показываются `город / регион / страна`, если GeoIP смог это определить

## Что считается

Метрика считает:

- `total_unique_ips`
- `unique_last_24h`
- `unique_last_7d`

Это именно уникальные клиентские `IP`, а не Telegram-аккаунты.

GeoIP-данные:

- определяются best-effort и кэшируются в `SQLite`
- для мобильных сетей, CGNAT, VPN и proxy могут быть неточными
- в текущей реализации lookup делается через `ip-api.com`
- у бесплатного batch endpoint есть лимит `15 req/min` и он работает по `HTTP`, не по `HTTPS`
