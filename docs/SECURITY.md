# 🔐 SECURITY — postura y modelo de amenazas

> ¿De qué me protejo y cómo? — **proporcional** (Método §1) a lo que es: una API RAG multi-tenant
> con demo pública de solo-lectura, en un VPS. No es banca; sí maneja secretos por tenant y una
> superficie de subida/consulta pública. Lo que **no** cubro está explícito al final (aceptado, con su `AUD`).

## Postura

- **API-only**, sin cookies ni sesiones (no hay CSRF que gestionar).
- **Multi-tenant lógico**: aislamiento por `tenant_id` en cada consulta, no por base separada.
- **Demo pública read-only**: un tenant marcado `read_only` sirve el corpus curado; nadie anónimo escribe.
- **Sin registro abierto**: 2 cuentas fijas por `db:seed` (admin cura, visitante lee).

## Activos a proteger

| Activo | Protección |
|---|---|
| **API keys** (de `Tenant` y de `User`) | Cifradas en reposo (**Lockbox** → `*_ciphertext`) + búsqueda por **blind index** (constant-time) |
| **Corpus por tenant** | Todo retrieval scopeado por `tenant_id` (`DocumentChunk.for_tenant`) |
| **Contraseñas** | `has_secure_password` (bcrypt), mínimo 8 chars |
| **Secretos de infra** (`RAILS_MASTER_KEY`, `METRICS_TOKEN`, passwords) | En `~/.env` del VPS, **no** versionado |

## Autenticación y autorización

- **Auth por API key** (`Authorization: Bearer` o `X-Api-Key`) resuelta en tiempo constante vía blind index.
  Una key de usuario → `Current.user` (+ rol + tenant); una key de tenant → path anónimo/público.
- **Autorización de escritura por ROL, no por key**: el gate de subida es `Current.user&.admin?` — admin y
  visitante comparten un tenant pero solo admin sube. Ver [`documents_controller.rb`](../app/controllers/api/v1/documents_controller.rb).
- **Aislamiento de tenant**: verificado por una **suite adversarial dedicada**
  ([`tenant_isolation_test.rb`](../test/integration/api/v1/tenant_isolation_test.rb)): un tenant atacante
  autenticado sondea cada endpoint con ids de la víctima (cuyo corpus lleva un canario). Cubre: leer un
  documento ajeno por id (404), mezclar ids propios y ajenos en una consulta (solo cita lo propio), inferir
  el estado de indexación de un doc ajeno (no revela `processing`), cruzar la **caché de respuestas** con la
  misma pregunta+ids (la clave incluye `tenant_id`), bloquear la subida de otro con un backlog de ingesta
  propio, e inflar la cuota ajena. Más los checks por endpoint en sus propios tests (feedback, analytics,
  listado de documentos).

## Superficie de entrada y defensas

**Subida de documentos** ([`documents_controller.rb`](../app/controllers/api/v1/documents_controller.rb))
- Validación por **magic bytes** (`%PDF-`), no solo extensión → un no-PDF renombrado se rechaza.
- Tope de tamaño (`MAX_UPLOAD_MB`, def 160) + **Caddy rechaza >170MB en el edge** (antes de tocar disco).
- **Cuota por tenant** (`STORAGE_BUDGET_MB`) re-chequeada bajo `tenant.with_lock` → sin TOCTOU.
- **Cap de ingestas en vuelo** (`MAX_INFLIGHT_INGESTIONS`) → un flood de PDFs-bomba no monopoliza el worker.
- **Timeout** en `pdftotext` (SIGKILL) + limpieza del temp también en fallo → sin cuelgues ni fuga de disco.

**Consulta** ([`chats_controller.rb`](../app/controllers/api/v1/chats_controller.rb))
- Cap de cardinalidad de `document_ids` (`MAX_QUERY_DOCUMENT_IDS`) y de largo de pregunta (`MAX_QUESTION_LENGTH`)
  → sin `IN (...)` patológico ni cargas desmedidas de embed/rerank.
- **Abstención como safety** (Método/CASES): si nada del corpus es relevante, responde "no encontré…" en vez de
  inventar; **fail-fast en boot** si el reranker activo no gatea ([`retrieval_guard.rb`](../config/initializers/retrieval_guard.rb)).

**Rate limiting** ([`rack_attack.rb`](../config/initializers/rack_attack.rb))
- Per-key (hash, nunca se guarda la key) para tráfico autenticado.
- Per-IP para `/api/` **sin** key → frena fuerza bruta de keys.
- Per-IP más estricto en `login`, con mensaje genérico (**no enumera** si el email existe).

**Observabilidad**
- `/metrics` **fail-closed en producción** (401 sin `METRICS_TOKEN` válido) **y** 403 en el edge (Caddy) —
  defensa en profundidad. Ver [`metrics_controller.rb`](../app/controllers/metrics_controller.rb) y [DEPLOY](DEPLOY.md).

**Transporte / headers** (Caddy)
- HTTPS automático (Let's Encrypt) + **HSTS**, `X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`.

**Privacidad**
- `QueryLog` con **retención** (`QUERY_LOG_RETENTION_DAYS`), truncado y **redacción opcional** del texto de la
  pregunta (`QUERY_LOG_STORE_QUESTION=0`). Ver [`query_log.rb`](../app/models/query_log.rb).

## Postura a escala productiva (qué se activaría y cuándo)

Ejercicio de proporcionalidad (Método §1) en la otra dirección: si esto fuera un SaaS con usuarios
reales pagando, qué controles de la caja de herramientas clásica (ISO/OWASP/NIST…) se activarían y en
qué orden. Es una **declaración de aplicabilidad** informal: lo que hoy no está, no está por juicio,
no por omisión.

**Tier 1 — día 1 de producción real (datos de clientes):**
- **IAM completo**: registro + verificación de email, reset de contraseña, MFA para admins, rotación y
  revocación de API keys, audit log de acciones admin. (Hoy: 2 cuentas seed, suficiente para la demo.)
- **Tests adversariales de aislamiento**: ✅ **ya implementados** (ver arriba) — el riesgo #1 de un
  multi-tenant es un bug de scoping, no un atacante externo, así que se adelantó a hoy.
- **Backups + DRP probado**: dump automatizado de Postgres + un drill de restauración documentado.
  (Hoy: el corpus demo es re-ingestable; no hay datos irrecuperables.)
- **Gestión de vulnerabilidades continua**: `brakeman`/`bundler-audit` en CI + Dependabot + triage CVSS.
- **Cifrado un paso más**: at-rest de los PDFs subidos, secrets en un manager (no `.env` plano),
  retención/borrado por tenant al cerrar cuenta.

**Tier 2 — con tracción (decenas de tenants activos):**
- **Alerting** sobre lo que ya se emite (logs JSON + Prometheus): picos de logins fallidos, abuso por
  tenant, error rate del write path. El "SIEM proporcional".
- **Gestión de incidentes formal**: severidades, comunicación a clientes, postmortem con timeline.
- **Pentest / assessment OWASP externo** (Top 10 web + **Top 10 LLM**) antes del primer cliente pagando.
- **Hardening del cloud** (GCP): firewall VPC mínimo, service accounts de mínimo privilegio, parcheo del OS.

**Tier 3 — solo si un contrato lo exige:**
- ISO 27001 / COBIT / SOAR / ITIL / ISO 22301 completo. Su costo es enorme y su valor es contractual,
  no técnico; certificarse "por si acaso" es deuda, no virtud. MITRE ATT&CK puede llegar antes como
  *vocabulario* del modelo de amenazas, no como framework operativo.

## Fuera de alcance (aceptado a propósito)

Cada uno tiene o merece su `AUD` en [AUDIT](AUDIT.md):
- **Prompt injection desde el contenido del PDF** → nulo hoy (respuesta extractiva, sin LLM generativo);
  **crítico al activar la generación** (`AUD-006` / `AUD-004`).
- **Tokens sin expiración/rotación** — la API key vive en `localStorage` de la demo; robable por XSS. Aceptable
  para una demo; un despliegue serio querría sesiones de corta vida.
- **Sin verificación de email**, sin MFA, sin WAF — desproporcionado para la escala actual.
- **La abstención se apaga si el modelo del reranker no carga** (`AUD-003`).

## Cómo reportar

Es un proyecto de portafolio. Si encontrás algo, abrí un issue en el repo (sin exploit público para
vulnerabilidades sensibles — contacto directo primero).
