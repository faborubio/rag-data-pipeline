# 🛠️ Troubleshooting & lecciones aprendidas

Bitácora de incidentes reales del proyecto y su solución, para no volver a perder
tiempo en el mismo muro. Cada entrada sigue el mismo formato: **síntoma → causa →
solución → prevención**. Al resolver algo no obvio, añade una entrada nueva.

Índice:
- [CI](#ci) — fallos del pipeline ajenos a tu código
- [Base de datos / búsqueda](#base-de-datos--búsqueda)
- [Despliegue](#despliegue)
- [Entorno de desarrollo](#entorno-de-desarrollo)

---

## CI

### CI falla en `scan_ruby` sin que tú tocaras nada de seguridad

Los fallos de CI **no siempre son por tu commit**. El job `scan_ruby` corre dos
herramientas que dependen del *calendario externo*, no de tu código, así que un
push que no toca nada relevante puede ponerse rojo de un día para otro.

#### a) Brakeman: `--ensure-latest` se rompe al salir una versión nueva

- **Síntoma:** el paso *"Scan for common Rails security vulnerabilities"* falla con
  exit 5 y **sin reportar ningún warning**. En local, `bin/brakeman` imprime solo
  `Brakeman X is not the latest version Y` y termina.
- **Causa:** el binstub `bin/brakeman` añade `--ensure-latest`, que hace fallar el
  scan si la gema no es la última publicada en RubyGems. Cuando el equipo de
  Brakeman publica una versión nueva, tu lock queda atrás y CI se cae — aunque no
  haya ninguna vulnerabilidad.
- **Solución:** subir la gema en el lock (no hace falta instalarla en local):
  ```bash
  bundle lock --update brakeman
  ```
- **Prevención:** para confirmar que es esto y no un warning real, corre el scan
  **sin** la bandera: `bundle exec brakeman --no-pager` → si dice
  `No warnings found` / exit 0, era solo la versión. *(Decisión pendiente: quitar
  `--ensure-latest` del binstub desacopla el CI del calendario de releases de
  Brakeman, a cambio de no avisarte de versiones nuevas.)*

#### b) bundler-audit: CVE publicado contra una gema (a veces transitiva)

- **Síntoma:** el paso *"Scan for known security vulnerabilities in gems used"*
  falla; `bundler-audit` lista uno o más `CVE-...` con `Vulnerabilities found!`.
- **Causa:** la base de advisories (`ruby-advisory-db`) se actualiza a diario. Un
  CVE recién publicado contra **cualquier** gema del `Gemfile.lock` —incluida una
  dependencia transitiva que ni declaraste, p. ej. `net-imap` vía Action Mailer—
  pone el gate en rojo. Ocurrió el 2026-06-14 con `net-imap 0.6.4`
  (CVE-2026-47240/47241/47242).
- **Solución:** subir la gema parcheada en el lock (lee la línea `Solution:` del
  reporte para la versión mínima):
  ```bash
  bundle lock --update net-imap
  ```
- **Prevención:** correr el audit en local **sin** cargar la app (el binstub
  `bin/bundler-audit` carga Rails y puede fallar por otras razones). Si el gem dir
  del sistema no es escribible, usa un `GEM_HOME` temporal:
  ```bash
  GEM_HOME=/tmp/ba gem install bundler-audit --no-document
  GEM_HOME=/tmp/ba /tmp/ba/bin/bundle-audit check --update
  ```

> **Regla general:** cuando CI falle, mira **qué job** falló antes de asumir que es
> tu cambio. `test` y `lint` verdes + `scan_ruby` rojo casi siempre = evento
> externo (versión nueva o CVE), no tu PR.

---

## Base de datos / búsqueda

### Full-text search devuelve 0 resultados para preguntas en lenguaje natural

- **Síntoma:** el scope FTS no matchea nada en preguntas normales; los evals dan
  métricas planas e idénticas a solo-vector (señal de que la rama léxica aporta 0).
  Diagnóstico rápido: `fts_total=0` para casi todas las consultas.
- **Causa:** `websearch_to_tsquery` / `plainto_tsquery` combinan los términos con
  **AND** por defecto. Una pregunta como *"¿Puedo usar el elevador si hay fuego?"*
  exige que **todos** los términos estén en el chunk → casi nunca matchea.
- **Solución:** semántica **OR** rankeada por `ts_rank`. Se construye de forma
  segura reescribiendo la salida de `plainto_tsquery` (ver
  [`DocumentChunk.full_text_search`](app/models/document_chunk.rb)):
  ```sql
  replace(plainto_tsquery('spanish', immutable_unaccent(?))::text, '&', '|')::tsquery
  ```
- **Prevención:** al añadir un retriever, **medir su recall por separado** (no solo
  el agregado): si una señal aporta 0, el agregado no se mueve y el bug pasa
  desapercibido. Los evals (`bin/rails rag:evals`) existen justo para esto.

### `unaccent()` no se puede usar en un índice de expresión

- **Síntoma:** `CREATE INDEX ... unaccent(content)` falla con
  *"functions in index expression must be marked IMMUTABLE"*.
- **Causa:** `unaccent()` no es IMMUTABLE porque su diccionario es configurable.
- **Solución:** wrapper IMMUTABLE fijado al diccionario `public.unaccent` (ver la
  migración FTS). Tanto el índice GIN como el scope deben llamar a la **misma**
  función (`immutable_unaccent`) para que el índice se use.
- **Prevención:** cualquier función dentro de un índice de expresión debe ser
  IMMUTABLE; si no lo es, envuélvela.

---

## Despliegue

### Cambios al `Caddyfile` no se aplican aunque `caddy reload` diga "ok"

Documentado en detalle en **[DEPLOY.md](DEPLOY.md)** (gotcha del bind mount de
archivo único: al sincronizar con `tar`/`mv` cambia el inode y el contenedor sigue
leyendo la config vieja). **Solución:** `docker compose ... up -d --force-recreate
caddy`. Se incluye aquí solo como índice; el procedimiento completo está en
DEPLOY.md.

### Una migración nueva no llega a la VPS en el deploy

- **Síntoma:** desplegaste código que añade una migración, pero producción sigue
  con el esquema viejo.
- **Causa/Solución:** el `bin/docker-entrypoint` corre `db:prepare` al arrancar el
  server, así que el redeploy estándar (build + `up -d web`) aplica las migraciones
  solo. Verifica con los pasos de DEPLOY.md tras el deploy.

---

## Entorno de desarrollo

### `pdftotext -layout` recorta silenciosamente el texto largo

- **Síntoma:** chunks ingeridos truncados (p. ej. a ~88 chars); las keywords
  esperadas "desaparecen" aunque estén en el PDF original.
- **Causa:** una línea de texto que se sale del ancho de la `MediaBox` es
  **clipeada** por `pdftotext -layout`, sin error.
- **Solución:** envolver el texto en líneas cortas al generar el PDF (ver
  [`Rag::Evals::PdfBuilder`](app/services/rag/evals/pdf_builder.rb), método
  `text_stream`).
- **Prevención:** al generar PDFs de prueba, no metas párrafos largos en un solo
  `Tj`; o valida que `pdftotext` devuelve el texto completo tras ingerir.

### La salida de comandos `rails` en dev es ilegible (spam de OpenTelemetry)

- **Síntoma:** `bin/rails db:migrate`, `runner`, `routes`, etc. escupen objetos
  `OpenTelemetry::Trace::Span...` por stdout y tapan el output útil.
- **Causa:** en `development` el inicializador de OTel usa el *console exporter*,
  que imprime cada span a stdout.
- **Solución:** para inspeccionar el resultado real, filtra
  (`... 2>&1 | grep -vE "^I, |Instrumentation"`) o verifica el efecto de otra forma
  (p. ej. `db/structure.sql` tras una migración en vez de leer el log de
  `db:migrate`).
- **Prevención:** no te fíes del exit/output ruidoso; confirma el efecto en la
  fuente de verdad (schema, BD, archivo generado).

### `bundle install` / `gem install` falla por permisos del gem dir del sistema

- **Síntoma:** `Bundler::PermissionError` / `Gem::FilePermissionError` al escribir
  en `/usr/local/rbenv/.../gems`.
- **Causa:** el directorio de gemas del sistema es de `root`; tu usuario no puede
  escribir ahí.
- **Solución según el caso:**
  - **Solo cambiar el lock** (subir una gema para CI): `bundle lock --update <gema>`
    — no instala nada en local, y CI instala fresco. Es lo que usamos para
    `brakeman` y `net-imap`.
  - **Necesitas la herramienta en local:** instálala en un `GEM_HOME` temporal
    (`GEM_HOME=/tmp/x gem install <gema>`), o instala con privilegios y reajusta el
    dueño (`sudo ... && sudo chown -R $USER ...`).
- **Prevención:** para fixes de CI, prefiere siempre `bundle lock --update`: es más
  rápido y no toca tu entorno.
