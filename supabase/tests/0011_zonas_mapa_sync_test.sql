-- pgTAP · migración 0008 — el mapa de la campaña en el delta (sync.pull).
--
-- Como 0004_sync_delta_test, NO va en una transacción: el delta solo sirve lo que quedó por
-- debajo del horizonte del snapshot, así que las filas tienen que estar commiteadas. Limpia
-- sus filas al final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres): b1 inscripto en Verano, b2 inscripto en Otra.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000011' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mapa-sync-' || s || '@example.com', 'x', now(), now()
  from unnest(array['b1','b2']) s;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000011c0', 'Pais mapa sync', 'ZS');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000011c1', 'Ciudad mapa sync', '01920000-0000-7000-8000-0000000011c0', -34.9, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio) values
  ('01920000-0000-7000-8000-0000000011e1', 'Verano sync', 'PERMANENTE', current_date - 10),
  ('01920000-0000-7000-8000-0000000011e2', 'Otra sync',   'PERMANENTE', current_date - 10);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011c1'),
  ('01920000-0000-7000-8000-0000000011f2', '01920000-0000-7000-8000-0000000011e2', '01920000-0000-7000-8000-0000000011c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000011d1', 'Esquinas sync', '01920000-0000-7000-8000-0000000011f1', 'ESQUINAS',
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.91]]]}');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000011d2', 'Radial sync', '01920000-0000-7000-8000-0000000011f1', 'RADIAL', -34.95, -56.16, 300),
  ('01920000-0000-7000-8000-0000000011d3', 'De otra sync', '01920000-0000-7000-8000-0000000011f2', 'RADIAL', -34.95, -56.16, 300);
insert into public.zona_vertice (id, zona_id, orden, lat, lon) values
  ('01920000-0000-7000-8000-0000000011a1', '01920000-0000-7000-8000-0000000011d1', 1, -34.91, -56.17),
  ('01920000-0000-7000-8000-0000000011a2', '01920000-0000-7000-8000-0000000011d1', 2, -34.91, -56.16),
  ('01920000-0000-7000-8000-0000000011a3', '01920000-0000-7000-8000-0000000011d1', 3, -34.90, -56.16);
insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011b1'),
  ('01920000-0000-7000-8000-0000000011e2', '01920000-0000-7000-8000-0000000011b2');

-- ---------------------------------------------------------------------------
-- 1. El registro
-- ---------------------------------------------------------------------------
select ok((select not permite_push from sync.entidad where nombre = e), e || ' es pull (solo lectura)')
  from unnest(array['campania_ciudad', 'zona', 'zona_vertice']) e;

-- ---------------------------------------------------------------------------
-- 2. El delta de b1 trae el mapa de su campaña, y no el de otra
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');

create temp table delta_b1 as
select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], '{}'::jsonb, 1000) as d;

select is(
  (select jsonb_path_query_array(d, '$.rows.campania_ciudad[*].id') from delta_b1),
  '["01920000-0000-7000-8000-0000000011f1"]'::jsonb,
  'el delta trae la ciudad de su campaña y no la de otra');
select is(
  (select jsonb_path_query_array(d, '$.rows.zona[*].nombre') from delta_b1),
  '["Esquinas sync", "Radial sync"]'::jsonb,
  'el delta trae todas las zonas de su campaña (no solo la suya) y no las de otra');
select is(
  (select jsonb_path_query_array(d, '$.rows.zona_vertice[*].orden') from delta_b1),
  '[1, 2, 3]'::jsonb,
  'el delta trae las esquinas de las zonas de su campaña');
select ok(
  (select jsonb_path_exists(d, '$.rows.zona[*] ? (@.nombre == "Radial sync" && @.tipo_forma == "RADIAL" && @.radio_m == 300 && @.poligono_geojson.type == "Polygon")')
     from delta_b1),
  'la zona viaja con su forma (tipo, radio y el polígono calculado)');
select ok(
  (select not jsonb_path_exists(d, '$.rows.zona[*].xmin_w') from delta_b1),
  'xmin_w no viaja');

-- Un cambio de forma sale en el delta siguiente.
reset role;
update public.zona set radio_m = 350 where id = '01920000-0000-7000-8000-0000000011d2';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
select is(
  (select jsonb_path_query_array(sync.pull(array['zona'], d -> 'watermark', 1000), '$.rows.zona[*].radio_m')
     from delta_b1),
  '[350]'::jsonb,
  'un cambio de forma sale en el delta siguiente (solo esa zona)');

-- b2 ve solo lo de Otra.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b2');
select is(
  (select jsonb_path_query_array(sync.pull(array['zona', 'zona_vertice'], '{}'::jsonb, 1000), '$.rows.zona[*].nombre')),
  '["De otra sync"]'::jsonb,
  'el inscripto en otra campaña recibe solo las zonas de esa campaña');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', false);
select set_config('request.jwt.claim.sub', '', false);

drop table delta_b1;
delete from public.campania_colportor where campania_id in ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011e2');
delete from public.zona_vertice where zona_id = '01920000-0000-7000-8000-0000000011d1';
delete from public.zona where campania_ciudad_id in ('01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011f2');
delete from public.campania_ciudad where id in ('01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011f2');
delete from public.campania where id in ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011e2');
delete from public.ciudad where id = '01920000-0000-7000-8000-0000000011c1';
delete from public.pais where id = '01920000-0000-7000-8000-0000000011c0';
delete from auth.users where id in ('01920000-0000-7000-8000-0000000011b1', '01920000-0000-7000-8000-0000000011b2');

select * from finish();
