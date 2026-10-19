-- ============================================================================
-- 0038 · La vista previa de guardar_zona() vuelve a devolver las superposiciones y suma las
--        calles compartidas (backend-supabase#87, HU-CAM-006, ADR-018, vista 24)
--
-- Decisión de Cristian del 30/09 tarde (HU-CAM-006, «Zonas superpuestas», S56): una zona que se
-- superpone con otra se guarda sin rechazo, pero la vista marca el tramo en rojo y avisa sin frenar
-- («Esta zona se superpone con «X» en el tramo marcado en rojo. Podés guardarla igual.»). La 0013
-- sacó el cálculo de guardar_zona() porque nadie lo leía; la HU lo sigue pidiendo y el panel lo
-- consume desde front-coordinadores-web#40. Decisiones del orquestador del 16/10, por el mapa de
-- decisiones: front-coordinadores-web#52 (P4) y backend-supabase#86 (P2).
--
-- ## Qué cambia
--
-- guardar_zona() (misma firma, mismo cuerpo que en 0024) suma dos claves a su respuesta, tanto en
-- la vista previa como al guardar. NUNCA rechaza por esto: ni CZ007 (que no se reutiliza) ni nada.
--
--   · `superposiciones`: [{"zona_id", "nombre", "interseccion"}], una por cada zona viva de la MISMA
--     ciudad de la campaña (campania_ciudad) cuya área comparte área con la zona que se dibuja;
--     `interseccion` es el GeoJSON de esa parte común (el tramo que el panel pinta en rojo). Sin
--     tolerancia en metros (ADR-018: «no hay validación que rechace la superposición ni tolerancia»):
--     dos zonas que solo comparten borde, o se tocan en un punto, NO se superponen. Ordenadas por
--     nombre y id. Lista vacía si no hay.
--   · `calles_compartidas`: el aviso «Comparte la calle Heredia con Belvedere» (canvas 24, artboard
--     03). Solo para una zona ESQUINAS (una RADIAL devuelve []). [{"zona_id", "nombre", "calle",
--     "punto"}]: la zona vecina (con su nombre), el nombre de la calle y un punto del tramo para el
--     rótulo (GeoJSON Point). Una fila por zona vecina y por calle; si el tramo no tiene nombre en
--     OSM, `calle` es null (no se inventa) y los tramos sin nombre de una misma zona van juntos.
--     `null` (no `[]`) si la ciudad todavía no tiene calles cargadas (ruteo.red, 0036): no se pudo
--     calcular, y eso no frena el guardado.
--
-- ## Cuándo «comparte» una calle (decisión del orquestador del 16/10, backend-supabase#86, P2)
--
-- El borde de la zona nueva recorre al menos UN tramo de la red de calles (ruteo.tramo) que también
-- está en el borde de otra zona viva de la misma ciudad de la campaña. Sin largo mínimo. Tocarse en
-- una sola esquina no cuenta (un punto no es un tramo). «Recorre» = el tramo entero queda a 1 m o
-- menos del borde, el mismo metro que ADR-018 usa para las esquinas: el borde de una zona por
-- esquinas se arma pegando tramos (poligono_por_calles(), 0036), así que dos zonas vecinas lo
-- recorren idéntico. Compartir un borde NO es superponerse: la zona vecina que solo comparte la
-- calle sale en `calles_compartidas` y no en `superposiciones` («pueden compartir una calle como
-- borde», canvas 24).
--
-- ## Alcance de la comparación
--
-- Solo zonas VIVAS (deleted_at is null) de la misma campania_ciudad, sin contar la que se edita
-- (p_zona_id: una zona no se superpone consigo misma). Otra ciudad de la campaña y otra campaña no
-- cuentan. Se calcula dentro del lock del mapa (bloquear_mapa()), con lo último que se guardó.
--
-- ## Permisos
--
-- Los de guardar_zona(), sin tocar: SECURITY DEFINER con search_path vacío, y el permiso es lo
-- primero (42501 sin sesión, sin el rol, o campaña de otro coordinador; CZ001 / CZ011 / CZ012). Solo
-- quien coordina la campaña, o un ADMIN, recibe las zonas de esa ciudad. Las dos funciones nuevas
-- son internas (las llama guardar_zona(), que corre como su dueño): sin EXECUTE para anon ni
-- authenticated, y devuelven nombres de zona, geometría y nombres de calle: ni importes ni personas.
-- No toca el sync ni el contrato de Bruno: no hay tabla ni entidad nueva, y la respuesta de la RPC
-- no viaja al teléfono.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Con qué zonas se superpone (interna)
-- ----------------------------------------------------------------------------

-- Zonas vivas de la campania_ciudad que comparten ÁREA con p_poligono (sin contar p_zona_id, la que
-- se está editando), con la parte común en GeoJSON. Compartir solo borde o un punto no cuenta.
create function public.zonas_que_se_superponen(p_campania_ciudad_id uuid, p_poligono jsonb,
                                               p_zona_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('zona_id', x.id, 'nombre', x.nombre,
                                               'interseccion', extensions.st_asgeojson(x.comun, 7)::jsonb)
                            order by x.nombre, x.id), '[]'::jsonb)
    from (
      select c.id, c.nombre,
             extensions.st_collectionextract(extensions.st_intersection(c.forma, public.zona_geometria(p_poligono)), 3) as comun
        from (
          select z.id, z.nombre, public.zona_geometria(z.poligono_geojson) as forma
            from public.zona z
           where z.campania_ciudad_id = p_campania_ciudad_id
             and z.deleted_at is null
             and z.id is distinct from p_zona_id
        ) c
       where extensions.st_intersects(c.forma, public.zona_geometria(p_poligono))
    ) x
   where not extensions.st_isempty(x.comun);
$$;

comment on function public.zonas_que_se_superponen(uuid, jsonb, uuid) is
  'Interna (0038): [{zona_id, nombre, interseccion}] de las zonas vivas de la campania_ciudad que '
  'comparten área con p_poligono (sin p_zona_id), con la parte común en GeoJSON; [] si no hay. Sin '
  'tolerancia: compartir solo el borde no es superponerse. Por nombre y id.';

-- ----------------------------------------------------------------------------
-- 2. Qué calles comparte con otras zonas (interna)
-- ----------------------------------------------------------------------------

-- Los tramos de la red de la ciudad que el borde de p_poligono recorre (el tramo entero a 1 m o menos)
-- y que también recorre el borde de otra zona viva de la campania_ciudad (sin p_zona_id). Una fila por
-- zona y por nombre de calle; el punto es la mitad del más largo de esos tramos. null si la ciudad no
-- tiene calles cargadas.
create function public.zonas_que_comparten_calle(p_campania_ciudad_id uuid, p_poligono jsonb,
                                                 p_zona_id uuid)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  c_tolerancia constant double precision := 1.0;   -- metros: el mismo de las esquinas (ADR-018)
  v_ciudad_id  uuid;
  v_nueva      extensions.geometry := public.zona_geometria(p_poligono);
  v_franja     extensions.geometry;   -- 1 m a cada lado del borde de la zona nueva
begin
  select cc.ciudad_id into v_ciudad_id
    from public.campania_ciudad cc where cc.id = p_campania_ciudad_id;
  if v_ciudad_id is null
     or not exists (select 1 from ruteo.red r where r.ciudad_id = v_ciudad_id) then
    return null;
  end if;

  v_franja := extensions.geometry(extensions.st_buffer(
                extensions.geography(extensions.st_exteriorring(v_nueva)), c_tolerancia));

  return coalesce((
    with recorridos as (          -- los tramos que el borde nuevo recorre
      select t.id, t.nombre, t.largo_m, t.geom
        from ruteo.tramo t
       where t.ciudad_id = v_ciudad_id
         and extensions.st_coveredby(t.geom, v_franja)
    ),
    vecinas as (                  -- las zonas vivas de la ciudad de la campaña que llegan hasta ahí
      select z.id, z.nombre,
             extensions.geometry(extensions.st_buffer(
               extensions.geography(extensions.st_exteriorring(public.zona_geometria(z.poligono_geojson))),
               c_tolerancia)) as franja
        from public.zona z
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
        join recorridos r on extensions.st_coveredby(r.geom, v.franja)
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

comment on function public.zonas_que_comparten_calle(uuid, jsonb, uuid) is
  'Interna (0038): [{zona_id, nombre, calle, punto}] de las zonas vivas de la campania_ciudad (sin '
  'p_zona_id) con las que el borde de p_poligono recorre al menos un mismo tramo de ruteo.tramo (el '
  'tramo entero a 1 m o menos de los dos bordes; sin largo mínimo; tocarse en una esquina no cuenta). '
  'calle es null si el tramo no tiene nombre; punto, la mitad del tramo más largo. null si la ciudad '
  'no tiene calles cargadas.';

-- ----------------------------------------------------------------------------
-- 3. guardar_zona(): las dos claves nuevas
-- ----------------------------------------------------------------------------

-- Misma firma y mismo cuerpo que en 0024; cambian la declaración de v_sup y v_calles, el cálculo
-- justo después de v_incluidas y las dos respuestas (vista previa y guardado).
--
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
                   then public.zonas_que_comparten_calle(v_cc.id, v_poligono, p_zona_id)
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
  'ciudad no tiene calles cargadas). Las zonas se pueden superponer (S56): los avisos no rechazan. '
  'Errores: 42501; CZ001, CZ004, CZ008, CZ009 (nombre vacío, repetido o de más de 40 caracteres), '
  'CZ011, CZ012.';

-- ----------------------------------------------------------------------------
-- 4. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` y `service_role` también en el revoke: en una base creada desde cero los default
-- privileges de la imagen de Supabase les dan EXECUTE sobre cada función nueva de public (ver 0008).
-- Las dos son internas: las llama guardar_zona(), que corre como su dueño. service_role las puede
-- ejecutar (herramientas y pruebas); ningún cliente. guardar_zona() es `create or replace`: conserva
-- sus privilegios.
revoke all on function
  public.zonas_que_se_superponen(uuid, jsonb, uuid),
  public.zonas_que_comparten_calle(uuid, jsonb, uuid)
  from public, anon, authenticated, service_role;
grant execute on function
  public.zonas_que_se_superponen(uuid, jsonb, uuid),
  public.zonas_que_comparten_calle(uuid, jsonb, uuid)
  to service_role;
