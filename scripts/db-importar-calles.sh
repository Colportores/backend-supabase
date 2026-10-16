#!/usr/bin/env bash
# Importa las calles de OpenStreetMap de UNA ciudad del catálogo (backend-supabase#25, ADR-018).
#
#   DB_URL=postgresql://… scripts/db-importar-calles.sh <ciudad_id> <archivo.json> [fuente]
#
# <archivo.json> es una respuesta de Overpass con geometría de las vías (`[out:json]`, `out body geom;`);
# docs/calles-ruteo.md explica cómo conseguirla y qué tipos de calle conviene pedir. Este script NO
# descarga nada: solo lee el archivo, se lo pasa a ruteo.cargar_red() y deja la red lista.
#
# Reimportar la misma ciudad REEMPLAZA su red entera, en una sola transacción: si el archivo no sirve
# (sin calles, sin cruces, no es de Overpass) falla y la red que había queda como estaba. Las zonas ya
# guardadas no cambian. Se puede correr las veces que haga falta (por ejemplo, para actualizar las calles).
#
# [fuente] es una nota libre para saber de dónde salió la red (por defecto, el nombre del archivo y la
# fecha de hoy). Queda en ruteo.red.fuente.
#
# Sirve para la base local (compose.dev.yml) y para la nube: DB_URL decide dónde. Contra la nube, usar
# la cadena de conexión directa del proyecto (puerto 5432, no el pooler en modo transacción): la carga
# de una ciudad grande tarda más que el timeout de las consultas del pooler.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Uso: DB_URL=… $0 <ciudad_id> <archivo.json> [fuente]" >&2
  exit 2
fi

CIUDAD_ID="$1"
ARCHIVO="$2"
FUENTE="${3:-$(basename "$ARCHIVO") · $(date +%Y-%m-%d)}"

if ! [[ "$CIUDAD_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  echo "ciudad_id no es un uuid: $CIUDAD_ID" >&2
  exit 2
fi
if [ ! -s "$ARCHIVO" ]; then
  echo "No existe o está vacío: $ARCHIVO" >&2
  exit 2
fi

cd "$(dirname "$0")/.."

# El archivo entra a psql como variable (:'osm'), leído por el shell: nada del archivo pasa por la
# línea de comandos ni se interpreta como SQL.
export OSM_ARCHIVO="$ARCHIVO"

psql "$DB_URL" -v ON_ERROR_STOP=1 -v ciudad="$CIUDAD_ID" -v fuente="$FUENTE" <<'SQL'
\set osm `cat "$OSM_ARCHIVO"`
set statement_timeout = 0;
select jsonb_pretty(ruteo.cargar_red(:'ciudad'::uuid, :'osm'::jsonb, :'fuente')) as resumen;
-- Los índices y las estadísticas, al día para que el planificador use el GiST de los cruces.
analyze ruteo.nodo, ruteo.tramo;
SQL
