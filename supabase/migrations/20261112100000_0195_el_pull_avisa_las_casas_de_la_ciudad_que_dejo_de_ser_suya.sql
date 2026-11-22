-- ============================================================================
-- 0195 · Cuando el área se achica, el pull avisa las casas de la ciudad que dejó de ser suya
--        (backend-supabase#283; seguimiento de la revisión de front-colportores-mobile#712, #181)
--
-- El hueco (hallazgo 3 de la revisión del PR 712, front-colportores-mobile#714): en 0023 el área que se
-- achica sigue con el delta, sin area_reset (decisión del 02/10 en backend-supabase#61, comentario
-- 5958061741: no volver a bajar una ciudad entera, ~100.000 casas y 27 MB). Pero tampoco salía ningún
-- out_of_area, así que las casas de la ciudad que se fue dejaban de actualizarse y la app nunca las
-- marcaba «fuera del área». El contrato §2.1 dice que sí: «Las ubicaciones de una ciudad que dejó de
-- actualizarse, o que salieron del área, se conservan y la app las marca como “fuera del área”». El motor
-- no lo puede deducir solo: la lista de ciudades viaja en el watermark, que para él es opaco.
--
-- ## Qué cambia
--
--   · sync.pull, en el delta de `ubicacion`: si la lista de ciudades del watermark tenía ciudades que la de
--     ahora no tiene (le dieron una zona de una de sus ciudades, terminó una de sus campañas, lo quitaron
--     de una), las casas de esas ciudades van en el `out_of_area` de siempre, junto con las que cambiaron
--     de ciudad en el tramo (0016, 0023). Sale una sola vez: el watermark que vuelve ya lleva la lista
--     nueva. Sigue sin area_reset y sin volver a bajar nada (la decisión del 02/10 no cambia).
--   · Las que registró él no se avisan: siguen bajando siempre (0023). Tampoco una casa que en el tramo
--     pasó a una de sus ciudades de ahora: baja como fila.
--   · Con reinicio (apareció además una ciudad nueva) no hace falta: el motor arranca la entidad de cero
--     y marca lo que no vuelve a bajar (front-colportores-mobile#712). Un watermark sin lista (teléfono de
--     antes de 0023) se compara por la huella, como antes, y no avisa nada.
--   · public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(): ids de las casas de esas ciudades, más
--     las que estaban en una de ellas en el tramo y terminaron fuera del área (pasaron a otra ciudad que
--     tampoco es suya). SECURITY DEFINER, como ubicaciones_que_salieron() (la RLS ya no le deja leer esas
--     casas). Como la lista llega en el watermark, que el teléfono devuelve, solo cuenta las ciudades de
--     una campaña en la que está o estuvo inscripto (viva o dada de baja): no sirve para listar casas de
--     cualquier ciudad. Devuelve solo ids, como el aviso.
--   · Índice nuevo `ubicacion_ciudad_idx` (ciudad_id): el aviso busca las casas por ciudad, también las
--     dadas de baja (ubicacion_direccion_idx es solo de las vivas).
--
-- Mismo contrato con el motor: `out_of_area` = `{"ubicacion": [ids]}`, como desde 0016; no hay clave
-- nueva. El aviso es de una vez y trae todas las casas de la ciudad que se fue que no registró él: en una
-- ciudad grande son ids (unos 39 bytes por casa, ~4 MB por 100.000), contra los 27 MB de volver a bajarla.
--
-- ## Datos existentes
--
-- No se toca ninguna fila. Un teléfono que ya bajó con la lista achicada (antes de esta migración) no
-- recibe el aviso: su watermark ya tiene la lista nueva. Hoy los datos son simulados (producción desde
-- diciembre), así que no se hace nada para ese caso.
--
-- ## Para otros repos
--
--   · front-colportores-mobile: nada que cambiar; el motor ya marca «fuera del área» lo que llega en
--     out_of_area y lo desmarca si vuelve a bajar (#712). Cierra el punto «Backend … area_reset» de #714.
--   · docs-organizacion: contrato §2.1, «El pull avisa lo que salió del área»: sumar que también avisa las
--     casas de una ciudad que dejó de ser suya cuando el área se achica (cambio aditivo, misma clave).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Las casas de las ciudades que dejaron de ser suyas
-- ----------------------------------------------------------------------------

create index ubicacion_ciudad_idx on public.ubicacion (ciudad_id);

create function public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(
  p_ciudades  uuid[],
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
  with ciudades as (
    -- Sus ciudades de trabajo de ahora (las que baja el pull, sync.area_del_pull()).
    select c.ciudad_id
      from public.mis_ciudades_de_trabajo() c (ciudad_id)
  ),
  dejadas as (
    -- Solo ciudades de una campaña en la que está o estuvo inscripto (viva o dada de baja) y que ya no
    -- son suyas: la lista llega en el watermark, que devuelve el teléfono.
    select distinct cc.ciudad_id
      from unnest(p_ciudades) d (ciudad_id)
      join public.campania_ciudad cc on cc.ciudad_id = d.ciudad_id
      join public.campania_colportor cp on cp.campania_id = cc.campania_id
     where cp.usuario_id = auth.uid()
       and cc.ciudad_id not in (select c.ciudad_id from ciudades c)
  ),
  candidatas as (
    -- Las que están hoy en una de esas ciudades...
    select u.id
      from public.ubicacion u
     where u.ciudad_id in (select d.ciudad_id from dejadas d)
    union
    -- ...y las que estaban en una de ellas después del último pull y se fueron a otra.
    select m.ubicacion_id
      from sync.ubicacion_movida m
     where m.ciudad_id in (select d.ciudad_id from dejadas d)
       and (m.xmin_w, m.ubicacion_id) > (p_desde_xid, p_desde_id)
  )
  select k.id
    from candidatas k
    join public.ubicacion u on u.id = k.id
    -- La ciudad al final del tramo: la de antes del primer movimiento posterior; si no hay, la de la
    -- fila (como en ubicaciones_que_salieron()).
    left join lateral (
      select m.ciudad_id
        from sync.ubicacion_movida m
       where m.ubicacion_id = k.id
         and (m.xmin_w, m.ubicacion_id) > (p_hasta_xid, p_hasta_id)
       order by m.xmin_w
       limit 1
    ) sig on true
   where u.created_by is distinct from auth.uid()
     -- al final del tramo no está en sus ciudades de ahora (si está, baja como fila)
     and coalesce(sig.ciudad_id, u.ciudad_id) not in (select c.ciudad_id from ciudades c);
$$;
comment on function public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(uuid[], xid8, uuid, xid8, uuid) is
  'Ids de las ubicaciones de las ciudades de p_ciudades que dejaron de ser ciudades de trabajo del usuario '
  'autenticado (solo ciudades de una campaña en la que está o estuvo inscripto), más las que estaban en una '
  'de ellas en el tramo (desde, hasta] y se fueron a otra que tampoco es suya. Las propias y las que al final '
  'del tramo están en sus ciudades, nunca. Interna del pull: el aviso out_of_area cuando el área se achica (0195).';

revoke all on function public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(uuid[], xid8, uuid, xid8, uuid)
  from public, anon, authenticated, service_role;
-- sync.pull es INVOKER: authenticated necesita EXECUTE sobre el helper. Por PostgREST solo devuelve ids de
-- casas de ciudades de sus campañas que ya no son suyas.
grant execute on function public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(uuid[], xid8, uuid, xid8, uuid)
  to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. El pull las avisa en out_of_area
-- ----------------------------------------------------------------------------

-- Misma firma y cuerpo que en 0148; cambia solo el aviso de salida de `ubicacion`. Los privilegios de
-- sync.pull (0011) siguen: create or replace los conserva.

create or replace function sync.pull(
  p_entidades text[],
  p_watermark jsonb default '{}'::jsonb,
  p_limite    integer default 500,
  p_device    uuid default null,
  p_alcance   text default null
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
  v_previas   text[];
  v_reiniciar boolean;
  v_salieron  uuid[];
begin
  if v_usuario is null then
    raise exception 'sync.pull requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
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

    -- Alcance (0011, 0023): la fila baja si su ubicación la registró él o está en una de sus
    -- ciudades de trabajo (toda la ciudad de su zona; sin zona, todas las de su campaña).
    if v_col_ubic is not null then
      if v_huella is null then
        select a.ciudades, a.huella
          into v_ciudades, v_huella
          from sync.area_del_pull() a;
      end if;

      -- La lista de ciudades que guardó el watermark (0023); el motor lo devuelve tal cual. Algo que
      -- no es una lista cuenta como ausente. Se compara como texto: un elemento raro es una ciudad
      -- que la lista no tenía, y eso solo puede bajar de más, nunca de menos.
      v_previas := null;
      v_salieron := array[]::uuid[];
      if jsonb_typeof(v_desde -> 'ciudades') = 'array' then
        v_previas := array(select jsonb_array_elements_text(v_desde -> 'ciudades'));
      end if;

      -- Con lista: la entidad baja completa solo si apareció una ciudad que el watermark no tenía
      -- (sus filas pueden ser más viejas que el cursor). Lista igual o más chica: el delta sigue, y lo
      -- que quedó afuera deja de actualizarse sin borrarse. Sin lista (un teléfono de antes de 0023,
      -- o con otro alcance): la huella, como antes; ahí hay un solo reinicio y el watermark nuevo
      -- ya lleva la lista.
      if v_previas is not null then
        v_reiniciar := not (v_ciudades::text[] <@ v_previas);
      else
        v_reiniciar := (v_desde ->> 'area') is distinct from v_huella;
      end if;

      -- Si había un watermark de antes, se avisa en area_reset (0016): el área creció y esta
      -- entidad vuelve a bajar desde cero; la ciudad que ya no es suya no se actualiza (el motor no
      -- borra nada de lo que ya tiene).
      if v_reiniciar then
        if v_desde ? 'xid' then
          v_reinicio := v_reinicio || v_entidad;
        end if;
        v_desde := '{}'::jsonb;
      end if;
      -- Se achicó (0195): las ciudades que la lista guardada tenía y la de ahora no. Sus casas dejan de
      -- actualizarse y van en out_of_area (abajo), para que la app las marque «fuera del área» (contrato
      -- §2.1). Solo en delta: con reinicio el motor marca lo que no vuelve a bajar. Un elemento que no es
      -- un id no es ninguna ciudad.
      if v_previas is not null and not v_reiniciar and (v_desde ? 'xid') then
        v_salieron := array(
          select distinct e::uuid
            from unnest(v_previas) e
           where e ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
             and e::uuid <> all (v_ciudades));
      end if;
      -- La lista de ahora, siempre: es la que cuenta en el pull siguiente.
      v_marca := jsonb_build_object('area', v_huella, 'ciudades', to_jsonb(v_ciudades));

      -- Por fila, contra la ubicación (su PK).
      v_filtro := format(
        'and exists (select 1 from public.ubicacion u where u.id = t.%I'
        ' and (u.created_by = $4 or u.ciudad_id = any ($5)))', v_col_ubic);

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
    -- Desde 0148 la columna puede ser una lista separada por coma (baja_a_1,baja_a_2): la fila baja si el
    -- usuario es cualquiera de ellas.
    if v_col_duenio is not null then
      v_filtro := v_filtro || (select ' and (' || string_agg(format('t.%I = $4', c), ' or ' order by c) || ')'
                                 from unnest(string_to_array(v_col_duenio, ',')) c);
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
      -- Con huella (área o mapa), nada debajo del horizonte: todo lo de abajo ya se revisó,
      -- así que el cursor pasa al horizonte (lo que venga tiene un xmin_w mayor o igual) y la
      -- huella, con la lista de ciudades, queda guardada. Sin esto, un área vacía se recorre
      -- entera en cada pull, y el watermark sin la huella nueva haría bajar completa la entidad
      -- otra vez.
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

    -- Lo que salió del área (0016, 0023): las ubicaciones que el teléfono tenía en una de sus
    -- ciudades al último pull y ya no están, porque cambiaron de ciudad en el mismo tramo del
    -- cursor que esta respuesta cubre: del watermark que llegó al nuevo. Solo en delta (con el
    -- área de antes): si el área cambió, la entidad baja completa y va en area_reset.
    -- Desde 0195 también las casas de las ciudades que dejaron de ser suyas porque el área se achicó
    -- (v_salieron): sin reinicio, es la única forma de que el teléfono se entere.
    if v_tabla = 'public.ubicacion'::regclass and (v_desde ? 'xid') and ((v_nuevo -> v_entidad) ? 'xid') then
      select coalesce(jsonb_agg(s.id order by s.id), '[]'::jsonb)
        into v_ids
        from (
          select q.id
            from public.ubicaciones_que_salieron(
                   (v_desde ->> 'xid')::xid8,
                   coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
                   (v_nuevo -> v_entidad ->> 'xid')::xid8,
                   (v_nuevo -> v_entidad ->> 'id')::uuid) q (id)
          union
          select q.id
            from public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(
                   v_salieron,
                   (v_desde ->> 'xid')::xid8,
                   coalesce(v_desde ->> 'id', '00000000-0000-0000-0000-000000000000')::uuid,
                   (v_nuevo -> v_entidad ->> 'xid')::xid8,
                   (v_nuevo -> v_entidad ->> 'id')::uuid) q (id)
           where cardinality(v_salieron) > 0
        ) s;
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
  'Delta por (xmin_w, id) con la RLS del que llama (0002). ubicacion, espacio y house_status bajan '
  'siempre por toda la ciudad de su zona (sin zona, todas las ciudades de su campaña) más lo que '
  'registró él, sin elección (0023, HU-SYNC-011). Su watermark lleva la huella y la lista de '
  'ciudades: bajan completas solo si apareció una ciudad que la lista no tenía; si la lista se '
  'achica, el delta sigue y las casas de la ciudad que se fue van en out_of_area (0195). p_alcance se acepta por compatibilidad y se ignora. El mapa (campania_ciudad, zona, '
  'zona_vertice) baja completo si cambiaron las campañas que ve (0013). Las entidades con '
  'columna_duenio bajan solo las filas del usuario autenticado (0014); si la columna es una lista separada por '
  'coma, las filas donde el usuario es cualquiera de ellas (0148). out_of_area: las ubicaciones '
  'que cambiaron de ciudad en el tramo y las de las ciudades que dejaron de ser suyas (0195); area_reset: las entidades que arrancaron de cero porque '
  'cambió el área (0016).';

