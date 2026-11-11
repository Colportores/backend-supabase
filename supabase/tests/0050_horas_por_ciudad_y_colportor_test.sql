-- pgTAP · horas trabajadas por ciudad y colportor (migración 0060, backend-supabase#95, HU-REP-001;
-- la ciudad por el historial de zonas de cada día desde la 0106, backend-supabase#141)
-- horas_por_ciudad_y_colportor(): el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido,
-- coordinador de otra campaña) y que una campaña terminada se lee; los errores de campaña y de
-- parámetros; las horas por día, semana y mes (jornadas cerradas, el día de Montevideo, la campaña,
-- la baja de la inscripción, la ciudad de la zona de ese día y «sin ciudad»); el período anterior (el
-- lunes contra el sábado, la semana anterior, el mes contra el mes pasado, lo en curso sin
-- comparar salvo el mes a la fecha); el rango a períodos completos y su tope; los filtros; que la
-- respuesta no trae nada de más.
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

-- El uuid de un personaje del test: a0..a4, ad, b1..bA, c1, c2, e1.., d1.., 71...
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000050' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- La fila de un período y un colportor, como texto:
-- horas|jornadas|dias|acompañadas|en_curso|horas_anterior|jornadas_anterior (null = vacío).
create or replace function pg_temp.fila(p_camp text, p_desde date, p_hasta date, p_agr text,
                                        p_inicio date, p_colp text)
returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s|%s|%s', r.horas, r.jornadas, r.dias_trabajados,
                  r.jornadas_acompaniadas, r.en_curso::text, r.horas_anterior, r.jornadas_anterior)
      from public.horas_por_ciudad_y_colportor(pg_temp.u(p_camp), p_desde, p_hasta, p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- La ciudad de esa fila.
create or replace function pg_temp.ciudad_de(p_camp text, p_desde date, p_hasta date, p_agr text,
                                             p_inicio date, p_colp text)
returns text language sql as $$
  select coalesce((
    select coalesce(r.ciudad_nombre, '(sin ciudad)') || '/' || coalesce(r.ciudad_id::text, 'null')
      from public.horas_por_ciudad_y_colportor(pg_temp.u(p_camp), p_desde, p_hasta, p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Cierre y En curso; a2 coordinador de Otra; ad admin; a0 colportor;
--        a3 sin ningún rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Alfa (zona Centro, c1)  b2 Bravo (Centro, c1)  b3 Cruz (zona Costa, c2)
--        b4 Duarte (sin zona)  b5 Eguren (su zona se dio de baja)  b6 Fuentes (inscripción de
--        baja el 15/09)  b7 Gómez (NO inscripto)  b8, b9, ba (de En curso, zona Cerro, c1).
-- Campañas: e1 Cierre (03/08/2026 a 30/09/2026, terminada, a1)  e2 Otra (a2)  e4 Borrada (a1)
--        e6 En curso (desde hoy - 90, sin fin, a1)
-- Ciudades: c1 «Ciudad uno q95» y c2 «Ciudad dos q95» (en ese orden alfabético: dos antes que uno).
-- campania_ciudad: 71 Cierre/c1  72 Cierre/c2  73 En curso/c1  74 Otra/c2
-- Zonas: d1 Centro (en 71)  d2 Costa (en 72)  d3 Baja (en 71, se da de baja)  d4 Cerro (en 73)
-- Campaña e9 «Zonas» (0106): ciudades 75 (c1) y 76 (c2), zonas d5 (en 75) y d6 (en 76), colportores
-- bd, be y bf con tramos del historial a mano (ver «Cambio de zona» más abajo).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'horas-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo'), ('b9','Iris','Ibarra'),
               ('ba','Juan','Jara')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais horas', 'ZR');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q95', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Ciudad dos q95', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c3'), 'Ciudad tres q95', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Cierre',   'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otra',     'VERANO', '2026-08-03', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada',  'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), now()),
  (pg_temp.u('e6'), 'En curso', 'VERANO', pg_temp.hoy() - 90, null,   pg_temp.u('a1'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('73'), pg_temp.u('e6'), pg_temp.u('c1')),
  (pg_temp.u('74'), pg_temp.u('e2'), pg_temp.u('c2'));

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa',  pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb),
  (pg_temp.u('d3'), 'Baja',   pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.95],[-56.17,-34.95],[-56.17,-34.94],[-56.19,-34.94],[-56.19,-34.95]]]}'::jsonb),
  (pg_temp.u('d4'), 'Cerro',  pg_temp.u('73'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.98],[-56.17,-34.98],[-56.17,-34.97],[-56.19,-34.97],[-56.19,-34.98]]]}'::jsonb);

-- Cada colportor cuenta desde el día de su inscripción: las de Cierre y En curso son anteriores a
-- todas sus jornadas (más abajo, bb y bc prueban lo contrario).
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d2'), '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null,            '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d3'), '2026-08-01 12:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b6'), pg_temp.u('d1'), '2026-08-01 12:00-03'),
  (pg_temp.u('e6'), pg_temp.u('b8'), pg_temp.u('d4'), (pg_temp.hoy() - 90)::timestamptz),
  (pg_temp.u('e6'), pg_temp.u('b9'), pg_temp.u('d4'), (pg_temp.hoy() - 90)::timestamptz),
  (pg_temp.u('e6'), pg_temp.u('ba'), pg_temp.u('d4'), (pg_temp.hoy() - 90)::timestamptz);
-- La zona de b5 se da de baja; la inscripción de b6 se da de baja el 15/09 a mediodía.
update public.zona set deleted_at = now() where id = pg_temp.u('d3');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b6');
-- El historial (0022) abre el tramo con la hora real de la inserción; en este fixture las zonas se
-- asignaron al inscribirse, antes de todas las jornadas.
update public.campania_colportor_zona_historial h set desde = i.created_at
  from public.campania_colportor i where i.id = h.campania_colportor_id;

-- Jornadas de Cierre (horas locales de Montevideo, UTC-3). Semana 1 = lun 07/09 a dom 13/09.
--   b1 lun 07/09: 2 h + 1,5 h con acompañante; mar 08: 4 h; sáb 12: 3 h; dom 13: 1 h; lun 14: 5 h;
--      mar 15 23:00 a mié 16 02:00: 3 h (cruza la medianoche); fuera de la campaña: 20/07 y 02/10.
--   b2 lun 07/09: 6 h; el 08/09 una abierta (sin fin) y una dada de baja: no cuentan.
--   b3 lun 07/09: 7 h; jue 20/08: 2 h.   b4 08/09: 2 h.   b5 08/09: 1 h.
--   b6 jue 10/09: 3 h (antes de la baja); dom 20/09: 3 h (después: no cuenta).
--   b7 lun 07/09: 9 h (no está inscripto en Cierre).
insert into public.jornada (colportor_id, inicio, fin, acompaniante_id, deleted_at)
select pg_temp.u(x.s), x.i::timestamptz, x.f::timestamptz,
       case when x.acomp then pg_temp.u('a1') end, x.baja
  from (values
    ('b1', '2026-09-07 09:00-03', '2026-09-07 11:00-03', false, null::timestamptz),
    ('b1', '2026-09-07 14:00-03', '2026-09-07 15:30-03', true,  null),
    ('b1', '2026-09-08 09:00-03', '2026-09-08 13:00-03', false, null),
    ('b1', '2026-09-12 09:00-03', '2026-09-12 12:00-03', false, null),
    ('b1', '2026-09-13 10:00-03', '2026-09-13 11:00-03', false, null),
    ('b1', '2026-09-14 08:00-03', '2026-09-14 13:00-03', false, null),
    ('b1', '2026-09-15 23:00-03', '2026-09-16 02:00-03', false, null),
    ('b1', '2026-07-20 09:00-03', '2026-07-20 10:00-03', false, null),
    ('b1', '2026-10-02 09:00-03', '2026-10-02 10:00-03', false, null),
    ('b2', '2026-09-07 09:00-03', '2026-09-07 15:00-03', false, null),
    ('b2', '2026-09-08 09:00-03', null,                  false, null),
    ('b2', '2026-09-08 09:00-03', '2026-09-08 10:00-03', false, '2026-09-09 00:00+00'),
    ('b3', '2026-09-07 09:00-03', '2026-09-07 16:00-03', false, null),
    ('b3', '2026-08-20 09:00-03', '2026-08-20 11:00-03', false, null),
    ('b4', '2026-09-08 09:00-03', '2026-09-08 11:00-03', false, null),
    ('b5', '2026-09-08 09:00-03', '2026-09-08 10:00-03', false, null),
    ('b6', '2026-09-10 09:00-03', '2026-09-10 12:00-03', false, null),
    ('b6', '2026-09-20 09:00-03', '2026-09-20 12:00-03', false, null),
    ('b7', '2026-09-07 09:00-03', '2026-09-07 18:00-03', false, null)
  ) x(s, i, f, acomp, baja);

-- Reasignación e inscripción tardía (sin zona: ciudad null), campañas e7 Destino y e8 Origen, las
-- dos desde el 03/08 y sin fin, del coordinador a1.
--   bb: inscripto en Origen desde el 01/08, dado de baja el 15/09 a las 09:00 (Montevideo) y
--       reasignado a Destino a las 09:30 de ese día. Jornadas: 10/09 4 h (de Origen); 15/09 09:00
--       1 h (empieza justo en el instante de la baja: ya no es de Origen) y 10:00 2 h (después de la
--       baja, el día de la inscripción en Destino: de Destino); 16/09 3 h (de Destino).
--   bc: inscripto en Destino el 09/09 a las 10:00. Jornadas: 07/09 y 08/09 1 h cada una (días
--       anteriores: no cuentan), 09/09 2 h (desde las 08:00, el mismo día: cuenta, el corte es por
--       día), 10/09 3 h.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'horas-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['bb','bc']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('bb','Kira','Kent'), ('bc','Lola','Lara')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('bb'), ('bc')) x(s) join public.rol r on r.codigo = 'COLPORTOR';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e7'), 'Destino', 'VERANO', '2026-08-03', null, pg_temp.u('a1')),
  (pg_temp.u('e8'), 'Origen',  'VERANO', '2026-08-03', null, pg_temp.u('a1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e8'), pg_temp.u('bb'), null, '2026-08-01 12:00-03');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e8') and usuario_id = pg_temp.u('bb');
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e7'), pg_temp.u('bb'), null, '2026-09-15 12:30:00+00'),
  (pg_temp.u('e7'), pg_temp.u('bc'), null, '2026-09-09 10:00-03');
insert into public.jornada (colportor_id, inicio, fin)
select pg_temp.u(x.s), x.i::timestamptz, x.f::timestamptz
  from (values
    ('bb', '2026-09-10 09:00-03', '2026-09-10 13:00-03'),
    ('bb', '2026-09-15 09:00-03', '2026-09-15 10:00-03'),
    ('bb', '2026-09-15 10:00-03', '2026-09-15 12:00-03'),
    ('bb', '2026-09-16 09:00-03', '2026-09-16 12:00-03'),
    ('bc', '2026-09-07 09:00-03', '2026-09-07 10:00-03'),
    ('bc', '2026-09-08 09:00-03', '2026-09-08 10:00-03'),
    ('bc', '2026-09-09 08:00-03', '2026-09-09 10:00-03'),
    ('bc', '2026-09-10 09:00-03', '2026-09-10 12:00-03')
  ) x(s, i, f);

-- Jornadas de En curso (relativas a hoy, para lo en curso):
--   b8: hoy 1 h, y hace 7 días 3 h.   ba: ayer 2 h (hoy nada).
--   b9: hoy 1 h, y en el mes pasado los días 1 (4 h), 15 (2 h) y 28 (5 h).
insert into public.jornada (colportor_id, inicio, fin)
select pg_temp.u(x.s),
       (x.dia + time '08:00') at time zone 'America/Montevideo',
       (x.dia + time '08:00' + make_interval(hours => x.h)) at time zone 'America/Montevideo'
  from (values
    ('b8',  pg_temp.hoy(),     1),
    ('b8',  pg_temp.hoy() - 7, 3),
    ('ba', pg_temp.hoy() - 1, 2),
    ('b9',  pg_temp.hoy(),     1),
    ('b9',  (date_trunc('month', pg_temp.hoy()::timestamp) - interval '1 month')::date,        4),
    ('b9',  (date_trunc('month', pg_temp.hoy()::timestamp) - interval '1 month')::date + 14,   2),
    ('b9',  (date_trunc('month', pg_temp.hoy()::timestamp) - interval '1 month')::date + 27,   5)
  ) x(s, dia, h);

-- ---------------------------------------------------------------------------
-- 1. La función: forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-07', 'dia') r limit 1)) k
                 order by k collate "C")),
          array['apellido','ciudad_id','ciudad_nombre','colportor_id','dias_trabajados','en_curso',
                'horas','horas_anterior','jornadas','jornadas_acompaniadas','jornadas_anterior',
                'nombre','periodo_fin','periodo_inicio'],
          'la forma de la respuesta: solo totales (sin clientes, ventas, importes, ubicaciones ni emails)');
select pg_temp.actuar_como_servidor();

select is((select p.prosecdef from pg_proc p where p.oid = 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          true, 'es SECURITY DEFINER (el coordinador no lee jornada)');
select is((select p.provolatile from pg_proc p where p.oid = 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          'v', 'es VOLATILE (llama a lanzar_motivo_mapa())');
select is((select p.proconfig from pg_proc p where p.oid = 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          array['search_path=""'], 'fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute'),
          'anon NO la ejecuta');
select ok(not has_function_privilege('service_role', 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute'),
          'service_role NO la ejecuta (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.horas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          0, 'no tiene EXECUTE para PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'sin JWT (el servidor) falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'authenticated sin sesión falla');

select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como_servidor();

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a0');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un colportor no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050b1');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un colportor inscripto en la campaña tampoco ve ni sus propias horas por acá');
-- El permiso va antes que la existencia y que los parámetros.
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050ff', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-13', '2026-09-07', 'año') $$,
  '42501', null, 'un colportor con parámetros inválidos: 42501, no 22023');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a3');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a4');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'con el rol de coordinador vencido falla');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a2');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'el coordinador de otra campaña no ve las horas de esta');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus reportes. Entrá con la cuenta del coordinador de esta campaña.',
  'el mensaje del 42501 dice quién puede y habla de reportes');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-13', '2026-09-07', 'año') $$,
  '42501', null, 'el de otra campaña con parámetros inválidos: 42501, no 22023');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050ff', '2026-09-07', '2026-09-13', 'semana') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña y de parámetros (como el coordinador de la campaña)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e4', '2026-09-07', '2026-09-13', 'semana') $$,
  'CZ001', null, 'una campaña dada de baja: CZ001');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor(null, '2026-09-07', '2026-09-13', 'semana') $$,
  'CZ001', null, 'una campaña nula: CZ001');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'año') $$,
  '22023', 'Elegí cómo agrupar las horas: por día, por semana o por mes.', 'agrupación inválida');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', null) $$,
  '22023', null, 'agrupación nula');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'Semana') $$,
  '22023', null, 'la agrupación distingue mayúsculas');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-13', '2026-09-07', 'dia') $$,
  '22023', 'Elegí un rango de fechas: la fecha de inicio no puede ser posterior a la de fin.', 'desde posterior a hasta');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', null, '2026-09-13', 'dia') $$,
  '22023', null, 'desde nulo');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', null, 'dia') $$,
  '22023', null, 'hasta nulo');
select lives_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-01-01', '2027-01-01', 'dia') $$,
  '366 días en días: pasa');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-01-01', '2027-01-02', 'dia') $$,
  '22023', 'El rango es demasiado largo: pedí hasta 366 días por vez.', '367 días en días: error, no se recorta');
select lives_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-01-01', '2026-12-31', 'mes') $$,
  'doce meses: pasa');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-01-15', '2027-01-10', 'mes') $$,
  '22023', null, 'trece meses (el rango sube a meses completos): error');
select throws_ok($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-01-01', '2026-12-31', 'semana') $$,
  '22023', null, 'el año entero en semanas: sube a lunes y domingo y pasa de 366 días');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Una campaña terminada se lee, y el ADMIN lee cualquiera
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select isnt_empty($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  'Cierre terminó el 30/09 y el coordinador la lee (el reporte se pide al cierre)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050ad');
select isnt_empty($$ select * from public.horas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000050e1', '2026-09-07', '2026-09-13', 'semana') $$,
  'un ADMIN lee las horas de cualquier campaña');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Por día (lun 07/09 a mié 16/09)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');

select is((select count(*)::int from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-16', 'dia')),
          18, 'por día: 18 filas (los días con jornadas y los días siguientes a uno con jornadas)');

select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b1'),
          '3.50|2|1|1|false|0.00|0', 'b1 el lunes 07: 2 h + 1,5 h acompañada; el sábado anterior sin datos');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-08', 'b1'),
          '4.00|1|1|0|false|3.50|2', 'b1 el martes 08: se compara con el lunes');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-09', 'b1'),
          '0.00|0|0|0|false|4.00|1', 'b1 el miércoles 09 sin jornadas: fila vacía con el martes como anterior');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-10', 'b1'),
          'sin fila', 'b1 el jueves 10: ni jornadas ni anterior, sin fila');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-12', 'b1'),
          '3.00|1|1|0|false|0.00|0', 'b1 el sábado 12');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-13', 'b1'),
          '1.00|1|1|0|false|3.00|1', 'b1 el domingo 13 (se trabajó): anterior = el sábado');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-14', 'b1'),
          '5.00|1|1|0|false|3.00|1', 'b1 el lunes 14: el anterior es el SÁBADO (3 h), no el domingo (1 h)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-15', 'b1'),
          '3.00|1|1|0|false|5.00|1', 'b1 el martes 15: la jornada que cruza la medianoche cuenta entera en el 15');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-16', 'b1'),
          '0.00|0|0|0|false|3.00|1', 'b1 el miércoles 16: nada empezó ese día');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b2'),
          '6.00|1|1|0|false|0.00|0', 'b2 el 07: 6 h');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-08', 'b2'),
          '0.00|0|0|0|false|6.00|1', 'b2 el 08: la jornada abierta y la dada de baja no suman (fila vacía por el 07)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b7'),
          'sin fila', 'b7 no está inscripto en la campaña: sus 9 h no salen');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-10', 'b6'),
          '3.00|1|1|0|false|0.00|0', 'b6 el 10: antes de la baja de la inscripción, cuenta');
select is(pg_temp.fila('e1', '2026-09-18', '2026-09-22', 'dia', '2026-09-20', 'b6'),
          'sin fila', 'b6 el 20: después de la baja de la inscripción, no cuenta');

-- Cada colportor cuenta desde el día de su inscripción en la campaña (HU-CAM-005: reasignar).
select is(pg_temp.fila('e8', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'bb'),
          '4.00|1|1|0|false|0.00|0', 'bb en Origen: sus 4 h del 10/09, antes de la baja');
select is(pg_temp.fila('e8', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'bb'),
          '0.00|0|0|0|false|4.00|1', 'bb en Origen: lo posterior a la baja (15 y 16/09) no suma; queda la semana anterior');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'bb'),
          'sin fila', 'bb en Destino: las 4 h del 10/09 son de Origen, no se cuentan dos veces');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'bb'),
          '6.00|3|2|0|false|0.00|0', 'bb en Destino: desde el día de su inscripción (15/09, aunque la jornada empezó antes de la hora) y el 16/09');
select is((select sum(horas) from (
             select horas from public.horas_por_ciudad_y_colportor(pg_temp.u('e7'), '2026-09-07', '2026-09-20', 'semana', null, array[pg_temp.u('bb')])
             union all
             select horas from public.horas_por_ciudad_y_colportor(pg_temp.u('e8'), '2026-09-07', '2026-09-20', 'semana', null, array[pg_temp.u('bb')])
           ) t),
          10.00, 'la reasignación no duplica: Origen + Destino suman las 10 h que trabajó bb, ni una más (la jornada justo en el instante de la baja es de Destino)');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'dia', '2026-09-15', 'bb'),
          '3.00|2|1|0|false|0.00|0', 'por día: el 15/09 (día de la inscripción) cuenta en Destino, también la jornada que empezó justo en la baja');
select is(pg_temp.fila('e8', '2026-09-07', '2026-09-20', 'dia', '2026-09-15', 'bb'),
          'sin fila', 'por día: el 15/09, jornada posterior a la baja, no cuenta en Origen');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'bc'),
          '5.00|2|2|0|false|0.00|0', 'bc, inscripto el 09/09 a las 10:00: no cuenta el 07/09; el 09/09 desde las 08:00 sí (el corte es por día) y el 10/09');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'bc'),
          '0.00|0|0|0|false|5.00|2', 'bc: la semana siguiente compara contra lo que sí cuenta');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'dia', '2026-09-07', 'bc'),
          'sin fila', 'bc el 07/09: antes de su inscripción, sin fila');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'dia', '2026-09-08', 'bc'),
          'sin fila', 'bc el 08/09, el día anterior a su inscripción: sin fila');
select is(pg_temp.fila('e7', '2026-09-07', '2026-09-20', 'mes', '2026-09-01', 'bc'),
          '5.00|2|2|0|false|0.00|0', 'por mes: también desde el día de la inscripción');

-- La zona horaria de la sesión no mueve el día.
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-15', 'b1'),
          '3.00|1|1|0|false|5.00|1', 'con la sesión en Pacific/Kiritimati (UTC+14) el día sigue siendo el de Montevideo');
select set_config('TimeZone', 'Etc/GMT+12', true);
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b1'),
          '3.50|2|1|1|false|0.00|0', 'con la sesión en Etc/GMT+12 (UTC-12) tampoco');
select set_config('TimeZone', 'UTC', true);

-- Fuera de la campaña (antes del inicio y después del fin) no hay nada.
select is((select count(*)::int from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-07-18', '2026-07-22', 'dia')),
          0, 'antes del inicio de la campaña (b1 trabajó el 20/07): sin filas');
select is((select count(*)::int from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-10-01', '2026-10-03', 'dia')),
          0, 'después del fin de la campaña (b1 trabajó el 02/10): sin filas');
select is((select count(*)::int from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-21', '2026-09-22', 'dia')
            where colportor_id = pg_temp.u('b6')),
          0, 'b6 el 21 y 22/09: sin filas (la jornada del 20 es posterior a su baja)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Por semana (lun 07/09 a dom 20/09): la ciudad de la zona actual
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is((select count(*)::int from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana')),
          12, 'por semana: 12 filas (6 colportores × 2 semanas)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b1'),
          '11.50|5|4|1|false|0.00|0', 'b1 semana 1: 11,5 h, 5 jornadas en 4 días, una acompañada');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b1'),
          '8.00|2|2|0|false|11.50|5', 'b1 semana 2: 8 h contra la semana anterior completa');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b2'),
          '6.00|1|1|0|false|0.00|0', 'b2 semana 1');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b2'),
          '0.00|0|0|0|false|6.00|1', 'b2 semana 2: sin datos, con la anterior (para que la suma de la ciudad sea la de verdad)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b3'),
          '7.00|1|1|0|false|0.00|0', 'b3 semana 1');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b6'),
          '0.00|0|0|0|false|3.00|1', 'b6 semana 2: la jornada del 20 (después de la baja) no suma');

select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b1'),
          'Ciudad uno q95/01920000-0000-7000-8000-0000000050c1', 'b1 es de la ciudad de su zona (Centro)');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b3'),
          'Ciudad dos q95/01920000-0000-7000-8000-0000000050c2', 'b3 es de la ciudad de su zona (Costa)');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b4'),
          '(sin ciudad)/null', 'b4 sin zona: sin ciudad');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b5'),
          'Ciudad uno q95/01920000-0000-7000-8000-0000000050c1', 'b5, con la zona dada de baja DESPUÉS: sigue en la ciudad que tenía (un reporte cerrado no se mueve)');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b6'),
          'Ciudad uno q95/01920000-0000-7000-8000-0000000050c1',
          'b6, con la inscripción dada de baja DESPUÉS: la jornada del 10/09 va a la ciudad de su zona de ese día (R7)');
select is((select count(*)::int from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana')
            where colportor_id = pg_temp.u('b4')),
          1, 'sin zona aparece UNA sola vez, no repetido en cada ciudad (el total de horas no se infla)');
select is((select sum(horas) from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana')),
          30.50, 'el total de la semana 1 es la suma de las jornadas de los inscriptos (11,5 + 6 + 7 + 2 + 1 + 3)');

-- El orden: período, ciudad por nombre (sin ciudad al final), apellido.
select is((select array(select left(r.apellido, 3)
                          from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana') r)),
          array['Cru','Alf','Bra','Egu','Fue','Dua'],
          'el orden: Ciudad dos, Ciudad uno (por apellido), sin ciudad (por apellido)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. Por mes (ago y sep de 2026)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-08-01', 'b3'),
          '2.00|1|1|0|false|0.00|0', 'b3 agosto: 2 h; julio sin datos');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-09-01', 'b3'),
          '7.00|1|1|0|false|2.00|1', 'b3 septiembre: 7 h contra agosto completo');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-09-01', 'b1'),
          '19.50|7|6|1|false|0.00|0', 'b1 septiembre: 19,5 h en 7 jornadas, 6 días, una acompañada (la del 20/07 y la del 02/10 quedan fuera)');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-08-01', 'b1'),
          'sin fila', 'b1 agosto: sin jornadas');
select is((select periodo_inicio::text || '..' || periodo_fin::text
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-08-01', '2026-09-30', 'mes')
            where colportor_id = pg_temp.u('b3') and periodo_inicio = '2026-09-01'),
          '2026-09-01..2026-09-30', 'el mes va del 1 al 30');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 8. El rango sube a períodos completos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is((select min(periodo_inicio)::text || '..' || max(periodo_fin)::text
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-09', '2026-09-09', 'semana')),
          '2026-09-07..2026-09-13', 'semana: un miércoles pide la semana de lunes a domingo');
select is(pg_temp.fila('e1', '2026-09-09', '2026-09-09', 'semana', '2026-09-07', 'b1'),
          '11.50|5|4|1|false|0.00|0', 'y trae las 11,5 h de la semana entera, no solo desde el miércoles');
select is(pg_temp.fila('e1', '2026-09-20', '2026-09-25', 'mes', '2026-09-01', 'b3'),
          '7.00|1|1|0|false|2.00|1', 'mes: el 20 al 25 de septiembre trae septiembre entero');
select is((select min(periodo_inicio)::text from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-08', '2026-09-16', 'dia')),
          '2026-09-08', 'día: no se redondea nada');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 9. Filtros
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is((select string_agg(distinct left(apellido, 3), ',' order by left(apellido, 3))
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c1'))),
          'Alf,Bra,Egu,Fue', 'p_ciudad_id = ciudad uno: solo los de esa ciudad (b5 y b6 por su zona de ese día)');
select is((select string_agg(distinct left(apellido, 3), ',' order by left(apellido, 3))
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c2'))),
          'Cru', 'p_ciudad_id = ciudad dos');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c3'))),
          0, 'una ciudad que no es de la campaña: sin filas (y no es un error)');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana',
                                                      '00000000-0000-0000-0000-000000000000')),
          0, 'el uuid cero no es «sin ciudad»');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', null,
                                                      array[pg_temp.u('b1')])),
          2, 'p_colportor_ids = [b1]: sus 2 semanas');
select is((select count(distinct colportor_id)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', null,
                                                      array[pg_temp.u('b1'), pg_temp.u('b3'), pg_temp.u('b7')])),
          2, 'p_colportor_ids = [b1, b3, b7]: b7 no está inscripto y no aparece');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c1'),
                                                      array[pg_temp.u('b3')])),
          0, 'ciudad uno y un colportor de ciudad dos: sin filas');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', null, '{}')),
          0, 'una lista de colportores vacía: sin filas');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 10. Lo en curso (E6, fechas relativas a hoy)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
-- Día: hoy no se compara; ayer sí.
select is(pg_temp.fila('e6', pg_temp.hoy() - 1, pg_temp.hoy(), 'dia', pg_temp.hoy(), 'b8'),
          '1.00|1|1|0|true||', 'día: hoy está en curso y no se compara (horas_anterior y jornadas_anterior null)');
select is(pg_temp.fila('e6', pg_temp.hoy() - 1, pg_temp.hoy(), 'dia', pg_temp.hoy() - 1, 'ba'),
          '2.00|1|1|0|false|0.00|0', 'día: ayer (completo) sí se compara');
select is(pg_temp.fila('e6', pg_temp.hoy() - 1, pg_temp.hoy(), 'dia', pg_temp.hoy(), 'ba'),
          'sin fila', 'día: hoy sin jornadas y en curso no deja una fila vacía con el anterior escondido');
-- Semana: la semana en curso no se compara, aunque la anterior tenga datos (b8 trabajó hace 7 días).
select is(pg_temp.fila('e6', pg_temp.hoy(), pg_temp.hoy(), 'semana',
                        date_trunc('week', pg_temp.hoy()::timestamp)::date, 'b8'),
          '1.00|1|1|0|true||', 'semana: la semana en curso no se compara');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e6'), pg_temp.hoy() - 7, pg_temp.hoy() - 7, 'semana')
            where colportor_id = pg_temp.u('b8') and not en_curso),
          1, 'semana: la anterior (completa) sale sin ser la en curso');
-- Mes: el mes en curso SÍ se compara, contra el mismo tramo del mes pasado.
select is(pg_temp.fila('e6', pg_temp.hoy(), pg_temp.hoy(), 'mes',
                        date_trunc('month', pg_temp.hoy()::timestamp)::date, 'b9'),
          '1.00|1|1|0|true|'
          || (4 + case when extract(day from pg_temp.hoy()) >= 15 then 2 else 0 end
                + case when extract(day from pg_temp.hoy()) >= 28 then 5 else 0 end)::numeric(10,2)::text
          || '|'
          || (1 + case when extract(day from pg_temp.hoy()) >= 15 then 1 else 0 end
                + case when extract(day from pg_temp.hoy()) >= 28 then 1 else 0 end)::text,
          'mes en curso: se compara con los días 1 a N del mes pasado, siendo N el día de hoy');
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e6'), pg_temp.hoy(), pg_temp.hoy(), 'mes')
            where colportor_id = pg_temp.u('b9') and periodo_inicio = date_trunc('month', pg_temp.hoy()::timestamp)::date),
          1, 'mes en curso: una sola fila por colportor');
-- Lo que no ocurrió todavía no sale: ni períodos futuros.
select is((select count(*)::int
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e6'), pg_temp.hoy() + 1, pg_temp.hoy() + 30, 'dia')),
          0, 'los días futuros no salen');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 10b. Cambio de zona: la ciudad es la de la zona de cada día (0106, #141)
-- ---------------------------------------------------------------------------
-- e9 «Zonas» desde el 03/08, sin fin, de a1. Ciudades de campaña 75 (c1) y 76 (c2); zonas d5 (75)
-- y d6 (76). Los tramos del historial se cargan a mano (desde <= instante < hasta):
--   bd Ana: d5 hasta el lun 14/09 00:00 (Montevideo) y d6 desde ese instante.
--       Jornadas: 08/09 2 h, 10/09 3 h, dom 13/09 22:00 a 01:00 (3 h: empieza en el tramo viejo),
--       lun 14/09 00:00 a 01:00 (1 h: empieza justo en el instante del cambio, es de la nueva),
--       14/09 08:00 4 h, 15/09 1 h.
--   be Beto: d5 hasta el 09/09 00:00; sin zona; d6 desde el 20/09 00:00 (días sin zona en el medio).
--       Jornadas: 08/09 1 h (d5), 12/09 3 h (sin zona), 21/09 2 h (d6).
--   bf Fede: d5 hasta el 12/09 12:00, cuando se dio de baja la inscripción (R7, decisión 25/10).
--       Jornadas: 08/09 8 h, 11/09 3 h (de d5), 14/09 2 h (después de la baja: no cuenta).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'horas-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['bd','be','bf']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('bd','Ana','Zeta'), ('be','Beto','Yepes'), ('bf','Fede','Xavier')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('bd'), ('be'), ('bf')) x(s) join public.rol r on r.codigo = 'COLPORTOR';
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e9'), 'Zonas', 'VERANO', '2026-08-03', null, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('75'), pg_temp.u('e9'), pg_temp.u('c1')),
  (pg_temp.u('76'), pg_temp.u('e9'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d5'), 'Rivera',  pg_temp.u('75'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d6'), 'Artigas', pg_temp.u('76'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e9'), pg_temp.u('bd'), null, '2026-08-01 12:00-03'),
  (pg_temp.u('e9'), pg_temp.u('be'), null, '2026-08-01 12:00-03'),
  (pg_temp.u('e9'), pg_temp.u('bf'), null, '2026-08-01 12:00-03');
update public.campania_colportor set deleted_at = '2026-09-12 12:00-03'
 where campania_id = pg_temp.u('e9') and usuario_id = pg_temp.u('bf');
insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, hasta)
select i.id, pg_temp.u(x.z), x.d::timestamptz, x.h::timestamptz
  from (values
    ('bd', 'd5', '2026-08-01 12:00-03', '2026-09-14 00:00-03'),
    ('bd', 'd6', '2026-09-14 00:00-03', null),
    ('be', 'd5', '2026-08-01 12:00-03', '2026-09-09 00:00-03'),
    ('be', 'd6', '2026-09-20 00:00-03', null),
    ('bf', 'd5', '2026-08-01 12:00-03', '2026-09-12 12:00-03')
  ) x(c, z, d, h)
  join public.campania_colportor i
    on i.campania_id = pg_temp.u('e9') and i.usuario_id = pg_temp.u(x.c);
insert into public.jornada (colportor_id, inicio, fin)
select pg_temp.u(x.s), x.i::timestamptz, x.f::timestamptz
  from (values
    ('bd', '2026-09-08 09:00-03', '2026-09-08 11:00-03'),
    ('bd', '2026-09-10 09:00-03', '2026-09-10 12:00-03'),
    ('bd', '2026-09-13 22:00-03', '2026-09-14 01:00-03'),
    ('bd', '2026-09-14 00:00-03', '2026-09-14 01:00-03'),
    ('bd', '2026-09-14 08:00-03', '2026-09-14 12:00-03'),
    ('bd', '2026-09-15 09:00-03', '2026-09-15 10:00-03'),
    ('be', '2026-09-08 09:00-03', '2026-09-08 10:00-03'),
    ('be', '2026-09-12 09:00-03', '2026-09-12 12:00-03'),
    ('be', '2026-09-21 09:00-03', '2026-09-21 11:00-03'),
    ('bf', '2026-09-08 09:00-03', '2026-09-08 17:00-03'),
    ('bf', '2026-09-11 09:00-03', '2026-09-11 12:00-03'),
    ('bf', '2026-09-14 09:00-03', '2026-09-14 11:00-03')
  ) x(s, i, f);

-- horas|jornadas de un colportor, un período y una ciudad (c1, c2 o 'sin').
create or replace function pg_temp.fila_ciudad(p_agr text, p_inicio date, p_colp text, p_ciudad text)
returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s', r.horas, r.jornadas, r.horas_anterior, r.jornadas_anterior)
      from public.horas_por_ciudad_y_colportor(pg_temp.u('e9'), '2026-09-07', '2026-09-27', p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)
       and r.ciudad_id is not distinct from (case p_ciudad when 'sin' then null else pg_temp.u(p_ciudad) end)),
    'sin fila')
$$;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
-- Por semana: Ana trabajó la semana del 07/09 en la primera ciudad y la del 14/09 en la segunda.
select is(pg_temp.fila_ciudad('semana', '2026-09-07', 'bd', 'c1'), '8.00|3|0.00|0',
          'Ana, semana 07/09: 8 h en Ciudad uno (la jornada del domingo 22:00 a 01:00 empieza en el tramo viejo y cuenta entera ahí)');
select is(pg_temp.fila_ciudad('semana', '2026-09-07', 'bd', 'c2'), 'sin fila',
          'Ana, semana 07/09: nada en Ciudad dos');
select is(pg_temp.fila_ciudad('semana', '2026-09-14', 'bd', 'c2'), '6.00|3|0.00|0',
          'Ana, semana 14/09: 6 h en Ciudad dos (la jornada que empieza justo en el instante del cambio es de la zona nueva)');
select is(pg_temp.fila_ciudad('semana', '2026-09-14', 'bd', 'c1'), '0.00|0|8.00|3',
          'Ana, semana 14/09 en Ciudad uno: 0 h contra las 8 h de la semana anterior (la suma por ciudad dice la verdad: nada se cuenta dos veces)');
select is((select sum(horas) from public.horas_por_ciudad_y_colportor(pg_temp.u('e9'), '2026-09-07', '2026-09-27', 'semana')
            where colportor_id = pg_temp.u('bd')),
          14.00, 'Ana: 8 + 6 = 14 h en total, ni una más ni una menos');
-- Por mes: el cambio a mitad de mes parte el mes en dos ciudades.
select is(pg_temp.fila_ciudad('mes', '2026-09-01', 'bd', 'c1'), '8.00|3|0.00|0', 'Ana, septiembre en Ciudad uno: 8 h');
select is(pg_temp.fila_ciudad('mes', '2026-09-01', 'bd', 'c2'), '6.00|3|0.00|0', 'Ana, septiembre en Ciudad dos: 6 h');
-- Por día.
select is((select string_agg(r.horas::text || '@' || coalesce(ciu.nombre, '-'), ',' order by r.periodo_inicio, ciu.nombre)
             from public.horas_por_ciudad_y_colportor(pg_temp.u('e9'), '2026-09-13', '2026-09-15', 'dia') r
             left join public.ciudad ciu on ciu.id = r.ciudad_id
            where r.colportor_id = pg_temp.u('bd') and r.jornadas > 0),
          '3.00@Ciudad uno q95,5.00@Ciudad dos q95,1.00@Ciudad dos q95',
          'Ana por día: el 13 (3 h) en Ciudad uno; el 14 (5 h) y el 15 (1 h) en Ciudad dos');
-- Filtro por ciudad: solo lo que trabajó en esa ciudad.
select is((select sum(horas) from public.horas_por_ciudad_y_colportor(pg_temp.u('e9'), '2026-09-07', '2026-09-27', 'semana',
                                                                       pg_temp.u('c1'), array[pg_temp.u('bd')])),
          8.00, 'p_ciudad_id = Ciudad uno: de Ana solo las 8 h que trabajó allá');
select is((select sum(horas) from public.horas_por_ciudad_y_colportor(pg_temp.u('e9'), '2026-09-07', '2026-09-27', 'semana',
                                                                       pg_temp.u('c2'), array[pg_temp.u('bd')])),
          6.00, 'p_ciudad_id = Ciudad dos: de Ana solo las 6 h que trabajó allá');

-- Días sin zona: «Sin zona asignada» (ciudad null), una sola vez.
select is(pg_temp.fila_ciudad('semana', '2026-09-07', 'be', 'c1'), '1.00|1|0.00|0', 'Beto, semana 07/09: la hora del 08 (con zona) en Ciudad uno');
select is(pg_temp.fila_ciudad('semana', '2026-09-07', 'be', 'sin'), '3.00|1|0.00|0', 'Beto, semana 07/09: las 3 h del 12 (sin zona) van a «sin ciudad»');
select is(pg_temp.fila_ciudad('semana', '2026-09-21', 'be', 'c2'), '2.00|1|0.00|0', 'Beto, semana 21/09: con zona de nuevo, en Ciudad dos');
select is((select sum(horas) from public.horas_por_ciudad_y_colportor(pg_temp.u('e9'), '2026-09-07', '2026-09-27', 'semana')
            where colportor_id = pg_temp.u('be')),
          6.00, 'Beto: 1 + 3 + 2 = 6 h, los días sin zona no se pierden ni se repiten');

-- Inscripción dada de baja después (R7): sus horas siguen en la ciudad de la zona que tenía.
select is(pg_temp.fila_ciudad('semana', '2026-09-07', 'bf', 'c1'), '11.00|2|0.00|0',
          'Fede, dado de baja el 12/09: sus 11 h trabajadas antes de la baja van a Ciudad uno, no a «sin ciudad»');
select is(pg_temp.fila_ciudad('semana', '2026-09-07', 'bf', 'sin'), 'sin fila', 'Fede: nada en «sin ciudad»');
select is(pg_temp.fila_ciudad('semana', '2026-09-14', 'bf', 'c1'), '0.00|0|11.00|2',
          'Fede, semana 14/09: la jornada posterior a la baja no cuenta (queda la semana anterior)');
select pg_temp.actuar_como_servidor();

-- Un reporte de un mes cerrado no cambia aunque después den de baja la zona y la ciudad de campaña.
update public.zona set deleted_at = now() where id in (pg_temp.u('d5'), pg_temp.u('d6'));
update public.campania_ciudad set deleted_at = now() where id in (pg_temp.u('75'), pg_temp.u('76'));
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000050a1');
select is(pg_temp.fila_ciudad('mes', '2026-09-01', 'bd', 'c1'), '8.00|3|0.00|0',
          'con las zonas y las ciudades de campaña dadas de baja después, septiembre de Ana sigue igual (Ciudad uno)');
select is(pg_temp.fila_ciudad('mes', '2026-09-01', 'bd', 'c2'), '6.00|3|0.00|0',
          'y en Ciudad dos también');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 11. La función no escribe nada
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.jornada where colportor_id = pg_temp.u('b1')),
          9, 'las jornadas de b1 siguen siendo las 9 del fixture');
select is((select count(*)::int from public.jornada where colportor_id in (pg_temp.u('bb'), pg_temp.u('bc'))),
          8, 'y las de bb y bc, las 8 del fixture: el corte por inscripción no borra nada');

select * from finish();
rollback;
