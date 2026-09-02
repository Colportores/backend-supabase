#!/usr/bin/env bash
# Deja la base como recién creada y vuelve a aplicar todas las migraciones.
# Solo para la base local de compose.dev.yml — nunca apuntar a un proyecto remoto.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

case "$DB_URL" in
  *supabase.co*|*supabase.com*|*pooler*) echo "db-reset.sh es solo para la base local" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
psql "$DB_URL" -v ON_ERROR_STOP=1 -q <<'SQL'
drop schema if exists public cascade;
create schema public;
grant usage on schema public to postgres, anon, authenticated, service_role;
grant all on schema public to postgres, service_role;
-- La infra de sync (0002) vive en su propio schema y tiene FKs contra public:
-- sin dropearlo, `create schema sync` de la migración falla al reaplicar.
drop schema if exists sync cascade;
-- auth es de la imagen y no se dropea, pero sus filas sobreviven al reset y
-- chocan con los fixtures de los tests, que insertan usuarios con id fijo.
-- El trigger on_auth_user_created se va con `public`, así que esto no recrea perfiles.
delete from auth.users;
drop schema if exists supabase_migrations cascade;
SQL

exec bash "$(dirname "$0")/db-migrate.sh"
