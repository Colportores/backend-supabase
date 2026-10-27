-- pgTAP · el servidor frena la jornada antes del inicio de la campaña (migración 0115, backend-supabase#165,
-- seguimiento de #142; decisión de Cristian del 23/10 «Cuenta antes»: hasta el inicio no hay jornada ni venta)
--   1. La forma: jornada_no_antes_del_inicio es RESTRICTIVE, solo de INSERT, de authenticated.
--   2. El caso de uso: Agustín (inscripto en una campaña que empieza mañana y en otra después) inicia una
--      jornada hoy desde un teléfono desactualizado: 42501; el día se cuenta en Montevideo, por
--      jornada.inicio y no por la fecha del servidor; la rechazada no deja nada.
--   3. El borde: el día que empieza la campaña ya vale.
--   4. Por sync_push, que es el camino real: invalid con 42501 y el lote sigue.
--   5. Lo que no se rechaza: cerrar o corregir una jornada que ya existe, jornada tardía de una campaña
--      anterior (con y sin fin, y el plazo de 15 días), inscripción de baja como cobertura, campaña borrada
--      o sin inscripciones por empezar, campaña abierta ya empezada, el servidor.
--   6. La política de siempre (colportor_id = auth.uid()) sigue rigiendo.
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

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000115' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo.
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- Una jornada como el colportor logueado (RLS), que empieza en p_inicio.
create or replace function pg_temp.iniciar(p_id text, p_inicio timestamptz) returns text
language plpgsql as $$
begin
  insert into public.jornada (id, inicio) values (pg_temp.u(p_id), p_inicio);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object(
    'device', jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000115d0',
                                 'app_version', '1.4.2', 'schema_version', 1),
    'jobs', p_jobs));
$$;
create or replace function pg_temp.job_jornada(p_op text, p_id text, p_inicio timestamptz) returns jsonb
language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'jornada', 'op', 'insert',
                            'sync_version', null,
                            'payload', jsonb_build_object('id', pg_temp.u(p_id), 'inicio', p_inicio,
                                                           'created_at', now()));
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;

-- --- fixtures (como postgres, sin RLS) -----------------------------------------
-- Campañas (hoy = día de Montevideo):
--   c1 Invierno        hoy-10 .. hoy+20      c2 Primavera       hoy+21 .. hoy+80
--   ca Mañana          hoy+1 .. hoy+40       c4 Abierta         hoy+100 .. sin fin
--   c6 Terminada       hoy-90 .. hoy-30      c7 Borrada         hoy+30 .. hoy+60 (deleted_at)
--   cc Abierta empezada hoy-5 .. sin fin
-- Colportores:
--   e1 en Mañana y Primavera (nada empezó)        e2 en Invierno y Primavera (una en curso)
--   e3 en Terminada y Primavera                    e4 de baja en Invierno y en Primavera
--   e5 sin inscripciones                           e6 solo de baja en Primavera
--   e7 solo en Borrada                             e8 en Abierta empezada y Primavera
--   e9 en Primavera y Abierta (nada empezó, una sin fin)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'jornada115-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['e1','e2','e3','e4','e5','e6','e7','e8','e9']) s;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, deleted_at) values
  (pg_temp.u('c1'), 'Invierno',          'INVIERNO',   pg_temp.hoy() - 10,  pg_temp.hoy() + 20,  null),
  (pg_temp.u('c2'), 'Primavera',         'VERANO',     pg_temp.hoy() + 21,  pg_temp.hoy() + 80,  null),
  (pg_temp.u('c4'), 'Abierta',           'PERMANENTE', pg_temp.hoy() + 100, null,                null),
  (pg_temp.u('c6'), 'Terminada',         'VERANO',     pg_temp.hoy() - 90,  pg_temp.hoy() - 30,  null),
  (pg_temp.u('c7'), 'Borrada',           'VERANO',     pg_temp.hoy() + 30,  pg_temp.hoy() + 60,  now()),
  (pg_temp.u('ca'), 'Manana',            'VERANO',     pg_temp.hoy() + 1,   pg_temp.hoy() + 40,  null),
  (pg_temp.u('cc'), 'Abierta empezada',  'PERMANENTE', pg_temp.hoy() - 5,   null,                null);

-- Con inscripción de baja: deleted_at; las demás, vivas.
insert into public.campania_colportor (campania_id, usuario_id, deleted_at) values
  (pg_temp.u('ca'), pg_temp.u('e1'), null),
  (pg_temp.u('c2'), pg_temp.u('e1'), null),
  (pg_temp.u('c1'), pg_temp.u('e2'), null),
  (pg_temp.u('c2'), pg_temp.u('e2'), null),
  (pg_temp.u('c6'), pg_temp.u('e3'), null),
  (pg_temp.u('c2'), pg_temp.u('e3'), null),
  (pg_temp.u('c1'), pg_temp.u('e4'), now()),
  (pg_temp.u('c2'), pg_temp.u('e4'), null),
  (pg_temp.u('c2'), pg_temp.u('e6'), now()),
  (pg_temp.u('c7'), pg_temp.u('e7'), null),
  (pg_temp.u('cc'), pg_temp.u('e8'), null),
  (pg_temp.u('c2'), pg_temp.u('e8'), null),
  (pg_temp.u('c2'), pg_temp.u('e9'), null),
  (pg_temp.u('c4'), pg_temp.u('e9'), null);

-- Una jornada ya abierta de e1 (la cargó el servidor): para probar que cerrarla no se rechaza.
insert into public.jornada (id, colportor_id, inicio)
values (pg_temp.u('f0'), pg_temp.u('e1'), now());

-- ---------------------------------------------------------------------------
-- 1. La forma de la política
-- ---------------------------------------------------------------------------
select is((select polpermissive from pg_policy where polname = 'jornada_no_antes_del_inicio'
              and polrelid = 'public.jornada'::regclass),
          false, 'jornada_no_antes_del_inicio es RESTRICTIVE: se suma a jornada_propio, no la reemplaza');
select is((select polcmd from pg_policy where polname = 'jornada_no_antes_del_inicio'
              and polrelid = 'public.jornada'::regclass),
          'a', 'y es solo de INSERT');
select is((select polpermissive from pg_policy where polname = 'jornada_propio'
              and polrelid = 'public.jornada'::regclass),
          true, 'y la de siempre, jornada_propio, sigue siendo permisiva');

-- ---------------------------------------------------------------------------
-- 2. El caso de uso: Agustín, el 20/11, con la campaña que empieza el 1/12
-- ---------------------------------------------------------------------------
-- e1 está en Mañana (empieza mañana) y en Primavera (hoy+21): hoy es antes del inicio de las dos.
select pg_temp.actuar_como(pg_temp.u('e1'));
select is(pg_temp.iniciar('a1', now()), '42501', 'e1 (en dos campañas que no empezaron): iniciar jornada hoy, 42501');
select is(pg_temp.iniciar('a2', now() + interval '2 minutes'), '42501', 'y reintentar, también');
select is(pg_temp.iniciar('a3', ((pg_temp.hoy())::timestamp + interval '22 hours') at time zone 'America/Montevideo'),
          '42501', 'a las 22:00 de Montevideo (01:00 UTC de mañana) todavía es hoy: el día se cuenta en Montevideo');
select is(pg_temp.iniciar('a4', now() - interval '3 days'), '42501',
          'una jornada de hace tres días, también: ninguna campaña había empezado');
-- Por la fecha de la jornada y no por la del servidor: la de mañana a las 09:00 (hora de Montevideo).
select is(pg_temp.iniciar('a5', ((pg_temp.hoy() + 1)::timestamp + interval '9 hours') at time zone 'America/Montevideo'),
          'ok', '3. el día que empieza Mañana ya no es antes del inicio, aunque Primavera siga sin empezar');
select pg_temp.actuar_como_servidor();
select is((select count(*) from public.jornada where colportor_id = pg_temp.u('e1')), 2::bigint,
          'de e1 quedan la abierta del servidor y la del día de inicio: las rechazadas no dejaron nada');

-- ---------------------------------------------------------------------------
-- 4. Por sync_push: invalid con 42501 y el lote sigue
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('e1'));
create temp table r_push on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job_jornada('01', 'b1', now()),
    pg_temp.job_jornada('02', 'b2', now() + interval '1 day'))) as r;
grant select on r_push to authenticated;
select is(pg_temp.resultados((select r from r_push)), array['invalid', 'accepted'],
          'sync_push: la jornada de hoy vuelve invalid y la del día de inicio entra');
select is(pg_temp.codigos((select r from r_push)), array['42501', '-'], 'con 42501');

-- ---------------------------------------------------------------------------
-- 5. Lo que no se rechaza
-- ---------------------------------------------------------------------------
-- Cerrar o corregir una jornada que ya existe no se mira: solo el alta.
select is(pg_temp.error_de(format($$ update public.jornada set fin = now() + interval '1 hour' where id = %L $$,
                                   pg_temp.u('f0'))),
          'ok', 'cerrar la jornada que ya existe no se rechaza (aunque hoy sea antes del inicio)');

-- e2: Invierno (en curso) y Primavera (por empezar): inicia hoy.
select pg_temp.actuar_como(pg_temp.u('e2'));
select is(pg_temp.iniciar('c1', now()), 'ok', 'e2 (en curso y por empezar): iniciar hoy, ok');

-- e3: Terminada (terminó hace 30 días) y Primavera (por empezar).
select pg_temp.actuar_como(pg_temp.u('e3'));
select is(pg_temp.iniciar('d1', now()), '42501', 'e3: hoy no hay campaña empezada y pasó del plazo, 42501');
select is(pg_temp.iniciar('d2', now() - interval '60 days'), 'ok',
          'una jornada tardía de dentro de Terminada (hoy-60) no se pierde');
select is(pg_temp.iniciar('d3', now() - interval '20 days'), 'ok',
          'ni la de los 15 días de gracia después de que terminó (hoy-20; Terminada acabó en hoy-30)');
select is(pg_temp.iniciar('d4', now() - interval '15 days'), 'ok', 'el día 15 de la gracia todavía entra');
select is(pg_temp.iniciar('d5', now() - interval '14 days'), '42501', 'el día 16 ya no: 42501');
select is(pg_temp.iniciar('d6', now() - interval '10 days'), '42501',
          'pasado el plazo de Terminada (hoy-10) y antes de Primavera, 42501');

-- Una jornada ya cerrada que sube tarde (con fin) se mira por su inicio.
select is(pg_temp.error_de(format($$ insert into public.jornada (id, inicio, fin) values (%L, now() - interval '70 days',
                                      now() - interval '70 days' + interval '3 hours') $$, pg_temp.u('d7'))),
          'ok', 'una jornada cerrada de dentro de Terminada, subida tarde, entra');
select is(pg_temp.error_de(format($$ insert into public.jornada (id, inicio, fin) values (%L, now() - interval '5 days',
                                      now() - interval '5 days' + interval '3 hours') $$, pg_temp.u('d8'))),
          '42501', 'y una cerrada que empezó fuera de toda campaña, no');

-- e4: de baja en Invierno (en curso) y por empezar en Primavera: la inscripción de baja cubre hoy.
select pg_temp.actuar_como(pg_temp.u('e4'));
select is(pg_temp.iniciar('e1', now()), 'ok',
          'e4 (de baja en Invierno, que ya empezó): una jornada que ya existe en el teléfono no se pierde');

-- e6 solo tiene una inscripción dada de baja en una campaña futura; e7 una viva en una campaña borrada.
select pg_temp.actuar_como(pg_temp.u('e6'));
select is(pg_temp.iniciar('e2', now()), 'ok', 'e6 (de baja en una campaña que no empezó): iniciar, ok');
select pg_temp.actuar_como(pg_temp.u('e7'));
select is(pg_temp.iniciar('e3', now()), 'ok', 'e7 (solo en una campaña borrada): iniciar, ok');
-- e8 está en una abierta que ya empezó (sin fin) y en Primavera: la abierta cubre hoy.
select pg_temp.actuar_como(pg_temp.u('e8'));
select is(pg_temp.iniciar('e4', now()), 'ok', 'e8 (en una abierta ya empezada y una por empezar): iniciar, ok');
-- Sin fecha de fin, la abierta ya empezada cubre cualquier día posterior a su inicio (nunca pasa del plazo).
select is(pg_temp.iniciar('e5', now() - interval '3 days'), 'ok', 'y una de hace tres días, que ya había empezado, también');
select is(pg_temp.iniciar('e6', now() - interval '10 days'), '42501',
          'pero una de antes de que empiece Abierta empezada (hoy-5) y Primavera, no');

-- e5 no tiene ninguna inscripción: no cambia nada respecto de hoy.
select pg_temp.actuar_como(pg_temp.u('e5'));
select is(pg_temp.iniciar('e7', now()), 'ok', 'e5 (sin inscripciones): iniciar, como hasta ahora');

-- e9 en Primavera y en Abierta (sin fin, desde hoy+100): hoy no empezó ninguna.
select pg_temp.actuar_como(pg_temp.u('e9'));
select is(pg_temp.iniciar('e8', now()), '42501', 'e9 (en dos campañas que no empezaron): iniciar hoy, 42501');
select is(pg_temp.iniciar('e9', now() + interval '21 days'), 'ok', 'el día que empieza Primavera ya vale');
select is(pg_temp.iniciar('ea', now() + interval '100 days'), 'ok', 'y con Abierta sin fin, el día que empieza también');

-- El servidor (service_role / postgres) no pasa por la política: carga lo que haga falta.
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de(format($$ insert into public.jornada (id, colportor_id, inicio) values (%L, %L, now()) $$,
                                   pg_temp.u('eb'), pg_temp.u('e1'))),
          'ok', 'el servidor carga una jornada de hoy de e1 (la política es de authenticated)');

-- ---------------------------------------------------------------------------
-- 6. La política de siempre sigue rigiendo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('e2'));
select is(pg_temp.error_de(format($$ insert into public.jornada (id, colportor_id, inicio) values (%L, %L, now()) $$,
                                   pg_temp.u('ec'), pg_temp.u('e5'))),
          '42501', 'una jornada a nombre de otro colportor sigue rechazada');

select * from finish();
rollback;
