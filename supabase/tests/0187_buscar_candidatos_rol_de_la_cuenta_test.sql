-- pgTAP · migración 0187 (HU-CAM-004, vista 23; decisión de Cristian del 11/11): buscar_candidatos() suma la columna
-- rol_cuenta para que el panel advierta que la cuenta es de coordinación o de administración. La forma (las ocho columnas de
-- antes, en el mismo orden, y la nueva al final) y los privilegios (los de la 0015); qué vale la columna (ADMIN, COORDINADOR,
-- null; los dos roles = ADMIN; rol vencido, rol dado de baja, cuenta suspendida, colportor y sin rol = null); que sale igual en
-- los sugeridos y en la búsqueda, y para el ADMIN que busca; y que nada más cambió: la cuenta de coordinación o de
-- administración sigue apareciendo, sin motivo de bloqueo, y se la puede inscribir (decisión del 02/10).
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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000187' || p_sufijo)::uuid
$$;

-- ---------------------------------------------------------------------------
-- Fixtures. Cuentas (correo rol187-<sufijo>@example.com):
--   a1 coordinador de Verano187 (el que busca)      a5 su segundo coordinador (campania_coordinador)
--   a2 coordinadora de Otra187                      a6 coordinador sin ninguna campaña
--   ad administrador                                ae administrador y coordinador a la vez
--   a4 coordinador con el rol vencido               a7 coordinador con el rol dado de baja
--   b2 coordinador suspendido                       c1 colportor (rol COLPORTOR)
--   c2 sin ningún rol                               c3 colportor ya inscripto en Otra187
-- Campañas: e1 Verano187 (vigente, a1 + a5)  e2 Otra187 (vigente, a2)
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at, raw_user_meta_data)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'rol187-' || x.s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', x.nombre, 'apellido', x.apellido)
  from (values ('a1','Luis','Gomez'), ('a2','Marta','Lopez'), ('a4','Vera','Vieja'), ('a5','Ana','Mora'),
               ('a6','Zoe','Zeta'), ('a7','Rolo','Baja'), ('ad','Carlos','Ruiz'), ('ae','Beto','Ruiz'),
               ('b2','Susana','Suspendida'), ('c1','Rosa','Perez'), ('c2','Nadie','Nada'), ('c3','Otro','Equipo'))
       x(s, nombre, apellido);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'), ('a6','COORDINADOR'),
               ('ad','ADMIN'), ('ae','ADMIN'), ('ae','COORDINADOR'), ('b2','COORDINADOR'),
               ('c1','COLPORTOR'), ('c3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
-- a4: el rol de coordinador venció ayer.
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';
-- a7: el rol de coordinador se dio de baja.
insert into public.usuario_rol (usuario_id, rol_id, deleted_at)
select pg_temp.u('a7'), r.id, now()
  from public.rol r where r.codigo = 'COORDINADOR';
update public.usuario set suspendido_en = now() where id = pg_temp.u('b2');

-- Las más nuevas de la base, para que los sugeridos (las 5 pendientes más nuevas) sean cuentas de este test:
-- a2 (coordinadora), ad (administrador), c1 (colportor), c2 (sin rol) y a6 (coordinador). created_at es inmutable por UPDATE
-- (tg_auditoria_update): se apaga el trigger solo acá.
alter table public.usuario disable trigger usuario_auditoria_update;
update public.usuario u set created_at = now() + x.dias * interval '1 day'
  from (values ('a2', 50), ('ad', 49), ('c1', 48), ('c2', 47), ('a6', 46)) x(s, dias)
 where u.id = pg_temp.u(x.s);
alter table public.usuario enable trigger usuario_auditoria_update;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano187', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otra187',   'VERANO', current_date - 10, current_date + 30, pg_temp.u('a2'));
insert into public.campania_coordinador (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('a5'));
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e2'), pg_temp.u('c3'));

-- Lo que trae la búsqueda de una cuenta de este test por su correo, para la campaña Verano187: «estado|motivo|rol», con «-»
-- en los null; «sin fila» si no aparece.
create or replace function pg_temp.fila(p_s text) returns text language sql as $$
  select coalesce(string_agg(c.estado || '|' || coalesce(c.motivo_bloqueo, '-') || '|' || coalesce(c.rol_cuenta, '-'), ','),
                  'sin fila')
    from public.buscar_candidatos(pg_temp.u('e1'), 'rol187-' || p_s || '@') c
$$;
grant execute on function pg_temp.fila(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.buscar_candidatos(uuid, text, uuid)'::regprocedure)),
          'TABLE(usuario_id uuid, nombre text, apellido text, email text, estado text, campania_actual text, '
          'creada_en timestamp with time zone, motivo_bloqueo text, rol_cuenta text)',
          'buscar_candidatos(): las ocho columnas de antes, en el mismo orden, y rol_cuenta al final');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.buscar_candidatos(uuid, text, uuid)'::regprocedure),
          true, 'sigue SECURITY DEFINER');
select is((select p.proconfig from pg_proc p where p.oid = 'public.buscar_candidatos(uuid, text, uuid)'::regprocedure),
          array['search_path=""'], 'sigue con search_path vacío');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.buscar_candidatos(uuid, text, uuid)'::regprocedure),
          'v', 'sigue volatile');
select ok(has_function_privilege('authenticated', 'public.buscar_candidatos(uuid, text, uuid)', 'execute'),
          'authenticated la ejecuta');
select ok(has_function_privilege('service_role', 'public.buscar_candidatos(uuid, text, uuid)', 'execute'),
          'service_role la ejecuta, como desde la 0015');
select ok(not has_function_privilege('anon', 'public.buscar_candidatos(uuid, text, uuid)', 'execute'), 'anon NO la ejecuta');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.buscar_candidatos(uuid, text, uuid)'::regprocedure),
          0, 'sin EXECUTE para PUBLIC');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'buscar_candidatos'),
          1, 'hay una sola buscar_candidatos (la de antes se borró, no quedó una sobrecarga)');
select ok(obj_description('public.buscar_candidatos(uuid, text, uuid)'::regprocedure, 'pg_proc') like '%rol_cuenta%',
          'el comentario de la función nombra la columna nueva');

-- ---------------------------------------------------------------------------
-- 2. El permiso sigue primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'rol187') $$,
  '42501', null, 'sin JWT falla');
select pg_temp.actuar_como(pg_temp.u('c1'));
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'rol187') $$,
  '42501', null, 'un colportor no busca');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.buscar_candidatos(pg_temp.u('e1'), 'rol187') $$,
  '42501', null, 'la coordinadora de otra campaña no busca en esta');

-- ---------------------------------------------------------------------------
-- 3. Búsqueda: qué vale rol_cuenta
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('a2'), 'PENDIENTE_ASIGNACION|-|COORDINADOR',
  'la coordinadora de otra campaña aparece, sin bloqueo, con rol_cuenta COORDINADOR');
select is(pg_temp.fila('a5'), 'PENDIENTE_ASIGNACION|-|COORDINADOR',
  'el segundo coordinador de esta campaña: COORDINADOR');
select is(pg_temp.fila('a6'), 'PENDIENTE_ASIGNACION|-|COORDINADOR',
  'un coordinador sin ninguna campaña: COORDINADOR (cuenta el rol, no la campaña)');
select is(pg_temp.fila('a1'), 'PENDIENTE_ASIGNACION|-|COORDINADOR',
  'el coordinador que busca se ve a sí mismo con COORDINADOR');
select is(pg_temp.fila('ad'), 'PENDIENTE_ASIGNACION|-|ADMIN',
  'un administrador aparece, sin bloqueo, con rol_cuenta ADMIN');
select is(pg_temp.fila('ae'), 'PENDIENTE_ASIGNACION|-|ADMIN',
  'administrador y coordinador a la vez: ADMIN');
select is(pg_temp.fila('c1'), 'PENDIENTE_ASIGNACION|-|-',
  'un colportor: rol_cuenta null');
select is(pg_temp.fila('c2'), 'PENDIENTE_ASIGNACION|-|-',
  'una cuenta sin ningún rol: null');
select is(pg_temp.fila('a4'), 'PENDIENTE_ASIGNACION|-|-',
  'con el rol de coordinador vencido: null');
select is(pg_temp.fila('a7'), 'PENDIENTE_ASIGNACION|-|-',
  'con el rol de coordinador dado de baja: null');
select is(pg_temp.fila('b2'), 'SUSPENDIDA|USUARIO_SUSPENDIDO|-',
  'un coordinador suspendido: null (ya viene bloqueado por la suspensión)');
select is(pg_temp.fila('c3'), 'ACTIVA|EN_OTRA_CAMPANIA|-',
  'un colportor de otra campaña sigue bloqueado como antes y sin rol');

-- Las ocho columnas de antes traen lo mismo de siempre.
select results_eq(
  $$ select usuario_id, nombre, apellido, email, estado, campania_actual, motivo_bloqueo, rol_cuenta
       from public.buscar_candidatos(pg_temp.u('e1'), 'rol187-a2@') $$,
  $$ values (pg_temp.u('a2'), 'Marta'::text, 'Lopez'::text, 'rol187-a2@example.com'::text,
             'PENDIENTE_ASIGNACION'::text, null::text, null::text, 'COORDINADOR'::text) $$,
  'la fila de la coordinadora: los datos de siempre más el rol');
select is((select creada_en from public.buscar_candidatos(pg_temp.u('e1'), 'rol187-a2@')),
          now() + 50 * interval '1 day',
          'creada_en sigue siendo el alta de la cuenta (la de los fixtures: hoy más 50 días)');

-- La búsqueda por texto no cambió de orden ni de tamaño de página: 12 cuentas, 10 en la primera.
select is((select count(*)::int from public.buscar_candidatos(pg_temp.u('e1'), 'rol187-')), 10,
  'la página sigue siendo de 10');
select is((select count(*)::int from public.buscar_candidatos(pg_temp.u('e1'), 'rol187-',
            (select usuario_id from public.buscar_candidatos(pg_temp.u('e1'), 'rol187-') offset 9 limit 1))), 2,
  'y la segunda trae las 2 que faltan');

-- ---------------------------------------------------------------------------
-- 4. Sugeridos: la columna sale igual
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select usuario_id, estado, motivo_bloqueo, rol_cuenta from public.buscar_candidatos(pg_temp.u('e1')) $$,
  $$ values (pg_temp.u('a2'), 'PENDIENTE_ASIGNACION'::text, null::text, 'COORDINADOR'::text),
            (pg_temp.u('ad'), 'PENDIENTE_ASIGNACION', null, 'ADMIN'),
            (pg_temp.u('c1'), 'PENDIENTE_ASIGNACION', null, null),
            (pg_temp.u('c2'), 'PENDIENTE_ASIGNACION', null, null),
            (pg_temp.u('a6'), 'PENDIENTE_ASIGNACION', null, 'COORDINADOR') $$,
  'sugeridos: las cuentas de coordinación y de administración siguen saliendo (no se filtra por rol), con su rol');

-- El ADMIN que busca ve lo mismo.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.fila('a2'), 'PENDIENTE_ASIGNACION|-|COORDINADOR', 'el ADMIN ve el rol de la coordinadora');
select is(pg_temp.fila('ad'), 'PENDIENTE_ASIGNACION|-|ADMIN', 'y el suyo');
select is(pg_temp.fila('c1'), 'PENDIENTE_ASIGNACION|-|-', 'y el colportor sin rol');

-- ---------------------------------------------------------------------------
-- 5. No se filtra por rol: a la coordinadora se la sigue pudiendo inscribir (decisión del 02/10)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select public.inscribir_colportor(pg_temp.u('e1'), pg_temp.u('ad')) $$,
  'inscribir_colportor() acepta a un administrador como colportor');
select is(pg_temp.fila('ad'), 'sin fila', 'ya en el equipo, deja de ser candidata');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.campania_colportor
            where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('ad') and deleted_at is null),
          1, 'quedó inscripta');

select * from finish();
rollback;
