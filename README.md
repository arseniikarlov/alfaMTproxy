# MTProxy Infra

Воспроизводимая раскатка `Telegram MTProxy` на новый сервер с метрикой уникальных клиентских `IP` и браузерным live-дашбордом.

<p align="center">
  <a href="docs/architecture.md">
    <img src="docs/assets/architecture-overview.png" alt="MTProxy Infra Architecture" width="1200">
  </a>
</p>

Что внутри:

- `scripts/install-mtproxy-remote.sh` — ставит `MTProxy`, `systemd`-юниты, сборщик метрики и HTTP-дашборд
- `scripts/deploy-mtproxy.sh` — локально копирует installer на сервер и запускает его по `SSH`
- `scripts/mtproxy-metric.sh` — локально читает метрику с сервера
- `docs/mtproxy.md` — короткая инструкция
- `docs/architecture.md` — схема архитектуры
- `.mtproxy.env.example` — шаблон локального конфига

Быстрый старт:

```bash
cp .mtproxy.env.example .mtproxy.env
make mtproxy-deploy HOST=root@SERVER_IP
make mtproxy-metric
```

Подробности:

- [docs/mtproxy.md](docs/mtproxy.md)
- [docs/architecture.md](docs/architecture.md)
