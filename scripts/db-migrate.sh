#!/usr/bin/env bash
# Aplica las migraciones pendientes de supabase/migrations sobre $DB_URL (forward-only).
# Mismo comando que corre CI. Registra el historial en supabase_migrations.schema_migrations.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

cd "$(dirname "$0")/.."
supabase migration up --db-url "$DB_URL" --include-all
echo
supabase migration list --db-url "$DB_URL"
