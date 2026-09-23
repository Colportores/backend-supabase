#!/usr/bin/env bash
# Aplica supabase/seed.sql (datos de ejemplo, ficticios) sobre $DB_URL.
# Requiere las migraciones ya aplicadas. Idempotente: correrlo más de una vez
# no duplica ni rompe nada (ver comentario de cabecera de supabase/seed.sql).
#
# Mismo archivo que lee `supabase db reset` vía config.toml -> db.seed.sql_paths:
# este script existe para poder aplicarlo también sobre la base de compose.dev.yml,
# que este repo gestiona con scripts propios en vez de con el CLI de Supabase.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

case "$DB_URL" in
  *supabase.co*|*supabase.com*|*pooler*) echo "db-seed.sh es solo para la base local" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."
psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
