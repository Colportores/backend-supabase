# backend-supabase — infraestructura de sincronización

Lo que §4 del contrato pone de este lado: **RPC de ingesta batch, cache de
`client_op_id` (TTL 24 h) y vistas de delta**. El esquema de negocio y las RLS
son de Cristian; esto es la maquinaria que mueve los datos.

```bash
./run-tests.sh     # Postgres descartable en Docker, migraciones y tests
```

## Qué hay

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

Las dos funciones devuelven exactamente la forma del
[formato de cable](../prototipo-sync/app/packages/sync_engine/docs/formato-de-cable.md),
así que el BFF traduce poco: valida el JWT, saca el `pk_usuario` y pasa el
cuerpo.

## Decisiones que conviene mirar

**El registro de entidades es una tabla, no una lista en el código.** El RPC es
genérico; sin lista blanca, un cliente podría mandar `entity: "usuario"` y
escribir donde no debe. Es el espejo en SQL del `SyncSpec` del motor: si una
entidad no está registrada, no entra.

**Las columnas server-authoritative se descartan del payload en silencio**
(§5.4). Un test verifica que un cliente que manda `sync_version: 99` y
`pk_usuario` de otro no consigue ninguna de las dos cosas: no puede saltearse el
LWW ni regalarle su jornada a otro usuario.

**Un rechazo no entra al cache de `client_op_id`.** El job nunca tocó la base,
así que no hay nada que deduplicar; si el colportor corrige el dato y reencola,
tiene que volver a validarse contra el estado nuevo y no contra la respuesta
vieja.

**El cache gana sobre cualquier validación.** Un op ya aplicado vuelve
`duplicate` sin re-validarse. Al revés, un job aplicado cuya respuesta se perdió
y que en el reintento cae en una validación quedaría `INVALID` con la fila ya
escrita: el colportor vería en la cola de error una venta que ya cobró. Es el
mismo orden que el fake del motor, y por la misma razón.

**El `UPDATE` lleva la versión en el `WHERE`, no solo en un `if` previo.** Entre
leer la fila y escribirla hay una ventana: en READ COMMITTED otra transacción
puede bumpearla justo ahí, y el `UPDATE` quedaría esperando el lock para después
re-leer y escribir igual, pisando el cambio ajeno y devolviendo `accepted`. Es
la actualización perdida clásica. Con la versión en el `WHERE` es un
compare-and-swap: o aplica sobre la versión que el cliente esperaba, o se
reporta como conflicto. Hay un test con **dos conexiones concurrentes** que lo
verifica, y que sin el arreglo falla.

**Un job con el payload roto no puede tumbar el lote.** Cada job se aplica en
una subtransacción (el bloque `exception` de PL/pgSQL). Una fecha que no es
fecha o una FK que no existe queda `invalid` con su SQLSTATE, y el resto del
lote entra. Sin eso, un solo job venenoso hace fallar el push entero, el motor
lo clasifica como `5xx` transitorio y lo reintenta para siempre: **la cola del
colportor queda bloqueada y ninguna venta vuelve a subir**. Lo que no se atrapa
—deadlock, conexión caída, falta de memoria— sube y sale como `500`, que ahí sí
hay que reintentar.

**Los decimales viajan como texto.** `to_jsonb(fila)` convierte un
`numeric(10,2)` en número JSON: `42.50` sale como `42.5` y del otro lado
`jsonDecode` lo parsea como `double`. La conversión se hace en SQL y no en el
BFF porque acá todavía se sabe el tipo de cada columna: una vez que la fila es
`jsonb`, esa información se perdió.

**El cursor del delta es el xid de la transacción, no el reloj.** Esta decisión
reemplaza a la anterior, que era `(updated_at, id)` y **perdía filas**.

`updated_at` se llena con `now()`, que en Postgres es la hora de *inicio* de la
transacción. Dos escritores concurrentes commitean en un orden que no tiene por
qué coincidir con el de sus timestamps:

    A: begin (15:43) ── insert ────────────────────── commit (15:45)
    B:            begin (15:44) ── insert ── commit (15:44)
    pull:                                  ↑ acá: ve solo B, watermark = 15:44

Cuando A commitea, su fila entra con `updated_at` 15:43, **detrás** de un
watermark que ya avanzó. El delta no la vuelve a mirar nunca: subida, guardada,
y jamás entregada. El par `(updated_at, id)` no lo salvaba — desempata
timestamps iguales, que es otro problema.

El arreglo (`0010`) ordena por `(xmin_w, id)` y sirve solo lo que está por
debajo de `pg_snapshot_xmin(pg_current_snapshot())`. Toda transacción que
todavía pueda commitear tiene xid ≥ ese horizonte, así que cualquier fila futura
entra por delante de todo lo ya entregado. La fila de A no se saltea: espera y
sale en el pull siguiente.

Está reproducido con dos conexiones en [`test/concurrencia.sh`](test/concurrencia.sh),
que falla contra el esquema anterior y pasa contra este.

**El watermark es por entidad**, para que una colección no arrastre a la otra, y
es opaco para el cliente: el cambio de `{ts, id}` a `{xid, id}` no tocó una
línea del BFF ni de la app.

**Una entidad que el cliente pide y el servidor no conoce se ignora en el pull.**
Un cliente más nuevo que el backend no puede tumbar la sync de los demás.

## Los dos caminos a los datos

Es la decisión de seguridad más importante de este repo, y sale de §6: **el
batch va por el BFF, pero Realtime va directo a Supabase**.

| Camino | Quién filtra |
|---|---|
| App → BFF → `sync.push` / `sync.pull` | Las funciones, por el `pk_usuario` que el BFF sacó del JWT verificado |
| App → Supabase Realtime → tabla | **La RLS, y nada más** |

Por el segundo camino no corre `sync.pull`, así que el filtrado manual no
protege nada. Verificado antes de escribir las políticas: un rol `authenticated`
cualquiera veía las jornadas de **todos** los colportores. Una suscripción de
Realtime le habría dado a cualquiera los cambios de cualquiera.

`0006_rls.sql` cierra eso. Es de solo lectura y solo lo propio: escribir por el
camino directo no está permitido a propósito, porque §2 dice que la app nunca
escribe las tablas del cloud —*stagea* y el motor sube— y una escritura directa
se saltearía la idempotencia, el LWW y el descarte de columnas
server-authoritative.

Para que el camino del BFF siga funcionando, `sync.push` y `sync.pull` pasan a
`security definer` con el `search_path` fijo. Lo segundo no es opcional: sin él,
quien llama a la función puede anteponer un schema propio y hacer que `jornada`
resuelva a una tabla suya, ejecutando código con los privilegios del dueño.

Hay un test que recorre `sync.entidad` y falla si alguna tabla registrada para
sync quedó sin RLS: agregar una entidad al registro y olvidarse de las políticas
tiene que romper el CI, no filtrar datos.

> **Reparto (§4)**: las RLS son de Cristian. Están acá porque el motivo es de la
> arquitectura de sync; movelas con el resto del esquema si preferís.

## Rendimiento, medido

`./bench/correr.sh` carga 420.000 filas —150 colportores, una temporada— y mide.
Con eso:

| | |
|---|---|
| Página del delta (500 de 300.000 filas) | **20 ms**, Index Only Scan |
| Pull completo de una página | 31 ms |
| Pull incremental sin novedades | 1 ms |
| Push de un lote de 500 jobs | **430 ms** (0,86 ms por job) |

RR-02 pide lotes de 100 registros en menos de 30 s: hay tres órdenes de
magnitud de margen. El índice `(pk_usuario, xmin_w, id)` es el que usa la
comparación de fila del delta, y el corte por horizonte entra en el mismo
`Index Cond`, así que el plan es un Index Only Scan y no un Seq Scan por más
que crezca la tabla.

Los 60 ms que subió el push de 500 jobs contra la medición anterior son el
conteo de resultados y la línea de `sync.log` que agregó `0011`: 0,12 ms por
job para tener la telemetría que la Fase 3 necesita.

**Lo que sí encontró la medición**: el cache de `client_op_id` no lo purgaba
nadie. La función existía desde `0001` y el TTL de 24 h estaba documentado, pero
sin nada que la llamara el cache pasa de **5 MB en régimen a 945 MB en una
temporada**. Y no es solo disco: buscar el `client_op_id` es lo primero que hace
cada job de cada push, así que el índice degradado se paga en cada
sincronización. `0005` la agenda con `pg_cron`, que Supabase trae; si no está
disponible avisa con un `warning` y no frena el despliegue.

## Telemetría: `sync.log` y `sync.estado()`

`0011` cierra la tarea 1.4 del plan (RF-SY06) y deja puesto lo que la Fase 3
necesita para medir el piloto: bytes por ciclo, duración y tasa de rechazo, por
colportor.

```sql
select sync.estado('…uuid del colportor…');
```

**Un pull sin novedades no escribe nada, y eso es deliberado.** Es el latido más
común de todos —1 ms, sin filas— y loguearlo lo convertiría en una escritura.
Eso cuesta WAL y vacuum por cada latido de cada colportor, pero sobre todo
**cada pull tomaría un xid y con eso frenaría el horizonte del delta de todos
los demás** mientras dura. Con 200 usuarios sincronizando seguido, el horizonte
casi no avanzaría. Así que se registra solo el ciclo que entregó filas, que es
además el único que aporta algo a RR-07.

**La purga se agenda en la misma migración que crea la tabla**, y no dos
migraciones después: es la lección de `0005`, donde un TTL documentado y no
ejecutado dejó crecer el cache hasta los 945 MB.

**Lo que `sync.estado()` no contesta es la cola de pendientes.** Vive en el
dispositivo (`engine.errorQueue()`), y el servidor no la conoce: un job que
nunca llegó no dejó rastro acá. Devolver un `pendientes: 0` sacado de esta tabla
sería mentirle al colportor sobre lo único que le importa.

## Una nota sobre los tests

Dos cosas que salieron de arreglar el delta y que valen para cualquiera que
escriba tests acá:

**El `assert` compara con `is not true`, no con `not`.** Con `not p_cond` y
`p_cond` NULL, el `if` no entra y el test pasa en verde. Y NULL es justo lo que
devuelve una comparación contra un campo que no vino: `jsonb_array_length(NULL)
= 2` da NULL, no `false`. La versión ingenua dejaba pasar exactamente los fallos
que estos archivos existen para encontrar — con el delta roto, tres asserts del
pull seguían diciendo OK.

**`sync_test.sql` ya no envuelve todo en una transacción.** Cada `do $$` es la
suya, como en producción, donde el push y el pull son dos requests HTTP
distintos. Con todo en una sola transacción el delta no puede entregar lo que
esa misma transacción acaba de escribir —correctamente— y el archivo entero
probaba una configuración que no existe. A cambio, el archivo deja sus filas
puestas: espera una base recién creada, que es lo que `run-tests.sh` da.

## Lo que falta

- El resto de las entidades de §2, a medida que Cristian defina el esquema.
- `goose` o el mecanismo de migraciones que se elija; hoy los archivos se
  aplican en orden.
- Purga de tombstones: una fila con `deleted = true` se queda para siempre y
  todo cliente nuevo se la baja. Con una temporada de uso eso es peso muerto en
  la primera sync de cada dispositivo.
- Tope de lote del lado de SQL. Hoy el `413` lo decide el BFF a los 500 jobs;
  `sync.push` acepta lo que le manden, así que otro cliente del RPC no tiene
  freno.
