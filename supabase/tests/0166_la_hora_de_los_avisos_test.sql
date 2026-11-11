-- pgTAP · migraciones 0165 y 0166 (backend-supabase#242, decisiones de Cristian del 04/11): la hora de los avisos.
--   1. usuario.notif_preferences: la forma (objeto, hora_cuota y hora_agenda "HH:MM"), vacía en todas las filas.
--   2. Se guarda con guardar_mis_preferencias_de_avisos(): solo la fila propia, null vuelve a los valores por
--      defecto, el mismo valor no toca la fila, sin sesión falla; un PATCH a la fila no la cambia.
--   3. Cuotas pendientes a la hora de cada usuario (por defecto 09:00): dos usuarios con horas distintas, el
--      valor por defecto, quien cambia la hora antes y después de recibirlo, y la recuperación de 24 horas.
--   4. Agenda de mañana a la hora de cada usuario (por defecto 20:00): ventana de 4 horas sin pasar la
--      medianoche, la última pasada del día, quien cambia la hora después de recibirla.
-- El «ahora» de las dos tareas se pasa por argumento: no depende de la hora real en que corre el test.
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
  select ('01920000-0000-7000-8000-0000000166' || p)::uuid;
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Hoy (Montevideo) + n días, a cierta hora.
create or replace function pg_temp.a_las(p_hora text, p_dias integer default 0) returns timestamptz language sql as $$
  select ((public.hoy_montevideo() + p_dias)::timestamp + p_hora::time) at time zone 'America/Montevideo';
$$;
create or replace function pg_temp.prefs_de(p text) returns jsonb language sql as $$
  select notif_preferences from public.usuario where id = pg_temp.u(p);
$$;
-- Cuántos avisos de ese tipo tiene el usuario.
create or replace function pg_temp.avisos(p text, p_tipo text) returns integer language sql as $$
  select count(*)::int from push.evento where usuario_id = pg_temp.u(p) and tipo = p_tipo;
$$;
-- Una cita de cobranza programada a mediodía de hoy + p_dia (sin venta: cuenta igual).
create or replace function pg_temp.cita(p_id text, p_colportora text, p_tipo text, p_dia integer) returns void language sql as $$
  insert into public.agenda (id, espacio_id, tipo, fecha_programada, estado, colportor_id, created_at)
  values (pg_temp.u(p_id), pg_temp.u('11'), p_tipo, pg_temp.a_las('12:00', p_dia), 'PROGRAMADA', pg_temp.u(p_colportora),
          now() - interval '30 days');
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- e1 sin preferencias (09:00 / 20:00), e2 con 14:00 / 22:30, e3 con 00:00 / 08:00, e4 sin preferencias,
-- e5 con 18:00, e6 con 23:59 en la agenda, ad ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'hora166-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['e1','e2','e3','e4','e5','e6','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u('ad'), r.id from public.rol r where r.codigo = 'ADMIN';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais hora', 'ZH');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad hora', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('01'), 'CASA', 'Hora 01', '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('e1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('e1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'usuario', 'notif_preferences', 'jsonb', 'usuario.notif_preferences es jsonb');
select col_is_null('public', 'usuario', 'notif_preferences', 'y opcional');
select is((select count(*)::int from public.usuario where notif_preferences is not null), 0,
          'ninguna fila existente tiene preferencias: la columna solo suma y todo queda por defecto');
select ok(not exists (select 1 from sync.entidad where tabla = 'public.usuario'::regclass),
          'usuario no es entidad del motor de sync');

-- Lo que rechaza el servidor (como postgres: el CHECK vale para todos).
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '[]' where id = pg_temp.u('e1')$$), '23514',
          'una lista no es un objeto');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '"09:00"' where id = pg_temp.u('e1')$$), '23514',
          'ni un texto suelto');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_cuota": "9:00"}' where id = pg_temp.u('e1')$$), '23514',
          'la hora es HH:MM con dos dígitos: «9:00» no entra');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_cuota": "24:00"}' where id = pg_temp.u('e1')$$), '23514',
          'las 24:00 no existen');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_agenda": "20:60"}' where id = pg_temp.u('e1')$$), '23514',
          'ni los 60 minutos');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_cuota": 900}' where id = pg_temp.u('e1')$$), '23514',
          'la hora es un texto, no un número');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_agenda": null}' where id = pg_temp.u('e1')$$), '23514',
          'ni un null: para volver al valor por defecto se saca la clave');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_cuota": "09:00 "}' where id = pg_temp.u('e1')$$), '23514',
          'ni con un espacio al final');
select is(pg_temp.error_de(format($$update public.usuario set notif_preferences = %L where id = pg_temp.u('e1')$$,
                                  jsonb_build_object('relleno', repeat('a', 4100)))), '23514',
          'ni un objeto de más de 4096 caracteres');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"hora_cuota": "00:00", "hora_agenda": "23:59"}' where id = pg_temp.u('e1')$$), 'ok',
          'los extremos del día entran');
select is(pg_temp.error_de($$update public.usuario set notif_preferences = '{"cuotas": true, "tickets": false, "hora_cuota": "09:30"}' where id = pg_temp.u('e1')$$), 'ok',
          'y el objeto lleva además los interruptores de la app, que el servidor no mira');
update public.usuario set notif_preferences = null where id = pg_temp.u('e1');

-- ---------------------------------------------------------------------------
-- 2. Se guarda con la función
-- ---------------------------------------------------------------------------
select ok(has_function_privilege('authenticated', 'public.guardar_mis_preferencias_de_avisos(jsonb)', 'execute')
          and not has_function_privilege('anon', 'public.guardar_mis_preferencias_de_avisos(jsonb)', 'execute'),
          'la función la ejecuta una cuenta con sesión y no el anónimo');
select ok(not has_function_privilege('authenticated', 'public.tg_usuario_notif_preferences_servidor()', 'execute')
          and not has_function_privilege('authenticated', 'push.ultima_hora_de_aviso(timestamptz, time)', 'execute')
          and not has_function_privilege('authenticated', 'push.encolar_cuotas_pendientes(timestamptz)', 'execute')
          and not has_function_privilege('authenticated', 'push.encolar_agenda_manana(timestamptz)', 'execute'),
          'ni el trigger ni las funciones de las tareas las ejecuta nadie desde afuera');

select pg_temp.actuar_como(pg_temp.u('e2'));
select public.guardar_mis_preferencias_de_avisos('{"cuotas": true, "hora_cuota": "14:00", "hora_agenda": "22:30"}');
select pg_temp.actuar_como_servidor();
select is(pg_temp.prefs_de('e2'), '{"cuotas": true, "hora_cuota": "14:00", "hora_agenda": "22:30"}'::jsonb,
          'cada usuario guarda las suyas');
select is(pg_temp.prefs_de('e1'), null, 'y las de otro no se mueven');

-- Reemplaza el objeto entero.
select pg_temp.actuar_como(pg_temp.u('e2'));
select public.guardar_mis_preferencias_de_avisos('{"hora_cuota": "14:00", "hora_agenda": "22:30"}');
select pg_temp.actuar_como_servidor();
select is(pg_temp.prefs_de('e2'), '{"hora_cuota": "14:00", "hora_agenda": "22:30"}'::jsonb, 'la app manda el objeto entero y reemplaza al anterior');

-- Lo mismo otra vez no escribe nada.
create temp table antes_166 as select updated_at, sync_version from public.usuario where id = pg_temp.u('e2');
select pg_temp.actuar_como(pg_temp.u('e2'));
select public.guardar_mis_preferencias_de_avisos('{"hora_agenda": "22:30", "hora_cuota": "14:00"}');
select pg_temp.actuar_como_servidor();
select ok((select (u.updated_at, u.sync_version) = (a.updated_at, a.sync_version)
             from public.usuario u, antes_166 a where u.id = pg_temp.u('e2')),
          'guardar lo mismo no toca la fila');

-- Forma inválida: el error del servidor llega a la app.
select pg_temp.actuar_como(pg_temp.u('e2'));
select throws_ok($$select public.guardar_mis_preferencias_de_avisos('{"hora_cuota": "25:00"}')$$, '23514', null,
                 'una hora que no existe se rechaza con 23514');
select throws_ok($$select public.guardar_mis_preferencias_de_avisos('[1]')$$, '23514', null, 'y un valor que no es un objeto');
select pg_temp.actuar_como_servidor();
select is(pg_temp.prefs_de('e2'), '{"hora_cuota": "14:00", "hora_agenda": "22:30"}'::jsonb, 'sin tocar lo que ya había');

-- null vuelve a los valores por defecto.
select pg_temp.actuar_como(pg_temp.u('e2'));
select public.guardar_mis_preferencias_de_avisos(null);
select pg_temp.actuar_como_servidor();
select is(pg_temp.prefs_de('e2'), null, 'null vuelve a los valores por defecto');

-- Sin sesión.
select set_config('role', 'authenticated', true);
select throws_ok($$select public.guardar_mis_preferencias_de_avisos('{}')$$, '42501',
                 'Iniciá sesión para guardar tus preferencias de avisos.',
                 'con el rol de la app pero sin sesión, falla y dice qué hacer');
select pg_temp.actuar_como_servidor();

-- El PATCH a la fila no la cambia, ni el del ADMIN sobre la de otra.
select pg_temp.actuar_como(pg_temp.u('e1'));
update public.usuario set notif_preferences = '{"hora_cuota": "10:00"}' where id = pg_temp.u('e1');
select pg_temp.actuar_como(pg_temp.u('ad'));
update public.usuario set notif_preferences = '{"hora_cuota": "11:00"}' where id = pg_temp.u('e1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.prefs_de('e1'), null, 'un PATCH de la fila no cambia las preferencias, ni el del ADMIN');
update public.usuario set notif_preferences = '{"hora_cuota": "10:00"}' where id = pg_temp.u('e1');
select is(pg_temp.prefs_de('e1'), '{"hora_cuota": "10:00"}'::jsonb, 'el servidor sí las escribe');
update public.usuario set notif_preferences = null where id = pg_temp.u('e1');

-- Una cuenta dada de baja no guarda nada.
update public.usuario set deleted_at = now() where id = pg_temp.u('e6');
select pg_temp.actuar_como(pg_temp.u('e6'));
select public.guardar_mis_preferencias_de_avisos('{"hora_cuota": "10:00"}');
select pg_temp.actuar_como_servidor();
select is(pg_temp.prefs_de('e6'), null, 'una cuenta dada de baja no guarda preferencias');
update public.usuario set deleted_at = null where id = pg_temp.u('e6');

-- ---------------------------------------------------------------------------
-- 3. Cuotas pendientes a la hora de cada uno
-- ---------------------------------------------------------------------------
-- Todas con una cita de cobranza programada hace 3 días. e2 elige las 14:00, e3 las 00:00, e5 las 18:00; e1 y e4
-- quedan con las 09:00 por defecto.
update public.usuario set notif_preferences = '{"hora_cuota": "14:00"}' where id = pg_temp.u('e2');
update public.usuario set notif_preferences = '{"hora_cuota": "00:00"}' where id = pg_temp.u('e3');
update public.usuario set notif_preferences = '{"hora_cuota": "18:00"}' where id = pg_temp.u('e5');
select pg_temp.cita('a1', 'e1', 'COBRANZA', -3);
select pg_temp.cita('a2', 'e2', 'COBRANZA', -3);
select pg_temp.cita('a3', 'e3', 'COBRANZA', -3);
select pg_temp.cita('a4', 'e4', 'COBRANZA', -3);
select pg_temp.cita('a5', 'e5', 'COBRANZA', -3);

-- A las 08:00 todavía no llegó la hora de e1, e2, e4 ni e5; la de e3 (00:00) sí pasó.
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('08:00')), 1, 'a las 08:00 solo le toca a quien eligió la medianoche');
select is(pg_temp.avisos('e3', 'cuota_pendiente'), 1, 'es e3');
-- A las 10:00 llegó la hora por defecto: e1 y e4. e2 (14:00) y e5 (18:00) esperan.
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('10:00')), 2, 'a las 10:00 salen las dos de la hora por defecto');
select ok(pg_temp.avisos('e1', 'cuota_pendiente') = 1 and pg_temp.avisos('e4', 'cuota_pendiente') = 1
          and pg_temp.avisos('e2', 'cuota_pendiente') = 0 and pg_temp.avisos('e5', 'cuota_pendiente') = 0,
          'son e1 y e4, y a e2 y e5 todavía no');
-- A las 14:15 le toca a e2; a las 18:15, a e5.
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('14:15')), 1, 'a las 14:15 sale la de e2');
select is(pg_temp.avisos('e2', 'cuota_pendiente'), 1, 'es e2');
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('18:15')), 1, 'a las 18:15 sale la de e5');
select is(pg_temp.avisos('e5', 'cuota_pendiente'), 1, 'es e5');
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('23:45')), 0, 'ya recibieron todas: pasar otra vez no repite nada');
select is((select count(*)::int from push.evento where tipo = 'cuota_pendiente'), 5, 'cinco avisos, uno por cita');

-- Quien cambia la hora DESPUÉS de recibirlo no lo recibe de nuevo (e1 lo recibió a las 10:00).
update public.usuario set notif_preferences = '{"hora_cuota": "11:00"}' where id = pg_temp.u('e1');
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('12:00')), 0, 'e1 pasa su hora a las 11:00 y no se le repite el aviso de hoy');
update public.usuario set notif_preferences = '{"hora_cuota": "20:00"}' where id = pg_temp.u('e1');
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('21:00')), 0, 'ni pasándola a la noche');

-- Quien la cambia ANTES de recibirlo: e6 (sin preferencias, 09:00) tiene su cita y a las 08:00 todavía no le toca.
select pg_temp.cita('a6', 'e6', 'COBRANZA', -3);
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('08:00')), 0, 'a las 08:00 e6 todavía no recibe nada (su hora es la 09:00)');
update public.usuario set notif_preferences = '{"hora_cuota": "07:30"}' where id = pg_temp.u('e6');
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('08:00')), 1, 'si adelanta su hora a las 07:30, lo recibe en la pasada siguiente');
update public.usuario set notif_preferences = null where id = pg_temp.u('e6');

-- Una cita que no es de cobranza, o que ya se cumplió, no avisa a ninguna hora.
select pg_temp.cita('a7', 'e4', 'ENTREVISTA', -3);
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('12:00')), 0, 'una entrevista no es una cuota');

-- Si la pasada de ese día no corrió, se recupera hasta 24 horas después de la hora de esa colportora; después no.
delete from push.evento;
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('08:00', 1)), 5,
          'a las 08:00 de mañana se recuperan las de quienes tienen su hora después (e1, e2, e4, e5 y e6); e3 ya pasó al día siguiente');
delete from push.evento;
select is(push.encolar_cuotas_pendientes(pg_temp.a_las('10:00', 1)), 3,
          'a las 10:00 de mañana, las de quienes pasaron su hora hace menos de 24 horas (e1 a las 20:00, e2 a las 14:00, e5 a las 18:00)');
select is(pg_temp.avisos('e4', 'cuota_pendiente') + pg_temp.avisos('e6', 'cuota_pendiente'), 0,
          'y las de la hora por defecto (09:00) ya no: pasaron 25 horas');

-- ---------------------------------------------------------------------------
-- 4. Agenda de mañana a la hora de cada uno
-- ---------------------------------------------------------------------------
delete from push.evento;
update public.usuario set notif_preferences = null where id in (pg_temp.u('e1'), pg_temp.u('e3'));
update public.usuario set notif_preferences = '{"hora_agenda": "22:30"}' where id = pg_temp.u('e2');
update public.usuario set notif_preferences = '{"hora_agenda": "08:00"}' where id = pg_temp.u('e3');
update public.usuario set notif_preferences = '{"hora_agenda": "23:59"}' where id = pg_temp.u('e6');
-- Todas tienen una visita mañana (e4 y e5 no).
select pg_temp.cita('b1', 'e1', 'ENTREVISTA', 1);
select pg_temp.cita('b2', 'e2', 'ENTREVISTA', 1);
select pg_temp.cita('b3', 'e3', 'COBRANZA', 1);
select pg_temp.cita('b6', 'e6', 'ENTREVISTA', 1);

-- A las 07:00 no le toca a nadie (e3 elige las 08:00).
select is(push.encolar_agenda_manana(pg_temp.a_las('07:00')), 0, 'a las 07:00 todavía no llegó la hora de nadie');
-- A las 08:15: e3.
select is(push.encolar_agenda_manana(pg_temp.a_las('08:15')), 1, 'a las 08:15 sale la de e3 (eligió las 08:00)');
select is(pg_temp.avisos('e3', 'agenda_manana'), 1, 'es e3');
select is((select vence_en from push.evento where usuario_id = pg_temp.u('e3') and tipo = 'agenda_manana'), pg_temp.a_las('12:00'),
          'vale 4 horas desde su hora');
-- A las 12:30 la ventana de e3 (08:00 a 12:00) ya cerró y e1 todavía no empezó.
select is(push.encolar_agenda_manana(pg_temp.a_las('12:30')), 0, 'a las 12:30 nadie más: la hora de e1 es las 20:00');
-- A las 20:15: e1 con su hora por defecto. e2 (22:30) todavía no.
select is(push.encolar_agenda_manana(pg_temp.a_las('20:15')), 1, 'a las 20:15 sale la de e1 (hora por defecto)');
select is(pg_temp.avisos('e1', 'agenda_manana'), 1, 'es e1');
select is((select vence_en from push.evento where usuario_id = pg_temp.u('e1') and tipo = 'agenda_manana'), pg_temp.a_las('24:00'),
          'vale 4 horas, pero nunca pasada la medianoche: ahí el «mañana» ya es hoy');
-- A las 22:45: e2.
select is(push.encolar_agenda_manana(pg_temp.a_las('22:45')), 1, 'a las 22:45 sale la de e2 (eligió las 22:30)');
select is(pg_temp.avisos('e2', 'agenda_manana'), 1, 'es e2');
-- e1 no lo recibe de nuevo si cambia la hora después de recibirlo.
update public.usuario set notif_preferences = '{"hora_agenda": "21:00"}' where id = pg_temp.u('e1');
select is(push.encolar_agenda_manana(pg_temp.a_las('21:30')), 0, 'e1 pasa su hora a las 21:00 y no se le repite el aviso de hoy');
-- La última pasada del día es a las 23:45: e6 eligió las 23:59 y lo recibe en esa.
select is(push.encolar_agenda_manana(pg_temp.a_las('23:30')), 0, 'a las 23:30 todavía no (eligió las 23:59)');
select is(push.encolar_agenda_manana(pg_temp.a_las('23:45')), 1, 'una hora posterior a las 23:45 sale en la última pasada del día');
select is(pg_temp.avisos('e6', 'agenda_manana'), 1, 'es e6');
-- Pasada la medianoche, "mañana" ya es hoy: no sale aunque sea la ventana de 4 horas de e6.
delete from push.evento where usuario_id = pg_temp.u('e6');
select is(push.encolar_agenda_manana(pg_temp.a_las('00:15', 1)), 0, 'a las 00:15 el «mañana» de ayer ya es hoy: no sale');
-- Dentro de la ventana de 4 horas, aunque la pasada anterior no hubiera corrido, sale en la siguiente.
delete from push.evento;
select is(push.encolar_agenda_manana(pg_temp.a_las('09:00')), 1, 'e3 (08:00) todavía está dentro de sus 4 horas a las 09:00: lo recibe');
delete from push.evento;
-- Una cita cancelada no cuenta; sin citas de mañana no hay aviso.
update public.agenda set estado = 'CANCELADA' where id = pg_temp.u('b3');
select is(push.encolar_agenda_manana(pg_temp.a_las('09:00')), 0, 'si la cita de mañana se canceló, no hay aviso');

-- ---------------------------------------------------------------------------
-- 5. Las tareas de pg_cron
-- ---------------------------------------------------------------------------
select is((select count(*)::int from cron.job where jobname in ('push-cuotas-pendientes', 'push-agenda-manana')
              and schedule = '*/15 * * * *'), 2, 'las dos tareas corren cada 15 minutos');
select is((select count(*)::int from cron.job where jobname in ('push-cuotas-pendientes', 'push-agenda-manana')
              and command ~ '\(\)'), 2, 'y se llaman sin argumentos (el «ahora» es now())');
select is(push.ultima_hora_de_aviso(pg_temp.a_las('10:00'), time '09:00'), public.hoy_montevideo()::timestamp + time '09:00',
          'la última hora de las 09:00, a las 10:00, fue hoy');
select is(push.ultima_hora_de_aviso(pg_temp.a_las('08:00'), time '09:00'), (public.hoy_montevideo() - 1)::timestamp + time '09:00',
          'y a las 08:00 fue ayer');

select * from finish();
rollback;
