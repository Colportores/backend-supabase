-- pgTAP · lecturas del panel (migración 0007, HU-CAM-004/006)
-- zonas_asignables() y colportores_de_campania(): acceso (permiso primero), errores y cada
-- filtro, con los mismos criterios que motivo_rechazo_zona() / asignar_zona().
begin;
select * from no_plan();

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

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Verano y de Vieja (Montevideo), a2 coordinador de Salto y de
--        Otoño (Montevideo), ad admin, a0 colportor.
-- Inscriptos en Verano: b1 (Zeta, zona Cordón), b6 (Ana, sin zona), b7 (Beto, con una zona
--        que después se borra). b2 borrada, b5 dada de baja, b3 en Salto, b4 en Vieja.
-- Zonas (Montevideo salvo d3): d1 Centro (libre)  d2 Cordón (de Verano)  d3 Salto centro
--        d4 Pocitos (de Otoño)  d5 Borrada (libre, borrada)  d6 Ajena (de Vieja)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000009' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'lect-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','ad','b1','b2','b3','b4','b5','b6','b7']) s;

update public.usuario set nombre = x.n, apellido = x.a
  from (values ('b1','Uno','Zeta'), ('b6','Ana','Alfa'), ('b7','Beto','Beta')) x(s, n, a)
 where id = ('01920000-0000-7000-8000-0000000009' || x.s)::uuid;

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000009' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000009c0', 'Pais lect', 'ZL');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000009c1', 'Montevideo lect', '01920000-0000-7000-8000-0000000009c0', -34.9, -56.16),
  ('01920000-0000-7000-8000-0000000009c2', 'Salto lect',      '01920000-0000-7000-8000-0000000009c0', -31.4, -57.96);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, ciudad_id, coordinador_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000009e1', 'Verano',  'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009a1', null),
  ('01920000-0000-7000-8000-0000000009e2', 'Salto',   'VERANO',     current_date - 10, null,              '01920000-0000-7000-8000-0000000009c2', '01920000-0000-7000-8000-0000000009a2', null),
  ('01920000-0000-7000-8000-0000000009e3', 'Vieja',   'VERANO',     current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009a1', null),
  ('01920000-0000-7000-8000-0000000009e4', 'Borrada', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009a1', now()),
  ('01920000-0000-7000-8000-0000000009e5', 'Otoño',   'PERMANENTE', current_date - 10, null,              '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009a2', null);

insert into public.zona (id, nombre, ciudad_id, campania_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000009d1', 'Centro',       '01920000-0000-7000-8000-0000000009c1', null, null),
  ('01920000-0000-7000-8000-0000000009d2', 'Cordón',       '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009e1', null),
  ('01920000-0000-7000-8000-0000000009d3', 'Salto centro', '01920000-0000-7000-8000-0000000009c2', null, null),
  ('01920000-0000-7000-8000-0000000009d4', 'Pocitos',      '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009e5', null),
  ('01920000-0000-7000-8000-0000000009d5', 'Borrada',      '01920000-0000-7000-8000-0000000009c1', null, now()),
  ('01920000-0000-7000-8000-0000000009d6', 'Ajena',        '01920000-0000-7000-8000-0000000009c1', '01920000-0000-7000-8000-0000000009e3', null),
  ('01920000-0000-7000-8000-0000000009d7', 'Zona de Beto', '01920000-0000-7000-8000-0000000009c1', null, null);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b1', '01920000-0000-7000-8000-0000000009d2', null),
  ('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b6', null, null),
  ('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b7', '01920000-0000-7000-8000-0000000009d7', null),
  ('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b2', null, now()),
  ('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b5', null, null),
  ('01920000-0000-7000-8000-0000000009e2', '01920000-0000-7000-8000-0000000009b3', null, null),
  ('01920000-0000-7000-8000-0000000009e3', '01920000-0000-7000-8000-0000000009b4', null, null);

update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000009b5';
-- La zona de Beto se borra después de asignada: la lectura no la muestra.
update public.zona set deleted_at = now() where id = '01920000-0000-7000-8000-0000000009d7';

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select prosecdef from pg_proc where oid = 'public.zonas_asignables(uuid)'::regprocedure),
          true, 'zonas_asignables() es SECURITY DEFINER');
select is((select proconfig from pg_proc where oid = 'public.zonas_asignables(uuid)'::regprocedure),
          array['search_path=""'], 'zonas_asignables() fija search_path vacío');
select is((select proconfig from pg_proc where oid = 'public.colportores_de_campania(uuid)'::regprocedure),
          array['search_path=""'], 'colportores_de_campania() fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.zonas_asignables(uuid)', 'execute'),
          'authenticated ejecuta zonas_asignables()');
select ok(has_function_privilege('authenticated', 'public.colportores_de_campania(uuid)', 'execute'),
          'authenticated ejecuta colportores_de_campania()');
select ok(not has_function_privilege('anon', 'public.zonas_asignables(uuid)', 'execute'),
          'anon NO ejecuta zonas_asignables()');
select ok(not has_function_privilege('anon', 'public.colportores_de_campania(uuid)', 'execute'),
          'anon NO ejecuta colportores_de_campania()');
-- Sin datos personales de más: ninguna columna de retorno se llama email.
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.zonas_asignables(uuid)'::regprocedure, 'public.colportores_de_campania(uuid)'::regprocedure)
              and (p.proargnames::text ilike '%email%')), 0, 'ninguna de las dos devuelve email');

-- ---------------------------------------------------------------------------
-- 2. Acceso: permiso primero
-- ---------------------------------------------------------------------------
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'sin JWT, zonas_asignables() falla');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'sin JWT, colportores_de_campania() falla');

select set_config('role', 'anon', true);
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'anon no lista zonas asignables');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'anon no lista colportores');
select set_config('role', 'postgres', true);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009a0');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'un colportor no lista zonas asignables');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'un colportor no lista colportores');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009a2');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'el coordinador de otra campaña no lista zonas asignables');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e1') $$,
  '42501', null, 'el coordinador de otra campaña no lista colportores');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña (mismos códigos que asignar_zona)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009a1');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000009ff') $$,
  'CZ001', null, 'campaña inexistente: CZ001 (zonas)');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e4') $$,
  'CZ001', null, 'campaña borrada: CZ001 (colportores)');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000009e3') $$,
  'CZ002', null, 'campaña no vigente: CZ002 (zonas)');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e3') $$,
  'CZ002', null, 'campaña no vigente: CZ002 (colportores)');

-- ---------------------------------------------------------------------------
-- 4. zonas_asignables: cada filtro
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select id, nombre, de_esta_campania from public.zonas_asignables('01920000-0000-7000-8000-0000000009e1') $$,
  $$ values ('01920000-0000-7000-8000-0000000009d1'::uuid, 'Centro'::text, false),
            ('01920000-0000-7000-8000-0000000009d2'::uuid, 'Cordón'::text, true) $$,
  'el coordinador ve las de su ciudad sin campaña o de la suya; no ve otra ciudad (CZ005), ajenas (CZ006) ni borradas'
);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009ad');
select results_eq(
  $$ select id from public.zonas_asignables('01920000-0000-7000-8000-0000000009e2') $$,
  $$ values ('01920000-0000-7000-8000-0000000009d3'::uuid) $$,
  'un ADMIN lista las de cualquier campaña: solo las de la ciudad de Salto'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009a2');
select results_eq(
  $$ select id from public.zonas_asignables('01920000-0000-7000-8000-0000000009e5') $$,
  $$ values ('01920000-0000-7000-8000-0000000009d1'::uuid), ('01920000-0000-7000-8000-0000000009d4'::uuid) $$,
  'para Otoño: la libre y la propia (no la de Verano ni la de Vieja)'
);

-- Consistencia con la regla: cada zona listada la acepta motivo_rechazo_zona() (como servidor no hay JWT,
-- así que se prueba asignando de verdad).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009a1');
select lives_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b6', '01920000-0000-7000-8000-0000000009d1') $$,
  'una zona listada se puede asignar'
);
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000009e1', '01920000-0000-7000-8000-0000000009b6', '01920000-0000-7000-8000-0000000009d6') $$,
  'CZ006', null, 'una zona no listada (de otra campaña) no se puede asignar'
);

-- ---------------------------------------------------------------------------
-- 5. colportores_de_campania: cada filtro
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select usuario_id, nombre, apellido, zona_id, zona_nombre
       from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e1') $$,
  $$ values ('01920000-0000-7000-8000-0000000009b6'::uuid, 'Ana'::text, 'Alfa'::text, '01920000-0000-7000-8000-0000000009d1'::uuid, 'Centro'::text),
            ('01920000-0000-7000-8000-0000000009b7'::uuid, 'Beto'::text, 'Beta'::text, null::uuid, null::text),
            ('01920000-0000-7000-8000-0000000009b1'::uuid, 'Uno'::text, 'Zeta'::text, '01920000-0000-7000-8000-0000000009d2'::uuid, 'Cordón'::text) $$,
  'solo inscriptos vivos de esa campaña (sin borrada, dada de baja ni de otra), con su zona actual (la borrada sale null), ordenados por apellido'
);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009ad');
select results_eq(
  $$ select usuario_id from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e2') $$,
  $$ values ('01920000-0000-7000-8000-0000000009b3'::uuid) $$,
  'un ADMIN lista los de cualquier campaña vigente'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000009a2');
select is_empty(
  $$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000009e5') $$,
  'campaña sin inscriptos: lista vacía, no error'
);

select * from finish();
rollback;
