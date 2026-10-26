# Changelog — imagen ghcr.io/juanca2918/odoo18-ce

## v2.7.0 — 2026-10-26

### Corregido
- **Core de Odoo más viejo desde v2.4.** v2.2/v2.3 copiaban `/opt/odoo` desde una etapa
  de build que clonaba odoo/odoo 18.0 en ese momento (2026-05-28). Desde v2.4 el
  Dockerfile hace `COPY . /opt/odoo` del árbol de `despliegue_prod`, que era un snapshot
  de odoo/odoo 18.0 en `a6e0ff92ff` (2026-01-22). Resultado: 614 addons en vez de 622+ y
  `ubl_21_common.py` sin `cac:CorporateRegistrationScheme`, por lo que
  `l10n_co_electronic_invoice_self` fallaba con *"The following child node is not
  defined in the template: …/cac:PartyLegalEntity/cac:CorporateRegistrationScheme"*.
- Core re-sincronizado con odoo/odoo 18.0 `c3a89a815e` (2026-10-26): 628 addons,
  incluye `pos_edi_ubl`, `l10n_pl_edi`, `account_peppol_response`…; sale `website_twitter`.
  Se conservan los parches de Siteco: `xmlsig`/`xmltodict` en `requirements.txt` y las
  fuentes Noto locales en `addons/web/static/fonts`.
- El label `org.opencontainers.image.version` decía `2.5.0` en v2.6.x; ahora se pasa en el build.

### Añadido
- `scripts/verify-core.sh`, ejecutado en el Dockerfile tras el `COPY`: el build falla si
  falta `CorporateRegistrationScheme` en `PartyLegalEntity`, si falta un addon crítico
  (`account_edi_ubl_cii`, `l10n_co`, `l10n_co_pos`, `point_of_sale`, `pos_restaurant`,
  `pos_edi_ubl`), si hay menos de 622 addons o si `CORE_UPSTREAM_COMMIT` es anterior al
  mínimo fijado en el script.
- `CORE_UPSTREAM_COMMIT`: hash y fecha del odoo/odoo 18.0 usado.
- Labels `org.opencontainers.image.revision` y `siteco.odoo.upstream_commit`.
- `.gitattributes` para que los scripts que corren en Linux conserven LF.
- Se versionan en git el Dockerfile, entrypoint, `docker/odoo.conf`, compose y
  `.dockerignore` con los que se construyeron v2.4–v2.6.2 (estaban sin commitear).

### Cómo construir
```bash
git -c core.autocrlf=false archive --format=tar HEAD | docker build --platform linux/amd64 \
  --build-arg IMAGE_VERSION=2.7.0 \
  --build-arg VCS_REF=$(git rev-parse HEAD) \
  --build-arg ODOO_UPSTREAM_COMMIT=$(cut -d' ' -f1 CORE_UPSTREAM_COMMIT) \
  -t ghcr.io/juanca2918/odoo18-ce:siteco-odoo-v2.7.0 -
```
Se construye desde `git archive` (no desde la carpeta) para que en Windows no entren
finales de línea CRLF ni archivos sin commitear en la imagen.

### Re-sincronizar el core en el futuro
1. `git fetch upstream 18.0`
2. Aplicar `git diff --binary <commit en CORE_UPSTREAM_COMMIT> upstream/18.0` encima.
3. Actualizar `CORE_UPSTREAM_COMMIT` y subir `MIN_CORE_DATE` en `scripts/verify-core.sh`.
