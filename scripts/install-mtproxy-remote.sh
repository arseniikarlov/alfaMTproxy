#!/usr/bin/env bash
set -euo pipefail

PUBLIC_PORT="${PUBLIC_PORT:-443}"
INTERNAL_PORT="${INTERNAL_PORT:-2398}"
WORKERS="${WORKERS:-1}"
DASHBOARD_PORT="${DASHBOARD_PORT:-18080}"
DASHBOARD_BIND="${DASHBOARD_BIND:-0.0.0.0}"
INSTALL_DIR="${INSTALL_DIR:-/opt/MTProxy}"
DATA_DIR="${DATA_DIR:-/opt/mtproxy-data}"
METRICS_DIR="${METRICS_DIR:-/var/lib/mtproxy-metrics}"
SECRET_DIR="${SECRET_DIR:-/etc/mtproxy}"
SECRET_FILE="${SECRET_FILE:-${SECRET_DIR}/secret}"
DASHBOARD_TOKEN_FILE="${DASHBOARD_TOKEN_FILE:-${SECRET_DIR}/dashboard-token}"
SYSCTL_FILE="/etc/sysctl.d/60-mtproxy-reliability.conf"
COLLECTOR_BIN="/usr/local/bin/mtproxy_unique_collector.py"
STATS_BIN="/usr/local/bin/mtproxy-unique-stats"
DASHBOARD_BIN="/usr/local/bin/mtproxy-dashboard"
WATCHDOG_BIN="/usr/local/bin/mtproxy-watchdog"
COLLECTOR_SERVICE="/etc/systemd/system/mtproxy-unique-collector.service"
MTPROXY_SERVICE="/etc/systemd/system/mtproxy.service"
DASHBOARD_SERVICE="/etc/systemd/system/mtproxy-dashboard.service"
WATCHDOG_SERVICE="/etc/systemd/system/mtproxy-watchdog.service"
WATCHDOG_TIMER="/etc/systemd/system/mtproxy-watchdog.timer"
UPDATE_CRON="/etc/cron.d/mtproxy-update"

if [[ "${EUID}" -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

if ! [[ "${PUBLIC_PORT}" =~ ^[0-9]+$ && "${INTERNAL_PORT}" =~ ^[0-9]+$ && "${WORKERS}" =~ ^[0-9]+$ && "${DASHBOARD_PORT}" =~ ^[0-9]+$ ]]; then
  echo "PUBLIC_PORT, INTERNAL_PORT, WORKERS and DASHBOARD_PORT must be numeric" >&2
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

dashboard_listener="$(ss -ltnp 2>/dev/null | awk -v port=":${DASHBOARD_PORT}$" '$4 ~ port {print $0}')"
if [[ -n "${dashboard_listener}" ]]; then
  if systemctl is-active --quiet mtproxy-dashboard; then
    systemctl stop mtproxy-dashboard || true
    sleep 1
    dashboard_listener="$(ss -ltnp 2>/dev/null | awk -v port=":${DASHBOARD_PORT}$" '$4 ~ port {print $0}')"
  fi
  if [[ -n "${dashboard_listener}" ]]; then
    echo "dashboard port ${DASHBOARD_PORT} is already in use: ${dashboard_listener}" >&2
    exit 1
  fi
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

cat > "${SYSCTL_FILE}" <<SYSCTL
kernel.pid_max = 65535
SYSCTL
sysctl -q -p "${SYSCTL_FILE}" >/dev/null 2>&1 || sysctl -w kernel.pid_max=65535 >/dev/null 2>&1 || true

if [[ -n "${MTPROXY_SECRET:-}" ]]; then
  SECRET="${MTPROXY_SECRET}"
elif [[ -s "${SECRET_FILE}" ]]; then
  SECRET="$(cat "${SECRET_FILE}")"
else
  SECRET="$(head -c 16 /dev/urandom | xxd -ps -c 32)"
fi

if [[ -n "${MTPROXY_DASHBOARD_TOKEN:-}" ]]; then
  DASHBOARD_TOKEN="${MTPROXY_DASHBOARD_TOKEN}"
elif [[ -s "${DASHBOARD_TOKEN_FILE}" ]]; then
  DASHBOARD_TOKEN="$(cat "${DASHBOARD_TOKEN_FILE}")"
else
  DASHBOARD_TOKEN="$(head -c 18 /dev/urandom | xxd -ps -c 36)"
fi

printf '%s' "${SECRET}" > "${SECRET_FILE}"
printf '%s' "${DASHBOARD_TOKEN}" > "${DASHBOARD_TOKEN_FILE}"
chmod 600 "${SECRET_FILE}" "${DASHBOARD_TOKEN_FILE}"

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
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS geo_cache (
            ip TEXT PRIMARY KEY,
            country TEXT,
            region_name TEXT,
            city TEXT,
            timezone TEXT,
            is_mobile INTEGER,
            is_proxy INTEGER,
            is_hosting INTEGER,
            status TEXT NOT NULL DEFAULT 'pending',
            source TEXT,
            last_checked_ts REAL NOT NULL DEFAULT 0,
            last_error TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS geo_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
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
        "recent_clients": [],
    }
else:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS geo_cache (
            ip TEXT PRIMARY KEY,
            country TEXT,
            region_name TEXT,
            city TEXT,
            timezone TEXT,
            is_mobile INTEGER,
            is_proxy INTEGER,
            is_hosting INTEGER,
            status TEXT NOT NULL DEFAULT 'pending',
            source TEXT,
            last_checked_ts REAL NOT NULL DEFAULT 0,
            last_error TEXT
        )
        """
    )
    now = time.time()
    data = {
        "total_unique_ips": conn.execute("SELECT COUNT(*) FROM clients").fetchone()[0],
        "unique_last_24h": conn.execute(
            "SELECT COUNT(*) FROM clients WHERE last_seen_ts >= ?", (now - 86400,)
        ).fetchone()[0],
        "unique_last_7d": conn.execute(
            "SELECT COUNT(*) FROM clients WHERE last_seen_ts >= ?", (now - 7 * 86400,)
        ).fetchone()[0],
        "recent_clients": [
            {
                "ip": row["ip"],
                "last_seen_ts": row["last_seen_ts"],
                "hits": row["hits"],
                "city": row["city"] or "",
                "region_name": row["region_name"] or "",
                "country": row["country"] or "",
                "location": ", ".join(
                    [part for part in [row["city"], row["region_name"], row["country"]] if part]
                ),
            }
            for row in conn.execute(
                """
                SELECT c.ip, c.last_seen_ts, c.hits, g.city, g.region_name, g.country
                FROM clients c
                LEFT JOIN geo_cache g ON g.ip = c.ip
                ORDER BY c.last_seen_ts DESC
                LIMIT 15
                """
            ).fetchall()
        ],
    }

if "--json" in sys.argv:
    print(json.dumps(data, ensure_ascii=False))
else:
    for key, value in data.items():
        print(f"{key}\\t{value}")
PY
chmod 755 "${STATS_BIN}"

cat > "${DASHBOARD_BIN}" <<PY
#!/usr/bin/env python3
import json
import os
import sqlite3
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

DB_PATH = "${METRICS_DIR}/clients.sqlite"
BIND = "${DASHBOARD_BIND}"
PORT = ${DASHBOARD_PORT}
TOKEN = "${DASHBOARD_TOKEN}"
PUBLIC_HOST = "${PUBLIC_HOST}"
PUBLIC_PORT = ${PUBLIC_PORT}
GEOIP_BATCH_ENDPOINT = "http://ip-api.com/batch?fields=status,message,query,country,regionName,city,timezone,mobile,proxy,hosting&lang=ru"
GEOIP_TIMEOUT = 4
GEOIP_BATCH_SIZE = 15
GEOIP_SUCCESS_TTL = 30 * 86400
GEOIP_ERROR_TTL = 6 * 3600
GEOIP_MIN_BATCH_INTERVAL = 5

HTML = """<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>MTProxy Metrics</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0e1116;
      --panel: rgba(20, 26, 36, 0.88);
      --card: rgba(29, 37, 50, 0.92);
      --line: rgba(255, 255, 255, 0.08);
      --text: #eff3f8;
      --muted: #9eaabc;
      --accent: #7cf7c7;
      --accent-2: #55b7ff;
      --danger: #ff8b8b;
      --shadow: 0 24px 80px rgba(0, 0, 0, 0.35);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--text);
      background:
        radial-gradient(circle at top left, rgba(85, 183, 255, 0.22), transparent 28%),
        radial-gradient(circle at top right, rgba(124, 247, 199, 0.18), transparent 24%),
        linear-gradient(160deg, #0b0e13 0%, #101725 55%, #0d131c 100%);
    }
    .shell {
      max-width: 1120px;
      margin: 0 auto;
      padding: 40px 20px 64px;
    }
    .hero {
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 28px;
      padding: 28px;
      box-shadow: var(--shadow);
      backdrop-filter: blur(18px);
    }
    .eyebrow {
      display: inline-flex;
      gap: 8px;
      align-items: center;
      padding: 8px 12px;
      border-radius: 999px;
      background: rgba(124, 247, 199, 0.08);
      color: var(--accent);
      font-size: 13px;
      letter-spacing: 0.04em;
      text-transform: uppercase;
    }
    h1 {
      margin: 18px 0 10px;
      font-size: clamp(32px, 6vw, 52px);
      line-height: 0.96;
      letter-spacing: -0.04em;
    }
    .sub {
      max-width: 720px;
      margin: 0;
      color: var(--muted);
      font-size: 16px;
      line-height: 1.6;
    }
    .meta {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      margin-top: 18px;
      color: var(--muted);
      font-size: 14px;
    }
    .meta span {
      padding: 8px 12px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.03);
    }
    .token-box,
    .error-box {
      margin-top: 24px;
      border-radius: 22px;
      padding: 18px;
      border: 1px solid var(--line);
      background: rgba(255, 255, 255, 0.03);
    }
    .token-box form {
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      margin-top: 12px;
    }
    input {
      min-width: min(320px, 100%);
      flex: 1 1 320px;
      height: 46px;
      border-radius: 14px;
      border: 1px solid var(--line);
      padding: 0 14px;
      background: rgba(255, 255, 255, 0.04);
      color: var(--text);
      font-size: 15px;
    }
    button {
      height: 46px;
      border: 0;
      border-radius: 14px;
      padding: 0 18px;
      font-weight: 700;
      color: #0a1017;
      background: linear-gradient(135deg, var(--accent), #d3ffe9);
      cursor: pointer;
    }
    button.secondary {
      color: var(--text);
      background: rgba(255, 255, 255, 0.06);
      border: 1px solid var(--line);
    }
    .grid {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 16px;
      margin-top: 24px;
    }
    .card {
      padding: 20px;
      border-radius: 24px;
      border: 1px solid var(--line);
      background: var(--card);
      box-shadow: var(--shadow);
      min-height: 156px;
    }
    .card .label {
      color: var(--muted);
      font-size: 13px;
      text-transform: uppercase;
      letter-spacing: 0.08em;
    }
    .card .value {
      margin-top: 18px;
      font-size: clamp(34px, 6vw, 58px);
      letter-spacing: -0.06em;
      line-height: 0.9;
    }
    .card .hint {
      margin-top: 12px;
      color: var(--muted);
      font-size: 14px;
    }
    .card.primary .value { color: var(--accent); }
    .card.secondary .value { color: var(--accent-2); }
    .panel {
      margin-top: 24px;
      padding: 20px;
      border-radius: 24px;
      border: 1px solid var(--line);
      background: var(--panel);
      box-shadow: var(--shadow);
    }
    .panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 16px;
    }
    .panel-title {
      margin: 0;
      font-size: 22px;
      letter-spacing: -0.03em;
    }
    .panel-note {
      color: var(--muted);
      font-size: 14px;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: 14px;
    }
    th, td {
      text-align: left;
      padding: 12px 10px;
      border-bottom: 1px solid var(--line);
    }
    th {
      color: var(--muted);
      font-weight: 600;
    }
    .location-main {
      color: var(--text);
      font-weight: 600;
    }
    .location-sub {
      margin-top: 4px;
      color: var(--muted);
      font-size: 12px;
    }
    .badges {
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
      margin-top: 8px;
    }
    .badge {
      display: inline-flex;
      align-items: center;
      height: 22px;
      padding: 0 8px;
      border-radius: 999px;
      background: rgba(255, 255, 255, 0.06);
      border: 1px solid var(--line);
      color: var(--muted);
      font-size: 11px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .status {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      color: var(--muted);
      font-size: 14px;
    }
    .dot {
      width: 10px;
      height: 10px;
      border-radius: 999px;
      background: var(--danger);
      box-shadow: 0 0 0 8px rgba(255, 139, 139, 0.12);
    }
    .dot.ok {
      background: var(--accent);
      box-shadow: 0 0 0 8px rgba(124, 247, 199, 0.12);
    }
    .hidden { display: none; }
    @media (max-width: 860px) {
      .grid { grid-template-columns: 1fr; }
      .shell { padding: 24px 14px 40px; }
      .hero, .panel, .card { border-radius: 20px; }
      table { display: block; overflow-x: auto; }
    }
  </style>
</head>
<body>
  <div class="shell">
    <section class="hero">
      <div class="eyebrow">MTProxy Live</div>
      <h1>Онлайн-метрика прокси</h1>
      <p class="sub">
        Живая панель по уникальным подключениям к Telegram MTProxy. Данные обновляются автоматически каждые 5 секунд.
      </p>
      <div class="meta">
        <span>Proxy: <strong>""" + PUBLIC_HOST + ":" + str(PUBLIC_PORT) + """</strong></span>
        <span>API: <strong>/api/metrics</strong></span>
        <span id="last-update">Обновление: ещё не было</span>
      </div>
      <div class="token-box" id="token-box">
        <strong>Нужен токен доступа</strong>
        <p class="sub">Открой страницу по полной ссылке с токеном или вставь токен вручную. После первого успешного входа он сохранится в браузере.</p>
        <form id="token-form">
          <input id="token-input" type="password" placeholder="Вставь токен дашборда">
          <button type="submit">Открыть дашборд</button>
          <button type="button" class="secondary" id="clear-token">Сбросить токен</button>
        </form>
      </div>
      <div class="error-box hidden" id="error-box"></div>
    </section>

    <section id="dashboard" class="hidden">
      <div class="grid">
        <article class="card primary">
          <div class="label">Всего уникальных IP</div>
          <div class="value" id="total">0</div>
          <div class="hint">С момента запуска сбора метрики</div>
        </article>
        <article class="card secondary">
          <div class="label">Уникальные за 24 часа</div>
          <div class="value" id="day">0</div>
          <div class="hint">Последние сутки</div>
        </article>
        <article class="card">
          <div class="label">Уникальные за 7 дней</div>
          <div class="value" id="week">0</div>
          <div class="hint">Последняя неделя</div>
        </article>
      </div>

      <section class="panel">
        <div class="panel-head">
          <div>
            <h2 class="panel-title">Недавние подключения</h2>
            <div class="panel-note">Последние 15 IP, которые дошли до прокси</div>
          </div>
          <div class="status"><span class="dot" id="status-dot"></span><span id="status-text">ожидание данных</span></div>
        </div>
        <table>
          <thead>
            <tr>
              <th>IP</th>
              <th>Город / страна</th>
              <th>Последняя активность</th>
              <th>Хитов</th>
            </tr>
          </thead>
          <tbody id="recent-body">
            <tr><td colspan="4">Пока пусто</td></tr>
          </tbody>
        </table>
      </section>
    </section>
  </div>

  <script>
    const tokenBox = document.getElementById('token-box');
    const tokenForm = document.getElementById('token-form');
    const tokenInput = document.getElementById('token-input');
    const clearButton = document.getElementById('clear-token');
    const dashboard = document.getElementById('dashboard');
    const errorBox = document.getElementById('error-box');
    const statusDot = document.getElementById('status-dot');
    const statusText = document.getElementById('status-text');
    const lastUpdate = document.getElementById('last-update');

    const params = new URLSearchParams(window.location.search);
    const tokenFromQuery = params.get('token');
    if (tokenFromQuery) {
      sessionStorage.setItem('mtproxyToken', tokenFromQuery);
      params.delete('token');
      const next = window.location.pathname + (params.toString() ? '?' + params.toString() : '');
      window.history.replaceState({}, '', next);
    }

    function getToken() {
      return sessionStorage.getItem('mtproxyToken') || '';
    }

    function setToken(token) {
      sessionStorage.setItem('mtproxyToken', token);
    }

    function clearToken() {
      sessionStorage.removeItem('mtproxyToken');
      tokenInput.value = '';
      tokenBox.classList.remove('hidden');
      dashboard.classList.add('hidden');
      hideError();
      setStatus(false, 'токен очищен');
    }

    function showError(message) {
      errorBox.textContent = message;
      errorBox.classList.remove('hidden');
    }

    function hideError() {
      errorBox.classList.add('hidden');
      errorBox.textContent = '';
    }

    function setStatus(ok, text) {
      statusDot.classList.toggle('ok', ok);
      statusText.textContent = text;
    }

    function formatTs(value) {
      if (!value) return 'нет данных';
      return new Date(value * 1000).toLocaleString();
    }

    function renderRecent(items) {
      const body = document.getElementById('recent-body');
      if (!items.length) {
        body.innerHTML = '<tr><td colspan="4">Пока пусто</td></tr>';
        return;
      }
      const renderLocation = (item) => {
        const main = item.location || (item.geo_status === 'lookup_pending' ? 'Определяется...' : 'Нет данных');
        const parts = [];
        if (item.timezone) parts.push(item.timezone);
        const badges = [];
        if (item.is_mobile) badges.push('mobile');
        if (item.is_proxy) badges.push('proxy');
        if (item.is_hosting) badges.push('hosting');
        return (
          '<div class="location-main">' + main + '</div>' +
          (parts.length ? '<div class="location-sub">' + parts.join(' • ') + '</div>' : '') +
          (badges.length ? '<div class="badges">' + badges.map((badge) => '<span class="badge">' + badge + '</span>').join('') + '</div>' : '')
        );
      };
      body.innerHTML = items.map((item) => (
        '<tr>' +
          '<td>' + item.ip + '</td>' +
          '<td>' + renderLocation(item) + '</td>' +
          '<td>' + formatTs(item.last_seen_ts) + '</td>' +
          '<td>' + item.hits + '</td>' +
        '</tr>'
      )).join('');
    }

    async function loadMetrics() {
      const token = getToken();
      if (!token) {
        tokenBox.classList.remove('hidden');
        dashboard.classList.add('hidden');
        setStatus(false, 'ожидание токена');
        return;
      }

      const response = await fetch('/api/metrics', {
        headers: { 'X-MTProxy-Token': token }
      });

      if (response.status === 401) {
        clearToken();
        showError('Токен не подошёл. Вставь актуальный токен дашборда.');
        throw new Error('unauthorized');
      }

      if (!response.ok) {
        throw new Error('HTTP ' + response.status);
      }

      const data = await response.json();
      document.getElementById('total').textContent = String(data.total_unique_ips);
      document.getElementById('day').textContent = String(data.unique_last_24h);
      document.getElementById('week').textContent = String(data.unique_last_7d);
      lastUpdate.textContent = 'Обновление: ' + new Date().toLocaleTimeString();
      renderRecent(data.recent_clients || []);
      tokenBox.classList.add('hidden');
      dashboard.classList.remove('hidden');
      hideError();
      setStatus(true, 'данные обновлены');
    }

    tokenForm.addEventListener('submit', async (event) => {
      event.preventDefault();
      const token = tokenInput.value.trim();
      if (!token) return;
      setToken(token);
      try {
        await loadMetrics();
      } catch (error) {
        setStatus(false, 'ошибка авторизации');
      }
    });

    clearButton.addEventListener('click', clearToken);

    async function tick() {
      try {
        await loadMetrics();
      } catch (error) {
        if (error.message !== 'unauthorized') {
          showError('Не удалось загрузить данные: ' + error.message);
          setStatus(false, 'ошибка соединения');
        }
      }
    }

    tick();
    setInterval(tick, 5000);
  </script>
</body>
</html>
"""


def ensure_db(conn):
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
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS geo_cache (
            ip TEXT PRIMARY KEY,
            country TEXT,
            region_name TEXT,
            city TEXT,
            timezone TEXT,
            is_mobile INTEGER,
            is_proxy INTEGER,
            is_hosting INTEGER,
            status TEXT NOT NULL DEFAULT 'pending',
            source TEXT,
            last_checked_ts REAL NOT NULL DEFAULT 0,
            last_error TEXT
        )
        """
    )
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS geo_meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        )
        """
    )
    conn.commit()


def get_meta(conn, key, default=""):
    row = conn.execute("SELECT value FROM geo_meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else default


def set_meta(conn, key, value):
    conn.execute(
        """
        INSERT INTO geo_meta(key, value)
        VALUES(?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
        (key, value),
    )
    conn.commit()


def geo_row_to_dict(row):
    if row is None:
        return None
    return {
        "ip": row["ip"],
        "country": row["country"] or "",
        "region_name": row["region_name"] or "",
        "city": row["city"] or "",
        "timezone": row["timezone"] or "",
        "is_mobile": bool(row["is_mobile"]),
        "is_proxy": bool(row["is_proxy"]),
        "is_hosting": bool(row["is_hosting"]),
        "status": row["status"],
        "last_checked_ts": row["last_checked_ts"],
        "last_error": row["last_error"] or "",
    }


def fetch_geo_map(conn, ips):
    if not ips:
        return {}
    placeholders = ",".join("?" for _ in ips)
    rows = conn.execute(
        f"""
        SELECT ip, country, region_name, city, timezone, is_mobile, is_proxy, is_hosting,
               status, last_checked_ts, last_error
        FROM geo_cache
        WHERE ip IN ({placeholders})
        """,
        ips,
    ).fetchall()
    return {row["ip"]: geo_row_to_dict(row) for row in rows}


def geo_cache_is_stale(geo, now):
    if geo is None:
        return True
    ttl = GEOIP_SUCCESS_TTL if geo["status"] == "success" else GEOIP_ERROR_TTL
    return geo["last_checked_ts"] < now - ttl


def store_geo_success(conn, ip, payload, now):
    conn.execute(
        """
        INSERT INTO geo_cache(
            ip, country, region_name, city, timezone, is_mobile, is_proxy, is_hosting,
            status, source, last_checked_ts, last_error
        )
        VALUES(?, ?, ?, ?, ?, ?, ?, ?, 'success', 'ip-api', ?, NULL)
        ON CONFLICT(ip) DO UPDATE SET
            country = excluded.country,
            region_name = excluded.region_name,
            city = excluded.city,
            timezone = excluded.timezone,
            is_mobile = excluded.is_mobile,
            is_proxy = excluded.is_proxy,
            is_hosting = excluded.is_hosting,
            status = 'success',
            source = 'ip-api',
            last_checked_ts = excluded.last_checked_ts,
            last_error = NULL
        """,
        (
            ip,
            payload.get("country") or "",
            payload.get("regionName") or "",
            payload.get("city") or "",
            payload.get("timezone") or "",
            1 if payload.get("mobile") else 0,
            1 if payload.get("proxy") else 0,
            1 if payload.get("hosting") else 0,
            now,
        ),
    )


def store_geo_error(conn, ip, message, now):
    conn.execute(
        """
        INSERT INTO geo_cache(
            ip, country, region_name, city, timezone, is_mobile, is_proxy, is_hosting,
            status, source, last_checked_ts, last_error
        )
        VALUES(?, '', '', '', '', 0, 0, 0, 'error', 'ip-api', ?, ?)
        ON CONFLICT(ip) DO UPDATE SET
            status = 'error',
            source = 'ip-api',
            last_checked_ts = excluded.last_checked_ts,
            last_error = excluded.last_error
        """,
        (ip, now, message[:250]),
    )


def maybe_lookup_geo(conn, ips, now):
    batch = []
    for ip in ips:
        if ip and ip not in batch:
            batch.append(ip)
    batch = batch[:GEOIP_BATCH_SIZE]
    if not batch:
        return

    resume_ts = float(get_meta(conn, "geo_lookup_resume_ts", "0") or 0)
    if now < resume_ts:
        return

    last_batch_ts = float(get_meta(conn, "geo_lookup_last_batch_ts", "0") or 0)
    if now - last_batch_ts < GEOIP_MIN_BATCH_INTERVAL:
        return

    set_meta(conn, "geo_lookup_last_batch_ts", str(now))

    req = Request(
        GEOIP_BATCH_ENDPOINT,
        data=json.dumps([{"query": ip} for ip in batch]).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "mtproxy-dashboard/1.1",
        },
    )

    try:
        with urlopen(req, timeout=GEOIP_TIMEOUT) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
            rl = resp.headers.get("X-Rl")
            ttl = resp.headers.get("X-Ttl")
            if rl and ttl and rl.isdigit() and ttl.isdigit() and int(rl) <= 0:
                set_meta(conn, "geo_lookup_resume_ts", str(now + int(ttl)))
    except HTTPError as exc:
        ttl = exc.headers.get("X-Ttl") if exc.headers else None
        if exc.code == 429:
            wait_for = int(ttl) if ttl and ttl.isdigit() else 60
            set_meta(conn, "geo_lookup_resume_ts", str(now + wait_for))
        for ip in batch:
            store_geo_error(conn, ip, f"http_{exc.code}", now)
        conn.commit()
        return
    except (URLError, OSError, TimeoutError, ValueError, json.JSONDecodeError) as exc:
        for ip in batch:
            store_geo_error(conn, ip, str(exc), now)
        conn.commit()
        return

    seen = set()
    for item in payload if isinstance(payload, list) else []:
        ip = item.get("query")
        if not ip:
            continue
        seen.add(ip)
        if item.get("status") == "success":
            store_geo_success(conn, ip, item, now)
        else:
            store_geo_error(conn, ip, item.get("message", "lookup_failed"), now)

    for ip in batch:
        if ip not in seen:
            store_geo_error(conn, ip, "no_response", now)

    conn.commit()


def format_location(geo):
    if not geo or geo["status"] != "success":
        return ""
    parts = [geo["city"], geo["region_name"], geo["country"]]
    parts = [part for part in parts if part]
    return ", ".join(parts)


def query_data():
    now = time.time()
    if not os.path.exists(DB_PATH):
        return {
            "total_unique_ips": 0,
            "unique_last_24h": 0,
            "unique_last_7d": 0,
            "recent_clients": [],
            "generated_at": now,
        }

    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    ensure_db(conn)

    recent_rows = conn.execute(
        "SELECT ip, last_seen_ts, hits FROM clients ORDER BY last_seen_ts DESC LIMIT 15"
    ).fetchall()
    recent_ips = [row["ip"] for row in recent_rows]
    geo_map = fetch_geo_map(conn, recent_ips)

    lookup_needed = [ip for ip in recent_ips if geo_cache_is_stale(geo_map.get(ip), now)]
    maybe_lookup_geo(conn, lookup_needed, now)
    geo_map = fetch_geo_map(conn, recent_ips)

    return {
        "total_unique_ips": conn.execute("SELECT COUNT(*) FROM clients").fetchone()[0],
        "unique_last_24h": conn.execute(
            "SELECT COUNT(*) FROM clients WHERE last_seen_ts >= ?", (now - 86400,)
        ).fetchone()[0],
        "unique_last_7d": conn.execute(
            "SELECT COUNT(*) FROM clients WHERE last_seen_ts >= ?", (now - 7 * 86400,)
        ).fetchone()[0],
        "recent_clients": [
            {
                "ip": row["ip"],
                "last_seen_ts": row["last_seen_ts"],
                "last_seen_iso": datetime.fromtimestamp(
                    row["last_seen_ts"], tz=timezone.utc
                ).isoformat(),
                "hits": row["hits"],
                "city": (geo_map.get(row["ip"]) or {}).get("city", ""),
                "region_name": (geo_map.get(row["ip"]) or {}).get("region_name", ""),
                "country": (geo_map.get(row["ip"]) or {}).get("country", ""),
                "timezone": (geo_map.get(row["ip"]) or {}).get("timezone", ""),
                "is_mobile": (geo_map.get(row["ip"]) or {}).get("is_mobile", False),
                "is_proxy": (geo_map.get(row["ip"]) or {}).get("is_proxy", False),
                "is_hosting": (geo_map.get(row["ip"]) or {}).get("is_hosting", False),
                "geo_status": (geo_map.get(row["ip"]) or {}).get("status", "lookup_pending"),
                "location": format_location(geo_map.get(row["ip"])),
            }
            for row in recent_rows
        ],
        "generated_at": now,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "mtproxy-dashboard/1.0"

    def log_message(self, format, *args):
        return

    def _authorized(self, parsed):
        params = parse_qs(parsed.query)
        token = params.get("token", [""])[0]
        if token and token == TOKEN:
            return True
        if self.headers.get("X-MTProxy-Token", "") == TOKEN:
            return True
        auth = self.headers.get("Authorization", "")
        if auth == f"Bearer {TOKEN}":
            return True
        return False

    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self):
        body = HTML.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self._send_html()
            return
        if parsed.path == "/healthz":
            self._send_json(200, {"ok": True})
            return
        if parsed.path == "/api/metrics":
            if not self._authorized(parsed):
                self._send_json(401, {"error": "unauthorized"})
                return
            self._send_json(200, query_data())
            return
        self._send_json(404, {"error": "not_found"})


def main():
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
PY
chmod 755 "${DASHBOARD_BIN}"

cat > "${MTPROXY_SERVICE}" <<SERVICE
[Unit]
Description=Telegram MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
LimitNOFILE=65536
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

cat > "${DASHBOARD_SERVICE}" <<SERVICE
[Unit]
Description=MTProxy metrics dashboard
After=network-online.target mtproxy-unique-collector.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${DASHBOARD_BIN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

cat > "${WATCHDOG_BIN}" <<SH
#!/usr/bin/env bash
set -euo pipefail

PUBLIC_PORT="${PUBLIC_PORT}"
INTERNAL_PORT="${INTERNAL_PORT}"
DASHBOARD_PORT="${DASHBOARD_PORT}"

log() {
  logger -t mtproxy-watchdog "\$*"
  printf '%s\n' "\$*"
}

is_listening() {
  local port="\$1"
  ss -H -ltn "sport = :\${port}" | grep -q .
}

http_ok() {
  local url="\$1"
  curl -fsS --max-time 5 "\${url}" >/dev/null
}

restart_unit() {
  local unit="\$1"
  local reason="\$2"
  log "\${unit}: \${reason}; restarting"
  systemctl restart "\${unit}"
}

if ! systemctl is-active --quiet mtproxy; then
  restart_unit mtproxy "inactive"
elif ! is_listening "${PUBLIC_PORT}" || ! is_listening "${INTERNAL_PORT}" || ! http_ok "http://127.0.0.1:${INTERNAL_PORT}/stats"; then
  restart_unit mtproxy "port or stats check failed"
fi

if ! systemctl is-active --quiet mtproxy-unique-collector; then
  restart_unit mtproxy-unique-collector "inactive"
fi

if ! systemctl is-active --quiet mtproxy-dashboard; then
  restart_unit mtproxy-dashboard "inactive"
elif ! is_listening "${DASHBOARD_PORT}" || ! http_ok "http://127.0.0.1:${DASHBOARD_PORT}/healthz"; then
  restart_unit mtproxy-dashboard "port or healthz check failed"
fi

sleep 2

if ! systemctl is-active --quiet mtproxy || ! is_listening "${PUBLIC_PORT}" || ! is_listening "${INTERNAL_PORT}" || ! http_ok "http://127.0.0.1:${INTERNAL_PORT}/stats"; then
  log "mtproxy remains unhealthy after remediation"
  exit 1
fi

if ! systemctl is-active --quiet mtproxy-unique-collector; then
  log "mtproxy-unique-collector remains unhealthy after remediation"
  exit 1
fi

if ! systemctl is-active --quiet mtproxy-dashboard || ! is_listening "${DASHBOARD_PORT}" || ! http_ok "http://127.0.0.1:${DASHBOARD_PORT}/healthz"; then
  log "mtproxy-dashboard remains unhealthy after remediation"
  exit 1
fi

log "all checks passed"
SH
chmod 755 "${WATCHDOG_BIN}"

cat > "${WATCHDOG_SERVICE}" <<SERVICE
[Unit]
Description=Check and heal MTProxy services
After=network-online.target mtproxy.service mtproxy-unique-collector.service mtproxy-dashboard.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WATCHDOG_BIN}
SERVICE

cat > "${WATCHDOG_TIMER}" <<SERVICE
[Unit]
Description=Run MTProxy watchdog every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=15s
Persistent=true
Unit=mtproxy-watchdog.service

[Install]
WantedBy=timers.target
SERVICE

cat > "${UPDATE_CRON}" <<CRON
17 4 * * * root curl -fsSL https://core.telegram.org/getProxySecret -o ${DATA_DIR}/proxy-secret && curl -fsSL https://core.telegram.org/getProxyConfig -o ${DATA_DIR}/proxy-multi.conf && systemctl restart mtproxy
CRON

if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${DASHBOARD_PORT}/tcp" >/dev/null 2>&1 || true
  fi
fi

systemctl daemon-reload
systemctl enable --now mtproxy
systemctl enable --now mtproxy-unique-collector
systemctl enable --now mtproxy-dashboard
systemctl enable --now mtproxy-watchdog.timer
systemctl start mtproxy-watchdog.service

printf '\nProxy link:\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' "${PUBLIC_HOST}" "${PUBLIC_PORT}" "${SECRET}"
printf '\nMetric command on server:\n%s --json\n' "${STATS_BIN}"
printf '\nDashboard link:\nhttp://%s:%s/?token=%s\n' "${PUBLIC_HOST}" "${DASHBOARD_PORT}" "${DASHBOARD_TOKEN}"
printf '\nWatchdog:\nservice=%s\ntimer=%s\n' "mtproxy-watchdog.service" "mtproxy-watchdog.timer"
printf '\nCurrent metric snapshot:\n'
"${STATS_BIN}" --json
