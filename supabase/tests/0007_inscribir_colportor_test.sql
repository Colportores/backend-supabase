-- pgTAP · inscribir un colportor en una campaña (migración 0005, HU-CAM-004)
-- Cada regla por el RPC (código de error propio), el INSERT directo cerrado para todos, el
-- acceso (colportor, coordinador de otra campaña, anon) y la guarda del UPDATE.
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

-- El DETAIL de un error (lo que PostgREST devuelve en `details`); throws_ok no lo mira.
create or replace function pg_temp.detalle_error(p_sql text) returns text language plpgsql as $$
declare
  v_detalle text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_detalle = pg_exception_detail;
  return v_detalle;
end $$;

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
-- Staff: a1 coordinador de "Verano" (vigente), a2 coordinador de "Salto" (vigente),
--        ad admin, a0 colportor que intenta inscribir.
-- Objetivos: b1 pendiente verificado (el caso feliz)  b2 email sin verificar
--            b3 suspendido, con una inscripción borrada en Verano
--            b4 ya inscripto en Verano     b5 inscripto en Salto
--            b6 inscripción borrada en Verano      b7 dado de baja
--            b8 para el INSERT directo             b9 para el ADMIN en Salto
-- confirmed_at: en la imagen local es una columna común; en el cloud es la generada de
-- email_confirmed_at (ver 0005).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000007' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'inscribir-' || s || '@example.com', 'x',
       case when s = 'b2' then null else now() end, now(), now()
  from unnest(array['a1','a2','ad','a0','b1','b2','b3','b4','b5','b6','b7','b8','b9']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000007' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000007c0', 'Pais inscribir', 'ZI');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000007c1', 'Ciudad inscribir', '01920000-0000-7000-8000-0000000007c0', -34.9, -56.16);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000007e1', 'Verano', 'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000007a1', null),
  ('01920000-0000-7000-8000-0000000007e2', 'Salto', 'VERANO', current_date - 10, null, '01920000-0000-7000-8000-0000000007a2', null),
  ('01920000-0000-7000-8000-0000000007e3', 'Futura', 'INVIERNO', current_date + 5, current_date + 60, '01920000-0000-7000-8000-0000000007a1', null),
  ('01920000-0000-7000-8000-0000000007e4', 'Vieja', 'VERANO', current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000007a1', null),
  ('01920000-0000-7000-8000-0000000007e5', 'Borrada', 'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000007a1', now());
insert into public.campania_ciudad (campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007c1'),
  ('01920000-0000-7000-8000-0000000007e2', '01920000-0000-7000-8000-0000000007c1'),
  ('01920000-0000-7000-8000-0000000007e3', '01920000-0000-7000-8000-0000000007c1'),
  ('01920000-0000-7000-8000-0000000007e4', '01920000-0000-7000-8000-0000000007c1'),
  ('01920000-0000-7000-8000-0000000007e5', '01920000-0000-7000-8000-0000000007c1');

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
select '01920000-0000-7000-8000-0000000007d1', 'Centro', cc.id, 'RADIAL', -34.9, -56.16, 300
  from public.campania_ciudad cc where cc.campania_id = '01920000-0000-7000-8000-0000000007e1';

insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b4', null),
  ('01920000-0000-7000-8000-0000000007e2', '01920000-0000-7000-8000-0000000007b5', null),
  ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b6', now()),
  ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b3', now());

update public.usuario set suspendido_en = now() where id = '01920000-0000-7000-8000-0000000007b3';
update public.usuario set deleted_at = now()    where id = '01920000-0000-7000-8000-0000000007b7';

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select function_returns('public', 'inscribir_colportor', array['uuid','uuid'], 'campania_colportor',
                        'inscribir_colportor(uuid, uuid) devuelve la fila de campania_colportor');
select is((select prosecdef from pg_proc where oid = 'public.inscribir_colportor(uuid,uuid)'::regprocedure),
          true, 'inscribir_colportor() es SECURITY DEFINER: es el único camino para inscribir con JWT');
select is((select proconfig from pg_proc where oid = 'public.inscribir_colportor(uuid,uuid)'::regprocedure),
          array['search_path=""'], 'inscribir_colportor() fija search_path vacío');
select is((select proconfig from pg_proc where oid = 'public.motivo_rechazo_inscripcion(uuid,uuid)'::regprocedure),
          array['search_path=""'], 'motivo_rechazo_inscripcion() fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.inscribir_colportor(uuid,uuid)', 'execute'),
          'authenticated ejecuta inscribir_colportor()');
select ok(not has_function_privilege('anon', 'public.inscribir_colportor(uuid,uuid)', 'execute'),
          'anon NO ejecuta inscribir_colportor()');
select ok(not has_function_privilege('authenticated', 'public.motivo_rechazo_inscripcion(uuid,uuid)', 'execute'),
          'authenticated NO ejecuta motivo_rechazo_inscripcion(): no se puede sondear si alguien verificó el email');
select ok(not has_function_privilege('authenticated', 'public.campanias_vigentes_de(uuid)', 'execute'),
          'authenticated NO ejecuta campanias_vigentes_de(): recibe el usuario por parámetro');
select is(
  (select count(*) from pg_policies
    where schemaname = 'public' and tablename = 'campania_colportor' and cmd in ('INSERT', 'ALL')),
  0::bigint, 'campania_colportor no tiene política INSERT: la RLS niega el INSERT directo'
);

select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'sin JWT, inscribir_colportor() falla'
);

select set_config('role', 'anon', true);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'anon no puede inscribir'
);
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id)
     values ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'anon no puede insertar en campania_colportor'
);
select set_config('role', 'postgres', true);

-- ---------------------------------------------------------------------------
-- 2. Acceso: colportor y coordinador de otra campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a0');
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'un colportor no puede inscribir (RPC)'
);
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id)
     values ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'un colportor no puede inscribir (INSERT directo)'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b3') $$,
  '42501', null, 'un colportor recibe 42501 y no CI005: no puede sondear si otro está suspendido'
);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a2');
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'el coordinador de Salto no puede inscribir en Verano (RPC)'
);
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id)
     values ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  '42501', null, 'el coordinador de Salto no puede inscribir en Verano (INSERT directo)'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b3') $$,
  '42501', null, 'el coordinador de otra campaña recibe 42501 antes que cualquier dato del usuario (no CI005)'
);

-- ---------------------------------------------------------------------------
-- 3. Reglas, como coordinador de Verano
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a1');

select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007ff', '01920000-0000-7000-8000-0000000007b1') $$,
  'CI001', 'La campaña no existe.', 'campaña inexistente → CI001'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e5', '01920000-0000-7000-8000-0000000007b1') $$,
  'CI001', null, 'campaña borrada → CI001'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e3', '01920000-0000-7000-8000-0000000007b1') $$,
  'CI002', null, 'campaña futura (no activa) → CI002'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e4', '01920000-0000-7000-8000-0000000007b1') $$,
  'CI002', null, 'campaña terminada → CI002'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007fe') $$,
  'CI003', null, 'usuario inexistente → CI003'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b7') $$,
  'CI003', null, 'usuario dado de baja → CI003'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b2') $$,
  'CI004', null, 'email sin verificar (PENDIENTE_VERIFICACION_EMAIL) → CI004'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b3') $$,
  'CI005', 'La cuenta está suspendida. Contactá al administrador.', 'usuario suspendido → CI005'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b4') $$,
  'CI006', null, 'ya inscripto en esta campaña → CI006'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b5') $$,
  'CI007', 'Está en campaña Salto. Reasignar primero.', 'inscripto en otra campaña activa → CI007 con el literal de la HU'
);
select is(
  pg_temp.detalle_error($$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b5') $$)::jsonb,
  jsonb_build_object('campania_id', '01920000-0000-7000-8000-0000000007e2', 'campania_nombre', 'Salto'),
  'CI007 trae en details la campaña en conflicto (id y nombre) para el BFF'
);
-- Una inscripción borrada en esta campaña (b6, b3) ya no es CI008: inscribir_colportor() la reactiva
-- (0028, decisión de Cristian del 02/10). Lo cubre 0035_reactivar_inscripcion_test.

-- El INSERT directo está cerrado para todos: sin el lock del RPC, dos coordinadores podían
-- dejar a la misma persona en dos campañas vigentes.
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id, created_by)
     values ('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b8',
             '01920000-0000-7000-8000-0000000007a1') $$,
  '42501', null, 'INSERT directo de una inscripción válida en su propia campaña: cerrado, solo por el RPC'
);

-- ---------------------------------------------------------------------------
-- 4. El caso feliz: la cuenta sale de PENDIENTE_ASIGNACION sola
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007b1');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'b1 arranca PENDIENTE_ASIGNACION');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a1');
select is(
  (select (f.campania_id, f.usuario_id, f.created_by, f.deleted_at)::text
     from public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') f),
  ('01920000-0000-7000-8000-0000000007e1'::uuid, '01920000-0000-7000-8000-0000000007b1'::uuid,
   '01920000-0000-7000-8000-0000000007a1'::uuid, null::timestamptz)::text,
  'el coordinador de Verano inscribe a b1: devuelve la fila, con created_by = el coordinador'
);

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007b1');
select is(public.estado_cuenta(), 'ACTIVA', 'inscripto, b1 pasa a ACTIVA sin tocar nada más');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a1');
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e1', '01920000-0000-7000-8000-0000000007b1') $$,
  'CI006', null, 'reintentar la misma inscripción → CI006, no un duplicado'
);

-- El ADMIN inscribe en cualquier campaña, pero con las mismas reglas y solo por el RPC.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007ad');
select lives_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e2', '01920000-0000-7000-8000-0000000007b9') $$,
  'el ADMIN inscribe en una campaña que no coordina'
);
select throws_ok(
  $$ select public.inscribir_colportor('01920000-0000-7000-8000-0000000007e2', '01920000-0000-7000-8000-0000000007b3') $$,
  'CI005', null, 'el ADMIN tampoco inscribe a un suspendido'
);
select throws_ok(
  $$ insert into public.campania_colportor (campania_id, usuario_id)
     values ('01920000-0000-7000-8000-0000000007e2', '01920000-0000-7000-8000-0000000007b8') $$,
  '42501', null, 'el ADMIN tampoco inserta directo'
);

-- ---------------------------------------------------------------------------
-- 5. Un UPDATE no puede equivaler a inscribir
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a1');
select throws_ok(
  $$ update public.campania_colportor set usuario_id = '01920000-0000-7000-8000-0000000007b8'
      where campania_id = '01920000-0000-7000-8000-0000000007e1'
        and usuario_id = '01920000-0000-7000-8000-0000000007b1' $$,
  '23514', null, 'cambiar el usuario de una inscripción falla (sería inscribir salteándose las reglas)'
);
select throws_ok(
  $$ update public.campania_colportor set campania_id = '01920000-0000-7000-8000-0000000007e2'
      where campania_id = '01920000-0000-7000-8000-0000000007e1'
        and usuario_id = '01920000-0000-7000-8000-0000000007b1' $$,
  '23514', null, 'cambiar la campaña de una inscripción falla (reasignar es cerrar y abrir, HU-CAM-005)'
);

-- Reactivar una borrada: el bloqueante de la revisión. Sin la guarda, un coordinador de
-- otra campaña reactivaba la inscripción de un suspendido (la política UPDATE de 0003 lo deja).
select throws_ok(
  $$ update public.campania_colportor set deleted_at = null
      where campania_id = '01920000-0000-7000-8000-0000000007e1'
        and usuario_id = '01920000-0000-7000-8000-0000000007b6' $$,
  '23514', null, 'el coordinador de la campaña no reactiva una inscripción borrada con un UPDATE: solo con inscribir_colportor() (0028)'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a2');
select throws_ok(
  $$ update public.campania_colportor set deleted_at = null
      where campania_id = '01920000-0000-7000-8000-0000000007e1'
        and usuario_id = '01920000-0000-7000-8000-0000000007b3' $$,
  '23514', null, 'un coordinador de otra campaña no reactiva la inscripción borrada de un suspendido'
);
select pg_temp.actuar_como_servidor();
select ok(
  (select deleted_at is not null from public.campania_colportor
    where campania_id = '01920000-0000-7000-8000-0000000007e1'
      and usuario_id = '01920000-0000-7000-8000-0000000007b3'),
  '...y la inscripción de b3 sigue borrada'
);
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007b6');
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', '...y b6 sigue PENDIENTE_ASIGNACION');

-- El resto del UPDATE pasa esta guarda (acotarlo es de HU-CAM-005). zona_id no: desde 0006
-- solo cambia por asignar_zona() (ver 0008_asignar_zona_test).
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007a1');
select lives_ok(
  $$ update public.campania_colportor set meta_libros = 40
      where campania_id = '01920000-0000-7000-8000-0000000007e1'
        and usuario_id = '01920000-0000-7000-8000-0000000007b1' $$,
  'meta_libros se sigue actualizando'
);
select is(
  (select meta_libros from public.campania_colportor
    where campania_id = '01920000-0000-7000-8000-0000000007e1'
      and usuario_id = '01920000-0000-7000-8000-0000000007b1'),
  40, '...y queda meta_libros = 40'
);
select lives_ok(
  $$ update public.campania_colportor set deleted_at = now()
      where campania_id = '01920000-0000-7000-8000-0000000007e1'
        and usuario_id = '01920000-0000-7000-8000-0000000007b4' $$,
  'el soft delete de una inscripción sigue pasando'
);
select isnt(
  (select deleted_at from public.campania_colportor
    where campania_id = '01920000-0000-7000-8000-0000000007e1'
      and usuario_id = '01920000-0000-7000-8000-0000000007b4'),
  null, '...y la inscripción queda borrada'
);

-- Un proceso servidor (sin JWT) sí reactiva: la guarda es para los JWT.
select pg_temp.actuar_como_servidor();
update public.campania_colportor set deleted_at = null
 where campania_id = '01920000-0000-7000-8000-0000000007e1'
   and usuario_id = '01920000-0000-7000-8000-0000000007b6';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000007b6');
select is(public.estado_cuenta(), 'ACTIVA', 'un proceso servidor reactiva la inscripción de b6');

select * from finish();
rollback;
