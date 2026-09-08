# backend-supabase

Backend del ecosistema Colportaje sobre Supabase: schema, migraciones, RLS, RPCs, Edge Functions y seed. Región **sa-east-1** ([ADR-002](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-002-proveedor-cloud.md)).

**Estado: esquema inicial (Sprint 1)** — migración `0001` con todas las tablas V1 del cloud, RLS habilitada con políticas base, tests pgTAP y CI. Las políticas se refinan HU por HU desde Sprint 3; la infraestructura de sync (RPC de ingesta, `client_op_id`) la agrega `@BrunoFCapri` ([ADR-017](https://github.com/Colportores/docs-organizacion/blob/main/docs/decisiones/ADR-017-sync-engine-paquete.md)).

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
```

## CI/CD

- `ci.yml` (PR y push a `develop`/`staging`/`production`): levanta el mismo `compose.dev.yml`, aplica todas las migraciones sobre una base vacía, corre pgTAP y `supabase db lint`.
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

### Configurar un environment

Cada environment necesita tres secrets. **Nunca se pegan en un chat, un issue ni un archivo del repo**: se cargan una vez con `gh secret set`, que los lee de stdin y no los deja en el historial del shell.

```sh
REPO=Colportores/backend-supabase
ENV=develop

gh api -X PUT "repos/$REPO/environments/$ENV" --silent        # crear el environment

# Token personal de Supabase — https://supabase.com/dashboard/account/tokens
gh secret set SUPABASE_ACCESS_TOKEN --repo "$REPO" --env "$ENV"

# Contraseña de la base — Project Settings › Database › Database password
gh secret set SUPABASE_DB_PASSWORD  --repo "$REPO" --env "$ENV"

# Ref del proyecto (no es secreto, pero el workflow lo lee como tal)
gh secret set SUPABASE_PROJECT_ID   --repo "$REPO" --env "$ENV" --body "<project-ref>"
```

El `<project-ref>` es lo que va en la URL del dashboard: `https://supabase.com/dashboard/project/<project-ref>`.

> `supabase db push` es **forward-only y no tiene rollback**. El workflow imprime `migration list` antes y después justamente para que el log diga contra qué historial corrió.

## Privacidad

Los datos personales de clientes (`persona.nombre`, `persona.apellido`, `persona.telefono`, `nota.texto`) son **local-only**: viven solo en el dispositivo del colportor y nunca llegan al cloud, por la Ley 18.331 de Uruguay. Ver [`02-restricciones.md`](https://github.com/Colportores/docs-organizacion/blob/main/docs/02-restricciones.md).

**Este backend no tiene tablas `persona` ni `nota`.** No es una omisión temporal: es la restricción de diseño. Cualquier PR que las agregue debe rechazarse — y `supabase/tests/0001_esquema_inicial_test.sql` lo hace fallar automáticamente. `espacio_persona.persona_id` es un UUID opaco sin FK a propósito.

## Licencia

Uso propio — todos los derechos reservados. Ver [LICENSE](./LICENSE).
