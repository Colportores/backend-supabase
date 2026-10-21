-- pgTAP · migración 0023 (backend-supabase#58): el pull baja siempre toda la ciudad de su zona.
--   1. lo que se fue (la rama «zona» del pull, y el alcance en el aviso de salida) y lo que quedó;
--   2. sync.area_del_pull(): las ciudades de trabajo y su huella (la fórmula que ya tenía «ciudad»),
--      para quien tiene zona, quien no la tiene y quien no tiene inscripción, y cómo cambia al
--      cambiarle la zona;
--   3. sync.ubicacion_movida sigue como en 0016: anota cada cambio de posición o de ciudad;
--   4. el alcance que mande un motor viejo no rompe el pull;
--   5. el watermark guarda la lista de ciudades, y solo una ciudad nueva reinicia la entidad
--      (area_reset): con watermarks armados a mano.
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
select has_column('sync', 'ubicacion_movida', 'lat', 'el registro de movimientos sigue guardando la posición de antes (lat), como en 0016');
select has_column('sync', 'ubicacion_movida', 'lon', 'y lon');
select has_column('sync', 'ubicacion_movida', 'ciudad_id', 'y la ciudad de antes');

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
-- 3. sync.ubicacion_movida sigue anotando cada cambio de posición o de ciudad (0016, sin cambios)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.ubicacion set lat = -34.905, lon = -56.205 where id = pg_temp.u('01');
select is((select array[count(*)::text, min(lat)::text, min(lon)::text, min(ciudad_id::text)]
             from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')),
          array['1', '-34.9', '-56.2', pg_temp.u('c1')::text],
          'corregir solo la posición anota la de antes y la ciudad (que no avise es cosa de out_of_area, que mira la ciudad: 0019)');
update public.ubicacion set ciudad_id = pg_temp.u('c3'), lat = -34.7, lon = -56.1 where id = pg_temp.u('01');
select is((select array[count(*)::text, min(lat)::text, min(lon)::text, min(ciudad_id::text)]
             from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')),
          array['1', '-34.9', '-56.2', pg_temp.u('c1')::text],
          'otro cambio en la misma transacción (ahora de ciudad): queda el primero, el que un teléfono pudo haber visto');
update public.ubicacion set calle = 'Rivera nueva' where id = pg_temp.u('02');
select is((select count(*)::int from sync.ubicacion_movida where ubicacion_id = pg_temp.u('02')), 0,
          'editar otra cosa de la casa no anota nada');

-- ---------------------------------------------------------------------------
-- 4. El alcance que mande un motor viejo se ignora
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
select lives_ok($$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, 'pais') $$,
                'un alcance que no es «zona» ni «ciudad» ya no se rechaza con 22023');
select lives_ok($$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, 'zona') $$, '«zona» sigue aceptándose');
select lives_ok($$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, null) $$, 'y null');

-- ---------------------------------------------------------------------------
-- 5. El watermark guarda la lista de ciudades: solo una ciudad nueva reinicia la entidad
-- ---------------------------------------------------------------------------
-- Dentro de una transacción el delta no sirve filas (nada de lo que se escribe acá está por debajo
-- del horizonte), pero sí se ve cuándo sale area_reset y qué lista queda guardada: el pull de un
-- watermark con `xid` avisa el reinicio. Qué filas bajan o no, con datos commiteados: 0014.
-- b2 (sin zona: c1 y c3), a quien se le va cambiando la zona.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table w_inicial on commit drop as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], '{}'::jsonb, 10) as d;
select is((select d -> 'watermark' -> 'ubicacion' -> 'ciudades' from w_inicial),
          jsonb_build_array(pg_temp.u('c1'), pg_temp.u('c3')),
          'el pull guarda en el watermark la lista de ciudades (b2, sin zona: c1 y c3)');
select ok((select d -> 'watermark' -> 'espacio' -> 'ciudades' = d -> 'watermark' -> 'ubicacion' -> 'ciudades'
                  and d -> 'watermark' -> 'house_status' -> 'ciudades' = d -> 'watermark' -> 'ubicacion' -> 'ciudades'
             from w_inicial),
          'la misma lista en el watermark de espacio y de house_status');
select is((select d -> 'watermark' -> 'ubicacion' ->> 'area' from w_inicial),
          md5('ciudad|' || pg_temp.u('c1') || ',' || pg_temp.u('c3')), 'junto a la huella de siempre');
select ok((select not (sync.pull(array['ubicacion', 'espacio', 'house_status'], d -> 'watermark', 10) ? 'area_reset')
             from w_inicial),
          'la misma lista: no hay area_reset');

-- Se achica: le dan una zona de c1 (c1 y c3 → c1). El delta sigue y se guarda la lista nueva.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d1')
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table w_achica on commit drop as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from w_inicial), 10) as d;
select ok((select not (d ? 'area_reset') from w_achica),
          'la lista se achica (c1 y c3 → c1): no hay area_reset, no se vuelve a bajar nada');
select is((select d -> 'watermark' -> 'ubicacion' -> 'ciudades' from w_achica), jsonb_build_array(pg_temp.u('c1')),
          'el watermark guarda la lista nueva (solo c1)');
select is((select d -> 'watermark' -> 'house_status' ->> 'area' from w_achica), md5('ciudad|' || pg_temp.u('c1')),
          'con la huella nueva');

-- De c1 y c3 a solo c3 (otra zona, desde el watermark inicial): también se achica.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d3')
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select pg_temp.actuar_como(pg_temp.u('b2'));
select ok((select not (sync.pull(array['ubicacion', 'espacio', 'house_status'], d -> 'watermark', 10) ? 'area_reset')
             from w_inicial),
          'de c1 y c3 a solo c3: sin area_reset');
-- Una ciudad que la lista guardada no tenía: de solo c1 a c3.
create temp table w_otra on commit drop as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from w_achica), 10) as d;
select is((select d -> 'area_reset' from w_otra), '["ubicacion", "espacio", "house_status"]'::jsonb,
          'de solo c1 a c3 (una ciudad que la lista guardada no tenía): las tres entidades arrancan de cero');
select is((select d -> 'watermark' -> 'ubicacion' -> 'ciudades' from w_otra), jsonb_build_array(pg_temp.u('c3')),
          'y el watermark guarda la lista nueva');

-- Se achicó y vuelve a crecer: sin zona otra vez (c1 → c1 y c3). c3 no está en la lista guardada.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table w_vuelve on commit drop as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from w_achica), 10) as d;
select is((select d -> 'area_reset' from w_vuelve), '["ubicacion", "espacio", "house_status"]'::jsonb,
          'la lista se achicó (c1) y vuelve a crecer (c1 y c3): c3 no está en la lista guardada, hay area_reset');
select is((select d -> 'watermark' -> 'ubicacion' -> 'ciudades' from w_vuelve),
          jsonb_build_array(pg_temp.u('c1'), pg_temp.u('c3')), 'y la lista guardada vuelve a ser la de ahora');
select ok((select not (sync.pull(array['ubicacion', 'espacio', 'house_status'], d -> 'watermark', 10) ? 'area_reset')
             from w_vuelve),
          'con el watermark nuevo no hay otro reinicio');

-- Un watermark sin lista (un teléfono de antes de 0023): se compara por la huella, como hasta hoy.
-- Con la huella de ahora (quien ya bajaba toda la ciudad): sin reinicio, y el watermark pasa a llevar la lista.
create temp table w_sin_lista on commit drop as
select jsonb_object_agg(e.k, e.v - 'ciudades') as wm
  from w_inicial, jsonb_each(d -> 'watermark') e (k, v);
select ok((select not (wm -> 'ubicacion' ? 'ciudades') and (wm -> 'ubicacion' ? 'xid') from w_sin_lista),
          'el watermark armado a mano no trae lista y sí cursor');
create temp table w_sin_lista_pull on commit drop as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select wm from w_sin_lista), 10) as d;
select ok((select not (d ? 'area_reset') from w_sin_lista_pull),
          'sin lista y con la huella de ahora (la de «ciudad»): no hay area_reset');
select is((select d -> 'watermark' -> 'ubicacion' -> 'ciudades' from w_sin_lista_pull),
          jsonb_build_array(pg_temp.u('c1'), pg_temp.u('c3')), 'y el watermark que sale ya lleva la lista');
-- Con la huella vieja de «zona»: un solo reinicio.
create temp table w_zona on commit drop as
select sync.pull(array['ubicacion', 'espacio', 'house_status'],
                 (select jsonb_object_agg(e.k, (e.v - 'ciudades') || jsonb_build_object('area', 'zona|viejo'))
                    from w_inicial, jsonb_each(d -> 'watermark') e (k, v)), 10) as d;
select is((select d -> 'area_reset' from w_zona), '["ubicacion", "espacio", "house_status"]'::jsonb,
          'sin lista y con la huella vieja de «zona»: las tres entidades arrancan de cero');
select ok((select not (sync.pull(array['ubicacion', 'espacio', 'house_status'], d -> 'watermark', 10) ? 'area_reset')
             from w_zona),
          'una sola vez: con el watermark nuevo, que ya lleva la lista, no hay otro reinicio');

-- Una lista rara no rompe el pull: lo que no es una lista cuenta como ausente (se mira la huella)...
select ok((select not (sync.pull(array['ubicacion'],
                                 jsonb_build_object('ubicacion', (d -> 'watermark' -> 'ubicacion') || jsonb_build_object('ciudades', 'x')),
                                 10) ? 'area_reset')
             from w_inicial),
          'una «lista» que no es una lista cuenta como ausente: la huella coincide, sin area_reset ni error');
-- ...y un elemento que no es un id es una ciudad que la lista no tenía: baja de más, nunca de menos.
select is((select sync.pull(array['ubicacion'],
                            jsonb_build_object('ubicacion', (d -> 'watermark' -> 'ubicacion')
                                                            || jsonb_build_object('ciudades', jsonb_build_array('no-es-un-id'))),
                            10) -> 'area_reset'
             from w_inicial),
          '["ubicacion"]'::jsonb, 'una lista con un elemento que no es un id: area_reset, sin error');

-- Sin inscripción (b5): lista vacía; que la lista pase de una ciudad a ninguna es achicarse.
select pg_temp.actuar_como(pg_temp.u('b5'));
create temp table w_b5 on commit drop as
select sync.pull(array['ubicacion'], '{}'::jsonb, 10) as d;
select is((select d -> 'watermark' -> 'ubicacion' -> 'ciudades' from w_b5), '[]'::jsonb,
          'sin inscripción: la lista de ciudades es vacía');
select ok((select not (sync.pull(array['ubicacion'], d -> 'watermark', 10) ? 'area_reset') from w_b5),
          'y el pull siguiente no reinicia');
select ok((select not (sync.pull(array['ubicacion'],
                                 jsonb_build_object('ubicacion', (d -> 'watermark' -> 'ubicacion')
                                                                 || jsonb_build_object('ciudades', jsonb_build_array(pg_temp.u('c1')))),
                                 10) ? 'area_reset')
             from w_b5),
          'de una ciudad a ninguna (le dieron de baja): la lista se achica, sin area_reset');

select * from finish();
rollback;
