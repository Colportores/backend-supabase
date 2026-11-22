-- ============================================================================
-- 0200 · El pull avisa los coordinadores que dejaron de contar en «¿Quién te acompaña?»
--        (backend-supabase#249, hallazgo bloqueante de la revisión del PR 296; decisión del 22/11, P1, opción 1)
--
-- ## El caso
--
-- Ana sincronizó el lunes y tiene a Cesar, coordinador de su campaña, en «¿Quién te acompaña?» (vista 20J). El martes a
-- Cesar lo suspenden, le dan de baja la cuenta, le quitan el rol o se le vence (`valido_hasta`). La política de la 0178
-- (`puedo_ver_al_coordinador()`) ya no le muestra la fila, pero la fila de `campania_coordinador` no cambió (lo que cambió
-- es `usuario` o `usuario_rol`, y el vencimiento no cambia ninguna fila): el delta no trae nada y Cesar se queda en el
-- teléfono de Ana, que lo puede elegir. El servidor no controla al acompañante que sube el teléfono (decisión del 05/11,
-- «Valida acomp»), así que el pull es lo único que lo frena.
--
-- Decisión (agente de decisiones, 22/11, reglas R1 y R7 sobre «Lista acomp.» de Cristian del 09/11: «solo quienes tienen
-- hoy el rol COORDINADOR»; comentarios backend-supabase#296 7085559285 y #249 7085558935): opción 1, `out_of_area` para
-- `campania_coordinador` con los ids de los coordinadores que hoy no cuentan (helper DEFINER, solo ids, idempotente).
--
-- ## Qué cambia
--
--   · public.coordinadores_que_no_cuentan_en_mis_campanias(): los ids de las filas de `campania_coordinador` de las
--     campañas en las que quien llama está inscripto hoy (inscripción, campaña y cuenta vivas, como en
--     `puedo_ver_al_coordinador()`) cuyo coordinador hoy no tiene el rol COORDINADOR (`cuenta_tiene_rol()`: cuenta
--     suspendida o dada de baja, rol vencido, quitado o que nunca tuvo, como el administrador que figura en la campaña).
--     Deja afuera las filas que quien llama igual ve por otro lado de la política (es ADMIN, es su propia fila o
--     coordina esa campaña): esas siguen bajando como filas y no se avisan. SECURITY DEFINER (la RLS ya no le deja leer
--     esas filas), devuelve solo ids de fila (ni la persona ni el nombre), sin parámetros: no sirve para mirar campañas
--     ajenas ni roles de nadie en particular.
--   · sync.pull, en cada pull de `campania_coordinador` (delta o desde cero, en cada página): esos ids van en
--     `out_of_area` = `{"campania_coordinador": [ids]}`, la misma clave que `ubicacion` (0016, 0195). Se calcula en el
--     momento, sin triggers ni cron ni columnas: repetir el pull da lo mismo (idempotente) y el vencimiento por
--     `valido_hasta` se ve en el primer pull después de la hora. Si no hay ninguno, la clave no sale (como antes).
--   · Una fila que se da de baja (`deleted_at`, el coordinador que se quita de la campaña) cambia de versión y baja por el
--     delta como baja, como siempre, si el coordinador cuenta. Si además dejó de contar, la política esconde también la
--     baja: por eso el aviso incluye las filas dadas de baja de quien no cuenta (si no, el teléfono que lo tenía no se
--     entera nunca).
--
-- Lo que no cambia: quién ve qué (la política de la 0178 sigue igual), ni las demás entidades, ni el aviso de
-- `ubicacion` de la 0195.
--
-- ## Datos existentes
--
-- No toca filas. Solo una función nueva y el cuerpo de sync.pull. Lo prueba supabase/tests/0200_… . Forward-only.
--
-- ## Para otros repos
--
--   · front-colportores-mobile#146 (con #671): el motor quita de la lista local de acompañantes lo que llega en
--     `out_of_area` de `campania_coordinador` (hoy solo lo hace con `ubicacion`), sin borrar jornadas ni acompañamientos
--     ya registrados.
--   · docs-organizacion: contrato §2.1, `out_of_area` también para `campania_coordinador` (issue de seguimiento).
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Los coordinadores de mis campañas que hoy no cuentan
-- ----------------------------------------------------------------------------

create function public.coordinadores_que_no_cuentan_en_mis_campanias()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  -- También las filas dadas de baja: con el coordinador que no cuenta, la política esconde además su baja, y el delta
  -- tampoco la trae.
  select cc.id
    from public.campania_coordinador cc
   -- Las campañas en las que quien llama está inscripto hoy (el mismo criterio que puedo_ver_al_coordinador()).
   where exists (
       select 1
         from public.campania_colportor i
         join public.campania c on c.id = i.campania_id
         join public.usuario u on u.id = i.usuario_id
        where i.campania_id = cc.campania_id
          and i.usuario_id = auth.uid()
          and i.deleted_at is null
          and c.deleted_at is null
          and u.deleted_at is null
          and u.suspendido_en is null)
     -- Hoy no es coordinador: cuenta suspendida o dada de baja, rol vencido, quitado o que nunca tuvo.
     and not public.cuenta_tiene_rol(cc.usuario_id, 'COORDINADOR')
     -- Lo que igual ve por otro lado de la política de la 0178 sigue bajando como fila: no se avisa.
     and cc.usuario_id <> auth.uid()
     and not public.coordina_la_campania(cc.campania_id)
     and not public.tiene_rol('ADMIN');
$$;

comment on function public.coordinadores_que_no_cuentan_en_mis_campanias() is
  'Ids de las filas (vivas o dadas de baja) de campania_coordinador de las campañas en las que el usuario autenticado está inscripto hoy '
  '(inscripción, campaña y cuenta vivas) cuyo coordinador hoy no tiene el rol COORDINADOR (cuenta suspendida o de baja, '
  'rol vencido, quitado o que nunca tuvo), menos las que igual ve por la política (ADMIN, su propia fila, coordina la '
  'campaña). Solo ids de fila. Interna del pull: el aviso out_of_area de campania_coordinador (0200).';

revoke all on function public.coordinadores_que_no_cuentan_en_mis_campanias() from public, anon, authenticated, service_role;
-- sync.pull es INVOKER: authenticated necesita EXECUTE sobre el helper. Por PostgREST solo devuelve ids de fila de las
-- campañas en las que está inscripto (ni la persona ni el nombre): lo mismo que le llega en el aviso.
grant execute on function public.coordinadores_que_no_cuentan_en_mis_campanias() to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 2. El pull los avisa en out_of_area
-- ----------------------------------------------------------------------------

-- Misma firma y cuerpo que en 0195; se suma solo el aviso de `campania_coordinador`. Los privilegios de sync.pull (0011)
-- siguen: create or replace los conserva.

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

    -- Los coordinadores que dejaron de contar (0200): la política de la 0178 esconde la fila pero la fila no cambia (cambió
    -- la cuenta o el rol, o venció `valido_hasta`), así que el delta no trae nada. En cada pull de la entidad, con delta o
    -- desde cero (el teléfono no borra lo que ya tiene), van sus ids para que la app los saque de «¿Quién te acompaña?».
    if v_tabla = 'public.campania_coordinador'::regclass then
      select coalesce(jsonb_agg(q.id order by q.id), '[]'::jsonb)
        into v_ids
        from public.coordinadores_que_no_cuentan_en_mis_campanias() q (id);
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
  'que cambiaron de ciudad en el tramo y las de las ciudades que dejaron de ser suyas (0195), y en cada pull de '
  'campania_coordinador los ids de los coordinadores de sus campañas que hoy no cuentan (0200); area_reset: las entidades '
  'que arrancaron de cero porque cambió el área (0016).';
