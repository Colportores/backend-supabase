-- pgTAP · migración 0170 (backend-supabase#248): guardar_precios_de_la_ciudad(), la escritura de la
-- vista 27 del panel (HU-CAT-005, ADR-013).
--   1. La forma: argumentos, columnas, SECURITY DEFINER, VOLATILE, search_path vacío; EXECUTE solo
--      authenticated.
--   2. Quién la llama (la matriz): el ADMIN y el coordinador de ESA campaña (también si terminó);
--      sin JWT, anon, service_role, colportor, sin rol, rol vencido y coordinador de otra campaña
--      reciben 42501; la ciudad inexistente o quitada (CZ012) y la campaña dada de baja (CZ001).
--   3. La lista: PP001 (no es lista, vacía, más de 500), PP002 (cambio mal formado), PP003 (precio),
--      PP004 (repetido), PP005 (no existe o de baja). Todo o nada: un error no deja ni filas ni
--      eventos de auditoría.
--   4. Las vigencias: CREADA, CAMBIADA (cierra ayer y abre hoy; el mismo día corrige el importe),
--      QUITADA (cierra ayer; el mismo día, baja lógica), SIN_CAMBIO; tramos vencidos, futuros y de
--      baja que no se tocan; otra campaña de la misma ciudad que no se toca; nada se borra.
--   5. La auditoría: un evento por cambio efectivo, con el actor, la fila y los importes; ninguno por
--      SIN_CAMBIO. Un segundo guardado igual no cambia nada.
--      El tramo nuevo respeta el fin del vigente que reemplaza (K: sin futuro; L: con hueco hasta uno futuro).
--   6. La coherencia con precios_de_la_ciudad() (0037).
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
-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_rol(p_rol text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', p_rol, true);
  perform set_config('role', p_rol, true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000170' || p)::uuid;
$$;
-- «Hoy» de la aplicación: el día de Montevideo.
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Un cambio de la lista: el precio llega como JSON (26000, null, "26000", 10.5, true…).
create or replace function pg_temp.c(p_tipo text, p_id text, p_precio text) returns jsonb language sql as $$
  select jsonb_build_object('tipo', p_tipo, 'id', pg_temp.u(p_id), 'precio', p_precio::jsonb);
$$;
-- Guarda y devuelve las acciones en el orden de la lista.
create or replace function pg_temp.guardar(p_cc text, p_cambios jsonb) returns text language sql as $$
  select string_agg(r.accion, ',') from public.guardar_precios_de_la_ciudad(pg_temp.u(p_cc), p_cambios) r;
$$;
-- Los tramos de un producto o una colección en una ciudad, como precio:desde:hasta[:baja] con las fechas
-- en días desde hoy (~ = sin fin), por orden de inicio. Se lee como postgres.
create or replace function pg_temp.tramos(p_cc text, p_item text) returns text language sql as $$
  select coalesce(string_agg(p.precio_venta::text || ':' || (p.valido_desde - pg_temp.h())::text || ':'
                             || coalesce((p.valido_hasta - pg_temp.h())::text, '~')
                             || case when p.deleted_at is not null then ':baja' else '' end,
                             ' | ' order by p.valido_desde, (p.deleted_at is not null), p.id),
                  'SIN FILAS')
    from public.precio_por_ciudad p
   where p.campania_ciudad_id = pg_temp.u(p_cc)
     and (p.producto_id = pg_temp.u(p_item) or p.coleccion_id = pg_temp.u(p_item));
$$;
create or replace function pg_temp.eventos() returns integer language sql as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = 'precio_de_ciudad_guardado'
     and a.metadata ->> 'campania_ciudad_id' like '01920000-0000-7000-8000-0000000170%';
$$;
create or replace function pg_temp.filas() returns integer language sql as $$
  select count(*)::int from public.precio_por_ciudad p where p.campania_ciudad_id::text like '01920000-0000-7000-8000-0000000170%';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: ad es ADMIN; a1 coordina e1, e3 (terminada) y e4 (dada de baja); a2 coordina e2; a3 no
-- tiene ningún rol; a4 tiene el rol de coordinador vencido; b1 es colportor inscripto en e1.
-- campania_ciudad: f1 e1/c1, f2 e1/c2, f3 e1/c3 (quitada de la campaña), f4 e2/c1 (la MISMA ciudad real
-- que f1, otra campaña), f5 e3/c1 (terminada), f6 e4/c1 (campaña dada de baja).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'guardar170-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','a1','a2','a3','a4','b1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('b1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais guardar170', 'ZQ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Montevideo guardar170', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Salto guardar170', 'Departamento de prueba',      pg_temp.u('c0'), -31.40, -57.96),
  (pg_temp.u('c3'), 'Paysandu guardar170', 'Departamento de prueba',   pg_temp.u('c0'), -32.32, -58.08);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'e1 guardar170', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'e2 guardar170', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'e3 guardar170', 'VERANO', pg_temp.h() - 40, pg_temp.h() - 1,  pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'e4 guardar170', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1'), now());
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'), null),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2'), null),
  (pg_temp.u('f3'), pg_temp.u('e1'), pg_temp.u('c3'), now()),
  (pg_temp.u('f4'), pg_temp.u('e2'), pg_temp.u('c1'), null),
  (pg_temp.u('f5'), pg_temp.u('e3'), pg_temp.u('c1'), null),
  (pg_temp.u('f6'), pg_temp.u('e4'), pg_temp.u('c1'), null);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);

-- Catálogo. 17 y la colección d4 están dados de baja. Con categoría y código del editor distintos.
insert into public.producto (id, nombre, tipo, es_bonificable, deleted_at) values
  (pg_temp.u('11'), 'A sin excepcion t170',          'LIBRO', false, null),
  (pg_temp.u('12'), 'B excepcion igual t170',        'LIBRO', false, null),
  (pg_temp.u('13'), 'C excepcion de hoy t170',       'LIBRO', false, null),
  (pg_temp.u('14'), 'D excepcion vencida t170',      'LIBRO', false, null),
  (pg_temp.u('15'), 'E excepcion de baja t170',      'LIBRO', false, null),
  (pg_temp.u('16'), 'F con tramo futuro t170',       'LIBRO', false, null),
  (pg_temp.u('17'), 'Z producto de baja t170',       'LIBRO', false, now()),
  (pg_temp.u('18'), 'G para quitar t170',            'LIBRO', false, null),
  (pg_temp.u('19'), 'H para quitar el mismo dia t170', 'LIBRO', false, null),
  (pg_temp.u('1a'), 'I sin excepcion para quitar t170', 'LIBRO', false, null),
  (pg_temp.u('1b'), 'J limites del precio t170',   'LIBRO', false, null),
  (pg_temp.u('1c'), 'K vigente con fin sin futuro t170', 'LIBRO', false, null),
  (pg_temp.u('1d'), 'L vigente con fin y hueco t170', 'LIBRO', false, null);
insert into public.coleccion (id, nombre, deleted_at) values
  (pg_temp.u('d1'), 'Col con excepcion t170', null),
  (pg_temp.u('d2'), 'Col sin excepcion t170', null),
  (pg_temp.u('d4'), 'Col de baja t170', now());

-- Generales (Administración): algunos productos tienen general, para ver «rige el general» al quitar.
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  (pg_temp.u('21'), pg_temp.u('11'), null, 24000, pg_temp.h() - 100, null, null),
  (pg_temp.u('22'), pg_temp.u('18'), null, 20000, pg_temp.h() - 100, null, null),
  (pg_temp.u('23'), pg_temp.u('19'), null, 21000, pg_temp.h() - 100, null, null);

-- Excepciones por ciudad de la campaña (precio_por_ciudad), en f1 salvo que se diga:
--   31 B 25000 desde -30 · 32 C 26000 desde hoy · 33 D 21000 (-100 a -31, vencida) · 34 E 5000 desde -20
--   dada de baja · 35 F 25000 (-30 a +9) y 36 F 30000 desde +10 (el futuro) · 37 G 25000 desde -30 ·
--   38 H 27000 desde hoy · 39 colección d1 45000 desde -30 · 3a B en f4 (OTRA campaña) 29000 desde -30 ·
--   3b K 25000 (-30 a +9, sin tramo futuro) · 3c L 25000 (-30 a +5) y 3d L 30000 desde +20 (hueco de +6 a +19).
insert into public.precio_por_ciudad (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  (pg_temp.u('31'), pg_temp.u('12'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 30,  null,              null),
  (pg_temp.u('32'), pg_temp.u('13'), null, pg_temp.u('f1'), 26000, pg_temp.h(),       null,              null),
  (pg_temp.u('33'), pg_temp.u('14'), null, pg_temp.u('f1'), 21000, pg_temp.h() - 100, pg_temp.h() - 31, null),
  (pg_temp.u('34'), pg_temp.u('15'), null, pg_temp.u('f1'), 5000,  pg_temp.h() - 20,  null,              now()),
  (pg_temp.u('35'), pg_temp.u('16'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 30,  pg_temp.h() + 9,  null),
  (pg_temp.u('36'), pg_temp.u('16'), null, pg_temp.u('f1'), 30000, pg_temp.h() + 10,  null,              null),
  (pg_temp.u('37'), pg_temp.u('18'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 30,  null,              null),
  (pg_temp.u('38'), pg_temp.u('19'), null, pg_temp.u('f1'), 27000, pg_temp.h(),       null,              null),
  (pg_temp.u('39'), null, pg_temp.u('d1'), pg_temp.u('f1'), 45000, pg_temp.h() - 30,  null,              null),
  (pg_temp.u('3a'), pg_temp.u('12'), null, pg_temp.u('f4'), 29000, pg_temp.h() - 30,  null,              null),
  (pg_temp.u('3b'), pg_temp.u('1c'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 30,  pg_temp.h() + 9,  null),
  (pg_temp.u('3c'), pg_temp.u('1d'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 30,  pg_temp.h() + 5,  null),
  (pg_temp.u('3d'), pg_temp.u('1d'), null, pg_temp.u('f1'), 30000, pg_temp.h() + 20,  null,              null);

-- ---------------------------------------------------------------------------
-- 1. La forma y los privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'guardar_precios_de_la_ciudad', array['uuid', 'jsonb'], 'existe guardar_precios_de_la_ciudad(uuid, jsonb)');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'guardar_precios_de_la_ciudad'),
          1, 'y es una sola (sin sobrecargas)');
select is(pg_get_function_arguments('public.guardar_precios_de_la_ciudad(uuid,jsonb)'::regprocedure),
          'p_campania_ciudad_id uuid, p_cambios jsonb', 'recibe la ciudad de la campaña y la lista de cambios');
select is(pg_get_function_result('public.guardar_precios_de_la_ciudad(uuid,jsonb)'::regprocedure),
          'TABLE(tipo text, id uuid, accion text)', 'devuelve el tipo, el id y la acción de cada cambio');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.guardar_precios_de_la_ciudad(uuid,jsonb)'::regprocedure),
          true, 'es SECURITY DEFINER: escribe sin pasar por la RLS y el permiso lo decide la función');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.guardar_precios_de_la_ciudad(uuid,jsonb)'::regprocedure),
          'v', 'es VOLATILE (escribe)');
select ok((select 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = 'public.guardar_precios_de_la_ciudad(uuid,jsonb)'::regprocedure),
          'con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.guardar_precios_de_la_ciudad(uuid,jsonb)', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.guardar_precios_de_la_ciudad(uuid,jsonb)', 'execute'), 'anon no');
select ok(not has_function_privilege('service_role', 'public.guardar_precios_de_la_ciudad(uuid,jsonb)', 'execute'),
          'service_role tampoco (sin JWT no pasa el permiso)');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where p.oid = 'public.guardar_precios_de_la_ciudad(uuid,jsonb)'::regprocedure and a.grantee = 0), 0, 'ni PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. Quién la llama y el orden de los rechazos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'sin JWT: 42501');
select pg_temp.actuar_como_rol('anon');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'anon: 42501');
select pg_temp.actuar_como_rol('service_role');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'service_role: 42501');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'el colportor inscripto: 42501');
select pg_temp.actuar_como(pg_temp.u('a3'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'un usuario sin rol: 42501');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('00'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'sin rol y con una ciudad que no existe: el permiso va antes (42501, no CZ012)');
select pg_temp.actuar_como(pg_temp.u('a4'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'el coordinador con el rol vencido: 42501');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          '42501', 'el coordinador de OTRA campaña: 42501');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f6'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          'CZ001', 'una campaña dada de baja de otro coordinador: CZ001 (la existencia de la campaña va antes que el dueño, como en la lectura de la 0037)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('00'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          'CZ012', 'una ciudad de campaña que no existe: CZ012');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f3'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          'CZ012', 'una ciudad quitada de la campaña: CZ012');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f6'), jsonb_build_array(pg_temp.c('PRODUCTO','11','1000'))) $$),
          'CZ001', 'la campaña dada de baja: CZ001');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), null) $$),
          'PP001', 'el coordinador de la campaña pasa el permiso (y recién ahí mira la lista)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos(), 0, 'ningún rechazo escribió un evento');

-- ---------------------------------------------------------------------------
-- 3. La lista: forma de cada cambio, y todo o nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), '[]'::jsonb) $$), 'PP001', 'lista vacía: PP001');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), '{}'::jsonb) $$), 'PP001', 'un objeto en vez de una lista: PP001');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), '"x"'::jsonb) $$), 'PP001', 'un texto: PP001');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), 'null'::jsonb) $$), 'PP001', 'un null JSON: PP001');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            (select jsonb_agg(pg_temp.c('PRODUCTO','11','1000')) from generate_series(1, 501))) $$),
          'PP001', 'más de 500 cambios: PP001');

select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), '[1]'::jsonb) $$), 'PP002', 'un cambio que no es un objeto: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','PRODUCTO','id',pg_temp.u('11')))) $$),
          'PP002', 'sin la clave precio (un null explícito quita; la ausencia es un error): PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','PRODUCTO','precio',1000))) $$),
          'PP002', 'sin id: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('id',pg_temp.u('11'),'precio',1000))) $$),
          'PP002', 'sin tipo: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','PRODUCTO','id',pg_temp.u('11'),'precio',1000,'extra',1))) $$),
          'PP002', 'una clave que no existe: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','LIBRO','id',pg_temp.u('11'),'precio',1000))) $$),
          'PP002', 'un tipo que no es PRODUCTO ni COLECCION: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','producto','id',pg_temp.u('11'),'precio',1000))) $$),
          'PP002', 'y en minúsculas tampoco: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','PRODUCTO','id','no-es-un-uuid','precio',1000))) $$),
          'PP002', 'un id que no es un uuid: PP002');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(jsonb_build_object('tipo','PRODUCTO','id',12345,'precio',1000))) $$),
          'PP002', 'un id numérico: PP002');

select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','0'))) $$),
          'PP003', 'el precio 0: PP003 (para volver al general se manda null)');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','-5'))) $$),
          'PP003', 'un precio negativo: PP003');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','10.5'))) $$),
          'PP003', 'un precio con decimales: PP003');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','"1000"'))) $$),
          'PP003', 'un precio como texto: PP003');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','true'))) $$),
          'PP003', 'un precio booleano: PP003');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','2147483648'))) $$),
          'PP003', 'un precio mayor que el entero máximo: PP003 (no un desborde)');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','11','[1]'))) $$),
          'PP003', 'un precio que es una lista: PP003');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','1b','2147483647'))) $$),
          'ok', 'el entero máximo sí entra');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','1b','1000.0'))) $$),
          'ok', 'y 1000.0 es el entero 1000');

select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(pg_temp.c('PRODUCTO','12','1000'), pg_temp.c('PRODUCTO','12','2000'))) $$),
          'PP004', 'el mismo producto dos veces: PP004');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(pg_temp.c('COLECCION','d1','2000'), pg_temp.c('COLECCION','d1','3000'))) $$),
          'PP004', 'y la misma colección: PP004');

select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','17','1000'))) $$),
          'PP005', 'un producto dado de baja: PP005');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','ff','1000'))) $$),
          'PP005', 'un producto que no existe: PP005');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('COLECCION','d4','1000'))) $$),
          'PP005', 'una colección dada de baja: PP005');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('COLECCION','11','1000'))) $$),
          'PP005', 'un id de producto con tipo COLECCION: PP005');
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'), jsonb_build_array(pg_temp.c('PRODUCTO','d1','null'))) $$),
          'PP005', 'quitar la excepción de un producto que no existe: PP005');

-- Los dos "ok" de arriba escribieron en J (1b): 2147483647 y, el mismo día, 1000.0 = 1000 (corrige en el lugar).
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos('f1', '1b'), '1000:0:~', 'J: el entero máximo entró y 1000.0 lo corrigió a 1000 el mismo día');
select is(pg_temp.eventos(), 2, 'y dejaron dos eventos');

-- Todo o nada: dos cambios válidos seguidos de uno inválido no dejan nada, ni filas ni eventos.
select is(pg_temp.tramos('f1', '11'), 'SIN FILAS', 'antes: A no tiene excepción en f1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select * from public.guardar_precios_de_la_ciudad(pg_temp.u('f1'),
            jsonb_build_array(pg_temp.c('PRODUCTO','13','9999'), pg_temp.c('PRODUCTO','11','7777'), pg_temp.c('PRODUCTO','17','1000'))) $$),
          'PP005', 'dos cambios válidos y un tercero de un producto de baja: se rechaza todo');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos('f1', '13'), '26000:0:~', 'C sigue como estaba (el primero no se aplicó)');
select is(pg_temp.tramos('f1', '11'), 'SIN FILAS', 'A sigue sin filas (el segundo tampoco)');
select is(pg_temp.eventos(), 2, 'y no quedó ningún evento nuevo');

-- ---------------------------------------------------------------------------
-- 4. Las vigencias (el coordinador de la campaña en f1)
-- ---------------------------------------------------------------------------
-- Se parte de una cuenta limpia de eventos en el conteo: se toma el número de ahora como base.
create temp table base170 as
  select pg_temp.eventos() as eventos, pg_temp.filas() as filas;
grant all on base170 to public;

select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.guardar('f1', jsonb_build_array(
            pg_temp.c('PRODUCTO','11','24500'),      -- A: sin excepción -> CREADA
            pg_temp.c('PRODUCTO','12','25000'),      -- B: igual al vigente -> SIN_CAMBIO
            pg_temp.c('PRODUCTO','13','26500'),      -- C: el vigente empezó hoy -> CAMBIADA en el lugar
            pg_temp.c('PRODUCTO','14','21500'),      -- D: solo hay una vencida -> CREADA
            pg_temp.c('PRODUCTO','15','5500'),       -- E: solo hay una dada de baja -> CREADA
            pg_temp.c('PRODUCTO','16','31000'),      -- F: vigente hasta +9 y otra desde +10 -> CAMBIADA
            pg_temp.c('PRODUCTO','18','null'),       -- G: quitar, empezó antes de hoy -> QUITADA (cierra ayer)
            pg_temp.c('PRODUCTO','19','null'),       -- H: quitar, empezó hoy -> QUITADA (baja lógica)
            pg_temp.c('PRODUCTO','1a','null'),       -- I: quitar, no tenía -> SIN_CAMBIO
            pg_temp.c('COLECCION','d1','46000'),     -- colección con excepción -> CAMBIADA
            pg_temp.c('COLECCION','d2','47000'))),   -- colección sin excepción -> CREADA
          'CREADA,SIN_CAMBIO,CAMBIADA,CREADA,CREADA,CAMBIADA,QUITADA,QUITADA,SIN_CAMBIO,CAMBIADA,CREADA',
          'las acciones salen en el orden de la lista');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos('f1', '11'), '24500:0:~', 'A: tramo nuevo desde hoy, sin fin');
select is(pg_temp.tramos('f1', '12'), '25000:-30:~', 'B: SIN_CAMBIO no toca la fila');
select is(pg_temp.tramos('f1', '13'), '26500:0:~', 'C: el vigente de hoy cambia de importe en el lugar (cerrarlo ayer lo dejaría al revés)');
select is(pg_temp.tramos('f1', '14'), '21000:-100:-31 | 21500:0:~', 'D: la vencida queda como estaba y entra el tramo nuevo');
select is(pg_temp.tramos('f1', '15'), '5000:-20:~:baja | 5500:0:~', 'E: la dada de baja queda como estaba y entra el tramo nuevo');
select is(pg_temp.tramos('f1', '16'), '25000:-30:-1 | 31000:0:9 | 30000:10:~',
          'F: el vigente se cierra ayer y el nuevo termina el día antes del tramo futuro (que no se toca)');
select is(pg_temp.tramos('f1', '18'), '25000:-30:-1', 'G: quitar cierra el vigente ayer (rige el general)');
select is(pg_temp.tramos('f1', '19'), '27000:0:~:baja', 'H: quitar lo de hoy da de baja la fila (baja lógica, no se borra)');
select is(pg_temp.tramos('f1', '1a'), 'SIN FILAS', 'I: quitar lo que no existe no crea nada');
select is(pg_temp.tramos('f1', 'd1'), '45000:-30:-1 | 46000:0:~', 'colección con excepción: cierra ayer y abre hoy');
select is(pg_temp.tramos('f1', 'd2'), '47000:0:~', 'colección sin excepción: tramo nuevo');
select is(pg_temp.tramos('f4', '12'), '29000:-30:~', 'la misma ciudad real en OTRA campaña (f4) no se toca');
select is(pg_temp.filas(), (select filas from base170) + 6,
          'se agregaron 6 filas (A, D, E, F, d1 y d2; C se corrigió en el lugar) y ninguna se borró');
select is(pg_temp.eventos(), (select eventos from base170) + 9,
          'nueve eventos: uno por cada cambio efectivo (los dos SIN_CAMBIO no escriben nada)');
select is((select a.metadata ->> 'accion' || ':' || (a.metadata ->> 'precio_anterior') || ':' || (a.metadata ->> 'precio_nuevo')
             from auditoria.audit_log a
            where a.event_type = 'precio_de_ciudad_guardado' and a.fila_id = pg_temp.u('32')),
          'CAMBIADA:26000:26500', 'el evento de C guarda la acción y los dos importes, y su fila es la corregida');
select is((select a.metadata ->> 'precio_anterior' || ':' || coalesce(a.metadata ->> 'precio_nuevo', 'null') || ':' || (a.metadata ->> 'accion')
             from auditoria.audit_log a
            where a.event_type = 'precio_de_ciudad_guardado' and a.fila_id = pg_temp.u('37')),
          '25000:null:QUITADA', 'el evento de G (quitar) guarda el importe que tenía y precio_nuevo null; su fila es la cerrada');
select ok((select a.metadata -> 'precio_anterior' = 'null'::jsonb and a.metadata ->> 'accion' = 'CREADA'
             from auditoria.audit_log a
            where a.event_type = 'precio_de_ciudad_guardado' and a.metadata ->> 'item_id' = pg_temp.u('11')::text),
          'el evento de una CREADA trae precio_anterior null');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'precio_de_ciudad_guardado' and a.actor_user_id = pg_temp.u('a1')
              and a.tabla = 'precio_por_ciudad' and a.fila_id is not null and a.target_user_id is null
              and a.metadata ->> 'campania_ciudad_id' like '01920000-0000-7000-8000-0000000170%'),
          (select eventos from base170) + 9, 'todos los eventos: actor = la coordinadora, tabla precio_por_ciudad, sin objetivo (los 2 "ok" de antes incluidos en la base)');
select is((select a.metadata ->> 'campania_id' || ':' || (a.metadata ->> 'dia')
             from auditoria.audit_log a where a.fila_id = pg_temp.u('32') and a.event_type = 'precio_de_ciudad_guardado'),
          pg_temp.u('e1')::text || ':' || pg_temp.h()::text, 'el detalle lleva la campaña y el día');
select is((select p.created_by from public.precio_por_ciudad p
            where p.campania_ciudad_id = pg_temp.u('f1') and p.producto_id = pg_temp.u('11')),
          pg_temp.u('a1'), 'el tramo nuevo lo creó la coordinadora (created_by)');
select is((select p.sync_version from public.precio_por_ciudad p where p.id = pg_temp.u('32')), 1::bigint,
          'la fila corregida subió su sync_version (el teléfono la vuelve a bajar)');
select is((select p.sync_version from public.precio_por_ciudad p where p.id = pg_temp.u('31')), 0::bigint,
          'y la que no cambió (SIN_CAMBIO) no se tocó');

-- El tramo nuevo respeta el fin del vigente que reemplaza (no queda sin fin ni tapa el hueco del general).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.guardar('f1', jsonb_build_array(pg_temp.c('PRODUCTO','1c','31000'), pg_temp.c('PRODUCTO','1d','31000'))),
          'CAMBIADA,CAMBIADA', 'K y L: el vigente termina antes de hoy+10 y de hoy+20, y se cambia');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos('f1', '1c'), '25000:-30:-1 | 31000:0:9',
          'K: el vigente terminaba en +9 y sin tramo futuro: el nuevo termina en +9, no queda sin fin');
select is(pg_temp.tramos('f1', '1d'), '25000:-30:-1 | 31000:0:5 | 30000:20:~',
          'L: el vigente terminaba en +5 y hay un futuro en +20: el nuevo termina en +5 y el hueco de +6 a +19 sigue libre');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.precio_modificado from public.precios_de_la_ciudad(pg_temp.u('f1'), pg_temp.h() + 10) r where r.nombre = 'K vigente con fin sin futuro t170'),
          null, 'K: pasado su fin ya no rige ninguna excepción');
select is((select r.precio_modificado from public.precios_de_la_ciudad(pg_temp.u('f1'), pg_temp.h() + 10) r where r.nombre = 'L vigente con fin y hueco t170'),
          null, 'L: en el hueco (+10) no rige ninguna excepción (rige el general, si hay)');
select is((select r.precio_modificado from public.precios_de_la_ciudad(pg_temp.u('f1'), pg_temp.h() + 20) r where r.nombre = 'L vigente con fin y hueco t170'),
          30000, 'L: desde +20 rige el futuro, que no se tocó');

-- Coherencia con la lectura (0037): precio_modificado / vigente / origen después de guardar.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select r.precio_modificado from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'A sin excepcion t170'),
          24500, 'la lectura ve el precio guardado de A');
select is((select r.precio_vigente || ':' || r.origen from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'G para quitar t170'),
          '20000:GENERAL', 'G quitada: vuelve a regir el general');
select is((select r.precio_vigente || ':' || r.origen from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'H para quitar el mismo dia t170'),
          '21000:GENERAL', 'H quitada el mismo día: también rige el general');
select is((select r.precio_vigente || ':' || r.origen from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'F con tramo futuro t170'),
          '31000:MODIFICADO', 'F: rige el tramo nuevo, no el futuro');
select is((select r.precio_vigente from public.precios_de_la_ciudad(pg_temp.u('f1'), pg_temp.h() + 10) r where r.nombre = 'F con tramo futuro t170'),
          30000, 'y dentro de 10 días rige el futuro, que no se tocó');
select is((select r.precio_modificado from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Col sin excepcion t170'),
          47000, 'y la colección sin excepción ya la tiene');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select r.precio_modificado from public.precios_de_la_ciudad(pg_temp.u('f4')) r where r.nombre = 'B excepcion igual t170'),
          29000, 'en la otra campaña, B sigue con la suya');

-- ---------------------------------------------------------------------------
-- 5. Idempotencia: el mismo guardado otra vez no cambia nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table antes170 as
  select pg_temp.eventos() as eventos, pg_temp.filas() as filas,
         (select string_agg(p.id::text || p.precio_venta::text || p.valido_desde::text || coalesce(p.valido_hasta::text, '') || coalesce(p.deleted_at::text, '') || p.sync_version::text, ',' order by p.id)
            from public.precio_por_ciudad p where p.campania_ciudad_id::text like '01920000-0000-7000-8000-0000000170%') as foto;
grant all on antes170 to public;
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.guardar('f1', jsonb_build_array(
            pg_temp.c('PRODUCTO','11','24500'), pg_temp.c('PRODUCTO','12','25000'), pg_temp.c('PRODUCTO','13','26500'),
            pg_temp.c('PRODUCTO','14','21500'), pg_temp.c('PRODUCTO','15','5500'),  pg_temp.c('PRODUCTO','16','31000'),
            pg_temp.c('PRODUCTO','18','null'),  pg_temp.c('PRODUCTO','19','null'),  pg_temp.c('PRODUCTO','1a','null'),
            pg_temp.c('COLECCION','d1','46000'), pg_temp.c('COLECCION','d2','47000'))),
          'SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO,SIN_CAMBIO',
          'repetir el guardado: todo SIN_CAMBIO');
select pg_temp.actuar_como_servidor();
select is(pg_temp.eventos(), (select eventos from antes170), 'sin eventos nuevos');
select is((select string_agg(p.id::text || p.precio_venta::text || p.valido_desde::text || coalesce(p.valido_hasta::text, '') || coalesce(p.deleted_at::text, '') || p.sync_version::text, ',' order by p.id)
             from public.precio_por_ciudad p where p.campania_ciudad_id::text like '01920000-0000-7000-8000-0000000170%'),
          (select foto from antes170), 'y ninguna fila cambió (ni su sync_version)');

-- ---------------------------------------------------------------------------
-- 6. Otros que sí pueden: el ADMIN, y la campaña terminada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.guardar('f1', jsonb_build_array(pg_temp.c('PRODUCTO','12','26000'))), 'CAMBIADA', 'el ADMIN guarda en cualquier ciudad');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos('f1', '12'), '25000:-30:-1 | 26000:0:~', 'cierra ayer y abre hoy');
select is((select a.actor_user_id from auditoria.audit_log a
            where a.event_type = 'precio_de_ciudad_guardado' and a.metadata ->> 'item_id' = pg_temp.u('12')::text),
          pg_temp.u('ad'), 'y el actor del evento es el ADMIN');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.guardar('f4', jsonb_build_array(pg_temp.c('PRODUCTO','12','29500'))), 'CAMBIADA', 'el coordinador de la campaña e2 guarda en f4');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.guardar('f5', jsonb_build_array(pg_temp.c('PRODUCTO','11','1500'))), 'CREADA',
          'una campaña terminada se puede corregir (las políticas de la tabla tampoco lo impiden)');
select is(pg_temp.guardar('f2', jsonb_build_array(pg_temp.c('PRODUCTO','11','1600'))), 'CREADA', 'y otra ciudad de la misma campaña');
select pg_temp.actuar_como_servidor();
select is(pg_temp.tramos('f1', '11'), '24500:0:~', 'A en f1 no se movió por lo de f5 ni f2: cada ciudad de campaña tiene lo suyo');
select is(pg_temp.tramos('f2', '11'), '1600:0:~', 'f2 tiene su propia excepción');

select * from finish();
rollback;
