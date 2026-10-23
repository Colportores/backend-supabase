-- pgTAP · tablero de Inicio del panel (migraciones 0054 y 0055, backend-supabase#94, HU-CAM-008, vista 31)
-- tablero_de_inicio(): la forma de la respuesta (solo totales); el permiso primero (sin JWT, anon,
-- colportor, sin rol, rol vencido, coordinador de otra campaña) y que una campaña terminada se lee;
-- CZ001 y la fecha futura (22023); las cifras de hoy y de un día anterior por colportor, por ciudad y
-- en total (estado, horas, presentaciones, ventas, monto); la jornada abierta de hoy suma hasta ahora
-- y la de un día anterior no inventa un fin; qué visitas cuentan; el día de Montevideo (bordes de la
-- medianoche y una jornada que cruza); los bordes de la campaña; el colportor sin zona, con la zona o
-- su ciudad dadas de baja, de baja en la campaña o no inscripto; las ciudades sin colportores; el
-- último push; los pendientes vacíos; que la función no escribe nada.
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

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- El uuid de un personaje del test: a0..a4, ad, b1..b9, c1.., e1.., d1.., 71.., f1..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000060' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- Un instante de un día de Montevideo.
create or replace function pg_temp.a(p_dia date, p_hora time) returns timestamptz language sql immutable as $$
  select (p_dia + p_hora) at time zone 'America/Montevideo'
$$;

-- El tablero (como el coordinador o el admin que está actuando).
create or replace function pg_temp.tab(p_camp text, p_fecha date default null) returns jsonb language sql as $$
  select public.tablero_de_inicio(pg_temp.u(p_camp), p_fecha)
$$;

-- La fila de un colportor dentro de su ciudad, como texto:
-- estado|horas|presentaciones|ventas|monto_total|ciudad ('sin fila' si no está en ninguna ciudad).
create or replace function pg_temp.fila(p_camp text, p_fecha date, p_colp text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s|%s', c.value ->> 'estado', trim_scale((c.value ->> 'horas')::numeric),
                  c.value ->> 'presentaciones', c.value ->> 'ventas', c.value ->> 'monto_total',
                  ciu.value ->> 'nombre')
      from (select pg_temp.tab(p_camp, p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'ciudades') ciu(value),
           jsonb_array_elements(ciu.value -> 'colportores') c(value)
     where (c.value ->> 'colportor_id')::uuid = pg_temp.u(p_colp)), 'sin fila')
$$;

-- La fila de un colportor en «sin_zona»: estado ('no está' si no figura).
create or replace function pg_temp.sin_zona(p_camp text, p_fecha date, p_colp text) returns text language sql as $$
  select coalesce((
    select s.value ->> 'estado'
      from (select pg_temp.tab(p_camp, p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'sin_zona') s(value)
     where (s.value ->> 'colportor_id')::uuid = pg_temp.u(p_colp)), 'no está')
$$;

-- La bandera inscripcion_de_baja de un colportor de sin_zona ('no está' si no figura).
create or replace function pg_temp.sin_zona_baja(p_camp text, p_fecha date, p_colp text) returns text language sql as $$
  select coalesce((
    select s.value ->> 'inscripcion_de_baja'
      from (select pg_temp.tab(p_camp, p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'sin_zona') s(value)
     where (s.value ->> 'colportor_id')::uuid = pg_temp.u(p_colp)), 'no está')
$$;

-- Las cifras de una ciudad: cantidad|en_jornada|horas|presentaciones|ventas|monto_total|colportores
-- ('sin ciudad' si no figura).
create or replace function pg_temp.ciudad(p_camp text, p_fecha date, p_ciudad text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s|%s|%s', ciu.value ->> 'cantidad_colportores', ciu.value ->> 'en_jornada',
                  trim_scale((ciu.value ->> 'horas')::numeric), ciu.value ->> 'presentaciones',
                  ciu.value ->> 'ventas', ciu.value ->> 'monto_total',
                  jsonb_array_length(ciu.value -> 'colportores'))
      from (select pg_temp.tab(p_camp, p_fecha) as j) q,
           jsonb_array_elements(q.j -> 'ciudades') ciu(value)
     where (ciu.value ->> 'ciudad_id')::uuid = pg_temp.u(p_ciudad)), 'sin ciudad')
$$;

-- El total: cantidad|en_jornada|horas|presentaciones|ventas|monto_total.
create or replace function pg_temp.total(p_camp text, p_fecha date) returns text language sql as $$
  select format('%s|%s|%s|%s|%s|%s', q.j -> 'total' ->> 'cantidad_colportores', q.j -> 'total' ->> 'en_jornada',
                trim_scale((q.j -> 'total' ->> 'horas')::numeric), q.j -> 'total' ->> 'presentaciones',
                q.j -> 'total' ->> 'ventas', q.j -> 'total' ->> 'monto_total')
    from (select pg_temp.tab(p_camp, p_fecha) as j) q
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de En curso y Cierre; a2 coordinador de Otra; ad admin; a0 colportor;
--        a3 sin ningún rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Alfa (zona Centro, c1)  b2 Bravo (Centro, c1)  b3 Cruz (zona Costa, c2)
--        b4 Duarte (sin zona)  b5 Eguren (su zona se dio de baja)  b6 Fuentes (inscripción de baja)
--        b7 Gómez (NO inscripto)  b8 Haedo (la ciudad de su zona se dio de baja en la campaña)
--        bb Kappa (inscripción de baja ayer 12:00; su única jornada es de ayer 13:00)
--        bc Lara (sin zona; se inscribió hoy 00:00:00, justo después de que terminó ayer)
--        bd Mora (sin zona; se inscribió ayer 23:59:59, el último segundo de ayer)
--        b9 Ibarra (Costa, c2; sin nada)  ba Jara (Costa, c2; jornada abierta que empieza a las 23:59:59, en el futuro)
-- Campañas: e1 En curso (hoy - 30, sin fin, a1)  e2 Otra (a2)  e4 Borrada (a1)
--        e5 Cierre (03/08/2026 a 30/09/2026, terminada, a1)
-- Ciudades: c1 «Ciudad uno q94», c2 «Ciudad dos q94», c3 «Ciudad tres q94» (sin colportores),
--        c4 «Ciudad cuatro q94» (se da de baja en En curso).
-- campania_ciudad: 71 En curso/c1  72 En curso/c2  73 En curso/c3  74 En curso/c4 (baja)  75 Otra/c2  76 Cierre/c1
-- Zonas: d1 Centro (en 71)  d2 Costa (en 72)  d3 Baja (en 71, se da de baja)  d4 Fantasma (en 74)  d5 Cierre (en 76)
-- Donde se vende: ubicación f1, espacio f2, vínculo f3 (persona f4): todas las visitas y ventas cuelgan de ahí.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tablero-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba','bb','bc','bd']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Abel','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Aida','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo'), ('b9','Iris','Ibarra'),
               ('ba','Juan','Jara'), ('bb','Kari','Kappa'), ('bc','Luis','Lara'), ('bd','Mara','Mora')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais tablero', 'ZT');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q94',    pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Ciudad dos q94',    pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c3'), 'Ciudad tres q94',   pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c4'), 'Ciudad cuatro q94', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'En curso', 'VERANO', pg_temp.hoy() - 30, null,         pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otra',     'VERANO', '2026-08-03',       null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada',  'VERANO', '2026-08-03',       '2026-09-30', pg_temp.u('a1'), now()),
  (pg_temp.u('e5'), 'Cierre',   'VERANO', '2026-08-03',       '2026-09-30', pg_temp.u('a1'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('73'), pg_temp.u('e1'), pg_temp.u('c3')),
  (pg_temp.u('74'), pg_temp.u('e1'), pg_temp.u('c4')),
  (pg_temp.u('75'), pg_temp.u('e2'), pg_temp.u('c2')),
  (pg_temp.u('76'), pg_temp.u('e5'), pg_temp.u('c1'));

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro',   pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa',    pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb),
  (pg_temp.u('d3'), 'Baja',     pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.95],[-56.17,-34.95],[-56.17,-34.94],[-56.19,-34.94],[-56.19,-34.95]]]}'::jsonb),
  (pg_temp.u('d4'), 'Fantasma', pg_temp.u('74'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.98],[-56.17,-34.98],[-56.17,-34.97],[-56.19,-34.97],[-56.19,-34.98]]]}'::jsonb),
  (pg_temp.u('d5'), 'Cierre',   pg_temp.u('76'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-35.00],[-56.17,-35.00],[-56.17,-34.99],[-56.19,-34.99],[-56.19,-35.00]]]}'::jsonb);

-- Todas se inscribieron el 01/01/2026, salvo bc y bd (inscripciones de los bordes de ayer y hoy).
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d2'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null,            '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d3'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b6'), pg_temp.u('d1'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('bb'), pg_temp.u('d1'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b8'), pg_temp.u('d4'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('b9'), pg_temp.u('d2'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('ba'), pg_temp.u('d2'), '2026-01-01'),
  (pg_temp.u('e1'), pg_temp.u('bc'), null,            pg_temp.a(pg_temp.hoy(), '00:00:00')),
  (pg_temp.u('e1'), pg_temp.u('bd'), null,            pg_temp.a(pg_temp.hoy() - 1, '23:59:59')),
  (pg_temp.u('e5'), pg_temp.u('b1'), pg_temp.u('d5'), '2026-01-01'),
  (pg_temp.u('e5'), pg_temp.u('b2'), null,            '2026-01-01');
-- La zona de b5 se da de baja, la ciudad de la campaña de b8 también; las inscripciones de b6 y bb se dan
-- de baja ayer a las 12:00 (la baja de la inscripción la deja sin zona, 0009).
update public.zona set deleted_at = now() where id = pg_temp.u('d3');
update public.campania_ciudad set deleted_at = now() where id = pg_temp.u('74');
update public.campania_colportor set deleted_at = pg_temp.a(pg_temp.hoy() - 1, '12:00')
 where campania_id = pg_temp.u('e1') and usuario_id in (pg_temp.u('b6'), pg_temp.u('bb'));

-- Último push recibido: b1 hace 12 minutos, b2 hace 4 días, b4 (sin zona) hace 1 día; los demás, nunca (null).
update public.usuario set ultimo_push_at = now() - interval '12 minutes' where id = pg_temp.u('b1');
update public.usuario set ultimo_push_at = now() - interval '4 days'     where id = pg_temp.u('b2');
update public.usuario set ultimo_push_at = now() - interval '1 day'      where id = pg_temp.u('b4');

-- Donde cuelgan las visitas y las ventas (las FK lo piden; la función no las mira).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

-- Jornadas (horas de Montevideo; «hoy» y «ayer» relativos al día de Montevideo de ahora).
--   b1: hoy una ABIERTA desde las 00:00 y una cerrada de 00:00 a 01:30; ayer 10:00 a 13:00.
--   b2: hoy 00:00 a 02:00; ayer 23:00 a las 01:00 de hoy (cruza la medianoche: cuenta entera ayer).
--   b3: una ABIERTA desde ayer 22:00 (quedó abierta: nada de hoy).   b4 (sin zona): abierta hoy 00:00.
--   b6 (inscripción de baja ayer 12:00): ayer 09:00 a 11:00 (antes de la baja) y una cerrada hoy; bb (baja ayer 12:00):
--   solo ayer 13:00 a 14:00 (después de la baja); b7 (no inscripto): una cerrada hoy.
--   b2 también tiene ayer una ABIERTA desde las 08:00 (quedó sin cerrar: suma solo la cerrada).
--   ba: una ABIERTA que empieza hoy a las 23:59:59 (el reloj de su teléfono adelantado: suma 0 h, nunca negativas).
insert into public.jornada (colportor_id, inicio, fin)
select pg_temp.u(x.s), x.i, x.f
  from (values
    ('b1', pg_temp.a(pg_temp.hoy(), '00:00'),     null::timestamptz),
    ('b1', pg_temp.a(pg_temp.hoy(), '00:00'),     pg_temp.a(pg_temp.hoy(), '01:30')),
    ('b1', pg_temp.a(pg_temp.hoy() - 1, '10:00'), pg_temp.a(pg_temp.hoy() - 1, '13:00')),
    ('b2', pg_temp.a(pg_temp.hoy(), '00:00'),     pg_temp.a(pg_temp.hoy(), '02:00')),
    ('b2', pg_temp.a(pg_temp.hoy() - 1, '23:00'), pg_temp.a(pg_temp.hoy(), '01:00')),
    ('b3', pg_temp.a(pg_temp.hoy() - 1, '22:00'), null),
    ('b4', pg_temp.a(pg_temp.hoy(), '00:00'),     null),
    ('ba', pg_temp.a(pg_temp.hoy(), '23:59:59'),  null),
    ('b6', pg_temp.a(pg_temp.hoy(), '00:00'),     pg_temp.a(pg_temp.hoy(), '03:00')),
    ('b6', pg_temp.a(pg_temp.hoy() - 1, '09:00'), pg_temp.a(pg_temp.hoy() - 1, '11:00')),
    ('bb', pg_temp.a(pg_temp.hoy() - 1, '13:00'), pg_temp.a(pg_temp.hoy() - 1, '14:00')),
    ('b2', pg_temp.a(pg_temp.hoy() - 1, '08:00'), null),
    ('b7', pg_temp.a(pg_temp.hoy(), '00:00'),     pg_temp.a(pg_temp.hoy(), '03:00'))
  ) x(s, i, f);
-- Una jornada dada de baja de b2 hoy (no cuenta).
insert into public.jornada (colportor_id, inicio, fin, deleted_at)
values (pg_temp.u('b2'), pg_temp.a(pg_temp.hoy(), '05:00'), pg_temp.a(pg_temp.hoy(), '09:00'), now());

-- Ventas (monto en centavos).
--   b1: hoy 00:00:00 (2500) y 00:00:01 (500), una dada de baja (9999); ayer 12:00 (4000) y 23:59:59 (1000);
--       antes de ayer (77777); antes de que empiece la campaña (hoy - 31: 5555).
--   b2: hoy 10:00 (10000) y 11:00 (5000).   b3: hoy 09:00 (7000).
--   b4 (sin zona): hoy 99999.   b6 (de baja): hoy 3000.   b7 (no inscripto): hoy 99999.   b8: hoy 1234.
insert into public.venta (espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, deleted_at)
select pg_temp.u('f3'), 'T-' || row_number() over (), x.m, x.f, pg_temp.u(x.s), x.baja
  from (values
    ('b1', 2500,  pg_temp.a(pg_temp.hoy(), '00:00:00'),     null::timestamptz),
    ('b1', 500,   pg_temp.a(pg_temp.hoy(), '00:00:01'),     null),
    ('b1', 9999,  pg_temp.a(pg_temp.hoy(), '10:00'),        now()),
    ('b1', 4000,  pg_temp.a(pg_temp.hoy() - 1, '12:00'),    null),
    ('b1', 1000,  pg_temp.a(pg_temp.hoy() - 1, '23:59:59'), null),
    ('b1', 77777, pg_temp.a(pg_temp.hoy() - 2, '12:00'),    null),
    ('b1', 5555,  pg_temp.a(pg_temp.hoy() - 31, '12:00'),   null),
    ('b2', 10000, pg_temp.a(pg_temp.hoy(), '10:00'),        null),
    ('b2', 5000,  pg_temp.a(pg_temp.hoy(), '11:00'),        null),
    ('b3', 7000,  pg_temp.a(pg_temp.hoy(), '09:00'),        null),
    ('b4', 99999, pg_temp.a(pg_temp.hoy(), '09:00'),        null),
    ('b6', 3000,  pg_temp.a(pg_temp.hoy(), '09:00'),        null),
    ('b7', 99999, pg_temp.a(pg_temp.hoy(), '09:00'),        null),
    ('b8', 1234,  pg_temp.a(pg_temp.hoy(), '09:00'),        null)
  ) x(s, m, f, baja);

-- Visitas. Presentación = VENTA o ENTREVISTA; NO_CONTESTO y RECHAZO no cuentan.
--   b1: hoy 00:00:00 VENTA, 10:00 ENTREVISTA, 11:00 ENTREVISTA (3), 12:00 NO_CONTESTO, 13:00 RECHAZO,
--       14:00 ENTREVISTA dada de baja (no cuentan); ayer 15:00 VENTA y 23:59:59 ENTREVISTA (2).
--   b2: hoy 09:00 VENTA.   b4 (sin zona): hoy 3 ENTREVISTA.   b7 (no inscripto): hoy ENTREVISTA.
insert into public.visita (espacio_persona_id, fecha, tipo_resultado, colportor_id, deleted_at)
select pg_temp.u('f3'), x.f, x.t, pg_temp.u(x.s), x.baja
  from (values
    ('b1', pg_temp.a(pg_temp.hoy(), '00:00:00'),     'VENTA',       null::timestamptz),
    ('b1', pg_temp.a(pg_temp.hoy(), '10:00'),        'ENTREVISTA',  null),
    ('b1', pg_temp.a(pg_temp.hoy(), '11:00'),        'ENTREVISTA',  null),
    ('b1', pg_temp.a(pg_temp.hoy(), '12:00'),        'NO_CONTESTO', null),
    ('b1', pg_temp.a(pg_temp.hoy(), '13:00'),        'RECHAZO',     null),
    ('b1', pg_temp.a(pg_temp.hoy(), '14:00'),        'ENTREVISTA',  now()),
    ('b1', pg_temp.a(pg_temp.hoy() - 1, '15:00'),    'VENTA',       null),
    ('b1', pg_temp.a(pg_temp.hoy() - 1, '23:59:59'), 'ENTREVISTA',  null),
    ('b2', pg_temp.a(pg_temp.hoy(), '09:00'),        'VENTA',       null),
    ('b4', pg_temp.a(pg_temp.hoy(), '09:00'),        'ENTREVISTA',  null),
    ('b4', pg_temp.a(pg_temp.hoy(), '10:00'),        'ENTREVISTA',  null),
    ('b4', pg_temp.a(pg_temp.hoy(), '11:00'),        'ENTREVISTA',  null),
    ('b7', pg_temp.a(pg_temp.hoy(), '09:00'),        'ENTREVISTA',  null)
  ) x(s, f, t, baja);

-- Lo de Cierre (campaña terminada): b1 el 07/09 vende 6000 y trabaja de 10:00 a 12:30; los bordes de
-- la campaña: 03/08 00:00 (primer día, 1111) y 30/09 23:59 (último, 2222) cuentan; 02/08 23:59 (999)
-- y 01/10 00:00 (888) no.
insert into public.venta (espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
select pg_temp.u('f3'), 'C-' || row_number() over (), x.m, x.f::timestamptz, pg_temp.u('b1')
  from (values
    (6000, '2026-09-07 09:00-03'), (1111, '2026-08-03 00:00-03'), (2222, '2026-09-30 23:59-03'),
    (999,  '2026-08-02 23:59-03'), (888,  '2026-10-01 00:00-03')
  ) x(m, f);
-- Y una de 30 horas (08/09 00:00 al 09/09 06:00: el tope de 12 h es de la app, no de la nube): la cuenta es exacta.
insert into public.jornada (colportor_id, inicio, fin)
values (pg_temp.u('b1'), '2026-09-07 10:00-03', '2026-09-07 12:30-03'),
       (pg_temp.u('b1'), '2026-09-08 00:00-03', '2026-09-09 06:00-03');

-- ---------------------------------------------------------------------------
-- 1. La función: forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select array(select k from jsonb_object_keys(pg_temp.tab('e1')) k order by k collate "C")),
          array['calculado_a','ciudades','es_hoy','fecha','pendientes','sin_zona','total'],
          'la forma de la respuesta: las claves de primer nivel');
select is((select array(select k from jsonb_object_keys(pg_temp.tab('e1') -> 'total') k order by k collate "C")),
          array['cantidad_colportores','en_jornada','horas','monto_total','presentaciones','ventas'],
          'la forma del total');
select is((select array(select k from jsonb_object_keys(pg_temp.tab('e1') -> 'ciudades' -> 0) k order by k collate "C")),
          array['cantidad_colportores','ciudad_id','colportores','en_jornada','horas','monto_total','nombre',
                'presentaciones','ventas'],
          'la forma de una ciudad');
select is((select array(select k from jsonb_object_keys(pg_temp.tab('e1') -> 'ciudades' -> 0 -> 'colportores' -> 0) k order by k collate "C")),
          array['apellido','colportor_id','estado','horas','monto_total','nombre','presentaciones','ultimo_push_at','ventas'],
          'la forma de un colportor: solo cifras (sin clientes, ubicaciones, talonarios ni emails)');
select is((select array(select k from jsonb_object_keys(pg_temp.tab('e1') -> 'sin_zona' -> 0) k order by k collate "C")),
          array['apellido','colportor_id','estado','inscripcion_de_baja','inscripto_at','nombre','ultimo_push_at'],
          'la forma de un colportor sin zona: sin cifras');
select pg_temp.actuar_como_servidor();

select is((select p.prosecdef from pg_proc p where p.oid = 'public.tablero_de_inicio(uuid,date)'::regprocedure),
          true, 'es SECURITY DEFINER (el coordinador no lee jornada, visita ni venta ajenas)');
select is((select p.provolatile from pg_proc p where p.oid = 'public.tablero_de_inicio(uuid,date)'::regprocedure),
          'v', 'es VOLATILE (llama a lanzar_motivo_mapa())');
select is((select p.proconfig from pg_proc p where p.oid = 'public.tablero_de_inicio(uuid,date)'::regprocedure),
          array['search_path=""'], 'fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.tablero_de_inicio(uuid,date)', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.tablero_de_inicio(uuid,date)', 'execute'),
          'anon NO la ejecuta');
select ok(not has_function_privilege('service_role', 'public.tablero_de_inicio(uuid,date)', 'execute'),
          'service_role NO la ejecuta (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.tablero_de_inicio(uuid,date)'::regprocedure),
          0, 'no tiene EXECUTE para PUBLIC');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'tablero_de_inicio'),
          1, 'hay una sola firma');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'sin JWT (el servidor) falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'authenticated sin sesión falla');

select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como_servidor();

select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'un colportor no la llama');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'un colportor inscripto en la campaña tampoco ve el tablero');
-- El permiso va antes que la existencia y que los parámetros.
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060ff') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1', current_date + 5) $$,
  '42501', null, 'un colportor con una fecha futura: 42501, no 22023');

select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como(pg_temp.u('a4'));
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'con el rol de coordinador vencido falla');

select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', null, 'el coordinador de otra campaña no ve este tablero');
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver su tablero. Entrá con la cuenta del coordinador de esta campaña.',
  'el mensaje del 42501 dice quién puede');
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1', current_date + 5) $$,
  '42501', null, 'el de otra campaña con una fecha futura: 42501, no 22023');
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060ff') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- Los que sí pueden.
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1') $$,
  'el coordinador de la campaña la lee');
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e4') $$,
  'CZ001', null, 'una campaña dada de baja: CZ001');
select throws_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060ff') $$,
  'CZ001', null, 'una campaña inexistente: CZ001');
select pg_temp.actuar_como(pg_temp.u('ad'));
select lives_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e2') $$,
  'un administrador lee cualquier campaña');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. La fecha
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok(format($f$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1', %L::date) $f$, pg_temp.hoy() + 1),
  '22023', 'Ese día todavía no llegó. Elegí hoy o un día anterior.', 'mañana: 22023 con un mensaje que guía');
select throws_ok(format($f$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e1', %L::date) $f$, pg_temp.hoy() + 400),
  '22023', null, 'un día lejano del futuro: 22023');
select is(pg_temp.tab('e1') ->> 'fecha', pg_temp.hoy()::text, 'sin fecha: es hoy (Montevideo)');
select is((pg_temp.tab('e1') ->> 'es_hoy')::boolean, true, 'sin fecha: es_hoy');
select is(pg_temp.tab('e1', pg_temp.hoy()) ->> 'fecha', pg_temp.hoy()::text, 'con la fecha de hoy: la misma');
select is((pg_temp.tab('e1', pg_temp.hoy()) ->> 'es_hoy')::boolean, true, 'con la fecha de hoy: es_hoy');
select is(pg_temp.tab('e1', pg_temp.hoy() - 1) ->> 'fecha', (pg_temp.hoy() - 1)::text, 'ayer: la fecha pedida');
select is((pg_temp.tab('e1', pg_temp.hoy() - 1) ->> 'es_hoy')::boolean, false, 'ayer: no es_hoy');
select is((pg_temp.tab('e1') ->> 'calculado_a')::timestamptz, now(), 'calculado_a es el momento del cálculo');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Hoy: cada colportor
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
-- b1: una jornada abierta desde las 00:00 (suma hasta ahora) y una cerrada de 1,5 h; 3 presentaciones
-- (VENTA y 2 ENTREVISTA; NO_CONTESTO, RECHAZO y la dada de baja no cuentan); 2 ventas por 3000 (la dada
-- de baja, la de ayer y la de antes de la campaña no).
select is(pg_temp.fila('e1', null, 'b1'),
          'EN_JORNADA|'
          || trim_scale(round((5400 + extract(epoch from (now() - pg_temp.a(pg_temp.hoy(), '00:00'))))::numeric / 3600, 2))::text
          || '|3|2|3000|Ciudad uno q94',
          'b1 hoy: en jornada, la abierta suma hasta ahora, 3 presentaciones, 2 ventas');
-- b2: una jornada cerrada de 2 h (la dada de baja y la de ayer que cruza la medianoche no cuentan hoy).
select is(pg_temp.fila('e1', null, 'b2'), 'FINALIZADA|2|1|2|15000|Ciudad uno q94',
          'b2 hoy: finalizada, 2 h, 1 presentación, 2 ventas');
-- b3: la jornada abierta es de ayer: hoy no inició; la venta de hoy SÍ sale (la jornada no manda sobre las cifras).
select is(pg_temp.fila('e1', null, 'b3'), 'SIN_INICIAR|0|0|1|7000|Ciudad dos q94',
          'b3 hoy: sin iniciar (su jornada abierta es de ayer), con su venta');
select is(pg_temp.fila('e1', null, 'b9'), 'SIN_INICIAR|0|0|0|0|Ciudad dos q94',
          'b9 hoy: sin nada: sin iniciar y las cifras en cero (no null)');
-- ba: la abierta empieza en el futuro (reloj adelantado): en jornada, y las horas no salen negativas.
select is(pg_temp.fila('e1', null, 'ba'), 'EN_JORNADA|0|0|0|0|Ciudad dos q94',
          'ba hoy: en jornada con una jornada que empieza en el futuro: 0 h, no negativas');
-- Quién no figura en una ciudad.
select is(pg_temp.fila('e1', null, 'b4'), 'sin fila', 'b4 (sin zona) no está en ninguna ciudad');
select is(pg_temp.fila('e1', null, 'b5'), 'sin fila', 'b5 (zona dada de baja) no está en ninguna ciudad');
select is(pg_temp.fila('e1', null, 'b8'), 'sin fila', 'b8 (ciudad de campaña dada de baja) no está en ninguna ciudad');
select is(pg_temp.fila('e1', null, 'b6'), 'sin fila', 'b6 (inscripción de baja) no está en ninguna ciudad');
select is(pg_temp.fila('e1', null, 'b7'), 'sin fila', 'b7 (no inscripto) no está en ninguna ciudad');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Hoy: por ciudad y en total
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.ciudad('e1', null, 'c1'),
          '2|1|'
          || trim_scale(round((5400 + extract(epoch from (now() - pg_temp.a(pg_temp.hoy(), '00:00'))))::numeric / 3600, 2) + 2)::text
          || '|4|4|18000|2',
          'Ciudad uno: 2 colportores, 1 en jornada, la suma de sus horas, 4 presentaciones, 4 ventas, 18000');
select is(pg_temp.ciudad('e1', null, 'c2'), '3|1|0|0|1|7000|3',
          'Ciudad dos: 3 colportores, uno en jornada (ba), 1 venta por 7000');
select is(pg_temp.ciudad('e1', null, 'c3'), '0|0|0|0|0|0|0',
          'Ciudad tres no tiene colportores: figura igual, con ceros y la lista vacía');
select is(pg_temp.ciudad('e1', null, 'c4'), 'sin ciudad', 'la ciudad de la campaña dada de baja no figura');
select is(jsonb_array_length(pg_temp.tab('e1') -> 'ciudades'), 3, 'hay 3 ciudades (la dada de baja no)');
select is(pg_temp.ciudad('e1', null, 'c0'), 'sin ciudad', 'lo que no es una ciudad de la campaña no figura');
select is(pg_temp.total('e1', null),
          '5|2|'
          || trim_scale(round((5400 + extract(epoch from (now() - pg_temp.a(pg_temp.hoy(), '00:00'))))::numeric / 3600, 2) + 2)::text
          || '|4|5|25000',
          'el total: solo lo de las ciudades (5 colportores, 2 en jornada, 4 presentaciones, 5 ventas, 25000)');
-- Las ciudades salen por nombre y los colportores por apellido.
select is((select array_agg(ciu.value ->> 'nombre' order by ciu.ord)
             from jsonb_array_elements(pg_temp.tab('e1') -> 'ciudades') with ordinality ciu(value, ord)),
          array['Ciudad dos q94', 'Ciudad tres q94', 'Ciudad uno q94'], 'las ciudades por nombre');
select is((select array_agg(c.value ->> 'apellido' order by c.ord)
             from jsonb_array_elements(pg_temp.tab('e1') -> 'ciudades' -> 2 -> 'colportores') with ordinality c(value, ord)),
          array['Alfa', 'Bravo'], 'los colportores de una ciudad por apellido (no por nombre: Abel Bravo va después de Ana Alfa)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Los que no tienen zona: aparte, fuera de las cifras
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.sin_zona('e1', null, 'b4'), 'EN_JORNADA', 'b4 (sin zona) figura en sin_zona, con su estado');
select is(pg_temp.sin_zona('e1', null, 'b5'), 'SIN_INICIAR', 'b5 (zona dada de baja) figura en sin_zona');
select is(pg_temp.sin_zona('e1', null, 'b8'), 'SIN_INICIAR', 'b8 (ciudad de campaña dada de baja) figura en sin_zona');
select is(pg_temp.sin_zona('e1', null, 'b1'), 'no está', 'uno con zona no figura en sin_zona');
select is(pg_temp.sin_zona('e1', null, 'b6'), 'no está', 'b6 (inscripción dada de baja ayer) no figura hoy en sin_zona');
select is(pg_temp.sin_zona('e1', null, 'bb'), 'no está', 'bb (inscripción dada de baja ayer) tampoco');
select is(pg_temp.sin_zona('e1', null, 'bc'), 'SIN_INICIAR', 'bc (se inscribió hoy a las 00:00:00) figura hoy');
select is(pg_temp.sin_zona('e1', null, 'bd'), 'SIN_INICIAR', 'bd (se inscribió ayer a las 23:59:59) figura hoy');
select is(pg_temp.sin_zona_baja('e1', null, 'b4'), 'false', 'b4 no está de baja');
-- inscripto_at: el created_at de la inscripción («se sumó hoy a las 11:02»).
select is((select (s.value ->> 'inscripto_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1') -> 'sin_zona') s(value)
            where (s.value ->> 'colportor_id')::uuid = pg_temp.u('bc')),
          pg_temp.a(pg_temp.hoy(), '00:00:00'), 'inscripto_at de bc: cuándo se inscribió (hoy 00:00:00)');
select is((select (s.value ->> 'inscripto_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1') -> 'sin_zona') s(value)
            where (s.value ->> 'colportor_id')::uuid = pg_temp.u('bd')),
          pg_temp.a(pg_temp.hoy() - 1, '23:59:59'), 'inscripto_at de bd: ayer 23:59:59');
select is((select (s.value ->> 'inscripto_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1') -> 'sin_zona') s(value)
            where (s.value ->> 'colportor_id')::uuid = pg_temp.u('b4')),
          '2026-01-01'::timestamptz, 'inscripto_at de b4: 01/01/2026');
select is((select (s.value ->> 'inscripto_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1', pg_temp.hoy() - 1) -> 'sin_zona') s(value)
            where (s.value ->> 'colportor_id')::uuid = pg_temp.u('b6')),
          '2026-01-01'::timestamptz, 'inscripto_at de b6 (de baja): también está');
select is(pg_temp.sin_zona('e1', null, 'b7'), 'no está', 'b7 (no inscripto) no figura en sin_zona');
select is(jsonb_array_length(pg_temp.tab('e1') -> 'sin_zona'), 5, 'sin_zona tiene 5 (b4, b5, b8, bc y bd)');
-- Sus ventas, su jornada y sus visitas no están en ninguna cifra: el total de arriba (25000, 4, 5) ya lo prueba;
-- además, ninguna ciudad los cuenta.
select is((select sum((ciu.value ->> 'cantidad_colportores')::int)::int
             from jsonb_array_elements(pg_temp.tab('e1') -> 'ciudades') ciu(value)),
          5, 'ninguna ciudad cuenta a los sin zona');
-- El orden de sin_zona: por apellido.
select is((select array_agg(s.value ->> 'apellido' order by s.ord)
             from jsonb_array_elements(pg_temp.tab('e1') -> 'sin_zona') with ordinality s(value, ord)),
          array['Duarte', 'Eguren', 'Haedo', 'Lara', 'Mora'], 'sin_zona por apellido (no por nombre)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. Un día anterior
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
-- b1 ayer: jornada de 3 h; 2 ventas (4000 a mediodía y 1000 a las 23:59:59; la de hoy a las 00:00:00 no);
-- 2 presentaciones (VENTA y la ENTREVISTA de las 23:59:59).
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b1'), 'FINALIZADA|3|2|2|5000|Ciudad uno q94',
          'b1 ayer: finalizada, 3 h, 2 presentaciones, 2 ventas (bordes de la medianoche de Montevideo)');
-- b2 ayer: la jornada que cruza la medianoche cuenta entera en el día en que empezó (2 h).
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b2'), 'SIN_CERRAR|2|0|0|0|Ciudad uno q94',
          'b2 ayer: la jornada de las 23:00 a la 01:00 cuenta entera ayer (2 h); la abierta de las 08:00 no suma y lo deja sin cerrar');
-- b3 ayer: la jornada abierta de un día anterior no suma horas (nada inventa un fin) y no está «en jornada».
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b3'), 'SIN_CERRAR|0|0|0|0|Ciudad dos q94',
          'b3 ayer: su jornada sigue abierta: sin cerrar, no «en jornada», y no suma horas (nadie inventa un fin)');
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b9'), 'SIN_INICIAR|0|0|0|0|Ciudad dos q94', 'b9 ayer: sin iniciar');
-- Las inscripciones de ayer: bd (23:59:59) estaba; bc (hoy 00:00:00) todavía no; b6 y bb (baja ayer 12:00) estaban.
select is(pg_temp.sin_zona('e1', pg_temp.hoy() - 1, 'bd'), 'SIN_INICIAR', 'bd ya estaba inscripto ayer (a las 23:59:59)');
select is(pg_temp.sin_zona('e1', pg_temp.hoy() - 1, 'bc'), 'no está', 'bc no estaba inscripto ayer (se inscribió hoy a las 00:00:00)');
select is(pg_temp.sin_zona('e1', pg_temp.hoy() - 1, 'b6'), 'FINALIZADA', 'b6, dado de baja ayer a las 12:00, ayer figura sin zona y su jornada de las 09:00 cuenta');
select is(pg_temp.sin_zona_baja('e1', pg_temp.hoy() - 1, 'b6'), 'true', 'y se marca como inscripción de baja');
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b6'), 'sin fila', 'b6 de baja no está en ninguna ciudad');
select is(pg_temp.sin_zona('e1', pg_temp.hoy() - 1, 'bb'), 'SIN_INICIAR', 'bb: su única jornada de ayer es posterior a la baja (13:00): no cuenta');
select is(pg_temp.sin_zona('e1', pg_temp.hoy() - 2, 'b6'), 'SIN_INICIAR', 'antes de ayer b6 estaba inscripto (sin zona, de baja después): sin iniciar');
select is(pg_temp.sin_zona('e1', pg_temp.hoy() - 2, 'bd'), 'no está', 'antes de ayer bd no estaba inscripto');
select is(pg_temp.ciudad('e1', pg_temp.hoy() - 1, 'c1'), '2|0|5|2|2|5000|2',
          'Ciudad uno ayer: 5 h (3 + 2), 2 presentaciones, 2 ventas por 5000, nadie en jornada');
select is(pg_temp.total('e1', pg_temp.hoy() - 1), '5|0|5|2|2|5000', 'el total de ayer');
select is(pg_temp.fila('e1', pg_temp.hoy() - 2, 'b1'), 'SIN_INICIAR|0|0|1|77777|Ciudad uno q94',
          'antes de ayer: la venta de ese día, sin jornada');
-- Un día antes de que empiece la campaña: ceros (la venta de 5555 de ese día no cuenta) y no es un error.
select is(pg_temp.fila('e1', pg_temp.hoy() - 31, 'b1'), 'SIN_INICIAR|0|0|0|0|Ciudad uno q94',
          'un día antes de que empiece la campaña: ceros, sin error');
select is(pg_temp.total('e1', pg_temp.hoy() - 31), '5|0|0|0|0|0', 'y el total en ceros');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 8. Campaña terminada: se lee, y sus bordes
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('e5', '2026-09-07', 'b1'), 'FINALIZADA|2.5|0|1|6000|Ciudad uno q94',
          'campaña terminada: se lee un día suyo (jornada de 2,5 h, 1 venta)');
select is(pg_temp.fila('e5', '2026-09-08', 'b1'), 'FINALIZADA|30|0|0|0|Ciudad uno q94',
          'una jornada de 30 h: 30 horas exactas (la cuenta es en segundos)');
select is(pg_temp.fila('e5', '2026-08-03', 'b1'), 'SIN_INICIAR|0|0|1|1111|Ciudad uno q94', 'el primer día de la campaña cuenta');
select is(pg_temp.fila('e5', '2026-08-02', 'b1'), 'SIN_INICIAR|0|0|0|0|Ciudad uno q94', 'el día anterior al primero no cuenta (la venta de las 23:59)');
select is(pg_temp.fila('e5', '2026-09-30', 'b1'), 'SIN_INICIAR|0|0|1|2222|Ciudad uno q94', 'el último día de la campaña cuenta (venta de las 23:59)');
select is(pg_temp.fila('e5', '2026-10-01', 'b1'), 'SIN_INICIAR|0|0|0|0|Ciudad uno q94', 'el día posterior al último no cuenta');
select is(pg_temp.total('e5', '2026-09-07'), '1|0|2.5|0|1|6000', 'el total de un día de la campaña terminada');
select is(pg_temp.sin_zona('e5', '2026-09-07', 'b2'), 'SIN_INICIAR', 'su inscripción sin zona figura en sin_zona');
select lives_ok($$ select public.tablero_de_inicio('01920000-0000-7000-8000-0000000060e5') $$,
  'hoy en una campaña terminada: no es un error');
select is(pg_temp.total('e5', null), '1|0|0|0|0|0', 'hoy en una campaña terminada: todo en cero');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 9. Último push, pendientes y datos de más
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select (c.value ->> 'ultimo_push_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1') -> 'ciudades' -> 2 -> 'colportores') c(value)
            where (c.value ->> 'colportor_id')::uuid = pg_temp.u('b1')),
          now() - interval '12 minutes', 'ultimo_push_at de b1');
select is((select (c.value ->> 'ultimo_push_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1') -> 'ciudades' -> 2 -> 'colportores') c(value)
            where (c.value ->> 'colportor_id')::uuid = pg_temp.u('b2')),
          now() - interval '4 days', 'ultimo_push_at de b2: hace 4 días');
select is((select c.value -> 'ultimo_push_at'
             from jsonb_array_elements(pg_temp.tab('e1') -> 'ciudades' -> 0 -> 'colportores') c(value)
            where (c.value ->> 'colportor_id')::uuid = pg_temp.u('b9')),
          'null'::jsonb, 'ultimo_push_at de quien nunca sincronizó: null (la clave está)');
select is((select (s.value ->> 'ultimo_push_at')::timestamptz
             from jsonb_array_elements(pg_temp.tab('e1') -> 'sin_zona') s(value)
            where (s.value ->> 'colportor_id')::uuid = pg_temp.u('b4')),
          now() - interval '1 day', 'ultimo_push_at también en sin_zona');
select is((select s.value -> 'ultimo_push_at'
             from jsonb_array_elements(pg_temp.tab('e1') -> 'sin_zona') s(value)
            where (s.value ->> 'colportor_id')::uuid = pg_temp.u('b5')),
          'null'::jsonb, 'y null para quien nunca sincronizó');
select is(pg_temp.tab('e1') -> 'pendientes', '[]'::jsonb, 'pendientes: vacío hasta V2');
-- Ni emails ni nada de la persona: el texto entero de la respuesta no trae ningún email del fixture.
select is(position('@example.com' in pg_temp.tab('e1')::text), 0, 'la respuesta no trae emails');
-- Ni el número del talonario.
select is(position('T-' in pg_temp.tab('e1')::text), 0, 'la respuesta no trae números de talonario');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 10. El día es el de Montevideo, no el de la sesión
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b1'), 'FINALIZADA|3|2|2|5000|Ciudad uno q94',
          'con la sesión en Pacific/Kiritimati (UTC+14): el mismo ayer');
select is((pg_temp.tab('e1') ->> 'fecha'), pg_temp.hoy()::text, 'y el mismo hoy');
select set_config('TimeZone', 'Etc/GMT+12', true);
select is(pg_temp.fila('e1', pg_temp.hoy() - 1, 'b1'), 'FINALIZADA|3|2|2|5000|Ciudad uno q94',
          'con la sesión en Etc/GMT+12 (UTC-12): el mismo ayer');
select is((pg_temp.tab('e1') ->> 'fecha'), pg_temp.hoy()::text, 'y el mismo hoy');
select set_config('TimeZone', 'UTC', true);
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 11. La función no escribe nada
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.venta where colportor_id = pg_temp.u('b1')), 12,
          'las ventas de b1 siguen siendo las 12 del fixture');
select is((select count(*)::int from public.jornada where colportor_id = pg_temp.u('b2')), 4,
          'las jornadas de b2 siguen siendo las 4 del fixture');
select is((select count(*)::int from public.visita where colportor_id = pg_temp.u('b1')), 8,
          'las visitas de b1 siguen siendo las 8 del fixture');

select * from finish();
rollback;
