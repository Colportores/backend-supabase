-- pgTAP · políticas RLS de la migración 0001
-- Simula JWTs de dos colportores y verifica el aislamiento básico. Las políticas se refinan
-- HU por HU desde Sprint 3; acá se fija el piso: nadie ve ni escribe lo del otro.
begin;
select * from no_plan();

-- --- fixtures (como postgres, sin RLS) ---------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000000a1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ana@example.com', 'x', now(), now()),
  ('01920000-0000-7000-8000-0000000000a2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'beto@example.com', 'x', now(), now());

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000000c0', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000000c1', 'Montevideo', '01920000-0000-7000-8000-0000000000c0', -34.9, -56.16);
insert into public.zona (id, nombre, ciudad_id) values
  ('01920000-0000-7000-8000-0000000000d1', 'Zona Ana',  '01920000-0000-7000-8000-0000000000c1'),
  ('01920000-0000-7000-8000-0000000000d2', 'Zona Beto', '01920000-0000-7000-8000-0000000000c1');
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000000d1' where id = '01920000-0000-7000-8000-0000000000a1';
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000000d2' where id = '01920000-0000-7000-8000-0000000000a2';

insert into public.producto (id, nombre, tipo) values ('01920000-0000-7000-8000-0000000000e1', 'Libro', 'LIBRO');

-- --- helper: actuar como un usuario autenticado --------------------------------
-- Se setean las dos formas del claim: `request.jwt.claims` (PostgREST ≥ 9, auth.uid() de los
-- proyectos hosteados) y `request.jwt.claim.sub` (la que lee auth.uid() de la imagen base).
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- --- Ana crea su jornada y una ubicación en su zona --------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a1');

select lives_ok(
  $$ insert into public.jornada (id, inicio) values ('01920000-0000-7000-8000-0000000000f1', now()) $$,
  'Ana crea una jornada (colportor_id por default = auth.uid())'
);
select is((select colportor_id from public.jornada where id = '01920000-0000-7000-8000-0000000000f1'),
          '01920000-0000-7000-8000-0000000000a1'::uuid, 'colportor_id se rellena con auth.uid()');

select lives_ok(
  $$ insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id)
     values ('01920000-0000-7000-8000-0000000000f2', 'CASA', 'Av. 18 de Julio', '1000', -34.9, -56.18,
             '01920000-0000-7000-8000-0000000000c1', '01920000-0000-7000-8000-0000000000d1') $$,
  'Ana crea una ubicación en su zona'
);

select throws_ok(
  $$ insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id)
     values ('01920000-0000-7000-8000-0000000000f3', 'CASA', 'Otra', '1', -34.9, -56.18,
             '01920000-0000-7000-8000-0000000000c1', '01920000-0000-7000-8000-0000000000d2') $$,
  '42501', null,
  'Ana NO puede crear una ubicación en la zona de Beto'
);

select throws_ok(
  $$ insert into public.jornada (id, inicio, colportor_id)
     values ('01920000-0000-7000-8000-0000000000f4', now(), '01920000-0000-7000-8000-0000000000a2') $$,
  '42501', null,
  'Ana NO puede crear una jornada a nombre de Beto'
);

select is((select count(*) from public.producto), 1::bigint, 'Ana lee el catálogo');
select throws_ok(
  $$ insert into public.producto (nombre, tipo) values ('Pirata', 'LIBRO') $$,
  '42501', null,
  'Ana (sin rol ADMIN) NO puede escribir el catálogo'
);

select throws_ok(
  $$ delete from public.jornada where id = '01920000-0000-7000-8000-0000000000f1' $$,
  '42501', null,
  'authenticated no puede DELETE físico'
);

-- --- Beto no ve lo de Ana --------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000000a2');

select is((select count(*) from public.jornada), 0::bigint, 'Beto no ve las jornadas de Ana');
select is((select count(*) from public.ubicacion), 0::bigint, 'Beto no ve ubicaciones fuera de su zona');
select is((select count(*) from public.usuario where id = '01920000-0000-7000-8000-0000000000a1'), 0::bigint,
          'Beto no ve el perfil de Ana');
select is((select count(*) from public.usuario where id = '01920000-0000-7000-8000-0000000000a2'), 1::bigint,
          'Beto ve su propio perfil');

-- --- anon no ve nada ----------------------------------------------------------------
select set_config('role', 'anon', true);
select throws_ok($$ select count(*) from public.producto $$, '42501', null, 'anon no puede leer ni el catálogo');

select * from finish();
rollback;
