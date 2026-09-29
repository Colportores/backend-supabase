-- pgTAP · estado de la cuenta (migración 0004, HU-AUTH-008)
-- estado_cuenta() deriva PENDIENTE_ASIGNACION de campania_colportor y SUSPENDIDA de
-- usuario.suspendido_en. Un usuario por escenario: la inscripción es única por
-- (campania_id, usuario_id) y así cada caso se lee solo.
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

-- Proceso servidor: sin JWT (auth.uid() null) y como postgres, sin RLS.
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
--   b1 sin campaña            b2 campaña vencida         b3 campaña futura
--   b4 inscripción borrada    b5 vigente (sin zona)      b6 suspendido + vigente
--   b7 suspendido sin campaña b8 campaña borrada         b9 vigente con zona
--   ba admin (para fijar que tampoco cambia la marca con su JWT)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000006' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'estado-' || s || '@example.com', 'x', now(), now()
  from unnest(array['b1','b2','b3','b4','b5','b6','b7','b8','b9','ba']) s;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000006c0', 'Pais estado', 'ZE');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000006c1', 'Ciudad estado', '01920000-0000-7000-8000-0000000006c0', -34.9, -56.16);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000006e1', 'Vigente',   'VERANO',     current_date - 10, current_date + 10, '01920000-0000-7000-8000-0000000006c1', null),
  ('01920000-0000-7000-8000-0000000006e2', 'Vencida',   'VERANO',     current_date - 60, current_date - 1,  '01920000-0000-7000-8000-0000000006c1', null),
  ('01920000-0000-7000-8000-0000000006e3', 'Futura',    'INVIERNO',   current_date + 1,  current_date + 30, '01920000-0000-7000-8000-0000000006c1', null),
  ('01920000-0000-7000-8000-0000000006e4', 'Borrada',   'VERANO',     current_date - 10, current_date + 10, '01920000-0000-7000-8000-0000000006c1', now()),
  ('01920000-0000-7000-8000-0000000006e5', 'Termina hoy','PERMANENTE', current_date - 10, current_date,     '01920000-0000-7000-8000-0000000006c1', null);

insert into public.zona (id, nombre, ciudad_id, campania_id) values
  ('01920000-0000-7000-8000-0000000006d1', 'Zona vigente', '01920000-0000-7000-8000-0000000006c1', '01920000-0000-7000-8000-0000000006e5'),
  ('01920000-0000-7000-8000-0000000006d2', 'Zona directa', '01920000-0000-7000-8000-0000000006c1', null);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000006e2', '01920000-0000-7000-8000-0000000006b2', null, null),
  ('01920000-0000-7000-8000-0000000006e3', '01920000-0000-7000-8000-0000000006b3', null, null),
  ('01920000-0000-7000-8000-0000000006e1', '01920000-0000-7000-8000-0000000006b4', null, now()),
  ('01920000-0000-7000-8000-0000000006e1', '01920000-0000-7000-8000-0000000006b5', null, null),
  ('01920000-0000-7000-8000-0000000006e1', '01920000-0000-7000-8000-0000000006b6', null, null),
  ('01920000-0000-7000-8000-0000000006e4', '01920000-0000-7000-8000-0000000006b8', null, null),
  ('01920000-0000-7000-8000-0000000006e5', '01920000-0000-7000-8000-0000000006b9', '01920000-0000-7000-8000-0000000006d1', null);

update public.usuario set suspendido_en = now()
 where id in ('01920000-0000-7000-8000-0000000006b6', '01920000-0000-7000-8000-0000000006b7');
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000006d2'
 where id = '01920000-0000-7000-8000-0000000006b9';

insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000006ba', r.id from public.rol r where r.codigo = 'ADMIN';

-- ---------------------------------------------------------------------------
-- 1. Forma de la función: lo que consume el BFF
-- ---------------------------------------------------------------------------
select has_function('public', 'estado_cuenta', array[]::text[], 'existe public.estado_cuenta() sin parámetros');
select function_returns('public', 'estado_cuenta', array[]::text[], 'text', 'estado_cuenta() devuelve text');
select is(
  (select prosecdef from pg_proc where oid = 'public.estado_cuenta()'::regprocedure),
  false, 'estado_cuenta() es SECURITY INVOKER: lee usuario con la RLS del llamador'
);
select is(
  (select proconfig from pg_proc where oid = 'public.estado_cuenta()'::regprocedure),
  array['search_path=""'], 'estado_cuenta() fija search_path vacío'
);
select is(
  (select proconfig from pg_proc where oid = 'public.mis_campanias_vigentes()'::regprocedure),
  array['search_path=""'], 'mis_campanias_vigentes() fija search_path vacío'
);
select ok(has_function_privilege('authenticated', 'public.estado_cuenta()', 'execute'), 'authenticated ejecuta estado_cuenta()');
select ok(not has_function_privilege('anon', 'public.estado_cuenta()', 'execute'), 'anon NO ejecuta estado_cuenta()');
select ok(not has_function_privilege('anon', 'public.mis_campanias_vigentes()', 'execute'), 'anon NO ejecuta mis_campanias_vigentes()');

select throws_ok(
  $$ select public.estado_cuenta() $$,
  '42501', null,
  'sin JWT (auth.uid() null) estado_cuenta() falla en vez de inventar un estado'
);

-- ---------------------------------------------------------------------------
-- 2. Estados derivados
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b1');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'sin campaña → PENDIENTE_ASIGNACION');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b2');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'campaña vencida (fecha_fin ayer) → PENDIENTE_ASIGNACION');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b3');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'campaña futura (fecha_inicio mañana) → PENDIENTE_ASIGNACION');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b4');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'inscripción borrada (campania_colportor.deleted_at) → PENDIENTE_ASIGNACION');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b8');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'campaña borrada (campania.deleted_at) → PENDIENTE_ASIGNACION');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b5');
select is(public.estado_cuenta(), 'ACTIVA', 'inscripción vigente, todavía sin zona → ACTIVA');
select is((select count(*) from public.mis_zonas()), 0::bigint,
          'la misma inscripción sin zona no abre ninguna zona en mis_zonas()');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b9');
select is(public.estado_cuenta(), 'ACTIVA', 'campaña que termina hoy sigue vigente → ACTIVA');
select set_eq(
  $$ select * from public.mis_zonas() $$,
  $$ values ('01920000-0000-7000-8000-0000000006d1'::uuid), ('01920000-0000-7000-8000-0000000006d2'::uuid) $$,
  'mis_zonas() sigue sumando la zona directa y la de la inscripción vigente'
);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b6');
select is(public.estado_cuenta(), 'SUSPENDIDA', 'suspendido con campaña vigente → SUSPENDIDA');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b7');
select is(public.estado_cuenta(), 'SUSPENDIDA', 'suspendido sin campaña → SUSPENDIDA');

-- ---------------------------------------------------------------------------
-- 3. El estado ajeno no se ve
-- ---------------------------------------------------------------------------
-- b5 está ACTIVA y b6 SUSPENDIDA en la misma campaña: cada uno obtiene el suyo.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b5');
select is(public.estado_cuenta(), 'ACTIVA', 'b5 recibe su propio estado, no el de b6 (misma campaña)');
select is_empty(
  $$ select suspendido_en from public.usuario where id = '01920000-0000-7000-8000-0000000006b6' $$,
  'b5 NO lee la marca de suspensión de b6 (RLS de usuario)'
);
select is_empty(
  $$ select * from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000006b6' $$,
  'b5 NO lee la inscripción de b6 (RLS de campania_colportor)'
);

-- ---------------------------------------------------------------------------
-- 4. La marca es server-authoritative (quién suspende con su JWT: HU-ADM-003, pendiente)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b6');
select lives_ok(
  $$ update public.usuario set suspendido_en = null, nombre = 'Seis'
      where id = '01920000-0000-7000-8000-0000000006b6' $$,
  'b6 actualiza su fila mandando suspendido_en = null (no falla)'
);
select is(public.estado_cuenta(), 'SUSPENDIDA', '...pero sigue SUSPENDIDA: no se levanta la suspensión');
select is((select nombre from public.usuario where id = '01920000-0000-7000-8000-0000000006b6'), 'Seis',
          '...y el resto de la fila sí se actualiza');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b5');
update public.usuario set suspendido_en = now() where id = '01920000-0000-7000-8000-0000000006b5';
select is(public.estado_cuenta(), 'ACTIVA', 'b5 no puede marcarse suspendido a sí mismo');

-- Hasta que HU-ADM-003 decida quién suspende, tampoco un ADMIN lo hace con su JWT.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006ba');
update public.usuario set suspendido_en = null where id = '01920000-0000-7000-8000-0000000006b7';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b7');
select is(public.estado_cuenta(), 'SUSPENDIDA', 'un ADMIN con su JWT tampoco cambia la marca (pendiente HU-ADM-003)');

-- ---------------------------------------------------------------------------
-- 5. Transiciones sin estado duplicado
-- ---------------------------------------------------------------------------
-- HU-CAM-004 inscribe a b1: la cuenta queda ACTIVA sin tocar nada más.
select pg_temp.actuar_como_servidor();
insert into public.campania_colportor (campania_id, usuario_id)
values ('01920000-0000-7000-8000-0000000006e1', '01920000-0000-7000-8000-0000000006b1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b1');
select is(public.estado_cuenta(), 'ACTIVA', 'al inscribirlo en una campaña vigente, b1 pasa a ACTIVA solo');

-- Un proceso servidor (sin JWT) sí levanta la suspensión.
select pg_temp.actuar_como_servidor();
update public.usuario set suspendido_en = null where id = '01920000-0000-7000-8000-0000000006b6';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000006b6');
select is(public.estado_cuenta(), 'ACTIVA', 'un proceso servidor levanta la suspensión y b6 vuelve a ACTIVA');

select * from finish();
rollback;
