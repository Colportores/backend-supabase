-- pgTAP · migración 0053 (backend-supabase#93, HU-CAM-008, vista 31 «Inicio», C2, supuesto S61):
-- usuario.ultimo_push_at, el momento en que el servidor recibió el último sync_push de un colportor.
--   1. La columna: timestamptz, opcional (null = todavía no llegó ninguna sincronización), y un
--      usuario nuevo no la trae. `usuario` sigue sin estar en sync.entidad.
--   2. Quién la marca: public.sync_push() con un lote que pasó la puerta, de cualquier tipo: vacío,
--      con altas aceptadas, con jobs inválidos, y el reintento (duplicate). Solo el usuario del JWT;
--      el resto queda en null. La marca es now() de la transacción.
--   3. Quién NO la marca: un lote que la puerta rechaza (sin sesión, sin sobre, sobre inválido, 501
--      jobs), un pull, y sync.push() llamada directo.
--   4. No retrocede: un push cuya hora es anterior a la guardada la deja; uno posterior la mueve. Y
--      dos pushes en la misma transacción no vuelven a escribir la fila (sync_version).
--   5. Solo el servidor la escribe: un PATCH de la propia fila (authenticated, también ADMIN) o de
--      anon no la cambia; postgres y service_role sí; la propia fila se puede seguir editando.
--   6. Permisos y forma de las funciones nuevas.
-- Va en una transacción: now() es fijo, y la marca se compara con él.
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
-- Como service_role, con o sin JWT (el JWT de service_role no trae `sub`).
create or replace function pg_temp.actuar_como_service_role() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('role', 'service_role', true);
end $$;
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000059' || p)::uuid;
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000059d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
-- Un push por la puerta con estos jobs.
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
-- La marca de un usuario, leída como servidor (sin pasar por la RLS ni cambiar de rol para siempre).
create or replace function pg_temp.marca(p_uid uuid) returns timestamptz language plpgsql as $$
declare
  v timestamptz;
  v_rol text := current_setting('role');
begin
  perform set_config('role', 'postgres', true);
  select ultimo_push_at into v from public.usuario where id = p_uid;
  perform set_config('role', v_rol, true);
  return v;
end $$;
create or replace function pg_temp.version(p_uid uuid) returns bigint language plpgsql as $$
declare
  v bigint;
  v_rol text := current_setting('role');
begin
  perform set_config('role', 'postgres', true);
  select sync_version into v from public.usuario where id = p_uid;
  perform set_config('role', v_rol, true);
  return v;
end $$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: b1 y b2 colportores de la ciudad f1 (b1 es el que empuja); b3 sin ningún push; ad ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'ultimo59-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais ultimo59', 'ZU');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('f1'), 'Ciudad f1 ultimo59', pg_temp.u('f0'), -34.9, -56.2),
  (pg_temp.u('f2'), 'Ciudad f2 ultimo59', pg_temp.u('f0'), -31.4, -57.9);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('f3'), 'Verano ultimo59', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30),
  (pg_temp.u('f4'), 'Otoño ultimo59',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f5'), pg_temp.u('f3'), pg_temp.u('f1')),
  (pg_temp.u('f6'), pg_temp.u('f4'), pg_temp.u('f2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('f3'), pg_temp.u('b1'), null),
  (pg_temp.u('f3'), pg_temp.u('b2'), null),
  (pg_temp.u('f3'), pg_temp.u('b3'), null);
-- Una casa de la ciudad f2 (que b1 no ve), para el job inválido.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('02'), 'CASA', 'Ultimo', '2', -31.4, -57.9, pg_temp.u('f2'));

-- Un job de alta de una casa de la ciudad f1 (entra) y uno de corrección de la casa de f2 (invalid).
create or replace function pg_temp.job_ok(p_n text) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u('a' || p_n), 'entity', 'ubicacion', 'op', 'insert',
                            'sync_version', null,
                            'payload', jsonb_build_object('id', pg_temp.u('0' || p_n), 'tipo', 'CASA',
                                                          'calle', 'Ultimo', 'numero', p_n,
                                                          'lat', -34.9 - p_n::int * 0.01, 'lon', -56.2,
                                                          'ciudad_id', pg_temp.u('f1')));
$$;
create or replace function pg_temp.job_malo() returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u('a9'), 'entity', 'ubicacion', 'op', 'update',
                            'sync_version', 1,
                            'payload', jsonb_build_object('id', pg_temp.u('02'), 'numero', '22'));
$$;

-- ---------------------------------------------------------------------------
-- 1. La columna
-- ---------------------------------------------------------------------------
select has_column('public', 'usuario', 'ultimo_push_at', 'usuario tiene ultimo_push_at');
select col_type_is('public', 'usuario', 'ultimo_push_at', 'timestamp with time zone',
                   'es timestamptz');
select col_is_null('public', 'usuario', 'ultimo_push_at', 'es opcional: null = todavía no llegó ningún push');
select col_hasnt_default('public', 'usuario', 'ultimo_push_at', 'y no tiene default');
select is((select count(*)::int from public.usuario where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('ad'))
              and ultimo_push_at is not null), 0,
          'un usuario nuevo (alta de auth.users) no trae marca: nunca subió datos');
select is((select count(*)::int from sync.entidad where nombre = 'usuario'), 0,
          'usuario no está en sync.entidad: subir su updated_at/sync_version no baja ni invalida nada');

-- ---------------------------------------------------------------------------
-- 2. Un push que pasó la puerta marca al usuario del JWT, y a nadie más
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.push('[]'::jsonb);
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'b1: un lote vacío que pasó la puerta marca now()');
select is(pg_temp.marca(pg_temp.u('b2')), null, 'b2, que no empujó, sigue en null');
select is(pg_temp.marca(pg_temp.u('b3')), null, 'b3, que no empujó, sigue en null');
select is(pg_temp.marca(pg_temp.u('ad')), null, 'el ADMIN, que no empujó, sigue en null');

-- Volver a null para probar cada tipo de lote desde cero.
select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = null where id = pg_temp.u('b1');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_ok as select pg_temp.push(jsonb_build_array(pg_temp.job_ok('1'))) as r;
select is((select pg_temp.resultados(r) from r_ok), array['accepted'], 'el lote de un alta se acepta');
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'un lote con un alta aceptada marca now()');

select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = null where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_dup as select pg_temp.push(jsonb_build_array(pg_temp.job_ok('1'))) as r;
select is((select pg_temp.resultados(r) from r_dup), array['duplicate'], 'el reintento del mismo lote vuelve duplicate');
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'un reintento (duplicate) también marca: el teléfono estaba conectado');

select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = null where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_mal as select pg_temp.push(jsonb_build_array(pg_temp.job_malo())) as r;
select is((select pg_temp.resultados(r) from r_mal), array['invalid'], 'el lote de un job que la RLS no deja vuelve invalid');
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'un lote todo invalid también marca: el servidor lo recibió');

select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = null where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.push(jsonb_build_array(pg_temp.job_ok('3'), pg_temp.job_malo()));
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'un lote mezclado marca');
select is(pg_temp.marca(pg_temp.u('b2')), null, 'y b2 sigue en null después de todos los pushes de b1');

-- Cada colportor marca lo suyo.
select pg_temp.actuar_como(pg_temp.u('b2'));
select pg_temp.push('[]'::jsonb);
select is(pg_temp.marca(pg_temp.u('b2')), now(), 'b2 marca lo suyo al empujar');
select is(pg_temp.marca(pg_temp.u('b3')), null, 'y b3 sigue sin marca');

-- ---------------------------------------------------------------------------
-- 3. Lo que NO marca
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = null where id in (pg_temp.u('b1'), pg_temp.u('b3'));

select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.error_de($$ select public.sync_push(jsonb_build_object('jobs', '[]'::jsonb)) $$), 'CS002',
          'sin sobre: CS002');
select is(pg_temp.error_de($$ select public.sync_push(jsonb_build_object(
            'device', jsonb_build_object('device_id', 'no-es-uuid', 'schema_version', 1), 'jobs', '[]'::jsonb)) $$), 'CS001',
          'sobre inválido: CS001');
select is(pg_temp.error_de($$ select public.sync_push(jsonb_build_object(
            'device', pg_temp.sobre(), 'jobs', '"no-es-array"'::jsonb)) $$), '22023', 'jobs que no es array: 22023');
select is(pg_temp.error_de($$ select pg_temp.push((select jsonb_agg(pg_temp.job_ok('4')) from generate_series(1, 501))) $$), 'CS003',
          '501 jobs: CS003');
select is(pg_temp.marca(pg_temp.u('b3')), null, 'ningún lote rechazado por la puerta dejó marca');

select pg_temp.actuar_sin_jwt();
select is(pg_temp.error_de($$ select pg_temp.push('[]'::jsonb) $$), '42501', 'sin sesión: 42501');
select is(pg_temp.marca(pg_temp.u('b3')), null, 'y sin sesión no se marca a nadie');

select pg_temp.actuar_como(pg_temp.u('b3'));
-- Un pull no cuenta: el dato es del push.
select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', jsonb_build_array('ubicacion')));
select is(pg_temp.marca(pg_temp.u('b3')), null, 'un pull no marca');
-- sync.push() llamada directo (no es la puerta del teléfono) tampoco.
select sync.push('[]'::jsonb, pg_temp.u('d0'));
select is(pg_temp.marca(pg_temp.u('b3')), null, 'sync.push() directo no marca');
-- La función de registro, sin sesión, no hace nada.
select pg_temp.actuar_sin_jwt();
select sync.registrar_push_recibido();
select is((select count(*)::int from public.usuario where id in (pg_temp.u('b3'), pg_temp.u('ad')) and ultimo_push_at is not null), 0,
          'registrar_push_recibido() sin sesión no marca a nadie');

-- ---------------------------------------------------------------------------
-- 4. No retrocede, y no reescribe la fila de más
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = now() + interval '1 day' where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.push('[]'::jsonb);
select is(pg_temp.marca(pg_temp.u('b1')), now() + interval '1 day',
          'un push con hora anterior a la guardada la deja (no retrocede)');

select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = now() - interval '4 days' where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.push('[]'::jsonb);
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'un push posterior a la guardada (hace 4 días) la mueve a now()');

-- Dos pushes en la misma transacción (now() no cambia): el segundo no vuelve a escribir la fila.
create temp table v_antes as select pg_temp.version(pg_temp.u('b1')) as v;
select pg_temp.push('[]'::jsonb);
select pg_temp.push('[]'::jsonb);
select is(pg_temp.version(pg_temp.u('b1')), (select v from v_antes),
          'con la marca ya en now(), otro push no escribe la fila de usuario (sync_version igual)');
select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = now() - interval '1 minute' where id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table v_antes2 as select pg_temp.version(pg_temp.u('b1')) as v;
select pg_temp.push('[]'::jsonb);
select is(pg_temp.version(pg_temp.u('b1')), (select v + 1 from v_antes2),
          'un push con la marca vieja escribe la fila una sola vez (sync_version + 1)');

-- ---------------------------------------------------------------------------
-- 5. Solo el servidor la escribe
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = null where id in (pg_temp.u('b1'), pg_temp.u('ad'));

-- Un colportor que se PATCHea la fila no puede fingir que está conectado...
select pg_temp.actuar_como(pg_temp.u('b1'));
update public.usuario set ultimo_push_at = now() where id = pg_temp.u('b1');
select is(pg_temp.marca(pg_temp.u('b1')), null, 'un colportor no se puede poner la marca con un UPDATE de su fila');
update public.usuario set ultimo_push_at = '2020-01-01'::timestamptz, nombre = 'Cambiado' where id = pg_temp.u('b1');
select is(pg_temp.marca(pg_temp.u('b1')), null, 'ni junto con otro cambio de la fila entera');
select is((select nombre from public.usuario where id = pg_temp.u('b1')), 'Cambiado',
          'y el resto de su fila se sigue pudiendo editar (se descarta sólo la marca, sin error)');

-- ...ni borrar la que tiene.
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.push('[]'::jsonb);
update public.usuario set ultimo_push_at = null where id = pg_temp.u('b1');
select is(pg_temp.marca(pg_temp.u('b1')), now(), 'ni se puede borrar la marca que tiene');

-- Ni el ADMIN con su JWT.
select pg_temp.actuar_como(pg_temp.u('ad'));
update public.usuario set ultimo_push_at = '2020-01-01'::timestamptz where id = pg_temp.u('b2');
select is(pg_temp.marca(pg_temp.u('b2')), now(),
          'el ADMIN con su JWT tampoco la cambia (b2 conserva la de su push)');
update public.usuario set ultimo_push_at = now() - interval '9 days' where id = pg_temp.u('ad');
select is(pg_temp.marca(pg_temp.u('ad')), null, 'ni la suya');

-- anon no tiene ni UPDATE sobre usuario.
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ update public.usuario set ultimo_push_at = now() where id = pg_temp.u('b3') $$), '42501',
          'anon no puede actualizar usuario');

-- El servidor sí la escribe: postgres y service_role.
select pg_temp.actuar_como_servidor();
update public.usuario set ultimo_push_at = '2026-10-01 10:00+00' where id = pg_temp.u('b3');
select is(pg_temp.marca(pg_temp.u('b3')), '2026-10-01 10:00+00'::timestamptz, 'el servidor (postgres) la escribe');
select pg_temp.actuar_como_service_role();
update public.usuario set ultimo_push_at = '2026-10-02 11:00+00' where id = pg_temp.u('b3');
select is(pg_temp.marca(pg_temp.u('b3')), '2026-10-02 11:00+00'::timestamptz, 'service_role la escribe');

-- ---------------------------------------------------------------------------
-- 6. Permisos y forma de las funciones nuevas
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select function_privs_are('sync', 'registrar_push_recibido', array[]::text[], 'anon', array[]::text[],
                          'anon no puede llamar a registrar_push_recibido');
select function_privs_are('sync', 'registrar_push_recibido', array[]::text[], 'authenticated', array['EXECUTE'],
                          'authenticated sí (la llama la puerta, que corre como quien llama)');
select function_privs_are('sync', 'registrar_push_recibido', array[]::text[], 'service_role', array['EXECUTE'],
                          'service_role también');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where p.oid = 'sync.registrar_push_recibido()'::regprocedure and a.grantee = 0), 0,
          'PUBLIC no tiene EXECUTE sobre registrar_push_recibido');
select is((select prosecdef from pg_proc where oid = 'sync.registrar_push_recibido()'::regprocedure), true,
          'registrar_push_recibido es SECURITY DEFINER (escribe la marca como el servidor)');
select is((select prosecdef from pg_proc where oid = 'public.sync_push(jsonb)'::regprocedure), false,
          'y sync_push sigue siendo SECURITY INVOKER (la RLS es la del colportor)');
select is((select proconfig from pg_proc where oid = 'sync.registrar_push_recibido()'::regprocedure),
          array['search_path=""'], 'con search_path vacío');
select function_privs_are('public', 'tg_usuario_ultimo_push_servidor', array[]::text[], 'authenticated', array[]::text[],
                          'authenticated no puede llamar a la función del trigger');
select has_trigger('public', 'usuario', 'usuario_ultimo_push_servidor', 'usuario tiene el trigger que guarda la marca');
select function_privs_are('public', 'sync_push', array['jsonb'], 'anon', array[]::text[],
                          'anon sigue sin poder llamar a sync_push');
select function_privs_are('public', 'sync_push', array['jsonb'], 'authenticated', array['EXECUTE'],
                          'authenticated sigue pudiendo llamar a sync_push');

select * from finish();
rollback;
