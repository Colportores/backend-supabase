# backend-supabase

Backend del ecosistema Colportaje sobre Supabase: schema, migraciones, RLS, RPCs, Edge Functions y seed. Región **sa-east-1** ([ADR-002](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-002-proveedor-cloud.md)).

**Estado: esquema inicial (Sprint 1)** — migración `0001` con todas las tablas V1 del cloud, RLS habilitada con políticas base, tests pgTAP y CI. Las políticas se refinan HU por HU desde Sprint 3; la infraestructura de sync (RPC de ingesta, `client_op_id`) la agrega `@BrunoFCapri` ([ADR-017](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-017-sync-engine-paquete.md)) — ver [Infraestructura de sincronización](#infraestructura-de-sincronización).

## Contexto

Parte del sistema [Colportaje App](https://github.com/Colportores). El modelo de datos, la arquitectura y las decisiones viven en la [documentación de la organización](https://github.com/Colportores/docs-organizacion) — en particular [`esquema-datos.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/esquema-datos.md) y el [contrato de sync](https://github.com/Colportores/docs-organizacion/blob/main/docs/contrato-sync-engine.md) §2, que fija qué entidades viven acá.

- **La RLS es la autoridad de permisos** de todo el sistema. Los BFF reenvían el JWT del usuario; no deciden nada por su cuenta ([ADR-016](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-016-bff-por-aplicacion.md)).
- La lógica de dominio que toca varias tablas vive en **RPCs de Postgres**, no en los BFF.
- Push FCM vía Edge Functions ([ADR-005](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-005-notificaciones.md)).

## Reglas del esquema

- Todos los IDs son **UUID v7 generados en el cliente** — nunca `SERIAL` ni `AUTOINCREMENT`. `public.uuid_generate_v7()` existe solo para seeds y filas creadas del lado servidor.
- Toda tabla lleva `created_at`, `updated_at`, `created_by`, `deleted_at` (soft delete) y `sync_version`. `updated_at` y `sync_version` los pone el servidor por trigger; `authenticated` no tiene `DELETE`.
- Dinero en **centavos** (`integer`).
- Migraciones **forward-only**: una migración aplicada no se modifica nunca. Nombre `<timestamp>_<nnnn>_<descripcion>.sql`.
- `anon` no tiene privilegios: todo entra por el BFF con el JWT del usuario.

Los tests pgTAP (`supabase/tests/`) verifican estas reglas en cada PR: si una tabla nueva no cumple, CI falla.

## Desarrollo

Todo corre en Docker; no hace falta el CLI de Supabase ni Postgres en el host.

```sh
docker compose -f compose.dev.yml build cli                               # una vez
docker compose -f compose.dev.yml run --rm cli bash scripts/db-migrate.sh # base vacía + migraciones
docker compose -f compose.dev.yml run --rm cli bash scripts/db-test.sh    # pgTAP
docker compose -f compose.dev.yml run --rm cli bash scripts/db-lint.sh    # plpgsql_check
docker compose -f compose.dev.yml run --rm cli bash scripts/db-reset.sh   # borrar y re-aplicar todo
docker compose -f compose.dev.yml run --rm cli psql "$DB_URL"             # consola
docker compose -f compose.dev.yml down -v                                 # apagar (la base no persiste)
```

- `db` es la imagen oficial `supabase/postgres` (mismos roles, schema `auth` y extensiones que producción), expuesta en el host en `localhost:55432` (`DB_PORT=` para cambiarlo).
- `cli` trae Supabase CLI, `psql` y `pg_prove`. El repo se monta en `/work`.
- Nueva migración: `docker compose -f compose.dev.yml run --rm cli supabase migration new <nnnn>_<descripcion>` y luego `db-migrate.sh`.

### Estructura

```
supabase/
├── config.toml        ← config del proyecto (supabase init); project_id = backend-supabase
├── migrations/        ← forward-only
│   └── 20260901000000_0001_esquema_inicial.sql
├── tests/             ← pgTAP: 0001 esquema/privacidad, 0002 RLS
└── functions/         ← Edge Functions Deno (llegan con ADR-005)
scripts/               ← db-migrate / db-test / db-lint / db-reset (los usa CI)

migrations/            ← ⚠ árbol del prototipo, sin reconciliar (ver abajo)
test/, bench/, run-tests.sh
```

## CI/CD

- `ci.yml` (PR y push a `develop`/`staging`/`production`): levanta el mismo `compose.dev.yml`, aplica todas las migraciones sobre una base vacía, corre pgTAP y `supabase db lint`.
- `deploy.yml` (push a `staging`/`production`): `supabase link` + `supabase db push` contra el proyecto del *environment*. Requiere `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID` y `SUPABASE_DB_PASSWORD` como secrets del environment de GitHub.

## Privacidad

Los datos personales de clientes (`persona.nombre`, `persona.apellido`, `persona.telefono`, `nota.texto`) son **local-only**: viven solo en el dispositivo del colportor y nunca llegan al cloud, por la Ley 18.331 de Uruguay. Ver [`02-restricciones.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/02-restricciones.md).

**Este backend no tiene tablas `persona` ni `nota`.** No es una omisión temporal: es la restricción de diseño. Cualquier PR que las agregue debe rechazarse — y `supabase/tests/0001_esquema_inicial_test.sql` lo hace fallar automáticamente. `espacio_persona.persona_id` es un UUID opaco sin FK a propósito.

La regla alcanza también a las **columnas** de texto libre sobre clientes (`notas`, `telefono`, nombres). No están en el esquema y no se agregan.

---

## Infraestructura de sincronización

Lo que §4 del contrato pone de este lado: **RPC de ingesta batch, cache de `client_op_id` (TTL 24 h) y vistas de delta**. El esquema de negocio y las RLS son de Cristian; esto es la maquinaria que mueve los datos.

> **⚠ Estado: sin reconciliar con `supabase/migrations/0001`.** El árbol `migrations/`, `test/`, `bench/` y `run-tests.sh` viene tal cual del monorepo `Prototipo` y todavía **no** está adaptado al esquema de este repo. No lo aplica ni el CI ni el deploy: `supabase db push` solo lee `supabase/migrations/`. Sirve como referencia de lo que funciona hoy de punta a punta mientras se acuerda la reconciliación. Lo pendiente está listado en [`Reconciliación pendiente`](#reconciliación-pendiente).

```bash
./run-tests.sh     # Postgres descartable en Docker, migraciones y tests del prototipo
```

### Qué hay

| Migración | Qué trae |
|---|---|
| `0001_sync_infra` | Schema `sync`, registro de entidades sincronizables, cache de `client_op_id`, purga |
| `0002_sync_push` | `sync.push(usuario, jobs)` — ingesta batch con aceptación por job |
| `0003_sync_pull` | `sync.pull(usuario, entidades, watermark, limite)` — delta |
| `0004_entidades_i1` | `jornada` y `ubicacion`: las entidades del hito I1 |
| `0005_purga_programada` | El TTL del cache, agendado con `pg_cron` |
| `0006_rls` | RLS sobre las tablas sincronizables; `security definer` para el camino del BFF |
| `0007_entidades_v1` | Las 17 entidades de V1, y la distinción entre tabla de un colportor y catálogo global |
| `0008_globales_y_rls` | El delta sin filtro de usuario para catálogos, y RLS para todo lo nuevo |
| `0009_catalogo_demo` | Catálogo mínimo para poder ver el pull funcionando |
| `0010_delta_por_xid` | **El cursor del delta pasa de `updated_at` a xid de transacción** |
| `0011_sync_log` | `C_SYNC_LOG` y `sync.estado()` (tarea 1.4, RF-SY06) |
| `0012_entrega_item` | El detalle de la entrega: qué producto y cuántos. Sin esto no hay RF-ST08 |
| `0013_item_sin_producto` | `pk_producto` deja de ser nullable en los dos detalles |
| `0014_device_id` | El `device_id` del sobre (§5.3) en `sync.log` y en el cache de `client_op_id`: telemetría por dispositivo, no solo por colportor |

Las dos funciones devuelven exactamente la forma del formato de cable del paquete `sync_engine`, así que el BFF traduce poco: valida el JWT, saca el usuario y pasa el cuerpo.

### Decisiones que conviene mirar

**El registro de entidades es una tabla, no una lista en el código.** El RPC es genérico; sin lista blanca, un cliente podría mandar `entity: "usuario"` y escribir donde no debe. Es el espejo en SQL del `SyncSpec` del motor: si una entidad no está registrada, no entra.

**Las columnas server-authoritative se descartan del payload en silencio** (§5.4). Un test verifica que un cliente que manda `sync_version: 99` y un usuario ajeno no consigue ninguna de las dos cosas: no puede saltearse el LWW ni regalarle su jornada a otro usuario.

**Un rechazo no entra al cache de `client_op_id`.** El job nunca tocó la base, así que no hay nada que deduplicar; si el colportor corrige el dato y reencola, tiene que volver a validarse contra el estado nuevo y no contra la respuesta vieja.

**El cache gana sobre cualquier validación.** Un op ya aplicado vuelve `duplicate` sin re-validarse. Al revés, un job aplicado cuya respuesta se perdió y que en el reintento cae en una validación quedaría `INVALID` con la fila ya escrita: el colportor vería en la cola de error una venta que ya cobró. Es el mismo orden que el fake del motor, y por la misma razón.

**El `UPDATE` lleva la versión en el `WHERE`, no solo en un `if` previo.** Entre leer la fila y escribirla hay una ventana: en READ COMMITTED otra transacción puede bumpearla justo ahí, y el `UPDATE` quedaría esperando el lock para después re-leer y escribir igual, pisando el cambio ajeno y devolviendo `accepted`. Es la actualización perdida clásica. Con la versión en el `WHERE` es un compare-and-swap: o aplica sobre la versión que el cliente esperaba, o se reporta como conflicto. Hay un test con **dos conexiones concurrentes** que lo verifica, y que sin el arreglo falla.

**Un job con el payload roto no puede tumbar el lote.** Cada job se aplica en una subtransacción (el bloque `exception` de PL/pgSQL). Una fecha que no es fecha o una FK que no existe queda `invalid` con su SQLSTATE, y el resto del lote entra. Sin eso, un solo job venenoso hace fallar el push entero, el motor lo clasifica como `5xx` transitorio y lo reintenta para siempre: **la cola del colportor queda bloqueada y ninguna venta vuelve a subir**. Lo que no se atrapa —deadlock, conexión caída, falta de memoria— sube y sale como `500`, que ahí sí hay que reintentar.

**Los decimales viajan como texto.** `to_jsonb(fila)` convierte un `numeric(10,2)` en número JSON: `42.50` sale como `42.5` y del otro lado `jsonDecode` lo parsea como `double`. La conversión se hace en SQL y no en el BFF porque acá todavía se sabe el tipo de cada columna: una vez que la fila es `jsonb`, esa información se perdió.

**El cursor del delta es el xid de la transacción, no el reloj.** Esta decisión reemplaza a la anterior, que era `(updated_at, id)` y **perdía filas**.

`updated_at` se llena con `now()`, que en Postgres es la hora de *inicio* de la transacción. Dos escritores concurrentes commitean en un orden que no tiene por qué coincidir con el de sus timestamps:

    A: begin (15:43) ── insert ────────────────────── commit (15:45)
    B:            begin (15:44) ── insert ── commit (15:44)
    pull:                                  ↑ acá: ve solo B, watermark = 15:44

Cuando A commitea, su fila entra con `updated_at` 15:43, **detrás** de un watermark que ya avanzó. El delta no la vuelve a mirar nunca: subida, guardada, y jamás entregada. El par `(updated_at, id)` no lo salvaba — desempata timestamps iguales, que es otro problema.

El arreglo (`0010`) ordena por `(xmin_w, id)` y sirve solo lo que está por debajo de `pg_snapshot_xmin(pg_current_snapshot())`. Toda transacción que todavía pueda commitear tiene xid ≥ ese horizonte, así que cualquier fila futura entra por delante de todo lo ya entregado. La fila de A no se saltea: espera y sale en el pull siguiente.

Está reproducido con dos conexiones en [`test/concurrencia.sh`](test/concurrencia.sh), que falla contra el esquema anterior y pasa contra este.

**El watermark es por entidad**, para que una colección no arrastre a la otra, y es opaco para el cliente: el cambio de `{ts, id}` a `{xid, id}` no tocó una línea del BFF ni de la app.

**Una entidad que el cliente pide y el servidor no conoce se ignora en el pull.** Un cliente más nuevo que el backend no puede tumbar la sync de los demás.

### Los dos caminos a los datos

Es la decisión de seguridad más importante de esta parte, y sale de §6: **el batch va por el BFF, pero Realtime va directo a Supabase**.

| Camino | Quién filtra |
|---|---|
| App → BFF → `sync.push` / `sync.pull` | Las funciones, por el usuario que el BFF sacó del JWT verificado |
| App → Supabase Realtime → tabla | **La RLS, y nada más** |

Por el segundo camino no corre `sync.pull`, así que el filtrado manual no protege nada. Verificado antes de escribir las políticas: un rol `authenticated` cualquiera veía las jornadas de **todos** los colportores. Una suscripción de Realtime le habría dado a cualquiera los cambios de cualquiera.

`0006_rls.sql` cierra eso. Es de solo lectura y solo lo propio: escribir por el camino directo no está permitido a propósito, porque §2 dice que la app nunca escribe las tablas del cloud —*stagea* y el motor sube— y una escritura directa se saltearía la idempotencia, el LWW y el descarte de columnas server-authoritative.

Para que el camino del BFF siga funcionando, `sync.push` y `sync.pull` pasan a `security definer` con el `search_path` fijo. Lo segundo no es opcional: sin él, quien llama a la función puede anteponer un schema propio y hacer que `jornada` resuelva a una tabla suya, ejecutando código con los privilegios del dueño.

Hay un test que recorre `sync.entidad` y falla si alguna tabla registrada para sync quedó sin RLS: agregar una entidad al registro y olvidarse de las políticas tiene que romper el CI, no filtrar datos.

> **Reparto (§4)**: las RLS son de Cristian. Están en `0006`/`0008` porque el motivo es de la arquitectura de sync; se mueven con el resto del esquema en la reconciliación. Nótese que `supabase/migrations/0001` ya trae RLS para las 24 tablas V1, así que esa parte se resuelve borrándola de acá, no fusionándola.

### Rendimiento, medido

`./bench/correr.sh` carga 420.000 filas —150 colportores, una temporada— y mide. Con eso:

| | |
|---|---|
| Página del delta (500 de 300.000 filas) | **20 ms**, Index Only Scan |
| Pull completo de una página | 31 ms |
| Pull incremental sin novedades | 1 ms |
| Push de un lote de 500 jobs | **430 ms** (0,86 ms por job) |

RR-02 pide lotes de 100 registros en menos de 30 s: hay tres órdenes de magnitud de margen. El índice `(usuario, xmin_w, id)` es el que usa la comparación de fila del delta, y el corte por horizonte entra en el mismo `Index Cond`, así que el plan es un Index Only Scan y no un Seq Scan por más que crezca la tabla.

Los 60 ms que subió el push de 500 jobs contra la medición anterior son el conteo de resultados y la línea de `sync.log` que agregó `0011`: 0,12 ms por job para tener la telemetría que la Fase 3 necesita.

**Lo que sí encontró la medición**: el cache de `client_op_id` no lo purgaba nadie. La función existía desde `0001` y el TTL de 24 h estaba documentado, pero sin nada que la llamara el cache pasa de **5 MB en régimen a 945 MB en una temporada**. Y no es solo disco: buscar el `client_op_id` es lo primero que hace cada job de cada push, así que el índice degradado se paga en cada sincronización. `0005` la agenda con `pg_cron`, que Supabase trae; si no está disponible avisa con un `warning` y no frena el despliegue.

### Telemetría: `sync.log` y `sync.estado()`

`0011` cierra la tarea 1.4 del plan (RF-SY06) y deja puesto lo que la Fase 3 necesita para medir el piloto: bytes por ciclo, duración y tasa de rechazo, por colportor.

```sql
select sync.estado('…uuid del colportor…');
```

`sync.log` guarda solo UUIDs, contadores y bytes — nada de PII, como pide `convenciones-desarrollo.md §7`.

**Un pull sin novedades no escribe nada, y eso es deliberado.** Es el latido más común de todos —1 ms, sin filas— y loguearlo lo convertiría en una escritura. Eso cuesta WAL y vacuum por cada latido de cada colportor, pero sobre todo **cada pull tomaría un xid y con eso frenaría el horizonte del delta de todos los demás** mientras dura. Con 200 usuarios sincronizando seguido, el horizonte casi no avanzaría. Así que se registra solo el ciclo que entregó filas, que es además el único que aporta algo a RR-07.

**La purga se agenda en la misma migración que crea la tabla**, y no dos migraciones después: es la lección de `0005`, donde un TTL documentado y no ejecutado dejó crecer el cache hasta los 945 MB.

**Lo que `sync.estado()` no contesta es la cola de pendientes.** Vive en el dispositivo (`engine.errorQueue()`), y el servidor no la conoce: un job que nunca llegó no dejó rastro acá. Devolver un `pendientes: 0` sacado de esta tabla sería mentirle al colportor sobre lo único que le importa.

### Una nota sobre los tests

Dos cosas que salieron de arreglar el delta y que valen para cualquiera que escriba tests acá:

**El `assert` compara con `is not true`, no con `not`.** Con `not p_cond` y `p_cond` NULL, el `if` no entra y el test pasa en verde. Y NULL es justo lo que devuelve una comparación contra un campo que no vino: `jsonb_array_length(NULL) = 2` da NULL, no `false`. La versión ingenua dejaba pasar exactamente los fallos que estos archivos existen para encontrar — con el delta roto, tres asserts del pull seguían diciendo OK.

**`sync_test.sql` ya no envuelve todo en una transacción.** Cada `do $$` es la suya, como en producción, donde el push y el pull son dos requests HTTP distintos. Con todo en una sola transacción el delta no puede entregar lo que esa misma transacción acaba de escribir —correctamente— y el archivo entero probaba una configuración que no existe. A cambio, el archivo deja sus filas puestas: espera una base recién creada, que es lo que `run-tests.sh` da.

### Reconciliación pendiente

Lo que hay que resolver antes de que este árbol pueda entrar a `supabase/migrations/`:

1. **Numeración.** Acá el `0001` es `sync_infra`; en `supabase/migrations/` el `0001` es `esquema_inicial`. La infra de sync arranca en `0002`.
2. **Layout.** El repo usa `supabase/migrations/<timestamp>_<nnnn>_...` y `supabase/tests/` con pgTAP; esto viene con `migrations/` y `test/` en la raíz y su propio `run-tests.sh`.
3. **Naming de columnas.** Los RPC asumen el naming del prototipo (`pk_usuario`, `deleted boolean`, `sync_version int default 1`). En `0001_esquema_inicial` las mismas tablas son `colportor_id` / `created_by`, `deleted_at timestamptz` y `sync_version bigint default 0` por trigger. El SQL dinámico de `sync.push`/`sync.pull` no funciona contra ese esquema sin tocarlo.
4. **Tablas duplicadas.** `0004`, `0006`, `0007`, `0009`, `0012` y `0013` crean tablas de negocio y RLS que `0001_esquema_inicial` ya cubre. Por ADR-017 esas son del esquema de negocio, no de la infra de sync.
5. **Privilegios.** Ninguna de las funciones del schema `sync` tiene un `grant execute` para el rol con el que se conecta el BFF, y `sync.aplicar_job`/`sync.aplicar_job_interno` quedaron `security definer` sin el `revoke` que sí recibieron `push` y `pull`.
6. **`search_path` de las `security definer`.** Están con `sync, public, pg_temp`; la convención del repo (y la skill `supabase-postgres-best-practices`) es `set search_path = ''` con todo calificado.

## Licencia

Uso propio — todos los derechos reservados. Ver [LICENSE](./LICENSE).
