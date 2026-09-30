-- pgTAP · zonas dentro del mapa de la campaña (migración 0008, backend-supabase#22)
-- Forma (RADIAL y ESQUINAS), no superposición con su tolerancia, el círculo, los RPC del
-- mapa (guardar, vista previa, baja, agregar ciudad), permisos, y la RLS de lectura y
-- escritura de campania_ciudad, zona y zona_vertice. El delta del sync está en
-- 0011_zonas_mapa_sync_test (necesita filas commiteadas) y la migración con datos en
-- scripts/db-test-migracion.sh.
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
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

create or replace function pg_temp.detalle_error(p_sql text) returns text language plpgsql as $$
declare
  v_detalle text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detalle = pg_exception_detail;
  return v_detalle;
end $$;

-- Rectángulo (lon/lat) como Polygon GeoJSON, en el orden SO → SE → NE → NO → SO.
create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;

-- Las cuatro esquinas del mismo rectángulo, en el mismo orden.
create or replace function pg_temp.esquinas(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('orden', 1, 'lon', x0, 'lat', y0, 'calle_a', 'Oeste', 'calle_b', 'Sur'),
    jsonb_build_object('orden', 2, 'lon', x1, 'lat', y0, 'calle_a', 'Este',  'calle_b', 'Sur'),
    jsonb_build_object('orden', 3, 'lon', x1, 'lat', y1, 'calle_a', 'Este',  'calle_b', 'Norte'),
    jsonb_build_object('orden', 4, 'lon', x0, 'lat', y1, 'calle_a', 'Oeste', 'calle_b', 'Norte'));
$$;

-- Guardar una zona ESQUINAS rectangular (lo más usado abajo).
create or replace function pg_temp.guardar_rect(p_cc uuid, p_nombre text,
                                                x0 numeric, y0 numeric, x1 numeric, y1 numeric,
                                                p_zona uuid default null, p_previa boolean default false)
returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => p_cc, p_nombre => p_nombre,
                             p_tipo_forma => 'ESQUINAS',
                             p_vertices => pg_temp.esquinas(x0, y0, x1, y1),
                             p_poligono_geojson => pg_temp.rect(x0, y0, x1, y1),
                             p_zona_id => p_zona, p_vista_previa => p_previa);
$$;

-- ¿El polígono de la zona cubre el punto a p_dist metros del centro con rumbo p_grados?
create or replace function pg_temp.cubre(p_zona uuid, p_lat float8, p_lon float8, p_dist float8, p_grados float8)
returns boolean language sql as $$
  select extensions.st_covers(
           public.zona_geometria(z.poligono_geojson),
           extensions.geometry(extensions.st_project(
             extensions.geography(extensions.st_setsrid(extensions.st_makepoint(p_lon, p_lat), 4326)),
             p_dist, radians(p_grados))))
    from public.zona z where z.id = p_zona;
$$;

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
-- Staff: a1 coordinador de Verano (Montevideo + Las Piedras) y de Vieja (terminada),
--        a2 coordinador de Otra (Montevideo), ad admin.
-- Colportores: b1 inscripto en Verano, b2 inscripto en Otra, b3 sin inscripción.
-- Ciudades de campaña: f1 Verano/Montevideo, f2 Verano/Las Piedras, f3 Otra/Montevideo,
--        f4 Vieja/Montevideo. c3 Canelones está en el catálogo y en ninguna campaña.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000010' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mapa-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3']) s;

update public.usuario set nombre = 'Uno', apellido = 'Zeta'
 where id = '01920000-0000-7000-8000-0000000010b1';

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000010' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000010c0', 'Pais mapa', 'ZM');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000010c1', 'Montevideo mapa',  '01920000-0000-7000-8000-0000000010c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-0000000010c2', 'Las Piedras mapa', '01920000-0000-7000-8000-0000000010c0', -34.73, -56.22),
  ('01920000-0000-7000-8000-0000000010c3', 'Canelones mapa',   '01920000-0000-7000-8000-0000000010c0', -34.52, -56.28);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000010e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000010a1'),
  ('01920000-0000-7000-8000-0000000010e2', 'Otra',   'PERMANENTE', current_date - 10, null,              '01920000-0000-7000-8000-0000000010a2'),
  ('01920000-0000-7000-8000-0000000010e3', 'Vieja',  'VERANO',     current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000010a1');

insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000010f1', '01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c1'),
  ('01920000-0000-7000-8000-0000000010f2', '01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c2'),
  ('01920000-0000-7000-8000-0000000010f3', '01920000-0000-7000-8000-0000000010e2', '01920000-0000-7000-8000-0000000010c1'),
  ('01920000-0000-7000-8000-0000000010f4', '01920000-0000-7000-8000-0000000010e3', '01920000-0000-7000-8000-0000000010c1');

insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010b1'),
  ('01920000-0000-7000-8000-0000000010e2', '01920000-0000-7000-8000-0000000010b2');

-- ---------------------------------------------------------------------------
-- 1. Forma del esquema y privilegios
-- ---------------------------------------------------------------------------
select has_extension('extensions', 'postgis', 'PostGIS habilitado en el schema extensions');
select hasnt_column('public', 'campania', 'ciudad_id', 'campania.ciudad_id ya no existe (pasa a campania_ciudad)');
select hasnt_column('public', 'zona', 'ciudad_id', 'zona.ciudad_id ya no existe');
select hasnt_column('public', 'zona', 'campania_id', 'zona.campania_id ya no existe');
select col_not_null('public', 'zona', 'campania_ciudad_id', 'zona.campania_ciudad_id es not null');
select col_not_null('public', 'zona', 'tipo_forma', 'zona.tipo_forma es not null');
select col_not_null('public', 'zona', 'poligono_geojson', 'zona.poligono_geojson es not null');
select has_index('public', 'zona', 'zona_geometria_idx', 'índice GiST sobre la geometría de la zona');

select ok(has_function_privilege('authenticated', f, 'execute'), 'authenticated ejecuta ' || f)
  from unnest(array[
    'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)',
    'public.baja_zona(uuid,boolean)',
    'public.agregar_ciudad_a_campania(uuid,uuid)']) f;
select ok(not has_function_privilege('authenticated', f, 'execute'), 'authenticated NO ejecuta la interna ' || f)
  from unnest(array[
    'public.zona_superposiciones(uuid,jsonb,uuid)', 'public.motivo_mapa_de_campania(uuid)',
    'public.lanzar_motivo_mapa(text)', 'public.bloquear_mapa(uuid)',
    'public.zona_ubicaciones_incluidas(uuid,jsonb)']) f;
select is((select array_agg(p.proname::text order by p.proname) from pg_proc p
            where p.pronamespace = 'public'::regnamespace
              and p.proname in ('guardar_zona', 'baja_zona', 'agregar_ciudad_a_campania')
              and p.prosecdef and p.proconfig = array['search_path=""']),
          array['agregar_ciudad_a_campania', 'baja_zona', 'guardar_zona'],
          'los RPC del mapa son SECURITY DEFINER con search_path vacío');

-- ---------------------------------------------------------------------------
-- 2. Permisos de los RPC (el permiso antes que cualquier dato)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010b1');
select throws_ok($$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'X', -56.17, -34.91, -56.16, -34.90) $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede cambiar su mapa.',
  'un colportor no guarda zonas (42501)');
select throws_ok($$ select public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c3') $$,
  '42501', null, 'un colportor no agrega ciudades a la campaña');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a2');
select throws_ok($$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'X', -56.17, -34.91, -56.16, -34.90) $$,
  '42501', null, 'el coordinador de otra campaña no guarda zonas en esta (42501)');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok($$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f4', 'X', -56.17, -34.91, -56.16, -34.90) $$,
  'CZ011', null, 'campaña terminada: su mapa no se cambia (CZ011)');
select throws_ok($$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010ff', 'X', -56.17, -34.91, -56.16, -34.90) $$,
  'CZ012', 'La ciudad no está en esta campaña. Agregala con «+ Agregar ciudad» y volvé a intentar.',
  'ciudad de campaña inexistente → CZ012');

select set_config('role', 'anon', true);
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'X', 'RADIAL') $$,
  '42501', null, 'anon no ejecuta guardar_zona()');
select set_config('role', 'postgres', true);

-- ---------------------------------------------------------------------------
-- 3. RADIAL
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lon => -56.22, p_radio_m => 400) $$,
  'CZ008', null, 'RADIAL sin latitud del centro → CZ008');
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lat => -34.73, p_radio_m => 400) $$,
  'CZ008', null, 'RADIAL sin longitud del centro → CZ008');
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lat => -34.73, p_centro_lon => -56.22) $$,
  'CZ008', 'Una zona radial necesita centro y un radio mayor a 0. Marcá el centro en el mapa y elegí el radio.',
  'RADIAL sin radio → CZ008');
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lat => -34.73, p_centro_lon => -56.22, p_radio_m => 0) $$,
  'CZ008', null, 'RADIAL con radio 0 → CZ008');
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lat => -34.73, p_centro_lon => -56.22, p_radio_m => -5) $$,
  'CZ008', null, 'RADIAL con radio negativo → CZ008');
-- Tope de 3000 m: hasta ahí vale la cota de ±1 m del círculo de 128 lados.
select throws_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lat => -34.73, p_centro_lon => -56.22, p_radio_m => 3001) $$,
  'CZ008', 'El radio de la zona es de 3001 m y el máximo es 3000 m. Achicalo, o dividí el área en varias zonas.',
  'RADIAL con radio de más de 3000 m → CZ008');
select lives_ok($$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'R', 'RADIAL', p_centro_lat => -34.73, p_centro_lon => -56.22, p_radio_m => 3000, p_vista_previa => true) $$,
  'RADIAL con radio de 3000 m: se acepta');

-- Sin pasar por el RPC la regla vale igual (trigger + CHECK).
select pg_temp.actuar_como_servidor();
select throws_ok($$ insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon)
                    values ('R directa', '01920000-0000-7000-8000-0000000010f2', 'RADIAL', -34.73, -56.22) $$,
  'CZ008', null, 'RADIAL sin radio por INSERT directo → CZ008');
select throws_ok($$ insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
                    values ('R directa', '01920000-0000-7000-8000-0000000010f2', 'RADIAL', -34.73, -56.22, 0) $$,
  'CZ008', null, 'RADIAL con radio 0 por INSERT directo → CZ008');
select throws_ok($$ insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
                    values ('R directa', '01920000-0000-7000-8000-0000000010f2', 'RADIAL', -34.73, -56.22, 3001) $$,
  'CZ008', 'El radio de la zona «R directa» es de 3001 m y el máximo es 3000 m. Achicalo, o dividí el área en varias zonas.',
  'RADIAL con radio de más de 3000 m por INSERT directo → CZ008');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
create temp table radial on commit drop as
select public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'Radial LP', 'RADIAL', '#3A7BD5',
                           p_centro_lat => -34.73, p_centro_lon => -56.22, p_radio_m => 400) as r;
select is((select r ->> 'guardada' from radial), 'true', 'RADIAL completa: se guarda');
select is((select jsonb_array_length(r -> 'poligono_geojson' -> 'coordinates' -> 0) from radial), 129,
          'el círculo es un polígono de 128 lados (129 posiciones con el cierre)');
select is((select jsonb_array_length(r -> 'vertices') from radial), 0, 'una zona RADIAL no tiene vértices');

-- El círculo: contiene el centro y todo punto a r − 1 m; no contiene uno a r + 1 m. Se mide
-- en un vértice (0°) y en el peor rumbo, el medio de un lado (180°/128 = 1,40625°).
select ok(pg_temp.cubre((select (r -> 'zona' ->> 'id')::uuid from radial), -34.73, -56.22, 0, 0),
          'el círculo contiene su centro');
select ok(pg_temp.cubre((select (r -> 'zona' ->> 'id')::uuid from radial), -34.73, -56.22, 399, g),
          format('contiene el punto a radio − 1 m con rumbo %s°', g))
  from unnest(array[0, 1.40625, 90, 181.40625, 270]) g;
select ok(not pg_temp.cubre((select (r -> 'zona' ->> 'id')::uuid from radial), -34.73, -56.22, 401, g),
          format('no contiene el punto a radio + 1 m con rumbo %s°', g))
  from unnest(array[0, 1.40625, 90, 181.40625, 270]) g;

-- Lo que manda el cliente como polígono de una RADIAL se pisa: lo calcula el servidor.
select pg_temp.actuar_como_servidor();
update public.zona set poligono_geojson = pg_temp.rect(-56.23, -34.74, -56.22, -34.73)
 where id = (select (r -> 'zona' ->> 'id')::uuid from radial);
select is((select jsonb_array_length(poligono_geojson -> 'coordinates' -> 0) from public.zona
            where id = (select (r -> 'zona' ->> 'id')::uuid from radial)), 129,
          'el polígono de una RADIAL lo recalcula el servidor aunque el UPDATE mande otro');

-- ---------------------------------------------------------------------------
-- 4. ESQUINAS
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => '[{"orden":1,"lat":-34.91,"lon":-56.17},{"orden":2,"lat":-34.91,"lon":-56.16}]',
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', 'Una zona por esquinas necesita al menos 3 esquinas (tiene 2). Marcá más esquinas en el mapa.',
  'ESQUINAS con 2 vértices → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => '[{"orden":1,"lat":-34.91,"lon":-56.17},{"orden":1,"lat":-34.91,"lon":-56.16},{"orden":3,"lat":-34.90,"lon":-56.16}]',
       p_poligono_geojson => '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.91]]]}') $$,
  'CZ008', 'La esquina 1 está repetida: cada esquina lleva un orden distinto. Volvé a marcar las esquinas.',
  'ESQUINAS con orden repetido → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', 'Falta el borde de la zona, que sigue las calles entre las esquinas. Volvé a cerrar la forma.',
  'ESQUINAS sin polígono → CZ008: no se rellena con rectas entre esquinas');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90),
       p_poligono_geojson => '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.90]]]}') $$,
  'CZ008', 'El borde de la zona no sirve: el borde no está cerrado: el último punto tiene que repetir el primero. Volvé a cerrar la forma.',
  'ESQUINAS con el anillo abierto → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90),
       p_poligono_geojson => '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.90],[-56.16,-34.91],[-56.17,-34.90],[-56.17,-34.91]]]}') $$,
  'CZ008', null, 'ESQUINAS con un borde que se cruza a sí mismo → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90) || '[{"orden":5,"lat":-34.905,"lon":-56.165}]'::jsonb,
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', 'El borde no pasa por la esquina 5. Volvé a cerrar la forma para que el borde siga las esquinas.',
  'ESQUINAS con una esquina lejos del borde → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => '[{"orden":1,"lat":-34.91,"lon":-56.17},{"orden":2,"lat":-34.91,"lon":-56.17},{"orden":3,"lat":-34.91,"lon":-56.17}]',
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', 'Una zona por esquinas necesita al menos 3 esquinas en lugares distintos y hay 1 (dos esquinas a 1 m o menos cuentan como una). Marcá las esquinas que faltan en el mapa.',
  'ESQUINAS con las 3 esquinas en el mismo punto → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => '[{"orden":1,"lat":-34.91,"lon":-56.17},{"orden":2,"lat":-34.910005,"lon":-56.170005},{"orden":3,"lat":-34.91,"lon":-56.16}]',
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', 'Una zona por esquinas necesita al menos 3 esquinas en lugares distintos y hay 2 (dos esquinas a 1 m o menos cuentan como una). Marcá las esquinas que faltan en el mapa.',
  'ESQUINAS con dos esquinas a menos de 1 m → cuentan como una → CZ008');
select is(
  (select jsonb_path_query_array(
            public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
              p_vertices => '[{"orden":1.0,"lat":-34.91,"lon":-56.17},{"orden":2.0,"lat":-34.91,"lon":-56.16},{"orden":3,"lat":-34.90,"lon":-56.16},{"orden":4.00,"lat":-34.90,"lon":-56.17}]',
              p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90), p_vista_previa => true),
            '$.guardada')),
  '[false]'::jsonb,
  'un orden 2.0 vale como 2 (no cae en un 22P02)');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS',
       p_vertices => '[{"orden":1,"lat":-34.91,"lon":-56.17},{"orden":2.5,"lat":-34.91,"lon":-56.16},{"orden":3,"lat":-34.90,"lon":-56.16}]',
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', 'El orden de una esquina tiene que ser un número entero. Volvé a marcar las esquinas.',
  'un orden 2.5 → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS', p_radio_m => 300,
       p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90),
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', null, 'ESQUINAS con radio → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'CUADRADA') $$,
  'CZ008', null, 'tipo de forma desconocido → CZ008');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', '  ', 'ESQUINAS') $$,
  'CZ009', 'La zona necesita un nombre. Escribí uno.', 'sin nombre → CZ009');
select throws_ok(
  $$ select public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'E', 'ESQUINAS', 'azul',
       p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90),
       p_poligono_geojson => pg_temp.rect(-56.17, -34.91, -56.16, -34.90)) $$,
  'CZ008', null, 'color que no es #RRGGBB → CZ008');

-- 3 esquinas alcanzan.
select is(
  (select jsonb_array_length(public.guardar_zona('01920000-0000-7000-8000-0000000010f2', 'Triángulo', 'ESQUINAS',
     p_vertices => '[{"orden":1,"lat":-34.70,"lon":-56.20},{"orden":2,"lat":-34.70,"lon":-56.19},{"orden":3,"lat":-34.69,"lon":-56.19}]',
     p_poligono_geojson => '{"type":"Polygon","coordinates":[[[-56.20,-34.70],[-56.19,-34.70],[-56.19,-34.69],[-56.20,-34.70]]]}') -> 'vertices')),
  3, 'ESQUINAS con 3 vértices → se guarda con sus 3 esquinas');

-- Orden repetido por INSERT directo: el índice único entre las vivas.
select pg_temp.actuar_como_servidor();
select throws_ok(
  $$ insert into public.zona_vertice (zona_id, orden, lat, lon)
     select z.id, 1, -34.70, -56.20 from public.zona z where z.nombre = 'Triángulo' $$,
  '23505', null, 'un vértice con orden repetido en la misma zona se rechaza también por INSERT directo');

-- ---------------------------------------------------------------------------
-- 5. No superposición
-- ---------------------------------------------------------------------------
-- A y B comparten el borde lon = -56.16 (la calle). C se mete en las dos.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
create temp table zonas_ab on commit drop as
select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona A', -56.17, -34.91, -56.16, -34.90) as a,
       null::jsonb as b;
update zonas_ab set b = pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona B', -56.16, -34.91, -56.15, -34.90);
select is((select a ->> 'guardada' from zonas_ab), 'true', 'Zona A se guarda');
select is((select b ->> 'guardada' from zonas_ab), 'true', 'Zona B comparte un borde (la calle) con A → se guarda');
select is((select jsonb_array_length(a -> 'vertices') from zonas_ab), 4, 'Zona A queda con sus 4 esquinas');

select throws_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona C', -56.165, -34.91, -56.155, -34.90) $$,
  'CZ007', 'Esta zona se superpone con «Zona A». Ajustá el borde para que solo compartan la calle.',
  'Zona C se superpone con A y B → CZ007, con el aviso de qué hacer');
select is(
  (select jsonb_path_query_array(pg_temp.detalle_error(
     $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona C', -56.165, -34.91, -56.155, -34.90) $$)::jsonb,
     '$.superposiciones[*].nombre')),
  '["Zona A", "Zona B"]'::jsonb,
  'el DETAIL de CZ007 lista todas las zonas con las que choca');
select is(
  (select pg_temp.detalle_error(
     $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona C', -56.165, -34.91, -56.155, -34.90) $$)::jsonb
     -> 'superposiciones' -> 0 -> 'interseccion' ->> 'type'),
  'Polygon', 'el DETAIL trae la geometría de la parte superpuesta (para marcarla en rojo)');

-- La vista previa no guarda: devuelve las superposiciones y cuántas ubicaciones incluye.
create temp table previa on commit drop as
select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona C', -56.165, -34.91, -56.155, -34.90,
                            p_previa => true) as p;
select is((select p ->> 'guardada' from previa), 'false', 'vista previa: no guarda');
select is((select jsonb_array_length(p -> 'superposiciones') from previa), 2, 'vista previa: devuelve las 2 superposiciones');
select is((select p -> 'ubicaciones_incluidas' from previa), '0'::jsonb,
          'vista previa: ubicaciones_incluidas (0: no hay ubicaciones; el conteo lo prueba 0013)');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.zona where nombre = 'Zona C'), 0::bigint, 'vista previa: Zona C no existe');

-- Tolerancia: una franja común de 0,33 m (ruido del borde) pasa; una de 3,3 m no.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select lives_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona D', -56.17, -34.900003, -56.16, -34.89) $$,
  'Zona D pisa a A en 0,33 m (menos de 1 m) → se toma como borde compartido');
select throws_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona E', -56.16, -34.90003, -56.15, -34.89) $$,
  'CZ007', 'Esta zona se superpone con «Zona B». Ajustá el borde para que solo compartan la calle.',
  'Zona E pisa a B en 3,3 m → CZ007');

-- En otra campania_ciudad (otra campaña, misma ciudad) sí se puede superponer.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a2');
select lives_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f3', 'Zona A de Otra', -56.17, -34.91, -56.16, -34.90) $$,
  'la misma forma de A en otra campaña → se guarda (la regla es por campania_ciudad)');

-- Por INSERT directo también (trigger).
select pg_temp.actuar_como_servidor();
select throws_ok(
  $$ insert into public.zona (nombre, campania_ciudad_id, tipo_forma, poligono_geojson)
     values ('Zona C directa', '01920000-0000-7000-8000-0000000010f1', 'ESQUINAS',
             pg_temp.rect(-56.165, -34.91, -56.155, -34.90)) $$,
  'CZ007', null, 'superposición por INSERT directo → CZ007 (trigger)');

-- ---------------------------------------------------------------------------
-- 6. Editar
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona B', -56.17, -34.93, -56.16, -34.92) $$,
  'CZ009', 'Ya hay una zona «Zona B» en esta ciudad de la campaña. Elegí otro nombre.', 'nombre repetido en la ciudad → CZ009');

create temp table ids_a on commit drop as
select v.orden, v.id from public.zona_vertice v
 where v.zona_id = (select (a -> 'zona' ->> 'id')::uuid from zonas_ab) and v.deleted_at is null;

-- Editar A con una quinta esquina en el medio del lado sur: el borde pasa por ella.
select is(
  (select jsonb_array_length(public.guardar_zona('01920000-0000-7000-8000-0000000010f1', 'Zona A', 'ESQUINAS', '#112233',
     p_vertices => pg_temp.esquinas(-56.17, -34.91, -56.16, -34.90) || '[{"orden":5,"lat":-34.91,"lon":-56.165}]'::jsonb,
     p_poligono_geojson => '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.165,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.90],[-56.17,-34.91]]]}',
     p_zona_id => (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)) -> 'vertices')),
  5, 'editar A agregando una esquina: quedan 5');
select is(
  (select count(*) from ids_a i join public.zona_vertice v on v.id = i.id and v.deleted_at is null),
  4::bigint, 'las esquinas que siguen conservan su id');
select is((select color from public.zona where id = (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)),
          '#112233', 'la edición cambia el color');

-- Volver a 4: la quinta queda como baja (tombstone para el sync), no se borra.
select lives_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona A', -56.17, -34.91, -56.16, -34.90,
                                 p_zona => (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'editar A quitando la quinta esquina');
select pg_temp.actuar_como_servidor();
select results_eq(
  $$ select count(*) filter (where deleted_at is null), count(*) filter (where deleted_at is not null)
       from public.zona_vertice where zona_id = (select (a -> 'zona' ->> 'id')::uuid from zonas_ab) $$,
  $$ values (4::bigint, 1::bigint) $$,
  'la esquina quitada queda dada de baja (4 vivas, 1 baja)');

-- Guardar sin cambios no toca la fila (no sube sync_version).
create temp table sv on commit drop as
select sync_version from public.zona where id = (select (a -> 'zona' ->> 'id')::uuid from zonas_ab);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select lives_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona A', -56.17, -34.91, -56.16, -34.90,
                                 p_zona => (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'guardar A sin cambios');
select pg_temp.actuar_como_servidor();
select is((select sync_version from public.zona where id = (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)),
          (select sync_version from sv), 'guardar sin cambios no sube sync_version');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f2', 'Zona A', -56.17, -34.91, -56.16, -34.90,
                                 p_zona => (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'CZ012', 'La zona no es de esta ciudad de la campaña. Recargá el mapa.',
  'editar una zona pasando otra ciudad de la campaña → CZ012');

select pg_temp.actuar_como_servidor();
select throws_ok(
  $$ update public.zona set campania_ciudad_id = '01920000-0000-7000-8000-0000000010f2'
      where id = (select (a -> 'zona' ->> 'id')::uuid from zonas_ab) $$,
  '23514', null, 'una zona no cambia de campania_ciudad ni por UPDATE directo');

-- ---------------------------------------------------------------------------
-- 7. Baja
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010b1',
                                (select (a -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'se asigna Zona A a b1');

select is(
  (select public.baja_zona((select (a -> 'zona' ->> 'id')::uuid from zonas_ab), true)
          -> 'colportores_asignados' -> 0 ->> 'apellido'),
  'Zeta', 'vista previa de la baja: lista a quién hay que reasignar');
select throws_ok(
  $$ select public.baja_zona((select (a -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'CZ010', 'La zona «Zona A» tiene colportores asignados: Uno Zeta. Reasignalos a otra zona antes de darla de baja.',
  'baja de una zona con colportores asignados → CZ010 con los nombres');

select is(
  (select public.baja_zona((select (b -> 'zona' ->> 'id')::uuid from zonas_ab)) ->> 'dada_de_baja'),
  'true', 'baja de una zona sin asignados');
select pg_temp.actuar_como_servidor();
select ok((select deleted_at is not null from public.zona where id = (select (b -> 'zona' ->> 'id')::uuid from zonas_ab)),
          'la baja es lógica (deleted_at), la fila sigue');
select is((select count(*) from public.zona_vertice
            where zona_id = (select (b -> 'zona' ->> 'id')::uuid from zonas_ab) and deleted_at is null),
          0::bigint, 'las esquinas de la zona dada de baja también quedan de baja');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010b1',
                                (select (b -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'CZ004', null, 'no se asigna una zona dada de baja');
select throws_ok(
  $$ select public.baja_zona((select (b -> 'zona' ->> 'id')::uuid from zonas_ab)) $$,
  'CZ004', null, 'dar de baja dos veces → CZ004');

-- Una zona dada de baja no cuenta para la superposición.
select lives_ok(
  $$ select pg_temp.guardar_rect('01920000-0000-7000-8000-0000000010f1', 'Zona B nueva', -56.16, -34.91, -56.15, -34.90) $$,
  'una zona nueva en el lugar de B (dada de baja) → se guarda');

-- ---------------------------------------------------------------------------
-- 8. Agregar ciudad
-- ---------------------------------------------------------------------------
create temp table agregada on commit drop as
select public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c3') as f;
select is((select (f).ciudad_id from agregada), '01920000-0000-7000-8000-0000000010c3'::uuid,
          'el coordinador agrega Canelones a su campaña');
select is((select (public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c3')).id),
          (select (f).id from agregada), 'agregarla de nuevo devuelve la misma fila');
select throws_ok(
  $$ select public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010cf') $$,
  'CZ013', 'La ciudad no está en el catálogo. Pedile a un administrador que la cargue.', 'ciudad inexistente → CZ013');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a2');
select throws_ok(
  $$ select public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c3') $$,
  '42501', null, 'el coordinador de otra campaña no agrega ciudades a esta');

-- ---------------------------------------------------------------------------
-- 9. RLS: quién lee el mapa y nadie lo escribe directo
-- ---------------------------------------------------------------------------
-- b1 (inscripto en Verano): todas las zonas de las ciudades de Verano, no las de Otra.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010b1');
select is(
  (select array_agg(nombre order by nombre) from public.zona where deleted_at is null),
  array['Radial LP', 'Triángulo', 'Zona A', 'Zona B nueva', 'Zona D'],
  'el colportor lee todas las zonas vivas de su campaña (no solo la suya) y ninguna de otra');
select ok((select count(*) > 0 from public.zona where deleted_at is not null),
          'el colportor también lee las bajas (tombstones para su réplica)');
select is((select count(*) from public.zona_vertice v
            join public.zona z on z.id = v.zona_id where z.nombre = 'Zona A' and v.deleted_at is null),
          4::bigint, 'el colportor lee las esquinas de las zonas de su campaña');
select is((select count(*) from public.campania_ciudad where campania_id = '01920000-0000-7000-8000-0000000010e1'),
          3::bigint, 'el colportor lee las ciudades de su campaña');
select is((select count(*) from public.campania_ciudad where campania_id <> '01920000-0000-7000-8000-0000000010e1'),
          0::bigint, 'y ninguna de otra campaña');
select is((select count(*) from public.zona_vertice v join public.zona z on z.id = v.zona_id
            where z.nombre = 'Zona A de Otra'), 0::bigint, 'no lee las esquinas de otra campaña');

select throws_ok(
  $$ insert into public.zona (nombre, campania_ciudad_id, tipo_forma, poligono_geojson)
     values ('Pirata', '01920000-0000-7000-8000-0000000010f1', 'ESQUINAS', pg_temp.rect(-56.10, -34.91, -56.09, -34.90)) $$,
  '42501', null, 'el colportor no inserta zonas');
select throws_ok(
  $$ update public.zona set nombre = 'Pirata' where nombre = 'Zona A' $$,
  '42501', null, 'el colportor no edita zonas');
select throws_ok(
  $$ insert into public.zona_vertice (zona_id, orden, lat, lon)
     select id, 9, -34.90, -56.16 from public.zona where nombre = 'Zona A' $$,
  '42501', null, 'el colportor no inserta vértices');
select throws_ok(
  $$ insert into public.campania_ciudad (campania_id, ciudad_id)
     values ('01920000-0000-7000-8000-0000000010e1', '01920000-0000-7000-8000-0000000010c2') $$,
  '42501', null, 'el colportor no agrega ciudades a la campaña');

-- Ni el coordinador escribe directo: solo por los RPC.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a1');
select throws_ok(
  $$ update public.zona set nombre = 'Otro nombre' where nombre = 'Zona A' $$,
  '42501', null, 'el coordinador tampoco edita zonas por UPDATE directo');

-- b3 (sin inscripción) no ve el mapa de nadie.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010b3');
select is((select count(*) from public.zona), 0::bigint, 'un colportor sin inscripción no ve zonas');
select is((select count(*) from public.campania_ciudad), 0::bigint, 'ni ciudades de campaña');

-- b2 (inscripto en Otra) ve lo de Otra.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010b2');
select is((select array_agg(nombre order by nombre) from public.zona), array['Zona A de Otra'],
          'el inscripto en Otra ve solo las zonas de Otra');

-- a2 (coordinador de Otra) ve lo de Otra; ad (ADMIN) ve todo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010a2');
select is((select array_agg(nombre order by nombre) from public.zona), array['Zona A de Otra'],
          'el coordinador ve las zonas de las campañas que coordina y no otras');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010ad');
select ok((select count(*) >= 7 from public.zona), 'el ADMIN ve las zonas de todas las campañas');

-- Un usuario dado de baja pierde el mapa (ADR-005).
select pg_temp.actuar_como_servidor();
update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000010b1';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000010b1');
select is((select count(*) from public.zona), 0::bigint, 'un usuario dado de baja no ve zonas');

select * from finish();
rollback;
