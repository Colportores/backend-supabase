-- pgTAP · migración 0011 — qué ubicaciones baja cada colportor (HU-SYNC-011, backend-supabase#32):
-- su zona o toda la ciudad, más las propias; el área completa cuando le asignan o le redibujan la
-- zona; y los espacios y el estado de una casa que se mueve a su área.
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
-- Fixtures (como postgres). Verano (e1, coordina a1) en c1 con Z1 y Z2; Otra (e2) en c2.
-- b1: Verano, Z1. b2: Verano, sin zona. b3: Otra, sin zona.
--   1401 en Z2, con estado y un espacio          1402 en c1, al oeste de Z2
--   1403 en c2                                   1404 en Z1          1405 en Z1, dada de baja
--   1406 de b2, en c1 fuera de toda zona, con estado y un espacio
--   1407 en c1 fuera de toda zona, con estado y un espacio (después se mueve a Z1)
-- Todas se cargan antes del primer pull de cada colportor.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000014' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'alcance-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000014a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000014c0', 'Pais alcance', 'ZR');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000014c1', 'Ciudad alcance', '01920000-0000-7000-8000-0000000014c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000014c2', 'Otra alcance',   '01920000-0000-7000-8000-0000000014c0', -34.8, -56.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000014e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000014a1'),
  ('01920000-0000-7000-8000-0000000014e2', 'Otra',   'PERMANENTE', current_date - 10, null,              null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014c1'),
  ('01920000-0000-7000-8000-0000000014f2', '01920000-0000-7000-8000-0000000014e2', '01920000-0000-7000-8000-0000000014c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000014d1', 'Z1', '01920000-0000-7000-8000-0000000014f1', 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91)),
  ('01920000-0000-7000-8000-0000000014d2', 'Z2', '01920000-0000-7000-8000-0000000014f1', 'ESQUINAS', pg_temp.rect(-56.21, -34.92, -56.20, -34.91));
insert into public.zona_vertice (zona_id, orden, lat, lon)
select '01920000-0000-7000-8000-0000000014d2', o, y, x
  from (values (1, -34.92, -56.21), (2, -34.92, -56.20), (3, -34.91, -56.20), (4, -34.91, -56.21)) v(o, y, x);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b1', '01920000-0000-7000-8000-0000000014d1'),
  ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b2', null),
  ('01920000-0000-7000-8000-0000000014e2', '01920000-0000-7000-8000-0000000014b3', null);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000001401', 'CASA', 'Rivera', '1', -34.915, -56.205, '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001402', 'CASA', 'Rivera', '2', -34.915, -56.215, '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001403', 'CASA', 'Rivera', '3', -34.8,   -56.0,   '01920000-0000-7000-8000-0000000014c2', null, null),
  ('01920000-0000-7000-8000-000000001404', 'CASA', 'Rivera', '4', -34.915, -56.185, '01920000-0000-7000-8000-0000000014c1', null, null),
  ('01920000-0000-7000-8000-000000001405', 'CASA', 'Rivera', '5', -34.915, -56.186, '01920000-0000-7000-8000-0000000014c1', null, now()),
  ('01920000-0000-7000-8000-000000001406', 'CASA', 'Propia', '6', -34.95, -56.25,   '01920000-0000-7000-8000-0000000014c1',
   '01920000-0000-7000-8000-0000000014b2', null),
  ('01920000-0000-7000-8000-000000001407', 'CASA', 'Rivera', '7', -34.95,  -56.30,  '01920000-0000-7000-8000-0000000014c1', null, null);
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by) values
  ('01920000-0000-7000-8000-000000001401', -34.915, -56.205, 'CASA', 'COBRANZA_PENDIENTE', 2, null),
  ('01920000-0000-7000-8000-000000001406', -34.95,  -56.25,  'CASA', 'RECHAZO', 7, '01920000-0000-7000-8000-0000000014b2'),
  ('01920000-0000-7000-8000-000000001407', -34.95,  -56.30,  'CASA', 'SIN_CONTESTAR', 6, null);
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-000000001411', '01920000-0000-7000-8000-000000001401', null),
  ('01920000-0000-7000-8000-000000001416', '01920000-0000-7000-8000-000000001406', '01920000-0000-7000-8000-0000000014b2'),
  ('01920000-0000-7000-8000-000000001417', '01920000-0000-7000-8000-000000001407', null);

-- ---------------------------------------------------------------------------
-- 1. Su zona: lo que cae en el polígono (las bajas también), y nada más
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array['01920000-0000-7000-8000-000000001404', '01920000-0000-7000-8000-000000001405'],
          'b1 (Z1) baja las casas de Z1, también la dada de baja (su tombstone); ni las de afuera ni las de Z2')
  from pull_b1;
select ok((select d -> 'watermark' -> 'ubicacion' ? 'area' from pull_b1),
          'el watermark de ubicacion lleva la huella del área');
select ok((select d -> 'watermark' -> 'espacio' ->> 'area' = d -> 'watermark' -> 'ubicacion' ->> 'area' from pull_b1),
          'sin espacios en el área, el watermark de espacio igual avanza y guarda la misma huella');
select is((select d -> 'watermark' -> 'espacio' ->> 'id' from pull_b1), '00000000-0000-0000-0000-000000000000',
          'con el cursor en el horizonte: el pull siguiente no vuelve a recorrer lo de abajo');

-- «Incluye N ubicaciones» coincide con lo que bajó: las vivas del área.
select pg_temp.como_servidor();
select is(public.zona_ubicaciones_incluidas('01920000-0000-7000-8000-0000000014f1',
                                            (select poligono_geojson from public.zona where id = '01920000-0000-7000-8000-0000000014d1')),
          (select count(*)::integer from pull_b1, jsonb_array_elements(d -> 'rows' -> 'ubicacion') e
            where e ->> 'deleted_at' is null),
          '«Incluye N» de Z1 = las casas vivas que bajó b1');

-- ---------------------------------------------------------------------------
-- 2. Sin zona: solo las propias
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array['01920000-0000-7000-8000-000000001406'],
          'b2, sin zona, baja solo la casa que registró') from pull_b2;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'), array['01920000-0000-7000-8000-000000001406'],
          'con su estado') from pull_b2;
select is(pg_temp.ids(d, 'espacio'), array['01920000-0000-7000-8000-000000001416'],
          'y su espacio') from pull_b2;

create temp table pull_b2_vacio as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2), 1000) as d;
select is((select d -> 'rows' from pull_b2_vacio), '{}'::jsonb, 'sin novedades en su área, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. Le asignan Z2: el pull siguiente trae completa el área, aunque se cargó antes
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014b2',
                                '01920000-0000-7000-8000-0000000014d2') $$,
  'el coordinador le asigna Z2 a b2');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_z2 as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2_vacio), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array['01920000-0000-7000-8000-000000001401', '01920000-0000-7000-8000-000000001406'],
          'con su watermark de antes, b2 baja las casas de Z2 (cargadas antes de su último pull) y las propias')
  from pull_b2_z2;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'),
          array['01920000-0000-7000-8000-000000001401', '01920000-0000-7000-8000-000000001406'],
          'con su estado') from pull_b2_z2;
select is(pg_temp.ids(d, 'espacio'),
          array['01920000-0000-7000-8000-000000001411', '01920000-0000-7000-8000-000000001416'],
          'y sus espacios') from pull_b2_z2;

-- ---------------------------------------------------------------------------
-- 4. Le redibujan Z2: lo mismo. Cambiarle el nombre no.
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select lives_ok($$ select pg_temp.guardar_z2('Z2 norte', -56.21, -56.20) $$, 'el coordinador le cambia el nombre a Z2');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_nombre as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2_z2), 1000) as d;
select is((select d -> 'rows' from pull_b2_nombre), '{}'::jsonb, 'cambiar el nombre no cambia el área: no baja nada');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014a1');
select is((pg_temp.guardar_z2('Z2 norte', -56.22, -56.20, true) -> 'ubicaciones_incluidas'), '2'::jsonb,
          'vista previa de agrandar Z2 al oeste: incluye 2 ubicaciones');
select lives_ok($$ select pg_temp.guardar_z2('Z2 norte', -56.22, -56.20) $$, 'y la guarda');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_redibujo as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b2_nombre), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array['01920000-0000-7000-8000-000000001401', '01920000-0000-7000-8000-000000001402',
                '01920000-0000-7000-8000-000000001406'],
          'redibujada, baja completa el área nueva: la casa que quedó adentro, aunque se cargó antes')
  from pull_b2_redibujo;
select is((select count(*)::integer from pull_b2_redibujo, jsonb_array_elements(d -> 'rows' -> 'ubicacion') e
            where e ->> 'deleted_at' is null
              and e ->> 'created_by' is distinct from '01920000-0000-7000-8000-0000000014b2'),
          2, '«Incluye N» (2) coincide con lo que bajó del área (sin las propias de afuera)');

-- ---------------------------------------------------------------------------
-- 5. Una casa que se mueve a su área trae sus espacios y su estado
-- ---------------------------------------------------------------------------
-- b1 ya pasó el cursor de espacio y house_status por encima de los de 1407 (sección 1). b2
-- (trabaja la ciudad) mueve 1407 adentro de Z1.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
select lives_ok(
  $$ update public.ubicacion set lat = -34.912, lon = -56.182 where id = '01920000-0000-7000-8000-000000001407' $$,
  'b2 corrige la posición de una casa ajena de su ciudad: cae en Z1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b1');
create temp table pull_b1_mueve as
select sync.pull(array['ubicacion', 'house_status', 'espacio'], (select d -> 'watermark' from pull_b1), 1000) as d;
select is(pg_temp.ids(d, 'ubicacion'), array['01920000-0000-7000-8000-000000001407'],
          'b1 baja la casa que entró a Z1') from pull_b1_mueve;
select is(pg_temp.ids(d, 'espacio'), array['01920000-0000-7000-8000-000000001417'],
          'y su espacio, aunque se cargó antes de su último pull') from pull_b1_mueve;
select is(pg_temp.ids(d, 'house_status', 'ubicacion_id'), array['01920000-0000-7000-8000-000000001407'],
          'y su estado') from pull_b1_mueve;

-- ---------------------------------------------------------------------------
-- 6. Toda la ciudad
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pull_b2_ciudad as
select sync.pull(array['ubicacion'], (select d -> 'watermark' from pull_b2_redibujo), 1000, null, 'ciudad') as d;
select is(pg_temp.ids(d, 'ubicacion'),
          array['01920000-0000-7000-8000-000000001401', '01920000-0000-7000-8000-000000001402',
                '01920000-0000-7000-8000-000000001404', '01920000-0000-7000-8000-000000001405',
                '01920000-0000-7000-8000-000000001406', '01920000-0000-7000-8000-000000001407'],
          'pasar a «ciudad» baja completa la ciudad (con su watermark de zona), y no la otra ciudad')
  from pull_b2_ciudad;
select isnt((select d -> 'watermark' -> 'ubicacion' ->> 'area' from pull_b2_ciudad),
            (select d -> 'watermark' -> 'ubicacion' ->> 'area' from pull_b2_redibujo),
            'con otra huella');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b3');
select is(pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, 'ciudad'), 'ubicacion'),
          array['01920000-0000-7000-8000-000000001403'],
          'b3 con «ciudad» baja solo las de su ciudad');

-- Paginado: la huella no reinicia la página siguiente.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000014b2');
create temp table pagina_1 as
select sync.pull(array['ubicacion'], '{}'::jsonb, 4, null, 'ciudad') as d;
create temp table pagina_2 as
select sync.pull(array['ubicacion'], (select d -> 'watermark' from pagina_1), 4, null, 'ciudad') as d;
select is((select (d ->> 'has_more')::boolean from pagina_1), true, 'página 1 de 4 filas: hay más');
select is((select array_length(pg_temp.ids(d, 'ubicacion'), 1) from pagina_2), 2, 'la página 2 trae las 2 que faltan');
select is((select pg_temp.ids(p1.d, 'ubicacion') || pg_temp.ids(p2.d, 'ubicacion') from pagina_1 p1, pagina_2 p2)::text[]
            @> (select pg_temp.ids(d, 'ubicacion') from pull_b2_ciudad), true,
          'entre las dos, todas, sin volver a empezar');

-- ---------------------------------------------------------------------------
-- 7. Un alcance que no existe
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select sync.pull(array['ubicacion'], '{}'::jsonb, 10, null, 'pais') $$,
  '22023', null, 'un alcance que no es zona ni ciudad se rechaza con un aviso');
select is(pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, null), 'ubicacion'),
          pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000), 'ubicacion'),
          'sin alcance es «zona» (S60 pendiente: lo que bajaba hasta ahora)');

-- ---------------------------------------------------------------------------
-- 8. Mover la casa no invalida lo pendiente de nadie (revisión de #36)
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
drop table pull_b1, pull_b2, pull_b2_vacio, pull_b2_z2, pull_b2_nombre, pull_b2_redibujo, pull_b1_mueve,
           pull_b2_ciudad, pagina_1, pagina_2;
delete from public.zona_vertice where zona_id in ('01920000-0000-7000-8000-0000000014d1', '01920000-0000-7000-8000-0000000014d2');
delete from public.espacio where ubicacion_id::text like '01920000-0000-7000-8000-00000000140%';
delete from public.house_status where ubicacion_id::text like '01920000-0000-7000-8000-00000000140%';
delete from public.ubicacion where id::text like '01920000-0000-7000-8000-00000000140%';
delete from public.campania_colportor where campania_id in ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014e2');
delete from public.zona where campania_ciudad_id in ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014f2');
delete from public.campania_ciudad where id in ('01920000-0000-7000-8000-0000000014f1', '01920000-0000-7000-8000-0000000014f2');
delete from public.campania where id in ('01920000-0000-7000-8000-0000000014e1', '01920000-0000-7000-8000-0000000014e2');
delete from public.ciudad where id in ('01920000-0000-7000-8000-0000000014c1', '01920000-0000-7000-8000-0000000014c2');
delete from public.pais where id = '01920000-0000-7000-8000-0000000014c0';
delete from public.usuario_rol where usuario_id = '01920000-0000-7000-8000-0000000014a1';
delete from auth.users where id in ('01920000-0000-7000-8000-0000000014a1', '01920000-0000-7000-8000-0000000014b1',
                                    '01920000-0000-7000-8000-0000000014b2', '01920000-0000-7000-8000-0000000014b3');

select * from finish();
