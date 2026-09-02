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
drop schema if exists supabase_migrations cascade;
SQL

exec bash "$(dirname "$0")/db-migrate.sh"
