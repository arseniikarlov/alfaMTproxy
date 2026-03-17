#!/usr/bin/env bash
set -euo pipefail

PUBLIC_PORT="${PUBLIC_PORT:-443}"
INTERNAL_PORT="${INTERNAL_PORT:-2398}"
WORKERS="${WORKERS:-1}"
INSTALL_DIR="${INSTALL_DIR:-/opt/MTProxy}"
DATA_DIR="${DATA_DIR:-/opt/mtproxy-data}"
METRICS_DIR="${METRICS_DIR:-/var/lib/mtproxy-metrics}"
SECRET_DIR="${SECRET_DIR:-/etc/mtproxy}"
SECRET_FILE="${SECRET_FILE:-${SECRET_DIR}/secret}"
COLLECTOR_BIN="/usr/local/bin/mtproxy_unique_collector.py"
STATS_BIN="/usr/local/bin/mtproxy-unique-stats"
COLLECTOR_SERVICE="/etc/systemd/system/mtproxy-unique-collector.service"
MTPROXY_SERVICE="/etc/systemd/system/mtproxy.service"
UPDATE_CRON="/etc/cron.d/mtproxy-update"

if [[ "${EUID}" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

if ! [[ "${PUBLIC_PORT}" =~ ^[0-9]+$ && "${INTERNAL_PORT}" =~ ^[0-9]+$ && "${WORKERS}" =~ ^[0-9]+$ ]]; then
  echo "PUBLIC_PORT, INTERNAL_PORT and WORKERS must be numeric" >&2
  exit 1
fi

SERVER_IP="${SERVER_IP:-$(ip -4 -o addr show scope global up | awk '{print $4}' | cut -d/ -f1 | head -n1)}"
PUBLIC_HOST="${PUBLIC_HOST:-${SERVER_IP}}"

if [[ -z "${SERVER_IP}" ]]; then
  echo "could not detect server IPv4 address" >&2
  exit 1
fi

existing_listener="$(ss -ltnp 2>/dev/null | awk -v port=":${PUBLIC_PORT}$" '$4 ~ port {print $0}')"
if [[ -n "${existing_listener}" && "${existing_listener}" != *"mtproto-proxy"* ]]; then
  echo "port ${PUBLIC_PORT} is already in use: ${existing_listener}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y git curl build-essential libssl-dev zlib1g-dev python3 xxd sqlite3 tcpdump

if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
  rm -rf "${INSTALL_DIR}"
  git clone https://github.com/TelegramMessenger/MTProxy "${INSTALL_DIR}"
else
  git -C "${INSTALL_DIR}" pull --ff-only || true
fi

make -C "${INSTALL_DIR}" -j"$(nproc)"

install -d -m 755 "${DATA_DIR}" "${METRICS_DIR}" "${SECRET_DIR}"
curl -fsSL https://core.telegram.org/getProxySecret -o "${DATA_DIR}/proxy-secret"
curl -fsSL https://core.telegram.org/getProxyConfig -o "${DATA_DIR}/proxy-multi.conf"

if [[ -n "${MTPROXY_SECRET:-}" ]]; then
  SECRET="${MTPROXY_SECRET}"
elif [[ -s "${SECRET_FILE}" ]]; then
  SECRET="$(cat "${SECRET_FILE}")"
else
  SECRET="$(head -c 16 /dev/urandom | xxd -ps -c 32)"
fi

printf '%s' "${SECRET}" > "${SECRET_FILE}"
chmod 600 "${SECRET_FILE}"

SERVER_IP_REGEX="${SERVER_IP//./\\.}"

cat > "${COLLECTOR_BIN}" <<PY
#!/usr/bin/env python3
import os
import re
import signal
import sqlite3
import subprocess
import sys
import time

DB_PATH = "${METRICS_DIR}/clients.sqlite"
LINE_RE = re.compile(r"IP (\\d+\\.\\d+\\.\\d+\\.\\d+)\\.\\d+ > ${SERVER_IP_REGEX}\\.${PUBLIC_PORT}:")
CHILD = None


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS clients (
            ip TEXT PRIMARY KEY,
            first_seen_ts REAL NOT NULL,
            last_seen_ts REAL NOT NULL,
            hits INTEGER NOT NULL DEFAULT 1
        )
        """
    )
    conn.commit()
    return conn


def upsert_ip(conn, ip, ts):
    conn.execute(
        """
        INSERT INTO clients(ip, first_seen_ts, last_seen_ts, hits)
        VALUES(?, ?, ?, 1)
        ON CONFLICT(ip) DO UPDATE SET
            last_seen_ts=excluded.last_seen_ts,
            hits=clients.hits + 1
        """,
        (ip, ts, ts),
    )
    conn.commit()


def stop_child(*_args):
    global CHILD
    if CHILD and CHILD.poll() is None:
        CHILD.terminate()
    sys.exit(0)


def main():
    global CHILD
    signal.signal(signal.SIGTERM, stop_child)
    signal.signal(signal.SIGINT, stop_child)
    conn = init_db()

    while True:
        CHILD = subprocess.Popen(
            [
                "tcpdump",
                "-l",
                "-n",
                "-i",
                "any",
                "tcp[tcpflags] & tcp-syn != 0 and dst host ${SERVER_IP} and dst port ${PUBLIC_PORT}",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        for raw in CHILD.stdout:
            line = raw.strip()
            match = LINE_RE.search(line)
            if not match:
                continue
            upsert_ip(conn, match.group(1), time.time())
        time.sleep(1)


if __name__ == "__main__":
    main()
PY
chmod 755 "${COLLECTOR_BIN}"

cat > "${STATS_BIN}" <<PY
#!/usr/bin/env python3
import json
import os
import sqlite3
import sys
import time

DB_PATH = "${METRICS_DIR}/clients.sqlite"

if not os.path.exists(DB_PATH):
    data = {
        "total_unique_ips": 0,
        "unique_last_24h": 0,
        "unique_last_7d": 0,
    }
else:
    conn = sqlite3.connect(DB_PATH)
    now = time.time()
    data = {
        "total_unique_ips": conn.execute("SELECT COUNT(*) FROM clients").fetchone()[0],
        "unique_last_24h": conn.execute(
            "SELECT COUNT(*) FROM clients WHERE last_seen_ts >= ?", (now - 86400,)
        ).fetchone()[0],
        "unique_last_7d": conn.execute(
            "SELECT COUNT(*) FROM clients WHERE last_seen_ts >= ?", (now - 7 * 86400,)
        ).fetchone()[0],
    }

if "--json" in sys.argv:
    print(json.dumps(data, ensure_ascii=False))
else:
    for key, value in data.items():
        print(f"{key}\\t{value}")
PY
chmod 755 "${STATS_BIN}"

cat > "${MTPROXY_SERVICE}" <<SERVICE
[Unit]
Description=Telegram MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=8192
ExecStart=${INSTALL_DIR}/objs/bin/mtproto-proxy -u nobody -p ${INTERNAL_PORT} -H ${PUBLIC_PORT} -S ${SECRET} --aes-pwd ${DATA_DIR}/proxy-secret ${DATA_DIR}/proxy-multi.conf -M ${WORKERS} --http-stats -v
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

cat > "${COLLECTOR_SERVICE}" <<SERVICE
[Unit]
Description=Collect unique MTProxy client IPs
After=mtproxy.service
Requires=mtproxy.service

[Service]
Type=simple
ExecStart=${COLLECTOR_BIN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

cat > "${UPDATE_CRON}" <<CRON
17 4 * * * root curl -fsSL https://core.telegram.org/getProxySecret -o ${DATA_DIR}/proxy-secret && curl -fsSL https://core.telegram.org/getProxyConfig -o ${DATA_DIR}/proxy-multi.conf && systemctl restart mtproxy
CRON

systemctl daemon-reload
systemctl enable --now mtproxy
systemctl enable --now mtproxy-unique-collector

printf '\nProxy link:\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' "${PUBLIC_HOST}" "${PUBLIC_PORT}" "${SECRET}"
printf '\nMetric command on server:\n%s --json\n' "${STATS_BIN}"
printf '\nCurrent metric snapshot:\n'
"${STATS_BIN}" --json
