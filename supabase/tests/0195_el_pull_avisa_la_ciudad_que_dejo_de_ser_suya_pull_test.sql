-- pgTAP · migración 0195 (backend-supabase#283): cuando el área se achica (le dan una zona de una de sus
-- ciudades, termina una de sus campañas), el pull avisa en out_of_area las casas de la ciudad que dejó de
-- ser suya, una sola vez, sin area_reset y sin volver a bajar nada. Las propias no se avisan; tampoco la que
-- en el tramo pasó a una de sus ciudades (baja como fila). La lista que llega en el watermark no sirve para
-- listar casas de una ciudad en la que nunca estuvo.
--
-- Como 0019, NO va en una transacción: el delta solo sirve lo commiteado. Limpia al final.

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
  select ('01920000-0000-7000-8000-0000000195' || p_sufijo)::uuid;
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

-- El watermark de p_delta con otra lista de ciudades en las tres entidades (lo que mandaría un teléfono
-- que la cambió a mano).
create or replace function pg_temp.con_lista(p_delta jsonb, p_lista jsonb) returns jsonb
language sql as $$
  select jsonb_object_agg(e.k, case when e.v ? 'ciudades' then e.v || jsonb_build_object('ciudades', p_lista) else e.v end)
    from jsonb_each(p_delta -> 'watermark') e (k, v);
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Verano (e1) en c1 (zona Z1) y c2; Invierno (e2) en c3; Lejos (e9) en c9.
-- b1: Verano sin zona e Invierno (trabaja c1, c2 y c3); nunca estuvo en Lejos.
--   01 en c1                     02 en c2                    03 en c2, la registró b1
--   04 en c2, dada de baja       05 en c2 (pasa a c1)        06 en c2 (pasa a c9)
--   07 en c3                     09 en c9
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('b1'), '00000000-0000-0000-0000-000000000000',
        'authenticated', 'authenticated', 'achica-b1@example.com', 'x', now(), now(), now());

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais achica', 'ZA');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad achica uno', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Ciudad achica dos', 'Departamento de prueba', pg_temp.u('c0'), -34.7, -56.1),
  (pg_temp.u('c3'), 'Ciudad achica tres', 'Departamento de prueba', pg_temp.u('c0'), -34.8, -56.0),
  (pg_temp.u('c9'), 'Ciudad achica lejos', 'Departamento de prueba', pg_temp.u('c0'), -33.0, -55.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'Verano achica', 'VERANO', current_date - 10, current_date + 30),
  (pg_temp.u('e2'), 'Invierno achica', 'VERANO', current_date - 10, current_date + 30),
  (pg_temp.u('e9'), 'Lejos achica', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e2'), pg_temp.u('c3')),
  (pg_temp.u('f9'), pg_temp.u('e9'), pg_temp.u('c9'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  (pg_temp.u('d1'), 'Z1', pg_temp.u('f1'), 'RADIAL', -34.90, -56.20, 300);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e2'), pg_temp.u('b1'), null);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at) values
  (pg_temp.u('01'), 'CASA', 'Rivera', '1', -34.90, -56.20, pg_temp.u('c1'), null, null),
  (pg_temp.u('02'), 'CASA', 'Artigas', '2', -34.70, -56.10, pg_temp.u('c2'), null, null),
  (pg_temp.u('03'), 'CASA', 'Propia', '3', -34.70, -56.11, pg_temp.u('c2'), pg_temp.u('b1'), null),
  (pg_temp.u('04'), 'CASA', 'Artigas', '4', -34.70, -56.12, pg_temp.u('c2'), null, now()),
  (pg_temp.u('05'), 'CASA', 'Artigas', '5', -34.70, -56.13, pg_temp.u('c2'), null, null),
  (pg_temp.u('06'), 'CASA', 'Artigas', '6', -34.70, -56.14, pg_temp.u('c2'), null, null),
  (pg_temp.u('07'), 'CASA', 'Colonia', '7', -34.80, -56.00, pg_temp.u('c3'), null, null),
  (pg_temp.u('09'), 'CASA', 'Lejos', '9', -33.00, -55.00, pg_temp.u('c9'), null, null);

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select prosecdef from pg_proc
            where oid = 'public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(uuid[], xid8, uuid, xid8, uuid)'::regprocedure),
          true, 'el helper es SECURITY DEFINER (la RLS ya no muestra las casas de la ciudad que se fue)');
select ok(has_function_privilege('authenticated',
            'public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(uuid[], xid8, uuid, xid8, uuid)', 'execute'),
          'authenticated lo ejecuta (sync.pull es INVOKER)');
select ok(not has_function_privilege('anon',
            'public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(uuid[], xid8, uuid, xid8, uuid)', 'execute'),
          'anon no');
select has_index('public', 'ubicacion', 'ubicacion_ciudad_idx', array['ciudad_id'],
                 'índice por ciudad: el aviso busca las casas de la ciudad, también las dadas de baja');

-- ---------------------------------------------------------------------------
-- 2. Primer pull: c1, c2 y c3, sin avisos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['ubicacion', 'espacio', 'house_status'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['01','02','03','04','05','06','07'], 'b1 (sin zona) baja c1, c2 y c3; no c9') from p1;
select ok(not (d ? 'out_of_area') and not (d ? 'area_reset'), 'el primer pull no lleva avisos') from p1;

-- ---------------------------------------------------------------------------
-- 3. Le dan una zona de c1: c2 deja de ser suya (cada cambio en su transacción)
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.campania_colportor set zona_id = pg_temp.u('d1')
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
update public.ubicacion set ciudad_id = pg_temp.u('c1'), lat = -34.90, lon = -56.21 where id = pg_temp.u('05');
update public.ubicacion set ciudad_id = pg_temp.u('c9'), lat = -33.00, lon = -55.01 where id = pg_temp.u('06');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from p1), 1000) as d;
select ok(not (d ? 'area_reset'), 'la lista se achica (c1, c2 y c3 → c1 y c3): sin area_reset (0023)') from p2;
select is(pg_temp.fuera(d), array['02','04','06'],
          'out_of_area trae las casas de c2 (también la dada de baja y la que se fue a c9), no la propia ni la que pasó a c1')
  from p2;
select is(pg_temp.filas(d), array['05'], 'la que pasó a c1 baja como fila; no vuelve a bajar nada más') from p2;
select is(d -> 'watermark' -> 'ubicacion' -> 'ciudades', jsonb_build_array(pg_temp.u('c1'), pg_temp.u('c3')),
          'el watermark guarda la lista nueva') from p2;
select ok(not (d -> 'out_of_area' ? 'espacio') and not (d -> 'out_of_area' ? 'house_status'),
          'el aviso es de ubicacion, como desde 0016') from p2;

create temp table p3 as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from p2), 1000) as d;
select ok(not (d ? 'out_of_area') and not (d ? 'area_reset'), 'una sola vez: el pull siguiente no avisa nada') from p3;

-- La lista vieja otra vez (un teléfono que no aplicó la respuesta): vuelve el mismo aviso.
select is(pg_temp.fuera(sync.pull(array['ubicacion'], (select d -> 'watermark' from p1), 1000)), array['02','04','06'],
          'sin aplicar la respuesta, el pull repite el aviso');

-- ---------------------------------------------------------------------------
-- 4. Termina Invierno: c3 deja de ser suya
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.campania set fecha_fin = current_date - 1 where id = pg_temp.u('e2');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p4 as
select sync.pull(array['ubicacion', 'espacio', 'house_status'], (select d -> 'watermark' from p3), 1000) as d;
select ok(not (d ? 'area_reset'), 'termina una de sus campañas (c1 y c3 → c1): sin area_reset') from p4;
select is(pg_temp.fuera(d), array['07'], 'out_of_area trae la casa de c3') from p4;

-- ---------------------------------------------------------------------------
-- 5. La lista del watermark no sirve para listar casas de cualquier ciudad
-- ---------------------------------------------------------------------------
-- c9 es de una campaña en la que b1 nunca estuvo: aunque el watermark la nombre, no se avisa (09 sigue
-- afuera del aviso; 06, que estaba en c2, tampoco: c2 no está en esta lista). Un elemento que no es un id
-- no rompe nada.
create temp table p5 as
select sync.pull(array['ubicacion'],
                 pg_temp.con_lista((select d from p4),
                                   jsonb_build_array(pg_temp.u('c1'), pg_temp.u('c3'), pg_temp.u('c9'), 'no-es-un-id')),
                 1000) as d;
select ok(not (d ? 'area_reset'), 'una lista con c9 y un elemento raro, que contiene la de ahora: sin reinicio ni error') from p5;
select is(pg_temp.fuera(d), array['07'], 'solo se avisa c3 (estuvo inscripto en Invierno); c9 no') from p5;
select is((select count(*)::int
             from public.ubicaciones_de_ciudades_que_dejaron_de_ser_suyas(
                    array[pg_temp.u('c9')], '0'::xid8, '00000000-0000-0000-0000-000000000000'::uuid,
                    '0'::xid8, '00000000-0000-0000-0000-000000000000'::uuid)),
          0, 'llamado directo por PostgREST con una ciudad ajena: no devuelve nada');

-- ---------------------------------------------------------------------------
-- 6. Se achica y crece a la vez: arranca de cero, y el motor marca lo que no vuelve a bajar
-- ---------------------------------------------------------------------------
-- La lista guardada era solo c2 (inventada) y hoy es c1: apareció una ciudad, hay reinicio y no hace
-- falta el aviso.
create temp table p6 as
select sync.pull(array['ubicacion'], pg_temp.con_lista((select d from p4), jsonb_build_array(pg_temp.u('c2'))), 1000) as d;
select is(d -> 'area_reset', '["ubicacion"]'::jsonb, 'de c2 a c1: area_reset') from p6;
select ok(not (d ? 'out_of_area'), 'y sin out_of_area: con el reinicio lo deduce el motor') from p6;

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table p1, p2, p3, p4, p5, p6;
delete from public.ubicacion where id::text like '01920000-0000-7000-8000-0000000195%';
delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e9'));
delete from public.zona where id = pg_temp.u('d1');
delete from public.campania_ciudad where id in (pg_temp.u('f1'), pg_temp.u('f2'), pg_temp.u('f3'), pg_temp.u('f9'));
delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e9'));
delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('c3'), pg_temp.u('c9'));
delete from public.pais where id = pg_temp.u('c0');
delete from auth.users where id = pg_temp.u('b1');

select * from finish();
