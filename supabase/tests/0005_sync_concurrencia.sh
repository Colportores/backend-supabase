#!/usr/bin/env bash
# Push y delta con dos transacciones cruzadas: lo único que pgTAP no puede ver.
#
# pg_prove corre cada archivo en UNA conexión, y las tres garantías de acá
# dependen de lo que pasa cuando una transacción está en vuelo mientras otra
# escribe. Hacen falta dos conexiones vivas a la vez, así que va en shell. Lo
# corre scripts/db-test.sh después de pgTAP.
#
#   1. REINTENTO EN VUELO. El motor manda un lote, el celular pierde señal antes
#      de la respuesta y el reintento llega mientras el primero todavía corre. El
#      cache de client_op_id no ve el op (no commiteó): lo que evita el doble
#      insert es la PK, y el reintento tiene que volver `duplicate`, no `invalid`
#      — un invalid ahí manda a la cola de error una venta que ya se cobró.
#
#   2. COMPARE-AND-SWAP. Dos colportores de la misma zona marcan la misma casa a
#      la vez, los dos desde sync_version 0. Los dos pasan el `if` de versión de
#      aplicar_job_interno; el segundo espera el lock de la fila en el UPDATE y,
#      al soltarse, tiene que salir `conflict` y no pisar al primero.
#
#   3. COMMITS FUERA DE ORDEN EN EL DELTA. A abre transacción y escribe; B
#      escribe y commitea; un pull entre medio no puede entregar la fila de B,
#      porque avanzaría el watermark por delante de la de A, que todavía puede
#      commitear. Al commitear A salen las dos. Es el bug que arregló el cursor
#      por xid (PR #5, 0010).
#
# Cada escenario comprueba además que la carrera ocurrió de verdad —la segunda
# conexión quedó esperando un lock, o la primera tenía xid—: sin eso el test
# pasaría igual con las dos escrituras en serie, y eso no prueba nada.
#
# Deja la base como la encontró. Espera las migraciones aplicadas.
set -euo pipefail

: "${DB_URL:?Definir DB_URL (postgresql://user:pass@host:port/db)}"

ANA=01920000-0000-7000-8000-0000000005a1
BETO=01920000-0000-7000-8000-0000000005a2
PAIS=01920000-0000-7000-8000-0000000005c0
CIUDAD=01920000-0000-7000-8000-0000000005c1
ZONA=01920000-0000-7000-8000-0000000005d1
CASA=01920000-0000-7000-8000-0000000005e1

TMP=$(mktemp -d)
FIFO="$TMP/a.fifo"
PID_A=
PID_B=

# Un lock que no se suelta tiene que fallar el test, no colgar el CI.
export PGOPTIONS='-c statement_timeout=30s'

consultar() { PGAPPNAME=conc-control psql "$DB_URL" -qAtX -v ON_ERROR_STOP=1 -c "$1"; }
fallar() { echo "FALLÓ: $1" >&2; exit 1; }

esperar() {  # esperar <condición SQL> <mensaje si no se cumple en 10 s>
  for _ in $(seq 1 100); do
    [ "$(consultar "select $1")" = t ] && return 0
    sleep 0.1
  done
  fallar "$2"
}

campo() {  # campo <json> <ruta>: un valor de la respuesta, con #>>
  consultar "select \$j\$$1\$j\$::jsonb #>> '$2'"
}

# El preámbulo de una conexión que actúa como <uid>: los mismos GUCs que
# pg_temp.actuar_como() de 0004, a nivel sesión.
como() {
  cat <<SQL
\o /dev/null
select set_config('request.jwt.claims', '{"sub":"$1","role":"authenticated"}', false);
select set_config('request.jwt.claim.sub', '$1', false);
\o
set role authenticated;
SQL
}

push_jornada() {  # push_jornada <client_op_id> <id>: insert de una jornada
  echo "select sync.push(jsonb_build_array(jsonb_build_object(
          'client_op_id', '$1', 'entity', 'jornada', 'op', 'insert',
          'payload', jsonb_build_object('id', '$2', 'inicio', now()))))::text;"
}

push_casa() {  # push_casa <client_op_id> <numero>: update de la casa desde sync_version 0
  echo "select sync.push(jsonb_build_array(jsonb_build_object(
          'client_op_id', '$1', 'entity', 'ubicacion', 'op', 'update', 'sync_version', 0,
          'payload', jsonb_build_object('id', '$CASA', 'numero', '$2'))))::text;"
}

# A: abre transacción, escribe y se queda en vuelo hasta commit_a.
abrir_a() {  # abrir_a <uid> <sql>
  mkfifo "$FIFO"
  PGAPPNAME=conc-a psql "$DB_URL" -qAtX -v ON_ERROR_STOP=1 < "$FIFO" > "$TMP/a.out" 2>&1 &
  PID_A=$!
  exec 3> "$FIFO"
  { como "$1"; echo "begin;"; echo "$2"; } >&3

  # Esperar a que A tenga xid de verdad en vez de dormir un rato fijo: un sleep
  # corto vuelve el test intermitente y uno largo lo vuelve lento.
  esperar "exists (select 1 from pg_stat_activity
                    where application_name = 'conc-a' and backend_xid is not null)" \
          "la conexión A nunca tomó un xid: el escenario no llegó a armarse"
}

commit_a() {
  echo "commit;" >&3
  exec 3>&-
  wait "$PID_A" || fallar "la conexión A terminó con error: $(cat "$TMP/a.out")"
  PID_A=
  rm -f "$FIFO"
}

# B: la segunda conexión. Corre de fondo para poder quedar esperando a A.
lanzar_b() {  # lanzar_b <uid> <sql>
  { como "$1"; echo "$2"; } \
    | PGAPPNAME=conc-b psql "$DB_URL" -qAtX -v ON_ERROR_STOP=1 > "$TMP/b.out" 2>&1 &
  PID_B=$!
}

esperar_b() {
  wait "$PID_B" || fallar "la conexión B terminó con error: $(cat "$TMP/b.out")"
  PID_B=
}

b_espera_lock() {  # b_espera_lock <mensaje si B nunca bloquea>
  esperar "exists (select 1 from pg_stat_activity
                    where application_name = 'conc-b' and wait_event_type = 'Lock')" \
          "$1"
}

borrar_fixtures() {
  consultar "
    delete from public.jornada   where colportor_id in ('$ANA', '$BETO');
    delete from public.ubicacion where id = '$CASA';
    delete from public.zona      where id = '$ZONA';
    delete from public.ciudad    where id = '$CIUDAD';
    delete from public.pais      where id = '$PAIS';
    -- usuario, op_cache y log se van por cascade desde auth.users.
    delete from auth.users       where id in ('$ANA', '$BETO');" >/dev/null
}

limpiar() {
  # Cerrar la FIFO termina la conexión A, y con ella su transacción: rollback.
  { exec 3>&-; } 2>/dev/null || true
  [ -z "$PID_A" ] || kill "$PID_A" 2>/dev/null || true
  [ -z "$PID_B" ] || kill "$PID_B" 2>/dev/null || true
  wait 2>/dev/null || true
  borrar_fixtures
  rm -rf "$TMP"
}
trap limpiar EXIT

# ---------------------------------------------------------------------------
# Fixtures (como postgres, sin RLS)
# ---------------------------------------------------------------------------

borrar_fixtures
consultar "
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
    ('$ANA',  '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ana.concurrencia@example.com',  'x', now(), now()),
    ('$BETO', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beto.concurrencia@example.com', 'x', now(), now());
  insert into public.pais (id, nombre, iso_code) values ('$PAIS', 'Uruguay', 'UY');
  insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
    values ('$CIUDAD', 'Montevideo', '$PAIS', -34.9, -56.16);
  insert into public.zona (id, nombre, ciudad_id) values ('$ZONA', 'Zona compartida', '$CIUDAD');
  -- Ana y Beto trabajan la misma zona: los dos pueden escribir sus casas.
  update public.usuario set zona_id = '$ZONA' where id in ('$ANA', '$BETO');
  insert into public.ubicacion (id, tipo, numero, lat, lon, ciudad_id, zona_id, created_by)
    values ('$CASA', 'CASA', '1234', -34.9, -56.18, '$CIUDAD', '$ZONA', '$ANA');" >/dev/null

# ---------------------------------------------------------------------------
# 1. Reintento en vuelo: el mismo client_op_id, dos veces a la vez
# ---------------------------------------------------------------------------

OP=01920000-0000-7000-8000-0000000005b1
J=01920000-0000-7000-8000-0000000005f1

abrir_a "$ANA" "$(push_jornada "$OP" "$J")"
lanzar_b "$ANA" "$(push_jornada "$OP" "$J")"

# El reintento no encuentra el op en el cache —A no commiteó— y tiene que
# quedar esperando la PK de la jornada. Si no espera, corrieron en serie.
b_espera_lock "el reintento no esperó al primer envío: la carrera no ocurrió"
commit_a
esperar_b

[ "$(campo "$(cat "$TMP/a.out")" '{results,0,outcome}')" = accepted ] \
  || fallar "el primer envío no quedó accepted: $(cat "$TMP/a.out")"
[ "$(campo "$(cat "$TMP/b.out")" '{results,0,outcome}')" = duplicate ] \
  || fallar "el reintento en vuelo no volvió duplicate: $(cat "$TMP/b.out")"
[ "$(consultar "select count(*) from public.jornada where id = '$J'")" = 1 ] \
  || fallar "el reintento en vuelo duplicó la jornada"
[ "$(consultar "select count(*) from sync.op_cache where client_op_id = '$OP'")" = 1 ] \
  || fallar "el cache no quedó con una sola entrada para el op"

echo "OK  un reintento en vuelo del mismo client_op_id vuelve duplicate y no duplica la fila"

# ---------------------------------------------------------------------------
# 2. Compare-and-swap: dos colportores, la misma casa, la misma versión
# ---------------------------------------------------------------------------

OP_ANA=01920000-0000-7000-8000-0000000005b2
OP_BETO=01920000-0000-7000-8000-0000000005b3

abrir_a "$ANA" "$(push_casa "$OP_ANA" 1236)"
lanzar_b "$BETO" "$(push_casa "$OP_BETO" 1238)"

# Beto leyó sync_version 0 —el UPDATE de Ana no commiteó—, pasó el `if` de
# versión y quedó esperando el lock de la fila: la ventana exacta que el
# compare-and-swap existe para cerrar.
b_espera_lock "el update de Beto no quedó esperando el lock de la fila: la carrera no ocurrió"
commit_a
esperar_b

R_B=$(cat "$TMP/b.out")
[ "$(campo "$(cat "$TMP/a.out")" '{results,0,outcome}')" = accepted ] \
  || fallar "el update de Ana no quedó accepted: $(cat "$TMP/a.out")"
[ "$(campo "$R_B" '{results,0,outcome}')" = conflict ] \
  || fallar "el segundo escritor no salió conflict: $R_B"
[ "$(campo "$R_B" '{results,0,server_row,numero}')" = 1236 ] \
  || fallar "el conflicto no devolvió la fila que ganó: $R_B"
[ "$(consultar "select numero || '/' || sync_version from public.ubicacion where id = '$CASA'")" = 1236/1 ] \
  || fallar "actualización perdida: la casa quedó en $(consultar "select numero || '/' || sync_version from public.ubicacion where id = '$CASA'"), esperaba 1236/1"
[ "$(consultar "select count(*) from sync.op_cache where client_op_id = '$OP_BETO'")" = 0 ] \
  || fallar "el conflicto de Beto entró al cache de client_op_id"

echo "OK  dos escritores desde la misma versión: uno aplica y el otro sale conflict con la fila ganadora"

# ---------------------------------------------------------------------------
# 3. El delta no saltea filas con commits fuera de orden
# ---------------------------------------------------------------------------
#
#   A: begin ── push ───────────────────────── commit
#   B:            push ── commit
#   pull:                          ↑ acá no puede salir la de B

OP_A=01920000-0000-7000-8000-0000000005b4
OP_B=01920000-0000-7000-8000-0000000005b5
JA=01920000-0000-7000-8000-0000000005f2
JB=01920000-0000-7000-8000-0000000005f3

pull_ana() {  # pull_ana <watermark>: el delta de jornadas que ve Ana
  { como "$ANA"; echo "select sync.pull(array['jornada'], '$1'::jsonb)::text;"; } \
    | PGAPPNAME=conc-pull psql "$DB_URL" -qAtX -v ON_ERROR_STOP=1
}

entregadas() {  # entregadas <respuesta del pull>: cuáles de JA/JB vinieron
  consultar "select coalesce(string_agg(r ->> 'id', ',' order by r ->> 'id'), '')
               from jsonb_array_elements(coalesce(\$j\$$1\$j\$::jsonb #> '{rows,jornada}', '[]')) r
              where r ->> 'id' in ('$JA', '$JB')"
}

abrir_a "$ANA" "$(push_jornada "$OP_A" "$JA")"
lanzar_b "$ANA" "$(push_jornada "$OP_B" "$JB")"
esperar_b

[ "$(consultar "select count(*) from public.jornada where id = '$JB'")" = 1 ] \
  || fallar "la jornada de B no quedó commiteada: el escenario no se armó"

# La fila de B ya está commiteada, pero entregarla avanzaría el watermark por
# delante de la de A. El delta la retiene: correcto y temporal, contra perderla:
# silencioso y permanente.
R=$(pull_ana '{}')
[ -z "$(entregadas "$R")" ] \
  || fallar "el delta entregó $(entregadas "$R") con A en vuelo: el watermark se adelanta a una fila que todavía puede commitear"
W=$(consultar "select \$j\$$R\$j\$::jsonb -> 'watermark'")

commit_a
esperar "not exists (select 1 from pg_stat_activity
                      where backend_xid is not null and pid <> pg_backend_pid())" \
        "quedó una transacción abierta que frena el horizonte del delta"

R=$(pull_ana "$W")
[ "$(entregadas "$R")" = "$JA,$JB" ] \
  || fallar "con el watermark anterior el delta entregó '$(entregadas "$R")', esperaba las dos: se perdió una fila"

echo "OK  el delta no saltea filas con commits fuera de orden"
