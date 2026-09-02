-- C_SYNC_LOG y `sync.estado()` — tarea 1.4 del plan, RF-SY06.
--
-- Es también lo que la Fase 3 necesita para medir el piloto contra RR-02
-- (lotes de 100 registros bajo 30 s) y RR-07 (consumo de datos): bytes por
-- ciclo, duración y tasa de rechazo, por colportor y por día. Sin esto, la
-- telemetría del piloto sale de mirar logs de aplicación a ojo.

create table sync.log (
  id            bigint generated always as identity primary key,
  pk_usuario    uuid not null,
  operacion     text not null check (operacion in ('push','pull')),
  -- `clock_timestamp()` y no `now()`: acá interesa el momento real del ciclo,
  -- no el inicio de la transacción. Es la misma distinción que causaba el bug
  -- del delta en 0010, mirada desde el otro lado.
  momento       timestamptz not null default clock_timestamp(),
  duracion_ms   numeric(10,2) not null,

  -- push
  jobs          int,
  aceptados     int,
  duplicados    int,
  conflictos    int,
  invalidos     int,

  -- pull
  entidades     text[],
  filas         int,
  hay_mas       boolean,

  -- Los dos lados del ciclo. RR-07 se mide sobre esto.
  bytes_entrada int not null default 0,
  bytes_salida  int not null default 0
);

-- El acceso normal es "lo último de este colportor".
create index on sync.log (pk_usuario, momento desc);
-- Y el de la purga.
create index on sync.log (momento);

comment on table sync.log is
  'Un registro por ciclo de sync. Purgar con sync.purgar_log(); ver 0005 para '
  'por qué una tabla que crece sin purga agendada no es una opción.';

-- ---------------------------------------------------------------------------
-- La purga, agendada desde el día uno
-- ---------------------------------------------------------------------------

-- La lección de 0005: el TTL documentado y no ejecutado deja crecer la tabla
-- hasta que el índice se degrada y se paga en cada sincronización. Acá el TTL
-- se agenda en la misma migración que crea la tabla, no dos migraciones
-- después.
--
-- 90 días: cubre una temporada de campaña entera, que es la ventana sobre la
-- que tiene sentido comparar un piloto.
create function sync.purgar_log(p_ttl interval default interval '90 days')
returns integer language sql as $$
  with borradas as (
    delete from sync.log where momento < now() - p_ttl returning 1
  )
  select count(*)::int from borradas;
$$;

do $$
begin
  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    raise warning
      'pg_cron no está disponible: agendá `select sync.purgar_log();` a diario '
      'por fuera, o la tabla de telemetría crece sin límite.';
    return;
  end if;

  create extension if not exists pg_cron;

  perform cron.unschedule('sync-purgar-log')
  where exists (select 1 from cron.job where jobname = 'sync-purgar-log');

  perform cron.schedule('sync-purgar-log', '23 4 * * *',
                        $cmd$ select sync.purgar_log(); $cmd$);
end;
$$;

-- ---------------------------------------------------------------------------
-- El push, instrumentado
-- ---------------------------------------------------------------------------

create or replace function sync.push(p_usuario uuid, p_jobs jsonb)
returns jsonb language plpgsql as $$
declare
  v_job      jsonb;
  v_res      jsonb;
  v_results  jsonb := '[]'::jsonb;
  v_arranque timestamptz := clock_timestamp();
  v_ok       int := 0;
  v_dup      int := 0;
  v_conf     int := 0;
  v_inv      int := 0;
  v_salida   jsonb;
begin
  -- En orden: los jobs de una misma entidad se aplican en orden de creación
  -- (§5.5), y un item nunca antes que su venta.
  for v_job in select * from jsonb_array_elements(p_jobs) loop
    v_res := sync.aplicar_job(p_usuario, v_job);
    v_results := v_results || jsonb_build_array(v_res);

    case v_res ->> 'outcome'
      when 'accepted'  then v_ok   := v_ok   + 1;
      when 'duplicate' then v_dup  := v_dup  + 1;
      when 'conflict'  then v_conf := v_conf + 1;
      else                  v_inv  := v_inv  + 1;
    end case;
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'results', v_results
  );

  -- El log va al final y en la misma transacción que el lote: si el push se
  -- cae, no queda una línea de telemetría diciendo que entró algo que no entró.
  insert into sync.log (pk_usuario, operacion, duracion_ms, jobs,
                        aceptados, duplicados, conflictos, invalidos,
                        bytes_entrada, bytes_salida)
  values (p_usuario, 'push',
          extract(epoch from clock_timestamp() - v_arranque) * 1000,
          jsonb_array_length(p_jobs), v_ok, v_dup, v_conf, v_inv,
          octet_length(p_jobs::text), octet_length(v_salida::text));

  return v_salida;
end;
$$;

alter function sync.push(uuid, jsonb) security definer set search_path = sync, public, pg_temp;
revoke execute on function sync.push(uuid, jsonb) from public;

-- ---------------------------------------------------------------------------
-- El pull, instrumentado — pero solo cuando trae algo
-- ---------------------------------------------------------------------------
--
-- Un pull sin novedades es el caso común (el bench lo mide en 1 ms) y hoy es
-- una transacción de solo lectura. Loguearlo lo convertiría en escritura, y eso
-- cuesta dos veces: WAL y vacuum por cada latido de cada colportor, y —peor—
-- **cada pull tomaría un xid y con eso frenaría el horizonte del delta de todos
-- los demás** mientras dura. Con 200 usuarios sincronizando seguido, el
-- horizonte casi nunca avanzaría y las filas quedarían esperando de más.
--
-- Así que se loguea solo el ciclo que entregó filas, que es además el único que
-- aporta algo a la medición de RR-07. Y el insert va como última sentencia, para
-- que el xid se tome lo más tarde posible y se suelte enseguida.

create or replace function sync.pull(
  p_usuario   uuid,
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    int default 500
) returns jsonb language plpgsql as $$
declare
  v_entidad     text;
  v_tabla       regclass;
  v_por_usuario boolean;
  v_desde       jsonb;
  v_filas       jsonb;
  v_rows        jsonb := '{}'::jsonb;
  v_nuevo       jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas     boolean := false;
  v_ultima      jsonb;
  v_horizonte   xid8;
  v_limite      int;
  v_arranque    timestamptz := clock_timestamp();
  v_total       int := 0;
  v_salida      jsonb;
begin
  -- Un límite fuera de rango es un cliente roto o un abuso, no una razón para
  -- devolver 500 (un `limit` negativo es un error de Postgres) ni para armar
  -- una respuesta de un millón de filas.
  v_limite := least(greatest(coalesce(p_limite, 500), 1), 1000);

  -- Una sola vez para todas las entidades: así el corte es el mismo para todas
  -- y el watermark que se devuelve es consistente entre ellas. Ver 0010.
  v_horizonte := pg_snapshot_xmin(pg_current_snapshot());

  foreach v_entidad in array p_entidades loop
    select e.tabla, e.por_usuario into v_tabla, v_por_usuario
    from sync.entidad e where e.nombre = v_entidad;
    continue when v_tabla is null;

    v_desde := coalesce(p_watermark -> v_entidad, '{}'::jsonb);

    execute format($q$
      select coalesce(jsonb_agg(j order by xw, id), '[]'::jsonb)
      from (
        select %s as j, t.xmin_w as xw, t.id as id
        from %s t
        where %s
          and t.xmin_w < $5
          and (t.xmin_w, t.id) > ($2::xid8, $3::uuid)
        order by t.xmin_w, t.id
        limit $4 + 1
      ) s
    $q$,
      sync.expresion_json(v_tabla), v_tabla,
      case when v_por_usuario then 't.pk_usuario = $1' else '($1 is not null)' end)
    into v_filas
    using p_usuario,
          coalesce(v_desde ->> 'xid', '0'),
          coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
          v_limite,
          v_horizonte;

    continue when jsonb_array_length(v_filas) = 0;

    if jsonb_array_length(v_filas) > v_limite then
      v_hay_mas := true;
      v_filas := (select jsonb_agg(f) from (
        select f from jsonb_array_elements(v_filas) f limit v_limite
      ) s);
    end if;

    v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);
    v_total := v_total + jsonb_array_length(v_filas);

    v_ultima := v_filas -> (jsonb_array_length(v_filas) - 1);
    execute format('select to_jsonb(t.xmin_w::text) from %s t where t.id = $1', v_tabla)
      into v_desde using (v_ultima ->> 'id')::uuid;

    v_nuevo := v_nuevo || jsonb_build_object(v_entidad, jsonb_build_object(
      'xid', v_desde #>> '{}',
      'id',  v_ultima ->> 'id'
    ));
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );

  if v_total > 0 then
    insert into sync.log (pk_usuario, operacion, duracion_ms, entidades, filas,
                          hay_mas, bytes_salida)
    values (p_usuario, 'pull',
            extract(epoch from clock_timestamp() - v_arranque) * 1000,
            p_entidades, v_total, v_hay_mas, octet_length(v_salida::text));
  end if;

  return v_salida;
end;
$$;

alter function sync.pull(uuid, text[], jsonb, int)
  security definer set search_path = sync, public, pg_temp;
revoke execute on function sync.pull(uuid, text[], jsonb, int) from public;

-- ---------------------------------------------------------------------------
-- El estado que ve el colportor (RF-SY06)
-- ---------------------------------------------------------------------------

-- Lo que el servidor **puede** contestar. La cola de pendientes y la de error
-- viven en el dispositivo (`engine.errorQueue()`), y el servidor no las conoce:
-- un job que nunca llegó no dejó rastro acá. Devolver un "pendientes: 0" sacado
-- de esta tabla sería mentirle al colportor sobre lo único que le importa.
create function sync.estado(p_usuario uuid, p_ventana interval default interval '24 hours')
returns jsonb language sql stable as $$
  with v as (
    select * from sync.log
    where pk_usuario = p_usuario and momento > now() - p_ventana
  )
  select jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'ultimo_push', (select max(momento) from sync.log
                     where pk_usuario = p_usuario and operacion = 'push'),
    'ultimo_pull', (select max(momento) from sync.log
                     where pk_usuario = p_usuario and operacion = 'pull'),
    'ventana', jsonb_build_object(
      'desde',   to_char((now() - p_ventana) at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'ciclos',  (select count(*) from v),
      'jobs',    (select coalesce(sum(jobs), 0) from v),
      'aceptados',  (select coalesce(sum(aceptados), 0) from v),
      'duplicados', (select coalesce(sum(duplicados), 0) from v),
      'conflictos', (select coalesce(sum(conflictos), 0) from v),
      'invalidos',  (select coalesce(sum(invalidos), 0) from v),
      'filas_bajadas', (select coalesce(sum(filas), 0) from v),
      -- RR-07: lo que el colportor paga de su plan de datos.
      'bytes_entrada', (select coalesce(sum(bytes_entrada), 0) from v),
      'bytes_salida',  (select coalesce(sum(bytes_salida), 0) from v),
      -- p95 y no promedio: RR-02 es un techo, y un techo no se verifica con
      -- una media que un montón de ciclos vacíos empuja hacia abajo.
      'p95_ms', (select round(percentile_cont(0.95)
                   within group (order by duracion_ms)::numeric, 2) from v)
    )
  );
$$;

alter function sync.estado(uuid, interval) security definer set search_path = sync, public, pg_temp;
revoke execute on function sync.estado(uuid, interval) from public;
