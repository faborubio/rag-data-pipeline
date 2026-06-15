# CLAUDE.md — contexto del proyecto

> Este archivo se carga automáticamente al iniciar cada sesión. **Para contexto
> profundo, lee primero [AUDIT.md](AUDIT.md) (bitácora de decisiones, hallazgos y
> todo lo hecho) y [README.md](README.md) (overview + roadmap).**

## Qué es

Pipeline RAG **Rails 8.1 + pgvector**, API-only, **multi-tenant**. Write Path:
PDF/TXT/MD → extracción (`pdftotext` con timeout / texto plano) → **chunking
estructural** (párrafos + secciones) → **embeddings** (Gemini free-tier →
OpenAI → fallback determinista; idempotente por `content_hash` + caché
reanudable en Solid Cache) → pgvector. Read Path: embed pregunta → **búsqueda
híbrida** (pgvector cosine + full-text español, fusión RRF) → **reranker neural**
(cross-encoder jina multilingüe) → **abstención por confianza** (si el score top
< `RERANK_MIN_SCORE`=0.18 responde "no encontré…") → **respuesta extractiva con
citas inline `[n]`** (no hay LLM generativo aún) → **streaming SSE** →
**caché de respuestas** versionada por contenido (Solid Cache).

También: feedback 👍/👎 (`/api/v1/feedback`), analítica por tenant
(`/api/v1/analytics`), observabilidad (logs JSON + Prometheus + OpenTelemetry),
rate limiting (rack-attack), evals con gate en CI (recall/MRR/keywords/grounding).

## Documentos fuente de verdad (leer según necesidad)

- **[AUDIT.md](AUDIT.md)** — bitácora: decisiones, hallazgos medidos, todo lo
  hecho y lo pendiente (por valor). **El changelog real del proyecto.**
- **[README.md](README.md)** — overview, arquitectura, roadmap (qué está hecho).
- **[DEPLOY.md](DEPLOY.md)** — runbook del VPS (Docker Compose + Caddy). Incluye
  el gotcha del inode al cambiar el `Caddyfile`.
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — incidentes recurrentes y sus fixes.
- **[SPEC.md](SPEC.md)** — especificación **original** (requisitos + SAD + diseño
  del endpoint). Útil para el *por qué*; NO para el estado actual (varios detalles
  evolucionaron — ver AUDIT/README).

## Comandos clave

- Tests: `bin/rails test` · Evals: `bin/rails rag:evals`
- Ingesta local reanudable de un PDF grande: `rake 'rag:ingest[/ruta.pdf,Tenant]'`
- Deploy (desde local, ya commiteado): ver [DEPLOY.md](DEPLOY.md) — en resumen
  `git archive HEAD | ssh … tar -x` + `docker compose build web && up -d web`
  (recrear `caddy` con `--force-recreate` solo si cambió el `Caddyfile`).
- Demo en vivo: https://fabianragpipeline.duckdns.org (raíz redirige a `/demo.html`).

## Convenciones / contexto de trabajo

- **Idioma:** hablar en **español**, explicaciones simples y directas.
- **Free-tier first:** desarrollar/medir con el **embedder fallback** (gratis,
  instantáneo, sin cuota); Gemini free-tier tiene **tope diario** que satura el
  bulk. El salto a LLM generativo está diferido a un proveedor de pago.
- **Medir, no asumir:** el harness de evals y mediciones reales guían las
  decisiones (varias features nacieron de medir primero, p.ej. el umbral 0.18).
- **VPS chico** (1 CPU / 3.8GB): cuidar RAM y CPU en cambios de infra.
- Al cambiar el **formato de respuesta**, subir `QueryService::CACHE_VERSION`
  (si no, la caché versionada-por-contenido enmascara el cambio).
