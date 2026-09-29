-- ============================================================================
-- 0008 · Zonas dentro del mapa de la campaña (backend-supabase#22)
--
-- Cambio de modelo del 29/09 (vistas de Claude Design «Vistas colportaje»: esquema-datos,
-- vista 24 del panel). Una campaña abarca varias ciudades y cada ciudad se divide en zonas
-- dibujadas sobre el mapa:
--
--   campania ─< campania_ciudad >─ ciudad
--                    └─< zona (RADIAL | ESQUINAS) ─< zona_vertice
--
--   · campania_ciudad reemplaza a campania.ciudad_id.
--   · zona cuelga de campania_ciudad y deja zona.ciudad_id y zona.campania_id.
--   · zona.poligono_geojson es LA geometría: la dibujan la app y el panel, y con ella se
--     ubica cada dirección (#24). RADIAL: la calcula el servidor (círculo). ESQUINAS: llega
--     calculada (el recorrido por calles es #25, que espera la decisión D3) y se valida.
--   · Dos zonas vivas de la misma campania_ciudad no comparten interior; sí un borde.
--
-- ## Datos existentes (criterio 2: nada se pierde)
--
-- Antes de tocar nada se revisan TODAS las zonas y, si alguna no se puede migrar, la
-- migración aborta y lista cada una con el porqué y qué hacer:
--   · sin campaña (zona.campania_id null): no hay a qué campania_ciudad colgarla;
--   · sin forma, o con una forma que no es un polígono simple válido: no se inventan formas;
--   · dos zonas vivas con el mismo nombre, o que se superponen, en la misma campaña y ciudad.
-- Con todo en regla:
--   · cada campaña queda con su fila de campania_ciudad (su ciudad actual), y cada zona en la
--     de su (campania_id, ciudad_id), que se crea si no existe;
--   · cada zona existente pasa a ESQUINAS con SU polígono intacto, y los puntos de su borde se
--     copian como vértices (orden 1..n, sin el punto de cierre). Es la única forma que
--     representa un polígono cualquiera sin cambiarlo. calle_a/calle_b quedan vacías.
--   · recién después se borran campania.ciudad_id, zona.ciudad_id y zona.campania_id.
--
-- ## Decisiones que se proponen acá (se confirman en la revisión)
--
--   · Tolerancia de superposición: la parte común se erosiona 0,5 m (geography). Si no queda
--     nada, la franja compartida mide menos de 1 m de ancho en todo su largo: es ruido
--     numérico del borde calculado por calles, no una superposición. Un metro es menos que
--     cualquier casa, así que no esconde un conflicto real.
--   · Círculo RADIAL: 128 puntos a radio_m del centro con ST_Project (geodésico, exacto sobre
--     el elipsoide), unidos en orden. El polígono queda inscripto: el error máximo, en el medio
--     de cada lado, es r·(1 − cos(π/128)) ≈ 0,03 % del radio (0,12 m a 400 m, 0,30 m a 1 km).
--     Cumple «contiene r − 1 m y no r + 1 m» hasta unos 3,3 km de radio. Coordenadas con 7
--     decimales (~1 cm).
--   · ESQUINAS: cada vértice tiene que quedar a 1 m o menos del borde recibido.
--   · El mapa de una campaña TERMINADA no se cambia (ni el ADMIN): recalcularía las
--     ubicaciones de una temporada cerrada (#24). Una campaña futura sí se puede preparar.
--   · Baja de una zona con colportores asignados: se rechaza (CZ010) y dice a quiénes
--     reasignar (opción conservadora del issue).
--   · El colportor ve las ciudades, zonas y vértices de toda campaña en la que tiene una
--     inscripción viva, vigente o no (la app puede bajar el mapa antes de que empiece).
--
-- ## PostGIS (para el ADR de Colportores/docs-organizacion#16)
--
-- Se habilita en `extensions`, como recomienda Supabase. Lo que resuelve en la base: validez
-- del polígono (ST_IsValid), superposición con tolerancia en metros (ST_Intersection +
-- ST_Buffer sobre geography), círculo geodésico (ST_Project), e índice GiST para ubicar
-- puntos (#24, ST_Covers). La alternativa sin PostGIS (turf en el BFF) deja la regla fuera de
-- la base: un segundo camino de escritura (seed, service_role, otro BFF) la saltea, y la
-- carrera entre dos guardados concurrentes se resuelve con locks en dos lugares. Costo: la
-- extensión y las funciones calificadas con `extensions.` (search_path vacío).
-- La geometría NO es una columna: sync.pull serializa todas las columnas de la tabla y la
-- mandaría repetida. Se deriva de poligono_geojson con zona_geometria() (inmutable) y el
-- índice GiST es sobre esa expresión.
--
-- ## Códigos (familia CZ, como asignar_zona)
--
--   CZ001 campaña inexistente         CZ007 superposición (DETAIL: JSON con la intersección)
--   CZ004 zona inexistente o de baja  CZ008 forma o datos de la zona no válidos
--   CZ005 zona de una ciudad quitada  CZ009 nombre vacío o repetido en la ciudad
--         de la campaña (asignar)     CZ010 baja de una zona con colportores asignados
--   CZ006 zona de otra campaña        CZ011 campaña terminada: el mapa no se cambia
--                                     CZ012 la ciudad no está en esta campaña
--                                     CZ013 la ciudad no está en el catálogo
--
-- ## Puntos de extensión
--
--   · zona_ubicaciones_que_cambian(): cuántas ubicaciones cambiarían de zona. Devuelve null
--     hasta #24, que la reemplaza con el conteo real. guardar_zona() y baja_zona() ya la
--     llaman y la devuelven, en la vista previa y al guardar.
--   · #23 saca usuario.zona_id y pasa a comparar la zona de la inscripción por
--     campania_ciudad con un trigger; acá solo se adapta motivo_rechazo_zona() al modelo.
--
-- ## Sync (dueño del motor: @BrunoFCapri)
--
-- campania_ciudad y zona_vertice entran a sync.entidad como pull, con su índice de delta.
-- zona ya estaba; cambia su forma (columnas nuevas y dos menos) y su RLS: deja de ser
-- lectura para todo autenticado.
--
-- Forward-only: esta migración no se edita una vez aplicada.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. PostGIS y helpers de geometría (no leen tablas)
-- ----------------------------------------------------------------------------

create extension if not exists postgis with schema extensions;

-- La geometría de una zona. Inmutable: el índice GiST es sobre esta expresión.
create function public.zona_geometria(p_poligono jsonb)
returns extensions.geometry
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  select extensions.st_setsrid(extensions.st_geomfromgeojson(p_poligono::text), 4326);
$$;

comment on function public.zona_geometria(jsonb) is
  'Geometría (SRID 4326) de un poligono_geojson. El índice GiST de zona es sobre esta expresión.';

-- null si p_poligono es un Polygon GeoJSON simple y válido; si no, el porqué, en palabras
-- para el aviso. Una zona es UN borde: sin huecos ni varios anillos.
create function public.zona_problema_de_forma(p_poligono jsonb)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_anillo jsonb;
  v_pos    jsonb;
  v_geom   extensions.geometry;
begin
  if p_poligono is null then
    return 'no tiene forma';
  end if;
  if jsonb_typeof(p_poligono) <> 'object' or (p_poligono ->> 'type') is distinct from 'Polygon' then
    return 'no es un Polygon GeoJSON';
  end if;
  if jsonb_typeof(p_poligono -> 'coordinates') is distinct from 'array'
     or jsonb_array_length(p_poligono -> 'coordinates') = 0 then
    return 'no tiene coordenadas';
  end if;
  if jsonb_array_length(p_poligono -> 'coordinates') > 1 then
    return 'tiene huecos o más de un borde, y una zona es un solo borde';
  end if;

  v_anillo := p_poligono -> 'coordinates' -> 0;
  if jsonb_typeof(v_anillo) is distinct from 'array' or jsonb_array_length(v_anillo) < 4 then
    return 'tiene menos de 3 puntos';
  end if;

  for v_pos in select e from jsonb_array_elements(v_anillo) e loop
    if jsonb_typeof(v_pos) <> 'array' or jsonb_array_length(v_pos) < 2 then
      return 'tiene un punto que no es una coordenada [lon, lat]';
    end if;
    if jsonb_typeof(v_pos -> 0) <> 'number' or jsonb_typeof(v_pos -> 1) <> 'number' then
      return 'tiene un punto que no es una coordenada [lon, lat]';
    end if;
    if abs((v_pos ->> 0)::numeric) > 180 or abs((v_pos ->> 1)::numeric) > 90 then
      return 'tiene un punto fuera del mapa (lon entre -180 y 180, lat entre -90 y 90)';
    end if;
  end loop;

  if (v_anillo -> 0) is distinct from (v_anillo -> -1) then
    return 'el borde no está cerrado: el último punto tiene que repetir el primero';
  end if;

  begin
    v_geom := public.zona_geometria(p_poligono);
  exception when others then
    return 'no se puede leer como GeoJSON (' || sqlerrm || ')';
  end;

  -- st_isvalidreason y no st_isvalid: el segundo tira un NOTICE por cada forma inválida.
  if extensions.st_isvalidreason(v_geom) <> 'Valid Geometry' then
    return 'el borde se cruza a sí mismo (' || extensions.st_isvalidreason(v_geom) || ')';
  end if;
  if extensions.st_area(v_geom) = 0 then
    return 'no encierra ningún área';
  end if;

  return null;
end;
$$;

comment on function public.zona_problema_de_forma(jsonb) is
  'null si el GeoJSON es un Polygon simple (un solo borde, cerrado) y válido; si no, el motivo.';

-- Círculo aproximado de una zona RADIAL: ver la cabecera (128 puntos geodésicos).
create function public.zona_circulo_geojson(p_lat double precision, p_lon double precision,
                                            p_radio_m integer)
returns jsonb
language sql
immutable
strict
parallel safe
set search_path = ''
as $$
  with puntos as (
    select array_agg(
             extensions.geometry(extensions.st_project(
               extensions.geography(extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326)),
               p_radio_m::double precision,
               radians(360.0 * i / 128)))
             order by i) as p
      from generate_series(0, 127) i
  )
  select extensions.st_asgeojson(
           extensions.st_makepolygon(extensions.st_addpoint(extensions.st_makeline(p.p), p.p[1])),
           7)::jsonb
    from puntos p;
$$;

comment on function public.zona_circulo_geojson(double precision, double precision, integer) is
  'Polígono de 128 lados inscripto en el círculo geodésico (centro, radio en metros). Error '
  'máximo r·(1 − cos(π/128)) ≈ 0,03 % del radio.';

-- La parte superpuesta de dos zonas, o null si solo comparten borde (o una franja de menos
-- de 1 m de ancho: ver la tolerancia en la cabecera).
create function public.zona_superposicion(p_a extensions.geometry, p_b extensions.geometry)
returns extensions.geometry
language plpgsql
immutable
strict
parallel safe
set search_path = ''
as $$
declare
  v_comun extensions.geometry;
begin
  if not extensions.st_intersects(p_a, p_b) then
    return null;
  end if;
  v_comun := extensions.st_collectionextract(extensions.st_intersection(p_a, p_b), 3);
  if extensions.st_isempty(v_comun) then
    return null;
  end if;
  if extensions.st_isempty(extensions.geometry(
       extensions.st_buffer(extensions.geography(v_comun), -0.5::double precision))) then
    return null;
  end if;
  return v_comun;
end;
$$;

comment on function public.zona_superposicion(extensions.geometry, extensions.geometry) is
  'Interior común de dos zonas más ancho que 1 m (erosión de 0,5 m), o null.';

-- ----------------------------------------------------------------------------
-- 2. Qué zonas no se pueden migrar: se revisa TODO antes de cambiar nada
-- ----------------------------------------------------------------------------

do $$
declare
  v_problemas text;
begin
  -- Primera pasada: sin campaña o sin una forma utilizable.
  select string_agg(format('  · «%s» (%s): %s', z.nombre, z.id, p.problema),
                    E'\n' order by z.nombre, z.id)
    into v_problemas
    from public.zona z
    cross join lateral (
      select case
        when z.campania_id is null then
          'no tiene campaña, y ahora cada zona es de una ciudad de una campaña. Cargale la '
          'campaña en zona.campania_id y volvé a aplicar la migración.'
        when z.poligono_geojson is null then
          'no tiene forma (poligono_geojson vacío) y no se inventan formas. Cargale el polígono '
          '(un Polygon GeoJSON) y volvé a aplicar la migración.'
        when public.zona_problema_de_forma(z.poligono_geojson) is not null then
          format('su forma no sirve: %s. Corregí poligono_geojson y volvé a aplicar la migración.',
                 public.zona_problema_de_forma(z.poligono_geojson))
      end as problema
    ) p
   where p.problema is not null;

  if v_problemas is not null then
    raise exception using
      message = 'La migración 0008 (zonas en el mapa de la campaña) no se aplicó: hay zonas que no '
                'se pueden migrar sin perder o inventar datos. No se cambió nada.',
      detail  = v_problemas,
      hint    = 'Corregí cada zona de la lista y volvé a aplicar la migración.';
  end if;

  -- Segunda pasada (las formas ya son válidas): nombre repetido o superposición entre zonas
  -- vivas de la misma campaña y ciudad.
  select string_agg(x.linea, E'\n' order by x.linea)
    into v_problemas
    from (
      select format('  · «%s» (%s) y «%s» (%s): %s', a.nombre, a.id, b.nombre, b.id,
               case when a.nombre = b.nombre
                    then 'tienen el mismo nombre en la misma campaña y ciudad. Renombrá una.'
                    else 'se superponen. Ajustá el borde de una para que solo compartan la calle.'
               end) as linea
        from public.zona a
        join public.zona b
          on b.campania_id = a.campania_id and b.ciudad_id = a.ciudad_id and b.id > a.id
       where a.deleted_at is null and b.deleted_at is null
         and (a.nombre = b.nombre
              or public.zona_superposicion(public.zona_geometria(a.poligono_geojson),
                                           public.zona_geometria(b.poligono_geojson)) is not null)
    ) x;

  if v_problemas is not null then
    raise exception using
      message = 'La migración 0008 (zonas en el mapa de la campaña) no se aplicó: hay zonas vivas '
                'de la misma campaña y ciudad que chocan entre sí. No se cambió nada.',
      detail  = v_problemas,
      hint    = 'Corregí cada par de la lista (o dale de baja a una de las dos) y volvé a aplicar '
                'la migración.';
  end if;
end
$$;

-- ----------------------------------------------------------------------------
-- 3. campania_ciudad
-- ----------------------------------------------------------------------------

create table public.campania_ciudad (
  id            uuid primary key default public.uuid_generate_v7(),
  campania_id   uuid not null references public.campania(id),
  ciudad_id     uuid not null references public.ciudad(id),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id(),
  unique (campania_id, ciudad_id)
);
create index campania_ciudad_ciudad_id_idx on public.campania_ciudad (ciudad_id);

comment on table public.campania_ciudad is
  'Ciudad incluida en una campaña (una campaña abarca una o más). Las zonas cuelgan de acá.';

create trigger campania_ciudad_auditoria_insert before insert on public.campania_ciudad
  for each row execute function public.tg_auditoria_insert();
create trigger campania_ciudad_auditoria_update before update on public.campania_ciudad
  for each row execute function public.tg_auditoria_update();
alter table public.campania_ciudad enable row level security;

-- Las zonas cuelgan de la fila: cambiarle la campaña o la ciudad movería todas sus zonas.
create function public.tg_campania_ciudad_identidad()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.campania_id is distinct from old.campania_id or new.ciudad_id is distinct from old.ciudad_id then
    raise exception 'Una ciudad de la campaña no cambia de campaña ni de ciudad: sus zonas cuelgan de ella. '
                    'Agregá la otra ciudad a la campaña.'
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger campania_ciudad_identidad before update on public.campania_ciudad
  for each row execute function public.tg_campania_ciudad_identidad();

-- Una fila por campaña con su ciudad actual (también las campañas dadas de baja: es su dato).
insert into public.campania_ciudad (campania_id, ciudad_id, created_at, created_by)
select c.id, c.ciudad_id, c.created_at, c.created_by
  from public.campania c;

-- Y la de cada zona cuya ciudad no es la de su campaña.
insert into public.campania_ciudad (campania_id, ciudad_id)
select distinct z.campania_id, z.ciudad_id
  from public.zona z
 where z.campania_id is not null
on conflict (campania_id, ciudad_id) do nothing;

-- ----------------------------------------------------------------------------
-- 4. zona: forma y campania_ciudad
-- ----------------------------------------------------------------------------

alter table public.zona
  add column campania_ciudad_id uuid references public.campania_ciudad(id),
  add column tipo_forma         text,
  add column centro_lat         double precision,
  add column centro_lon         double precision,
  add column radio_m            integer,
  add column color              text;

update public.zona z
   set campania_ciudad_id = cc.id,
       tipo_forma = 'ESQUINAS'
  from public.campania_ciudad cc
 where cc.campania_id = z.campania_id and cc.ciudad_id = z.ciudad_id;

alter table public.zona
  alter column campania_ciudad_id set not null,
  alter column tipo_forma set not null,
  alter column poligono_geojson set not null,
  add constraint zona_tipo_forma_valido check (tipo_forma in ('RADIAL', 'ESQUINAS')),
  add constraint zona_radial_completa check (
    tipo_forma <> 'RADIAL' or (centro_lat is not null and centro_lon is not null and radio_m is not null)),
  add constraint zona_radio_positivo check (radio_m is null or radio_m > 0),
  add constraint zona_centro_en_el_mapa check (
    (centro_lat is null or centro_lat between -90 and 90)
    and (centro_lon is null or centro_lon between -180 and 180)),
  add constraint zona_color_hex check (color is null or color ~ '^#[0-9A-Fa-f]{6}$');

create index zona_campania_ciudad_idx on public.zona (campania_ciudad_id);
create unique index zona_nombre_por_ciudad_uidx on public.zona (campania_ciudad_id, nombre)
  where deleted_at is null;
create index zona_geometria_idx on public.zona
  using gist (public.zona_geometria(poligono_geojson))
  where deleted_at is null;

comment on column public.zona.poligono_geojson is
  'Polygon GeoJSON (lon, lat). RADIAL: lo calcula el servidor. ESQUINAS: el recorrido por calles '
  'entre los vértices, validado al guardar. Es lo que se dibuja y con lo que se ubica cada dirección.';

-- ----------------------------------------------------------------------------
-- 5. zona_vertice
-- ----------------------------------------------------------------------------

create table public.zona_vertice (
  id            uuid primary key default public.uuid_generate_v7(),
  zona_id       uuid not null references public.zona(id),
  orden         integer not null,
  lat           double precision not null check (lat between -90 and 90),
  lon           double precision not null check (lon between -180 and 180),
  calle_a       text,
  calle_b       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid references public.usuario(id) on delete set null,
  deleted_at    timestamptz,
  sync_version  bigint not null default 0,
  xmin_w        xid8 not null default pg_current_xact_id()
);
-- Único entre las vivas: al editar, la esquina que se quita queda como baja (tombstone para
-- el sync) y su orden se puede volver a usar.
create unique index zona_vertice_orden_uidx on public.zona_vertice (zona_id, orden)
  where deleted_at is null;
create index zona_vertice_zona_idx on public.zona_vertice (zona_id, orden);

comment on table public.zona_vertice is
  'Esquina de una zona ESQUINAS, en orden; el borde va de cada una a la siguiente por las calles '
  'y de la última a la primera. Al menos 3 vivas: se valida al guardar (guardar_zona), no con un CHECK.';

create trigger zona_vertice_auditoria_insert before insert on public.zona_vertice
  for each row execute function public.tg_auditoria_insert();
create trigger zona_vertice_auditoria_update before update on public.zona_vertice
  for each row execute function public.tg_auditoria_update();
alter table public.zona_vertice enable row level security;

-- Los puntos del borde de cada zona existente (ya todas ESQUINAS), sin el de cierre.
insert into public.zona_vertice (zona_id, orden, lat, lon, created_at, deleted_at)
select z.id, d.path[1], extensions.st_y(d.geom), extensions.st_x(d.geom), z.created_at, z.deleted_at
  from public.zona z
  cross join lateral extensions.st_exteriorring(public.zona_geometria(z.poligono_geojson)) r(anillo)
  cross join lateral extensions.st_dumppoints(r.anillo) d
 where d.path[1] < extensions.st_npoints(r.anillo);

-- ----------------------------------------------------------------------------
-- 6. Las columnas viejas: primero lo que las usa
-- ----------------------------------------------------------------------------

drop policy precio_por_zona_insert_staff on public.precio_por_zona;
drop policy precio_por_zona_update_staff on public.precio_por_zona;
drop policy zona_select_autenticado on public.zona;
drop policy zona_insert_admin on public.zona;
drop policy zona_update_admin on public.zona;

alter table public.zona drop column ciudad_id, drop column campania_id;
alter table public.campania drop column ciudad_id;

-- ----------------------------------------------------------------------------
-- 7. Superposición, forma y lock del mapa: valen para todo camino de escritura
-- ----------------------------------------------------------------------------

-- Zonas vivas de la campania_ciudad cuya forma se superpone con p_poligono (sin contar
-- p_zona_id, la que se está editando). Interna.
create function public.zona_superposiciones(p_campania_ciudad_id uuid, p_poligono jsonb,
                                            p_zona_id uuid)
returns table (zona_id uuid, nombre text, interseccion jsonb)
language sql
stable
set search_path = ''
as $$
  select z.id, z.nombre, extensions.st_asgeojson(s.comun, 7)::jsonb
    from public.zona z
    cross join lateral (
      select public.zona_superposicion(public.zona_geometria(z.poligono_geojson),
                                       public.zona_geometria(p_poligono)) as comun
    ) s
   where z.campania_ciudad_id = p_campania_ciudad_id
     and z.deleted_at is null
     and z.id is distinct from p_zona_id
     and extensions.st_intersects(public.zona_geometria(z.poligono_geojson),
                                  public.zona_geometria(p_poligono))
     and s.comun is not null
   order by z.nombre, z.id;
$$;

comment on function public.zona_superposiciones(uuid, jsonb, uuid) is
  'Zonas vivas de la campania_ciudad que se superponen con p_poligono (sin p_zona_id), con la '
  'geometría de la parte común. Interna.';

-- Serializa los cambios de forma dentro de una campania_ciudad: sin esto, dos guardados
-- concurrentes se validan cada uno sin ver al otro y quedan superpuestos.
create function public.bloquear_mapa(p_campania_ciudad_id uuid)
returns void
language sql
set search_path = ''
as $$
  select pg_advisory_xact_lock(hashtextextended('mapa_zonas:' || p_campania_ciudad_id::text, 0));
$$;

-- El aviso de superposición: el mensaje nombra la primera zona, el DETAIL lleva todas con la
-- geometría de la parte común para que el panel la marque en rojo (vista 24).
create function public.lanzar_superposicion(p_superposiciones jsonb)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_superposiciones is null or jsonb_array_length(p_superposiciones) = 0 then
    return;
  end if;
  raise exception 'Esta zona se superpone con «%». Ajustá el borde para que solo compartan la calle.',
      p_superposiciones -> 0 ->> 'nombre'
    using errcode = 'CZ007',
          detail = jsonb_build_object('superposiciones', p_superposiciones)::text;
end;
$$;

-- BEFORE INSERT/UPDATE de zona. Guardar_zona() valida lo mismo y con mejores avisos; esto es
-- la red para cualquier otro camino (seed, service_role, un job).
--   · RADIAL: el polígono lo calcula el servidor, siempre (lo que mande el cliente se pisa).
--   · La forma tiene que ser un polígono simple válido (CZ008).
--   · Una zona viva no se superpone con otra viva de su campania_ciudad (CZ007).
--   · Una zona no cambia de campania_ciudad.
create function public.tg_zona_mapa()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_problema text;
  v_sup      jsonb;
begin
  if tg_op = 'UPDATE' and new.campania_ciudad_id is distinct from old.campania_ciudad_id then
    raise exception 'Una zona no cambia de ciudad ni de campaña. Creá una zona nueva donde corresponda.'
      using errcode = 'check_violation';
  end if;

  if new.tipo_forma = 'RADIAL' then
    if new.centro_lat is null or new.centro_lon is null or new.radio_m is null or new.radio_m <= 0 then
      raise exception 'Una zona radial necesita centro y un radio mayor a 0. Marcá el centro en el mapa y elegí el radio.'
        using errcode = 'CZ008';
    end if;
    new.poligono_geojson := public.zona_circulo_geojson(new.centro_lat, new.centro_lon, new.radio_m);
  end if;

  v_problema := public.zona_problema_de_forma(new.poligono_geojson);
  if v_problema is not null then
    raise exception 'El borde de la zona «%» no sirve: %. Volvé a cerrar la forma.', new.nombre, v_problema
      using errcode = 'CZ008';
  end if;

  -- Solo se busca superposición si la zona queda viva con una forma nueva (o vuelve de una baja).
  if new.deleted_at is not null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.deleted_at is null and new.poligono_geojson = old.poligono_geojson then
    return new;
  end if;

  perform public.bloquear_mapa(new.campania_ciudad_id);
  select jsonb_agg(jsonb_build_object('zona_id', s.zona_id, 'nombre', s.nombre,
                                      'interseccion', s.interseccion)
                   order by s.nombre, s.zona_id)
    into v_sup
    from public.zona_superposiciones(new.campania_ciudad_id, new.poligono_geojson, new.id) s;
  perform public.lanzar_superposicion(v_sup);

  return new;
end;
$$;

create trigger zona_mapa before insert or update on public.zona
  for each row execute function public.tg_zona_mapa();

-- ----------------------------------------------------------------------------
-- 8. Lectura: RLS de campania_ciudad, zona y zona_vertice. Escritura: solo por los RPC
-- ----------------------------------------------------------------------------

-- Las filas de campania_ciudad que ve el usuario autenticado: las de las campañas que
-- coordina y las de las campañas en las que tiene una inscripción viva (vigente o no). Sin
-- el ADMIN, que las políticas suman aparte. Un usuario dado de baja no ve nada (ADR-011).
create function public.mis_campania_ciudades()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select cc.id
    from public.campania_ciudad cc
    join public.campania c on c.id = cc.campania_id
    join public.usuario u on u.id = c.coordinador_id
   where c.coordinador_id = auth.uid() and u.deleted_at is null
  union
  select cc.id
    from public.campania_ciudad cc
    join public.campania_colportor ins on ins.campania_id = cc.campania_id
    join public.usuario u on u.id = ins.usuario_id
   where ins.usuario_id = auth.uid() and ins.deleted_at is null and u.deleted_at is null;
$$;

comment on function public.mis_campania_ciudades() is
  'campania_ciudad visibles para el usuario autenticado: las de las campañas que coordina y las '
  'de aquellas en las que está inscripto (inscripción viva). La usan las políticas del mapa.';

-- Incluye las bajas lógicas: la app necesita el tombstone para borrar su réplica.
create policy campania_ciudad_select on public.campania_ciudad
  for select to authenticated
  using ((select public.tiene_rol('ADMIN'))
         or id in (select public.mis_campania_ciudades()));

-- Todas las zonas de las ciudades de la campaña, no solo la propia: el mapa las dibuja y la
-- app calcula la zona de cada punto.
create policy zona_select on public.zona
  for select to authenticated
  using ((select public.tiene_rol('ADMIN'))
         or campania_ciudad_id in (select public.mis_campania_ciudades()));

-- Ve el vértice quien ve la zona (la subconsulta pasa por la RLS de zona).
create policy zona_vertice_select on public.zona_vertice
  for select to authenticated
  using (zona_id in (select z.id from public.zona z));

-- Sin políticas de escritura y sin el privilegio: un INSERT/UPDATE directo falla con 42501
-- antes de llegar a los triggers. Escriben guardar_zona(), baja_zona() y
-- agregar_ciudad_a_campania() (SECURITY DEFINER).
-- Los grants de las tablas nuevas van explícitos: los default privileges de `public` dependen
-- de cómo se creó el schema (db-reset.sh lo recrea y se pierden), y 0001 §10 no alcanza a
-- tablas que no existían.
revoke all on public.campania_ciudad, public.zona_vertice from anon, authenticated;
grant select on public.campania_ciudad, public.zona_vertice to authenticated;
grant all on public.campania_ciudad, public.zona_vertice to service_role;
revoke insert, update on public.zona from authenticated;

-- precio_por_zona: mismas políticas de 0003, ahora llegando a la campaña por campania_ciudad.
create policy precio_por_zona_insert_staff on public.precio_por_zona
  for insert to authenticated
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.zona z
            join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
            join public.campania c on c.id = cc.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = (select auth.uid())))
  );

create policy precio_por_zona_update_staff on public.precio_por_zona
  for update to authenticated
  using (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.zona z
            join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
            join public.campania c on c.id = cc.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = (select auth.uid())))
  )
  with check (
    (select public.tiene_rol('ADMIN'))
    or ((select public.tiene_rol('COORDINADOR')) and exists (
          select 1 from public.zona z
            join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
            join public.campania c on c.id = cc.campania_id
           where z.id = precio_por_zona.zona_id and c.coordinador_id = (select auth.uid())))
  );

-- ----------------------------------------------------------------------------
-- 9. Permiso sobre el mapa de una campaña
-- ----------------------------------------------------------------------------

-- null si el usuario autenticado puede cambiar el mapa de p_campania_id: es ADMIN o su
-- coordinador, y la campaña existe y no terminó (una futura sí). Interna.
create function public.motivo_mapa_de_campania(p_campania_id uuid)
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

  if v_campania.fecha_fin is not null and v_campania.fecha_fin < current_date then
    return 'CAMPANIA_TERMINADA';
  end if;

  return null;
end;
$$;

comment on function public.motivo_mapa_de_campania(uuid) is
  'null si el usuario autenticado es ADMIN o el coordinador de p_campania_id y la campaña no '
  'terminó; si no, SIN_PERMISO | CAMPANIA_INEXISTENTE | CAMPANIA_TERMINADA. Interna.';

create function public.lanzar_motivo_mapa(p_motivo text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  case p_motivo
    when 'SIN_PERMISO' then
      raise exception 'Solo el coordinador de la campaña o un administrador puede cambiar su mapa.'
        using errcode = 'insufficient_privilege';
    when 'CAMPANIA_INEXISTENTE' then
      raise exception 'La campaña no existe. Elegí otra campaña.' using errcode = 'CZ001';
    when 'ZONA_INEXISTENTE' then
      raise exception 'La zona no existe o ya se dio de baja. Recargá el mapa.' using errcode = 'CZ004';
    when 'CAMPANIA_TERMINADA' then
      raise exception 'La campaña ya terminó y su mapa queda como estaba. Dibujá las zonas en una campaña activa o futura.'
        using errcode = 'CZ011';
    when 'CIUDAD_FUERA_DE_CAMPANIA' then
      raise exception 'La ciudad no está en esta campaña. Agregala con «+ Agregar ciudad» y volvé a intentar.'
        using errcode = 'CZ012';
    when 'ZONA_DE_OTRA_CIUDAD' then
      raise exception 'La zona no es de esta ciudad de la campaña. Recargá el mapa.'
        using errcode = 'CZ012';
    when 'CIUDAD_INEXISTENTE' then
      raise exception 'La ciudad no está en el catálogo. Pedile a un administrador que la cargue.'
        using errcode = 'CZ013';
    else
      null;
  end case;
end;
$$;

-- ----------------------------------------------------------------------------
-- 10. Punto de extensión de #24
-- ----------------------------------------------------------------------------

-- Cuántas ubicaciones cambiarían de zona si p_zona_id (null = zona nueva) pasa a tener
-- p_poligono (null = baja). null = todavía no se calcula: lo implementa #24.
create function public.zona_ubicaciones_que_cambian(p_zona_id uuid, p_campania_ciudad_id uuid,
                                                    p_poligono jsonb)
returns integer
language sql
stable
set search_path = ''
as $$
  select null::integer;
$$;

comment on function public.zona_ubicaciones_que_cambian(uuid, uuid, jsonb) is
  'Punto de extensión: ubicaciones que cambiarían de zona. null hasta #24. Interna.';

-- ----------------------------------------------------------------------------
-- 11. RPC del mapa (bff-coordinadores, vista 24)
-- ----------------------------------------------------------------------------

-- «+ Agregar ciudad»: suma una ciudad del catálogo a la campaña. Idempotente: si ya está,
-- devuelve la fila (y si estaba dada de baja, la reactiva).
create function public.agregar_ciudad_a_campania(p_campania_id uuid, p_ciudad_id uuid)
returns public.campania_ciudad
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_fila public.campania_ciudad;
begin
  if auth.uid() is null then
    raise exception 'agregar_ciudad_a_campania requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(p_campania_id));

  if not exists (select 1 from public.ciudad c where c.id = p_ciudad_id and c.deleted_at is null) then
    perform public.lanzar_motivo_mapa('CIUDAD_INEXISTENTE');
  end if;

  insert into public.campania_ciudad (campania_id, ciudad_id, created_by)
  values (p_campania_id, p_ciudad_id, auth.uid())
  on conflict (campania_id, ciudad_id) do nothing;

  select * into v_fila from public.campania_ciudad cc
   where cc.campania_id = p_campania_id and cc.ciudad_id = p_ciudad_id
     for update;

  if v_fila.deleted_at is not null then
    update public.campania_ciudad cc set deleted_at = null
     where cc.id = v_fila.id
    returning * into v_fila;
  end if;

  return v_fila;
end;
$$;

comment on function public.agregar_ciudad_a_campania(uuid, uuid) is
  'Vista 24 «+ Agregar ciudad»: agrega p_ciudad_id (catálogo) a p_campania_id y devuelve la fila. '
  'Errores: 42501 sin permiso; CZ001 campaña inexistente; CZ011 terminada; CZ013 ciudad inexistente.';

-- Crea (p_zona_id null) o edita una zona con sus vértices, en una transacción. Con
-- p_vista_previa no guarda: devuelve el polígono, las superposiciones y cuántas ubicaciones
-- cambiarían de zona (lo que la vista 24 muestra antes de guardar).
--
-- p_vertices (solo ESQUINAS): [{"orden": 1, "lat": -34.9, "lon": -56.1,
--                               "calle_a": "Grecia", "calle_b": "Vigo"}, ...]
-- p_poligono_geojson (solo ESQUINAS): el recorrido por calles ya calculado (#25). No se
--   rellena con rectas entre esquinas: sin polígono, CZ008. En RADIAL se ignora: lo calcula
--   el servidor.
--
-- Devuelve {"guardada", "zona", "vertices", "poligono_geojson", "superposiciones",
--           "ubicaciones_que_cambian"}.
create function public.guardar_zona(
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
  v_sup       jsonb;
  v_cambian   integer;
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

  -- Un guardado a la vez por ciudad de la campaña: la superposición y el nombre se validan
  -- viendo lo último que se guardó.
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
      v_orden := (v_v ->> 'orden')::integer;
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

  select coalesce(jsonb_agg(jsonb_build_object('zona_id', s.zona_id, 'nombre', s.nombre,
                                               'interseccion', s.interseccion)
                            order by s.nombre, s.zona_id), '[]'::jsonb)
    into v_sup
    from public.zona_superposiciones(v_cc.id, v_poligono, p_zona_id) s;

  v_cambian := public.zona_ubicaciones_que_cambian(p_zona_id, v_cc.id, v_poligono);

  if p_vista_previa then
    return jsonb_build_object('guardada', false, 'zona', null, 'vertices', null,
                              'poligono_geojson', v_poligono, 'superposiciones', v_sup,
                              'ubicaciones_que_cambian', v_cambian);
  end if;

  perform public.lanzar_superposicion(v_sup);

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
    'superposiciones', '[]'::jsonb,
    'ubicaciones_que_cambian', v_cambian);
end;
$$;

comment on function public.guardar_zona(uuid, text, text, text, double precision, double precision,
                                        integer, jsonb, jsonb, uuid, boolean) is
  'Vista 24: crea o edita una zona y sus vértices; con p_vista_previa solo devuelve polígono, '
  'superposiciones y ubicaciones que cambiarían. Errores: 42501; CZ001, CZ004, CZ007 (DETAIL con '
  'la intersección), CZ008, CZ009, CZ011, CZ012.';

-- Baja (soft delete) de una zona. Si tiene colportores asignados se rechaza y dice a quiénes
-- reasignar. Con p_vista_previa no da de baja: devuelve los asignados y cuántas ubicaciones
-- quedarían sin zona.
create function public.baja_zona(p_zona_id uuid, p_vista_previa boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_zona       public.zona;
  v_cc         public.campania_ciudad;
  v_asignados  jsonb;
  v_nombres    text;
  v_cambian    integer;
begin
  if auth.uid() is null then
    raise exception 'baja_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  if not (public.tiene_rol('ADMIN') or public.tiene_rol('COORDINADOR')) then
    perform public.lanzar_motivo_mapa('SIN_PERMISO');
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;
  select * into v_cc from public.campania_ciudad cc where cc.id = v_zona.campania_ciudad_id;
  perform public.lanzar_motivo_mapa(public.motivo_mapa_de_campania(v_cc.campania_id));

  -- La fila bloqueada: asignar_zona() toma la misma zona FOR SHARE, así que una asignación
  -- concurrente o termina antes (y se ve abajo) o espera y encuentra la zona dada de baja.
  perform public.bloquear_mapa(v_cc.id);
  select * into v_zona from public.zona z where z.id = p_zona_id for update;
  if v_zona.deleted_at is not null then
    perform public.lanzar_motivo_mapa('ZONA_INEXISTENTE');
  end if;

  -- Asignados: inscripciones vivas con esta zona y, mientras exista (#23 la saca), la zona
  -- directa de usuario.
  select jsonb_agg(jsonb_build_object('usuario_id', u.id, 'nombre', u.nombre, 'apellido', u.apellido)
                   order by u.apellido, u.nombre, u.id),
         string_agg(coalesce(nullif(btrim(concat_ws(' ', u.nombre, u.apellido)), ''), 'un colportor sin nombre'),
                    ', ' order by u.apellido, u.nombre, u.id)
    into v_asignados, v_nombres
    from public.usuario u
   where u.deleted_at is null
     and (u.zona_id = p_zona_id
          or exists (select 1 from public.campania_colportor ins
                      where ins.usuario_id = u.id and ins.zona_id = p_zona_id
                        and ins.deleted_at is null));

  v_cambian := public.zona_ubicaciones_que_cambian(p_zona_id, v_cc.id, null);

  if p_vista_previa then
    return jsonb_build_object('dada_de_baja', false, 'zona', to_jsonb(v_zona) - 'xmin_w',
                              'colportores_asignados', coalesce(v_asignados, '[]'::jsonb),
                              'ubicaciones_que_cambian', v_cambian);
  end if;

  if v_asignados is not null then
    raise exception 'La zona «%» tiene colportores asignados: %. Reasignalos a otra zona antes de darla de baja.',
        v_zona.nombre, v_nombres
      using errcode = 'CZ010',
            detail = jsonb_build_object('colportores_asignados', v_asignados)::text;
  end if;

  update public.zona z set deleted_at = now() where z.id = p_zona_id
  returning * into v_zona;
  update public.zona_vertice v set deleted_at = now()
   where v.zona_id = p_zona_id and v.deleted_at is null;

  return jsonb_build_object('dada_de_baja', true, 'zona', to_jsonb(v_zona) - 'xmin_w',
                            'colportores_asignados', '[]'::jsonb,
                            'ubicaciones_que_cambian', v_cambian);
end;
$$;

comment on function public.baja_zona(uuid, boolean) is
  'Vista 24: da de baja una zona sin colportores asignados (si no, CZ010 con los nombres). Con '
  'p_vista_previa solo informa. Errores: 42501; CZ001, CZ004, CZ010, CZ011.';

-- ----------------------------------------------------------------------------
-- 12. Lo de 0006/0007 que leía zona.campania_id, zona.ciudad_id o campania.ciudad_id
-- ----------------------------------------------------------------------------

-- Misma firma y mismos motivos. La zona tiene que ser de una ciudad de ESTA campaña:
--   ZONA_DE_OTRA_CAMPANIA (CZ006)  su campania_ciudad es de otra campaña.
--   ZONA_DE_OTRA_CIUDAD   (CZ005)  es de esta campaña, pero su ciudad se quitó de ella
--                                  (campania_ciudad dada de baja). Unificar con CZ006 es #23.
create or replace function public.motivo_rechazo_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_motivo text;
  v_zona   public.zona;
  v_cc     public.campania_ciudad;
begin
  v_motivo := public.motivo_campania_del_coordinador(p_campania_id);
  if v_motivo is not null then
    return v_motivo;
  end if;

  if not exists (select 1 from public.campania_colportor cc
                   join public.usuario u on u.id = cc.usuario_id
                  where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
                    and cc.deleted_at is null and u.deleted_at is null) then
    return 'NO_INSCRIPTO';
  end if;

  select * into v_zona from public.zona z where z.id = p_zona_id;
  if not found or v_zona.deleted_at is not null then
    return 'ZONA_INEXISTENTE';
  end if;

  select * into v_cc from public.campania_ciudad cc where cc.id = v_zona.campania_ciudad_id;
  if v_cc.campania_id <> p_campania_id then
    return 'ZONA_DE_OTRA_CAMPANIA';
  end if;
  if v_cc.deleted_at is not null then
    return 'ZONA_DE_OTRA_CIUDAD';
  end if;

  return null;
end;
$$;

-- Igual que en 0006, más un FOR SHARE sobre la zona: baja_zona() la toma FOR UPDATE, así que
-- una baja concurrente no deja a nadie asignado a una zona dada de baja.
create or replace function public.asignar_zona(p_campania_id uuid, p_usuario_id uuid, p_zona_id uuid)
returns public.campania_colportor
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_filas integer;
  v_fila  public.campania_colportor;
begin
  if auth.uid() is null then
    raise exception 'asignar_zona requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  perform 1 from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     for update;

  perform 1 from public.zona z where z.id = p_zona_id for share;

  perform public.lanzar_motivo_zona(public.motivo_rechazo_zona(p_campania_id, p_usuario_id, p_zona_id));

  update public.campania_colportor cc
     set zona_id = p_zona_id
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null
     and cc.zona_id is distinct from p_zona_id;
  get diagnostics v_filas = row_count;

  select * into v_fila from public.campania_colportor cc
   where cc.campania_id = p_campania_id and cc.usuario_id = p_usuario_id
     and cc.deleted_at is null;

  if v_filas = 0 and (v_fila.id is null or v_fila.zona_id is distinct from p_zona_id) then
    perform public.lanzar_motivo_zona('NO_INSCRIPTO');
  end if;

  return v_fila;
end;
$$;

-- Misma firma. Las zonas asignables son las vivas de las ciudades vivas de la campaña;
-- de_esta_campania queda siempre en true (ya no hay zonas sin campaña) y se mantiene para no
-- romper al BFF. Deja de ser STABLE: llama a lanzar_motivo_zona(), que es volátil (lint).
create or replace function public.zonas_asignables(p_campania_id uuid)
returns table (id uuid, nombre text, de_esta_campania boolean)
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'zonas_asignables requiere un usuario autenticado'
      using errcode = 'insufficient_privilege';
  end if;

  perform public.lanzar_motivo_zona(public.motivo_campania_del_coordinador(p_campania_id));

  return query
    select z.id, z.nombre, true
      from public.zona z
      join public.campania_ciudad cc on cc.id = z.campania_ciudad_id
     where cc.campania_id = p_campania_id
       and cc.deleted_at is null
       and z.deleted_at is null
     order by z.nombre, z.id;
end;
$$;

comment on function public.zonas_asignables(uuid) is
  'HU-CAM-006: zonas que asignar_zona() aceptaría en p_campania_id (vivas, de sus ciudades vivas). '
  'de_esta_campania es siempre true. Errores: 42501 sin permiso; CZ001 inexistente; CZ002 no vigente.';

-- Mismo lint: llama a lanzar_motivo_zona(), volátil.
alter function public.colportores_de_campania(uuid) volatile;

-- ----------------------------------------------------------------------------
-- 13. Sync: campania_ciudad y zona_vertice, pull (contrato §2)
-- ----------------------------------------------------------------------------

insert into sync.entidad (nombre, tabla, columna_pk, permite_push) values
  ('campania_ciudad', 'public.campania_ciudad'::regclass, 'id', false),
  ('zona_vertice',    'public.zona_vertice'::regclass,    'id', false);

create index campania_ciudad_delta_idx on public.campania_ciudad (xmin_w, id);
create index zona_vertice_delta_idx    on public.zona_vertice    (xmin_w, id);

-- ----------------------------------------------------------------------------
-- 14. Privilegios
-- ----------------------------------------------------------------------------

revoke all on function
  public.zona_geometria(jsonb),
  public.zona_problema_de_forma(jsonb),
  public.zona_circulo_geojson(double precision, double precision, integer),
  public.zona_superposicion(extensions.geometry, extensions.geometry),
  public.zona_superposiciones(uuid, jsonb, uuid),
  public.bloquear_mapa(uuid),
  public.lanzar_superposicion(jsonb),
  public.tg_zona_mapa(),
  public.tg_campania_ciudad_identidad(),
  public.mis_campania_ciudades(),
  public.motivo_mapa_de_campania(uuid),
  public.lanzar_motivo_mapa(text),
  public.zona_ubicaciones_que_cambian(uuid, uuid, jsonb),
  public.agregar_ciudad_a_campania(uuid, uuid),
  public.guardar_zona(uuid, text, text, text, double precision, double precision, integer, jsonb,
                      jsonb, uuid, boolean),
  public.baja_zona(uuid, boolean)
  from public, anon, authenticated;
-- `authenticated` también: en una base creada desde cero, los default privileges de la imagen
-- de Supabase le dan EXECUTE sobre cada función nueva de public (0001 §10 solo lo saca a
-- public y anon). Tras un db-reset.sh no pasa, y por eso el local no lo mostraba.

-- Funciones puras de geometría: sin datos, las puede usar cualquier autenticado (y las usan
-- los triggers de #24 sobre ubicacion, que corren como quien escribe).
grant execute on function
  public.zona_geometria(jsonb),
  public.zona_problema_de_forma(jsonb),
  public.zona_circulo_geojson(double precision, double precision, integer),
  public.zona_superposicion(extensions.geometry, extensions.geometry)
  to authenticated, service_role;

-- La usan las políticas.
grant execute on function public.mis_campania_ciudades() to authenticated, service_role;

-- Los RPC que llama bff-coordinadores.
grant execute on function
  public.agregar_ciudad_a_campania(uuid, uuid),
  public.guardar_zona(uuid, text, text, text, double precision, double precision, integer, jsonb,
                      jsonb, uuid, boolean),
  public.baja_zona(uuid, boolean)
  to authenticated, service_role;

-- Internas: solo service_role (y el dueño, que es quien corre adentro de los RPC).
grant execute on function
  public.zona_superposiciones(uuid, jsonb, uuid),
  public.bloquear_mapa(uuid),
  public.lanzar_superposicion(jsonb),
  public.motivo_mapa_de_campania(uuid),
  public.lanzar_motivo_mapa(text),
  public.zona_ubicaciones_que_cambian(uuid, uuid, jsonb)
  to service_role;
