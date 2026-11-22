-- pgTAP · las horas, las ventas y el tablero de Inicio dejan afuera lo que se hizo en un hueco de la inscripción
-- (migración 0197, backend-supabase#162, seguimiento de #140 y #141)
--
-- horas_por_ciudad_y_colportor (0060/0106), ventas_por_ciudad_y_colportor (0061/0106) y tablero_de_inicio (0055/0106)
-- cuentan lo que `inscripcion_cubre_el_instante()` (0100) deja dentro: desde el INSTANTE del alta, antes de la baja y
-- fuera de los huecos (`tramos_afuera`). Casos: a Diego lo dan de baja, trabaja 20 días afuera y vuelve (el hueco no
-- cuenta y lo de antes y de después sí); una venta del día del alta pero antes de la hora del alta; un hueco que cubre
-- solo parte de un día; el límite del hueco (se abre en su inicio, se cierra en su fin: [inicio, fin)); quien no tiene
-- zona no cae en «Sin zona asignada» por lo que hizo afuera; el tablero no lista a quien estuvo afuera el día entero.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- Los uuid de los personajes: a1 coordinador; b1..b4 colportores; e1 campaña; c1 ciudad; 71 campania_ciudad; d1 zona.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000197' || p_sufijo)::uuid
$$;

-- Un instante de un día de Montevideo.
create or replace function pg_temp.a(p_dia date, p_hora time) returns timestamptz language sql immutable as $$
  select (p_dia + p_hora) at time zone 'America/Montevideo'
$$;

-- Horas: la fila de un período (mes) y un colportor, como texto horas|jornadas|dias|acompañadas ('sin fila' si no está).
create or replace function pg_temp.horas(p_agr text, p_inicio date, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s', r.horas, r.jornadas, r.dias_trabajados, r.jornadas_acompaniadas)
      from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), date '2026-09-01', date '2026-10-31', p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- Horas: cuántas filas con jornadas trae un colportor en todo el rango, y en qué ciudades (texto ordenado).
create or replace function pg_temp.horas_ciudades(p_colp text) returns text language sql as $$
  select coalesce(string_agg(coalesce(r.ciudad_nombre, '(sin ciudad)') || ':' || r.jornadas, ',' order by r.periodo_inicio), 'ninguna')
    from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), date '2026-09-01', date '2026-10-31', 'mes') r
   where r.colportor_id = pg_temp.u(p_colp) and r.jornadas > 0
$$;

-- Ventas: ventas|monto|presentaciones de un período y un colportor ('sin fila' si no está).
create or replace function pg_temp.ventas(p_agr text, p_inicio date, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s', r.ventas, r.monto_total, r.presentaciones)
      from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), date '2026-09-01', date '2026-10-31', p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

create or replace function pg_temp.ventas_ciudades(p_colp text) returns text language sql as $$
  select coalesce(string_agg(coalesce(r.ciudad_nombre, '(sin ciudad)') || ':' || r.ventas, ',' order by r.periodo_inicio), 'ninguna')
    from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), date '2026-09-01', date '2026-10-31', 'mes') r
   where r.colportor_id = pg_temp.u(p_colp) and (r.ventas > 0 or r.presentaciones > 0)
$$;

-- Tablero: el estado|horas|presentaciones|ventas|monto de un colportor dentro de su ciudad ('sin fila' si no está).
create or replace function pg_temp.tablero(p_fecha date, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s', c.value ->> 'estado', trim_scale((c.value ->> 'horas')::numeric),
                  c.value ->> 'presentaciones', c.value ->> 'ventas', c.value ->> 'monto_total')
      from (select public.tablero_de_inicio(pg_temp.u('e1'), p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'ciudades') ciu(value),
           jsonb_array_elements(ciu.value -> 'colportores') c(value)
     where (c.value ->> 'colportor_id')::uuid = pg_temp.u(p_colp)), 'sin fila')
$$;

-- Tablero: el estado de un colportor en «sin_zona» ('no está' si no figura).
create or replace function pg_temp.tablero_sin_zona(p_fecha date, p_colp text) returns text language sql as $$
  select coalesce((
    select s.value ->> 'estado'
      from (select public.tablero_de_inicio(pg_temp.u('e1'), p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'sin_zona') s(value)
     where (s.value ->> 'colportor_id')::uuid = pg_temp.u(p_colp)), 'no está')
$$;

-- --- fixtures ------------------------------------------------------------------
-- Colportores: b1 Diego (zona Centro; lo dan de baja el 10/09 y vuelve el 30/09: hueco [10/09 00:00, 30/09 00:00))
--        b2 Alta (se inscribió el 07/09 a las 14:00)
--        b3 Joaquín (sin zona; el mismo hueco que Diego)
--        b4 Parcial (zona Centro; un hueco de 24 h que cubre solo parte de dos días: [16/09 12:00, 17/09 12:00))
-- Campaña e1 (desde el 03/08/2026, sin fin, coordinada por a1), ciudad c1, campania_ciudad 71, zona d1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'huecos-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Diego','Duarte'), ('b2','Alta','Beltran'), ('b3','Joaquin','Cabrera'), ('b4','Parcial','Duran')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais huecos', 'ZH');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial)
values (pg_temp.u('c1'), 'Ciudad uno q197', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id)
values (pg_temp.u('e1'), 'Huecos', 'VERANO', '2026-08-03', null, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-09-07 14:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null,            '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1'), '2026-08-01 12:00-03');
-- Los huecos, como los deja la baja y la vuelta (0100): lo escribe el servidor.
update public.campania_colportor
   set tramos_afuera = array[tstzrange(pg_temp.a(date '2026-09-10', '00:00'), pg_temp.a(date '2026-09-30', '00:00'), '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id in (pg_temp.u('b1'), pg_temp.u('b3'));
update public.campania_colportor
   set tramos_afuera = array[tstzrange(pg_temp.a(date '2026-09-16', '12:00'), pg_temp.a(date '2026-09-17', '12:00'), '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
-- El historial de zonas (0022) abre el tramo con la hora real de la inserción: en este fixture la zona es de siempre.
update public.campania_colportor_zona_historial h set desde = i.created_at
  from public.campania_colportor i where i.id = h.campania_colportor_id;

-- Donde cuelgan las visitas y las ventas (las FK lo piden; las funciones no las miran).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

-- Jornadas (horas de Montevideo).
--   b1: 09/09 09:00-11:00 (2 h, antes del hueco: cuenta); 10/09 00:00-01:00 (empieza justo en el inicio del hueco:
--       no); 15/09 09:00-12:00 (dentro: no; con acompañante); 29/09 23:59-00:30 (empieza adentro: no);
--       30/09 00:00-02:00 (empieza justo en el fin del hueco: cuenta, con acompañante); 01/10 09:00-10:00 (cuenta).
--   b2: 07/09 09:00-12:00 (antes de la hora del alta: no); 14:00-14:30 (justo en el alta: cuenta); 15:00-17:00 (cuenta).
--   b3 (sin zona): 09/09 09:00-10:00 (cuenta, «sin ciudad»); 15/09 09:00-12:00 (dentro del hueco: no).
--   b4: 16/09 09:00-11:00 (antes del hueco: cuenta) y 14:00-15:00 (adentro: no); 17/09 09:00-10:00 (adentro: no) y
--       12:00-13:00 (justo en el fin: cuenta).
insert into public.jornada (colportor_id, inicio, fin, acompaniante_id)
select pg_temp.u(x.s), x.i::timestamptz, x.f::timestamptz, case when x.acomp then pg_temp.u('a1') end
  from (values
    ('b1', '2026-09-09 09:00-03', '2026-09-09 11:00-03', false),
    ('b1', '2026-09-10 00:00-03', '2026-09-10 01:00-03', false),
    ('b1', '2026-09-15 09:00-03', '2026-09-15 12:00-03', true),
    ('b1', '2026-09-29 23:59-03', '2026-09-30 00:30-03', false),
    ('b1', '2026-09-30 00:00-03', '2026-09-30 02:00-03', true),
    ('b1', '2026-10-01 09:00-03', '2026-10-01 10:00-03', false),
    ('b2', '2026-09-07 09:00-03', '2026-09-07 12:00-03', false),
    ('b2', '2026-09-07 14:00-03', '2026-09-07 14:30-03', false),
    ('b2', '2026-09-07 15:00-03', '2026-09-07 17:00-03', false),
    ('b3', '2026-09-09 09:00-03', '2026-09-09 10:00-03', false),
    ('b3', '2026-09-15 09:00-03', '2026-09-15 12:00-03', false),
    ('b4', '2026-09-16 09:00-03', '2026-09-16 11:00-03', false),
    ('b4', '2026-09-16 14:00-03', '2026-09-16 15:00-03', false),
    ('b4', '2026-09-17 09:00-03', '2026-09-17 10:00-03', false),
    ('b4', '2026-09-17 12:00-03', '2026-09-17 13:00-03', false)
  ) x(s, i, f, acomp);

-- Ventas (monto en centavos).
--   b1: 09/09 10:00 (100: cuenta); 15/09 11:00 (200: dentro, no); 30/09 00:00 (400: en el fin del hueco, cuenta);
--       01/10 12:00 (800: cuenta).
--   b2: 07/09 10:00 (1000: el día del alta pero antes de la hora, no); 14:00:00 (2000: justo en el alta, cuenta);
--       16:00 (4000: cuenta).
--   b3 (sin zona): 15/09 (8000: dentro, no); 09/09 (16000: cuenta, «sin ciudad»).
--   b4: 16/09 10:00 (32: cuenta); 13:00 (64: dentro, no); 17/09 11:00 (128: dentro, no); 12:00 (256: cuenta).
insert into public.venta (espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
select pg_temp.u('f3'), 'H-' || row_number() over (), x.m, x.f::timestamptz, pg_temp.u(x.s)
  from (values
    ('b1', 100,   '2026-09-09 10:00-03'), ('b1', 200,  '2026-09-15 11:00-03'),
    ('b1', 400,   '2026-09-30 00:00-03'), ('b1', 800,  '2026-10-01 12:00-03'),
    ('b2', 1000,  '2026-09-07 10:00-03'), ('b2', 2000, '2026-09-07 14:00:00-03'), ('b2', 4000, '2026-09-07 16:00-03'),
    ('b3', 8000,  '2026-09-15 10:00-03'), ('b3', 16000, '2026-09-09 10:00-03'),
    ('b4', 32,    '2026-09-16 10:00-03'), ('b4', 64,   '2026-09-16 13:00-03'),
    ('b4', 128,   '2026-09-17 11:00-03'), ('b4', 256,  '2026-09-17 12:00-03')
  ) x(s, m, f);

-- Presentaciones (visitas VENTA o ENTREVISTA).
--   b1: 09/09 10:30 (cuenta), 15/09 10:30 (dentro, no).   b4: 16/09 09:30 (cuenta), 16/09 14:30 (dentro, no).
insert into public.visita (espacio_persona_id, fecha, tipo_resultado, colportor_id)
select pg_temp.u('f3'), x.f::timestamptz, 'ENTREVISTA', pg_temp.u(x.s)
  from (values ('b1', '2026-09-09 10:30-03'), ('b1', '2026-09-15 10:30-03'),
               ('b4', '2026-09-16 09:30-03'), ('b4', '2026-09-16 14:30-03')) x(s, f);

select pg_temp.actuar_como(pg_temp.u('a1'));

-- --- 1. Horas ---------------------------------------------------------------------
-- Diego: setiembre trae las dos jornadas de fuera del hueco (09/09 y 30/09 00:00, que es el fin del hueco, abierto); octubre, la suya.
select is(pg_temp.horas('mes', '2026-09-01', 'b1'), '4.00|2|2|1',
          'horas, Diego en setiembre: la del 09/09 y la del 30/09 en el fin del hueco; ni la del inicio del hueco, ni la de adentro, ni la que empezó adentro');
select is(pg_temp.horas('mes', '2026-10-01', 'b1'), '1.00|1|1|0', 'horas, Diego en octubre: la de después de la vuelta cuenta');
select is(pg_temp.horas('dia', '2026-09-15', 'b1'), 'sin fila', 'horas por día: el 15/09 dentro del hueco no trae fila');
select is((select r.jornadas from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), date '2026-09-10', date '2026-09-10', 'dia') r
            where r.colportor_id = pg_temp.u('b1')), 0,
          'horas por día: el 10/09 (la jornada de las 00:00, en el inicio del hueco) no suma: 0 jornadas');
select is(pg_temp.horas('dia', '2026-09-30', 'b1'), '2.00|1|1|1', 'horas por día: el 30/09 (fin del hueco) cuenta, con su acompañamiento');
select is(pg_temp.horas('semana', '2026-09-14', 'b1'), '0.00|0|0|0', 'horas por semana: la semana del 14 al 20/09 entera dentro del hueco no suma nada (0 jornadas; solo queda la fila de la comparación)');
select is(pg_temp.horas_ciudades('b1'), 'Ciudad uno q197:2,Ciudad uno q197:1', 'horas: Diego sale solo en su ciudad, en dos meses');

-- El día del alta, desde la hora del alta (decisión del 27/10): la de las 14:00 en punto y la de las 15:00 cuentan; la de las 09:00 no.
select is(pg_temp.horas('mes', '2026-09-01', 'b2'), '2.50|2|1|0', 'horas, el día del alta: desde el instante (14:00 en punto cuenta, 09:00 no)');

-- Joaquín (sin zona): lo de antes del hueco va a «sin ciudad»; lo del hueco no cae en «Sin zona asignada».
select is(pg_temp.horas_ciudades('b3'), '(sin ciudad):1', 'horas, Joaquín sin zona: una sola jornada en «sin ciudad»; la del hueco no suma');
select is(pg_temp.horas('mes', '2026-09-01', 'b3'), '1.00|1|1|0', 'horas, Joaquín: 1 h en total');

-- Parcial: un hueco que cubre parte de dos días descuenta solo lo de adentro.
select is(pg_temp.horas('dia', '2026-09-16', 'b4'), '2.00|1|1|0', 'horas, hueco a media jornada (16/09): la de la mañana cuenta, la de la tarde no');
select is(pg_temp.horas('dia', '2026-09-17', 'b4'), '1.00|1|1|0', 'horas, hueco a media jornada (17/09): la de las 09:00 no, la de las 12:00 (fin del hueco) sí');

-- --- 2. Ventas ----------------------------------------------------------------------
select is(pg_temp.ventas('mes', '2026-09-01', 'b1'), '2|500|1', 'ventas, Diego en setiembre: 100 + 400 (fin del hueco), 1 presentación; la de adentro no');
select is(pg_temp.ventas('mes', '2026-10-01', 'b1'), '1|800|0', 'ventas, Diego en octubre: lo de después de la vuelta cuenta');
select is(pg_temp.ventas('dia', '2026-09-15', 'b1'), 'sin fila', 'ventas por día: el 15/09 dentro del hueco no trae fila (ni venta ni presentación)');
select is(pg_temp.ventas_ciudades('b1'), 'Ciudad uno q197:2,Ciudad uno q197:1', 'ventas: Diego sale solo en su ciudad');
select is(pg_temp.ventas('mes', '2026-09-01', 'b2'), '2|6000|0',
          'ventas, el día del alta: la de las 10:00 (antes de la hora del alta) no; la de las 14:00:00 y la de las 16:00 sí');
select is(pg_temp.ventas('mes', '2026-09-01', 'b3'), '1|16000|0', 'ventas, Joaquín: solo la de antes del hueco');
select is(pg_temp.ventas_ciudades('b3'), '(sin ciudad):1', 'ventas: lo del hueco no cae en «sin ciudad»; solo lo de antes');
select is(pg_temp.ventas('mes', '2026-09-01', 'b4'), '2|288|1', 'ventas, hueco parcial: 32 + 256; la de 13:00 y la de 17/09 11:00 no; 1 presentación (la de la mañana)');

-- --- 3. Tablero de Inicio -----------------------------------------------------------
-- Un día antes del hueco: todo cuenta.
select is(pg_temp.tablero(date '2026-09-09', 'b1'), 'FINALIZADA|2|1|1|100', 'tablero 09/09: Diego, antes del hueco, con todo lo suyo');
select is(pg_temp.tablero_sin_zona(date '2026-09-09', 'b3'), 'FINALIZADA', 'tablero 09/09: Joaquín figura en «sin zona» con su jornada');
-- Días enteros dentro del hueco: no figuran.
select is(pg_temp.tablero(date '2026-09-10', 'b1'), 'sin fila', 'tablero 10/09: el hueco cubre el día entero (empieza a las 00:00): Diego no figura');
select is(pg_temp.tablero(date '2026-09-15', 'b1'), 'sin fila', 'tablero 15/09: dentro del hueco: Diego no figura en ninguna ciudad');
select is(pg_temp.tablero_sin_zona(date '2026-09-15', 'b3'), 'no está', 'tablero 15/09: Joaquín no cae en «sin zona asignada»');
select is(pg_temp.tablero(date '2026-09-29', 'b1'), 'sin fila', 'tablero 29/09: último día entero del hueco');
-- El día que vuelve: el hueco termina a las 00:00 y el día cuenta entero.
select is(pg_temp.tablero(date '2026-09-30', 'b1'), 'FINALIZADA|2|0|1|400', 'tablero 30/09: el hueco termina a las 00:00: la jornada y la venta de las 00:00 cuentan');
-- El día del alta, desde la hora del alta.
select is(pg_temp.tablero(date '2026-09-07', 'b2'), 'FINALIZADA|2.5|0|2|6000', 'tablero 07/09: el día del alta, desde las 14:00 (horas 2,5; ventas 2000 + 4000)');
-- Hueco a media jornada: el colportor figura y solo cuenta lo de afuera del hueco.
select is(pg_temp.tablero(date '2026-09-16', 'b4'), 'FINALIZADA|2|1|1|32', 'tablero 16/09: el hueco empieza a las 12:00: cuenta la mañana, no la tarde');
select is(pg_temp.tablero(date '2026-09-17', 'b4'), 'FINALIZADA|1|0|1|256', 'tablero 17/09: el hueco termina a las 12:00: cuenta desde las 12:00');
select is(pg_temp.tablero(date '2026-09-15', 'b4'), 'SIN_INICIAR|0|0|0|0', 'tablero 15/09: antes del hueco de Parcial, sin nada, figura');

-- --- 4. Lo que no cambia ----------------------------------------------------------------
select is((select count(*)::integer from pg_proc p where p.pronamespace = 'public'::regnamespace
              and p.proname in ('horas_por_ciudad_y_colportor', 'ventas_por_ciudad_y_colportor', 'tablero_de_inicio')
              and p.prosecdef and p.provolatile = 'v' and p.proconfig = array['search_path=""']), 3,
          'las tres siguen siendo DEFINER, volatile y con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute')
          and has_function_privilege('authenticated', 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute')
          and has_function_privilege('authenticated', 'public.tablero_de_inicio(uuid,date)', 'execute'),
          'authenticated las sigue ejecutando');
select ok(not has_function_privilege('anon', 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute')
          and not has_function_privilege('anon', 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute')
          and not has_function_privilege('anon', 'public.tablero_de_inicio(uuid,date)', 'execute'),
          'anon no ejecuta ninguna');

select * from finish();
rollback;
