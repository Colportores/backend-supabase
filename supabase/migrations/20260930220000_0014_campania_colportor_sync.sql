-- ============================================================================
-- 0014 · campania_colportor en el sync: la inscripción y la zona llegan al celular
--        (backend-supabase#40)
--
-- Decisión de Cristian del 30/09 en front-coordinadores-web#20 (punto 1): «Se suma
-- campania_colportor al sync, solo con las inscripciones propias (RLS)». Con eso el pull le
-- trae al colportor su campaña y su zona, también cuando cambian (asignar_zona(),
-- quitar_zona(), baja_zona() que lo deja sin zona), y la app avisa al abrirse: «Te asignaron la
-- zona <zona> en <campaña>.» / «Ya no tenés zona en <campaña>.» (el lado móvil va en
-- front-colportores-mobile#178). Contrato de sync 0.9.5, §2 (docs-organizacion#19).
--
-- ## Qué baja
--
-- campania_colportor entra a sync.entidad como pull (la app nunca la escribe: el push responde
-- ENTIDAD_DE_SOLO_LECTURA). Bajan todas las columnas de la fila (id, campania_id, usuario_id,
-- zona_id, meta_libros, auditoría, deleted_at, sync_version), también las inscripciones dadas de
-- baja (su tombstone) y las de campañas terminadas: la app decide qué muestra con las fechas de
-- la campaña, que ya le llegan con `campania`.
--
-- ## Solo las propias
--
-- Para un colportor, la RLS de 0003 ya es «las propias» (usuario_id = auth.uid()). Pero el
-- coordinador y el ADMIN ven todas las inscripciones (la política no se acotó: es de
-- HU-CAM-005), y un coordinador también puede usar la app. Por eso el pull filtra además por
-- dueño: sync.entidad.columna_duenio (nueva) nombra la columna que tiene que ser el usuario
-- autenticado, y sync.pull agrega `and t.<columna> = auth.uid()`. La RLS de la tabla no
-- cambia: el panel y los RPC siguen igual.
--
-- ## Delta
--
-- Una inscripción no cambia de usuario (trigger de identidad, 0005), así que nada se le «abre»
-- a nadie después: el delta por (xmin_w, id) alcanza, sin huella. Toda escritura (asignar,
-- quitar, baja de la zona, meta_libros, soft delete) pasa por tg_auditoria_update, que sube el
-- xmin_w. El índice es (usuario_id, xmin_w, id), como los de jornada o venta (0002).
--
-- ## Datos existentes
--
-- No se toca ninguna fila. La primera vez que cada app pida campania_colportor, baja completa
-- (no tiene watermark).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El registro
-- ----------------------------------------------------------------------------

alter table sync.entidad add column columna_duenio text;

comment on column sync.entidad.columna_duenio is
  'La columna de la fila que es su dueño. Si no es null, el pull baja solo las filas del usuario '
  'autenticado (esa columna = auth.uid()), aunque la RLS le muestre más (0014).';

insert into sync.entidad (nombre, tabla, columna_pk, permite_push, columna_duenio) values
  ('campania_colportor', 'public.campania_colportor'::regclass, 'id', false, 'usuario_id');

create index campania_colportor_delta_idx on public.campania_colportor (usuario_id, xmin_w, id);

-- ----------------------------------------------------------------------------
-- 2. El pull: solo las filas propias en las entidades con columna_duenio
-- ----------------------------------------------------------------------------

-- Misma firma que en 0013. Suma el filtro por dueño; el resto no cambia.

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
  'zona_vertice) baja completo si cambiaron las campañas que ve (0013). Las entidades con '
  'columna_duenio bajan solo las filas del usuario autenticado (0014).';


-- Sin funciones nuevas: los privilegios de sync.pull (0011) siguen.
