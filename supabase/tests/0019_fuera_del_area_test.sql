-- pgTAP · migraciones 0016 y 0023 (backend-supabase#37 y #58): el pull avisa las ubicaciones que
-- salieron de las ciudades del colportor desde su último pull (out_of_area) y las entidades que
-- arrancaron de cero porque cambió su ciudad de trabajo (area_reset). Nada se borra del teléfono:
-- el aviso son ids. Corregir la posición dentro de la misma ciudad no es salir: la casa sigue
-- bajando como fila.
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
-- Fixtures (como postgres). Verano (e1, coordina a1) en c1 (zona Z1) y c2 (zona Z2); Otra (e2) en c3.
-- b1: Verano, Z1 (trabaja c1). b2 y b4: Verano, sin zona (c1 y c2). b3: Otra, sin zona (c3).
--   01 en c1 (b4 la pasa a c2 por el push)         02 en c1 (pasa a c3)
--   03 en c1 (sale después de otra edición)        04 en c1 (se corrige la posición, sigue en c1)
--   05 de b1, en c1 (pasa a c3, pero es suya)      06 en c2 (pasa a c3)
--   07 en c1 (sale y vuelve)                       08 en c1 (se edita adentro)
--   09 en c1 (dos movimientos en una transacción)  0a en c1 (no se mueve)
--   0b y 0c en c1, se cargan en 5b (salir, volver y salir con una página en el medio)
--   0d y 0e en c1, se cargan en 5c (pasar a c2 —adentro para b2—, y después a c3)
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
  (pg_temp.u('d2'), 'Z2', pg_temp.u('f2'), 'ESQUINAS', pg_temp.rect(-56.11, -34.71, -56.09, -34.69));
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
select ok(has_function_privilege('authenticated', 'public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)', 'execute'),
          'authenticated ejecuta el helper (sync.pull es INVOKER)');
select ok(not has_function_privilege('anon', 'public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)', 'execute'),
          'anon no');
select is((select prosecdef from pg_proc where oid = 'public.ubicaciones_que_salieron(xid8, uuid, xid8, uuid)'::regprocedure),
          true, 'el helper es SECURITY DEFINER (la casa pudo irse a una ciudad que la RLS ya no muestra)');

-- ---------------------------------------------------------------------------
-- 2. Primer pull: sin avisos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03','04','05','07','08','09','0a'],
          'b1 (Z1, en c1) baja toda c1: no la de c2') from p1;
select ok(not (d ? 'out_of_area') and not (d ? 'area_reset'), 'el primer pull no lleva out_of_area ni area_reset') from p1;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03','04','05','06','07','08','09','0a'],
          'b2 (sin zona) baja c1 y c2') from q1;

-- ---------------------------------------------------------------------------
-- 3. Se mueven casas (cada cambio en su transacción)
-- ---------------------------------------------------------------------------
-- 01: b4 la pasa de c1 a c2 por el push (el trigger anota también lo que entra por el push).
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(jsonb_path_query_array(sync.push(jsonb_build_array(
  jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update',
                     'sync_version', (select sync_version from public.ubicacion where id = pg_temp.u('01')),
                     'payload', jsonb_build_object('id', pg_temp.u('01'), 'ciudad_id', pg_temp.u('c2'))))),
          '$.results[*].outcome'),
          '["accepted"]'::jsonb, 'b4 pasa 01 de c1 a c2');
select pg_temp.como_servidor();
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('02');
update public.ubicacion set lat = -34.96 where id = pg_temp.u('04');
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('05');
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('06');
update public.ubicacion set lat = -34.9175 where id = pg_temp.u('08');
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('07');
update public.ubicacion set ciudad_id = pg_temp.u('c1') where id = pg_temp.u('07');

select is((select array[count(*)::text, min(ciudad_id::text)] from sync.ubicacion_movida where ubicacion_id = pg_temp.u('01')),
          array['1', pg_temp.u('c1')::text], 'el movimiento de 01 quedó anotado con la ciudad de antes');
select is((select count(*)::int from sync.ubicacion_movida where ubicacion_id in (pg_temp.u('04'), pg_temp.u('08'))), 0,
          'corregir la posición dentro de la ciudad no anota nada: no es salir');

-- ---------------------------------------------------------------------------
-- 4. El pull siguiente avisa lo que salió
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.fuera(d), array['01','02'],
          'out_of_area: 01 (a c2) y 02 (a c3); no la suya (05), ni las que se corrigieron adentro (04, 08), ni la que '
          'salió y volvió (07), ni la que nunca estuvo en su ciudad (06)') from p2;
select is((select array_agg(k order by k) from p2, jsonb_object_keys(d -> 'out_of_area') k), array['ubicacion'],
          'el aviso va solo en ubicacion (los espacios y el estado siguen a su casa)');
select is(pg_temp.filas(d), array['04','05','07','08'],
          'las filas: las corregidas adentro, la suya (siempre baja) y la que volvió; las que salieron no bajan') from p2;
select ok(not (d ? 'area_reset'), 'misma ciudad: no hay area_reset') from p2;
select pg_temp.como_servidor();
select is((select count(*)::int from public.ubicacion where id in (pg_temp.u('01'), pg_temp.u('02')) and deleted_at is null), 2,
          'el servidor no borra nada: las dos siguen vivas');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p2), 1000) as d;
select ok(not (d ? 'out_of_area'), 'el pull siguiente no repite el aviso') from p3;
select is(d -> 'rows', '{}'::jsonb, 'ni trae filas') from p3;

-- b2 (c1 y c2): sale lo que se fue de las dos.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q2 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from q1), 1000) as d;
select is(pg_temp.fuera(d), array['02','05','06'],
          'b2: out_of_area con las que pasaron a c3 (también 05, que es de b1); 01 pasó de c1 a c2, las dos suyas: no sale')
  from q2;
select is(pg_temp.filas(d), array['01','04','07','08'], 'y las que siguen en sus ciudades bajan como filas') from q2;

-- ---------------------------------------------------------------------------
-- 5. Una salida posterior a la última fila entregada llega en el pull siguiente, una sola vez
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.ubicacion set calle = 'Rivera nueva' where id = pg_temp.u('08');
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('03');

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
--     0b sale, vuelve y sale otra vez con un pull paginado en el medio. 0c es otra casa de c1 que
--     se edita entre medio.
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('0b'), 'CASA', 'Rivera', '11', -34.9152, -56.1852, pg_temp.u('c1'), null),
  (pg_temp.u('0c'), 'CASA', 'Rivera', '12', -34.9153, -56.1853, pg_temp.u('c1'), null);
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pa as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p6), 1000) as d;
select is(pg_temp.filas(d), array['0b','0c'], 'b1 baja las dos casas nuevas de c1') from pa;

-- 0b: sale (M1), se edita 0c, vuelve (M2); pull con límite 1 (la página corta en 0c); sale otra vez (M3).
select pg_temp.como_servidor();
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('0b');
update public.ubicacion set calle = 'Rivera once' where id = pg_temp.u('0c');
update public.ubicacion set ciudad_id = pg_temp.u('c1') where id = pg_temp.u('0b');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pb as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pa), 1) as d;
select is(pg_temp.filas(d), array['0c'], 'la página trae solo 0c') from pb;
select ok((select (d ->> 'has_more')::boolean from pb), 'y hay más');
select is(pg_temp.fuera(d), array['0b'],
          'el tramo cubre la salida de 0b (M1) y al final del tramo 0b seguía en c3: se avisa, aunque «ahora» esté en c1')
  from pb;
select pg_temp.como_servidor();
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('0b');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pc as select sync.pull(array['ubicacion'], (select d -> 'watermark' from pb), 1000) as d;
select ok(not (d ? 'out_of_area'), 'M2 y M3 en el tramo siguiente: 0b ya estaba afuera al principio, no se repite') from pc;
select is(d -> 'rows', '{}'::jsonb, 'y 0b no baja como fila (está en c3)') from pc;

-- ---------------------------------------------------------------------------
-- 5c. Pasar a otra ciudad suya y después salir (b2, que trabaja c1 y c2): 0d pasa a c2 (M1), se
--     edita 0e, 0d pasa a c3 (M2). El tramo del primer pull cubre solo M1: 0d no salió.
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('0d'), 'CASA', 'Rivera', '13', -34.9154, -56.1854, pg_temp.u('c1'), null),
  (pg_temp.u('0e'), 'CASA', 'Rivera', '14', -34.9155, -56.1855, pg_temp.u('c1'), null);
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table qa as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select pg_temp.como_servidor();
update public.ubicacion set ciudad_id = pg_temp.u('c2') where id = pg_temp.u('0d');
update public.ubicacion set calle = 'Rivera catorce' where id = pg_temp.u('0e');
update public.ubicacion set ciudad_id = pg_temp.u('c3') where id = pg_temp.u('0d');
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table qb as select sync.pull(array['ubicacion'], (select d -> 'watermark' from qa), 1000) as d;
select is(pg_temp.filas(d), array['0e'], 'baja la edición de 0e (0d ya está en c3)') from qb;
select ok(not (d ? 'out_of_area'),
          'el tramo termina en 0e y cubre solo M1: al final del tramo 0d seguía en c2, una ciudad suya: no se avisa') from qb;
create temp table qc as select sync.pull(array['ubicacion'], (select d -> 'watermark' from qb), 1000) as d;
select is(pg_temp.fuera(d), array['0d'], 'se avisa en el pull siguiente, cuando sale de c2') from qc;
create temp table qd as select sync.pull(array['ubicacion'], (select d -> 'watermark' from qc), 1000) as d;
select ok(not (d ? 'out_of_area'), 'una sola vez') from qd;

-- ---------------------------------------------------------------------------
-- 6. Cambia la ciudad de trabajo: area_reset, sin lista
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select public.asignar_zona(pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d2')) $$,
                'el coordinador le pasa a b1 la zona Z2 (en c2)');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p7 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from pc), 1000) as d;
select is(d -> 'area_reset', '["ubicacion", "espacio", "house_status"]'::jsonb,
          'zona de otra ciudad: area_reset con las tres entidades (lo que tenía y no vuelve a bajar quedó fuera)') from p7;
select ok(not (d ? 'out_of_area'), 'y sin out_of_area: la entidad baja completa') from p7;
select is(pg_temp.filas(d), array['01','05'], 'baja completa c2 (01, que le pasó b4) y la suya, de la ciudad vieja') from p7;
create temp table p8 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from p7), 1000) as d;
select ok(not (d ? 'area_reset'), 'con el watermark nuevo ya no hay area_reset') from p8;

-- El alcance que mande un motor viejo no cambia el área.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q3 as select sync.pull(array['ubicacion'], (select d -> 'watermark' from qd), 1000, null, 'zona') as d;
select ok(not (d ? 'area_reset'), 'con alcance «zona» (que el servidor ignora) no hay area_reset') from q3;

-- ---------------------------------------------------------------------------
-- 7. Quien la recibe: una casa que entra a la ciudad baja como fila; el aviso no filtra ids ajenos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table r1 as select sync.pull(array['ubicacion'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['02','03','05','06','0b','0d'], 'b3 (c3) recibe las casas que llegaron a su ciudad') from r1;
select is((select count(*)::int from public.ubicaciones_que_salieron('0'::xid8, '00000000-0000-0000-0000-000000000000',
                                                                  pg_current_xact_id(), 'ffffffff-ffff-ffff-ffff-ffffffffffff')),
          0, 'el helper, llamado directo con todo el historial, no le da a b3 ninguna casa que no estuviera en su ciudad');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select array_agg(right(s::text, 2) order by s)
             from public.ubicaciones_que_salieron('0'::xid8, '00000000-0000-0000-0000-000000000000',
                                                pg_current_xact_id(), 'ffffffff-ffff-ffff-ffff-ffffffffffff') s),
          array['02','03','05','06','0b','0d'], 'a b2, solo las que estaban en c1 o c2 y terminaron en otra ciudad');

-- ---------------------------------------------------------------------------
-- 8. Dos movimientos en una transacción: queda la ciudad de antes de la transacción
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
do $$
begin
  update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000019c3' where id = '01920000-0000-7000-8000-000000001909';
  update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000019c2' where id = '01920000-0000-7000-8000-000000001909';
end $$;
select is((select array_agg(ciudad_id) from sync.ubicacion_movida where ubicacion_id = pg_temp.u('09')),
          array[pg_temp.u('c1')], 'una sola anotación, con la ciudad que un teléfono pudo haber visto');

-- ---------------------------------------------------------------------------
-- Limpieza (borrar la ubicación borra su registro de movimientos)
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, p3, p4, p5, p6, pa, pb, pc, p7, p8, q1, q2, q3, qa, qb, qc, qd, r1;
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
