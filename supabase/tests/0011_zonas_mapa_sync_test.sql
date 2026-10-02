-- pgTAP · migraciones 0008 y 0013 — el mapa de la campaña en el delta (sync.pull): el de las
-- campañas en curso o por empezar (S56 y decisión del 30/09), no el de las terminadas, y completo
-- cuando cambian las campañas que ve (huella). Las casas, con la misma regla (decisión del 02/10).
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
  ('01920000-0000-7000-8000-0000000011e2', 'Otra sync',   'PERMANENTE', current_date - 10),
  ('01920000-0000-7000-8000-0000000011e3', 'Futura sync', 'PERMANENTE', current_date + 30);
-- El mapa de la campaña futura se prepara ANTES que el resto, cada tabla en su propia
-- sentencia: así sus filas quedan con un (xmin_w, id) menor que el watermark de b1 (sección 3).
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000011f3', '01920000-0000-7000-8000-0000000011e3', '01920000-0000-7000-8000-0000000011c1');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011c1'),
  ('01920000-0000-7000-8000-0000000011f2', '01920000-0000-7000-8000-0000000011e2', '01920000-0000-7000-8000-0000000011c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000011d4', 'Futura sync', '01920000-0000-7000-8000-0000000011f3', 'ESQUINAS',
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.91]]]}');
insert into public.zona_vertice (id, zona_id, orden, lat, lon) values
  ('01920000-0000-7000-8000-0000000011a4', '01920000-0000-7000-8000-0000000011d4', 1, -34.91, -56.17),
  ('01920000-0000-7000-8000-0000000011a5', '01920000-0000-7000-8000-0000000011d4', 2, -34.91, -56.16),
  ('01920000-0000-7000-8000-0000000011a6', '01920000-0000-7000-8000-0000000011d4', 3, -34.90, -56.16);
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
-- 3. Una campaña por empezar cuyo mapa se preparó antes de su último pull (0013, decisión del
--    30/09): al inscribirse, el pull siguiente la trae completa aunque sus filas tengan un xmin_w
--    menor que su watermark (cambió la huella de sus campañas). El día que empieza no cambia
--    nada: ya la tenía.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

-- Los ids (o nombres, u órdenes) de una entidad en la respuesta de un pull, como texto.
create or replace function pg_temp.col(p_delta jsonb, p_entidad text, p_col text) returns text[]
language sql as $$
  select coalesce(array_agg(e ->> p_col order by e ->> p_col), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
create temp table delta_b1_antes as
select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], '{}'::jsonb, 1000) as d;
select ok(
  (select not jsonb_path_exists(d, '$.rows.zona[*] ? (@.nombre == "Futura sync")') from delta_b1_antes),
  'antes de inscribirse no recibe el mapa de la campaña futura');
select is((select d -> 'watermark' -> 'zona' ->> 'area' from delta_b1_antes) is not null, true,
          'el watermark del mapa lleva la huella de sus campañas');
select is(
  (select d -> 'rows' from (select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], d -> 'watermark', 1000) as d
                              from delta_b1_antes) x),
  '{}'::jsonb, 'sin cambios, el pull siguiente no trae nada (con la huella guardada no vuelve a bajar completo)');

select pg_temp.como_servidor();
insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000011e3', '01920000-0000-7000-8000-0000000011b1');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
create temp table delta_b1_inscripto as
select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], (select d -> 'watermark' from delta_b1_antes), 1000) as d;
select isnt((select d -> 'watermark' -> 'zona' ->> 'area' from delta_b1_inscripto),
            (select d -> 'watermark' -> 'zona' ->> 'area' from delta_b1_antes),
            'inscripto en una campaña por empezar, cambia la huella de sus campañas');
select is(pg_temp.col(d, 'campania_ciudad', 'id'),
          array['01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011f3'],
          'y el pull siguiente trae completo el mapa: la ciudad de la campaña por empezar (cargada antes) y la de Verano')
  from delta_b1_inscripto;
select is(pg_temp.col(d, 'zona', 'nombre'), array['Esquinas sync', 'Futura sync', 'Radial sync'],
          'con las zonas de las dos campañas') from delta_b1_inscripto;
select is(pg_temp.col(d, 'zona_vertice', 'id'),
          array['01920000-0000-7000-8000-0000000011a1', '01920000-0000-7000-8000-0000000011a2', '01920000-0000-7000-8000-0000000011a3',
                '01920000-0000-7000-8000-0000000011a4', '01920000-0000-7000-8000-0000000011a5', '01920000-0000-7000-8000-0000000011a6'],
          'y sus esquinas') from delta_b1_inscripto;

-- La campaña empieza: ya tenía el mapa, no vuelve a bajar.
select pg_temp.como_servidor();
update public.campania set fecha_inicio = current_date - 1 where id = '01920000-0000-7000-8000-0000000011e3';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
create temp table delta_b1_empieza as
select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], (select d -> 'watermark' from delta_b1_inscripto), 1000) as d;
select is((select d -> 'watermark' -> 'zona' ->> 'area' from delta_b1_empieza),
          (select d -> 'watermark' -> 'zona' ->> 'area' from delta_b1_inscripto),
          'cuando la campaña empieza, la huella de sus campañas no cambia');
select is((select d -> 'rows' from delta_b1_empieza), '{}'::jsonb, 'y el mapa no vuelve a bajar');

-- Otro inscripto en Verano no vuelve a bajar nada: inscribir a b1 ya no republica el mapa.
select pg_temp.como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000011b3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'mapa-sync-b3@example.com', 'x', now(), now());
insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011b3');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b3');
create temp table delta_b3 as
select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], '{}'::jsonb, 1000) as d;
select pg_temp.como_servidor();
insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011b2');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b3');
select is(
  (select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], d -> 'watermark', 1000) -> 'rows' from delta_b3),
  '{}'::jsonb, 'los demás inscriptos de la campaña no vuelven a bajar el mapa cuando se inscribe otro');

-- Baja y reactivación de la inscripción (solo por el camino de servidor: con JWT, 0005 no
-- deja reactivar).
select pg_temp.como_servidor();
update public.campania_colportor set deleted_at = now()
 where campania_id = '01920000-0000-7000-8000-0000000011e3' and usuario_id = '01920000-0000-7000-8000-0000000011b1';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
create temp table delta_b1_baja as
select sync.pull(array['campania_ciudad', 'zona', 'zona_vertice'], (select d -> 'watermark' from delta_b1_empieza), 1000) as d;
select ok(not (pg_temp.col(d, 'zona', 'nombre') @> array['Futura sync']),
          'dada de baja la inscripción, el mapa de esa campaña deja de bajar (el que ya bajó queda: no hay borrados)')
  from delta_b1_baja;
select is(pg_temp.col(d, 'zona', 'nombre'), array['Esquinas sync', 'Radial sync'],
          'cambió la huella: baja completo lo que sigue viendo (Verano)') from delta_b1_baja;
select pg_temp.como_servidor();
update public.campania_colportor set deleted_at = null
 where campania_id = '01920000-0000-7000-8000-0000000011e3' and usuario_id = '01920000-0000-7000-8000-0000000011b1';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
create temp table delta_b1_reactiva as
select sync.pull(array['zona'], (select d -> 'watermark' from delta_b1_baja), 1000) as d;
select ok(pg_temp.col(d, 'zona', 'nombre') @> array['Futura sync'],
          'al reactivar la inscripción, el pull siguiente vuelve a traer el mapa de la campaña') from delta_b1_reactiva;

-- La campaña termina: su mapa deja de bajar.
select pg_temp.como_servidor();
update public.campania set fecha_inicio = current_date - 20, fecha_fin = current_date - 1
 where id = '01920000-0000-7000-8000-0000000011e3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b1');
select is(pg_temp.col(sync.pull(array['zona'], d -> 'watermark', 1000), 'zona', 'nombre'),
          array['Esquinas sync', 'Radial sync'],
          'terminada la campaña, su mapa deja de bajar (S56); baja completo lo que sigue viendo') from delta_b1_reactiva;

-- ---------------------------------------------------------------------------
-- 4. Las casas, con la misma regla que el mapa (0013, decisión del 02/10): inscripta en una
--    campaña por empezar, con o sin zona, baja también las casas de su ciudad antes del primer día
--    (toda la ciudad de su zona, 0023). En otra ciudad (c2), para no mezclarse con Verano.
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000011' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mapa-sync-' || s || '@example.com', 'x', now(), now()
  from unnest(array['b4','b5']) s;
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000011c2', 'Ciudad casas sync', '01920000-0000-7000-8000-0000000011c0', -34.80, -56.00);
insert into public.campania (id, nombre, tipo, fecha_inicio) values
  ('01920000-0000-7000-8000-0000000011e4', 'Futura casas sync', 'PERMANENTE', current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000011f4', '01920000-0000-7000-8000-0000000011e4', '01920000-0000-7000-8000-0000000011c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000011d5', 'Casas sync', '01920000-0000-7000-8000-0000000011f4', 'RADIAL', -34.80, -56.00, 300);
-- 91 en la zona; 92 en la ciudad, fuera de la zona; 93 en la otra ciudad (la de Verano).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001191', 'CASA', 'Casas sync', '1', -34.80, -56.00, '01920000-0000-7000-8000-0000000011c2'),
  ('01920000-0000-7000-8000-000000001192', 'CASA', 'Casas sync', '2', -34.82, -56.02, '01920000-0000-7000-8000-0000000011c2'),
  ('01920000-0000-7000-8000-000000001193', 'CASA', 'Casas sync', '3', -34.95, -56.30, '01920000-0000-7000-8000-0000000011c1');
-- b4 sin zona, b5 con la zona de la campaña por empezar.
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000011e4', '01920000-0000-7000-8000-0000000011b4', null),
  ('01920000-0000-7000-8000-0000000011e4', '01920000-0000-7000-8000-0000000011b5', '01920000-0000-7000-8000-0000000011d5');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b4');
select is(pg_temp.col(sync.pull(array['ubicacion'], '{}'::jsonb, 1000), 'ubicacion', 'id'),
          array['01920000-0000-7000-8000-000000001191', '01920000-0000-7000-8000-000000001192'],
          'b4 (por empezar, sin zona) baja las casas de la ciudad de esa campaña, y no las de otra');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b5');
create temp table delta_b5 as
select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select is(pg_temp.col(d, 'ubicacion', 'id'), array['01920000-0000-7000-8000-000000001191', '01920000-0000-7000-8000-000000001192'],
          'b5 (por empezar, con zona) baja antes del primer día toda la ciudad de su zona, no solo la zona') from delta_b5;

select pg_temp.como_servidor();
update public.campania set fecha_inicio = current_date - 1 where id = '01920000-0000-7000-8000-0000000011e4';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b5');
create temp table delta_b5_empieza as
select sync.pull(array['ubicacion'], (select d -> 'watermark' from delta_b5), 1000) as d;
select is((select d -> 'watermark' -> 'ubicacion' ->> 'area' from delta_b5_empieza),
          (select d -> 'watermark' -> 'ubicacion' ->> 'area' from delta_b5),
          'cuando la campaña empieza, la huella del área no cambia');
select is((select d -> 'rows' from delta_b5_empieza), '{}'::jsonb, 'y las casas no vuelven a bajar');

select pg_temp.como_servidor();
update public.campania set fecha_inicio = current_date - 20, fecha_fin = current_date - 1 where id = '01920000-0000-7000-8000-0000000011e4';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000011b5');
create temp table delta_b5_termina as
select sync.pull(array['ubicacion'], (select d -> 'watermark' from delta_b5_empieza), 1000) as d;
select isnt((select d -> 'watermark' -> 'ubicacion' ->> 'area' from delta_b5_termina),
            (select d -> 'watermark' -> 'ubicacion' ->> 'area' from delta_b5_empieza),
            'terminada la campaña, cambia la huella del área');
select is(pg_temp.col(d, 'ubicacion', 'id'), array[]::text[],
          'y no baja nada más de esa campaña (lo que ya bajó queda: no hay borrados)') from delta_b5_termina;

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claims', '', false);
select set_config('request.jwt.claim.sub', '', false);

drop table delta_b1, delta_b1_antes, delta_b1_inscripto, delta_b1_empieza, delta_b3, delta_b1_baja, delta_b1_reactiva,
           delta_b5, delta_b5_empieza, delta_b5_termina;
delete from public.ubicacion where id in ('01920000-0000-7000-8000-000000001191', '01920000-0000-7000-8000-000000001192', '01920000-0000-7000-8000-000000001193');
delete from public.campania_colportor where campania_id in ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011e2', '01920000-0000-7000-8000-0000000011e3', '01920000-0000-7000-8000-0000000011e4');
delete from public.zona_vertice where zona_id in ('01920000-0000-7000-8000-0000000011d1', '01920000-0000-7000-8000-0000000011d4');
delete from public.zona where campania_ciudad_id in ('01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011f2', '01920000-0000-7000-8000-0000000011f3', '01920000-0000-7000-8000-0000000011f4');
delete from public.campania_ciudad where id in ('01920000-0000-7000-8000-0000000011f1', '01920000-0000-7000-8000-0000000011f2', '01920000-0000-7000-8000-0000000011f3', '01920000-0000-7000-8000-0000000011f4');
delete from public.campania where id in ('01920000-0000-7000-8000-0000000011e1', '01920000-0000-7000-8000-0000000011e2', '01920000-0000-7000-8000-0000000011e3', '01920000-0000-7000-8000-0000000011e4');
delete from public.ciudad where id in ('01920000-0000-7000-8000-0000000011c1', '01920000-0000-7000-8000-0000000011c2');
delete from public.pais where id = '01920000-0000-7000-8000-0000000011c0';
delete from auth.users where id in ('01920000-0000-7000-8000-0000000011b1', '01920000-0000-7000-8000-0000000011b2',
                                    '01920000-0000-7000-8000-0000000011b3', '01920000-0000-7000-8000-0000000011b4', '01920000-0000-7000-8000-0000000011b5');

select * from finish();
