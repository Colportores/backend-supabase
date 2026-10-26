-- pgTAP · migración 0110 (backend-supabase#152, seguimiento de #137, HU-CAT-006; «Precio viejo»):
-- cada cambio de parametro_global queda en audit_log.
--   1. La forma: los dos triggers y sus funciones (SECURITY DEFINER, sin acceso para ningún rol).
--   2. El cambio de valor: un registro con el valor anterior y el nuevo, la fila, el cuándo y el rol del
--      servidor; sin usuario el actor es null, con usuario es ese usuario.
--   3. Lo que NO registra: un UPDATE sin cambios, un cambio rechazado por el CHECK, un intento de un cliente.
--   4. Alta, baja lógica, reactivación, DELETE y TRUNCATE.
--   5. Que el registro y el cambio van juntos (una sola transacción) y que audit_log sigue cerrada.
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
-- El SQL Editor: el rol dueño, sin JWT.
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;
-- service_role de la API: JWT con el rol y sin usuario.
create or replace function pg_temp.actuar_como_service_role() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  perform set_config('role', 'service_role', true);
end $$;
-- Lo que haría una RPC de Administración (SECURITY DEFINER) cuando exista: corre como el dueño, pero con
-- el JWT del administrador, así que auth.uid() es él.
create or replace function pg_temp.actuar_como_rpc_de(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'postgres', true);
end $$;
-- Un cliente con JWT: sin escritura sobre la tabla.
create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000110' || p)::uuid;
$$;
-- SQLSTATE|mensaje del error que da una sentencia ('ok' si no da ninguno).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;
create or replace function pg_temp.codigo_de(p_sql text) returns text language sql as $$
  select split_part(pg_temp.error_de(p_sql), '|', 1)
$$;
-- Cuántos registros de parametro_global hay (como dueño: un cliente no ve audit_log), de un evento o de todos.
create or replace function pg_temp.n(p_event text default null) returns bigint language sql as $$
  select count(*) from auditoria.audit_log
   where (tabla = 'parametro_global' or event_type like 'parametro_global%')
     and (p_event is null or event_type = p_event)
$$;
-- El registro de un evento que cumple el filtro del detalle, en una sola fila de texto:
-- evento|actor|fila|metadata. created_at es now() en toda la transacción: no hay «el último» por fecha,
-- así que cada registro se pide por su evento y su detalle (si hubiera dos, el texto sale doble y falla).
create or replace function pg_temp.reg(p_event text, p_filtro text) returns text language sql as $$
  select string_agg(event_type || '|' || coalesce(actor_user_id::text, '-') || '|' || coalesce(fila_id::text, '-')
                    || '|' || metadata::text, ' // ')
    from auditoria.audit_log
   where event_type = p_event and metadata @> p_filtro::jsonb
$$;

-- --- fixtures ------------------------------------------------------------------
-- a1 ADMIN · b1 colportor.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'param110-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1', 'b1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('a1'), r.id from public.rol r where r.codigo = 'ADMIN';

-- La fila de referencia de 0070 (15 días).
create temp table fila on commit drop as
select id from public.parametro_global where clave = 'dias_antiguedad_precios' and deleted_at is null;
grant select on fila to public;

-- ===============================================================================
-- 1. La forma
-- ===============================================================================
select has_trigger('public', 'parametro_global', 'parametro_global_auditar_cambio', 'trigger por fila del cambio');
select has_trigger('public', 'parametro_global', 'parametro_global_auditar_vaciado', 'trigger del TRUNCATE');
select has_function('public', 'tg_parametro_global_auditar', array[]::text[], 'la función del trigger por fila');
select has_function('public', 'tg_parametro_global_vaciado', array[]::text[], 'la función del trigger del TRUNCATE');
select is((select count(*)::int from pg_proc
            where pronamespace = 'public'::regnamespace
              and proname in ('tg_parametro_global_auditar', 'tg_parametro_global_vaciado')
              and prosecdef and proconfig @> array['search_path=""']), 2,
          'las dos son SECURITY DEFINER con search_path vacío (un trigger que registra tiene que serlo, 0073)');
select is((select bool_or(has_function_privilege(r, 'public.tg_parametro_global_auditar()', 'execute')
                          or has_function_privilege(r, 'public.tg_parametro_global_vaciado()', 'execute'))
             from unnest(array['anon', 'authenticated', 'service_role']) r), false,
          'ni anon, ni authenticated, ni service_role las ejecutan a mano');
select is((select tgenabled from pg_trigger where tgname = 'parametro_global_auditar_cambio'), 'O',
          'el trigger del cambio está activo');

-- La migración no registra hacia atrás: la fila de 15 de 0070 no tiene evento de alta.
select is(pg_temp.n(), 0::bigint, 'al arrancar no hay ningún registro de parametro_global');

-- ===============================================================================
-- 2. El cambio de valor: el caso de uso (15 a 20)
-- ===============================================================================
select pg_temp.actuar_como_servidor();
update public.parametro_global set valor = 20 where id = (select id from fila);
select is(pg_temp.n(), 1::bigint, 'el cambio de 15 a 20 desde el SQL Editor deja un registro');
select is(pg_temp.n('parametro_global_cambio'), 1::bigint, 'es del evento parametro_global_cambio');
select is(pg_temp.reg('parametro_global_cambio', '{"valor_nuevo": 20}'),
          'parametro_global_cambio|-|' || (select id from fila) || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', 15, 'valor_nuevo', 20,
                                'rol', session_user::text)::text,
          'sin usuario no hay actor; dice la fila, el valor anterior, el nuevo y el rol de la conexión');
select is((select tabla || '|' || fila_id::text from auditoria.audit_log
            where event_type = 'parametro_global_cambio'),
          'parametro_global|' || (select id from fila), 'nombra la tabla y la fila');
select ok((select created_at = now() from auditoria.audit_log where event_type = 'parametro_global_cambio'),
          'y cuándo (el momento de la transacción)');
select is((select target_user_id from auditoria.audit_log where event_type = 'parametro_global_cambio'), null::uuid,
          'no hay una persona sobre la que se actúe: target null');
select is((select auditoria.metadata_sin_datos_personales(metadata) from auditoria.audit_log
            where event_type = 'parametro_global_cambio'), true,
          'el detalle no tiene correo ni datos de personas');

-- Un segundo cambio suma otro registro, no pisa el primero.
update public.parametro_global set valor = 25 where id = (select id from fila);
select is(pg_temp.n('parametro_global_cambio'), 2::bigint, 'cada cambio es un registro propio');
select is((select string_agg((metadata ->> 'valor_anterior') || '>' || (metadata ->> 'valor_nuevo'), ','
                          order by (metadata ->> 'valor_nuevo')::int)
             from auditoria.audit_log where event_type = 'parametro_global_cambio'),
          '15>20,20>25', 'la cadena de valores se puede reconstruir');

-- service_role de la API: sin usuario; el rol es el del JWT.
select pg_temp.actuar_como_service_role();
update public.parametro_global set valor = 30 where id = (select id from fila);
select pg_temp.actuar_como_servidor();
select is(pg_temp.reg('parametro_global_cambio', '{"valor_nuevo": 30}'),
          'parametro_global_cambio|-|' || (select id from fila) || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', 25, 'valor_nuevo', 30,
                                'rol', 'service_role')::text,
          'service_role: actor null y rol service_role');

-- Una RPC de Administración (futura): el actor es el administrador.
select pg_temp.actuar_como_rpc_de(pg_temp.u('a1'));
update public.parametro_global set valor = 40 where id = (select id from fila);
select pg_temp.actuar_como_servidor();
select is(pg_temp.reg('parametro_global_cambio', '{"valor_nuevo": 40}'),
          'parametro_global_cambio|' || pg_temp.u('a1') || '|' || (select id from fila) || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', 30, 'valor_nuevo', 40,
                                'rol', 'authenticated')::text,
          'con usuario el actor es quien llamó');

-- ===============================================================================
-- 3. Lo que no registra
-- ===============================================================================
select is(pg_temp.n(), 4::bigint, 'hasta acá, cuatro cambios, cuatro registros');

update public.parametro_global set valor = 40 where id = (select id from fila);
select is(pg_temp.n(), 4::bigint, 'un UPDATE al mismo valor no es un cambio: no registra');
update public.parametro_global set updated_at = now() + interval '1 minute' where id = (select id from fila);
select is(pg_temp.n(), 4::bigint, 'ni uno que solo toca updated_at');
update public.parametro_global set clave = clave where id = (select id from fila);
select is(pg_temp.n(), 4::bigint, 'ni uno que reescribe la misma clave');

-- Un valor fuera de rango lo rechaza el CHECK de 0070 y el cambio no existe: tampoco su registro.
select is(pg_temp.codigo_de($$ update public.parametro_global set valor = 0 where clave = 'dias_antiguedad_precios' $$),
          '23514', '0 días lo rechaza el CHECK');
select is(pg_temp.codigo_de($$ update public.parametro_global set valor = 366 where clave = 'dias_antiguedad_precios' $$),
          '23514', '366 también');
select is(pg_temp.n(), 4::bigint, 'un cambio rechazado no deja registro');
select is((select valor from public.parametro_global where id = (select id from fila)), 40, 'y el valor sigue en 40');

-- Un cliente con JWT no escribe la tabla (ni el ADMIN): no hay cambio, no hay registro.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.codigo_de($$ update public.parametro_global set valor = 99 where clave = 'dias_antiguedad_precios' $$),
          '42501', 'el ADMIN con su JWT no puede escribir la tabla todavía');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.codigo_de($$ update public.parametro_global set valor = 99 where clave = 'dias_antiguedad_precios' $$),
          '42501', 'ni un colportor');
select is(pg_temp.codigo_de($$ insert into public.parametro_global (clave, valor) values ('dias_antiguedad_precios', 3) $$),
          '42501', 'ni dar de alta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n(), 4::bigint, 'los intentos de un cliente no dejan registro');

-- ===============================================================================
-- 4. Baja, reactivación, alta, DELETE y TRUNCATE
-- ===============================================================================
update public.parametro_global set deleted_at = now() where id = (select id from fila);
select is(pg_temp.reg('parametro_global_baja', '{"definitiva": false}'),
          'parametro_global_baja|-|' || (select id from fila) || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', 40, 'valor_nuevo', null,
                                'rol', session_user::text, 'definitiva', false)::text,
          'la baja lógica: el valor que tenía, sin valor nuevo, y no es definitiva');

-- Cambiar el valor de una fila de baja sigue siendo un cambio.
update public.parametro_global set valor = 50 where id = (select id from fila);
select is((select (metadata ->> 'valor_anterior') || '>' || (metadata ->> 'valor_nuevo') from auditoria.audit_log
            where event_type = 'parametro_global_cambio' and metadata @> '{"valor_nuevo": 50}'), '40>50',
          'un cambio de valor sobre una fila de baja también queda');

-- La reactivación es un alta: no había valor vigente.
update public.parametro_global set deleted_at = null where id = (select id from fila);
select is(pg_temp.reg('parametro_global_alta', '{"valor_nuevo": 50}'),
          'parametro_global_alta|-|' || (select id from fila) || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', null, 'valor_nuevo', 50,
                                'rol', session_user::text)::text,
          'reactivar la fila es un alta: sin valor anterior, con el nuevo');

-- El borrado de verdad.
delete from public.parametro_global where id = (select id from fila);
select is(pg_temp.reg('parametro_global_baja', '{"definitiva": true}'),
          'parametro_global_baja|-|' || (select id from fila) || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', 50, 'valor_nuevo', null,
                                'rol', session_user::text, 'definitiva', true)::text,
          'un DELETE queda como baja definitiva');

-- El alta de una fila nueva.
insert into public.parametro_global (id, clave, valor) values (pg_temp.u('d1'), 'dias_antiguedad_precios', 12);
select is(pg_temp.reg('parametro_global_alta', '{"valor_nuevo": 12}'),
          'parametro_global_alta|-|' || pg_temp.u('d1') || '|'
          || jsonb_build_object('clave', 'dias_antiguedad_precios', 'valor_anterior', null, 'valor_nuevo', 12,
                                'rol', session_user::text)::text,
          'el alta: la fila nueva, sin valor anterior');
select is(pg_temp.n(), 9::bigint, 'nueve registros hasta acá (4 cambios, baja, cambio, alta, baja, alta)');

-- El alta rechazada (otra clave) no deja registro.
select is(pg_temp.codigo_de($$ insert into public.parametro_global (clave, valor) values ('otra_cosa', 5) $$),
          '23514', 'una clave desconocida la rechaza el CHECK');
select is(pg_temp.n(), 9::bigint, 'y no deja registro');

-- TRUNCATE: sin fila que nombrar, pero con cuántas había.
select pg_temp.actuar_como_service_role();
truncate public.parametro_global;
select pg_temp.actuar_como_servidor();
select is(pg_temp.reg('parametro_global_vaciado', '{}'),
          'parametro_global_vaciado|-|-|' || jsonb_build_object('filas', 1, 'rol', 'service_role')::text,
          'el TRUNCATE queda con las filas que había y el rol');
select is((select tabla from auditoria.audit_log where event_type = 'parametro_global_vaciado'), 'parametro_global',
          'y nombra la tabla');
select is((select fila_id from auditoria.audit_log where event_type = 'parametro_global_vaciado'), null::uuid,
          'sin fila');

-- ===============================================================================
-- 5. Una sola transacción, y audit_log sigue cerrada
-- ===============================================================================
-- Si el cambio se deshace, su registro se deshace con él.
insert into public.parametro_global (id, clave, valor) values (pg_temp.u('d2'), 'dias_antiguedad_precios', 15);
savepoint antes;
update public.parametro_global set valor = 60 where id = pg_temp.u('d2');
select is(pg_temp.n('parametro_global_cambio'), 6::bigint, 'dentro del savepoint el cambio ya tiene su registro');
rollback to savepoint antes;
select is((select valor from public.parametro_global where id = pg_temp.u('d2')), 15, 'se deshace el cambio...');
select is(pg_temp.n('parametro_global_cambio'), 5::bigint, '...y se deshace su registro: o los dos o ninguno');

-- Los registros no se editan ni se borran (0073), ni siquiera los de este evento.
select is(pg_temp.codigo_de($$ delete from auditoria.audit_log where event_type like 'parametro_global%' $$), 'AU001',
          'los registros de parametro_global no se pueden borrar');
select is(pg_temp.codigo_de($$ update auditoria.audit_log set metadata = '{}'::jsonb where event_type like 'parametro_global%' $$),
          'AU001', 'ni editar');

-- Y un cliente sigue sin ver la auditoría.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.codigo_de($$ select count(*) from auditoria.audit_log $$), '42501', 'el ADMIN con su JWT no lee audit_log');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
