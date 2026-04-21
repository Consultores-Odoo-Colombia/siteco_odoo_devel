#!/usr/bin/env bash
# =============================================================================
# Odoo 18 — Production Server Setup Script
# =============================================================================
# Prepares a fresh server for running Odoo 18 via Docker Compose + systemd.
#
# Usage:
#   scp -r . root@your-server:/opt/odoo18
#   ssh root@your-server 'bash /opt/odoo18/deploy/deploy.sh'
#
# Prerequisites:
#   - Ubuntu 22.04+ / Debian 12+
#   - Docker Engine + Docker Compose V2 installed
# =============================================================================
set -euo pipefail

DEPLOY_DIR="/opt/odoo18"
SERVICE_NAME="odoo18-compose"
ENV_FILE="${DEPLOY_DIR}/.env"

log() { echo "[deploy $(date -u +'%H:%M:%S')] $*"; }

# ---------------------------------------------------------------------------
# 1. Validate prerequisites
# ---------------------------------------------------------------------------
log "Checking prerequisites..."
for cmd in docker; do
  if ! command -v "${cmd}" &>/dev/null; then
    echo "ERROR: '${cmd}' is not installed. Install Docker first."
    exit 1
  fi
done

if ! docker compose version &>/dev/null; then
  echo "ERROR: 'docker compose' (V2) is not available."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Create directory structure
# ---------------------------------------------------------------------------
log "Creating directory structure..."
mkdir -p "${DEPLOY_DIR}"

# ---------------------------------------------------------------------------
# 3. Ensure .env exists
# ---------------------------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  if [[ -f "${DEPLOY_DIR}/.env.example" ]]; then
    cp "${DEPLOY_DIR}/.env.example" "${ENV_FILE}"
    log "Created ${ENV_FILE} from .env.example — EDIT IT BEFORE STARTING!"
    echo ""
    echo "=========================================="
    echo " ACTION REQUIRED: Edit ${ENV_FILE}"
    echo " Change all CHANGE_ME values, then run:"
    echo "   systemctl start ${SERVICE_NAME}"
    echo "=========================================="
    echo ""
  else
    log "ERROR: No .env.example found in ${DEPLOY_DIR}"
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 4. Install systemd service
# ---------------------------------------------------------------------------
log "Installing systemd service..."
cp "${DEPLOY_DIR}/deploy/systemd/${SERVICE_NAME}.service" \
   "/etc/systemd/system/${SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

log "Service '${SERVICE_NAME}' installed and enabled."

# ---------------------------------------------------------------------------
# 5. Configure firewall (if ufw is present)
# ---------------------------------------------------------------------------
if command -v ufw &>/dev/null; then
  log "Configuring UFW firewall..."
  ufw allow 22/tcp   comment 'SSH'        >/dev/null 2>&1 || true
  ufw allow 80/tcp   comment 'HTTP'       >/dev/null 2>&1 || true
  ufw allow 443/tcp  comment 'HTTPS'      >/dev/null 2>&1 || true
  # Do NOT expose 8069 directly — use reverse proxy
  ufw --force enable >/dev/null 2>&1 || true
  log "Firewall configured (22, 80, 443 open)"
fi

# ---------------------------------------------------------------------------
# 6. Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================================"
echo " Deployment ready!"
echo ""
echo " Config  : ${ENV_FILE}"
echo " Service : systemctl {start|stop|status} ${SERVICE_NAME}"
echo " Logs    : docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs -f"
echo ""
echo " Next steps:"
echo "   1. Edit ${ENV_FILE} (change CHANGE_ME values)"
echo "   2. systemctl start ${SERVICE_NAME}"
echo "   3. Check: systemctl status ${SERVICE_NAME}"
echo "   4. Watch logs: docker compose -f ${DEPLOY_DIR}/docker-compose.yml logs -f odoo"
echo "============================================================"
echo ""
