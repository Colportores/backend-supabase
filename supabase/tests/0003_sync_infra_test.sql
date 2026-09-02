-- pgTAP · migración 0002 — estructura, registro y privilegios de la infra de sync.
-- Lo que se puede verificar sin cruzar transacciones. El comportamiento del push
-- y del delta va en 0004, que necesita varias transacciones para probarse.
begin;
select * from no_plan();

-- ---------------------------------------------------------------------------
-- 1. El schema y sus tablas
-- ---------------------------------------------------------------------------

select has_schema('sync', 'existe el schema sync');
select has_table('sync', 'entidad',  'sync.entidad');
select has_table('sync', 'op_cache', 'sync.op_cache');
select has_table('sync', 'log',      'sync.log');

-- Regla 6 del 0001. Con SECURITY INVOKER esto no es decorativo: es lo único que
-- impide leer el cache o la telemetría de otro colportor.
select is(
  (select bool_and(c.relrowsecurity)
     from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'sync' and c.relkind = 'r'),
  true,
  'todas las tablas de sync tienen RLS habilitada'
);

-- ---------------------------------------------------------------------------
-- 2. El cursor del delta existe en todas las tablas
-- ---------------------------------------------------------------------------

-- En las 24, no solo en las sincronizables: las funciones de auditoría son
-- compartidas y asignan xmin_w sin preguntar. Una tabla sin la columna rompería
-- el trigger en runtime, no en la migración.
select is(
  (select count(*)::integer
     from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
     left join pg_attribute a
            on a.attrelid = c.oid and a.attname = 'xmin_w' and not a.attisdropped
    where n.nspname = 'public' and c.relkind = 'r' and a.attname is null),
  0,
  'ninguna tabla de public quedó sin xmin_w'
);

select col_type_is('public', 'venta', 'xmin_w', 'xid8', 'xmin_w es xid8 (64 bits, sin wraparound)');
select col_not_null('public', 'venta', 'xmin_w', 'xmin_w es not null');

-- ---------------------------------------------------------------------------
-- 3. El registro es el espejo del contrato §2
-- ---------------------------------------------------------------------------

select is((select count(*)::integer from sync.entidad), 19, 'hay 19 entidades registradas');

select is(
  (select array_agg(nombre order by nombre) from sync.entidad where not permite_push),
  array['campania','ciudad','coleccion','pais','precio_por_zona','producto',
        'producto_coleccion','zona'],
  'las entidades pull están marcadas de solo lectura (contrato §2)'
);

select is(
  (select array_agg(nombre order by nombre) from sync.entidad where permite_push),
  array['agenda','cobranza','entrega','espacio','espacio_persona','house_status',
        'jornada','ubicacion','venta','venta_item','visita'],
  'las entidades push son las del contrato §2 más espacio_persona'
);

-- Ley 18.331: no es una omisión temporal, es la restricción de diseño.
select is(
  (select count(*)::integer from sync.entidad where nombre in ('persona','nota')),
  0,
  'persona y nota NO están registradas para sync (contrato §2, política local)'
);

select is(
  (select columna_pk from sync.entidad where nombre = 'house_status'),
  'ubicacion_id',
  'house_status declara su PK real: el RPC es genérico, la excepción vive en el registro'
);

-- Toda entidad registrada apunta a una tabla que existe y tiene la PK declarada.
select is(
  (select count(*)::integer
     from sync.entidad e
     left join pg_attribute a
            on a.attrelid = e.tabla and a.attname = e.columna_pk and not a.attisdropped
    where a.attname is null),
  0,
  'toda entidad registrada apunta a una tabla con la columna_pk que declara'
);

-- ---------------------------------------------------------------------------
-- 4. Columnas server-authoritative (contrato §5.4)
-- ---------------------------------------------------------------------------

select ok(
  (select columnas_servidor @> array['sync_version','updated_at','created_by','xmin_w']
     from sync.entidad where nombre = 'venta'),
  'sync_version, updated_at, created_by y xmin_w los fija el servidor'
);

-- created_at SÍ lo manda el cliente: la fila nace offline y sube después
-- (0001 regla 3). El trigger la protege en el UPDATE, que es donde hacía falta.
select ok(
  (select not (columnas_servidor @> array['created_at'])
     from sync.entidad where nombre = 'venta'),
  'created_at NO es server-authoritative en el INSERT (0001 regla 3)'
);

select ok(
  (select bool_and(columnas_servidor @> array['colportor_id'])
     from sync.entidad where nombre in ('jornada','visita','agenda','venta')),
  'colportor_id se descarta del payload: decide qué filas ve el usuario'
);

-- ---------------------------------------------------------------------------
-- 5. Seguridad de las funciones
-- ---------------------------------------------------------------------------

-- La decisión de ADR-016 hecha código: si la ingesta corriera como su dueño, la
-- RLS no la alcanzaría y la autorización pasaría a depender del BFF.
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'sync' and p.prosecdef),
  array['purgar_cache','purgar_log'],
  'solo las purgas son SECURITY DEFINER; push/pull corren con el JWT de quien llama'
);

-- Postgres guarda `set search_path = ''` como la cadena `search_path=""`.
-- Cualquier otro valor —en particular uno que incluya `public`— deja abierta la
-- mitad del vector que el search_path fijo existe para cerrar.
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'sync'
      and coalesce(p.proconfig, array[]::text[]) <> array['search_path=""']),
  null::text[],
  'todas las funciones de sync fijan search_path = '''' y nada más'
);

-- Postgres otorga EXECUTE a PUBLIC en cada CREATE FUNCTION y anon lo hereda.
select is(
  (select count(*)::integer
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'sync'
      and has_function_privilege('anon', p.oid, 'execute')),
  0,
  'anon no puede ejecutar ninguna función de sync'
);

select ok(has_function_privilege('authenticated', 'sync.push(jsonb,uuid)', 'execute'),
          'authenticated puede llamar a sync.push');
select ok(has_function_privilege('authenticated', 'sync.pull(text[],jsonb,integer,uuid)', 'execute'),
          'authenticated puede llamar a sync.pull');
select ok(not has_function_privilege('authenticated', 'sync.purgar_cache(interval)', 'execute'),
          'authenticated NO puede correr la purga (es SECURITY DEFINER, la corre pg_cron)');

select ok(not has_schema_privilege('anon', 'sync', 'usage'),
          'anon no tiene USAGE sobre el schema sync');
select ok(has_schema_privilege('authenticated', 'sync', 'usage'),
          'authenticated tiene USAGE sobre el schema sync');

-- El schema sync no se expone en la Data API (config.toml lista public y
-- graphql_public), pero los privilegios no se apoyan en esa configuración.
select ok(not has_table_privilege('anon', 'sync.op_cache', 'select'),
          'anon no lee el cache de client_op_id');
select ok(not has_table_privilege('authenticated', 'sync.entidad', 'insert'),
          'authenticated no escribe el registro de entidades');

-- ---------------------------------------------------------------------------
-- 6. Purga agendada
-- ---------------------------------------------------------------------------

-- La lección del prototipo: un TTL documentado y no ejecutado deja crecer el
-- cache hasta que el índice se degrada, y se descubre midiendo, tarde.
select is(
  (select array_agg(jobname order by jobname) from cron.job
    where jobname in ('sync-purgar-op-cache','sync-purgar-log')),
  array['sync-purgar-log','sync-purgar-op-cache'],
  'las dos purgas quedan agendadas en pg_cron'
);

-- ---------------------------------------------------------------------------
-- 7. Índices del delta
-- ---------------------------------------------------------------------------

-- El orden importa: la columna del predicado RLS va primero para que
-- `colportor_id = auth.uid()` entre en el Index Cond y no sea un filtro
-- post-scan (security-rls-performance.md).
select has_index('public', 'venta',   'venta_delta_idx',   array['colportor_id','xmin_w','id']);
select has_index('public', 'jornada', 'jornada_delta_idx', array['colportor_id','xmin_w','id']);
select has_index('public', 'producto','producto_delta_idx',array['xmin_w','id']);
select has_index('public', 'house_status', 'house_status_delta_idx', array['xmin_w','ubicacion_id']);

select is(
  (select count(*)::integer
     from sync.entidad e
    where not exists (
      select 1 from pg_index i
       where i.indrelid = e.tabla
         and 'xmin_w' = any (select a.attname from pg_attribute a
                              where a.attrelid = e.tabla and a.attnum = any (i.indkey)))),
  0,
  'toda entidad registrada tiene un índice que incluye xmin_w'
);

select * from finish();
rollback;
