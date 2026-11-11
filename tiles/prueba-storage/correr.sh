#!/usr/bin/env bash
# Prueba el bucket `mapas` y el publicador contra un Storage DE VERDAD, en Docker, sin credenciales ni
# proyecto en la nube. La base del job `migraciones` de CI no trae el servicio Storage (la 0029 y pgTAP 0036 se
# saltean ahí); por eso CI corre este script con SOLO_BASE=1 en su job `storage` (backend-supabase#75), y falla
# si la 0029 o la 0036 se saltean. Entero, se corre a mano:
#
#   1. levanta la base de compose.dev.yml + el storage-api oficial + PostgREST + un gateway que imita a Kong;
#   2. aplica las migraciones (la 0029 crea el bucket) y corre los pgTAP que dependen de Storage (hoy la 0036),
#      con las aserciones completas;
#   3. carga Montevideo en public.ciudad con el bloque de docs/guia-carga-manual.md (el mismo que pega
#      Cristian: lo extrae de la guía, no tiene copia); comprueba que sin su rectángulo el publicador no
#      publica nada ni sube nada; publica el estilo y Montevideo (recorte REAL del build más nuevo de
#      Protomaps: necesita red) y comprueba que el ambito_id del catálogo es el id de la ciudad en la base;
#   4. verifica el bucket (cli verificar), comprueba que el publicador lee por el endpoint autenticado,
#      publica de nuevo (tiene que dar «sin cambios») y comprueba que con la clave anónima no se puede
#      escribir ni listar;
#   5. crea una zona (en una campaña vigente), publica su paquete (recorte REAL por su polígono), comprueba
#      que el enlace queda en public.zona.paquete_mapa, que el archivo está en el bucket con el mismo SHA-256,
#      que el catálogo público no lo nombra y que publicar otra vez no cambia nada.
#
# Uso, desde la raíz del repo:   bash tiles/prueba-storage/correr.sh
# Variables: PROYECTO (compose, por defecto tiles-storage), DB_PORT (55452), CIUDAD (montevideo),
#            DEJAR_ARRIBA=1 (no apagar al terminar, para mirar con curl; el gateway queda en :8000 dentro de la red),
#            SOLO_BASE=1 (parar después del paso 2: la base, el Storage y los pgTAP de Storage; sin red, sin recorte y sin
#            cargar ciudades; es lo que corre el job `storage` de CI).
# Si la 0029 no creó el bucket o algún pgTAP de Storage se saltea, el script FALLA (no es un aviso): pgTAP corre con
# EXIGIR_STORAGE=1 (ver supabase/tests/0036_bucket_mapas_test.sql). Corre TODOS los pgTAP de supabase/tests que
# nombran `hay_storage` o las tablas de storage (storage.buckets / storage.objects): una prueba nueva que dependa del
# servicio entra sola, y se saltea (a la vista) en el job `migraciones`, que no tiene Storage.
#
# Baja, la primera vez: storage-api (~1,4 GB) y node:22-bookworm (~1,6 GB; la variante slim no trae los
# certificados que `pmtiles` necesita para leer build.protomaps.com; con SOLO_BASE=1 no hace falta). Nunca
# construye imágenes: necesita la `backend-supabase-dev:latest` de compose.dev.yml (`docker compose -f compose.dev.yml
# build cli`, lo que hace CI antes).
set -euo pipefail

cd "$(dirname "$0")/../.."
RAIZ="$(pwd -W 2>/dev/null || pwd)"
export MSYS_NO_PATHCONV=1
export DB_PORT="${DB_PORT:-55452}"

P="${PROYECTO:-tiles-storage}"
RED="${P}_default"
CIUDAD="${CIUDAD:-montevideo}"
# ghcr.io y no public.ecr.aws: mismo tag y mismo digest (storage-api sha256:ff78c60e..., postgrest sha256:bb289d00...
# en linux/amd64), pero sin el límite de pulls anónimos que rompía CI (#27; ver compose.dev.yml). Si cambiás un tag,
# cambiá también su fila en scripts/ci-imagenes.txt (scripts/check-ci-imagenes.sh lo comprueba).
STORAGE_IMAGEN="ghcr.io/supabase/storage-api:v1.61.10"
REST_IMAGEN="ghcr.io/supabase/postgrest:v14.5"
NODE_IMAGEN="node:22-bookworm"
SECRETO="super-secret-jwt-token-with-at-least-32-characters-long"
C=(docker compose -p "$P" -f compose.dev.yml)
PRUEBA="$RAIZ/tiles/prueba-storage"

limpiar() {
  docker rm -f "$P-storage" "$P-rest" "$P-gateway" >/dev/null 2>&1 || true
  "${C[@]}" down -v >/dev/null 2>&1 || true
}
if [ "${DEJAR_ARRIBA:-0}" != "1" ]; then trap limpiar EXIT; fi
limpiar

paso() { printf '\n=== %s\n' "$1"; }

paso "base de datos"
"${C[@]}" up -d --wait db
psql_db() { "${C[@]}" exec -T db psql -U supabase_admin -d postgres -At -v ON_ERROR_STOP=1 "$@"; }

# La imagen de la base trae los roles de Storage y de PostgREST sin clave: sus servicios necesitan entrar con una.
"${C[@]}" exec -T db psql -U supabase_admin -d postgres -q \
  -c "alter role supabase_storage_admin with login password 'postgres'" \
  -c "alter role authenticator with login password 'postgres'"

paso "imágenes"
# Un registro que contesta mal (un TLS handshake timeout o un `toomanyrequests` de ghcr.io) no tiene que tirar la
# prueba: ci-pull.sh prueba los espejos de scripts/ci-imagenes.txt, por digest, y reintenta con espera creciente.
# Lo que ya está en Docker (en CI, lo que dejó la caché) no se baja. Solo el pull se reintenta, nunca las pruebas.
bash "$RAIZ/scripts/ci-pull.sh" "$STORAGE_IMAGEN" "$REST_IMAGEN" node:22-bookworm-slim

read -r ANON SERVICIO < <(docker run --rm -v "$PRUEBA:/p:ro" node:22-bookworm-slim node /p/jwt.mjs "$SECRETO")

paso "storage-api, PostgREST y gateway"
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
docker run -d --name "$P-rest" --network "$RED" --network-alias rest \
  -e PGRST_DB_URI="postgres://authenticator:postgres@db:5432/postgres" \
  -e PGRST_DB_SCHEMAS=public -e PGRST_DB_ANON_ROLE=anon -e PGRST_JWT_SECRET="$SECRETO" \
  -e PGRST_SERVER_PORT=3000 \
  "$REST_IMAGEN" >/dev/null
docker run -d --name "$P-gateway" --network "$RED" -v "$PRUEBA:/p:ro" node:22-bookworm-slim node /p/gateway.mjs >/dev/null

for intento in $(seq 1 40); do
  if docker run --rm --network "$RED" -e ANON_KEY="$ANON" node:22-bookworm-slim node -e \
    "Promise.all([fetch('http://storage:5000/status'), fetch('http://rest:3000/', { headers: { apikey: process.env.ANON_KEY } })]).then(rs=>process.exit(rs.every(r=>r.ok)?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    echo "storage-api y PostgREST listos (intento $intento)"
    break
  fi
  if [ "$intento" = 40 ]; then docker logs --tail 40 "$P-storage"; docker logs --tail 40 "$P-rest"; echo "FALLO: storage-api o PostgREST no contestan"; exit 1; fi
  sleep 3
done

# storage-api crea sus tablas (storage.buckets, storage.objects) al arrancar, y contesta /status antes o después de
# terminar según la versión. La 0029 se saltea sin avisar si todavía no existen: se espera a que estén, y si no
# aparecen se falla, en vez de migrar y dejar que el bucket falte.
paso "las tablas de Storage"
for intento in $(seq 1 40); do
  if [ "$(psql_db -c "select to_regclass('storage.buckets') is not null and to_regclass('storage.objects') is not null")" = "t" ]; then
    echo "storage.buckets y storage.objects existen (intento $intento)"
    break
  fi
  if [ "$intento" = 40 ]; then docker logs --tail 40 "$P-storage"; echo "FALLO: storage-api no creó sus tablas en la base"; exit 1; fi
  sleep 3
done

paso "migraciones (la 0029 crea el bucket) y pgTAP de Storage"
if ! SALIDA_MIGRACIONES="$("${C[@]}" run --rm -T cli bash scripts/db-migrate.sh 2>&1)"; then
  printf '%s\n' "$SALIDA_MIGRACIONES" | tail -40
  echo "FALLO: las migraciones no se aplicaron"
  exit 1
fi
printf '%s\n' "$SALIDA_MIGRACIONES" | grep -E "0029|ERROR" || true
# El CLI no muestra los avisos de la 0029 (RAISE NOTICE): lo que dice si corrió es el bucket.
[ "$(psql_db -c "select count(*) from storage.buckets where id = 'mapas'")" = "1" ] \
  || { echo "FALLO: la 0029 no creó el bucket mapas (se salteó: la base no tenía las tablas de Storage al migrar)"; exit 1; }
echo "la 0029 creó el bucket mapas"

# Todos los pgTAP que dependen del servicio Storage: los que nombran `hay_storage` (el guard \if de la 0036) o las tablas
# de storage. Una prueba nueva de este tipo entra acá sin tocar el script; en el job `migraciones` (sin Storage) se
# saltea a la vista.
TESTS_STORAGE="$(grep -lE 'hay_storage|storage\.(buckets|objects)' supabase/tests/*.sql | sort | tr '\n' ' ')"
[ -n "${TESTS_STORAGE// /}" ] || { echo "FALLO: no encuentro ningún pgTAP de Storage en supabase/tests"; exit 1; }
echo "pgTAP de Storage: $TESTS_STORAGE"
# EXIGIR_STORAGE=1: sin Storage la prueba FALLA en vez de saltearse. Y si igual algún test sale como SKIP, también.
# `-e` y no una variable puesta delante del comando: por Docker, esa no entra al contenedor.
# shellcheck disable=SC2086  # la lista son rutas del repo, sin espacios
if ! SALIDA_PGTAP="$("${C[@]}" run --rm -T -e EXIGIR_STORAGE=1 cli bash -c \
  'psql "$DB_URL" -q -c "create extension if not exists pgtap with schema extensions;" && pg_prove --ext .sql --verbose "$@"' _ \
  $TESTS_STORAGE 2>&1)"; then
  printf '%s\n' "$SALIDA_PGTAP"
  echo "FALLO: algún pgTAP de Storage no pasó"
  exit 1
fi
printf '%s\n' "$SALIDA_PGTAP"
if grep -qiE "# SKIP|skipped" <<<"$SALIDA_PGTAP"; then echo "FALLO: algún pgTAP de Storage se salteó pruebas contra un Storage real"; exit 1; fi
[ "$(grep -cE '^ok [0-9]+ - ' <<<"$SALIDA_PGTAP")" -ge 1 ] || { echo "FALLO: los pgTAP de Storage no corrieron ninguna prueba"; exit 1; }

# SOLO_BASE=1 para acá: la base, el Storage y los pgTAP de Storage (lo que corre el job `storage` de CI). Lo de abajo
# necesita red y carga la ciudad.
if [ "${SOLO_BASE:-0}" = "1" ]; then
  echo "Base y Storage listos (SOLO_BASE=1): migraciones y pgTAP de Storage pasaron."
  exit 0
fi

# Lo que el proyecto real ya tiene antes de la primera publicación: el país UY (§ 1 de la guía de carga manual).
# Montevideo, con su rectángulo, se carga después con el bloque de la guía (§ 2).
psql_db -c "insert into public.pais (nombre, iso_code) select 'Uruguay', 'UY' where not exists (select 1 from public.pais where iso_code = 'UY')" >/dev/null

# El bloque de Montevideo de la guía: el primer ```sql que sigue a su título (sin copia, para que no se desfasen).
bloque_de_la_guia() {
  awk '/^#### Montevideo, lista para pegar/ { buscando = 1; next }
       buscando && /^```sql/ { dentro = 1; next }
       dentro && /^```/ { exit }
       dentro { sub(/\r$/, ""); print }' docs/guia-carga-manual.md
}
BLOQUE="$(bloque_de_la_guia)"
[ -n "$BLOQUE" ] || { echo "FALLO: no encuentro el bloque de Montevideo en docs/guia-carga-manual.md"; exit 1; }
paso "Montevideo con su rectángulo, con el bloque de la guía de carga manual"
for vez in 1 2; do
  printf '%s\n' "$BLOQUE" | "${C[@]}" exec -T db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -q -At >/dev/null
  echo "bloque aplicado (vez $vez)"
done
[ "$(psql_db -c "select count(*) from public.ciudad where nombre = 'Montevideo' and deleted_at is null")" = "1" ] \
  || { echo "FALLO: repetir el bloque tiene que dejar UNA sola Montevideo"; exit 1; }
AMBITO_ESPERADO="$(psql_db -c "select c.id from public.ciudad c join public.pais p on p.id = c.pais_id where p.iso_code = 'UY' and c.nombre = 'Montevideo' and c.bbox_oeste is not null")"
[ -n "$AMBITO_ESPERADO" ] || { echo "FALLO: Montevideo quedó sin rectángulo"; exit 1; }
echo "Montevideo en public.ciudad: $AMBITO_ESPERADO"

NODO=(docker run --rm --network "$RED" -v "$RAIZ:/repo" -w /repo/tiles
  -e SUPABASE_URL="http://$P-gateway:8000" -e SUPABASE_SERVICE_ROLE_KEY="$SERVICIO" -e ANON_KEY="$ANON"
  -e AMBITO_ESPERADO="$AMBITO_ESPERADO" -e ZONA -e HOME=/tmp)
if [ "$(uname -s)" = "Linux" ]; then NODO+=(--user "$(id -u):$(id -g)"); fi
NODO+=("$NODE_IMAGEN")
PUBLICA="http://$P-gateway:8000/storage/v1/object/public/mapas"

paso "pruebas unitarias"
"${NODO[@]}" bash -c 'npm ci --no-audit --no-fund >/dev/null && npm test' | grep -E "^# (tests|pass|fail)|^not ok"

paso "sin su rectángulo la ciudad no se publica y el publicador no sube nada"
RECTANGULO="$(psql_db -c "select bbox_oeste || ',' || bbox_sur || ',' || bbox_este || ',' || bbox_norte from public.ciudad where id = '$AMBITO_ESPERADO'")"
psql_db -c "update public.ciudad set bbox_oeste = null, bbox_sur = null, bbox_este = null, bbox_norte = null where id = '$AMBITO_ESPERADO'" >/dev/null
SALIDA_SIN="$("${NODO[@]}" node src/cli.mjs publicar --ciudad "$CIUDAD" 2>&1 || true)"
echo "$SALIDA_SIN"
grep -q "ciudades sin rectángulo.*Montevideo" <<<"$SALIDA_SIN" || { echo "FALLO: tenía que listar a Montevideo como ciudad sin rectángulo"; exit 1; }
grep -q "Ninguna ciudad con rectángulo coincide" <<<"$SALIDA_SIN" || { echo "FALLO: tenía que detenerse por la ciudad que no tiene rectángulo"; exit 1; }
SUBIDOS="$(psql_db -c "select count(*) from storage.objects where bucket_id = 'mapas'")"
[ "$SUBIDOS" = "0" ] || { echo "FALLO: se subieron $SUBIDOS archivos antes de resolver la ciudad"; exit 1; }
IFS=, read -r OESTE SUR ESTE NORTE <<<"$RECTANGULO"
psql_db -c "update public.ciudad set bbox_oeste = $OESTE, bbox_sur = $SUR, bbox_este = $ESTE, bbox_norte = $NORTE where id = '$AMBITO_ESPERADO'" >/dev/null

paso "publicar el estilo y las ciudades con rectángulo (los dos comandos de la guía «Publicar a mano»)"
"${NODO[@]}" node src/cli.mjs publicar --solo estilo
"${NODO[@]}" node src/cli.mjs publicar --solo ciudades

paso "el catálogo trae el ambito_id de la ciudad en la base y la versión del estilo"
"${NODO[@]}" node prueba-storage/ambito-del-catalogo.mjs "$PUBLICA"

paso "verificar lo que ve un navegador"
"${NODO[@]}" node src/cli.mjs verificar

paso "el publicador lee por el endpoint autenticado"
"${NODO[@]}" node prueba-storage/lectura-autenticada.mjs

paso "publicar otra vez: no tiene que subir nada"
SEGUNDA="$("${NODO[@]}" node src/cli.mjs publicar --solo ciudades --ciudad "$CIUDAD")"
echo "$SEGUNDA"
grep -q "sin cambios" <<<"$SEGUNDA" || { echo "FALLO: la segunda publicación subió algo"; exit 1; }

paso "con la clave anónima no se escribe"
"${NODO[@]}" node prueba-storage/acceso-anonimo.mjs "$PUBLICA"

paso "una zona: su paquete se publica fuera del catálogo y su enlace queda en public.zona.paquete_mapa"
# Una campaña vigente con Montevideo y una zona circular de 300 m en el centro (lo que el panel dibuja).
ZONA="$(psql_db -q <<'SQL' | tail -n 1
insert into public.campania (nombre, tipo, fecha_inicio, fecha_fin)
  values ('Campaña de prueba del publicador', 'VERANO', public.hoy_montevideo() - 5, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (campania_id, ciudad_id)
  select ca.id, ci.id from public.campania ca, public.ciudad ci
   where ca.nombre = 'Campaña de prueba del publicador' and ci.nombre = 'Montevideo' and ci.deleted_at is null;
insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color)
  select 'Zona de prueba del publicador', cc.id, 'RADIAL', -34.9011, -56.1645, 300, '#3A7BD5'
    from public.campania_ciudad cc join public.campania ca on ca.id = cc.campania_id
   where ca.nombre = 'Campaña de prueba del publicador'
returning id;
SQL
)"
[ -n "$ZONA" ] || { echo "FALLO: no pude crear la zona de prueba"; exit 1; }
echo "zona de prueba: $ZONA"
SALIDA_ZONA="$("${NODO[@]}" node src/cli.mjs publicar --solo zonas)"
echo "$SALIDA_ZONA"
grep -q "zonas: 1 publicadas" <<<"$SALIDA_ZONA" || { echo "FALLO: tenía que publicar la zona"; exit 1; }
grep -q "zonas/" <<<"$SALIDA_ZONA" && { echo "FALLO: el nombre del archivo de la zona salió por la consola"; exit 1; }
ZONA="$ZONA" "${NODO[@]}" node prueba-storage/zona-publicada.mjs "$PUBLICA"

paso "publicar las zonas otra vez: no cambia nada"
VERSION_ANTES="$(psql_db -c "select sync_version from public.zona where id = '$ZONA'")"
OTRA_VEZ="$("${NODO[@]}" node src/cli.mjs publicar --solo zonas)"
echo "$OTRA_VEZ"
grep -q "zonas: 0 publicadas, 1 sin cambios" <<<"$OTRA_VEZ" || { echo "FALLO: la segunda corrida tocó la zona"; exit 1; }
[ "$(psql_db -c "select sync_version from public.zona where id = '$ZONA'")" = "$VERSION_ANTES" ]   || { echo "FALLO: la segunda corrida subió sync_version de la zona"; exit 1; }

printf '\nTodo bien.\n'
