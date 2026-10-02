# backend-supabase

Backend del ecosistema Colportaje sobre Supabase: schema, migraciones, RLS, RPCs, Edge Functions y seed. Región **sa-east-1** ([ADR-012](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-012-backend-supabase-sa-east-1.md)).

**Estado: esquema inicial + infra de sync** — migración `0001` con todas las tablas V1 del cloud y RLS con políticas base; migración `0002` con el RPC de ingesta batch, el cache de `client_op_id` y el delta pull ([ADR-008](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-008-sync-engine-paquete-dart.md)); migración `0004` con el estado de la cuenta (`estado_cuenta()`, HU-AUTH-008); migración `0005` con la inscripción en campaña (`inscribir_colportor()`, HU-CAM-004); migración `0006` con la zona del colportor (`asignar_zona()`, HU-CAM-006); migración `0007` con las lecturas del panel; migración `0008` con el mapa de la campaña (ciudades, zonas RADIAL/ESQUINAS, PostGIS). Las políticas se refinan HU por HU desde Sprint 3.

## Contexto

Parte del sistema [Colportaje App](https://github.com/Colportores). El modelo de datos, la arquitectura y las decisiones viven en la [documentación de la organización](https://github.com/Colportores/docs-organizacion) — en particular [`esquema-datos.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/esquema-datos.md) y el [contrato de sync](https://github.com/Colportores/docs-organizacion/blob/main/docs/contrato-sync-engine.md) §2, que fija qué entidades viven acá.

- **La RLS es la autoridad de permisos** de todo el sistema. Los BFF reenvían el JWT del usuario; no deciden nada por su cuenta ([ADR-013](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-013-un-bff-por-aplicacion-en-workers.md)).
- La lógica de dominio que toca varias tablas vive en **RPCs de Postgres**, no en los BFF.
- Push FCM vía Edge Functions ([ADR-014](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-014-push-con-fcm-desde-edge-functions.md)).

## Reglas del esquema

- Todos los IDs son **UUID v7 generados en el cliente** — nunca `SERIAL` ni `AUTOINCREMENT`. `public.uuid_generate_v7()` existe solo para seeds y filas creadas del lado servidor.
- Toda tabla lleva `created_at`, `updated_at`, `created_by`, `deleted_at` (soft delete) y `sync_version`. `updated_at` y `sync_version` los pone el servidor por trigger; `authenticated` no tiene `DELETE`.
- Dinero en **centavos** (`integer`).
- Migraciones **forward-only**: una migración aplicada no se modifica nunca. Nombre `<timestamp>_<nnnn>_<descripcion>.sql`.
- `anon` no tiene privilegios: todo entra por el BFF con el JWT del usuario.

Los tests pgTAP (`supabase/tests/`) verifican estas reglas en cada PR: si una tabla nueva no cumple, CI falla.

**Todo el SQL del repo vive en `supabase/`**, y `scripts/check-sql-layout.sh` lo hace cumplir en CI. `supabase migration up` y `supabase db push` leen únicamente `supabase/migrations/`: un árbol de SQL en cualquier otro lado sale verde sin que nadie lo haya aplicado ni probado.

## Desarrollo

Todo corre en Docker; no hace falta el CLI de Supabase ni Postgres en el host.

```sh
docker compose -f compose.dev.yml build cli                               # una vez
docker compose -f compose.dev.yml run --rm cli bash scripts/db-migrate.sh # base vacía + migraciones
docker compose -f compose.dev.yml run --rm cli bash scripts/db-test.sh    # pgTAP
docker compose -f compose.dev.yml run --rm cli bash scripts/db-lint.sh    # plpgsql_check
docker compose -f compose.dev.yml run --rm cli bash scripts/db-reset.sh   # borrar y re-aplicar todo
docker compose -f compose.dev.yml run --rm cli bash scripts/db-seed.sh    # + datos de ejemplo (opcional)
docker compose -f compose.dev.yml run --rm cli psql "$DB_URL"             # consola
docker compose -f compose.dev.yml down -v                                 # apagar (la base no persiste)
```

- **Imagen y cachés compartidas.** `-p <nombre>` propio está bien para aislar contenedores y la base; la imagen (`backend-supabase-dev:latest`) es compartida por todos los proyectos.
  `docker compose build` solo cuando cambia `dockerfile.dev`.
- `db` es la imagen oficial `supabase/postgres` (mismos roles, schema `auth` y extensiones que producción), expuesta en el host en `localhost:55432` (`DB_PORT=` para cambiarlo).
- `cli` trae Supabase CLI, `psql` y `pg_prove`. El repo se monta en `/work`.
- Nueva migración: `docker compose -f compose.dev.yml run --rm cli supabase migration new <nnnn>_<descripcion>` y luego `db-migrate.sh`.
- `db-seed.sh` carga `supabase/seed.sql` (zonas, campañas, catálogo y precios de ejemplo, todos ficticios — issue #16). Es un paso aparte de `db-reset.sh`, a propósito: la suite pgTAP asume el catálogo vacío salvo sus propios fixtures (p. ej. `0002_rls_test.sql` cuenta exactamente 1 fila en `producto`), así que sembrar datos de ejemplo no es parte del reset que usa CI. `db-seed.sh` es el **único camino sancionado**: `[db.seed] enabled = false` en `config.toml` a propósito, para que `supabase db reset --linked` (el comando nativo del CLI contra un proyecto remoto linkeado) **no** aplique el catálogo ficticio sobre staging/producción. Para cargar datos **reales** en vez de los de ejemplo, ver [`docs/guia-carga-manual.md`](./docs/guia-carga-manual.md).

### Estructura

```
supabase/
├── config.toml        ← config del proyecto (supabase init); project_id = backend-supabase
├── migrations/        ← forward-only
│   ├── 20260901000000_0001_esquema_inicial.sql
│   ├── 20260902180000_0002_sync_infra.sql
│   ├── 20260902200000_0003_rls_performance.sql
│   ├── 20260929120000_0004_estado_cuenta.sql
│   ├── 20260929180000_0005_inscribir_colportor.sql
│   ├── 20260929200000_0006_asignar_zona.sql
│   ├── 20260929210000_0007_lecturas_panel.sql
│   ├── 20260929220000_0008_zonas_mapa.sql
│   ├── 20260929230000_0009_zona_solo_inscripcion.sql
│   ├── 20260929235000_0010_zona_por_posicion.sql
│   └── 20260930120000_0011_zona_al_descargar.sql
├── seed.sql            ← datos de ejemplo (ficticios) de zonas, campañas, catálogo y precios
├── tests/             ← pgTAP: 0001 esquema/privacidad, 0002 RLS,
│                        0003 estructura de sync, 0004 push y delta, 0005 idempotencia del seed,
│                        0006 estado de la cuenta, 0007 inscripción en campaña, 0008 zona,
│                        0009 lecturas del panel, 0010 mapa de la campaña, 0011 mapa en el delta,
│                        0012 zona solo en la inscripción, 0013 ubicación sin zona,
│                        0014 alcance del pull
├── tests_migracion/   ← migraciones que mueven datos, probadas con datos (db-test-migracion.sh)
├── bench/             ← carga sintética y medición del delta (no lo corre CI)
└── functions/         ← Edge Functions Deno (llegan con ADR-014)
docs/                  ← documentación propia de este repo (ver docs-organizacion/convenciones-desarrollo.md §1.1)
scripts/               ← db-migrate / db-test / db-test-migracion / db-lint / db-reset / db-seed / db-bench
```

`0004_sync_delta_test.sql`, `0011_zonas_mapa_sync_test.sql` y `0014_alcance_del_pull_test.sql` son los únicos que **no** envuelven todo en una transacción: el delta sirve solo lo que está por debajo del horizonte de la transacción actual, así que un `begin` no puede entregar lo que él mismo escribió. Limpian sus filas al final.

`db-test-migracion.sh` prueba las migraciones que mueven datos: por cada caso de `supabase/tests_migracion/` limpia la base, aplica las migraciones hasta la versión previa, carga los datos del caso, aplica el resto y verifica (pgTAP, o que aborte con el mensaje esperado). Al final deja la base como `db-reset.sh`.

## CI/CD

- `ci.yml` (PR y push a `develop`/`staging`/`production`): levanta el mismo `compose.dev.yml`, aplica todas las migraciones sobre una base vacía, corre pgTAP y `supabase db lint`, y al final prueba las migraciones que mueven datos con `db-test-migracion.sh`.
- `deploy.yml`: `supabase link` + `supabase db push` contra el proyecto Supabase del *environment*. **Se dispara al terminar CI en verde sobre el mismo commit**, nunca en paralelo: una migración que rompe pgTAP no llega a la base real.

### Cuándo aplica cada rama

| rama | aplica | condición |
|---|---|---|
| `develop` | environment `develop` | solo si la variable de repo **`DEPLOY_DEVELOP`** vale `true` |
| `staging` | environment `staging` | siempre, con CI verde |
| `production` | environment `production` | siempre, con CI verde |

El auto-deploy de `develop` va detrás de una bandera y no de un cambio de workflow: durante la fase de desarrollo conviene que cada merge deje el proyecto cloud al día, y eso deja de ser aceptable en cuanto arranque el piloto. Apagarlo es cambiar una variable:

```sh
gh variable set DEPLOY_DEVELOP --repo Colportores/backend-supabase --body false
```

También se puede disparar a mano contra cualquier environment desde la pestaña Actions (`workflow_dispatch`), o con `gh workflow run deploy.yml -f environment=develop`.


## Infraestructura de sincronización

Lo que ADR-008 pone de este lado: RPC de ingesta batch, cache de `client_op_id` (TTL 24 h) y delta pull. Vive en el schema `sync`, que **no se expone en la Data API** (`config.toml` lista `public` y `graphql_public`): se llega por los RPC.

```sql
select sync.push(jobs, device_id);                       -- ingesta batch
select sync.pull(entidades, watermark, limite, device, alcance);  -- delta ('zona' o 'ciudad')
select sync.estado();                                    -- telemetría del colportor (RF-SY06)
```

Tres cosas que conviene saber antes de tocarlo:

**La RLS es la autoridad de permisos, también en el push.** Los RPC son `SECURITY INVOKER` y no reciben el usuario por parámetro: lo sacan de `auth.uid()`. El BFF reenvía el JWT y no decide nada ([ADR-013](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-013-un-bff-por-aplicacion-en-workers.md)). Por eso no hay filtro manual por columna de dueño — un `select` dentro de estas funciones ya devuelve solo lo que el usuario puede ver, y eso cubre los tres casos que un filtro por columna no cubría: `venta_item`/`entrega`/`cobranza` (sin columna propia, heredan el permiso vía `venta`), las tablas compartidas por ciudad (`mis_ciudades_de_trabajo()`, que no es una igualdad) y los catálogos globales.

**El cursor del delta es el xid de la transacción, no el reloj.** `updated_at` se llena con `now()`, que es la hora de *inicio* de transacción: dos escritores concurrentes commitean en un orden que no tiene por qué coincidir con el de sus timestamps, y la fila que commiteó tarde queda detrás de un watermark que ya avanzó — subida, guardada y jamás entregada. Se ordena por `(xmin_w, id)` y se sirve solo lo que está por debajo de `pg_snapshot_xmin(pg_current_snapshot())`. El diagnóstico y el arreglo son de @BrunoFCapri.

**`xmin_w` lo pone el trigger de auditoría, no el RPC.** Si dependiera del RPC, toda escritura que no pase por `sync.push()` —seeds, panel del coordinador, un job— dejaría la fila con el xid de su INSERT: modificada en la base y nunca propagada.

**Las políticas RLS envuelven sus llamadas en `(select ...)`.** `tiene_rol()` suelta en un `USING` se evalúa **por fila**; envuelta es un InitPlan que corre una vez. Medido sobre 390.000 filas, el delta de `ubicacion` pasó de **1.210 ms a 35 ms** (`supabase/bench/README.md`). Un test en `0002_rls_test.sql` falla si una política nueva se aparta.

El registro de entidades (`sync.entidad`) es una tabla y no una lista en el código: el RPC es genérico, y sin lista blanca un cliente podría mandar `entity: "usuario"` y escribir donde no debe. Es el espejo en SQL del `SyncSpec` del motor ([contrato §2](https://github.com/Colportores/docs-organizacion/blob/main/docs/contrato-sync-engine.md)). **`persona` y `nota` no están, y no van a estar.**

## Estado de la cuenta

`select public.estado_cuenta();` devuelve el estado del usuario autenticado: `ACTIVA`, `PENDIENTE_ASIGNACION` o `SUSPENDIDA` (HU-AUTH-008). Lo consume `bff-colportores` en `GET /v1/me` con el JWT del usuario ([ADR-013](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-013-un-bff-por-aplicacion-en-workers.md)); por PostgREST es `POST /rest/v1/rpc/estado_cuenta` y responde un string JSON.

**No es una columna que alguien mantenga**, se deriva:

- `SUSPENDIDA` si `usuario.suspendido_en` no es null. Gana sobre todo lo demás.
- `ACTIVA` si tiene una inscripción vigente en `campania_colportor`: fila no borrada, campaña no borrada y hoy entre `fecha_inicio` y `fecha_fin`. Cuando HU-CAM-004 inscribe al colportor, la cuenta queda activa sola.
- `PENDIENTE_ASIGNACION` en cualquier otro caso.

"Vigente" está escrito una sola vez, en `mis_campanias_vigentes()`, y `mis_zonas()` lo usa. Con una diferencia: una inscripción sin zona activa la cuenta, pero no abre ninguna zona.

`suspendido_en` la fija el servidor: un trigger descarta en silencio cualquier cambio que venga con JWT, incluido el de un ADMIN. Quién suspende y reactiva es de HU-ADM-003, que todavía no está decidido.

## Inscripción en campaña

`select public.inscribir_colportor(campania_id, usuario_id);` inscribe a un colportor en una campaña y devuelve la fila de `campania_colportor` (HU-CAM-004). Con eso su cuenta pasa sola de `PENDIENTE_ASIGNACION` a `ACTIVA`. Lo consume `bff-coordinadores`; por PostgREST es `POST /rest/v1/rpc/inscribir_colportor`.

- **Quién.** El coordinador de esa campaña (`campania.coordinador_id`) o un ADMIN. Si no, `42501`.
- **Qué reglas.** Campaña vigente; usuario existente, con email verificado y no suspendido; que no esté ya inscripto; que no esté en otra campaña vigente. Cada regla tiene su código propio, `CI001`..`CI008`: ver el header de la migración `0005`.
- **Dónde viven.** Una sola definición, `motivo_rechazo_inscripcion()`, que es interna.
- **Un solo camino.** El RPC es el único camino para inscribir con JWT. `campania_colportor` no tiene política INSERT, así que la RLS niega el INSERT directo, incluso al ADMIN. El RPC es `SECURITY DEFINER` y toma un lock por usuario: así nadie queda en dos campañas vigentes por dos inscripciones simultáneas.
- **Qué no se puede hacer con un UPDATE.**
  - Cambiar la campaña o el usuario de una inscripción. Reasignar es cerrar una y abrir otra (HU-CAM-005).
  - Reactivar una inscripción borrada. Si se reactiva o no está pendiente de decisión.

### Cuentas: qué ve el coordinador y búsqueda de candidatos

Desde la migración `0015` (backend-supabase#41) el coordinador **no lee `public.usuario` directo**: la política `usuario_select_propio_o_admin` le deja leer solo su fila (la del `GET /v1/me`); el ADMIN lee todas. A las cuentas ajenas llega por dos RPC, que acotan filas y columnas (decisiones de Cristian del 30/09, front-coordinadores-web#20 y #29):

```sql
select * from public.colportores_de_campania(campania_id);        -- «Ya en tu equipo»: nombre, email y estado
select * from public.buscar_candidatos(campania_id, texto, despues_de); -- vista 23: sugeridos o búsqueda
```

- **Quién.** El coordinador de esa campaña o un ADMIN, con la campaña vigente. Si no, `42501`; `buscar_candidatos()` responde `CI001`/`CI002` como `inscribir_colportor()`.
- **Candidatas.** Cuentas vivas, con el email verificado y que no estén ya en el equipo. Aparecen también las suspendidas, las que están en otra campaña vigente y las que tienen una inscripción dada de baja en esta campaña, con su `motivo_bloqueo`: el motivo con que `inscribir_colportor()` las rechazaría (`null` si se pueden añadir).
- **Sin texto: sugeridos.** Hasta 5 cuentas `PENDIENTE_ASIGNACION`, de la más nueva a la más vieja.
- **Con texto: búsqueda.** Las cuentas cuyo nombre completo o email contiene el texto, sin distinguir mayúsculas ni tildes. Primero las que empiezan con él (nombre, apellido o email); después el resto, alfabético (decisión del 02/10). De a 10 por página: para la siguiente, `despues_de` es el `usuario_id` de la última cuenta mostrada (cursor, sin duplicados ni huecos aunque la lista cambie entre páginas). Una página con menos de 10 es la última.
- **Columnas.** `usuario_id`, `nombre`, `apellido`, `email`, `estado` (como `estado_cuenta()`), `campania_actual` (la campaña vigente en la que está, para «Está en campaña X»), `creada_en` y `motivo_bloqueo`.
- **Estado de la cuenta.** La precedencia (suspendida, activa, pendiente) vive en `estado_de_cuenta()`, que usan `estado_cuenta()` y los dos RPC.

### Zona del colportor

`select public.asignar_zona(campania_id, usuario_id, zona_id);` asigna o cambia la zona de un colportor inscripto (`campania_colportor.zona_id`, HU-CAM-006) y devuelve la fila. `mis_zonas()` le abre la zona nueva y deja de abrirle la anterior.

Desde la migración `0009`, la inscripción es el **único** lugar donde vive la zona de un colportor (`null` = sin zona): `usuario.zona_id` ya no existe. Un trigger (`campania_colportor_zona_valida`) exige, también fuera del RPC, que la zona sea de una ciudad viva de la misma campaña y no esté dada de baja; lo revisa también al reactivar una inscripción dada de baja (si su zona ya no sirve, se rechaza y el aviso dice que se reactive sin zona). `mis_zonas()` solo devuelve zonas vivas de inscripciones vigentes.

- **Quién.** El coordinador de esa campaña o un ADMIN. Si no, `42501`.
- **Qué reglas.** Campaña vigente; colportor con inscripción viva en esa campaña; zona viva de una ciudad de esa campaña (desde `0008`: `CZ006` si es de otra campaña, `CZ005` si su ciudad se quitó de la campaña). Los códigos son `CZ001`..`CZ006`: ver el header de las migraciones `0006` y `0008`.
- **Un solo camino.** Es el único camino para cambiar `zona_id` con JWT: un trigger rechaza el UPDATE directo de esa columna, incluso del ADMIN.
- **Con quién comparte el permiso.** El chequeo de permiso y campaña vigente (`motivo_campania_del_coordinador()`) es el mismo que usa `inscribir_colportor()`.

## Mapa de la campaña

Una campaña abarca una o más ciudades (`campania_ciudad`) y cada ciudad se divide en zonas dibujadas sobre el mapa (vista 24 del panel, migración `0008`). Una zona es `RADIAL` (centro y radio; el polígono lo calcula el servidor) o `ESQUINAS` (esquinas en `zona_vertice` y el borde que sigue las calles, que llega ya calculado). `zona.poligono_geojson` es la geometría que dibujan la app y el panel.

```sql
select public.agregar_ciudad_a_campania(campania_id, ciudad_id);   -- «+ Agregar ciudad»
select public.guardar_zona(campania_ciudad_id, nombre, tipo_forma, color, centro_lat, centro_lon,
                           radio_m, vertices, poligono_geojson, zona_id, vista_previa);
select public.baja_zona(zona_id, vista_previa);                     -- «Eliminar zona»
select public.quitar_zona(campania_id, usuario_id);                -- «Quitar» (0012)
```

- **Quién.** El coordinador de la campaña o un ADMIN, y solo si la campaña no terminó. Nadie escribe estas tablas directo (ni el privilegio tiene `authenticated`).
- **Superposición.** Las zonas se pueden superponer (S56, migración `0013`): no hay regla ni tolerancia, y nada se rechaza por tocar o cubrir parte de otra zona. El nombre sí es único entre las zonas vivas de la misma `campania_ciudad` (`CZ009`).
- **Forma.** `RADIAL`: radio de 1 a 3000 m (hasta ahí el círculo de 128 lados queda a menos de 1 m del geodésico). `ESQUINAS`: al menos 3 esquinas en lugares distintos (a 1 m o menos cuentan como la misma), con `orden` entero, y el borde pasando a 1 m o menos de cada una. Todo lo demás, `CZ008`.
- **Vista previa.** Con `vista_previa` no se guarda nada: devuelve el polígono y `ubicaciones_incluidas`, el «Incluye N ubicaciones» de la vista 24: las ubicaciones vivas de la ciudad que caen dentro de la forma, calculado en el momento con PostGIS. Al guardar devuelve lo mismo. `baja_zona()` devuelve las que incluía la zona. Guardar o dar de baja una zona no toca ninguna ubicación.
- **Baja y «Quitar».** La baja es lógica. Los colportores asignados quedan sin zona y devuelve quiénes (`colportores_asignados`) y cuántos (`colportores_sin_zona`), también en la vista previa (`0012`). `quitar_zona()` deja sin zona a un colportor. `asignar_zona()` rechaza una cuenta suspendida (`CZ014`), que conserva la zona que tenía.
- **Lectura.** El colportor ve las ciudades, zonas y esquinas de toda campaña en la que está inscripto y que **no terminó**: en curso o por empezar (todas las zonas, no solo la suya; S56, `0013`, y decisión del 30/09: el mapa de una campaña futura se baja antes del primer día). Las terminadas, no. El coordinador ve las de las campañas que coordina, terminadas incluidas; el ADMIN, todas. `campania_ciudad`, `zona` y `zona_vertice` viajan por el delta como pull, y su watermark lleva la huella de las campañas que ve (`sync.entidad.sigue_campanias`). Si cambian (termina una campaña, lo inscriben o lo reactivan), el mapa baja completo, también lo que se cargó antes de su último pull. El servidor no manda borrados: el mapa de una campaña terminada queda en el teléfono y la app decide si lo muestra.
- **La inscripción en el celular.** `campania_colportor` baja por el pull (`0014`), solo con las inscripciones propias: `sync.entidad.columna_duenio` filtra por `usuario_id = auth.uid()` aunque la RLS le muestre más al coordinador o al ADMIN. Con eso la app sabe su campaña y su zona, y recibe el cambio cuando se la asignan, se la quitan o dan de baja la zona. La app no la escribe (`ENTIDAD_DE_SOLO_LECTURA`).
- **Códigos.** `CZ008`..`CZ014`: ver los headers de las migraciones `0008` y `0012`. `CZ007` (superposición) y `CZ010` (baja con asignados) ya no se usan.

### Qué ubicaciones baja cada colportor

Desde la migración `0011` (backend-supabase#32, decisión D2 del 29/09) la zona es una guía visual: **las ubicaciones no guardan zona ni campaña** (`ubicacion.zona_id` y `house_status.zona_id`, de `0010`, ya no existen). La zona decide qué casas bajan al teléfono, y eso se calcula al descargar (HU-SYNC-011).

- **Quién ve qué.** El colportor ve las ubicaciones de su ciudad de trabajo (`mis_ciudades_de_trabajo()`: la de su zona asignada; sin zona, todas las de la campaña, S55) y las que registró él. Cuentan las campañas en las que tiene una inscripción viva y que no terminaron: en curso o por empezar, igual que el mapa (`0013`, decisión del 02/10: las casas de una campaña futura se bajan antes del primer día); registra en cualquier lado (R-CM04). El coordinador y el ADMIN las ven todas. `espacio` y `house_status` siguen a su ubicación, y también los ve quien los cargó.
- **Quién escribe dónde.** La zona acota solo la lectura (decisión de Cristian del 30/09, #36): el colportor corrige ubicaciones y carga espacios y estados en todas las ciudades de sus campañas ya empezadas y no terminadas, o terminadas hace 15 días o menos (`0020`), tenga zona o no (`mis_ciudades_de_campania()`, `puedo_escribir_en_ubicacion()`). Lo que cargó sin señal en una casa de otra ciudad de su campaña sube aunque después le asignen una zona en otra ciudad: el espacio, y colgando de él la persona, la visita y la venta. Lo que sigue sin subir es la corrección de una fila que la lectura ya no le deja ver (el push la lee antes: `FILA_INEXISTENTE`, sin borrar nada del teléfono).
- **Corregir lo que cargó, solo con la campaña vigente** (`0018`, decisión del 02/10). Un espacio o un estado se corrige o se da de baja mientras su campaña está vigente (más los 15 días de `0020`; desde `0021`, también en una casa que registró él: sin campaña en la que escribir, el autor tampoco corrige): con la campaña terminada, el push vuelve `invalid` 42501, visible en la cola de error, y no se pierde nada.
- **Corregir lo que ve, aunque todavía no pueda escribir** (`0021`). Antes del primer día de la campaña ve las casas, espacios y estados ajenos pero no los puede corregir: el push vuelve `invalid` 42501 (visible en la cola de error), no un `conflict` con `server_row` que el teléfono aplicaba pisando su corrección. Lo que no ve sigue con `FILA_INEXISTENTE`.
- **Lo que sube tarde** (`0020`, decisión del 02/10). Lo que depende de la campaña (corregir una casa ajena, cargar o corregir espacios y estados) se acepta hasta 15 días después de que terminó, contados en la hora de Montevideo: el día 15 entra hasta las 23:59 y el 16 ya no. Es solo para escribir: la lectura y el estado de la cuenta siguen cortando el último día, así que corregir una fila ajena que ya no ve sigue volviendo `FILA_INEXISTENTE`.
- **Dar de baja una casa** (`0018`, decisión del 02/10). No se puede si tiene alguna venta (`UB001`) o alguna visita registrada por otro colportor (`UB002`), contando también las dadas de baja. El push lo devuelve `invalid` con ese código, sin tumbar el lote, y la casa queda como estaba; la app lo traduce a un aviso y lo revisa antes de ofrecer «Dar de baja».
- **Qué baja.** `sync.pull(..., alcance)`: con `'zona'` (el default), las que registró él más las que caen en el polígono de su zona asignada (`ST_Covers`, borde incluido, misma ciudad); sin zona, solo las propias. Con `'ciudad'`, todas las de sus ciudades más las propias. Con cada ubicación bajan sus espacios y su estado, también las bajas (su tombstone). `sync.entidad.columna_ubicacion` marca qué entidades bajan así.
- **Área completa.** El watermark de esas entidades lleva la huella del área. Si le asignan otra zona, se la redibujan, cambia de alcance, lo inscriben en otra campaña o termina una, la huella cambia (el día que una campaña empieza, no: sus casas ya habían bajado) y la entidad baja completa, también lo que se cargó antes de su último pull. Cambiarle el nombre o el color a la zona no cambia nada.
- **Lo que sale del área** (`0016`, backend-supabase#37). Si una casa que el colportor tenía en su área se mueve fuera (otro la corrige a otra posición o a otra ciudad), su pull siguiente la avisa en `out_of_area`: `{"ubicacion": [ids]}`. La app la marca «fuera del área» y no borra nada. Para eso, un trigger anota en `sync.ubicacion_movida` la posición de antes de cada movimiento. Si lo que cambia es el área (otra zona, otra forma, otro alcance, termina una campaña), la entidad arranca de cero y el pull lo dice en `area_reset`: lo que el teléfono tenía y no vuelve a bajar quedó afuera. La forma del aviso es una propuesta, pendiente del acuerdo con el motor (front-colportores-mobile#178).
- **Una casa que se mueve.** Si cambia la posición o la ciudad de una ubicación, sus espacios y su estado se republican, y le llegan a quien la empieza a tener en su área. Republicar sube solo `xmin_w`, no `sync_version` ni `updated_at` (la GUC local `colportores.republicar` en `tg_auditoria_update`): así no vuelve `conflict` lo que un teléfono tenga pendiente sobre esas filas. `house_status.lat`/`lon` (el pin) los pone el servidor con la posición de la casa; el push los descarta.
- **Supuestos de HU-SYNC-011 (decididos el 30/09).** S60: sin alcance baja `'zona'`. S55: «la ciudad» es la de su zona asignada; sin zona, todas las de la campaña (las que no terminaron, decisión del 02/10); acota lo que baja y lo que ve, no dónde escribe. S54: se puede cambiar de alcance; las casas que quedan afuera no se borran.
- **Posible duplicado** (aviso, no bloqueo). `posibles_duplicados_de_ubicacion(ciudad_id, calle, numero, lat, lon, excluir_id)` devuelve las ubicaciones visibles con la misma dirección normalizada (trim y minúsculas) o a menos de 5 m.
- **Dirección única (D1, `0017`).** Dos ubicaciones vivas de la misma ciudad con la misma calle y número normalizados (sin tildes ni espacios de más) no pueden estar a menos de 100 m: `23505` con la restricción `ubicacion_direccion_unica`. En el push vuelve `conflict` sin `server_row`: la fila queda en el teléfono y se resuelve en la vista 10. Lo que cuelga de esa alta en el mismo lote (el depto, la persona, la visita, la venta, el estado) vuelve `conflict` con `code: ESPERA_ALTA_EN_CONFLICTO` y `depends_on` (decisión del 02/10): no se escribe y el motor lo reintenta cuando se resuelve el alta. La migración no da de baja nada: si la base tiene direcciones repetidas a menos de 100 m, aborta y las lista todas (decisión del 02/10).

## Privacidad

Los datos personales de clientes (`persona.nombre`, `persona.apellido`, `persona.telefono`, `nota.texto`) son **local-only**: viven solo en el dispositivo del colportor y nunca llegan al cloud, por la Ley 18.331 de Uruguay. Ver [`02-restricciones.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/02-restricciones.md).

**Este backend no tiene tablas `persona` ni `nota`.** No es una omisión temporal: es la restricción de diseño. Cualquier PR que las agregue debe rechazarse — y `supabase/tests/0001_esquema_inicial_test.sql` lo hace fallar automáticamente. `espacio_persona.persona_id` es un UUID opaco sin FK a propósito.

## Licencia

Uso propio — todos los derechos reservados. Ver [LICENSE](./LICENSE).
