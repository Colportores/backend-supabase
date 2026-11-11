#!/usr/bin/env bash
# Carga, chequea o retira los DATOS DE DEMO simulados (supabase/seed-demo/). Distinto de scripts/db-seed.sh, que
# aplica supabase/seed.sql solo a la base local.
#
#   scripts/db-seed-demo.sh                 carga la demo en la base LOCAL ($DB_URL)
#   scripts/db-seed-demo.sh --chequeo       conteos por tabla y coherencia (solo lectura), base local
#   scripts/db-seed-demo.sh --retirar       vista previa del retiro (no cambia nada); con --aplicar lo hace de verdad
#   scripts/db-seed-demo.sh --coordinador   suma a coordinador.demo como coordinador de las campañas de la demo
#                                           (solo agrega; sin esa cuenta no hace nada). Ver supabase/seed-demo/README.md
#   scripts/db-seed-demo.sh --fechas        vista previa de la corrección de la fecha de alta de las inscripciones de una
#                                           demo cargada antes del 11/11; con --aplicar lo hace de verdad
#   scripts/db-seed-demo.sh --remoto <modo> lo mismo contra el proyecto de DEMO ohdsavwpasfpapbyutrv, con el CLI de
#                                           Supabase ya logueado (o SUPABASE_ACCESS_TOKEN en el entorno)
#
# Reglas que este script hace cumplir:
#   · Nunca `db reset`, nunca borra ni trunca: la carga solo inserta (idempotente) y el retiro da de baja lógica.
#   · Remoto: la única base que acepta es ohdsavwpasfpapbyutrv (guarda por project-ref; no hay forma de pasarle otra).
#     El proyecto viejo (isygm…) y cualquier otro se rechazan.
#   · Local: rechaza cualquier $DB_URL que parezca de Supabase (supabase.co, supabase.com, pooler).
#   · Contraseña de los usuarios de la demo: solo en local y solo si viene en la variable DEMO_PASSWORD (se lee con
#     \getenv de psql, no pasa por la línea de comandos ni se escribe en ningún archivo). En remoto no se aplica: la
#     contraseña se pone desde Supabase Studio (Authentication) si hace falta entrar con esos usuarios.
set -euo pipefail

REF_DEMO="ohdsavwpasfpapbyutrv"
cd "$(dirname "$0")/.."
DIR="supabase/seed-demo"

remoto=0; modo="cargar"; aplicar=0
for a in "$@"; do
  case "$a" in
    --remoto) remoto=1 ;;
    --chequeo) modo="chequeo" ;;
    --retirar) modo="retirar" ;;
    --coordinador) modo="coordinador" ;;
    --fechas) modo="fechas" ;;
    --aplicar) aplicar=1 ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "Argumento desconocido: $a (ver --help)" >&2; exit 2 ;;
  esac
done
if [ "$aplicar" = 1 ] && [ "$modo" != "retirar" ] && [ "$modo" != "fechas" ]; then
  echo "--aplicar solo va con --retirar o --fechas" >&2; exit 2
fi

case "$modo" in
  cargar)  archivo="$DIR/demo-datos.sql" ;;
  chequeo) archivo="$DIR/chequeo-demo.sql" ;;
  retirar) archivo="$DIR/retirar-demo-datos.sql" ;;
  coordinador) archivo="$DIR/sumar-coordinador-demo.sql" ;;
  fechas)  archivo="$DIR/corregir-fechas-de-alta-demo.sql" ;;
esac

# Para --aplicar se arma una copia temporal con la confirmación activa dentro del propio DO (el original queda en vista
# previa). No depende de la transacción: psql -f confirma cada sentencia por separado.
if [ "$aplicar" = 1 ]; then
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  marca="retiro"; [ "$modo" = "fechas" ] && marca="fechas"
  sed "s/v_aplicar boolean := false;  -- $marca:aplicar/v_aplicar boolean := true;  -- $marca:aplicar/" "$archivo" > "$tmp"
  grep -q "v_aplicar boolean := true;  -- $marca:aplicar" "$tmp" || { echo "No se pudo activar --aplicar en $archivo" >&2; exit 1; }
  archivo="$tmp"
fi

if [ "$remoto" = 1 ]; then
  command -v supabase >/dev/null || { echo "Falta el CLI de Supabase (supabase)" >&2; exit 1; }
  if [ -n "${DEMO_PASSWORD:-}" ]; then
    echo "DEMO_PASSWORD no se aplica en remoto (la contraseña no se manda por la API): ponela desde Supabase Studio." >&2
  fi
  echo "Proyecto de demo: $REF_DEMO — $modo$([ "$aplicar" = 1 ] && echo ' (APLICAR)')" >&2
  # Sin exec: así el trap borra la copia temporal de --aplicar al terminar.
  supabase db query --linked --project-ref "$REF_DEMO" -o table -f "$archivo"
  exit $?
fi

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db) o usar --remoto}"
case "$DB_URL" in
  *supabase.co*|*supabase.com*|*pooler*) echo "Sin --remoto, este script es solo para la base local" >&2; exit 1 ;;
esac

psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$archivo"

if [ "$modo" = "cargar" ] && [ -n "${DEMO_PASSWORD:-}" ]; then
  export DEMO_PASSWORD
  psql "$DB_URL" -v ON_ERROR_STOP=1 <<'SQL'
\getenv pw DEMO_PASSWORD
update auth.users set encrypted_password = crypt(:'pw', gen_salt('bf'))
 where id::text like '5eed0000-0000-7000-8%';
SQL
fi
