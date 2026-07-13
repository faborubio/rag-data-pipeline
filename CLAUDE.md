# CLAUDE.md — contexto del proyecto

> Este archivo se carga automáticamente al iniciar cada sesión.
>
> **AL INICIAR, lee de entrada los documentos fuente de verdad para tener todo el
> contexto antes de actuar** (orden sugerido): [AUDIT.md](docs/AUDIT.md) (changelog/estado
> real + registro de deuda `AUD-NNN`), [README.md](README.md) (overview + roadmap),
> [CASES.md](docs/CASES.md) (casos de dominio medidos `CASE-NNN`),
> [SECURITY.md](docs/SECURITY.md) (postura y modelo de amenazas),
> [DEPLOY.md](docs/DEPLOY.md) (runbook VPS), [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
> (incidentes + fixes) y [SPEC.md](SPEC.md) (spec original; para el *por qué*, no el estado
> actual). Los docs compañeros viven en [`docs/`](docs/); el proyecto sigue *El Método*
> (documentación como sistema, proporcional a la escala).

## Qué es

Pipeline RAG **Rails 8.1 + pgvector**, API-only, **multi-tenant**. Write Path:
PDF/TXT/MD → extracción (`pdftotext` con timeout / texto plano) → **chunking
estructural** (párrafos + secciones) → **embeddings** (`EMBEDDER=local`: ONNX
**e5-small 384d** vía informers, sin API ni rate-limit, **default en prod** →
Gemini → OpenAI → fallback determinista BoW; idempotente por `content_hash` +
provider, caché reanudable en Solid Cache) → pgvector (`vector(384)` + HNSW).
Read Path: embed pregunta → **búsqueda híbrida** (pgvector cosine + full-text
español, fusión RRF) → **reranker neural** (cross-encoder jina multilingüe) →
**abstención por confianza** (si el score top < `RERANK_MIN_SCORE`=0.18 responde
"no encontré…"; gate medido con golden set negativo) → **respuesta extractiva
con citas inline `[n]`** (no hay LLM generativo aún) → **streaming SSE** →
**caché de respuestas** versionada por contenido (Solid Cache).

**Demo / acceso:** anónimo y **visitante** (login) = solo lectura del corpus;
**admin** (login) cura el corpus (sube docs). Sin registro abierto: 2 cuentas
fijas creadas con `db:seed` (`ADMIN_PASSWORD`/`VISITOR_PASSWORD`). Permiso de
subida por **rol** (`Current.user.admin?`), no por la API key; auth por usuario
(key propia tipo Tenant) con fallback a tenant-key. **Cuota** de subida por
tenant (`STORAGE_BUDGET_MB`, `GET /api/v1/storage`). Indicadores de carga en la UI.

También: feedback 👍/👎 (`/api/v1/feedback`), analítica por tenant
(`/api/v1/analytics`), observabilidad (logs JSON + Prometheus + OpenTelemetry),
rate limiting (rack-attack), evals con gate en CI (recall/MRR/keywords/grounding).

## Documentos fuente de verdad (leer según necesidad)

- **[AUDIT.md](docs/AUDIT.md)** — bitácora: decisiones, hallazgos medidos, lo hecho y el
  **registro de deuda `AUD-NNN`** (deuda aceptada + plan de pago). **El changelog real.**
- **[README.md](README.md)** — overview, arquitectura, roadmap (qué está hecho).
- **[CASES.md](docs/CASES.md)** — casos raros del dominio (`CASE-NNN`) con evidencia medida:
  colisión "mundial", sinónimos ES, umbral 0.18, PDF sin texto… **Leer antes de tocar una heurística/umbral.**
- **[SECURITY.md](docs/SECURITY.md)** — postura y modelo de amenazas (auth, aislamiento,
  rate-limit, subida, abstención como safety) y lo que queda fuera de alcance a propósito.
- **[DEPLOY.md](docs/DEPLOY.md)** — runbook del VPS (Docker Compose + Caddy). Incluye
  el gotcha del inode al cambiar el `Caddyfile`.
- **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)** — incidentes recurrentes y sus fixes.
- **[SPEC.md](SPEC.md)** — especificación **original** (requisitos + SAD + diseño
  del endpoint). Útil para el *por qué*; NO para el estado actual (varios detalles
  evolucionaron — ver AUDIT/README).

## Comandos clave

- Tests: `bin/rails test` · Evals: `bin/rails rag:evals`
- Ingesta local reanudable de un PDF grande: `rake 'rag:ingest[/ruta.pdf,Tenant]'`
- Todas las tasks del pipeline viven en [`lib/tasks/rag.rake`](lib/tasks/rag.rake): `rag:evals`,
  `rag:ingest`, `rag:reembed` (re-embebe tras cambiar de proveedor; sella `updated_at` para
  invalidar la caché de respuestas) y `rag:purge_query_logs` (retención de `QueryLog`).
- Deploy (desde local, ya commiteado): ver [DEPLOY.md](docs/DEPLOY.md) — en resumen
  `git archive HEAD | ssh fabian@fabianragpipeline.duckdns.org tar -x` + `docker
  compose build web && up -d web` (SSH **por el dominio**, no por IP, porque la IP
  del VPS es efímera; recrear `caddy` con `--force-recreate` solo si cambió el `Caddyfile`).
- Prod corre con `EMBEDDER=local` + `RERANKER=neural` (modelos bakeados en la imagen),
  **Puma single-mode** (`WEB_CONCURRENCY=0`, no duplica los modelos ONNX) y `/metrics`
  **fail-closed** (`METRICS_TOKEN` seteado en el `.env` del VPS).
- Demo en vivo: https://fabianragpipeline.duckdns.org (raíz redirige a `/demo.html`).
- **Al iniciar prod hay un guard** ([`retrieval_guard.rb`](config/initializers/retrieval_guard.rb)):
  aborta el boot si el reranker activo no gatea la abstención (escape `ALLOW_NON_GATING_RERANKER=1`).

## Convenciones / contexto de trabajo

- **Idioma:** hablar en **español**, explicaciones simples y directas.
- **Gratis sin cuota:** el **embedder local ONNX** (`EMBEDDER=local`, e5-small)
  reemplazó al free-tier de Gemini (que saturaba el bulk con 429) — sin API ni
  rate-limit. Para CI/tests sin secretos, el **fallback BoW** determinista. El
  salto a LLM generativo sigue diferido a un proveedor de pago.
- **Medir, no asumir:** el harness de evals y mediciones reales guían las
  decisiones (varias features nacieron de medir primero, p.ej. el umbral 0.18, o
  elegir e5-small midiendo recall/RAM/latencia antes de migrar).
- **VPS `e2-standard-2`** (2 vCPU / 8GB + 2GB swap): holgado, pero aún cuidar RAM/CPU
  (embedder + reranker ONNX cargados); modelos bakeados en la imagen Docker.
- Al cambiar el **formato de respuesta**, subir `QueryService::CACHE_VERSION`
  (si no, la caché versionada-por-contenido enmascara el cambio).
- **Documentación como sistema (*El Método*, ~/Workspace/metodo):** proporcional a la
  escala. Docs compañeros en [`docs/`](docs/); el `README` es la **cara pública**
  (profesional, para quien evalúa) y `CLAUDE.md` la **cara interna** (reentrar rápido).
  Deuda aceptada → `AUD-NNN` en [AUDIT](docs/AUDIT.md); casos de dominio → `CASE-NNN` en
  [CASES](docs/CASES.md) **antes** de tocar una heurística/umbral. Al cerrar trabajo que
  cambió el estado: sincronizar AUDIT/CASES/TROUBLESHOOTING/CLAUDE + verde + commit.
