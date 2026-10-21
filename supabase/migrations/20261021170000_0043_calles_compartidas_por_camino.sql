-- ============================================================================
-- 0043 · El aviso «Comparte la calle X con Y» cuenta solo los tramos del camino entre las esquinas
--        (backend-supabase#91, seguimiento de #87 / PR #90, HU-CAM-006, ADR-018, vista 24)
--
-- Decisión del orquestador del 19/10, por el mapa de decisiones, sobre la revisión de #90:
-- https://github.com/Colportores/backend-supabase/pull/90#issuecomment-6272512059
--
-- ## El caso
--
-- La 0038 decide «el borde nuevo recorre este tramo» mirando la geometría: el tramo entero a 1 m o
-- menos del borde (el metro de ADR-018). Con esa tolerancia, un tramo de 1 m o menos que SALE del
-- borde (una calle que se junta a mitad del borde, o la T donde termina un borde en común) queda
-- también dentro del metro y suma una calle de más: «Comparte Col 1 S, Corta y Fila 1 con A», y la
-- zona vecina no recorre «Fila 1». La zona vecina es la correcta y no se pierde nada ni se frena el
-- guardado; sobra el nombre de una calle. La geometría sola no distingue ese tramo del borde.
--
-- ## Qué cambia
--
-- El borde de una zona por esquinas ES el camino por calles entre sus esquinas: lo arma
-- poligono_por_calles() (0036) enganchando cada esquina a su cruce (ruteo.cruce_mas_cercano) y
-- uniendo los cruces seguidos con ruteo.camino(), de la última a la primera. Ahora
-- zonas_que_comparten_calle() arma ese mismo camino con las esquinas (p_vertices) que le pasa
-- guardar_zona() y SOLO cuentan los tramos que:
--
--   1. son parte de ese camino (el tramo entero sobre el recorrido), Y
--   2. quedan además a 1 m o menos del borde de la zona vecina (como hoy), Y
--   3. siguen quedando a 1 m o menos del borde que se dibuja (como hoy: el borde que llega puede no
--      ser el del camino si alguien lo armó a mano), Y
--   4. no quedan enteros a 1 m o menos de un punto donde los dos bordes solo se tocan o se cruzan
--      (la regla del 19/10 queda como está).
--
-- Las condiciones se suman a las de la 0038: el aviso solo puede salir menos veces, nunca de más.
-- Un tramo que sale del borde (Fila 1, un pasaje paralelo a 0,46 m) ya no entra aunque quede dentro
-- del metro; un tramo corto que SÍ es parte del camino (aunque mida 0,44 m) sigue contando.
--
-- Si el camino no se puede armar, `calles_compartidas` es `null` («no se pudo calcular»; la misma
-- respuesta que cuando la ciudad no tiene calles cargadas, decisión de P1 del 19/10). No se inventa
-- ni se frena el guardado. Es `null` cuando: las esquinas no son una lista de puntos, hay menos de 3
-- cruces distintos entre ellas, la ciudad no tiene cruces, no hay camino por las calles entre dos
-- esquinas seguidas, o una recarga de las calles está en curso (ver abajo).
--
-- ## Recarga de las calles en curso
--
-- La función ahora es VOLATILE (llama a ruteo.camino(), que lo es): cada sentencia ve lo último
-- confirmado, y ruteo.cargar_red() reemplaza la red con ids nuevos. Toma el mismo lock advisory
-- compartido que ciudad_para_dibujar() (clave `ruteo_red:<ciudad>`) para que los ids de nodo no
-- cambien a mitad de camino, pero con `pg_try_advisory_xact_lock_shared`: guardar_zona() nunca se
-- rechaza por esto y esperar una recarga larga pasaría el statement_timeout de 8 s (57014). Si hay una
-- recarga en curso, el aviso es `null` (no se pudo calcular) y el guardado sigue igual.
--
-- ## Firma
--
-- zonas_que_comparten_calle() suma el cuarto parámetro `p_vertices` (las esquinas de guardar_zona(),
-- con `orden`, `lon` y `lat`): es una función interna (solo service_role y guardar_zona()), así que
-- se reemplaza sin dejar la vieja. guardar_zona() conserva firma, cuerpo y respuesta de la 0038; solo
-- cambia la llamada. Sin tabla nueva, sin tocar el sync ni el contrato.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Qué calles comparte con otras zonas (interna): ahora con el camino entre las esquinas
-- ----------------------------------------------------------------------------

-- Los tramos del camino por calles entre las esquinas p_vertices (el borde de p_poligono) que también
-- recorre el borde de otra zona viva de la campania_ciudad (sin p_zona_id), salvo los que quedan enteros a
-- 1 m o menos de un punto donde los dos bordes se tocan o se cruzan. Una fila por zona y por nombre de calle;
-- el punto es la mitad del más largo de esos tramos. null si la ciudad no tiene calles cargadas o el
-- camino no se pudo armar.
create function public.zonas_que_comparten_calle(p_campania_ciudad_id uuid, p_poligono jsonb,
                                                 p_zona_id uuid, p_vertices jsonb)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  c_tolerancia constant double precision := 1.0;   -- metros: el mismo de las esquinas (ADR-018)
  v_ciudad_id  uuid;
  v_nueva      extensions.geometry := public.zona_geometria(p_poligono);
  v_anillo     extensions.geometry := extensions.st_exteriorring(public.zona_geometria(p_poligono));
  v_franja     extensions.geometry;   -- 1 m a cada lado del borde de la zona nueva
  v_esquina    jsonb;
  v_cruce      record;
  v_camino     record;
  v_nodos      bigint[] := array[]::bigint[];
  v_lineas     extensions.geometry[] := array[]::extensions.geometry[];
  v_recorrido  extensions.geometry;   -- el camino por calles entre las esquinas (el mismo de poligono_por_calles)
begin
  select cc.ciudad_id into v_ciudad_id
    from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if v_ciudad_id is null then
    return null;
  end if;

  -- Una recarga de las calles en curso: los ids de nodo cambian, no se puede armar el camino. No se espera
  -- (guardar_zona() no se rechaza): el aviso queda en «no se pudo calcular».
  if not pg_try_advisory_xact_lock_shared(hashtextextended('ruteo_red:' || v_ciudad_id::text, 0)) then
    return null;
  end if;

  if not exists (select 1 from ruteo.red r where r.ciudad_id = v_ciudad_id) then
    return null;
  end if;

  -- El camino por calles entre las esquinas, como lo arma poligono_por_calles(): cada esquina a su cruce
  -- (en el orden de `orden`), sin repetidos seguidos ni la vuelta a la primera, y un camino de cada cruce al
  -- siguiente y del último al primero.
  if p_vertices is null or jsonb_typeof(p_vertices) is distinct from 'array' then
    return null;
  end if;
  for v_esquina in
    select e from jsonb_array_elements(p_vertices) e
     order by case when jsonb_typeof(e -> 'orden') = 'number' then (e ->> 'orden')::numeric end
  loop
    -- (un elemento que no es un objeto no tiene `lon` ni `lat`: jsonb_typeof(null) no es 'number')
    if jsonb_typeof(v_esquina -> 'lon') is distinct from 'number'
       or jsonb_typeof(v_esquina -> 'lat') is distinct from 'number'
       or abs((v_esquina ->> 'lon')::numeric) > 180
       or abs((v_esquina ->> 'lat')::numeric) > 90 then
      return null;
    end if;
    select * into v_cruce from ruteo.cruce_mas_cercano(v_ciudad_id, (v_esquina ->> 'lon')::double precision,
                                                       (v_esquina ->> 'lat')::double precision);
    if not found then
      return null;
    end if;
    if cardinality(v_nodos) = 0 or v_nodos[cardinality(v_nodos)] <> v_cruce.nodo_id then
      v_nodos := v_nodos || v_cruce.nodo_id;
    end if;
  end loop;
  if cardinality(v_nodos) > 1 and v_nodos[1] = v_nodos[cardinality(v_nodos)] then
    v_nodos := v_nodos[1:cardinality(v_nodos) - 1];
  end if;
  if (select count(distinct x) from unnest(v_nodos) x) < 3 then
    return null;
  end if;

  for v_i in 1..cardinality(v_nodos) loop
    select * into v_camino
      from ruteo.camino(v_ciudad_id, v_nodos[v_i],
                        v_nodos[case when v_i = cardinality(v_nodos) then 1 else v_i + 1 end]);
    if not found then
      return null;
    end if;
    v_lineas := v_lineas || v_camino.geom;
  end loop;
  v_recorrido := extensions.st_collect(v_lineas);

  v_franja := extensions.geometry(extensions.st_buffer(extensions.geography(v_anillo), c_tolerancia));

  return coalesce((
    -- `materialized` en los dos: sin eso Postgres los inlinea y vuelve a leer las calles (y a probar la franja
    -- entera) una vez por cada zona vecina; con una zona grande sobre una ciudad ya dividida en muchas zonas
    -- pasaba los 8 s del statement_timeout (57014) y el guardado, que nunca se rechaza, se rechazaba.
    -- st_covers(franja, tramo) es lo mismo que st_coveredby(tramo, franja), pero PostGIS prepara el primer
    -- argumento y lo reutiliza para todos los tramos.
    with recorridos as materialized (     -- los tramos que el borde nuevo recorre: los del camino entre las esquinas
      select t.id, t.nombre, t.largo_m, t.geom
        from ruteo.tramo t
       where t.ciudad_id = v_ciudad_id
         and extensions.st_covers(v_franja, t.geom)
         and extensions.st_covers(v_recorrido, t.geom)
    ),
    vecinas as materialized (             -- las zonas vivas de la ciudad de la campaña que llegan hasta ahí
      -- `cerca`: 1 m alrededor de los puntos sueltos donde el borde de la vecina cruza o toca el de la zona nueva
      -- (la intersección de los dos bordes sin sus tramos en común); null si no hay.
      select z.id, z.nombre,
             extensions.geometry(extensions.st_buffer(extensions.geography(a.anillo), c_tolerancia)) as franja,
             case when not extensions.st_isempty(p.puntos)
                  then extensions.geometry(extensions.st_buffer(extensions.geography(p.puntos), c_tolerancia)) end as cerca
        from public.zona z
        cross join lateral (select extensions.st_exteriorring(public.zona_geometria(z.poligono_geojson)) as anillo) a
        cross join lateral (select extensions.st_collectionextract(extensions.st_intersection(v_anillo, a.anillo), 1) as puntos) p
       where z.campania_ciudad_id = p_campania_ciudad_id
         and z.deleted_at is null
         and z.id is distinct from p_zona_id
         and extensions.st_dwithin(extensions.geography(public.zona_geometria(z.poligono_geojson)),
                                   extensions.geography(v_nueva), c_tolerancia)
    ),
    compartidos as (
      select v.id as zona_id, v.nombre as zona, nullif(btrim(r.nombre), '') as calle,
             (array_agg(r.geom order by r.largo_m desc, r.id))[1] as tramo_mayor
        from vecinas v
        join recorridos r on r.geom operator(extensions.&&) v.franja
                         and extensions.st_covers(v.franja, r.geom)
                         and (v.cerca is null or not extensions.st_covers(v.cerca, r.geom))
       group by v.id, v.nombre, nullif(btrim(r.nombre), '')
    )
    select jsonb_agg(jsonb_build_object(
                       'zona_id', c.zona_id, 'nombre', c.zona, 'calle', c.calle,
                       'punto', extensions.st_asgeojson(extensions.st_lineinterpolatepoint(c.tramo_mayor, 0.5), 7)::jsonb)
                     order by c.zona, c.zona_id, c.calle nulls last)
      from compartidos c
  ), '[]'::jsonb);
end;
$$;

comment on function public.zonas_que_comparten_calle(uuid, jsonb, uuid, jsonb) is
  'Interna (0043): [{zona_id, nombre, calle, punto}] de las zonas vivas de la campania_ciudad (sin '
  'p_zona_id) con las que el borde de p_poligono recorre al menos un mismo tramo de ruteo.tramo: un tramo '
  'del camino por calles entre las esquinas p_vertices (el de poligono_por_calles()) que además queda '
  'entero a 1 m o menos de los dos bordes; sin largo mínimo; tocarse en una esquina no cuenta, ni un tramo '
  'entero a 1 m o menos de ese punto. calle es null si el tramo no tiene nombre; punto, la mitad del tramo '
  'más largo. null si la ciudad no tiene calles cargadas, el camino no se pudo armar o hay una recarga de '
  'las calles en curso.';

-- ----------------------------------------------------------------------------
-- 2. guardar_zona(): le pasa las esquinas
-- ----------------------------------------------------------------------------

-- Misma firma, mismo cuerpo y misma respuesta que en 0038; cambia solo la llamada a
-- zonas_que_comparten_calle(), que ahora recibe las esquinas.
-- Devuelve {"guardada", "zona", "vertices", "poligono_geojson", "ubicaciones_incluidas",
--           "superposiciones", "calles_compartidas"}.
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
  v_sup       jsonb;
  v_calles    jsonb;
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
  -- Hasta 40 caracteres (no bytes), sin los espacios de los costados. Rige también al editar.
  if char_length(v_nombre) > 40 then
    raise exception 'El nombre de la zona puede tener hasta 40 caracteres y el que escribiste tiene %. Acortalo.',
        char_length(v_nombre)
      using errcode = 'CZ009';
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

  -- Los avisos de la vista 24 (0038): con qué otras zonas de la ciudad se superpone y qué calles
  -- comparte. Solo informan: nada de esto rechaza el guardado (S56). El lock del mapa ya está
  -- tomado, así que lo que se compara es lo último que se guardó.
  v_sup := public.zonas_que_se_superponen(v_cc.id, v_poligono, p_zona_id);
  v_calles := case when p_tipo_forma = 'ESQUINAS'
                   then public.zonas_que_comparten_calle(v_cc.id, v_poligono, p_zona_id, v_vertices)
                   else '[]'::jsonb end;

  if p_vista_previa then
    return jsonb_build_object('guardada', false, 'zona', null, 'vertices', null,
                              'poligono_geojson', v_poligono,
                              'ubicaciones_incluidas', v_incluidas,
                              'superposiciones', v_sup, 'calles_compartidas', v_calles);
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
    'ubicaciones_incluidas', v_incluidas,
    'superposiciones', v_sup, 'calles_compartidas', v_calles);
end;
$$;

comment on function public.guardar_zona(uuid, text, text, text, double precision, double precision,
                                        integer, jsonb, jsonb, uuid, boolean) is
  'Vista 24: crea o edita una zona y sus vértices; con p_vista_previa solo devuelve el polígono, '
  'cuántas ubicaciones incluye («Incluye N ubicaciones»), con qué zonas de la ciudad se superpone '
  '(superposiciones) y qué calles comparte con ellas (calles_compartidas, solo ESQUINAS; null si la '
  'ciudad no tiene calles cargadas o el camino entre las esquinas no se pudo armar). Las zonas se pueden superponer (S56): los avisos no rechazan. '
  'Errores: 42501; CZ001, CZ004, CZ008, CZ009 (nombre vacío, repetido o de más de 40 caracteres), '
  'CZ011, CZ012.';

-- ----------------------------------------------------------------------------
-- 3. Privilegios, y la función vieja se va
-- ----------------------------------------------------------------------------

-- La de tres parámetros (0038) era interna y solo la llamaba guardar_zona(): ya no la llama nadie.
drop function public.zonas_que_comparten_calle(uuid, jsonb, uuid);

-- Igual que en 0038: `authenticated` y `service_role` también en el revoke (los default privileges de la
-- imagen de Supabase les dan EXECUTE sobre cada función nueva de public). Interna: la llama guardar_zona(),
-- que corre como su dueño; service_role la puede ejecutar (herramientas y pruebas); ningún cliente.
revoke all on function public.zonas_que_comparten_calle(uuid, jsonb, uuid, jsonb)
  from public, anon, authenticated, service_role;
grant execute on function public.zonas_que_comparten_calle(uuid, jsonb, uuid, jsonb) to service_role;
