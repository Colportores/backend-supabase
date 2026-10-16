-- pgTAP · migración 0034 (backend-supabase#78): precio general de venta (Administración) y búsqueda
-- «modificado o, si no hay, general» (HU-CAT-004, HU-CAT-005, HU-CAT-006; decisión de Cristian del 06/10).
--   1. La forma: tabla, columnas, FK, restricciones de no solapamiento, políticas, privilegios, índice
--      del delta; todavía fuera de sync.entidad (el contrato espera el OK de Bruno); la función es
--      SECURITY INVOKER, STABLE y solo la ejecutan authenticated y service_role.
--   2. Las vigencias: importes negativos, producto y colección a la vez, rango al revés; un solo
--      general vigente a la vez por producto o colección; tramos contiguos sí, una baja lógica no cuenta.
--   3. precio_vigente: con modificado y general vale el modificado; sin modificado, el general; sin
--      ninguno, nada; modificado vencido, futuro o dado de baja no cuenta; los extremos de la vigencia
--      son inclusivos; el día es el de Montevideo con la sesión en cualquier zona horaria; colección;
--      dos campañas en la misma ciudad no se pisan; argumentos inválidos (22023).
--   4. precio_vigente y la RLS: quién ve qué; una ciudad que no ve no devuelve el general como si no
--      hubiera modificado; ciudad dada de baja; anon sin EXECUTE; service_role para el servidor.
--   5. Lectura del general: el ADMIN, el coordinador (aun de una campaña terminada) y el colportor
--      inscripto en una campaña que no terminó; no un colportor sin campaña, con la inscripción dada
--      de baja o en una campaña terminada, un usuario dado de baja ni un coordinador sin campañas.
--   6. Escritura del general: solo el ADMIN (positivos y negativos de coordinador, colportor, sin
--      campaña y anon); la modificación de una campaña no toca el general.
--   7. Un cambio de precio: historial y ventas anteriores intactas.
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
create or replace function pg_temp.actuar_como_rol(p_rol text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', p_rol, true);
  perform set_config('role', p_rol, true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000043' || p)::uuid;
$$;
-- «Hoy» de la aplicación: el día de Montevideo.
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- Lo que precio_vigente devuelve para quien llama, en una línea: «ORIGEN:importe:id (últimos 2)» o «-».
-- Es INVOKER: corre con el rol y el JWT de la sesión.
create or replace function pg_temp.pv(p_cc text, p_prod text, p_col text default null, p_fecha date default null)
returns text language sql as $$
  select coalesce(
    (select v.origen || ':' || v.precio_venta || ':' || right(v.precio_id::text, 2)
       from public.precio_vigente(pg_temp.u(p_cc), pg_temp.u(p_prod), pg_temp.u(p_col), p_fecha) v),
    '-');
$$;
-- ¿Cuántas filas toca un UPDATE del importe? (un update que la RLS no deja ver no falla: toca 0)
create or replace function pg_temp.intentar_precio(p_id uuid, p_precio integer) returns integer language plpgsql as $$
declare n integer;
begin
  update public.precio_general set precio_venta = p_precio where id = p_id;
  get diagnostics n = row_count;
  return n;
end $$;
create or replace function pg_temp.intentar_baja(p_id uuid) returns integer language plpgsql as $$
declare n integer;
begin
  update public.precio_general set deleted_at = now() where id = p_id;
  get diagnostics n = row_count;
  return n;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: ad es ADMIN; a1 coordina e1; a2 coordina e2 y e3 (e3 ya terminó); a5 es COORDINADOR sin
-- campañas; b1 está inscripto en e1; b2 en e2; b3 en e3 (terminada); b4 en ninguna; b5 tuvo e1 y la
-- inscripción está dada de baja; b6 está inscripto en e1 pero el usuario está dado de baja.
-- Campañas: e1 (f1 en c1, f2 en c2) y e2 (f3 en c1: la MISMA ciudad que f1; f5 en c2, dada de baja)
-- en curso; e3 (f4 en c3) terminada.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'general43-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','a1','a2','a5','b1','b2','b3','b4','b5','b6']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'),
               ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais general43', 'ZG');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 general43', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Ciudad c2 general43', pg_temp.u('c0'), -34.70, -56.20),
  (pg_temp.u('c3'), 'Ciudad c3 general43', pg_temp.u('c0'), -34.50, -56.30);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 general43', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 general43', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a2')),
  (pg_temp.u('e3'), 'e3 general43', 'VERANO', pg_temp.h() - 40, pg_temp.h() - 1,  pg_temp.u('a2'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2')),
  (pg_temp.u('f3'), pg_temp.u('e2'), pg_temp.u('c1')),
  (pg_temp.u('f4'), pg_temp.u('e3'), pg_temp.u('c3'));
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  (pg_temp.u('f5'), pg_temp.u('e2'), pg_temp.u('c2'), now());
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null),
  (pg_temp.u('e2'), pg_temp.u('b2'), null),
  (pg_temp.u('e3'), pg_temp.u('b3'), null),
  (pg_temp.u('e1'), pg_temp.u('b6'), null);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b5'), null, now());
update public.usuario set deleted_at = now() where id = pg_temp.u('b6');

insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro p1 general43', 'LIBRO'),
  (pg_temp.u('12'), 'Libro p2 general43', 'LIBRO'),
  (pg_temp.u('13'), 'Libro p3 general43', 'LIBRO'),
  (pg_temp.u('14'), 'Libro p4 general43', 'LIBRO'),
  (pg_temp.u('15'), 'Libro p5 general43', 'LIBRO'),
  (pg_temp.u('16'), 'Libro p6 general43', 'LIBRO'),
  (pg_temp.u('17'), 'Libro p7 general43', 'LIBRO'),
  (pg_temp.u('18'), 'Libro p8 general43', 'LIBRO'),
  (pg_temp.u('19'), 'Libro p9 general43', 'LIBRO'),
  (pg_temp.u('1a'), 'Libro p10 general43', 'LIBRO'),
  (pg_temp.u('1b'), 'Libro p11 general43', 'LIBRO'),
  (pg_temp.u('1c'), 'Libro p12 general43', 'LIBRO'),
  (pg_temp.u('1d'), 'Libro p13 general43', 'LIBRO');
insert into public.coleccion (id, nombre) values
  (pg_temp.u('d0'), 'Coleccion general43'),
  (pg_temp.u('d1'), 'Coleccion d1 general43');

-- Precios generales. p1 y p2 con general abierto; p3 con historial (g3a y g3b contiguos); p7 solo hoy;
-- p4 y p8 con un general dado de baja y ningún otro; p5, p6 sin general; la colección con general.
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  (pg_temp.u('21'), pg_temp.u('11'), null, 24000, pg_temp.h() - 100, null, null),
  (pg_temp.u('22'), pg_temp.u('12'), null, 26000, pg_temp.h() - 100, null, null),
  (pg_temp.u('23'), pg_temp.u('13'), null, 20000, pg_temp.h() - 100, pg_temp.h() - 31, null),
  (pg_temp.u('24'), pg_temp.u('13'), null, 22000, pg_temp.h() - 30, null, null),
  (pg_temp.u('25'), pg_temp.u('14'), null, 18000, pg_temp.h() - 100, null, now()),
  (pg_temp.u('26'), null, pg_temp.u('d0'), 44000, pg_temp.h() - 100, null, null),
  (pg_temp.u('27'), pg_temp.u('17'), null, 1000, pg_temp.h(), pg_temp.h(), null),
  (pg_temp.u('28'), pg_temp.u('18'), null, 9000, pg_temp.h() - 100, null, now()),
  (pg_temp.u('29'), pg_temp.u('19'), null, 30000, pg_temp.h() - 100, null, null),
  -- d1: una colección con un único general, dado de baja.
  (pg_temp.u('5b'), null, pg_temp.u('d1'), 40000, pg_temp.h() - 100, null, now());

-- Precios modificados por ciudad de la campaña (los de siempre, precio_por_ciudad).
--   m1  p1 en f1 · m2 p1 en f3 (la misma ciudad que f1, otra campaña) · m3 p3 en f1, vencido ·
--   m4  p3 en f3, futuro · m5 p2 en f1, dado de baja · m6 p5 en f1, sin general ·
--   m7  la colección en f1 · m8 p6 en f4 (campaña terminada), sin general.
insert into public.precio_por_ciudad (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  (pg_temp.u('31'), pg_temp.u('11'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 100, null, null),
  (pg_temp.u('32'), pg_temp.u('11'), null, pg_temp.u('f3'), 26500, pg_temp.h() - 100, null, null),
  (pg_temp.u('33'), pg_temp.u('13'), null, pg_temp.u('f1'), 21000, pg_temp.h() - 100, pg_temp.h() - 61, null),
  (pg_temp.u('34'), pg_temp.u('13'), null, pg_temp.u('f3'), 23000, pg_temp.h() + 30, null, null),
  (pg_temp.u('35'), pg_temp.u('12'), null, pg_temp.u('f1'), 27000, pg_temp.h() - 100, null, now()),
  (pg_temp.u('36'), pg_temp.u('15'), null, pg_temp.u('f1'), 5000, pg_temp.h() - 100, null, null),
  (pg_temp.u('37'), null, pg_temp.u('d0'), pg_temp.u('f1'), 45000, pg_temp.h() - 100, null, null),
  (pg_temp.u('38'), pg_temp.u('16'), null, pg_temp.u('f4'), 3000, pg_temp.h() - 100, null, null);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_table('public', 'precio_general', 'existe la tabla del precio general');
select has_column('public', 'precio_general', c, format('precio_general.%s', c))
  from unnest(array['producto_id', 'coleccion_id', 'precio_venta', 'valido_desde', 'valido_hasta']) c;
select hasnt_column('public', 'precio_general', c, format('precio_general no tiene %s (no cuelga de ninguna ciudad ni de nadie)', c))
  from unnest(array['campania_ciudad_id', 'zona_id', 'campania_id', 'pais_id']) c;
select col_type_is('public', 'precio_general', 'precio_venta', 'integer', 'el importe es entero (centavos)');
select col_not_null('public', 'precio_general', 'precio_venta', 'el importe es obligatorio');
select col_not_null('public', 'precio_general', 'valido_desde', 'valido_desde es obligatorio');
select col_is_null('public', 'precio_general', 'valido_hasta', 'valido_hasta puede ser null (vigente hasta nuevo aviso)');
select col_is_null('public', 'precio_general', 'producto_id', 'producto_id puede ser null (el precio es de una colección)');
select fk_ok('public', 'precio_general', 'producto_id', 'public', 'producto', 'id', 'producto_id apunta a producto');
select fk_ok('public', 'precio_general', 'coleccion_id', 'public', 'coleccion', 'id', 'coleccion_id apunta a coleccion');
select matches(
  (select pg_get_expr(d.adbin, d.adrelid) from pg_attrdef d
    where d.adrelid = 'public.precio_general'::regclass
      and d.adnum = (select attnum from pg_attribute where attrelid = 'public.precio_general'::regclass and attname = 'valido_desde')),
  'hoy_montevideo',
  'valido_desde se llena con hoy_montevideo(), no con current_date');
select is((select count(*)::int from pg_constraint
            where conrelid = 'public.precio_general'::regclass and contype = 'x'
              and conname in ('precio_general_producto_sin_solape', 'precio_general_coleccion_sin_solape')),
          2, 'las dos restricciones de no solapamiento, la de producto y la de colección');
select policies_are('public', 'precio_general',
  array['precio_general_select', 'precio_general_insert_admin', 'precio_general_update_admin'],
  'tres políticas: leer, insertar (ADMIN) y actualizar (ADMIN); sin DELETE, la baja es lógica');
select ok((select relrowsecurity from pg_class where oid = 'public.precio_general'::regclass), 'tiene RLS habilitada');
select has_trigger('public', 'precio_general', 'precio_general_auditoria_insert', 'trigger de auditoría en el INSERT');
select has_trigger('public', 'precio_general', 'precio_general_auditoria_update', 'trigger de auditoría en el UPDATE');
select has_index('public', 'precio_general', 'precio_general_delta_idx', array['xmin_w', 'id'],
                 'el índice del delta, listo para cuando el contrato de sync la registre');

select ok(has_table_privilege('authenticated', 'public.precio_general', 'select'), 'authenticated lee');
select ok(has_table_privilege('authenticated', 'public.precio_general', 'insert'), 'authenticated inserta (si la RLS lo deja)');
select ok(has_table_privilege('authenticated', 'public.precio_general', 'update'), 'authenticated actualiza (si la RLS lo deja)');
select ok(not has_table_privilege('authenticated', 'public.precio_general', 'delete'), 'authenticated no borra');
select ok(not has_table_privilege('authenticated', 'public.precio_general', 'truncate'), 'ni vacía la tabla');
select ok(not (has_table_privilege('anon', 'public.precio_general', 'select')
               or has_table_privilege('anon', 'public.precio_general', 'insert')
               or has_table_privilege('anon', 'public.precio_general', 'update')
               or has_table_privilege('anon', 'public.precio_general', 'delete')),
          'anon no tiene ningún privilegio');
select ok(has_table_privilege('service_role', 'public.precio_general', 'select')
          and has_table_privilege('service_role', 'public.precio_general', 'insert')
          and has_table_privilege('service_role', 'public.precio_general', 'update'),
          'service_role lee y escribe (seeds y jobs)');

-- El contrato de sync no se toca en este issue: la tabla no está registrada. Cuando el contrato la
-- sume (PR de docs que revisa Bruno), esta comprobación se cambia por la de su registro.
select is((select count(*)::int from sync.entidad where nombre = 'precio_general'), 0,
          'todavía no es una entidad del sync (espera el OK del contrato)');

select has_function('public', 'precio_vigente', array['uuid', 'uuid', 'uuid', 'date'], 'existe precio_vigente');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.precio_vigente(uuid,uuid,uuid,date)'::regprocedure),
          false, 'precio_vigente es SECURITY INVOKER: la RLS es la autoridad, la función no repite permisos');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.precio_vigente(uuid,uuid,uuid,date)'::regprocedure),
          's', 'y es STABLE');
select ok((select 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = 'public.precio_vigente(uuid,uuid,uuid,date)'::regprocedure),
          'con el search_path vacío');
select ok(has_function_privilege('authenticated', 'public.precio_vigente(uuid,uuid,uuid,date)', 'execute'),
          'authenticated la ejecuta');
select ok(has_function_privilege('service_role', 'public.precio_vigente(uuid,uuid,uuid,date)', 'execute'),
          'service_role la ejecuta (las validaciones del servidor)');
select ok(not has_function_privilege('anon', 'public.precio_vigente(uuid,uuid,uuid,date)', 'execute'),
          'anon no');

-- ---------------------------------------------------------------------------
-- 2. Las vigencias del general
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.precio_general (producto_id, coleccion_id, precio_venta)
     values ('01920000-0000-7000-8000-000000004311', '01920000-0000-7000-8000-0000000043d0', 100) $$,
  '23514', null, 'un precio de producto y de colección a la vez se rechaza');
select throws_ok(
  $$ insert into public.precio_general (producto_id, coleccion_id, precio_venta) values (null, null, 100) $$,
  '23514', null, 'y uno de ninguno de los dos, también');
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta) values ('01920000-0000-7000-8000-000000004318', -1) $$,
  '23514', null, 'un importe negativo se rechaza');
select lives_ok(
  $$ insert into public.precio_general (id, producto_id, precio_venta, valido_desde, valido_hasta)
     values ('01920000-0000-7000-8000-00000000432f', '01920000-0000-7000-8000-000000004318', 0,
             public.hoy_montevideo() - 200, public.hoy_montevideo() - 200) $$,
  'el importe 0 se acepta (ejemplar misionero), y un tramo de un solo día');
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde, valido_hasta)
     values ('01920000-0000-7000-8000-000000004318', 100, '2026-05-10', '2026-05-09') $$,
  '23514', null, 'una vigencia que termina antes de empezar se rechaza');
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta) values (null, 100) $$,
  '23514', null, 'sin producto ni colección se rechaza (también con el importe)');

-- Un solo general vigente a la vez por producto: p1 ya tiene g1 abierto.
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004311', 25000, public.hoy_montevideo() - 10) $$,
  '23P01', 'conflicting key value violates exclusion constraint "precio_general_producto_sin_solape"',
  'otro general vigente del mismo producto se rechaza');
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004311', 24000, public.hoy_montevideo() + 10) $$,
  '23P01', null, 'aunque valga lo mismo y empiece más adelante (el primero no tiene fin)');
select lives_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000431a', 24000, public.hoy_montevideo() - 10) $$,
  'otro producto no se pisa');
-- p3 tiene dos tramos contiguos (g3a termina h-31, g3b empieza h-30): no se pisan.
select is((select count(*)::int from public.precio_general
            where producto_id = pg_temp.u('13') and deleted_at is null), 2,
          'dos tramos contiguos (el día siguiente) del mismo producto conviven');
select throws_ok(
  $$ update public.precio_general set valido_desde = public.hoy_montevideo() - 31
      where id = '01920000-0000-7000-8000-000000004324' $$,
  '23P01', null, 'estirar un tramo sobre el día final del anterior se rechaza');
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde, valido_hasta)
     values ('01920000-0000-7000-8000-000000004313', 1, public.hoy_montevideo() - 35, public.hoy_montevideo() - 20) $$,
  '23P01', null, 'un tramo que entra en dos vigencias se rechaza');
select lives_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde, valido_hasta)
     values ('01920000-0000-7000-8000-000000004313', 19000, public.hoy_montevideo() - 200, public.hoy_montevideo() - 101) $$,
  'un tramo histórico anterior a todos se acepta');
-- Colección: la misma regla, con su restricción.
select throws_ok(
  $$ insert into public.precio_general (coleccion_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000043d0', 46000, public.hoy_montevideo() - 5) $$,
  '23P01', 'conflicting key value violates exclusion constraint "precio_general_coleccion_sin_solape"',
  'una colección con dos generales vigentes se rechaza');
select lives_ok(
  $$ insert into public.precio_general (coleccion_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-0000000043d1', 41000, public.hoy_montevideo() - 50) $$,
  'un general de colección dado de baja no bloquea uno nuevo para la misma colección');
-- Un precio dado de baja no cuenta: ni al insertar uno nuevo ni, después, al reactivarlo. p8 tiene
-- un general dado de baja (g8, abierto desde hace 100 días).
select lives_ok(
  $$ insert into public.precio_general (id, producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000432a', '01920000-0000-7000-8000-000000004318', 9500,
             public.hoy_montevideo() - 50) $$,
  'un general dado de baja no bloquea uno nuevo para el mismo producto');
select throws_ok(
  $$ update public.precio_general set deleted_at = null where id = '01920000-0000-7000-8000-000000004328' $$,
  '23P01', null, 'pero no se puede reactivar el dado de baja si ahora se pisa con el vigente');

-- ---------------------------------------------------------------------------
-- 3. precio_vigente: modificado o, si no hay, general (como ADMIN: ve todo; la RLS va en la 4)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('ad'));
-- Con modificado y general vigentes, vale el modificado.
select is(pg_temp.pv('f1', '11'), 'MODIFICADO:25000:31', 'con modificado y general vigentes vale el modificado (y dice de cuál sale)');
-- Sin modificado en esa ciudad, el general.
select is(pg_temp.pv('f2', '11'), 'GENERAL:24000:21', 'sin modificado en la ciudad vale el general');
-- Sin ninguno, nada.
select is(pg_temp.pv('f1', '16'), '-', 'sin modificado ni general no hay precio (el producto no se ofrece)');
select is(pg_temp.pv('f2', '15'), '-', 'p5 sin general en otra ciudad donde no tiene modificado: nada');
-- Sin general, el modificado solo.
select is(pg_temp.pv('f1', '15'), 'MODIFICADO:5000:36', 'con modificado y sin general vale el modificado');
select is(pg_temp.pv('f4', '16'), 'MODIFICADO:3000:38', 'también en la ciudad de una campaña terminada (el ADMIN la ve)');
-- Modificado dado de baja: no cuenta.
select is(pg_temp.pv('f1', '12'), 'GENERAL:26000:22', 'un modificado dado de baja no cuenta: vale el general');
-- General dado de baja y ningún otro: nada.
select is(pg_temp.pv('f1', '14'), '-', 'un general dado de baja y ningún otro precio: no hay precio');
select is(pg_temp.pv('f1', '18', null, pg_temp.h() - 200), 'GENERAL:0:2f', 'p8 tiene un tramo de un solo día (importe 0): ese día vale');
select is(pg_temp.pv('f1', '18', null, pg_temp.h() - 60), '-', 'y el general dado de baja (de h-100 en adelante) no cuenta antes del nuevo (h-50)');
-- Modificado vencido y futuro: no cuentan.
select is(pg_temp.pv('f1', '13'), 'GENERAL:22000:24', 'un modificado vencido no cuenta: vale el general de hoy');
select is(pg_temp.pv('f3', '13'), 'GENERAL:22000:24', 'un modificado que empieza en el futuro todavía no cuenta');
-- Por fecha.
select is(pg_temp.pv('f1', '13', null, pg_temp.h() - 70), 'MODIFICADO:21000:33', 'con fecha: el día que el modificado vencido todavía valía');
select is(pg_temp.pv('f1', '13', null, pg_temp.h() - 61), 'MODIFICADO:21000:33', 'con fecha: el último día del modificado todavía vale (extremo inclusivo)');
select is(pg_temp.pv('f1', '13', null, pg_temp.h() - 60), 'GENERAL:20000:23', 'con fecha: el día siguiente al último del modificado, el general');
select is(pg_temp.pv('f1', '13', null, pg_temp.h() - 40), 'GENERAL:20000:23', 'con fecha: pasado el modificado, el general de entonces (el historial)');
select is(pg_temp.pv('f2', '13', null, pg_temp.h() - 31), 'GENERAL:20000:23', 'el último día de un tramo vale (extremo inclusivo)');
select is(pg_temp.pv('f2', '13', null, pg_temp.h() - 30), 'GENERAL:22000:24', 'el día siguiente vale el tramo nuevo (extremo inclusivo del desde)');
select matches(pg_temp.pv('f2', '13', null, pg_temp.h() - 150), '^GENERAL:19000:', 'un tramo histórico anterior a los demás: vale en su fecha');
select is(pg_temp.pv('f2', '13', null, pg_temp.h() - 210), '-', 'antes de que existiera cualquier precio: nada');
select is(pg_temp.pv('f3', '13', null, pg_temp.h() + 29), 'GENERAL:22000:24', 'la víspera de que empiece el modificado, todavía el general');
select is(pg_temp.pv('f3', '13', null, pg_temp.h() + 30), 'MODIFICADO:23000:34', 'el día que empieza, el modificado');
-- Colección.
select is(pg_temp.pv('f1', null, 'd0'), 'MODIFICADO:45000:37', 'una colección con modificado y general: el modificado');
select is(pg_temp.pv('f2', null, 'd0'), 'GENERAL:44000:26', 'una colección sin modificado en la ciudad: el general');
select is(pg_temp.pv('f1', null, '11'), '-', 'un producto y una colección no se mezclan: el id de un producto pasado como colección no encuentra nada');
-- Dos campañas en la misma ciudad no se pisan.
select is(pg_temp.pv('f3', '11'), 'MODIFICADO:26500:32', 'la otra campaña de la misma ciudad tiene su propio modificado');
select is(pg_temp.pv('f1', '11'), 'MODIFICADO:25000:31', 'y el de la primera no cambia');
select pg_temp.actuar_como_servidor();

-- «Hoy» es el día de Montevideo, con la sesión en cualquier zona horaria. p7 vale solo hoy: con
-- current_date, una de las dos zonas extremas (UTC+14, UTC-12) buscaría otro día y no lo encontraría.
select pg_temp.actuar_como(pg_temp.u('ad'));
select set_config('TimeZone', 'Pacific/Kiritimati', true);   -- UTC+14
select is(pg_temp.pv('f2', '17'), 'GENERAL:1000:27', 'sin fecha, con la sesión en UTC+14: el día de Montevideo');
select set_config('TimeZone', 'Etc/GMT+12', true);           -- UTC-12
select is(pg_temp.pv('f2', '17'), 'GENERAL:1000:27', 'sin fecha, con la sesión en UTC-12: también');
select set_config('TimeZone', 'UTC', true);
select is(pg_temp.pv('f2', '17'), 'GENERAL:1000:27', 'y con la sesión en UTC');
select is(pg_temp.pv('f2', '17', null, pg_temp.h() + 1), '-', 'mañana ya no vale');
select is(pg_temp.pv('f2', '17', null, pg_temp.h() - 1), '-', 'ayer tampoco');
select ok((now() at time zone 'Pacific/Kiritimati')::date <> public.hoy_montevideo()
          or (now() at time zone 'Etc/GMT+12')::date <> public.hoy_montevideo(),
          'control: current_date da otro día que Montevideo en alguna de las dos zonas extremas, a cualquier hora');
select pg_temp.actuar_como_servidor();

-- Argumentos que no cierran: 22023, con un aviso que dice qué pasar.
select pg_temp.actuar_como(pg_temp.u('ad'));
select throws_ok(
  $$ select * from public.precio_vigente('01920000-0000-7000-8000-0000000043f1') $$,
  '22023', null, 'sin producto ni colección: 22023');
select throws_ok(
  $$ select * from public.precio_vigente('01920000-0000-7000-8000-0000000043f1',
       '01920000-0000-7000-8000-000000004311', '01920000-0000-7000-8000-0000000043d0') $$,
  '22023', null, 'con los dos: 22023');
select throws_ok(
  $$ select * from public.precio_vigente(null, '01920000-0000-7000-8000-000000004311') $$,
  '22023', null, 'sin la ciudad de la campaña: 22023');
select throws_like(
  $$ select * from public.precio_vigente('01920000-0000-7000-8000-0000000043f1') $$,
  'precio_vigente pide la ciudad de la campaña%', 'y el mensaje dice qué pasar');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. precio_vigente y la RLS
-- ---------------------------------------------------------------------------
-- a1 coordina e1: sus ciudades, sí; la de otra campaña en la misma ciudad (f3), no: ni el general
-- como si ahí no hubiera modificado, que sería una respuesta falsa (en f3 hay otro precio).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.pv('f1', '11'), 'MODIFICADO:25000:31', 'el coordinador de la campaña ve el modificado de su ciudad');
select is(pg_temp.pv('f2', '11'), 'GENERAL:24000:21', 'y el general donde no modificó');
select is(pg_temp.pv('f3', '11'), '-', 'pero en la ciudad de otra campaña (la misma ciudad real) no ve nada: no se le dice «general» ahí');
select is(pg_temp.pv('f4', '16'), '-', 'ni en una campaña terminada de otro coordinador');
-- a2 coordina e2 (en curso) y e3 (terminada): las dos le valen.
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.pv('f3', '11'), 'MODIFICADO:26500:32', 'el otro coordinador ve el de su campaña, en la misma ciudad');
select is(pg_temp.pv('f1', '11'), '-', 'y no el de la primera');
select is(pg_temp.pv('f4', '16'), 'MODIFICADO:3000:38', 'un coordinador consulta una campaña suya terminada (los precios históricos)');
-- b1 (e1), b2 (e2): lo de su campaña.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.pv('f1', '11'), 'MODIFICADO:25000:31', 'el colportor de la campaña ve el modificado de su ciudad');
select is(pg_temp.pv('f2', '11'), 'GENERAL:24000:21', 'y el general en la otra ciudad de su campaña');
select is(pg_temp.pv('f3', '11'), '-', 'no el de otra campaña');
select is(pg_temp.pv('f1', '16'), '-', 'sin precio no hay precio');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.pv('f3', '11'), 'MODIFICADO:26500:32', 'el colportor de la otra campaña ve el suyo');
select is(pg_temp.pv('f1', '11'), '-', 'y no el de la campaña de la misma ciudad');
-- Los que no ven precios: ninguna fila, en ninguna ciudad.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.pv('f4', '16'), '-', 'un colportor de una campaña que ya terminó no consulta precios');
select is(pg_temp.pv('f1', '11'), '-', 'ni los de otra');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.pv('f1', '11'), '-', 'un colportor sin campaña no ve precios (ni el general)');
select is(pg_temp.pv('f2', '11'), '-', 'en ninguna ciudad');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.pv('f1', '11'), '-', 'con la inscripción dada de baja, no');
select pg_temp.actuar_como(pg_temp.u('b6'));
select is(pg_temp.pv('f1', '11'), '-', 'un usuario dado de baja, tampoco');
select pg_temp.actuar_como(pg_temp.u('a5'));
select is(pg_temp.pv('f1', '11'), '-', 'un coordinador sin campañas no ve los de ninguna');
-- Ciudad dada de baja: no hay precio, ni el general ni el modificado, aunque quien llama la vea.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.pv('f5', '11'), '-', 'una ciudad de la campaña dada de baja no devuelve nada (ni el ADMIN)');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.pv('f5', '11'), '-', 'ni su coordinador, que ve la baja como tombstone');
select is(pg_temp.pv('f1', '11') || pg_temp.pv('f2', '11'), '-' || '-', 'control: a2 sigue sin ver las ciudades de la campaña de a1');
-- Una ciudad que no existe.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.pv('f9', '11'), '-', 'una ciudad que no existe: nada');
select pg_temp.actuar_como_servidor();

-- anon no ejecuta; service_role sí, para cualquier ciudad (validaciones del servidor).
select pg_temp.actuar_como_rol('anon');
select throws_ok(
  $$ select * from public.precio_vigente('01920000-0000-7000-8000-0000000043f1', '01920000-0000-7000-8000-000000004311') $$,
  '42501', null, 'anon no ejecuta precio_vigente');
select pg_temp.actuar_como_rol('service_role');
select is(pg_temp.pv('f1', '11'), 'MODIFICADO:25000:31', 'service_role consulta cualquier ciudad (f1)');
select is(pg_temp.pv('f3', '11'), 'MODIFICADO:26500:32', 'y cualquier otra (f3)');
select is(pg_temp.pv('f2', '15'), '-', 'y sin precio no hay precio');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Quién lee el general
-- ---------------------------------------------------------------------------
-- Las filas del general de esta prueba con id fijo (los '432x'), tombstones incluidos (g4 y g8, dados
-- de baja): las 9 del fixture y las dos de la sección 2 con id fijo (`432a` y `432f`).
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-00000000432%'), 11,
          'control: las 11 filas con id fijo del general de la prueba (como postgres)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-00000000432%'), 11,
          'el ADMIN lee todo el general');
select ok(exists (select 1 from public.precio_general where id = pg_temp.u('28') and deleted_at is not null),
          'incluida la baja lógica (la app necesita el tombstone)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-00000000432%'), 11,
          'el coordinador de una campaña lo lee');
select ok(exists (select 1 from public.precio_general where id = pg_temp.u('28') and deleted_at is not null),
          'con la baja lógica');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-00000000432%'), 11,
          'el que coordina una campaña en curso y otra terminada, también');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-00000000432%'), 11,
          'el colportor inscripto en una campaña en curso lo lee');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.precio_general where id::text like '01920000-0000-7000-8000-00000000432%'), 11,
          'el de otra campaña, también: el general es de todas');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is((select count(*)::int from public.precio_general), 0,
          'un colportor de una campaña que ya terminó no lo lee');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is((select count(*)::int from public.precio_general), 0,
          'un colportor sin campaña no lee precios');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is((select count(*)::int from public.precio_general), 0,
          'con la inscripción dada de baja, no');
select pg_temp.actuar_como(pg_temp.u('b6'));
select is((select count(*)::int from public.precio_general), 0,
          'un usuario dado de baja, no');
select pg_temp.actuar_como(pg_temp.u('a5'));
select is((select count(*)::int from public.precio_general), 0,
          'un coordinador sin campañas, no');
select pg_temp.actuar_como_servidor();
select pg_temp.actuar_como_rol('anon');
select throws_ok($$ select count(*) from public.precio_general $$, '42501', null, 'anon no lo lee');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Quién escribe el general: solo el ADMIN
-- ---------------------------------------------------------------------------
-- El ADMIN: alta, cambio y baja lógica; no borra.
select pg_temp.actuar_como(pg_temp.u('ad'));
select lives_ok(
  $$ insert into public.precio_general (id, producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000432c', '01920000-0000-7000-8000-000000004315', 5500, '2026-01-01') $$,
  'el ADMIN carga un precio general');
select is((select sync_version from public.precio_general where id = pg_temp.u('2c')), 0::bigint,
          'su sync_version arranca en 0');
select is((select created_by from public.precio_general where id = pg_temp.u('2c')), pg_temp.u('ad'),
          'created_by es el ADMIN que lo cargó (lo fija el DEFAULT)');
select is(pg_temp.intentar_precio(pg_temp.u('2c'), 5600), 1, 'el ADMIN cambia un importe (1 fila)');
select is((select precio_venta from public.precio_general where id = pg_temp.u('2c')), 5600, 'y quedó cambiado');
select is((select sync_version from public.precio_general where id = pg_temp.u('2c')), 1::bigint,
          'el trigger de auditoría sube la versión');
select is(pg_temp.intentar_baja(pg_temp.u('2c')), 1, 'el ADMIN da de baja el precio (la baja es una actualización)');
select throws_ok(
  $$ delete from public.precio_general where id = '01920000-0000-7000-8000-00000000432c' $$,
  '42501', null, 'borrar de verdad no se puede (authenticated no tiene DELETE)');
-- Con el general cargado, el modificado sigue ganando donde existe; donde no, vale el general nuevo.
select is((select count(*)::int from public.precio_general where producto_id = pg_temp.u('15') and deleted_at is null), 0,
          'control: el precio de p5 quedó dado de baja');
select lives_ok(
  $$ insert into public.precio_general (id, producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-00000000432d', '01920000-0000-7000-8000-000000004315', 5700, '2026-01-01') $$,
  'y el ADMIN carga uno nuevo para el mismo producto (la baja no estorba)');
select is(pg_temp.pv('f1', '15'), 'MODIFICADO:5000:36', 'dar de alta el general no pisa el modificado de la campaña');
select is(pg_temp.pv('f2', '15'), 'GENERAL:5700:2d', 'y en la otra ciudad vale el general nuevo');
-- Reactivar el dado de baja se pisaría con el nuevo.
select throws_ok(
  $$ update public.precio_general set deleted_at = null where id = '01920000-0000-7000-8000-00000000432c' $$,
  '23P01', null, 'reactivar un precio dado de baja que se pisaría con el vigente se rechaza');
select pg_temp.actuar_como_servidor();

-- Coordinador de una campaña: no escribe el general.
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004316', 1000, '2026-01-01') $$,
  '42501', null, 'el coordinador de la campaña no carga un precio general');
select is(pg_temp.intentar_precio(pg_temp.u('21'), 1), 0, 'ni cambia uno: el update no toca ninguna fila');
select is(pg_temp.intentar_baja(pg_temp.u('21')), 0, 'ni lo da de baja');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004316', 1000, '2026-01-01') $$,
  '42501', null, 'tampoco el que coordina otra campaña (ni siquiera la terminada)');
select is(pg_temp.intentar_precio(pg_temp.u('22'), 1), 0, 'ni cambia uno');
-- Colportor de la campaña, sin campaña, coordinador sin campañas: tampoco.
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004316', 1000, '2026-01-01') $$,
  '42501', null, 'un colportor no carga un precio general');
select is(pg_temp.intentar_precio(pg_temp.u('21'), 1), 0, 'ni cambia uno (lo ve, pero la política no lo deja actualizar)');
select is(pg_temp.intentar_baja(pg_temp.u('21')), 0, 'ni lo da de baja');
select pg_temp.actuar_como(pg_temp.u('b4'));
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004316', 1000, '2026-01-01') $$,
  '42501', null, 'un colportor sin campaña no carga un precio general');
select pg_temp.actuar_como(pg_temp.u('a5'));
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004316', 1000, '2026-01-01') $$,
  '42501', null, 'un coordinador sin campañas, tampoco');
select pg_temp.actuar_como_rol('anon');
select throws_ok(
  $$ insert into public.precio_general (producto_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004316', 1000, '2026-01-01') $$,
  '42501', null, 'anon, tampoco');
select pg_temp.actuar_como_servidor();
-- Después de todos los intentos, el general de p1 y p2 sigue como estaba.
select results_eq(
  $$ select precio_venta, deleted_at is null from public.precio_general
      where id in ('01920000-0000-7000-8000-000000004321', '01920000-0000-7000-8000-000000004322') order by id $$,
  $$ values (24000, true), (26000, true) $$,
  'el general de p1 y p2 quedó intacto después de todos los intentos');
select is((select sync_version from public.precio_general where id = pg_temp.u('21')), 0::bigint,
          'y ni siquiera subió su versión');

-- La modificación de una campaña es del coordinador y no toca el general.
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok(
  $$ insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
     values ('01920000-0000-7000-8000-000000004339', '01920000-0000-7000-8000-000000004312',
             '01920000-0000-7000-8000-0000000043f1', 28000, public.hoy_montevideo()) $$,
  'el coordinador modifica el precio de p2 en una ciudad de su campaña');
select is(pg_temp.pv('f1', '12'), 'MODIFICADO:28000:39', 'y en su ciudad vale la modificación');
select is(pg_temp.pv('f2', '12'), 'GENERAL:26000:22', 'en la otra ciudad de la campaña sigue el general');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.pv('f3', '12'), 'GENERAL:26000:22', 'en la misma ciudad de otra campaña la modificación no se aplica: sigue el general');
select is(pg_temp.pv('f1', '12'), '-', 'y el coordinador de esa otra campaña no ve la modificación ajena');
select pg_temp.actuar_como_servidor();
select is((select sync_version from public.precio_general where id = pg_temp.u('22')), 0::bigint,
          'el general de p2 no se tocó (misma versión)');

-- ---------------------------------------------------------------------------
-- 7. Un cambio de precio: historial, y las ventas anteriores no cambian
-- ---------------------------------------------------------------------------
-- Una venta de p9 al precio general de entonces (30000, g9).
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
values (pg_temp.u('cc'), pg_temp.u('ca'), 'T-43', 60000, now(), pg_temp.u('b1'));
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
values (pg_temp.u('cd'), pg_temp.u('cc'), pg_temp.u('19'), 2, 30000, 60000);
create temp table venta0 on commit drop as
  select i.sync_version as v_item, i.updated_at as u_item, v.sync_version as v_venta, v.monto_total
    from public.venta_item i join public.venta v on v.id = i.venta_id where i.id = pg_temp.u('cd');

-- El ADMIN cambia el general de p9: cierra el vigente y carga el nuevo desde hoy (sin valido_desde).
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.pv('f2', '19'), 'GENERAL:30000:29', 'antes del cambio vale el general de 30000');
update public.precio_general set valido_hasta = public.hoy_montevideo() - 1 where id = pg_temp.u('29');
select lives_ok(
  $$ insert into public.precio_general (id, producto_id, precio_venta)
     values ('01920000-0000-7000-8000-00000000432e', '01920000-0000-7000-8000-000000004319', 33000) $$,
  'carga el nuevo sin valido_desde (hoy en Montevideo)');
select is(pg_temp.pv('f2', '19'), 'GENERAL:33000:2e', 'desde hoy vale el nuevo');
select is(pg_temp.pv('f2', '19', null, pg_temp.h() - 1), 'GENERAL:30000:29', 'y ayer valía el anterior (historial)');
select pg_temp.actuar_como_servidor();
select is((select valido_desde from public.precio_general where id = pg_temp.u('2e')), public.hoy_montevideo(),
          'valido_desde por defecto es el día de Montevideo');
select results_eq(
  $$ select i.precio_unitario, i.subtotal, i.sync_version = v.v_item, i.updated_at = v.u_item
       from public.venta_item i, venta0 v where i.id = '01920000-0000-7000-8000-0000000043cd' $$,
  $$ values (30000, 60000, true, true) $$,
  'la venta anterior conserva su precio_unitario (ni el importe ni la versión ni la fecha de modificación cambian)');
select is((select monto_total from public.venta where id = pg_temp.u('cc')), 60000, 'ni el monto de la venta');
select is((select count(*)::int from information_schema.table_constraints tc
             join information_schema.constraint_column_usage u using (constraint_schema, constraint_name)
            where tc.table_schema = 'public' and tc.constraint_type = 'FOREIGN KEY'
              and u.table_name = 'precio_general'),
          0, 'ninguna tabla tiene una FK al precio general (la venta guarda el suyo, sin apuntarlo)');

-- El procedimiento de cambio de la guía (docs/guia-carga-manual.md, § 8 y § 9): cierra ayer lo que ya
-- rige, da de baja lo que empieza hoy o más adelante y recién ahí inserta el nuevo. No puede dar 23514
-- con un precio cargado hoy ni agarrar uno futuro programado (revisión de #83, menor 3). Las dos
-- funciones repiten los pasos de la guía, con los ids de la prueba.
create or replace function pg_temp.cambiar_general(p_producto uuid, p_nuevo uuid, p_importe integer)
returns void language plpgsql as $$
begin
  update public.precio_general
     set valido_hasta = public.hoy_montevideo() - 1
   where producto_id = p_producto and deleted_at is null
     and valido_desde < public.hoy_montevideo()
     and (valido_hasta is null or valido_hasta >= public.hoy_montevideo());
  update public.precio_general
     set deleted_at = now()
   where producto_id = p_producto and deleted_at is null
     and valido_desde >= public.hoy_montevideo();
  insert into public.precio_general (id, producto_id, precio_venta, valido_desde)
  values (p_nuevo, p_producto, p_importe, public.hoy_montevideo());
end $$;
create or replace function pg_temp.cambiar_modificado(p_producto uuid, p_ciudad uuid, p_nuevo uuid, p_importe integer)
returns void language plpgsql as $$
begin
  update public.precio_por_ciudad
     set valido_hasta = public.hoy_montevideo() - 1
   where producto_id = p_producto and campania_ciudad_id = p_ciudad and deleted_at is null
     and valido_desde < public.hoy_montevideo()
     and (valido_hasta is null or valido_hasta >= public.hoy_montevideo());
  update public.precio_por_ciudad
     set deleted_at = now()
   where producto_id = p_producto and campania_ciudad_id = p_ciudad and deleted_at is null
     and valido_desde >= public.hoy_montevideo();
  insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde)
  values (p_nuevo, p_producto, p_ciudad, p_importe, public.hoy_montevideo());
end $$;

select pg_temp.actuar_como_servidor();
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('61'), 'Libro p14 general43', 'LIBRO'),
  (pg_temp.u('62'), 'Libro p15 general43', 'LIBRO'),
  (pg_temp.u('63'), 'Libro p16 general43', 'LIBRO'),
  (pg_temp.u('64'), 'Libro p17 general43', 'LIBRO'),
  (pg_temp.u('65'), 'Libro p18 general43', 'LIBRO');
-- p14: general cargado HOY (el caso que antes daba 23514). p15: general que rige y otro programado a
-- futuro, abierto (el update viejo agarraba el futuro). p16: el general abierto de siempre.
insert into public.precio_general (id, producto_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('71'), pg_temp.u('61'), 1000, pg_temp.h(), null),
  (pg_temp.u('73'), pg_temp.u('62'), 1000, pg_temp.h() - 10, pg_temp.h() + 4),
  (pg_temp.u('74'), pg_temp.u('62'), 1500, pg_temp.h() + 5, null),
  (pg_temp.u('76'), pg_temp.u('63'), 1000, pg_temp.h() - 100, null);
-- p17: modificado cargado HOY; p18: modificado que rige y otro programado (f1, la ciudad de e1).
insert into public.precio_por_ciudad (id, producto_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('7a'), pg_temp.u('64'), pg_temp.u('f1'), 3000, pg_temp.h(), null),
  (pg_temp.u('7c'), pg_temp.u('65'), pg_temp.u('f1'), 3000, pg_temp.h() - 10, pg_temp.h() + 4),
  (pg_temp.u('7d'), pg_temp.u('65'), pg_temp.u('f1'), 3200, pg_temp.h() + 5, null);

select lives_ok(
  $$ select pg_temp.cambiar_general('01920000-0000-7000-8000-000000004361', '01920000-0000-7000-8000-000000004372', 2000) $$,
  'cambiar el general cargado HOY con el procedimiento de la guía no da 23514');
select results_eq(
  $$ select id, precio_venta, deleted_at is not null from public.precio_general
      where producto_id = '01920000-0000-7000-8000-000000004361' order by precio_venta $$,
  $$ values ('01920000-0000-7000-8000-000000004371'::uuid, 1000, true),
            ('01920000-0000-7000-8000-000000004372'::uuid, 2000, false) $$,
  'el cargado hoy queda dado de baja y rige el nuevo');
select lives_ok(
  $$ select pg_temp.cambiar_general('01920000-0000-7000-8000-000000004362', '01920000-0000-7000-8000-000000004375', 2000) $$,
  'con un general programado a futuro, el procedimiento de la guía tampoco falla');
select results_eq(
  $$ select id, valido_hasta, deleted_at is not null from public.precio_general
      where producto_id = '01920000-0000-7000-8000-000000004362' order by id $$,
  $$ values ('01920000-0000-7000-8000-000000004373'::uuid, public.hoy_montevideo() - 1, false),
            ('01920000-0000-7000-8000-000000004374'::uuid, null::date, true),
            ('01920000-0000-7000-8000-000000004375'::uuid, null::date, false) $$,
  'el que regía se cierra ayer, el programado se da de baja y el nuevo queda abierto');
select lives_ok(
  $$ select pg_temp.cambiar_general('01920000-0000-7000-8000-000000004363', '01920000-0000-7000-8000-000000004377', 2000) $$,
  'y el cambio de siempre (general abierto desde hace tiempo) sigue andando');
select results_eq(
  $$ select id, valido_hasta, deleted_at is not null from public.precio_general
      where producto_id = '01920000-0000-7000-8000-000000004363' order by id $$,
  $$ values ('01920000-0000-7000-8000-000000004376'::uuid, public.hoy_montevideo() - 1, false),
            ('01920000-0000-7000-8000-000000004377'::uuid, null::date, false) $$,
  'el viejo queda cerrado ayer (historial) y rige el nuevo');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.pv('f1', '62'), 'GENERAL:2000:75', 'hoy vale el nuevo general');
select is(pg_temp.pv('f1', '62', null, pg_temp.h() - 5), 'GENERAL:1000:73', 'y hace cinco días valía el que regía');
select pg_temp.actuar_como_servidor();

select lives_ok(
  $$ select pg_temp.cambiar_modificado('01920000-0000-7000-8000-000000004364', '01920000-0000-7000-8000-0000000043f1',
                                       '01920000-0000-7000-8000-00000000437b', 3500) $$,
  'cambiar el precio por ciudad cargado HOY con el procedimiento de la guía no da 23514');
select results_eq(
  $$ select id, precio_venta, deleted_at is not null from public.precio_por_ciudad
      where producto_id = '01920000-0000-7000-8000-000000004364' order by precio_venta $$,
  $$ values ('01920000-0000-7000-8000-00000000437a'::uuid, 3000, true),
            ('01920000-0000-7000-8000-00000000437b'::uuid, 3500, false) $$,
  'el cargado hoy queda dado de baja y rige el nuevo (precio por ciudad)');
select lives_ok(
  $$ select pg_temp.cambiar_modificado('01920000-0000-7000-8000-000000004365', '01920000-0000-7000-8000-0000000043f1',
                                       '01920000-0000-7000-8000-00000000437e', 3500) $$,
  'con un precio por ciudad programado a futuro, el procedimiento de la guía tampoco falla');
select results_eq(
  $$ select id, valido_hasta, deleted_at is not null from public.precio_por_ciudad
      where producto_id = '01920000-0000-7000-8000-000000004365' order by id $$,
  $$ values ('01920000-0000-7000-8000-00000000437c'::uuid, public.hoy_montevideo() - 1, false),
            ('01920000-0000-7000-8000-00000000437d'::uuid, null::date, true),
            ('01920000-0000-7000-8000-00000000437e'::uuid, null::date, false) $$,
  'el que regía se cierra ayer, el programado se da de baja y el nuevo queda abierto (precio por ciudad)');

-- Con la sesión en cualquier zona horaria, el valido_desde por defecto es el día de Montevideo.
select pg_temp.actuar_como(pg_temp.u('ad'));
select set_config('TimeZone', 'Pacific/Kiritimati', true);
insert into public.precio_general (id, producto_id, precio_venta) values (pg_temp.u('4a'), pg_temp.u('1b'), 1);
select set_config('TimeZone', 'Etc/GMT+12', true);
insert into public.precio_general (id, producto_id, precio_venta) values (pg_temp.u('4b'), pg_temp.u('1c'), 1);
select set_config('TimeZone', 'UTC', true);
insert into public.precio_general (id, producto_id, precio_venta) values (pg_temp.u('4c'), pg_temp.u('1d'), 1);
select pg_temp.actuar_como_servidor();
select is((select valido_desde from public.precio_general where id = pg_temp.u('4a')), public.hoy_montevideo(),
          'con la sesión en UTC+14, valido_desde es el día de Montevideo');
select is((select valido_desde from public.precio_general where id = pg_temp.u('4b')), public.hoy_montevideo(),
          'con la sesión en UTC-12, también');
select is((select valido_desde from public.precio_general where id = pg_temp.u('4c')), public.hoy_montevideo(),
          'y con la sesión en UTC');

select * from finish();
rollback;
