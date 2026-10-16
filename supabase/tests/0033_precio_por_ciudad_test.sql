-- pgTAP · migración 0027 (backend-supabase#26): el precio de venta cuelga de la ciudad de la campaña
-- (campania_ciudad), no de la zona. La tabla se llamaba precio_por_zona: 0030 (#71) la renombró a
-- precio_por_ciudad, y este archivo dice el nombre de hoy (0037 prueba el renombre).
--   1. La forma: campania_ciudad_id (NOT NULL, FK) en lugar de zona_id; las restricciones de no
--      solapamiento, el índice, las políticas y la entidad de sync.
--   2. Un precio vale para cualquier zona de la ciudad: dibujar, mover o dar de baja una zona no lo
--      toca; todos los colportores de la campaña lo leen, tengan la zona que tengan o ninguna.
--   3. Un solo precio vigente a la vez por producto o colección en cada campania_ciudad: otra
--      ciudad o otra campaña en la misma ciudad no se pisan; vigencias contiguas, sí; una baja
--      lógica no cuenta.
--   4. valido_desde por defecto = el día de Montevideo (hoy_montevideo()), no el de la sesión: con la
--      sesión en UTC+14 y en UTC-12 (que juntas dan otro día que el de Uruguay a cualquier hora).
--   5. RLS: escribe el ADMIN y el COORDINADOR de la campaña de esa campania_ciudad (otro
--      coordinador, un colportor y quien no tiene campañas, no); lee el ADMIN y quien ve esa
--      campania_ciudad (coordina la campaña, o está inscripto en una que no terminó): una campaña de
--      la misma ciudad no ve los precios de la otra, y la baja lógica se ve.
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
  select ('01920000-0000-7000-8000-0000000033' || p)::uuid;
$$;
create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;
-- Los precios de la prueba de visibilidad que el usuario actual ve (sufijo del id y si está dado de baja).
create or replace function pg_temp.veo() returns text language sql as $$
  select coalesce(string_agg(right(p.id::text, 2) || case when p.deleted_at is not null then 'x' else '' end,
                             ',' order by p.id), '-')
    from public.precio_por_ciudad p
   where p.id::text like '01920000-0000-7000-8000-00000000337%';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: a1 coordina e1; a2 coordina e2 y e3; a3 coordina e4 y además está inscripto en e2 (de e2 lee,
-- no escribe); ad es ADMIN; b1 (zona z1), b5 (zona z2) y b6 (sin zona) están inscriptos en e1; b2 en e2;
-- b3 en e3 (terminada); b4 en ninguna.
-- Campañas: e1 (c1 y c2) en curso; e2 (c1: la MISMA ciudad que e1) en curso; e3 (c3) terminada; e4 (c2) en curso.
-- Zonas: z1 y z2 (con colportores) y z3 (sin nadie), las tres en f1 (e1 en c1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'precio33-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a3','ad','b1','b2','b3','b4','b5','b6']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a3','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'),
               ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais precio33', 'ZP');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 precio33', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Ciudad c2 precio33', pg_temp.u('c0'), -34.70, -56.20),
  (pg_temp.u('c3'), 'Ciudad c3 precio33', pg_temp.u('c0'), -34.50, -56.30);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 precio33', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 precio33', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a2')),
  (pg_temp.u('e3'), 'e3 precio33', 'VERANO', public.hoy_montevideo() - 40, public.hoy_montevideo() - 1,  pg_temp.u('a2')),
  (pg_temp.u('e4'), 'e4 precio33', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a3'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e2'), pg_temp.u('c1')),
  (pg_temp.u('f4'), pg_temp.u('e3'), pg_temp.u('c3')),
  (pg_temp.u('f5'), pg_temp.u('e4'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  (pg_temp.u('d1'), 'Z1 precio33', pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91)),
  (pg_temp.u('d2'), 'Z2 precio33', pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.15, -34.88, -56.14, -34.87)),
  (pg_temp.u('d3'), 'Z3 precio33', pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.13, -34.86, -56.12, -34.85));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1')),
  (pg_temp.u('e1'), pg_temp.u('b5'), pg_temp.u('d2')),
  (pg_temp.u('e1'), pg_temp.u('b6'), null),
  (pg_temp.u('e2'), pg_temp.u('b2'), null),
  (pg_temp.u('e2'), pg_temp.u('a3'), null),
  (pg_temp.u('e3'), pg_temp.u('b3'), null);

insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('a1'), 'Libro A precio33', 'LIBRO'),
  (pg_temp.u('a2'), 'Libro B precio33', 'LIBRO'),
  (pg_temp.u('a3'), 'Libro C precio33', 'LIBRO'),
  (pg_temp.u('a4'), 'Libro D precio33', 'LIBRO'),
  (pg_temp.u('a5'), 'Libro E precio33', 'LIBRO'),
  (pg_temp.u('a6'), 'Libro F precio33', 'LIBRO'),
  (pg_temp.u('a7'), 'Libro G precio33', 'LIBRO'),
  (pg_temp.u('a8'), 'Libro de la visibilidad precio33', 'LIBRO'),
  (pg_temp.u('a9'), 'Libro de las escrituras precio33', 'LIBRO');
insert into public.coleccion (id, nombre) values (pg_temp.u('b0'), 'Coleccion precio33');

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'precio_por_ciudad', 'campania_ciudad_id', 'el precio tiene campania_ciudad_id');
select col_not_null('public', 'precio_por_ciudad', 'campania_ciudad_id', 'y es obligatorio');
select hasnt_column('public', 'precio_por_ciudad', 'zona_id', 'ya no tiene zona_id');
select fk_ok('public', 'precio_por_ciudad', 'campania_ciudad_id', 'public', 'campania_ciudad', 'id',
             'campania_ciudad_id apunta a campania_ciudad');
select ok(exists (select 1 from pg_indexes
                   where schemaname = 'public' and tablename = 'precio_por_ciudad'
                     and indexname = 'precio_por_ciudad_campania_ciudad_idx'
                     and indexdef like '%(campania_ciudad_id)%'),
          'el índice por campania_ciudad_id');
select ok(not exists (select 1 from pg_indexes
                       where schemaname = 'public' and tablename = 'precio_por_ciudad'
                         and indexname = 'precio_por_ciudad_zona_idx'),
          'y el de zona_id se fue con la columna');
select is((select count(*)::int from pg_constraint
             where conrelid = 'public.precio_por_ciudad'::regclass and contype = 'x'
               and conname in ('precio_por_ciudad_coleccion_sin_solape', 'precio_por_ciudad_producto_sin_solape')
               and pg_get_constraintdef(oid) like '%campania_ciudad_id WITH =%'),
          2, 'las dos restricciones de no solapamiento (producto y colección) son por campania_ciudad_id');
select matches(
  (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d
    where d.adrelid = 'public.precio_por_ciudad'::regclass
      and d.adnum = (select attnum from pg_attribute where attrelid = 'public.precio_por_ciudad'::regclass and attname = 'valido_desde')),
  'hoy_montevideo',
  'valido_desde se llena con hoy_montevideo(), no con current_date');
select policies_are('public', 'precio_por_ciudad',
  array['precio_por_ciudad_select', 'precio_por_ciudad_insert_staff', 'precio_por_ciudad_update_staff'],
  'las tres políticas (sin DELETE: la baja es lógica)');
select results_eq(
  $$ select sigue_campanias, permite_push from sync.entidad where nombre = 'precio_por_ciudad' $$,
  $$ values (true, false) $$,
  'en el sync es de solo bajada y sigue las campañas del usuario');
select ok(has_function_privilege('authenticated', 'public.hoy_montevideo(timestamptz)', 'execute'),
          'authenticated ejecuta hoy_montevideo (la evalúa el default, con quien inserta)');
select ok(not has_function_privilege('anon', 'public.hoy_montevideo(timestamptz)', 'execute'),
          'anon no');

-- ---------------------------------------------------------------------------
-- 2. El precio es de la ciudad: no depende de las zonas
-- ---------------------------------------------------------------------------
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde) values
  (pg_temp.u('60'), pg_temp.u('a1'), pg_temp.u('f1'), 25000, '2026-01-01');
create temp table v0 on commit drop as
  select sync_version from public.precio_por_ciudad where id = pg_temp.u('60');

update public.zona set nombre = 'Z1 redibujada precio33',
       poligono_geojson = pg_temp.rect(-56.195, -34.925, -56.18, -34.91)
 where id = pg_temp.u('d1');
update public.zona set deleted_at = now() where id = pg_temp.u('d3');
select is((select sync_version from public.precio_por_ciudad where id = pg_temp.u('60')),
          (select sync_version from v0),
          'redibujar una zona y dar de baja otra no tocan el precio (su sync_version no cambia)');

-- b1 (zona z1), b5 (zona z2) y b6 (sin zona) leen el mismo precio.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.precio_por_ciudad where id = pg_temp.u('60')), 1, 'b1 (zona z1) lee el precio de la ciudad');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is((select count(*)::int from public.precio_por_ciudad where id = pg_temp.u('60')), 1, 'b5 (zona z2), también');
select pg_temp.actuar_como(pg_temp.u('b6'));
select is((select count(*)::int from public.precio_por_ciudad where id = pg_temp.u('60')), 1, 'b6 (sin zona), también');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Un solo precio vigente a la vez por producto o colección en cada campania_ciudad
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a1', '01920000-0000-7000-8000-0000000033f1', 26000, '2026-06-01') $$,
  '23P01', 'conflicting key value violates exclusion constraint "precio_por_ciudad_producto_sin_solape"',
  'otro precio vigente del mismo producto en la misma ciudad de la campaña se rechaza');
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a1', '01920000-0000-7000-8000-0000000033f1', 25000, '2026-06-01') $$,
  '23P01', null, 'aunque valga lo mismo');
select lives_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a1', '01920000-0000-7000-8000-0000000033f2', 27000, '2026-01-01') $$,
  'el mismo producto en otra ciudad de la misma campaña se acepta');
select lives_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a1', '01920000-0000-7000-8000-0000000033f3', 28000, '2026-01-01') $$,
  'y en la misma ciudad pero de otra campaña (otra campania_ciudad), también: no se pisan');

-- Colección: la misma regla, con su restricción.
insert into public.precio_por_ciudad (producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde)
values (null, pg_temp.u('b0'), pg_temp.u('f1'), 45000, '2026-01-01');
select throws_ok(
  $$ insert into public.precio_por_ciudad (coleccion_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033b0', '01920000-0000-7000-8000-0000000033f1', 46000, '2026-02-01') $$,
  '23P01', 'conflicting key value violates exclusion constraint "precio_por_ciudad_coleccion_sin_solape"',
  'una colección con dos precios vigentes en la misma ciudad de la campaña se rechaza');
select lives_ok(
  $$ insert into public.precio_por_ciudad (coleccion_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033b0', '01920000-0000-7000-8000-0000000033f3', 46000, '2026-02-01') $$,
  'y la misma colección en otra campaña de la misma ciudad se acepta');

-- Vigencias contiguas (el día siguiente) no se pisan; una que entra en la anterior, sí.
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta)
values (pg_temp.u('61'), pg_temp.u('a2'), pg_temp.u('f1'), 10000, '2026-01-01', '2026-03-31');
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000003362', '01920000-0000-7000-8000-0000000033a2',
             '01920000-0000-7000-8000-0000000033f1', 12000, '2026-04-01') $$,
  'un precio que empieza el día siguiente al fin del anterior se acepta');
select throws_ok(
  $$ update public.precio_por_ciudad set valido_desde = '2026-03-31'
      where id = '01920000-0000-7000-8000-000000003362' $$,
  '23P01', null, 'y estirarlo hacia atrás, sobre el día final del anterior, se rechaza');
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta)
     values ('01920000-0000-7000-8000-0000000033a2', '01920000-0000-7000-8000-0000000033f1', 11000, '2026-03-15', '2026-04-10') $$,
  '23P01', null, 'un tramo que entra en dos vigencias se rechaza');

-- Un precio dado de baja no cuenta, ni al insertar ni al reactivarlo.
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde, deleted_at)
values (pg_temp.u('63'), pg_temp.u('a3'), pg_temp.u('f1'), 9000, '2026-01-01', now());
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000003364', '01920000-0000-7000-8000-0000000033a3',
             '01920000-0000-7000-8000-0000000033f1', 9500, '2026-01-01') $$,
  'un precio dado de baja no bloquea uno nuevo para el mismo producto y ciudad');
select throws_ok(
  $$ update public.precio_por_ciudad set deleted_at = null where id = '01920000-0000-7000-8000-000000003363' $$,
  '23P01', null, 'pero no se puede reactivar si ahora se pisa con el vigente');

-- Un precio sin ciudad no entra.
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, precio_venta) values ('01920000-0000-7000-8000-0000000033a4', 100) $$,
  '23502', null, 'sin campania_ciudad_id no se acepta');

-- ---------------------------------------------------------------------------
-- 4. valido_desde por defecto: el día de Montevideo, con la sesión en cualquier zona horaria
-- ---------------------------------------------------------------------------
-- a1 coordina e1: inserta sin valido_desde (productos distintos, para no pisarse).
select pg_temp.actuar_como(pg_temp.u('a1'));
select set_config('TimeZone', 'Pacific/Kiritimati', true);   -- UTC+14
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta)
values (pg_temp.u('54'), pg_temp.u('a4'), pg_temp.u('f1'), 31000);
select set_config('TimeZone', 'Etc/GMT+12', true);           -- UTC-12
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta)
values (pg_temp.u('55'), pg_temp.u('a5'), pg_temp.u('f1'), 32000);
select set_config('TimeZone', 'UTC', true);
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta)
values (pg_temp.u('56'), pg_temp.u('a6'), pg_temp.u('f1'), 33000);
select pg_temp.actuar_como_servidor();

select is((select valido_desde from public.precio_por_ciudad where id = pg_temp.u('54')), public.hoy_montevideo(),
          'con la sesión en UTC+14, valido_desde es el día de Montevideo');
select is((select valido_desde from public.precio_por_ciudad where id = pg_temp.u('55')), public.hoy_montevideo(),
          'con la sesión en UTC-12, también');
select is((select valido_desde from public.precio_por_ciudad where id = pg_temp.u('56')), public.hoy_montevideo(),
          'y con la sesión en UTC');
-- Control: con el `current_date` de antes, alguna de las dos sesiones habría guardado otro día
-- (UTC+14 de las 07:00 a las 24:00 de Uruguay; UTC-12 de las 00:00 a las 09:00).
select ok((now() at time zone 'Pacific/Kiritimati')::date <> public.hoy_montevideo()
          or (now() at time zone 'Etc/GMT+12')::date <> public.hoy_montevideo(),
          'control: current_date da otro día que Montevideo en alguna de las dos zonas extremas, a cualquier hora');

-- Con valido_desde explícito, el default no pesa.
select pg_temp.actuar_como(pg_temp.u('a1'));
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
values (pg_temp.u('57'), pg_temp.u('a7'), pg_temp.u('f1'), 34000, '2026-02-02');
select is((select valido_desde from public.precio_por_ciudad where id = pg_temp.u('57')), '2026-02-02'::date,
          'una fecha explícita se respeta');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. RLS: quién escribe
-- ---------------------------------------------------------------------------
-- a1 coordina e1 (f1 y f2): escribe ahí; no en f3 (e2, de a2) ni en f4 (e3, de a2).
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000003380', '01920000-0000-7000-8000-0000000033a9',
             '01920000-0000-7000-8000-0000000033f1', 100, '2026-01-01') $$,
  'el coordinador de la campaña carga un precio en su ciudad');
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a9', '01920000-0000-7000-8000-0000000033f3', 100, '2026-01-01') $$,
  '42501', null, 'no en una ciudad de otra campaña, aunque sea la misma ciudad (otro coordinador)');
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a9', '01920000-0000-7000-8000-0000000033f4', 100, '2026-01-01') $$,
  '42501', null, 'ni en una campaña de otro coordinador que ya terminó');
select lives_ok(
  $$ update public.precio_por_ciudad set precio_venta = 26000 where id = '01920000-0000-7000-8000-000000003360' $$,
  'actualiza un precio de su ciudad');
select is((select precio_venta from public.precio_por_ciudad where id = pg_temp.u('60')), 26000, 'y quedó actualizado');
select throws_ok(
  $$ update public.precio_por_ciudad set campania_ciudad_id = '01920000-0000-7000-8000-0000000033f3'
      where id = '01920000-0000-7000-8000-000000003360' $$,
  '42501', null, 'pero no puede pasar un precio a una ciudad de otra campaña');
select lives_ok(
  $$ update public.precio_por_ciudad set deleted_at = now() where id = '01920000-0000-7000-8000-000000003380' $$,
  'da de baja el precio (la baja es una actualización, no un delete)');
select throws_ok(
  $$ delete from public.precio_por_ciudad where id = '01920000-0000-7000-8000-000000003360' $$,
  '42501', null, 'borrar de verdad no se puede (authenticated no tiene DELETE)');

-- a2 (coordina e2 y e3): sus precios, sí; los de e1, ni los ve ni los cambia.
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*)::int from public.precio_por_ciudad where id = pg_temp.u('60')), 0,
          'otro coordinador no ve el precio de una campaña ajena');
update public.precio_por_ciudad set precio_venta = 1 where id = pg_temp.u('60');
select pg_temp.actuar_como_servidor();
select is((select precio_venta from public.precio_por_ciudad where id = pg_temp.u('60')), 26000,
          'y un update suyo sobre ese precio no cambia nada (0 filas)');
select pg_temp.actuar_como(pg_temp.u('a2'));
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000003381', '01920000-0000-7000-8000-0000000033a9',
             '01920000-0000-7000-8000-0000000033f3', 200, '2026-01-01') $$,
  'a2 carga el precio de su campaña (misma ciudad que e1, otra campania_ciudad)');
select pg_temp.actuar_como_servidor();

-- a3 coordina e4 y es colportor de e2: de e2 ve los precios (los lee: es una campaña que ve) pero no los
-- escribe; de e4, sí.
select pg_temp.actuar_como(pg_temp.u('a3'));
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000003383', '01920000-0000-7000-8000-0000000033a9',
             '01920000-0000-7000-8000-0000000033f5', 400, '2026-01-01') $$,
  'a3 carga el precio de la campaña que coordina');
select is((select count(*)::int from public.precio_por_ciudad where id = pg_temp.u('81')), 1,
          'control: ve el precio de la campaña en la que solo está inscripto');
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a2', '01920000-0000-7000-8000-0000000033f3', 100, '2026-01-01') $$,
  '42501', null, 'pero que coordine otra campaña no le da permiso de cargar precios en la que solo ve');
update public.precio_por_ciudad set precio_venta = 1 where id = pg_temp.u('81');
select pg_temp.actuar_como_servidor();
select is((select precio_venta from public.precio_por_ciudad where id = pg_temp.u('81')), 200,
          'ni cambiar el precio que lee (0 filas)');
select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok(
  $$ update public.precio_por_ciudad set campania_ciudad_id = '01920000-0000-7000-8000-0000000033f3'
      where id = '01920000-0000-7000-8000-000000003383' $$,
  '42501', null, 'ni pasar un precio suyo a esa campaña que solo ve');
select pg_temp.actuar_como_servidor();

-- Colportores y quien no está en ninguna campaña: no escriben.
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a9', '01920000-0000-7000-8000-0000000033f1', 100, '2026-05-05') $$,
  '42501', null, 'un colportor de la campaña no carga precios');
update public.precio_por_ciudad set precio_venta = 1 where id = pg_temp.u('60');
select pg_temp.actuar_como_servidor();
select is((select precio_venta from public.precio_por_ciudad where id = pg_temp.u('60')), 26000,
          'ni cambia los que lee');
select pg_temp.actuar_como(pg_temp.u('b4'));
select throws_ok(
  $$ insert into public.precio_por_ciudad (producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000033a9', '01920000-0000-7000-8000-0000000033f1', 100, '2026-05-05') $$,
  '42501', null, 'tampoco quien no está en ninguna campaña');
select pg_temp.actuar_como_servidor();

-- El ADMIN escribe en cualquier ciudad.
select pg_temp.actuar_como(pg_temp.u('ad'));
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000003382', '01920000-0000-7000-8000-0000000033a9',
             '01920000-0000-7000-8000-0000000033f4', 300, '2026-01-01') $$,
  'el ADMIN carga un precio en la campaña de cualquiera (incluso terminada)');
select lives_ok(
  $$ update public.precio_por_ciudad set precio_venta = 27000 where id = '01920000-0000-7000-8000-000000003360' $$,
  'y cambia uno de otra campaña');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. RLS: quién lee (con la baja lógica incluida)
-- ---------------------------------------------------------------------------
-- Un conjunto aparte, con ids 70..74 y su propio producto (pg_temp.veo() mira solo estos):
--   70 f1 (e1, c1) · 71 f3 (e2, c1) · 72 f4 (e3 terminada) · 73 f2 (e1, c2) · 74 f1 dado de baja
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde, deleted_at) values
  (pg_temp.u('70'), pg_temp.u('a8'), pg_temp.u('f1'), 1000, '2025-01-01', null),
  (pg_temp.u('71'), pg_temp.u('a8'), pg_temp.u('f3'), 1100, '2025-01-01', null),
  (pg_temp.u('72'), pg_temp.u('a8'), pg_temp.u('f4'), 1200, '2025-01-01', null),
  (pg_temp.u('73'), pg_temp.u('a8'), pg_temp.u('f2'), 1300, '2025-01-01', null),
  (pg_temp.u('74'), pg_temp.u('a8'), pg_temp.u('f1'), 900,  '2024-01-01', now());
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.veo(), '70,73,74x', 'el coordinador de e1 ve los precios de f1 y f2, con la baja lógica, y no los de e2 ni e3');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.veo(), '71,72', 'el de e2 y e3 ve los suyos, la campaña terminada incluida (el coordinador ve la suya)');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(pg_temp.veo(), '71', 'a3, coordinador inscripto en e2, ve el de e2 (y no los de e1)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.veo(), '70,71,72,73,74x', 'el ADMIN ve todos');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), '70,73,74x', 'b1, inscripto en e1, ve los de las dos ciudades de e1 (y la baja, para borrarla de su teléfono)');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.veo(), '70,73,74x', 'b5, con otra zona, los mismos');
select pg_temp.actuar_como(pg_temp.u('b6'));
select is(pg_temp.veo(), '70,73,74x', 'y b6, sin zona');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.veo(), '71', 'b2, inscripto en e2 (misma ciudad c1 que e1), solo ve el de e2: los de e1 no');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.veo(), '-', 'b3, inscripto en una campaña que ya terminó, no ve ninguno');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.veo(), '-', 'y b4, sin campañas, tampoco (antes cualquier autenticado leía todos)');
select pg_temp.actuar_como_servidor();

-- La inscripción da de baja la visión: b1 deja de ver los precios cuando se le da de baja.
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.veo(), '-', 'dado de baja de la campaña, b1 ya no ve sus precios');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
