#!/usr/bin/env bash
set -euo pipefail

VENV_PATH="${ODOO_VENV:-/opt/odoo/venv}"

if [[ ! -f "${VENV_PATH}/bin/activate" ]]; then
  echo "No existe el entorno virtual en ${VENV_PATH}" >&2
  exit 1
fi

ACTION="${1:-help}"

case "${ACTION}" in
  shell)
    echo "Abriendo shell con venv activo (${VENV_PATH})"
    exec bash -lc "source '${VENV_PATH}/bin/activate' && exec bash"
    ;;
  pip)
    shift
    source "${VENV_PATH}/bin/activate"
    exec pip "$@"
    ;;
  run)
    shift
    source "${VENV_PATH}/bin/activate"
    exec "$@"
    ;;
  help|*)
    cat <<'EOF'
Uso:
  odoo-venv shell
  odoo-venv pip install <paquete>
  odoo-venv run <comando>

Ejemplos:
  odoo-venv pip install black
  odoo-venv run python -V
EOF
    ;;
esac
