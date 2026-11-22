-- pgTAP · migración 0182 (backend-supabase#254, casilla «Términos»): la versión vigente de los Términos baja por el sync y la
-- aceptación de cada versión la registran todos los roles.
--   1. La clave `terminos_version_vigente` en `parametro_global` (sembrada en 1), el trigger que exige una versión publicada,
--      `terminos_version_vigente()` y los privilegios de las funciones nuevas.
--   2. `aceptar_terminos()`: una colportora, un coordinador y un administrador aceptan la vigente (null) o una publicada por
--      nombre; queda la fila con la hora del servidor, quién y el evento de auditoría; repetir no hace nada (ya_estaba);
--      una versión no publicada o con forma inválida: TC001 sin dejar nada; sin sesión o cuenta suspendida: 42501.
--   3. Sale la v2: se publica, pasa a vigente y cada rol la acepta (historial v1 + v2).
-- Va en una transacción (audit_log solo se agrega y no se puede limpiar). El pull está en 0182_…_pull_test.sql.

begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create or replace function pg_temp.sin_sesion() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000182' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- «version|ya_estaba» de lo que devuelve aceptar_terminos(), como la persona p.
create or replace function pg_temp.acepto(p text, p_version text default null) returns text language plpgsql as $$
declare r record;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  select * into r from public.aceptar_terminos(p_version);
  perform pg_temp.como_servidor();
  return r.version || '|' || r.ya_estaba;
end $$;

-- Lo que bajó de consentimiento_terminos: «versión,…».
create or replace function pg_temp.consentimientos(p_delta jsonb) returns text language sql as $$
  select coalesce(string_agg(e ->> 'version', ',' order by e ->> 'version'), '-')
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'consentimiento_terminos', '[]'::jsonb)) e
$$;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is((select valor from public.parametro_global where clave = 'terminos_version_vigente' and deleted_at is null), 1,
          'la clave terminos_version_vigente está sembrada en 1 (v1)');
select is(public.terminos_version_vigente(), 'v1', 'terminos_version_vigente(): v1');
select is((select count(*)::int from public.parametro_global where clave = 'dias_antiguedad_precios' and deleted_at is null), 1,
          'la clave de la 0070 sigue ahí, intacta');
select is(pg_temp.error_de($$ insert into public.parametro_global (clave, valor) values ('otra_clave', 1) $$), '23514|' ||
          'new row for relation "parametro_global" violates check constraint "parametro_global_clave_valor_check"',
          'una clave desconocida sigue rechazada por el CHECK');
select is(left(pg_temp.error_de($$ update public.parametro_global set valor = 0 where clave = 'terminos_version_vigente' $$), 5), 'TC001',
          'la versión 0 no entra (no es una publicada)');
select is(left(pg_temp.error_de($$ update public.parametro_global set valor = 1000000000 where clave = 'terminos_version_vigente' $$), 5), 'TC001',
          'ni una de más de 9 dígitos');
select is(left(pg_temp.error_de($$ update public.parametro_global set valor = 9 where clave = 'terminos_version_vigente' $$), 5), 'TC001',
          'una vigente que no está publicada (v9) no entra: TC001');
select is(public.terminos_version_vigente(), 'v1', 'y la vigente no cambió');
select is(has_function_privilege('anon', 'public.aceptar_terminos(text)', 'execute'), false, 'anon no ejecuta aceptar_terminos');
select is(has_function_privilege('authenticated', 'public.aceptar_terminos(text)', 'execute'), true, 'authenticated sí');
select is(has_function_privilege('anon', 'public.terminos_version_vigente()', 'execute'), false, 'anon no ejecuta terminos_version_vigente');
select is(has_function_privilege('authenticated', 'public.terminos_version_vigente()', 'execute'), true, 'authenticated sí');
select is(has_function_privilege('authenticated', 'public.tg_parametro_terminos_vigente()', 'execute'), false,
          'la función del trigger no la ejecuta nadie con JWT');
select results_eq(
  $$ select nombre, tabla::text, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where nombre = 'consentimiento_terminos' $$,
  $$ values ('consentimiento_terminos'::text, 'consentimiento_terminos'::text, false, false, null::text, 'usuario_id'::text) $$,
  'consentimiento_terminos es entidad de solo bajada con el dueño en usuario_id');
select has_index('public', 'consentimiento_terminos', 'consentimiento_terminos_duenio_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'el índice del delta, con el dueño primero');

-- ---------------------------------------------------------------------------
-- Fixtures: b1 colportora, c1 coordinador, ad administrador, b2 colportora suspendida, b3 sin ningún rol.
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'terminos182-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
update public.usuario set suspendido_en = now() where id = pg_temp.u('b2');

-- ---------------------------------------------------------------------------
-- 2. aceptar_terminos(): cualquier rol
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.consentimiento_terminos where usuario_id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('ad'))), 0,
          'al empezar nadie aceptó');
select is(pg_temp.acepto('b1'), 'v1|false', 'la colportora acepta la vigente (null): v1, no estaba');
select is(pg_temp.acepto('c1', 'v1'), 'v1|false', 'el coordinador acepta v1 por nombre');
select is(pg_temp.acepto('ad'), 'v1|false', 'el administrador acepta la vigente');
select is((select count(*)::int from public.consentimiento_terminos where usuario_id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('ad')) and version = 'v1'), 3,
          'tres filas, una por persona');
select ok((select bool_and(aceptado_en >= now() - interval '1 minute' and aceptado_en <= now() + interval '1 minute'
                           and created_by = usuario_id and deleted_at is null)
             from public.consentimiento_terminos where usuario_id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('ad'))),
          'con la hora del servidor y quién lo aceptó');
select is((select count(*)::int from auditoria.audit_log a
             join public.consentimiento_terminos c on c.id = a.fila_id
            where a.event_type = 'terminos_aceptados' and a.actor_user_id = pg_temp.u('c1') and a.target_user_id = pg_temp.u('c1')
              and a.tabla = 'consentimiento_terminos' and a.metadata = jsonb_build_object('version', 'v1')), 1,
          'el coordinador dejó el evento terminos_aceptados con la versión');
select is(pg_temp.acepto('b1'), 'v1|true', 'repetirla no hace nada: ya_estaba');
select is(pg_temp.acepto('b1', 'v1'), 'v1|true', 'ni por nombre');
select is((select count(*)::int from public.consentimiento_terminos where usuario_id = pg_temp.u('b1')), 1, 'una sola fila');
select is((select count(*)::int from auditoria.audit_log a join public.consentimiento_terminos c on c.id = a.fila_id
            where a.event_type = 'terminos_aceptados' and c.usuario_id = pg_temp.u('b1')), 1,
          'y un solo evento');

-- Errores: nada queda escrito.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(left(pg_temp.error_de($$ select * from public.aceptar_terminos('v7') $$), 5), 'TC001', 'una versión no publicada (v7): TC001');
select is(left(pg_temp.error_de($$ select * from public.aceptar_terminos('x1') $$), 5), 'TC001', 'una forma inválida: TC001');
select is(left(pg_temp.error_de($$ select * from public.aceptar_terminos('') $$), 5), 'TC001', 'vacía: TC001');
select ok(pg_temp.error_de($$ select * from public.aceptar_terminos('v7') $$) like 'TC001|La versión de los Términos%publicadas: v1%',
          'con un aviso que dice cuáles hay');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(left(pg_temp.error_de($$ select * from public.aceptar_terminos() $$), 5), '42501', 'una cuenta suspendida no acepta: 42501');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.error_de($$ select * from public.aceptar_terminos() $$) like 'ok%', true,
          'una cuenta activa sin rol sí puede (el consentimiento es de la persona, no del rol)');
select pg_temp.sin_sesion();
select is(left(pg_temp.error_de($$ select * from public.aceptar_terminos() $$), 5), '42501', 'sin sesión: 42501');
select pg_temp.como_servidor();
select is((select count(*)::int from public.consentimiento_terminos where usuario_id = pg_temp.u('b2')), 0, 'la suspendida no dejó nada');
select is((select count(*)::int from public.consentimiento_terminos where usuario_id = pg_temp.u('b1')), 1, 'ni los errores dejaron filas de más');

-- ---------------------------------------------------------------------------
-- 3. Salir la v2: se publica, pasa a vigente y cada rol la acepta
-- ---------------------------------------------------------------------------
create or replace function public.terminos_versiones_publicadas() returns text[] language sql immutable set search_path = ''
as $$ select array['v1', 'v2']::text[] $$;
update public.parametro_global set valor = 2 where clave = 'terminos_version_vigente';
select is(public.terminos_version_vigente(), 'v2', 'se publicó la v2 y es la vigente');
select is(pg_temp.acepto('ad'), 'v2|false', 'el administrador acepta la nueva con null (la vigente)');
select is(pg_temp.acepto('ad', 'v1'), 'v1|true', 'y la v1, que había aceptado, sigue registrada');
select is((select string_agg(version, ',' order by version) from public.consentimiento_terminos where usuario_id = pg_temp.u('ad')), 'v1,v2',
          'queda el historial: v1 y v2');

select * from finish();
rollback;
