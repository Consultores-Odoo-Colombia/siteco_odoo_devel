# syntax=docker/dockerfile:1
FROM ghcr.io/juanca2918/odoo18-ce:siteco-odoo-v2.3

# Versión MAYOR del cliente PostgreSQL. DEBE ser >= a la del servidor
# (postgres:${PSQL_VERSION} en docker-compose) o pg_dump rechazará el volcado.
# Mantener sincronizado con PSQL_VERSION del .env.
ARG PG_MAJOR=16

USER root

# Instala el cliente oficial de PostgreSQL (pg_dump / pg_restore / psql) desde el
# repositorio PGDG. Odoo invoca estos binarios para backup/restore desde el gestor
# de bases de datos; si faltan o su versión es menor que la del servidor, falla.
RUN set -eux; \
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --batch --yes --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] \
        https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*; \
    # Falla el build si los binarios no quedan resolubles en el PATH del runtime.
    pg_dump --version; \
    pg_restore --version

USER odoo
