-- pgTAP · 0166 (backend-supabase#243, casilla «Devol. $ 0»; decisión de Cristian del 04/11, «Sí, solo vuelve el libro»):
--   1. Una venta de total $ 0 acepta devoluciones (por el push y por la API): anota los libros que vuelven y los repone en
--      el stock, sin mover plata (el saldo sigue en 0, nunca negativo; no se crea ningún cobro).
--   2. Una venta con total mayor que 0 sigue rechazando la devolución cuando ya está saldada (23514), y con saldo la acepta.
--   3. El reintento de la que entró sigue siendo duplicate, y la devolución de una venta ajena no se juzga distinto.
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
  select ('01920000-0000-7000-8000-0000000166' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-9000-0000000166' || p)::uuid;
$$;
-- «sqlstate restricción» o «ok» de lo que hace una sentencia.
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
declare
  v_restriccion text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_restriccion = constraint_name;
  return sqlstate || ' ' || coalesce(v_restriccion, '');
end $$;
-- Un elemento de productos_devueltos: libro, cantidad y renglón (sufijos de pg_temp.u).
create or replace function pg_temp.el(p_prod text, p_cant int, p_renglon text) returns jsonb language sql as $$
  select jsonb_build_object('producto_id', pg_temp.u(p_prod), 'cantidad', p_cant, 'venta_item_id', pg_temp.u(p_renglon));
$$;
create or replace function pg_temp.push1(p_op uuid, p_payload jsonb) returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'devolucion', 'op', 'insert', 'payload', p_payload))) -> 'results' -> 0;
$$;
create or replace function pg_temp.dev(p_id uuid, p_venta uuid, p_items jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'venta_id', p_venta, 'productos_devueltos', p_items,
                            'fecha_devolucion', '2026-10-05T12:00:00Z');
$$;
create or replace function pg_temp.stock() returns text language sql as $$
  select coalesce((select s.cantidad_disponible::text from public.stock s
                    where s.usuario_id = pg_temp.u('b1') and s.producto_id = pg_temp.u('11')), 'sin fila');
$$;
create or replace function pg_temp.entradas(p_dev text) returns integer language sql as $$
  select coalesce(sum(m.cantidad), 0)::int from public.movimiento_stock m
   where m.devolucion_id = pg_temp.u(p_dev) and m.tipo = 'ENTRADA_DEVOLUCION' and m.deleted_at is null;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 colportora. Libro 11. Tres ventas de b1 con un renglón del libro 11 a $ 1.000 la unidad:
--   z1 de $ 0 (un regalo: el total se bajó a 0 con motivo) × 3 · z2 de $ 1.000 ya cobrada entera × 1 · z3 de $ 1.000 sin cobrar × 1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev166-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t166', 'LIBRO');
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev166', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev166', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e1'), pg_temp.u('c2'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, motivo_monto_manual) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-16671', 0,      '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1'), 'regalo: descuento total'),
  (pg_temp.u('72'), pg_temp.u('51'), 'T-16672', 100000, '2026-10-01 16:00:00+00', pg_temp.u('b1'), pg_temp.u('b1'), null),
  (pg_temp.u('73'), pg_temp.u('51'), 'T-16673', 100000, '2026-10-01 17:00:00+00', pg_temp.u('b1'), pg_temp.u('b1'), null);
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('82'), pg_temp.u('72'), pg_temp.u('11'), 1, 100000, 100000),
  (pg_temp.u('83'), pg_temp.u('73'), pg_temp.u('11'), 1, 100000, 100000);
insert into public.cobranza (id, venta_id, monto, medio, fecha) values
  (pg_temp.u('c2'), pg_temp.u('72'), 100000, 'EFECTIVO', '2026-10-01 16:10:00+00');
-- Todo lo vendido ya está entregado (la devolución suma al stock solo lo entregado, 0148). Las entregas se cargan sin los
-- triggers del stock: el stock del test se fija a mano.
alter table public.entrega disable trigger entrega_stock_inconsistente;
alter table public.entrega disable trigger entrega_descuenta_stock;
insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente) values
  (pg_temp.u('e1'), pg_temp.u('71'), pg_temp.u('11'), 3, '2026-10-01 15:30:00+00', false),
  (pg_temp.u('e2'), pg_temp.u('72'), pg_temp.u('11'), 1, '2026-10-01 16:30:00+00', false),
  (pg_temp.u('e3'), pg_temp.u('73'), pg_temp.u('11'), 1, '2026-10-01 17:30:00+00', false);
alter table public.entrega enable trigger entrega_stock_inconsistente;
alter table public.entrega enable trigger entrega_descuenta_stock;
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values (pg_temp.u('b1'), pg_temp.u('11'), 10);

-- --- 0. el punto de partida ---------------------------------------------------------
select is(public.saldo_de_la_venta(pg_temp.u('71')), 0::bigint, 'la venta de $ 0 nace con saldo 0');
select is(public.saldo_de_la_venta(pg_temp.u('72')), 0::bigint, 'la cobrada entera, también');
select is(public.saldo_de_la_venta(pg_temp.u('73')), 100000::bigint, 'la sin cobrar debe $ 1.000');

-- --- 1. la venta de $ 0 acepta devoluciones ----------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r1 on commit drop as
  select pg_temp.push1(pg_temp.op('01'), pg_temp.dev(pg_temp.u('d1'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81')))) as r;
grant select on r1 to authenticated;
select is((select r ->> 'outcome' from r1), 'accepted', 'por el teléfono: la devolución de un libro de una venta de $ 0 entra');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.devolucion where id = pg_temp.u('d1') and deleted_at is null), 1,
          'y queda anotada con su libro');
select is(pg_temp.entradas('d1'), 1, 'el libro vuelve al stock: una entrada de devolución');
select is(pg_temp.stock(), '11', 'el stock sube de 10 a 11');
select is(public.saldo_de_la_venta(pg_temp.u('71')), 0::bigint, 'sin plata: el saldo sigue en 0, nunca negativo');
select is((select count(*)::int from public.cobranza where venta_id = pg_temp.u('71')), 0, 'y no se creó ningún cobro');

-- Otra más, con la venta ya en 0 (la primera no la dejó «saldada» de golpe: nunca tuvo saldo).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('02'), pg_temp.dev(pg_temp.u('d2'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81')))) ->> 'outcome'),
          'accepted', 'el segundo libro también vuelve');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock(), '12', 'y el stock sube a 12');
-- El reintento del mismo job y del mismo id: duplicate.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('01'), pg_temp.dev(pg_temp.u('d1'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81')))) ->> 'outcome'),
          'duplicate', 'el mismo job otra vez: duplicate');
select is((select pg_temp.push1(pg_temp.op('03'), pg_temp.dev(pg_temp.u('d1'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81')))) ->> 'outcome'),
          'duplicate', 'y el mismo id con otro client_op_id: duplicate');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock(), '12', 'sin reponer dos veces');
-- Por la API directa: lo mismo.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d3'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81')), now(), pg_temp.u('b1')) $$),
          'ok', 'por la API directa también se acepta sobre la venta de $ 0');
select pg_temp.actuar_como_servidor();

-- --- 2. con total mayor que 0 sigue la regla de la 0157 ----------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r2 on commit drop as
  select pg_temp.push1(pg_temp.op('04'), pg_temp.dev(pg_temp.u('d4'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '82')))) as r;
grant select on r2 to authenticated;
select is((select r ->> 'outcome' from r2), 'invalid', 'la venta de $ 1.000 ya cobrada entera: la devolución es invalid');
select is((select r ->> 'code' from r2), '23514', 'con 23514');
select ok((select r ->> 'message' from r2) like 'Esta venta ya está saldada%', 'y un aviso que dice qué pasó y qué hacer');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d5'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '82')), now(), pg_temp.u('b1')) $$),
          '23514 devolucion_venta_con_saldo', 'por la API directa, 23514 devolucion_venta_con_saldo');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.devolucion where venta_id = pg_temp.u('72')), 0, 'no dejó nada');
select is(pg_temp.stock(), '13', 'ni tocó el stock');

-- Con saldo, se acepta (la regla de siempre).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('05'), pg_temp.dev(pg_temp.u('d6'), pg_temp.u('73'), jsonb_build_array(pg_temp.el('11', 1, '83')))) ->> 'outcome'),
          'accepted', 'la venta de $ 1.000 sin cobrar acepta la devolución');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock(), '14', 'y su libro vuelve al stock');
select is(public.saldo_de_la_venta(pg_temp.u('73')), 0::bigint, 'el saldo llega a 0 y no baja de ahí');

-- Una venta que se reabre: anular el cobro de la entera de $ 1.000 vuelve a aceptar devoluciones.
update public.cobranza set anulado_at = now(), motivo_anulacion = 'Monto equivocado' where id = pg_temp.u('c2');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('06'), pg_temp.dev(pg_temp.u('d7'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '82')))) ->> 'outcome'),
          'accepted', 'si se anula el cobro, la venta vuelve a tener saldo y acepta la devolución');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
