#!/usr/bin/env bash
# Corre los tests de supabase/tests contra $DB_URL: primero los pgTAP (.sql) y después
# los de shell (.sh). Requiere migraciones aplicadas.
# pg_prove no entiende URIs con query string, así que se conecta con las variables PG*
# (compose.dev.yml las define) y solo psql usa DB_URL.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

cd "$(dirname "$0")/.."
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c 'create extension if not exists pgtap with schema extensions;'
pg_prove --ext .sql --recurse --verbose supabase/tests

# Lo que pg_prove no puede probar: dos transacciones cruzadas necesitan dos
# conexiones vivas a la vez, y pg_prove corre cada archivo en una sola.
for t in supabase/tests/*.sh; do
  bash "$t"
done
