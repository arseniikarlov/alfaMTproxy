# MTProxy Rollout

Настройка прокси и метрики сохранена в git как воспроизводимый набор:

- `scripts/install-mtproxy-remote.sh` — установка на сервере
- `scripts/deploy-mtproxy.sh` — локальная раскатка по SSH
- `scripts/mtproxy-metric.sh` — локальный просмотр метрики
- `.mtproxy.env.example` — пример конфигурации

## Что хранится в git

- установка `MTProxy` из официального репозитория
- `systemd`-юниты для прокси и сборщика метрики
- сбор уникальных IP по входящим TCP SYN на порт прокси
- команда просмотра метрики

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

Если нужен фиксированный `secret`, можно перед раскаткой задать `MTPROXY_SECRET`.

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

На выходе скрипт печатает:

- готовую ссылку `t.me/proxy`
- текущий снимок метрики

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

## Что считается

Метрика считает:

- `total_unique_ips`
- `unique_last_24h`
- `unique_last_7d`

Это именно уникальные клиентские `IP`, а не Telegram-аккаунты.
