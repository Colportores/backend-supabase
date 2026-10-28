-- pgTAP · migración 0143 (backend-supabase#203): la cuenta suspendida queda afuera.
--   · tiene_rol() no le da ningún rol mientras `usuario.suspendido_en` no sea null (ADMIN y
--     COORDINADOR), así que las reglas de acceso que lo usan la dejan afuera aunque la sesión siga
--     viva; la fila propia y estado_cuenta() siguen respondiendo (el cliente muestra el aviso);
--     al reactivar, el rol vuelve.
--   · sync_push y sync_pull rechazan la llamada entera con CS004 (de cualquier rol), antes que el
--     sobre; no escriben nada; al reactivar, el mismo lote entra.
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

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000143' || p)::uuid;
$$;

-- La suspensión la fija el servidor (la guarda de 0004 descarta el cambio de un JWT).
create or replace function pg_temp.suspender(p text) returns void language plpgsql as $$
begin
  perform pg_temp.como_servidor();
  update public.usuario set suspendido_en = now() where id = pg_temp.u(p);
end $$;

create or replace function pg_temp.reactivar(p text) returns void language plpgsql as $$
begin
  perform pg_temp.como_servidor();
  update public.usuario set suspendido_en = null where id = pg_temp.u(p);
end $$;

create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000143d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;

-- Una regla de acceso interna (sin EXECUTE para authenticated) vista como si la llamara p_uid.
create or replace function pg_temp.motivo_de(p_uid uuid, p_campania uuid) returns text
language plpgsql security definer set search_path = '' as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  return public.motivo_campania_del_coordinador(p_campania);
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 ADMIN · a2 COORDINADOR · b1 colportor de Verano en la zona Z1 · b2 colportor sin campaña.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'suspendido-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1', 'a2', 'b1', 'b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1', 'ADMIN'), ('a2', 'COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('1d'), 'Pais suspendido', 'ZS');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('1c'), 'Ciudad suspendido', 'Departamento de prueba', pg_temp.u('1d'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('e1'), 'Verano suspendido', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a2'));
insert into public.campania_ciudad (id, campania_id, ciudad_id)
values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('1c'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson)
values (pg_temp.u('d1'), 'Z1 suspendido', pg_temp.u('f1'), 'ESQUINAS',
        '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.18,-34.92],[-56.18,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id)
values (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'));

-- El lote que sube el teléfono de b1: una casa en su ciudad.
create temp table lote as
select jsonb_build_array(
  jsonb_build_object('client_op_id', pg_temp.u('a9'), 'entity', 'ubicacion', 'op', 'insert', 'sync_version', null,
                     'payload', jsonb_build_object('id', pg_temp.u('01'), 'tipo', 'CASA', 'calle', 'Suspendido',
                                                   'numero', '1', 'lat', -34.915, 'lon', -56.185,
                                                   'ciudad_id', pg_temp.u('1c')))
) as jobs;
grant select on lote to authenticated;

-- ---------------------------------------------------------------------------
-- 1. tiene_rol(): activo, suspendido, reactivado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(public.tiene_rol('COORDINADOR'), true, 'el coordinador activo tiene el rol');
select is(pg_temp.motivo_de(pg_temp.u('a2'), pg_temp.u('e1')), null, 'y la regla de acceso de su campaña lo deja pasar');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(public.tiene_rol('ADMIN'), true, 'el administrador activo tiene el rol');
select is((select count(*)::integer from public.usuario where id = pg_temp.u('b1')), 1,
          'y ve a los colportores (usuario_select_propio_o_admin)');

select pg_temp.suspender('a2');
select pg_temp.suspender('a1');

select pg_temp.actuar_como(pg_temp.u('a2'));
select is(public.tiene_rol('COORDINADOR'), false, 'el coordinador suspendido ya no tiene el rol, con la sesión abierta');
select is((select count(*)::integer from public.usuario where id = pg_temp.u('a2')), 1,
          'pero la fila propia sí la lee: es lo que muestra el aviso');
select is(public.estado_cuenta(), 'SUSPENDIDA', 'estado_cuenta() sigue contestando SUSPENDIDA');
select is(pg_temp.motivo_de(pg_temp.u('a2'), pg_temp.u('e1')), 'SIN_PERMISO',
          'una regla de acceso que usa tiene_rol lo rechaza (SIN_PERMISO), también sobre su propia campaña');

select pg_temp.actuar_como(pg_temp.u('a1'));
select is(public.tiene_rol('ADMIN'), false, 'el administrador suspendido tampoco tiene el rol');
select is((select count(*)::integer from public.usuario where id = pg_temp.u('b1')), 0,
          'y la base ya no le devuelve a los colportores');
select is((select count(*)::integer from public.usuario where id = pg_temp.u('a1')), 1, 'solo su fila');

-- Un JWT no levanta su propia suspensión (guarda de 0004).
update public.usuario set suspendido_en = null where id = pg_temp.u('a1');
select pg_temp.como_servidor();
select isnt((select suspendido_en from public.usuario where id = pg_temp.u('a1')), null,
            'un UPDATE de su propia fila no levanta la suspensión');

select pg_temp.reactivar('a2');
select pg_temp.reactivar('a1');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(public.tiene_rol('COORDINADOR'), true, 'reactivado, el coordinador recupera el rol');
select is(pg_temp.motivo_de(pg_temp.u('a2'), pg_temp.u('e1')), null, 'y la regla de acceso lo deja pasar');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(public.tiene_rol('ADMIN'), true, 'reactivado, el administrador recupera el rol');
select is((select count(*)::integer from public.usuario where id = pg_temp.u('b1')), 1, 'y vuelve a ver a los colportores');

-- El colportor no tiene rol de negocio que perder: tiene_rol sigue siendo falso para él, activo o no.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.tiene_rol('COORDINADOR'), false, 'un colportor nunca tuvo el rol de coordinador');

-- ---------------------------------------------------------------------------
-- 2. Privilegios de la comprobación nueva
-- ---------------------------------------------------------------------------
select function_privs_are('sync', 'exigir_cuenta_no_suspendida', array[]::text[], 'anon', array[]::text[],
                          'anon no puede llamar a la comprobación');
select function_privs_are('sync', 'exigir_cuenta_no_suspendida', array[]::text[], 'authenticated', array['EXECUTE'],
                          'authenticated sí (la llaman las puertas, que son INVOKER)');
select is(
  (select count(*)::integer
     from pg_proc p, aclexplode(p.proacl) a
    where p.oid = 'sync.exigir_cuenta_no_suspendida()'::regprocedure and a.grantee = 0),
  0, 'PUBLIC no tiene EXECUTE sobre la comprobación');

-- ---------------------------------------------------------------------------
-- 3. sync_push / sync_pull: la cuenta suspendida se rechaza entera con CS004
-- ---------------------------------------------------------------------------
-- Activa: sube y baja como siempre.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '[]'::jsonb)) ? 'watermark'),
          true, 'activa: sync_pull responde');

select pg_temp.suspender('b1');

select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', (select jobs from lote))) $$,
                 'CS004', null, 'suspendida: sync_push falla con CS004');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '[]'::jsonb)) $$,
                 'CS004', null, 'suspendida: sync_pull falla con CS004');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', (select jobs from lote))) $$,
                 'CS004', 'La cuenta está suspendida. Lo que tengas sin subir queda guardado en el teléfono y se sube cuando un administrador la reactive.',
                 'el mensaje dice qué pasa y qué hacer');
select throws_ok($$ select public.sync_push('{}'::jsonb) $$,
                 'CS004', null, 'se mira antes que el sobre: un push sin sobre de una cuenta suspendida es CS004, no CS002');
select throws_ok($$ select public.sync_pull('{}'::jsonb) $$,
                 'CS004', null, 'lo mismo en el pull');
select pg_temp.como_servidor();
select is((select count(*)::integer from public.ubicacion where id = pg_temp.u('01')), 0,
          'el push rechazado no escribió nada');
select is((select count(*)::integer from sync.op_cache where client_op_id = pg_temp.u('a9')), 0,
          'y no dejó la operación como hecha: reintentar es entrar de cero');

-- También la de un coordinador suspendido (cualquier rol).
select pg_temp.suspender('a2');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '[]'::jsonb)) $$,
                 'CS004', null, 'un coordinador suspendido también recibe CS004');
select pg_temp.reactivar('a2');

-- Sin sesión sigue siendo 42501 (la sesión se mira primero).
select set_config('request.jwt.claims', '', true), set_config('request.jwt.claim.sub', '', true), set_config('role', 'authenticated', true);
select throws_ok($$ select public.sync_push('{}'::jsonb) $$, '42501', null, 'sin sesión: 42501, no CS004');
select pg_temp.como_servidor();

-- Al reactivar, el mismo lote que quedó pendiente en el teléfono entra.
select pg_temp.reactivar('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select jsonb_path_query_array(
             public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', (select jobs from lote))),
             '$.results[*].outcome')),
          '["accepted"]'::jsonb, 'reactivada: el lote pendiente entra');
select is((select count(*)::integer from public.ubicacion where id = pg_temp.u('01')), 1, 'y la casa quedó escrita');
select is((select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '[]'::jsonb)) ? 'watermark'),
          true, 'y el pull responde otra vez');

select * from finish();
rollback;
