-- pgTAP · el aviso «Comparte la calle X con Y» cuenta solo los tramos del camino entre las esquinas
-- (migración 0059, backend-supabase#91, seguimiento de #87 / PR #90, HU-CAM-006, ADR-018, vista 24)
--   1. Forma y privilegios: la interna ahora recibe las esquinas; la de tres parámetros ya no existe.
--   2. El tramo que sale a mitad de un borde en común no cuenta (Fila 1, Pasaje E), el corto que es parte del camino sí.
--   3. La T donde termina un borde en común: el tramo que sigue de largo no cuenta.
--   4. Las esquinas desordenadas, repetidas o con la vuelta a la primera dan lo mismo.
--   5. Si el camino no se puede armar, calles_compartidas es null y el guardado sigue.
--   6. Otros null: esquinas que no sirven, ciudad inexistente. Una radial no calcula.
--   7. El lock compartido de la carga de las calles, y la vista previa y el guardado dicen lo mismo.
--   8. Permiso: el de guardar_zona().
-- (Las esquinas desordenadas se prueban en un circuito de lados desiguales, donde el orden cambia qué tramos recorre el camino.)
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

create or replace function pg_temp.actuar_como_servicio() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('role', 'service_role', true);
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

-- --- OSM de mentira (el formato de Overpass), como en los tests 0045 y 0048 ------------------------
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

-- Un punto de una malla de 0,001° con origen (lon0, lat0): x hacia el este, y hacia el sur.
create or replace function pg_temp.pt(p_lon0 numeric, p_lat0 numeric, p_x numeric, p_y numeric) returns jsonb
language sql immutable as
$$ select jsonb_build_array(pg_temp.r7(p_lon0 + 0.001 * p_x), pg_temp.r7(p_lat0 - 0.001 * p_y)) $$;

-- --- fixtures del dominio -------------------------------------------------------------------------
-- Staff: a1 coordinador de e1 y e2; a2 coordinador de e3; ad admin; a0 colportor.
-- Ciudades: c6 «Esquina corta» (cuadrícula de 3×3 cruces con dos tramos de menos de 1 m en el cruce (1,1))
--           c7 «Dos islas» (dos cuadrículas de 2×2 cruces sin ninguna calle que las una)
--           c8 «Circuito» (un anillo de cuatro calles de largos distintos: 3, 1, 3,2 y 2 cuadras)
-- Campañas: e1 Verano (a1), e2 Otra (a1), e3 Ajena (a2)
-- campania_ciudad: 71 e1/c6 (control a mitad del borde)  72 e2/c6 (la T)  73 e1/c7 (sin camino)  74 e3/c6  75 e1/c8
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000050' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'camino-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0', 'a1', 'a2', 'ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000050' || x.s)::uuid, r.id
  from (values ('a1', 'COORDINADOR'), ('a2', 'COORDINADOR'), ('ad', 'ADMIN'), ('a0', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000050c0', 'Pais camino', 'ZR');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000050c6', 'Esquina corta q91', '01920000-0000-7000-8000-0000000050c0', -34.8, -56.6, 15),
  ('01920000-0000-7000-8000-0000000050c7', 'Dos islas q91',     '01920000-0000-7000-8000-0000000050c0', -34.8, -56.7, 15),
  ('01920000-0000-7000-8000-0000000050c8', 'Circuito q91',      '01920000-0000-7000-8000-0000000050c0', -34.8, -56.8, 15);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000050e1', 'Verano', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000050a1'),
  ('01920000-0000-7000-8000-0000000050e2', 'Otra',   'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000050a1'),
  ('01920000-0000-7000-8000-0000000050e3', 'Ajena',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, '01920000-0000-7000-8000-0000000050a2');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-000000005071', '01920000-0000-7000-8000-0000000050e1', '01920000-0000-7000-8000-0000000050c6'),
  ('01920000-0000-7000-8000-000000005072', '01920000-0000-7000-8000-0000000050e2', '01920000-0000-7000-8000-0000000050c6'),
  ('01920000-0000-7000-8000-000000005073', '01920000-0000-7000-8000-0000000050e1', '01920000-0000-7000-8000-0000000050c7'),
  ('01920000-0000-7000-8000-000000005074', '01920000-0000-7000-8000-0000000050e3', '01920000-0000-7000-8000-0000000050c6'),
  ('01920000-0000-7000-8000-000000005075', '01920000-0000-7000-8000-0000000050e1', '01920000-0000-7000-8000-0000000050c8');

-- c6: una cuadrícula de 3×3 cruces (0,001°) con dos nodos a ~0,45 m del cruce (1,1), como en el §11 del 0048:
--   · al este, sobre «Fila 1», donde se junta «Pasaje E» (que corre 11 m al norte, paralelo a la columna 1 a 0,46 m de ella):
--     parte la calle y deja un tramo de «Fila 1» de 0,46 m que sale de la columna;
--   · al norte, sobre la columna 1, donde se junta «Pasaje N»: la columna 1 son tres vías («Col 1 N», «Corta» y
--     «Col 1 S»), y «Corta» es un tramo de 0,44 m que SÍ es parte de la columna.
select ruteo.cargar_red('01920000-0000-7000-8000-0000000050c6', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(70000, 'Fila 0', 'residential', jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 0), pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0))),
  pg_temp.via(70001, 'Fila 1', 'residential', jsonb_build_array(
    pg_temp.pt(-56.6, -34.8, 0, 1), pg_temp.pt(-56.6, -34.8, 1, 1),
    jsonb_build_array(pg_temp.r7(-56.6 + 0.001 + 0.000005), pg_temp.r7(-34.8 - 0.001)), pg_temp.pt(-56.6, -34.8, 2, 1))),
  pg_temp.via(70002, 'Fila 2', 'residential', jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 2), pg_temp.pt(-56.6, -34.8, 1, 2), pg_temp.pt(-56.6, -34.8, 2, 2))),
  pg_temp.via(70010, 'Col 0', 'residential', jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 0), pg_temp.pt(-56.6, -34.8, 0, 1), pg_temp.pt(-56.6, -34.8, 0, 2))),
  pg_temp.via(70011, 'Col 1 N', 'residential', jsonb_build_array(
    pg_temp.pt(-56.6, -34.8, 1, 0), jsonb_build_array(pg_temp.r7(-56.6 + 0.001), pg_temp.r7(-34.8 - 0.001 + 0.000004)))),
  pg_temp.via(70012, 'Corta', 'residential', jsonb_build_array(
    jsonb_build_array(pg_temp.r7(-56.6 + 0.001), pg_temp.r7(-34.8 - 0.001 + 0.000004)), pg_temp.pt(-56.6, -34.8, 1, 1))),
  pg_temp.via(70013, 'Col 1 S', 'residential', jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 1), pg_temp.pt(-56.6, -34.8, 1, 2))),
  pg_temp.via(70112, 'Col 2', 'residential', jsonb_build_array(pg_temp.pt(-56.6, -34.8, 2, 0), pg_temp.pt(-56.6, -34.8, 2, 1), pg_temp.pt(-56.6, -34.8, 2, 2))),
  pg_temp.via(70020, 'Pasaje E', 'residential', jsonb_build_array(
    jsonb_build_array(pg_temp.r7(-56.6 + 0.001 + 0.000005), pg_temp.r7(-34.8 - 0.001)),
    jsonb_build_array(pg_temp.r7(-56.6 + 0.001 + 0.000005), pg_temp.r7(-34.8 - 0.001 + 0.0001)))),
  pg_temp.via(70021, 'Pasaje N', 'residential', jsonb_build_array(
    jsonb_build_array(pg_temp.r7(-56.6 + 0.001), pg_temp.r7(-34.8 - 0.001 + 0.000004)),
    jsonb_build_array(pg_temp.r7(-56.6 + 0.001 + 0.0001), pg_temp.r7(-34.8 - 0.001 + 0.000004)))))),
  'pgTAP esquina corta');

-- c7: dos cuadrículas de 2×2 cruces (la de x = 0..1 y la de x = 5..6), sin ninguna calle entre las dos.
select ruteo.cargar_red('01920000-0000-7000-8000-0000000050c7', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(80000, 'Isla uno H0', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 0, 0), pg_temp.pt(-56.7, -34.8, 1, 0))),
  pg_temp.via(80001, 'Isla uno H1', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 0, 1), pg_temp.pt(-56.7, -34.8, 1, 1))),
  pg_temp.via(80010, 'Isla uno V0', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 0, 0), pg_temp.pt(-56.7, -34.8, 0, 1))),
  pg_temp.via(80011, 'Isla uno V1', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 1, 0), pg_temp.pt(-56.7, -34.8, 1, 1))),
  pg_temp.via(80100, 'Isla dos H0', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 5, 0), pg_temp.pt(-56.7, -34.8, 6, 0))),
  pg_temp.via(80101, 'Isla dos H1', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 5, 1), pg_temp.pt(-56.7, -34.8, 6, 1))),
  pg_temp.via(80110, 'Isla dos V0', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 5, 0), pg_temp.pt(-56.7, -34.8, 5, 1))),
  pg_temp.via(80111, 'Isla dos V1', 'residential', jsonb_build_array(pg_temp.pt(-56.7, -34.8, 6, 0), pg_temp.pt(-56.7, -34.8, 6, 1))))),
  'pgTAP dos islas');

-- c8: un anillo de cuatro calles entre las esquinas Q1 (0,0), Q2 (3,0), Q3 (3,1) y Q4 (0,2): sin diagonales, y de largos
-- distintos (3, 1, 3,16 y 2 cuadras), así que el camino más corto entre dos esquinas no vecinas es único.
select ruteo.cargar_red('01920000-0000-7000-8000-0000000050c8', jsonb_build_object('elements', jsonb_build_array(
  pg_temp.via(90000, 'Lado S', 'residential', jsonb_build_array(pg_temp.pt(-56.8, -34.8, 0, 0), pg_temp.pt(-56.8, -34.8, 3, 0))),
  pg_temp.via(90001, 'Lado E', 'residential', jsonb_build_array(pg_temp.pt(-56.8, -34.8, 3, 0), pg_temp.pt(-56.8, -34.8, 3, 1))),
  pg_temp.via(90002, 'Lado N', 'residential', jsonb_build_array(pg_temp.pt(-56.8, -34.8, 3, 1), pg_temp.pt(-56.8, -34.8, 0, 2))),
  pg_temp.via(90003, 'Lado W', 'residential', jsonb_build_array(pg_temp.pt(-56.8, -34.8, 0, 2), pg_temp.pt(-56.8, -34.8, 0, 0))))),
  'pgTAP circuito');

-- --- ayudas ----------------------------------------------------------------------------------------
-- Guarda (o, con p_previa, solo mira) una zona ESQUINAS con el borde que arma poligono_por_calles(), como la vista 24:
-- p_pts es la lista de esquinas [lon, lat].
create or replace function pg_temp.zona(p_cc uuid, p_nombre text, p_pts jsonb, p_previa boolean default false,
                                        p_zona uuid default null) returns jsonb language plpgsql as $$
declare
  v record;
begin
  select * into v from public.poligono_por_calles(p_cc,
    (select jsonb_agg(jsonb_build_object('lon', e -> 0, 'lat', e -> 1) order by i)
       from jsonb_array_elements(p_pts) with ordinality t(e, i)));
  return public.guardar_zona(p_campania_ciudad_id => p_cc, p_nombre => p_nombre, p_tipo_forma => 'ESQUINAS',
                             p_vertices => v.esquinas, p_poligono_geojson => v.poligono_geojson,
                             p_zona_id => p_zona, p_vista_previa => p_previa);
end $$;

-- «Zona X / Calle» : las calles compartidas, en el orden en que vienen (null → «(sin nombre)»).
create or replace function pg_temp.calles(p_r jsonb) returns text language sql as $$
  select coalesce(string_agg((e ->> 'nombre') || ' / ' || coalesce(e ->> 'calle', '(sin nombre)'), '; ' order by i), '(ninguna)')
    from jsonb_array_elements(p_r -> 'calles_compartidas') with ordinality t(e, i)
$$;

-- Las esquinas de guardar_zona() ([{orden, lon, lat}]) de una lista de puntos [lon, lat] en el orden dado.
create or replace function pg_temp.esquinas(p_pts jsonb) returns jsonb language sql immutable as $$
  select jsonb_agg(jsonb_build_object('orden', i, 'lon', e -> 0, 'lat', e -> 1) order by i)
    from jsonb_array_elements(p_pts) with ordinality t(e, i)
$$;

-- Los tramos de menos de 1 m de la ciudad c6 que quedan enteros a 1 m o menos del borde del polígono p_geojson.
create or replace function pg_temp.cortos_en_la_franja(p_geojson jsonb) returns text language sql security definer as $$
  select coalesce(string_agg(t.nombre, '; ' order by t.nombre), '(ninguno)')
    from ruteo.tramo t
   where t.ciudad_id = '01920000-0000-7000-8000-0000000050c6' and t.largo_m < 1
     and extensions.st_covers(
           extensions.geometry(extensions.st_buffer(extensions.geography(
             extensions.st_exteriorring(public.zona_geometria(p_geojson))), 1.0)), t.geom)
$$;

-- Si hay un tramo de ese nombre de c6 que queda entero a 1 m o menos del borde de los dos polígonos.
create or replace function pg_temp.tramo_en_las_franjas(p_nombre text, p_a jsonb, p_b jsonb) returns boolean language sql security definer as $$
  select exists (select 1 from ruteo.tramo t
                  where t.ciudad_id = '01920000-0000-7000-8000-0000000050c6' and t.nombre = p_nombre
                    and extensions.st_covers(extensions.geometry(extensions.st_buffer(extensions.geography(
                          extensions.st_exteriorring(public.zona_geometria(p_a))), 1.0)), t.geom)
                    and extensions.st_covers(extensions.geometry(extensions.st_buffer(extensions.geography(
                          extensions.st_exteriorring(public.zona_geometria(p_b))), 1.0)), t.geom))
$$;

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'zonas_que_comparten_calle', array['uuid', 'jsonb', 'uuid', 'jsonb'],
                    'zonas_que_comparten_calle() recibe las esquinas (cuarto parámetro)');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'zonas_que_comparten_calle'), 1,
          'y la de tres parámetros (0038) ya no existe: una sola');
select is((select p.provolatile::text from pg_proc p
            where p.oid = 'public.zonas_que_comparten_calle(uuid,jsonb,uuid,jsonb)'::regprocedure), 'v',
          'es volátil (llama a ruteo.camino() y toma el lock de la carga de las calles)');
select is((select p.proconfig from pg_proc p where p.oid = 'public.zonas_que_comparten_calle(uuid,jsonb,uuid,jsonb)'::regprocedure),
          array['search_path=""'], 'fija search_path vacío');
select ok(not has_function_privilege(r, 'public.zonas_que_comparten_calle(uuid,jsonb,uuid,jsonb)', 'execute'), r || ' NO la ejecuta')
  from unnest(array['anon', 'authenticated']) r;
select ok(has_function_privilege('service_role', 'public.zonas_que_comparten_calle(uuid,jsonb,uuid,jsonb)', 'execute'),
          'service_role la ejecuta');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'guardar_zona'), 1, 'sigue habiendo una sola guardar_zona() (la firma no cambió)');
select ok(has_function_privilege('authenticated',
            'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)', 'execute'),
          'authenticated ejecuta guardar_zona()');

-- La red tiene los dos tramos de menos de 1 m del cruce (1,1).
select is((select string_agg(t.nombre, '; ' order by t.nombre) from ruteo.tramo t
            where t.ciudad_id = '01920000-0000-7000-8000-0000000050c6' and t.largo_m < 1),
          'Corta; Fila 1', 'la red de c6 tiene dos tramos de menos de 1 m: «Corta» (0,44 m) y el de «Fila 1» (0,46 m)');

-- ---------------------------------------------------------------------------
-- 2. El tramo que sale a mitad de un borde en común no cuenta
-- ---------------------------------------------------------------------------
-- A y B comparten la columna 1 entera (Col 1 N, Corta, Col 1 S). En el cruce (1,1), a mitad de ese borde, sale el tramo
-- de «Fila 1» (0,46 m) y corre al lado «Pasaje E» (a 0,46 m de la columna): los dos quedan a 1 m o menos de los dos
-- bordes, pero ninguno es parte del camino entre las esquinas de B.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
create temp table za on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005071', 'A',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 0), pg_temp.pt(-56.6, -34.8, 1, 0),
                                       pg_temp.pt(-56.6, -34.8, 1, 2), pg_temp.pt(-56.6, -34.8, 0, 2))) r;
create temp table zb on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005071', 'B',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 2), pg_temp.pt(-56.6, -34.8, 1, 2)), true) r;
select is((select r ->> 'guardada' from za), 'true', 'la zona A se guarda');
select is((select r ->> 'guardada' from zb), 'false', 'la vista previa de B no guarda');
select is(pg_temp.cortos_en_la_franja((select r -> 'poligono_geojson' from zb)), 'Corta; Fila 1',
          'el tramo de Fila 1 (0,46 m) queda dentro del metro del borde de B: sin la regla del camino, entraba');
select ok(pg_temp.tramo_en_las_franjas('Pasaje E', (select r -> 'poligono_geojson' from zb), (select r -> 'poligono_geojson' from za)),
          'y el Pasaje E (a 0,46 m de la columna) queda dentro del metro de los dos bordes: tampoco sería parte del camino');
select is(pg_temp.calles((select r from zb)), 'A / Col 1 N; A / Col 1 S; A / Corta',
          'B comparte con A solo las tres vías de la columna 1: Corta (0,44 m, parte del camino) sigue contando; ni Fila 1 ni Pasaje E');
select is((select jsonb_array_length(r -> 'calles_compartidas') from zb), 3, 'tres filas, la lista entera');
select is((select array_agg(k order by k) from jsonb_object_keys((select r -> 'calles_compartidas' -> 0 from zb)) k),
          array['calle', 'nombre', 'punto', 'zona_id'], 'cada una con la zona, el nombre de la calle y el punto, como antes');
select is((select r -> 'calles_compartidas' -> 0 -> 'punto' ->> 'type' from zb), 'Point', 'el punto es un Point GeoJSON');
select ok((select extensions.st_distance(
             extensions.geography(extensions.st_setsrid(extensions.st_geomfromgeojson((e -> 'punto')::text), 4326)),
             extensions.geography(extensions.st_exteriorring(public.zona_geometria(r -> 'poligono_geojson')))) < 0.5
             from zb, jsonb_array_elements(r -> 'calles_compartidas') e where e ->> 'calle' = 'Corta'),
          'el punto de Corta cae sobre el borde');
select is((select r -> 'superposiciones' from zb), '[]'::jsonb, 'y compartir la columna no es superponerse');

-- Al revés: la vista previa de A (con B ya guardada) comparte lo mismo con B.
create temp table zb_guardada on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005071', 'B',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 2), pg_temp.pt(-56.6, -34.8, 1, 2))) r;
create temp table za_previa on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005071', 'A',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 0), pg_temp.pt(-56.6, -34.8, 1, 0),
                                       pg_temp.pt(-56.6, -34.8, 1, 2), pg_temp.pt(-56.6, -34.8, 0, 2)), true,
                      (select (r -> 'zona' ->> 'id')::uuid from za)) r;
select is(pg_temp.calles((select r from zb_guardada)), 'A / Col 1 N; A / Col 1 S; A / Corta',
          'al guardar B, la respuesta dice lo mismo que la vista previa');
select is(pg_temp.calles((select r from za_previa)), 'B / Col 1 N; B / Col 1 S; B / Corta',
          'y A, editada sin cambios, comparte con B las mismas tres vías (el camino de A también es la columna 1)');

-- ---------------------------------------------------------------------------
-- 3. La T donde termina un borde en común
-- ---------------------------------------------------------------------------
-- A2 (columnas 0-1, filas 0-1) y B2 (columna 1-2, filas 0-2) comparten solo la columna 1 entre las filas 0 y 1 (Col 1 N y
-- Corta): el borde en común termina en el cruce (1,1), en una T. El tramo de «Fila 1» de 0,46 m que sigue hacia el este
-- queda a 1 m o menos de los dos bordes, pero B2 sigue de largo por Col 1 S y A2 dobla al oeste: no lo recorre ninguna.
create temp table za2 on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005072', 'A2',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 0), pg_temp.pt(-56.6, -34.8, 1, 0),
                                       pg_temp.pt(-56.6, -34.8, 1, 1), pg_temp.pt(-56.6, -34.8, 0, 1))) r;
create temp table zb2 on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005072', 'B2',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 2), pg_temp.pt(-56.6, -34.8, 1, 2)), true) r;
select is((select r ->> 'guardada' from za2), 'true', 'la zona A2 se guarda');
select is(pg_temp.cortos_en_la_franja((select r -> 'poligono_geojson' from zb2)), 'Corta; Fila 1',
          'el tramo de Fila 1 queda dentro del metro del borde de B2 (y del de A2, que dobla justo ahí)');
select is(pg_temp.cortos_en_la_franja((select r -> 'poligono_geojson' from za2)), 'Corta; Fila 1',
          'sanidad: también del de A2');
select is(pg_temp.calles((select r from zb2)), 'A2 / Col 1 N; A2 / Corta',
          'la T al final del borde en común: solo Col 1 N y Corta; ni el tramo de Fila 1 ni Pasaje E');
select is((select r -> 'superposiciones' from zb2), '[]'::jsonb, 'y no se superponen');
-- Al revés: A2 mira a B2 guardada. El camino de A2 incluye Fila 1 (de (1,1) a (0,1)), pero no su tramo hacia el este.
create temp table zb2_guardada on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005072', 'B2',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 2), pg_temp.pt(-56.6, -34.8, 1, 2))) r;
create temp table za2_previa on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005072', 'A2',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 0), pg_temp.pt(-56.6, -34.8, 1, 0),
                                       pg_temp.pt(-56.6, -34.8, 1, 1), pg_temp.pt(-56.6, -34.8, 0, 1)), true,
                      (select (r -> 'zona' ->> 'id')::uuid from za2)) r;
select is(pg_temp.calles((select r from za2_previa)), 'B2 / Col 1 N; B2 / Corta',
          'visto desde A2, el mismo borde en común: Col 1 N y Corta; la Fila 1 que A2 sí recorre no llega a B2');

-- Esquinas que se tocan en diagonal (la regla del 19/10 sigue como estaba): NE guardada, SO en vista previa (campaña de a2).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a2');
create temp table ne on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005074', 'NE',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 1), pg_temp.pt(-56.6, -34.8, 1, 1))) r;
create temp table ne_a2 on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005074', 'NE otro',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 1), pg_temp.pt(-56.6, -34.8, 1, 1)), true) r;
select is(pg_temp.calles((select r from ne_a2)), 'NE / Col 1 N; NE / Col 2; NE / Corta; NE / Fila 0; NE / Fila 1',
          'una copia exacta de NE comparte sus cinco vías (Corta incluida) y ninguna de más');
select ok((select extensions.st_distance(
             extensions.geography(extensions.st_setsrid(extensions.st_geomfromgeojson((e -> 'punto')::text), 4326)),
             extensions.geography(extensions.st_setsrid(extensions.st_makepoint(-56.599, -34.801), 4326))) > 40
             from ne_a2, jsonb_array_elements(r -> 'calles_compartidas') e where e ->> 'calle' = 'Fila 1'),
          'el punto de «Fila 1» (un tramo de 0,46 m y otro de 110 m) cae en el más largo, no en el chiquito pegado al cruce (1,1)');
create temp table so on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005074', 'SO',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 1), pg_temp.pt(-56.6, -34.8, 1, 1),
                                       pg_temp.pt(-56.6, -34.8, 1, 2), pg_temp.pt(-56.6, -34.8, 0, 2)), true) r;
select is((select r -> 'calles_compartidas' from so), '[]'::jsonb,
          'SO y NE en diagonal, con tramos de 0,46 m y 0,44 m pegados a la esquina: no comparten calle');
-- Al revés: con SO guardada, NE editada. El camino de NE sí incluye Corta y el tramo de Fila 1 que salen del cruce (1,1), y los dos
-- quedan a menos de 1 m del borde de SO, que pasa por ese cruce: son los tramos pegados a la esquina donde las dos solo se tocan.
create temp table so_g on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005074', 'SO',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 0, 1), pg_temp.pt(-56.6, -34.8, 1, 1),
                                       pg_temp.pt(-56.6, -34.8, 1, 2), pg_temp.pt(-56.6, -34.8, 0, 2))) r;
create temp table ne_editada on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005074', 'NE',
                      jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 1), pg_temp.pt(-56.6, -34.8, 1, 1)), true,
                      (select (r -> 'zona' ->> 'id')::uuid from ne)) r;
select is((select r ->> 'guardada' from so_g), 'true', 'la SO se guarda');
select is((select r -> 'calles_compartidas' from ne_editada), '[]'::jsonb,
          'NE contra SO, que solo se tocan en el cruce (1,1): ni Corta (0,44 m) ni el tramo de Fila 1 (0,46 m) pegados a esa esquina');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');

-- ---------------------------------------------------------------------------
-- 4. Las mismas esquinas, escritas de otra manera, dan lo mismo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table vert_b on commit drop as
  select pg_temp.esquinas(jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                            pg_temp.pt(-56.6, -34.8, 2, 2), pg_temp.pt(-56.6, -34.8, 1, 2))) v;
create or replace function pg_temp.calles_de(p_cc uuid, p_poligono jsonb, p_zona uuid, p_vertices jsonb) returns text
language plpgsql as $$
declare
  v jsonb;
begin
  v := public.zonas_que_comparten_calle(p_cc, p_poligono, p_zona, p_vertices);
  if v is null then return 'null'; end if;
  return pg_temp.calles(jsonb_build_object('calles_compartidas', v));
end $$;
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005071', (select r -> 'poligono_geojson' from zb), null, (select v from vert_b)),
          'A / Col 1 N; A / Col 1 S; A / Corta; B / Col 1 N; B / Col 1 S; B / Col 2; B / Corta; B / Fila 0; B / Fila 2'::text,
          'directo, sin excluir a ninguna zona: A comparte la columna 1 y la B guardada, que es el mismo borde, sus seis vías (nunca Fila 1)');
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005071', (select r -> 'poligono_geojson' from zb),
                            (select (r -> 'zona' ->> 'id')::uuid from zb_guardada), (select v from vert_b)),
          'A / Col 1 N; A / Col 1 S; A / Corta', 'directo, sin B (p_zona_id): el resultado de la vista previa');
-- El borde que llega también manda: con las esquinas de B pero el borde de A2 (columnas 0-1, filas 0-1), solo cuentan los
-- tramos del camino de B que además quedan sobre ese borde: de la columna 1, Col 1 N y Corta (no Col 1 S, que A2 no recorre).
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005072', (select r -> 'poligono_geojson' from za2),
                            (select (r -> 'zona' ->> 'id')::uuid from za2), (select v from vert_b)),
          'B2 / Col 1 N; B2 / Corta', 'cuentan los tramos del camino de las esquinas que además están en el borde que se dibuja');
-- Las esquinas desordenadas en la lista (el `orden` manda), con la primera repetida al final y una esquina repetida seguida.
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005071', (select r -> 'poligono_geojson' from zb),
                            (select (r -> 'zona' ->> 'id')::uuid from zb_guardada),
                            (select jsonb_build_array(v -> 2, v -> 0, v -> 3, v -> 1) from vert_b)),
          'A / Col 1 N; A / Col 1 S; A / Corta', 'las esquinas desordenadas en la lista dan lo mismo: manda `orden`');
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005071', (select r -> 'poligono_geojson' from zb),
                            (select (r -> 'zona' ->> 'id')::uuid from zb_guardada),
                            (select v || jsonb_build_array(jsonb_set(v -> 0, '{orden}', '5')) from vert_b)),
          'A / Col 1 N; A / Col 1 S; A / Corta', 'con la vuelta a la primera esquina al final: lo mismo');
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005071', (select r -> 'poligono_geojson' from zb),
                            (select (r -> 'zona' ->> 'id')::uuid from zb_guardada),
                            (select jsonb_build_array(v -> 0, jsonb_set(v -> 0, '{orden}', '1.5'), v -> 1, v -> 2, v -> 3) from vert_b)),
          'A / Col 1 N; A / Col 1 S; A / Corta', 'y con una esquina repetida seguida: lo mismo');
-- Un circuito de lados desiguales: la zona Q1-Q2-Q3-Q4 recorre sus cuatro lados. Con las esquinas fuera de orden en la lista
-- (Q1, Q3, Q4, Q2), el camino seguiría el `orden` o la lista: por la lista, Q4 → Q2 pasaría por Q3 y Q2 → Q1 por el lado S, y el
-- lado W (Q4 → Q1) quedaría sin recorrer.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
create temp table circuito_g on commit drop as
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000005075', p_nombre => 'Circuito uno',
    p_tipo_forma => 'ESQUINAS',
    p_vertices => pg_temp.esquinas(jsonb_build_array(pg_temp.pt(-56.8, -34.8, 0, 0), pg_temp.pt(-56.8, -34.8, 3, 0),
                                                    pg_temp.pt(-56.8, -34.8, 3, 1), pg_temp.pt(-56.8, -34.8, 0, 2))),
    p_poligono_geojson => jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
      pg_temp.pt(-56.8, -34.8, 0, 0), pg_temp.pt(-56.8, -34.8, 3, 0), pg_temp.pt(-56.8, -34.8, 3, 1),
      pg_temp.pt(-56.8, -34.8, 0, 2), pg_temp.pt(-56.8, -34.8, 0, 0))))) r;
select is((select r ->> 'guardada' from circuito_g), 'true', 'se guarda la zona del circuito');
select pg_temp.actuar_como_servidor();
create temp table circuito_v on commit drop as
  select pg_temp.esquinas(jsonb_build_array(pg_temp.pt(-56.8, -34.8, 0, 0), pg_temp.pt(-56.8, -34.8, 3, 0),
                                            pg_temp.pt(-56.8, -34.8, 3, 1), pg_temp.pt(-56.8, -34.8, 0, 2))) v,
         jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
           pg_temp.pt(-56.8, -34.8, 0, 0), pg_temp.pt(-56.8, -34.8, 3, 0), pg_temp.pt(-56.8, -34.8, 3, 1),
           pg_temp.pt(-56.8, -34.8, 0, 2), pg_temp.pt(-56.8, -34.8, 0, 0)))) p;
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005075', (select p from circuito_v), null, (select v from circuito_v)),
          'Circuito uno / Lado E; Circuito uno / Lado N; Circuito uno / Lado S; Circuito uno / Lado W',
          'el circuito en orden: los cuatro lados');
select is(pg_temp.calles_de('01920000-0000-7000-8000-000000005075', (select p from circuito_v), null,
                            (select jsonb_build_array(v -> 0, v -> 2, v -> 3, v -> 1) from circuito_v)),
          'Circuito uno / Lado E; Circuito uno / Lado N; Circuito uno / Lado S; Circuito uno / Lado W',
          'y con las esquinas desordenadas en la lista (Q1, Q3, Q4, Q2): lo mismo, manda `orden`');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');

-- ---------------------------------------------------------------------------
-- 5. Si el camino no se puede armar: null, y el guardado sigue
-- ---------------------------------------------------------------------------
-- c7: dos islas sin ninguna calle entre las dos. El rectángulo (0,0)-(6,0)-(6,1)-(0,1) tiene dos esquinas en cada isla.
create or replace function pg_temp.rect_islas(p_nombre text, p_previa boolean, p_zona uuid default null) returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000005073', p_nombre => p_nombre,
    p_tipo_forma => 'ESQUINAS', p_zona_id => p_zona,
    p_vertices => jsonb_build_array(
      jsonb_build_object('orden', 1, 'lon', pg_temp.pt(-56.7, -34.8, 0, 0) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 0, 0) -> 1),
      jsonb_build_object('orden', 2, 'lon', pg_temp.pt(-56.7, -34.8, 6, 0) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 6, 0) -> 1),
      jsonb_build_object('orden', 3, 'lon', pg_temp.pt(-56.7, -34.8, 6, 1) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 6, 1) -> 1),
      jsonb_build_object('orden', 4, 'lon', pg_temp.pt(-56.7, -34.8, 0, 1) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 0, 1) -> 1)),
    p_poligono_geojson => jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
      pg_temp.pt(-56.7, -34.8, 0, 0), pg_temp.pt(-56.7, -34.8, 6, 0), pg_temp.pt(-56.7, -34.8, 6, 1),
      pg_temp.pt(-56.7, -34.8, 0, 1), pg_temp.pt(-56.7, -34.8, 0, 0)))),
    p_vista_previa => p_previa);
$$;
-- Una zona vecina en la misma ciudad de la campaña, que comparte las calles de la isla uno (el rectángulo de la isla uno).
create temp table isla_uno on commit drop as
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000005073', p_nombre => 'Isla uno',
    p_tipo_forma => 'ESQUINAS',
    p_vertices => jsonb_build_array(
      jsonb_build_object('orden', 1, 'lon', pg_temp.pt(-56.7, -34.8, 0, 0) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 0, 0) -> 1),
      jsonb_build_object('orden', 2, 'lon', pg_temp.pt(-56.7, -34.8, 1, 0) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 1, 0) -> 1),
      jsonb_build_object('orden', 3, 'lon', pg_temp.pt(-56.7, -34.8, 1, 1) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 1, 1) -> 1),
      jsonb_build_object('orden', 4, 'lon', pg_temp.pt(-56.7, -34.8, 0, 1) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 0, 1) -> 1)),
    p_poligono_geojson => jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
      pg_temp.pt(-56.7, -34.8, 0, 0), pg_temp.pt(-56.7, -34.8, 1, 0), pg_temp.pt(-56.7, -34.8, 1, 1),
      pg_temp.pt(-56.7, -34.8, 0, 1), pg_temp.pt(-56.7, -34.8, 0, 0)))), p_vista_previa => false) r;
select is((select r ->> 'guardada' from isla_uno), 'true', 'se guarda una zona que cubre la isla uno entera');
-- Con camino, esa misma zona sí comparte calles con una copia suya.
create temp table isla_copia on commit drop as
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000005073', p_nombre => 'Isla copia',
    p_tipo_forma => 'ESQUINAS',
    p_vertices => jsonb_build_array(
      jsonb_build_object('orden', 1, 'lon', pg_temp.pt(-56.7, -34.8, 0, 0) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 0, 0) -> 1),
      jsonb_build_object('orden', 2, 'lon', pg_temp.pt(-56.7, -34.8, 1, 0) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 1, 0) -> 1),
      jsonb_build_object('orden', 3, 'lon', pg_temp.pt(-56.7, -34.8, 1, 1) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 1, 1) -> 1),
      jsonb_build_object('orden', 4, 'lon', pg_temp.pt(-56.7, -34.8, 0, 1) -> 0, 'lat', pg_temp.pt(-56.7, -34.8, 0, 1) -> 1)),
    p_poligono_geojson => jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
      pg_temp.pt(-56.7, -34.8, 0, 0), pg_temp.pt(-56.7, -34.8, 1, 0), pg_temp.pt(-56.7, -34.8, 1, 1),
      pg_temp.pt(-56.7, -34.8, 0, 1), pg_temp.pt(-56.7, -34.8, 0, 0)))), p_vista_previa => true) r;
select is(pg_temp.calles((select r from isla_copia)), 'Isla uno / Isla uno H0; Isla uno / Isla uno H1; Isla uno / Isla uno V0; Isla uno / Isla uno V1',
          'una copia de la isla uno comparte sus cuatro calles (hay camino entre sus esquinas)');
create temp table sin_camino on commit drop as select pg_temp.rect_islas('Entre islas', true) r;
select is((select r -> 'calles_compartidas' from sin_camino), 'null'::jsonb,
          'sin camino por las calles entre dos esquinas seguidas: calles_compartidas es null (no se pudo calcular), no []');
select is((select r ->> 'guardada' from sin_camino), 'false', 'la vista previa no guarda');
select ok((select jsonb_typeof(r -> 'poligono_geojson') = 'object' and r -> 'ubicaciones_incluidas' is not null from sin_camino),
          'y el resto de la respuesta sigue igual: el polígono y las ubicaciones');
create temp table sin_camino_g on commit drop as select pg_temp.rect_islas('Entre islas', false) r;
select is((select r ->> 'guardada' from sin_camino_g), 'true', 'el guardado no se frena aunque no haya camino');
select is((select r -> 'calles_compartidas' from sin_camino_g), 'null'::jsonb, 'y la respuesta del guardado también dice null');
select is((select count(*)::int from public.zona where campania_ciudad_id = '01920000-0000-7000-8000-000000005073' and deleted_at is null and nombre = 'Entre islas'),
          1, 'la zona de las dos islas quedó guardada');
select is((select r -> 'superposiciones' -> 0 ->> 'nombre' from sin_camino_g), 'Isla uno',
          'y las superposiciones se calculan igual: cubre a la isla uno');

-- ---------------------------------------------------------------------------
-- 6. Otros null, y una radial no calcula
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table poli_b on commit drop as select r -> 'poligono_geojson' p from zb;
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null, null), null::jsonb,
          'sin esquinas (null): null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null, '{}'::jsonb), null::jsonb,
          'esquinas que no son una lista: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null, '[]'::jsonb), null::jsonb,
          'una lista vacía: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null,
            (select jsonb_build_array(v -> 0, v -> 1) from vert_b)), null::jsonb,
          'con dos esquinas: no hay 3 cruces distintos, null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null,
            (select jsonb_build_array(v -> 0, v -> 0, v -> 0, v -> 1) from vert_b)), null::jsonb,
          'con tres esquinas en dos lugares distintos: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null,
            (select jsonb_build_array(v -> 0, v -> 1, '{"orden":3,"lon":"x","lat":1}'::jsonb, v -> 3) from vert_b)), null::jsonb,
          'una esquina con la longitud en texto: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null,
            (select jsonb_build_array(v -> 0, v -> 1, '{"orden":3,"lon":500,"lat":1}'::jsonb, v -> 3) from vert_b)), null::jsonb,
          'una esquina fuera del mapa: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null,
            (select jsonb_build_array(v -> 0, v -> 1, '{"orden":3,"lon":1,"lat":95}'::jsonb, v -> 3) from vert_b)), null::jsonb,
          'una esquina con la latitud fuera del mapa: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null,
            (select jsonb_build_array(v -> 0, v -> 1, '7'::jsonb, v -> 3) from vert_b)), null::jsonb,
          'una esquina que no es un objeto: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-00000000ffff', (select p from poli_b), null, (select v from vert_b)),
          null::jsonb, 'una ciudad de la campaña que no existe: null');
select is(public.zonas_que_comparten_calle('01920000-0000-7000-8000-000000005071', (select p from poli_b), null, (select v from vert_b)) is null,
          false, 'sanidad: con las esquinas buenas no es null');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is(public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-000000005071', p_nombre => 'Radial', p_tipo_forma => 'RADIAL',
            p_centro_lat => -34.8, p_centro_lon => -56.6, p_radio_m => 300, p_vista_previa => true) -> 'calles_compartidas',
          '[]'::jsonb, 'una zona radial: [] (no calcula el camino)');

-- ---------------------------------------------------------------------------
-- 7. El lock compartido de la carga de las calles
-- ---------------------------------------------------------------------------
-- La vista previa toma el mismo lock advisory compartido que ciudad_para_dibujar(): una recarga de las calles
-- (cargar_red(), lock exclusivo) no cambia los ids de nodo mientras se arma el camino. Con una recarga en curso
-- (otra sesión), el aviso es null y no se espera (la prueba con dos sesiones está en el PR).
create or replace function pg_temp.tiene_el_lock(p_ciudad uuid) returns boolean language sql as $$
  select exists (select 1 from pg_locks l
                  where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.granted and l.mode = 'ShareLock'
                    and ((l.classid::bigint << 32) | l.objid::bigint) = hashtextextended('ruteo_red:' || p_ciudad::text, 0))
$$;
select pg_temp.actuar_como_servidor();
select is(pg_temp.tiene_el_lock('01920000-0000-7000-8000-0000000050c7'), true,
          'sanidad: la sesión ya tiene el lock de c7 (solo pudo tomarlo zonas_que_comparten_calle(): la sección 5 guarda con guardar_zona() sin pasar por poligono_por_calles())');
select ok(not pg_temp.tiene_el_lock('01920000-0000-7000-8000-00000000ffff'), 'pero no el de una ciudad que no tocó');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');

-- ---------------------------------------------------------------------------
-- 8. Permiso: el de guardar_zona()
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a0');
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000005071'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.8, p_centro_lon => -56.6, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'un colportor no ve las zonas de la ciudad: 42501');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a2');
select is(pg_temp.codigo('select public.guardar_zona(p_campania_ciudad_id => ''01920000-0000-7000-8000-000000005071'', p_nombre => ''x'', p_tipo_forma => ''RADIAL'', p_centro_lat => -34.8, p_centro_lon => -56.6, p_radio_m => 100, p_vista_previa => true)'),
          '42501', 'el coordinador de otra campaña: 42501');
select pg_temp.actuar_como_anon();
select is(pg_temp.codigo('select public.zonas_que_comparten_calle(''01920000-0000-7000-8000-000000005071'', ''{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}'', null, ''[]'')'),
          '42501', 'anon no ejecuta la interna');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is(pg_temp.codigo('select public.zonas_que_comparten_calle(''01920000-0000-7000-8000-000000005071'', ''{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}'', null, ''[]'')'),
          '42501', 'el coordinador tampoco la ejecuta directo: solo por guardar_zona()');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050ad');
create temp table adm on commit drop as
  select pg_temp.zona('01920000-0000-7000-8000-000000005071', 'B', jsonb_build_array(pg_temp.pt(-56.6, -34.8, 1, 0), pg_temp.pt(-56.6, -34.8, 2, 0),
                                       pg_temp.pt(-56.6, -34.8, 2, 2), pg_temp.pt(-56.6, -34.8, 1, 2)), true,
                      (select (r -> 'zona' ->> 'id')::uuid from zb_guardada)) r;
select is(pg_temp.calles((select r from adm)), 'A / Col 1 N; A / Col 1 S; A / Corta', 'el ADMIN ve lo mismo');
select pg_temp.actuar_como_servicio();
select ok(pg_temp.codigo('select public.zonas_que_comparten_calle(''01920000-0000-7000-8000-000000005071'', ''{"type":"Polygon","coordinates":[[[0,0],[1,0],[1,1],[0,0]]]}'', null, ''[]'')') = 'OK',
          'service_role sí ejecuta la interna');

select * from finish();
rollback;
