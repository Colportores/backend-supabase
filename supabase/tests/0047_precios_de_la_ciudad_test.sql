-- pgTAP · migración 0037 (backend-supabase#84): precios_de_la_ciudad(), la lectura de la vista 27 del
-- panel (HU-CAT-005, ADR-013). Una fila por producto y por colección del catálogo vivo con el
-- general, el modificado de la ciudad de la campaña, el que rige y su vigencia.
--   1. La forma: columnas, SECURITY DEFINER, STABLE, search_path vacío; EXECUTE solo authenticated.
--   2. Quién la llama (la matriz): el ADMIN y el coordinador de ESA campaña, también si terminó o
--      si no empezó; sin JWT, anon, service_role, colportor (inscripto o no), sin rol, rol vencido,
--      coordinador dado de baja y coordinador de otra campaña reciben 42501.
--   3. Los códigos de rechazo y su orden: el permiso antes que la existencia (42501), la ciudad
--      inexistente o quitada (CZ012), la campaña inexistente o dada de baja (CZ001).
--   4. El contenido, producto por producto: modificado sobre general, solo general, solo modificado,
--      ninguno (origen null), vencido, futuro, dado de baja, importe 0, vigencias que no se mezclan.
--   5. Colecciones, el catálogo vivo (una baja no aparece) y el orden: productos antes que
--      colecciones, por nombre y por id.
--   6. Las fechas: sin fecha es el día de Montevideo con la sesión en cualquier zona; los extremos de
--      un tramo valen; un día pasado y uno futuro; y lo mismo en una colección, con su general y su
--      modificado vencidos, futuros y dados de baja (cada filtro de los laterales de colección tiene
--      su caso: quitarlo hace fallar una prueba).
--   7. La alerta «bonificables sin precio», dos campañas en la misma ciudad que no se pisan, la
--      coherencia con precio_vigente() (0034) y que lee sin modificar nada.
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
  select ('01920000-0000-7000-8000-0000000047' || p)::uuid;
$$;
-- «Hoy» de la aplicación: el día de Montevideo.
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- La fila de un producto o colección en una línea: general|modificado|vigente|origen|desde|hasta.
-- Los importes en centavos; las fechas, como días desde hoy (-100 = hace cien días); ~ = null;
-- SIN FILA si la función no devuelve esa fila. Corre con el rol y el JWT de la sesión.
create or replace function pg_temp.fila(p_cc text, p_nombre text, p_fecha date default null)
returns text language sql as $$
  select coalesce(
    (select concat_ws('|',
              coalesce(r.precio_general::text, '~'), coalesce(r.precio_modificado::text, '~'),
              coalesce(r.precio_vigente::text, '~'), coalesce(r.origen, '~'),
              coalesce((r.valido_desde - pg_temp.h())::text, '~'),
              coalesce((r.valido_hasta - pg_temp.h())::text, '~'))
       from public.precios_de_la_ciudad(pg_temp.u(p_cc), p_fecha) r
      where r.nombre = p_nombre),
    'SIN FILA');
$$;
-- ¿Cuántas filas de este test devuelve la función para una ciudad? (el catálogo puede tener más)
create or replace function pg_temp.n(p_cc text, p_fecha date default null) returns integer
language sql as $$
  select count(*)::int from public.precios_de_la_ciudad(pg_temp.u(p_cc), p_fecha) r where r.nombre like '%t47';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: ad es ADMIN; a1 coordina e1, e3 (terminada), e4 (dada de baja) y e5 (por empezar); a2
-- coordina e2; a3 no tiene ningún rol; a4 tiene el rol de coordinador vencido; a5 es coordinador pero
-- el usuario está dado de baja (coordina e6); a0 es colportor sin inscripción; b1 es colportor
-- inscripto en e1.
-- Campañas: e1 y e2 en curso; e3 terminada; e4 dada de baja; e5 empieza en 10 días; e6 en curso.
-- campania_ciudad: f1 e1/Montevideo, f2 e1/Salto, f3 e1/Paysandú (quitada de la campaña), f4
-- e2/Montevideo (la MISMA ciudad real que f1, otra campaña), f5 e3/Montevideo, f6 e4/Montevideo,
-- f7 e5/Montevideo, f8 e6/Montevideo.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'precios47-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','a0','a1','a2','a3','a4','a5','b1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'),
               ('a0','COLPORTOR'), ('b1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';
update public.usuario set deleted_at = now() where id = pg_temp.u('a5');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais precios47', 'ZQ');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Montevideo precios47', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Salto precios47',      pg_temp.u('c0'), -31.40, -57.96),
  (pg_temp.u('c3'), 'Paysandu precios47',   pg_temp.u('c0'), -32.32, -58.08);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  (pg_temp.u('e1'), 'e1 precios47', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1'), null),
  (pg_temp.u('e2'), 'e2 precios47', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a2'), null),
  (pg_temp.u('e3'), 'e3 precios47', 'VERANO', pg_temp.h() - 40, pg_temp.h() - 1,  pg_temp.u('a1'), null),
  (pg_temp.u('e4'), 'e4 precios47', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1'), now()),
  (pg_temp.u('e5'), 'e5 precios47', 'VERANO', pg_temp.h() + 10, pg_temp.h() + 40, pg_temp.u('a1'), null),
  (pg_temp.u('e6'), 'e6 precios47', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a5'), null);
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'), null),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2'), null),
  (pg_temp.u('f3'), pg_temp.u('e1'), pg_temp.u('c3'), now()),
  (pg_temp.u('f4'), pg_temp.u('e2'), pg_temp.u('c1'), null),
  (pg_temp.u('f5'), pg_temp.u('e3'), pg_temp.u('c1'), null),
  (pg_temp.u('f6'), pg_temp.u('e4'), pg_temp.u('c1'), null),
  (pg_temp.u('f7'), pg_temp.u('e5'), pg_temp.u('c1'), null),
  (pg_temp.u('f8'), pg_temp.u('e6'), pg_temp.u('c1'), null);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);

-- Catálogo. El sufijo « t47» identifica a los de este test (la base puede tener otros). Prod 04, 05
-- y 02 son bonificables. Prod 08 está dado de baja; la colección 4 también.
insert into public.producto (id, nombre, tipo, es_bonificable, deleted_at) values
  (pg_temp.u('11'), 'Prod 01 t47', 'LIBRO', false, null),
  (pg_temp.u('12'), 'Prod 02 t47', 'LIBRO', true,  null),
  (pg_temp.u('13'), 'Prod 03 t47', 'LIBRO', false, null),
  (pg_temp.u('14'), 'Prod 04 t47', 'LIBRO', true,  null),
  (pg_temp.u('15'), 'Prod 05 t47', 'LIBRO', true,  null),
  (pg_temp.u('16'), 'Prod 06 t47', 'LIBRO', false, null),
  (pg_temp.u('17'), 'Prod 07 t47', 'LIBRO', false, null),
  (pg_temp.u('18'), 'Prod 08 t47', 'LIBRO', false, now()),
  (pg_temp.u('19'), 'Prod 09 t47', 'LIBRO', false, null),
  (pg_temp.u('1a'), 'Prod 10 t47', 'LIBRO', false, null),
  (pg_temp.u('1b'), 'Prod 11 t47', 'LIBRO', false, null),
  (pg_temp.u('1c'), 'Gemelo t47',  'LIBRO', false, null),
  (pg_temp.u('1d'), 'Gemelo t47',  'LIBRO', false, null);
insert into public.coleccion (id, nombre, deleted_at) values
  (pg_temp.u('d1'), 'Aaa Col 1 t47', null),
  (pg_temp.u('d2'), 'Aaa Col 2 t47', null),
  (pg_temp.u('d3'), 'Aaa Col 3 t47', null),
  (pg_temp.u('d4'), 'Aaa Col 4 t47', now());

-- Precios generales (Administración). p1, p2: abiertos; p3: historial (g3a y g3b contiguos); p6: solo
-- uno dado de baja; p7: un solo día, hoy; p8: de un producto dado de baja; p9: con fin (hoy + 50);
-- p10: 500; p11: importe 0 (ejemplar misionero); d1 y d2: colecciones; d4: de una colección dada de baja.
-- d3 (la colección «sin precio»): tres generales que hoy NO rigen, uno por cada filtro del lateral de
-- colección de la función: 41 vencido (hace 100 a 31 días), 42 futuro (desde dentro de 30 días) y 43 dado
-- de baja (abierto desde hace 20 días: cubre hoy, así que solo lo saca el filtro de deleted_at).
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  (pg_temp.u('21'), pg_temp.u('11'), null, 24000, pg_temp.h() - 100, null,                 null),
  (pg_temp.u('22'), pg_temp.u('12'), null, 26000, pg_temp.h() - 100, null,                 null),
  (pg_temp.u('23'), pg_temp.u('13'), null, 20000, pg_temp.h() - 100, pg_temp.h() - 31,     null),
  (pg_temp.u('24'), pg_temp.u('13'), null, 22000, pg_temp.h() - 30,  null,                 null),
  (pg_temp.u('25'), pg_temp.u('16'), null, 18000, pg_temp.h() - 100, null,                 now()),
  (pg_temp.u('26'), pg_temp.u('17'), null, 1000,  pg_temp.h(),       pg_temp.h(),          null),
  (pg_temp.u('27'), pg_temp.u('18'), null, 9000,  pg_temp.h() - 100, null,                 null),
  (pg_temp.u('28'), pg_temp.u('19'), null, 30000, pg_temp.h() - 100, pg_temp.h() + 50,     null),
  (pg_temp.u('29'), pg_temp.u('1a'), null, 500,   pg_temp.h() - 100, null,                 null),
  (pg_temp.u('2a'), pg_temp.u('1b'), null, 0,     pg_temp.h() - 100, null,                 null),
  (pg_temp.u('2b'), null, pg_temp.u('d1'), 44000, pg_temp.h() - 100, null,                 null),
  (pg_temp.u('2c'), null, pg_temp.u('d2'), 40000, pg_temp.h() - 100, null,                 null),
  (pg_temp.u('2d'), null, pg_temp.u('d4'), 7000,  pg_temp.h() - 100, null,                 null),
  (pg_temp.u('41'), null, pg_temp.u('d3'), 41000, pg_temp.h() - 100, pg_temp.h() - 31,     null),
  (pg_temp.u('42'), null, pg_temp.u('d3'), 42000, pg_temp.h() + 30,  null,                 null),
  (pg_temp.u('43'), null, pg_temp.u('d3'), 43000, pg_temp.h() - 20,  null,                 now());

-- Precios modificados por ciudad de la campaña (precio_por_ciudad).
--   m1  p1 en f1 · m2 p1 en f4 (la misma ciudad real, otra campaña) · m3 p3 en f1, vencido ·
--   m4  p3 en f4, futuro · m5 p2 en f1, dado de baja · m6 p5 en f1, sin general ·
--   m7  p6 en f1, futuro (y su general está dado de baja) · m8 p8 en f1 (producto dado de baja) ·
--   m9  p9 en f1, sin fin (el general tiene fin) · ma p10 en f1, importe 0 · mb d1 en f1 ·
--   mc  p1 en f5 (campaña terminada) · md p1 en f7 (campaña por empezar) ·
--   44, 45 y 46  d3 en f1 (los tres modificados que hoy NO rigen): vencido (hasta hace 61 días), futuro
--   (desde dentro de 40 días) y dado de baja (abierto desde hace 20 días, cubre hoy).
insert into public.precio_por_ciudad (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  (pg_temp.u('31'), pg_temp.u('11'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 100, null,                null),
  (pg_temp.u('32'), pg_temp.u('11'), null, pg_temp.u('f4'), 26500, pg_temp.h() - 100, null,                null),
  (pg_temp.u('33'), pg_temp.u('13'), null, pg_temp.u('f1'), 21000, pg_temp.h() - 100, pg_temp.h() - 61,    null),
  (pg_temp.u('34'), pg_temp.u('13'), null, pg_temp.u('f4'), 23000, pg_temp.h() + 30,  null,                null),
  (pg_temp.u('35'), pg_temp.u('12'), null, pg_temp.u('f1'), 27000, pg_temp.h() - 100, null,                now()),
  (pg_temp.u('36'), pg_temp.u('15'), null, pg_temp.u('f1'), 5000,  pg_temp.h() - 100, null,                null),
  (pg_temp.u('37'), pg_temp.u('16'), null, pg_temp.u('f1'), 19000, pg_temp.h() + 30,  null,                null),
  (pg_temp.u('38'), pg_temp.u('18'), null, pg_temp.u('f1'), 8000,  pg_temp.h() - 100, null,                null),
  (pg_temp.u('39'), pg_temp.u('19'), null, pg_temp.u('f1'), 31000, pg_temp.h() - 10,  null,                null),
  (pg_temp.u('3a'), pg_temp.u('1a'), null, pg_temp.u('f1'), 0,     pg_temp.h() - 100, null,                null),
  (pg_temp.u('3b'), null, pg_temp.u('d1'), pg_temp.u('f1'), 45000, pg_temp.h() - 100, null,                null),
  (pg_temp.u('3c'), pg_temp.u('11'), null, pg_temp.u('f5'), 23500, pg_temp.h() - 100, null,                null),
  (pg_temp.u('3d'), pg_temp.u('11'), null, pg_temp.u('f7'), 27500, pg_temp.h() - 100, null,                null),
  (pg_temp.u('44'), null, pg_temp.u('d3'), pg_temp.u('f1'), 51000, pg_temp.h() - 100, pg_temp.h() - 61,    null),
  (pg_temp.u('45'), null, pg_temp.u('d3'), pg_temp.u('f1'), 52000, pg_temp.h() + 40,  null,                null),
  (pg_temp.u('46'), null, pg_temp.u('d3'), pg_temp.u('f1'), 53000, pg_temp.h() - 20,  null,                now());

-- ---------------------------------------------------------------------------
-- 1. La forma y los privilegios
-- ---------------------------------------------------------------------------
select has_function('public', 'precios_de_la_ciudad', array['uuid', 'date'], 'existe precios_de_la_ciudad(uuid, date)');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'precios_de_la_ciudad'),
          1, 'y es una sola (sin sobrecargas)');
select is(pg_get_function_arguments('public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'p_campania_ciudad_id uuid, p_fecha date DEFAULT NULL::date',
          'recibe la ciudad de la campaña y, si se quiere, la fecha');
select is(pg_get_function_result('public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'TABLE(tipo text, id uuid, nombre text, es_bonificable boolean, precio_general integer, precio_modificado integer, precio_vigente integer, origen text, valido_desde date, valido_hasta date, componentes_de_baja integer)',
          'la forma de la respuesta (importes en centavos y, desde la 0057, los componentes de baja de un combo; nada de personas ni de clientes)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          true, 'es SECURITY DEFINER: el permiso lo decide la función y el rechazo trae su motivo');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          's', 'es STABLE (solo lee)');
select ok((select 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'fija el search_path vacío');
select ok(has_function_privilege('authenticated', 'public.precios_de_la_ciudad(uuid,date)', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.precios_de_la_ciudad(uuid,date)', 'execute'),
          'anon no');
select ok(not has_function_privilege('service_role', 'public.precios_de_la_ciudad(uuid,date)', 'execute'),
          'service_role tampoco (sin JWT no pasa el permiso; el servidor usa precio_vigente())');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          0, 'no tiene EXECUTE para PUBLIC');
select ok(coalesce(obj_description('public.precios_de_la_ciudad(uuid,date)'::regprocedure::oid, 'pg_proc'), '') like '%Vista 27%',
          'tiene comentario: dice para qué es');

-- ---------------------------------------------------------------------------
-- 2. Quién la llama (la matriz de permisos)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', 'Hace falta iniciar sesión. Entrá con tu cuenta de coordinador.',
  'authenticated sin sesión (sin JWT): 42501');
select pg_temp.actuar_como_rol('anon');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', null, 'anon: 42501 (sin EXECUTE)');
select pg_temp.actuar_como_rol('service_role');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', null, 'service_role: 42501 (sin EXECUTE)');

select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', 'Esta cuenta no es de coordinador. Entrá con tu cuenta de coordinador.',
  'un colportor inscripto en la campaña: 42501 (él lee los precios por el sync)');
select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', null, 'un colportor sin inscripción: 42501');
select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', null, 'un usuario sin ningún rol: 42501');
select pg_temp.actuar_como(pg_temp.u('a4'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', null, 'con el rol de coordinador vencido: 42501');
select pg_temp.actuar_como(pg_temp.u('a5'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f8') $$,
  '42501', null, 'un coordinador dado de baja, aun en su propia campaña: 42501');
-- El permiso va antes que la existencia: quien no tiene el rol recibe 42501 aunque el id no exista.
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047ff') $$,
  '42501', null, 'un colportor con una ciudad inexistente: 42501, no CZ012 (no se puede sondear qué ids hay)');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047ff') $$,
  '42501', null, 'sin sesión con una ciudad inexistente: 42501');

-- Un coordinador de OTRA campaña: 42501, también en una campaña terminada, por empezar o de una ciudad quitada.
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  '42501', 'Solo el coordinador de la campaña puede ver sus precios. Entrá con la cuenta del coordinador de esta campaña.',
  'el coordinador de otra campaña (e2) no ve los precios de f1 (e1): 42501');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f2') $$,
  '42501', null, 'ni los de f2');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f5') $$,
  '42501', null, 'ni los de una campaña terminada de otro (f5)');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f7') $$,
  '42501', null, 'ni los de una campaña por empezar de otro (f7)');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f3') $$,
  '42501', null, 'ni los de una ciudad quitada de la campaña de otro (f3): el permiso va antes que la baja de la ciudad');
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f4') $$,
  '42501', null, 'y el de e1 no ve los de f4 (e2), la misma ciudad real');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f8') $$,
  '42501', null, 'ni los de f8 (e6, de otro coordinador)');

-- El coordinador de la campaña, sí: en curso, terminada y por empezar.
select lives_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f1') $$,
  'el coordinador de la campaña lee los precios de su ciudad (f1, en curso)');
select is(pg_temp.n('f1'), 15, 'f1: una fila por cada uno de los 12 productos vivos y las 3 colecciones vivas');
select is(pg_temp.n('f2'), 15, 'f2 (otra ciudad de la misma campaña): las mismas 15 filas');
select lives_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f5') $$,
  'también si la campaña ya terminó (f5): ver qué precios tuvo tiene sentido');
select is(pg_temp.n('f5'), 15, 'f5 (terminada): las 15 filas');
select lives_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f7') $$,
  'y si todavía no empezó (f7)');
select is(pg_temp.n('f7'), 15, 'f7 (por empezar): las 15 filas');
select pg_temp.actuar_como(pg_temp.u('a2'));
select lives_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f4') $$,
  'el coordinador de la otra campaña lee la suya (f4)');
select is(pg_temp.n('f4'), 15, 'f4: las 15 filas');

-- El ADMIN lee cualquiera, también la de un coordinador dado de baja.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.n('f1'), 15, 'el ADMIN lee f1');
select is(pg_temp.n('f4'), 15, 'y f4');
select is(pg_temp.n('f5'), 15, 'y la terminada (f5)');
select is(pg_temp.n('f7'), 15, 'y la por empezar (f7)');
select is(pg_temp.n('f8'), 15, 'y la de un coordinador dado de baja (f8)');

-- ---------------------------------------------------------------------------
-- 3. Los códigos de rechazo
-- ---------------------------------------------------------------------------
-- La ciudad de la campaña no existe (CZ012) o se quitó de la campaña (CZ012).
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047ff') $$,
  'CZ012', 'La ciudad no está en una campaña o ya se quitó de ella. Recargá las ciudades de la campaña.',
  'una ciudad de la campaña que no existe: CZ012, con un aviso que dice qué hacer');
select throws_ok($$ select * from public.precios_de_la_ciudad(null) $$,
  'CZ012', null, 'sin ciudad (null): CZ012');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f3') $$,
  'CZ012', null, 'una ciudad quitada de MI campaña (f3): CZ012');
-- La campaña no existe o está dada de baja (CZ001), antes que el dueño (como las lecturas de la 0033).
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f6') $$,
  'CZ001', 'La campaña no existe. Elegí otra campaña.', 'la ciudad de una campaña dada de baja (f6): CZ001');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f6') $$,
  'CZ001', null, 'otro coordinador con la campaña dada de baja: CZ001 (la inexistencia va antes que el dueño)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f6') $$,
  'CZ001', null, 'el ADMIN con la campaña dada de baja: CZ001');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047ff') $$,
  'CZ012', null, 'el ADMIN con una ciudad inexistente: CZ012');
select throws_ok($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000047f3') $$,
  'CZ012', null, 'el ADMIN con una ciudad quitada de la campaña (f3): CZ012');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. El contenido, producto por producto (el coordinador de e1 mira f1)
-- ---------------------------------------------------------------------------
-- Cada línea: general|modificado|vigente|origen|desde|hasta (días desde hoy; ~ = null).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('f1', 'Prod 01 t47'), '24000|25000|25000|MODIFICADO|-100|~',
          'p1: con general y modificado rige el modificado, con los dos importes a la vista');
select is(pg_temp.fila('f2', 'Prod 01 t47'), '24000|~|24000|GENERAL|-100|~',
          'p1 en otra ciudad de la campaña (sin modificado): rige el general');
select is(pg_temp.fila('f1', 'Prod 02 t47'), '26000|~|26000|GENERAL|-100|~',
          'p2: el modificado dado de baja no cuenta: rige el general');
select is(pg_temp.fila('f1', 'Prod 03 t47'), '22000|~|22000|GENERAL|-30|~',
          'p3: con historial rige el tramo de hoy (el general vencido y el modificado vencido no cuentan)');
select is(pg_temp.fila('f1', 'Prod 04 t47'), '~|~|~|~|~|~',
          'p4: sin ningún precio la fila está, con todo en null: el producto no se ofrece (R-CT05)');
select is(pg_temp.fila('f1', 'Prod 05 t47'), '~|5000|5000|MODIFICADO|-100|~',
          'p5: solo modificado (sin general): rige el modificado y el general es null');
select is(pg_temp.fila('f1', 'Prod 06 t47'), '~|~|~|~|~|~',
          'p6: un general dado de baja y un modificado futuro no cuentan hoy');
select is(pg_temp.fila('f1', 'Prod 07 t47'), '1000|~|1000|GENERAL|0|0',
          'p7: un general que vale solo hoy rige hoy (los dos extremos valen)');
select is(pg_temp.fila('f1', 'Prod 08 t47'), 'SIN FILA',
          'p8: un producto dado de baja no aparece, aunque tenga precios');
select is(pg_temp.fila('f1', 'Prod 09 t47'), '30000|31000|31000|MODIFICADO|-10|~',
          'p9: la vigencia es la del modificado (sin fin), no mezclada con la del general (con fin)');
select is(pg_temp.fila('f1', 'Prod 10 t47'), '500|0|0|MODIFICADO|-100|~',
          'p10: un modificado de importe 0 rige (0 es un precio, no «sin precio»)');
select is(pg_temp.fila('f1', 'Prod 11 t47'), '0|~|0|GENERAL|-100|~',
          'p11: un general de importe 0 rige');
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Gemelo t47'), 2,
          'dos productos con el mismo nombre salen los dos');
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f1')) r
            where r.nombre = 'Gemelo t47' and r.origen is null and r.precio_vigente is null
              and r.precio_general is null and r.precio_modificado is null
              and r.valido_desde is null and r.valido_hasta is null),
          2, 'y los dos sin precio');

-- ---------------------------------------------------------------------------
-- 5. Colecciones, el catálogo vivo y el orden
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('f1', 'Aaa Col 1 t47'), '44000|45000|45000|MODIFICADO|-100|~',
          'colección con general y modificado: rige el modificado');
select is(pg_temp.fila('f1', 'Aaa Col 2 t47'), '40000|~|40000|GENERAL|-100|~',
          'colección solo con general');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47'), '~|~|~|~|~|~',
          'colección sin precio que rija hoy (sus generales y modificados vencidos, futuros y dados de baja no cuentan): está, con todo en null');
select is(pg_temp.fila('f1', 'Aaa Col 4 t47'), 'SIN FILA', 'una colección dada de baja no aparece');
select is(pg_temp.fila('f2', 'Aaa Col 1 t47'), '44000|~|44000|GENERAL|-100|~',
          'la colección en otra ciudad de la campaña: el modificado de f1 no se filtra');

select is((select r.tipo from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Prod 01 t47'), 'PRODUCTO', 'tipo PRODUCTO');
select is((select r.tipo from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Aaa Col 1 t47'), 'COLECCION', 'tipo COLECCION');
select is((select r.id from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Prod 01 t47'), pg_temp.u('11'),
          'id es el del producto');
select is((select r.id from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Aaa Col 1 t47'), pg_temp.u('d1'),
          'y el de la colección');
select is((select r.es_bonificable from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Prod 02 t47'), true,
          'es_bonificable: el del producto (bonificable)');
select is((select r.es_bonificable from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Prod 01 t47'), false,
          'y no bonificable');
select is((select r.es_bonificable from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Aaa Col 1 t47'), null,
          'en una colección es null: no se afirma lo que no se sabe');

-- Productos antes que colecciones, por nombre; a igual nombre, por id.
select is((select string_agg(r.nombre, '|' order by r.n)
             from public.precios_de_la_ciudad(pg_temp.u('f1')) with ordinality
                  as r(tipo, id, nombre, es_bonificable, precio_general, precio_modificado, precio_vigente, origen, valido_desde, valido_hasta, componentes_de_baja, n)
            where r.nombre like '%t47'),
          'Gemelo t47|Gemelo t47|Prod 01 t47|Prod 02 t47|Prod 03 t47|Prod 04 t47|Prod 05 t47|Prod 06 t47|Prod 07 t47|Prod 09 t47|Prod 10 t47|Prod 11 t47|Aaa Col 1 t47|Aaa Col 2 t47|Aaa Col 3 t47',
          'orden: los productos por nombre y después las colecciones por nombre (aunque su nombre sea anterior)');
select is((select array_agg(r.id order by r.n)
             from public.precios_de_la_ciudad(pg_temp.u('f1')) with ordinality
                  as r(tipo, id, nombre, es_bonificable, precio_general, precio_modificado, precio_vigente, origen, valido_desde, valido_hasta, componentes_de_baja, n)
            where r.nombre = 'Gemelo t47'),
          array[pg_temp.u('1c'), pg_temp.u('1d')], 'a igual nombre, por id');
select ok((select max(r.n) filter (where r.tipo = 'PRODUCTO') < min(r.n) filter (where r.tipo = 'COLECCION')
             from public.precios_de_la_ciudad(pg_temp.u('f1')) with ordinality
                  as r(tipo, id, nombre, es_bonificable, precio_general, precio_modificado, precio_vigente, origen, valido_desde, valido_hasta, componentes_de_baja, n)),
          'todos los productos del catálogo van antes que todas las colecciones');

-- ---------------------------------------------------------------------------
-- 6. Las fechas
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('f1', 'Prod 07 t47', null), pg_temp.fila('f1', 'Prod 07 t47', pg_temp.h()),
          'sin fecha es lo mismo que hoy (el día de Montevideo)');
select is(pg_temp.n('f1', null), pg_temp.n('f1', pg_temp.h()), 'con la fecha en null también devuelve las mismas filas');

-- Hay días en que current_date de la sesión no es el de Montevideo: la función cuenta el de Montevideo.
select set_config('TimeZone', 'Pacific/Kiritimati', true);   -- UTC+14
select is(pg_temp.fila('f1', 'Prod 07 t47'), '1000|~|1000|GENERAL|0|0', 'sin fecha, con la sesión en UTC+14: el día de Montevideo');
select set_config('TimeZone', 'Etc/GMT+12', true);           -- UTC-12
select is(pg_temp.fila('f1', 'Prod 07 t47'), '1000|~|1000|GENERAL|0|0', 'sin fecha, con la sesión en UTC-12: también');
select set_config('TimeZone', 'UTC', true);
select is(pg_temp.fila('f1', 'Prod 07 t47'), '1000|~|1000|GENERAL|0|0', 'y con la sesión en UTC');
select ok((now() at time zone 'Pacific/Kiritimati')::date <> public.hoy_montevideo()
          or (now() at time zone 'Etc/GMT+12')::date <> public.hoy_montevideo(),
          'control: current_date da otro día que Montevideo en alguna de las dos zonas extremas, a cualquier hora');

-- Los extremos de un tramo valen; un día antes o después, no.
select is(pg_temp.fila('f1', 'Prod 07 t47', pg_temp.h() - 1), '~|~|~|~|~|~', 'ayer el general de un día no regía');
select is(pg_temp.fila('f1', 'Prod 07 t47', pg_temp.h() + 1), '~|~|~|~|~|~', 'mañana tampoco');
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() - 31), '20000|~|20000|GENERAL|-100|-31', 'el último día del tramo viejo (inclusive)');
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() - 30), '22000|~|22000|GENERAL|-30|~', 'el primer día del tramo nuevo (inclusive)');
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() - 50), '20000|~|20000|GENERAL|-100|-31', 'un día pasado: el general que regía');
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() - 61), '20000|21000|21000|MODIFICADO|-100|-61', 'el último día del modificado vencido: rige el modificado');
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() - 60), '20000|~|20000|GENERAL|-100|-31', 'y al día siguiente ya no');
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() - 70), '20000|21000|21000|MODIFICADO|-100|-61', 'un día pasado con modificado: rige el modificado');
select is(pg_temp.fila('f1', 'Prod 06 t47', pg_temp.h() + 29), '~|~|~|~|~|~', 'el día antes de que empiece el modificado futuro: sin precio');
select is(pg_temp.fila('f1', 'Prod 06 t47', pg_temp.h() + 30), '~|19000|19000|MODIFICADO|30|~', 'el primer día del modificado futuro: rige');
select is(pg_temp.fila('f1', 'Prod 06 t47', pg_temp.h() + 40), '~|19000|19000|MODIFICADO|30|~', 'una fecha futura: lo que va a regir');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.fila('f4', 'Prod 03 t47', pg_temp.h() + 40), '22000|23000|23000|MODIFICADO|30|~', 'el futuro de f4 es el suyo (otra campaña) ...');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.fila('f1', 'Prod 03 t47', pg_temp.h() + 40), '22000|~|22000|GENERAL|-30|~', '... y f1 no recibe el modificado futuro de f4');
select is(pg_temp.fila('f1', 'Prod 09 t47', pg_temp.h() - 20), '30000|~|30000|GENERAL|-100|50',
          'antes de que empiece el modificado: rige el general, con su fin');
select is(pg_temp.fila('f1', 'Prod 09 t47', pg_temp.h() + 50), '30000|31000|31000|MODIFICADO|-10|~', 'el último día del general con fin');
select is(pg_temp.fila('f1', 'Prod 09 t47', pg_temp.h() + 51), '~|31000|31000|MODIFICADO|-10|~', 'al día siguiente el general ya no rige y el modificado sí');

-- Lo mismo en una colección (Aaa Col 3, en f1): su general vencido, el futuro y el dado de baja, y su
-- modificado vencido, el futuro y el dado de baja. Hoy ninguno rige (comprobado arriba); en su día, sí.
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() - 50), '41000|~|41000|GENERAL|-100|-31',
          'colección: un día pasado rige el general que tenía (hoy vencido)');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() - 61), '41000|51000|51000|MODIFICADO|-100|-61',
          'colección: el último día del modificado vencido (inclusive) rige el modificado');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() - 60), '41000|~|41000|GENERAL|-100|-31',
          'colección: al día siguiente rige el general');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() - 31), '41000|~|41000|GENERAL|-100|-31',
          'colección: el último día del general vencido (inclusive)');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() - 30), '~|~|~|~|~|~',
          'colección: al día siguiente no hay precio (el dado de baja no cuenta)');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() + 29), '~|~|~|~|~|~',
          'colección: el día antes de que empiece el general futuro, sin precio');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() + 30), '42000|~|42000|GENERAL|30|~',
          'colección: el primer día del general futuro rige');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() + 39), '42000|~|42000|GENERAL|30|~',
          'colección: el día antes de que empiece el modificado futuro sigue el general');
select is(pg_temp.fila('f1', 'Aaa Col 3 t47', pg_temp.h() + 40), '42000|52000|52000|MODIFICADO|40|~',
          'colección: el primer día del modificado futuro rige el modificado');
select is(pg_temp.fila('f2', 'Aaa Col 3 t47', pg_temp.h() - 61), '41000|~|41000|GENERAL|-100|-31',
          'colección: el modificado vencido de f1 no pasa a f2 (otra ciudad de la campaña)');

-- ---------------------------------------------------------------------------
-- 7. La alerta, las campañas que no se pisan y la coherencia con precio_vigente()
-- ---------------------------------------------------------------------------
-- «Productos bonificables sin precio en X»: productos bonificables sin precio que rige. Bonificables
-- del test: p2, p4 y p5.
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f1')) r
            where r.nombre like '%t47' and r.tipo = 'PRODUCTO' and r.es_bonificable and r.origen is null),
          1, 'f1: un bonificable sin precio (p4); p2 tiene general y p5 tiene modificado');
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f2')) r
            where r.nombre like '%t47' and r.tipo = 'PRODUCTO' and r.es_bonificable and r.origen is null),
          2, 'f2: dos (p4 y p5): el modificado de p5 es de f1');
select is(pg_temp.fila('f2', 'Prod 05 t47'), '~|~|~|~|~|~', 'el modificado de una ciudad no pasa a la otra de la misma campaña');

-- Dos campañas en la misma ciudad real no se pisan.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.fila('f1', 'Prod 01 t47'), '24000|25000|25000|MODIFICADO|-100|~', 'e1/Montevideo: su modificado');
select is(pg_temp.fila('f4', 'Prod 01 t47'), '24000|26500|26500|MODIFICADO|-100|~', 'e2/Montevideo: el suyo, el de la misma ciudad real no se pisa');
select is(pg_temp.fila('f5', 'Prod 01 t47'), '24000|23500|23500|MODIFICADO|-100|~', 'e3 (terminada): el que tuvo');
select is(pg_temp.fila('f7', 'Prod 01 t47'), '24000|27500|27500|MODIFICADO|-100|~', 'e5 (por empezar): el que va a tener');
select is(pg_temp.fila('f8', 'Prod 01 t47'), '24000|~|24000|GENERAL|-100|~', 'e6 (sin modificados): el general');

-- La misma respuesta para el ADMIN y para el coordinador de la campaña.
select pg_temp.actuar_como_servidor();
create temp table res47 (quien text, ciudad text, resultado text);
grant all on res47 to authenticated;
create or replace function pg_temp.todo(p_cc text, p_fecha date default null) returns text language sql as $$
  select string_agg(concat_ws('|', r.tipo, r.nombre, coalesce(r.es_bonificable::text, '~'),
                              coalesce(r.precio_general::text, '~'), coalesce(r.precio_modificado::text, '~'),
                              coalesce(r.precio_vigente::text, '~'), coalesce(r.origen, '~'),
                              coalesce((r.valido_desde - pg_temp.h())::text, '~'),
                              coalesce((r.valido_hasta - pg_temp.h())::text, '~')),
                    E'\n' order by r.n)
    from public.precios_de_la_ciudad(pg_temp.u(p_cc), p_fecha) with ordinality
         as r(tipo, id, nombre, es_bonificable, precio_general, precio_modificado, precio_vigente, origen, valido_desde, valido_hasta, componentes_de_baja, n)
   where r.nombre like '%t47';
$$;
select pg_temp.actuar_como(pg_temp.u('ad'));
insert into res47 values ('ad', 'f1', pg_temp.todo('f1')), ('ad', 'f4', pg_temp.todo('f4'));
select pg_temp.actuar_como(pg_temp.u('a1'));
insert into res47 values ('a1', 'f1', pg_temp.todo('f1'));
select pg_temp.actuar_como(pg_temp.u('a2'));
insert into res47 values ('a2', 'f4', pg_temp.todo('f4'));
select pg_temp.actuar_como_servidor();
select is((select resultado from res47 where quien = 'a1' and ciudad = 'f1'),
          (select resultado from res47 where quien = 'ad' and ciudad = 'f1'),
          'el coordinador de la campaña y el ADMIN ven exactamente lo mismo en f1');
select is((select resultado from res47 where quien = 'a2' and ciudad = 'f4'),
          (select resultado from res47 where quien = 'ad' and ciudad = 'f4'),
          'y en f4');
select isnt((select resultado from res47 where quien = 'ad' and ciudad = 'f1'),
            (select resultado from res47 where quien = 'ad' and ciudad = 'f4'),
            'control: f1 y f4 (la misma ciudad real) no dan lo mismo');

-- Coherencia con precio_vigente() (0034): para cada producto y colección, el que rige y su origen son
-- los de precio_vigente(); hoy, en un día pasado con modificado y en uno futuro.
create or replace function pg_temp.incoherentes(p_cc text, p_fecha date) returns integer language sql as $$
  select count(*)::int
    from public.precios_de_la_ciudad(pg_temp.u(p_cc), p_fecha) r
    left join lateral public.precio_vigente(pg_temp.u(p_cc),
                                            case when r.tipo = 'PRODUCTO' then r.id end,
                                            case when r.tipo = 'COLECCION' then r.id end,
                                            p_fecha) v on true
   where r.nombre like '%t47'
     and (r.origen is distinct from v.origen
          or r.precio_vigente is distinct from v.precio_venta
          or r.valido_desde is distinct from v.valido_desde
          or r.valido_hasta is distinct from v.valido_hasta);
$$;
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.incoherentes('f1', null), 0, 'f1 hoy: coincide con precio_vigente() en las 15 filas (importe, origen y vigencia)');
select is(pg_temp.incoherentes('f1', pg_temp.h() - 70), 0, 'f1 hace 70 días: coincide');
select is(pg_temp.incoherentes('f1', pg_temp.h() + 40), 0, 'f1 dentro de 40 días: coincide');
select is(pg_temp.incoherentes('f4', pg_temp.h() + 40), 0, 'f4 dentro de 40 días: coincide');
select is(pg_temp.incoherentes('f2', null), 0, 'f2 hoy: coincide');
select is(pg_temp.incoherentes('f5', null), 0, 'f5 (campaña terminada) hoy: coincide');
select is(pg_temp.incoherentes('f1', pg_temp.h() - 50), 0, 'f1 hace 50 días (la colección con su general vencido): coincide');
select is(pg_temp.incoherentes('f1', pg_temp.h() - 61), 0, 'f1 hace 61 días (el último día del modificado vencido de la colección): coincide');
select is(pg_temp.incoherentes('f1', pg_temp.h() + 30), 0, 'f1 dentro de 30 días (el primer día del general futuro de la colección): coincide');
select pg_temp.actuar_como_servidor();

-- Solo lee (STABLE, comprobado arriba): después de todas las llamadas los precios siguen ahí.
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-0000000047%'), 16,
          'precio_general: las 16 filas del test siguen ahí');
select is((select count(*)::int from public.precio_por_ciudad where id::text like '01920000-0000-7000-8000-0000000047%'), 16,
          'precio_por_ciudad: las 16 filas del test siguen ahí');

select * from finish();
rollback;
