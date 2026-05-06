# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Siteco's downstream of **Odoo 18 Community Edition**. The upstream Odoo source is vendored in place (`odoo/`, `addons/`, `setup/`, `odoo-bin`, `requirements.txt`, etc.) and customizations live alongside it. There are two parallel addon trees:

- `addons/` — upstream Odoo CE modules (~600). Treat as vendored: avoid local edits unless intentionally patching upstream.
- `custom_addons/` — Siteco-specific modules, mostly PoS extensions (`pos_moresco_direct`, `pos_cierre_caja`, `pos_waiter_view`, `pos_order_lock`, `pos_change_salesperson`, `pos_auto_tip`, `pos_ticket_order_actions`), plus reporting (`custom_report_factura*`, `reportes_admin`) and `user_menu_visibility`. **Note:** `custom_addons/` is listed in `.gitignore` but is tracked in this branch — be deliberate when adding files there. The `publicar/` subfolder holds packaged `.zip` releases of those modules.

The `addons_path` configured in `odoo.conf` is `odoo/addons,addons,custom_addons` (in that load order).

## Running Odoo

Two supported workflows; both use the same source tree.

### 1. Local (host venv)

`.venv/` already exists at the repo root. `odoo.conf` (root) is the dev config and points to `localhost:5000` / db `sitecodb` / user `odoo`. To start:

```bash
source .venv/bin/activate
./odoo-bin -c odoo.conf
# Update one module against the dev DB:
./odoo-bin -c odoo.conf -d sitecodb -u <module> --stop-after-init
# Run Odoo's test suite for a module:
./odoo-bin -c odoo.conf -d <test_db> -i <module> --test-enable --stop-after-init --log-level=test
```

`environment.yml` defines a conda env (`env_odoo18_devel`, Python 3.12) as an alternative to `.venv`.

### 2. Docker Compose (canonical for dev and prod)

`docker-compose.yml` defines `db` (Postgres 16), `redis` (7-alpine, used for Odoo session store + cache), and `odoo`. `docker-compose.override.yml` is auto-loaded in dev and adds:

- the `build:` context (without override, prod pulls `${ODOO_IMAGE}` from GHCR)
- a bind mount of `./addons → /mnt/extra-addons` for hot-reload
- `WORKERS=0`, `LIST_DB=True`, `LOG_LEVEL=debug`

For production, **do not ship `docker-compose.override.yml`** — rename or delete it on the prod host so only the base compose file is used.

```bash
cp .env.example .env            # required; edit CHANGE_ME values
docker compose up -d --build    # dev (override active)
docker compose logs -f odoo
docker compose exec odoo odoo-venv shell                # Python shell with Odoo's site-packages
docker compose exec odoo odoo-venv pip install <pkg>    # install into the container's site-packages
docker compose exec odoo odoo-venv run python -V
```

Persistence relies on named volumes `db-data`, `redis-data`, `odoo-data`, `odoo-logs`, `odoo-modules`. `docker compose down -v` wipes them — including the master password and DB.

### 3. Production server

`deploy/deploy.sh` provisions a fresh Ubuntu/Debian host: drops `deploy/systemd/odoo18-compose.service` into `/etc/systemd/system/`, enables it, and configures UFW (22/80/443 only — Odoo's 8069 is never exposed; Traefik labels in `docker-compose.yml` terminate TLS and front 8069/8072). Operate via `systemctl {start|stop|restart|status} odoo18-compose`.

## Container entrypoint behavior (important)

`scripts/container-entrypoint.sh` is the production `ENTRYPOINT` and has non-obvious semantics:

1. **Config templating.** `docker/odoo.conf` is the **template** with `${VAR:-default}` placeholders. On first boot, the entrypoint expands env vars (via an inline Python regex pass — *not* `envsubst`, despite the comments) into `/var/lib/odoo/odoo.conf` inside the persistent `odoo-data` volume. That expanded copy is what Odoo reads via `-c`.
2. **Why persistence matters.** Odoo writes the hashed `admin_passwd` back into its config file. Regenerating from template every boot would clobber the hash. So the entrypoint *only* regenerates when the file is missing or `FORCE_RECONFIG=1`. After changing env vars that affect `odoo.conf`, set `FORCE_RECONFIG=1`, restart once, then set it back to `0`.
3. **`-c` injection.** Any `-c`/`--config` args coming in via `CMD` or user args are stripped, and `-c "${RUNTIME_CONF}"` plus DB-connection overrides are appended. Don't try to override the config path from compose — adjust env vars instead.
4. **First-run init.** If `ir_module_module` doesn't exist in the target DB, the entrypoint runs `odoo-bin -i ${ODOO_INIT_MODULES:-base} --stop-after-init --without-demo=all`, then `UPDATE res_users SET password=...` for `admin` using a pbkdf2_sha512 hash of `ODOO_ADMIN_PASSWORD` (default `admin`), and writes `/var/lib/odoo/initial-credentials.txt` (mode 600).
5. **Graceful shutdown.** The script traps SIGTERM and forwards it to the Odoo child — don't replace the entrypoint with a bare `odoo-bin` exec without preserving this.

## Image build (multi-stage)

`Dockerfile` has three stages: `base` (OS deps, wkhtmltopdf, Postgres client, rtlcss), `builder` (compile toolchain, `pip install` Odoo's `requirements.txt` from upstream + Siteco extras: `redis`, `python-escpos`, `click-odoo-contrib`, `git-aggregator`, `python-json-logger`, `inotify`, `psycogreen`, `rlpycairo`; clones Odoo 18.0 into `/opt/odoo`), and `production` (lean runtime, non-root `odoo` user UID/GID 101, drops the build toolchain). The production tag published to GHCR is `${ODOO_IMAGE}` in `.env` (currently `ghcr.io/juanca2918/odoo18-ce:siteco-odoo-v1.0`).

A few quirks worth knowing:

- The Dockerfile pulls Odoo `requirements.txt` *from GitHub* (`raw.githubusercontent.com/odoo/odoo/${ODOO_VERSION}/requirements.txt`), not from the local checkout. The vendored `requirements.txt` here is for host-side venv use.
- The image installs Odoo as `pip install --editable /opt/odoo` so `odoo-bin` resolves the bundled `odoo/` package, not whatever is bind-mounted at `/mnt/extra-addons`.
- Custom addons reach the container *only* via the `odoo-modules` named volume (prod) or the `./addons` bind mount (dev override). To ship a custom module in the prod image you must either copy it in via a Dockerfile change or place it in the `odoo-modules` volume on the host.

## Redis session store

`docker/odoo.conf` template wires `session_redis`, `redis_host`, `redis_port`, `redis_db`, `redis_prefix` from env vars. This relies on the *upstream* Odoo build supporting these options — if a future upgrade drops them, sessions silently fall back to filesystem and Redis becomes a no-op. Verify after Odoo version bumps.

## Conventions and gotchas

- **Don't edit `addons/` casually.** It's the upstream tree. New behavior belongs in `custom_addons/<your_module>/` with a proper `__manifest__.py` and standard Odoo layout (`models/`, `views/`, `static/src/`, `security/ir.model.access.csv`).
- **PoS modules use OWL/JS assets.** They register XML templates and JS files via the `assets` key in `__manifest__.py` under `point_of_sale._assets_pos`. After editing PoS JS/XML, you generally need `-u <module>` against the dev DB to re-bundle.
- **Module install/upgrade from a running container:**
  ```bash
  docker compose exec odoo odoo-bin -c /var/lib/odoo/odoo.conf -d <db> -u <module> --stop-after-init
  ```
  Use the *expanded* runtime config path (`/var/lib/odoo/odoo.conf`), not the template at `/etc/odoo/odoo.conf.template`.
- **Odoo's CLI tests** run via `--test-enable`/`--test-tags` against a DB with the module installed; there is no separate test runner in this repo.
- The repo root holds historical/log artifacts (`build-*.log`, `push-*.txt`, `*.md.resolved`) — these are not authoritative documentation.
