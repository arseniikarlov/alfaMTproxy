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
COLLECTOR_BIN="/usr/local/bin/mtproxy_unique_collector.py"
STATS_BIN="/usr/local/bin/mtproxy-unique-stats"
DASHBOARD_BIN="/usr/local/bin/mtproxy-dashboard"
COLLECTOR_SERVICE="/etc/systemd/system/mtproxy-unique-collector.service"
MTPROXY_SERVICE="/etc/systemd/system/mtproxy.service"
DASHBOARD_SERVICE="/etc/systemd/system/mtproxy-dashboard.service"
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
if [[ -n "${dashboard_listener}" && "${dashboard_listener}" != *"mtproxy-dashboard"* ]]; then
  echo "dashboard port ${DASHBOARD_PORT} is already in use: ${dashboard_listener}" >&2
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

cat > "${DASHBOARD_BIN}" <<PY
#!/usr/bin/env python3
import json
import os
import sqlite3
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

DB_PATH = "${METRICS_DIR}/clients.sqlite"
BIND = "${DASHBOARD_BIND}"
PORT = ${DASHBOARD_PORT}
TOKEN = "${DASHBOARD_TOKEN}"
PUBLIC_HOST = "${PUBLIC_HOST}"
PUBLIC_PORT = ${PUBLIC_PORT}

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
              <th>Последняя активность</th>
              <th>Хитов</th>
            </tr>
          </thead>
          <tbody id="recent-body">
            <tr><td colspan="3">Пока пусто</td></tr>
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
        body.innerHTML = '<tr><td colspan="3">Пока пусто</td></tr>';
        return;
      }
      body.innerHTML = items.map((item) => (
        '<tr>' +
          '<td>' + item.ip + '</td>' +
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
    recent_rows = conn.execute(
        "SELECT ip, last_seen_ts, hits FROM clients ORDER BY last_seen_ts DESC LIMIT 15"
    ).fetchall()
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

printf '\nProxy link:\nhttps://t.me/proxy?server=%s&port=%s&secret=dd%s\n' "${PUBLIC_HOST}" "${PUBLIC_PORT}" "${SECRET}"
printf '\nMetric command on server:\n%s --json\n' "${STATS_BIN}"
printf '\nDashboard link:\nhttp://%s:%s/?token=%s\n' "${PUBLIC_HOST}" "${DASHBOARD_PORT}" "${DASHBOARD_TOKEN}"
printf '\nCurrent metric snapshot:\n'
"${STATS_BIN}" --json
