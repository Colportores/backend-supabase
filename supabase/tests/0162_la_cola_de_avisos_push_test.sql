-- pgTAP · migraciones 0162 y 0163 (backend-supabase#237, HU-NOT-003, ADR-014): la cola de avisos push.
--   1. La forma: schema push cerrado, tabla push.evento sin acceso para los clientes, las dos RPC solo para
--      service_role, las tareas de pg_cron.
--   2. Pedido autorizado: un aviso a la colportora a los 15 s; el «Deshacer» lo descarta y volver a
--      autorizar lo reabre; sin cambio de estado no hay aviso; solo ids en el payload.
--   3. Ticket validado / rechazado.
--   4. Asignación a campaña: solo el paso de PENDIENTE_ASIGNACION a ACTIVA; con zona si ya la tiene.
--   5. push_tomar_pendientes: reserva, descarta con su motivo (sin token, cuenta no activa, ya no aplica,
--      vencido) y no se pisa con un segundo despertar.
--   6. push_resultado: enviado, reintento con espera creciente hasta agotarse, token inválido (borra el token
--      solo si sigue siendo el mismo), descartar, y lo que ya no está pendiente no se toca.
--   7. Cuota pendiente (3 días vencida) y agenda de mañana.
--   8. El despertar de la Edge Function y la purga.
-- Va en una transacción.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000162' || p)::uuid;
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- El mediodía de Montevideo, hoy + n días.
create or replace function pg_temp.dia(p_n integer) returns timestamptz language sql as $$
  select ((public.hoy_montevideo() + p_n)::timestamp + interval '12 hours') at time zone 'America/Montevideo';
$$;
-- Los avisos de un usuario de cierto tipo (como postgres).
create or replace function pg_temp.avisos(p_usuario text, p_tipo text) returns integer language sql as $$
  select count(*)::int from push.evento where usuario_id = pg_temp.u(p_usuario) and tipo = p_tipo;
$$;
create or replace function pg_temp.aviso(p_usuario text, p_tipo text) returns push.evento language sql as $$
  select e from push.evento e where e.usuario_id = pg_temp.u(p_usuario) and e.tipo = p_tipo
   order by e.creado_en desc, e.id desc limit 1;
$$;
-- Deja listos para salir todos los avisos pendientes de un usuario (la demora de 15 s ya pasó).
create or replace function pg_temp.listos(p_usuario text) returns void language sql as $$
  update push.evento set enviar_desde = now() - interval '1 second'
   where usuario_id = pg_temp.u(p_usuario) and estado = 'PENDIENTE';
$$;
create or replace function pg_temp.estado_de(p_id uuid) returns text language sql as $$
  select estado || coalesce('/' || motivo_descarte, '') from push.evento where id = p_id;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: a1 Ana (con token), a2 Beto, a3 Carla (sin token), b1 suspendida (con token), c1 coordinadora.
-- Campañas: e1 en curso, e2 por empezar (sin pisar a e1), e3 ya terminada. Zona f1 de e1. Pedidos 11, 12, 13.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'push162-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a3','b1','c1']) s;
update public.usuario set fcm_token = 'token-a1' where id = pg_temp.u('a1');
update public.usuario set fcm_token = 'token-a2' where id = pg_temp.u('a2');
update public.usuario set fcm_token = 'token-b1', suspendido_en = now() where id = pg_temp.u('b1');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais push', 'ZP');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad push', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'En curso push',  'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30),
  (pg_temp.u('e2'), 'Por empezar push', 'VERANO', public.hoy_montevideo() + 40, public.hoy_montevideo() + 80),
  (pg_temp.u('e3'), 'Terminada push', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
values (pg_temp.u('f1'), 'Zona push', pg_temp.u('f2'), 'RADIAL', -34.9, -56.16, 300);

-- Hasta acá no hubo ninguna inscripción: ningún aviso de asignación.
select is((select count(*)::int from push.evento), 0, 'sin hechos todavía, la cola está vacía');

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_schema('push', 'existe el schema push');
select ok(not has_schema_privilege('anon', 'push', 'usage') and not has_schema_privilege('authenticated', 'push', 'usage'),
          'el schema push está cerrado a los clientes');
select ok(not has_table_privilege('anon', 'push.evento', 'select')
          and not has_table_privilege('authenticated', 'push.evento', 'select')
          and not has_table_privilege('authenticated', 'push.evento', 'insert')
          and not has_table_privilege('authenticated', 'push.evento', 'update')
          and not has_table_privilege('authenticated', 'push.evento', 'delete'),
          'push.evento no la toca ningún cliente');
select ok((select relrowsecurity from pg_class where oid = 'push.evento'::regclass),
          'push.evento tiene RLS activa (sin políticas)');
select ok(has_function_privilege('service_role', 'public.push_tomar_pendientes(integer)', 'execute')
          and has_function_privilege('service_role', 'public.push_resultado(uuid, text, text, text)', 'execute'),
          'service_role ejecuta las dos RPC');
select ok(not has_function_privilege('authenticated', 'public.push_tomar_pendientes(integer)', 'execute')
          and not has_function_privilege('anon', 'public.push_tomar_pendientes(integer)', 'execute')
          and not has_function_privilege('authenticated', 'public.push_resultado(uuid, text, text, text)', 'execute')
          and not has_function_privilege('anon', 'public.push_resultado(uuid, text, text, text)', 'execute'),
          'ni anon ni authenticated ejecutan las RPC de la cola');
select ok(not has_function_privilege('service_role', 'push.encolar(uuid, text, uuid, text, interval, interval)', 'execute')
          and not has_function_privilege('authenticated', 'push.encolar(uuid, text, uuid, text, interval, interval)', 'execute'),
          'nadie desde afuera anota un aviso a mano');
select is((select count(*)::int from cron.job
            where jobname in ('push-despertar', 'push-cuotas-pendientes', 'push-agenda-manana', 'push-purgar')), 4,
          'las cuatro tareas de pg_cron están agendadas');
select is((select schedule from cron.job where jobname = 'push-despertar'), '* * * * *', 'el despertar corre cada minuto');
select is((select schedule from cron.job where jobname = 'push-cuotas-pendientes'), '0 12 * * *',
          'las cuotas se miran a las 09:00 de Montevideo');
select is((select schedule from cron.job where jobname = 'push-agenda-manana'), '0 23 * * *',
          'la agenda de mañana se avisa a las 20:00 de Montevideo');
select throws_ok($$insert into push.evento (usuario_id, tipo, clave) values (null, 'agenda_manana', 'x')$$, '23502',
                 null, 'un aviso sin destinataria no entra');
select throws_ok(format($$insert into push.evento (usuario_id, tipo, clave) values (%L, 'agenda_manana', 'k1'), (%L, 'agenda_manana', 'k1')$$,
                        pg_temp.u('a1'), pg_temp.u('a2')), '23505', null, 'la clave es única: el mismo hecho no anota dos avisos');
select throws_ok(format($$insert into push.evento (usuario_id, tipo, clave) values (%L, 'tipo_raro', 'k2')$$, pg_temp.u('a1')),
                 '23514', null, 'solo hay seis tipos de aviso');
select throws_ok(format($$insert into push.evento (usuario_id, tipo, clave, entidad_id) values (%L, 'agenda_manana', 'k3', %L)$$,
                        pg_temp.u('a1'), pg_temp.u('a2')), '23514', null, 'la agenda de mañana no lleva id de entidad');
select throws_ok(format($$insert into push.evento (usuario_id, tipo, clave) values (%L, 'pedido_autorizado', 'k4')$$, pg_temp.u('a1')),
                 '23514', null, 'y los demás tipos sí lo llevan');
select throws_ok(format($$insert into push.evento (usuario_id, tipo, clave, ultimo_error) values (%L, 'agenda_manana', 'k5', 'un texto libre con datos')$$,
                        pg_temp.u('a1')), '23514', null, 'el último error es un código corto, nunca texto libre');

-- ---------------------------------------------------------------------------
-- 2. Pedido autorizado
-- ---------------------------------------------------------------------------
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido) values
  (pg_temp.u('11'), pg_temp.u('a1'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', now()),
  (pg_temp.u('12'), pg_temp.u('a1'), 'BORRADOR', 0, 'COORDINADOR', now());
select is(pg_temp.avisos('a1', 'pedido_autorizado'), 0, 'un pedido que se pide no avisa nada');

update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = pg_temp.u('11');
select is(pg_temp.avisos('a1', 'pedido_autorizado'), 1, 'autorizar el pedido anota un aviso para la colportora');
select is((pg_temp.aviso('a1', 'pedido_autorizado')).entidad_id, pg_temp.u('11'), 'el aviso lleva el pedido');
select is((pg_temp.aviso('a1', 'pedido_autorizado')).enviar_desde, now() + interval '15 seconds',
          'y sale a los 15 segundos: el «Deshacer» de la bandeja dura 8');
select is((pg_temp.aviso('a1', 'pedido_autorizado')).vence_en, now() + interval '15 seconds' + interval '1 day',
          'vale un día desde que puede salir');
select is((select count(*)::int from public.push_tomar_pendientes(50)), 0, 'antes de los 15 segundos no sale');

-- Otro UPDATE de estado al mismo valor no es un paso nuevo.
update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = pg_temp.u('11');
select is(pg_temp.avisos('a1', 'pedido_autorizado'), 1, 'autorizar lo ya autorizado no duplica el aviso');

-- El coordinador se arrepiente dentro del «Deshacer»: el aviso que no salió se descarta al tomarlo.
update public.pedido_casa_editora set estado = 'PENDIENTE_AUTORIZACION' where id = pg_temp.u('11');
select pg_temp.listos('a1');
select is((select count(*)::int from public.push_tomar_pendientes(50)), 0, 'deshecho, no sale');
select is(pg_temp.estado_de((pg_temp.aviso('a1', 'pedido_autorizado')).id), 'DESCARTADO/YA_NO_APLICA',
          'queda descartado: ya no es verdad');

-- Y si lo vuelve a autorizar, el aviso se reabre (sigue siendo uno solo).
update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = pg_temp.u('11');
select is(pg_temp.avisos('a1', 'pedido_autorizado'), 1, 'volver a autorizar no suma un segundo aviso…');
select is(pg_temp.estado_de((pg_temp.aviso('a1', 'pedido_autorizado')).id), 'PENDIENTE', '…reabre el que estaba descartado');
select is((pg_temp.aviso('a1', 'pedido_autorizado')).intentos, 0, 'sin intentos gastados');

-- Un pedido que nace autorizado también avisa.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido)
values (pg_temp.u('13'), pg_temp.u('a2'), 'AUTORIZADO', 0, 'COORDINADOR', now());
select is(pg_temp.avisos('a2', 'pedido_autorizado'), 1, 'un pedido que nace AUTORIZADO avisa a su colportora');

-- Un pedido que sigue su camino después de autorizado no vuelve a avisar.
update public.pedido_casa_editora set estado = 'DESPACHADO' where id = pg_temp.u('13');
select is(pg_temp.avisos('a2', 'pedido_autorizado'), 1, 'despacharlo no avisa de nuevo');

-- El payload: solo type, event_id y pedido_id, todo texto.
select pg_temp.listos('a1');
create temp table tomados_a1 as select * from public.push_tomar_pendientes(50);
select is((select count(*)::int from tomados_a1), 1, 'pasados los 15 segundos, sale');
select is((select token from tomados_a1), 'token-a1', 'con el token de la colportora');
select is((select intento from tomados_a1), 1, 'es el primer intento');
select is((select datos from tomados_a1),
          jsonb_build_object('type', 'pedido_autorizado', 'event_id', (pg_temp.aviso('a1', 'pedido_autorizado')).id::text,
                             'pedido_id', pg_temp.u('11')::text),
          'el payload lleva el tipo, el event_id y el pedido, y nada más');
select ok((select bool_and(jsonb_typeof(v) = 'string') from tomados_a1, jsonb_each(datos) x(k, v)),
          'todos los valores son texto (FCM manda data como texto)');

-- ---------------------------------------------------------------------------
-- 3. Ticket validado y rechazado
-- ---------------------------------------------------------------------------
insert into public.ticket (id, usuario_id, tipo, estado) values
  (pg_temp.u('31'), pg_temp.u('a1'), 'OTRO', 'PENDIENTE'),
  (pg_temp.u('32'), pg_temp.u('a1'), 'OTRO', 'PENDIENTE'),
  (pg_temp.u('33'), pg_temp.u('a2'), 'OTRO', 'PENDIENTE');
select is((select count(*)::int from push.evento where tipo in ('ticket_validado', 'ticket_rechazado')), 0,
          'subir un ticket no avisa nada');
update public.ticket set monto = 5000 where id = pg_temp.u('31');
select is((select count(*)::int from push.evento where tipo in ('ticket_validado', 'ticket_rechazado')), 0,
          'completar un ticket pendiente tampoco');

update public.ticket set estado = 'VALIDADO', revisado_por = pg_temp.u('c1'), revisado_en = now() where id = pg_temp.u('31');
select is(pg_temp.avisos('a1', 'ticket_validado'), 1, 'validar el ticket avisa a su dueña');
select is((pg_temp.aviso('a1', 'ticket_validado')).entidad_id, pg_temp.u('31'), 'con el ticket');
select ok((pg_temp.aviso('a1', 'ticket_validado')).enviar_desde <= now(), 'y sale enseguida: una validación no se deshace');

update public.ticket set estado = 'RECHAZADO', revisado_por = pg_temp.u('c1'), revisado_en = now(),
       motivo_rechazo = 'El monto no coincide' where id = pg_temp.u('32');
select is(pg_temp.avisos('a1', 'ticket_rechazado'), 1, 'rechazar el ticket avisa a su dueña');
select is((select datos from public.push_tomar_pendientes(50) where datos ->> 'type' = 'ticket_rechazado'),
          jsonb_build_object('type', 'ticket_rechazado',
                             'event_id', (pg_temp.aviso('a1', 'ticket_rechazado')).id::text,
                             'ticket_id', pg_temp.u('32')::text),
          'el payload lleva el ticket y no el motivo del rechazo');
select is((select count(*)::int from push.evento e where push.datos_del_aviso(e)::text like '%coincide%'), 0,
          'el motivo escrito del rechazo nunca viaja');
select is(pg_temp.avisos('a2', 'ticket_validado') + pg_temp.avisos('a2', 'ticket_rechazado'), 0,
          'el ticket de Beto, todavía pendiente, no avisa');

-- ---------------------------------------------------------------------------
-- 4. Asignación a campaña (PENDIENTE_ASIGNACION → ACTIVA)
-- ---------------------------------------------------------------------------
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id)
values (pg_temp.u('41'), pg_temp.u('e1'), pg_temp.u('a1'), null);
select is(pg_temp.avisos('a1', 'asignacion_campania'), 1, 'sumar a Ana a una campaña en curso avisa: la cuenta pasa a ACTIVA');
select is((pg_temp.aviso('a1', 'asignacion_campania')).entidad_id, pg_temp.u('e1'), 'con la campaña');

-- La coordinadora le asigna la zona antes de que salga: el payload la lleva (se lee al mandar).
update public.campania_colportor set zona_id = pg_temp.u('f1') where id = pg_temp.u('41');
select is((select datos from public.push_tomar_pendientes(50) where datos ->> 'type' = 'asignacion_campania'),
          jsonb_build_object('type', 'asignacion_campania',
                             'event_id', (pg_temp.aviso('a1', 'asignacion_campania')).id::text,
                             'campania_id', pg_temp.u('e1')::text, 'zona_id', pg_temp.u('f1')::text),
          'si la inscripción ya tiene zona, el payload lleva zona_id');

-- Ya ACTIVA: otra campaña (que no se pisa) no es el paso de PENDIENTE_ASIGNACION a ACTIVA.
insert into public.campania_colportor (id, campania_id, usuario_id) values (pg_temp.u('42'), pg_temp.u('e2'), pg_temp.u('a1'));
select is(pg_temp.avisos('a1', 'asignacion_campania'), 1, 'una cuenta que ya estaba ACTIVA no recibe aviso por sumarse a otra campaña');

-- Una campaña por empezar cuenta (desde la 0102 la cuenta es ACTIVA).
insert into public.campania_colportor (id, campania_id, usuario_id) values (pg_temp.u('43'), pg_temp.u('e2'), pg_temp.u('a3'));
select is(pg_temp.avisos('a3', 'asignacion_campania'), 1, 'sumar a Carla a una campaña por empezar también avisa');
select is(push.datos_del_aviso(pg_temp.aviso('a3', 'asignacion_campania')) ->> 'zona_id', null,
          'sin zona, el payload no lleva zona_id');

-- Una campaña terminada no activa la cuenta.
insert into public.campania_colportor (id, campania_id, usuario_id) values (pg_temp.u('44'), pg_temp.u('e3'), pg_temp.u('a2'));
select is(pg_temp.avisos('a2', 'asignacion_campania'), 0, 'una campaña ya terminada no activa la cuenta: no avisa');

-- Una cuenta suspendida es SUSPENDIDA, no ACTIVA.
insert into public.campania_colportor (id, campania_id, usuario_id) values (pg_temp.u('45'), pg_temp.u('e1'), pg_temp.u('b1'));
select is(pg_temp.avisos('b1', 'asignacion_campania'), 0, 'una cuenta suspendida no recibe aviso de asignación');

-- Baja de la inscripción y reactivación: la cuenta vuelve a PENDIENTE_ASIGNACION y a ACTIVA, otro aviso.
update public.campania_colportor set deleted_at = now() where id = pg_temp.u('43');
select is(pg_temp.avisos('a3', 'asignacion_campania'), 1, 'dar de baja la inscripción no avisa');
-- (reactivar en la misma transacción: la clave lleva la hora de la transacción, así que hay que
--  mover la clave del aviso anterior para que sean dos hechos distintos, como lo son en la vida real)
update push.evento set clave = clave || ':anterior' where usuario_id = pg_temp.u('a3') and tipo = 'asignacion_campania';
update public.campania_colportor set deleted_at = null where id = pg_temp.u('43');
select is(pg_temp.avisos('a3', 'asignacion_campania'), 2, 'reactivar la inscripción de una cuenta sin otra vuelve a avisar');

-- Inscribir sin cambiar nada (UPDATE de otra columna) no avisa.
update public.campania_colportor set meta_libros = 10 where id = pg_temp.u('43');
select is(pg_temp.avisos('a3', 'asignacion_campania'), 2, 'cambiar la meta no avisa');

-- ---------------------------------------------------------------------------
-- 5. push_tomar_pendientes
-- ---------------------------------------------------------------------------
-- Estado limpio para esta parte: un aviso de cada situación.
delete from push.evento;
select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'tp:con-token');
select push.encolar(pg_temp.u('a3'), 'agenda_manana', null, 'tp:sin-token');
select push.encolar(pg_temp.u('b1'), 'agenda_manana', null, 'tp:suspendida');
select push.encolar(pg_temp.u('a2'), 'agenda_manana', null, 'tp:vencido', interval '0 seconds', interval '1 second');
select push.encolar(pg_temp.u('a2'), 'ticket_validado', pg_temp.u('33'), 'tp:futuro', interval '5 minutes');
update push.evento set vence_en = now() - interval '1 second' where clave = 'tp:vencido';

create temp table tomados as select * from public.push_tomar_pendientes(50);
select is((select count(*)::int from tomados), 1, 'de los cinco avisos solo uno se manda');
select is((select token from tomados), 'token-a1', 'el de la colportora con token');
select is(pg_temp.estado_de((select id from push.evento where clave = 'tp:sin-token')), 'DESCARTADO/SIN_TOKEN',
          'sin token: descartado, no queda esperando');
select is(pg_temp.estado_de((select id from push.evento where clave = 'tp:suspendida')), 'DESCARTADO/CUENTA_NO_ACTIVA',
          'cuenta suspendida: descartado');
select is(pg_temp.estado_de((select id from push.evento where clave = 'tp:vencido')), 'DESCARTADO/VENCIDO',
          'vencido: descartado (un «mañana» viejo miente)');
select is(pg_temp.estado_de((select id from push.evento where clave = 'tp:futuro')), 'PENDIENTE',
          'el que todavía no puede salir espera');
select is((select intentos from push.evento where clave = 'tp:con-token'), 1, 'el que salió gastó un intento');
select ok((select reservado_hasta from push.evento where clave = 'tp:con-token') = now() + interval '2 minutes',
          'y quedó reservado 2 minutos');
select is((select count(*)::int from public.push_tomar_pendientes(50)), 0, 'un segundo despertar no lo vuelve a tomar mientras está reservado');
update push.evento set reservado_hasta = now() - interval '1 second' where clave = 'tp:con-token';
select is((select intento from public.push_tomar_pendientes(50)), 2,
          'si la función se cayó sin contar el resultado, a los 2 minutos vuelve a la cola (intento 2)');

-- El límite y el orden.
delete from push.evento;
insert into push.evento (usuario_id, tipo, clave, enviar_desde)
select pg_temp.u('a1'), 'agenda_manana', 'lim:' || i, now() - make_interval(secs => 100 - i) from generate_series(1, 5) i;
select is((select array_agg(e.clave order by e.enviar_desde) from push.evento e
            where e.id in (select evento_id from public.push_tomar_pendientes(2))),
          array['lim:1', 'lim:2'], 'p_max limita y salen primero los más viejos');
select is((select count(*)::int from public.push_tomar_pendientes(0)), 1, 'p_max 0 se toma como 1');
select is((select count(*)::int from public.push_tomar_pendientes(null)), 2, 'p_max null toma hasta 50 (los 2 que quedan)');

-- ---------------------------------------------------------------------------
-- 6. push_resultado
-- ---------------------------------------------------------------------------
delete from push.evento;
select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'rs:1');
select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'rs:2');
select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'rs:3');
select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'rs:4');
create or replace function pg_temp.ev(p_clave text) returns uuid language sql as $$
  select id from push.evento where clave = p_clave;
$$;
select is((select count(*)::int from public.push_tomar_pendientes(50)), 4, 'los cuatro salen');

select is(public.push_resultado(pg_temp.ev('rs:1'), 'ENVIADO'), true, 'ENVIADO responde que lo anotó');
select is(pg_temp.estado_de(pg_temp.ev('rs:1')), 'ENVIADO', 'el aviso queda enviado');
select ok((select enviado_en = now() and reservado_hasta is null from push.evento where clave = 'rs:1'),
          'con la hora y sin reserva');
select is(public.push_resultado(pg_temp.ev('rs:1'), 'ENVIADO'), false, 'un aviso que ya no está pendiente no se toca');
select is(public.push_resultado(pg_temp.ev('rs:1'), 'REINTENTAR'), false, 'ni se reabre');
select is(pg_temp.estado_de(pg_temp.ev('rs:1')), 'ENVIADO', 'sigue enviado');
select is(public.push_resultado('00000000-0000-0000-0000-000000000000', 'ENVIADO'), false, 'un id que no existe tampoco');

-- REINTENTAR: espera creciente.
select is(public.push_resultado(pg_temp.ev('rs:2'), 'REINTENTAR', null, 'UNAVAILABLE'), true, 'REINTENTAR responde que lo anotó');
select is((select enviar_desde from push.evento where clave = 'rs:2'), now() + interval '1 minute',
          'tras el primer intento espera 1 minuto');
select is((select ultimo_error from push.evento where clave = 'rs:2'), 'UNAVAILABLE', 'y guarda el código de FCM');
select ok((select reservado_hasta is null from push.evento where clave = 'rs:2'), 'sin reserva: sale cuando le toque');
select is((select count(*)::int from public.push_tomar_pendientes(50) where evento_id = pg_temp.ev('rs:2')), 0,
          'hasta entonces no se toma');
update push.evento set intentos = 3 where clave = 'rs:2';
select public.push_resultado(pg_temp.ev('rs:2'), 'REINTENTAR', null, 'unavailable en minúscula');
select is((select enviar_desde from push.evento where clave = 'rs:2'), now() + interval '4 minutes', 'tras el tercero espera 4');
select is((select ultimo_error from push.evento where clave = 'rs:2'), null, 'un código con otra forma se guarda como null');
update push.evento set intentos = 5 where clave = 'rs:2';
select public.push_resultado(pg_temp.ev('rs:2'), 'REINTENTAR', null, 'INTERNAL');
select is((select enviar_desde from push.evento where clave = 'rs:2'), now() + interval '16 minutes', 'tras el quinto espera 16');
update push.evento set intentos = 6 where clave = 'rs:2';
select public.push_resultado(pg_temp.ev('rs:2'), 'REINTENTAR', null, 'INTERNAL');
select is(pg_temp.estado_de(pg_temp.ev('rs:2')), 'DESCARTADO/AGOTADO', 'al sexto intento sin respuesta se da por agotado');

-- TOKEN_INVALIDO: el aviso se descarta y el token se borra solo si sigue siendo el mismo.
select is(public.push_resultado(pg_temp.ev('rs:3'), 'TOKEN_INVALIDO', 'token-a1', 'UNREGISTERED'), true, 'TOKEN_INVALIDO responde que lo anotó');
select is(pg_temp.estado_de(pg_temp.ev('rs:3')), 'DESCARTADO/TOKEN_INVALIDO', 'el aviso se descarta, no se reintenta');
select is((select fcm_token from public.usuario where id = pg_temp.u('a1')), null, 'y el token se borra de usuario.fcm_token');
select is((select ultimo_error from push.evento where clave = 'rs:3'), 'UNREGISTERED', 'con el código de FCM');

update public.usuario set fcm_token = 'token-nuevo-a1' where id = pg_temp.u('a1');
select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'rs:5');
create temp table tomado5 as select * from public.push_tomar_pendientes(50);
-- Mientras FCM rechazaba el token viejo, Ana ya guardó uno nuevo: ese no se borra.
select public.push_resultado(pg_temp.ev('rs:5'), 'TOKEN_INVALIDO', 'token-viejo-a1', 'UNREGISTERED');
select is((select fcm_token from public.usuario where id = pg_temp.u('a1')), 'token-nuevo-a1',
          'si la app ya guardó un token nuevo, el rechazo del viejo no lo borra');

-- DESCARTAR.
select is(public.push_resultado(pg_temp.ev('rs:4'), 'DESCARTAR', null, 'INVALID_ARGUMENT'), true, 'DESCARTAR responde que lo anotó');
select is(pg_temp.estado_de(pg_temp.ev('rs:4')), 'DESCARTADO/RECHAZADO_POR_FCM', 'FCM rechazó el mensaje: no tiene sentido reintentar');

-- Un resultado que no existe.
select throws_ok(format($$select public.push_resultado(%L, 'QUIZAS')$$, pg_temp.ev('rs:5')), '22023', null,
                 'un resultado desconocido es un error, no se ignora');
select throws_ok(format($$select public.push_resultado(%L, null)$$, pg_temp.ev('rs:5')), '22023', null,
                 'ni uno nulo');

-- ---------------------------------------------------------------------------
-- 7. Cuota pendiente y agenda de mañana
-- ---------------------------------------------------------------------------
delete from push.evento;
update public.usuario set fcm_token = 'token-a1' where id = pg_temp.u('a1');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('01'), 'CASA', 'Push 01', '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('a1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('a1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('d1'), pg_temp.u('a1'));
-- Ventas de Ana: 51 con saldo (1000,00 y un cobro de 100,00), 52 saldada, 53 con el cobro dado de baja.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u('21'), 'P-' || x.v, x.monto, now(), pg_temp.u('a1'), pg_temp.u('a1')
  from (values ('51', 100000), ('52', 20000), ('53', 30000)) x(v, monto);
insert into public.cobranza (id, venta_id, monto, medio, fecha, deleted_at, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 10000, 'EFECTIVO', now(), null, pg_temp.u('a1')),
  (pg_temp.u('72'), pg_temp.u('52'), 20000, 'EFECTIVO', now(), null, pg_temp.u('a1')),
  (pg_temp.u('73'), pg_temp.u('53'), 30000, 'EFECTIVO', now(), now(), pg_temp.u('a1'));

-- Citas (todas de Ana, en el espacio 11). Columnas: id, tipo, día, estado, venta, baja.
create or replace function pg_temp.cita(p_id text, p_tipo text, p_dia integer, p_estado text, p_venta text default null,
                                        p_baja boolean default false)
returns void language sql as $$
  insert into public.agenda (id, espacio_id, tipo, fecha_programada, estado, colportor_id, venta_id, deleted_at,
                             created_at)
  values (pg_temp.u(p_id), pg_temp.u('11'), p_tipo, pg_temp.dia(p_dia), p_estado, pg_temp.u('a1'),
          pg_temp.u(p_venta), case when p_baja then now() end, now() - interval '30 days');
$$;
select pg_temp.cita('81', 'COBRANZA', -3, 'PROGRAMADA', '51');            -- sí: hace 3 días, con saldo
select pg_temp.cita('82', 'COBRANZA', -2, 'PROGRAMADA', '51');            -- no: hace 2 días
select pg_temp.cita('83', 'COBRANZA', -4, 'PROGRAMADA', '51');            -- no: hace 4 días (ya pasó el día)
select pg_temp.cita('84', 'COBRANZA', -3, 'CUMPLIDA',   '51');            -- no: ya se cumplió
select pg_temp.cita('85', 'COBRANZA', -3, 'PROGRAMADA', '52');            -- no: la venta está saldada
select pg_temp.cita('86', 'COBRANZA', -3, 'PROGRAMADA', '53');            -- sí: el único cobro está dado de baja
select pg_temp.cita('87', 'COBRANZA', -3, 'PROGRAMADA', null);            -- sí: sin venta, la cita sola
select pg_temp.cita('88', 'COBRANZA', -3, 'PROGRAMADA', '51', true);      -- no: la cita está dada de baja
select pg_temp.cita('89', 'ENTREVISTA', -3, 'PROGRAMADA');                -- no: no es una cobranza
select pg_temp.cita('8a', 'COBRANZA', -3, 'CANCELADA', '51');             -- no: cancelada
-- Mañana: 91 programada (entrevista), 92 programada (cobranza), 93 cancelada.
select pg_temp.cita('91', 'ENTREVISTA', 1, 'PROGRAMADA');
select pg_temp.cita('92', 'COBRANZA', 1, 'PROGRAMADA', '51');
select pg_temp.cita('93', 'ENTREVISTA', 1, 'CANCELADA');

select is(push.encolar_cuotas_pendientes(), 3, 'la tarea anota las 3 citas de cobranza que cumplen 3 días sin cobro');
select is((select array_agg(entidad_id order by entidad_id) from push.evento where tipo = 'cuota_pendiente'),
          array[pg_temp.u('81'), pg_temp.u('86'), pg_temp.u('87')], 'son la 81, la 86 y la 87');
select ok((select bool_and(usuario_id = pg_temp.u('a1')) from push.evento where tipo = 'cuota_pendiente'), 'todas para su colportora');
select is(push.encolar_cuotas_pendientes(), 0, 'correr la tarea otra vez no duplica nada: una vez por cita');
select is(push.encolar_cuotas_pendientes(public.hoy_montevideo() + 1), 1,
          'el día se recibe por argumento: con p_hoy = mañana cumple 3 días la cita 82');
delete from push.evento where entidad_id = pg_temp.u('82');
select is((select push.datos_del_aviso(e) from push.evento e where e.entidad_id = pg_temp.u('81')),
          jsonb_build_object('type', 'cuota_pendiente', 'event_id', (select id::text from push.evento where entidad_id = pg_temp.u('81')),
                             'agenda_id', pg_temp.u('81')::text),
          'el payload lleva agenda_id, no la cuota ni el monto');

-- La cita que se resolvió antes de que salga el aviso no molesta.
update public.agenda set estado = 'CUMPLIDA' where id = pg_temp.u('81');
select is((select count(*)::int from public.push_tomar_pendientes(50) where datos ->> 'agenda_id' = pg_temp.u('81')::text), 0,
          'si la cita ya se cumplió cuando le toca salir, no sale');
select is(pg_temp.estado_de((select id from push.evento where entidad_id = pg_temp.u('81'))), 'DESCARTADO/YA_NO_APLICA', 'queda descartada por ya no aplicar');

-- Agenda de mañana.
select is(push.encolar_agenda_manana(), 1, 'la agenda de mañana anota un aviso por colportora, no uno por cita');
select is(pg_temp.avisos('a1', 'agenda_manana'), 1, 'es el de Ana (tiene 2 citas programadas mañana)');
select is((select entidad_id from push.evento where tipo = 'agenda_manana'), null, 'sin id de entidad');
select is((select push.datos_del_aviso(e) from push.evento e where e.tipo = 'agenda_manana'),
          jsonb_build_object('type', 'agenda_manana', 'event_id', (select id::text from push.evento where tipo = 'agenda_manana')),
          'el payload es solo type y event_id: la app cuenta las citas en su base');
select is((select vence_en from push.evento where tipo = 'agenda_manana'), now() + interval '4 hours',
          'vale 4 horas: pasada la noche el «mañana» ya es hoy');
select is(push.encolar_agenda_manana(), 0, 'correrla otra vez el mismo día no repite el aviso');
select is(push.encolar_agenda_manana(public.hoy_montevideo() + 1), 0, 'pasado mañana no hay citas programadas');
update public.agenda set estado = 'CANCELADA' where id in (pg_temp.u('91'), pg_temp.u('92'));
delete from push.evento where tipo = 'agenda_manana';
select is(push.encolar_agenda_manana(), 0, 'si todas las citas de mañana se cancelaron, no hay aviso');

-- ---------------------------------------------------------------------------
-- 8. El despertar de la Edge Function y la purga
-- ---------------------------------------------------------------------------
delete from push.evento;
select is(push.despertar(), false, 'sin avisos listos no despierta a nadie (no gasta invocaciones)');

select push.encolar(pg_temp.u('a1'), 'agenda_manana', null, 'dp:1');
select is(push.despertar(), false, 'con avisos listos pero sin los secretos de Vault, avisa con un WARNING y no hace nada');

select vault.create_secret('https://proyecto.supabase.test/functions/v1/push-fcm', 'push_fcm_url');
select is(push.despertar(), false, 'con la URL pero sin la clave, tampoco');
select vault.create_secret('clave-compartida-de-prueba', 'push_fcm_clave');

delete from net.http_request_queue;
select is(push.despertar(), true, 'con avisos listos y los dos secretos, despierta a la función');
select is((select count(*)::int from net.http_request_queue where url = 'https://proyecto.supabase.test/functions/v1/push-fcm'), 1,
          'con un POST por pg_net a la URL de Vault');
select is((select headers ->> 'x-push-clave' from net.http_request_queue limit 1), 'clave-compartida-de-prueba',
          'que lleva la clave compartida en la cabecera x-push-clave');
select is((select method::text from net.http_request_queue limit 1), 'POST', 'por POST');

-- Un aviso reservado (en manos de la función) o que espera su hora no la despierta.
update push.evento set reservado_hasta = now() + interval '2 minutes';
select is(push.despertar(), false, 'si todo está reservado, no la despierta de nuevo');
update push.evento set reservado_hasta = null, enviar_desde = now() + interval '1 minute';
select is(push.despertar(), false, 'ni si todo espera su hora');

-- La purga.
delete from push.evento;
insert into push.evento (usuario_id, tipo, clave, creado_en)
values (pg_temp.u('a1'), 'agenda_manana', 'pg:viejo', now() - interval '15 days'),
       (pg_temp.u('a1'), 'agenda_manana', 'pg:reciente', now() - interval '13 days');
select is(push.purgar(), 1, 'la purga borra el aviso de más de 14 días');
select is((select array_agg(clave) from push.evento), array['pg:reciente'], 'y deja el reciente');

select * from finish();
rollback;
