#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MTPROXY_CONFIG:-${SCRIPT_DIR}/../.mtproxy.env}"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts_mtproxy"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

HOST="${MTPROXY_HOST:-}"

if [[ -z "${HOST}" ]]; then
  echo "set MTPROXY_HOST in .mtproxy.env or environment" >&2
  exit 1
fi

mkdir -p "${HOME}/.ssh"

exec ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="${KNOWN_HOSTS}" \
  "$HOST" \
  mtproxy-unique-stats "$@"
