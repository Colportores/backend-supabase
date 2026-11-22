-- pgTAP · migración 0183 (backend-supabase#257): quién puede figurar como acompañante en el panel (vista 33).
-- acompaniantes_del_panel(): la forma y los privilegios; el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido,
-- coordinador de otra campaña) y que sí entran un coordinador de la campaña, su segundo coordinador (0175) y el ADMIN; los
-- códigos (CZ001; la campaña terminada se lee); la lista (coordinadores de cualquier campaña y administradores, sin colportores,
-- sin gente sin rol, sin cuentas dadas de baja, suspendidas, con el rol vencido o con el rol dado de baja; una persona con los
-- dos roles, una vez); que trae solo id, nombre y apellido; el orden; y que leer no modificó nada.
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

create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000183' || p_sufijo)::uuid
$$;

-- ---------------------------------------------------------------------------
-- Fixtures. Cuentas (nombre y apellido entre paréntesis):
--   a1 coordinador de Verano (Luis Gomez)           a5 su segundo coordinador (campania_coordinador) (Ana Mora)
--   a2 coordinador de Otra (Marta Lopez)            a6 coordinador sin ninguna campaña (Zoe Zeta)
--   ad administrador (Carlos Ruiz)                  ae administrador y coordinador a la vez (Beto Ruiz)
--   a0 colportor (Rosa Perez)                       a3 sin ningún rol (Nadie Nada)
--   a4 coordinador con el rol vencido (Vera Vieja)  a7 coordinador con el rol dado de baja (Rolo Baja)
--   b1 coordinador dado de baja (Bruno Baja)        b2 administrador suspendido (Susana Suspendida)
-- Campañas: e1 Verano (vigente, a1 + a5)  e2 Otra (vigente, a2)  e3 Vieja (terminada, a1)  e4 Larga (terminada, a1)
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at, raw_user_meta_data)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'panel183-' || x.s || '@example.com', 'x', now(), now(), now(),
       jsonb_build_object('nombre', x.nombre, 'apellido', x.apellido)
  from (values ('a0','Rosa','Perez'), ('a1','Luis','Gomez'), ('a2','Marta','Lopez'), ('a3','Nadie','Nada'),
               ('a4','Vera','Vieja'), ('a5','Ana','Mora'), ('a6','Zoe','Zeta'), ('a7','Rolo','Baja'),
               ('ad','Carlos','Ruiz'), ('ae','Beto','Ruiz'), ('b1','Bruno','Baja'), ('b2','Susana','Suspendida'))
       x(s, nombre, apellido);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a0','COLPORTOR'), ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'), ('a6','COORDINADOR'),
               ('ad','ADMIN'), ('ae','ADMIN'), ('ae','COORDINADOR'), ('b1','COORDINADOR'), ('b2','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
-- a4: el rol de coordinador venció ayer.
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';
-- a7: el rol de coordinador se dio de baja.
insert into public.usuario_rol (usuario_id, rol_id, deleted_at)
select pg_temp.u('a7'), r.id, now()
  from public.rol r where r.codigo = 'COORDINADOR';
update public.usuario set deleted_at = now() where id = pg_temp.u('b1');
update public.usuario set suspendido_en = now() where id = pg_temp.u('b2');

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano183', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otra183',   'VERANO', current_date - 10, null,              pg_temp.u('a2')),
  (pg_temp.u('e3'), 'Vieja183',  'VERANO', current_date - 90, current_date - 30, pg_temp.u('a1')),
  (pg_temp.u('e4'), 'Reciente183', 'VERANO', current_date - 40, current_date - 3, pg_temp.u('a1'));
insert into public.campania_coordinador (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('a5'));

-- Lo que la lista trae de las cuentas de este test, en orden (apellido, nombre, id).
create or replace function pg_temp.lista(p_campania uuid) returns text language sql as $$
  select coalesce(string_agg(right(l.usuario_id::text, 2), ',' order by l.apellido, l.nombre, l.usuario_id), '')
    from public.acompaniantes_del_panel(p_campania) l
   where l.usuario_id::text like '01920000-0000-7000-8000-0000000183%'
$$;
grant execute on function pg_temp.lista(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.acompaniantes_del_panel(uuid)'::regprocedure)),
          'TABLE(usuario_id uuid, nombre text, apellido text)',
          'acompaniantes_del_panel(): la forma de la respuesta (id, nombre y apellido; ni correo, ni teléfono, ni cédula, ni rol)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.acompaniantes_del_panel(uuid)'::regprocedure),
          true, 'es SECURITY DEFINER');
select is((select p.proconfig from pg_proc p where p.oid = 'public.acompaniantes_del_panel(uuid)'::regprocedure),
          array['search_path=""'], 'fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.acompaniantes_del_panel(uuid)', 'execute'), 'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.acompaniantes_del_panel(uuid)', 'execute'), 'anon NO la ejecuta');
select ok(not has_function_privilege('service_role', 'public.acompaniantes_del_panel(uuid)', 'execute'), 'service_role NO la ejecuta');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE' and p.oid = 'public.acompaniantes_del_panel(uuid)'::regprocedure),
          0, 'sin EXECUTE para PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. El permiso es lo primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'authenticated sin sesión falla');
select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como_servidor();

select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'un colportor no la llama');
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183ff') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como(pg_temp.u('a4'));
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'con el rol de coordinador vencido falla');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'el coordinador de otra campaña no la llama para esta');
select throws_like($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  'Solo el coordinador de la campaña%', 'el mensaje del 42501 dice quién puede');
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e3') $$,
  '42501', null, 'una campaña ajena y terminada: 42501');
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183ff') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como(pg_temp.u('a6'));
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  '42501', null, 'un coordinador sin campaña propia tampoco la llama para una ajena');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Quién la llama y la campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  'el coordinador de la campaña la llama');
select lives_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e3') $$,
  'una campaña terminada hace más de 15 días también se lee (el selector se carga; el límite lo pone agregar_acompaniamiento al guardar)');
select lives_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e4') $$,
  'una campaña terminada hace pocos días se lee');
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183ff') $$,
  'CZ001', null, 'campaña inexistente: CZ001');
select throws_ok($$ select * from public.acompaniantes_del_panel(null) $$,
  'CZ001', null, 'campaña null: CZ001');
select pg_temp.actuar_como(pg_temp.u('a5'));
select lives_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  'el segundo coordinador de la campaña (0175) también');
select pg_temp.actuar_como(pg_temp.u('ad'));
select lives_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e1') $$,
  'el administrador la llama para cualquier campaña');
select lives_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183e2') $$,
  'el administrador, también para una campaña que no es de nadie conocido');
select throws_ok($$ select * from public.acompaniantes_del_panel('01920000-0000-7000-8000-0000000183ff') $$,
  'CZ001', null, 'el administrador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. La lista
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.lista(pg_temp.u('e1')), 'a1,a2,a5,ae,ad,a6',
  'el coordinador de Verano ve a todos los coordinadores (los de Verano, la de Otra y la sin campaña) y a los administradores; en orden de apellido, nombre e id');
select is(pg_temp.lista(pg_temp.u('e3')), pg_temp.lista(pg_temp.u('e1')),
  'la lista no depende de la campaña: la misma para una campaña terminada');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.lista(pg_temp.u('e2')), 'a1,a2,a5,ae,ad,a6', 'la coordinadora de Otra ve los mismos, incluidos los de Verano');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.lista(pg_temp.u('e1')), 'a1,a2,a5,ae,ad,a6', 'el administrador ve los mismos');
select pg_temp.actuar_como_servidor();


select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table r1 as select * from public.acompaniantes_del_panel(pg_temp.u('e1'));
grant select on r1 to authenticated;
select pg_temp.actuar_como_servidor();

select ok(not exists (select 1 from r1 where right(usuario_id::text, 2) = 'a0'), 'sin colportores (a0)');
select ok(not exists (select 1 from r1 where right(usuario_id::text, 2) = 'a3'), 'sin gente sin rol (a3)');
select ok(not exists (select 1 from r1 where right(usuario_id::text, 2) = 'a4'), 'sin el coordinador con el rol vencido (a4)');
select ok(not exists (select 1 from r1 where right(usuario_id::text, 2) = 'a7'), 'sin el coordinador con el rol dado de baja (a7)');
select ok(not exists (select 1 from r1 where right(usuario_id::text, 2) = 'b1'), 'sin el coordinador dado de baja (b1)');
select ok(not exists (select 1 from r1 where right(usuario_id::text, 2) = 'b2'), 'sin el administrador suspendido (b2)');
select is((select count(*)::int from r1 where right(usuario_id::text, 2) = 'ae'), 1,
  'la persona con los dos roles (administrador y coordinador) sale una sola vez');
select is((select nombre || ' ' || apellido from r1 where right(usuario_id::text, 2) = 'a2'), 'Marta Lopez',
  'trae nombre y apellido de la coordinadora de otra campaña');
select is((select nombre || ' ' || apellido from r1 where right(usuario_id::text, 2) = 'ad'), 'Carlos Ruiz',
  'trae nombre y apellido del administrador');

-- Un administrador dado de baja o un coordinador al que se le suspende la cuenta desaparecen de la lista en la próxima llamada.
update public.usuario set suspendido_en = now() where id = pg_temp.u('a6');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.lista(pg_temp.u('e1')), 'a1,a2,a5,ae,ad', 'una cuenta suspendida después sale de la lista');
select pg_temp.actuar_como_servidor();
update public.usuario set suspendido_en = null where id = pg_temp.u('a6');
update public.usuario set deleted_at = now() where id = pg_temp.u('ad');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.lista(pg_temp.u('e1')), 'a1,a2,a5,ae,a6', 'un administrador dado de baja después sale de la lista');
select pg_temp.actuar_como_servidor();
update public.usuario set deleted_at = null where id = pg_temp.u('ad');

-- Solo id, nombre y apellido (nada de correo, teléfono, cédula).
select is((select array_agg(a.attname::text order by a.attnum) from pg_attribute a
            where a.attrelid = 'r1'::regclass and a.attnum > 0 and not a.attisdropped),
          array['usuario_id', 'nombre', 'apellido'], 'la respuesta trae solo usuario_id, nombre y apellido');

-- ---------------------------------------------------------------------------
-- 5. No se reabre la lectura de usuario (0015) y leer no modifica nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*)::int from public.usuario where id = pg_temp.u('a1')), 0,
  'el coordinador sigue sin poder leer la tabla usuario de otra persona');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.usuario where id::text like '01920000-0000-7000-8000-0000000183%'), 12,
  'leer no modificó usuarios');

select * from finish();
rollback;
