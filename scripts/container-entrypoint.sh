#!/usr/bin/env bash
set -euo pipefail

DB_HOST="${ODOO_DB_HOST:-db}"
DB_PORT="${ODOO_DB_PORT:-5432}"
DB_USER="${ODOO_DB_USER:-odoo}"
DB_PASSWORD="${ODOO_DB_PASSWORD:-odoo}"

if [[ "${1:-}" == "-"* ]]; then
  set -- odoo-bin "$@"
fi

if [[ "${1:-}" == "odoo-bin" ]]; then
  echo "Esperando Postgres en ${DB_HOST}:${DB_PORT}..."
  until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}"; do
    sleep 2
  done

  # Inject DB settings from container env so they override static config values.
  set -- "$@" \
    "--db_host=${DB_HOST}" \
    "--db_port=${DB_PORT}" \
    "--db_user=${DB_USER}" \
    "--db_password=${DB_PASSWORD}"
fi

exec "$@"
