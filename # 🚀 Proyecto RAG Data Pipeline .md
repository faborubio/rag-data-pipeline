# 🚀 Proyecto: RAG Data Pipeline & Knowledge API (Ruby on Rails 8)

Este es el repositorio de un **Pipeline de Ingestión RAG (Retrieval-Augmented Generation)** de nivel de producción diseñado para procesar, fragmentar y vectorizar documentos PDF corporativos a gran escala. Permite realizar consultas semánticas y auditorías en tiempo real con aislamiento estricto por inquilino (*Multi-tenancy*).

El objetivo principal de este proyecto es demostrar habilidades avanzadas de **ingeniería de datos, concurrencia y optimización de infraestructura backend** utilizando el ecosistema moderno de Ruby on Rails 8, sin depender de servicios externos innecesarios para el almacenamiento vectorial.

---

## ✅ Estado de Implementación

> Este documento es la **especificación original**. El proyecto se implementó **por completo y se extendió** más allá del alcance inicial. Para la guía de uso, arquitectura y endpoints actualizados, ver el **[README](README.md)**.

### Requisitos de la spec — todos implementados
- ✅ Esquema con **UUID** + **pgvector/HNSW** (`vector_cosine_ops`) — `db/migrate/`, `db/structure.sql`
- ✅ Modelos `Tenant` / `Document` (enum `status`) / `DocumentChunk` (`has_neighbors`) — `app/models/`
- ✅ **Cifrado** de API keys en reposo (Lockbox + Blind Index) — `app/models/tenant.rb`
- ✅ **Pipeline de ingestión asíncrono**: `pdftotext` → chunking (langchainrb) → embeddings en lotes de 20 — `app/services/rag/`, `app/jobs/document_ingestion_job.rb`
- ✅ **Resiliencia**: reintentos con backoff exponencial + **Circuit Breaker** — `app/services/rag/circuit_breaker.rb`
- ✅ Endpoint **`POST /api/v1/chats/query`** (coseno top-5, filtro por `tenant_id` + `document_ids`, payload exacto) — `app/controllers/api/v1/chats_controller.rb`, `app/services/rag/query_service.rb`
- ✅ **Autenticación por tenant** vía API key (blind index)
- ✅ Stack: Rails 8 API · Puma · Solid Queue · Solid Cache · PostgreSQL 16 + pgvector · Kamal

### Construido más allá de la spec (extras)
- ➕ **Suite de tests** (Minitest, 53 tests) y **CI verde** en GitHub Actions
- ➕ **Streaming SSE** real (`stream: true`) — respuesta token por token
- ➕ **Rate limiting por tenant** (rack-attack, 429 + Retry-After)
- ➕ **Caché distribuida** (Solid Cache sobre PostgreSQL) para la caché semántica y los contadores
- ➕ **Observabilidad**: logs JSON estructurados (lograge) + métricas **Prometheus** en `/metrics`
- ➕ **Demo web** sin build (`public/demo.html`): subir PDF + chat con streaming
- ➕ Worker de Solid Queue dedicado (`bin/jobs`) o embebido en Puma (`bin/dev`)

---

## 🏗️ Software Architecture Document (SAD)

### 1. Vista de Procesos (Flujo de Datos)
El backend se divide en dos flujos críticos diseñados para maximizar el rendimiento y la disponibilidad:
* **Pipeline de Ingestión Asíncrono (Write Path):** Los PDFs pesados se reciben, se extraen, se segmentan semánticamente y se vectorizan de forma 100% asíncrona mediante trabajadores concurrentes.
* **Motor de Búsqueda Semántica & Contexto (Read Path):** Consultas de baja latencia que utilizan índices vectoriales avanzados sobre PostgreSQL para responder preguntas citando las fuentes exactas en milisegundos.
### 2. Decisiones Arquitectónicas Significativas (ADRs)
* **Aislamiento de Datos (Multi-tenancy):** Se implementa filtrado estricto por `tenant_id` en todas las consultas a nivel de base de datos (`Row-Level Security` lógico) para garantizar que ningún cliente acceda a vectores ajenos.
* **Vector Storage:** Se elige `pgvector` sobre soluciones SaaS (Pinecone, Milvus) para reducir la latencia de red a cero y simplificar la consistencia de datos mediante transacciones ACID nativas.
* **Indexing Estructurado:** Uso de índices **HNSW (Hierarchical Navigable Small World)** en lugar de IVFFlat para priorizar la velocidad de búsqueda bajo cargas de datos dinámicas y evitar la necesidad de reconstruir el índice periódicamente. El índice se crea con la clase de operadores **`vector_cosine_ops`** para alinearse con la búsqueda por **distancia de coseno** (operador `<=>`) usada en el Read Path.
* **Background Processing:** Adopción de `Solid Queue` para alinearse con la arquitectura nativa de Rails 8, eliminando la dependencia obligatoria de Redis y usando bloqueos de fila de alta velocidad (`FOR UPDATE SKIP LOCKED`).

---

## 📝 Especificaciones Técnicas para la IA (System Specs)

### 1. Esquema de Base de Datos y Modelos (ActiveRecord)
* **`Tenant`**: `id` (UUID), `name` (string), `api_key_id` (string).
* **`Document`**: `id` (UUID), `tenant_id` (FK), `filename` (string), `status` (enum: `[processing, completed, failed]`), `metadata` (jsonb).
* **`DocumentChunk`**: `id` (UUID), `document_id` (FK), `content` (text), `embedding` (vector, 1536 dimensiones), `page_number` (integer).
  * *Nota obligatoria:* El vector debe ser de 1536 dimensiones debido al uso del modelo estándar `text-embedding-3-small` de OpenAI.
  * *Nota de implementación:* Los IDs UUID se generan en el servidor con `gen_random_uuid()`, por lo que la base de datos requiere también la extensión **`pgcrypto`** (además de `vector`).

### 2. Reglas del Pipeline de Ingestión (The Worker Logic)
1. **Validación:** Validar en el controlador que el archivo sea estrictamente `.pdf` y tenga un tamaño máximo de 20MB.
2. **Extracción:** Delegar el procesamiento pesado al binario compilado de C/C++ `pdftotext` (paquete Poppler) invocándolo mediante subprocesos para optimizar memoria RAM.
3. **Estrategia de Chunking Semántico:**
   * Utilizar un `RecursiveCharacterTextSplitter` a través de la gema `langchainrb`.
   * Configurar un tamaño máximo de **500 tokens** por fragmento.
   * Aplicar un solapamiento (*overlap*) del **10% (50 tokens)** para mantener consistencia contextual entre bordes de fragmentación.
4. **Vectorización:** Agrupar los chunks en lotes (*batches*) de 20 antes de enviarlos a la API de embeddings para minimizar llamadas de red externas.

### 3. Mitigación de Fallos (Resiliencia Backend)
* Los jobs en `Solid Queue` deben implementar políticas de reintento automáticos con retroceso exponencial (*exponential backoff*).
* Implementar el patrón *Circuit Breaker* en el servicio cliente de IA para evitar degradar el servidor web si las APIs externas sufren caídas globales o *rate-limiting*.

---

## 🛠️ Diseño del Endpoint Crítico: Consulta RAG

### `POST /api/v1/chats/query`
Este endpoint maneja de forma síncrona y optimizada el flujo de recuperación y generación de lenguaje natural.

#### Lógica Interna del Servicio backend:
1. Convierte el parámetro `question` enviado por el usuario en un embedding vectorial utilizando la gema `langchainrb`.
2. Ejecuta una búsqueda de similitud de coseno en la base de datos PostgreSQL usando el operador `<=>`.
3. Aplica un filtro de seguridad estricto para asegurar que solo busque dentro de los `document_ids` proporcionados y permitidos para el `tenant_id` autenticado.
4. Recupera los **5 fragmentos más relevantes**.
5. Construye un Prompt del Sistema inyectando el contexto recuperado y envía la solicitud al LLM.

#### Consulta SQL Semántica Requerida (Alineada con ActiveRecord):
```sql
SELECT content, page_number, document_id 
FROM document_chunks 
WHERE document_id IN (SELECT id FROM documents WHERE tenant_id = :current_tenant_id)
  AND document_id IN (:allowed_document_ids)
ORDER BY embedding <=> :query_vector 
LIMIT 5;
```

Estructura Payload HTTP:
Cuerpo de la Solicitud (JSON):

JSON
{
  "document_ids": ["d3b07384-d113-4956-a5cc-8848d793c6ec"], 
  "question": "¿Cuál es el protocolo de seguridad en caso de incendio corporativo?",
  "stream": false
}
Cuerpo de la Respuesta (JSON):

JSON
{
  "answer": "Según el manual de operaciones de la empresa (pág. 12), el protocolo en caso de incendio consiste en evacuar inmediatamente por las escaleras de emergencia y...",
  "sources": [
    { "document_id": "d3b07384-d113-4956-a5cc-8848d793c6ec", "page": 12, "text_snippet": "...el protocolo en caso de incendio consiste en evacuar inmediatamente..." },
    { "document_id": "d3b07384-d113-4956-a5cc-8848d793c6ec", "page": 13, "text_snippet": "...usar siempre las escaleras de emergencia, queda prohibido el ascensor..." }
  ],
  "latency_ms": 420
}
🛠️ Stack Tecnológico de Alto Rendimiento ("Para que vuele")
Framework Core: Ruby on Rails 8.0+ configurado estrictamente en Modo API (--api) para limpiar la pila de middleware de dependencias innecesarias de frontend.

Servidor Web: Puma 6+ configurado con balance de subprocesos e hilos ajustados para rendimiento máximo de entrada/salida (I/O).

Gestor de Tareas Asíncronas: Solid Queue corriendo nativamente sobre PostgreSQL.

Motor de Base de Datos Vectorial: PostgreSQL 16+ + la extensión pgvector e índice HNSW.

Caché Semántica y de Datos: Solid Cache para almacenar respuestas completas de consultas idénticas frecuentes sobre discos NVMe locales, reduciendo drásticamente los costos de tokens API.

Gemas de Integración Clave:

langchainrb: Orquestación estructural del flujo de IA.

pgvector & neighbor: Adaptadores DSL de ActiveRecord para operaciones vectoriales eficientes.

lockbox & blind_index: Para encriptar de manera segura en reposo las API Keys de los tenants.

🚢 Configuración de Despliegue de Producción con Kamal
El proyecto está diseñado para empaquetarse en contenedores Docker y desplegarse automáticamente en cualquier VPS mediante Kamal, garantizando Zero Downtime y desacoplamiento de infraestructura.

Archivo de Configuración: config/deploy.yml
YAML
service: rag-pipeline-api

image: tu-usuario-dockerhub/rag-pipeline-api

servers:
  web:
    hosts:
      - 123.456.78.90 # IP Pública de producción
    labels:
      traefik.http.routers.rag-pipeline.rule: Host(`api.tuproyecto.com`)
      traefik.http.routers.rag-pipeline.tls: true

# Desacoplamiento de procesamiento: Ejecución aislada de Solid Queue
jobs:
  hosts:
    - 123.456.78.90
  cmd: bundle exec rails solid_queue:start

# Variables de Entorno Seguras e Inyecciones de Secretos
env:
  clear:
    DB_HOST: 123.456.78.90
    RAILS_LOG_TO_STDOUT: true
    RAILS_MAX_THREADS: 5
  secret:
    - RAILS_MASTER_KEY
    - OPENAI_API_KEY
    - DATABASE_URL

# Accesorios de Infraestructura: Contenedor Postgres con soporte Vectorial
accessories:
  db:
    image: ankane/pgvector:latest # Imagen preconfigurada con pgvector listo
    host: 123.456.78.90
    port: 5432
    env:
      POSTGRES_USER: rag_backend_user
      POSTGRES_PASSWORD: <%= ENV["DATABASE_PASSWORD"] %>
    directories:
      - data:/var/lib/postgresql/data
🏁 Inicialización del Entorno de Desarrollo
Requisitos del Sistema Anfitrión:
Ruby 3.3.0 o superior.

Binarios de sistema instalados: poppler-utils (para pdftotext).

Servidor PostgreSQL local con la extensión pgvector activada (CREATE EXTENSION IF NOT EXISTS vector;). Nota: el proyecto/paquete se llama "pgvector", pero el nombre real de la extensión dentro de PostgreSQL es `vector` (no `pgvector`). Se requiere además `CREATE EXTENSION IF NOT EXISTS pgcrypto;` para los UUID.

Pasos de Configuración:
Ejecutar bundle install.

Configurar credenciales maestras localmente usando rails credentials:edit.

Crear y ejecutar el set de migraciones iniciales mediante rails db:create db:migrate.

Levantar de manera concurrente el servidor Puma y los workers en segundo plano utilizando:

Bash
bin/dev