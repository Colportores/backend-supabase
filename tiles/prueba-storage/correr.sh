#!/usr/bin/env bash
# Prueba el bucket `mapas` y el publicador contra un Storage DE VERDAD, en Docker, sin credenciales ni
# proyecto en la nube. Es lo que CI no hace (la base de CI no trae el servicio Storage):
#
#   1. levanta la base de compose.dev.yml + el storage-api oficial + un gateway que imita a Kong;
#   2. aplica las migraciones (la 0029 crea el bucket) y corre pgTAP 0036, con las aserciones completas;
#   3. publica el estilo y Montevideo (recorte REAL del build más nuevo de Protomaps: necesita red);
#   4. verifica el bucket (cli verificar), publica de nuevo (tiene que dar «sin cambios») y comprueba
#      que con la clave anónima no se puede escribir.
#
# Uso, desde la raíz del repo:   bash tiles/prueba-storage/correr.sh
# Variables: PROYECTO (compose, por defecto tiles-storage), DB_PORT (55452), CIUDAD (montevideo),
#            DEJAR_ARRIBA=1 (no apagar al terminar, para mirar con curl; el gateway queda en :8000 dentro de la red).
#
# Baja, la primera vez: public.ecr.aws/supabase/storage-api (~1,4 GB) y node:22-bookworm (~1,6 GB; la
# variante slim no trae los certificados que `pmtiles` necesita para leer build.protomaps.com).
# Nunca construye imágenes.
set -euo pipefail

cd "$(dirname "$0")/../.."
RAIZ="$(pwd -W 2>/dev/null || pwd)"
export MSYS_NO_PATHCONV=1
export DB_PORT="${DB_PORT:-55452}"

P="${PROYECTO:-tiles-storage}"
RED="${P}_default"
CIUDAD="${CIUDAD:-montevideo}"
STORAGE_IMAGEN="public.ecr.aws/supabase/storage-api:v1.61.10"
NODE_IMAGEN="node:22-bookworm"
SECRETO="super-secret-jwt-token-with-at-least-32-characters-long"
C=(docker compose -p "$P" -f compose.dev.yml)
PRUEBA="$RAIZ/tiles/prueba-storage"

limpiar() {
  docker rm -f "$P-storage" "$P-gateway" >/dev/null 2>&1 || true
  "${C[@]}" down -v >/dev/null 2>&1 || true
}
if [ "${DEJAR_ARRIBA:-0}" != "1" ]; then trap limpiar EXIT; fi
limpiar

paso() { printf '\n=== %s\n' "$1"; }

paso "base de datos"
"${C[@]}" up -d --wait db

# La imagen de la base trae el rol de Storage sin clave: el storage-api necesita entrar con una.
"${C[@]}" exec -T db psql -U supabase_admin -d postgres -q -c "alter role supabase_storage_admin with login password 'postgres'"

read -r ANON SERVICIO < <(docker run --rm -v "$PRUEBA:/p:ro" node:22-bookworm-slim node /p/jwt.mjs "$SECRETO")

paso "storage-api y gateway"
docker run -d --name "$P-storage" --network "$RED" --network-alias storage \
  -e SERVER_PORT=5000 \
  -e AUTH_JWT_SECRET="$SECRETO" -e PGRST_JWT_SECRET="$SECRETO" \
  -e ANON_KEY="$ANON" -e SERVICE_KEY="$SERVICIO" \
  -e DATABASE_URL="postgres://supabase_storage_admin:postgres@db:5432/postgres" \
  -e DB_INSTALL_ROLES=false \
  -e STORAGE_BACKEND=file -e FILE_STORAGE_BACKEND_PATH=/var/lib/storage \
  -e TENANT_ID=stub -e REGION=stub -e GLOBAL_S3_BUCKET=stub -e STORAGE_S3_REGION=stub \
  -e FILE_SIZE_LIMIT=52428800 \
  -e ENABLE_IMAGE_TRANSFORMATION=false \
  -e POSTGREST_URL=http://stub:3000 \
  "$STORAGE_IMAGEN" >/dev/null
docker run -d --name "$P-gateway" --network "$RED" -v "$PRUEBA:/p:ro" node:22-bookworm-slim node /p/gateway.mjs >/dev/null

for intento in $(seq 1 40); do
  if docker run --rm --network "$RED" node:22-bookworm-slim node -e \
    "fetch('http://storage:5000/status').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    echo "storage-api listo (intento $intento)"
    break
  fi
  if [ "$intento" = 40 ]; then docker logs --tail 40 "$P-storage"; echo "FALLO: storage-api no contesta"; exit 1; fi
  sleep 3
done

paso "migraciones (la 0029 crea el bucket) y pgTAP 0036"
"${C[@]}" run --rm cli bash scripts/db-migrate.sh | grep -E "0029|ERROR" || true
"${C[@]}" run --rm cli bash -c \
  'psql "$DB_URL" -q -c "create extension if not exists pgtap with schema extensions;" && pg_prove --ext .sql --verbose supabase/tests/0036_bucket_mapas_test.sql'

NODO=(docker run --rm --network "$RED" -v "$RAIZ:/repo" -w /repo/tiles
  -e SUPABASE_URL="http://$P-gateway:8000" -e SUPABASE_SERVICE_ROLE_KEY="$SERVICIO" -e ANON_KEY="$ANON"
  -e HOME=/tmp)
if [ "$(uname -s)" = "Linux" ]; then NODO+=(--user "$(id -u):$(id -g)"); fi
NODO+=("$NODE_IMAGEN")
PUBLICA="http://$P-gateway:8000/storage/v1/object/public/mapas"

paso "pruebas unitarias"
"${NODO[@]}" bash -c 'npm ci --no-audit --no-fund >/dev/null && npm test' | grep -E "^# (tests|pass|fail)|^not ok"

paso "publicar estilo y $CIUDAD"
"${NODO[@]}" node src/cli.mjs publicar --ciudad "$CIUDAD"

paso "verificar lo que ve un navegador"
"${NODO[@]}" node src/cli.mjs verificar

paso "publicar otra vez: no tiene que subir nada"
SEGUNDA="$("${NODO[@]}" node src/cli.mjs publicar --solo ciudades --ciudad "$CIUDAD")"
echo "$SEGUNDA"
grep -q "sin cambios" <<<"$SEGUNDA" || { echo "FALLO: la segunda publicación subió algo"; exit 1; }

paso "con la clave anónima no se escribe"
"${NODO[@]}" node prueba-storage/acceso-anonimo.mjs "$PUBLICA"

printf '\nTodo bien.\n'
