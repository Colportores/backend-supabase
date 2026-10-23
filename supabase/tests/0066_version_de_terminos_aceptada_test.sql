-- pgTAP · la versión de Términos y Política que acepta la colportora (migración 0065, backend-supabase#109,
-- HU-AUTH-001, R-AU04)
--   1. La tabla consentimiento_terminos: columnas, forma de la versión, una fila por (usuario, versión),
--      auditoría, RLS, privilegios (anon nada; authenticated solo lee; service_role todo) y que no es entidad
--      de sync.
--   2. El registro con `terminos_version` en los metadatos guarda la fila (versión, hora del servidor,
--      quién); sin la clave o con null el registro sigue igual y no guarda nada; con otra forma, o con la
--      forma correcta pero una versión no publicada (hoy solo v1), se rechaza con TC001 y no queda ni el
--      perfil; el cliente no pone la fecha ni el usuario.
--   3. Quién lo lee: cada persona lo suyo, nadie lo ajeno (tampoco un ADMIN ni un coordinador); nadie lo
--      escribe con su JWT; el servidor puede sumar una versión nueva (historial) pero no repetir una.
--   4. Las cuentas que ya existían no se tocan; borrar la cuenta se lleva sus consentimientos.
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

-- Como el servicio de la API de Supabase: rol service_role, sin usuario.
create or replace function pg_temp.actuar_como_service_role() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('role', 'service_role', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000066' || p_sufijo)::uuid
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
          'terminos-' || p_sufijo || '@example.com', 'x', p_meta, now(), now());
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- Los consentimientos de una persona, como texto: versión|versión… (por versión), '(vacío)' si no hay.
create or replace function pg_temp.consentimientos(p_sufijo text) returns text language sql as $$
  select coalesce(string_agg(c.version, '|' order by c.version), '(vacío)')
    from public.consentimiento_terminos c where c.usuario_id = pg_temp.u(p_sufijo)
$$;

-- ---------------------------------------------------------------------------
-- 1. La tabla
-- ---------------------------------------------------------------------------
select has_table('public', 'consentimiento_terminos', 'existe consentimiento_terminos');
select col_is_pk('public', 'consentimiento_terminos', 'id', 'id es la clave');
select col_type_is('public', 'consentimiento_terminos', 'version', 'text', 'version es text');
select col_not_null('public', 'consentimiento_terminos', 'version', 'version es obligatoria');
select col_not_null('public', 'consentimiento_terminos', 'usuario_id', 'usuario_id es obligatorio');
select col_type_is('public', 'consentimiento_terminos', 'aceptado_en', 'timestamp with time zone',
                   'aceptado_en es timestamptz');
select col_not_null('public', 'consentimiento_terminos', 'aceptado_en', 'aceptado_en es obligatoria');
select fk_ok('public', 'consentimiento_terminos', 'usuario_id', 'public', 'usuario', 'id',
             'usuario_id apunta al perfil');
select has_index('public', 'consentimiento_terminos', 'consentimiento_terminos_usuario_version_key',
                 array['usuario_id', 'version'], 'una fila por (usuario, versión)');
select is((select relrowsecurity from pg_class where oid = 'public.consentimiento_terminos'::regclass),
          true, 'tiene RLS');
select is(
  (select array_agg(p.policyname || ':' || p.cmd collate "C" order by p.policyname collate "C")
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'consentimiento_terminos'),
  array['consentimiento_terminos_select_propio:SELECT'],
  'una sola política: leer lo propio (ninguna de escritura)'
);
select ok(not exists (select 1 from sync.entidad where nombre = 'consentimiento_terminos'),
          'no es entidad de sync: no baja al teléfono');

select ok(not (has_table_privilege('anon', 'public.consentimiento_terminos', 'select')
            or has_table_privilege('anon', 'public.consentimiento_terminos', 'insert')
            or has_table_privilege('anon', 'public.consentimiento_terminos', 'update')
            or has_table_privilege('anon', 'public.consentimiento_terminos', 'delete')),
          'anon no tiene ningún privilegio');
select ok(has_table_privilege('authenticated', 'public.consentimiento_terminos', 'select'),
          'authenticated lee');
select ok(not (has_table_privilege('authenticated', 'public.consentimiento_terminos', 'insert')
            or has_table_privilege('authenticated', 'public.consentimiento_terminos', 'update')
            or has_table_privilege('authenticated', 'public.consentimiento_terminos', 'delete')
            or has_table_privilege('authenticated', 'public.consentimiento_terminos', 'truncate')),
          'authenticated no escribe');
select ok(has_table_privilege('service_role', 'public.consentimiento_terminos', 'select')
          and has_table_privilege('service_role', 'public.consentimiento_terminos', 'insert')
          and has_table_privilege('service_role', 'public.consentimiento_terminos', 'update'),
          'service_role lee y escribe');
select ok(not has_function_privilege('authenticated', 'public.tg_auth_usuario_nuevo()', 'execute')
          and not has_function_privilege('anon', 'public.tg_auth_usuario_nuevo()', 'execute'),
          'la función del trigger del registro no la ejecuta ni authenticated ni anon');

-- ---------------------------------------------------------------------------
-- 2. El registro
-- ---------------------------------------------------------------------------

-- Con la versión: el perfil de siempre y la fila del consentimiento.
select is(pg_temp.registrar('a1', '{"nombre":"Rocío","apellido":"Alfa","terminos_version":"v1"}'), 'ok',
          'el registro con la versión v1 se crea');
select row_eq(
  $$ select email, nombre, apellido from public.usuario where id = pg_temp.u('a1') $$,
  row('terminos-a1@example.com'::text, 'Rocío'::text, 'Alfa'::text),
  'el perfil se crea como antes (email, nombre, apellido)'
);
select is(pg_temp.consentimientos('a1'), 'v1', 'queda una fila con la versión aceptada');
select row_eq(
  $$ select version, aceptado_en = now(), created_by = usuario_id, deleted_at is null, sync_version
       from public.consentimiento_terminos where usuario_id = pg_temp.u('a1') $$,
  row('v1'::text, true, true, true, 0::bigint),
  'versión, hora del servidor (now() de la transacción del registro), creada por la propia persona, viva'
);

-- Otras dos personas con la v1 (las lecturas de abajo las usan como coordinador y ADMIN).
select is(pg_temp.registrar('a2', '{"terminos_version":"v1"}'), 'ok', 'otra persona se registra con v1');
select is(pg_temp.consentimientos('a2'), 'v1', 'v1 queda guardada');
select is(pg_temp.registrar('a3', '{"terminos_version":"v1"}'), 'ok', 'una tercera persona se registra con v1');
select is(pg_temp.consentimientos('a3'), 'v1', 'v1 queda guardada también');

-- La lista de versiones publicadas está en un solo lugar y hoy es solo v1.
select is(public.terminos_versiones_publicadas(), array['v1']::text[], 'las versiones publicadas son solo v1');
select ok(not has_function_privilege('authenticated', 'public.terminos_versiones_publicadas()', 'execute')
          and not has_function_privilege('anon', 'public.terminos_versiones_publicadas()', 'execute'),
          'la lista de versiones publicadas no la ejecuta ni authenticated ni anon');

-- Una versión con la forma correcta pero que nunca se publicó se rechaza (decisión P2, 22/10): la v2 todavía
-- no existe, ni la v7, ni una de varios dígitos.
select is(pg_temp.registrar('e1', '{"terminos_version":"v2"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v2").',
  'v2 (forma válida, no publicada) se rechaza');
select is(pg_temp.registrar('e2', '{"terminos_version":"v7"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v7").',
  'v7 (forma válida, no publicada) se rechaza');
select is(pg_temp.registrar('e3', '{"terminos_version":"v12"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v12").',
  'v12 (forma válida, no publicada) se rechaza');
select is(pg_temp.registrar('e4', '{"terminos_version":"v123456789"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v123456789").',
  'v con 9 dígitos (forma válida, no publicada) se rechaza');

-- El cliente no pone la fecha ni el usuario ni el id: lo demás de los metadatos se ignora.
select is(pg_temp.registrar('a4',
  '{"terminos_version":"v1","aceptado_en":"2020-01-01T00:00:00Z","usuario_id":"01920000-0000-7000-8000-000000000001","created_by":"01920000-0000-7000-8000-000000000001"}'),
  'ok', 'metadatos de más no rompen el registro');
select row_eq(
  $$ select usuario_id = pg_temp.u('a4'), aceptado_en = now(), created_by = pg_temp.u('a4')
       from public.consentimiento_terminos where usuario_id = pg_temp.u('a4') $$,
  row(true, true, true),
  'la fecha y el usuario salen del servidor, no de los metadatos'
);

-- Sin la clave, o con null: el registro sigue igual y no se guarda nada (el móvil todavía no la manda).
select is(pg_temp.registrar('b1', '{"nombre":"Beto","apellido":"Bravo"}'), 'ok', 'el registro sin la clave se crea');
select is(pg_temp.consentimientos('b1'), '(vacío)', 'sin la clave no se guarda nada');
select is((select nombre from public.usuario where id = pg_temp.u('b1')), 'Beto', 'y el perfil se crea igual');
select is(pg_temp.registrar('b2', '{}'), 'ok', 'el registro con metadatos vacíos se crea');
select is(pg_temp.consentimientos('b2'), '(vacío)', 'con metadatos vacíos no se guarda nada');
select is(pg_temp.registrar('b3', '{"terminos_version":null}'), 'ok', 'el registro con la versión null se crea');
select is(pg_temp.consentimientos('b3'), '(vacío)', 'con la versión null no se guarda nada');
select is(pg_temp.registrar('b4', null), 'ok', 'el registro sin metadatos (null) se crea');
select is(pg_temp.consentimientos('b4'), '(vacío)', 'sin metadatos no se guarda nada');

-- Una forma inválida frena el registro con TC001 y no deja ni el perfil.
select is(pg_temp.registrar('c1', '{"terminos_version":"V1"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "V1").',
  'V1 en mayúscula se rechaza');
select is(pg_temp.registrar('c2', '{"terminos_version":"1"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "1").',
  '1 sin la v se rechaza');
select is(pg_temp.registrar('c3', '{"terminos_version":1}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "1").',
  'un número JSON se rechaza');
select is(pg_temp.registrar('c4', '{"terminos_version":"v0"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v0").',
  'v0 se rechaza');
select is(pg_temp.registrar('c5', '{"terminos_version":"v01"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v01").',
  'v01 (cero a la izquierda) se rechaza');
select is(pg_temp.registrar('c6', '{"terminos_version":""}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "").',
  'la cadena vacía se rechaza');
select is(pg_temp.registrar('c7', '{"terminos_version":"v1 "}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v1 ").',
  'v1 con un espacio se rechaza (no se recorta)');
select is(pg_temp.registrar('c8', '{"terminos_version":"v1" }'), 'ok', 'el espacio del JSON de afuera no cuenta');
select is(pg_temp.registrar('c9', '{"terminos_version":"v1234567890"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v1234567890").',
  'v con 10 dígitos se rechaza');
select is(pg_temp.registrar('d1', '{"terminos_version":"v1\n"}'),
  E'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v1\n").',
  'v1 con un salto de línea se rechaza ($ de la regex no lo deja pasar)');
select is(pg_temp.registrar('d2', '{"terminos_version":"v1; drop table usuario"}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v1; drop table usuario").',
  'texto de más se rechaza');
select is(pg_temp.registrar('d3', '{"terminos_version":["v1"]}'),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "["v1"]").',
  'una lista JSON se rechaza');
select is(pg_temp.registrar('d4', ('{"terminos_version":"v' || repeat('9', 60) || '"}')::jsonb),
  'TC001|La versión de los Términos y la Política de Privacidad no es una versión publicada (publicadas: v1; llegó "v' || repeat('9', 39) || '").',
  'una versión larguísima se rechaza y el mensaje la recorta a 40 caracteres');
select is(
  (select count(*) from public.usuario where id in
     (select pg_temp.u(s) from unnest(array['c1','c2','c3','c4','c5','c6','c7','c9','d1','d2','d3','d4','e1','e2','e3','e4']) s)),
  0::bigint,
  'ningún registro rechazado dejó el perfil'
);
select is(
  (select count(*) from auth.users where id in
     (select pg_temp.u(s) from unnest(array['c1','c2','c3','c4','c5','c6','c7','c9','d1','d2','d3','d4','e1','e2','e3','e4']) s)),
  0::bigint,
  'ningún registro rechazado dejó la cuenta'
);
select is(pg_temp.consentimientos('c8'), 'v1', 'el JSON con espacios de afuera guardó v1');

-- ---------------------------------------------------------------------------
-- 3. Quién lo lee y quién lo escribe
-- ---------------------------------------------------------------------------
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COLPORTOR'), ('a2','COORDINADOR'), ('a3','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select string_agg(version, '|') from public.consentimiento_terminos), 'v1',
          'Rocío lee su consentimiento y nada más');
select is((select count(*) from public.consentimiento_terminos where usuario_id = pg_temp.u('a2')), 0::bigint,
          'Rocío no lee el de otra persona');
select is(pg_temp.error_de($$ insert into public.consentimiento_terminos (usuario_id, version)
                             values (pg_temp.u('a1'), 'v2') $$),
          '42501|permission denied for table consentimiento_terminos', 'Rocío no se agrega una versión');
select is(pg_temp.error_de($$ update public.consentimiento_terminos set version = 'v9' $$),
          '42501|permission denied for table consentimiento_terminos', 'Rocío no cambia la versión aceptada');
select is(pg_temp.error_de($$ update public.consentimiento_terminos set deleted_at = now() $$),
          '42501|permission denied for table consentimiento_terminos', 'Rocío no se da de baja el consentimiento');
select is(pg_temp.error_de($$ delete from public.consentimiento_terminos $$),
          '42501|permission denied for table consentimiento_terminos', 'Rocío no lo borra');
select pg_temp.actuar_como_servidor();
select is(pg_temp.consentimientos('a1'), 'v1', 'y su fila sigue igual');

-- Un coordinador y un ADMIN tampoco lo leen (es de cada persona).
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*) from public.consentimiento_terminos), 1::bigint,
          'el coordinador lee solo el suyo (el de a2)');
select is((select version from public.consentimiento_terminos), 'v1', 'el suyo es v1');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is((select count(*) from public.consentimiento_terminos where usuario_id <> pg_temp.u('a3')), 0::bigint,
          'el ADMIN no lee los de las otras personas');
select pg_temp.actuar_como_servidor();

-- anon: nada.
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select count(*) from public.consentimiento_terminos $$),
          '42501|permission denied for table consentimiento_terminos', 'anon no lee');
select pg_temp.actuar_como_servidor();

-- El servidor: suma una versión nueva (historial) pero no repite una ni inventa una forma.
select pg_temp.actuar_como_service_role();
select is(pg_temp.error_de($$ insert into public.consentimiento_terminos (usuario_id, version)
                             values (pg_temp.u('a1'), 'v2') $$), 'ok', 'el servidor suma la v2 de Rocío');
select is(pg_temp.consentimientos('a1'), 'v1|v2', 'queda el historial: v1 y v2');
select is(left(pg_temp.error_de($$ insert into public.consentimiento_terminos (usuario_id, version)
                                  values (pg_temp.u('a1'), 'v2') $$), 5),
          '23505', 'la misma versión dos veces para la misma persona se rechaza');
select is(left(pg_temp.error_de($$ insert into public.consentimiento_terminos (usuario_id, version)
                                  values (pg_temp.u('a2'), 'versión 2') $$), 5),
          '23514', 'el servidor tampoco guarda una forma inválida');
select is(left(pg_temp.error_de($$ insert into public.consentimiento_terminos (usuario_id, version)
                                  values (pg_temp.u('ff'), 'v1') $$), 5),
          '23503', 'ni de una persona que no existe');
select pg_temp.actuar_como_servidor();

-- Auditoría: la actualización del servidor sube sync_version y no reescribe created_at/created_by.
update public.consentimiento_terminos set updated_at = now() - interval '1 day'
 where usuario_id = pg_temp.u('a1') and version = 'v1';
select row_eq(
  $$ select sync_version, created_by = usuario_id from public.consentimiento_terminos
      where usuario_id = pg_temp.u('a1') and version = 'v1' $$,
  row(1::bigint, true),
  'los triggers de auditoría corren (sync_version sube, created_by no se reescribe)'
);

-- ---------------------------------------------------------------------------
-- 4. Lo que ya existía y el borrado de la cuenta
-- ---------------------------------------------------------------------------
select is((select count(*) from public.consentimiento_terminos where usuario_id = pg_temp.u('b1')), 0::bigint,
          'una cuenta sin la versión sigue sin consentimiento (no se inventa)');

delete from auth.users where id = pg_temp.u('a1');
select is(pg_temp.consentimientos('a1'), '(vacío)', 'borrar la cuenta se lleva sus consentimientos');
select is((select count(*) from public.consentimiento_terminos where usuario_id = pg_temp.u('a2')), 1::bigint,
          'y no toca los de otras personas');

select * from finish();
rollback;
