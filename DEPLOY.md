# 🚢 Runbook de despliegue (VPS)

Producción corre en una VPS de Google Cloud con **Docker Compose** ([`compose.production.yml`](compose.production.yml)):
tres contenedores — `web` (Rails + Solid Queue embebido), `db` (pgvector) y `caddy`
(reverse proxy con HTTPS automático de Let's Encrypt para `fabianragpipeline.duckdns.org`).

> El directorio del proyecto en la VPS (`~/rag-data-pipeline`) **no es un repo git**:
> se sincroniza copiando el árbol commiteado. Los secretos viven en `~/rag-data-pipeline/.env`
> (no versionado) — el procedimiento de abajo nunca lo toca.

## Procedimiento estándar

Desde la copia local, con los cambios ya commiteados y pusheados:

```bash
# 1. Sincronizar EXACTAMENTE el árbol commiteado (no toca .env ni archivos extra de la VPS)
git archive HEAD | ssh fabian@34.176.216.64 'tar -x -C ~/rag-data-pipeline'

# 2. Reconstruir la imagen web y levantarla (el healthcheck de db ordena el arranque)
ssh fabian@34.176.216.64 'cd ~/rag-data-pipeline \
  && docker compose -f compose.production.yml build web \
  && docker compose -f compose.production.yml up -d web'

# 3. Solo si cambió el Caddyfile — ver gotcha más abajo
ssh fabian@34.176.216.64 'cd ~/rag-data-pipeline \
  && docker compose -f compose.production.yml up -d --force-recreate caddy'
```

## Verificación post-deploy

```bash
B=https://fabianragpipeline.duckdns.org
curl -s -o /dev/null -w "up: %{http_code}\n"      $B/up           # 200
curl -s -o /dev/null -w "demo: %{http_code}\n"    $B/demo.html    # 200
curl -s -o /dev/null -w "metrics: %{http_code}\n" $B/metrics      # 403 (bloqueado en el edge)
curl -s -o /dev/null -w "auth: %{http_code}\n"    $B/api/v1/documents  # 401 sin API key
curl -sI $B/demo.html | grep -i strict-transport  # HSTS presente
```

## Tenant de la demo pública (solo lectura)

La demo (`/demo.html`) se autocredencia vía `GET /api/v1/demo`, que sirve un tenant
**marcado `read_only`**. Ese flag es la barrera real: la UI oculta la zona de subida
(`can_upload: false`) **y** `DocumentsController#create` rechaza cualquier upload a un
tenant read-only (403). Por eso la demo pública nunca permite ingesta.

El tenant se crea una sola vez en la VPS (no está en seeds). Para crearlo / verificar
que es read-only e ingerir su corpus:

```bash
ssh fabian@34.176.216.64 'cd ~/rag-data-pipeline && docker compose -f compose.production.yml exec -T web \
  bin/rails runner "t = Tenant.find_or_create_by!(name: %q(Libro Baseline)); t.update!(read_only: true); puts t.read_only"'
# debe imprimir: true
```

> Si algún día la demo de prod empezara a mostrar el botón de subir, es que su tenant
> quedó con `read_only: false` — corrígelo con el `update!(read_only: true)` de arriba.
> En **local** ocurre lo contrario a propósito (tenant escribible → subida habilitada);
> ver [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## ⚠️ Gotcha: cambios al `Caddyfile` requieren recrear el contenedor

**Síntoma** (nos pasó el 2026-06-11): tras sincronizar un `Caddyfile` nuevo,
`caddy reload --config /etc/caddy/Caddyfile` reporta éxito ("adapted config to JSON")
pero **los cambios no se aplican** — el contenedor sigue sirviendo la config vieja.

**Causa**: `compose.production.yml` monta el archivo individualmente
(`./Caddyfile:/etc/caddy/Caddyfile:ro`). Un bind mount de archivo único en Docker
apunta al **inode**, no a la ruta. Al sincronizar con `tar` (o `mv`, o el "save"
atómico de muchos editores), el archivo del host se **reemplaza por un inode nuevo**,
y el contenedor queda leyendo el inode viejo. El `reload` dentro del contenedor
relee fielmente… el archivo desactualizado.

**Solución**: recrear el contenedor para que el mount se resuelva de nuevo:

```bash
docker compose -f compose.production.yml up -d --force-recreate caddy
```

Sin miedo: los certificados TLS persisten en el volumen `caddy_data`, así que
**no hay re-emisión** con Let's Encrypt ni riesgo de rate limit; el corte es de ~2s.

**Cómo verificar que el contenedor ve la config correcta** (host vs contenedor):

```bash
head -3 ~/rag-data-pipeline/Caddyfile
docker compose -f compose.production.yml exec caddy head -3 /etc/caddy/Caddyfile
```

Si difieren, es este gotcha. Alternativa que sí permite `reload`: editar el
archivo **in-place** en la VPS (`nano`/`vim` sin swap atómico), que conserva el inode.

## Decisiones de borde (Caddy)

- `/metrics` responde **403 en el edge**: Prometheus es para scraping interno
  (desde la VPS: `curl http://localhost:80/metrics` contra el contenedor `web`).
  Si se añade un host de monitoreo, hacer whitelist en el `Caddyfile`.
- Security headers (HSTS, `X-Frame-Options`, `X-Content-Type-Options`,
  `Referrer-Policy`) los añade Caddy — Rails no los gestiona.

## ⚠️ Acople: la ingestión usa el disco local del contenedor

Al subir un PDF, `DocumentsController` lo guarda en `tmp/uploads` y encola
`DocumentIngestionJob` pasándole **la ruta del archivo**. Esto funciona porque en
producción `SOLID_QUEUE_IN_PUMA=1`: el worker corre **embebido en el mismo proceso
Puma / mismo contenedor** que la API, así que comparten ese disco.

**Antes de escalar el worker a un proceso/contenedor aparte** (p. ej. `bin/jobs`
en otro servicio de Compose, o réplicas), hay que romper este acople — si no, el
job no encontrará el archivo:

- Mover los uploads a almacenamiento compartido (Active Storage con un bucket
  S3/GCS, o un volumen montado en ambos contenedores), **o**
- Pasar los bytes del PDF al job (no la ruta), aceptando el coste de serializarlos
  en la cola.

Mientras el worker siga embebido en Puma, no hay nada que hacer.

## Kamal (alternativa, no activa)

Existe [`config/deploy.yml`](config/deploy.yml) preparado para Kamal con
`ankane/pgvector` como accesorio, pero **el despliegue activo es el de Compose**
descrito arriba.
