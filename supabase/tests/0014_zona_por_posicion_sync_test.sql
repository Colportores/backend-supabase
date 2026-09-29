-- pgTAP · migración 0010 — al rotar el colportor, quien toma la zona recibe por el delta las
-- casas ya trabajadas con su estado (HU-CAM-006), aunque se hayan cargado antes de su último
-- pull.
--
-- Como 0011, NO va en una transacción: el delta solo sirve filas commiteadas. Limpia al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Verano (e1, coordina a1) vigente con Z1 y Z2; Pasada (e0) todavía
-- vigente al cargar, con Z0, que cubre parte de Z2. b1 trabaja Z1; b2 está inscripto sin zona.
--   u1: casa en Z2 (con house_status y un espacio), cargada antes de que b2 sincronice.
--   u2: casa en Z0 ∩ Z2: se carga en Z0 (menor id) mientras Pasada está vigente.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000014' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'rota-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000014a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000014c0', 'Pais rota', 'ZR');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000014c1', 'Ciudad rota', '01920000-0000-7000-8000-0000000014c0', -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000014e0', 'Pasada', 'VERANO', current_date - 60, null, null),
  ('01920000-0000-7000-8000-0000000014e1', 'Verano', 'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000014a1');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000014f0', '01920000-0000-7000-8000-0000000014e0', '01920000-0000-7000-8000-0000000014c1'),
  ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000014d0', 'Z0', '01920000-0000-7000-8000-0000000014f0', 'ESQUINAS',
   '{"type":"Polygon","coordinates":[[[-56.21,-34.92],[-56.205,-34.92],[-56.205,-34.91],[-56.21,-34.91],[-56.21,-34.92]]]}'),
  ('01920000-0000-7000-8000-0000000014d1', 'Z1', '01920000-0000-7000-8000-0000000014f1', 'ESQUINAS',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.18,-34.92],[-56.18,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'),
  ('01920000-0000-7000-8000-0000000014d2', 'Z2', '01920000-0000-7000-8000-0000000014f1', 'ESQUINAS',
   '{"type":"Polygon","coordinates":[[[-56.21,-34.92],[-56.20,-34.92],[-56.20,-34.91],[-56.21,-34.91],[-56.21,-34.92]]]}');
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b1', '01920000-0000-7000-8000-0000000014d1'),
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b2', null);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001401', 'CASA', 'Rivera', '100', -34.915, -56.202, '01920000-0000-7000-8000-0000000014c1'),
  ('01920000-0000-7000-8000-000000001402', 'CASA', 'Rivera', '200', -34.915, -56.207, '01920000-0000-7000-8000-0000000014c1');
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad) values
  ('01920000-0000-7000-8000-000000001401', -34.915, -56.202, 'CASA', 'COBRANZA_PENDIENTE', 2);
insert into public.espacio (id, ubicacion_id) values
  ('01920000-0000-7000-8000-000000001411', '01920000-0000-7000-8000-000000001401');

select is((select zona_id from public.ubicacion where id = '01920000-0000-7000-8000-000000001402'),
          '01920000-0000-7000-8000-0000000014d0'::uuid, 'fixture: u2 se cargó en Z0 (Pasada vigente, menor id)');

-- Pasada termina. Nada se recalcula solo (D2 (a)): u2 sigue en Z0.
update public.campania set fecha_fin = current_date - 1 where id = '01920000-0000-7000-8000-0000000014e0';

-- Después, b2 registra una casa suya fuera de toda zona, con su estado y su espacio: así su
-- primer pull trae algo de cada tabla y su watermark queda POR ENCIMA de u1 y u2 (una entidad
-- sin filas no avanza el watermark y el pull siguiente arrancaría de cero).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-000000001403', 'CASA', 'Propia', '1', -34.95, -56.25,
   '01920000-0000-7000-8000-0000000014c1', '01920000-0000-7000-8000-0000000014b2');
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by) values
  ('01920000-0000-7000-8000-000000001403', -34.95, -56.25, 'CASA', 'RECHAZO', 7, '01920000-0000-7000-8000-0000000014b2');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-000000001413', '01920000-0000-7000-8000-000000001403', '01920000-0000-7000-8000-0000000014b2');

-- ---------------------------------------------------------------------------
-- b2 sincroniza sin zona: recibe solo lo suyo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table delta_b2 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], '{}'::jsonb, 1000) as d;
select is((select jsonb_path_query_array(d, '$.rows.ubicacion[*].numero') from delta_b2), '["1"]'::jsonb,
          'sin zona, b2 recibe solo la casa que registró');
select ok((select d -> 'watermark' ? 'house_status' and d -> 'watermark' ? 'espacio' from delta_b2),
          'y su watermark avanzó en las tres tablas');

-- ---------------------------------------------------------------------------
-- El coordinador le asigna Z2: el delta siguiente trae las casas de Z2 con su estado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b2',
                                '01920000-0000-7000-8000-0000000014d2') $$,
  'el coordinador le asigna Z2 a b2');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table delta_b2_rota as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from delta_b2), 1000) as d;
select is(
  (select jsonb_path_query_array(d, '$.rows.ubicacion[*].numero') from delta_b2_rota),
  '["100", "200"]'::jsonb,
  'el delta siguiente trae las casas de Z2, aunque se cargaron antes de su último pull');
select ok(
  (select jsonb_path_exists(d, '$.rows.ubicacion[*] ? (@.numero == "200" && @.zona_id == "01920000-0000-7000-8000-0000000014d2")')
     from delta_b2_rota),
  'u2 (de una campaña que ya terminó) pasa a Z2 al republicarse, y así la ve');
select is(
  (select jsonb_path_query_array(d, '$.rows.house_status[*].color') from delta_b2_rota),
  '["COBRANZA_PENDIENTE"]'::jsonb,
  'y el estado de cada casa (house_status)');
select is(
  (select jsonb_path_query_array(d, '$.rows.espacio[*].id') from delta_b2_rota),
  '["01920000-0000-7000-8000-000000001411"]'::jsonb,
  'y sus espacios');

-- b1 (Z1) no recibe nada de esto.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
select is(
  (select coalesce(jsonb_array_length(sync.pull(array['ubicacion'], '{}'::jsonb, 1000) -> 'rows' -> 'ubicacion'), 0)),
  0,
  'el de otra zona no recibe las casas de Z2');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table delta_b2, delta_b2_rota;
delete from public.espacio where ubicacion_id in (select id from public.ubicacion where ciudad_id = '01920000-0000-7000-8000-0000000014c1');
delete from public.house_status where ubicacion_id in (select id from public.ubicacion where ciudad_id = '01920000-0000-7000-8000-0000000014c1');
delete from public.ubicacion where ciudad_id = '01920000-0000-7000-8000-0000000014c1';
delete from public.campania_colportor where campania_id in ('01920000-0000-7000-8000-0000000014e0', '01920000-0000-7000-8000-0000000014e1');
delete from public.zona where campania_ciudad_id in ('01920000-0000-7000-8000-0000000014f0', '01920000-0000-7000-8000-0000000014f1');
delete from public.campania_ciudad where id in ('01920000-0000-7000-8000-0000000014f0', '01920000-0000-7000-8000-0000000014f1');
delete from public.campania where id in ('01920000-0000-7000-8000-0000000014e0', '01920000-0000-7000-8000-0000000014e1');
delete from public.ciudad where id = '01920000-0000-7000-8000-0000000014c1';
delete from public.pais where id = '01920000-0000-7000-8000-0000000014c0';
delete from public.usuario_rol where usuario_id = '01920000-0000-7000-8000-0000000014a1';
delete from auth.users where id in ('01920000-0000-7000-8000-0000000014a1', '01920000-0000-7000-8000-0000000014b1', '01920000-0000-7000-8000-0000000014b2');

select * from finish();
