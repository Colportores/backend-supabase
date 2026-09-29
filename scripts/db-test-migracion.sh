#!/usr/bin/env bash
# Prueba las migraciones que mueven datos, con datos. db-test.sh corre sobre una base recién
# migrada y vacía, así que ahí una migración de datos no mueve nada; acá sí.
#
# Cada caso vive en supabase/tests_migracion/<caso>/ (fuera de supabase/tests: pg_prove
# --recurse no lo levanta):
#   version_previa  timestamp de la última migración que se aplica ANTES de cargar los datos
#   datos.sql       filas con el esquema de esa versión
#   test.sql        pgTAP sobre el resultado, si la migración tiene que pasar
#   aborta.txt      si tiene que abortar: cada línea tiene que aparecer en el error
#
# Por caso: limpia la base, aplica las migraciones hasta version_previa, carga datos.sql,
# aplica el resto (cada archivo en una transacción, como `supabase migration up`) y verifica.
# Al final deja la base como db-reset.sh. Solo para la base local de compose.dev.yml.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

case "$DB_URL" in
  *supabase.co*|*supabase.com*|*pooler*) echo "db-test-migracion.sh es solo para la base local" >&2; exit 1 ;;
esac

cd "$(dirname "$0")/.."

# Sin los NOTICE del `drop schema … cascade` de cada limpieza.
export PGOPTIONS="-c client_min_messages=warning"

fallas=0

for caso in supabase/tests_migracion/*/; do
  caso="${caso%/}"
  nombre="$(basename "$caso")"
  previa="$(tr -d '[:space:]' < "$caso/version_previa")"
  echo "== $nombre (datos después de $previa)"

  DB_RESET_SIN_MIGRAR=1 bash scripts/db-reset.sh

  resto=()
  for m in supabase/migrations/*.sql; do
    version="$(basename "$m" | cut -d_ -f1)"
    if [[ "$version" > "$previa" ]]; then
      resto+=("$m")
    else
      psql "$DB_URL" -v ON_ERROR_STOP=1 -q -1 -f "$m" > /dev/null
    fi
  done

  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -1 -f "$caso/datos.sql" > /dev/null

  salida=""
  estado=0
  for m in "${resto[@]}"; do
    if ! salida+="$(psql "$DB_URL" -v ON_ERROR_STOP=1 -q -1 -f "$m" 2>&1)"$'\n'; then
      estado=1
      break
    fi
  done

  if [ -f "$caso/aborta.txt" ]; then
    if [ "$estado" -eq 0 ]; then
      echo "   FALLA: la migración tenía que abortar y se aplicó"; fallas=$((fallas + 1)); continue
    fi
    while IFS= read -r esperado || [ -n "$esperado" ]; do
      esperado="${esperado%$'\r'}"   # un checkout en Windows puede dejar CRLF
      [ -z "$esperado" ] && continue
      if ! grep -qF -- "$esperado" <<< "$salida"; then
        echo "   FALLA: el error no dice: $esperado"; fallas=$((fallas + 1))
      fi
    done < "$caso/aborta.txt"
    echo "   abortó como se esperaba"
  else
    if [ "$estado" -ne 0 ]; then
      echo "   FALLA: la migración no se aplicó:"; echo "$salida" | tail -n 20; fallas=$((fallas + 1)); continue
    fi
    psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c 'create extension if not exists pgtap with schema extensions;'
    if ! pg_prove --ext .sql --verbose "$caso/test.sql"; then
      fallas=$((fallas + 1))
    fi
  fi
done

echo "== base de vuelta al estado de db-reset.sh"
bash scripts/db-reset.sh > /dev/null

if [ "$fallas" -gt 0 ]; then
  echo "db-test-migracion: $fallas falla(s)" >&2
  exit 1
fi
echo "db-test-migracion: OK"
