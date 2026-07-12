# 🧩 CASES — casos raros del dominio (RAG en español)

> ¿Qué casos del dominio encontré, con qué evidencia, y qué decidí? (Método, regla 3: **antes
> de tocar una heurística/umbral/config, el caso real se documenta; se calibra con evidencia,
> no con intuición.**) Cada caso es rastreable (`CASE-NNN`) y apunta al código y a la medición.

Ordenados por relevancia, no por antigüedad. La mayoría nació de **medir el golden set**
([`config/evals/golden_set.yml`](../config/evals/golden_set.yml)) o de observar prod.

---

## CASE-001 — Sinónimo semántico español que el léxico no ve
**Síntoma:** "maternidad" debía recuperar el chunk de "licencia parental" (`rh-008`); no comparten
palabras, así que el retrieval léxico lo perdía.
**Evidencia:** con embeddings de Gemini el retrieval ya lo traía en rank 1, pero el cross-encoder
**inglés** (`mxbai-rerank-base`) lo **demotaba fuera del top-5** (recall 1.0 → 0.958). El
**multilingüe** (`jina-reranker-v2-base-multilingual`) entiende maternidad↔parental y lo deja en
rank 1 → 1.0/1.0/1.0.
**Decisión:** reranker cross-encoder **multilingüe** (jina). *Lección: un reranker solo ayuda si
habla el idioma del corpus.* Ver [`neural_reranker.rb`](../app/services/rag/neural_reranker.rb).

## CASE-002 — Colisión léxica fuera de tema ("mundial")
**Síntoma:** una pregunta off-topic que comparte un término raro con el corpus puede puntuar alto
y hacer que el RAG **responda basura** en vez de abstenerse.
**Evidencia:** golden set **negativo** (5 preguntas fuera del corpus, incluida la colisión "mundial").
El cross-encoder neural separa dentro (≥ ~0.20) de fuera (≤ ~0.15); la señal léxica **no** (puntúa
igual por stopwords).
**Decisión:** abstención gateada por el score del cross-encoder, umbral **0.18** (`RERANK_MIN_SCORE`),
con métrica `abstention` en el harness. Ver [CASE-004] y [`query_service.rb`](../app/services/rag/query_service.rb).

## CASE-003 — Vocabulario divergente (elevador↔ascensor, clave↔contraseña)
**Síntoma:** el usuario usa un sinónimo que el documento no; el retrieval léxico puro falla.
**Evidencia:** preguntas *difíciles a propósito* del golden set; solo-vector BoW recall 0.917 → híbrido 0.958.
**Decisión:** **búsqueda híbrida** (denso pgvector + full-text español) fusionada con RRF — el denso
captura la paráfrasis, el léxico clava códigos/nombres exactos. Ver [`rrf.rb`](../app/services/rag/rrf.rb).

## CASE-004 — Calibración del umbral de abstención (0.18)
**Síntoma:** ¿dónde cortar entre "responder" y "no encontré información"?
**Evidencia:** medido sobre corpus real — dentro ≥ ~0.20, fuera ≤ ~0.15. Sanity de regresión:
`RERANK_MIN_SCORE=0.95` tumba positivas (`false_abstention`), `=0.01` deja de abstener (`abstention`);
ambos rompen el gate → el 0.18 queda protegido por CI.
**Decisión:** umbral **0.18**, con doble métrica de gate (`false_abstention` máx 0.0, `abstention` mín 0.90).

## CASE-005 — Elección de embedder por medición (e5-small vs bge-m3 vs Gemini)
**Síntoma:** el free tier de Gemini satura el bulk (429 + tope diario) → inviable indexar corpus grandes.
**Evidencia:** smoke sobre golden set — `Xenova/multilingual-e5-small` (384d): recall/MRR **1.0**, 64ms/embed,
~500MB RAM; `bge-m3` (1024d) no mejora calidad y cuesta 20× en latencia.
**Decisión:** **e5-small local (384d)** vía ONNX. Mata el rate limit, iguala a Gemini, mínima RAM/latencia.

## CASE-006 — PDF escaneado / solo imágenes (sin texto extraíble)
**Síntoma:** `pdftotext` devuelve vacío → 0 chunks; el documento quedaba `completed` en silencio y el
Read Path nunca podía responder de él.
**Decisión:** 0 chunks → marcar el documento `failed` con `metadata.error = "no_extractable_text"`
(reintentar no ayuda a un PDF sin texto). Ver [`document_ingestion_job.rb`](../app/jobs/document_ingestion_job.rb).
*(Futuro: OCR si aparece la necesidad.)*

## CASE-007 — Pregunta meta/vaga sobre un corpus chico
**Síntoma:** "¿de qué trata el documento?" abstiene aunque el doc sea on-topic.
**Evidencia (prod, 2026-06-26):** en el corpus demo (2 chunks, manual de evacuación) el cross-encoder
puntúa la pregunta meta en ~0.09 (< 0.18) → abstiene; en cambio "¿qué hago en caso de incendio?" puntúa
alto y responde con citas. El gate **discrimina** (in-corpus > off-topic) pero el umbral conservador sobre
un corpus diminuto sacrifica preguntas-resumen.
**Decisión:** aceptado como trade-off del umbral (no bajar 0.18 y arriesgar CASE-002). Con corpus más
grande deja de ser un problema. Documentado para no "arreglar" el umbral sin evidencia.

## CASE-008 — Preguntas degeneradas (solo puntuación)
**Síntoma:** `"???"` y `"..."` normalizan ambas a `""` → compartían **una** entrada de caché (una servía
la respuesta de la otra).
**Decisión:** cuando la normalización queda vacía, la clave cae a la pregunta cruda (stripped/downcased).
Ver [`query_service.rb`](../app/services/rag/query_service.rb).

## CASE-009 — Consulta a un documento aún en indexación
**Síntoma:** preguntar por un doc en `processing` (sin chunks) daba "no encontré información" — indistinguible
de "no está en el corpus".
**Decisión:** si el tenant posee los docs pero ninguno está `completed`, responder **202** con `processing: true`
(scopeado al tenant, no revela nada de otros). Ver [`chats_controller.rb`](../app/controllers/api/v1/chats_controller.rb).

## CASE-010 — 429 del free tier durante el bulk
**Síntoma:** un 429 (RESOURCE_EXHAUSTED) sostenido abortaba la ingesta y abría el circuit breaker.
**Evidencia:** el 429 es **backpressure por-minuto**, no una caída; recupera estando idle.
**Decisión:** el breaker **ignora** los 429 (`ignore:`), el `Embedder` reintenta con backoff+jitter, y cada
lote embebido se **memoiza en Solid Cache** → una ingesta cortada **reanuda** sin re-embeber. Ver
[`embedder.rb`](../app/services/rag/embedder.rb) y [`circuit_breaker.rb`](../app/services/rag/circuit_breaker.rb).
