-- El `device_id` del sobre (§5.3) llega a la base — F4 del plan de sync.
--
-- El BFF ya recibe el sobre y responde `426` a un `schema_version` viejo, pero
-- hasta acá lo validaba y lo tiraba. Sin el dispositivo en la base pasan tres
-- cosas, todas de multi-dispositivo:
--
--   * La telemetría de 0011 mide "bytes por colportor", no por dispositivo. Si
--     un colportor tiene el teléfono viejo y el nuevo y **uno de los dos**
--     sincroniza mal, los dos se suman en la misma fila y no se ve.
--   * No hay forma de cerrar la sesión de un dispositivo perdido sin cerrar
--     todas: no existe con qué distinguirlo.
--   * Un `duplicate` no dice quién lo mandó, que es justo el dato que sirve
--     cuando dos dispositivos del mismo colportor reintentan el mismo op.
--
-- Las dos columnas son **nullable a propósito**: las filas anteriores a esta
-- migración no tienen dispositivo y no se puede inventar, y un cliente sin
-- sobre ya no llega hasta acá (lo corta el 426 del BFF).

alter table sync.log      add column device_id uuid;
alter table sync.op_cache add column device_id uuid;

comment on column sync.log.device_id is
  'Qué instalación hizo este ciclo. Null en filas anteriores a 0014.';
comment on column sync.op_cache.device_id is
  'Qué instalación aplicó este op primero. No se pisa en un reintento: el '
  'interés es quién lo aplicó, no quién lo reintentó.';

-- Sin índice por `device_id`, y a propósito. Las consultas por dispositivo son
-- analíticas —se corren al mirar el piloto, no en cada sync— y sobre una tabla
-- que la purga de 0011 mantiene en 90 días. Un índice de más se paga en cada
-- escritura de cada colportor, todo el día, para acelerar una consulta que se
-- hace de vez en cuando. Si la Fase 3 muestra que hace falta, se agrega ahí.

-- ---------------------------------------------------------------------------
-- El push
-- ---------------------------------------------------------------------------
--
-- Se **dropea** la versión de dos argumentos en vez de dejarla conviviendo: si
-- quedara, un llamador que no se actualizó seguiría funcionando y registrando
-- dispositivo nulo en silencio. Que falle en el deploy es mejor que descubrir
-- meses después que media telemetría está vacía.
drop function sync.push(uuid, jsonb);

create function sync.push(p_usuario uuid, p_jobs jsonb,
                          p_device uuid default null)
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
  v_ops      uuid[] := '{}';
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

    -- El op_id sale del **resultado**, no del job crudo: ahí ya pasó por
    -- `aplicar_job` y es un uuid o es null. Castear el texto que mandó el
    -- cliente acá afuera, donde no hay bloque `exception` que lo contenga,
    -- convertiría un client_op_id malformado en un 500 que tumba el lote
    -- entero — exactamente lo que 0002 se ocupa de evitar.
    if v_res ->> 'client_op_id' is not null then
      v_ops := v_ops || ((v_res ->> 'client_op_id')::uuid);
    end if;
  end loop;

  -- El dispositivo en el cache se estampa acá y no dentro de `aplicar_job`
  -- porque esa función ya la redefinieron enteras 0008 y 0010: copiar 120
  -- líneas más para agregar un parámetro es la forma segura de que las
  -- versiones se separen. Un solo UPDATE por push, contra la PK.
  --
  -- `device_id is null` protege el reintento: si el op ya estaba en el cache
  -- porque lo aplicó **otro** dispositivo, la fila conserva al primero. Es la
  -- pregunta que importa —quién lo aplicó— y no quién lo repitió.
  if p_device is not null and array_length(v_ops, 1) is not null then
    update sync.op_cache
       set device_id = p_device
     where client_op_id = any (v_ops)
       and device_id is null;
  end if;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'results', v_results
  );

  -- El log va al final y en la misma transacción que el lote: si el push se
  -- cae, no queda una línea de telemetría diciendo que entró algo que no entró.
  insert into sync.log (pk_usuario, device_id, operacion, duracion_ms, jobs,
                        aceptados, duplicados, conflictos, invalidos,
                        bytes_entrada, bytes_salida)
  values (p_usuario, p_device, 'push',
          extract(epoch from clock_timestamp() - v_arranque) * 1000,
          jsonb_array_length(p_jobs), v_ok, v_dup, v_conf, v_inv,
          octet_length(p_jobs::text), octet_length(v_salida::text));

  return v_salida;
end;
$$;

alter function sync.push(uuid, jsonb, uuid) security definer set search_path = sync, public, pg_temp;
revoke execute on function sync.push(uuid, jsonb, uuid) from public;

-- ---------------------------------------------------------------------------
-- El pull
-- ---------------------------------------------------------------------------
--
-- Cuerpo idéntico al de 0011 salvo el `device_id` del log. Se copia entero
-- porque el insert está adentro, y tiene que seguir siendo la última sentencia
-- por lo del xid (ver 0011).
--
-- Acá `p_device` va **al final y con default**: los tests y el bench llaman
-- posicionalmente con 2, 3 y 4 argumentos, y moverlo adelante los rompería a
-- todos sin que eso pruebe nada.
drop function sync.pull(uuid, text[], jsonb, int);

create function sync.pull(
  p_usuario   uuid,
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    int default 500,
  p_device    uuid default null
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
    insert into sync.log (pk_usuario, device_id, operacion, duracion_ms,
                          entidades, filas, hay_mas, bytes_salida)
    values (p_usuario, p_device, 'pull',
            extract(epoch from clock_timestamp() - v_arranque) * 1000,
            p_entidades, v_total, v_hay_mas, octet_length(v_salida::text));
  end if;

  return v_salida;
end;
$$;

alter function sync.pull(uuid, text[], jsonb, int, uuid)
  security definer set search_path = sync, public, pg_temp;
revoke execute on function sync.pull(uuid, text[], jsonb, int, uuid) from public;
