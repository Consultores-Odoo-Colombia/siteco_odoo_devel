#!/usr/bin/env bash
# =============================================================================
# Siteco Odoo 18 CE — Mutable-friendly Entrypoint
# =============================================================================
# Responsabilidades:
#   1. Esperar a PostgreSQL y Redis.
#   2. Preparar venv mutable en /var/lib/odoo/venv (copia base + instala extras).
#   3. Instalar requirements.txt desde /mnt/extra-addons en cada arranque.
#   4. Expandir /etc/odoo/odoo.conf.template → /var/lib/odoo/odoo.conf.
#   5. Forzar regeneración de admin_passwd si RESET_ADMIN_PASSWD=1.
#   6. Auto-inicializar BD si ODOO_AUTO_INIT=1 y no existe ir_module_module.
#   7. Lanzar Odoo con graceful shutdown.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Database / Redis variables (múltiples convenciones)
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-${DB_PORT_5432_TCP_ADDR:-${PGHOST:-db}}}"
DB_PORT="${DB_PORT:-${DB_PORT_5432_TCP_PORT:-${PGPORT:-5432}}}"
DB_USER="${DB_USER:-${DB_ENV_POSTGRES_USER:-${PGUSER:-odoo}}}"
DB_PASSWORD="${DB_PASSWORD:-${DB_ENV_POSTGRES_PASSWORD:-${PGPASSWORD:-odoo}}}"
DB_NAME="${DBNAME:-${ODOO_DB_NAME:-${POSTGRES_DB:-odoo}}}"
export DB_NAME

ODOO_INIT_MODULES="${ODOO_INIT_MODULES:-base}"
ODOO_BASEPATH="${ODOO_BASEPATH:-/opt/odoo}"
ODOO_VENV_BASE="${ODOO_VENV_BASE:-/opt/odoo/venv}"
ODOO_VENV_RUNTIME="${ODOO_VENV_RUNTIME:-/var/lib/odoo/venv}"

ODOO_AUTO_INIT="${ODOO_AUTO_INIT:-0}"
FORCE_RECONFIG="${FORCE_RECONFIG:-0}"
RESET_ADMIN_PASSWD="${RESET_ADMIN_PASSWD:-0}"

DATA_DIR="/var/lib/odoo"
CREDENTIALS_FILE="${DATA_DIR}/initial-credentials.txt"
RUNTIME_CONF="${DATA_DIR}/odoo.conf"

log() { echo "[entrypoint $(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
log_err() { echo "[entrypoint $(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }

_term() {
  log "Received SIGTERM — shutting down gracefully..."
  kill -TERM "${CHILD_PID}" 2>/dev/null || true
  wait "${CHILD_PID}" 2>/dev/null || true
  exit 0
}
trap _term SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Expand env vars in odoo.conf template → writable copy
# ---------------------------------------------------------------------------
_expand_conf() {
  local src="$1" dest="$2"
  if [[ -f "${src}" ]]; then
    CONF_FILE="${src}" python3 <<'PY' > "${dest}"
import os, re

def expand_vars(text):
    pattern = re.compile(r'\$\{([^}]+)\}')

    def repl(match):
        var_expr = match.group(1)
        if ':-' in var_expr:
            var_name, default = var_expr.split(':-', 1)
            return os.environ.get(var_name) or default
        else:
            return os.environ.get(var_expr, '')

    return pattern.sub(repl, text)

text = open(os.environ['CONF_FILE'], encoding='utf-8').read()
print(expand_vars(text), end='')
PY
    log "Configuration expanded from ${src}"
  else
    log_err "${src} not found — cannot generate Odoo config"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Hash password (pbkdf2_sha512)
# ---------------------------------------------------------------------------
_hash_password() {
  local raw_pass="$1"
  python3 -c "
from passlib.context import CryptContext
ctx = CryptContext(schemes=['pbkdf2_sha512'])
print(ctx.hash('${raw_pass}'))
"
}

# ---------------------------------------------------------------------------
# Prepare mutable venv on persistent volume
# ---------------------------------------------------------------------------
_prepare_runtime_venv() {
  log "Preparing mutable venv at ${ODOO_VENV_RUNTIME}..."

  if [[ ! -f "${ODOO_VENV_RUNTIME}/bin/python" ]]; then
    log "No runtime venv found — cloning base venv..."
    mkdir -p "${ODOO_VENV_RUNTIME}"
    cp -a "${ODOO_VENV_BASE}/." "${ODOO_VENV_RUNTIME}/"
    log "Runtime venv cloned from base image"
  fi

  # Asegurar pip actualizado en runtime venv
  "${ODOO_VENV_RUNTIME}/bin/pip" install --upgrade "pip<25" "setuptools<81" "wheel<0.46" >/dev/null 2>&1 || true

  # Instalar requirements.txt de addons a posteriori
  if [[ -f "/mnt/extra-addons/requirements.txt" ]]; then
    log "Installing /mnt/extra-addons/requirements.txt into runtime venv..."
    if "${ODOO_VENV_RUNTIME}/bin/pip" install --prefer-binary -r "/mnt/extra-addons/requirements.txt"; then
      log "Runtime requirements installed"
    else
      log_err "Failed to install some requirements from /mnt/extra-addons/requirements.txt — continuing anyway"
    fi
  fi

  # Instalar librerías individuales si se pasan por env
  if [[ -n "${ODOO_EXTRA_PIP:-}" ]]; then
    log "Installing extra pip packages: ${ODOO_EXTRA_PIP}"
    "${ODOO_VENV_RUNTIME}/bin/pip" install --prefer-binary ${ODOO_EXTRA_PIP} || log_err "Some extra pip packages failed"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "-"* ]]; then
  set -- "${ODOO_BASEPATH}/odoo-bin" "$@"
fi

if [[ "${1:-}" == *"odoo-bin" ]]; then
  mkdir -p "${DATA_DIR}"

  # --- Wait for PostgreSQL ---
  log "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
  retries=0
  max_retries=30
  until pg_isready -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -q; do
    retries=$((retries + 1))
    if [[ ${retries} -ge ${max_retries} ]]; then
      log_err "PostgreSQL not ready after ${max_retries} attempts — aborting"
      exit 1
    fi
    sleep 2
  done
  log "PostgreSQL is ready"

  # --- Prepare mutable venv ---
  _prepare_runtime_venv

  # --- Expand config ---
  if [[ ! -f "${RUNTIME_CONF}" || "${FORCE_RECONFIG}" == "1" ]]; then
    _expand_conf "/etc/odoo/odoo.conf.template" "${RUNTIME_CONF}"

    # Force admin_passwd regeneration from ADMIN_PASSWORD
    if [[ "${RESET_ADMIN_PASSWD}" == "1" ]]; then
      admin_password="${ADMIN_PASSWORD:-${ODOO_ADMIN_PASSWORD:-admin}}"
      hashed=$(_hash_password "${admin_password}")
      sed -i -E "s|^\s*admin_passwd\s*=.*|admin_passwd = ${hashed}|" "${RUNTIME_CONF}"
      log "admin_passwd regenerated from ADMIN_PASSWORD/ODOO_ADMIN_PASSWORD"
    fi

    log "Runtime config written to ${RUNTIME_CONF}"
  else
    log "Using existing runtime config at ${RUNTIME_CONF} (set FORCE_RECONFIG=1 to regenerate)"
  fi

  unset ODOO_RC OPENERP_SERVER

  # --- Auto-init database ---
  if [[ "${ODOO_AUTO_INIT}" == "1" ]]; then
    TABLE_EXISTS=$(PGPASSWORD="${DB_PASSWORD}" psql \
      -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='ir_module_module';" 2>/dev/null || echo "")

    if [[ "${TABLE_EXISTS}" != "1" ]]; then
      ADMIN_PASSWORD="${ODOO_ADMIN_PASSWORD:-${ADMIN_PASSWORD:-admin}}"

      log "Database '${DB_NAME}' not initialized. Running --init ${ODOO_INIT_MODULES}..."
      "${ODOO_VENV_RUNTIME}/bin/odoo-bin" \
        -c "${RUNTIME_CONF}" \
        -d "${DB_NAME}" \
        --db_host="${DB_HOST}" \
        --db_port="${DB_PORT}" \
        --db_user="${DB_USER}" \
        --db_password="${DB_PASSWORD}" \
        -i "${ODOO_INIT_MODULES}" \
        --stop-after-init \
        --without-demo=all

      log "Setting admin user password..."
      HASHED_PASS=$(_hash_password "${ADMIN_PASSWORD}")
      PGPASSWORD="${DB_PASSWORD}" psql \
        -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
        -c "UPDATE res_users SET password = '${HASHED_PASS}' WHERE login = 'admin';"

      cat > "${CREDENTIALS_FILE}" <<EOF
=== Odoo Initial Credentials ===
Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Database : ${DB_NAME}
URL      : (your domain)/web
User     : admin
Password : ${ADMIN_PASSWORD}
=================================
EOF
      chmod 600 "${CREDENTIALS_FILE}"

      log "================================================================"
      log " INITIAL CREDENTIALS"
      log " Odoo User : admin"
      log " Password  : ${ADMIN_PASSWORD}"
      log " (also saved in ${CREDENTIALS_FILE})"
      log "================================================================"
      log "Initialization completed."
    fi
  else
    log "ODOO_AUTO_INIT=0 — skipping auto-init. Use /web/database/manager or set ODOO_AUTO_INIT=1."
  fi

  # --- Strip -c/--config from original args and append runtime config ---
  cleaned_args=()
  skip_next=false
  for arg in "$@"; do
    if ${skip_next}; then
      skip_next=false
      continue
    fi
    case "${arg}" in
      -c|--config) skip_next=true ;;
      -c=*|--config=*) ;;
      *) cleaned_args+=("${arg}") ;;
    esac
  done

  # --- Opciones que deben poder cambiarse desde Coolify en cada despliegue ---
  # odoo.conf solo se regenera si falta o con FORCE_RECONFIG=1 (así no se pisa
  # el admin_passwd que Odoo escribe ahí), de modo que cambiar LIST_DB o
  # DBFILTER en las variables del servicio no tenía ningún efecto. Los flags de
  # línea de comando se aplican en cada arranque y tienen prioridad sobre el
  # archivo, sin necesidad de regenerarlo.
  env_overrides=()
  case "${LIST_DB:-}" in
    [Ff]alse|FALSE|0|[Nn]o|[Oo]ff) env_overrides+=(--no-database-list) ;;
  esac
  if [[ -n "${DBFILTER:-}" ]]; then
    env_overrides+=("--db-filter=${DBFILTER}")
  fi

  set -- "${cleaned_args[@]}" \
    -c "${RUNTIME_CONF}" \
    --db_host="${DB_HOST}" \
    --db_port="${DB_PORT}" \
    --db_user="${DB_USER}" \
    --db_password="${DB_PASSWORD}" \
    --database="${DB_NAME}" \
    "${env_overrides[@]}"
fi

# La línea de arranque va a los logs del contenedor (y a Coolify): sin enmascarar
# dejaba la contraseña de la base a la vista de cualquiera con acceso a logs.
safe_args=()
for arg in "$@"; do
  case "${arg}" in
    --db_password=*) safe_args+=("--db_password=***") ;;
    *) safe_args+=("${arg}") ;;
  esac
done
log "Starting: ${safe_args[*]}"
exec "$@"
