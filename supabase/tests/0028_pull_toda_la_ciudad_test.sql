-- pgTAP · migración 0023 (backend-supabase#58): el pull baja siempre toda la ciudad de su zona.
--   1. lo que se fue (la rama «zona» del pull, y el alcance en el aviso de salida) y lo que quedó;
--   2. sync.area_del_pull(): las ciudades de trabajo y su huella (la fórmula que ya tenía «ciudad»),
--      para quien tiene zona, quien no la tiene y quien no tiene inscripción, y cómo cambia al
--      cambiarle la zona;
--   3. sync.ubicacion_movida solo anota los cambios de ciudad;
--   4. el alcance que mande un motor viejo no rompe el pull.
-- Qué baja y qué se avisa, con datos de verdad: 0014 y 0019 (no van en transacción). Acá, lo que se
-- puede mirar adentro de una.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000028' || p)::uuid;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures. Verano (e1) en c1 (zonas Z1 y Z2) y en c3 (zona Z3).
-- b1: Verano, Z1. b2: Verano, sin zona. b5: sin inscripción.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'ciudad-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b5']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais toda la ciudad', 'ZT');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad uno', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c3'), 'Ciudad tres', pg_temp.u('c0'), -34.7, -56.1);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'Verano', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f3'), pg_temp.u('e1'), pg_temp.u('c3'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  (pg_temp.u('d1'), 'Z1', pg_temp.u('f1'), 'RADIAL', -34.90, -56.20, 300),
  (pg_temp.u('d2'), 'Z2', pg_temp.u('f1'), 'RADIAL', -34.95, -56.25, 300),
  (pg_temp.u('d3'), 'Z3', pg_temp.u('f3'), 'RADIAL', -34.70, -56.10, 300);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1')),
  (pg_temp.u('e1'), pg_temp.u('b2'), null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  (pg_temp.u('01'), 'CASA', 'Rivera', '1', -34.90, -56.20, pg_temp.u('c1')),
  (pg_temp.u('02'), 'CASA', 'Rivera', '2', -34.91, -56.21, pg_temp.u('c1'));

-- ---------------------------------------------------------------------------
-- 1. Lo que se fue y lo que quedó
-- ---------------------------------------------------------------------------
select hasnt_function('public', 'ubicaciones_de_mi_zona', 'la rama «zona» del pull se fue: ubicaciones_de_mi_zona() ya no existe');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'sync' and p.proname = 'area_del_pull'), 1,
          'una sola area_del_pull (la de un parámetro por alcance se fue)');
select is((select pronargs::int from pg_proc where oid = 'sync.area_del_pull()'::regprocedure), 0,
          'y no recibe alcance');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'ubicaciones_que_salieron'), 1,
          'una sola ubicaciones_que_salieron');
select is((select pronargs::int from pg_proc where oid = 'public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)'::regprocedure), 4,
          'sin el alcance: solo el tramo del cursor');
select ok(obj_description('sync.area_del_pull()'::regprocedure, 'pg_proc') is not null
          and obj_description('public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)'::regprocedure, 'pg_proc') is not null
          and obj_description('sync.pull(text[], jsonb, integer, uuid, text)'::regprocedure, 'pg_proc') is not null
          and obj_description('sync.ubicacion_movida'::regclass, 'pg_class') is not null,
          'lo que cambia lleva su comment on');
select ok(has_function_privilege('authenticated', 'sync.area_del_pull()', 'execute'),
          'authenticated ejecuta area_del_pull (sync.pull es INVOKER)');
select ok(not has_function_privilege('anon', 'sync.area_del_pull()', 'execute'), 'anon no');
select ok(pg_get_function_arguments('sync.pull(text[], jsonb, integer, uuid, text)'::regprocedure) like '%p_alcance text DEFAULT NULL%',
          'sync.pull conserva p_alcance (un motor viejo lo sigue mandando), sin valor por defecto');
select hasnt_column('sync', 'ubicacion_movida', 'lat', 'el registro de movimientos ya no guarda la posición de antes (lat)');
select hasnt_column('sync', 'ubicacion_movida', 'lon', 'ni lon');
select has_column('sync', 'ubicacion_movida', 'ciudad_id', 'solo la ciudad de antes');

-- ---------------------------------------------------------------------------
-- 2. area_del_pull(): las ciudades de trabajo y su huella
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select results_eq($$ select ciudades, huella from sync.area_del_pull() $$,
                  $$ values (array['01920000-0000-7000-8000-0000000028c1']::uuid[],
                             md5('ciudad|01920000-0000-7000-8000-0000000028c1')) $$,
                  'b1 (Z1, en c1): la ciudad de su zona, con la huella que «ciudad» ya tenía');
select pg_temp.actuar_como(pg_temp.u('b2'));
select results_eq($$ select ciudades, huella from sync.area_del_pull() $$,
                  $$ values (array['01920000-0000-7000-8000-0000000028c1', '01920000-0000-7000-8000-0000000028c3']::uuid[],
                             md5('ciudad|01920000-0000-7000-8000-0000000028c1,01920000-0000-7000-8000-0000000028c3')) $$,
                  'b2, sin zona: todas las ciudades de su campaña');
select pg_temp.actuar_como(pg_temp.u('b5'));
select results_eq($$ select ciudades, huella from sync.area_del_pull() $$,
                  $$ values (array[]::uuid[], md5('ciudad|')) $$,
                  'b5, sin inscripción: ninguna ciudad (solo baja lo que registró él)');

-- Cambiarle la zona dentro de la misma ciudad no cambia la huella; a otra ciudad, sí.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table huella_z1 on commit drop as select huella from sync.area_del_pull();
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d2')
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select huella from sync.area_del_pull()), (select huella from huella_z1),
          'otra zona de la misma ciudad: la misma huella (no baja nada)');
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d3')
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select results_eq($$ select ciudades, huella from sync.area_del_pull() $$,
                  $$ values (array['01920000-0000-7000-8000-0000000028c3']::uuid[],
                             md5('ciudad|01920000-0000-7000-8000-0000000028c3')) $$,
                  'una zona de otra ciudad: su ciudad pasa a ser esa, con otra huella');
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select array_length(ciudades, 1) from sync.area_del_pull()), 2,
          'sin zona otra vez: las dos ciudades de la campaña');

-- ---------------------------------------------------------------------------
-- 3. sync.ubicacion_movida solo anota los cambios de ciudad
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.ubicacion set lat = -34.905, lon = -56.205 where id = pg_temp.u('01');
select is((select count(*)::int from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')), 0,
          'corregir solo la posición no anota nada: la casa sigue en su ciudad');
update public.ubicacion set ciudad_id = pg_temp.u('c3'), lat = -34.7, lon = -56.1 where id = pg_temp.u('01');
select is((select array_agg(ciudad_id) from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')),
          array[pg_temp.u('c1')], 'cambiar de ciudad anota la de antes (también si cambia la posición)');
update public.ubicacion set ciudad_id = pg_temp.u('c1') where id = pg_temp.u('01');
select is((select array_agg(ciudad_id) from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')),
          array[pg_temp.u('c1')], 'otro cambio en la misma transacción: queda la primera, la que un teléfono pudo haber visto');
update public.ubicacion set calle = 'Rivera nueva' where id = pg_temp.u('02');
select is((select count(*)::int from sync.ubicacion_movida where ubicacion_id = pg_temp.u('02')), 0,
          'editar otra cosa de la casa tampoco');

-- ---------------------------------------------------------------------------
-- 4. El alcance que mande un motor viejo se ignora
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
select lives_ok($$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, 'pais') $$,
                'un alcance que no es «zona» ni «ciudad» ya no se rechaza con 22023');
select lives_ok($$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, 'zona') $$, '«zona» sigue aceptándose');
select lives_ok($$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, null) $$, 'y null');

select * from finish();
rollback;
