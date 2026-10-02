-- pgTAP · migraciones 0011 y 0023 — qué ubicaciones baja cada colportor (HU-SYNC-011,
-- backend-supabase#32 y #58): toda la ciudad de su zona (sin zona, todas las de su campaña), más
-- las propias, sin elección; la ciudad completa cuando cambia de ciudad, y nada cuando cambia de
-- zona dentro de la misma; y los espacios y el estado de una casa que llega a su ciudad.
--
-- Como 0004 y 0011, NO va en una transacción: el delta solo sirve filas commiteadas. Limpia al
-- final.

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

-- Los ids de una entidad en la respuesta de un pull, ordenados.
create or replace function pg_temp.ids(p_delta jsonb, p_entidad text, p_pk text default 'id') returns text[]
language sql as $$
  select coalesce(array_agg(e ->> p_pk order by e ->> p_pk), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;

-- La huella del área que el pull guardó en el watermark de ubicacion.
create or replace function pg_temp.huella(p_delta jsonb) returns text
language sql as $$
  select p_delta -> 'watermark' -> 'ubicacion' ->> 'area';
$$;

-- Los ids de una casa, con el prefijo de este test (140 + un dígito hexadecimal).
create or replace function pg_temp.u(p_sufijo text) returns text
language sql as $$
  select '01920000-0000-7000-8000-0000000014' || p_sufijo;
$$;

create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;

-- Guarda Z2 (del coordinador a1) con otro rectángulo o nombre.
create or replace function pg_temp.guardar_z2(p_nombre text, x0 numeric, x1 numeric, p_previa boolean default false)
returns jsonb language sql as $$
  select public.guardar_zona(
    p_campania_ciudad_id => '01920000-0000-7000-8000-0000000014f1', p_nombre => p_nombre, p_tipo_forma => 'ESQUINAS',
    p_zona_id => '01920000-0000-7000-8000-0000000014d2', p_vista_previa => p_previa,
    p_vertices => jsonb_build_array(
      jsonb_build_object('orden', 1, 'lon', x0, 'lat', -34.92), jsonb_build_object('orden', 2, 'lon', x1, 'lat', -34.92),
      jsonb_build_object('orden', 3, 'lon', x1, 'lat', -34.91), jsonb_build_object('orden', 4, 'lon', x0, 'lat', -34.91)),
    p_poligono_geojson => pg_temp.rect(x0, -34.92, x1, -34.91));
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Verano (e1, coordina a1) en c1 (Z1 y Z2) y en c3 (Canelones, con Z3);
-- Otra (e2) en c2.
-- b1: Verano, Z1. b2: Verano, sin zona. b3: Otra, sin zona. b4: Verano, sin zona.
-- b5: sin inscripción.
--   1401 en Z2, con estado y un espacio          1402 en c1, al oeste de Z2
--   1403 en c2                                   1404 en Z1          1405 en Z1, dada de baja
--   1406 de b2, en c1 fuera de toda zona, con estado y un espacio
--   1407 en c1 fuera de toda zona, con estado y un espacio
--   1409 en c3 (la otra ciudad de Verano), con estado y un espacio (después se muda a c1)
--   140a de b1, en c1                            140b en c3, con estado
--   140c de b5, en c1 (b5 no tiene inscripción)
-- Todas se cargan antes del primer pull de cada colportor.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000014' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'alcance-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4','b5']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000014a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000014c0', 'Pais alcance', 'ZR');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000014c1', 'Ciudad alcance', '01920000-0000-7000-8000-0000000014c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000014c2', 'Otra alcance',   '01920000-0000-7000-8000-0000000014c0', -34.8, -56.0),
  ('01920000-0000-7000-8000-0000000014c3', 'Canelones alcance', '01920000-0000-7000-8000-0000000014c0', -34.7, -56.1);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000014e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000014a1'),
  ('01920000-0000-7000-8000-0000000014e2', 'Otra',   'PERMANENTE', current_date - 10, null,              null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014c1'),
  ('01920000-0000-7000-8000-0000000014f2', '01920000-0000-7000-8000-0000000014e2', '01920000-0000-7000-8000-0000000014c2'),
  ('01920000-0000-7000-8000-0000000014f3', '01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014c3');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000014d1', 'Z1', '01920000-0000-7000-8000-0000000014f1', 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91)),
  ('01920000-0000-7000-8000-0000000014d2', 'Z2', '01920000-0000-7000-8000-0000000014f1', 'ESQUINAS', pg_temp.rect(-56.21, -34.92, -56.20, -34.91)),
  ('01920000-0000-7000-8000-0000000014d3', 'Z3', '01920000-0000-7000-8000-0000000014f3', 'ESQUINAS', pg_temp.rect(-56.11, -34.71, -56.09, -34.69));
insert into public.zona_vertice (zona_id, orden, lat, lon)
select '01920000-0000-7000-8000-0000000014d2', o, y, x
  from (values (1, -34.92, -56.21), (2, -34.92, -56.20), (3, -34.91, -56.20), (4, -34.91, -56.21)) v(o, y, x);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b1', '01920000-0000-7000-8000-0000000014d1'),
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b2', null),
  ('01920000-0000-7000-8000-0000000014e2', '01920000-0000-7000-8000-0000000014b3', null),
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b4', null);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000001401', 'CASA', 'Rivera', '1', -34.915, -56.205, '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001402', 'CASA', 'Rivera', '2', -34.915, -56.215, '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001403', 'CASA', 'Rivera', '3', -34.8,   -56.0,   '01920000-0000-7000-8000-0000000014c2', null, null),
  ('01920000-0000-7000-8000-000000001404', 'CASA', 'Rivera', '4', -34.915, -56.185, '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001405', 'CASA', 'Rivera', '5', -34.915, -56.186, '01920000-0000-7000-8000-0000000014c1', null, now()),
  ('01920000-0000-7000-8000-000000001406', 'CASA', 'Propia', '6', -34.95, -56.25,   '01920000-0000-7000-8000-0000000014c1',
   '01920000-0000-7000-8000-0000000014b2', null),
  ('01920000-0000-7000-8000-000000001407', 'CASA', 'Rivera', '7', -34.95,  -56.30,  '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001409', 'CASA', 'Artigas', '9', -34.7,  -56.1,   '01920000-0000-7000-8000-0000000014c3', null, null),
  ('01920000-0000-7000-8000-00000000140a', 'CASA', 'Propia b1', '10', -34.93, -56.26, '01920000-0000-7000-8000-0000000014c1',
   '01920000-0000-7000-8000-0000000014b1', null),
  ('01920000-0000-7000-8000-00000000140b', 'CASA', 'Canelones', '11', -34.71, -56.11, '01920000-0000-7000-8000-0000000014c3', null, null),
  ('01920000-0000-7000-8000-00000000140c', 'CASA', 'Propia b5', '12', -34.97, -56.30, '01920000-0000-7000-8000-0000000014c1',
   '01920000-0000-7000-8000-0000000014b5', null);
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by) values
  ('01920000-0000-7000-8000-000000001401', -34.915, -56.205, 'CASA', 'COBRANZA_PENDIENTE', 2, null),
  ('01920000-0000-7000-8000-000000001406', -34.95,  -56.25,  'CASA', 'RECHAZO', 7, '01920000-0000-7000-8000-0000000014b2'),
  ('01920000-0000-7000-8000-000000001407', -34.95,  -56.30,  'CASA', 'SIN_CONTESTAR', 6, null),
  ('01920000-0000-7000-8000-000000001409', -34.7,   -56.1,   'CASA', 'RECHAZO', 7, null),
  ('01920000-0000-7000-8000-00000000140b', -34.71,  -56.11,  'CASA', 'SIN_CONTESTAR', 6, null);
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-000000001411', '01920000-0000-7000-8000-000000001401', null),
  ('01920000-0000-7000-8000-000000001416', '01920000-0000-7000-8000-000000001406', '01920000-0000-7000-8000-0000000014b2'),
  ('01920000-0000-7000-8000-000000001417', '01920000-0000-7000-8000-000000001407', null),
  ('01920000-0000-7000-8000-000000001419', '01920000-0000-7000-8000-000000001409', null);

-- ---------------------------------------------------------------------------
-- 1. Con zona: toda la ciudad de su zona, no solo el polígono (las bajas también)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array[pg_temp.u('01'), pg_temp.u('02'), pg_temp.u('04'), pg_temp.u('05'), pg_temp.u('06'), pg_temp.u('07'),
                pg_temp.u('0a'), pg_temp.u('0c')],
          'b1 (Z1, en c1) baja toda c1, no solo Z1: las de Z1 (la baja también, su tombstone), las de Z2, las de afuera '
          'de toda zona y las que cargó otro (también b5, que no tiene inscripción); ni las de otra campaña ni las de Canelones')
  from pull_b1;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'), array[pg_temp.u('01'), pg_temp.u('06'), pg_temp.u('07')],
          'con el estado de esas casas') from pull_b1;
select is(pg_temp.ids(d, 'espacio'), array[pg_temp.u('11'), pg_temp.u('16'), pg_temp.u('17')],
          'y sus espacios') from pull_b1;
select ok((select d -> 'watermark' -> 'ubicacion' ? 'area' from pull_b1),
          'el watermark de ubicacion lleva la huella del área');
select ok((select not (d ? 'area_reset') and not (d ? 'out_of_area') from pull_b1),
          'el primer pull no avisa nada');

-- ---------------------------------------------------------------------------
-- 2. Sin zona: todas las ciudades de su campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array[pg_temp.u('01'), pg_temp.u('02'), pg_temp.u('04'), pg_temp.u('05'), pg_temp.u('06'), pg_temp.u('07'),
                pg_temp.u('09'), pg_temp.u('0a'), pg_temp.u('0b'), pg_temp.u('0c')],
          'b2, sin zona, baja todas las ciudades de Verano (c1 y Canelones), con las que registró él; no las de otra campaña')
  from pull_b2;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'),
          array[pg_temp.u('01'), pg_temp.u('06'), pg_temp.u('07'), pg_temp.u('09'), pg_temp.u('0b')],
          'con su estado') from pull_b2;
select is(pg_temp.ids(d, 'espacio'), array[pg_temp.u('11'), pg_temp.u('16'), pg_temp.u('17'), pg_temp.u('19')],
          'y sus espacios') from pull_b2;

create temp table pull_b2_vacio as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2), 1000) as d;
select is((select d -> 'rows' from pull_b2_vacio), '{}'::jsonb, 'sin novedades, el pull siguiente no trae nada');
select ok((select not (d ? 'area_reset') and not (d ? 'out_of_area') from pull_b2_vacio), 'ni avisos');

-- ---------------------------------------------------------------------------
-- 3. Otra campaña y sin inscripción
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b3');
create temp table pull_b3 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('03')], 'b3 (Otra, en c2) baja solo c2') from pull_b3;
select is((select array_agg(k) from pull_b3, jsonb_object_keys(d -> 'rows') k), array['ubicacion'],
          'c2 no tiene espacios ni estados: no vienen en rows');
select ok((select d -> 'watermark' -> 'espacio' ->> 'area' = d -> 'watermark' -> 'ubicacion' ->> 'area' from pull_b3),
          'pero el watermark de espacio igual avanza y guarda la misma huella');
select is((select d -> 'watermark' -> 'espacio' ->> 'id' from pull_b3), '00000000-0000-0000-0000-000000000000',
          'con el cursor en el horizonte: el pull siguiente no vuelve a recorrer lo de abajo');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b5');
select is(pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000), 'ubicacion'), array[pg_temp.u('0c')],
          'b5, sin inscripción, no tiene ciudad: baja solo la casa que registró');

-- ---------------------------------------------------------------------------
-- 4. Una casa que llega a su ciudad trae sus espacios y su estado
-- ---------------------------------------------------------------------------
-- b2 (trabaja c1 y Canelones) corrige 1409: pasa de Canelones a c1, a una posición fuera de toda zona.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
select lives_ok(
  $$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000014c1', lat = -34.93, lon = -56.25
      where id = '01920000-0000-7000-8000-000000001409' $$,
  'b2 corrige una casa ajena y la pasa de Canelones a c1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1_mueve as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b1), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('09')], 'b1 baja la casa que llegó a c1, aunque no cae en Z1')
  from pull_b1_mueve;
select is(pg_temp.ids(d, 'espacio'), array[pg_temp.u('19')], 'y su espacio, aunque se cargó antes de su último pull')
  from pull_b1_mueve;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'), array[pg_temp.u('09')], 'y su estado') from pull_b1_mueve;
select ok((select not (d ? 'out_of_area') and not (d ? 'area_reset') from pull_b1_mueve), 'sin avisos');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_mueve as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2_vacio), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('09')], 'b2 recibe la edición de esa casa: sigue en su área') from pull_b2_mueve;
select ok((select not (d ? 'out_of_area') from pull_b2_mueve),
          'pasar de una ciudad suya a otra no es salir del área: no se avisa');

-- ---------------------------------------------------------------------------
-- 5. Le cambian la zona dentro de la misma ciudad: no baja nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b1',
                                '01920000-0000-7000-8000-0000000014d2') $$,
  'el coordinador le pasa a b1 de Z1 a Z2 (las dos en c1)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1_z2 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b1_mueve), 1000) as d;
select is((select d -> 'rows' from pull_b1_z2), '{}'::jsonb, 'otra zona de la misma ciudad: no baja nada');
select ok((select not (d ? 'area_reset') and not (d ? 'out_of_area') from pull_b1_z2),
          'ni area_reset: lo que ya tenía sigue siendo su área');
select is((select pg_temp.huella(d) from pull_b1_z2), (select pg_temp.huella(d) from pull_b1),
          'la huella del área es la misma que con Z1');

-- Renombrar o redibujar la zona tampoco: la zona es solo visual.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok($$ select pg_temp.guardar_z2('Z2 norte', -56.21, -56.20) $$, 'el coordinador le cambia el nombre a Z2');
select lives_ok($$ select pg_temp.guardar_z2('Z2 norte', -56.22, -56.20) $$, 'y la agranda al oeste');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1_redibujo as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b1_z2), 1000) as d;
select is((select d -> 'rows' from pull_b1_redibujo), '{}'::jsonb, 'cambiar el nombre o la forma de la zona no baja nada');
select ok((select not (d ? 'area_reset') from pull_b1_redibujo), 'ni area_reset');

-- ---------------------------------------------------------------------------
-- 6. Sin zona → una zona de c1: baja c1 completa; Canelones deja de actualizarse, sin borrar nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b2',
                                '01920000-0000-7000-8000-0000000014d2') $$,
  'el coordinador le asigna Z2 (en c1) a b2');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_z2 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2_mueve), 1000) as d;
select is(d -> 'area_reset', '["ubicacion", "house_status", "espacio"]'::jsonb,
          'cambió la ciudad de trabajo (c1 y Canelones → c1): las tres entidades arrancan de cero') from pull_b2_z2;
select is(pg_temp.ids(d, 'ubicacion'),
          array[pg_temp.u('01'), pg_temp.u('02'), pg_temp.u('04'), pg_temp.u('05'), pg_temp.u('06'), pg_temp.u('07'),
                pg_temp.u('09'), pg_temp.u('0a'), pg_temp.u('0c')],
          'baja c1 completa, con su watermark de antes: las casas cargadas antes de su último pull también')
  from pull_b2_z2;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'),
          array[pg_temp.u('01'), pg_temp.u('06'), pg_temp.u('07'), pg_temp.u('09')], 'con su estado') from pull_b2_z2;
select is(pg_temp.ids(d, 'espacio'), array[pg_temp.u('11'), pg_temp.u('16'), pg_temp.u('17'), pg_temp.u('19')],
          'y sus espacios') from pull_b2_z2;
select is(jsonb_path_query_array((select d from pull_b2_z2),
            '$.rows.*[*] ? (@.id == "01920000-0000-7000-8000-00000000140b" || @.ubicacion_id == "01920000-0000-7000-8000-00000000140b")'),
          '[]'::jsonb,
          'de la casa de Canelones no baja nada, ni un tombstone: el teléfono la conserva (R-UB12)');
select is((select count(*) from public.ubicacion where id = '01920000-0000-7000-8000-00000000140b'), 0::bigint,
          'la RLS sigue la misma regla: b2 ya no ve Canelones');
select pg_temp.como_servidor();
select is((select count(*)::integer from public.ubicacion where id = '01920000-0000-7000-8000-00000000140b' and deleted_at is null),
          1, 'y el servidor no la borró');

-- Canelones deja de actualizarse; c1 sigue al día.
update public.ubicacion set calle = 'Canelones nueva' where id = '01920000-0000-7000-8000-00000000140b';
update public.ubicacion set calle = 'Rivera dos' where id = '01920000-0000-7000-8000-000000001402';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_sigue as
select sync.pull(array['ubicacion'], (select d -> 'watermark' from pull_b2_z2), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('02')],
          'una edición en la ciudad vieja ya no le llega; la de su ciudad sí') from pull_b2_sigue;

-- ---------------------------------------------------------------------------
-- 7. Una zona de otra ciudad: baja esa ciudad completa y la vieja deja de actualizarse
-- ---------------------------------------------------------------------------
-- b4, sin zona: todas las ciudades de Verano. Le asignan Z3 (Canelones).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b4');
create temp table pull_b4 as
select sync.pull(array['ubicacion', 'house_status'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array[pg_temp.u('01'), pg_temp.u('02'), pg_temp.u('04'), pg_temp.u('05'), pg_temp.u('06'), pg_temp.u('07'),
                pg_temp.u('09'), pg_temp.u('0a'), pg_temp.u('0b'), pg_temp.u('0c')],
          'b4, sin zona, baja todas las ciudades de Verano (c1 y Canelones)') from pull_b4;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b4',
                                '01920000-0000-7000-8000-0000000014d3') $$,
  'el coordinador le asigna Z3 (en Canelones) a b4');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b4');
create temp table pull_b4_z3 as
select sync.pull(array['ubicacion', 'house_status'], (select d -> 'watermark' from pull_b4), 1000) as d;
select is(d -> 'area_reset', '["ubicacion", "house_status"]'::jsonb, 'con zona en Canelones, las dos entidades arrancan de cero')
  from pull_b4_z3;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('0b')],
          'y baja solo Canelones: nada de c1, que quedó en el teléfono como estaba') from pull_b4_z3;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'), array[pg_temp.u('0b')], 'con su estado') from pull_b4_z3;
select is((select count(*) from public.ubicacion where ciudad_id = '01920000-0000-7000-8000-0000000014c1'), 0::bigint,
          'la RLS sigue la misma regla: b4 ya no ve c1');

-- b1, con zona en c1: le pasan a Z3. Sus casas propias de c1 siguen bajando.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b1',
                                '01920000-0000-7000-8000-0000000014d3') $$,
  'el coordinador le pasa a b1 de Z2 (c1) a Z3 (Canelones)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1_z3 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b1_redibujo), 1000) as d;
select is(d -> 'area_reset', '["ubicacion", "house_status", "espacio"]'::jsonb, 'otra ciudad: las tres entidades arrancan de cero')
  from pull_b1_z3;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('0a'), pg_temp.u('0b')],
          'baja Canelones completa y, de la ciudad vieja, solo lo que registró él (siempre baja)') from pull_b1_z3;
select isnt((select pg_temp.huella(d) from pull_b1_z3), (select pg_temp.huella(d) from pull_b1_redibujo),
            'con otra huella');

select pg_temp.como_servidor();
update public.ubicacion set calle = 'Rivera uno' where id = '01920000-0000-7000-8000-000000001401';
update public.ubicacion set calle = 'Canelones dos' where id = '01920000-0000-7000-8000-00000000140b';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1_sigue as
select sync.pull(array['ubicacion'], (select d -> 'watermark' from pull_b1_z3), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array[pg_temp.u('0b')],
          'la ciudad vieja (c1) dejó de actualizarse; Canelones sí') from pull_b1_sigue;
select ok((select not (d ? 'out_of_area') from pull_b1_sigue),
          'y cambiar de zona no es «salir del área»: no se avisa nada de las casas de c1');

-- ---------------------------------------------------------------------------
-- 8. Paginado: la huella no reinicia la página siguiente
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pagina_1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 3) as d;
create temp table pagina_2 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pagina_1), 3) as d;
create temp table pagina_3 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pagina_2), 3) as d;
select is((select array[(d ->> 'has_more')::text, array_length(pg_temp.ids(d, 'ubicacion'), 1)::text] from pagina_1),
          array['true', '3'], 'página 1 de 3 filas: hay más');
select is((select array[(d ->> 'has_more')::text, array_length(pg_temp.ids(d, 'ubicacion'), 1)::text] from pagina_2),
          array['true', '3'], 'página 2: otras 3, y hay más');
select is((select array[(d ->> 'has_more')::text, array_length(pg_temp.ids(d, 'ubicacion'), 1)::text] from pagina_3),
          array['false', '3'], 'página 3: las 3 que faltan (9 en total: c1 completa)');
select is((select array_agg(i order by i) from pagina_1 p1, pagina_2 p2, pagina_3 p3,
             unnest(pg_temp.ids(p1.d, 'ubicacion') || pg_temp.ids(p2.d, 'ubicacion') || pg_temp.ids(p3.d, 'ubicacion')) i),
          (select pg_temp.ids(d, 'ubicacion') from pull_b2_z2),
          'entre las tres, toda c1, sin repetir ni volver a empezar');

-- ---------------------------------------------------------------------------
-- 9. No hay elección: el alcance que mande la app se ignora (contrato 0.9.8)
-- ---------------------------------------------------------------------------
select is(pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, a), 'ubicacion'),
          pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000), 'ubicacion'),
          'b2 con alcance «' || a || '» baja lo mismo que sin alcance (no se valida ni cambia lo que baja)')
  from unnest(array['zona', 'ciudad', 'pais', '']) a;
select is(pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, null), 'ubicacion'),
          pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000), 'ubicacion'),
          'y con alcance null');
select is((select pg_temp.huella(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, 'zona'))),
          (select pg_temp.huella(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, 'ciudad'))),
          'la huella no depende del alcance');
select is((select pg_temp.huella(d) from pull_b2_z2),
          md5('ciudad|01920000-0000-7000-8000-0000000014c1'),
          'y es la que «ciudad» ya guardaba (md5 de «ciudad|» y los ids de las ciudades): quien bajaba toda la ciudad no la vuelve a bajar');

-- ---------------------------------------------------------------------------
-- 10. Mover la casa no invalida lo pendiente de nadie (revisión de #36)
-- ---------------------------------------------------------------------------
-- 1408 es de b1, en Z1, con su estado y un espacio (versión 0). El estado se carga con otra
-- posición: el pin es siempre la de la casa.
select pg_temp.como_servidor();
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-000000001408', 'CASA', -34.912, -56.188, '01920000-0000-7000-8000-0000000014c1',
   '01920000-0000-7000-8000-0000000014b1');
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by) values
  ('01920000-0000-7000-8000-000000001408', 0, 0, 'CASA', 'SIN_CONTESTAR', 6, '01920000-0000-7000-8000-0000000014b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-000000001418', '01920000-0000-7000-8000-000000001408', '01920000-0000-7000-8000-0000000014b1');
select is((select array[lat, lon] from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001408'),
          array[-34.912, -56.188]::float8[], 'el pin toma la posición de la casa, no la que se manda');

-- b1 corrige el pin 3 m, marca la visita y el piso, en un lote (lo pendiente de su teléfono).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table lote_b1 as
select sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update', 'sync_version', 0,
                     'payload', jsonb_build_object('id', '01920000-0000-7000-8000-000000001408',
                                                   'lat', -34.91203, 'lon', -56.188)),
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'house_status', 'op', 'update', 'sync_version', 0,
                     'payload', jsonb_build_object('ubicacion_id', '01920000-0000-7000-8000-000000001408',
                                                   'lat', -34.91203, 'lon', -56.188,
                                                   'color', 'VENTA_COMPLETA', 'prioridad', 4)),
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'espacio', 'op', 'update', 'sync_version', 0,
                     'payload', jsonb_build_object('id', '01920000-0000-7000-8000-000000001418', 'piso', '2')))) as r;
select is((select jsonb_path_query_array(r, '$.results[*].outcome') from lote_b1),
          '["accepted", "accepted", "accepted"]'::jsonb,
          'mover la casa, cambiar el estado y el piso en un lote: entran los tres (mover no sube la versión de los dependientes)');
select pg_temp.como_servidor();
select is((select array[color, lat::text, sync_version::text] from public.house_status
            where ubicacion_id = '01920000-0000-7000-8000-000000001408'),
          array['VENTA_COMPLETA', '-34.91203', '1'], 'el estado queda como lo dejó b1, con el pin en la posición nueva');
select is((select array[piso, sync_version::text] from public.espacio where id = '01920000-0000-7000-8000-000000001418'),
          array['2', '1'], 'y el piso');

-- b2 (trabaja la ciudad) corrige la casa mientras b1 tiene pendiente otro estado.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
update public.ubicacion set lat = -34.9125 where id = '01920000-0000-7000-8000-000000001408';
select pg_temp.como_servidor();
select is((select array[lat::text, sync_version::text] from public.house_status
            where ubicacion_id = '01920000-0000-7000-8000-000000001408'),
          array['-34.9125', '1'], 'el pin sigue a la casa que corrigió otro, sin subir la versión del estado');
select is((select sync_version from public.espacio where id = '01920000-0000-7000-8000-000000001418'), 1::bigint,
          'ni la del espacio');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
select is(sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'house_status', 'op', 'update', 'sync_version', 1,
                     'payload', jsonb_build_object('ubicacion_id', '01920000-0000-7000-8000-000000001408',
                                                   'lat', -34.91203, 'lon', -56.188,
                                                   'color', 'RECHAZO', 'prioridad', 7)))) #>> '{results,0,outcome}',
          'accepted', 'el estado pendiente de b1 entra aunque otro haya movido la casa');
select pg_temp.como_servidor();
select is((select array[color, lat::text] from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001408'),
          array['RECHAZO', '-34.9125'], 'y su posición vieja no pisa el pin');

-- El lote en el otro orden: el estado antes que la casa movida. El pin igual queda en la nueva.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
select is(jsonb_path_query_array(sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'house_status', 'op', 'update', 'sync_version', 2,
                     'payload', jsonb_build_object('ubicacion_id', '01920000-0000-7000-8000-000000001408',
                                                   'color', 'SIN_CONTESTAR', 'prioridad', 6)),
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update', 'sync_version', 2,
                     'payload', jsonb_build_object('id', '01920000-0000-7000-8000-000000001408', 'lat', -34.913)))),
          '$.results[*].outcome'),
          '["accepted", "accepted"]'::jsonb, 'estado y después la casa movida: entran los dos');
select pg_temp.como_servidor();
select is((select array[color, lat::text] from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001408'),
          array['SIN_CONTESTAR', '-34.913'], 'y el pin queda en la posición nueva');
drop table lote_b1;

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table pull_b1, pull_b2, pull_b2_vacio, pull_b3, pull_b1_mueve, pull_b2_mueve, pull_b1_z2, pull_b1_redibujo,
           pull_b2_z2, pull_b2_sigue, pull_b4, pull_b4_z3, pull_b1_z3, pull_b1_sigue, pagina_1, pagina_2, pagina_3;
delete from public.zona_vertice where zona_id in ('01920000-0000-7000-8000-0000000014d1', '01920000-0000-7000-8000-0000000014d2');
delete from public.espacio where ubicacion_id::text like '01920000-0000-7000-8000-00000000140%';
delete from public.house_status where ubicacion_id::text like '01920000-0000-7000-8000-00000000140%';
delete from public.ubicacion where id::text like '01920000-0000-7000-8000-00000000140%';
delete from public.campania_colportor where campania_id in ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014e2');
delete from public.zona where campania_ciudad_id in ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014f2',
                                                      '01920000-0000-7000-8000-0000000014f3');
delete from public.campania_ciudad where id in ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014f2',
                                                '01920000-0000-7000-8000-0000000014f3');
delete from public.campania where id in ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014e2');
delete from public.ciudad where id in ('01920000-0000-7000-8000-0000000014c1', '01920000-0000-7000-8000-0000000014c2',
                                       '01920000-0000-7000-8000-0000000014c3');
delete from public.pais where id = '01920000-0000-7000-8000-0000000014c0';
delete from public.usuario_rol where usuario_id = '01920000-0000-7000-8000-0000000014a1';
delete from auth.users where id in ('01920000-0000-7000-8000-0000000014a1', '01920000-0000-7000-8000-0000000014b1',
                                    '01920000-0000-7000-8000-0000000014b2', '01920000-0000-7000-8000-0000000014b3',
                                    '01920000-0000-7000-8000-0000000014b4', '01920000-0000-7000-8000-0000000014b5');

select * from finish();
