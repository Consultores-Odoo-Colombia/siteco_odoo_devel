# syntax=docker/dockerfile:1
# =============================================================================
# Siteco Odoo 18 CE — Imagen base mutable-friendly
# =============================================================================
# Modelo B: la imagen trae Odoo + sistema base. Librerías Python adicionales
# y addons custom se instalan/actualizan en runtime desde volúmenes persistentes.
#
# Volumen persistente ODOO_DATA (/var/lib/odoo):
#   - /var/lib/odoo/data        → filestore, sessions, config
#   - /var/lib/odoo/logs        → logs persistentes (si se configuran)
#   - /var/lib/odoo/venv        → virtualenv mutable para pip installs a posteriori
#
# Volumen persistente ODOO_MODULES (/mnt/extra-addons):
#   - aquí subes tus custom_addons via SFTP/S3/git/web UI
#   - si existe /mnt/extra-addons/requirements.txt se instala en cada arranque
#
# Esto evita tener que hacer docker build + push por cada librería o addon nuevo.
# =============================================================================

FROM python:3.11-slim-bookworm

LABEL org.opencontainers.image.title="Siteco Odoo 18 CE" \
      org.opencontainers.image.description="Odoo 18 CE mutable-friendly: runtime addons and pip installs via persistent volumes" \
      org.opencontainers.image.source="https://github.com/juanca2918/siteco_odoo_devel" \
      org.opencontainers.image.version="2.5.0"

ENV DEBIAN_FRONTEND=noninteractive \
    ODOO_HOME=/opt/odoo \
    ODOO_VENV_BASE=/opt/odoo/venv \
    # Venv mutable en volumen persistente para librerías a posteriori
    ODOO_VENV_RUNTIME=/var/lib/odoo/venv \
    PATH="/var/lib/odoo/venv/bin:/opt/odoo/venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PG_MAJOR=16

USER root

# -----------------------------------------------------------------------------
# 1. Dependencias del sistema
# -----------------------------------------------------------------------------
RUN set -eux; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        gnupg \
        libpq-dev \
        libxml2-dev \
        libxslt1-dev \
        zlib1g-dev \
        libsasl2-dev \
        libldap2-dev \
        libssl-dev \
        libffi-dev \
        libjpeg62-turbo-dev \
        liblcms2-dev \
        libblas-dev \
        libatlas-base-dev \
        libfreetype6-dev \
        libwebp-dev \
        libharfbuzz-dev \
        libfribidi-dev \
        wkhtmltopdf \
        # Útiles para instalar addons a posteriori
        unzip \
        rsync; \
    \
    # Cliente PostgreSQL (mismo major que el servidor)
    install -d /usr/share/postgresql-common/pgdg; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
        | gpg --batch --yes --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg; \
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] \
        https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update -qq; \
    apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"; \
    rm -rf /var/lib/apt/lists/*; \
    pg_dump --version

# -----------------------------------------------------------------------------
# 2. Usuario odoo y directorios persistentes
# -----------------------------------------------------------------------------
RUN set -eux; \
    groupadd -g 101 odoo; \
    useradd -m -d /home/odoo -u 101 -g odoo -s /bin/bash odoo; \
    mkdir -p ${ODOO_HOME} ${ODOO_VENV_BASE} /var/lib/odoo/data /var/lib/odoo/logs /var/lib/odoo/venv /mnt/extra-addons /etc/odoo; \
    chown -R odoo:odoo ${ODOO_HOME} /var/lib/odoo /mnt/extra-addons /etc/odoo

WORKDIR ${ODOO_HOME}

# -----------------------------------------------------------------------------
# 3. Instalar dependencias base de Odoo en venv de imagen (inmutable)
# -----------------------------------------------------------------------------
COPY --chown=odoo:odoo requirements.txt ./requirements.txt
# Fix cbor2==5.4.2 source build failure on Python 3.11 (missing pkg_resources).
RUN sed -E "s/^cbor2==5\.4\.2(\s*;.*)?$/cbor2==5.4.6\1/" requirements.txt > /tmp/requirements-docker.txt && cat /tmp/requirements-docker.txt

USER odoo
RUN set -eux; \
    python -m venv "${ODOO_VENV_BASE}"; \
    "${ODOO_VENV_BASE}/bin/pip" install --upgrade "pip<25" "setuptools<81" "wheel<0.46"; \
    "${ODOO_VENV_BASE}/bin/pip" install --prefer-binary -r /tmp/requirements-docker.txt

# -----------------------------------------------------------------------------
# 4. Copiar Odoo e instalar editable
# -----------------------------------------------------------------------------
COPY --chown=odoo:odoo . ${ODOO_HOME}

RUN set -eux; \
    "${ODOO_VENV_BASE}/bin/pip" install --no-deps --editable "${ODOO_HOME}"; \
    ln -sf "${ODOO_HOME}/odoo-bin" "${ODOO_VENV_BASE}/bin/odoo-bin"; \
    ln -sf "${ODOO_HOME}/setup/odoo" "${ODOO_VENV_BASE}/bin/odoo"; \
    odoo-bin --version 2>/dev/null | head -1

# -----------------------------------------------------------------------------
# 5. Entrypoint y config
# -----------------------------------------------------------------------------
USER root
COPY --chown=odoo:odoo scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
COPY --chown=odoo:odoo docker/odoo.conf /etc/odoo/odoo.conf.template

RUN chmod +x /usr/local/bin/container-entrypoint.sh

HEALTHCHECK --interval=30s --timeout=10s --retries=5 \
    CMD curl -f http://localhost:8069/web/health || exit 1

EXPOSE 8069 8072

USER odoo

ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]
CMD ["odoo-bin"]
