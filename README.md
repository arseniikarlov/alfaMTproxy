# MTProxy Infra

Воспроизводимая раскатка `Telegram MTProxy` на новый сервер с метрикой уникальных клиентских `IP`.

Что внутри:

- `scripts/install-mtproxy-remote.sh` — ставит `MTProxy`, `systemd`-юниты и сборщик метрики
- `scripts/deploy-mtproxy.sh` — локально копирует installer на сервер и запускает его по `SSH`
- `scripts/mtproxy-metric.sh` — локально читает метрику с сервера
- `docs/mtproxy.md` — короткая инструкция
- `.mtproxy.env.example` — шаблон локального конфига

Быстрый старт:

```bash
cp .mtproxy.env.example .mtproxy.env
make mtproxy-deploy HOST=root@SERVER_IP
make mtproxy-metric
```

Подробности: [docs/mtproxy.md](docs/mtproxy.md)
