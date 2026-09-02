#!/usr/bin/env bash
# Carga 420.000 filas y mide el delta, el push y el crecimiento del cache.
# Tarda ~1 minuto. No toca ninguna base existente.
#
#   ./bench/correr.sh
set -euo pipefail

CONTENEDOR=colportaje-bench-$$
limpiar() { docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true; }
trap limpiar EXIT

docker run -d --rm --name "$CONTENEDOR" \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=colportaje postgres:16-alpine >/dev/null

for _ in $(seq 1 60); do
  docker exec "$CONTENEDOR" psql -U postgres -d colportaje -c 'select 1' \
    >/dev/null 2>&1 && break
  sleep 1
done

psql_() { docker exec -i "$CONTENEDOR" psql -U postgres -d colportaje "$@"; }

# Sin `|| true`: un error de migración tiene que frenar el bench, no dejarlo
# medir un esquema a medio aplicar. Solo se silencia la salida normal.
for f in migrations/*.sql; do psql_ -v ON_ERROR_STOP=1 -q < "$f" >/dev/null; done
echo "migraciones aplicadas"

psql_ -q < bench/carga.sql
psql_ < bench/medir.sql
