#!/usr/bin/env bash
# Corre los tests pgTAP de supabase/tests contra $DB_URL. Requiere migraciones aplicadas.
# pg_prove no entiende URIs con query string, así que se conecta con las variables PG*
# (compose.dev.yml las define) y solo psql usa DB_URL.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

cd "$(dirname "$0")/.."
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c 'create extension if not exists pgtap with schema extensions;'
pg_prove --ext .sql --recurse --verbose supabase/tests
