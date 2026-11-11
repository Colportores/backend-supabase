-- ============================================================================
-- 0016 · El pull avisa las ubicaciones que salieron del área (backend-supabase#37)
--
-- Decisión de Cristian del 30/09 en backend-supabase#32: «el pull avisa las ubicaciones que
-- salieron del área desde el último pull. La app no las borra: las marca como fuera del área y
-- aplica la misma elección visual de S54 (mostrarlas u ocultarlas).» Regla que manda: nunca se
-- borran del teléfono ubicaciones, espacios, personas ni ventas; ocultar es solo visual
-- (R-UB12). Contrato de sync §2.1: «La forma exacta del aviso se acuerda entre el backend y el
-- motor (front-colportores-mobile#178 y #244)». Esta migración trae una PROPUESTA de forma,
-- aditiva, pendiente de ese acuerdo (comentario en backend-supabase#37).
--
-- ## El caso que el teléfono no puede ver
--
-- b1 tiene la zona Z y ya bajó la casa H. Otro corrige H 2 km al norte, fuera de Z (o a una
-- ciudad donde b1 no trabaja). El delta de b1 filtra por su área, así que H no le vuelve a bajar:
-- queda en su teléfono en la posición vieja, adentro de Z, y la app no tiene cómo enterarse.
--
-- ## 1. Registro de movimientos: sync.ubicacion_movida
--
-- El servidor no guarda qué tiene cada teléfono, y la fila de H solo sabe dónde está ahora. Para
-- saber que H ESTABA en el área, un trigger (AFTER UPDATE de posición o ciudad, por cualquier
-- camino: push, RPC o servidor) anota la posición y la ciudad de ANTES, con el xid de la
-- transacción (el mismo xmin_w que la fila). Si la misma transacción la mueve dos veces, queda la
-- primera: la posición de antes de la transacción, la única que un teléfono pudo haber visto.
-- Solo ids, posición y ciudad; nada de personas. Interna: nadie la lee con JWT.
--
-- ## 2. Qué salió del área: public.ubicaciones_que_salieron()
--
-- En un pull en delta (el área es la misma del watermark), para cada ubicación con movimientos en
-- el tramo del cursor que cubre la respuesta, (watermark que llegó, watermark nuevo], la posición
-- que tenía al último pull es la de ANTES de su primer movimiento del tramo, y la que tiene al FINAL
-- del tramo es la de antes de su primer movimiento posterior al tramo o, si no hay, la de la fila.
-- Salió del área si la primera estaba en el área del pull y la segunda no. No sirve la posición de
-- la fila a secas: el snapshot del pull puede ver movimientos que caen después del tramo (con
-- has_more, o si el tramo termina en la última fila entregada), y esos se evalúan en el tramo
-- siguiente: una casa que sale, vuelve y sale otra vez se perdía sin aviso, y una corregida adentro
-- que después salía se avisaba dos veces (revisión del PR #48). El área es la misma regla que el pull
-- (0011, S55, S60): 'zona', dentro del polígono de sus zonas y de la ciudad de cada una; 'ciudad',
-- en su ciudad de trabajo (mis_ciudades_de_trabajo()). Las que registró él nunca salen (siempre
-- bajan). Los tramos de pulls seguidos se tocan sin pisarse, igual que las filas: nada se avisa
-- dos veces ni se pierde, también con has_more.
-- SECURITY DEFINER: la casa pudo irse a una ciudad donde la RLS ya no se la muestra. Va en public,
-- como ubicaciones_de_mi_zona(): en sync solo las purgas son DEFINER (0003_sync_infra_test). Devuelve
-- solo ids de casas que estaban en SU área; el área sale de auth.uid(), no de un parámetro.
--
-- ## 3. La respuesta del pull (propuesta, aditiva)
--
--   out_of_area   {"ubicacion": ["<id>", ...]}  las que salieron del área en este tramo, ordenadas.
--                 Solo si pidió ubicacion y hay alguna. La app las marca «fuera del área» y no
--                 borra nada: ni la ubicación, ni sus espacios, ni su estado, ni lo que cuelga de
--                 ellas. Si una casa vuelve a entrar, baja de nuevo como fila en el delta.
--   area_reset    ["ubicacion", "espacio", "house_status"]  las entidades que este pull arrancó
--                 de cero porque cambió el área (le asignaron o redibujaron la zona, se la
--                 quitaron, cambió de alcance, empezó o terminó una campaña): lo que el teléfono
--                 tenía de antes y no vuelve a bajar hasta que termine la descarga (has_more =
--                 false) quedó fuera del área nueva. Solo si traía un watermark de antes; el
--                 primer pull no lo lleva.
-- Sin avisos, la respuesta es igual que antes: una app que no conoce las claves nuevas no nota
-- nada.
--
-- ## Pendientes (no se deciden acá; comentario en backend-supabase#37)
--
--   · La forma del aviso (nombres, ids por entidad o lista plana) se acuerda con el motor
--     (front-colportores-mobile#178, Bruno).
--   · Cuando cambia el área, el servidor no lista qué salió: no guarda el área vieja. Con
--     area_reset, lo deduce el motor (lo que tenía y no volvió a bajar). Si se quiere la lista del
--     servidor, hace falta guardar el área de cada watermark: al pasar de «ciudad» a «zona» son
--     miles de ids.
--   · Relación con la decisión pendiente de #36 (escrituras con S55): el aviso sigue al área del
--     pull (area_del_pull()/mis_ciudades_de_trabajo()), no a la RLS de escritura; si se elige (b)
--     y cambia qué baja con «ciudad», el aviso lo sigue solo.
--   · sync.ubicacion_movida no se limpia: un teléfono que vuelve después de meses necesita su
--     tramo. Son pocas filas (una por corrección de posición).
--
-- ## Datos existentes
--
-- No se toca ninguna fila. Los movimientos de antes de esta migración no quedaron anotados: una
-- casa que salió del área antes de hoy no se avisa (sigue como antes de 0016).
--
-- ## Para otros repos
--
--   · front-colportores-mobile (motor, #178; app, #244): leer out_of_area y area_reset; marcar
--     «fuera del área» sin borrar nada.
--   · bff-colportores: si reenvía la respuesta del pull, pasar las dos claves nuevas.
--   · docs-organizacion: contrato de sync §2.1, la forma del aviso cuando se acuerde (#19).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Registro de movimientos
-- ----------------------------------------------------------------------------

create table sync.ubicacion_movida (
  xmin_w        xid8 not null default pg_current_xact_id(),
  ubicacion_id  uuid not null references public.ubicacion (id) on delete cascade,
  ciudad_id     uuid not null,
  lat           double precision not null,
  lon           double precision not null,
  created_at    timestamptz not null default now(),
  primary key (xmin_w, ubicacion_id)
);

-- El primer movimiento de una casa después del tramo (ubicaciones_que_salieron()) y el on delete
-- cascade desde ubicacion buscan por casa: la PK arranca por xmin_w.
create index ubicacion_movida_ubicacion_idx on sync.ubicacion_movida (ubicacion_id, xmin_w);

comment on table sync.ubicacion_movida is
  'Cada cambio de posición o ciudad de una ubicación, con la posición y la ciudad de ANTES y el xid '
  'de la transacción (el xmin_w de la fila). De acá sale el aviso out_of_area del pull (0016). '
  'Interna: sin privilegios para anon ni authenticated.';

alter table sync.ubicacion_movida enable row level security;
revoke all on table sync.ubicacion_movida from public, anon, authenticated;
grant all on table sync.ubicacion_movida to service_role;

-- SECURITY DEFINER: escribe en sync aunque la casa la mueva un colportor por el push.
create function public.tg_ubicacion_registrar_movida()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- La primera de la transacción gana: es la posición que un teléfono pudo haber visto.
  insert into sync.ubicacion_movida (ubicacion_id, ciudad_id, lat, lon)
  values (new.id, old.ciudad_id, old.lat, old.lon)
  on conflict (xmin_w, ubicacion_id) do nothing;
  return null;
end;
$$;

comment on function public.tg_ubicacion_registrar_movida() is
  'AFTER UPDATE de ubicacion que la mueve (lat, lon o ciudad): anota la posición y la ciudad de '
  'antes en sync.ubicacion_movida (0016).';

create trigger ubicacion_registrar_movida
  after update on public.ubicacion
  for each row
  when ((old.lat, old.lon, old.ciudad_id) is distinct from (new.lat, new.lon, new.ciudad_id))
  execute function public.tg_ubicacion_registrar_movida();

-- ----------------------------------------------------------------------------
-- 2. Qué salió del área en un tramo del cursor
-- ----------------------------------------------------------------------------

create function public.ubicaciones_que_salieron(
  p_alcance   text,
  p_desde_xid xid8,
  p_desde_id  uuid,
  p_hasta_xid xid8,
  p_hasta_id  uuid
)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  with primera as (
    -- La posición al último pull: la de antes del primer movimiento del tramo.
    select distinct on (m.ubicacion_id) m.ubicacion_id, m.ciudad_id, m.lat, m.lon
      from sync.ubicacion_movida m
     where (m.xmin_w, m.ubicacion_id) > (p_desde_xid, p_desde_id)
       and (m.xmin_w, m.ubicacion_id) <= (p_hasta_xid, p_hasta_id)
     order by m.ubicacion_id, m.xmin_w
  ),
  zonas as (
    -- 'zona': sus zonas, cada una con su ciudad (la misma regla que ubicaciones_de_mi_zona()).
    select public.zona_geometria(z.poligono_geojson) as geom, cc.ciudad_id
      from public.zona z
      join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
     where p_alcance = 'zona'
       and z.id in (select public.mis_zonas())
  ),
  ciudades as (
    -- 'ciudad': su ciudad de trabajo (S55), la misma que area_del_pull().
    select c.ciudad_id
      from public.mis_ciudades_de_trabajo() c (ciudad_id)
     where p_alcance = 'ciudad'
  )
  select p.ubicacion_id
    from primera p
    join public.ubicacion u on u.id = p.ubicacion_id
    -- La posición al final del tramo: la de antes del primer movimiento posterior; si no hay, la
    -- de la fila.
    left join lateral (
      select m.ciudad_id, m.lat, m.lon
        from sync.ubicacion_movida m
       where m.ubicacion_id = p.ubicacion_id
         and (m.xmin_w, m.ubicacion_id) > (p_hasta_xid, p_hasta_id)
       order by m.xmin_w
       limit 1
    ) sig on true
    cross join lateral (
      select coalesce(sig.ciudad_id, u.ciudad_id) as ciudad_id,
             coalesce(sig.lat, u.lat) as lat,
             coalesce(sig.lon, u.lon) as lon
    ) fin
   where u.created_by is distinct from auth.uid()
     -- estaba en el área
     and (exists (select 1 from zonas z
                   where z.ciudad_id = p.ciudad_id
                     and extensions.st_covers(z.geom, public.ubicacion_geometria(p.lat, p.lon)))
          or p.ciudad_id in (select c.ciudad_id from ciudades c))
     -- y al final del tramo ya no
     and not (exists (select 1 from zonas z
                       where z.ciudad_id = fin.ciudad_id
                         and extensions.st_covers(z.geom, public.ubicacion_geometria(fin.lat, fin.lon)))
              or fin.ciudad_id in (select c.ciudad_id from ciudades c));
$$;

comment on function public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid) is
  'Ids de las ubicaciones que estaban en el área del pull del usuario autenticado (alcance zona o '
  'ciudad) al principio del tramo (desde, hasta] del cursor y al final del tramo ya no, porque se '
  'movieron. '
  'Las propias nunca. Interna del pull (0016).';

revoke all on function public.tg_ubicacion_registrar_movida(),
  public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid)
  from public, anon, authenticated;
-- sync.pull es INVOKER: authenticated necesita EXECUTE sobre el helper. Por PostgREST cualquiera lo
-- puede llamar, como ubicaciones_de_mi_zona(): solo devuelve ids de casas que estaban en SU área.
grant execute on function public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid)
  to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. El pull: out_of_area y area_reset
-- ----------------------------------------------------------------------------

-- Misma firma que en 0014: el resto no cambia. El lote vacío ya no corta la vuelta con continue,
-- para que el aviso se calcule también cuando no hay filas nuevas en el área.
create or replace function sync.pull(
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    integer default 500,
  p_device    uuid default null,
  p_alcance   text default 'zona'
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_entidad   text;
  v_tabla     regclass;
  v_pk_col    text;
  v_col_ubic  text;
  v_desde     jsonb;
  v_lote      jsonb;
  v_filas     jsonb;
  v_rows      jsonb := '{}'::jsonb;
  v_nuevo     jsonb := coalesce(p_watermark, '{}'::jsonb);
  v_hay_mas   boolean := false;
  v_ultima    jsonb;
  v_horizonte xid8;
  v_limite    integer;
  v_arranque  timestamptz := clock_timestamp();
  v_total     integer := 0;
  v_salida    jsonb;
  v_usuario   uuid := auth.uid();
  v_alcance   text := coalesce(p_alcance, 'zona');
  v_ciudades  uuid[];
  v_huella    text;
  v_filtro    text;
  v_marca     jsonb;
  v_sigue     boolean;
  v_huella_mapa text;
  v_col_duenio text;
  v_fuera     jsonb := '{}'::jsonb;
  v_reinicio  text[] := array[]::text[];
  v_ids       jsonb;
begin
  if v_usuario is null then
    raise exception 'sync.pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- S60 (decisión de Cristian del 30/09): si el colportor no eligió, 'zona' (su zona y lo propio).
  if v_alcance not in ('zona', 'ciudad') then
    raise exception 'El alcance del pull tiene que ser «zona» o «ciudad», y llegó «%». Actualizá la app.',
        v_alcance
      using errcode = 'invalid_parameter_value';
  end if;

  -- Un límite fuera de rango es un cliente roto o un abuso: se acota y se sigue (0002).
  v_limite := least(greatest(coalesce(p_limite, 500), 1), 1000);

  -- Una sola vez para todas las entidades: el corte es el mismo para todas (0002).
  v_horizonte := pg_snapshot_xmin(pg_current_snapshot());

  foreach v_entidad in array coalesce(p_entidades, array[]::text[]) loop
    select e.tabla, e.columna_pk, e.columna_ubicacion, e.sigue_campanias, e.columna_duenio
      into v_tabla, v_pk_col, v_col_ubic, v_sigue, v_col_duenio
      from sync.entidad e where e.nombre = v_entidad;
    -- Una entidad que el servidor no conoce se ignora (0002).
    continue when v_tabla is null;

    -- Un watermark sin `xid` arranca de cero (0002).
    v_desde := coalesce(p_watermark -> v_entidad, '{}'::jsonb);
    v_filtro := '';
    v_marca := '{}'::jsonb;

    -- Alcance (0011): la fila baja si su ubicación la registró él o está en su área.
    if v_col_ubic is not null then
      if v_huella is null then
        select a.ciudades, a.huella
          into v_ciudades, v_huella
          from sync.area_del_pull(v_alcance) a;
      end if;

      -- Otra área que la del watermark (o un watermark sin huella): esta entidad baja completa.
      -- Si había un watermark de antes, se avisa en area_reset (0016): lo que el teléfono tenía y
      -- no vuelve a bajar quedó fuera del área nueva.
      if (v_desde ->> 'area') is distinct from v_huella then
        if v_desde ? 'xid' then
          v_reinicio := v_reinicio || v_entidad;
        end if;
        v_desde := '{}'::jsonb;
      end if;
      v_marca := jsonb_build_object('area', v_huella);

      -- 'zona': el conjunto sale una vez por consulta, del índice GiST (ubicaciones_de_mi_zona()).
      -- 'ciudad': por fila, contra la ubicación (su PK).
      v_filtro := case v_alcance
        when 'ciudad' then format(
          'and exists (select 1 from public.ubicacion u where u.id = t.%I'
          ' and (u.created_by = $4 or u.ciudad_id = any ($5)))', v_col_ubic)
        else format('and t.%I in (select public.ubicaciones_de_mi_zona())', v_col_ubic)
      end;

    -- El mapa (0013): qué filas ve depende de sus campañas (las que coordina y las que no
    -- terminaron en las que está inscripto). Si cambiaron desde su último pull (terminó una
    -- campaña, lo inscribieron, le dieron una campaña para coordinar), la entidad baja completa: esas
    -- filas pueden ser más viejas que su watermark. La RLS decide qué filas; acá no hay filtro.
    elsif v_sigue then
      if v_huella_mapa is null then
        v_huella_mapa := sync.huella_del_mapa();
      end if;
      if (v_desde ->> 'area') is distinct from v_huella_mapa then
        v_desde := '{}'::jsonb;
      end if;
      v_marca := jsonb_build_object('area', v_huella_mapa);
    end if;

    -- Solo las filas propias (0014): la RLS le puede mostrar más (el coordinador y el ADMIN
    -- ven todas las inscripciones), pero al teléfono baja solo lo suyo. Usa el índice
    -- (dueño, xmin_w, id).
    if v_col_duenio is not null then
      v_filtro := v_filtro || format(' and t.%I = $4', v_col_duenio);
    end if;

    -- Una fila de más para saber si hay más; el xmin_w viaja al lado de la fila (0002).
    execute format($q$
      select coalesce(jsonb_agg(jsonb_build_object('j', j, 'xw', xw::text, 'id', id)
                                order by xw, id), '[]'::jsonb)
      from (
        select %s as j, t.xmin_w as xw, t.%I as id
        from %s t
        where t.xmin_w < $3
          and (t.xmin_w, t.%I) > ($1::xid8, $2::uuid)
          %s
        order by t.xmin_w, t.%I
        limit %s
      ) s
    $q$,
      sync.expresion_json(v_tabla), v_pk_col, v_tabla, v_pk_col, v_filtro, v_pk_col,
      (v_limite + 1)::text)
    into v_lote
    using coalesce(v_desde ->> 'xid', '0'),
          coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
          v_horizonte, v_usuario, v_ciudades;

    if jsonb_array_length(v_lote) = 0 then
      -- Con huella (alcance o mapa), nada debajo del horizonte: todo lo de abajo ya se revisó,
      -- así que el cursor pasa al horizonte (lo que venga tiene un xmin_w mayor o igual) y la
      -- huella queda guardada. Sin esto, un área vacía se recorre entera en cada pull, y el
      -- watermark sin la huella nueva haría bajar completa la entidad otra vez.
      if v_marca <> '{}'::jsonb then
        v_nuevo := v_nuevo || jsonb_build_object(v_entidad,
          jsonb_build_object('xid', v_horizonte::text, 'id', '00000000-0000-0000-0000-000000000000')
          || v_marca);
      end if;
    else
      if jsonb_array_length(v_lote) > v_limite then
        v_hay_mas := true;
        v_lote := (select jsonb_agg(e) from (
          select e from jsonb_array_elements(v_lote) e limit v_limite
        ) s);
      end if;

      v_filas := (select jsonb_agg(e -> 'j') from jsonb_array_elements(v_lote) e);

      -- Una entidad ausente de `rows` significa "sin cambios" (0002).
      v_rows := v_rows || jsonb_build_object(v_entidad, v_filas);
      v_total := v_total + jsonb_array_length(v_filas);

      v_ultima := v_lote -> (jsonb_array_length(v_lote) - 1);
      v_nuevo := v_nuevo || jsonb_build_object(v_entidad,
        jsonb_build_object('xid', v_ultima ->> 'xw', 'id', v_ultima ->> 'id') || v_marca);
    end if;

    -- Lo que salió del área (0016): las ubicaciones que el teléfono tenía en su área al último
    -- pull y ya no están, porque se movieron (otra posición u otra ciudad) en el mismo tramo del
    -- cursor que esta respuesta cubre: del watermark que llegó al nuevo. Solo en delta (con el
    -- área de antes): si el área cambió, la entidad baja completa y va en area_reset.
    if v_tabla = 'public.ubicacion'::regclass and (v_desde ? 'xid') and ((v_nuevo -> v_entidad) ? 'xid') then
      select coalesce(jsonb_agg(s.id order by s.id), '[]'::jsonb)
        into v_ids
        from public.ubicaciones_que_salieron(
               v_alcance,
               (v_desde ->> 'xid')::xid8,
               coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
               (v_nuevo -> v_entidad ->> 'xid')::xid8,
               (v_nuevo -> v_entidad ->> 'id')::uuid) s (id);
      if jsonb_array_length(v_ids) > 0 then
        v_fuera := v_fuera || jsonb_build_object(v_entidad, v_ids);
      end if;
    end if;
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );
  -- Claves nuevas (0016), solo si hay algo: una respuesta sin avisos es igual que antes.
  if v_fuera <> '{}'::jsonb then
    v_salida := v_salida || jsonb_build_object('out_of_area', v_fuera);
  end if;
  if cardinality(v_reinicio) > 0 then
    v_salida := v_salida || jsonb_build_object('area_reset', to_jsonb(v_reinicio));
  end if;

  -- Un pull sin novedades no escribe nada: tomaría un xid y frenaría el horizonte de todos (0002).
  if v_total > 0 then
    insert into sync.log (device_id, operacion, duracion_ms, entidades, filas, hay_mas, bytes_salida)
    values (p_device, 'pull',
            extract(epoch from clock_timestamp() - v_arranque) * 1000,
            p_entidades, v_total, v_hay_mas, octet_length(v_salida::text));
  end if;

  return v_salida;
end;
$$;

comment on function sync.pull(text[], jsonb, integer, uuid, text) is
  'Delta por (xmin_w, id) con la RLS del que llama (0002). p_alcance (0011, HU-SYNC-011): '
  '''zona'' (default) o ''ciudad''; ubicacion, espacio y house_status bajan según ese alcance, y '
  'bajan completas si cambió el área (huella en el watermark). El mapa (campania_ciudad, zona, '
  'zona_vertice) baja completo si cambiaron las campañas que ve (0013). Las entidades con '
  'columna_duenio bajan solo las filas del usuario autenticado (0014). out_of_area: las ubicaciones '
  'que salieron del área en el tramo; area_reset: las entidades que arrancaron de cero porque '
  'cambió el área (0016).';

-- Sin funciones públicas nuevas: los privilegios de sync.pull (0011) siguen.
