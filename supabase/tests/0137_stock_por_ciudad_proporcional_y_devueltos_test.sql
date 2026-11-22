-- pgTAP · 0137 (backend-supabase#201, decisiones «Por cobrar» y «Devol. stock» del 27/10, seguimiento de 0111):
-- stock_por_ciudad() cuenta lo «por cobrar» en proporción a lo que falta cobrar de cada venta (redondeo hacia
-- arriba, regla R4) y trae la columna nueva «devueltos». Cubre:
--   1. La forma: la columna nueva está, y `entregados` sigue siendo lo entregado.
--   2. Por cobrar proporcional: mitad, un tercio, nada cobrado, paga justo, cobrada de más, redondeo hacia arriba.
--   3. Devueltos: se suman por libro; la devolución anulada y la de una venta fuera de la campaña no cuentan; un
--      libro con solo devoluciones sale igual.
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
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000137' || p)::uuid;
$$;
-- «por_entregar|entregados|devueltos|por_cobrar» de b1 y un libro.
create or replace function pg_temp.fila(p_prod text) returns text language sql as $$
  select coalesce((
    select format('%s|%s|%s|%s', r.por_entregar, r.entregados, r.devueltos, r.por_cobrar)
      from public.stock_por_ciudad(pg_temp.u('e1')) r
     where r.colportor_id = pg_temp.u('b1') and r.producto_id = pg_temp.u(p_prod)), 'sin fila')
$$;

-- --- fixtures ------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'stock137-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','b1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id from (values ('ad','ADMIN'), ('b1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Cierre 137', 'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('ad'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), '2026-08-01 10:00-03');
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('91'), 'P1 t137', 'LIBRO'), (pg_temp.u('92'), 'P2 t137', 'LIBRO'), (pg_temp.u('93'), 'P3 t137', 'LIBRO'),
  (pg_temp.u('94'), 'P4 t137', 'LIBRO'), (pg_temp.u('95'), 'P5 t137', 'LIBRO'), (pg_temp.u('96'), 'P6 t137', 'LIBRO');
insert into public.coleccion (id, nombre) values (pg_temp.u('d0'), 'Pack t137');
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais 137', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad 137', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id)
values (pg_temp.u('f1'), 'CASA', 'Calle 137', '1', -34.915, -56.18, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('f2'), pg_temp.u('f1'));
insert into public.espacio_persona (id, espacio_id, persona_id) values (pg_temp.u('f3'), pg_temp.u('f2'), pg_temp.u('f4'));

-- Ventas de b1: v1 9000 con 4500 cobrados (la mitad); v2 9000 con 6000 (queda un tercio); v3 9000 sin cobros;
-- v4 9000 paga justo; v5 9000 cobrada de más (12000); v7 de 3 con 2 cobrados (queda 1/3); v8 fuera de la campaña.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  (pg_temp.u('b1'), pg_temp.u('f3'), 'T-1371', 9000, '2026-09-01 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b2'), pg_temp.u('f3'), 'T-1372', 9000, '2026-09-02 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b3'), pg_temp.u('f3'), 'T-1373', 9000, '2026-09-03 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b4'), pg_temp.u('f3'), 'T-1374', 9000, '2026-09-04 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b5'), pg_temp.u('f3'), 'T-1375', 9000, '2026-09-05 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b7'), pg_temp.u('f3'), 'T-1377', 3,    '2026-09-07 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b8'), pg_temp.u('f3'), 'T-1378', 9000, '2026-10-05 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('b9'), pg_temp.u('f3'), 'T-1379', 6000, '2026-09-09 12:00+00', pg_temp.u('b1'));
insert into public.cobranza (venta_id, monto, medio, fecha) values
  (pg_temp.u('b1'), 4500,  'EFECTIVO', '2026-09-01 13:00+00'),
  (pg_temp.u('b2'), 6000,  'EFECTIVO', '2026-09-02 13:00+00'),
  (pg_temp.u('b4'), 9000,  'EFECTIVO', '2026-09-04 13:00+00'),
  (pg_temp.u('b5'), 12000, 'EFECTIVO', '2026-09-05 13:00+00'),
  (pg_temp.u('b7'), 2,     'EFECTIVO', '2026-09-07 13:00+00');
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('c1'), pg_temp.u('b1'), pg_temp.u('91'), 3, 1000, 3000),
  (pg_temp.u('c2'), pg_temp.u('b2'), pg_temp.u('91'), 3, 1000, 3000),
  (pg_temp.u('c8'), pg_temp.u('b8'), pg_temp.u('91'), 9, 1000, 9000),
  (pg_temp.u('c4'), pg_temp.u('b1'), pg_temp.u('94'), 2, 1000, 2000),
  (pg_temp.u('c3'), pg_temp.u('b3'), pg_temp.u('92'), 3, 3000, 9000);
insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes) values
  (pg_temp.u('c9'), pg_temp.u('b9'), pg_temp.u('d0'), 1, 6000, 6000,
   jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('96'), 'cantidad', 2)));
-- Entregas (sin los triggers de stock: acá el stock no se mira).
alter table public.entrega disable trigger entrega_descuenta_stock;
alter table public.entrega disable trigger entrega_stock_inconsistente;
insert into public.entrega (venta_id, producto_id, cantidad, pendiente) values
  (pg_temp.u('b1'), pg_temp.u('91'), 3, false),
  (pg_temp.u('b2'), pg_temp.u('91'), 3, false),
  (pg_temp.u('b3'), pg_temp.u('92'), 3, false),
  (pg_temp.u('b3'), pg_temp.u('92'), 2, true),
  (pg_temp.u('b4'), pg_temp.u('92'), 4, false),
  (pg_temp.u('b5'), pg_temp.u('93'), 1, false),
  (pg_temp.u('b7'), pg_temp.u('95'), 1, false),
  (pg_temp.u('b9'), pg_temp.u('96'), 2, false);
alter table public.entrega enable trigger entrega_descuenta_stock;
alter table public.entrega enable trigger entrega_stock_inconsistente;
-- Devoluciones: dos vivas de P1 (2 y 1), una anulada de P1 (5), una de P4 (2, un libro sin entregas) y otra de una
-- venta fuera de la campaña (7).
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id, deleted_at) values
  (pg_temp.u('d1'), pg_temp.u('b1'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('91'), 'cantidad', 2, 'venta_item_id', pg_temp.u('c1'))),
   '2026-09-10 12:00+00', pg_temp.u('b1'), null),
  (pg_temp.u('d2'), pg_temp.u('b2'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('91'), 'cantidad', 1, 'venta_item_id', pg_temp.u('c2'))),
   '2026-09-11 12:00+00', pg_temp.u('b1'), null),
  (pg_temp.u('d3'), pg_temp.u('b1'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('91'), 'cantidad', 5, 'venta_item_id', pg_temp.u('c1'))),
   '2026-09-12 12:00+00', pg_temp.u('b1'), now()),
  (pg_temp.u('d4'), pg_temp.u('b1'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('94'), 'cantidad', 2, 'venta_item_id', pg_temp.u('c4'))),
   '2026-09-13 12:00+00', pg_temp.u('b1'), null),
  (pg_temp.u('d5'), pg_temp.u('b8'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('91'), 'cantidad', 7, 'venta_item_id', pg_temp.u('c8'))),
   '2026-10-06 12:00+00', pg_temp.u('b1'), null);
-- Devoluciones que bajan lo que falta cobrar (ADR-002 efecto 3): los 3 libros de una venta sin cobros (d6) y 1 de las
-- 2 unidades de un combo de 6000 (d7: vale 3000).
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id) values
  (pg_temp.u('d6'), pg_temp.u('b3'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('92'), 'cantidad', 3, 'venta_item_id', pg_temp.u('c3'))),
   '2026-09-14 12:00+00', pg_temp.u('b1')),
  (pg_temp.u('d7'), pg_temp.u('b9'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('96'), 'cantidad', 1, 'venta_item_id', pg_temp.u('c9'))),
   '2026-09-15 12:00+00', pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select array(select k from jsonb_object_keys(
                  (select to_jsonb(r) from public.stock_por_ciudad(pg_temp.u('e1')) r limit 1)) k
                 order by k collate "C")),
          array['apellido','ciudad_id','ciudad_nombre','colportor_id','de_baja','departamento','devueltos','entregados',
                'nombre','por_cobrar','por_entregar','producto_id','producto_nombre','producto_tipo','tiene',
                'ultimo_dato_at'],
          'stock_por_ciudad trae la columna nueva «devueltos» y nada de plata');
select is((select data_type from information_schema.columns where table_name = 'devolucion' and column_name = 'motivo'), 'text',
          'devolucion.motivo existe (lo lee el coordinador por otro camino)');
select is((select has_function_privilege('authenticated', 'public.stock_por_ciudad(uuid)', 'execute')), true, 'authenticated la ejecuta');
select is((select has_function_privilege('anon', 'public.stock_por_ciudad(uuid)', 'execute')), false, 'anon no');

-- ---------------------------------------------------------------------------
-- 2. Por cobrar, en proporción y redondeado hacia arriba
-- ---------------------------------------------------------------------------
-- P1: v1 (3 libros, la mitad por cobrar: ceil(1,5) = 2) + v2 (3 libros, un tercio por cobrar: 1) = 3
-- Con lo devuelto restado del saldo (ADR-002): v1 queda en 4500 - 2000 = 2500 (ceil(3 × 2500 ÷ 9000) = 1) y v2 en
-- 3000 - 1000 = 2000 (1).
select is(pg_temp.fila('91'), '0|6|3|2',
          'P1: lo devuelto baja lo que falta cobrar: 1 + 1; entregados 6; devueltos 2 + 1');
-- P2: v3 sin cobros (3 por cobrar), v4 paga justo (0); 2 pendientes de entrega no cuentan
select is(pg_temp.fila('92'), '2|7|3|0',
          'P2: la venta sin cobros con los 3 libros devueltos no deja nada por cobrar; la paga justo, ninguna; los pendientes no cuentan');
select is(pg_temp.fila('96'), '0|2|1|1', 'combo: 1 de sus 2 unidades devuelta vale 3000 y quedan 3000 por cobrar: 1');
select is(pg_temp.fila('93'), '0|1|0|0', 'P3: cobrada de más: 0 por cobrar');
select is(pg_temp.fila('95'), '0|1|0|1', 'P5: 1 libro de una venta de 3 con 2 cobrados: 1/3 hacia arriba = 1 (nunca subestima)');

-- ---------------------------------------------------------------------------
-- 3. Devueltos
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('94'), '0|0|2|0', 'P4: solo con una devolución, sale igual, con 2 devueltos');
select is((select r.devueltos from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1') and r.producto_id = pg_temp.u('91')), 3,
          'la devolución anulada (5) y la de una venta fuera de la campaña (7) no cuentan');
select is((select r.entregados from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1') and r.producto_id = pg_temp.u('91')), 6,
          'y «entregados» no se descuenta por lo devuelto');

-- Anular una devolución viva la saca de la cuenta.
select pg_temp.actuar_como_servidor();
update public.devolucion set deleted_at = now() where id = pg_temp.u('d2');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select r.devueltos from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1') and r.producto_id = pg_temp.u('91')), 2, 'anular una viva baja lo devuelto (3 a 2)');

select * from finish();
rollback;
