# 🔍 Auditoría del proyecto (2026-06-14)

Revisión de las fases del pipeline (ingestión, retrieval, resiliencia, seguridad,
observabilidad, CI) buscando mejoras de rendimiento y endurecimiento. Las 8
observaciones de esta primera ronda **están implementadas** (ver commit asociado);
este documento queda como registro y base para futuras auditorías.

| # | Hallazgo | Severidad | Estado |
|---|----------|-----------|--------|
| 1 | Inserción de chunks N+1 | Rendimiento | ✅ Resuelto |
| 2 | Tráfico `/api/` sin auth no rate-limited | Seguridad | ✅ Resuelto |
| 3 | Documento marcado `failed` en cada reintento | Correctitud | ✅ Resuelto |
| 4 | "Caché semántica" es exact-match | Exactitud docs | ✅ Resuelto (wording) |
| 5 | Circuit breaker half-open deja pasar todo | Resiliencia | ✅ Resuelto |
| 6 | Ingestión acoplada al disco local | Arquitectura | ✅ Documentado |
| 7 | Validación de PDF solo por extensión | Robustez | ✅ Resuelto |
| 8 | `--ensure-latest` en `bin/brakeman` | CI/Tooling | ✅ Resuelto |

---

## 1. Inserción de chunks N+1 → `insert_all!` *(rendimiento)*

**Antes:** [`Ingestor`](app/services/rag/ingestor.rb) hacía un `create!` por chunk
dentro de la transacción — un PDF de 118 chunks = 118 INSERTs + 118 ciclos de
validación.
**Ahora:** un único `DocumentChunk.insert_all!` (timestamps explícitos). El borrado
previo se hace con `DocumentChunk.where(document_id:).delete_all` en vez de la
asociación, para no dejar el target de la asociación cacheado como vacío (gotcha:
`insert_all!` escribe por SQL y no actualizaría esa caché en memoria).
**Verificación:** [`ingestor_test.rb`](test/services/rag/ingestor_test.rb).

## 2. Rate limiting para tráfico sin autenticar *(seguridad)*

**Antes:** [`rack_attack.rb`](config/initializers/rack_attack.rb) solo throttleaba
keyeando por hash de la API key; las requests **sin** key retornaban `nil` → sin
límite. Un atacante podía hacer fuerza bruta de keys sin tope (cada intento dispara
una búsqueda por blind index).
**Ahora:** segundo throttle por **IP** para `/api/` sin key
(`UNAUTH_RATE_LIMIT_PER_MINUTE`, default 20/min). Extracción de la key refactorizada
a `RateLimit.api_key(req)` y reutilizada por ambos throttles.
**Verificación:** test "throttles unauthenticated API traffic by IP" en
[`rate_limit_test.rb`](test/integration/api/v1/rate_limit_test.rb).

## 3. Estado `failed` solo en el intento final *(correctitud)*

**Antes:** [`DocumentIngestionJob`](app/jobs/document_ingestion_job.rb) marcaba el
documento `failed` en **cada** reintento fallido y re-lanzaba, así que el status
parpadeaba `failed → processing → failed` entre retries (un cliente podía leer un
estado falso).
**Ahora:** se marca `failed` (y se incrementa la métrica) **solo** cuando
`executions >= MAX_ATTEMPTS`; mientras quedan reintentos el documento permanece
`processing`.
**Verificación:** tests "stays processing while retries remain" y "marks the
document failed only on the final attempt".

## 4. "Caché semántica" → caché exact-match *(exactitud de docs)*

**Antes:** README y comentarios llamaban "caché semántica" a una caché cuya clave es
`SHA256(pregunta + document_ids)` — solo hay hit con pregunta **idéntica**.
**Ahora:** wording corregido en [README](README.md) y
[`query_service.rb`](app/services/rag/query_service.rb) a "exact-match", con nota de
que una caché por similitud de embedding es trabajo futuro (roadmap).

## 5. Circuit breaker: half-open real *(resiliencia)*

**Antes:** [`CircuitBreaker`](app/services/rag/circuit_breaker.rb) al expirar el
`reset_timeout` reseteaba `failures = 0` y dejaba pasar **todo** el tráfico de golpe
(*thundering herd* contra la dependencia que se intenta proteger).
**Ahora:** máquina de estados `closed → open → half_open → closed/open`. En half-open
se admite **una sola** request de prueba; las concurrentes se rechazan, y si la
prueba falla el circuito vuelve a `open` de inmediato.
**Verificación:** tests de re-apertura y de "admite un solo trial" (con dos hilos) en
[`circuit_breaker_test.rb`](test/services/rag/circuit_breaker_test.rb).

## 6. Acople de la ingestión al disco local *(arquitectura)*

**Hallazgo:** el upload se guarda en `tmp/uploads` y se pasa la **ruta** al job.
Funciona porque en producción `SOLID_QUEUE_IN_PUMA=1` (worker embebido en Puma,
mismo contenedor). Si se escala el worker a un contenedor aparte, el job no
encontrará el archivo.
**Acción:** documentado en [DEPLOY.md](DEPLOY.md) con las dos salidas (Active Storage
/ volumen compartido, o pasar los bytes al job) a aplicar **antes** de separar el
worker. No requiere cambio de código hoy.

## 7. Validación de PDF por magic bytes *(robustez)*

**Antes:** [`DocumentsController#pdf?`](app/controllers/api/v1/documents_controller.rb)
validaba solo la extensión `.pdf`; un archivo no-PDF renombrado pasaba y fallaba más
tarde en `pdftotext`.
**Ahora:** además de la extensión, se leen los primeros bytes y se exige la cabecera
`%PDF-` (con `rewind` para no consumir el IO antes de guardarlo).
**Verificación:** test "rejects a non-pdf disguised with a .pdf extension" en
[`documents_test.rb`](test/integration/api/v1/documents_test.rb).

## 8. `--ensure-latest` fuera de `bin/brakeman` *(CI/tooling)*

**Antes:** el binstub pasaba `--ensure-latest`, que hace fallar el scan cada vez que
se publica una versión nueva de Brakeman — un rojo de CI ajeno a tu código (ocurrió
el 2026-06-14). **Ahora:** se quitó la bandera; Dependabot mantiene la gema al día.
Detalle en [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Hallazgo: el cross-encoder neural inglés perjudica el español (2026-06-14)

Se implementó *retrieve-then-rerank* con dos rerankers (léxico + cross-encoder
neural ONNX). **Medición con embeddings reales de Gemini** sobre el golden set:

| Config | recall@5 | MRR | keywords |
|---|---|---|---|
| Gemini + reranker **léxico** (default) | 1.000 | 0.948 | 0.917 |
| Gemini + neural **`mxbai-rerank-base`** (inglés) | 0.958 ↓ | 0.958 | 0.958 |
| Gemini + neural **`jina-reranker-v2-base-multilingual`** | **1.000** | **1.000** | **1.000** |

Con Gemini, el retrieval ya trae el chunk correcto de `rh-008` ("maternidad"→
"licencia parental") en **rank 1**. El cross-encoder **inglés** (mxbai) no entiende
ese sinónimo español y lo **demota fuera del top-5** (recall 1.0 → 0.958) — *empeora*
lo que el retrieval acertó. Al cambiar al cross-encoder **multilingüe** (jina v2,
cuantizado ~267MB) el problema desaparece: entiende maternidad↔parental y deja todo
en **rank 1** → **1.0/1.0/1.0**.

**Lecciones:** (1) el salto principal vino de los **embeddings** (Gemini); (2) un
reranker solo ayuda si **habla el idioma del corpus** — uno inglés sobre español es
net-negativo. `NeuralReranker::MODEL` es ahora jina multilingüe; el reranker sigue
**opt-in** (`RERANKER=neural`) por su coste (267MB + ~1-2s/consulta en 1 CPU), con
el léxico como default rápido (que ya logra recall 1.0).

## Estado actual del pipeline (2026-06-14)

Producción (demo pública) corre: **embeddings Gemini** (free tier) → búsqueda
**híbrida** (vector + full-text, RRF) → **reranker neural multilingüe jina**
(`RERANKER=neural`, modelo bakeado en la imagen) → **respuesta extractiva enfocada**
(frase relevante + multi-fuente, sin LLM). Evals con este stack: **recall/MRR/
keywords = 1.0**. Demo solo-lectura, 1 documento (`manual-seguridad-rag.pdf`).
Latencia ~1.4s en caliente. Hallazgo operativo: el **free tier de Gemini limita la
indexación masiva** (429); las consultas en vivo (cacheadas) van bien.

## Hecho desde la última auditoría

- **Idempotencia de embeddings** — `document_chunks` lleva `content_hash` (SHA256
  del contenido) + `embedding_provider`. El ingestor reusa vectores ya guardados
  para contenido idéntico del **mismo** provider y solo embebe lo nuevo; re-ingestar
  un documento sin cambios es un único SELECT con cero llamadas al embedder. No se
  mezclan espacios de distintos providers (la clave incluye el provider; las filas
  viejas con provenance NULL nunca se reusan hasta re-embeberse).

- **Chunking estructural** — el `SemanticChunker` segmenta por párrafos (con reflow
  de líneas cortadas por `pdftotext -layout`) y secciones (encabezados tipo
  "Artículo 5", "Capítulo II", "1.2"), empaca bloques hasta ~500 chars **sin** cruzar
  el inicio de una sección, y solo parte con langchain (preservando overlap) cuando un
  bloque solo excede el límite. Cada chunk queda semánticamente coherente. Medido: en
  el corpus limpio de la demo los evals no cambian (recall 0.958 / MRR 0.906 /
  keywords 0.833, idénticos al baseline) — la ganancia es robustez con PDFs reales
  desordenados.

- **Caché de consultas endurecida** — la clave ahora se versiona por contenido:
  `cache_key` normaliza la pregunta (minúsculas, espacios, puntuación de los extremos;
  **sin** quitar acentos para no cambiar significado en español) y le suma
  `MAX(updated_at)` de los chunks de los documentos. Efecto: variantes triviales de la
  misma pregunta comparten entrada, y re-ingestar un documento **invalida** sus
  respuestas cacheadas (antes podían quedar viejas hasta 1h). Con la clave versionada
  el TTL ya no es un riesgo de staleness, así que subió a 12h (más hits).

- **Caché también en el path de streaming** — `QueryService#call_streaming` comparte la
  misma clave y payload que `#call`. En hit reproduce la respuesta guardada en un solo
  delta (sin embed/search/rerank/LLM); en miss transmite token a token, acumula y la
  guarda al final (no cachea respuestas parciales si el cliente se desconecta). Una
  pregunta servida por streaming queda cacheada para la próxima, streamed o no, y
  viceversa. El controller (`stream_answer`) ya no llama al LLM directo.

- **PDFs grandes con recursos limitados** — cambios para procesar un PDF pesado (medido
  con un libro real de 147MB / 339 págs) sin VPS más grande: (1) `MAX_SIZE` 20→160MB
  (`MAX_UPLOAD_MB`) y upload **streameado a disco** (`IO.copy_stream` del tempfile de
  Rack, ya no `file.read` a RAM). (2) **timeout** en `pdftotext` (`PDF_EXTRACTION_TIMEOUT`,
  def 120s) vía `popen3`+threads+SIGKILL. (3) **throttle + retry/backoff ante 429** en el
  `Embedder`, y el **circuit breaker ignora los 429** (`ignore:` en `CircuitBreaker`) —
  un 429 es backpressure, no caída, así que ya no abre el breaker ni aborta la ingesta.

  **Medición real (local):** extracción 10s y **solo ~21MB de RAM** (pdftotext procesa
  página a página → el miedo a la RAM del VPS quedó descartado); 339 págs → **2.075
  chunks** → 104 lotes. El muro real es el **rate limit del free tier de Gemini**
  (RESOURCE_EXHAUSTED): el bulk sostenido lo satura; recupera estando idle (es sobre todo
  por-minuto) pero puede haber tope diario.

- **Embedding reanudable (free-tier friendly)** — el `Embedder` memoiza cada embedding en
  **Solid Cache** (clave `provider+sha256(texto)`, TTL 30d), escrito **lote a lote**. Si
  una corrida se corta por rate limit, lo ya embebido sobrevive y un re-run solo pide lo
  que falta (validado: 2ª corrida = 0 llamadas a la API). Rake task `rag:ingest[path,tenant]`
  re-ejecutable para ingerir un PDF local y reanudar entre días. `GEMINI_THROTTLE_SECONDS`
  def 5s. Camino elegido para no pagar; el salto a Gemini billing lo volvería innecesario.

- **Hardening de auditoría (3 bombas)** — (1) **fuga de temp**: `cleanup` del upload solo
  corría en éxito → cualquier ingesta fallida dejaba el archivo (100MB+) y llenaba el
  disco; ahora se borra también en fallo terminal y en doc borrado. (2) **upload sin tope
  en el edge**: Caddy rechaza bodies >170MB (por encima del límite app de 160MB) para que
  un body gigante no se streamee a disco antes del check (DoS). (3) **ingesta web no era
  rate-limit-aware**: un 429 marcaba `failed` tras 5 reintentos rápidos; ahora reintenta
  cada hora (`RATE_LIMIT_ATTEMPTS=6`) dejando el doc `processing` y reanudando desde la
  caché del embedder. Auditoría también confirmó OK: OTel no floodea prod (exporter
  gateado por entorno), auth en tiempo constante (blind index), retrieval scopeado por
  tenant.

- **Hardening escalabilidad (2ª tanda)** — (1) **bug latente del pool de DB**: `database.yml`
  usaba `max_connections:` (clave que AR **ignora**) en vez de `pool:`, así que el pool NO
  escalaba con `RAILS_MAX_THREADS` y estaba en el default; corregido a `pool:` (verificado:
  ahora `pool.size == RAILS_MAX_THREADS`). (2) **Inanición de threads por streaming**:
  `RAILS_MAX_THREADS` 3→6 (el VPS es 1 CPU, así que más threads en un proceso resuelve el
  cuello I/O-bound del SSE mejor que 2 workers; Solid Queue corre 1 sola vez vía fork en el
  master, sin duplicar jobs). (3) **`insert_all!`** ahora en lotes de 500 (statement acotado,
  misma transacción atómica). (4) **TTL caché embeddings** 30d→7d para no desalojar la caché
  de respuestas en los 256MB compartidos.

- **Respuestas con umbral de confianza (abstención)** — un RAG que siempre responde
  **inventa** ante preguntas fuera del corpus (medido: un manual de conducir "respondía"
  la capital de Francia, cómo hacer una torta, la fotosíntesis). Ahora sabe cuándo NO
  responder: los rerankers devuelven `[chunk, score]` y exponen `confident?(top_score)`.
  La señal **léxica no sirve** (fuera de tema puntuaba igual que dentro por stopwords);
  el **cross-encoder neural sí** (medido: dentro ≥ ~0.20, fuera ≤ ~0.15 — umbral **0.18**,
  `RERANK_MIN_SCORE`). `QueryService` abstiene (devuelve "No encontré información…", sin
  fuentes) en ruta sync y streaming. Validado end-to-end y **en producción** (Gemini +
  neural): dentro responde, fuera abstiene. *(Idea #1 de 4.)*

- **Las otras 3 ideas (todas desplegadas y verificadas en prod):** **#2 grounding eval** —
  métrica de fidelidad en el harness (fracción de tokens de la respuesta presentes en el
  contexto; 1.000 con respuestas extractivas, gate min 0.90 — caza alucinaciones del LLM
  futuro). **#4 analítica por tenant** — `QueryLog` (1 fila por consulta, best-effort) +
  `GET /api/v1/analytics` (volumen, tasa de respuesta, cache-hit, top preguntas, vacíos de
  contenido = abstenciones). **#3 UI** — la demo ahora estila la abstención, muestra
  pills de latencia/caché por respuesta (el evento SSE `done` lleva `cache_hit`+`latency_ms`),
  chips sugeridos (uno fuera de tema), auto-selección de docs y panel de analítica en vivo.

- **3 features más (desplegadas y verificadas en prod):** **citas inline `[n]`** (la
  respuesta extractiva referencia cada fuente por su posición; completa trazabilidad junto
  a abstención+grounding); **formatos TXT/Markdown** (`PlainTextExtractor` + `Rag.extractor_for`
  por extensión; el upload conserva su extensión real; controller acepta pdf/txt/md);
  **feedback 👍/👎** (`POST /api/v1/feedback {query_id, rating}`, el query devuelve `query_id`
  en JSON y en el evento SSE `done`; analítica suma thumbs). También: la clave de caché ahora
  lleva `CACHE_VERSION` para que cambios de formato de respuesta **se invaliden solos** (un
  cambio de código quedaba enmascarado por la caché versionada-por-contenido).

- **Gate de abstención medido (golden set negativo)** — la abstención (umbral 0.18) estaba
  validada a mano y en prod, pero **nada automatizado** la protegía de una regresión silenciosa
  (subir/bajar `RERANK_MIN_SCORE`, cambiar el modelo, romper el plumbing de `confident` → el RAG
  volvería a *inventar* sin que ningún test lo note). Ahora el harness lleva un bloque
  `negatives:` en el golden set (5 preguntas fuera del corpus, incl. la colisión léxica
  "mundial") y dos métricas: **`false_abstention`** (positivas abstenidas por error, máx **0.0**)
  y **`abstention`** (negativas correctamente abstenidas, mín **0.90**). Respeta la asimetría
  de los rerankers: el **léxico** no puede abstener (`confident? = true`), así que el piso de
  abstención **solo se exige cuando el reranker realmente gatea** (`abstention_gated`); en el
  tier léxico de CI solo se verifica que las positivas nunca abstienen. El gate de CI determinista
  (`rag_quality_test.rb`) añade el test de `false_abstention == 0`; la abstención real es gate del
  tier neural (`RERANKER=neural bin/rails rag:evals`), espejo del tier Gemini. **Medido:** léxico
  → false_abstention 0.0, abstención n/a, PASS; neural → 5/5 abstienen, abstention 1.0, PASS.
  Sanidad de regresión: `RERANK_MIN_SCORE=0.95` falla por false_abstention (tumba positivas) y
  `=0.01` falla por abstention (deja de abstener) — el gate efectivamente protege el umbral.

## Pendiente / próximas auditorías (trabajo opcional, por valor)

0. **Del audit, menor/cosmético:** `WEB_CONCURRENCY=1` deja Puma en cluster-mode con 1 worker
   (desperdicio; pasar a single-mode o 2 workers); `documents_version` sin scope de tenant
   (no hay fuga, solo prolijidad).


1. **Generación real con LLM** — el fallback ya es extractivo-enfocado; el salto a
   respuestas generadas requiere proveedor de pago (Gemini con billing / Claude
   Haiku) tras el patrón live/fallback existente.
2. **Caché semántica real** — diferida a propósito: el embed (lo que ahorraría) es la
   parte barata; el ahorro grande (rerank + LLM) recién vale con LLM de pago, y trae
   riesgo de hit incorrecto. Revisar junto con la generación real.
