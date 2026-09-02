#!/usr/bin/env bash
# Levanta un Postgres descartable, aplica las migraciones y corre los tests.
# No toca ninguna base existente: el contenedor se borra al terminar.
#
#   ./run-tests.sh
set -euo pipefail

CONTENEDOR=colportaje-sync-test-$$
IMAGEN=postgres:16-alpine

limpiar() { docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true; }
trap limpiar EXIT

docker run -d --rm --name "$CONTENEDOR" \
  -e POSTGRES_PASSWORD=test -e POSTGRES_DB=colportaje \
  "$IMAGEN" >/dev/null

# `pg_isready` dice que sí durante el arranque interno de initdb, cuando la base
# todavía no existe. Esperar una consulta de verdad es lo único confiable.
for _ in $(seq 1 60); do
  docker exec "$CONTENEDOR" psql -U postgres -d colportaje -c 'select 1' \
    >/dev/null 2>&1 && break
  sleep 1
done

psql_() { docker exec -i "$CONTENEDOR" psql -U postgres -d colportaje -v ON_ERROR_STOP=1 -q "$@"; }

for f in migrations/*.sql; do
  echo "migración  $(basename "$f")"
  psql_ < "$f"
done

echo
for t in test/*_test.sql; do
  # Los NOTICE son los OK; todo lo demás —errores incluidos— tiene que salir a
  # la vista. Filtrarlo todo con un sed escondía los fallos.
  psql_ -f - < "$t" 2>&1 | sed -e 's/^psql:[^ ]* //' -e 's/^NOTICE:  //'
done
# Los tests de dos conexiones van en shell: necesitan una sesión abierta y en
# vuelo mientras otra escribe, y eso no se puede montar dentro de un solo .sql.
for t in test/*.sh; do
  echo
  "$t" "$CONTENEDOR"
done

echo
echo "todos los tests pasaron"
