-- pgTAP · la zona del colportor vive solo en su inscripción (migración 0009, backend-supabase#23)
-- Sin usuario.zona_id; la zona de una inscripción es de una ciudad viva de la misma campaña
-- (por el RPC y fuera de él); mis_zonas() sin zonas borradas ni campañas vencidas. La
-- migración con datos está en supabase/tests_migracion/0009_*.
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

-- --- fixtures (como postgres) --------------------------------------------------
-- Verano (a1) abarca Montevideo (f1) y Las Piedras (f2); Otra (a2) está en Montevideo (f3);
-- Vencida terminó (f4). Zonas: d1 Centro y d5 Cordón (f1), d2 Las Piedras (f2), d3 De Otra
-- (f3), d4 Borrada (f1, dada de baja), d6 Vieja (f4).
-- Colportores: b1 y b4 en Verano, b3 en Vencida con la zona d6.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000012' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'insc-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','b1','b3','b4']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000012' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000012c0', 'Pais insc', 'ZI');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000012c1', 'Montevideo insc',  '01920000-0000-7000-8000-0000000012c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-0000000012c2', 'Las Piedras insc', '01920000-0000-7000-8000-0000000012c0', -34.73, -56.22);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000012e1', 'Verano',  'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000012a1'),
  ('01920000-0000-7000-8000-0000000012e2', 'Otra',    'PERMANENTE', current_date - 10, null,              '01920000-0000-7000-8000-0000000012a2'),
  ('01920000-0000-7000-8000-0000000012e3', 'Vencida', 'VERANO',     current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000012a1');

insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000012f1', '01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012c1'),
  ('01920000-0000-7000-8000-0000000012f2', '01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012c2'),
  ('01920000-0000-7000-8000-0000000012f3', '01920000-0000-7000-8000-0000000012e2', '01920000-0000-7000-8000-0000000012c1'),
  ('01920000-0000-7000-8000-0000000012f4', '01920000-0000-7000-8000-0000000012e3', '01920000-0000-7000-8000-0000000012c1');

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, deleted_at) values
  ('01920000-0000-7000-8000-0000000012d1', 'Centro',      '01920000-0000-7000-8000-0000000012f1', 'RADIAL', -34.90, -56.18, 300, null),
  ('01920000-0000-7000-8000-0000000012d5', 'Cordón',      '01920000-0000-7000-8000-0000000012f1', 'RADIAL', -34.90, -56.14, 300, null),
  ('01920000-0000-7000-8000-0000000012d2', 'Las Piedras', '01920000-0000-7000-8000-0000000012f2', 'RADIAL', -34.73, -56.22, 300, null),
  ('01920000-0000-7000-8000-0000000012d3', 'De Otra',     '01920000-0000-7000-8000-0000000012f3', 'RADIAL', -34.90, -56.18, 300, null),
  ('01920000-0000-7000-8000-0000000012d4', 'Borrada',     '01920000-0000-7000-8000-0000000012f1', 'RADIAL', -34.90, -56.10, 300, now()),
  ('01920000-0000-7000-8000-0000000012d6', 'Vieja',       '01920000-0000-7000-8000-0000000012f4', 'RADIAL', -34.90, -56.18, 300, null);

insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b1', null),
  ('01920000-0000-7000-8000-0000000012e3', '01920000-0000-7000-8000-0000000012b3', '01920000-0000-7000-8000-0000000012d6');

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select hasnt_column('public', 'usuario', 'zona_id', 'usuario.zona_id ya no existe');
select hasnt_trigger('public', 'usuario', 'usuario_zona_servidor', 'ni su trigger');
select ok(not exists (select 1 from pg_proc where proname = 'tg_usuario_zona_servidor'), 'ni su función');
select has_trigger('public', 'campania_colportor', 'campania_colportor_zona_valida',
                   'campania_colportor valida la zona fuera del RPC');

-- ---------------------------------------------------------------------------
-- 2. Por el RPC
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000012a1');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b1', '01920000-0000-7000-8000-0000000012d3') $$,
  'CZ006', 'La zona es de otra campaña. Elegí una zona de «Verano».', 'zona de otra campaña → CZ006, y dice de qué campaña elegir');
select is(
  (select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b1', '01920000-0000-7000-8000-0000000012d1')),
  '01920000-0000-7000-8000-0000000012d1'::uuid, 'campaña con dos ciudades: zona de Montevideo → ok');
select is(
  (select zona_id from public.asignar_zona('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b1', '01920000-0000-7000-8000-0000000012d2')),
  '01920000-0000-7000-8000-0000000012d2'::uuid, 'campaña con dos ciudades: zona de Las Piedras → ok');
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b1', '01920000-0000-7000-8000-0000000012d4') $$,
  'CZ004', 'La zona no existe o ya se dio de baja. Recargá el mapa.', 'zona dada de baja → CZ004, con el aviso del mapa');

-- ---------------------------------------------------------------------------
-- 3. Fuera del RPC (trigger)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id, zona_id)
     values ('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b4', '01920000-0000-7000-8000-0000000012d3') $$,
  'CZ006', 'La zona es de otra campaña. Elegí una zona de «Verano».', 'INSERT directo con zona de otra campaña → CZ006');
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id, zona_id)
     values ('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b4', '01920000-0000-7000-8000-0000000012d4') $$,
  'CZ004', null, 'INSERT directo con una zona dada de baja → CZ004');
select lives_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id, zona_id)
     values ('01920000-0000-7000-8000-0000000012e1', '01920000-0000-7000-8000-0000000012b4', null) $$,
  'INSERT directo sin zona (null = «sin zona») → ok');
select throws_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000012d3'
      where usuario_id = '01920000-0000-7000-8000-0000000012b1' $$,
  'CZ006', null, 'UPDATE directo a una zona de otra campaña → CZ006, aunque sea un proceso servidor');
select lives_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000012d5'
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'UPDATE directo a una zona de la misma campaña → ok');
select lives_ok(
  $$ update public.campania_colportor set zona_id = null
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'dejar sin zona → ok');

-- Una ciudad quitada de la campaña: su zona no se asigna (CZ005).
update public.campania_ciudad set deleted_at = now() where id = '01920000-0000-7000-8000-0000000012f2';
select throws_ok(
  $$ update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000012d2'
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'CZ005', 'La ciudad de esa zona ya no está en «Verano». Elegí una zona de otra ciudad de la campaña o volvé a agregar la ciudad.',
  'zona de una ciudad quitada de la campaña → CZ005, con qué hacer');
-- Una fila que ya tenía esa zona no se bloquea por un cambio que no toca la zona.
select lives_ok(
  $$ update public.campania_colportor set meta_libros = 30
      where usuario_id = '01920000-0000-7000-8000-0000000012b1' $$,
  'cambiar meta_libros no revalida una zona que no cambió');

-- ---------------------------------------------------------------------------
-- 4. mis_zonas()
-- ---------------------------------------------------------------------------
-- b1 tiene Las Piedras (d2), cuya ciudad se acaba de quitar: no le abre nada.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000012b1');
select is((select count(*) from public.mis_zonas()), 0::bigint,
          'mis_zonas() no devuelve la zona de una ciudad quitada de la campaña');

select pg_temp.actuar_como_servidor();
update public.campania_ciudad set deleted_at = null where id = '01920000-0000-7000-8000-0000000012f2';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000012b1');
select results_eq($$ select * from public.mis_zonas() $$,
                  $$ values ('01920000-0000-7000-8000-0000000012d2'::uuid) $$,
                  'mis_zonas() devuelve la zona viva de la inscripción vigente');

-- La zona se da de baja (directo, como servidor: baja_zona() no deja con asignados).
select pg_temp.actuar_como_servidor();
update public.zona set deleted_at = now() where id = '01920000-0000-7000-8000-0000000012d2';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000012b1');
select is((select count(*) from public.mis_zonas()), 0::bigint,
          'mis_zonas() no devuelve una zona dada de baja (antes seguía dando acceso)');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000012b3');
select is((select count(*) from public.mis_zonas()), 0::bigint,
          'mis_zonas() no devuelve la zona de una campaña vencida');

-- ---------------------------------------------------------------------------
-- 5. Reactivar una inscripción revalida su zona (solo por el camino de servidor: con JWT,
--    0005 no deja reactivar)
-- ---------------------------------------------------------------------------
-- Mientras la inscripción de b4 está de baja nadie la cuenta como asignada, y su zona
-- (Cordón) se da de baja. Al reactivarla con esa zona se rechaza y dice qué hacer.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000012d5'
 where usuario_id = '01920000-0000-7000-8000-0000000012b4';
update public.campania_colportor set deleted_at = now()
 where usuario_id = '01920000-0000-7000-8000-0000000012b4';
update public.zona set deleted_at = now() where id = '01920000-0000-7000-8000-0000000012d5';
select throws_ok(
  $$ update public.campania_colportor set deleted_at = null
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'CZ004', 'La inscripción que se reactiva tiene la zona «Cordón», que ya se dio de baja. Reactivala sin zona (zona_id = null) y asignale otra con asignar_zona().',
  'reactivar una inscripción cuya zona se dio de baja → CZ004, con qué hacer');
select lives_ok(
  $$ update public.campania_colportor set deleted_at = null, zona_id = null
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'reactivarla sin zona → ok');

-- Lo mismo con la ciudad de su zona quitada de la campaña (CZ005).
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000012d1'
 where usuario_id = '01920000-0000-7000-8000-0000000012b4';
update public.campania_colportor set deleted_at = now()
 where usuario_id = '01920000-0000-7000-8000-0000000012b4';
update public.campania_ciudad set deleted_at = now() where id = '01920000-0000-7000-8000-0000000012f1';
select throws_ok(
  $$ update public.campania_colportor set deleted_at = null
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'CZ005', 'La inscripción que se reactiva tiene la zona «Centro», que es de una ciudad que se quitó de la campaña. Reactivala sin zona (zona_id = null) y asignale otra con asignar_zona().',
  'reactivar una inscripción cuya zona es de una ciudad quitada → CZ005, con qué hacer');

-- Con la zona todavía válida, la reactivación la conserva (no se borra en silencio).
update public.campania_ciudad set deleted_at = null where id = '01920000-0000-7000-8000-0000000012f1';
select lives_ok(
  $$ update public.campania_colportor set deleted_at = null
      where usuario_id = '01920000-0000-7000-8000-0000000012b4' $$,
  'reactivar una inscripción con una zona viva → ok');
select is(
  (select zona_id from public.campania_colportor where usuario_id = '01920000-0000-7000-8000-0000000012b4'),
  '01920000-0000-7000-8000-0000000012d1'::uuid,
  'la inscripción reactivada conserva su zona');

select * from finish();
rollback;
