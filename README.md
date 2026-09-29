# backend-supabase

Backend del ecosistema Colportaje sobre Supabase: schema, migraciones, RLS, RPCs, Edge Functions y seed. Región **sa-east-1** ([ADR-002](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-002-proveedor-cloud.md)).

**Estado: esquema inicial + infra de sync** — migración `0001` con todas las tablas V1 del cloud y RLS con políticas base; migración `0002` con el RPC de ingesta batch, el cache de `client_op_id` y el delta pull ([ADR-017](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-017-sync-engine-paquete.md) §4); migración `0004` con el estado de la cuenta (`estado_cuenta()`, HU-AUTH-008); migración `0005` con la inscripción en campaña (`inscribir_colportor()`, HU-CAM-004); migración `0006` con la zona del colportor (`asignar_zona()`, HU-CAM-006); migración `0007` con las lecturas del panel; migración `0008` con el mapa de la campaña (ciudades, zonas RADIAL/ESQUINAS sin superposición, PostGIS). Las políticas se refinan HU por HU desde Sprint 3.

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
│   └── 20260929230000_0009_zona_solo_inscripcion.sql
├── seed.sql            ← datos de ejemplo (ficticios) de zonas, campañas, catálogo y precios
├── tests/             ← pgTAP: 0001 esquema/privacidad, 0002 RLS,
│                        0003 estructura de sync, 0004 push y delta, 0005 idempotencia del seed,
│                        0006 estado de la cuenta, 0007 inscripción en campaña, 0008 zona,
│                        0009 lecturas del panel, 0010 mapa de la campaña, 0011 mapa en el delta,
│                        0012 zona solo en la inscripción
├── tests_migracion/   ← migraciones que mueven datos, probadas con datos (db-test-migracion.sh)
├── bench/             ← carga sintética y medición del delta (no lo corre CI)
└── functions/         ← Edge Functions Deno (llegan con ADR-005)
docs/                  ← documentación propia de este repo (ver docs-organizacion/convenciones-desarrollo.md §1.1)
scripts/               ← db-migrate / db-test / db-test-migracion / db-lint / db-reset / db-seed / db-bench
```

`0004_sync_delta_test.sql` y `0011_zonas_mapa_sync_test.sql` son los únicos que **no** envuelven todo en una transacción: el delta sirve solo lo que está por debajo del horizonte de la transacción actual, así que un `begin` no puede entregar lo que él mismo escribió. Limpian sus filas al final.

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

Lo que ADR-017 §4 pone de este lado: RPC de ingesta batch, cache de `client_op_id` (TTL 24 h) y delta pull. Vive en el schema `sync`, que **no se expone en la Data API** (`config.toml` lista `public` y `graphql_public`): se llega por los RPC.

```sql
select sync.push(jobs, device_id);                       -- ingesta batch
select sync.pull(entidades, watermark, limite, device);  -- delta
select sync.estado();                                    -- telemetría del colportor (RF-SY06)
```

Tres cosas que conviene saber antes de tocarlo:

**La RLS es la autoridad de permisos, también en el push.** Los RPC son `SECURITY INVOKER` y no reciben el usuario por parámetro: lo sacan de `auth.uid()`. El BFF reenvía el JWT y no decide nada ([ADR-016](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-016-bff-por-aplicacion.md)). Por eso no hay filtro manual por columna de dueño — un `select` dentro de estas funciones ya devuelve solo lo que el usuario puede ver, y eso cubre los tres casos que un filtro por columna no cubría: `venta_item`/`entrega`/`cobranza` (sin columna propia, heredan el permiso vía `venta`), las tablas compartidas por zona (`mis_zonas()`, que no es una igualdad) y los catálogos globales.

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

### Zona del colportor

`select public.asignar_zona(campania_id, usuario_id, zona_id);` asigna o cambia la zona de un colportor inscripto (`campania_colportor.zona_id`, HU-CAM-006) y devuelve la fila. `mis_zonas()` le abre la zona nueva y deja de abrirle la anterior.

Desde la migración `0009`, la inscripción es el **único** lugar donde vive la zona de un colportor (`null` = sin zona): `usuario.zona_id` ya no existe. Un trigger (`campania_colportor_zona_valida`) exige, también fuera del RPC, que la zona sea de una ciudad viva de la misma campaña y no esté dada de baja. `mis_zonas()` solo devuelve zonas vivas de inscripciones vigentes.

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
select public.baja_zona(zona_id, vista_previa);
```

- **Quién.** El coordinador de la campaña o un ADMIN, y solo si la campaña no terminó. Nadie escribe estas tablas directo (ni el privilegio tiene `authenticated`).
- **No superposición.** Dos zonas vivas de la misma `campania_ciudad` no comparten interior; sí la calle del borde (tolerancia: una franja de menos de 1 m de ancho no cuenta). Se valida con PostGIS en un trigger, así que vale para cualquier camino de escritura. `CZ007` trae en el DETAIL la geometría de la parte superpuesta.
- **Vista previa.** Con `vista_previa` no se guarda nada: devuelve el polígono, las superposiciones y `ubicaciones_que_cambian` (null hasta #24).
- **Baja.** Lógica. Si la zona tiene colportores asignados se rechaza (`CZ010`) y dice a quiénes reasignar.
- **Lectura.** El colportor ve las ciudades, zonas y esquinas de las campañas en las que está inscripto (todas las zonas, no solo la suya); el coordinador, las de sus campañas; el ADMIN, todas. `campania_ciudad`, `zona` y `zona_vertice` viajan por el delta como pull.
- **Códigos.** `CZ007`..`CZ013`: ver el header de la migración `0008`.

## Privacidad

Los datos personales de clientes (`persona.nombre`, `persona.apellido`, `persona.telefono`, `nota.texto`) son **local-only**: viven solo en el dispositivo del colportor y nunca llegan al cloud, por la Ley 18.331 de Uruguay. Ver [`02-restricciones.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/02-restricciones.md).

**Este backend no tiene tablas `persona` ni `nota`.** No es una omisión temporal: es la restricción de diseño. Cualquier PR que las agregue debe rechazarse — y `supabase/tests/0001_esquema_inicial_test.sql` lo hace fallar automáticamente. `espacio_persona.persona_id` es un UUID opaco sin FK a propósito.

## Licencia

Uso propio — todos los derechos reservados. Ver [LICENSE](./LICENSE).
