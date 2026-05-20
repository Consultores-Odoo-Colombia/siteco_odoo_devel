# syntax=docker/dockerfile:1

ARG PYTHON_VERSION=3.11-slim
ARG OS_VARIANT=bookworm
ARG ODOO_VERSION=18.0
ARG WKHTMLTOX_VERSION=0.12.6.1-3
ARG ODOO_USER=odoo
ARG ODOO_BASEPATH=/opt/odoo
ARG APP_UID=101
ARG APP_GID=101

# =============================================================================
# Stage 1 — Base: OS dependencies shared between builder and production
# =============================================================================
FROM python:${PYTHON_VERSION}-${OS_VARIANT} AS base

SHELL ["/bin/bash", "-xo", "pipefail", "-c"]

USER root

# Library versions
ARG WKHTMLTOX_VERSION
ENV WKHTMLTOX_VERSION=${WKHTMLTOX_VERSION}

# Use noninteractive to get rid of apt-utils message
ENV DEBIAN_FRONTEND=noninteractive

# Install core Odoo system dependencies
# hadolint ignore=DL3008
RUN apt-get -qq update \
    && apt-get -qq install -y --no-install-recommends \
    # Odoo dependencies
    ca-certificates \
    curl \
    dirmngr \
    fonts-noto-cjk \
    gnupg \
    libssl-dev \
    node-less \
    npm \
    python3-num2words \
    python3-odf \
    python3-pdfminer \
    python3-pip \
    python3-phonenumbers \
    python3-pyldap \
    python3-qrcode \
    python3-renderpm \
    python3-setuptools \
    python3-slugify \
    python3-vobject \
    python3-watchdog \
    python3-xlrd \
    python3-xlwt \
    # Minimal production utilities
    gettext-base \
    fonts-liberation2 \
    lsb-release \
    xz-utils \
    && \
    if [ "$(uname -m)" = "aarch64" ]; then \
        curl -o wkhtmltox.deb -sSL https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/wkhtmltox_${WKHTMLTOX_VERSION}.$(lsb_release -cs)_arm64.deb \
    ; else \
        curl -o wkhtmltox.deb -sSL https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/wkhtmltox_${WKHTMLTOX_VERSION}.$(lsb_release -cs)_amd64.deb \
    ; fi \
    && apt-get install -y --no-install-recommends ./wkhtmltox.deb \
    && apt-get autopurge -yqq \
    && rm -rf /var/lib/apt/lists/* wkhtmltox.deb /tmp/*

# install latest postgresql-client
RUN apt-get -qq update \
    && apt-get -qq install -y --no-install-recommends \
    lsb-release \
    && echo "deb http://apt.postgresql.org/pub/repos/apt/ $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && GNUPGHOME="$(mktemp -d)" \
    && export GNUPGHOME \
    && repokey='B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8' \
    && gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "${repokey}" \
    && gpg --batch --armor --export "${repokey}" > /etc/apt/trusted.gpg.d/pgdg.gpg.asc \
    && gpgconf --kill all \
    && rm -rf "$GNUPGHOME" \
    && apt-get -qq install -y --no-install-recommends postgresql-client libpq-dev \
    && rm -f /etc/apt/sources.list.d/pgdg.list \
    && rm -rf /var/lib/apt/lists/*

# Install rtlcss
RUN npm install -g rtlcss \
    && rm -Rf ~/.npm /tmp/*

# =============================================================================
# Stage 2 — Builder: compile Python packages & clone Odoo source
# =============================================================================
FROM base AS builder

# Install build dependencies (only needed to compile wheels)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    apt-utils \
    apt-transport-https \
    build-essential \
    git-core \
    libcairo2-dev \
    libfreetype6-dev \
    libfribidi-dev \
    libghc-zlib-dev \
    libharfbuzz-dev \
    libjpeg-dev \
    libgeoip-dev \
    libmaxminddb-dev \
    liblcms2-dev \
    libldap2-dev \
    libopenjp2-7-dev \
    libsasl2-dev \
    libtiff5-dev \
    libxml2-dev \
    libxslt1-dev \
    libmagic1 \
    libwebp-dev \
    tcl-dev \
    tk-dev \
    zlib1g-dev \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Install Odoo Python requirements + production-only extras
ARG ODOO_VERSION

RUN pip3 install --prefix=/usr/local --no-cache-dir --upgrade \
    --requirement https://raw.githubusercontent.com/odoo/odoo/${ODOO_VERSION}/requirements.txt \
    && pip3 install --prefix=/usr/local --no-cache-dir --upgrade \
    rlpycairo \
    'websocket-client~=0.56' \
    psycogreen \
    click-odoo-contrib \
    git-aggregator \
    inotify \
    python-json-logger \
    redis \
    python-escpos \
    xmlsig \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# Clone Odoo source
RUN git clone --depth 1 -b ${ODOO_VERSION} https://github.com/odoo/odoo.git /opt/odoo \
    && pip3 install --editable /opt/odoo \
    && find /opt/odoo -name '.git' -type d -exec rm -rf {} + 2>/dev/null || true \
    && rm -rf /var/lib/apt/lists/* /tmp/*

# =============================================================================
# Stage 3 — Production: lean, hardened runtime image
# =============================================================================
FROM base AS production

LABEL org.opencontainers.image.title="Odoo 18 CE - Siteco" \
      org.opencontainers.image.description="Odoo 18 Community Edition production image" \
      org.opencontainers.image.version="18.0" \
      org.opencontainers.image.vendor="Siteco" \
      org.opencontainers.image.source="https://github.com/Consultores-Odoo-Colombia/siteco_odoo_devel"

# --- Runtime environment variables ---
ARG ODOO_BASEPATH
ENV ODOO_BASEPATH=${ODOO_BASEPATH}

# Create app user WITHOUT sudo
ARG ODOO_USER
ENV ODOO_USER=${ODOO_USER}

ARG APP_UID
ENV APP_UID=${APP_UID}

ARG APP_GID
ENV APP_GID=${APP_GID}

RUN addgroup --system --gid ${APP_GID} ${ODOO_USER} \
    && adduser --system --uid ${APP_UID} --ingroup ${ODOO_USER} \
       --home ${ODOO_BASEPATH} --disabled-login --shell /bin/bash ${ODOO_USER}

# --- Odoo configuration defaults (overridable at runtime via env vars) ---
ENV \
    ADMIN_PASSWORD=admin \
    ODOO_DATA_DIR=/var/lib/odoo/data \
    DB_HOST=db \
    DB_PORT=5432 \
    DB_USER=odoo \
    DB_PASSWORD=odoo \
    DB_MAXCONN=64 \
    DB_SSLMODE=prefer \
    DB_TEMPLATE=template1 \
    DBFILTER=.* \
    DBNAME= \
    HTTP_INTERFACE=0.0.0.0 \
    HTTP_PORT=8069 \
    LIMIT_REQUEST=8196 \
    LIMIT_MEMORY_HARD=2684354560 \
    LIMIT_MEMORY_SOFT=2147483648 \
    LIMIT_TIME_CPU=60 \
    LIMIT_TIME_REAL=120 \
    LIMIT_TIME_REAL_CRON=0 \
    LIST_DB=False \
    LOG_DB=False \
    LOG_DB_LEVEL=warning \
    LOG_HANDLER=:INFO \
    LOG_LEVEL=info \
    MAX_CRON_THREADS=2 \
    PROXY_MODE=True \
    SERVER_WIDE_MODULES=base,web \
    SMTP_PASSWORD=False \
    SMTP_PORT=25 \
    SMTP_SERVER=localhost \
    SMTP_SSL=False \
    SMTP_USER=False \
    TEST_ENABLE=False \
    UNACCENT=False \
    WITHOUT_DEMO=all \
    WORKERS=4

# Redis session management
ENV \
    ODOO_SESSION_REDIS=1 \
    ODOO_SESSION_REDIS_HOST=redis \
    ODOO_SESSION_REDIS_PORT=6379 \
    ODOO_SESSION_REDIS_PREFIX=session \
    ODOO_SESSION_REDIS_STORE=1

# Define all needed directories
ENV ODOO_DATA_DIR=/var/lib/odoo/data
ENV ODOO_LOGS_DIR=/var/lib/odoo/logs
ENV ODOO_EXTRA_ADDONS=/mnt/extra-addons
ENV ODOO_ADDONS_BASEPATH=${ODOO_BASEPATH}/addons
ENV ODOO_CMD=${ODOO_BASEPATH}/odoo-bin

RUN mkdir -p /var/lib/odoo ${ODOO_DATA_DIR} ${ODOO_LOGS_DIR} ${ODOO_EXTRA_ADDONS} /etc/odoo/

# Own folders — include /var/lib/odoo so the entrypoint can write odoo.conf there
RUN chown -R ${APP_UID}:${APP_GID} \
    /var/lib/odoo ${ODOO_EXTRA_ADDONS} \
    ${ODOO_BASEPATH} /etc/odoo

# Named volumes
VOLUME ["/var/lib/odoo/data", "/var/lib/odoo/logs", "/mnt/extra-addons"]

ARG EXTRA_ADDONS_PATHS
ENV EXTRA_ADDONS_PATHS=${EXTRA_ADDONS_PATHS}

ARG EXTRA_MODULES
ENV EXTRA_MODULES=${EXTRA_MODULES}

# Copy Python packages and Odoo from builder stage
COPY --link --chown=${APP_UID}:${APP_GID} --from=builder /usr/local /usr/local
COPY --link --chown=${APP_UID}:${APP_GID} --from=builder /opt/odoo ${ODOO_BASEPATH}

# Copy custom scripts and configuration
COPY --link --chown=${APP_UID}:${APP_GID} scripts/container-entrypoint.sh /usr/local/bin/container-entrypoint.sh
COPY --link --chown=${APP_UID}:${APP_GID} scripts/odoo-venv.sh /usr/local/bin/odoo-venv
COPY --link --chown=${APP_UID}:${APP_GID} docker/odoo.conf /etc/odoo/odoo.conf.template

# MODIFICACIÓN: Dar permisos de ejecución Y limpiar saltos de línea CRLF que rompen el shebang en Linux
RUN chmod u+x /usr/local/bin/container-entrypoint.sh /usr/local/bin/odoo-venv \
    && sed -i 's/\r$//' /usr/local/bin/container-entrypoint.sh /usr/local/bin/odoo-venv

EXPOSE 8069 8071 8072

# Healthcheck — uses static resource that loads without DB
HEALTHCHECK --interval=30s --timeout=10s --retries=5 --start-period=60s \
  CMD curl -sf http://127.0.0.1:${HTTP_PORT:-8069}/web/health || exit 1

# Switch to non-root user BEFORE entrypoint
USER ${ODOO_USER}

ENTRYPOINT ["/usr/local/bin/container-entrypoint.sh"]

CMD ["/opt/odoo/odoo-bin"]