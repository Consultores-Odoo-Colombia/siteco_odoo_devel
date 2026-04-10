# Odoo 18 CE con Docker Compose (Debian/Ubuntu)

Esta configuracion usa:

- Python `3.11` (compatible con Debian 12/Ubuntu 24.04 y `requirements.txt` del repo)
- Entorno virtual con `venv`
- Gestor de paquetes `pip`
- Postgres 16
- Redis opcional (perfil `with-redis`)

## Por que `venv + pip`

Para Odoo CE en este repositorio, la forma mas compatible y mantenible es `python -m venv` + `pip` porque:

- Odoo distribuye dependencias en `requirements.txt` pensado para `pip`.
- Evitas friccion de herramientas extra (`poetry`, `pipenv`, etc.) en builds de servidor.
- Es estandar en Debian/Ubuntu y facil de automatizar en Docker y CI.

## Levantar el stack en segundo plano

```bash
docker compose up -d --build
```

Abrir Odoo en:

- http://localhost:8069

## Variables de entorno para DB

Puedes manejar usuarios, password y base de datos sin editar `docker-compose.yml`:

1. Crear tu archivo de entorno:

```bash
cp .env.example .env
```

2. Editar valores en `.env` (por ejemplo usuario/password).

3. Aplicar cambios:

```bash
docker compose up -d --build
```

Con esto, las variables se inyectan al contenedor y el entrypoint de Odoo las pasa al proceso `odoo-bin`.

## Activar entorno virtual y agregar paquetes Python

Abrir shell con venv activo:

```bash
docker compose exec odoo odoo-venv shell
```

Instalar una dependencia en el venv:

```bash
docker compose exec odoo odoo-venv pip install <paquete>
```

Ejemplo:

```bash
docker compose exec odoo odoo-venv pip install pytz==2025.1
```

> Nota: para persistencia de dependencias entre rebuilds, agrega los paquetes tambien a `requirements.txt`.

## Redis (opcional)

Si tus modulos usan Redis (cache/colas), levanta el perfil opcional:

```bash
docker compose --profile with-redis up -d
```

Si no lo usas, no es necesario para Odoo CE base.

## Gestion como servicio del sistema (systemd)

Debian y Ubuntu usan `systemd`, asi que aplica igual en ambos.

1. Copiar el servicio:

```bash
sudo cp deploy/systemd/odoo18-compose.service /etc/systemd/system/
```

2. Editar `WorkingDirectory` si tu ruta no es `/opt/odoo18`:

```bash
sudo systemctl edit --full odoo18-compose.service
```

3. Recargar y habilitar:

```bash
sudo systemctl daemon-reload
sudo systemctl enable odoo18-compose.service
```

4. Comandos de operacion:

```bash
sudo systemctl start odoo18-compose.service
sudo systemctl status odoo18-compose.service
sudo systemctl restart odoo18-compose.service
sudo systemctl stop odoo18-compose.service
sudo journalctl -u odoo18-compose.service -f
```

## Comandos utiles

```bash
docker compose ps
docker compose logs -f odoo
docker compose down
docker compose down -v
```

## Archivos creados

- `Dockerfile.odoo18`
- `docker-compose.yml`
- `docker/odoo.conf`
- `scripts/container-entrypoint.sh`
- `scripts/odoo-venv.sh`
- `deploy/systemd/odoo18-compose.service`
- `docker/README.container.md` (se copia al contenedor en `/README-container.md`)
