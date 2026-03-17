#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${MTPROXY_CONFIG:-${SCRIPT_DIR}/../.mtproxy.env}"
KNOWN_HOSTS="${HOME}/.ssh/known_hosts_mtproxy"
REMOTE_INSTALLER="/root/install-mtproxy-remote.sh"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
fi

TARGET="${1:-${MTPROXY_HOST:-}}"
PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_PORT="${PUBLIC_PORT:-443}"
INTERNAL_PORT="${INTERNAL_PORT:-2398}"
WORKERS="${WORKERS:-1}"

if [[ -z "${TARGET}" ]]; then
  echo "usage: $0 user@host" >&2
  exit 1
fi

if [[ -z "${PUBLIC_HOST}" ]]; then
  PUBLIC_HOST="${TARGET#*@}"
fi

mkdir -p "${HOME}/.ssh"

SSH_OPTS=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${KNOWN_HOSTS}"
)

scp "${SSH_OPTS[@]}" "${SCRIPT_DIR}/install-mtproxy-remote.sh" "${TARGET}:${REMOTE_INSTALLER}"

REMOTE_ENV=(
  "PUBLIC_HOST=$(printf '%q' "${PUBLIC_HOST}")"
  "PUBLIC_PORT=$(printf '%q' "${PUBLIC_PORT}")"
  "INTERNAL_PORT=$(printf '%q' "${INTERNAL_PORT}")"
  "WORKERS=$(printf '%q' "${WORKERS}")"
)

if [[ -n "${MTPROXY_SECRET:-}" ]]; then
  REMOTE_ENV+=("MTPROXY_SECRET=$(printf '%q' "${MTPROXY_SECRET}")")
fi

ssh "${SSH_OPTS[@]}" "${TARGET}" "$(printf '%s ' "${REMOTE_ENV[@]}") bash ${REMOTE_INSTALLER}"
