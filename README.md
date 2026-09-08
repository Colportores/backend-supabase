# backend-supabase

Backend del ecosistema Colportaje sobre Supabase: schema, migraciones, RLS, RPCs, Edge Functions y seed. Región **sa-east-1** ([ADR-002](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-002-proveedor-cloud.md)).

**Estado: esquema inicial + infra de sync** — migración `0001` con todas las tablas V1 del cloud y RLS con políticas base; migración `0002` con el RPC de ingesta batch, el cache de `client_op_id` y el delta pull ([ADR-017](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-017-sync-engine-paquete.md) §4). Las políticas se refinan HU por HU desde Sprint 3.

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
│   ├── 20260901000000_0001_esquema_inicial.sql
│   ├── 20260902180000_0002_sync_infra.sql
│   └── 20260902200000_0003_rls_performance.sql
├── tests/             ← pgTAP: 0001 esquema/privacidad, 0002 RLS,
│                        0003 estructura de sync, 0004 push y delta
├── bench/             ← carga sintética y medición del delta (no lo corre CI)
└── functions/         ← Edge Functions Deno (llegan con ADR-005)
scripts/               ← db-migrate / db-test / db-lint / db-reset / db-bench
```

`0004_sync_delta_test.sql` es el único que **no** envuelve todo en una transacción: el delta sirve solo lo que está por debajo del horizonte de la transacción actual, así que un `begin` no puede entregar lo que él mismo escribió. Limpia sus filas al final.

## CI/CD

- `ci.yml` (PR y push a `develop`/`staging`/`production`): verifica que no haya SQL fuera de `supabase/`, levanta el mismo `compose.dev.yml`, aplica todas las migraciones sobre una base vacía, corre pgTAP y `supabase db lint`.
- `deploy.yml` (push a `staging`/`production`): `supabase link` + `supabase db push` contra el proyecto del *environment*. Requiere `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_ID` y `SUPABASE_DB_PASSWORD` como secrets del environment de GitHub.

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

## Privacidad

Los datos personales de clientes (`persona.nombre`, `persona.apellido`, `persona.telefono`, `nota.texto`) son **local-only**: viven solo en el dispositivo del colportor y nunca llegan al cloud, por la Ley 18.331 de Uruguay. Ver [`02-restricciones.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/02-restricciones.md).

**Este backend no tiene tablas `persona` ni `nota`.** No es una omisión temporal: es la restricción de diseño. Cualquier PR que las agregue debe rechazarse — y `supabase/tests/0001_esquema_inicial_test.sql` lo hace fallar automáticamente. `espacio_persona.persona_id` es un UUID opaco sin FK a propósito.

## Licencia

Uso propio — todos los derechos reservados. Ver [LICENSE](./LICENSE).
