-- pgTAP · ventas y presentaciones por ciudad y colportor (migración 0061, backend-supabase#96, HU-REP-002)
-- ventas_por_ciudad_y_colportor(): el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido,
-- coordinador de otra campaña) y que una campaña terminada se lee; los errores de campaña y de
-- parámetros; las ventas, los montos y las presentaciones por día, semana y mes (qué visitas cuentan,
-- las dadas de baja, el día de Montevideo, los bordes de la campaña, la baja de la inscripción, la
-- ciudad de la zona actual y «sin ciudad»); el período anterior (el lunes contra el sábado, la semana
-- anterior, el mes contra el mes pasado, lo en curso sin comparar salvo el mes a la fecha); el rango a
-- períodos completos y su tope; los filtros; que un colportor cuenta desde el día en que se inscribió
-- en la campaña (dos campañas con fechas superpuestas no cuentan lo mismo dos veces); lo cobrado
-- nulo hasta V2; que la respuesta no trae nada de más.
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

-- El uuid de un personaje del test: a0..a4, ad, b1..bA, c1.., e1.., d1.., 71.., f1..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000051' || p_sufijo)::uuid
$$;

-- Hoy en Montevideo (hoy_montevideo() no se ejecuta como authenticated).
create or replace function pg_temp.hoy() returns date language sql stable as $$
  select (now() at time zone 'America/Montevideo')::date
$$;

-- La fila de un período y un colportor, como texto:
-- ventas|monto|presentaciones|en_curso|ventas_anterior|monto_anterior|presentaciones_anterior (null = vacío).
create or replace function pg_temp.fila(p_camp text, p_desde date, p_hasta date, p_agr text,
                                        p_inicio date, p_colp text)
returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s|%s|%s', r.ventas, r.monto_total, r.presentaciones, r.en_curso::text,
                  r.ventas_anterior, r.monto_anterior, r.presentaciones_anterior)
      from public.ventas_por_ciudad_y_colportor(pg_temp.u(p_camp), p_desde, p_hasta, p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- La ciudad de esa fila.
create or replace function pg_temp.ciudad_de(p_camp text, p_desde date, p_hasta date, p_agr text,
                                             p_inicio date, p_colp text)
returns text language sql as $$
  select coalesce((
    select coalesce(r.ciudad_nombre, '(sin ciudad)') || '/' || coalesce(r.ciudad_id::text, 'null')
      from public.ventas_por_ciudad_y_colportor(pg_temp.u(p_camp), p_desde, p_hasta, p_agr) r
     where r.periodo_inicio = p_inicio and r.colportor_id = pg_temp.u(p_colp)), 'sin fila')
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Cierre y En curso; a2 coordinador de Otra; ad admin; a0 colportor;
--        a3 sin ningún rol; a4 coordinador con el rol vencido.
-- Colportores: b1 Alfa (zona Centro, c1)  b2 Bravo (Centro, c1)  b3 Cruz (zona Costa, c2)
--        b4 Duarte (sin zona)  b5 Eguren (su zona se dio de baja)  b6 Fuentes (inscripción de
--        baja el 15/09)  b7 Gómez (NO inscripto)  b8, b9, ba (de En curso, zona Cerro, c1)
--        bb Hache (su campania_ciudad se da de baja)  bc Lima (de Otra, se inscribe el 09/09).
--        b1 también está en Otra, inscripto el 14/09.
-- Campañas: e1 Cierre (03/08/2026 a 30/09/2026, terminada, a1)  e2 Otra (a2)  e4 Borrada (a1)
--        e6 En curso (desde hoy - 90, sin fin, a1)
-- Ciudades: c1 «Ciudad uno q96» y c2 «Ciudad dos q96» (en ese orden alfabético: dos antes que uno).
-- campania_ciudad: 71 Cierre/c1  72 Cierre/c2  73 En curso/c1  74 Otra/c2  75 Cierre/c3 (se da de baja)
-- Zonas: d1 Centro (en 71)  d2 Costa (en 72)  d3 Baja (en 71, se da de baja)  d4 Cerro (en 73)  d5 Tres (en 75)
-- Donde se vende: ubicación f1, espacio f2, vínculo f3 (persona f4): todas las visitas y ventas cuelgan de ahí.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'ventas-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8','b9','ba','bb','bc']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo'), ('b9','Iris','Ibarra'),
               ('ba','Juan','Jara'), ('bb','Kari','Hache'), ('bc','Lola','Lima')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais ventas', 'ZS');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q96', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Ciudad dos q96', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c3'), 'Ciudad tres q96', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Cierre',   'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otra',     'VERANO', '2026-08-03', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada',  'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), now()),
  (pg_temp.u('e6'), 'En curso', 'VERANO', pg_temp.hoy() - 90, null,   pg_temp.u('a1'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('73'), pg_temp.u('e6'), pg_temp.u('c1')),
  (pg_temp.u('74'), pg_temp.u('e2'), pg_temp.u('c2')),
  (pg_temp.u('75'), pg_temp.u('e1'), pg_temp.u('c3'));

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa',  pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb),
  (pg_temp.u('d3'), 'Baja',   pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.95],[-56.17,-34.95],[-56.17,-34.94],[-56.19,-34.94],[-56.19,-34.95]]]}'::jsonb),
  (pg_temp.u('d4'), 'Cerro',  pg_temp.u('73'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.98],[-56.17,-34.98],[-56.17,-34.97],[-56.19,-34.97],[-56.19,-34.98]]]}'::jsonb),
  (pg_temp.u('d5'), 'Tres',   pg_temp.u('75'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-35.00],[-56.17,-35.00],[-56.17,-34.99],[-56.19,-34.99],[-56.19,-35.00]]]}'::jsonb);

-- `created_at` explícito: un colportor cuenta desde el día en que se inscribió en la campaña. Los de
-- Cierre, desde el 01/08 (antes de que empiece); los de En curso, desde hace 100 días.
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), pg_temp.u('d2'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d3'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b6'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('bb'), pg_temp.u('d5'), '2026-08-01 10:00-03'),
  (pg_temp.u('e6'), pg_temp.u('b8'), pg_temp.u('d4'), now() - interval '100 days'),
  (pg_temp.u('e6'), pg_temp.u('b9'), pg_temp.u('d4'), now() - interval '100 days'),
  (pg_temp.u('e6'), pg_temp.u('ba'), pg_temp.u('d4'), now() - interval '100 days'),
  -- Otra (a2): bc se inscribe el 09/09 a las 15:00 y b1, que ya trabajó en Cierre, el 14/09 a las 12:00.
  (pg_temp.u('e2'), pg_temp.u('bc'), null,            '2026-09-09 15:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b1'), null,            '2026-09-14 12:00-03');
-- La zona de b5 se da de baja, la ciudad de la campaña de bb también; la inscripción de b6 se da de baja
-- el 15/09 a mediodía.
update public.zona set deleted_at = now() where id = pg_temp.u('d3');
update public.campania_ciudad set deleted_at = now() where id = pg_temp.u('75');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b6');

-- Donde cuelgan las visitas y las ventas (las FK lo piden; la función no las mira).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

-- Ventas de Cierre (monto en centavos; horas locales de Montevideo, UTC-3). Semana 1 = lun 07/09 a dom 13/09.
--   b1: lun 07/09 100000 + 50000, y una de 40000 dada de baja (no cuenta); mar 08: 20000; lun 14: 30000;
--       mar 15 23:30 (cruza a la medianoche UTC): 10000; fuera de la campaña: 20/07 y 02/10 (5000 c/u).
--   b2: lun 07/09: 60000; los bordes: lun 03/08 00:00 (primer día, 1111) y mié 30/09 23:59 (último, 2222)
--       cuentan; sáb 02/08 23:59 (999) y jue 01/10 00:00 (888) no.
--   b3: lun 07/09: 3 de 10000; jue 20/08: 5000.   b4: 08/09: 7000 y el domingo 13/09: 500.   b5: 08/09: 1000.
--   bb: 08/09: 800.
--   b6: jue 10/09: 2000 (antes de la baja); dom 20/09: 3000 (después: no cuenta).
--   b7: lun 07/09: 99999 (no está inscripto en Cierre).
--   bc (de Otra, inscripto el 09/09 15:00): mar 08/09: 5000 y una ENTREVISTA (antes de inscribirse: no
--       cuentan); mié 09/09 08:00: 1000 y una ENTREVISTA 09:00 (el mismo día, antes de la hora: cuentan,
--       la regla es por día); jue 10/09: 2000.
insert into public.venta (espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, deleted_at)
select pg_temp.u('f3'), 'T-' || row_number() over (), x.m, x.f::timestamptz, pg_temp.u(x.s), x.baja
  from (values
    ('b1', '2026-09-07 09:00-03', 100000, null::timestamptz),
    ('b1', '2026-09-07 15:00-03', 50000,  null),
    ('b1', '2026-09-07 16:00-03', 40000,  now()),
    ('b1', '2026-09-08 10:00-03', 20000,  null),
    ('b1', '2026-09-14 10:00-03', 30000,  null),
    ('b1', '2026-09-15 23:30-03', 10000,  null),
    ('b1', '2026-07-20 10:00-03', 5000,   null),
    ('b1', '2026-10-02 10:00-03', 5000,   null),
    ('b2', '2026-09-07 09:00-03', 60000,  null),
    ('b2', '2026-08-03 00:00-03', 1111,   null),
    ('b2', '2026-09-30 23:59-03', 2222,   null),
    ('b2', '2026-08-02 23:59-03', 999,    null),
    ('b2', '2026-10-01 00:00-03', 888,    null),
    ('b3', '2026-09-07 09:00-03', 10000,  null),
    ('b3', '2026-09-07 10:00-03', 10000,  null),
    ('b3', '2026-09-07 11:00-03', 10000,  null),
    ('b3', '2026-08-20 10:00-03', 5000,   null),
    ('b4', '2026-09-08 10:00-03', 7000,   null),
    ('b4', '2026-09-13 10:00-03', 500,    null),
    ('bb', '2026-09-08 10:00-03', 800,    null),
    ('b5', '2026-09-08 10:00-03', 1000,   null),
    ('b6', '2026-09-10 10:00-03', 2000,   null),
    ('b6', '2026-09-20 10:00-03', 3000,   null),
    ('b7', '2026-09-07 09:00-03', 99999,  null),
    ('bc', '2026-09-08 10:00-03', 5000,   null),
    ('bc', '2026-09-09 08:00-03', 1000,   null),
    ('bc', '2026-09-10 10:00-03', 2000,   null)
  ) x(s, f, m, baja);

-- Visitas de Cierre. Presentación = VENTA o ENTREVISTA; NO_CONTESTO y RECHAZO no cuentan.
--   b1: lun 07/09: VENTA, VENTA, ENTREVISTA (3), NO_CONTESTO ×2, RECHAZO y una ENTREVISTA dada de baja (no
--       cuentan); mar 08: ENTREVISTA; sáb 12: ENTREVISTA ×2; lun 14: VENTA; mar 15 23:30: ENTREVISTA;
--       fuera de la campaña: 20/07 y 02/10.
--   b2: lun 07/09: VENTA.   b3: lun 07/09: ENTREVISTA ×5; jue 20/08: ENTREVISTA.   b4: 08/09: ENTREVISTA.
--   b7: lun 07/09: ENTREVISTA (no inscripto).
insert into public.visita (espacio_persona_id, fecha, tipo_resultado, colportor_id, deleted_at)
select pg_temp.u('f3'), x.f::timestamptz, x.t, pg_temp.u(x.s), x.baja
  from (values
    ('b1', '2026-09-07 09:00-03', 'VENTA',       null::timestamptz),
    ('b1', '2026-09-07 10:00-03', 'VENTA',       null),
    ('b1', '2026-09-07 11:00-03', 'ENTREVISTA',  null),
    ('b1', '2026-09-07 12:00-03', 'NO_CONTESTO', null),
    ('b1', '2026-09-07 13:00-03', 'NO_CONTESTO', null),
    ('b1', '2026-09-07 14:00-03', 'RECHAZO',     null),
    ('b1', '2026-09-07 15:00-03', 'ENTREVISTA',  now()),
    ('b1', '2026-09-08 10:00-03', 'ENTREVISTA',  null),
    ('b1', '2026-09-12 10:00-03', 'ENTREVISTA',  null),
    ('b1', '2026-09-12 11:00-03', 'ENTREVISTA',  null),
    ('b1', '2026-09-14 10:00-03', 'VENTA',       null),
    ('b1', '2026-09-15 23:30-03', 'ENTREVISTA',  null),
    ('b1', '2026-07-20 10:00-03', 'ENTREVISTA',  null),
    ('b1', '2026-10-02 10:00-03', 'ENTREVISTA',  null),
    ('b2', '2026-09-07 09:00-03', 'VENTA',       null),
    ('b3', '2026-09-07 09:00-03', 'ENTREVISTA',  null),
    ('b3', '2026-09-07 10:00-03', 'ENTREVISTA',  null),
    ('b3', '2026-09-07 11:00-03', 'ENTREVISTA',  null),
    ('b3', '2026-09-07 12:00-03', 'ENTREVISTA',  null),
    ('b3', '2026-09-07 13:00-03', 'ENTREVISTA',  null),
    ('b3', '2026-08-20 10:00-03', 'ENTREVISTA',  null),
    ('b4', '2026-09-08 10:00-03', 'ENTREVISTA',  null),
    ('b7', '2026-09-07 09:00-03', 'ENTREVISTA',  null),
    ('bc', '2026-09-08 11:00-03', 'ENTREVISTA',  null),
    ('bc', '2026-09-09 09:00-03', 'ENTREVISTA',  null)
  ) x(s, f, t, baja);

-- Lo de En curso (relativo a hoy, para lo en curso):
--   b8: hoy una venta de 10000 y una ENTREVISTA, y hace 7 días una venta de 5000.   ba: ayer una de 20000.
--   b9: hoy una de 3000, y en el mes pasado los días 1 (4000), 15 (2000) y 28 (5000).
insert into public.venta (espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
select pg_temp.u('f3'), 'E-' || row_number() over (), x.m,
       (x.dia + time '10:00') at time zone 'America/Montevideo', pg_temp.u(x.s)
  from (values
    ('b8',  pg_temp.hoy(),     10000),
    ('b8',  pg_temp.hoy() - 7, 5000),
    ('ba',  pg_temp.hoy() - 1, 20000),
    ('b9',  pg_temp.hoy(),     3000),
    ('b9',  (date_trunc('month', pg_temp.hoy()::timestamp) - interval '1 month')::date,        4000),
    ('b9',  (date_trunc('month', pg_temp.hoy()::timestamp) - interval '1 month')::date + 14,   2000),
    ('b9',  (date_trunc('month', pg_temp.hoy()::timestamp) - interval '1 month')::date + 27,   5000)
  ) x(s, dia, m);
insert into public.visita (espacio_persona_id, fecha, tipo_resultado, colportor_id)
values (pg_temp.u('f3'), (pg_temp.hoy() + time '10:30') at time zone 'America/Montevideo', 'ENTREVISTA', pg_temp.u('b8'));

-- ---------------------------------------------------------------------------
-- 1. La función: forma y privilegios
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-07', 'dia') r limit 1)) k
                 order by k collate "C")),
          array['apellido','ciudad_id','ciudad_nombre','cobrado','cobrado_anterior','colportor_id',
                'en_curso','monto_anterior','monto_total','nombre','periodo_fin','periodo_inicio',
                'presentaciones','presentaciones_anterior','ventas','ventas_anterior'],
          'la forma de la respuesta: solo totales (sin clientes, cobros, talonarios, ubicaciones ni emails)');
select pg_temp.actuar_como_servidor();

select is((select p.prosecdef from pg_proc p where p.oid = 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          true, 'es SECURITY DEFINER (el coordinador no lee venta ni visita ajenas)');
select is((select p.provolatile from pg_proc p where p.oid = 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          'v', 'es VOLATILE (llama a lanzar_motivo_mapa())');
select is((select p.proconfig from pg_proc p where p.oid = 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          array['search_path=""'], 'fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute'),
          'anon NO la ejecuta');
select ok(not has_function_privilege('service_role', 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])', 'execute'),
          'service_role NO la ejecuta (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.ventas_por_ciudad_y_colportor(uuid,date,date,text,uuid,uuid[])'::regprocedure),
          0, 'no tiene EXECUTE para PUBLIC');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'ventas_por_ciudad_y_colportor'),
          1, 'hay una sola firma');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'sin JWT (el servidor) falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'authenticated sin sesión falla');

select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como_servidor();

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a0');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un colportor no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051b1');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un colportor inscripto en la campaña tampoco ve ni sus propias ventas por acá');
-- El permiso va antes que la existencia y que los parámetros.
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051ff', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-13', '2026-09-07', 'año') $$,
  '42501', null, 'un colportor con parámetros inválidos: 42501, no 22023');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a3');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a4');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'con el rol de coordinador vencido falla');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a2');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', null, 'el coordinador de otra campaña no ve las ventas de esta');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus reportes. Entrá con la cuenta del coordinador de esta campaña.',
  'el mensaje del 42501 dice quién puede y habla de reportes');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-13', '2026-09-07', 'año') $$,
  '42501', null, 'el de otra campaña con parámetros inválidos: 42501, no 22023');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051ff', '2026-09-07', '2026-09-13', 'semana') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña y de parámetros (como el coordinador de la campaña)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e4', '2026-09-07', '2026-09-13', 'semana') $$,
  'CZ001', null, 'una campaña dada de baja: CZ001');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor(null, '2026-09-07', '2026-09-13', 'semana') $$,
  'CZ001', null, 'una campaña nula: CZ001');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'año') $$,
  '22023', 'Elegí cómo agrupar las ventas: por día, por semana o por mes.', 'agrupación inválida');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', null) $$,
  '22023', null, 'agrupación nula');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'Semana') $$,
  '22023', null, 'la agrupación distingue mayúsculas');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-13', '2026-09-07', 'dia') $$,
  '22023', 'Elegí un rango de fechas: la fecha de inicio no puede ser posterior a la de fin.', 'desde posterior a hasta');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', null, '2026-09-13', 'dia') $$,
  '22023', null, 'desde nulo');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', null, 'dia') $$,
  '22023', null, 'hasta nulo');
select lives_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-01-01', '2027-01-01', 'dia') $$,
  '366 días en días: pasa');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-01-01', '2027-01-02', 'dia') $$,
  '22023', 'El rango es demasiado largo: pedí hasta 366 días por vez.', '367 días en días: error, no se recorta');
select lives_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-01-01', '2026-12-31', 'mes') $$,
  'doce meses: pasa');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-01-15', '2027-01-10', 'mes') $$,
  '22023', null, 'trece meses (el rango sube a meses completos): error');
select throws_ok($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-01-01', '2026-12-31', 'semana') $$,
  '22023', null, 'el año entero en semanas: sube a lunes y domingo y pasa de 366 días');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Una campaña terminada se lee, y el ADMIN lee cualquiera
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select isnt_empty($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  'Cierre terminó el 30/09 y el coordinador la lee (el reporte se pide al cierre)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051ad');
select isnt_empty($$ select * from public.ventas_por_ciudad_y_colportor('01920000-0000-7000-8000-0000000051e1', '2026-09-07', '2026-09-13', 'semana') $$,
  'un ADMIN lee las ventas de cualquier campaña');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Por día (lun 07/09 a mié 16/09)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');

select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b1'),
          '2|150000|3|false|0|0|0',
          'b1 el lunes 07: 2 ventas (la dada de baja no) por 150000 y 3 presentaciones (VENTA, VENTA, ENTREVISTA; ni NO_CONTESTO, ni RECHAZO, ni la dada de baja)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-08', 'b1'),
          '1|20000|1|false|2|150000|3', 'b1 el martes 08: se compara con el lunes');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-09', 'b1'),
          '0|0|0|false|1|20000|1', 'b1 el miércoles 09 sin nada: fila vacía con el martes como anterior');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-10', 'b1'),
          'sin fila', 'b1 el jueves 10: ni datos ni anterior, sin fila');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-12', 'b1'),
          '0|0|2|false|0|0|0', 'b1 el sábado 12: sin ventas y 2 presentaciones (una fila con solo presentaciones existe)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-13', 'b1'),
          '0|0|0|false|0|0|2', 'b1 el domingo 13: sin nada, con el sábado como anterior');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-14', 'b1'),
          '1|30000|1|false|0|0|2', 'b1 el lunes 14: el anterior es el SÁBADO (2 presentaciones), no el domingo');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-15', 'b1'),
          '1|10000|1|false|1|30000|1', 'b1 el martes 15: la venta de las 23:30 cuenta en el 15 (día de Montevideo, no de UTC)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-16', 'b1'),
          '0|0|0|false|1|10000|1', 'b1 el miércoles 16: nada ocurrió ese día');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-16', 'dia')
            where colportor_id = pg_temp.u('b1')),
          8, 'b1 por día: 8 filas (07, 08, 09, 12, 13, 14, 15 y 16)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-13', 'b4'),
          '1|500|0|false|0|0|0', 'b4 el domingo 13: se vendió (el domingo existe) y no hay sábado con qué comparar');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-14', 'b4'),
          'sin fila', 'b4 el lunes 14: el anterior es el sábado, no el domingo (que no se compara con nadie)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b2'),
          '1|60000|1|false|0|0|0', 'b2 el 07: 1 venta y 1 presentación (la visita VENTA cuenta)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-08', 'b2'),
          '0|0|0|false|1|60000|1', 'b2 el 08: fila vacía por el 07');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b7'),
          'sin fila', 'b7 no está inscripto en la campaña: su venta de 99999 no sale');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-10', 'b6'),
          '1|2000|0|false|0|0|0', 'b6 el 10: antes de la baja de la inscripción, cuenta');
select is(pg_temp.fila('e1', '2026-09-18', '2026-09-22', 'dia', '2026-09-20', 'b6'),
          'sin fila', 'b6 el 20: después de la baja de la inscripción, no cuenta');

-- La zona horaria de la sesión no mueve el día.
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-15', 'b1'),
          '1|10000|1|false|1|30000|1', 'con la sesión en Pacific/Kiritimati (UTC+14) el día sigue siendo el de Montevideo');
select set_config('TimeZone', 'Etc/GMT+12', true);
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-16', 'dia', '2026-09-07', 'b1'),
          '2|150000|3|false|0|0|0', 'con la sesión en Etc/GMT+12 (UTC-12) tampoco');
select set_config('TimeZone', 'UTC', true);

-- Los bordes de la campaña: el primer y el último día cuentan, el anterior y el posterior no.
select is(pg_temp.fila('e1', '2026-08-01', '2026-08-05', 'dia', '2026-08-03', 'b2'),
          '1|1111|0|false|0|0|0', 'la venta de las 00:00 del primer día de la campaña (03/08) cuenta');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-08-01', '2026-08-02', 'dia')
            where colportor_id = pg_temp.u('b2')),
          0, 'la venta de las 23:59 del día anterior al inicio (02/08) no cuenta');
select is(pg_temp.fila('e1', '2026-09-29', '2026-09-30', 'dia', '2026-09-30', 'b2'),
          '1|2222|0|false|0|0|0', 'la venta de las 23:59 del último día de la campaña (30/09) cuenta');
select is(pg_temp.fila('e1', '2026-10-01', '2026-10-02', 'dia', '2026-10-01', 'b2'),
          '0|0|0|false|1|2222|0', 'la del 01/10 (888) no cuenta: solo queda la comparación con el 30/09');
select is((select sum(ventas)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-10-01', '2026-10-02', 'dia')),
          0, 'después del fin de la campaña no hay ventas (b1 vendió el 02/10)');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-07-18', '2026-07-22', 'dia')),
          0, 'antes del inicio de la campaña (b1 vendió y visitó el 20/07): sin filas');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-21', '2026-09-22', 'dia')
            where colportor_id = pg_temp.u('b6')),
          0, 'b6 el 21 y 22/09: sin filas (la venta del 20 es posterior a su baja)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Por semana (lun 07/09 a dom 20/09): la ciudad de la zona actual
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana')),
          14, 'por semana: 14 filas (7 colportores × 2 semanas)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b1'),
          '3|170000|6|false|0|0|0', 'b1 semana 1: 3 ventas por 170000 y 6 presentaciones');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b1'),
          '2|40000|2|false|3|170000|6', 'b1 semana 2 contra la semana anterior completa');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b2'),
          '1|60000|1|false|0|0|0', 'b2 semana 1');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b2'),
          '0|0|0|false|1|60000|1', 'b2 semana 2: sin datos, con la anterior (para que la suma de la ciudad sea la de verdad)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b3'),
          '3|30000|5|false|0|0|0', 'b3 semana 1: 3 ventas de 10000 y 5 presentaciones');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b6'),
          '1|2000|0|false|0|0|0', 'b6 semana 1');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b6'),
          '0|0|0|false|1|2000|0', 'b6 semana 2: la venta del 20 (después de la baja) no suma');

select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b1'),
          'Ciudad uno q96/01920000-0000-7000-8000-0000000051c1', 'b1 es de la ciudad de su zona (Centro)');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b3'),
          'Ciudad dos q96/01920000-0000-7000-8000-0000000051c2', 'b3 es de la ciudad de su zona (Costa)');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b4'),
          '(sin ciudad)/null', 'b4 sin zona: sin ciudad');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b5'),
          '(sin ciudad)/null', 'b5, con la zona dada de baja: sin ciudad');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b6'),
          '(sin ciudad)/null', 'b6, con la inscripción dada de baja: sin ciudad');
select is(pg_temp.ciudad_de('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'bb'),
          '(sin ciudad)/null', 'bb, con la ciudad de la campaña de su zona dada de baja: sin ciudad');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana')
            where colportor_id = pg_temp.u('b4')),
          1, 'sin zona aparece UNA sola vez, no repetido en cada ciudad (los totales no se inflan)');
select is((select sum(ventas)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana')),
          12, 'el total de ventas de la semana 1 es la suma de los inscriptos (3 + 1 + 3 + 2 + 1 + 1 + 1)');
select is((select sum(monto_total)::bigint from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana')),
          271300::bigint, 'el total vendido de la semana 1: 170000 + 60000 + 30000 + 7500 + 1000 + 2000 + 800');
select is((select sum(presentaciones)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana')),
          13, 'el total de presentaciones de la semana 1: 6 + 1 + 5 + 1');

-- El orden: período, ciudad por nombre (sin ciudad al final), apellido.
select is((select array(select left(r.apellido, 3)
                          from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-13', 'semana') r)),
          array['Cru','Alf','Bra','Dua','Egu','Fue','Hac'],
          'el orden: Ciudad dos, Ciudad uno (por apellido), sin ciudad (por apellido)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. Por mes (ago y sep de 2026)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-08-01', 'b3'),
          '1|5000|1|false|0|0|0', 'b3 agosto: 1 venta y 1 presentación; julio sin datos');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-09-01', 'b3'),
          '3|30000|5|false|1|5000|1', 'b3 septiembre contra agosto completo');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-09-01', 'b1'),
          '5|210000|8|false|0|0|0', 'b1 septiembre: 5 ventas por 210000 y 8 presentaciones (lo del 20/07 y del 02/10 queda fuera)');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-08-01', 'b1'),
          'sin fila', 'b1 agosto: sin nada');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-08-01', 'b2'),
          '1|1111|0|false|0|0|0', 'b2 agosto: la venta del primer día de la campaña');
select is(pg_temp.fila('e1', '2026-08-01', '2026-09-30', 'mes', '2026-09-01', 'b2'),
          '2|62222|1|false|1|1111|0', 'b2 septiembre: incluye la del último día (30/09)');
select is((select periodo_inicio::text || '..' || periodo_fin::text
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-08-01', '2026-09-30', 'mes')
            where colportor_id = pg_temp.u('b3') and periodo_inicio = '2026-09-01'),
          '2026-09-01..2026-09-30', 'el mes va del 1 al 30');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 8. El rango sube a períodos completos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is((select min(periodo_inicio)::text || '..' || max(periodo_fin)::text
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-09', '2026-09-09', 'semana')),
          '2026-09-07..2026-09-13', 'semana: un miércoles pide la semana de lunes a domingo');
select is(pg_temp.fila('e1', '2026-09-09', '2026-09-09', 'semana', '2026-09-07', 'b1'),
          '3|170000|6|false|0|0|0', 'y trae la semana entera, no solo desde el miércoles');
select is(pg_temp.fila('e1', '2026-09-20', '2026-09-25', 'mes', '2026-09-01', 'b3'),
          '3|30000|5|false|1|5000|1', 'mes: el 20 al 25 de septiembre trae septiembre entero');
select is((select min(periodo_inicio)::text from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-08', '2026-09-16', 'dia')),
          '2026-09-08', 'día: no se redondea nada');
-- Lo anterior se lee aunque quede fuera del rango pedido.
select is(pg_temp.fila('e1', '2026-09-14', '2026-09-14', 'dia', '2026-09-14', 'b1'),
          '1|30000|1|false|0|0|2', 'día: pedir solo un lunes trae el sábado (dos días atrás) como anterior');
select is(pg_temp.fila('e1', '2026-09-14', '2026-09-14', 'semana', '2026-09-14', 'b1'),
          '2|40000|2|false|3|170000|6', 'semana: pedir solo la semana 2 trae la semana 1 como anterior');
select is(pg_temp.fila('e1', '2026-09-01', '2026-09-30', 'mes', '2026-09-01', 'b2'),
          '2|62222|1|false|1|1111|0', 'mes: pedir solo septiembre trae agosto entero (la venta del 03/08) como anterior');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 9. Filtros
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is((select string_agg(distinct left(apellido, 3), ',' order by left(apellido, 3))
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c1'))),
          'Alf,Bra', 'p_ciudad_id = ciudad uno: solo los de esa ciudad');
select is((select string_agg(distinct left(apellido, 3), ',' order by left(apellido, 3))
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c2'))),
          'Cru', 'p_ciudad_id = ciudad dos');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c3'))),
          0, 'una ciudad que no es de la campaña: sin filas (y no es un error)');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana',
                                                       '00000000-0000-0000-0000-000000000000')),
          0, 'el uuid cero no es «sin ciudad»');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', null,
                                                       array[pg_temp.u('b1')])),
          2, 'p_colportor_ids = [b1]: sus 2 semanas');
select is((select count(distinct colportor_id)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', null,
                                                       array[pg_temp.u('b1'), pg_temp.u('b3'), pg_temp.u('b7')])),
          2, 'p_colportor_ids = [b1, b3, b7]: b7 no está inscripto y no aparece');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', pg_temp.u('c1'),
                                                       array[pg_temp.u('b3')])),
          0, 'ciudad uno y un colportor de ciudad dos: sin filas');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-20', 'semana', null, '{}')),
          0, 'una lista de colportores vacía: sin filas');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 9b. Un colportor cuenta desde el día en que se inscribió en ESTA campaña
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a2');
select is(pg_temp.fila('e2', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'bc'),
          '2|3000|1|false|0|0|0',
          'bc, inscripto el 09/09 a las 15:00: la venta y la presentación del 08/09 no cuentan; las del 09/09 (antes de la hora, el mismo día) y la del 10/09 sí');
select is(pg_temp.fila('e2', '2026-09-08', '2026-09-08', 'dia', '2026-09-08', 'bc'),
          'sin fila', 'bc el 08/09, el día anterior a su inscripción: sin fila');
select is(pg_temp.fila('e2', '2026-09-09', '2026-09-10', 'dia', '2026-09-09', 'bc'),
          '1|1000|1|false|0|0|0', 'bc el 09/09, el día de su inscripción: cuenta entero, aunque antes de la hora');
select is(pg_temp.fila('e2', '2026-09-09', '2026-09-10', 'dia', '2026-09-10', 'bc'),
          '1|2000|0|false|1|1000|1', 'bc el 10/09, contra el 09/09');
select is(pg_temp.ciudad_de('e2', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'bc'),
          '(sin ciudad)/null', 'bc, sin zona: sin ciudad');
-- b1 ya trabajó en Cierre y se inscribió en Otra el 14/09: la otra campaña no le ve lo de antes.
select is(pg_temp.fila('e2', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b1'),
          'sin fila', 'b1 en Otra, semana del 07/09 (antes de inscribirse en Otra): sin fila, sus ventas son de Cierre');
select is(pg_temp.fila('e2', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b1'),
          '2|40000|2|false|0|0|0',
          'b1 en Otra, semana del 14/09: el 14 (el día de su inscripción) y el 15 cuentan, y la semana anterior no se le atribuye');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e2'), '2026-09-07', '2026-09-13', 'dia')
            where colportor_id = pg_temp.u('b1')),
          0, 'b1 en Otra, del 07 al 13/09: ninguna fila (ni vacía)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-07', 'b1'),
          '3|170000|6|false|0|0|0', 'y en Cierre b1 sigue igual (la inscripción en Otra no le saca nada)');
select is(pg_temp.fila('e1', '2026-09-07', '2026-09-20', 'semana', '2026-09-14', 'b1'),
          '2|40000|2|false|3|170000|6', 'incluida la semana del 14/09');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 10. Lo en curso (e6, fechas relativas a hoy)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
-- Día: hoy no se compara; ayer sí.
select is(pg_temp.fila('e6', pg_temp.hoy() - 1, pg_temp.hoy(), 'dia', pg_temp.hoy(), 'b8'),
          '1|10000|1|true|||', 'día: hoy está en curso y no se compara (los tres «_anterior» son null)');
select is(pg_temp.fila('e6', pg_temp.hoy() - 1, pg_temp.hoy(), 'dia', pg_temp.hoy() - 1, 'ba'),
          '1|20000|0|false|0|0|0', 'día: ayer (completo) sí se compara');
select is(pg_temp.fila('e6', pg_temp.hoy() - 1, pg_temp.hoy(), 'dia', pg_temp.hoy(), 'ba'),
          'sin fila', 'día: hoy sin nada y en curso no deja una fila vacía con el anterior escondido');
-- Semana: la semana en curso no se compara, aunque la anterior tenga datos (b8 vendió hace 7 días).
select is(pg_temp.fila('e6', pg_temp.hoy(), pg_temp.hoy(), 'semana',
                        date_trunc('week', pg_temp.hoy()::timestamp)::date, 'b8'),
          '1|10000|1|true|||', 'semana: la semana en curso no se compara');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e6'), pg_temp.hoy() - 7, pg_temp.hoy() - 7, 'semana')
            where colportor_id = pg_temp.u('b8') and not en_curso),
          1, 'semana: la anterior (completa) sale sin ser la en curso');
-- Mes: el mes en curso SÍ se compara, contra el mismo tramo del mes pasado.
select is(pg_temp.fila('e6', pg_temp.hoy(), pg_temp.hoy(), 'mes',
                        date_trunc('month', pg_temp.hoy()::timestamp)::date, 'b9'),
          '1|3000|0|true|'
          || (1 + case when extract(day from pg_temp.hoy()) >= 15 then 1 else 0 end
                + case when extract(day from pg_temp.hoy()) >= 28 then 1 else 0 end)::text
          || '|'
          || (4000 + case when extract(day from pg_temp.hoy()) >= 15 then 2000 else 0 end
                   + case when extract(day from pg_temp.hoy()) >= 28 then 5000 else 0 end)::text
          || '|0',
          'mes en curso: se compara con los días 1 a N del mes pasado, siendo N el día de hoy');
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e6'), pg_temp.hoy(), pg_temp.hoy(), 'mes')
            where colportor_id = pg_temp.u('b9') and periodo_inicio = date_trunc('month', pg_temp.hoy()::timestamp)::date),
          1, 'mes en curso: una sola fila por colportor');
-- Lo que no ocurrió todavía no sale: ni períodos futuros.
select is((select count(*)::int
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e6'), pg_temp.hoy() + 1, pg_temp.hoy() + 30, 'dia')),
          0, 'los días futuros no salen');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 11. Lo cobrado viene nulo hasta V2, y la función no escribe nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000051a1');
select is((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-08-01', '2026-09-30', 'semana')
            where cobrado is not null or cobrado_anterior is not null),
          0, 'cobrado y cobrado_anterior son null en todas las filas (V2: sin conectar)');
select cmp_ok((select count(*)::int from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-08-01', '2026-09-30', 'semana')),
              '>', 0, 'y sí hay filas (el null no es una respuesta vacía)');
select is((select pg_typeof(r.cobrado)::text || ',' || pg_typeof(r.cobrado_anterior)::text
             from public.ventas_por_ciudad_y_colportor(pg_temp.u('e1'), '2026-09-07', '2026-09-07', 'dia') r limit 1),
          'bigint,bigint', 'cobrado y cobrado_anterior son bigint (centavos, como monto_total)');
select pg_temp.actuar_como_servidor();

select is((select count(*)::int from public.venta where colportor_id = pg_temp.u('b1')),
          8, 'las ventas de b1 siguen siendo las 8 del fixture');
select is((select count(*)::int from public.visita where colportor_id = pg_temp.u('b1')),
          14, 'las visitas de b1 siguen siendo las 14 del fixture');

select * from finish();
rollback;
