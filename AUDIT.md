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

## Pendiente / próximas auditorías

- **Respuestas reales del LLM:** hoy en fallback extractivo (Gemini tiene la
  generación bloqueada en capa gratuita; OpenAI/Claude requieren billing). Evaluar
  cuando haya un proveedor de generación gratuito o presupuesto.
- **Caché semántica real** (similitud de embedding sobre umbral) — feature, no fix.
- **Búsqueda híbrida en paralelo:** hoy las ramas vector y full-text corren en
  secuencia; podrían concurrir, pero con el pool de conexiones de AR no compensa a
  esta escala.
