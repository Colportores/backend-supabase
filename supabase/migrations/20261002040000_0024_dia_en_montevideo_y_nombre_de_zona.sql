-- ============================================================================
-- 0024 · El día se cuenta en Montevideo en todo el sistema, y el nombre de una zona tiene tope
--        (backend-supabase#59: ajustes de la re-revisión de #55 y decisiones del 02/10)
--
-- ## 1. El mismo día en la lectura, la escritura y la inscripción
--
-- Re-revisión de #55 (comentario 5954669233, observación): la lectura corta con el `current_date`
-- de la sesión, que en Supabase es UTC (0013), y «en curso» y la gracia se miden en
-- America/Montevideo (0020 y 0021). Entre las 21:00 y las 24:00 de Montevideo del último día de
-- una campaña, la base ya está en el día siguiente en UTC: el colportor dejaba de ver el mapa y las
-- casas de su campaña (y corregir algo ajeno que ya no veía volvía FILA_INEXISTENTE, no CG001 ni
-- `accepted`), mientras que escribir seguía permitido. El mismo desajuste cortaba tres horas antes
-- la vigencia de la inscripción (cuenta ACTIVA, asignar zona, inscribir) y adelantaba tres horas
-- el primer día.
--
-- Decisión del orquestador (02/10, por el mapa de decisiones; backend-supabase#59): contar el día en
-- Montevideo también en la lectura, para que sea el mismo día en todo el sistema. Todo lo que
-- decide «hoy» de una campaña sale de public.hoy_montevideo(), y ya no depende de la zona horaria
-- de la sesión (ni de quién llame: PostgREST, el SQL editor, un job).
--
--   · hoy_montevideo(p_ahora): el día de p_ahora en America/Montevideo (docs/08-conceptos-
--     transversales.md, §8.6). Pura; el parámetro existe para poder probar la hora.
--   · Pasan a usarla, con el mismo cuerpo de antes salvo el día:
--       - mis_inscripciones_no_terminadas() (0013): el mapa y las casas que ve y baja el colportor.
--       - campania_vigente() (0005): inscribir, asignar zona, estado de la cuenta, zona por
--         posición (por campanias_vigentes_de() y mis_campanias_vigentes()).
--       - motivo_mapa_de_campania() (0008): CZ011, «la campaña ya terminó», al cambiar un mapa.
--       - mis_campanias_para_escribir() (0020): el comienzo de la campaña (el fin ya era de
--         Montevideo).
--       - escritura_dentro_de_plazo() (0020) y escritura_en_curso() (0021): dejan su cuenta
--         inline y delegan en hoy_montevideo(), para que haya una sola definición del día.
--   · Efecto: la campaña que termina el día D sigue en curso hasta las 23:59 de Montevideo del día D
--     (antes, hasta las 21:00); la que empieza el día D arranca a las 00:00 de Montevideo (antes, a
--     las 21:00 del día anterior). Lectura y escritura coinciden: no hay horas en las que se pueda
--     escribir lo que ya no se ve.
--   · Lo que no cambia: la gracia de 15 días y CG001 (0020, 0021), la regla de qué es «no
--     terminada» (fecha_fin null o >= hoy), ni ningún dato.
--   · Queda afuera a propósito: el DEFAULT de precio_por_zona.valido_desde (0001) sigue en
--     current_date. Esa tabla la reemplaza backend-supabase#26 (precio por campania_ciudad): se
--     resuelve ahí (mapa §2: coherencia, anotado en el PR).
--
-- ## 2. Tope de 40 caracteres en el nombre de la zona
--
-- HU-CAM-006 (decisión de Cristian, 02/10, front-coordinadores-web#28, comentario 5952251958): el
-- nombre de la zona tiene hasta 40 caracteres, y se valida en el formulario y del lado del
-- servidor, en guardar_zona(), para que no dependa del navegador. Se agrega el tope a
-- guardar_zona() (misma firma y mismo cuerpo que en 0013): el nombre se mide sin los espacios de
-- los costados y en caracteres, no en bytes. Código CZ009 (el del nombre vacío o repetido), con un
-- mensaje que dice cuánto se pasó y qué hacer. También rige al editar una zona y en la vista previa.
-- Una zona que ya tiene un nombre más largo (de antes de esta migración) no se toca; al editarla
-- hay que acortarlo.
--
-- ## Para otros repos
--
--   · front-coordinadores-web (vista 24): CZ009 también para el nombre de más de 40 caracteres
--     («El nombre de la zona puede tener hasta 40 caracteres y el que escribiste tiene N. Acortalo.»).
--     El formulario ya lo frena antes («El nombre puede tener hasta 40 caracteres.»); esto es la
--     defensa del servidor.
--   · front-colportores-mobile y motor (#178): entre las 21:00 y las 24:00 de Montevideo del último
--     día de la campaña el pull sigue bajando el mapa y las casas (antes dejaba de bajarlos), y la
--     corrección de algo ajeno cae en el mismo caso que a cualquier hora de ese día, no en
--     FILA_INEXISTENTE.
--   · Despliegue (no es una migración): supabase/config.toml sube `minimum_password_length` de 6 a 8
--     para que el servidor exija lo mismo que la app (HU-AUTH-001, S1). En el proyecto hosteado va
--     por `supabase config push` o por el panel de Supabase (Authentication, política de
--     contraseñas). `password_requirements` queda vacío: la mayúscula, que cuenta cualquier letra
--     mayúscula (también con tilde y Ñ), la valida la app.
--
-- Datos: ninguno cambia; solo funciones.
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. El día de Montevideo
-- ----------------------------------------------------------------------------

-- El día de p_ahora en la hora del proyecto, America/Montevideo. No mira la zona horaria de la
-- sesión: el mismo instante da el mismo día en cualquier conexión. Pura (sin datos).
create function public.hoy_montevideo(p_ahora timestamptz default now())
returns date
language sql
stable
set search_path = ''
as $$
  select (p_ahora at time zone 'America/Montevideo')::date;
$$;

comment on function public.hoy_montevideo(timestamptz) is
  'El día de p_ahora (por defecto, ahora) en America/Montevideo, sin depender de la zona horaria '
  'de la sesión. Única definición de «hoy» para la vigencia de una campaña (0024). Interna.';

-- Misma cuenta que en 0020 y 0021, ahora con una sola definición del día.
create or replace function public.escritura_dentro_de_plazo(p_fecha_fin date, p_ahora timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_fecha_fin is null
      or p_fecha_fin + 15 >= public.hoy_montevideo(p_ahora);
$$;

comment on function public.escritura_dentro_de_plazo(date, timestamptz) is
  'Si una campaña que termina en p_fecha_fin admite escrituras en p_ahora: no terminó, o terminó '
  'hace 15 días o menos, en la hora de America/Montevideo (0020, decisión del 02/10; 0024).';

create or replace function public.escritura_en_curso(p_fecha_fin date, p_ahora timestamptz default now())
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_fecha_fin is null
      or p_fecha_fin >= public.hoy_montevideo(p_ahora);
$$;

comment on function public.escritura_en_curso(date, timestamptz) is
  'Si una campaña que termina en p_fecha_fin todavía no terminó en p_ahora, en la hora de '
  'America/Montevideo (0021, 0024). La gracia de 0020 es lo que viene después, hasta 15 días.';

-- ----------------------------------------------------------------------------
-- 2. Lo que decidía «hoy» en UTC
-- ----------------------------------------------------------------------------

-- Misma firma y mismo cuerpo que en 0005, salvo el día.
create or replace function public.campania_vigente(p_campania public.campania)
returns boolean
language sql
stable
set search_path = ''
as $$
  select p_campania.deleted_at is null
     and p_campania.fecha_inicio <= public.hoy_montevideo()
     and (p_campania.fecha_fin is null or p_campania.fecha_fin >= public.hoy_montevideo());
$$;

-- Misma firma y mismo cuerpo que en 0013, salvo el día: la lectura del mapa y de las casas.
create or replace function public.mis_inscripciones_no_terminadas()
returns table (campania_id uuid, zona_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id, cc.zona_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and cc.deleted_at is null
     and u.deleted_at is null
     and c.deleted_at is null
     and (c.fecha_fin is null or c.fecha_fin >= public.hoy_montevideo());
$$;

comment on function public.mis_inscripciones_no_terminadas() is
  'Inscripciones vivas del usuario autenticado en campañas que no terminaron (en curso o por '
  'empezar), con su zona. El día se cuenta en America/Montevideo (0024). Decide el mapa y las '
  'casas que ve y baja (0013; decisiones del 30/09 y del 02/10). Interna.';

-- Misma firma y mismo cuerpo que en 0020, salvo el día de comienzo.
create or replace function public.mis_campanias_para_escribir()
returns table (campania_id uuid)
language sql
stable
security definer
set search_path = ''
as $$
  select cc.campania_id
    from public.campania_colportor cc
    join public.usuario u on u.id = cc.usuario_id
    join public.campania c on c.id = cc.campania_id
   where cc.usuario_id = auth.uid()
     and cc.deleted_at is null
     and u.deleted_at is null
     and c.deleted_at is null
     and c.fecha_inicio <= public.hoy_montevideo()
     and public.escritura_dentro_de_plazo(c.fecha_fin);
$$;

-- Misma firma y mismo cuerpo que en 0008, salvo el día: la campaña terminó según el día de
-- Montevideo, no el de UTC (0024).
-- null si el usuario autenticado puede cambiar el mapa de p_campania_id: es ADMIN o su
-- coordinador, y la campaña existe y no terminó (una futura sí). Interna.
create or replace function public.motivo_mapa_de_campania(p_campania_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campania public.campania;
  v_es_admin boolean := public.tiene_rol('ADMIN');
begin
  if auth.uid() is null or not (v_es_admin or public.tiene_rol('COORDINADOR')) then
    return 'SIN_PERMISO';
  end if;

  select * into v_campania from public.campania c where c.id = p_campania_id;
  if not found or v_campania.deleted_at is not null then
    return 'CAMPANIA_INEXISTENTE';
  end if;

  if not v_es_admin and v_campania.coordinador_id is distinct from auth.uid() then
    return 'SIN_PERMISO';
  end if;

  if v_campania.fecha_fin is not null and v_campania.fecha_fin < public.hoy_montevideo() then
    return 'CAMPANIA_TERMINADA';
  end if;

  return null;
end;
$$;

comment on function public.motivo_mapa_de_campania(uuid) is
  'null si el usuario autenticado es ADMIN o el coordinador de p_campania_id y la campaña no '
  'terminó (el día se cuenta en America/Montevideo, 0024); si no, SIN_PERMISO | '
  'CAMPANIA_INEXISTENTE | CAMPANIA_TERMINADA. Interna.';


-- ----------------------------------------------------------------------------
-- 3. El nombre de la zona
-- ----------------------------------------------------------------------------

-- Misma firma y mismo cuerpo que en 0013, más el tope de 40 caracteres del nombre (0024, HU-CAM-006).
-- Sin superposiciones (S56): las zonas se pueden superponer, así que no se calculan ni se
-- rechazan (CZ007), y la respuesta no trae la clave `superposiciones`.
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
  'Errores: 42501; CZ001, CZ004, CZ008, CZ009 (nombre vacío, repetido o de más de 40 caracteres), '
  'CZ011, CZ012.';

-- ----------------------------------------------------------------------------
-- 4. Privilegios
-- ----------------------------------------------------------------------------

-- `authenticated` también en el revoke: en una base creada desde cero los default privileges de la
-- imagen le dan EXECUTE sobre cada función nueva de public (ver 0008). hoy_montevideo() es interna:
-- la llaman funciones SECURITY DEFINER (que corren como su dueño) y, como campania_vigente(), el
-- service_role. Las demás funciones de esta migración son `create or replace`: conservan sus
-- privilegios.
revoke all on function public.hoy_montevideo(timestamptz) from public, anon, authenticated;
grant execute on function public.hoy_montevideo(timestamptz) to service_role;
