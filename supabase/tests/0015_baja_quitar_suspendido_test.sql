-- pgTAP · migración 0012 (backend-supabase#38): asignar_zona() rechaza una cuenta suspendida y
-- conserva su zona; quitar_zona() deja sin zona («Quitar» en la vista 24); baja_zona() deja sin
-- zona a los asignados y dice cuántos y quiénes.
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

-- La zona de la inscripción viva (o dada de baja, con p_viva = false) de un colportor.
create or replace function pg_temp.zona_de(p_usuario text, p_campania text default 'e1', p_viva boolean default true)
returns uuid language sql as $$
  select cc.zona_id from public.campania_colportor cc
   where cc.usuario_id = ('01920000-0000-7000-8000-0000000015' || p_usuario)::uuid
     and cc.campania_id = ('01920000-0000-7000-8000-0000000015' || p_campania)::uuid
     and (cc.deleted_at is null) = p_viva;
$$;

create or replace function pg_temp.version_de(p_usuario text) returns bigint language sql as $$
  select cc.sync_version from public.campania_colportor cc
   where cc.usuario_id = ('01920000-0000-7000-8000-0000000015' || p_usuario)::uuid
     and cc.campania_id = '01920000-0000-7000-8000-0000000015e1';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Verano (e1, coordina a1) y Vencida (e3, terminada, a1) en Montevideo; Otra (e2, coordina a2).
-- Zonas de Verano: d1 Norte, d2 Sur, d3 Oeste (sin nadie). d4 Vieja, de Vencida.
-- Verano: b1 Uno Zeta (Norte), b2 Dos Alfa (Norte, suspendido), b3 (Sur), b4 (Norte, su
-- inscripción dada de baja), b5 (Norte, usuario dado de baja), b6 (sin zona, suspendido),
-- b9 (Sur, suspendido). Vencida: b7 (Vieja). Otra: b8 (suspendido).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000015' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'quitar-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000015' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Uno','Zeta'), ('b2','Dos','Alfa'), ('b5','Cinco','Beta')) x(s, n, a)
 where u.id = ('01920000-0000-7000-8000-0000000015' || x.s)::uuid;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000015c0', 'Pais quitar', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000015c1', 'Montevideo quitar', '01920000-0000-7000-8000-0000000015c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000015e1', 'Verano',  'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000015a1'),
  ('01920000-0000-7000-8000-0000000015e2', 'Otra',    'PERMANENTE', current_date - 10, null,              '01920000-0000-7000-8000-0000000015a2'),
  ('01920000-0000-7000-8000-0000000015e3', 'Vencida', 'VERANO',     current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000015a1');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000015f1', '01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015c1'),
  ('01920000-0000-7000-8000-0000000015f2', '01920000-0000-7000-8000-0000000015e2', '01920000-0000-7000-8000-0000000015c1'),
  ('01920000-0000-7000-8000-0000000015f3', '01920000-0000-7000-8000-0000000015e3', '01920000-0000-7000-8000-0000000015c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000015d1', 'Norte', '01920000-0000-7000-8000-0000000015f1', 'RADIAL', -34.88, -56.16, 300),
  ('01920000-0000-7000-8000-0000000015d2', 'Sur',   '01920000-0000-7000-8000-0000000015f1', 'RADIAL', -34.92, -56.16, 300),
  ('01920000-0000-7000-8000-0000000015d3', 'Oeste', '01920000-0000-7000-8000-0000000015f1', 'RADIAL', -34.90, -56.20, 300),
  ('01920000-0000-7000-8000-0000000015d4', 'Vieja', '01920000-0000-7000-8000-0000000015f3', 'RADIAL', -34.90, -56.16, 300);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at)
select ('01920000-0000-7000-8000-0000000015' || x.e)::uuid, ('01920000-0000-7000-8000-0000000015' || x.b)::uuid,
       ('01920000-0000-7000-8000-0000000015' || x.d)::uuid, case when x.baja then now() end
  from (values ('e1','b1','d1',false), ('e1','b2','d1',false), ('e1','b3','d2',false), ('e1','b4','d1',true),
               ('e1','b5','d1',false), ('e1','b6',null,false), ('e1','b9','d2',false), ('e3','b7','d4',false),
               ('e2','b8',null,false)) x(e, b, d, baja);
update public.usuario set suspendido_en = now()
 where id in ('01920000-0000-7000-8000-0000000015b2', '01920000-0000-7000-8000-0000000015b6',
              '01920000-0000-7000-8000-0000000015b8', '01920000-0000-7000-8000-0000000015b9');
update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000015b5';

-- ---------------------------------------------------------------------------
-- 1. asignar_zona() rechaza una cuenta suspendida y conserva su zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b2',
                                '01920000-0000-7000-8000-0000000015d2') $$,
  'CZ014', 'Cuenta suspendida. Pedile a un administrador que la reactive.',
  'asignarle otra zona a una cuenta suspendida → CZ014 con el aviso de la decisión');
select is(pg_temp.zona_de('b2'), '01920000-0000-7000-8000-0000000015d1'::uuid, 'y conserva la zona que tenía');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b2',
                                '01920000-0000-7000-8000-0000000015d1') $$,
  'CZ014', null, 'reasignarle la misma zona también se rechaza');
select is(pg_temp.zona_de('b2'), '01920000-0000-7000-8000-0000000015d1'::uuid, 'y la zona sigue igual');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b6',
                                '01920000-0000-7000-8000-0000000015d2') $$,
  'CZ014', null, 'a una cuenta suspendida sin zona tampoco se le asigna');
select is(pg_temp.zona_de('b6'), null::uuid, 'y sigue sin zona');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b6',
                                '01920000-0000-7000-8000-0000000015d4') $$,
  'CZ014', null, 'suspendida y con una zona de otra campaña: manda la suspensión (dato de la persona)');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b8',
                                '01920000-0000-7000-8000-0000000015d2') $$,
  'CZ003', null, 'suspendida pero no inscripta en esta campaña: CZ003 primero');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a2');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b2',
                                '01920000-0000-7000-8000-0000000015d2') $$,
  '42501', null, 'el coordinador de otra campaña no se entera de la suspensión: 42501 antes');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select is((select suspendido from public.colportores_de_campania('01920000-0000-7000-8000-0000000015e1')
            where usuario_id = '01920000-0000-7000-8000-0000000015b2'), true,
          'la lista del panel la muestra suspendida');
select is((select zona_id from public.colportores_de_campania('01920000-0000-7000-8000-0000000015e1')
            where usuario_id = '01920000-0000-7000-8000-0000000015b2'), '01920000-0000-7000-8000-0000000015d1'::uuid,
          'con su zona');

-- Reactivada, se le asigna.
select pg_temp.actuar_como_servidor();
update public.usuario set suspendido_en = null where id = '01920000-0000-7000-8000-0000000015b6';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select is((select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b6',
                                                   '01920000-0000-7000-8000-0000000015d2')),
          '01920000-0000-7000-8000-0000000015d2'::uuid, 'reactivada la cuenta, la asignación entra');

-- ---------------------------------------------------------------------------
-- 2. quitar_zona(): «Quitar» en la vista 24
-- ---------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'public.quitar_zona(uuid,uuid)', 'execute'),
          'authenticated ejecuta quitar_zona (el permiso lo decide el RPC)');
select ok(not has_function_privilege('anon', 'public.quitar_zona(uuid,uuid)', 'execute'), 'anon no');

select pg_temp.actuar_como_servidor();
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b3') $$,
  '42501', 'quitar_zona requiere un usuario autenticado', 'sin usuario autenticado → 42501');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015b1');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b1') $$,
  '42501', null, 'un colportor no se quita la zona');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a2');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b3') $$,
  '42501', null, 'el coordinador de otra campaña no quita zonas en esta');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015ef', '01920000-0000-7000-8000-0000000015b3') $$,
  'CZ001', null, 'campaña inexistente → CZ001');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e3', '01920000-0000-7000-8000-0000000015b7') $$,
  'CZ002', null, 'campaña terminada → CZ002');
select is(pg_temp.zona_de('b7', 'e3'), '01920000-0000-7000-8000-0000000015d4'::uuid, 'y la zona queda');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b8') $$,
  'CZ003', 'El colportor no está en esta campaña.', 'no inscripto en esta campaña → CZ003');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b4') $$,
  'CZ003', null, 'inscripción dada de baja → CZ003');
select is(pg_temp.zona_de('b4', 'e1', false), '01920000-0000-7000-8000-0000000015d1'::uuid,
          'y la inscripción dada de baja conserva su zona');
select throws_ok(
  $$ select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b5') $$,
  'CZ003', null, 'usuario dado de baja → CZ003');

-- El ADMIN le quita la zona a b3; b3 deja de tenerla en mis_zonas().
create temp table version_b3 on commit drop as select pg_temp.version_de('b3') as v;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015ad');
create temp table quitada on commit drop as
select public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b3') as f;
select is((select (f).zona_id from quitada), null::uuid, 'el ADMIN quita la zona: devuelve la inscripción sin zona');
select is((select (f).usuario_id from quitada), '01920000-0000-7000-8000-0000000015b3'::uuid, 'la de b3');
select pg_temp.actuar_como_servidor();
select is(pg_temp.zona_de('b3'), null::uuid, 'b3 queda sin zona');
select is(pg_temp.version_de('b3'), (select v + 1 from version_b3), 'y su inscripción sube de versión');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015b3');
select is((select count(*) from public.mis_zonas()), 0::bigint, 'mis_zonas() de b3 queda vacía');

-- Quitarla de nuevo: responde igual y no toca la fila.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select is((select zona_id from public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b3')),
          null::uuid, 'quitarle la zona a quien no tiene: responde la inscripción sin zona');
select pg_temp.actuar_como_servidor();
select is(pg_temp.version_de('b3'), (select v + 1 from version_b3), 'sin tocar la fila (no sube la versión)');

-- Una cuenta suspendida sí se puede quitar.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select is((select zona_id from public.quitar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b9')),
          null::uuid, 'a una cuenta suspendida se le puede quitar la zona');

-- Quitar solo por el RPC: el UPDATE directo sigue rechazado (0006).
select throws_ok(
  $$ update public.campania_colportor set zona_id = null
      where usuario_id = '01920000-0000-7000-8000-0000000015b1' and campania_id = '01920000-0000-7000-8000-0000000015e1' $$,
  '23514', null, 'el coordinador no quita la zona con un UPDATE directo');

-- ---------------------------------------------------------------------------
-- 3. baja_zona(): los asignados quedan sin zona
-- ---------------------------------------------------------------------------
-- Norte (d1): b1 y b2 (vivos, b2 suspendido), b4 (inscripción de baja), b5 (usuario de baja).
create temp table version_b1 on commit drop as select pg_temp.version_de('b1') as v;
create temp table previa on commit drop as
select public.baja_zona('01920000-0000-7000-8000-0000000015d1', true) as r;
select is((select r -> 'colportores_sin_zona' from previa), '2'::jsonb,
          'vista previa: 2 colportores quedarían sin zona (sin la inscripción de baja ni el usuario de baja)');
select is((select array_agg(e ->> 'apellido' order by o) from previa, jsonb_array_elements(r -> 'colportores_asignados')
             with ordinality x(e, o)),
          array['Alfa', 'Zeta'], 'y quiénes, por apellido');
select is((select r ->> 'dada_de_baja' from previa), 'false', 'sin darla de baja');
select is(pg_temp.zona_de('b1'), '01920000-0000-7000-8000-0000000015d1'::uuid, 'ni tocar a nadie');

create temp table baja on commit drop as
select public.baja_zona('01920000-0000-7000-8000-0000000015d1') as r;
select is((select r ->> 'dada_de_baja' from baja), 'true', 'con colportores asignados, la baja ya no se rechaza (antes CZ010)');
select is((select r -> 'colportores_sin_zona' from baja), '2'::jsonb, 'dice cuántos quedaron sin zona');
select is((select array_agg(e ->> 'apellido' order by o) from baja, jsonb_array_elements(r -> 'colportores_asignados')
             with ordinality x(e, o)),
          array['Alfa', 'Zeta'], 'y quiénes');
select is((select r -> 'colportores_asignados' -> 0 ->> 'usuario_id' from baja), '01920000-0000-7000-8000-0000000015b2',
          'con su usuario_id');

select pg_temp.actuar_como_servidor();
select is(pg_temp.zona_de('b1'), null::uuid, 'b1 quedó sin zona');
select is(pg_temp.zona_de('b2'), null::uuid, 'b2 (suspendido) también');
select is(pg_temp.version_de('b1'), (select v + 1 from version_b1), 'su inscripción sube de versión (es un cambio real)');
select is(pg_temp.zona_de('b5'), null::uuid, 'la inscripción viva del usuario dado de baja no queda apuntando a la zona muerta');
select is(pg_temp.zona_de('b4', 'e1', false), '01920000-0000-7000-8000-0000000015d1'::uuid,
          'la inscripción dada de baja conserva su zona (al reactivarla, 0009 pide hacerlo sin zona)');
select is(pg_temp.zona_de('b6'), '01920000-0000-7000-8000-0000000015d2'::uuid, 'quien tiene otra zona la conserva');
select ok((select deleted_at is not null from public.zona where id = '01920000-0000-7000-8000-0000000015d1'),
          'la zona quedó dada de baja');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015b1');
select is((select count(*) from public.mis_zonas()), 0::bigint, 'mis_zonas() de b1 queda vacía');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000015a1');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000015e1', '01920000-0000-7000-8000-0000000015b1',
                                '01920000-0000-7000-8000-0000000015d1') $$,
  'CZ004', null, 'la zona dada de baja ya no se asigna');

create temp table baja_vacia on commit drop as
select public.baja_zona('01920000-0000-7000-8000-0000000015d3') as r;
select is((select r -> 'colportores_sin_zona' from baja_vacia), '0'::jsonb, 'una zona sin asignados: 0 quedan sin zona');
select is((select r -> 'colportores_asignados' from baja_vacia), '[]'::jsonb, 'y la lista vacía');

select * from finish();
rollback;
