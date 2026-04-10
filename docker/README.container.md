# README del contenedor

Este archivo vive en la raiz del contenedor (`/README-container.md`) para operaciones internas.

## Entorno virtual Python

- Ruta del entorno virtual: `/opt/odoo/venv`
- Activar manualmente en una sesion dentro del contenedor:

```bash
source /opt/odoo/venv/bin/activate
```

- Usar helper incluido:

```bash
odoo-venv shell
odoo-venv pip install <paquete>
odoo-venv run python -V
```

## Servicio Odoo en el contenedor

El proceso principal del contenedor es Odoo y lo gestiona Docker (`restart: unless-stopped`).

Ver logs desde host:

```bash
docker compose logs -f odoo
```
