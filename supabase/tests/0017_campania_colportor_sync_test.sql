-- pgTAP · migración 0014 (backend-supabase#40): campania_colportor en el pull, solo las
-- inscripciones propias, con los cambios de zona (asignar, quitar, baja de la zona).
--
-- Como 0004 y 0014, NO va en una transacción: el delta solo sirve filas commiteadas. Limpia
-- al final.

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

-- Una columna de las filas de campania_colportor de un pull, ordenadas por campaña.
create or replace function pg_temp.col(p_delta jsonb, p_col text) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> p_col, '-') order by e ->> 'campania_id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'campania_colportor', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Verano (e1, vigente, coordina a1), Vieja (e2, terminada), Otra
-- (e3, vigente). Zonas Z1 y Z2 en Verano.
--   b1: Verano con Z1, Vieja, y Otra dada de baja.   b2: Verano sin zona.
--   a1 (coordinador de Verano): también inscripto en Otra, sin zona.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000017' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'insc-sync-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000017a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000017c0', 'Pais insc sync', 'ZW');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000017c1', 'Ciudad insc sync', '01920000-0000-7000-8000-0000000017c0', -34.9, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000017e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000017a1'),
  ('01920000-0000-7000-8000-0000000017e2', 'Vieja',  'VERANO',     current_date - 90, current_date - 30, null),
  ('01920000-0000-7000-8000-0000000017e3', 'Otra',   'PERMANENTE', current_date - 10, null,              null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000017f1', '01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017c1'),
  ('01920000-0000-7000-8000-0000000017f2', '01920000-0000-7000-8000-0000000017e2', '01920000-0000-7000-8000-0000000017c1'),
  ('01920000-0000-7000-8000-0000000017f3', '01920000-0000-7000-8000-0000000017e3', '01920000-0000-7000-8000-0000000017c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000017d1', 'Z1', '01920000-0000-7000-8000-0000000017f1', 'RADIAL', -34.88, -56.16, 300),
  ('01920000-0000-7000-8000-0000000017d2', 'Z2', '01920000-0000-7000-8000-0000000017f1', 'RADIAL', -34.92, -56.16, 300);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, meta_libros, deleted_at) values
  ('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017b1', '01920000-0000-7000-8000-0000000017d1', 120, null),
  ('01920000-0000-7000-8000-0000000017e2', '01920000-0000-7000-8000-0000000017b1', null, null, null),
  ('01920000-0000-7000-8000-0000000017e3', '01920000-0000-7000-8000-0000000017b1', null, null, now()),
  ('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017b2', null, null, null),
  ('01920000-0000-7000-8000-0000000017e3', '01920000-0000-7000-8000-0000000017a1', null, null, null);

-- ---------------------------------------------------------------------------
-- 1. El registro
-- ---------------------------------------------------------------------------
select is((select array[permite_push::text, columna_duenio] from sync.entidad where nombre = 'campania_colportor'),
          array['false', 'usuario_id'], 'campania_colportor es pull (solo lectura) y baja solo lo del dueño (usuario_id)');
select has_index('public', 'campania_colportor', 'campania_colportor_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'índice de delta por dueño');

-- ---------------------------------------------------------------------------
-- 2. Cada uno baja sus inscripciones y nada más
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b1');
create temp table pull_b1 as
select sync.pull(array['campania_colportor'], '{}'::jsonb, 1000) as d;
select is(pg_temp.col(d, 'campania_id'),
          array['01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017e2',
                '01920000-0000-7000-8000-0000000017e3'],
          'b1 baja sus tres inscripciones: la vigente, la de la campaña terminada y la dada de baja') from pull_b1;
select is(pg_temp.col(d, 'usuario_id'),
          array['01920000-0000-7000-8000-0000000017b1', '01920000-0000-7000-8000-0000000017b1',
                '01920000-0000-7000-8000-0000000017b1'],
          'todas suyas: ni la de b2 ni la de a1') from pull_b1;
select is(pg_temp.col(d, 'zona_id'), array['01920000-0000-7000-8000-0000000017d1', '-', '-'],
          'con su zona (Z1 en Verano, sin zona en las otras)') from pull_b1;
select is((pg_temp.col(d, 'deleted_at'))[3] <> '-', true, 'la dada de baja baja como tombstone') from pull_b1;
select is(pg_temp.col(d, 'meta_libros'), array['120', '-', '-'], 'con meta_libros') from pull_b1;
select ok((select not jsonb_path_exists(d, '$.rows.campania_colportor[*].xmin_w') from pull_b1), 'xmin_w no viaja');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b2');
create temp table pull_b2 as
select sync.pull(array['campania_colportor'], '{}'::jsonb, 1000) as d;
select is(pg_temp.col(d, 'usuario_id'), array['01920000-0000-7000-8000-0000000017b2'], 'b2 baja solo la suya') from pull_b2;

-- El coordinador ve todas por la RLS (la política no se acotó: HU-CAM-005), pero su pull baja
-- solo las suyas.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017a1');
select ok((select count(*) >= 5 from public.campania_colportor), 'el coordinador ve todas las inscripciones por la RLS');
select is(pg_temp.col(sync.pull(array['campania_colportor'], '{}'::jsonb, 1000), 'usuario_id'),
          array['01920000-0000-7000-8000-0000000017a1'],
          'pero al teléfono del coordinador baja solo su inscripción');

-- ---------------------------------------------------------------------------
-- 3. Los cambios de zona llegan en el pull siguiente
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b1');
select is((select sync.pull(array['campania_colportor'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017b1',
                                '01920000-0000-7000-8000-0000000017d2') $$,
  'el coordinador le asigna Z2 a b1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b1');
create temp table pull_b1_asignada as
select sync.pull(array['campania_colportor'], (select d -> 'watermark' from pull_b1), 1000) as d;
select is(pg_temp.col(d, 'zona_id'), array['01920000-0000-7000-8000-0000000017d2'],
          'b1 recibe su inscripción con la zona nueva («Te asignaron la zona…»), y nada más') from pull_b1_asignada;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017a1');
select lives_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017b1') $$,
  'el coordinador le quita la zona');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b1');
create temp table pull_b1_quitada as
select sync.pull(array['campania_colportor'], (select d -> 'watermark' from pull_b1_asignada), 1000) as d;
select is(pg_temp.col(d, 'zona_id'), array['-'], 'b1 recibe su inscripción sin zona («Ya no tenés zona…»)')
  from pull_b1_quitada;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017b1',
                                '01920000-0000-7000-8000-0000000017d1') $$,
  'le vuelve a asignar Z1');
select lives_ok($$ select public.baja_zona('01920000-0000-7000-8000-0000000017d1') $$, 'y da de baja Z1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b1');
select is(pg_temp.col(sync.pull(array['campania_colportor'], d -> 'watermark', 1000), 'zona_id'), array['-'],
          'la baja de su zona también le llega: su inscripción, sin zona') from pull_b1_quitada;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b2');
select is((select sync.pull(array['campania_colportor'], d -> 'watermark', 1000) -> 'rows' from pull_b2), '{}'::jsonb,
          'a b2 no le llega nada de los cambios de b1');

-- ---------------------------------------------------------------------------
-- 4. La app no la escribe
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000017b1');
create temp table push_b1 as
select sync.push(jsonb_build_array(jsonb_build_object(
  'client_op_id', gen_random_uuid(), 'entity', 'campania_colportor', 'op', 'update', 'sync_version', 0,
  'payload', jsonb_build_object('id', (select id from public.campania_colportor
                                        where usuario_id = '01920000-0000-7000-8000-0000000017b1'
                                          and campania_id = '01920000-0000-7000-8000-0000000017e1'),
                                'zona_id', '01920000-0000-7000-8000-0000000017d2')))) as r;
select is((select r #>> '{results,0,outcome}' from push_b1), 'invalid', 'el push de una inscripción se rechaza');
select ok((select (r #>> '{results,0}') like '%ENTIDAD_DE_SOLO_LECTURA%' from push_b1),
          'como réplica de solo lectura');
select pg_temp.como_servidor();
select is((select zona_id from public.campania_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000017b1' and campania_id = '01920000-0000-7000-8000-0000000017e1'),
          null::uuid, 'y la zona no cambia');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table pull_b1, pull_b2, pull_b1_asignada, pull_b1_quitada, push_b1;
delete from public.campania_colportor where campania_id in ('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017e2',
                                                            '01920000-0000-7000-8000-0000000017e3');
delete from public.zona where campania_ciudad_id = '01920000-0000-7000-8000-0000000017f1';
delete from public.campania_ciudad where id in ('01920000-0000-7000-8000-0000000017f1', '01920000-0000-7000-8000-0000000017f2',
                                                '01920000-0000-7000-8000-0000000017f3');
delete from public.campania where id in ('01920000-0000-7000-8000-0000000017e1', '01920000-0000-7000-8000-0000000017e2',
                                         '01920000-0000-7000-8000-0000000017e3');
delete from public.ciudad where id = '01920000-0000-7000-8000-0000000017c1';
delete from public.pais where id = '01920000-0000-7000-8000-0000000017c0';
delete from public.usuario_rol where usuario_id = '01920000-0000-7000-8000-0000000017a1';
delete from auth.users where id in ('01920000-0000-7000-8000-0000000017a1', '01920000-0000-7000-8000-0000000017b1',
                                    '01920000-0000-7000-8000-0000000017b2');

select * from finish();
