-- ============================================================================
-- 0023 · El pull baja siempre toda la ciudad de su zona (backend-supabase#58)
--
-- Decisión de Cristian del 02/10 en front-colportores-mobile#244 (comentario 5952408648):
-- «cada teléfono baja todas las ubicaciones de la ciudad de su zona; sin zona, todas las ciudades
-- de la campaña; ya no hay elección.» HU-SYNC-011 (docs-organizacion#26) y el contrato de sync
-- v0.9.8, §2.1. Regla que manda, sin cambios: del teléfono no se borra ninguna ubicación, espacio,
-- persona ni venta (R-UB12).
--
-- ## Qué cambia
--
-- Hasta hoy el pull tenía dos alcances (0011): 'zona' (el default: lo propio más lo que cae en el
-- polígono de su zona) y 'ciudad' (todas las de sus ciudades de trabajo). El colportor ya no elige,
-- y la zona no acota la descarga: acota solo lo que se ve de la ciudad, y eso es visual. Queda el
-- alcance que antes se llamaba 'ciudad', que ya es la regla de lectura de la RLS:
-- mis_ciudades_de_trabajo() (0013) es la ciudad de su zona o, sin zona, todas las de las campañas
-- en las que está inscripto y que no terminaron (en curso o por empezar).
--
--   · sync.pull: sin la rama «zona». p_alcance queda en la firma para que un motor viejo no se rompa,
--     y se ignora: no se valida ni cambia lo que baja (contrato 0.9.8: «el servidor, si la recibe, la
--     ignora»; el motor deja de mandarla en front-colportores-mobile#178). Ya no hay 22023.
--   · sync.area_del_pull() pierde el parámetro: la huella del área es la de las ciudades de trabajo,
--     con la misma fórmula que tenía 'ciudad' (md5('ciudad|' || ids ordenados)). Un teléfono que ya
--     bajaba «toda la ciudad» no vuelve a bajar nada.
--   · public.ubicaciones_de_mi_zona() se va: solo la usaba la rama «zona» del pull.
--   · public.ubicaciones_que_salieron() pierde el alcance y la rama de zonas: una casa sale del área
--     cuando cambia de ciudad (ya no cuando se corrige dentro de la misma ciudad: sigue bajando como
--     fila, porque sigue en el área). Cambia solo cómo se lee el registro de movimientos:
--   · sync.ubicacion_movida NO cambia (decisión del 02/10, comentario 5957800802): el trigger sigue
--     anotando cada cambio de posición o de ciudad, con la posición y la ciudad de antes, y no se
--     quitan columnas. Es un registro técnico interno (ids, posición y ciudad; sin ventas ni
--     personas). Lo que cambia es la lectura: el aviso out_of_area mira solo la ciudad. Una
--     corrección de posición dentro de la misma ciudad queda anotada y no avisa nada.
--   · El watermark de las entidades por ciudad guarda también la lista de ciudades (siguiente
--     sección), para no volver a bajar lo que ya está cuando el área se achica.
--
-- ## El watermark guarda la lista de ciudades (decisión del 02/10, comentario 5958061741)
--
-- La huella sola no sabe si el área creció o se achicó. Un colportor sin zona que ya bajó c1 y c2 y
-- recibe una zona de c1 (o al que le termina una de sus dos campañas) volvía a bajar c1 entera: en
-- una ciudad real son unas 100.000 casas, 27 MB y unos 5 minutos en 3G, muchas veces con datos
-- móviles. Eso contradice lo escrito en HU-SYNC-011 y el contrato §2.1. Ahora el watermark de cada
-- entidad con columna_ubicacion (ubicacion, espacio y house_status) lleva, junto a la huella
-- (`area`), la lista ACTUAL de ciudades (`ciudades`: ids). El servidor ya armaba ese watermark y
-- el motor lo devuelve tal cual, así que no cambia el contrato con el motor.
--
--   · area_reset (la entidad arranca de cero) solo si la lista nueva tiene una ciudad que la del
--     watermark no tenía: sus casas pueden ser más viejas que el cursor.
--   · Lista igual o más chica: sigue el delta, sin area_reset, y se guarda la lista nueva. Lo que
--     quedó afuera deja de actualizarse y no se borra nada.
--   · Si después vuelve a crecer (c1 → c1 y c2), c2 no está en la lista guardada: hay reset, porque
--     sus casas pueden estar viejas y por debajo del cursor.
--   · Un watermark sin lista (un teléfono que bajó antes de esta migración, o con el alcance
--     «zona») se compara por la huella, como hasta hoy: una sola vez, y el watermark que sale ya
--     lleva la lista. Una lista que no es una lista se trata como ausente.
--   · Límite conocido: el reinicio vuelve a bajar toda la lista de ciudades, no solo la nueva (que
--     llegue una ciudad es el caso raro; así no hace falta un cursor por ciudad).
--
-- ## Zonas, ciudades y qué pasa cuando cambian
--
--   · Le asignan o le cambian la zona dentro de la MISMA ciudad: la lista de ciudades no cambia, no
--     baja nada nuevo (HU-SYNC-011: «el cambio de zona dentro de la misma ciudad no descarga nada»).
--   · Le asignan una zona de OTRA ciudad, o lo inscriben en otra campaña: si esa ciudad no estaba
--     en la lista del watermark, la entidad baja completa (area_reset trae las que arrancaron de
--     cero). La ciudad vieja, si ya no es suya, deja de actualizarse: sus filas se quedan en el
--     teléfono, no se manda ningún borrado. Una casa de la ciudad vieja que se mueve o se edita ya
--     no le llega; lo que cargó sin señal ahí sube igual por el push (las escrituras siguen
--     acotadas por mis_ciudades_de_campania(), 0020/0021, no por esta migración).
--   · Le dan una zona de una de las ciudades que ya tenía (sin zona, c1 y c2 → zona de c1), o termina
--     una de sus campañas: la lista se achica, el delta sigue y no baja nada de nuevo.
--   · Sin zona: todas las ciudades de su campaña. Una campaña por empezar también baja (0013).
--   · El colportor que registró una casa la sigue recibiendo siempre, esté o no en su ciudad.
--   · Una casa que sale de su ciudad (otro la corrige a otra ciudad) se avisa en out_of_area, y la
--     app la marca «fuera del área»; no se borra.
--
-- ## Datos existentes
--
-- No se toca ninguna fila de negocio ni de ubicacion_movida. Todos los watermarks de antes de esta
-- migración son sin lista. Uno que había bajado con 'zona' tiene en su watermark la huella vieja
-- ('zona|...'): en su primer pull después de esta migración la huella no coincide, las tres
-- entidades (ubicacion, espacio, house_status) bajan completas y el pull trae area_reset. Es una
-- vez, y lo que baja es un superconjunto de lo que tenía (toda su ciudad); el watermark que recibe
-- ya lleva la lista. Quien ya usaba 'ciudad' no nota nada: su huella coincide, y el watermark pasa a
-- llevar la lista.
--
-- ## Para otros repos
--
--   · front-colportores-mobile (motor, #178; app, #244): dejar de mandar el alcance (el servidor lo
--     ignora desde esta migración, así que no hay apuro ni orden de despliegue); sacar la elección
--     «mi zona» / «toda la ciudad» de Ajustes; ante area_reset, no borrar nada: solo volver a bajar;
--     ante out_of_area, marcar «fuera del área». El watermark trae una clave nueva (`ciudades`) dentro
--     de cada entidad: el motor ya lo guarda y lo devuelve entero, no cambia nada de su lado.
--   · docs-organizacion: README/contrato ya dicen «toda la ciudad» (0.9.8); el contrato aún dice que
--     el aviso de salida es una propuesta pendiente de #178. El watermark de esas entidades lleva
--     `area` y `ciudades`, opacos para el motor (§2.1).
--   · bff-colportores: en pausa (ADR-013); si algún día reenvía el pull, no hay parámetro que pasar.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Registro de movimientos: igual que en 0016, solo el comentario
-- ----------------------------------------------------------------------------

-- El trigger y las columnas no se tocan: se sigue anotando cada cambio de posición o de ciudad.
comment on table sync.ubicacion_movida is
  'Cada cambio de posición o ciudad de una ubicación, con la posición y la ciudad de ANTES y el xid '
  'de la transacción (el xmin_w de la fila). De acá sale el aviso out_of_area del pull (0016), que '
  'desde 0023 mira solo la ciudad. Interna: sin privilegios para anon ni authenticated.';

-- ----------------------------------------------------------------------------
-- 2. Qué salió del área en un tramo del cursor: cambió a una ciudad que no es suya
-- ----------------------------------------------------------------------------

drop function public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid);

create function public.ubicaciones_que_salieron(
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
    -- La ciudad al último pull: la de antes del primer movimiento del tramo (si ese movimiento fue
    -- solo de posición, es la misma ciudad que tiene ahora y no hay nada que avisar).
    select distinct on (m.ubicacion_id) m.ubicacion_id, m.ciudad_id
      from sync.ubicacion_movida m
     where (m.xmin_w, m.ubicacion_id) > (p_desde_xid, p_desde_id)
       and (m.xmin_w, m.ubicacion_id) <= (p_hasta_xid, p_hasta_id)
     order by m.ubicacion_id, m.xmin_w
  ),
  ciudades as (
    -- Sus ciudades de trabajo (S55), las mismas que baja el pull (sync.area_del_pull()).
    select c.ciudad_id
      from public.mis_ciudades_de_trabajo() c (ciudad_id)
  )
  select p.ubicacion_id
    from primera p
    join public.ubicacion u on u.id = p.ubicacion_id
    -- La ciudad al final del tramo: la de antes del primer movimiento posterior; si no hay, la de la
    -- fila.
    left join lateral (
      select m.ciudad_id
        from sync.ubicacion_movida m
       where m.ubicacion_id = p.ubicacion_id
         and (m.xmin_w, m.ubicacion_id) > (p_hasta_xid, p_hasta_id)
       order by m.xmin_w
       limit 1
    ) sig on true
   where u.created_by is distinct from auth.uid()
     -- estaba en el área
     and p.ciudad_id in (select c.ciudad_id from ciudades c)
     -- y al final del tramo ya no
     and coalesce(sig.ciudad_id, u.ciudad_id) not in (select c.ciudad_id from ciudades c);
$$;

comment on function public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid) is
  'Ids de las ubicaciones que estaban en una de las ciudades de trabajo del usuario autenticado al '
  'principio del tramo (desde, hasta] del cursor y al final del tramo ya no, porque cambiaron de '
  'ciudad. Las propias nunca. Interna del pull (0016, 0023).';

revoke all on function public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)
  from public, anon, authenticated;
-- sync.pull es INVOKER: authenticated necesita EXECUTE sobre el helper. Por PostgREST cualquiera lo
-- puede llamar: solo devuelve ids de casas que estaban en SUS ciudades de trabajo.
grant execute on function public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)
  to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3. La huella del área: la de sus ciudades de trabajo
-- ----------------------------------------------------------------------------

drop function sync.area_del_pull(text);
-- Solo la rama «zona» del pull la usaba.
drop function public.ubicaciones_de_mi_zona();

-- SECURITY INVOKER, como antes: lee sus ciudades con la RLS del mapa. Interna del pull. La fórmula
-- es la de 'ciudad' en 0011: quien ya bajaba toda la ciudad conserva su huella.
create function sync.area_del_pull(out ciudades uuid[], out huella text)
language sql
stable
set search_path = ''
as $$
  select coalesce(array_agg(c.ciudad_id order by c.ciudad_id), array[]::uuid[]),
         md5('ciudad|' || coalesce(string_agg(c.ciudad_id::text, ',' order by c.ciudad_id), ''))
    from public.mis_ciudades_de_trabajo() c (ciudad_id);
$$;

comment on function sync.area_del_pull() is
  'Las ciudades de trabajo del usuario autenticado (mis_ciudades_de_trabajo(): la de su zona; sin '
  'zona, las de sus campañas que no terminaron) y la huella de esa lista. Van en el watermark de las '
  'entidades con columna_ubicacion (la lista, para saber si el área creció; la huella, para un '
  'watermark sin lista; 0011, 0023). Interna del pull.';

revoke all on function sync.area_del_pull() from public, anon;
grant execute on function sync.area_del_pull() to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4. El pull: sin la rama «zona»
-- ----------------------------------------------------------------------------

-- Misma firma que en 0016 (p_alcance se acepta y se ignora: contrato 0.9.8). El default pasa a null:
-- 'zona' ya no significa nada.
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
    if v_tabla = 'public.ubicacion'::regclass and (v_desde ? 'xid') and ((v_nuevo -> v_entidad) ? 'xid') then
      select coalesce(jsonb_agg(s.id order by s.id), '[]'::jsonb)
        into v_ids
        from public.ubicaciones_que_salieron(
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
  'Delta por (xmin_w, id) con la RLS del que llama (0002). ubicacion, espacio y house_status bajan '
  'siempre por toda la ciudad de su zona (sin zona, todas las ciudades de su campaña) más lo que '
  'registró él, sin elección (0023, HU-SYNC-011). Su watermark lleva la huella y la lista de '
  'ciudades: bajan completas solo si apareció una ciudad que la lista no tenía; si la lista se '
  'achica, el delta sigue. p_alcance se acepta por compatibilidad y se ignora. El mapa (campania_ciudad, zona, '
  'zona_vertice) baja completo si cambiaron las campañas que ve (0013). Las entidades con '
  'columna_duenio bajan solo las filas del usuario autenticado (0014). out_of_area: las ubicaciones '
  'que cambiaron de ciudad en el tramo; area_reset: las entidades que arrancaron de cero porque '
  'cambió el área (0016).';

-- Los privilegios de sync.pull (0011) siguen: create or replace los conserva.

-- ----------------------------------------------------------------------------
-- 5. Comentarios que todavía hablaban de «su zona o toda la ciudad»
-- ----------------------------------------------------------------------------

-- Ya no hay alcance que elegir: solo cambia el texto (0011 y 0013 siguen como estaban).
comment on table public.ubicacion is
  'Casa del territorio, con su dirección. Sin datos de persona (ADR-004). No guarda zona ni '
  'campaña (0011): la ve quien trabaja en su ciudad, y al teléfono bajan todas las de su ciudad de '
  'trabajo (la de su zona; sin zona, las de su campaña) más las que registró él, sin elección '
  '(0023, HU-SYNC-011).';

comment on column sync.entidad.columna_ubicacion is
  'La columna de la fila que es el id de su ubicación. Si no es null, el pull baja la fila solo '
  'si su ubicación la registró el colportor o está en una de sus ciudades de trabajo (toda la '
  'ciudad de su zona; sin zona, todas las de su campaña, HU-SYNC-011), y su watermark lleva la '
  'huella del área y la lista de esas ciudades (0011, 0023).';

comment on function public.mis_ciudades_de_trabajo() is
  'Ciudad de trabajo del usuario autenticado (S55 de HU-SYNC-011): por cada inscripción viva en '
  'una campaña que no terminó (en curso o por empezar; 0013, decisión del 02/10), la de su zona '
  'asignada; sin zona, todas las ciudades vivas de esa campaña. Decide qué ubicaciones ve un '
  'colportor (RLS de lectura) y qué baja el pull, siempre toda la ciudad (0023). Dónde escribe lo '
  'decide mis_ciudades_de_campania().';
