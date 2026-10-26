#!/usr/bin/env bash
# Falla el build si el core de Odoo copiado a la imagen es más viejo de lo esperado.
# Motivo: v2.4–v2.6.x se publicaron con un snapshot de Odoo 18 anterior al de v2.2/v2.3
# (faltaba cac:CorporateRegistrationScheme y la facturación DIAN fallaba).
# Uso: verify-core.sh [ODOO_HOME]   (por defecto /opt/odoo)
set -euo pipefail

ROOT="${1:-/opt/odoo}"
MIN_ADDONS=622
# Fecha del commit upstream de la última re-sincronización: al re-sincronizar, súbela, nunca la bajes.
MIN_CORE_DATE="2026-10-26"
CRITICAL_ADDONS="account_edi_ubl_cii l10n_co l10n_co_pos point_of_sale pos_restaurant pos_edi_ubl"

fail() { echo "verify-core: ERROR: $*" >&2; exit 1; }

UBL="${ROOT}/addons/account_edi_ubl_cii/tools/ubl_21_common.py"
[ -f "$UBL" ] || fail "no existe $UBL"
# Bloque 'cac:PartyLegalEntity': { ... } hasta su cierre con la misma indentación.
awk "/^    'cac:PartyLegalEntity': \{/{f=1} f{print} f&&/^    \},/{exit}" "$UBL" \
    | grep -q "'cac:CorporateRegistrationScheme'" \
    || fail "cac:CorporateRegistrationScheme no está dentro de cac:PartyLegalEntity en $UBL"

for a in $CRITICAL_ADDONS; do
    [ -f "${ROOT}/addons/${a}/__manifest__.py" ] || fail "falta el addon crítico ${a}"
done

count=$(find "${ROOT}/addons" -mindepth 2 -maxdepth 2 -name __manifest__.py | wc -l)
[ "$count" -ge "$MIN_ADDONS" ] || fail "solo ${count} addons en ${ROOT}/addons (mínimo ${MIN_ADDONS})"

COMMIT_FILE="${ROOT}/CORE_UPSTREAM_COMMIT"
[ -f "$COMMIT_FILE" ] || fail "falta $COMMIT_FILE"
read -r sha date _ < "$COMMIT_FILE"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || fail "hash inválido en CORE_UPSTREAM_COMMIT: '${sha}'"
[[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "fecha inválida en CORE_UPSTREAM_COMMIT: '${date}'"
[[ ! "$date" < "$MIN_CORE_DATE" ]] || fail "core upstream ${date} es anterior al mínimo ${MIN_CORE_DATE}"

echo "verify-core: OK (${count} addons, upstream ${sha} ${date})"
