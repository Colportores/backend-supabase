#!/usr/bin/env bash
# Lint de funciones plpgsql/sql del schema public con plpgsql_check (vía Supabase CLI).
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

cd "$(dirname "$0")/.."
supabase db lint --db-url "$DB_URL" --schema public --level warning
