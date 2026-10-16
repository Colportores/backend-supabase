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

-- Un job del push, y los outcome (con el code, si hay) de una respuesta, en orden.
create or replace function pg_temp.job(p_ent text, p_op text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', p_ent, 'op', p_op, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg((e ->> 'outcome') || coalesce(' ' || (e ->> 'code'), '') order by i)
    from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

create or replace function pg_temp.ids_visibles() returns uuid[] language sql as $$
  select coalesce(array_agg(id order by id), array[]::uuid[]) from public.ubicacion;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Montevideo (c1) en Verano (e1, vigente, coordina a1) y en Vieja (e3, terminada); Otra ciudad
-- (c2) en Otra (e2, vigente); Canelones (c3) también en Verano. Zonas de Verano: A y B en
-- Montevideo, D en Canelones.
-- b1: Verano, zona A. b2: Verano, sin zona. b3: Otra, sin zona. b4: solo Vieja. b5: Verano, zona D.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000013' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'sinzona-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4','b5']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000013a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000013c0', 'Pais sin zona', 'ZP');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000013c1', 'Montevideo sz', '01920000-0000-7000-8000-0000000013c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000013c2', 'Otra ciudad sz', '01920000-0000-7000-8000-0000000013c0', -34.8, -56.0),
  ('01920000-0000-7000-8000-0000000013c3', 'Canelones sz',   '01920000-0000-7000-8000-0000000013c0', -34.7, -56.1);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000013e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000013a1'),
  ('01920000-0000-7000-8000-0000000013e2', 'Otra',   'PERMANENTE', current_date - 10, null,              null),
  ('01920000-0000-7000-8000-0000000013e3', 'Vieja',  'VERANO',     current_date - 90, current_date - 30, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000013f1', '01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-0000000013f2', '01920000-0000-7000-8000-0000000013e2', '01920000-0000-7000-8000-0000000013c2'),
  ('01920000-0000-7000-8000-0000000013f3', '01920000-0000-7000-8000-0000000013e3', '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-0000000013f4', '01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013c3');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000013d1', 'A', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.20, -34.92, -56.19, -34.91)),
  ('01920000-0000-7000-8000-0000000013d2', 'B', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91)),
  ('01920000-0000-7000-8000-0000000013d3', 'D', '01920000-0000-7000-8000-0000000013f4', 'ESQUINAS', pg_temp.rect(-56.11, -34.71, -56.10, -34.70));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b1', '01920000-0000-7000-8000-0000000013d1'),
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b2', null),
  ('01920000-0000-7000-8000-0000000013e2', '01920000-0000-7000-8000-0000000013b3', null),
  ('01920000-0000-7000-8000-0000000013e3', '01920000-0000-7000-8000-0000000013b4', null),
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b5', '01920000-0000-7000-8000-0000000013d3');

-- u1 en A, u2 en Montevideo fuera de toda zona, u3 en la otra ciudad, u30 en Canelones fuera de D.
-- Las carga el servidor.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001301', 'CASA', 'Rivera', '1', -34.915, -56.195, '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001302', 'CASA', 'Rivera', '2', -34.95,  -56.25,  '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001303', 'CASA', 'Rivera', '3', -34.915, -56.195, '01920000-0000-7000-8000-0000000013c2'),
  ('01920000-0000-7000-8000-000000001330', 'CASA', 'Artigas', '30', -34.72, -56.12, '01920000-0000-7000-8000-0000000013c3');

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
  'bajan según la ciudad de trabajo del pull: ubicacion, y espacio y house_status por su ubicación');
select has_index('public', 'ubicacion', 'ubicacion_geometria_idx', 'índice GiST de la posición (pull e Incluye N)');
select ok((select indexdef !~* ' where ' from pg_indexes
            where schemaname = 'public' and indexname = 'ubicacion_geometria_idx'),
          'e incluye las bajas: el pull por zona baja su tombstone');
select has_index('public', 'ubicacion', 'ubicacion_geografia_idx', 'índice geography + GiST para los 5 m');
select ok(has_function_privilege('authenticated', 'public.mis_ciudades_de_trabajo()', 'execute'),
          'authenticated ejecuta mis_ciudades_de_trabajo (la usan las políticas)');
select ok(has_function_privilege('authenticated', 'public.mis_ciudades_de_campania()', 'execute')
          and has_function_privilege('authenticated', 'public.puedo_escribir_en_ubicacion(uuid)', 'execute'),
          'authenticated ejecuta mis_ciudades_de_campania y puedo_escribir_en_ubicacion (políticas de escritura)');
select ok(not has_function_privilege('anon', 'public.puedo_escribir_en_ubicacion(uuid)', 'execute'),
          'anon no');
select hasnt_function('public', 'ubicaciones_de_mi_zona', 'el pull ya no tiene la rama «zona» (0023): la función se fue');
select ok(not has_function_privilege('authenticated', 'public.zona_ubicaciones_incluidas(uuid,jsonb)', 'execute'),
          'authenticated NO ejecuta la interna zona_ubicaciones_incluidas');
select ok(has_function_privilege('authenticated',
            'public.posibles_duplicados_de_ubicacion(uuid,text,text,double precision,double precision,uuid)', 'execute'),
          'authenticated ejecuta posibles_duplicados_de_ubicacion (la RLS decide qué filas)');

-- ---------------------------------------------------------------------------
-- 2. mis_ciudades_de_trabajo(): la ciudad de su zona; sin zona, todas las de sus campañas
--    vigentes (S55, decisión de Cristian del 30/09)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select results_eq($$ select * from public.mis_ciudades_de_trabajo() $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c1'::uuid) $$,
                  'b1 (Verano, zona A en Montevideo) trabaja en la ciudad de su zona, no en Canelones (S55)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b5');
select results_eq($$ select * from public.mis_ciudades_de_trabajo() $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c3'::uuid) $$,
                  'b5 (Verano, zona D en Canelones) trabaja en Canelones, no en Montevideo (S55)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select results_eq($$ select * from public.mis_ciudades_de_trabajo() order by 1 $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c1'::uuid), ('01920000-0000-7000-8000-0000000013c3'::uuid) $$,
                  'b2 (Verano, sin zona) trabaja en todas las ciudades de Verano (S55)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
select is((select count(*) from public.mis_ciudades_de_trabajo()), 0::bigint,
          'b4 solo está en una campaña terminada: ninguna');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((select count(*) from public.mis_ciudades_de_trabajo()), 0::bigint,
          'el coordinador no tiene inscripciones: ninguna (ve todo por su rol)');

-- Una zona dada de baja cuenta como sin zona (la misma vigencia que mis_zonas()). baja_zona()
-- no deja dar de baja una zona asignada: se fuerza como servidor, y se deshace enseguida.
select pg_temp.actuar_como_servidor();
update public.zona set deleted_at = now() where id = '01920000-0000-7000-8000-0000000013d3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b5');
select results_eq($$ select * from public.mis_ciudades_de_trabajo() order by 1 $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c1'::uuid), ('01920000-0000-7000-8000-0000000013c3'::uuid) $$,
                  'con su zona dada de baja, b5 cuenta como sin zona: todas las ciudades de Verano');
select pg_temp.actuar_como_servidor();
update public.zona set deleted_at = null where id = '01920000-0000-7000-8000-0000000013d3';

-- ---------------------------------------------------------------------------
-- 3. Quién ve qué ubicación: la ciudad, no la zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select is(pg_temp.ids_visibles(),
          array['01920000-0000-7000-8000-000000001301', '01920000-0000-7000-8000-000000001302']::uuid[],
          'b1 ve las casas de la ciudad de su zona, dentro y fuera de ella; ni las de Canelones (otra ciudad de Verano, S55) ni las de otra campaña');
select is((select array_agg(x order by x) from sync.area_del_pull() a, unnest(a.ciudades) x),
          array['01920000-0000-7000-8000-0000000013c1']::uuid[],
          'el pull de b1 baja toda la ciudad de su zona (0023): una sola ciudad, la de A, no la de Canelones');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select is(pg_temp.ids_visibles(),
          array['01920000-0000-7000-8000-000000001301', '01920000-0000-7000-8000-000000001302',
                '01920000-0000-7000-8000-000000001330']::uuid[],
          'b2, sin zona, ve las de todas las ciudades de Verano (S55); no las de otra campaña');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b5');
select is(pg_temp.ids_visibles(), array['01920000-0000-7000-8000-000000001330']::uuid[],
          'b5 (zona D) ve las de Canelones, también fuera de su zona; no las de Montevideo (S55)');
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
-- ciudad donde no trabaja. Las propias van a cualquier lado, con alguna campaña en la que escribir (0021).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select lives_ok(
  $$ update public.ubicacion set lat = -34.951 where id = '01920000-0000-7000-8000-000000001302' $$,
  'b2 corrige una casa ajena de su ciudad');
select throws_ok(
  $$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000013c2'
      where id = '01920000-0000-7000-8000-000000001302' $$,
  '42501', null, 'b2 NO la manda a una ciudad donde no trabaja');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select throws_ok(
  $$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000013c3'
      where id = '01920000-0000-7000-8000-000000001302' $$,
  '42501', null,
  'b1 (zona en Montevideo) NO manda una casa ajena a Canelones: podría escribir allá, pero dejaría de verla (el UPDATE la lee, S55)');
update public.ubicacion set calle = 'Pirata' where id = '01920000-0000-7000-8000-000000001330';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
update public.ubicacion set calle = 'Pirata' where id = '01920000-0000-7000-8000-000000001301';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
-- b4 solo tiene una campaña terminada hace más de 15 días: desde 0021, el autor corrige y muda su
-- casa solo con alguna campaña en la que escribir (decisión de Cristian del 02/10, #55).
select throws_ok(
  $$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000013c2', lat = -34.8, lon = -56.0
      where id = '01920000-0000-7000-8000-000000001304' $$,
  '42501', null, 'b4 (sin campaña en la que escribir) ya no mueve su propia casa a otra ciudad');
select pg_temp.actuar_como_servidor();
select is((select calle from public.ubicacion where id = '01920000-0000-7000-8000-000000001301'), 'Rivera',
          'b3 no tocó una casa de otra ciudad (para él no existe)');
select is((select calle from public.ubicacion where id = '01920000-0000-7000-8000-000000001330'), 'Artigas',
          'b1 tampoco tocó una casa de Canelones: no es la ciudad de su zona (S55)');

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

-- b3 no puede reapuntar su estado a una casa que no ve: el pin (que copia el servidor) le
-- revelaría su posición.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001309', 'CASA', -34.81, -56.01, '01920000-0000-7000-8000-0000000013c2');
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad) values
  ('01920000-0000-7000-8000-000000001309', 0, 0, 'CASA', 'RECHAZO', 7);
select throws_ok(
  $$ update public.house_status set ubicacion_id = '01920000-0000-7000-8000-000000001302'
      where ubicacion_id = '01920000-0000-7000-8000-000000001309' $$,
  '42501', null, 'b3 NO reapunta su estado a una casa de otra ciudad (no ve su posición)');
select is((select array[lat, lon] from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001309'),
          array[-34.81, -56.01]::float8[], 'su estado sigue en su casa, con el pin de ella');

-- ---------------------------------------------------------------------------
-- 4b. Escribir no se acota a la zona (decisión de Cristian del 30/09 sobre S55, #36): se
--     aceptan las escrituras en todas las ciudades de sus campañas vigentes, tenga zona o no
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select results_eq($$ select * from public.mis_ciudades_de_campania() order by 1 $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c1'::uuid), ('01920000-0000-7000-8000-0000000013c3'::uuid) $$,
                  'b1 (zona A en Montevideo) escribe en todas las ciudades de Verano, también Canelones');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
select results_eq($$ select * from public.mis_ciudades_de_campania() $$,
                  $$ values ('01920000-0000-7000-8000-0000000013c2'::uuid) $$,
                  'b3 (Otra) solo en la ciudad de Otra');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
select is((select count(*) from public.mis_ciudades_de_campania()), 0::bigint,
          'b4 (solo una campaña terminada) en ninguna');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((select count(*) from public.mis_ciudades_de_campania()), 0::bigint,
          'el coordinador (sin inscripciones) en ninguna');

-- El caso de la decisión: b1 trabajó sin señal en una casa de Canelones que no registró él
-- (1330: no la ve, porque su zona es de Montevideo) y le vendió a alguien de un depto nuevo.
-- A la noche sincroniza: el espacio, el vínculo, la visita, la venta y el estado suben.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select is((select count(*) from public.ubicacion where id = '01920000-0000-7000-8000-000000001330'), 0::bigint,
          'la lectura sigue acotada a su zona: b1 no ve la casa de Canelones (S55)');
create temp table lote_canelones on commit drop as
select sync.push(jsonb_build_array(
  pg_temp.job('espacio', 'insert', '{"id": "01920000-0000-7000-8000-000000001331",
                                     "ubicacion_id": "01920000-0000-7000-8000-000000001330", "numero_depto": "3"}'),
  pg_temp.job('espacio_persona', 'insert', '{"id": "01920000-0000-7000-8000-000000001332",
                                             "espacio_id": "01920000-0000-7000-8000-000000001331",
                                             "persona_id": "01920000-0000-7000-8000-000000001333"}'),
  pg_temp.job('visita', 'insert', jsonb_build_object('id', '01920000-0000-7000-8000-000000001334',
                                                     'espacio_persona_id', '01920000-0000-7000-8000-000000001332',
                                                     'fecha', now(), 'tipo_resultado', 'VENTA')),
  pg_temp.job('venta', 'insert', jsonb_build_object('id', '01920000-0000-7000-8000-000000001335',
                                                    'espacio_persona_id', '01920000-0000-7000-8000-000000001332',
                                                    'numero_talonario', 'T-1335', 'monto_total', 150000,
                                                    'fecha', now(), 'visita_id', '01920000-0000-7000-8000-000000001334')),
  pg_temp.job('house_status', 'insert', '{"ubicacion_id": "01920000-0000-7000-8000-000000001330",
                                          "tipo_ubicacion": "CASA", "color": "VENTA_COMPLETA", "prioridad": 4}')
)) as r;
select is((select pg_temp.resultados(r) from lote_canelones),
          array['accepted', 'accepted', 'accepted', 'accepted', 'accepted'],
          'b1 (zona en Montevideo) sube el espacio, el vínculo, la visita, la venta y el estado de una casa de Canelones');
select is((select array_agg(e ->> 'sync_version' order by i)
             from lote_canelones, jsonb_array_elements(r -> 'results') with ordinality x(e, i)),
          array['0', '0', '0', '0', '0'], 'cada uno con su versión (el push lee lo que acaba de escribir)');
select is((select count(*) from public.espacio where id = '01920000-0000-7000-8000-000000001331'), 1::bigint,
          'b1 ve el depto que cargó (la rama de quien lo cargó, como en house_status)');
select is((select count(*) from public.ubicacion where id = '01920000-0000-7000-8000-000000001330'), 0::bigint,
          'pero la casa sigue sin verla');
select lives_ok(
  $$ update public.espacio set piso = '4' where id = '01920000-0000-7000-8000-000000001331' $$,
  'b1 corrige el depto que cargó allá');
select lives_ok(
  $$ update public.house_status set color = 'ENTREGA_Y_COBRANZA_PENDIENTE', prioridad = 1
      where ubicacion_id = '01920000-0000-7000-8000-000000001330' $$,
  'y el estado (lo ve porque lo escribió él)');

select pg_temp.actuar_como_servidor();
select is((select colportor_id from public.venta where id = '01920000-0000-7000-8000-000000001335'),
          '01920000-0000-7000-8000-0000000013b1'::uuid, 'la venta quedó en el servidor, de b1');
select is((select array[ubicacion_id::text, piso] from public.espacio where id = '01920000-0000-7000-8000-000000001331'),
          array['01920000-0000-7000-8000-000000001330', '4'], 'y el depto, en la casa de Canelones, con la corrección');
select is((select array[color, created_by::text] from public.house_status
            where ubicacion_id = '01920000-0000-7000-8000-000000001330'),
          array['ENTREGA_Y_COBRANZA_PENDIENTE', '01920000-0000-7000-8000-0000000013b1'],
          'y el estado, con la corrección');

-- Por el INSERT directo, en el otro sentido: b5 (zona D en Canelones) carga un espacio en una casa
-- ajena de Montevideo, que no ve.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b5');
select lives_ok(
  $$ insert into public.espacio (id, ubicacion_id)
     values ('01920000-0000-7000-8000-000000001336', '01920000-0000-7000-8000-000000001302') $$,
  'b5 (zona en Canelones) carga un espacio en una casa ajena de Montevideo, otra ciudad de Verano');

-- Fuera de sus campañas sigue rechazado, por el push y por el INSERT directo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
select is(pg_temp.resultados(sync.push(jsonb_build_array(
            pg_temp.job('espacio', 'insert', '{"id": "01920000-0000-7000-8000-000000001337",
                                               "ubicacion_id": "01920000-0000-7000-8000-000000001330"}'),
            pg_temp.job('house_status', 'insert', '{"ubicacion_id": "01920000-0000-7000-8000-000000001302",
                                                    "tipo_ubicacion": "CASA", "color": "RECHAZO", "prioridad": 7}')))),
          array['invalid 42501', 'invalid 42501'],
          'b3 (Otra) no carga un espacio ni un estado en casas de Verano: no es su campaña');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b4');
select throws_ok(
  $$ insert into public.espacio (ubicacion_id) values ('01920000-0000-7000-8000-000000001330') $$,
  '42501', null, 'b4 (campaña terminada) tampoco');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.espacio
            where id in ('01920000-0000-7000-8000-000000001337')), 0::bigint,
          'lo rechazado no se escribió');

-- La GUC del republicado solo cuenta adentro de un trigger: puesta a mano, la versión sube igual.
select pg_temp.actuar_como_servidor();
create temp table version_1302 on commit drop as
select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-000000001302';
select set_config('colportores.republicar', 'on', true);
update public.ubicacion set calle = 'Rivera bis' where id = '01920000-0000-7000-8000-000000001302';
select set_config('colportores.republicar', 'off', true);
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-000000001302'),
          (select sync_version + 1 from version_1302),
          'un UPDATE de primer nivel con colportores.republicar = on sube la versión igual');

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
-- D1 (0017, backend-supabase#34) solo bloquea a menos de 100 m: esta está lejos, se guarda (con el aviso).
select lives_ok(
  $$ insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id)
     values ('CASA', 'av. italia', ' 2000', -34.80, -56.10, '01920000-0000-7000-8000-0000000013c1') $$,
  'la misma dirección lejos se guarda (el aviso no bloquea; D1 es solo a menos de 100 m)');

select * from finish();
rollback;
