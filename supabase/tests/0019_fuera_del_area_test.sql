-- pgTAP · migración 0016 (backend-supabase#37): el pull avisa las ubicaciones que salieron del
-- área del colportor desde su último pull (out_of_area) y las entidades que arrancaron de cero
-- porque cambió el área (area_reset). Nada se borra del teléfono: el aviso son ids.
--
-- Como 0004, 0011, 0014 y 0017, NO va en una transacción: el delta solo sirve lo commiteado.
-- Limpia al final.

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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000019' || p_sufijo)::uuid;
$$;

-- Los sufijos de los ids de una entidad en `rows`, ordenados.
create or replace function pg_temp.filas(p_delta jsonb, p_entidad text default 'ubicacion') returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;

-- Los sufijos de out_of_area.ubicacion, en el orden en que vienen.
create or replace function pg_temp.fuera(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e #>> '{}', 2) order by o), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'out_of_area' -> 'ubicacion', '[]'::jsonb)) with ordinality x(e, o);
$$;

create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Verano (e1, coordina a1) en c1 (zonas Z1 y Z2) y c2 (sin zonas);
-- Otra (e2) en c3. b1: Verano, Z1. b2 y b4: Verano, sin zona. b3: Otra, sin zona.
--   01 en Z1 (b4 la corrige al norte, fuera de Z1)   02 en Z1 (pasa a c3)
--   03 en Z1 (sale después de otra edición)          04 en c1 fuera de las zonas (se mueve, sigue afuera)
--   05 de b1, en Z1 (sale, pero es suya)             06 en c2 (pasa a c3)
--   07 en Z1 (sale y vuelve)                          08 en Z1 (se mueve adentro de Z1)
--   09 en c1 fuera de las zonas (dos movimientos en una transacción)   0a en Z2
--   0b..0e en Z1, se cargan en 5b (salir, volver y salir; corregir adentro y salir)
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'fuera-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('a1'), r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais fuera', 'ZF');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad fuera', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Segunda fuera', pg_temp.u('c0'), -34.7, -56.1),
  (pg_temp.u('c3'), 'Otra fuera', pg_temp.u('c0'), -34.8, -56.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otra', 'PERMANENTE', current_date - 10, null, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e2'), pg_temp.u('c3'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  (pg_temp.u('d1'), 'Z1', pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91)),
  (pg_temp.u('d2'), 'Z2', pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.21, -34.92, -56.20, -34.91));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1')),
  (pg_temp.u('e1'), pg_temp.u('b2'), null),
  (pg_temp.u('e2'), pg_temp.u('b3'), null),
  (pg_temp.u('e1'), pg_temp.u('b4'), null);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Rivera', '1', -34.915, -56.185, pg_temp.u('c1'), null),
  (pg_temp.u('02'), 'CASA', 'Rivera', '2', -34.915, -56.184, pg_temp.u('c1'), null),
  (pg_temp.u('03'), 'CASA', 'Rivera', '3', -34.915, -56.183, pg_temp.u('c1'), null),
  (pg_temp.u('04'), 'CASA', 'Rivera', '4', -34.95,  -56.25,  pg_temp.u('c1'), null),
  (pg_temp.u('05'), 'CASA', 'Propia', '5', -34.914, -56.184, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('06'), 'CASA', 'Artigas', '6', -34.7,  -56.1,   pg_temp.u('c2'), null),
  (pg_temp.u('07'), 'CASA', 'Rivera', '7', -34.916, -56.186, pg_temp.u('c1'), null),
  (pg_temp.u('08'), 'CASA', 'Rivera', '8', -34.917, -56.187, pg_temp.u('c1'), null),
  (pg_temp.u('09'), 'CASA', 'Rivera', '9', -34.95,  -56.26,  pg_temp.u('c1'), null),
  (pg_temp.u('0a'), 'CASA', 'Rivera', '10', -34.915, -56.205, pg_temp.u('c1'), null);

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select ok(not has_table_privilege('authenticated', 'sync.ubicacion_movida', 'select'),
          'authenticated no lee el registro de movimientos');
select ok(not has_table_privilege('authenticated', 'sync.ubicacion_movida', 'insert'),
          'ni escribe en él (lo escribe el trigger)');
select ok(has_function_privilege('authenticated', 'public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid)', 'execute'),
          'authenticated ejecuta el helper (sync.pull es INVOKER)');
select ok(not has_function_privilege('anon', 'public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid)', 'execute'),
          'anon no');
select is((select prosecdef from pg_proc where oid = 'public.ubicaciones_que_salieron(text, xid8, uuid, xid8, uuid)'::regprocedure),
          true, 'el helper es SECURITY DEFINER (la casa pudo irse a una ciudad que la RLS ya no muestra)');

-- ---------------------------------------------------------------------------
-- 2. Primer pull: sin avisos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03','05','07','08'], 'b1 (Z1) baja las de Z1 y la suya') from p1;
select ok(not (d ? 'out_of_area') and not (d ? 'area_reset'), 'el primer pull no lleva out_of_area ni area_reset') from p1;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, 'ciudad') as d;
select is(pg_temp.filas(d), array['01','02','03','04','05','06','07','08','09','0a'],
          'b2 («ciudad», sin zona) baja c1 y c2') from q1;

-- ---------------------------------------------------------------------------
-- 3. Se mueven casas (cada cambio en su transacción)
-- ---------------------------------------------------------------------------
-- 01: b4 la corrige 2 km al norte por el push (el trigger anota también lo que entra por el push).
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(jsonb_path_query_array(sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update',
                     'sync_version', (select sync_version from public.ubicacion where id = pg_temp.u('01')),
                     'payload', jsonb_build_object('id', pg_temp.u('01'), 'lat', -34.895)))),
          '$.results[*].outcome'),
          '["accepted"]'::jsonb, 'b4 corrige 01 fuera de Z1 (sigue en c1)');
select pg_temp.como_servidor();
update public.ubicacion set lat = -34.8, lon = -56.0, ciudad_id = pg_temp.u('c3') where id = pg_temp.u('02');
update public.ubicacion set lat = -34.96 where id = pg_temp.u('04');
update public.ubicacion set lat = -34.95, lon = -56.30 where id = pg_temp.u('05');
update public.ubicacion set lat = -34.8, lon = -56.0, ciudad_id = pg_temp.u('c3') where id = pg_temp.u('06');
update public.ubicacion set lat = -34.9175 where id = pg_temp.u('08');
update public.ubicacion set lat = -34.95 where id = pg_temp.u('07');
update public.ubicacion set lat = -34.916 where id = pg_temp.u('07');

select is((select array[count(*)::text, min(lat)::text] from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')),
          array['1', '-34.915'], 'el movimiento de 01 quedó anotado con la posición de antes');

-- ---------------------------------------------------------------------------
-- 4. El pull siguiente avisa lo que salió
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.fuera(d), array['01','02'],
          'out_of_area: 01 (corregida fuera de Z1) y 02 (a otra ciudad); no la suya (05), ni la que se movió '
          'adentro (08), ni la que salió y volvió (07), ni las que nunca estuvieron en su área (04, 06)') from p2;
select is((select array_agg(k order by k) from p2, jsonb_object_keys(d -> 'out_of_area') k), array['ubicacion'],
          'el aviso va solo en ubicacion (los espacios y el estado siguen a su casa)');
select is(pg_temp.filas(d), array['05','07','08'],
          'las filas: la suya (siempre baja), la que volvió y la que se movió adentro; las que salieron no bajan') from p2;
select ok(not (d ? 'area_reset'), 'mismo área: no hay area_reset') from p2;
select pg_temp.como_servidor();
select is((select count(*)::int from public.ubicacion where id in (pg_temp.u('01'), pg_temp.u('02')) and deleted_at is null), 2,
          'el servidor no borra nada: las dos siguen vivas');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p2), 1000) as d;
select ok(not (d ? 'out_of_area'), 'el pull siguiente no repite el aviso') from p3;
select is(d -> 'rows', '{}'::jsonb, 'ni trae filas') from p3;

-- «ciudad»: sale lo que se fue de sus ciudades.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q2 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from q1), 1000, null, 'ciudad') as d;
select is(pg_temp.fuera(d), array['02','06'], '«ciudad»: out_of_area con las que pasaron a c3; las que se movieron adentro de c1 no')
  from q2;
select is(pg_temp.filas(d), array['01','04','05','07','08'], 'y esas bajan como filas') from q2;

-- ---------------------------------------------------------------------------
-- 5. Una salida posterior a la última fila entregada llega en el pull siguiente, una sola vez
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.ubicacion set calle = 'Rivera nueva' where id = pg_temp.u('08');
update public.ubicacion set lat = -34.95 where id = pg_temp.u('03');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p4 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p3), 1000) as d;
select is(pg_temp.filas(d), array['08'], 'baja la edición de 08') from p4;
select ok(not (d ? 'out_of_area'), 'la salida de 03 es posterior a esa fila: todavía no se avisa') from p4;
create temp table p5 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p4), 1000) as d;
select is(pg_temp.fuera(d), array['03'], 'se avisa en el pull siguiente') from p5;
create temp table p6 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p5), 1000) as d;
select ok(not (d ? 'out_of_area'), 'y no se repite') from p6;

-- ---------------------------------------------------------------------------
-- 5b. «Al final del tramo», no «ahora» (revisión del PR #48): el snapshot del pull puede ver
--     movimientos posteriores al tramo, y esos se evalúan en el tramo siguiente.
--     0b sale, vuelve y sale otra vez con un pull paginado en el medio; 0d se corrige adentro y
--     después sale. 0c y 0e son otras casas de Z1 que se editan entre medio.
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('0b'), 'CASA', 'Rivera', '11', -34.9152, -56.1852, pg_temp.u('c1'), null),
  (pg_temp.u('0c'), 'CASA', 'Rivera', '12', -34.9153, -56.1853, pg_temp.u('c1'), null),
  (pg_temp.u('0d'), 'CASA', 'Rivera', '13', -34.9154, -56.1854, pg_temp.u('c1'), null),
  (pg_temp.u('0e'), 'CASA', 'Rivera', '14', -34.9155, -56.1855, pg_temp.u('c1'), null);
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pa as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p6), 1000) as d;
select is(pg_temp.filas(d), array['0b','0c','0d','0e'], 'b1 baja las cuatro casas nuevas de Z1') from pa;

-- 0b: sale (M1), se edita 0c, vuelve (M2); pull con límite 1 (la página corta en 0c); sale otra vez (M3).
select pg_temp.como_servidor();
update public.ubicacion set lat = -34.95 where id = pg_temp.u('0b');
update public.ubicacion set calle = 'Rivera once' where id = pg_temp.u('0c');
update public.ubicacion set lat = -34.9151 where id = pg_temp.u('0b');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pb as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pa), 1) as d;
select is(pg_temp.filas(d), array['0c'], 'la página trae solo 0c') from pb;
select ok((select (d ->> 'has_more')::boolean from pb), 'y hay más');
select is(pg_temp.fuera(d), array['0b'],
          'el tramo cubre la salida de 0b (M1) y al final del tramo 0b seguía afuera: se avisa, aunque «ahora» esté adentro')
  from pb;
select pg_temp.como_servidor();
update public.ubicacion set lat = -34.96 where id = pg_temp.u('0b');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pc as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pb), 1000) as d;
select ok(not (d ? 'out_of_area'), 'M2 y M3 en el tramo siguiente: 0b ya estaba afuera al principio, no se repite') from pc;
select is(d -> 'rows', '{}'::jsonb, 'y 0b no baja como fila (está afuera)') from pc;

-- 0d: se corrige adentro (M1), se edita 0e, sale (M2).
select pg_temp.como_servidor();
update public.ubicacion set lat = -34.9156 where id = pg_temp.u('0d');
update public.ubicacion set calle = 'Rivera catorce' where id = pg_temp.u('0e');
update public.ubicacion set lat = -34.95 where id = pg_temp.u('0d');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pd as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pc), 1000) as d;
select is(pg_temp.filas(d), array['0e'], 'baja la edición de 0e') from pd;
select ok(not (d ? 'out_of_area'),
          'el tramo termina en 0e y cubre solo M1: al final del tramo 0d seguía adentro, todavía no se avisa') from pd;
create temp table pe as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pd), 1000) as d;
select is(pg_temp.fuera(d), array['0d'], 'se avisa en el pull siguiente') from pe;
create temp table pf as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pe), 1000) as d;
select ok(not (d ? 'out_of_area'), 'una sola vez') from pf;

-- ---------------------------------------------------------------------------
-- 6. Cambia el área: area_reset, sin lista
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select public.asignar_zona(pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d2')) $$,
                'el coordinador le pasa a b1 a Z2');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p7 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from pf), 1000) as d;
select is(d -> 'area_reset', '["ubicacion", "espacio", "house_status"]'::jsonb,
          'otra zona: area_reset con las tres entidades (lo que tenía y no vuelve a bajar quedó fuera)') from p7;
select ok(not (d ? 'out_of_area'), 'y sin out_of_area: la entidad baja completa') from p7;
select is(pg_temp.filas(d), array['05','0a'], 'baja completa el área nueva (0a) y la suya') from p7;
create temp table p8 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p7), 1000) as d;
select ok(not (d ? 'area_reset'), 'con el watermark nuevo ya no hay area_reset') from p8;

-- Cambiar de alcance también.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q3 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from q2), 1000, null, 'zona') as d;
select is(d -> 'area_reset', '["ubicacion"]'::jsonb, 'de «ciudad» a «zona»: area_reset') from q3;

-- ---------------------------------------------------------------------------
-- 7. Quien la recibe: una casa que entra al área baja como fila; el aviso no filtra ids ajenos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000, null, 'ciudad') as d;
select is(pg_temp.filas(d), array['02','06'], 'b3 (c3) recibe las dos casas que llegaron a su ciudad') from r1;
select is((select count(*)::int from public.ubicaciones_que_salieron('ciudad', '0'::xid8, '00000000-0000-0000-0000-000000000000',
                                                                  pg_current_xact_id(), 'ffffffff-ffff-ffff-ffff-ffffffffffff')),
          0, 'el helper, llamado directo con todo el historial, no le da a b3 ninguna casa que no estuviera en su área');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select array_agg(right(s::text, 2) order by s)
             from public.ubicaciones_que_salieron('ciudad', '0'::xid8, '00000000-0000-0000-0000-000000000000',
                                                pg_current_xact_id(), 'ffffffff-ffff-ffff-ffff-ffffffffffff') s),
          array['02','06'], 'a b2, solo las que estaban en sus ciudades');

-- ---------------------------------------------------------------------------
-- 8. Dos movimientos en una transacción: queda la posición de antes de la transacción
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
do $$
begin
  update public.ubicacion set lat = -34.951 where id = '01920000-0000-7000-8000-000000001909';
  update public.ubicacion set lat = -34.952 where id = '01920000-0000-7000-8000-000000001909';
end $$;
select is((select array_agg(lat::text) from sync.ubicacion_movida where ubicacion_id = pg_temp.u('09')),
          array['-34.95'], 'una sola anotación, con la posición que un teléfono pudo haber visto');

-- ---------------------------------------------------------------------------
-- Limpieza (borrar la ubicación borra su registro de movimientos)
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, p3, p4, p5, p6, pa, pb, pc, pd, pe, pf, p7, p8, q1, q2, q3, r1;
delete from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000019%';
select is((select count(*)::int from sync.ubicacion_movida where ubicacion_id::text like '01920000-0000-7000-8000-0000000019%'),
          0, 'el registro se va con la ubicación');
delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.zona where id in (pg_temp.u('d1'), pg_temp.u('d2'));
delete from public.campania_ciudad where id in (pg_temp.u('f1'), pg_temp.u('f2'), pg_temp.u('f3'));
delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('c3'));
delete from public.pais where id = pg_temp.u('c0');
delete from public.usuario_rol where usuario_id = pg_temp.u('a1');
delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'));

select * from finish();
