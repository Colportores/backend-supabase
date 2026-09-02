-- C_SYNC_LOG y sync.estado() (tarea 1.4, RF-SY06).
--
-- Sin `begin;` que envuelva el archivo: cada `do $$` es su propia transacción,
-- porque el delta por xid no entrega lo que sigue en vuelo (ver 0010) y porque
-- lo que se mide acá —que un pull vacío no escriba— solo tiene sentido con
-- transacciones de verdad.
--
-- Usa su propio colportor para no pisar los datos de sync_test.sql.

\set QUIET on
\set ON_ERROR_STOP on

create or replace function assert(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  if p_cond is not true then raise exception 'FALLÓ: %', p_msg; end if;
end $$;

--   u = 0771...   sus jornadas = 0772...

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; l sync.log%rowtype; begin
  -- Un lote con de todo: uno que entra, uno repetido, y uno inválido.
  r := sync.push('07710000-0000-7000-8000-000000000001'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','07730000-0000-7000-8000-000000000001',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','07720000-0000-7000-8000-000000000001','inicio','2026-11-13T08:00:00Z')),
    jsonb_build_object('client_op_id','07730000-0000-7000-8000-000000000001',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','07720000-0000-7000-8000-000000000001','inicio','2026-11-13T08:00:00Z')),
    jsonb_build_object('client_op_id','07730000-0000-7000-8000-000000000003',
      'entity','no_existe','op','insert',
      'payload', jsonb_build_object('id','07720000-0000-7000-8000-000000000009'))));

  select * into l from sync.log
   where pk_usuario = '07710000-0000-7000-8000-000000000001' and operacion = 'push';

  perform assert(l.id is not null, 'el push dejó su línea en el log');
  perform assert(l.jobs = 3,       'cuenta los jobs del lote');
  perform assert(l.aceptados = 1,  'uno aceptado');
  perform assert(l.duplicados = 1, 'uno duplicado');
  perform assert(l.invalidos = 1,  'uno inválido');
  perform assert(l.bytes_entrada > 0 and l.bytes_salida > 0, 'mide los dos lados del ciclo');
  perform assert(l.duracion_ms >= 0, 'y la duración');
  raise notice 'OK  el push se registra con sus contadores';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare n_antes int; n_despues int; r jsonb; begin
  select count(*) into n_antes from sync.log;

  -- Un colportor sin nada que bajar: el latido más común de todos.
  r := sync.pull('07710000-0000-7000-8000-0000000000ff'::uuid, array['jornada']);
  perform assert(r -> 'rows' = '{}'::jsonb, 'no tenía nada que bajar');

  select count(*) into n_despues from sync.log;

  -- Si esto falla, cada latido de cada colportor pasa a ser una escritura: WAL
  -- y vacuum de más, y sobre todo un xid tomado que frena el horizonte del
  -- delta de todos los demás mientras dura.
  perform assert(n_despues = n_antes, 'un pull sin novedades no escribe nada');
  raise notice 'OK  el pull vacío no toca el log (queda de solo lectura)';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; l sync.log%rowtype; begin
  r := sync.pull('07710000-0000-7000-8000-000000000001'::uuid, array['jornada']);
  perform assert(jsonb_array_length(r -> 'rows' -> 'jornada') = 1, 'baja la jornada del push');

  select * into l from sync.log
   where pk_usuario = '07710000-0000-7000-8000-000000000001' and operacion = 'pull';

  perform assert(l.id is not null,  'el pull que trae filas sí se registra');
  perform assert(l.filas = 1,       'cuenta las filas entregadas');
  perform assert(l.entidades = array['jornada'], 'y qué entidades se pidieron');
  perform assert(l.hay_mas = false, 'y si quedó cola');
  raise notice 'OK  el pull con filas se registra';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare e jsonb; begin
  e := sync.estado('07710000-0000-7000-8000-000000000001'::uuid);

  perform assert(e -> 'ultimo_push' is not null, 'sabe cuándo fue el último push');
  perform assert(e -> 'ultimo_pull' is not null, 'y el último pull');
  perform assert((e -> 'ventana' ->> 'ciclos')::int = 2, 'los dos ciclos de la ventana');
  perform assert((e -> 'ventana' ->> 'jobs')::int = 3, 'suma los jobs');
  perform assert((e -> 'ventana' ->> 'invalidos')::int = 1, 'y los rechazos');
  perform assert((e -> 'ventana' ->> 'bytes_salida')::int > 0, 'y los bytes de RR-07');
  perform assert(e -> 'ventana' -> 'p95_ms' is not null, 'p95 de duración, no promedio');
  raise notice 'OK  sync.estado resume la ventana';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare e jsonb; begin
  -- Un colportor que nunca sincronizó no es un error: es un colportor nuevo.
  e := sync.estado('07710000-0000-7000-8000-0000000000ee'::uuid);
  perform assert(e ->> 'ultimo_push' is null, 'sin push previo');
  perform assert((e -> 'ventana' ->> 'ciclos')::int = 0, 'cero ciclos, no NULL');
  perform assert((e -> 'ventana' ->> 'jobs')::int = 0, 'cero jobs, no NULL');
  raise notice 'OK  un colportor sin historia devuelve ceros, no nulos';
end $$;

-- ---------------------------------------------------------------------------
-- El device_id del sobre (§5.3, F4) — 0014
--
-- Va después de los asserts de `sync.estado` a propósito: agregar ciclos antes
-- cambiaría los conteos de la ventana que esos bloques fijan.
do $$
declare
  r jsonb;
  l sync.log%rowtype;
  c sync.op_cache%rowtype;
  d1 uuid := '07740000-0000-7000-8000-00000000000a';
  d2 uuid := '07740000-0000-7000-8000-00000000000b';
begin
  r := sync.push('07710000-0000-7000-8000-000000000002'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','07730000-0000-7000-8000-00000000000a',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','07720000-0000-7000-8000-00000000000a',
                                    'inicio','2026-11-13T08:00:00Z'))), d1);

  select * into l from sync.log
   where pk_usuario = '07710000-0000-7000-8000-000000000002' and operacion = 'push';
  perform assert(l.device_id = d1, 'el push registra de qué dispositivo vino');

  select * into c from sync.op_cache
   where client_op_id = '07730000-0000-7000-8000-00000000000a';
  perform assert(c.device_id = d1, 'y el cache también');

  -- El mismo op, desde el otro teléfono del mismo colportor. Vuelve
  -- `duplicate`, que es lo correcto, y el cache **conserva al primero**: la
  -- pregunta que sirve es quién lo aplicó, no quién lo repitió.
  r := sync.push('07710000-0000-7000-8000-000000000002'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','07730000-0000-7000-8000-00000000000a',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','07720000-0000-7000-8000-00000000000a',
                                    'inicio','2026-11-13T08:00:00Z'))), d2);

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'duplicate', 'el reintento es duplicate');

  select * into c from sync.op_cache
   where client_op_id = '07730000-0000-7000-8000-00000000000a';
  perform assert(c.device_id = d1, 'un reintento de otro dispositivo no pisa al primero');

  raise notice 'OK  el device_id llega al log y al cache';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; l sync.log%rowtype; d uuid := '07740000-0000-7000-8000-00000000000c'; begin
  r := sync.pull('07710000-0000-7000-8000-000000000002'::uuid, array['jornada'],
                 '{}'::jsonb, 500, d);
  perform assert(jsonb_array_length(r -> 'rows' -> 'jornada') = 1, 'baja la jornada');

  select * into l from sync.log
   where pk_usuario = '07710000-0000-7000-8000-000000000002' and operacion = 'pull';
  perform assert(l.device_id = d, 'el pull también dice de qué dispositivo vino');
  raise notice 'OK  el device_id viaja en las dos operaciones';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; l sync.log%rowtype; begin
  -- Un push sin dispositivo no es un error de la base: el 426 del BFF ya lo
  -- corta antes, y las filas viejas tampoco lo tienen. La base no puede
  -- inventarlo, así que lo deja en null y sigue.
  r := sync.push('07710000-0000-7000-8000-000000000003'::uuid, '[]'::jsonb);

  select * into l from sync.log
   where pk_usuario = '07710000-0000-7000-8000-000000000003' and operacion = 'push';
  perform assert(l.id is not null,      'el ciclo se registra igual');
  perform assert(l.device_id is null,   'sin dispositivo, null, no un valor inventado');
  raise notice 'OK  sin device_id la base no inventa nada';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare n int; begin
  -- La lección de 0005: el TTL documentado y no ejecutado deja crecer la tabla.
  update sync.log set momento = now() - interval '91 days';
  n := sync.purgar_log();
  perform assert(n > 0, 'purga lo vencido');
  perform assert((select count(*) from sync.log) = 0, 'no queda nada');
  raise notice 'OK  purga del log a los 90 días';
end $$;
