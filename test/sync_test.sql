-- Tests de la infraestructura de sync, contra Postgres de verdad.
--
--   docker exec -i <pg> psql -U postgres -d colportaje -v ON_ERROR_STOP=1 -f test/sync_test.sql
--
-- Cada bloque falla con `assert` si el resultado no es el esperado, así que un
-- error de salida distinta de cero es un test roto.
--
-- El archivo espera una base recién creada: sin el `rollback` de antes, deja
-- sus filas puestas y correrlo dos veces contra la misma base falla. `run-tests.sh`
-- levanta un contenedor descartable por corrida, que es como se usa.

\set QUIET on
\set ON_ERROR_STOP on

-- Sin un `begin;` que envuelva el archivo: cada `do $$` corre en su propia
-- transacción, como en producción, donde el push y el pull son dos requests
-- HTTP distintos. Con todo en una sola transacción el delta por xid no puede
-- entregar lo que esa misma transacción acaba de escribir —correctamente: nada
-- que siga en vuelo puede salir— y el archivo entero probaba una configuración
-- que no existe. La base la crea y la tira `run-tests.sh`, así que el
-- `rollback` no hacía falta para limpiar.

create or replace function assert(p_cond boolean, p_msg text)
returns void language plpgsql as $$
begin
  -- `is not true` y no `not p_cond`: con p_cond NULL, `not NULL` es NULL, el
  -- IF no entra y el assert pasa en silencio. Y NULL es justo lo que devuelve
  -- una comparación contra un campo que no vino —`jsonb_array_length(NULL) = 2`
  -- da NULL, no false— así que la forma ingenua deja pasar exactamente los
  -- fallos que este archivo existe para encontrar.
  if p_cond is not true then raise exception 'FALLÓ: %', p_msg; end if;
end $$;

-- Los UUID van literales: psql no sustituye :variables dentro de $$…$$.
--   u1 = el colportor          11111111-…
--   j1, j2 = sus jornadas      018f2c4e-6b7d-7a11-… (v7, como los del dispositivo)

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(jsonb_build_object(
    'client_op_id', 'aaaaaaaa-0000-4000-8000-000000000001',
    'entity', 'jornada', 'op', 'insert',
    'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000001', 'inicio', '2026-11-13T08:00:00Z')
  )));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'accepted', 'insert acepta');
  perform assert((r -> 'results' -> 0 ->> 'sync_version')::int = 1, 'arranca en v1');
  perform assert((select count(*) from jornada where pk_usuario = '11111111-1111-4111-8111-111111111111') = 1, 'la fila entró');
  perform assert((select pk_usuario from jornada where id = '018f2c4e-6b7d-7a11-9f3c-000000000001')
                   = '11111111-1111-4111-8111-111111111111'::uuid, 'el dueño lo pone el servidor');
  raise notice 'OK  insert';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- El mismo client_op_id otra vez: reintento tras un timeout (§5.3).
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(jsonb_build_object(
    'client_op_id', 'aaaaaaaa-0000-4000-8000-000000000001',
    'entity', 'jornada', 'op', 'insert',
    'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000001', 'inicio', '2026-11-13T08:00:00Z')
  )));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'duplicate', 'mismo op_id → duplicate');
  perform assert((select count(*) from jornada where pk_usuario = '11111111-1111-4111-8111-111111111111') = 1, 'no duplicó');
  raise notice 'OK  idempotencia por client_op_id';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- Otro op_id, misma PK: el replay de §7 con el cache ya vencido.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(jsonb_build_object(
    'client_op_id', 'aaaaaaaa-0000-4000-8000-00000000000f',
    'entity', 'jornada', 'op', 'insert',
    'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000001', 'inicio', '2026-11-13T08:00:00Z')
  )));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'duplicate',
                 'replay sobre PK existente es éxito idempotente, no error');
  perform assert((select count(*) from jornada where pk_usuario = '11111111-1111-4111-8111-111111111111') = 1, 'cero duplicados');
  raise notice 'OK  replay idempotente (§7)';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(jsonb_build_object(
    'client_op_id', 'aaaaaaaa-0000-4000-8000-000000000002',
    'entity', 'jornada', 'op', 'update', 'sync_version', 1,
    'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000001', 'km_recorridos', 42.5)
  )));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'accepted', 'update con la versión correcta');
  perform assert((r -> 'results' -> 0 ->> 'sync_version')::int = 2, 'la versión avanza');
  perform assert((select km_recorridos from jornada where id = '018f2c4e-6b7d-7a11-9f3c-000000000001') = 42.5, 'el dato cambió');
  raise notice 'OK  update';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- Llega tarde, con la versión 1 en la mano, cuando el servidor ya está en 2.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(jsonb_build_object(
    'client_op_id', 'aaaaaaaa-0000-4000-8000-000000000003',
    'entity', 'jornada', 'op', 'update', 'sync_version', 1,
    'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000001', 'km_recorridos', 999)
  )));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'conflict', 'versión vieja → conflict');
  perform assert((r -> 'results' -> 0 -> 'server_row' ->> 'km_recorridos')::numeric = 42.5,
                 'devuelve la fila del servidor: el cliente resuelve sin un pull extra');
  perform assert((select km_recorridos from jornada where id = '018f2c4e-6b7d-7a11-9f3c-000000000001') = 42.5, 'el servidor gana (LWW)');
  raise notice 'OK  conflicto LWW (§5.4)';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- El cliente intenta escribir columnas del servidor.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(jsonb_build_object(
    'client_op_id', 'aaaaaaaa-0000-4000-8000-000000000004',
    'entity', 'jornada', 'op', 'update', 'sync_version', 2,
    'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000001', 'km_recorridos', 50,
                                  'sync_version', 99, 'pk_usuario',
                                  '22222222-2222-4222-8222-222222222222')
  )));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'accepted', 'el job entra igual');
  perform assert((select sync_version from jornada where id = '018f2c4e-6b7d-7a11-9f3c-000000000001') = 3, 'sync_version la fija el servidor');
  perform assert((select pk_usuario from jornada where id = '018f2c4e-6b7d-7a11-9f3c-000000000001') = '11111111-1111-4111-8111-111111111111'::uuid,
                 'un cliente no puede regalarle su jornada a otro usuario');
  raise notice 'OK  campos server-authoritative (§5.4)';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id', 'aaaaaaaa-0000-4000-8000-000000000005',
      'entity', 'usuario', 'op', 'insert',
      'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000002')),
    jsonb_build_object('client_op_id', 'aaaaaaaa-0000-4000-8000-000000000006',
      'entity', 'jornada', 'op', 'insert',
      'payload', jsonb_build_object('id', '018f2c4e-6b7d-7a11-9f3c-000000000002', 'inicio', '2026-11-14T08:00:00Z'))
  ));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'invalid', 'entidad no registrada');
  perform assert(r -> 'results' -> 0 ->> 'code' = 'ENTIDAD_DESCONOCIDA', 'con su código');
  perform assert(r -> 'results' -> 1 ->> 'outcome' = 'accepted',
                 'aceptación parcial: un job malo no tumba el lote');
  raise notice 'OK  lista blanca de entidades y aceptación parcial';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; w jsonb; begin
  r := sync.pull('11111111-1111-4111-8111-111111111111'::uuid, array['jornada','ubicacion']);

  perform assert(jsonb_array_length(r -> 'rows' -> 'jornada') = 2, 'trae las dos jornadas');
  perform assert(not (r -> 'rows' ? 'ubicacion'),
                 'una entidad sin cambios queda ausente, no vacía');
  perform assert((r ->> 'has_more')::boolean = false, 'no hay más');

  w := r -> 'watermark';
  r := sync.pull('11111111-1111-4111-8111-111111111111'::uuid, array['jornada'], w);
  perform assert(r -> 'rows' = '{}'::jsonb, 'el segundo pull no trae nada nuevo');
  raise notice 'OK  delta pull y watermark';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; w jsonb; begin
  r := sync.pull('11111111-1111-4111-8111-111111111111'::uuid, array['jornada'], '{}'::jsonb, 1);
  perform assert(jsonb_array_length(r -> 'rows' -> 'jornada') = 1, 'respeta el límite');
  perform assert((r ->> 'has_more')::boolean = true, 'avisa que hay más');

  r := sync.pull('11111111-1111-4111-8111-111111111111'::uuid, array['jornada'], r -> 'watermark', 1);
  perform assert(jsonb_array_length(r -> 'rows' -> 'jornada') = 1, 'la segunda página');
  perform assert((r ->> 'has_more')::boolean = false, 'y ahí se terminó');
  raise notice 'OK  paginado';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- Otro colportor no ve nada de este.
  r := sync.pull('99999999-9999-4999-8999-999999999999'::uuid, array['jornada']);
  perform assert(r -> 'rows' = '{}'::jsonb, 'el delta es por usuario');
  raise notice 'OK  aislamiento por usuario';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare n int; begin
  update sync.op_cache set aplicado_en = now() - interval '25 hours';
  n := sync.purgar_cache();
  perform assert(n > 0, 'purga lo vencido');
  perform assert((select count(*) from sync.op_cache) = 0, 'no queda nada');
  raise notice 'OK  purga del cache a las 24 h';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  perform sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','bbbbbbbb-0000-4000-8000-000000000001',
      'entity','jornada','op','update','sync_version',3,
      'payload', jsonb_build_object('id','018f2c4e-6b7d-7a11-9f3c-000000000001',
                                    'km_recorridos', 42.50))));
end $$;

-- El pull va en su propio bloque, o sea en su propia transacción: el delta no
-- entrega lo que todavía está en vuelo, así que un push y un pull en el mismo
-- `do $$` no verían nada. Es la misma separación que hay en producción.
do $$
declare r jsonb; f jsonb; begin
  r := sync.pull('11111111-1111-4111-8111-111111111111'::uuid, array['jornada']);

  -- Se busca la fila por id en vez de asumir `-> 0`. El delta ordena por orden
  -- de escritura, así que una fila actualizada se va al final del lote: fijar
  -- la posición hacía que el test mirara otra jornada y —con un `km_recorridos`
  -- ausente— comparara contra NULL, que es exactamente lo que el assert viejo
  -- dejaba pasar en verde.
  select e into f
  from jsonb_array_elements(r -> 'rows' -> 'jornada') e
  where e ->> 'id' = '018f2c4e-6b7d-7a11-9f3c-000000000001';

  perform assert(f is not null, 'la jornada actualizada está en el delta');
  perform assert(jsonb_typeof(f -> 'km_recorridos') = 'string',
    'los decimales viajan como string, no como número JSON');
  perform assert(f ->> 'km_recorridos' = '42.50',
    'y sin perder el cero de los centavos');
  raise notice 'OK  decimales como string';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','bbbbbbbb-0000-4000-8000-000000000002',
      'entity','jornada','op','update','sync_version',1,
      'payload', jsonb_build_object('id','018f2c4e-6b7d-7a11-9f3c-000000000001',
                                    'km_recorridos', 7))));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'conflict', 'versión vieja');
  perform assert(
    jsonb_typeof(r -> 'results' -> 0 -> 'server_row' -> 'km_recorridos') = 'string',
    'el server_row de un conflicto viaja igual que una fila del pull');
  raise notice 'OK  decimales en el server_row de un conflicto';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- Un job con una fecha que no es fecha, y otro sano detrás.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','cccccccc-0000-4000-8000-000000000001',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','018f2c4e-6b7d-7a11-9f3c-00000000000e',
                                    'inicio','esto no es una fecha')),
    jsonb_build_object('client_op_id','cccccccc-0000-4000-8000-000000000002',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','018f2c4e-6b7d-7a11-9f3c-00000000000f',
                                    'inicio','2026-11-13T08:00:00Z'))));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'invalid',
                 'el payload roto queda INVALID, no tumba el push');
  perform assert(r -> 'results' -> 0 ->> 'code' = '22007',
                 'con el SQLSTATE para que la app pueda decir qué pasó');
  perform assert(r -> 'results' -> 1 ->> 'outcome' = 'accepted',
                 'el job sano de atrás entra igual');
  perform assert(
    (select count(*) from jornada where id = '018f2c4e-6b7d-7a11-9f3c-00000000000f') = 1,
    'y queda guardado');
  perform assert(
    (select count(*) from jornada where id = '018f2c4e-6b7d-7a11-9f3c-00000000000e') = 0,
    'el roto no dejó nada a medias: la subtransacción lo revirtió');
  raise notice 'OK  un job venenoso no bloquea la cola';
end $$;

-- ---------------------------------------------------------------------------
do $$
declare r jsonb; begin
  -- Una FK que no existe es lo mismo: dato malo, no falla del servidor.
  r := sync.push('11111111-1111-4111-8111-111111111111'::uuid, jsonb_build_array(
    jsonb_build_object('client_op_id','cccccccc-0000-4000-8000-000000000003',
      'entity','jornada','op','insert',
      'payload', jsonb_build_object('id','no-es-un-uuid'))));

  perform assert(r -> 'results' -> 0 ->> 'outcome' = 'invalid', 'PK malformada');
  raise notice 'OK  una PK malformada tampoco tumba el lote';
end $$;

-- ---------------------------------------------------------------------------
-- Guard del registro: agregar una entidad y olvidarse del cursor del delta
-- tiene que romper el CI, no entregar filas de menos en producción.
do $$
declare r record; falta text := '';
begin
  for r in select e.nombre, e.tabla::text as tabla, e.por_usuario, e.columnas_servidor
           from sync.entidad e loop

    -- La columna del cursor.
    if not exists (
      select 1 from pg_attribute a
      where a.attrelid = r.tabla::regclass and a.attname = 'xmin_w'
        and a.attnum > 0 and not a.attisdropped
        and a.atttypid = 'xid8'::regtype and a.attnotnull) then
      falta := falta || format(' %s(sin xmin_w xid8 not null)', r.nombre);
      continue;
    end if;

    -- Que el cliente no la pueda escribir: si pudiera, se saltearía el orden.
    if not ('xmin_w' = any (r.columnas_servidor)) then
      falta := falta || format(' %s(xmin_w escribible por el cliente)', r.nombre);
    end if;

    -- Y el índice que hace que el delta no sea un Seq Scan. Se compara el
    -- prefijo de columnas indexadas, no el nombre: renombrar el índice no
    -- puede hacer pasar el test.
    if not exists (
      select 1 from pg_index i
      where i.indrelid = r.tabla::regclass
        and (select array_agg(a.attname::text order by k.ord)
             from unnest(i.indkey::int[]) with ordinality k(att, ord)
             join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.att)
            = case when r.por_usuario
                   then array['pk_usuario','xmin_w','id']
                   else array['xmin_w','id'] end) then
      falta := falta || format(' %s(sin índice del delta)', r.nombre);
    end if;
  end loop;

  perform assert(falta = '', 'toda entidad registrada necesita el cursor:' || falta);
  raise notice 'OK  toda entidad registrada tiene el cursor del delta';
end $$;
