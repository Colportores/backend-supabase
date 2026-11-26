-- pgTAP · la campaña de destino cuenta desde la baja de la otra, el mismo día
-- (migración 0205, backend-supabase#313, «Salto cuenta desde la baja»; decisión de Cristian del 24/11)
--
-- bb trabaja el 15/09 en Montevideo (e1), la dan de baja de Montevideo a las 09:00 y la inscriben en Salto (e2) a las 09:30.
-- Montevideo cuenta lo que empezó antes de las 09:00 y Salto lo que empezó desde las 09:00 (la hora de la baja): cada
-- jornada, venta y presentación cae en una sola campaña, nada queda afuera y la suma es lo que bb hizo ese día.
-- Controles: una baja de otro día no mueve el alta; una baja posterior al alta tampoco; lo hecho entre la baja y el alta sale
-- con la zona del alta (no en «Sin zona asignada»); el tablero de Salto del día cuenta lo mismo.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- a1 coordinador de las dos campañas; b1 bb (salta el 15/09), b2 (la baja y el alta son de días distintos),
-- b3 (la baja es posterior al alta); e1 Montevideo, e2 Salto; c1, c2 ciudades; 71, 72 campania_ciudad; d1, d2 zonas.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000205' || p_sufijo)::uuid
$$;

create or replace function pg_temp.a(p_dia date, p_hora time) returns timestamptz language sql immutable as $$
  select (p_dia + p_hora) at time zone 'America/Montevideo'
$$;

-- horas|jornadas de un colportor en una campaña, todo el rango, todas las ciudades ('sin fila' si no hay).
create or replace function pg_temp.horas(p_camp text, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s', sum(r.horas), sum(r.jornadas))
      from public.horas_por_ciudad_y_colportor(pg_temp.u(p_camp), date '2026-09-01', date '2026-09-30', 'mes') r
     where r.colportor_id = pg_temp.u(p_colp) and r.jornadas > 0
    having count(*) > 0), 'sin fila')
$$;

-- Las ciudades en que salen las horas de un colportor en una campaña (texto ordenado).
create or replace function pg_temp.horas_ciudades(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(coalesce(r.ciudad_nombre, '(sin ciudad)') || ':' || r.jornadas, ',' order by r.ciudad_nombre), 'ninguna')
    from public.horas_por_ciudad_y_colportor(pg_temp.u(p_camp), date '2026-09-01', date '2026-09-30', 'mes') r
   where r.colportor_id = pg_temp.u(p_colp) and r.jornadas > 0
$$;

-- ventas|monto|presentaciones de un colportor en una campaña, todo el rango.
create or replace function pg_temp.ventas(p_camp text, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s', sum(r.ventas), sum(r.monto_total), sum(r.presentaciones))
      from public.ventas_por_ciudad_y_colportor(pg_temp.u(p_camp), date '2026-09-01', date '2026-09-30', 'mes') r
     where r.colportor_id = pg_temp.u(p_colp) and (r.ventas > 0 or r.presentaciones > 0)
    having count(*) > 0), 'sin fila')
$$;

create or replace function pg_temp.ventas_ciudades(p_camp text, p_colp text) returns text language sql as $$
  select coalesce(string_agg(coalesce(r.ciudad_nombre, '(sin ciudad)') || ':' || r.ventas, ',' order by r.ciudad_nombre), 'ninguna')
    from public.ventas_por_ciudad_y_colportor(pg_temp.u(p_camp), date '2026-09-01', date '2026-09-30', 'mes') r
   where r.colportor_id = pg_temp.u(p_colp) and (r.ventas > 0 or r.presentaciones > 0)
$$;

-- Tablero: estado|horas|presentaciones|ventas|monto de un colportor, en su ciudad o en sin_zona ('sin fila' si no figura).
create or replace function pg_temp.tablero(p_camp text, p_fecha date, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s', c.value ->> 'estado', trim_scale((c.value ->> 'horas')::numeric),
                  c.value ->> 'presentaciones', c.value ->> 'ventas', c.value ->> 'monto_total')
      from (select public.tablero_de_inicio(pg_temp.u(p_camp), p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'ciudades') ciu(value),
           jsonb_array_elements(ciu.value -> 'colportores') c(value)
     where (c.value ->> 'colportor_id')::uuid = pg_temp.u(p_colp)), 'sin fila')
$$;

-- --- fixtures ------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'salto-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','b4','b5']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Bea','Benitez'), ('b2','Bruno','Bonilla'), ('b3','Beto','Bravo'), ('b4','Berta','Baez'), ('b5','Boris','Bentos')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais salto', 'ZS');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Montevideo q205', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Salto q205',      'Departamento de prueba', pg_temp.u('c0'), -31.39, -57.96, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Montevideo', 'VERANO', '2026-08-03', null, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Salto',      'VERANO', '2026-08-03', null, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costanera', pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-57.97,-31.40],[-57.95,-31.40],[-57.95,-31.38],[-57.97,-31.38],[-57.97,-31.40]]]}'::jsonb);

-- Las inscripciones. bb: Montevideo desde agosto, la baja el 15/09 a las 09:00 y Salto el 15/09 a las 09:30.
--   b2: Montevideo, baja el 15/09 a las 09:00; Salto el 16/09 a las 09:30 (otro día).
--   b3: Salto el 15/09 a las 09:30 y Montevideo con la baja el 15/09 a las 10:00 (posterior al alta de Salto).
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('91'), pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('92'), pg_temp.u('e2'), pg_temp.u('b1'), pg_temp.u('d2'), '2026-09-15 09:30-03'),
  (pg_temp.u('93'), pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('94'), pg_temp.u('e2'), pg_temp.u('b2'), pg_temp.u('d2'), '2026-09-16 09:30-03'),
  (pg_temp.u('95'), pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('96'), pg_temp.u('e2'), pg_temp.u('b3'), pg_temp.u('d2'), '2026-09-15 09:30-03');
update public.campania_colportor set deleted_at = pg_temp.a(date '2026-09-15', '09:00')
 where id in (pg_temp.u('91'), pg_temp.u('93'));
-- b4 vuelve a una campaña donde ya había estado (reinscripción): estuvo en Salto del 01/08 al 10/08, pasó a Montevideo, la dan
-- de baja de Montevideo el 15/09 a las 09:00 y a las 09:30 la reactivan en Salto (el hueco [10/08, 15/09 09:30) lo escribe el servidor, 0100).
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at, tramos_afuera) values
  (pg_temp.u('97'), pg_temp.u('e2'), pg_temp.u('b4'), pg_temp.u('d2'), '2026-08-01 12:00-03',
   array[tstzrange(pg_temp.a(date '2026-08-10', '00:00'), pg_temp.a(date '2026-09-15', '09:30'), '[)')]),
  (pg_temp.u('98'), pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1'), '2026-08-11 12:00-03', '{}');
update public.campania_colportor set deleted_at = pg_temp.a(date '2026-09-15', '09:00') where id = pg_temp.u('98');
-- b5: la baja de Montevideo el 15/09 a las 09:00 y el alta en Salto a las 09:30; el 22/09 vuelve a Montevideo (baja de Salto a las
-- 09:55 y reactivación de Montevideo a las 10:00: la baja del 15/09 queda como hueco [15/09 09:00, 22/09 10:00)).
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at, tramos_afuera) values
  (pg_temp.u('99'), pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d1'), '2026-08-01 12:00-03',
   array[tstzrange(pg_temp.a(date '2026-09-15', '09:00'), pg_temp.a(date '2026-09-22', '10:00'), '[)')]),
  (pg_temp.u('9a'), pg_temp.u('e2'), pg_temp.u('b5'), pg_temp.u('d2'), '2026-09-15 09:30-03', '{}');
update public.campania_colportor set deleted_at = pg_temp.a(date '2026-09-22', '09:55') where id = pg_temp.u('9a');
update public.campania_colportor set deleted_at = pg_temp.a(date '2026-09-15', '10:00')
 where id = pg_temp.u('95');
-- El historial de zonas (0022) abre el tramo con la hora real de la inserción: en este fixture es la del alta.
update public.campania_colportor_zona_historial h set desde = i.created_at
  from public.campania_colportor i where i.id = h.campania_colportor_id;

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

-- Jornadas del 15/09 de bb (horas de Montevideo): 06:00-08:00 y 08:30-08:45 (antes de la baja: Montevideo); 09:00-09:30
-- (empieza justo en la baja: Salto); 09:10-10:10 (entre la baja y el alta: Salto); 11:00-12:00 (después del alta: Salto).
--   b2: 15/09 09:10-10:10 (entre la baja y... un día antes de su alta: no cuenta en Salto; tampoco en Montevideo) y
--       16/09 08:00-09:00 (antes de la hora del alta: no) y 10:00-11:00 (después: sí).
--   b3: 15/09 09:40-10:40 (las dos inscripciones vivas: la de Montevideo cuenta hasta las 10:00, la de Salto desde las 09:30).
insert into public.jornada (colportor_id, inicio, fin)
select pg_temp.u(x.s), x.i::timestamptz, x.f::timestamptz
  from (values
    ('b1', '2026-09-15 06:00-03', '2026-09-15 08:00-03'),
    ('b1', '2026-09-15 08:30-03', '2026-09-15 08:45-03'),
    ('b1', '2026-09-15 09:00-03', '2026-09-15 09:30-03'),
    ('b1', '2026-09-15 09:10-03', '2026-09-15 10:10-03'),
    ('b1', '2026-09-15 11:00-03', '2026-09-15 12:00-03'),
    ('b2', '2026-09-15 09:10-03', '2026-09-15 10:10-03'),
    ('b2', '2026-09-16 08:00-03', '2026-09-16 09:00-03'),
    ('b2', '2026-09-16 10:00-03', '2026-09-16 11:00-03'),
    ('b3', '2026-09-15 09:40-03', '2026-09-15 10:40-03'),
    ('b4', '2026-09-15 09:10-03', '2026-09-15 10:10-03'),
    ('b4', '2026-09-15 11:00-03', '2026-09-15 12:00-03'),
    ('b5', '2026-09-15 09:10-03', '2026-09-15 10:10-03')
  ) x(s, i, f);

-- Ventas de bb (centavos): 07:00 (100: Montevideo), 09:15 (200: Salto), 12:00 (400: Salto).
insert into public.venta (espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
select pg_temp.u('f3'), 'S-' || row_number() over (), x.m, x.f::timestamptz, pg_temp.u(x.s)
  from (values ('b1', 100, '2026-09-15 07:00-03'), ('b1', 200, '2026-09-15 09:15-03'), ('b1', 400, '2026-09-15 12:00-03')) x(s, m, f);

-- Presentaciones de bb: 08:20 (Montevideo) y 09:20 (Salto).
insert into public.visita (espacio_persona_id, fecha, tipo_resultado, colportor_id)
select pg_temp.u('f3'), x.f::timestamptz, 'ENTREVISTA', pg_temp.u(x.s)
  from (values ('b1', '2026-09-15 08:20-03'), ('b1', '2026-09-15 09:20-03')) x(s, f);

-- --- 0. La hora desde la que cuenta cada inscripción ----------------------------------
select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('92')) v), pg_temp.a(date '2026-09-15', '09:00'),
          'bb en Salto: cuenta desde la hora de su baja de Montevideo (09:00), no desde las 09:30');
select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('91')) v), '2026-08-01 12:00-03'::timestamptz,
          'bb en Montevideo (de donde la dieron de baja): sigue contando desde su alta');
select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('94')) v), '2026-09-16 09:30-03'::timestamptz,
          'una baja de otro día no mueve el alta: b2 en Salto cuenta desde las 09:30 del 16/09');
select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('96')) v), '2026-09-15 09:30-03'::timestamptz,
          'una baja posterior al alta (10:00 contra 09:30) no la mueve: las dos inscripciones estaban vivas');
select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('ff')) v), null,
          'una inscripción que no existe da null');

select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('97')) v), '2026-08-01 12:00-03'::timestamptz,
          'una reinscripción: el alta sigue siendo la original');
select is((select v.afuera from public.ventana_de_la_inscripcion(pg_temp.u('97')) v),
          array[tstzrange(pg_temp.a(date '2026-08-10', '00:00'), pg_temp.a(date '2026-09-15', '09:00'), '[)')],
          'pero su último hueco se acorta hasta la baja de Montevideo (09:00) en lugar de la vuelta (09:30)');
select is((select v.afuera from public.ventana_de_la_inscripcion(pg_temp.u('99')) v),
          array[tstzrange(pg_temp.a(date '2026-09-15', '09:00'), pg_temp.a(date '2026-09-22', '09:55'), '[)')],
          'Montevideo reactivada el 22/09 a las 10:00: su hueco se acorta hasta la baja de Salto de las 09:55 (la ida y la vuelta son el mismo salto, cada una a su lado)');
select is((select v.alta from public.ventana_de_la_inscripcion(pg_temp.u('9a')) v), pg_temp.a(date '2026-09-15', '09:00'),
          'y Salto sigue contando desde la salida de Montevideo aunque esa baja ya sea un hueco (la reactivación no lo borra para atrás)');

select pg_temp.actuar_como(pg_temp.u('a1'));

-- --- 1. Horas ---------------------------------------------------------------------
select is(pg_temp.horas('e1', 'b1'), '2.25|2', 'horas, bb en Montevideo: las dos que empezaron antes de la baja (2 h y 15 min)');
select is(pg_temp.horas('e2', 'b1'), '2.50|3', 'horas, bb en Salto: la que empezó en la baja, la de entre la baja y el alta y la de después (30 min + 1 h + 1 h)');
select is(pg_temp.horas_ciudades('e2', 'b1'), 'Salto q205:3', 'horas, bb en Salto: las tres salen en Salto, con la zona del alta (ninguna en «Sin zona asignada»)');
select is(pg_temp.horas_ciudades('e1', 'b1'), 'Montevideo q205:2', 'horas, bb en Montevideo: sale en su ciudad');
select is((select sum(r.jornadas)::int from (
             select r.jornadas from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), date '2026-09-15', date '2026-09-15', 'dia') r where r.colportor_id = pg_temp.u('b1')
             union all
             select r.jornadas from public.horas_por_ciudad_y_colportor(pg_temp.u('e2'), date '2026-09-15', date '2026-09-15', 'dia') r where r.colportor_id = pg_temp.u('b1')) r),
          5, 'las cinco jornadas de bb suman 5 entre las dos campañas: ninguna queda afuera y ninguna cuenta dos veces');

-- Una baja de otro día no mueve el alta: lo del 15/09 de b2 no cuenta en Salto (no estaba inscripta) ni en Montevideo (baja a las 09:00).
select is(pg_temp.horas('e1', 'b2'), 'sin fila', 'horas, b2 en Montevideo: la jornada de las 09:10 es posterior a su baja (09:00)');
select is(pg_temp.horas('e2', 'b2'), '1.00|1', 'horas, b2 en Salto: solo la de después del alta del 16/09 (la de las 08:00 es anterior a las 09:30 y la baja era de otro día)');
-- Las dos inscripciones vivas a la vez: cada una con lo suyo, como antes (Montevideo hasta las 10:00, Salto desde las 09:30).
select is(pg_temp.horas('e1', 'b3'), '1.00|1', 'horas, b3 en Montevideo: la jornada de las 09:40 empezó antes de su baja (10:00)');
select is(pg_temp.horas('e2', 'b3'), '1.00|1', 'horas, b3 en Salto: la jornada de las 09:40 es posterior a su alta (09:30): como antes de la 0205, una baja posterior al alta no la mueve');

-- Reinscripción (b4): la jornada de las 09:10 cuenta en Salto (no queda en el hueco de la vuelta) y no en Montevideo.
select is(pg_temp.horas('e1', 'b4'), 'sin fila', 'horas, b4 en Montevideo: ninguna (las dos empezaron después de su baja de las 09:00)');
select is(pg_temp.horas('e2', 'b4'), '2.00|2', 'horas, b4 en Salto (reinscripción): la de las 09:10 y la de las 11:00');
-- Origen reactivado más tarde (b5): lo que ya contaba en Salto sigue contando.
select is(pg_temp.horas('e1', 'b5'), 'sin fila', 'horas, b5 en Montevideo reactivada: la de las 09:10 es de su hueco, no cuenta');
select is(pg_temp.horas('e2', 'b5'), '1.00|1', 'horas, b5 en Salto: la de las 09:10 sigue contando después de que Montevideo se reactivó');

-- --- 2. Ventas y presentaciones ----------------------------------------------------
select is(pg_temp.ventas('e1', 'b1'), '1|100|1', 'ventas, bb en Montevideo: la de las 07:00 y la presentación de las 08:20');
select is(pg_temp.ventas('e2', 'b1'), '2|600|1', 'ventas, bb en Salto: la de las 09:15 (entre la baja y el alta) y la de las 12:00, y la presentación de las 09:20');
select is(pg_temp.ventas_ciudades('e2', 'b1'), 'Salto q205:2', 'ventas, bb en Salto: salen en Salto, con la zona del alta');

-- --- 3. Tablero ---------------------------------------------------------------------
-- Salto el 15/09: bb figura con las tres jornadas (2,5 h), 2 ventas ($ 6,00) y 1 presentación. Su estado es el de lo que cuenta.
select is(pg_temp.tablero('e2', date '2026-09-15', 'b1'), 'FINALIZADA|2.5|1|2|600',
          'tablero de Salto, 15/09: las horas, la presentación y las dos ventas de desde la baja');
select is(pg_temp.tablero('e1', date '2026-09-15', 'b1'), 'FINALIZADA|2.25|1|1|100',
          'tablero de Montevideo, 15/09: lo que bb hizo antes de la baja (2 h 15 min, la presentación de las 08:20 y la venta de las 07:00), sin lo de Salto');

select * from finish();
rollback;
