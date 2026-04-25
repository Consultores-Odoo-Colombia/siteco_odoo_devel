#!/usr/bin/env bash
# =============================================================================
# Odoo 18 Container Entrypoint — Production
# =============================================================================
# Handles:
#   1. Waiting for PostgreSQL readiness
#   2. First-run database initialization (--init base)
#   3. Expanding environment variables into odoo.conf via envsubst
#   4. Graceful shutdown via SIGTERM
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Unified database variables (compatible with multiple naming conventions)
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-${DB_PORT_5432_TCP_ADDR:-${PGHOST:-db}}}"
DB_PORT="${DB_PORT:-${DB_PORT_5432_TCP_PORT:-${PGPORT:-5432}}}"
DB_USER="${DB_USER:-${DB_ENV_POSTGRES_USER:-${PGUSER:-odoo}}}"
DB_PASSWORD="${DB_PASSWORD:-${DB_ENV_POSTGRES_PASSWORD:-${PGPASSWORD:-odoo}}}"
DB_NAME="${DBNAME:-${ODOO_DB_NAME:-${POSTGRES_DB:-odoo}}}"

ODOO_INIT_MODULES="${ODOO_INIT_MODULES:-base}"
ODOO_BASEPATH="${ODOO_BASEPATH:-/opt/odoo}"

# Files persisted in the odoo-data volume
DATA_DIR="/var/lib/odoo"
CREDENTIALS_FILE="${DATA_DIR}/initial-credentials.txt"

# Persistent runtime config — survives container restarts so Odoo's
# master password hash (admin_passwd) is not overwritten on every boot.
RUNTIME_CONF="${DATA_DIR}/odoo.conf"

# Set FORCE_RECONFIG=1 to regenerate the config from the template,
# e.g. after changing env vars. Default: only generate if missing.
FORCE_RECONFIG="${FORCE_RECONFIG:-0}"

# ---------------------------------------------------------------------------
# Logging helper
# ---------------------------------------------------------------------------
log() { echo "[entrypoint $(date -u +'%Y-%m-%dT%H:%M:%SZ')] $*"; }
log_err() { echo "[entrypoint $(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# Graceful shutdown handler
# ---------------------------------------------------------------------------
_term() {
  log "Received SIGTERM — shutting down gracefully..."
  kill -TERM "${CHILD_PID}" 2>/dev/null || true
  wait "${CHILD_PID}" 2>/dev/null || true
  exit 0
}
trap _term SIGTERM SIGINT

# ---------------------------------------------------------------------------
# Expand env vars in odoo.conf → writable copy
# ---------------------------------------------------------------------------
_expand_conf() {
  local src="$1" dest="$2"
  if [[ -f "${src}" ]]; then
    CONF_FILE="${src}" python3 <<'PY' > "${dest}"
import os, re

def expand_vars(text):
    # Simple approach: replace ${VAR:-default} patterns
    # Find all ${...} patterns
    pattern = re.compile(r'\$\{([^}]+)\}')
    
    def repl(match):
        var_expr = match.group(1)
        if ':-' in var_expr:
            var_name, default = var_expr.split(':-', 1)
            return os.environ.get(var_name, default)
        else:
            return os.environ.get(var_expr, '')
    
    return pattern.sub(repl, text)

text = open(os.environ['CONF_FILE'], encoding='utf-8').read()
expanded = expand_vars(text)
print(expanded, end='')
PY
    log "Configuration expanded from ${src}"
  else
    log_err "${src} not found — cannot generate Odoo config"
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Hash password using Odoo's crypto context (no venv dependency)
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
# Main logic
# ---------------------------------------------------------------------------

# If called with flags (e.g. -u, -i), prepend odoo-bin
if [[ "${1:-}" == "-"* ]]; then
  set -- "${ODOO_BASEPATH}/odoo-bin" "$@"
fi

if [[ "${1:-}" == *"odoo-bin" ]]; then
  # Ensure data directory exists
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

  # --- Expand env vars in config template → persistent runtime config ---
  # The runtime config is written to the persistent volume so that Odoo can
  # save changes (e.g. hashed master password) and they survive restarts.
  if [[ ! -f "${RUNTIME_CONF}" || "${FORCE_RECONFIG}" == "1" ]]; then
    _expand_conf "/etc/odoo/odoo.conf.template" "${RUNTIME_CONF}"
    log "Runtime config written to ${RUNTIME_CONF}"
  else
    log "Using existing runtime config at ${RUNTIME_CONF} (set FORCE_RECONFIG=1 to regenerate)"
  fi

  # Unset ODOO_RC so Odoo's configmanager doesn't auto-read the raw template
  # (which contains unexpanded ${VAR} placeholders). The expanded config is
  # passed explicitly via -c "${RUNTIME_CONF}".
  unset ODOO_RC
  unset OPENERP_SERVER

  # --- First-run initialization ---
  TABLE_EXISTS=$(PGPASSWORD="${DB_PASSWORD}" psql \
    -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
    -tAc "SELECT 1 FROM information_schema.tables WHERE table_name='ir_module_module';" 2>/dev/null || echo "")

  if [[ "${TABLE_EXISTS}" != "1" ]]; then
    ADMIN_PASSWORD="${ODOO_ADMIN_PASSWORD:-admin}"

    log "Database '${DB_NAME}' not initialized. Running --init ${ODOO_INIT_MODULES}..."

    "${ODOO_BASEPATH}/odoo-bin" \
      -c "${RUNTIME_CONF}" \
      -d "${DB_NAME}" \
      --db_host="${DB_HOST}" \
      --db_port="${DB_PORT}" \
      --db_user="${DB_USER}" \
      --db_password="${DB_PASSWORD}" \
      -i "${ODOO_INIT_MODULES}" \
      --stop-after-init \
      --without-demo=all

    # Set admin password
    log "Setting admin user password..."
    HASHED_PASS=$(_hash_password "${ADMIN_PASSWORD}")
    PGPASSWORD="${DB_PASSWORD}" psql \
      -h "${DB_HOST}" -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" \
      -c "UPDATE res_users SET password = '${HASHED_PASS}' WHERE login = 'admin';"

    # Write credentials file (readable only by owner)
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

  # Strip any existing -c / --config args from $@ (e.g. from CMD) so we don't
  # pass the raw template path to odoo-bin. Only the expanded config is used.
  cleaned_args=()
  skip_next=false
  for arg in "$@"; do
    if ${skip_next}; then
      skip_next=false
      continue
    fi
    case "${arg}" in
      -c|--config) skip_next=true ;; # drop -c and its value
      -c=*|--config=*) ;;            # drop --config=<path>
      *) cleaned_args+=("${arg}") ;;
    esac
  done

  # Rebuild args: odoo-bin + expanded config + DB overrides
  set -- "${cleaned_args[@]}" \
    -c "${RUNTIME_CONF}" \
    "--db_host=${DB_HOST}" \
    "--db_port=${DB_PORT}" \
    "--db_user=${DB_USER}" \
    "--db_password=${DB_PASSWORD}"
fi

# --- Exec Odoo (PID 1) ---
log "Starting: $*"
exec "$@" &
CHILD_PID=$!
wait "${CHILD_PID}"
