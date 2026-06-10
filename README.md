<div align="center">

# 🚀 RAG Data Pipeline & Knowledge API

**Pipeline de ingestión RAG (Retrieval-Augmented Generation) de nivel producción** para procesar, fragmentar y vectorizar documentos PDF corporativos a gran escala, con búsqueda semántica de baja latencia y aislamiento estricto por inquilino (*multi-tenancy*).

[![Ruby](https://img.shields.io/badge/Ruby-3.3.11-CC342D?logo=ruby&logoColor=white)](.ruby-version)
[![Rails](https://img.shields.io/badge/Rails-8.1-CC0000?logo=rubyonrails&logoColor=white)](Gemfile)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)](config/database.yml)
[![pgvector](https://img.shields.io/badge/pgvector-HNSW-31648C)](db/structure.sql)
[![API Only](https://img.shields.io/badge/Mode-API--only-informational)](config/application.rb)

</div>

---

## 📖 Descripción

Este proyecto implementa un backend RAG construido sobre el ecosistema **moderno de Ruby on Rails 8**, sin depender de servicios externos para el almacenamiento vectorial. Permite a múltiples clientes (*tenants*) subir documentos PDF, procesarlos de forma asíncrona y realizar consultas en lenguaje natural que devuelven respuestas **citando las fuentes exactas** (documento y página).

El objetivo es demostrar habilidades avanzadas de **ingeniería de datos, concurrencia, seguridad y optimización de infraestructura backend**.

## 🏗️ Arquitectura

El sistema se divide en dos flujos críticos diseñados para maximizar rendimiento y disponibilidad:

```
┌─────────────────────────── WRITE PATH (asíncrono) ───────────────────────────┐
│                                                                               │
│  POST /api/v1/documents                                                       │
│        │  (valida .pdf + ≤20MB)                                               │
│        ▼                                                                       │
│  Document(status: processing) ──► DocumentIngestionJob (Solid Queue)          │
│                                        │                                       │
│        pdftotext ──► SemanticChunker ──► Embedder (lotes de 20) ──► pgvector  │
│        (Poppler)     (langchainrb)       (OpenAI + Circuit Breaker)            │
│                                        │                                       │
│                                        ▼                                       │
│                              Document(status: completed)                       │
└───────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────── READ PATH (síncrono) ─────────────────────────────┐
│                                                                               │
│  POST /api/v1/chats/query                                                     │
│        │                                                                       │
│        ▼                                                                       │
│  Embed pregunta ──► Búsqueda coseno (HNSW, top 5) ──► Prompt + LLM ──► Answer  │
│                     · filtro estricto por tenant_id    (Solid Cache)  + sources │
│                     · filtro por document_ids permitidos                       │
└───────────────────────────────────────────────────────────────────────────────┘
```

### Decisiones arquitectónicas (ADRs)

| Decisión | Justificación |
|----------|---------------|
| **Vector storage con `pgvector`** | Latencia de red cero y consistencia ACID nativa, en lugar de SaaS (Pinecone/Milvus). |
| **Índice HNSW (`vector_cosine_ops`)** | Velocidad de búsqueda bajo cargas dinámicas sin reconstruir el índice; alineado con la distancia de coseno (`<=>`). |
| **Multi-tenancy lógico** | Filtrado estricto por `tenant_id` a nivel de consulta para garantizar aislamiento de datos. |
| **Solid Queue / Solid Cache** | Procesamiento en segundo plano y caché nativos sobre PostgreSQL, sin dependencia de Redis. |
| **Cifrado en reposo (Lockbox + Blind Index)** | Las API keys de los tenants se cifran y se buscan por índice ciego sin exponer el secreto. |
| **Circuit Breaker** | Protege el proceso web/worker ante caídas o *rate-limiting* de las APIs de IA externas. |

## 🛠️ Stack Tecnológico

- **Framework:** Ruby on Rails 8.1 (modo `--api`)
- **Lenguaje:** Ruby 3.3.11
- **Base de datos:** PostgreSQL 16 + extensión `pgvector` (índice HNSW)
- **Background jobs:** Solid Queue (sobre PostgreSQL)
- **Caché:** Solid Cache
- **Servidor:** Puma
- **IA / RAG:** `langchainrb` (chunking) + `ruby-openai` (embeddings `text-embedding-3-small` 1536-d)
- **Seguridad:** `lockbox` + `blind_index`
- **Extracción PDF:** `pdftotext` (Poppler)
- **Despliegue:** Docker + Kamal

## 🗃️ Modelo de Datos

Todas las tablas usan **claves primarias UUID** (`gen_random_uuid()` vía `pgcrypto`).

| Modelo | Campos principales |
|--------|--------------------|
| **`Tenant`** | `id` (uuid), `name`, `api_key` (cifrado), `api_key_bidx` (blind index), `api_key_id` |
| **`Document`** | `id` (uuid), `tenant_id` (FK), `filename`, `status` (enum: `processing`/`completed`/`failed`), `metadata` (jsonb) |
| **`DocumentChunk`** | `id` (uuid), `document_id` (FK), `content` (text), `embedding` (`vector(1536)` + índice HNSW), `page_number` |

## 🔌 API

> Todas las rutas requieren autenticación por API key:
> `Authorization: Bearer <api_key>` (o cabecera `X-Api-Key`).

### `POST /api/v1/documents` — Subir un PDF (ingestión asíncrona)

```bash
curl -X POST http://localhost:3000/api/v1/documents \
  -H "Authorization: Bearer rag_sk_xxx" \
  -F "file=@manual.pdf"
```
```jsonc
// 202 Accepted
{ "id": "d3b0...", "filename": "manual.pdf", "status": "processing" }
```
Validaciones: extensión `.pdf` estricta y tamaño máximo **20 MB** (de lo contrario `422`).

### `GET /api/v1/documents/:id` — Estado de un documento

```jsonc
// 200 OK
{ "id": "d3b0...", "filename": "manual.pdf", "status": "completed", "chunks": 42 }
```

### `POST /api/v1/chats/query` — Consulta RAG (Read Path)

```bash
curl -X POST http://localhost:3000/api/v1/chats/query \
  -H "Authorization: Bearer rag_sk_xxx" \
  -H "Content-Type: application/json" \
  -d '{
        "document_ids": ["d3b07384-d113-4956-a5cc-8848d793c6ec"],
        "question": "¿Cuál es el protocolo en caso de incendio?",
        "stream": false
      }'
```
```jsonc
// 200 OK
{
  "answer": "Según el manual (pág. 12), el protocolo consiste en evacuar...",
  "sources": [
    { "document_id": "d3b0...", "page": 12, "text_snippet": "...evacuar por las escaleras..." }
  ],
  "latency_ms": 144
}
```

**Streaming (SSE):** con `"stream": true` la respuesta se transmite token por token como *Server-Sent Events* (`Content-Type: text/event-stream`):
```
event: token
data: {"delta":"Según "}

event: token
data: {"delta":"el "}

event: done
data: {"sources":[...],"done":true}
```

**Rate limiting:** cada API key tiene un presupuesto de peticiones por minuto (configurable con `RATE_LIMIT_PER_MINUTE`, por defecto 60). Al excederlo se responde `429 Too Many Requests` con cabecera `Retry-After`.

## 🖥️ Demo visual

Hay una página de demo (sin build, servida por el propio Rails) para subir PDFs y **chatear con streaming** sobre ellos:

```bash
bin/dev                 # levanta web + worker
# crea un tenant y copia su API key:
bin/rails runner 'puts Tenant.create!(name: "Demo").api_key'
```
Abre **http://localhost:3000/demo.html**, pega la API key, sube un PDF y pregúntale. La respuesta llega token por token (SSE) citando las páginas fuente.

## ✅ Requisitos

- **Ruby** 3.3.0+
- **PostgreSQL** 16+ con la extensión `pgvector` (`CREATE EXTENSION vector;`)
- **Poppler** (`pdftotext`) instalado en el sistema
- *(Opcional)* `OPENAI_API_KEY` para embeddings/LLM reales

> 💡 **Nota:** este proyecto está pensado para ejecutarse en **Linux/WSL2** (no Windows nativo), donde `pgvector` y Poppler se instalan sin fricción.

## ⚙️ Instalación

```bash
# 1. Dependencias del sistema (Ubuntu/Debian)
sudo apt-get install -y postgresql-16 postgresql-16-pgvector poppler-utils libpq-dev

# 2. Dependencias Ruby
bundle install

# 3. Llaves de cifrado (Lockbox + Blind Index) en las credenciales de Rails
#    (ver config/initializers/lockbox.rb y blind_index.rb)
bin/rails runner 'puts Lockbox.generate_key; puts BlindIndex.generate_key'
EDITOR="code --wait" bin/rails credentials:edit   # añade lockbox.master_key y blind_index.master_key

# 4. Crear y migrar la base de datos
bin/rails db:create db:migrate

# 5. Levantar servidor web + workers en paralelo
bin/dev
```

### Variables de entorno

| Variable | Descripción |
|----------|-------------|
| `OPENAI_API_KEY` | Habilita embeddings y respuestas reales con OpenAI. **Sin ella, el sistema usa fallbacks deterministas** para que todo el pipeline funcione localmente sin secretos. |
| `LOCKBOX_MASTER_KEY` / `BLIND_INDEX_MASTER_KEY` | Alternativa a las credenciales de Rails para entornos en contenedor. |

## 🧪 Crear un tenant y probar

```bash
# Crear un tenant y obtener su API key
bin/rails runner 't = Tenant.create!(name: "Acme"); puts t.api_key'
```

## 📂 Estructura del proyecto

```
app/
├── controllers/api/v1/   # BaseController (auth), Documents, Chats
├── jobs/                 # DocumentIngestionJob (async, retry + backoff)
├── models/               # Tenant, Document, DocumentChunk, Current
└── services/rag/         # Pipeline RAG
    ├── pdf_text_extractor.rb   # Extracción vía pdftotext
    ├── semantic_chunker.rb     # Chunking recursivo (langchainrb)
    ├── embedder.rb             # Embeddings batched + fallback
    ├── circuit_breaker.rb      # Resiliencia ante fallos externos
    ├── ingestor.rb             # Orquestación del Write Path
    ├── llm.rb                  # Generación de respuesta
    └── query_service.rb        # Read Path (retrieval + cache)
db/
├── migrate/              # Migraciones (UUID, pgvector/HNSW, cifrado)
└── structure.sql         # Esquema (SQL para preservar vector + HNSW)
```

## ⚙️ Jobs en segundo plano y Observabilidad

**Solid Queue (Write Path asíncrono):** la ingestión de PDFs corre en un worker fuera del proceso web.
```bash
bin/jobs          # worker dedicado (estilo producción)
# o bien:
bin/dev           # web + worker embebido en Puma (SOLID_QUEUE_IN_PUMA=1)
```

**Logs estructurados (lograge):** una línea JSON por petición, con `request_id`, `tenant_id` y métricas RAG de latencia:
```json
{ "method":"POST", "path":"/api/v1/chats/query", "status":200,
  "request_id":"3273...", "tenant_id":"1461...",
  "embed_ms":1.28, "search_ms":146.34, "cache_hit":false, "sources":1, "latency_ms":148 }
```
Esto permite medir p50/p95, el desglose embeddings vs. búsqueda vectorial y el hit-rate de caché (ahorro de tokens).

**Métricas Prometheus (`GET /metrics`):** contadores e histogramas de la app (sin Grafana obligatorio). Protégelo a nivel de red o con `METRICS_TOKEN`.
```
rag_queries_total 2.0
rag_cache_lookups_total{result="hit"} 1.0
rag_cache_lookups_total{result="miss"} 1.0
rag_query_latency_seconds_sum 0.146
rag_ingestions_total{status="completed"} 1.0
```

**Caché distribuida (Solid Cache sobre PostgreSQL):** la caché semántica de consultas y los contadores de rate limiting viven en Postgres, así que son **consistentes entre procesos/instancias**. En la práctica, una consulta repetida baja de ~144ms a ~2ms (cache hit).

## 🚢 Despliegue

El proyecto está preparado para empaquetarse en Docker y desplegarse con **Kamal** (ver [`config/deploy.yml`](config/deploy.yml)), usando la imagen `ankane/pgvector` como accesorio de base de datos para *zero-downtime deployments*.

## 🗺️ Roadmap

- [x] Esquema de datos (UUID + pgvector/HNSW)
- [x] Modelos y multi-tenancy
- [x] Cifrado de API keys (Lockbox + Blind Index)
- [x] Pipeline de ingestión asíncrono
- [x] Endpoint de consulta RAG (Read Path)
- [x] Autenticación por tenant
- [x] Suite de tests automatizados (Minitest, 49 tests)
- [x] Rate limiting por tenant (rack-attack)
- [x] Streaming de respuestas (SSE)
- [x] Worker de Solid Queue (proceso `bin/jobs` / embebido en Puma)
- [x] Observabilidad (logs JSON + métricas RAG + endpoint Prometheus `/metrics`)
- [x] Caché y rate limiting distribuidos (Solid Cache sobre PostgreSQL)
- [ ] Tracing distribuido (OpenTelemetry)

## 📄 Licencia

Proyecto de portafolio con fines demostrativos.

---

<div align="center">
<sub>Construido con Ruby on Rails 8 · PostgreSQL · pgvector</sub>
</div>
