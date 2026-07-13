<div align="center">

# 🚀 RAG Data Pipeline & Knowledge API

**Backend RAG (Retrieval-Augmented Generation) multi-tenant** en Rails 8 + pgvector, sin vector store SaaS. Ingiere documentos (PDF/TXT/MD) y responde preguntas en lenguaje natural con **búsqueda híbrida**, **reranking neural**, **citas a la fuente** y **abstención** cuando el corpus no cubre la pregunta.

[![CI](https://github.com/faborubio/rag-data-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/faborubio/rag-data-pipeline/actions/workflows/ci.yml)
[![Tests](https://img.shields.io/badge/tests-163%20passing-22c55e)](test/)
[![Ruby](https://img.shields.io/badge/Ruby-3.3.11-CC342D?logo=ruby&logoColor=white)](.ruby-version)
[![Rails](https://img.shields.io/badge/Rails-8.1-CC0000?logo=rubyonrails&logoColor=white)](Gemfile)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-4169E1?logo=postgresql&logoColor=white)](config/database.yml)
[![pgvector](https://img.shields.io/badge/pgvector-HNSW-31648C)](db/structure.sql)
[![API Only](https://img.shields.io/badge/Mode-API--only-informational)](config/application.rb)

### 🔴 [Demo en vivo → https://fabianragpipeline.duckdns.org/demo.html](https://fabianragpipeline.duckdns.org/demo.html)

<sub>Desplegado 24/7 en Google Cloud (Docker Compose) con HTTPS (Let's Encrypt vía Caddy)</sub>

</div>

---

## ⭐ Por qué destaca

Tres cosas que lo separan de un RAG de tutorial, **medidas, no prometidas** (golden set + gate en CI):

- **Calidad de retrieval verificada** — búsqueda híbrida (vector + full-text ES, fusión RRF) + reranker neural multilingüe → **recall@5 / MRR = 1.0** en el golden set. No es una demo que "parece" andar: hay un harness que **bloquea el merge** si la calidad regresa.
- **Sabe cuándo *no* responder (abstención)** — la mayoría de los RAG inventan ante preguntas fuera del corpus. Este mide la confianza del cross-encoder y **abstiene bajo un umbral calibrado con evidencia** (0.18, protegido por un golden set negativo). Un RAG honesto vale más que uno seguro-de-sí-mismo.
- **Sin costo ni rate-limit: embeddings neuronales locales** — embedder ONNX (`e5-small`, 384d) que **iguala a Gemini** en calidad medida (recall 1.0) a 64ms/embed, corriendo en el propio VPS. Elegido midiendo recall/RAM/latencia antes de migrar, no por moda.

> Toda decisión de peso está documentada con su *por qué* y su evidencia: [decisiones y hallazgos](docs/AUDIT.md) · [casos de dominio medidos](docs/CASES.md) · [modelo de amenazas](docs/SECURITY.md).

## 📖 Descripción

Este proyecto implementa un backend RAG construido sobre el ecosistema **moderno de Ruby on Rails 8**, sin depender de servicios externos para el almacenamiento vectorial. Permite a múltiples clientes (*tenants*) subir documentos (PDF/TXT/MD), procesarlos de forma asíncrona y realizar consultas en lenguaje natural que devuelven respuestas **citando las fuentes exactas** (documento y página) — o **abstenerse** cuando el corpus no cubre la pregunta.

El objetivo es demostrar habilidades avanzadas de **ingeniería de datos, concurrencia, seguridad y optimización de infraestructura backend**.

## ✨ Características destacadas

- 🔎 **Búsqueda híbrida + reranking**: vectorial (`pgvector`/**HNSW**) + full-text en español fusionadas con **RRF**, y una 2ª etapa de reranking *(retrieve-then-rerank)*. Embeddings **neuronales locales** (ONNX `e5-small`, sin API ni rate limit); Gemini/OpenAI opcionales y fallback determinista.
- 🏢 **Multi-tenancy** con aislamiento estricto por `tenant_id` en cada consulta.
- 🔐 **API keys cifradas en reposo** (Lockbox) con búsqueda por *blind index*.
- ⚙️ **Pipeline de ingestión asíncrono** (Solid Queue): `pdftotext` → chunking → embeddings por lotes, con reintentos y *circuit breaker*.
- 💬 **Respuestas en streaming (SSE)** token por token, citando documento y página.
- 🚦 **Rate limiting por tenant** (rack-attack) y **caché distribuida** (Solid Cache sobre PostgreSQL).
- 📈 **Observabilidad (3 pilares)**: logs JSON estructurados (lograge) + métricas **Prometheus** en `/metrics` + **tracing distribuido OpenTelemetry** (spans `rag.*`, exporter OTLP).
- 🖥️ **Demo web** (sin build) para subir PDFs y chatear; ✅ **CI verde** con 163 tests.
- 📐 **Evals de calidad RAG**: golden dataset + recall@5/MRR/keywords como **gate en CI** (con embeddings reales de Gemini: **recall 1.0**).

## 🏗️ Arquitectura

El sistema se divide en dos flujos críticos diseñados para maximizar rendimiento y disponibilidad:

**Write Path** (asíncrono, Solid Queue):

```mermaid
flowchart LR
    A["POST /api/v1/documents<br/>PDF · TXT · MD · ≤160MB"] --> C["DocumentIngestionJob<br/>Solid Queue · async"]
    C --> D["extracción<br/>pdftotext / texto plano"]
    D --> E["chunking estructural<br/>párrafos + secciones"]
    E --> F["embeddings<br/>ONNX e5-small 384d · local"]
    F --> G[("pgvector<br/>vector 384 + HNSW")]
    G --> H["Document: completed"]
```
<sub>Idempotente por `content_hash` · reintentos + circuit breaker · **reanudable** ante rate-limit (caché de embeddings en Solid Cache).</sub>

**Read Path** (síncrono):

```mermaid
flowchart LR
    Q["POST /api/v1/chats/query"] --> E["embed pregunta"]
    E --> H["búsqueda híbrida<br/>pgvector coseno + full-text ES · RRF"]
    H --> R["reranker neural<br/>cross-encoder jina multilingüe"]
    R --> C{"score ≥ umbral?"}
    C -->|sí| A["respuesta EXTRACTIVA<br/>con citas a la fuente"]
    C -->|no| X["ABSTIENE<br/>no encontré información"]
    A --> S["streaming SSE<br/>+ caché de respuestas"]
```
<sub>Scope estricto por `tenant_id` + `document_ids` en cada consulta. La respuesta es **extractiva con citas** (sin LLM generativo aún; el salto está diferido — ver [AUDIT.md](docs/AUDIT.md), `AUD-004`).</sub>

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
- **IA / RAG:** `langchainrb` (chunking) + `informers`/ONNX (embeddings locales `multilingual-e5-small` 384-d + reranker neural) — `ruby-openai`/Gemini opcionales
- **Seguridad:** `lockbox` + `blind_index`
- **Extracción PDF:** `pdftotext` (Poppler)
- **Despliegue:** Docker + Kamal

## 🗃️ Modelo de Datos

Todas las tablas usan **claves primarias UUID** (`gen_random_uuid()` vía `pgcrypto`).

| Modelo | Campos principales |
|--------|--------------------|
| **`Tenant`** | `id` (uuid), `name`, `api_key` (cifrado), `api_key_bidx` (blind index), `api_key_id` |
| **`Document`** | `id` (uuid), `tenant_id` (FK), `filename`, `status` (enum: `processing`/`completed`/`failed`), `metadata` (jsonb) |
| **`DocumentChunk`** | `id` (uuid), `document_id` (FK), `content` (text), `embedding` (`vector(384)` + índice HNSW), `page_number` |

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
Validaciones: extensión `.pdf` estricta y tamaño máximo **160 MB** (configurable con `MAX_UPLOAD_MB`; de lo contrario `422`). El archivo se **streamea a disco** (nunca a memoria) y la extracción con `pdftotext` tiene timeout (`PDF_EXTRACTION_TIMEOUT`, def 120s). Para PDFs grandes con el free tier de Gemini, el embedding se espacia (`GEMINI_THROTTLE_SECONDS`), reintenta ante 429 (sin abrir el circuit breaker) y **memoiza cada vector en Solid Cache**, de modo que una ingesta interrumpida por rate limit **reanuda** sin re-embeber. Para ingerir un PDF grande localmente de forma reanudable: `rake 'rag:ingest[/ruta/al.pdf,Nombre Tenant]'` (re-ejecutable hasta completar).

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

Una página de demo (sin build, servida por el propio Rails) con **dos cuentas fijas** sobre un mismo corpus (no hay registro abierto — control del VPS):

- **Visitante** (login, credenciales compartidas) y **anónimo** (sin login, `GET /api/v1/demo`): **solo lectura** — chatea con streaming sobre el corpus curado, con citas y abstención.
- **Admin** (login): **cura el corpus** — sube documentos (PDF/TXT/MD) que todos consultan, con un **contador de cuota** (`STORAGE_BUDGET_MB`).

`POST /api/v1/login` devuelve la API key del usuario + su `role`; la demo la guarda en `localStorage` y muestra la subida solo al admin. El permiso de subida lo decide el **rol** (`Current.user.admin?`), no la API key, así que admin y visitante comparten el mismo tenant con accesos distintos. Las cuentas se crean con `bin/rails db:seed` (passwords por `ADMIN_PASSWORD`/`VISITOR_PASSWORD`).

```bash
ADMIN_PASSWORD=... VISITOR_PASSWORD=... bin/rails db:seed   # crea admin + visitante
bin/dev                                                     # levanta web + worker
```
Abre **http://localhost:3000/demo.html**, entra como admin, sube un PDF y pregúntale. La respuesta llega token por token (SSE) citando las páginas fuente.

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
| `EMBEDDER` | `local` usa el **embedder neural local** (ONNX, `Xenova/multilingual-e5-small`, 384d) — sin API, sin rate limit, gratis; **tiene prioridad** sobre las API keys. Al activarlo (o cambiar de espacio), **re-indexa el corpus** con `bin/rails rag:reembed`. |
| `GEMINI_API_KEY` | Embeddings reales con **Google Gemini** (`gemini-embedding-001`, capa gratuita). Alternativa por API; al activarla, **re-indexa el corpus** con `bin/rails rag:reembed`. |
| `OPENAI_API_KEY` | Embeddings y respuestas con OpenAI (alternativa). **Sin ningún proveedor, el sistema usa fallbacks deterministas** para que todo el pipeline funcione localmente sin secretos. |
| `RERANKER` | `neural` activa el cross-encoder ONNX local (opt-in); por defecto, reranker léxico (ver sección de búsqueda). |
| `STORAGE_BUDGET_MB` | Cuota de subida por tenant (default **500**). Salvaguarda lógica del VPS (no es el disco); la demo muestra un contador usado/disponible y rechaza uploads que la excedan (`GET /api/v1/storage`). |
| `AUTH_RATE_LIMIT_PER_MINUTE` | Tope por IP para `login` (default **10**); frena fuerza bruta de contraseñas. |
| `ADMIN_PASSWORD` / `VISITOR_PASSWORD` | Contraseñas de las 2 cuentas de la demo que crea `db:seed` (admin secreta; visitante compartible). |
| `MAX_UPLOAD_MB` | Tamaño máximo por archivo subido (default **160**). |
| `LOCKBOX_MASTER_KEY` / `BLIND_INDEX_MASTER_KEY` | Alternativa a las credenciales de Rails para entornos en contenedor. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Activa el envío de trazas OpenTelemetry vía OTLP al colector/backend indicado (Jaeger, Grafana Tempo, Honeycomb…). Sin ella no se exporta nada (en desarrollo se imprime en consola). |

**Prioridad de proveedor de embeddings:** `EMBEDDER=local` (ONNX local) → `GEMINI_API_KEY` → `OPENAI_API_KEY` → fallback determinista (bag-of-words). Todos producen vectores de **384 dims** (la dimensión nativa del modelo local; Gemini vía `outputDimensionality`, OpenAI vía `dimensions`), así que comparten una única columna `vector(384)`. **Cambiar de proveedor implica re-embeber** (`rag:reembed`), ya que cada modelo vive en su propio espacio. El embedder local es el **default en producción** (mata el rate limit del free tier de Gemini que saturaba el bulk — ver [AUDIT.md](docs/AUDIT.md)).

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

**Caché distribuida (Solid Cache sobre PostgreSQL):** la caché de consultas y los contadores de rate limiting viven en Postgres, así que son **consistentes entre procesos/instancias**. En la práctica, una consulta repetida baja de ~144ms a ~2ms (cache hit). La clave del caché está **versionada por contenido**: la pregunta se normaliza (minúsculas, espacios, puntuación de los extremos) para que variantes triviales compartan entrada, e incluye la marca de tiempo del último chunk de los documentos, de modo que **re-ingestar un documento invalida sus respuestas cacheadas** (nunca sirve una respuesta vieja). El path de **streaming** (SSE) comparte la misma caché: una pregunta repetida reproduce la respuesta guardada sin recalcular, y una respuesta recién transmitida queda cacheada para la próxima. *(Una caché realmente semántica —hit por similitud de embedding— se difiere hasta tener generación con LLM de pago, donde un miss cuesta dinero; ver roadmap.)*

**Tracing distribuido (OpenTelemetry):** el tercer pilar de observabilidad, junto a logs y métricas. Auto-instrumenta Rack/Action Pack, Active Record (pgvector), Net::HTTP (OpenAI) y Active Job, y añade spans propios del pipeline — `rag.query` → `rag.embed` / `rag.search` / `rag.generate` en el Read Path, y `rag.ingest` → `rag.extract` / `rag.chunk` / `rag.embed` en el Write Path. Gracias a la propagación de contexto de Active Job, **una sola traza enlaza el `POST /documents` síncrono con el `DocumentIngestionJob` asíncrono** (cruzando el límite de procesos). El desglose por span revela exactamente dónde se va la latencia (típicamente la llamada al LLM domina el tiempo de la consulta).

Sin configuración no exporta nada (cero dependencias para correr local); se activa apuntando a cualquier backend OTLP:
```bash
# Enviar trazas a un colector / Jaeger / Grafana Tempo / Honeycomb
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
```
En desarrollo, sin esa variable, los spans se imprimen en consola (exporter de consola) para inspeccionarlos al instante.

## 🔎 Búsqueda híbrida (vector + full-text con RRF)

El Read Path no se queda en similitud vectorial: fusiona **dos señales complementarias** con **Reciprocal Rank Fusion**.

- **Densa (pgvector, coseno + HNSW)** — captura paráfrasis y semántica: "¿qué hago si se incendia?" recupera "protocolo de incendio" aunque no compartan palabras.
- **Léxica (full-text de Postgres, `tsvector` en español, *accent-insensitive*)** — clava términos exactos, códigos y nombres propios que el embedding diluye: "INC-01", "clase B", "VPN".

Cada señal aporta sus 20 mejores candidatos y [`Rag::Rrf`](app/services/rag/rrf.rb) los fusiona por `1/(k+rank)` (k=60), sin necesidad de normalizar escalas heterogéneas (distancia coseno vs. `ts_rank`). Todo dentro de Postgres — coherente con la arquitectura *single-database* — con sub-spans OTel `rag.search.vector` y `rag.search.fulltext` para ver el peso de cada una. El full-text usa un índice **GIN** sobre `to_tsvector('spanish', immutable_unaccent(content))` y semántica **OR** rankeada (una pregunta en lenguaje natural rara vez contiene todos los términos literales).

**Segunda etapa — reranking (retrieve-then-rerank).** Los candidatos fusionados (top-10) pasan por un reranker que los re-puntúa por par *(pregunta, pasaje)* antes de cortar a top-5, bajo el span `rag.rerank`. Hay dos detrás de la misma interfaz: un **reranker léxico** determinista (cobertura de términos + proximidad, por defecto) y un **cross-encoder neural** ONNX local ([`informers`](https://github.com/ankane/informers), opt-in con `RERANKER=neural`).

**Lo que midieron los evals (decisión data-driven).** Con embeddings reales de **Gemini** el retrieval ya es casi perfecto. Probando rerankers neuronales: el **inglés** (`mxbai-rerank-base`) *demota* el caso español `rh-008` fuera del top-5 (recall 1.0 → 0.958 — empeora), pero el **multilingüe** (`jina-reranker-v2-base-multilingual`, cuantizado ~267MB) entiende maternidad↔"licencia parental" y deja todo en rank 1 → **1.0/1.0/1.0**. Lección: *un reranker solo ayuda si habla el idioma del corpus*. El cross-encoder neural (jina) queda **opt-in** (`RERANKER=neural`) por su coste (267MB + ~1-2s/consulta en 1 CPU); el **léxico es el default** rápido y ya logra recall 1.0 (ver [AUDIT.md](docs/AUDIT.md)).

## 📐 Evals de calidad RAG

La suite de tests verifica *corrección*; los **evals** verifican *calidad de retrieval y respuesta* — y **bloquean CI si regresa**. Un golden dataset versionado ([`config/evals/golden_set.yml`](config/evals/golden_set.yml)) define 3 manuales sintéticos (~21 páginas) y 24 preguntas con páginas y keywords esperadas. El runner ([`Rag::Evals::Runner`](app/services/rag/evals/runner.rb)) ingiere el corpus por el **pipeline real** (PDF → `pdftotext` → chunking → embeddings → pgvector) y mide cada pregunta vía `Rag::QueryService`:

| Métrica | Qué mide | Solo vector (BoW) | Híbrido (BoW) | **Híbrido + Gemini** |
|---|---|---|---|---|
| **Recall@5** | ¿La página correcta del documento correcto aparece en las fuentes? | 0.917 | 0.958 | **1.000** |
| **MRR** | ¿En qué posición del ranking aparece? | 0.826 | 0.927 | **0.948** |
| **Keyword presence** | ¿La respuesta contiene los datos esperados? | 0.750 | 0.917 | **0.917** |

Las dos primeras columnas son el tier **sin secretos** (embeddings bag-of-words deterministas), que es lo que mide CI. La tercera es con **embeddings reales de Gemini** (capa gratuita) + reranker léxico — **recall perfecto** (cierra `rh-008`); reproducible local con `GEMINI_API_KEY=... bin/rails rag:evals`. El gate de CI usa el tier sin secretos para mantenerse determinista y verde.

Las columnas son el mismo golden set antes y después de la **búsqueda híbrida** (ver abajo): el harness no solo verifica calidad, **demuestra la mejora con números** (+10 pts de MRR, +17 de keyword presence). Los umbrales del gate están fijados bajo el baseline híbrido, así que una regresión a solo-vector haría fallar CI.

El gate ([`test/evals/rag_quality_test.rb`](test/evals/rag_quality_test.rb)) corre dentro de `rails test` (y por tanto en CI) con umbrales calibrados bajo el baseline. Funciona **sin API key**: el fallback del embedder usa *bag-of-words con feature hashing* (determinista, similitud léxica real), así que los evals miden retrieval significativo también en CI. El mismo harness corre contra OpenAI real:

```bash
bin/rails rag:evals                      # tier fallback (tabla por pregunta + agregados)
OPENAI_API_KEY=sk-... bin/rails rag:evals  # tier real (embeddings + LLM de OpenAI)
```

El golden set incluye preguntas *difíciles* a propósito (vocabulario divergente: "elevador" vs "ascensor", "clave" vs "contrasena") que el retrieval léxico falla — son el margen de mejora medible para los siguientes pasos del roadmap (hybrid search, reranking).

## 🚢 Despliegue

Producción corre en una VPS (Google Cloud) con **Docker Compose** ([`compose.production.yml`](compose.production.yml)): Rails + pgvector + **Caddy** como reverse proxy con HTTPS automático (Let's Encrypt) y security headers, sirviendo la [demo en vivo](https://fabianragpipeline.duckdns.org/demo.html). El procedimiento paso a paso, la verificación post-deploy y los *gotchas* conocidos (p. ej. por qué un `caddy reload` no basta tras sincronizar el `Caddyfile`) están documentados en **[DEPLOY.md](docs/DEPLOY.md)**. Los incidentes recurrentes y su solución (fallos de CI por versiones nuevas o CVEs, full-text vacío, etc.) viven en **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**, y la auditoría de mejoras de rendimiento/seguridad en **[AUDIT.md](docs/AUDIT.md)**.

La documentación compañera vive en [`docs/`](docs/) y sigue *El Método* (documentación como sistema, proporcional a la escala): **[AUDIT.md](docs/AUDIT.md)** (changelog + deuda `AUD-NNN`), **[CASES.md](docs/CASES.md)** (casos de dominio medidos `CASE-NNN`), **[SECURITY.md](docs/SECURITY.md)** (postura y modelo de amenazas), **[DEPLOY.md](docs/DEPLOY.md)** y **[TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**.

También existe configuración para **Kamal** (ver [`config/deploy.yml`](config/deploy.yml)) como alternativa, aunque el despliegue activo es el de Compose.

## 🗺️ Roadmap

**Hecho** — el detalle y el *por qué* de cada decisión viven en [AUDIT.md](docs/AUDIT.md) (el changelog real):
esquema UUID + pgvector/HNSW · multi-tenancy con API keys cifradas (Lockbox + blind index) · ingestión
asíncrona (Solid Queue) con reintentos + circuit breaker · **búsqueda híbrida** (vector + full-text ES, RRF) +
**reranking neural** · **abstención medida** (gate en CI con golden set negativo) · **embedder local ONNX**
(e5-small 384d) · respuestas extractivas con **citas inline `[n]`** · streaming SSE · caché versionada por
contenido · formatos PDF/TXT/MD · analítica y feedback por tenant · observabilidad (logs JSON + Prometheus +
OpenTelemetry) · evals con gate (**recall/MRR = 1.0**) · deploy en VPS `e2-standard-2` (Docker Compose + Caddy).

**Próximos pasos** (por valor — ver el registro de deuda `AUD-NNN` en [AUDIT.md](docs/AUDIT.md)):

- **Generación real con LLM** (`AUD-004`) — el salto de mayor impacto visible; hoy la respuesta es extractiva. Requiere proveedor de pago (Gemini con billing, o Claude Haiku ~$0.0025/respuesta) tras el patrón live/fallback ya existente.
- **Caché semántica real** (`AUD-005`) y **defensa anti prompt-injection** (`AUD-006`) — ligadas a activar el LLM generativo.

> **Para retomar:** estado, decisiones y hallazgos en [AUDIT.md](docs/AUDIT.md) (changelog + deuda `AUD-NNN`); casos de dominio medidos en [CASES.md](docs/CASES.md); postura de seguridad en [SECURITY.md](docs/SECURITY.md); deploy en [DEPLOY.md](docs/DEPLOY.md); incidentes en [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md).

## 📄 Licencia

Proyecto de portafolio con fines demostrativos.

---

<div align="center">
<sub>Construido con Ruby on Rails 8 · PostgreSQL · pgvector</sub>
</div>
