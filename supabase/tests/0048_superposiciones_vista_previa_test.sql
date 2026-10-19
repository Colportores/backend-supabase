-- pgTAP · la vista previa de guardar_zona() devuelve las superposiciones y las calles compartidas
-- (migración 0038, backend-supabase#87, HU-CAM-006 «Zonas superpuestas», ADR-018, vista 24)
--   1. Forma y privilegios: las dos funciones internas; guardar_zona() sigue igual de cerrada.
--   2. Sin solape: ciudad vacía, zona radial, zona lejos.
--   3. Compartir calle NO es superponerse: dos zonas vecinas por esquinas (el aviso «Comparte la calle»).
--   4. Tocarse en una sola esquina no cuenta.
--   5. Con solape: parte común, orden, calles compartidas, y el guardado nunca se rechaza.
--   6. Zona propia (editar no se solapa consigo misma), otra ciudad y otra campaña, zonas dadas de baja.
--   7. Ciudad sin calles cargadas (calles_compartidas null) y calle sin nombre (null).
--   8. Permiso: el de guardar_zona(); la respuesta no lleva ni importes ni personas.
--   9. El metro de tolerancia al recorrer un tramo, y las calles de otra ciudad del catálogo no cuentan.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- sqlstate de ejecutar p_sql ('OK' si no falló).
create or replace function pg_temp.codigo(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'OK';
exception when others then
  return sqlstate;
end $$;

-- --- OSM de mentira (el formato de Overpass), como en el test 0045 -------------------------------
create or replace function pg_temp.r7(p double precision) returns double precision language sql immutable as
$$ select round(p::numeric, 7)::double precision $$;

create or replace function pg_temp.nid(p_lon double precision, p_lat double precision) returns bigint
language sql immutable as
$$ select round(p_lon * 1e7)::bigint * 1000000007 + round(p_lat * 1e7)::bigint $$;

create or replace function pg_temp.via(p_id bigint, p_nombre text, p_tipo text, p_pts jsonb) returns jsonb
language sql as $$
  select jsonb_build_object(
    'type', 'way', 'id', p_id,
    'nodes', (select jsonb_agg(pg_temp.nid((e ->> 0)::double precision, (e ->> 1)::double precision) order by i)
                from jsonb_array_elements(p_pts) with ordinality t(e, i)),
    'geometry', (select jsonb_agg(jsonb_build_object('lat', (e ->> 1)::double precision,
                                                     'lon', (e ->> 0)::double precision) order by i)
                   from jsonb_array_elements(p_pts) with ordinality t(e, i)),
    'tags', jsonb_build_object('highway', p_tipo)
            || case when p_nombre is null then '{}'::jsonb else jsonb_build_object('name', p_nombre) end);
$$;

-- La cuadrícula de c1: 4 calles de oeste a este (filas: Heredia, Garzón, Belvedere, Larrañaga) por 4 de norte
-- a sur (columnas: Pororó, Aparicio, Charrúa, Yaro). Las coordenadas se corren unos metros (sin empates).
create or replace function pg_temp.glon(c integer, r integer) returns double precision language sql immutable as
$$ select pg_temp.r7(-56.2000 + 0.0010 * c + 0.00003 * sin(r * 3.1 + c * 1.7)) $$;
create or replace function pg_temp.glat(c integer, r integer) returns double precision language sql immutable as
$$ select pg_temp.r7(-34.9000 - 0.0010 * r + 0.00003 * cos(r * 2.3 + c * 4.1)) $$;
create or replace function pg_temp.gpt(c integer, r integer) returns jsonb language sql immutable as
$$ select jsonb_build_array(pg_temp.glon(c, r), pg_temp.glat(c, r)) $$;

-- Un rectángulo de la cuadrícula (columnas c0..c1, filas r0..r1) como lista de esquinas [lon, lat].
create or replace function pg_temp.q(c0 integer, r0 integer, c1 integer, r1 integer) returns jsonb language sql immutable as
$$ select jsonb_build_array(pg_temp.gpt(c0, r0), pg_temp.gpt(c1, r0), pg_temp.gpt(c1, r1), pg_temp.gpt(c0, r1)) $$;

-- Un punto de una malla de 0,001° con origen (lon0, lat0): x hacia el este, y hacia el sur.
create or replace function pg_temp.pt(p_lon0 numeric, p_lat0 numeric, p_x numeric, p_y numeric) returns jsonb
language sql immutable as
$$ select jsonb_build_array(pg_temp.r7(p_lon0 + 0.001 * p_x), pg_temp.r7(p_lat0 - 0.001 * p_y)) $$;

create temp table osm_doc (k text primary key, doc jsonb) on commit drop;

insert into osm_doc
select 'grilla', jsonb_build_object('elements',
  (select jsonb_agg(w order by ord) from (
     select r as ord,
            pg_temp.via(1000 + r, (array['Heredia', 'Garzón', 'Belvedere', 'Larrañaga'])[r + 1], 'residential',
                        (select jsonb_agg(pg_temp.gpt(c, r) order by c) from generate_series(0, 3) c)) as w
       from generate_series(0, 3) r
     union all
     select 10 + c,
            pg_temp.via(2000 + c, (array['Pororó', 'Aparicio', 'Charrúa', 'Yaro'])[c + 1], 'residential',
                        (select jsonb_agg(pg_temp.gpt(c, r) order by r) from generate_series(0, 3) r))
       from generate_series(0, 3) c
  ) x));

-- La misma geometría que la cuadrícula con otros nombres: las calles de OTRA ciudad del catálogo cargadas en el mismo lugar
-- (dos municipios vecinos importados con el mismo recuadro). No tienen que contar para las zonas de c1.
insert into osm_doc
select 'grilla_falsa', jsonb_build_object('elements',
  (select jsonb_agg(jsonb_set(w, '{tags,name}', to_jsonb('Falsa ' || (w -> 'tags' ->> 'name'))) order by w ->> 'id')
     from jsonb_array_elements((select doc -> 'elements' from osm_doc where k = 'grilla')) w));

-- «Sin nombres»: una cuadrícula de 3 columnas por 2 filas cuyas calles OSM no tienen nombre (cada vía
-- sin nombre cuenta como su propia calle: las esquinas son cruces igual).
insert into osm_doc
select 'sin_nombres', jsonb_build_object('elements',
  (select jsonb_agg(pg_temp.via(5000 + n, null, 'residential', p) order by n) from (
     select r as n, (select jsonb_agg(pg_temp.pt(-56.3, -34.8, c, r) order by c) from generate_series(0, 2) c) as p
       from generate_series(0, 1) r
     union all
     select 10 + c, (select jsonb_agg(pg_temp.pt(-56.3, -34.8, c, r) order by r) from generate_series(0, 1) r)
       from generate_series(0, 2) c
  ) x));

-- --- fixtures del dominio -------------------------------------------------------------------------
-- Staff: a1 coordinador de e1; a2 coordinador de e2; ad admin; a0 colportor; a3 sin ningún rol.
-- Ciudades: c1 Cuadrícula (calles con nombre)  c2 Sin nombres (calles sin nombre)  c3 Sin calles cargadas
--           c4 Calles repetidas (las de c1 con otros nombres, sin campaña)
-- Campañas: e1 Verano (a1)  e2 Otra (a2)  e3 Tolerancia (a1)
-- campania_ciudad: 71 e1/c1  72 e1/c2  73 e1/c3  74 e2/c1  75 e3/c1
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000048' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'superpone-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0', 'a1', 'a2', 'a3', 'ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000048' || x.s)::uuid, r.id
  from (values ('a1', 'COORDINADOR'), ('a2', 'COORDINADOR'), ('ad', 'ADMIN'), ('a0', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000048c0', 'Pais superpone', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000048c1', 'Cuadrícula q87',   '01920000-0000-7000-8000-0000000048c0', -34.90, -56.20, 15),
  ('01920000-0000-7000-8000-0000000048c2', 'Sin nombres q87',  '01920000-0000-7000-8000-0000000048c0', -34.80, -56.30, 15),
  ('01920000-0000-7000-8000-0000000048c3', 'Sin calles q87',   '01920000-0000-7000-8000-0000000048c0', -33.00, -56.00, 15),
  ('01920000-0000-7000-8000-0000000048c4', 'Repetidas q87',    '01920000-0000-7000-8000-0000000048c0', -34.90, -56.20, 15);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000048e1', 'Verano', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000048a1'),
  ('01920000-0000-7000-8000-0000000048e2', 'Otra',   'VERANO', public.hoy_montevideo() - 10, null,                         '01920000-0000-7000-8000-0000000048a2'),
  ('01920000-0000-7000-8000-0000000048e3', 'Tolerancia', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000048a1');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-000000004871', '01920000-0000-7000-8000-0000000048e1', '01920000-0000-7000-8000-0000000048c1'),
  ('01920000-0000-7000-8000-000000004872', '01920000-0000-7000-8000-0000000048e1', '01920000-0000-7000-8000-0000000048c2'),
  ('01920000-0000-7000-8000-000000004873', '01920000-0000-7000-8000-0000000048e1', '01920000-0000-7000-8000-0000000048c3'),
  ('01920000-0000-7000-8000-000000004874', '01920000-0000-7000-8000-0000000048e2', '01920000-0000-7000-8000-0000000048c1'),
  ('01920000-0000-7000-8000-000000004875', '01920000-0000-7000-8000-0000000048e3', '01920000-0000-7000-8000-0000000048c1');

select ruteo.cargar_red('01920000-0000-7000-8000-0000000048c1', (select doc from osm_doc where k = 'grilla'), 'pgTAP grilla');
select ruteo.cargar_red('01920000-0000-7000-8000-0000000048c2', (select doc from osm_doc where k = 'sin_nombres'), 'pgTAP sin nombres');
select ruteo.cargar_red('01920000-0000-7000-8000-0000000048c4', (select doc from osm_doc where k = 'grilla_falsa'), 'pgTAP grilla falsa');

-- --- ayudas ----------------------------------------------------------------------------------------
-- Guarda (o, con p_previa, solo mira) una zona ESQUINAS con el borde que arma poligono_por_calles(), como
-- la vista 24: p_pts es la lista de esquinas [lon, lat].
create or replace function pg_temp.zona(p_cc uuid, p_nombre text, p_pts jsonb, p_previa boolean default false,
                                        p_zona uuid default null, p_cc_calles uuid default null) returns jsonb language plpgsql as $$
declare
  v record;
begin
  -- p_cc_calles: de qué campania_ciudad salen las calles del borde (por defecto, la misma donde se guarda).
  select * into v from public.poligono_por_calles(coalesce(p_cc_calles, p_cc),
    (select jsonb_agg(jsonb_build_object('lon', e -> 0, 'lat', e -> 1) order by i)
       from jsonb_array_elements(p_pts) with ordinality t(e, i)));
  return public.guardar_zona(p_campania_ciudad_id => p_cc, p_nombre => p_nombre, p_tipo_forma => 'ESQUINAS',
                             p_vertices => v.esquinas, p_poligono_geojson => v.poligono_geojson,
                             p_zona_id => p_zona, p_vista_previa => p_previa);
end $$;

create or replace function pg_temp.radial(p_cc uuid, p_nombre text, p_lat double precision, p_lon double precision,
                                          p_radio integer, p_previa boolean default false) returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => p_cc, p_nombre => p_nombre, p_tipo_forma => 'RADIAL',
                             p_centro_lat => p_lat, p_centro_lon => p_lon, p_radio_m => p_radio,
                             p_vista_previa => p_previa);
$$;

-- «Zona X; Zona Y» : los nombres de las zonas con las que se superpone, en el orden en que vienen.
create or replace function pg_temp.sup(p_r jsonb) returns text language sql as $$
  select coalesce(string_agg(e ->> 'nombre', '; ' order by i), '(ninguna)')
    from jsonb_array_elements(p_r -> 'superposiciones') with ordinality t(e, i)
$$;

-- «Zona X / Calle» : las calles compartidas, en el orden en que vienen (null → «(sin nombre)»).
create or replace function pg_temp.calles(p_r jsonb) returns text language sql as $$
  select coalesce(string_agg((e ->> 'nombre') || ' / ' || coalesce(e ->> 'calle', '(sin nombre)'), '; ' order by i), '(ninguna)')
    from jsonb_array_elements(p_r -> 'calles_compartidas') with ordinality t(e, i)
$$;

create or replace function pg_temp.area_m2(p_geojson jsonb) returns double precision language sql as $$
  select extensions.st_area(extensions.geography(public.zona_geometria(p_geojson)))
$$;

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select has_function('public', f, 'existe ' || f)
  from unnest(array['zonas_que_se_superponen', 'zonas_que_comparten_calle']) f;
select ok(not has_function_privilege(r, f, 'execute'), r || ' NO ejecuta ' || f)
  from unnest(array['anon', 'authenticated']) r,
       unnest(array['public.zonas_que_se_superponen(uuid,jsonb,uuid)', 'public.zonas_que_comparten_calle(uuid,jsonb,uuid)']) f;
select ok(has_function_privilege('service_role', f, 'execute'), 'service_role ejecuta ' || f)
  from unnest(array['public.zonas_que_se_superponen(uuid,jsonb,uuid)', 'public.zonas_que_comparten_calle(uuid,jsonb,uuid)']) f;
select is((select p.proconfig from pg_proc p where p.oid = f::regprocedure), array['search_path=""'],
          f || ' fija search_path vacío')
  from unnest(array['public.zonas_que_se_superponen(uuid,jsonb,uuid)', 'public.zonas_que_comparten_calle(uuid,jsonb,uuid)',
                    'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)']) f;
select is((select p.prosecdef from pg_proc p
            where p.oid = 'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)'::regprocedure),
          true, 'guardar_zona() sigue siendo SECURITY DEFINER');
select ok(has_function_privilege('authenticated',
            'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)', 'execute'),
          'authenticated ejecuta guardar_zona()');
select ok(not has_function_privilege('anon',
            'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)', 'execute'),
          'anon NO ejecuta guardar_zona()');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'guardar_zona'), 1, 'sigue habiendo una sola guardar_zona() (la firma no cambió)');

-- ---------------------------------------------------------------------------
-- 2. Sin solape
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');

create temp table previa_vacia on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona uno', pg_temp.q(0, 0, 1, 2), true) r;
select is((select r ->> 'guardada' from previa_vacia), 'false', 'ciudad sin zonas: la vista previa no guarda');
select is((select r -> 'superposiciones' from previa_vacia), '[]'::jsonb, 'ciudad sin zonas: superposiciones es una lista vacía');
select is((select r -> 'calles_compartidas' from previa_vacia), '[]'::jsonb, 'ciudad sin zonas: calles_compartidas es una lista vacía (hay calles, no hay con quién)');
select is((select array_agg(k order by k) from jsonb_object_keys((select r from previa_vacia)) k),
          array['calles_compartidas', 'guardada', 'poligono_geojson', 'superposiciones', 'ubicaciones_incluidas', 'vertices', 'zona'],
          'la respuesta de la vista previa: las claves de siempre más superposiciones y calles_compartidas');
select is((select r -> 'ubicaciones_incluidas' from previa_vacia), '0'::jsonb, 'y ubicaciones_incluidas sigue');

select is(pg_temp.radial('01920000-0000-7000-8000-000000004871', 'Radial', -34.90, -56.20, 300, true) -> 'superposiciones',
          '[]'::jsonb, 'una zona radial en una ciudad sin zonas: sin superposiciones');
select is(pg_temp.radial('01920000-0000-7000-8000-000000004871', 'Radial', -34.90, -56.20, 300, true) -> 'calles_compartidas',
          '[]'::jsonb, 'y sin calles compartidas (solo las zonas por esquinas las calculan)');

-- La vista previa no guarda nada.
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.zona where campania_ciudad_id in
            ('01920000-0000-7000-8000-000000004871', '01920000-0000-7000-8000-000000004872', '01920000-0000-7000-8000-000000004873')),
          0, 'las vistas previas no crearon ninguna zona');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');

-- ---------------------------------------------------------------------------
-- 3. Compartir la calle no es superponerse
-- ---------------------------------------------------------------------------
-- Otra ciudad de la campaña y otra campaña, con zonas que cubrirían a las de abajo: no cuentan.
create temp table radial_otra_ciudad on commit drop as
  select pg_temp.radial('01920000-0000-7000-8000-000000004872', 'Radial otra ciudad', -34.90, -56.1985, 600) r;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a2');
create temp table radial_otra_campania on commit drop as
  select pg_temp.radial('01920000-0000-7000-8000-000000004874', 'Radial otra campaña', -34.90, -56.1985, 600) r;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');
-- Y zonas por esquinas con el mismo borde exacto que la uno: en otra ciudad de la campaña (con el borde de las calles de c1) y
-- en otra campaña. Sus tramos coinciden con los de la uno, pero no son de esta ciudad de la campaña: no cuentan.
create temp table esq_otra_ciudad on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004872', 'Esquinas otra ciudad', pg_temp.q(0, 0, 1, 2), false, null,
                      '01920000-0000-7000-8000-000000004871') r;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a2');
create temp table esq_otra_campania on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004874', 'Esquinas otra campaña', pg_temp.q(0, 0, 1, 2)) r;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');
select is((select r ->> 'guardada' from esq_otra_ciudad), 'true', 'se guarda una zona por esquinas, con el borde de la uno, en otra ciudad de la campaña');
select is((select r ->> 'guardada' from esq_otra_campania), 'true', 'y otra, con el mismo borde, en otra campaña');
select is((select r ->> 'guardada' from radial_otra_ciudad), 'true', 'se guarda una zona radial en otra ciudad de la campaña');
select is((select r ->> 'guardada' from radial_otra_campania), 'true', 'y otra en la misma ciudad pero de otra campaña');

create temp table g1 on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona uno', pg_temp.q(0, 0, 1, 2)) r;
create temp table g2 on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona dos', pg_temp.q(1, 0, 2, 2)) r;
select is((select r ->> 'guardada' from g1), 'true', 'la zona uno se guarda');
select is((select r ->> 'superposiciones' from g1), '[]', 'la primera no se superpone con nadie (ni con las de otra ciudad ni otra campaña, aunque las cubran)');
select is((select r ->> 'calles_compartidas' from g1), '[]', 'ni comparte calles');
select is((select r ->> 'guardada' from g2), 'true', 'la zona vecina, que comparte el borde de Aparicio, se guarda');
select is((select r -> 'superposiciones' from g2), '[]'::jsonb,
          'dos zonas vecinas que comparten una calle NO se superponen: compartir el borde no es solapar');
select is(pg_temp.calles((select r from g2)), 'Zona uno / Aparicio',
          'pero sí comparten la calle: «Comparte la calle Aparicio con Zona uno»');
select is((select jsonb_array_length(r -> 'calles_compartidas') from g2), 1, 'una sola calle compartida (una fila por zona y por calle, aunque sean dos tramos)');
select is((select array_agg(k order by k) from jsonb_object_keys((select r -> 'calles_compartidas' -> 0 from g2)) k),
          array['calle', 'nombre', 'punto', 'zona_id'], 'cada calle compartida lleva solo la zona, el nombre de la calle y un punto');
select is((select r -> 'calles_compartidas' -> 0 ->> 'zona_id' from g2), (select r -> 'zona' ->> 'id' from g1),
          'con el id de la zona vecina');
select is((select r -> 'calles_compartidas' -> 0 -> 'punto' ->> 'type' from g2), 'Point', 'el punto del rótulo es un Point GeoJSON');
select ok((select extensions.st_distance(
             extensions.geography(extensions.st_setsrid(extensions.st_geomfromgeojson((r -> 'calles_compartidas' -> 0 -> 'punto')::text), 4326)),
             extensions.geography(extensions.st_exteriorring(public.zona_geometria(r -> 'poligono_geojson')))) < 0.5
             from g2),
          'el punto cae sobre el borde (sobre la calle compartida, a menos de 0,5 m)');

-- Un guardado tras otro: el lock del mapa ya los serializa, y la vista previa de la zona uno ahora ve a la dos.
create temp table previa_uno on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona uno', pg_temp.q(0, 0, 1, 2), true,
                      (select (r -> 'zona' ->> 'id')::uuid from g1)) r;
select is((select r -> 'superposiciones' from previa_uno), '[]'::jsonb, 'zona propia: editar la zona uno sin cambios no se superpone consigo misma');
select is(pg_temp.calles((select r from previa_uno)), 'Zona dos / Aparicio', 'y la calle compartida es con la dos, no con ella misma');
create temp table previa_dos on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona dos', pg_temp.q(1, 0, 2, 2), true,
                      (select (r -> 'zona' ->> 'id')::uuid from g2)) r;
select is(pg_temp.calles((select r from previa_dos)), 'Zona uno / Aparicio', 'la dos, editada sin cambios, comparte Aparicio con la uno');
select is((select r -> 'superposiciones' from previa_dos), '[]'::jsonb, 'y no se superpone con nadie');

-- ---------------------------------------------------------------------------
-- 4. Tocarse en una sola esquina no cuenta
-- ---------------------------------------------------------------------------
-- La tres (columnas 1-2, filas 2-3): su borde de arriba (Belvedere, de la esquina (1,2) a la (2,2)) es el de abajo
-- de la dos; con la uno solo se toca en la esquina (1,2): Aparicio y Belvedere están en las dos zonas, pero en
-- otros tramos.
create temp table previa_tres on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona tres', pg_temp.q(1, 2, 2, 3), true) r;
select is((select r -> 'superposiciones' from previa_tres), '[]'::jsonb, 'la tres solo comparte borde con la dos y se toca con la uno: sin superposiciones');
select is(pg_temp.calles((select r from previa_tres)), 'Zona dos / Belvedere',
          'comparte la calle con la dos; con la uno solo se toca en una esquina y no cuenta, aunque las dos usen calles con el mismo nombre');
-- La seis (columnas 2-3, filas 2-3) toca a la dos solo en la esquina (2,2).
create temp table previa_seis on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona seis', pg_temp.q(2, 2, 3, 3), true) r;
select is((select r -> 'superposiciones' from previa_seis), '[]'::jsonb, 'tocarse en un punto no es superponerse');
select is((select r -> 'calles_compartidas' from previa_seis), '[]'::jsonb, 'ni compartir una calle: un punto no es un tramo');

-- ---------------------------------------------------------------------------
-- 5. Con solape: la parte común, el orden, las calles, y el guardado nunca se rechaza
-- ---------------------------------------------------------------------------
-- La cuatro (columnas 0-2, filas 1-3) cubre la mitad de abajo de la uno y de la dos.
create temp table previa_cuatro on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona cuatro', pg_temp.q(0, 1, 2, 3), true) r;
select is((select r ->> 'guardada' from previa_cuatro), 'false', 'la vista previa de una zona que se superpone no guarda');
select is(pg_temp.sup((select r from previa_cuatro)), 'Zona dos; Zona uno', 'se superpone con la dos y con la uno, por nombre');
select is((select array_agg(k order by k) from jsonb_object_keys((select r -> 'superposiciones' -> 0 from previa_cuatro)) k),
          array['interseccion', 'nombre', 'zona_id'], 'cada superposición lleva el id, el nombre de la zona y la parte común');
select is((select r -> 'superposiciones' -> 1 ->> 'zona_id' from previa_cuatro), (select r -> 'zona' ->> 'id' from g1), 'con el id de la zona');
select ok((select (r -> 'superposiciones' -> 1 -> 'interseccion' ->> 'type') in ('Polygon', 'MultiPolygon') from previa_cuatro),
          'la parte común es un polígono GeoJSON (el tramo que el panel pinta en rojo)');
select ok((select pg_temp.area_m2(r -> 'superposiciones' -> 1 -> 'interseccion') between 8000 and 12000 from previa_cuatro),
          'y mide una manzana (la cuadra de la uno, entre las filas 1 y 2 y las columnas 0 y 1)');
select ok((select extensions.st_covers(public.zona_geometria(r -> 'poligono_geojson'),
                                       public.zona_geometria(r -> 'superposiciones' -> 1 -> 'interseccion')) from previa_cuatro),
          'y queda adentro de la zona que se dibuja');
select is(pg_temp.calles((select r from previa_cuatro)), 'Zona dos / Charrúa; Zona uno / Pororó',
          'además comparte calles: Charrúa con la dos (entre las filas 1 y 2) y Pororó con la uno');

-- Una copia exacta de la uno: se superpone entera y comparte las cuatro calles de su borde.
create temp table previa_copia on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona copia', pg_temp.q(0, 0, 1, 2), true) r;
select is(pg_temp.sup((select r from previa_copia)), 'Zona uno', 'la copia exacta de la uno se superpone con la uno');
select ok((select abs(pg_temp.area_m2(r -> 'superposiciones' -> 0 -> 'interseccion') - pg_temp.area_m2(r -> 'poligono_geojson')) < 1 from previa_copia),
          'en toda su área');
select is(pg_temp.calles((select r from previa_copia)),
          'Zona dos / Aparicio; Zona uno / Aparicio; Zona uno / Belvedere; Zona uno / Heredia; Zona uno / Pororó',
          'y comparte las cuatro calles de su borde con la uno (una fila por calle, aunque Aparicio y Pororó sean dos tramos) y Aparicio con la dos');
-- Zona propia: la uno redibujada como la cuatro se superpone con la dos, no consigo misma.
create temp table uno_como_cuatro on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona uno', pg_temp.q(0, 1, 2, 3), true,
                      (select (r -> 'zona' ->> 'id')::uuid from g1)) r;
select is(pg_temp.sup((select r from uno_como_cuatro)), 'Zona dos', 'zona propia: editar la uno no la superpone con la uno, solo con la dos');
select is(pg_temp.calles((select r from uno_como_cuatro)), 'Zona dos / Charrúa', 'y comparte con la dos solo la calle Charrúa');

-- Guardar con solape: se guarda, y la respuesta trae los avisos.
create temp table g4 on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona cuatro', pg_temp.q(0, 1, 2, 3)) r;
select is((select r ->> 'guardada' from g4), 'true', 'una zona superpuesta se guarda, sin rechazo');
select is(pg_temp.sup((select r from g4)), 'Zona dos; Zona uno', 'y la respuesta del guardado avisa con quiénes se superpone');
select is(pg_temp.calles((select r from g4)), 'Zona dos / Charrúa; Zona uno / Pororó', 'y qué calles comparte');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.zona where campania_ciudad_id = '01920000-0000-7000-8000-000000004871' and deleted_at is null),
          3, 'quedan tres zonas vivas en la ciudad de la campaña: la superpuesta existe');
select is((select deleted_at is null from public.zona where id = (select (r -> 'zona' ->> 'id')::uuid from g4)), true, 'la cuatro está viva');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');

-- Editar la cuatro (misma forma): no se superpone consigo misma, sí con las otras dos.
create temp table cuatro_editada on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona cuatro', pg_temp.q(0, 1, 2, 3), false,
                      (select (r -> 'zona' ->> 'id')::uuid from g4)) r;
select is(pg_temp.sup((select r from cuatro_editada)), 'Zona dos; Zona uno', 'zona propia: editar la cuatro la superpone con las otras dos y no con ella');

-- ---------------------------------------------------------------------------
-- 6. Zonas dadas de baja
-- ---------------------------------------------------------------------------
select public.baja_zona((select (r -> 'zona' ->> 'id')::uuid from g2));
create temp table sin_dos on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona siete', pg_temp.q(0, 1, 2, 3), true) r;
select is(pg_temp.sup((select r from sin_dos)), 'Zona cuatro; Zona uno', 'una zona dada de baja ya no se superpone con nadie (la dos no sale)');
select is(pg_temp.calles((select r from sin_dos)), 'Zona cuatro / Charrúa; Zona cuatro / Garzón; Zona cuatro / Larrañaga; Zona cuatro / Pororó; Zona uno / Pororó',
          'ni comparte calles: la dos no sale y el borde igual a la cuatro comparte sus calles');
select public.baja_zona((select (r -> 'zona' ->> 'id')::uuid from g1));
create temp table sin_uno on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona ocho', pg_temp.q(0, 0, 1, 2), true) r;
select is(pg_temp.sup((select r from sin_uno)), 'Zona cuatro', 'dadas de baja la uno y la dos, solo queda la cuatro');
select is(pg_temp.calles((select r from sin_uno)), 'Zona cuatro / Pororó', 'y la calle compartida es la de la cuatro');
select public.baja_zona((select (r -> 'zona' ->> 'id')::uuid from g4));
create temp table sin_nadie on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona nueve', pg_temp.q(0, 1, 2, 3), true) r;
select is(pg_temp.sup((select r from sin_nadie)), '(ninguna)', 'sin zonas vivas en la ciudad: ninguna superposición');
select is((select r -> 'calles_compartidas' from sin_nadie), '[]'::jsonb, 'ni calles compartidas');

-- ---------------------------------------------------------------------------
-- 7. Ciudad sin calles cargadas y calle sin nombre
-- ---------------------------------------------------------------------------
-- Sin calles: el borde ya viene calculado (no se puede pedir a poligono_por_calles()) y el guardado no se frena.
create or replace function pg_temp.rect_a_mano(p_nombre text, x0 numeric, y0 numeric, x1 numeric, y1 numeric, p_previa boolean)
returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000004873', p_nombre => p_nombre,
    p_tipo_forma => 'ESQUINAS',
    p_vertices => jsonb_build_array(
      jsonb_build_object('orden', 1, 'lon', x0, 'lat', y0, 'calle_a', 'Oeste', 'calle_b', 'Sur'),
      jsonb_build_object('orden', 2, 'lon', x1, 'lat', y0, 'calle_a', 'Este',  'calle_b', 'Sur'),
      jsonb_build_object('orden', 3, 'lon', x1, 'lat', y1, 'calle_a', 'Este',  'calle_b', 'Norte'),
      jsonb_build_object('orden', 4, 'lon', x0, 'lat', y1, 'calle_a', 'Oeste', 'calle_b', 'Norte')),
    p_poligono_geojson => jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
      jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
      jsonb_build_array(x0, y1), jsonb_build_array(x0, y0)))),
    p_vista_previa => p_previa);
$$;
create temp table sc1 on commit drop as select pg_temp.rect_a_mano('Sin calles uno', -56.002, -33.002, -56.000, -33.000, false) r;
create temp table sc2 on commit drop as select pg_temp.rect_a_mano('Sin calles dos', -56.0015, -33.0015, -55.9995, -32.9995, true) r;
select is((select r ->> 'guardada' from sc1), 'true', 'ciudad sin calles cargadas: el guardado de una zona por esquinas no se frena');
select is((select r -> 'calles_compartidas' from sc2), 'null'::jsonb,
          'ciudad sin calles cargadas: calles_compartidas es null (no se pudo calcular), distinto de [] (se calculó y no hay)');
select is(pg_temp.sup((select r from sc2)), 'Sin calles uno', 'pero las superposiciones se calculan igual, sin calles');
select is((select r ->> 'guardada' from sc2), 'false', 'y la vista previa no guarda');
select is(pg_temp.radial('01920000-0000-7000-8000-000000004873', 'Radial sin calles', -33.001, -56.001, 100, true) -> 'calles_compartidas',
          '[]'::jsonb, 'una zona radial en esa ciudad: [] (no calcula calles, no hay nada que no se pudo calcular)');

-- Calle sin nombre: calle null, el punto igual.
create temp table sn_a on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004872', 'Sin nombre A',
                      jsonb_build_array(pg_temp.pt(-56.3, -34.8, 0, 0), pg_temp.pt(-56.3, -34.8, 1, 0),
                                        pg_temp.pt(-56.3, -34.8, 1, 1), pg_temp.pt(-56.3, -34.8, 0, 1))) r;
create temp table sn_b on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004872', 'Sin nombre B',
                      jsonb_build_array(pg_temp.pt(-56.3, -34.8, 1, 0), pg_temp.pt(-56.3, -34.8, 2, 0),
                                        pg_temp.pt(-56.3, -34.8, 2, 1), pg_temp.pt(-56.3, -34.8, 1, 1)), true) r;
select is((select r ->> 'guardada' from sn_a), 'true', 'calles sin nombre: la zona A se guarda');
select is(pg_temp.calles((select r from sn_b)), 'Sin nombre A / (sin nombre)', 'la B comparte con la A un tramo sin nombre: se avisa sin inventar la calle');
select is((select r -> 'calles_compartidas' -> 0 -> 'calle' from sn_b), 'null'::jsonb, 'calle es null');
select is((select r -> 'calles_compartidas' -> 0 -> 'punto' ->> 'type' from sn_b), 'Point', 'pero lleva su punto para el rótulo');
select is((select r -> 'superposiciones' from sn_b), '[]'::jsonb, 'y no se superpone');
-- Lo que se guardó en otra ciudad de la campaña no cuenta: la radial de c2 está a un lado.
select is(pg_temp.sup((select r from sn_b)), '(ninguna)', 'la radial de esa ciudad (lejos) tampoco se superpone');

-- ---------------------------------------------------------------------------
-- 8. Permiso: el de guardar_zona()
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a0');
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000004871'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.9, p_centro_lon => -56.2, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'un colportor no ve las zonas de la ciudad: 42501');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a3');
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000004871'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.9, p_centro_lon => -56.2, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'un usuario sin rol: 42501');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a2');
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000004871'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.9, p_centro_lon => -56.2, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'el coordinador de otra campaña: 42501, y no averigua qué zonas hay');
select pg_temp.actuar_sin_jwt();
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000004871'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.9, p_centro_lon => -56.2, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'sin sesión: 42501');
select pg_temp.actuar_como_anon();
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000004871'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.9, p_centro_lon => -56.2, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'anon: 42501');
select is(pg_temp.codigo('select public.zonas_que_se_superponen(''01920000-0000-7000-8000-000000004871'', ''{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}'', null)'),
          '42501', 'anon no ejecuta la interna de superposiciones');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');
select is(pg_temp.codigo('select public.zonas_que_comparten_calle(''01920000-0000-7000-8000-000000004871'', ''{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}'', null)'),
          '42501', 'el coordinador tampoco ejecuta las internas directo: solo por guardar_zona()');

-- El ADMIN y el coordinador de la campaña sí; lo que ven es lo mismo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048ad');
create temp table adm_zona on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona admin', pg_temp.q(0, 0, 1, 2)) r;
select is((select r ->> 'guardada' from adm_zona), 'true', 'el ADMIN guarda una zona en la campaña de otro coordinador');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');
create temp table coord_ve on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004871', 'Zona copia admin', pg_temp.q(0, 0, 1, 2), true) r;
select is(pg_temp.sup((select r from coord_ve)), 'Zona admin', 'y el coordinador de la campaña ve esa zona en las superposiciones');
select is((select jsonb_array_length(r -> 'superposiciones') from coord_ve), 1, 'una sola');

-- Ni importes ni personas: las únicas claves de la respuesta y de cada aviso.
select is((select array_agg(k order by k) from jsonb_object_keys((select r -> 'calles_compartidas' -> 0 from coord_ve)) k),
          array['calle', 'nombre', 'punto', 'zona_id'], 'calles_compartidas: zona, calle y punto, nada más');
select is((select array_agg(k order by k) from jsonb_object_keys((select r -> 'superposiciones' -> 0 from coord_ve)) k),
          array['interseccion', 'nombre', 'zona_id'], 'superposiciones: zona, nombre y parte común, nada más');

-- ---------------------------------------------------------------------------
-- 9. El metro de tolerancia, y las calles de otra ciudad del catálogo
-- ---------------------------------------------------------------------------
-- «Recorre» un tramo = el tramo entero a 1 m o menos del borde. La ciudad c1 está también cargada como c4 «Repetidas»
-- (mismas calles, otros nombres): las calles de c4 no entran en los avisos de las zonas de c1.
create temp table base_q on commit drop as
  select * from public.poligono_por_calles('01920000-0000-7000-8000-000000004871', (
    select jsonb_agg(jsonb_build_object('lon', e -> 0, 'lat', e -> 1) order by i)
      from jsonb_array_elements(pg_temp.q(0, 0, 1, 2)) with ordinality t(e, i)));
select pg_temp.actuar_como_servidor();
-- Zonas de la campaña «Tolerancia» corridas hacia el este 0,37 m (cuenta) y 3 m (no cuenta). Por INSERT directo: el borde
-- de la segunda no pasa a 1 m de sus esquinas, y guardar_zona() la rechazaría (CZ008).
insert into public.zona (nombre, campania_ciudad_id, tipo_forma, poligono_geojson)
select x.nombre, '01920000-0000-7000-8000-000000004875', 'ESQUINAS',
       extensions.st_asgeojson(extensions.st_translate(public.zona_geometria(b.poligono_geojson), x.dx, 0), 7)::jsonb
  from base_q b, (values ('Corrida 0,4 m', 0.000004), ('Corrida 3 m', 0.000033)) x(nombre, dx);
select is((select round(extensions.st_distance(extensions.geography(extensions.st_point(-56.2, -34.9)),
                                               extensions.geography(extensions.st_point(-56.2 + 0.000004, -34.9)))::numeric, 2)), 0.37,
          'la corrida chica mide 0,37 m');
select is((select round(extensions.st_distance(extensions.geography(extensions.st_point(-56.2, -34.9)),
                                               extensions.geography(extensions.st_point(-56.2 + 0.000033, -34.9)))::numeric, 1)), 3.0,
          'y la grande, 3 m');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000048a1');
create temp table tolerancia on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000004875', 'Prueba', pg_temp.q(0, 0, 1, 2), true, null,
                      '01920000-0000-7000-8000-000000004871') r;
select is(pg_temp.calles((select r from tolerancia)),
          'Corrida 0,4 m / Aparicio; Corrida 0,4 m / Belvedere; Corrida 0,4 m / Heredia; Corrida 0,4 m / Pororó',
          'una zona cuyo borde pasa a 0,37 m de las mismas calles las comparte (el metro de tolerancia); a 3 m, no');
select is(pg_temp.sup((select r from tolerancia)), 'Corrida 0,4 m; Corrida 3 m',
          'y las dos se superponen en área, con o sin la calle compartida: son avisos distintos');

select * from finish();
rollback;
