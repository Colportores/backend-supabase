-- ============================================================================
-- 0013 · S56: zonas superpuestas permitidas y el mapa solo de las campañas vigentes
--        (backend-supabase#39)
--
-- Decisión de Cristian del 30/09 sobre el supuesto S56 de HU-CAM-006 (docs-organizacion#19,
-- ya en main con docs#20: S56 «Ajustado»). Se confirman los parámetros de 0008 (círculo de 128
-- lados, radio de 1 a 3000 m, esquina a 1 m o menos del borde, campaña terminada sin cambios en
-- el mapa, sin quitar ciudad ni reactivar zona, sin aviso de zona fuera de la ciudad) y cambian
-- tres cosas; la baja que deja sin zona es 0012 (#38). Las otras dos van acá:
--
-- ## 1. Las zonas se pueden superponer
--
-- Sale la regla de 0008 «dos zonas vivas de la misma campania_ciudad no comparten interior» y su
-- tolerancia de 1 m (la erosión de 0,5 m). La zona es solo visual (0011): superponerse no rompe
-- nada, y la UI no marca ni rechaza una zona por tocar o cubrir parte de otra (HU-CAM-006).
--   · guardar_zona() ya no calcula superposiciones ni rechaza con CZ007, y su respuesta pierde
--     la clave `superposiciones` (nadie la leía: bff-coordinadores todavía no llama a
--     guardar_zona, y el panel la simula).
--   · El trigger zona_mapa deja de buscar superposiciones (y de tomar el lock del mapa para
--     eso). Sigue validando la forma (CZ008), el círculo RADIAL y que la zona no cambie de
--     campania_ciudad.
--   · Se van zona_superposicion(), zona_superposiciones() y lanzar_superposicion(). CZ007 deja
--     de usarse y no se reutiliza.
--   · El nombre sigue siendo único por ciudad de la campaña (CZ009), con el lock del mapa.
--
-- ## 2. El colportor ve solo el mapa de sus campañas vigentes
--
-- Antes veía las ciudades, zonas y esquinas de toda campaña con una inscripción viva, vigente o
-- no (0008). Ahora, solo las de sus inscripciones vigentes (mis_campanias_vigentes(): la misma
-- vigencia de mis_zonas() y del pull de ubicaciones). Tampoco ve el de una campaña futura: le
-- llega el día que empieza. El coordinador sigue viendo el mapa de las campañas que coordina,
-- terminadas incluidas (el panel las muestra), y el ADMIN todo.
--   · mis_campanias_del_mapa() (nueva): las campañas cuyo mapa ve. mis_campania_ciudades(), que
--     usan las políticas del mapa, sale de ella.
--   · El sync. Una campaña que empieza vuelve visible un mapa que se cargó antes: sus filas
--     quedan por debajo del watermark y el delta no las traería nunca. Pasa lo mismo al
--     inscribirlo o reactivarlo. Como la huella del área de 0011: el watermark de
--     campania_ciudad, zona y zona_vertice guarda la huella de las campañas que ve ('area': md5
--     de esas campañas y de si es ADMIN), y si cambió, la entidad baja completa. Las marca
--     sync.entidad.sigue_campanias.
--   · Eso reemplaza el republicado del mapa al inscribir (trigger campania_colportor_republicar_mapa
--     de 0008), que se va: ya no hace falta, y hacía bajar el mapa otra vez a todos los demás
--     inscriptos de la campaña.
--   · El servidor no manda borrados por ausencia: cuando una campaña termina, el mapa que ya
--     bajó queda en el teléfono. La app decide qué muestra con la vigencia de la campaña, que
--     le llega con campania_colportor (backend-supabase#40).
--   · La primera vez que cada app sincronice después de esto, el mapa baja completo una vez (su
--     watermark no tiene huella).
--
-- ## Datos existentes
--
-- No se toca ninguna fila: solo cambian funciones, un trigger y una columna nueva con default en
-- sync.entidad. Las zonas superpuestas no existen todavía (0008 las rechazaba).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El mapa que ve cada uno
-- ----------------------------------------------------------------------------

-- Las campañas cuyo mapa ve el usuario autenticado: las que coordina (terminadas incluidas) y
-- las vigentes en las que está inscripto. Sin el ADMIN, que las políticas suman aparte. Un
-- usuario dado de baja no ve nada (ADR-011): el coordinador se filtra acá, el inscripto en
-- mis_campanias_vigentes().
create function public.mis_campanias_del_mapa()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select c.id
    from public.campania c
    join public.usuario u on u.id = c.coordinador_id
   where c.coordinador_id = auth.uid() and u.deleted_at is null
  union
  select v.campania_id from public.mis_campanias_vigentes() v;
$$;

comment on function public.mis_campanias_del_mapa() is
  'Campañas cuyo mapa ve el usuario autenticado: las que coordina y las vigentes en las que está '
  'inscripto (S56, 0013). La usan mis_campania_ciudades() y la huella del mapa en el pull.';

-- Misma firma que en 0008: ahora sale de mis_campanias_del_mapa().
create or replace function public.mis_campania_ciudades()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cc.id
    from public.campania_ciudad cc
   where cc.campania_id in (select public.mis_campanias_del_mapa());
$$;

comment on function public.mis_campania_ciudades() is
  'campania_ciudad visibles para el usuario autenticado: las de mis_campanias_del_mapa() (las '
  'campañas que coordina y las vigentes en las que está inscripto). La usan las políticas del mapa.';

-- ----------------------------------------------------------------------------
-- 2. Sync: la huella de las campañas en el watermark del mapa
-- ----------------------------------------------------------------------------

alter table sync.entidad add column sigue_campanias boolean not null default false;

comment on column sync.entidad.sigue_campanias is
  'Si es true, qué filas ve el usuario depende de las campañas cuyo mapa ve '
  '(mis_campanias_del_mapa()): su watermark lleva la huella de esas campañas y, si cambia, la '
  'entidad baja completa (0013).';

update sync.entidad set sigue_campanias = true where nombre in ('campania_ciudad', 'zona', 'zona_vertice');

-- md5 de las campañas cuyo mapa ve el usuario autenticado, y de si es ADMIN (ve todo). SECURITY
-- INVOKER: solo mira lo del usuario autenticado. Interna del pull.
create function sync.huella_del_mapa()
returns text
language sql
stable
set search_path = ''
as $$
  select md5('mapa|' || case when public.tiene_rol('ADMIN') then 'admin|' else '' end
             || coalesce(string_agg(c.id::text, ',' order by c.id), ''))
    from public.mis_campanias_del_mapa() c (id);
$$;

comment on function sync.huella_del_mapa() is
  'Huella de las campañas cuyo mapa ve el usuario autenticado; va en el watermark de las '
  'entidades con sigue_campanias (0013). Interna.';

-- Misma firma que en 0011. Suma la huella del mapa para las entidades con sigue_campanias, y el
-- cursor al horizonte cuando no hay filas vale para toda entidad con huella. El resto no cambia.

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
    select e.tabla, e.columna_pk, e.columna_ubicacion, e.sigue_campanias
      into v_tabla, v_pk_col, v_col_ubic, v_sigue
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
      if (v_desde ->> 'area') is distinct from v_huella then
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

    -- El mapa (0013): qué filas ve depende de sus campañas (las que coordina y las vigentes en
    -- las que está inscripto). Si cambiaron desde su último pull (empezó o terminó una campaña,
    -- lo inscribieron, le dieron una campaña para coordinar), la entidad baja completa: esas
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
      continue;
    end if;

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
  end loop;

  v_salida := jsonb_build_object(
    'server_time', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'watermark', v_nuevo,
    'has_more', v_hay_mas,
    'rows', v_rows
  );

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
  'zona_vertice) baja completo si cambiaron las campañas que ve (0013).';

-- La huella reemplaza el republicado del mapa al inscribir (ver la cabecera).
drop trigger campania_colportor_republicar_mapa on public.campania_colportor;
drop function public.tg_campania_colportor_republicar_mapa();

-- ----------------------------------------------------------------------------
-- 3. Zonas superpuestas: fuera la regla y su tolerancia
-- ----------------------------------------------------------------------------

-- Igual que en 0008, sin la búsqueda de superposiciones (ni su lock del mapa).
--   · RADIAL: el polígono lo calcula el servidor, siempre (lo que mande el cliente se pisa).
--   · La forma tiene que ser un polígono simple válido (CZ008).
--   · Una zona no cambia de campania_ciudad.
create or replace function public.tg_zona_mapa()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_problema text;
begin
  if tg_op = 'UPDATE' and new.campania_ciudad_id is distinct from old.campania_ciudad_id then
    raise exception 'Una zona no cambia de ciudad ni de campaña. Creá una zona nueva donde corresponda.'
      using errcode = 'check_violation';
  end if;

  -- Ni la forma ni la baja cambian (un cambio de nombre o de color): no hay nada que validar.
  if tg_op = 'UPDATE'
     and (new.tipo_forma, new.centro_lat, new.centro_lon, new.radio_m, new.poligono_geojson, new.deleted_at)
         is not distinct from
         (old.tipo_forma, old.centro_lat, old.centro_lon, old.radio_m, old.poligono_geojson, old.deleted_at) then
    return new;
  end if;

  if new.tipo_forma = 'RADIAL' then
    if new.centro_lat is null or new.centro_lon is null or new.radio_m is null or new.radio_m <= 0 then
      raise exception 'Una zona radial necesita centro y un radio mayor a 0. Marcá el centro en el mapa y elegí el radio.'
        using errcode = 'CZ008';
    end if;
    if new.radio_m > 3000 then
      raise exception 'El radio de la zona «%» es de % m y el máximo es 3000 m. Achicalo, o dividí el área en varias zonas.',
          new.nombre, new.radio_m
        using errcode = 'CZ008';
    end if;
    new.poligono_geojson := public.zona_circulo_geojson(new.centro_lat, new.centro_lon, new.radio_m);
  end if;

  v_problema := public.zona_problema_de_forma(new.poligono_geojson);
  if v_problema is not null then
    raise exception 'El borde de la zona «%» no sirve: %. Volvé a cerrar la forma.', new.nombre, v_problema
      using errcode = 'CZ008';
  end if;

  return new;
end;
$$;

-- Misma firma y mismo comportamiento que en 0011, sin superposiciones (S56): las zonas se
-- pueden superponer, así que no se calculan ni se rechazan (CZ007), y la respuesta ya no trae
-- la clave `superposiciones`.
--
-- Devuelve {"guardada", "zona", "vertices", "poligono_geojson", "ubicaciones_incluidas"}.
create or replace function public.guardar_zona(
  p_campania_ciudad_id uuid,
  p_nombre             text,
  p_tipo_forma         text,
  p_color              text default null,
  p_centro_lat         double precision default null,
  p_centro_lon         double precision default null,
  p_radio_m            integer default null,
  p_vertices           jsonb default null,
  p_poligono_geojson   jsonb default null,
  p_zona_id            uuid default null,
  p_vista_previa       boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cc        public.campania_ciudad;
  v_zona      public.zona;
  v_nombre    text := nullif(btrim(coalesce(p_nombre, '')), '');
  v_vertices  jsonb := coalesce(p_vertices, '[]'::jsonb);
  v_poligono  jsonb;
  v_problema  text;
  v_v         jsonb;
  v_orden     integer;
  v_ordenes   integer[] := array[]::integer[];
  v_incluidas integer;
begin
  if auth.uid() is null then
    raise exception 'guardar_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  -- El permiso primero: sin rol de staff, 42501 antes de mirar ningún dato.
  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if not found then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));
  if v_cc.deleted_at is not null then
    perform public.lanzar_motivo_mapa('CIUDAD_FUERA_DE_CAMPANIA');
  end if;

  -- Un guardado a la vez por ciudad de la campaña: el nombre se valida viendo lo último que
  -- se guardó.
  perform public.bloquear_mapa(v_cc.id);

  if p_zona_id is not null then
    select * into v_zona from public.zona z where z.id = p_zona_id for update;
    if not found or v_zona.deleted_at is not null then
      perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
    end if;
    if v_zona.campania_ciudad_id <> v_cc.id then
      perform public.lanzar_motivo_mapa('ZONA_DE_OTRA_CIUDAD');
    end if;
  end if;

  -- Nombre
  if v_nombre is null then
    raise exception 'La zona necesita un nombre. Escribí uno.' using errcode = 'CZ009';
  end if;
  if exists (select 1 from public.zona z
              where z.campania_ciudad_id = v_cc.id and z.deleted_at is null
                and z.nombre = v_nombre and z.id is distinct from p_zona_id) then
    raise exception 'Ya hay una zona «%» en esta ciudad de la campaña. Elegí otro nombre.', v_nombre
      using errcode = 'CZ009';
  end if;

  -- Color
  if p_color is not null and p_color !~ '^#[0-9A-Fa-f]{6}$' then
    raise exception 'El color tiene que ser #RRGGBB (por ejemplo #3A7BD5). Elegilo de nuevo.'
      using errcode = 'CZ008';
  end if;

  -- Forma
  if p_tipo_forma = 'RADIAL' then
    if p_centro_lat is null or p_centro_lon is null or p_radio_m is null or p_radio_m <= 0 then
      raise exception 'Una zona radial necesita centro y un radio mayor a 0. Marcá el centro en el mapa y elegí el radio.'
        using errcode = 'CZ008';
    end if;
    if p_radio_m > 3000 then
      raise exception 'El radio de la zona es de % m y el máximo es 3000 m. Achicalo, o dividí el área en varias zonas.',
          p_radio_m
        using errcode = 'CZ008';
    end if;
    if p_centro_lat not between -90 and 90 or p_centro_lon not between -180 and 180 then
      raise exception 'El centro de la zona está fuera del mapa. Marcalo de nuevo.'
        using errcode = 'CZ008';
    end if;
    if jsonb_typeof(v_vertices) <> 'array' or jsonb_array_length(v_vertices) > 0 then
      raise exception 'Una zona radial no lleva esquinas. Quitalas o elegí «Por esquinas».'
        using errcode = 'CZ008';
    end if;
    v_poligono := public.zona_circulo_geojson(p_centro_lat, p_centro_lon, p_radio_m);

  elsif p_tipo_forma = 'ESQUINAS' then
    if p_centro_lat is not null or p_centro_lon is not null or p_radio_m is not null then
      raise exception 'Una zona por esquinas no lleva centro ni radio. Quitalos o elegí «Radial».'
        using errcode = 'CZ008';
    end if;
    if jsonb_typeof(v_vertices) <> 'array' or jsonb_array_length(v_vertices) < 3 then
      raise exception 'Una zona por esquinas necesita al menos 3 esquinas (tiene %). Marcá más esquinas en el mapa.',
          case when jsonb_typeof(v_vertices) = 'array' then jsonb_array_length(v_vertices) else 0 end
        using errcode = 'CZ008';
    end if;

    for v_v in select e from jsonb_array_elements(v_vertices) e loop
      if jsonb_typeof(v_v) <> 'object'
         or jsonb_typeof(v_v -> 'orden') is distinct from 'number'
         or jsonb_typeof(v_v -> 'lat') is distinct from 'number'
         or jsonb_typeof(v_v -> 'lon') is distinct from 'number' then
        raise exception 'Una esquina no tiene orden o posición. Volvé a marcar las esquinas.'
          using errcode = 'CZ008';
      end if;
      if (v_v ->> 'orden')::numeric <> trunc((v_v ->> 'orden')::numeric)
         or abs((v_v ->> 'orden')::numeric) > 1000000 then
        raise exception 'El orden de una esquina tiene que ser un número entero. Volvé a marcar las esquinas.'
          using errcode = 'CZ008';
      end if;
      -- Por numeric: un JSON 2.0 llega como el texto «2.0», que ::integer no acepta.
      v_orden := (v_v ->> 'orden')::numeric::integer;
      if v_orden = any (v_ordenes) then
        raise exception 'La esquina % está repetida: cada esquina lleva un orden distinto. Volvé a marcar las esquinas.', v_orden
          using errcode = 'CZ008';
      end if;
      if abs((v_v ->> 'lat')::numeric) > 90 or abs((v_v ->> 'lon')::numeric) > 180 then
        raise exception 'La esquina % está fuera del mapa. Volvé a marcarla.', v_orden
          using errcode = 'CZ008';
      end if;
      v_ordenes := v_ordenes || v_orden;
    end loop;

    -- De acá en adelante el orden va como entero: lo leen los casts de abajo.
    select jsonb_agg(e || jsonb_build_object('orden', (e ->> 'orden')::numeric::integer) order by i)
      into v_vertices
      from jsonb_array_elements(v_vertices) with ordinality x(e, i);

    -- Al menos 3 lugares distintos: una esquina a 1 m o menos de otra de orden menor cuenta
    -- como la misma (la tolerancia con la que se valida el borde, más abajo).
    select count(*) into v_orden
      from jsonb_array_elements(v_vertices) a
     where not exists (
             select 1 from jsonb_array_elements(v_vertices) b
              where (b ->> 'orden')::integer < (a ->> 'orden')::integer
                and extensions.st_dwithin(
                      extensions.geography(extensions.st_setsrid(extensions.st_makepoint(
                        (a ->> 'lon')::double precision, (a ->> 'lat')::double precision), 4326)),
                      extensions.geography(extensions.st_setsrid(extensions.st_makepoint(
                        (b ->> 'lon')::double precision, (b ->> 'lat')::double precision), 4326)),
                      1.0::double precision));
    if v_orden < 3 then
      raise exception 'Una zona por esquinas necesita al menos 3 esquinas en lugares distintos y hay % (dos esquinas a 1 m o menos cuentan como una). Marcá las esquinas que faltan en el mapa.',
          v_orden
        using errcode = 'CZ008';
    end if;

    if p_poligono_geojson is null then
      raise exception 'Falta el borde de la zona, que sigue las calles entre las esquinas. Volvé a cerrar la forma.'
        using errcode = 'CZ008';
    end if;
    v_problema := public.zona_problema_de_forma(p_poligono_geojson);
    if v_problema is not null then
      raise exception 'El borde de la zona no sirve: %. Volvé a cerrar la forma.', v_problema
        using errcode = 'CZ008';
    end if;

    -- El borde tiene que pasar por cada esquina (1 m de tolerancia).
    select min((e ->> 'orden')::integer) into v_orden
      from jsonb_array_elements(v_vertices) e
     where not extensions.st_dwithin(
             extensions.geography(extensions.st_exteriorring(public.zona_geometria(p_poligono_geojson))),
             extensions.geography(extensions.st_setsrid(
               extensions.st_makepoint((e ->> 'lon')::double precision, (e ->> 'lat')::double precision), 4326)),
             1.0::double precision);
    if v_orden is not null then
      raise exception 'El borde no pasa por la esquina %. Volvé a cerrar la forma para que el borde siga las esquinas.', v_orden
        using errcode = 'CZ008';
    end if;
    v_poligono := p_poligono_geojson;

  else
    raise exception 'La forma de la zona tiene que ser RADIAL o ESQUINAS. Elegí «Radial» o «Por esquinas».'
      using errcode = 'CZ008';
  end if;

  v_incluidas := public.zona_ubicaciones_incluidas(v_cc.id, v_poligono);

  if p_vista_previa then
    return jsonb_build_object('guardada', false, 'zona', null, 'vertices', null,
                              'poligono_geojson', v_poligono,
                              'ubicaciones_incluidas', v_incluidas);
  end if;

  if p_zona_id is null then
    insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon,
                             radio_m, poligono_geojson, color, created_by)
    values (v_nombre, v_cc.id, p_tipo_forma, p_centro_lat, p_centro_lon,
            p_radio_m, v_poligono, p_color, auth.uid())
    returning * into v_zona;
  else
    -- Sin cambios no se toca la fila (no sube sync_version).
    update public.zona z
       set nombre = v_nombre, tipo_forma = p_tipo_forma, centro_lat = p_centro_lat,
           centro_lon = p_centro_lon, radio_m = p_radio_m, poligono_geojson = v_poligono,
           color = p_color
     where z.id = p_zona_id
       and (z.nombre, z.tipo_forma, z.centro_lat, z.centro_lon, z.radio_m, z.poligono_geojson, z.color)
           is distinct from
           (v_nombre, p_tipo_forma, p_centro_lat, p_centro_lon, p_radio_m, v_poligono, p_color)
    returning * into v_zona;
    if not found then
      select * into v_zona from public.zona z where z.id = p_zona_id;
    end if;
  end if;

  -- Vértices: se conserva el id de cada orden que sigue; los que se van quedan como baja.
  update public.zona_vertice v
     set deleted_at = now()
   where v.zona_id = v_zona.id and v.deleted_at is null
     and not (v.orden = any (v_ordenes));

  for v_v in select e from jsonb_array_elements(case when p_tipo_forma = 'ESQUINAS'
                                                     then v_vertices else '[]'::jsonb end) e loop
    update public.zona_vertice v
       set lat = (v_v ->> 'lat')::double precision, lon = (v_v ->> 'lon')::double precision,
           calle_a = v_v ->> 'calle_a', calle_b = v_v ->> 'calle_b'
     where v.zona_id = v_zona.id and v.orden = (v_v ->> 'orden')::integer and v.deleted_at is null
       and (v.lat, v.lon, v.calle_a, v.calle_b) is distinct from
           ((v_v ->> 'lat')::double precision, (v_v ->> 'lon')::double precision,
            v_v ->> 'calle_a', v_v ->> 'calle_b');
    if not exists (select 1 from public.zona_vertice v
                    where v.zona_id = v_zona.id and v.orden = (v_v ->> 'orden')::integer
                      and v.deleted_at is null) then
      insert into public.zona_vertice (zona_id, orden, lat, lon, calle_a, calle_b, created_by)
      values (v_zona.id, (v_v ->> 'orden')::integer, (v_v ->> 'lat')::double precision,
              (v_v ->> 'lon')::double precision, v_v ->> 'calle_a', v_v ->> 'calle_b', auth.uid());
    end if;
  end loop;

  return jsonb_build_object(
    'guardada', true,
    'zona', to_jsonb(v_zona) - 'xmin_w',
    'vertices', (select coalesce(jsonb_agg(to_jsonb(v) - 'xmin_w' order by v.orden), '[]'::jsonb)
                   from public.zona_vertice v
                  where v.zona_id = v_zona.id and v.deleted_at is null),
    'poligono_geojson', v_zona.poligono_geojson,
    'ubicaciones_incluidas', v_incluidas);
end;
$$;

comment on function public.guardar_zona(uuid, text, text, text, double precision, double precision,
                                        integer, jsonb, jsonb, uuid, boolean) is
  'Vista 24: crea o edita una zona y sus vértices; con p_vista_previa solo devuelve el polígono '
  'y cuántas ubicaciones incluye («Incluye N ubicaciones»). Las zonas se pueden superponer (S56). '
  'Errores: 42501; CZ001, CZ004, CZ008, CZ009, CZ011, CZ012.';

-- Sin uso desde acá (guardar_zona() y el trigger ya no las llaman).
drop function public.lanzar_superposicion(jsonb);
drop function public.zona_superposiciones(uuid, jsonb, uuid);
drop function public.zona_superposicion(extensions.geometry, extensions.geometry);

-- ----------------------------------------------------------------------------
-- 4. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de
-- la imagen le dan EXECUTE sobre cada función nueva de public (ver 0008).
revoke all on function public.mis_campanias_del_mapa() from public, anon, authenticated;
revoke all on function sync.huella_del_mapa() from public, anon;

-- La huella corre como quien llama al pull (SECURITY INVOKER, como sync.area_del_pull): necesita
-- las dos. Solo miran al usuario autenticado.
grant execute on function public.mis_campanias_del_mapa() to authenticated, service_role;
grant execute on function sync.huella_del_mapa() to authenticated, service_role;
