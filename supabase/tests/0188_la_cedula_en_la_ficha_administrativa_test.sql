-- pgTAP · la cédula del colportor en una ficha solo de la nube que lee Administración (migración 0188,
-- backend-supabase#266, decisión de Cristian 11/11 «Cédula adm.»)
--   1. La tabla ficha_administrativa: columnas, una fila por cuenta, auditoría, RLS, privilegios (anon y
--      authenticated nada; service_role todo) y que no es entidad de sync.
--   2. El registro con `cedula` en los metadatos guarda la ficha (sin espacios en los extremos, creada por
--      la propia persona); sin la clave, null o vacía no guarda nada y el registro sigue; el perfil y el
--      consentimiento de los Términos se crean igual que antes; un TC001 no deja ficha.
--   3. Quién la lee: Administración por cedula_de_la_cuenta(); el colportor (ni la suya) y la coordinadora
--      no la leen ni por la RPC ni directo, ni la cambian; anon nada.
--   4. Rocío no la cambia sola: cambiar después los metadatos de Auth no toca la ficha.
--   5. El audit_log no guarda la cédula; borrar la cuenta se lleva su ficha.
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

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function pg_temp.actuar_como_service_role() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('role', 'service_role', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000188' || p_sufijo)::uuid
$$;

-- SQLSTATE|mensaje del error que da una sentencia ('ok' si no da ninguno).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Registrarse: un insert en auth.users con estos metadatos (lo que hace Supabase Auth en un signUp).
create or replace function pg_temp.registrar(p_sufijo text, p_meta jsonb) returns text language plpgsql as $$
begin
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, raw_user_meta_data,
                          created_at, updated_at)
  values (pg_temp.u(p_sufijo), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'cedula-' || p_sufijo || '@example.com', 'x', p_meta, now(), now());
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- La cédula guardada de una cuenta, leída como servidor ('(sin ficha)' si no hay fila).
create or replace function pg_temp.ficha(p_sufijo text) returns text language sql as $$
  select coalesce((select f.cedula from public.ficha_administrativa f where f.usuario_id = pg_temp.u(p_sufijo)),
                  '(sin ficha)')
$$;

-- ---------------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------------
select has_table('public', 'ficha_administrativa', 'existe ficha_administrativa');
select col_is_pk('public', 'ficha_administrativa', 'id', 'id es la clave');
select col_type_is('public', 'ficha_administrativa', 'cedula', 'text', 'cedula es text');
select col_not_null('public', 'ficha_administrativa', 'cedula', 'cedula es obligatoria');
select col_not_null('public', 'ficha_administrativa', 'usuario_id', 'usuario_id es obligatorio');
select fk_ok('public', 'ficha_administrativa', 'usuario_id', 'public', 'usuario', 'id',
             'usuario_id apunta al perfil');
select has_index('public', 'ficha_administrativa', 'ficha_administrativa_usuario_key', array['usuario_id'],
                 'una ficha por cuenta');
select has_trigger('public', 'ficha_administrativa', 'ficha_administrativa_auditoria_insert', 'trigger de auditoría al insertar');
select has_trigger('public', 'ficha_administrativa', 'ficha_administrativa_auditoria_update', 'trigger de auditoría al actualizar');
select is((select relrowsecurity from pg_class where oid = 'public.ficha_administrativa'::regclass),
          true, 'tiene RLS');
select is(
  (select array_agg(p.policyname || ':' || p.cmd collate "C" order by p.policyname collate "C")
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'ficha_administrativa'),
  array['ficha_administrativa_select_admin:SELECT'],
  'una sola política, de lectura y solo del ADMIN (ninguna de escritura)'
);
select ok(not exists (select 1 from sync.entidad where nombre = 'ficha_administrativa'),
          'no es entidad de sync: no baja al teléfono');

select ok(not (has_table_privilege('anon', 'public.ficha_administrativa', 'select')
            or has_table_privilege('anon', 'public.ficha_administrativa', 'insert')
            or has_table_privilege('anon', 'public.ficha_administrativa', 'update')
            or has_table_privilege('anon', 'public.ficha_administrativa', 'delete')),
          'anon no tiene ningún privilegio');
select ok(not (has_table_privilege('authenticated', 'public.ficha_administrativa', 'select')
            or has_table_privilege('authenticated', 'public.ficha_administrativa', 'insert')
            or has_table_privilege('authenticated', 'public.ficha_administrativa', 'update')
            or has_table_privilege('authenticated', 'public.ficha_administrativa', 'delete')
            or has_table_privilege('authenticated', 'public.ficha_administrativa', 'truncate')),
          'authenticated no tiene ningún privilegio (ni leer): se lee por la RPC');
select ok(has_table_privilege('service_role', 'public.ficha_administrativa', 'select')
          and has_table_privilege('service_role', 'public.ficha_administrativa', 'insert')
          and has_table_privilege('service_role', 'public.ficha_administrativa', 'update'),
          'service_role lee y escribe');
select ok(has_function_privilege('authenticated', 'public.cedula_de_la_cuenta(uuid)', 'execute')
          and not has_function_privilege('anon', 'public.cedula_de_la_cuenta(uuid)', 'execute'),
          'la RPC la ejecuta authenticated (decide adentro) y anon no');
select ok(not has_function_privilege('authenticated', 'public.tg_auth_usuario_nuevo()', 'execute')
          and not has_function_privilege('anon', 'public.tg_auth_usuario_nuevo()', 'execute'),
          'la función del trigger del registro no la ejecuta ni authenticated ni anon');

-- ---------------------------------------------------------------------------
-- 2. El registro
-- ---------------------------------------------------------------------------

-- Rocío se registra con su cédula (como la manda la app) y la versión de los Términos.
select is(pg_temp.registrar('a1',
  '{"nombre":"Rocío","apellido":"Alfa","cedula":"4.567.890-1","terminos_version":"v1"}'), 'ok',
  'el registro con la cédula se crea');
select is(pg_temp.ficha('a1'), '45678901', 'la ficha guarda la cédula en solo dígitos (0190)');
select row_eq(
  $$ select created_by = usuario_id, deleted_at is null, sync_version
       from public.ficha_administrativa where usuario_id = pg_temp.u('a1') $$,
  row(true, true, 0::bigint),
  'la ficha la crea la propia cuenta, viva, versión 0'
);
select row_eq(
  $$ select email, nombre, apellido from public.usuario where id = pg_temp.u('a1') $$,
  row('cedula-a1@example.com'::text, 'Rocío'::text, 'Alfa'::text),
  'el perfil se crea como antes (email, nombre, apellido)'
);
select is((select version from public.consentimiento_terminos where usuario_id = pg_temp.u('a1')), 'v1',
          'y el consentimiento de los Términos también (0065 sigue igual)');

-- La coordinadora y el ADMIN (las lecturas de abajo los usan); Bruno, otro colportor.
select is(pg_temp.registrar('a2', '{"nombre":"Carla","apellido":"Coord","cedula":"11111111"}'), 'ok',
          'la coordinadora se registra con cédula');
select is(pg_temp.registrar('a3', '{"nombre":"Ana","apellido":"Adm","cedula":"22222222"}'), 'ok',
          'el ADMIN se registra con cédula');
select is(pg_temp.registrar('a4', '{"nombre":"Bruno","apellido":"Beta","cedula":"33333333"}'), 'ok',
          'otro colportor se registra con cédula');

-- Los espacios de los extremos no se guardan.
select is(pg_temp.registrar('a5', '{"cedula":"  1234567-8 "}'), 'ok', 'cédula con espacios: el registro se crea');
select is(pg_temp.ficha('a5'), '12345678', 'se guarda sin espacios ni guion (0190)');
-- Un número JSON se guarda como texto.
select is(pg_temp.registrar('a6', '{"cedula":12345678}'), 'ok', 'cédula como número JSON: el registro se crea');
select is(pg_temp.ficha('a6'), '12345678', 'se guarda como texto');

-- El cliente no pone el usuario ni quién la creó.
select is(pg_temp.registrar('a7',
  '{"cedula":"55555555","usuario_id":"01920000-0000-7000-8000-000000018801","created_by":"01920000-0000-7000-8000-000000018801"}'),
  'ok', 'metadatos de más no rompen el registro');
select row_eq(
  $$ select usuario_id = pg_temp.u('a7'), created_by = pg_temp.u('a7')
       from public.ficha_administrativa where cedula = '55555555' $$,
  row(true, true),
  'el usuario y quién la creó salen del servidor, no de los metadatos'
);

-- Sin la clave, null o vacía: el registro sigue igual y no queda ficha.
select is(pg_temp.registrar('b1', '{"nombre":"Beto","apellido":"Bravo"}'), 'ok', 'el registro sin la cédula se crea');
select is(pg_temp.ficha('b1'), '(sin ficha)', 'sin la clave no hay ficha');
select is((select nombre from public.usuario where id = pg_temp.u('b1')), 'Beto', 'y el perfil se crea igual');
select is(pg_temp.registrar('b2', '{"cedula":null}'), 'ok', 'el registro con la cédula null se crea');
select is(pg_temp.ficha('b2'), '(sin ficha)', 'con null no hay ficha');
select is(pg_temp.registrar('b3', '{"cedula":""}'), 'ok', 'el registro con la cédula vacía se crea');
select is(pg_temp.ficha('b3'), '(sin ficha)', 'vacía no hay ficha');
select is(pg_temp.registrar('b4', '{"cedula":"   "}'), 'ok', 'el registro con la cédula en blanco se crea');
select is(pg_temp.ficha('b4'), '(sin ficha)', 'en blanco no hay ficha');
select is(pg_temp.registrar('b5', null), 'ok', 'el registro sin metadatos (null) se crea');
select is(pg_temp.ficha('b5'), '(sin ficha)', 'sin metadatos no hay ficha');

-- Un registro que la 0065 rechaza (TC001) no deja ficha.
select is(left(pg_temp.registrar('c1', '{"cedula":"44444444","terminos_version":"v9"}'), 5), 'TC001',
          'una versión de Términos no publicada sigue frenando el registro');
select is(pg_temp.ficha('c1'), '(sin ficha)', 'y no deja ficha');
select is((select count(*) from public.usuario where id = pg_temp.u('c1')), 0::bigint, 'ni perfil');

-- La tabla no guarda una cédula en blanco ni dos fichas para la misma cuenta, ni de una cuenta que no existe.
select pg_temp.actuar_como_service_role();
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('b1'), '  ') $$), 5),
          '23514', 'el servidor no guarda una cédula en blanco (desde la 0190, solo 7 u 8 dígitos)');
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('a1'), '99999999') $$), 5),
          '23505', 'ni una segunda ficha para la misma cuenta');
select is(left(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                                  values (pg_temp.u('ff'), '99999999') $$), 5),
          '23503', 'ni la de una cuenta que no existe');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Quién la lee
-- ---------------------------------------------------------------------------
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COLPORTOR'), ('a2','COORDINADOR'), ('a3','ADMIN'), ('a4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- Administración: la de cualquiera, por la RPC.
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(public.cedula_de_la_cuenta(pg_temp.u('a1')), '45678901', 'Administración lee la cédula de Rocío');
select is(public.cedula_de_la_cuenta(pg_temp.u('a4')), '33333333', 'y la de otro colportor');
select is(public.cedula_de_la_cuenta(pg_temp.u('a2')), '11111111', 'y la de la coordinadora');
select is(public.cedula_de_la_cuenta(pg_temp.u('b1')), null, 'una cuenta sin ficha da null');
select is(public.cedula_de_la_cuenta(pg_temp.u('ff')), null, 'una cuenta que no existe da null');
select is(public.cedula_de_la_cuenta(null), null, 'sin cuenta da null');
select is(pg_temp.error_de($$ select count(*) from public.ficha_administrativa $$),
          '42501|permission denied for table ficha_administrativa',
          'ni Administración lee la tabla directo: solo por la RPC');
select pg_temp.actuar_como_servidor();

-- Rocío: ni la suya, ni la de otro; no la cambia.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a1')) $$),
          '42501|Solo Administración puede ver la cédula de una cuenta. Si la necesitás, pedísela a Administración.',
          'Rocío no lee su cédula por la RPC');
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a4')) $$),
          '42501|Solo Administración puede ver la cédula de una cuenta. Si la necesitás, pedísela a Administración.',
          'ni la de otro colportor');
select is(pg_temp.error_de($$ select count(*) from public.ficha_administrativa $$),
          '42501|permission denied for table ficha_administrativa', 'Rocío no lee la tabla');
select is(pg_temp.error_de($$ update public.ficha_administrativa set cedula = '00000000' $$),
          '42501|permission denied for table ficha_administrativa', 'Rocío no cambia su cédula');
select is(pg_temp.error_de($$ update public.ficha_administrativa set deleted_at = now() $$),
          '42501|permission denied for table ficha_administrativa', 'Rocío no se da de baja la ficha');
select is(pg_temp.error_de($$ insert into public.ficha_administrativa (usuario_id, cedula)
                             values (pg_temp.u('b1'), '00000000') $$),
          '42501|permission denied for table ficha_administrativa', 'Rocío no le crea una ficha a otra cuenta');
select is(pg_temp.error_de($$ delete from public.ficha_administrativa $$),
          '42501|permission denied for table ficha_administrativa', 'Rocío no la borra');
select pg_temp.actuar_como_servidor();
select is(pg_temp.ficha('a1'), '45678901', 'y su ficha sigue igual');

-- La coordinadora: tampoco.
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a1')) $$),
          '42501|Solo Administración puede ver la cédula de una cuenta. Si la necesitás, pedísela a Administración.',
          'la coordinadora no lee la cédula de Rocío');
select is(pg_temp.error_de($$ select count(*) from public.ficha_administrativa $$),
          '42501|permission denied for table ficha_administrativa', 'la coordinadora no lee la tabla');
select is(pg_temp.error_de($$ update public.ficha_administrativa set cedula = '00000000' $$),
          '42501|permission denied for table ficha_administrativa', 'la coordinadora no la cambia');
select pg_temp.actuar_como_servidor();

-- Un ADMIN dado de baja del rol ya no la lee.
update public.usuario_rol set deleted_at = now()
 where usuario_id = pg_temp.u('a3');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a1')) $$),
          '42501|Solo Administración puede ver la cédula de una cuenta. Si la necesitás, pedísela a Administración.',
          'sin el rol ADMIN vigente no la lee');
select pg_temp.actuar_como_servidor();
update public.usuario_rol set deleted_at = null
 where usuario_id = pg_temp.u('a3');

-- Sin sesión (una sesión authenticated sin sub) ni anon.
select pg_temp.actuar_como_service_role();
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a1')) $$),
          '42501|permission denied for function cedula_de_la_cuenta',
          'service_role no la llama (lee la tabla si hace falta)');
select is(pg_temp.ficha('a1'), '45678901', 'service_role lee la tabla');
select pg_temp.actuar_como_servidor();
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a1')) $$),
          '42501|permission denied for function cedula_de_la_cuenta', 'anon no llama la RPC');
select is(pg_temp.error_de($$ select count(*) from public.ficha_administrativa $$),
          '42501|permission denied for table ficha_administrativa', 'anon no lee la tabla');
select pg_temp.actuar_como_servidor();
select set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
select set_config('role', 'authenticated', true);
select is(pg_temp.error_de($$ select public.cedula_de_la_cuenta(pg_temp.u('a1')) $$),
          '42501|Para ver la cédula de una cuenta hay que iniciar sesión.',
          'una sesión sin usuario no la lee');
select pg_temp.actuar_como_servidor();

-- Una ficha dada de baja no se lee.
update public.ficha_administrativa set deleted_at = now() where usuario_id = pg_temp.u('a4');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(public.cedula_de_la_cuenta(pg_temp.u('a4')), null, 'una ficha dada de baja da null');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Rocío no la cambia sola: los metadatos de Auth ya no mandan
-- ---------------------------------------------------------------------------
update auth.users
   set raw_user_meta_data = raw_user_meta_data || '{"cedula":"00000000"}'::jsonb
 where id = pg_temp.u('a1');
select is(pg_temp.ficha('a1'), '45678901',
          'cambiar la cédula en los metadatos de Auth (auth.updateUser) no toca la ficha');
update auth.users
   set raw_user_meta_data = '{"cedula":"77777777"}'::jsonb
 where id = pg_temp.u('b1');
select is(pg_temp.ficha('b1'), '(sin ficha)',
          'ponerla en los metadatos después del registro no crea la ficha');

-- La actualización del servidor pasa por la auditoría (sync_version sube, created_by no se reescribe).
update public.ficha_administrativa set updated_at = now() - interval '1 day' where usuario_id = pg_temp.u('a2');
select row_eq(
  $$ select sync_version, created_by = usuario_id from public.ficha_administrativa
      where usuario_id = pg_temp.u('a2') $$,
  row(1::bigint, true),
  'los triggers de auditoría corren (sync_version sube, created_by no se reescribe)'
);

-- ---------------------------------------------------------------------------
-- 5. El audit_log no guarda la cédula; borrar la cuenta se lleva su ficha
-- ---------------------------------------------------------------------------
select is(
  (select count(*) from auditoria.audit_log l
    where l.metadata::text ~ '45678901|4\.567\.890-1|11111111|22222222|33333333|1234567-8|12345678|55555555'),
  0::bigint,
  'ningún evento del audit_log lleva una cédula'
);
select is(
  (select count(*) from auditoria.audit_log l where l.tabla = 'ficha_administrativa'),
  0::bigint,
  'ningún evento habla de la ficha (registrarse y leerla no registran eventos)'
);

delete from auth.users where id = pg_temp.u('a5');
select is(pg_temp.ficha('a5'), '(sin ficha)', 'borrar la cuenta se lleva su ficha');
select is(pg_temp.ficha('a6'), '12345678', 'y no toca la de otras cuentas');

select * from finish();
rollback;
