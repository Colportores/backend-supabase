#!/usr/bin/env bash
# El delta no puede saltear una fila, pase lo que pase con el orden de commit.
#
# Es la única familia de bugs que un test de una sola sesión no puede encontrar,
# así que va en shell y no en un .sql: hacen falta dos conexiones vivas a la vez.
#
#   ./test/concurrencia.sh <nombre-del-contenedor>
#
# El escenario es el que rompía el delta ordenado por `updated_at` (ver la
# migración 0010):
#
#   A: begin (t=0) ── push ─────────────────────── commit (t=3)
#   B:          begin (t=1) ── push ── commit (t=1)
#   pull:                                  ↑ acá
#
# `now()` es la hora de INICIO de la transacción, así que la fila de A queda con
# un timestamp MENOR que la de B aunque commitee después. Un delta ordenado por
# tiempo entrega la de B, avanza el watermark, y la de A queda detrás para
# siempre: subida, guardada, y jamás entregada.
set -euo pipefail

PG=${1:?falta el nombre del contenedor}
U=01a04999-0000-7000-8000-000000000001
J1=01a04998-0000-7000-8000-000000000001
J2=01a04998-0000-7000-8000-000000000002
FIFO=$(mktemp -u)

limpiar() { exec 3>&- 2>/dev/null || true; rm -f "$FIFO"; }
trap limpiar EXIT

psql_() { docker exec -i "$PG" psql -U postgres -d colportaje -qAt -v ON_ERROR_STOP=1 "$@"; }
fallar() { echo "FALLÓ: $1" >&2; exit 1; }

push() {  # push <client_op_id> <id-de-jornada>
  echo "select sync.push('$U', jsonb_build_array(jsonb_build_object(
          'client_op_id','$1', 'entity','jornada', 'op','insert',
          'payload', jsonb_build_object('id','$2','inicio', now()))));"
}

# Cuántas filas de jornada entrega un pull, y con qué watermark queda.
pull() { psql_ -c "select sync.pull('$U', array['jornada'], '$1'::jsonb, 500)::text"; }

psql_ -c "delete from jornada where pk_usuario = '$U';" >/dev/null

# --- A abre transacción, escribe y NO commitea -------------------------------
mkfifo "$FIFO"
docker exec -i "$PG" psql -U postgres -d colportaje -qAt >/dev/null 2>&1 < "$FIFO" &
exec 3>"$FIFO"
{ echo "begin;"; push "01a04997-0000-7000-8000-000000000001" "$J1"; } >&3

# Esperar a que A tenga xid de verdad en vez de dormir un rato fijo: un sleep
# corto vuelve el test intermitente y uno largo lo vuelve lento.
for _ in $(seq 1 100); do
  [ "$(psql_ -c "select count(*) from pg_stat_activity
                  where backend_xid is not null and pid <> pg_backend_pid();")" -ge 1 ] && break
  sleep 0.1
done
[ "$(psql_ -c "select count(*) from pg_stat_activity
                where backend_xid is not null and pid <> pg_backend_pid();")" -ge 1 ] \
  || fallar "la conexión A nunca tomó un xid: el test no llegó a montar el escenario"

# --- B escribe y commitea, mientras A sigue en vuelo -------------------------
psql_ -c "$(push "01a04997-0000-7000-8000-000000000002" "$J2")" >/dev/null

# --- El pull no puede entregar nada todavía ----------------------------------
#
# La fila de B ya está commiteada, pero entregarla avanzaría el watermark por
# delante de la de A, que aún puede commitear. El delta lo retiene: correcto y
# temporal, contra perderlo: silencioso y permanente.
R=$(pull '{}')
N=$(psql_ -c "select jsonb_array_length(coalesce(\$\$$R\$\$::jsonb -> 'rows' -> 'jornada', '[]'))")
[ "$N" = "0" ] || fallar "entregó $N fila(s) con una transacción en vuelo: el watermark puede adelantarse"
W=$(psql_ -c "select (\$\$$R\$\$::jsonb -> 'watermark')::text")

# --- A commitea recién ahora -------------------------------------------------
echo "commit;" >&3
exec 3>&-
wait 2>/dev/null || true

for _ in $(seq 1 100); do
  [ "$(psql_ -c "select count(*) from pg_stat_activity
                  where backend_xid is not null and pid <> pg_backend_pid();")" = "0" ] && break
  sleep 0.1
done

# --- Y ahora salen las dos, ninguna se perdió --------------------------------
R=$(pull "$W")
N=$(psql_ -c "select jsonb_array_length(coalesce(\$\$$R\$\$::jsonb -> 'rows' -> 'jornada', '[]'))")
EN_BASE=$(psql_ -c "select count(*) from jornada where pk_usuario = '$U';")

[ "$EN_BASE" = "2" ] || fallar "el escenario no quedó armado: $EN_BASE filas en la base, esperaba 2"
[ "$N" = "2" ] || fallar "el delta entregó $N de $EN_BASE filas: se saltearon $((EN_BASE - N))"

echo "OK  el delta no saltea filas con commits fuera de orden (2 conexiones)"
