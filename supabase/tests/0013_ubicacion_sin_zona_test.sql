-- pgTAP · migración 0011 — la ubicación no guarda zona (backend-supabase#32): forma, RLS por
-- ciudad, «Incluye N ubicaciones» de la vista 24 y el aviso de posible duplicado (0010). Lo que
-- baja en el pull (necesita filas commiteadas) lo prueba 0014.
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

create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;

create or replace function pg_temp.guardar_rect(p_nombre text, x0 numeric, y0 numeric, x1 numeric, y1 numeric,
                                                p_zona uuid default null, p_previa boolean default false)
returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-0000000013f1', p_nombre => p_nombre,
                             p_tipo_forma => 'ESQUINAS',
                             p_vertices => jsonb_build_array(
                               jsonb_build_object('orden', 1, 'lon', x0, 'lat', y0), jsonb_build_object('orden', 2, 'lon', x1, 'lat', y0),
                               jsonb_build_object('orden', 3, 'lon', x1, 'lat', y1), jsonb_build_object('orden', 4, 'lon', x0, 'lat', y1)),
                             p_poligono_geojson => pg_temp.rect(x0, y0, x1, y1),
                             p_zona_id => p_zona, p_vista_previa => p_previa);
$$;

-- Un punto a p_metros al este de (p_lat, p_lon), sobre el elipsoide.
create or replace function pg_temp.al_este(p_lat float8, p_lon float8, p_metros float8, out lat float8, out lon float8)
language sql as $$
  select extensions.st_y(g), extensions.st_x(g)
    from (select extensions.geometry(extensions.st_project(public.ubicacion_geografia(p_lat, p_lon),
                                                           p_metros, radians(90))) g) x;
$$;

create or replace function pg_temp.ids_visibles() returns uuid[] language sql as $$
  select coalesce(array_agg(id order by id), array[]::uuid[]) from public.ubicacion;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Montevideo (c1) en Verano (e1, vigente, coordina a1) y en Vieja (e3, terminada); Otra ciudad
-- (c2) en Otra (e2, vigente). Zonas de Verano: A y B.
-- b1: Verano, zona A. b2: Verano, sin zona. b3: Otra, sin zona. b4: solo Vieja.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000013' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'sinzona-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000013a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000013c0', 'Pais sin zona', 'ZP');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000013c1', 'Montevideo sz', '01920000-0000-7000-8000-0000000013c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000013c2', 'Otra ciudad sz', '01920000-0000-7000-8000-0000000013c0', -34.8, -56.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000013e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000013a1'),
  ('01920000-0000-7000-8000-0000000013e2', 'Otra',   'PERMANENTE', current_date - 10, null,              null),
  ('01920000-0000-7000-8000-0000000013e3', 'Vieja',  'VERANO',     current_date - 90, current_date - 30, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000013f1', '01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-0000000013f2', '01920000-0000-7000-8000-0000000013e2', '01920000-0000-7000-8000-0000000013c2'),
  ('01920000-0000-7000-8000-0000000013f3', '01920000-0000-7000-8000-0000000013e3', '01920000-0000-7000-8000-0000000013c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000013d1', 'A', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.20, -34.92, -56.19, -34.91)),
  ('01920000-0000-7000-8000-0000000013d2', 'B', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b1', '01920000-0000-7000-8000-0000000013d1'),
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b2', null),
  ('01920000-0000-7000-8000-0000000013e2', '01920000-0000-7000-8000-0000000013b3', null),
  ('01920000-0000-7000-8000-0000000013e3', '01920000-0000-7000-8000-0000000013b4', null);

-- u1 en A, u2 en Montevideo fuera de toda zona, u3 en la otra ciudad. Las carga el servidor.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001301', 'CASA', 'Rivera', '1', -34.915, -56.195, '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001302', 'CASA', 'Rivera', '2', -34.95,  -56.25,  '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001303', 'CASA', 'Rivera', '3', -34.915, -56.195, '01920000-0000-7000-8000-0000000013c2');

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select hasnt_column('public', 'ubicacion', 'zona_id', 'ubicacion ya no guarda zona');
select hasnt_column('public', 'house_status', 'zona_id', 'house_status tampoco');
select hasnt_trigger('public', 'ubicacion', 'ubicacion_zona_por_posicion', 'sin zona por posición');
select hasnt_trigger('public', 'ubicacion', 'ubicacion_zona_a_dependientes', 'sin republicado por cambio de zona');
select hasnt_trigger('public', 'house_status', 'house_status_zona_de_su_ubicacion', 'house_status no copia zona');
select hasnt_trigger('public', 'zona', 'zona_recalcular_ubicaciones', 'cambiar una zona no recalcula nada');
select hasnt_trigger('public', 'campania_colportor', 'campania_colportor_republicar_zona',
                     'asignar una zona no republica (lo reemplaza la huella del área en el pull)');
select has_trigger('public', 'ubicacion', 'ubicacion_posicion_a_dependientes',
                   'mover una ubicación republica sus espacios y su house_status');
select has_trigger('public', 'house_status', 'house_status_posicion_de_su_ubicacion',
                   'el pin (house_status.lat/lon) es la posición de su ubicación');
select ok((select columnas_servidor @> array['lat', 'lon'] from sync.entidad where nombre = 'house_status'),
          'house_status.lat/lon son del servidor: el push las descarta');
select hasnt_function('public', f, 'se fue ' || f)
  from unnest(array['zona_de_posicion', 'ubicacion_campanias_preferidas', 'recalcular_zona_de_ubicaciones',
                    'ubicaciones_de_zona_cambiada', 'zona_ubicaciones_que_cambian']) f;
select ok((select bool_and(not ('zona_id' = any (columnas_servidor))) from sync.entidad),
          'zona_id ya no está en columnas_servidor');
select results_eq(
  $$ select nombre, columna_ubicacion from sync.entidad where columna_ubicacion is not null order by nombre $$,
  $$ values ('espacio', 'ubicacion_id'), ('house_status', 'ubicacion_id'), ('ubicacion', 'id') $$,
  'bajan según el alcance del pull: ubicacion, y espacio y house_status por su ubicación');
select has_index('public', 'ubicacion', 'ubicacion_geometria_idx', 'índice GiST de la posición (pull e Incluye N)');
select ok((select indexdef !~* ' where ' from pg_indexes
            where schemaname = 'public' and indexname = 'ubicacion_geometria_idx'),
          'e incluye las bajas: el pull por zona baja su tombstone');
select has_index('public', 'ubicacion', 'ubicacion_geografia_idx', 'índice geography + GiST para los 5 m');
select ok(has_function_privilege('authenticated', 'public.mis_ciudades_de_trabajo()', 'execute'),
          'authenticated ejecuta mis_ciudades_de_trabajo (la usan las políticas)');
select ok(has_function_privilege('authenticated', 'public.ubicaciones_de_mi_zona()', 'execute'),
          'authenticated ejecuta ubicaciones_de_mi_zona (la usa el pull, que corre como él)');
select ok(not has_function_privilege('authenticated', 'public.zona_ubicaciones_incluidas(uuid,jsonb)', 'execute'),
          'authenticated NO ejecuta la interna zona_ubicaciones_incluidas');
select ok(has_function_privilege('authenticated',
            'public.posibles_duplicados_de_ubicacion(uuid,text,text,double precision,double precision,uuid)', 'execute'),
          'authenticated ejecuta posibles_duplicados_de_ubicacion (la RLS decide qué filas)');

-- ---------------------------------------------------------------------------
-- 2. mis_ciudades_de_trabajo(): las ciudades de sus campañas vigentes
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select results_eq($$ select * from public.mis_ciudades_de_trabajo() $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c1'::uuid) $$,
                  'b1 (Verano, zona A) trabaja en Montevideo');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select results_eq($$ select * from public.mis_ciudades_de_trabajo() $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c1'::uuid) $$,
                  'b2 también, aunque no tenga zona (S55, provisorio)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
select is((select count(*) from public.mis_ciudades_de_trabajo()), 0::bigint,
          'b4 solo está en una campaña terminada: ninguna');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((select count(*) from public.mis_ciudades_de_trabajo()), 0::bigint,
          'el coordinador no tiene inscripciones: ninguna (ve todo por su rol)');

-- ---------------------------------------------------------------------------
-- 3. Quién ve qué ubicación: la ciudad, no la zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select is(pg_temp.ids_visibles(),
          array['01920000-0000-7000-8000-000000001301', '01920000-0000-7000-8000-000000001302']::uuid[],
          'b1 ve las casas de su ciudad, dentro y fuera de su zona; no las de otra ciudad');
select is((select array_agg(x order by x) from public.ubicaciones_de_mi_zona() x),
          array['01920000-0000-7000-8000-000000001301']::uuid[],
          'la parte «zona» del pull de b1: la casa de A (no la de afuera ni la de otra ciudad)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select is(pg_temp.ids_visibles(),
          array['01920000-0000-7000-8000-000000001301', '01920000-0000-7000-8000-000000001302']::uuid[],
          'b2, sin zona, también (la zona no es un permiso)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
select is(pg_temp.ids_visibles(), array['01920000-0000-7000-8000-000000001303']::uuid[],
          'b3 ve solo las de su ciudad');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
select is(pg_temp.ids_visibles(), array[]::uuid[], 'b4 (campaña terminada) no ve ninguna');
select lives_ok(
  $$ insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
     values ('01920000-0000-7000-8000-000000001304', 'CASA', -34.95, -56.26, '01920000-0000-7000-8000-0000000013c1') $$,
  'b4 registra una casa aunque no trabaje en ninguna campaña (R-CM04)');
select is(pg_temp.ids_visibles(), array['01920000-0000-7000-8000-000000001304']::uuid[],
          'y ve la propia');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select ok(pg_temp.ids_visibles() @> array['01920000-0000-7000-8000-000000001301', '01920000-0000-7000-8000-000000001302',
                                          '01920000-0000-7000-8000-000000001303', '01920000-0000-7000-8000-000000001304']::uuid[],
          'el coordinador las ve todas (como antes)');

-- Corregir: quien trabaja en la ciudad corrige cualquier casa de ella, pero no la manda a una
-- ciudad donde no trabaja. Las propias van a cualquier lado.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select lives_ok(
  $$ update public.ubicacion set lat = -34.951 where id = '01920000-0000-7000-8000-000000001302' $$,
  'b2 corrige una casa ajena de su ciudad');
select throws_ok(
  $$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000013c2'
      where id = '01920000-0000-7000-8000-000000001302' $$,
  '42501', null, 'b2 NO la manda a una ciudad donde no trabaja');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
update public.ubicacion set calle = 'Pirata' where id = '01920000-0000-7000-8000-000000001301';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
select lives_ok(
  $$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000013c2', lat = -34.8, lon = -56.0
      where id = '01920000-0000-7000-8000-000000001304' $$,
  'b4 mueve su propia casa a otra ciudad');
select pg_temp.actuar_como_servidor();
select is((select calle from public.ubicacion where id = '01920000-0000-7000-8000-000000001301'), 'Rivera',
          'b3 no tocó una casa de otra ciudad (para él no existe)');

-- ---------------------------------------------------------------------------
-- 4. espacio y house_status siguen a su ubicación
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select lives_ok(
  $$ insert into public.espacio (id, ubicacion_id)
     values ('01920000-0000-7000-8000-000000001311', '01920000-0000-7000-8000-000000001301') $$,
  'b2 carga un espacio en una casa de su ciudad (fuera de su zona: no tiene)');
select lives_ok(
  $$ insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad)
     values ('01920000-0000-7000-8000-000000001301', -34.915, -56.195, 'CASA', 'RECHAZO', 7) $$,
  'y su estado');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select lives_ok(
  $$ update public.house_status set color = 'SIN_CONTESTAR', prioridad = 6
      where ubicacion_id = '01920000-0000-7000-8000-000000001301' $$,
  'b1 actualiza el estado que cargó b2 en una casa de su ciudad');
select is((select color from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001301'),
          'SIN_CONTESTAR', 'y lo ve');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
select is((select count(*) from public.espacio where ubicacion_id = '01920000-0000-7000-8000-000000001301'), 0::bigint,
          'b3 no ve los espacios de una casa de otra ciudad');
select is((select count(*) from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001301'), 0::bigint,
          'ni su estado');
select throws_ok(
  $$ insert into public.espacio (ubicacion_id) values ('01920000-0000-7000-8000-000000001301') $$,
  '42501', null, 'ni carga un espacio en ella');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((select count(*) from public.espacio where ubicacion_id = '01920000-0000-7000-8000-000000001301'), 1::bigint,
          'el coordinador ve los espacios');
select throws_ok(
  $$ insert into public.espacio (ubicacion_id) values ('01920000-0000-7000-8000-000000001302') $$,
  '42501', null, 'pero no los escribe: no trabaja la ciudad');

-- ---------------------------------------------------------------------------
-- 5. «Incluye N ubicaciones» (vista 24): calculado en el momento, sin recalcular nada
-- ---------------------------------------------------------------------------
-- En la franja C (lon -56.18..-56.17) de Montevideo: dos vivas y una baja. En la otra ciudad,
-- una en el mismo lugar (no cuenta: la zona es de Montevideo).
select pg_temp.actuar_como_servidor();
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-000000001305', 'CASA', -34.915, -56.175, '01920000-0000-7000-8000-0000000013c1', null),
  ('01920000-0000-7000-8000-000000001306', 'CASA', -34.915, -56.17,  '01920000-0000-7000-8000-0000000013c1', null),
  ('01920000-0000-7000-8000-000000001307', 'CASA', -34.915, -56.176, '01920000-0000-7000-8000-0000000013c1', now()),
  ('01920000-0000-7000-8000-000000001308', 'CASA', -34.915, -56.175, '01920000-0000-7000-8000-0000000013c2', null);
create temp table versiones_antes on commit drop as
select id, sync_version from public.ubicacion where id::text like '01920000-0000-7000-8000-00000000130%';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((pg_temp.guardar_rect('C', -56.18, -34.92, -56.17, -34.91, null, true) -> 'ubicaciones_incluidas'), '2'::jsonb,
          'vista previa de C: incluye las 2 vivas de Montevideo (la del borde también); ni la baja ni la de otra ciudad');
create temp table zona_c on commit drop as
select pg_temp.guardar_rect('C', -56.18, -34.92, -56.17, -34.91) as r;
select is((select r -> 'ubicaciones_incluidas' from zona_c), '2'::jsonb, 'al guardar, lo mismo');
select ok((select r ? 'ubicaciones_que_cambian' from zona_c) is false, 'ya no devuelve ubicaciones_que_cambian');
select is((pg_temp.guardar_rect('C', -56.18, -34.92, -56.174, -34.91,
                                (select (r -> 'zona' ->> 'id')::uuid from zona_c)) -> 'ubicaciones_incluidas'),
          '1'::jsonb, 'achicarla: incluye 1');
select is((public.baja_zona((select (r -> 'zona' ->> 'id')::uuid from zona_c), true) -> 'ubicaciones_incluidas'),
          '1'::jsonb, 'vista previa de la baja: la zona incluye 1');
select is((public.baja_zona((select (r -> 'zona' ->> 'id')::uuid from zona_c)) -> 'ubicaciones_incluidas'),
          '1'::jsonb, 'baja: lo mismo');
select pg_temp.actuar_como_servidor();
select results_eq(
  $$ select u.id, u.sync_version from public.ubicacion u
      where u.id::text like '01920000-0000-7000-8000-00000000130%' order by u.id $$,
  $$ select id, sync_version from versiones_antes order by id $$,
  'guardar, achicar y dar de baja una zona no toca ninguna ubicación');

-- ---------------------------------------------------------------------------
-- 6. Posible duplicado (aviso, 0010): a menos de 5 m, o la misma dirección normalizada
-- ---------------------------------------------------------------------------
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001320', 'CASA', 'Av. Italia', '2000', -34.95, -56.30, '01920000-0000-7000-8000-0000000013c1');
select is(
  (select array_agg(ubicacion_id) from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000013c1', null, null,
     (pg_temp.al_este(-34.95, -56.30, 4)).lat, (pg_temp.al_este(-34.95, -56.30, 4)).lon)),
  array['01920000-0000-7000-8000-000000001320'::uuid],
  'posible duplicado a 4 m → aparece');
select is(
  (select count(*) from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000013c1', null, null,
     (pg_temp.al_este(-34.95, -56.30, 6)).lat, (pg_temp.al_este(-34.95, -56.30, 6)).lon)),
  0::bigint,
  'a 6 m → no');
select is(
  (select array_agg(ubicacion_id::text || ' ' || misma_direccion) from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000013c1', '  AV. ITALIA ', '2000 ', -34.80, -56.10)),
  array['01920000-0000-7000-8000-000000001320 true'],
  'la misma dirección con mayúsculas y espacios distintos, lejos → aparece como misma dirección');
-- D1 (backend-supabase#34) todavía no está: hoy no hay único, así que se guarda (con el aviso).
select lives_ok(
  $$ insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id)
     values ('CASA', 'av. italia', ' 2000', -34.80, -56.10, '01920000-0000-7000-8000-0000000013c1') $$,
  'la misma dirección se guarda mientras falte D1 (el aviso no bloquea)');

select * from finish();
rollback;
