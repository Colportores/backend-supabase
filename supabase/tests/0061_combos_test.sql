-- pgTAP · migración 0056 (backend-supabase#99, HU-CAT-009 y HU-VEN-001, C10): un combo es una colección
-- con precio propio y se vende como un solo ítem.
--   1. La forma: venta_item.coleccion_id (uuid, opcional, FK a coleccion), producto_id opcional, el CHECK
--      «uno de los dos», el índice; producto_coleccion.cantidad (integer, NOT NULL, default 1, > 0).
--   2. Armar un combo: «1 libro y 2 revistas»; la cantidad por defecto, cero, negativa o null; el mismo
--      producto dos veces; un combo dentro de otro combo no se puede representar (23503).
--   3. El precio del combo: el general para todo el país, la excepción de una ciudad, un combo sin precio
--      no se ofrece, y quien no ve la ciudad no lo ve; precios_de_la_ciudad() lo lista como COLECCION.
--   4. Vender un combo: un ítem con coleccion_id y sin producto_id (directo y por sync_push); los dos o
--      ninguno, una colección que no existe, el subtotal que no cuadra y la venta de otro colportor se
--      rechazan; el reintento del push es idempotente.
--   5. La composición cambia después de la venta: la venta conserva su ítem y su precio.
--   6. Lo que no se toca: los ítems de producto de siempre y el sync siguen igual.
-- Desde la 0071 (backend-supabase#138) un ítem de combo lleva además `componentes` (lo que traía el combo): las
-- inserciones de combos de este archivo lo mandan; sus reglas están en 0071_combo_a_elegir_y_motivo_del_monto_test.sql.
-- Va en una transacción.
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
  select ('01920000-0000-7000-8000-0000000061' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- Lo que precio_vigente devuelve a quien llama, en una línea: «ORIGEN:importe» o «-» (INVOKER: rol y JWT de la sesión).
create or replace function pg_temp.pv(p_cc text, p_prod text, p_col text default null)
returns text language sql as $$
  select coalesce(
    (select v.origen || ':' || v.precio_venta
       from public.precio_vigente(pg_temp.u(p_cc), pg_temp.u(p_prod), pg_temp.u(p_col), null) v),
    '-');
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000061d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_entidad text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', 'insert',
                            'sync_version', null, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Un ítem de venta de un combo (o de un producto) tal como lo sube el teléfono.
create or replace function pg_temp.payload_item(p_id text, p_venta text, p_prod text, p_col text,
                                                p_cant integer, p_precio integer)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', pg_temp.u(p_id), 'venta_id', pg_temp.u(p_venta),
    'producto_id', pg_temp.u(p_prod), 'coleccion_id', pg_temp.u(p_col),
    'cantidad', p_cant, 'precio_unitario', p_precio, 'subtotal', p_cant * p_precio,
    -- Desde la 0071 un ítem de combo trae lo que traía el combo (1 libro y 2 revistas).
    'componentes', case when p_col is not null then jsonb_build_array(
      jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1),
      jsonb_build_object('producto_id', pg_temp.u('12'), 'cantidad', 2)) end));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- ad es ADMIN; b1 está inscripto en la campaña e1 (ciudades f1 = c1 y f2 = c2); b2 es colportor sin campaña.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'combos61-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais combos61', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 combos61', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16),
  (pg_temp.u('c2'), 'Ciudad c2 combos61', 'Departamento de prueba', pg_temp.u('c0'), -34.70, -56.20);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 combos61', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e1'), pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);

-- Catálogo: un libro (11), una revista (12), un producto suelto (13). El combo «Pack Familiar» (d0) lleva 1 libro
-- y 2 revistas; el combo d1 no tiene precio en ningún lado.
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro p1 combos61', 'LIBRO'),
  (pg_temp.u('12'), 'Revista p2 combos61', 'REVISTA'),
  (pg_temp.u('13'), 'Libro p3 combos61', 'LIBRO');
insert into public.coleccion (id, nombre) values
  (pg_temp.u('d0'), 'Pack Familiar combos61'),
  (pg_temp.u('d1'), 'Combo sin precio combos61');
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  (pg_temp.u('a1'), pg_temp.u('11'), pg_temp.u('d0'), 1),
  (pg_temp.u('a2'), pg_temp.u('12'), pg_temp.u('d0'), 2);
-- El libro tiene su propio precio general: el del combo no sale de la suma de los componentes.
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('21'), pg_temp.u('11'), null, 24000, pg_temp.h() - 100, null),
  (pg_temp.u('22'), pg_temp.u('12'), null,  7500, pg_temp.h() - 100, null),
  (pg_temp.u('23'), null, pg_temp.u('d0'), 120000, pg_temp.h() - 100, null);
-- Excepción del combo en la ciudad f1.
insert into public.precio_por_ciudad (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('31'), null, pg_temp.u('d0'), pg_temp.u('f1'), 110000, pg_temp.h() - 100, null);
-- Una casa y un vínculo para las ventas de b1.
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'venta_item', 'coleccion_id', 'venta_item tiene coleccion_id');
select col_type_is('public', 'venta_item', 'coleccion_id', 'uuid', 'coleccion_id es uuid');
select col_is_null('public', 'venta_item', 'coleccion_id', 'coleccion_id es opcional: el ítem puede ser un producto');
select col_is_null('public', 'venta_item', 'producto_id', 'producto_id pasa a ser opcional: el ítem puede ser un combo');
select col_hasnt_default('public', 'venta_item', 'coleccion_id', 'coleccion_id no tiene default');
select fk_ok('public', 'venta_item', 'coleccion_id', 'public', 'coleccion', 'id', 'coleccion_id apunta a coleccion(id)');
select fk_ok('public', 'venta_item', 'producto_id', 'public', 'producto', 'id', 'producto_id sigue apuntando a producto(id)');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.venta_item'::regclass and conname = 'venta_item_producto_o_coleccion'),
          'CHECK (((producto_id IS NULL) <> (coleccion_id IS NULL)))',
          'el CHECK pide exactamente uno de producto_id / coleccion_id (el mismo de los precios)');
select is((select count(*)::int from pg_constraint
            where conrelid = 'public.venta_item'::regclass and contype = 'c'
              and pg_get_constraintdef(oid) like '%subtotal = (cantidad * precio_unitario)%'),
          1, 'y el CHECK del subtotal sigue');
select has_index('public', 'venta_item', 'venta_item_coleccion_idx', 'venta_item tiene el índice por colección');
select has_index('public', 'venta_item', 'venta_item_producto_idx', 'y el de producto sigue');
select col_type_is('public', 'producto_coleccion', 'cantidad', 'integer', 'producto_coleccion.cantidad es integer');
select col_not_null('public', 'producto_coleccion', 'cantidad', 'cantidad es obligatoria');
select col_default_is('public', 'producto_coleccion', 'cantidad', '1', 'y vale 1 si no se manda');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.producto_coleccion'::regclass and conname = 'producto_coleccion_cantidad_positiva'),
          'CHECK ((cantidad > 0))', 'cantidad tiene que ser positiva');
select is((select count(*)::int from sync.entidad where nombre in ('venta_item', 'producto_coleccion')), 2,
          'venta_item y producto_coleccion siguen en el sync');

-- ---------------------------------------------------------------------------
-- 2. Armar un combo
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select p.nombre, pc.cantidad from public.producto_coleccion pc
       join public.producto p on p.id = pc.producto_id
      where pc.coleccion_id = '01920000-0000-7000-8000-0000000061d0'
      order by 1 $$,
  $$ values ('Libro p1 combos61'::text, 1), ('Revista p2 combos61', 2) $$,
  'el Pack Familiar lleva 1 libro y 2 revistas');
select lives_ok(
  $$ insert into public.producto_coleccion (id, producto_id, coleccion_id)
     values ('01920000-0000-7000-8000-0000000061a3', '01920000-0000-7000-8000-000000006113',
             '01920000-0000-7000-8000-0000000061d1') $$,
  'un componente sin cantidad se carga');
select is((select cantidad from public.producto_coleccion where id = pg_temp.u('a3')), 1,
          'y lleva 1 unidad: la cantidad por defecto');
select is(pg_temp.error_de($$ insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad)
     values ('01920000-0000-7000-8000-0000000061a4', '01920000-0000-7000-8000-000000006111',
             '01920000-0000-7000-8000-0000000061d1', 0) $$), '23514', 'cantidad 0: rechazada');
select is(pg_temp.error_de($$ insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad)
     values ('01920000-0000-7000-8000-0000000061a4', '01920000-0000-7000-8000-000000006111',
             '01920000-0000-7000-8000-0000000061d1', -2) $$), '23514', 'cantidad negativa: rechazada');
select is(pg_temp.error_de($$ insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad)
     values ('01920000-0000-7000-8000-0000000061a4', '01920000-0000-7000-8000-000000006111',
             '01920000-0000-7000-8000-0000000061d1', null) $$), '23502', 'cantidad null: rechazada (NOT NULL)');
select is(pg_temp.error_de($$ update public.producto_coleccion set cantidad = 0
      where id = '01920000-0000-7000-8000-0000000061a2' $$), '23514', 'bajar la cantidad de un componente a 0 también');
select is(pg_temp.error_de($$ insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad)
     values ('01920000-0000-7000-8000-0000000061a5', '01920000-0000-7000-8000-000000006112',
             '01920000-0000-7000-8000-0000000061d0', 5) $$), '23505',
          'el mismo producto dos veces en un combo: se cambia la cantidad de la fila, no se repite');
-- Un combo no puede incluir otro combo: producto_id apunta a producto y no a una colección.
select is(pg_temp.error_de($$ insert into public.producto_coleccion (id, producto_id, coleccion_id)
     values ('01920000-0000-7000-8000-0000000061a6', '01920000-0000-7000-8000-0000000061d0',
             '01920000-0000-7000-8000-0000000061d1') $$), '23503',
          'un combo dentro de otro combo no se puede representar: producto_id es una FK a producto');
select is((select count(*)::int from public.producto_coleccion where coleccion_id = pg_temp.u('d1')), 1,
          'y el combo d1 quedó solo con el componente bueno');
select is((select sum(cantidad)::int from public.producto_coleccion where coleccion_id = pg_temp.u('d0')), 3,
          'el Pack Familiar sigue en 3 unidades en total después de todos los intentos');

-- ---------------------------------------------------------------------------
-- 3. El precio del combo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.pv('f1', null, 'd0'), 'MODIFICADO:110000', 'en la ciudad con excepción el combo vale la excepción');
select is(pg_temp.pv('f2', null, 'd0'), 'GENERAL:120000', 'en la otra vale el general de todo el país');
select is(pg_temp.pv('f1', null, 'd1'), '-', 'un combo sin precio no tiene vigente: no se ofrece (R-CT05)');
select is(pg_temp.pv('f1', '11'), 'GENERAL:24000',
          'el libro del combo sigue con su precio propio: el del combo no sale de sumar componentes');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.pv('f2', null, 'd0'), '-', 'un colportor sin campaña en esa ciudad no lo ve');
select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq(
  $$ select tipo, nombre, precio_general, precio_modificado, precio_vigente, origen
       from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000061f1')
      where id = '01920000-0000-7000-8000-0000000061d0' $$,
  $$ values ('COLECCION'::text, 'Pack Familiar combos61'::text, 120000, 110000, 110000, 'MODIFICADO'::text) $$,
  'precios_de_la_ciudad lista el combo como COLECCION con su general, su excepción y el que rige');
select results_eq(
  $$ select precio_general, precio_modificado, precio_vigente, origen
       from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000061f2')
      where id = '01920000-0000-7000-8000-0000000061d0' $$,
  $$ values (120000, null::integer, 120000, 'GENERAL'::text) $$,
  'y en la otra ciudad rige el general');
select results_eq(
  $$ select precio_vigente, origen from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000061f1')
      where id = '01920000-0000-7000-8000-0000000061d1' $$,
  $$ values (null::integer, null::text) $$,
  'el combo sin precio sale con el precio vigente en null');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Vender un combo
-- ---------------------------------------------------------------------------
-- La venta de b1: dos Pack Familiar a 110000 en f1 = 220000 (un solo ítem, no tres líneas).
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
values (pg_temp.u('b0'), pg_temp.u('ca'), 'T-61', 220000, now(), pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select lives_ok(
  $$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000061b1', '01920000-0000-7000-8000-0000000061b0',
             '01920000-0000-7000-8000-0000000061d0', 2, 110000, 220000, '[{"producto_id": "01920000-0000-7000-8000-000000006111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000006112", "cantidad": 2}]'::jsonb) $$,
  'el colportor vende el combo como un ítem: coleccion_id y sin producto_id');
select results_eq(
  $$ select producto_id is null, coleccion_id, cantidad, precio_unitario, subtotal
       from public.venta_item where venta_id = '01920000-0000-7000-8000-0000000061b0' $$,
  $$ values (true, '01920000-0000-7000-8000-0000000061d0'::uuid, 2, 110000, 220000) $$,
  'la venta tiene UN ítem, con el precio del combo y no el de cada componente');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, producto_id, coleccion_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-0000000061b2', '01920000-0000-7000-8000-0000000061b0',
             '01920000-0000-7000-8000-000000006111', '01920000-0000-7000-8000-0000000061d0',
             1, 1000, 1000) $$), '23514', 'un ítem con producto y colección a la vez: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-0000000061b2', '01920000-0000-7000-8000-0000000061b0',
             1, 1000, 1000) $$), '23514', 'un ítem sin producto ni colección: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000061b2', '01920000-0000-7000-8000-0000000061b0',
             '01920000-0000-7000-8000-0000000061ee', 1, 1000, 1000, '[{"producto_id": "01920000-0000-7000-8000-000000006111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000006112", "cantidad": 2}]'::jsonb) $$), '23503', 'una colección que no existe: rechazada');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000061b2', '01920000-0000-7000-8000-0000000061b0',
             '01920000-0000-7000-8000-0000000061d0', 2, 110000, 999, '[{"producto_id": "01920000-0000-7000-8000-000000006111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000006112", "cantidad": 2}]'::jsonb) $$), '23514', 'el subtotal del combo también es cantidad * precio_unitario');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000061b2', '01920000-0000-7000-8000-0000000061b0',
             '01920000-0000-7000-8000-0000000061d0', 0, 110000, 0, '[{"producto_id": "01920000-0000-7000-8000-000000006111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000006112", "cantidad": 2}]'::jsonb) $$), '23514', 'ni 0 unidades de un combo');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000061b2', '01920000-0000-7000-8000-0000000061b0',
             '01920000-0000-7000-8000-0000000061d0', 1, 110000, 110000, '[{"producto_id": "01920000-0000-7000-8000-000000006111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000006112", "cantidad": 2}]'::jsonb) $$), '42501',
          'otro colportor no agrega un combo a la venta de b1');
select is((select count(*)::int from public.venta_item), 0, 'y b2 no ve el ítem de b1');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta_item where venta_id = pg_temp.u('b0')), 1,
          'después de todos los intentos la venta sigue con su único ítem');

-- Por el sync, que es el camino real: la venta y sus ítems (un combo y un libro suelto) suben juntos.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('c1', 'venta', jsonb_build_object('id', pg_temp.u('b3'), 'espacio_persona_id', pg_temp.u('ca'),
                'numero_talonario', 'T-62', 'monto_total', 134500, 'fecha', now(),
                'motivo_monto_manual', 'el último ítem pasa el total (0150)')),
    pg_temp.job('c2', 'venta_item', pg_temp.payload_item('b4', 'b3', null, 'd0', 1, 110000)),
    pg_temp.job('c3', 'venta_item', pg_temp.payload_item('b5', 'b3', '11', null, 1, 24500)))) as r;
grant select on r_push to authenticated;
select is(pg_temp.resultados((select r from r_push)), array['accepted', 'accepted', 'accepted'],
          'push: la venta, el ítem del combo y el ítem del libro entran');
select results_eq(
  $$ select producto_id is null, coleccion_id is null, precio_unitario
       from public.venta_item where venta_id = '01920000-0000-7000-8000-0000000061b3' order by id $$,
  $$ values (true, false, 110000), (false, true, 24500) $$,
  'el combo quedó con coleccion_id y el libro con producto_id');
create temp table r_push2 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('c2', 'venta_item', pg_temp.payload_item('b4', 'b3', null, 'd0', 1, 110000)))) as r;
grant select on r_push2 to authenticated;
select is(pg_temp.resultados((select r from r_push2)), array['duplicate'],
          'el reintento del mismo ítem es idempotente (duplicate)');
create temp table r_push3 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('c4', 'venta_item', pg_temp.payload_item('b6', 'b3', '11', 'd0', 1, 1000)),
    pg_temp.job('c5', 'venta_item', jsonb_build_object('id', pg_temp.u('b7'), 'venta_id', pg_temp.u('b3'),
                'cantidad', 1, 'precio_unitario', 1000, 'subtotal', 1000)),
    pg_temp.job('c6', 'venta_item', pg_temp.payload_item('b8', 'b3', null, 'ee', 1, 1000)),
    pg_temp.job('c7', 'venta_item', pg_temp.payload_item('b9', 'b3', null, 'd1', 3, 5000)))) as r;
grant select on r_push3 to authenticated;
select is(pg_temp.resultados((select r from r_push3)), array['invalid', 'invalid', 'invalid', 'accepted'],
          'push: los dos a la vez, ninguno y una colección inexistente vuelven invalid y el lote sigue');
select is(pg_temp.codigos((select r from r_push3)), array['23514', '23514', '23503', '-'],
          'cada uno con su SQLSTATE: 23514, 23514, 23503');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta_item where venta_id = pg_temp.u('b3')), 3,
          'la venta del push quedó con sus 3 ítems (los rechazados no dejaron nada)');

-- ---------------------------------------------------------------------------
-- 5. La composición cambia después de la venta
-- ---------------------------------------------------------------------------
-- La venta guarda el ítem del combo y su precio; cambiar la cantidad de un componente o dar de baja el
-- precio no toca la venta (ni su versión de sync).
create temp table venta0 on commit drop as
  select i.sync_version as v_item, i.updated_at as u_item, i.cantidad, i.precio_unitario, i.subtotal
    from public.venta_item i where i.id = pg_temp.u('b1');
update public.producto_coleccion set cantidad = 3 where id = pg_temp.u('a2');
update public.precio_por_ciudad set deleted_at = now() where id = pg_temp.u('31');
select results_eq(
  $$ select i.cantidad, i.precio_unitario, i.subtotal, i.sync_version = v.v_item, i.updated_at = v.u_item
       from public.venta_item i, venta0 v where i.id = '01920000-0000-7000-8000-0000000061b1' $$,
  $$ values (2, 110000, 220000, true, true) $$,
  'la venta anterior conserva su ítem y su precio (ni la versión ni la fecha cambian)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.pv('f1', null, 'd0'), 'GENERAL:120000', 'y el combo, sin la excepción, vuelve al general para las ventas nuevas');
select pg_temp.actuar_como_servidor();

-- Un componente dado de baja: el combo sigue en el catálogo con su componente dado de baja (la lista de los
-- combos afectados que usa la guía de carga manual).
update public.producto set deleted_at = now() where id = pg_temp.u('12');
select results_eq(
  $$ select c.nombre, p.nombre
       from public.coleccion c
       join public.producto_coleccion pc on pc.coleccion_id = c.id and pc.deleted_at is null
       join public.producto p on p.id = pc.producto_id and p.deleted_at is not null
      where c.deleted_at is null and c.id in ('01920000-0000-7000-8000-0000000061d0', '01920000-0000-7000-8000-0000000061d1') $$,
  $$ values ('Pack Familiar combos61'::text, 'Revista p2 combos61'::text) $$,
  'la consulta de la guía encuentra el combo con un componente dado de baja');

-- ---------------------------------------------------------------------------
-- 6. Lo que no se toca
-- ---------------------------------------------------------------------------
select is('coleccion_id' = any (sync.columnas_escribibles('venta_item')), true,
          'coleccion_id es una columna que el teléfono puede escribir');
select is('producto_id' = any (sync.columnas_escribibles('venta_item')), true, 'y producto_id también');
select is('cantidad' = any (sync.columnas_escribibles('producto_coleccion')), true,
          'cantidad es una columna de producto_coleccion para el sync');
select is((select sync.expresion_json('public.producto_coleccion'::regclass) like '%''cantidad''%'), true,
          'y el pull la serializa');

select * from finish();
rollback;
