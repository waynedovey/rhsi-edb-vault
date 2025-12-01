#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-postgres-primary}"
PORT="${PORT:-5432}"
USER="${USER:-appuser}"
DB="${DB:-postgres}"
PASSWORD="${PASSWORD:-supersecret}"

export PGPASSWORD="${PASSWORD}"

echo "Checking connectivity to ${HOST}:${PORT}/${DB} as ${USER}"
psql -h "${HOST}" -p "${PORT}" -U "${USER}" -d "${DB}" -c 'SELECT now() AS connected_at;'
