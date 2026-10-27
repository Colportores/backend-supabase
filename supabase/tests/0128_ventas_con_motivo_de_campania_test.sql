-- pgTAP · el coordinador lee el motivo del monto manual (migración 0128, backend-supabase#154)
-- ventas_con_motivo_de_campania(): el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido,
-- coordinador de otra campaña); los errores de campaña y de parámetros; qué ventas salen (solo las con
-- motivo, las vivas, los bordes de la campaña, la ventana de inscripción: alta con su hora, baja y hueco
-- de `tramos_afuera`, un colportor no inscripto); los montos (total y suma de los ítems vivos, en
-- centavos); la ciudad de la zona que tenía el colportor en el instante de la venta (historial de zonas: cambio de zona, baja
-- posterior de la inscripción, zona o ciudad dadas de baja después, días sin zona, tramo borrado); los filtros; el orden; el motivo tal cual (500 caracteres,
-- con tildes); que la respuesta no trae nada del cliente ni de dónde fue ni el talonario; y que el
-- coordinador sigue sin poder leer `venta` (sin política nueva).
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

-- El rol `anon`.
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- El uuid de un personaje del test (sufijo hex de dos caracteres).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000054' || p_sufijo)::uuid
$$;

-- Los dos últimos caracteres del id de cada venta que devuelve la lectura, en el orden en que salen.
create or replace function pg_temp.ids(p_camp text, p_desde date, p_hasta date,
                                       p_ciudad text default null, p_colps text[] default null)
returns text language sql as $$
  select coalesce(string_agg(right(r.venta_id::text, 2), ',' order by r.ord), '-')
    from public.ventas_con_motivo_de_campania(
           pg_temp.u(p_camp), p_desde, p_hasta,
           case when p_ciudad is null then null else pg_temp.u(p_ciudad) end,
           case when p_colps is null then null
                else coalesce((select array_agg(pg_temp.u(x)) from unnest(p_colps) x), array[]::uuid[]) end)
         with ordinality as r(venta_id, colportor_id, nombre, apellido, ciudad_id, ciudad_nombre, fecha,
                              monto_total, suma_items, motivo, ord)
$$;

-- Una venta de la lectura como texto: colportor|ciudad|total|suma|motivo (ciudad null = «-»).
create or replace function pg_temp.fila(p_camp text, p_venta text)
returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s|%s', right(r.colportor_id::text, 2), coalesce(r.ciudad_nombre, '-'),
                  r.monto_total, r.suma_items, r.motivo)
      from public.ventas_con_motivo_de_campania(pg_temp.u(p_camp), '2026-01-01', '2026-12-31') r
     where r.venta_id = pg_temp.u(p_venta)), 'sin fila')
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Cierre; a2 coordinador de Otra; ad admin; a0 colportor; a3 sin ningún rol;
--        a4 coordinador con el rol vencido.
-- Colportores: b1 Alfa (zona Centro, c1)  b2 Bravo (zona Costa, c2)  b3 Cruz (sin zona)
--        b4 Duarte (zona Centro; su inscripción se da de baja el 15/09 a las 09:00 hora de Montevideo)
--        b5 Eguren (zona Centro; fuera de la campaña del 10/09 al 12/09 a las 00:00: un hueco)
--        b6 Fuentes (zona Centro; se inscribe el 09/09 a las 12:00)  b7 Gómez (NO inscripto)
--        b8 Haedo (de Otra).
-- Campañas: e1 Cierre (03/08/2026 a 30/09/2026, terminada, a1)  e2 Otra (desde el 03/08, sin fin, a2)
--        e4 Borrada (a1)
-- Ciudades: c1 «Ciudad uno q154» y c2 «Ciudad dos q154». campania_ciudad: 71 Cierre/c1  72 Cierre/c2.
-- Zonas: d1 Centro (en 71)  d2 Costa (en 72).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'motivo-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1','b2','b3','b4','b5','b6','b7','b8']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b5','Elena','Eguren'), ('b6','Fede','Fuentes'),
               ('b7','Gabi','Gómez'), ('b8','Hugo','Haedo')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais motivo', 'ZM');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q154', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Ciudad dos q154', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'Cierre',  'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'Otra',    'VERANO', '2026-08-03', null,         pg_temp.u('a2'), null),
  (pg_temp.u('e4'), 'Borrada', 'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1'), now());
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costa',  pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb);

insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d2'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null,            '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d1'), '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b6'), pg_temp.u('d1'), '2026-09-09 12:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b8'), null,            '2026-08-01 10:00-03');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
update public.campania_colportor
   set tramos_afuera = array[tstzrange('2026-09-10 00:00-03'::timestamptz, '2026-09-12 00:00-03'::timestamptz, '[)')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b5');

-- El historial de zonas (0022): los triggers lo abren con la hora de ahora; se reemplaza por tramos con fechas de
-- verdad (desde <= instante < hasta):
--   b1: Centro (d1) del 01/08 al 20/09 00:00 y después Costa (d2): un cambio de zona a mitad de campaña.
--   b2: Costa (d2) desde el 03/08 a las 12:00: antes de eso no tenía zona.
--   b3: un tramo de Centro BORRADO (deleted_at): no cuenta, sigue sin zona.
--   b4: Centro hasta la baja de la inscripción (15/09 12:00 UTC): la baja es posterior a la venta 40.
--   b5: Centro hasta el 12/09 10:00 y Costa desde ahí (el instante exacto de la venta 52: el desde cuenta, el hasta no).
--   b6: Centro desde que se inscribió hasta el 20/09 00:00 (lo quitaron de la zona, sin otra): la venta 63 de ese instante exacto
--       ya no tiene zona.
delete from public.campania_colportor_zona_historial
 where campania_colportor_id in (select id from public.campania_colportor where campania_id = pg_temp.u('e1'));
insert into public.campania_colportor_zona_historial (campania_colportor_id, zona_id, desde, hasta, deleted_at)
select cc.id, pg_temp.u(x.zona), x.desde::timestamptz, x.hasta::timestamptz, x.borrado::timestamptz
  from (values
    ('b1', 'd1', '2026-08-01 10:00-03', '2026-09-20 00:00-03', null),
    ('b1', 'd2', '2026-09-20 00:00-03', null,                   null),
    ('b2', 'd2', '2026-08-03 12:00-03', null,                   null),
    ('b3', 'd1', '2026-08-01 10:00-03', null,                   '2026-10-01 00:00+00'),
    ('b4', 'd1', '2026-08-01 10:00-03', '2026-09-15 12:00+00', null),
    ('b5', 'd1', '2026-08-01 10:00-03', '2026-09-12 10:00-03', null),
    ('b5', 'd2', '2026-09-12 10:00-03', null,                   null),
    ('b6', 'd1', '2026-09-09 12:00-03', '2026-09-20 00:00-03', null)
  ) x(colp, zona, desde, hasta, borrado)
  join public.campania_colportor cc on cc.campania_id = pg_temp.u('e1') and cc.usuario_id = pg_temp.u(x.colp);

-- Donde cuelgan las ventas (las FK lo piden; la lectura no las mira).
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle de prueba', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro p1 motivo', 'LIBRO'),
  (pg_temp.u('12'), 'Revista p2 motivo', 'REVISTA');

-- Ventas (monto en centavos; horas locales de Montevideo, UTC-3). El id (2 caracteres) dice cuál es.
--   b1: 10 lun 07/09 09:00, total 85000 con motivo «descuento por pago en efectivo» y ítems de 50000 + 39000
--           (+ un ítem de 5000 dado de baja, que no suma);
--       11 lun 07/09 15:00, sin motivo (no sale); 12 lun 07/09 16:00, con motivo pero dada de baja (no sale);
--       13 lun 14/09 10:00, con motivo y sin ítems (suma 0); 24 lun 21/09 10:00 (la misma hora que la 16 de b2, que tiene el id
--       más chico: el orden de un empate es por apellido, no por id); 14 y 15, con motivo pero antes (20/07) y después
--       (02/10) de la campaña (no salen).
--   b2: 20 lun 03/08 00:00 y 21 mié 30/09 23:59 (los bordes: cuentan; el 21 con un motivo de 500 caracteres
--       con tildes); 22 sáb 02/08 23:59 y 23 jue 01/10 00:00 (no).
--   b3: 30 08/09 10:00 (sin zona).
--   b4: 40 jue 10/09 (antes de la baja: sale); 41 dom 20/09 (después de la baja: no).
--   b5: 50 mié 09/09 (antes del hueco: sale); 51 vie 11/09 (en el hueco: no); 52 sáb 12/09 10:00 (vuelve: sale).
--   b6 (inscripto el 09/09 a las 12:00): 60 mar 08/09 (antes: no); 61 mié 09/09 08:00 (el mismo día, antes de la
--       hora: no); 62 mié 09/09 16:00 (sale); 63 dom 20/09 00:00 (sale, sin ciudad: ver el historial).
--   b7 (no inscripto en Cierre): 70 lun 07/09 (no sale).
--   b8 (de Otra): 80 lun 07/09 (sale de Otra, no de Cierre).
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id,
                          motivo_monto_manual, deleted_at)
select pg_temp.u(x.id), pg_temp.u('f3'), 'M-' || x.id, x.m, x.f::timestamptz, pg_temp.u(x.s), x.motivo, x.baja
  from (values
    ('10', 'b1', '2026-09-07 09:00-03', 85000, 'descuento por pago en efectivo', null::timestamptz),
    ('11', 'b1', '2026-09-07 15:00-03', 50000, null,                             null),
    ('12', 'b1', '2026-09-07 16:00-03', 40000, 'dada de baja',                   now()),
    ('13', 'b1', '2026-09-14 10:00-03', 1000,  'sin ítems',                      null),
    ('14', 'b1', '2026-07-20 10:00-03', 5000,  'antes de la campaña',            null),
    ('15', 'b1', '2026-10-02 10:00-03', 5000,  'después de la campaña',         null),
    ('24', 'b1', '2026-09-21 10:00-03', 3000,  'a la misma hora que la 16',     null),
    ('16', 'b2', '2026-09-21 10:00-03', 3000,  'a la misma hora que la 24',     null),
    ('20', 'b2', '2026-08-03 00:00-03', 1111,  'borde de inicio',                null),
    ('21', 'b2', '2026-09-30 23:59-03', 2222,  repeat('é', 500),                 null),
    ('22', 'b2', '2026-08-02 23:59-03', 999,   'un minuto antes',                null),
    ('23', 'b2', '2026-10-01 00:00-03', 888,   'un minuto después',              null),
    ('30', 'b3', '2026-09-08 10:00-03', 7000,  'sin zona',                       null),
    ('40', 'b4', '2026-09-10 10:00-03', 2000,  'antes de la baja',               null),
    ('41', 'b4', '2026-09-20 10:00-03', 3000,  'después de la baja',             null),
    ('50', 'b5', '2026-09-09 10:00-03', 1000,  'antes del hueco',                null),
    ('51', 'b5', '2026-09-11 10:00-03', 1000,  'en el hueco',                    null),
    ('52', 'b5', '2026-09-12 10:00-03', 1000,  'después del hueco',              null),
    ('60', 'b6', '2026-09-08 10:00-03', 1000,  'antes de inscribirse',           null),
    ('61', 'b6', '2026-09-09 08:00-03', 1000,  'el mismo día, antes de la hora', null),
    ('62', 'b6', '2026-09-09 16:00-03', 1000,  'después de inscribirse',         null),
    ('63', 'b6', '2026-09-20 00:00-03', 1000,  'justo cuando terminó su tramo',    null),
    ('70', 'b7', '2026-09-07 09:00-03', 99999, 'no inscripto',                   null),
    ('80', 'b8', '2026-09-07 09:00-03', 4000,  'de otra campaña',                null)
  ) x(id, s, f, m, motivo, baja);

insert into public.venta_item (venta_id, producto_id, cantidad, precio_unitario, subtotal, deleted_at) values
  (pg_temp.u('10'), pg_temp.u('11'), 1, 50000, 50000, null),
  (pg_temp.u('10'), pg_temp.u('12'), 1, 39000, 39000, null),
  (pg_temp.u('10'), pg_temp.u('12'), 1, 5000,  5000,  now()),
  (pg_temp.u('11'), pg_temp.u('11'), 1, 50000, 50000, null),
  (pg_temp.u('21'), pg_temp.u('11'), 2, 1000,  2000,  null);

-- ---------------------------------------------------------------------------
-- 1. La forma y los privilegios
-- ---------------------------------------------------------------------------
select is((select count(*) from pg_proc where proname = 'ventas_con_motivo_de_campania' and pronamespace = 'public'::regnamespace),
          1::bigint, 'hay una sola firma');
select is((select p.proargnames::text from pg_proc p where p.oid = 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])'::regprocedure),
          '{p_campania_id,p_desde,p_hasta,p_ciudad_id,p_colportor_ids,venta_id,colportor_id,nombre,apellido,ciudad_id,ciudad_nombre,fecha,monto_total,suma_items,motivo}',
          'las columnas son las del issue: colportor, ciudad, fecha, total, suma de los ítems y motivo; nada del cliente, del espacio ni del talonario');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])'::regprocedure),
          true, 'es SECURITY DEFINER');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])'::regprocedure),
          'v', 'es VOLATILE (supabase-js la manda por POST)');
select is((select array_to_string(p.proconfig, ',') from pg_proc p where p.oid = 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])'::regprocedure),
          'search_path=""', 'tiene search_path vacío');
select is(has_function_privilege('authenticated', 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])', 'execute'),
          true, 'authenticated la ejecuta');
select is(has_function_privilege('anon', 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])', 'execute'),
          false, 'anon no la ejecuta');
select is(has_function_privilege('service_role', 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])', 'execute'),
          false, 'service_role no la ejecuta');
select is((select count(*) from pg_proc p, aclexplode(p.proacl) a
            where p.oid = 'public.ventas_con_motivo_de_campania(uuid,date,date,uuid,uuid[])'::regprocedure and a.grantee = 0),
          0::bigint, 'PUBLIC no la ejecuta');
-- Sin política SELECT nueva sobre `venta`: las que hay son las de siempre (la del dueño).
select is((select array_agg(policyname order by policyname) from pg_policies
            where schemaname = 'public' and tablename = 'venta' and cmd in ('SELECT', 'ALL') and permissive = 'PERMISSIVE'),
          array['venta_propio']::name[], 'venta no gana ninguna política SELECT: solo la del dueño');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'authenticated sin sesión falla');
select pg_temp.actuar_como_anon();
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a0');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'un colportor no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054b1');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'el colportor inscripto en la campaña no lee ni el motivo de sus propias ventas por acá');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054ff', '2026-09-30', '2026-08-03') $$,
  '42501', null, 'un colportor con campaña inexistente y fechas inválidas: 42501, no CZ001 ni 22023');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a3');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a4');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', null, 'con el rol de coordinador vencido falla');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a2');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', '2026-09-30') $$,
  '42501', 'Solo el coordinador de la campaña o un administrador puede ver sus reportes. Entrá con la cuenta del coordinador de esta campaña.',
  'el coordinador de otra campaña no ve las ventas de esta; el mensaje dice quién puede y habla de reportes');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-09-30', '2026-08-03') $$,
  '42501', null, 'el de otra campaña con fechas inválidas: 42501, no 22023');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054ff', '2026-08-03', '2026-09-30') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña y de parámetros (como el coordinador de la campaña)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e4', '2026-08-03', '2026-09-30') $$,
  'CZ001', null, 'una campaña dada de baja: CZ001');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania(null, '2026-08-03', '2026-09-30') $$,
  'CZ001', null, 'una campaña nula: CZ001');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-09-30', '2026-08-03') $$,
  '22023', 'Elegí un rango de fechas: la fecha de inicio no puede ser posterior a la de fin.', 'desde posterior a hasta');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', null, '2026-09-30') $$,
  '22023', null, 'desde nulo');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-08-03', null) $$,
  '22023', null, 'hasta nulo');
select lives_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-01-01', '2027-01-01') $$,
  '366 días: pasa');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-01-01', '2027-01-02') $$,
  '22023', 'El rango es demasiado largo: pedí hasta 366 días por vez.', '367 días: error, no se recorta');
select lives_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e1', '2026-09-07', '2026-09-07') $$,
  'un solo día: pasa');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Qué ventas salen (el coordinador de la campaña, una campaña ya terminada)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
-- Más reciente primero. Salen: 21 20 16 (b2) 24 13 10 (b1) 30 (sin zona) 40 (b4) 50 52 (b5) 62 63 (b6).
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31'), '21,24,16,63,13,52,40,62,50,30,10,20',
  'salen solo las ventas con motivo, vivas, dentro de la campaña y de la ventana de inscripción, la más reciente primero');
select is(pg_temp.ids('e1', '2026-08-03', '2026-09-30'), '21,24,16,63,13,52,40,62,50,30,10,20',
  'el período de la campaña entera da lo mismo: el día 03/08 y el 30/09 están incluidos');
-- Una sin motivo, una dada de baja, dos fuera de las fechas de la campaña.
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31') ~ '(^|,)(11|12|14|15|22|23)(,|$)', false,
  'ni la venta sin motivo, ni la dada de baja, ni las de fuera de las fechas de la campaña');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31') ~ '(^|,)(41|51|60|61|70|80)(,|$)', false,
  'ni después de la baja, ni en el hueco, ni antes de inscribirse (con su hora), ni un no inscripto, ni otra campaña');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Qué trae cada fila
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
select is(pg_temp.fila('e1', '10'), 'b1|Ciudad uno q154|85000|89000|descuento por pago en efectivo',
  'el caso de uso: total 85000, suma de los ítems 89000 (el ítem dado de baja no suma), el motivo de Ana');
select is(pg_temp.fila('e1', '13'), 'b1|Ciudad uno q154|1000|0|sin ítems', 'una venta sin ítems: suma 0, no null');
select is(pg_temp.fila('e1', '20'), 'b2|-|1111|0|borde de inicio', 'un día sin tramo en el historial (b2 tuvo zona desde las 12:00): sin ciudad');
select is(pg_temp.fila('e1', '16'), 'b2|Ciudad dos q154|3000|0|a la misma hora que la 24', 'la ciudad de la zona de b2 ese día');
select is(pg_temp.fila('e1', '10'), 'b1|Ciudad uno q154|85000|89000|descuento por pago en efectivo', 'cambio de zona: la venta de antes del cambio es de la ciudad de antes');
select is(pg_temp.fila('e1', '24'), 'b1|Ciudad dos q154|3000|0|a la misma hora que la 16', 'cambio de zona: la de después, de la ciudad nueva (la zona actual de b1 es Costa)');
select is(pg_temp.fila('e1', '52'), 'b5|Ciudad dos q154|1000|0|después del hueco', 'el instante exacto del cambio es del tramo nuevo (desde incluido, hasta excluido)');
select is(pg_temp.fila('e1', '21'), 'b2|Ciudad dos q154|2222|2000|' || repeat('é', 500),
  'un motivo de 500 caracteres con tildes vuelve entero');
select is(pg_temp.fila('e1', '30'), 'b3|-|7000|0|sin zona', 'sin zona: la ciudad es null');
select is(pg_temp.fila('e1', '63'), 'b6|-|1000|0|justo cuando terminó su tramo', 'el instante en que termina el último tramo ya no es de esa zona (hasta excluido)');
select is(pg_temp.fila('e1', '40'), 'b4|Ciudad uno q154|2000|0|antes de la baja', 'una inscripción dada de baja después: la venta conserva la ciudad de su día (R7)');
select is((select r.fecha from public.ventas_con_motivo_de_campania(pg_temp.u('e1'), '2026-09-07', '2026-09-07') r),
          '2026-09-07 09:00-03'::timestamptz, 'la fecha es el instante de la venta');
select is((select format('%s %s', r.nombre, r.apellido) from public.ventas_con_motivo_de_campania(pg_temp.u('e1'), '2026-09-07', '2026-09-07') r),
          'Ana Alfa', 'el nombre del colportor');
select is((select pg_typeof(r.monto_total)::text || ',' || pg_typeof(r.suma_items)::text
             from public.ventas_con_motivo_de_campania(pg_temp.u('e1'), '2026-09-07', '2026-09-07') r),
          'bigint,bigint', 'los importes son bigint (centavos)');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Los filtros
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
select is(pg_temp.ids('e1', '2026-09-07', '2026-09-07'), '10', 'un solo día');
select is(pg_temp.ids('e1', '2026-09-08', '2026-09-10'), '40,62,50,30', 'un período en el medio (los dos bordes incluidos)');
select is(pg_temp.ids('e1', '2026-09-15', '2026-12-31'), '21,24,16,63', 'el período de después: lo posterior al 14/09 hasta el último día de la campaña');
select is(pg_temp.ids('e1', '2026-01-01', '2026-08-31'), '20', 'el período de antes: solo el primer día de la campaña');
select is(pg_temp.ids('e1', '2026-09-12', '2026-09-12'), '52', 'un día solo, el de la vuelta del hueco');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', 'c1'), '13,40,62,50,10', 'por ciudad: las que fueron de Centro (c1) ese día, también la de b4 (dado de baja después) y la de b1 antes de su cambio');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', 'c2'), '21,24,16,52', 'por ciudad: las que fueron de Costa (c2) ese día, con la de b1 después de su cambio y sin la de b2 de antes de tener zona');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', 'ee'), '-', 'por una ciudad que no es de la campaña: vacío, no error');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', null, array['b1']), '24,13,10', 'por colportor');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', null, array['b1', 'b3']), '24,13,30,10', 'por dos colportores (uno sin zona)');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', null, array['b7']), '-', 'por un colportor no inscripto: vacío');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', null, array[]::text[]), '-', 'una lista vacía de colportores: vacío');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', 'c1', array['b1', 'b2']), '13,10', 'ciudad y colportores a la vez');
-- La zona horaria de la sesión no cambia el día de Montevideo (la 21 es del 30/09 a las 23:59 allá, 01/10 en UTC).
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(pg_temp.ids('e1', '2026-08-03', '2026-09-30'), '21,24,16,63,13,52,40,62,50,30,10,20',
  'con otra zona horaria en la sesión sale lo mismo');
select set_config('TimeZone', 'UTC', true);
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. Cada coordinador lee su campaña; el ADMIN, cualquiera
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a2');
select is(pg_temp.ids('e2', '2026-01-01', '2026-12-31'), '80', 'el coordinador de Otra (sin fecha de fin) lee solo lo suyo');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
select throws_ok($$ select * from public.ventas_con_motivo_de_campania('01920000-0000-7000-8000-0000000054e2', '2026-09-07', '2026-09-07') $$,
  '42501', null, 'el coordinador de Cierre no lee Otra');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054ad');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31'), '21,24,16,63,13,52,40,62,50,30,10,20', 'el ADMIN lee Cierre');
select is(pg_temp.ids('e2', '2026-01-01', '2026-12-31'), '80', 'el ADMIN lee Otra');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 8. Sin datos del cliente ni de dónde fue ni el talonario, y sin política nueva
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
select is((select array_agg(k order by k) from public.ventas_con_motivo_de_campania(pg_temp.u('e1'), '2026-09-07', '2026-09-07') r,
                                       jsonb_object_keys(to_jsonb(r)) k),
          array['apellido','ciudad_id','ciudad_nombre','colportor_id','fecha','monto_total','motivo','nombre','suma_items','venta_id'],
          'la fila lleva solo esas diez claves');
select is((select count(*) from public.ventas_con_motivo_de_campania(pg_temp.u('e1'), '2026-01-01', '2026-12-31') r
            where to_jsonb(r)::text ~* (pg_temp.u('f3')::text || '|' || pg_temp.u('f2')::text || '|' || pg_temp.u('f1')::text || '|M-[0-9]')),
          0::bigint, 'en ninguna fila aparece el vínculo, el espacio, la ubicación ni el talonario');
select is((select count(*) from public.venta), 0::bigint, 'el coordinador sigue sin leer `venta` directo (RLS)');
select is((select count(*) from public.venta_item), 0::bigint, 'ni `venta_item`');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 9. La zona o la ciudad de la campaña dadas de baja DESPUÉS no cambian el pasado
-- ---------------------------------------------------------------------------
update public.zona set deleted_at = now() where id = pg_temp.u('d2');
update public.campania_ciudad set deleted_at = now() where id = pg_temp.u('71');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000054a1');
select is(pg_temp.fila('e1', '21'), 'b2|Ciudad dos q154|2222|2000|' || repeat('é', 500), 'con la zona dada de baja después, la venta sigue en su ciudad');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', 'c2'), '21,24,16,52', 'y sigue saliendo por la ciudad c2');
select is(pg_temp.fila('e1', '10'), 'b1|Ciudad uno q154|85000|89000|descuento por pago en efectivo', 'con la ciudad de la campaña dada de baja después, la venta sigue en su ciudad');
select is(pg_temp.ids('e1', '2026-01-01', '2026-12-31', 'c1'), '13,40,62,50,10', 'y sigue saliendo por la ciudad c1');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 99. Cierra
-- ---------------------------------------------------------------------------
select * from finish();
rollback;
