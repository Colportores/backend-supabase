#!/usr/bin/env bash
# Lint de funciones plpgsql/sql con plpgsql_check (vía Supabase CLI).
#
# `sync` va además de `public`: desde la 0002 el grueso del PL/pgSQL del repo vive
# ahí, y lintear solo public dejaba el RPC de ingesta fuera del control de CI.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

cd "$(dirname "$0")/.."
supabase db lint --db-url "$DB_URL" --schema public,sync --level warning
