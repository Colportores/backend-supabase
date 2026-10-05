-- pgTAP · migración 0024 (backend-supabase#59): el día de una campaña se cuenta en Montevideo en
-- todo el sistema, no con el `current_date` de la sesión (UTC en Supabase).
--   1. public.hoy_montevideo(): el día en America/Montevideo, sin depender de la zona horaria de la
--      sesión, y sus bordes (23:59:59 y 00:00 de Uruguay); escritura_en_curso() y
--      escritura_dentro_de_plazo() la usan.
--   2. La lectura (mapa, casas), la escritura, la inscripción y el estado de la cuenta dan el mismo
--      resultado en la misma campaña con la sesión en UTC, en UTC+14 y en UTC-12. `now()` no se puede
--      mover dentro de la transacción, así que el test no depende de la hora en que corre: las
--      campañas se definen contra hoy_montevideo() y se prueban dos zonas horarias extremas, que
--      juntas dan un día distinto al de Montevideo a cualquier hora (UTC+14 de las 07:00 a las 24:00
--      de Uruguay; UTC-12 de las 00:00 a las 09:00). Con el `current_date` de antes, siempre falla
--      alguna.
--   3. Las reglas que se enteraban del día por su cuenta (CZ011 al cambiar el mapa de una campaña
--      terminada, CI002 al inscribir fuera de fecha) también coinciden.
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
  select ('01920000-0000-7000-8000-0000000029' || p)::uuid;
$$;
-- La zona horaria de la sesión (hasta el final de la transacción).
create or replace function pg_temp.zona_horaria(p_tz text) returns void language sql as $$
  select set_config('TimeZone', p_tz, true);
$$;
-- Zona horaria + usuario de una vez.
create or replace function pg_temp.como(p_tz text, p_usuario text) returns void language plpgsql as $$
begin
  perform pg_temp.actuar_como_servidor();
  perform pg_temp.zona_horaria(p_tz);
  perform pg_temp.actuar_como(pg_temp.u(p_usuario));
end $$;

-- Lo que el usuario actual ve y puede hacer en las cuatro campañas del test, en una sola línea.
--   mapa     = campañas cuyo mapa ve (mis_campanias_del_mapa)
--   vigentes = inscripciones vigentes (estado de la cuenta, inscripción)
--   ciudades = ciudades de campaña que ve (RLS de lectura)
--   casas    = casas que ve (RLS de lectura)
--   escribe  = casas en las que puede escribir (sin pasar por lo que ve)
create or replace function pg_temp.observar() returns text language sql as $$
  select 'mapa=' || (select count(*) from public.mis_campanias_del_mapa())
      || ' vigentes=' || (select count(*) from public.mis_campanias_vigentes())
      || ' ciudades=' || (select count(*) from public.campania_ciudad cc
                           where cc.id::text like '01920000-0000-7000-8000-0000000029f%')
      || ' casas=' || (select count(*) from public.ubicacion x
                        where x.id::text like '01920000-0000-7000-8000-00000000290%')
      || ' escribe=' || (select count(*) from unnest(array[pg_temp.u('01'), pg_temp.u('02'), pg_temp.u('03'), pg_temp.u('04')]) c(id)
                          where public.puedo_escribir_en_ubicacion(c.id))
      || ' cuenta=' || public.estado_cuenta();
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Cuatro campañas coordinadas por a1, cada una con su ciudad y una casa:
--   e1 «termina hoy»   (c1): empezó hace 10 días y termina HOY (Montevideo).
--   e2 «terminó ayer»  (c2): terminó AYER, dentro de los 15 días de gracia.
--   e3 «empieza hoy»   (c3): empieza HOY y termina en 30 días.
--   e4 «empieza mañana» (c4): empieza MAÑANA.
-- b1..b4 están inscriptos en e1..e4 (en ese orden). b5..b8 sin inscripción (para inscribir).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dia29-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4','b5','b6','b7','b8']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR'), ('b7','COLPORTOR'), ('b8','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais dia29', 'ZD');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad e1 dia29', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Ciudad e2 dia29', pg_temp.u('c0'), -34.70, -56.20),
  (pg_temp.u('c3'), 'Ciudad e3 dia29', pg_temp.u('c0'), -34.50, -56.30),
  (pg_temp.u('c4'), 'Ciudad e4 dia29', pg_temp.u('c0'), -34.30, -56.40);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Termina hoy dia29',    'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo(),      pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Terminó ayer dia29',   'VERANO', public.hoy_montevideo() - 20, public.hoy_montevideo() - 1,  pg_temp.u('a1')),
  (pg_temp.u('e3'), 'Empieza hoy dia29',    'VERANO', public.hoy_montevideo(),      public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e4'), 'Empieza mañana dia29', 'VERANO', public.hoy_montevideo() + 1,  public.hoy_montevideo() + 30, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e3'), pg_temp.u('c3')),
  (pg_temp.u('f4'), pg_temp.u('e4'), pg_temp.u('c4'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')), (pg_temp.u('e2'), pg_temp.u('b2')),
  (pg_temp.u('e3'), pg_temp.u('b3')), (pg_temp.u('e4'), pg_temp.u('b4'));
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Calle e1', '1', -34.90, -56.16, pg_temp.u('c1'), pg_temp.u('a1')),
  (pg_temp.u('02'), 'CASA', 'Calle e2', '2', -34.70, -56.20, pg_temp.u('c2'), pg_temp.u('a1')),
  (pg_temp.u('03'), 'CASA', 'Calle e3', '3', -34.50, -56.30, pg_temp.u('c3'), pg_temp.u('a1')),
  (pg_temp.u('04'), 'CASA', 'Calle e4', '4', -34.30, -56.40, pg_temp.u('c4'), pg_temp.u('a1'));

-- ---------------------------------------------------------------------------
-- 1. hoy_montevideo(): el día de Uruguay, sin mirar la zona horaria de la sesión
-- ---------------------------------------------------------------------------
select has_function('public', 'hoy_montevideo', array['timestamp with time zone'], 'existe hoy_montevideo(timestamptz)');
select volatility_is('public', 'hoy_montevideo', array['timestamp with time zone'], 'stable', 'es stable (no mira datos)');
select ok(not has_function_privilege('anon', 'public.hoy_montevideo(timestamptz)', 'execute'), 'anon no la ejecuta');
select ok(has_function_privilege('authenticated', 'public.hoy_montevideo(timestamptz)', 'execute'),
          'authenticated sí, desde 0027: el default de precio_por_zona.valido_desde la evalúa con quien inserta');
select ok(has_function_privilege('service_role', 'public.hoy_montevideo(timestamptz)', 'execute'), 'service_role sí');

select is(public.hoy_montevideo('2026-10-03 02:59:59+00'), '2026-10-02'::date,
          '02/10 23:59:59 en Montevideo (03/10 02:59:59 UTC): todavía es el 02/10');
select is(public.hoy_montevideo('2026-10-03 03:00:00+00'), '2026-10-03'::date,
          '03/10 00:00 en Montevideo (03:00 UTC): ya es el 03/10');
select is(public.hoy_montevideo('2026-10-02 21:00:00-03'), '2026-10-02'::date,
          'las 21:00 de Uruguay son otro día en UTC, pero el día es el mismo');
select is(public.hoy_montevideo('2026-01-01 02:59:59+00'), '2025-12-31'::date, 'enero, borde de fin de año: 31/12');
select is(public.hoy_montevideo('2026-01-01 03:00:00+00'), '2026-01-01'::date, 'enero, borde de fin de año: 01/01');
select is(public.hoy_montevideo(), public.hoy_montevideo(now()), 'sin parámetro, el día de ahora');
select is(public.hoy_montevideo(), (now() at time zone 'America/Montevideo')::date, 'y es el de Montevideo');

select pg_temp.zona_horaria('Pacific/Kiritimati');
select is(public.hoy_montevideo('2026-10-03 02:59:59+00'), '2026-10-02'::date, 'sesión en UTC+14: el mismo día (borde de las 23:59:59)');
select is(public.hoy_montevideo('2026-10-03 03:00:00+00'), '2026-10-03'::date, 'sesión en UTC+14: el mismo día (borde de las 00:00)');
select is(public.hoy_montevideo(), (now() at time zone 'America/Montevideo')::date, 'sesión en UTC+14: el día de Montevideo ahora');
select pg_temp.zona_horaria('Etc/GMT+12');
select is(public.hoy_montevideo('2026-10-03 02:59:59+00'), '2026-10-02'::date, 'sesión en UTC-12: el mismo día (borde de las 23:59:59)');
select is(public.hoy_montevideo('2026-10-03 03:00:00+00'), '2026-10-03'::date, 'sesión en UTC-12: el mismo día (borde de las 00:00)');
select is(public.hoy_montevideo(), (now() at time zone 'America/Montevideo')::date, 'sesión en UTC-12: el día de Montevideo ahora');
select pg_temp.zona_horaria('UTC');

-- Las dos funciones de la escritura delegan en la misma definición del día.
select is(public.escritura_en_curso('2026-10-02', '2026-10-03 02:59:59+00'), true, 'en curso: el último día a las 23:59:59');
select is(public.escritura_en_curso('2026-10-02', '2026-10-03 03:00:00+00'), false, 'en curso: el día siguiente a las 00:00 ya no');
select is(public.escritura_en_curso(null, now()), true, 'en curso: sin fecha de fin, siempre');
select is(public.escritura_dentro_de_plazo('2026-10-02', '2026-10-18 02:59:59+00'), true, 'gracia: el día 15 a las 23:59:59');
select is(public.escritura_dentro_de_plazo('2026-10-02', '2026-10-18 03:00:00+00'), false, 'gracia: el día 16 a las 00:00 ya no');
select pg_temp.zona_horaria('Pacific/Kiritimati');
select is(public.escritura_en_curso('2026-10-02', '2026-10-03 02:59:59+00'), true, 'en curso, sesión en UTC+14: igual');
select is(public.escritura_dentro_de_plazo('2026-10-02', '2026-10-18 02:59:59+00'), true, 'gracia, sesión en UTC+14: igual');
select pg_temp.zona_horaria('Etc/GMT+12');
select is(public.escritura_en_curso('2026-10-02', '2026-10-03 03:00:00+00'), false, 'en curso, sesión en UTC-12: igual');
select is(public.escritura_dentro_de_plazo('2026-10-02', '2026-10-18 03:00:00+00'), false, 'gracia, sesión en UTC-12: igual');
select pg_temp.zona_horaria('UTC');

-- ---------------------------------------------------------------------------
-- 2. Lectura, escritura y cuenta: lo mismo con la sesión en UTC, UTC+14 y UTC-12
-- ---------------------------------------------------------------------------
-- b1: la campaña que termina HOY sigue en curso hasta las 23:59 de Montevideo: la ve, escribe y la
--     cuenta está activa (antes, con el día en UTC, dejaba de ver el mapa y las casas a las 21:00).
select pg_temp.como('UTC', 'b1');
select is(pg_temp.observar(), 'mapa=1 vigentes=1 ciudades=1 casas=1 escribe=1 cuenta=ACTIVA',
          'b1 (termina hoy), sesión en UTC: ve todo, escribe, cuenta ACTIVA');
select pg_temp.como('Pacific/Kiritimati', 'b1');
select is(pg_temp.observar(), 'mapa=1 vigentes=1 ciudades=1 casas=1 escribe=1 cuenta=ACTIVA',
          'b1 (termina hoy), sesión en UTC+14: lo mismo');
select pg_temp.como('Etc/GMT+12', 'b1');
select is(pg_temp.observar(), 'mapa=1 vigentes=1 ciudades=1 casas=1 escribe=1 cuenta=ACTIVA',
          'b1 (termina hoy), sesión en UTC-12: lo mismo');

-- b2: terminó AYER. No ve el mapa ni las casas, la cuenta no es activa, pero escribe (15 días de gracia).
select pg_temp.como('UTC', 'b2');
select is(pg_temp.observar(), 'mapa=0 vigentes=0 ciudades=0 casas=0 escribe=1 cuenta=PENDIENTE_ASIGNACION',
          'b2 (terminó ayer), sesión en UTC: no ve el mapa, escribe por la gracia');
select pg_temp.como('Pacific/Kiritimati', 'b2');
select is(pg_temp.observar(), 'mapa=0 vigentes=0 ciudades=0 casas=0 escribe=1 cuenta=PENDIENTE_ASIGNACION',
          'b2 (terminó ayer), sesión en UTC+14: lo mismo');
select pg_temp.como('Etc/GMT+12', 'b2');
select is(pg_temp.observar(), 'mapa=0 vigentes=0 ciudades=0 casas=0 escribe=1 cuenta=PENDIENTE_ASIGNACION',
          'b2 (terminó ayer), sesión en UTC-12: lo mismo');

-- b3: empieza HOY. Desde las 00:00 de Montevideo está en curso (antes, desde las 21:00 del día anterior).
select pg_temp.como('UTC', 'b3');
select is(pg_temp.observar(), 'mapa=1 vigentes=1 ciudades=1 casas=1 escribe=1 cuenta=ACTIVA',
          'b3 (empieza hoy), sesión en UTC: en curso');
select pg_temp.como('Pacific/Kiritimati', 'b3');
select is(pg_temp.observar(), 'mapa=1 vigentes=1 ciudades=1 casas=1 escribe=1 cuenta=ACTIVA',
          'b3 (empieza hoy), sesión en UTC+14: lo mismo');
select pg_temp.como('Etc/GMT+12', 'b3');
select is(pg_temp.observar(), 'mapa=1 vigentes=1 ciudades=1 casas=1 escribe=1 cuenta=ACTIVA',
          'b3 (empieza hoy), sesión en UTC-12: lo mismo');

-- b4: empieza MAÑANA. Ve el mapa y las casas (decisión del 30/09 y del 02/10), todavía no escribe ni
--     tiene la cuenta activa.
select pg_temp.como('UTC', 'b4');
select is(pg_temp.observar(), 'mapa=1 vigentes=0 ciudades=1 casas=1 escribe=0 cuenta=PENDIENTE_ASIGNACION',
          'b4 (empieza mañana), sesión en UTC: ve el mapa y las casas, todavía no escribe');
select pg_temp.como('Pacific/Kiritimati', 'b4');
select is(pg_temp.observar(), 'mapa=1 vigentes=0 ciudades=1 casas=1 escribe=0 cuenta=PENDIENTE_ASIGNACION',
          'b4 (empieza mañana), sesión en UTC+14: lo mismo');
select pg_temp.como('Etc/GMT+12', 'b4');
select is(pg_temp.observar(), 'mapa=1 vigentes=0 ciudades=1 casas=1 escribe=0 cuenta=PENDIENTE_ASIGNACION',
          'b4 (empieza mañana), sesión en UTC-12: lo mismo');

-- La vigencia de cada campaña, directo (como el servidor), con las tres zonas horarias.
select pg_temp.actuar_como_servidor();
create or replace function pg_temp.vigentes() returns boolean[] language sql as $$
  select array_agg(public.campania_vigente(c) order by c.id)
    from public.campania c where c.id in (pg_temp.u('e1'), pg_temp.u('e2'), pg_temp.u('e3'), pg_temp.u('e4'));
$$;
select is(pg_temp.vigentes(), array[true, false, true, false], 'campania_vigente: termina hoy sí, terminó ayer no, empieza hoy sí, empieza mañana no');
select pg_temp.zona_horaria('Pacific/Kiritimati');
select is(pg_temp.vigentes(), array[true, false, true, false], 'campania_vigente, sesión en UTC+14: igual');
select pg_temp.zona_horaria('Etc/GMT+12');
select is(pg_temp.vigentes(), array[true, false, true, false], 'campania_vigente, sesión en UTC-12: igual');
select pg_temp.zona_horaria('UTC');

-- ---------------------------------------------------------------------------
-- 3. Cambiar el mapa (CZ011) e inscribir (CI002): el mismo día
-- ---------------------------------------------------------------------------
-- a1 prueba el guardado de una zona en la campaña que termina hoy (se puede) y en la que terminó ayer
-- (CZ011), con vista previa: no deja nada guardado.
select pg_temp.como('UTC', 'a1');
select lives_ok(
  format($$ select public.guardar_zona(%L, 'Zona dia29', 'RADIAL', p_centro_lat => -34.90, p_centro_lon => -56.16,
                                       p_radio_m => 300, p_vista_previa => true) $$, pg_temp.u('f1')),
  'sesión en UTC: se puede cambiar el mapa de la campaña que termina hoy');
select throws_ok(
  format($$ select public.guardar_zona(%L, 'Zona dia29', 'RADIAL', p_centro_lat => -34.70, p_centro_lon => -56.20,
                                       p_radio_m => 300, p_vista_previa => true) $$, pg_temp.u('f2')),
  'CZ011', null, 'sesión en UTC: no el de la que terminó ayer (CZ011)');
select pg_temp.como('Pacific/Kiritimati', 'a1');
select lives_ok(
  format($$ select public.guardar_zona(%L, 'Zona dia29', 'RADIAL', p_centro_lat => -34.90, p_centro_lon => -56.16,
                                       p_radio_m => 300, p_vista_previa => true) $$, pg_temp.u('f1')),
  'sesión en UTC+14: se puede cambiar el mapa de la campaña que termina hoy (antes, no a partir de las 21:00)');
select throws_ok(
  format($$ select public.guardar_zona(%L, 'Zona dia29', 'RADIAL', p_centro_lat => -34.70, p_centro_lon => -56.20,
                                       p_radio_m => 300, p_vista_previa => true) $$, pg_temp.u('f2')),
  'CZ011', null, 'sesión en UTC+14: no el de la que terminó ayer');
select pg_temp.como('Etc/GMT+12', 'a1');
select lives_ok(
  format($$ select public.guardar_zona(%L, 'Zona dia29', 'RADIAL', p_centro_lat => -34.90, p_centro_lon => -56.16,
                                       p_radio_m => 300, p_vista_previa => true) $$, pg_temp.u('f1')),
  'sesión en UTC-12: se puede cambiar el mapa de la campaña que termina hoy');
select throws_ok(
  format($$ select public.guardar_zona(%L, 'Zona dia29', 'RADIAL', p_centro_lat => -34.70, p_centro_lon => -56.20,
                                       p_radio_m => 300, p_vista_previa => true) $$, pg_temp.u('f2')),
  'CZ011', null, 'sesión en UTC-12: no el de la que terminó ayer');
select pg_temp.actuar_como_servidor();
select pg_temp.zona_horaria('UTC');
select is((select count(*) from public.zona where nombre = 'Zona dia29'), 0::bigint, 'la vista previa no dejó nada guardado');

-- Inscribir: una campaña que termina hoy o que empieza hoy admite inscripciones; la que terminó ayer o
-- empieza mañana, no (CI002). b5 y b6 con la sesión en UTC+14; b7 y b8 con la sesión en UTC-12.
select pg_temp.como('Pacific/Kiritimati', 'a1');
select lives_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('b5')),
                'sesión en UTC+14: se inscribe en la campaña que termina hoy');
select lives_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e3'), pg_temp.u('b6')),
                'sesión en UTC+14: se inscribe en la campaña que empieza hoy');
select throws_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e2'), pg_temp.u('b7')),
                 'CI002', null, 'sesión en UTC+14: no en la que terminó ayer (CI002)');
select throws_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e4'), pg_temp.u('b7')),
                 'CI002', null, 'sesión en UTC+14: no en la que empieza mañana (CI002)');
select pg_temp.como('Etc/GMT+12', 'a1');
select lives_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e1'), pg_temp.u('b7')),
                'sesión en UTC-12: se inscribe en la campaña que termina hoy');
select lives_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e3'), pg_temp.u('b8')),
                'sesión en UTC-12: se inscribe en la campaña que empieza hoy');
select throws_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e2'), pg_temp.u('b5')),
                 'CI002', null, 'sesión en UTC-12: no en la que terminó ayer (CI002)');
select throws_ok(format('select public.inscribir_colportor(%L, %L)', pg_temp.u('e4'), pg_temp.u('b5')),
                 'CI002', null, 'sesión en UTC-12: no en la que empieza mañana (CI002)');

select * from finish();
rollback;
