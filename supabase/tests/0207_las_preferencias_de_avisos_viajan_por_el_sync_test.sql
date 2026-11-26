-- pgTAP · las preferencias de avisos viajan por el sync
-- (migración 0207, backend-supabase#313, «Avisos s/red»; decisión de Cristian del 24/11)
--
-- Diego cambia, sin señal, la hora del aviso de Cuotas y apaga «Tickets»: el cambio queda en el teléfono y sube después como una
-- fila más del motor (`preferencia_de_avisos`). Casos:
--   1. forma: una fila por persona desde que existe (también las que ya existían), con las mismas reglas que
--      usuario.notif_preferences;
--   2. el push actualiza la fila de quien sube y el servidor (usuario.notif_preferences, lo que lee el aviso de las 09:00) la ve;
--   3. la forma inválida vuelve `invalid` sin tumbar el lote y no cambia nada;
--   4. dos teléfonos: el segundo en subir, con la versión vieja, recibe `conflict` (rige el último cambio del motor);
--   5. nadie toca la fila de otra persona, ni la lee; un `delete` del push no la da de baja;
--   6. la RPC de siempre (guardar_mis_preferencias_de_avisos) sigue andando y llega a la fila que baja a los teléfonos;
--   7. lo que se guarda directo en usuario (el servidor) también llega a la fila.
-- Va en una transacción (el pull se prueba en 0207_..._pull_test.sql).
begin;
select * from no_plan();

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
  select ('01920000-0000-7000-8000-0000000207' || p)::uuid;
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia.
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.version_de(p text) returns bigint language sql as $$
  select sync_version from public.preferencia_de_avisos where id = pg_temp.u(p);
$$;
-- Un job de update de la fila de preferencias de una persona; devuelve el resultado.
create or replace function pg_temp.push_prefs(p_quien text, p_prefs jsonb, p_version bigint) returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', gen_random_uuid(), 'entity', 'preferencia_de_avisos', 'op', 'update',
           'sync_version', p_version,
           'payload', jsonb_build_object('id', pg_temp.u(p_quien), 'notif_preferences', p_prefs)))) -> 'results' -> 0;
$$;
create or replace function pg_temp.prefs_tabla(p text) returns jsonb language sql as $$
  select notif_preferences from public.preferencia_de_avisos where id = pg_temp.u(p);
$$;
create or replace function pg_temp.prefs_usuario(p text) returns jsonb language sql as $$
  select notif_preferences from public.usuario where id = pg_temp.u(p);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- d1 Diego y d2 otra persona. «ex» existía antes de la migración: se crea con preferencias y se prueba su fila más abajo.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'prefs207-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['d1','d2']) s;

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select has_table('public', 'preferencia_de_avisos', 'la tabla existe');
select col_type_is('public', 'preferencia_de_avisos', 'notif_preferences', 'jsonb', 'notif_preferences es jsonb');
select col_is_pk('public', 'preferencia_de_avisos', 'id', 'la clave es el id de la persona');
select ok(exists (select 1 from sync.entidad where nombre = 'preferencia_de_avisos' and permite_push and columna_duenio = 'id'),
          'está en el sync: push y pull, la dueña es la persona');
select is((select count(*)::int from public.usuario u where not exists (select 1 from public.preferencia_de_avisos p where p.id = u.id)), 0,
          'todas las personas tienen su fila (las que ya existían y las nuevas)');
select is(pg_temp.prefs_tabla('d1'), null, 'la fila de una persona nueva viene vacía (todo por defecto)');

select is(pg_temp.error_de($$insert into public.preferencia_de_avisos (id, notif_preferences) values (gen_random_uuid(), '{}')$$), '23503',
          'una fila de alguien que no existe: 23503');
select is(pg_temp.error_de(format($$update public.preferencia_de_avisos set notif_preferences = '[]' where id = %L$$, pg_temp.u('d1'))), '23514',
          'un arreglo no es un objeto: 23514');
select is(pg_temp.error_de(format($$update public.preferencia_de_avisos set notif_preferences = '{"hora_cuota":"25:00"}' where id = %L$$, pg_temp.u('d1'))), '23514',
          'hora_cuota fuera de rango: 23514');
select is(pg_temp.error_de(format($$update public.preferencia_de_avisos set notif_preferences = '{"hora_agenda":"9:00"}' where id = %L$$, pg_temp.u('d1'))), '23514',
          'hora_agenda sin cero: 23514');
select is(pg_temp.error_de(format($$update public.preferencia_de_avisos set notif_preferences = jsonb_build_object('x', repeat('a', 4100)) where id = %L$$, pg_temp.u('d1'))), '23514',
          'más de 4096 caracteres: 23514');
select is(pg_temp.error_de(format($$update public.preferencia_de_avisos set notif_preferences = '{"hora_cuota":"08:05","tickets":false}' where id = %L$$, pg_temp.u('d1'))), 'ok',
          'una forma válida (hora y un interruptor booleano) entra');
select is(pg_temp.prefs_usuario('d1'), '{"hora_cuota":"08:05","tickets":false}'::jsonb,
          'y llega a usuario.notif_preferences, lo que lee el aviso del servidor');
update public.preferencia_de_avisos set notif_preferences = null where id = pg_temp.u('d1');
select is(pg_temp.prefs_usuario('d1'), null, 'dejar el objeto en null también llega (todo por defecto)');

-- ---------------------------------------------------------------------------
-- 2. El push (como Diego)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('d1'));

select is(pg_temp.push_prefs('d1', '{"hora_cuota":"10:30","tickets":false,"agenda":true}'::jsonb, pg_temp.version_de('d1')) ->> 'outcome',
          'accepted', 'Diego sube su cambio sin señal: accepted');
select is(pg_temp.prefs_tabla('d1'), '{"hora_cuota":"10:30","tickets":false,"agenda":true}'::jsonb, 'la fila queda con lo que subió');
select pg_temp.como_servidor();
select is(pg_temp.prefs_usuario('d1'), '{"hora_cuota":"10:30","tickets":false,"agenda":true}'::jsonb,
          'y el servidor lo ve en usuario.notif_preferences: la hora del aviso de cuotas es la suya');
select pg_temp.actuar_como(pg_temp.u('d1'));

-- ---------------------------------------------------------------------------
-- 3. Forma inválida: invalid, y no cambia nada
-- ---------------------------------------------------------------------------
select is(pg_temp.push_prefs('d1', '{"hora_cuota":"99:99"}'::jsonb, pg_temp.version_de('d1')) ->> 'outcome', 'invalid',
          'una hora inválida vuelve invalid (23514), sin tumbar el lote');
select is(pg_temp.prefs_tabla('d1'), '{"hora_cuota":"10:30","tickets":false,"agenda":true}'::jsonb, 'y la fila queda como estaba');
select is(pg_temp.push_prefs('d1', '[1]'::jsonb, pg_temp.version_de('d1')) ->> 'outcome', 'invalid', 'un arreglo también');

-- ---------------------------------------------------------------------------
-- 4. Dos teléfonos: rige el último cambio del motor
-- ---------------------------------------------------------------------------
-- Los dos teléfonos de Diego bajaron la versión v; el primero sube y el segundo, con la v vieja, choca.
create temp table t4 as select pg_temp.version_de('d1') as v;
select is(pg_temp.push_prefs('d1', '{"hora_cuota":"07:00"}'::jsonb, (select v from t4)) ->> 'outcome', 'accepted', 'el primer teléfono sube');
select is(pg_temp.push_prefs('d1', '{"hora_cuota":"12:00"}'::jsonb, (select v from t4)) ->> 'outcome', 'conflict',
          'el segundo, con la versión que bajó antes, recibe conflict (el motor resuelve el último cambio)');
select is(pg_temp.prefs_tabla('d1'), '{"hora_cuota":"07:00"}'::jsonb, 'y no pisó lo del primero');
-- Resuelto: el segundo teléfono vuelve a subir con la versión nueva y queda lo último.
select is(pg_temp.push_prefs('d1', '{"hora_cuota":"12:00"}'::jsonb, pg_temp.version_de('d1')) ->> 'outcome', 'accepted',
          'con la versión nueva el segundo sube y queda el último cambio');
select is(pg_temp.prefs_tabla('d1'), '{"hora_cuota":"12:00"}'::jsonb, 'la fila tiene el último cambio');

-- ---------------------------------------------------------------------------
-- 5. Nadie toca la de otra persona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('d2'));
select is((select count(*)::int from public.preferencia_de_avisos), 1, 'Diego2 lee solo la suya');
select is((select count(*)::int from public.preferencia_de_avisos where id = pg_temp.u('d1')), 0, 'y no la de Diego');
select is(pg_temp.push_prefs('d1', '{"hora_cuota":"01:00"}'::jsonb, pg_temp.version_de('d1')) ->> 'outcome', 'invalid',
          'subir un cambio a la fila de Diego es invalid');
select is(pg_temp.error_de(format($$update public.preferencia_de_avisos set notif_preferences = '{}' where id = %L$$, pg_temp.u('d1'))), 'ok',
          'el update directo no falla pero no toca nada (la RLS no la deja ver)');
select is(pg_temp.error_de(format($$insert into public.preferencia_de_avisos (id, notif_preferences) values (%L, '{}')$$, pg_temp.u('d1'))), '42501',
          'ni insertar una a nombre de Diego (42501)');
select pg_temp.como_servidor();
select is(pg_temp.prefs_tabla('d1'), '{"hora_cuota":"12:00"}'::jsonb, 'la fila de Diego sigue como la dejó él');

-- La fila no se da de baja con el push.
select pg_temp.actuar_como(pg_temp.u('d1'));
select sync.push(jsonb_build_array(jsonb_build_object(
         'client_op_id', gen_random_uuid(), 'entity', 'preferencia_de_avisos', 'op', 'delete',
         'sync_version', pg_temp.version_de('d1'), 'payload', jsonb_build_object('id', pg_temp.u('d1')))));
select pg_temp.como_servidor();
select is((select deleted_at from public.preferencia_de_avisos where id = pg_temp.u('d1')), null, 'un delete del push no da de baja la fila');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de(format($$delete from public.preferencia_de_avisos where id = %L$$, pg_temp.u('d1'))), '42501',
          'y el delete directo no tiene privilegio (42501)');

-- ---------------------------------------------------------------------------
-- 6. La RPC de siempre llega a la fila que baja
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de($$select public.guardar_mis_preferencias_de_avisos('{"hora_agenda":"21:15"}'::jsonb)$$), 'ok', 'la RPC guarda');
select pg_temp.como_servidor();
select is(pg_temp.prefs_tabla('d1'), '{"hora_agenda":"21:15"}'::jsonb, 'y llega a la fila de la tabla (la que baja al teléfono)');
select is(pg_temp.prefs_usuario('d1'), '{"hora_agenda":"21:15"}'::jsonb, 'y a usuario.notif_preferences');
select is((select sync_version from public.preferencia_de_avisos where id = pg_temp.u('d1')) = pg_temp.version_de('d1'), true, 'una sola fila');
create temp table t6 as select pg_temp.version_de('d1') as v;
select pg_temp.actuar_como(pg_temp.u('d1'));
select public.guardar_mis_preferencias_de_avisos('{"hora_agenda":"21:15"}'::jsonb);
select pg_temp.como_servidor();
select is(pg_temp.version_de('d1'), (select v from t6), 'guardar el mismo valor no toca la fila (no hay versión nueva)');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de($$select public.guardar_mis_preferencias_de_avisos('{"hora_cuota":"mañana"}'::jsonb)$$), '23514', 'una forma inválida sigue siendo 23514');
select is(pg_temp.error_de($$select public.guardar_mis_preferencias_de_avisos(null)$$), 'ok', 'null vuelve a los valores por defecto');
select pg_temp.como_servidor();
select is(pg_temp.prefs_tabla('d1'), null, 'y la fila queda en null');
select is(pg_temp.prefs_usuario('d1'), null, 'y usuario también');

-- ---------------------------------------------------------------------------
-- 7. Lo que se guarda directo en usuario llega a la fila
-- ---------------------------------------------------------------------------
update public.usuario set notif_preferences = '{"hora_cuota":"06:45"}' where id = pg_temp.u('d2');
select is(pg_temp.prefs_tabla('d2'), '{"hora_cuota":"06:45"}'::jsonb, 'un cambio directo en usuario baja a la fila de la tabla');
-- Y una persona sin fila (se la sacamos a mano) la recupera con su próximo cambio.
delete from public.preferencia_de_avisos where id = pg_temp.u('d2');
update public.usuario set notif_preferences = '{"hora_cuota":"07:45"}' where id = pg_temp.u('d2');
select is(pg_temp.prefs_tabla('d2'), '{"hora_cuota":"07:45"}'::jsonb, 'si faltaba la fila, el cambio la crea');

select * from finish();
rollback;
