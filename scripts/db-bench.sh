#!/usr/bin/env bash
# Carga sintética + medición del delta. Ver supabase/bench/README.md.
#
# NO lo corre CI: tarda minutos y deja ~420.000 filas en la base. Es una
# herramienta de diagnóstico, se corre a mano cuando se toca el delta, los
# índices o una política RLS que el delta atraviese.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"
COLPORTORES="${COLPORTORES:-150}"
CIUDADES_AJENAS="${CIUDADES_AJENAS:-4}"

cd "$(dirname "$0")/.."

echo "== carga (${COLPORTORES} colportores, ${CIUDADES_AJENAS} ciudades ajenas) =="
time psql "$DB_URL" -v ON_ERROR_STOP=1 -q -v colportores="$COLPORTORES" -v ciudades_ajenas="$CIUDADES_AJENAS" -f supabase/bench/carga.sql

echo
echo "== medición =="
psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/bench/medir.sql
