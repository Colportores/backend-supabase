-- pgTAP · 0157 (backend-supabase#234, decisiones del 03/11 «Devoluciones: nunca queda plata a favor del cliente»):
--   1. devolucion ya no tiene dinero_retenido ni monto_reembolsado (columnas, CHECK, push, detalle de la auditoría).
--   2. valor_devuelto_de_la_venta() y saldo_de_la_venta(): monto - cobros vivos no anulados - lo devuelto, sin bajar de 0.
--   3. El trigger devolucion_venta_con_saldo: una venta saldada no acepta devoluciones del teléfono (23514), y el
--      reintento de la que ya entró sigue siendo duplicate.
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
  select ('01920000-0000-7000-8000-0000000157' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-9000-0000000157' || p)::uuid;
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
create or replace function pg_temp.ins(p_id text, p_venta text, p_prod jsonb, p_extra text default '') returns text language plpgsql as $$
begin
  return pg_temp.error_de(format($q$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id %s)
                                  values (%L, %L, %L::jsonb, '2026-10-05 12:00+00', %L %s) $q$,
                                  case when p_extra = '' then '' else ', motivo' end,
                                  pg_temp.u(p_id), pg_temp.u(p_venta), p_prod::text, pg_temp.u('b1'),
                                  case when p_extra = '' then '' else ', ' || quote_literal(p_extra) end));
end $$;
create or replace function pg_temp.stock(p_producto text) returns text language sql as $$
  select coalesce((select s.cantidad_disponible::text from public.stock s
                    where s.usuario_id = pg_temp.u('b1') and s.producto_id = pg_temp.u(p_producto)), 'sin fila');
$$;
create or replace function pg_temp.entradas(p_dev text) returns integer language sql as $$
  select coalesce(sum(m.cantidad), 0)::int from public.movimiento_stock m
   where m.devolucion_id = pg_temp.u(p_dev) and m.tipo = 'ENTRADA_DEVOLUCION' and m.deleted_at is null;
$$;
create or replace function pg_temp.movs(p_dev text) returns integer language sql as $$
  select count(*)::int from public.movimiento_stock m where m.devolucion_id = pg_temp.u(p_dev);
$$;
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'devolucion', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;
create or replace function pg_temp.dev(p_id uuid, p_venta uuid, p_items jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'venta_id', p_venta, 'productos_devueltos', p_items,
                            'fecha_devolucion', '2026-10-05T12:00:00Z');
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Colportores b1 y b2. Libros 11, 12, 13 y 14. Un combo (colección d0: 11 × 1 y 13 × 2).
-- Venta 71 de b1 con los renglones: 81 (11 × 3), 82 (12 × 3), 83 (combo × 2), 85 (11 × 2, el mismo libro aparte).
-- Venta 72 de b2 con el renglón 84 (11 × 3).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev157-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 t157', 'LIBRO'), (pg_temp.u('12'), 'Libro 2 t157', 'LIBRO'),
  (pg_temp.u('13'), 'Revista 3 t157', 'REVISTA'), (pg_temp.u('14'), 'Libro 4 t157', 'LIBRO');
insert into public.coleccion (id, nombre) values (pg_temp.u('d0'), 'Pack t157');
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  (pg_temp.u('a1'), pg_temp.u('11'), pg_temp.u('d0'), 1), (pg_temp.u('a2'), pg_temp.u('13'), pg_temp.u('d0'), 2);
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev157', 'ZT');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev157', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('b1')), (pg_temp.u('e2'), pg_temp.u('02'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e1'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e2'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, motivo_monto_manual) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-15771', 450000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1'), 'fixture: ítems que no cuadran con el total (0150)'),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-15772', 260000, '2026-10-01 16:00:00+00', pg_temp.u('b2'), pg_temp.u('b2'), 'fixture: ítems que no cuadran con el total (0150)');
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('82'), pg_temp.u('71'), pg_temp.u('12'), 3, 50000, 150000),
  (pg_temp.u('85'), pg_temp.u('71'), pg_temp.u('11'), 2, 100000, 200000),
  (pg_temp.u('84'), pg_temp.u('72'), pg_temp.u('11'), 3, 100000, 300000);
insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes) values
  (pg_temp.u('83'), pg_temp.u('71'), pg_temp.u('d0'), 2, 110000, 220000,
   jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1),
                     jsonb_build_object('producto_id', pg_temp.u('13'), 'cantidad', 2)));
-- Todo lo vendido ya está entregado (desde 0148 la devolución suma al stock solo lo entregado). Las entregas se
-- cargan sin los triggers del stock (0118, 0135): el stock del test se fija a mano abajo.
alter table public.entrega disable trigger entrega_stock_inconsistente;
alter table public.entrega disable trigger entrega_descuenta_stock;
insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente) values
  (pg_temp.u('e1'), pg_temp.u('71'), pg_temp.u('11'), 7, '2026-10-01 15:30:00+00', false),
  (pg_temp.u('e2'), pg_temp.u('71'), pg_temp.u('12'), 3, '2026-10-01 15:30:00+00', false),
  (pg_temp.u('e3'), pg_temp.u('71'), pg_temp.u('13'), 4, '2026-10-01 15:30:00+00', false),
  (pg_temp.u('e4'), pg_temp.u('72'), pg_temp.u('11'), 3, '2026-10-01 16:30:00+00', false);
alter table public.entrega enable trigger entrega_stock_inconsistente;
alter table public.entrega enable trigger entrega_descuenta_stock;
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('11'), 10), (pg_temp.u('b1'), pg_temp.u('12'), 0);


-- La venta 71 de b1 pasa a $ 8.700 (la suma de sus renglones); la 72 de b2 queda en $ 2.600 con renglón de $ 3.000.
update public.venta set monto_total = 870000 where id = pg_temp.u('71');

create or replace function pg_temp.saldo(p_venta text, p_excepto text default null) returns bigint language sql as $$
  select public.saldo_de_la_venta(pg_temp.u(p_venta), case when p_excepto is null then null else pg_temp.u(p_excepto) end);
$$;
create or replace function pg_temp.valor(p_venta text, p_excepto text default null) returns bigint language sql as $$
  select public.valor_devuelto_de_la_venta(pg_temp.u(p_venta), case when p_excepto is null then null else pg_temp.u(p_excepto) end);
$$;
create or replace function pg_temp.cobro(p_id text, p_venta text, p_monto int) returns void language sql as $$
  insert into public.cobranza (id, venta_id, monto, medio, fecha) values (pg_temp.u(p_id), pg_temp.u(p_venta), p_monto, 'EFECTIVO', now());
$$;

-- ---------------------------------------------------------------------------
-- 1. Las columnas de la plata se fueron
-- ---------------------------------------------------------------------------
select hasnt_column('public', 'devolucion', 'dinero_retenido', 'sin dinero_retenido');
select hasnt_column('public', 'devolucion', 'monto_reembolsado', 'sin monto_reembolsado');
select is((select count(*)::int from pg_constraint where conrelid = 'public.devolucion'::regclass
            and conname in ('devolucion_dinero_retenido_no_negativo', 'devolucion_monto_reembolsado_no_negativo')), 0,
          'ni sus CHECK');
select is((select count(*)::int from unnest(sync.columnas_escribibles('devolucion')) c
            where c in ('dinero_retenido', 'monto_reembolsado')), 0, 'el push ya no las escribe');
select ok(pg_get_functiondef('public.devolucion_detalle_de_auditoria(public.devolucion)'::regprocedure) not like '%dinero_retenido%'
          and pg_get_functiondef('public.devolucion_detalle_de_auditoria(public.devolucion)'::regprocedure) not like '%monto_reembolsado%',
          'el detalle de la auditoría no lleva montos');

-- ---------------------------------------------------------------------------
-- 2. El saldo de la venta: monto − cobros − lo devuelto, sin bajar de 0
-- ---------------------------------------------------------------------------
select is(pg_temp.saldo('71'), 870000::bigint, 'sin cobros ni devoluciones, el saldo es el monto');
select is(pg_temp.saldo('72'), 260000::bigint, 'la venta de b2, igual');
select is(public.saldo_de_la_venta(pg_temp.u('99')), 0::bigint, 'una venta que no existe no tiene saldo');
select is(pg_temp.valor('71'), 0::bigint, 'y nada devuelto');

select pg_temp.cobro('c1', '71', 100000);
select is(pg_temp.saldo('71'), 770000::bigint, 'un cobro de $ 1.000 baja el saldo');
select pg_temp.cobro('c2', '71', 50000);
update public.cobranza set anulado_at = now(), motivo_anulacion = 'Monto equivocado' where id = pg_temp.u('c2');
select is(pg_temp.saldo('71'), 770000::bigint, 'un cobro anulado no cuenta');
select pg_temp.cobro('c3', '71', 40000);
update public.cobranza set deleted_at = now() where id = pg_temp.u('c3');
select is(pg_temp.saldo('71'), 770000::bigint, 'ni uno dado de baja');

-- Un renglón suelto: las unidades por el precio del renglón (81: libro 11, $ 1.000 c/u).
select is(pg_temp.ins('d1', '71', jsonb_build_array(pg_temp.el('11', 1, '81'))), 'ok', 'devuelve 1 del renglón 81');
select is(pg_temp.valor('71'), 100000::bigint, 'vale $ 1.000');
select is(pg_temp.saldo('71'), 670000::bigint, 'y el saldo baja a $ 6.700');
select is(pg_temp.valor('71', 'd1'), 0::bigint, 'dejando afuera esa devolución, vale 0');
select is(pg_temp.saldo('71', 'd1'), 770000::bigint, 'y el saldo es el de antes de ella');

-- El mismo libro en otro renglón (85: $ 1.000 c/u) no se mezcla con el 81.
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('11', 2, '85'))), 'ok', 'devuelve 2 del renglón 85');
select is(pg_temp.valor('71'), 300000::bigint, 'se suman: 1 + 2 unidades de $ 1.000');

-- Un combo (renglón 83: 2 combos de $ 1.100; cada uno lleva 11 × 1 y 13 × 2). Medio combo no vale.
select is(pg_temp.ins('d3', '71', jsonb_build_array(pg_temp.el('11', 1, '83'))), 'ok', 'devuelve solo el libro 11 de un combo');
select is(pg_temp.valor('71'), 300000::bigint, 'medio combo no suma');
select is(pg_temp.ins('d4', '71', jsonb_build_array(pg_temp.el('13', 2, '83'))), 'ok', 'devuelve después las dos revistas del mismo combo');
select is(pg_temp.valor('71'), 410000::bigint, 'las dos devoluciones juntas son un combo entero: + $ 1.100');
select is(pg_temp.ins('d5', '71', jsonb_build_array(pg_temp.el('11', 1, '83'), pg_temp.el('13', 2, '83'))), 'ok', 'y otro combo entero de una vez');
select is(pg_temp.valor('71'), 520000::bigint, 'son dos combos: $ 2.200 en total');
select is(pg_temp.saldo('71'), 870000::bigint - 100000 - 520000, 'saldo = monto − cobro − devuelto');

-- Una devolución anulada no cuenta.
update public.devolucion set deleted_at = now() where id = pg_temp.u('d5');
select is(pg_temp.valor('71'), 410000::bigint, 'la anulada no vale');
select is(pg_temp.saldo('71'), 870000::bigint - 100000 - 410000, 'y el saldo la devuelve');

-- Una fila vieja de dos claves (sin renglón) no se puede valuar y no suma.
alter table public.devolucion disable trigger devolucion_venta_con_saldo;
alter table public.devolucion drop constraint devolucion_productos_validos;
alter table public.devolucion disable trigger devolucion_productos;
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
values (pg_temp.u('d6'), pg_temp.u('71'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('12'), 'cantidad', 1)),
        '2026-10-05 12:00+00', pg_temp.u('b1'));
select is(pg_temp.valor('71'), 410000::bigint, 'la de forma vieja no suma');
delete from public.movimiento_stock where devolucion_id = pg_temp.u('d6');
delete from public.devolucion where id = pg_temp.u('d6');
alter table public.devolucion enable trigger devolucion_productos;
alter table public.devolucion enable trigger devolucion_venta_con_saldo;

-- ---------------------------------------------------------------------------
-- 3. Una venta saldada no acepta devoluciones (por el teléfono)
-- ---------------------------------------------------------------------------
-- La venta 72 de b2: $ 2.600, un renglón de $ 3.000 por unidad... (3 × $ 1.000 en el renglón 84).
select pg_temp.cobro('c4', '72', 100000);
select is(pg_temp.saldo('72'), 160000::bigint, 'b2 pagó $ 1.000 de $ 2.600: le quedan $ 1.600');

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table r1 on commit drop as
  select pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.dev(pg_temp.u('e1'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 2, '84')))) as r;
grant select on r1 to authenticated;
select is((select r ->> 'outcome' from r1), 'accepted', 'con saldo, la devolución entra (aunque valga más que el saldo)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.valor('72'), 200000::bigint, 'vale $ 2.000...');
select is(pg_temp.saldo('72'), 0::bigint, '...pero el saldo era $ 1.600: queda en 0 y no a favor del cliente');
select is(public.saldo_de_la_venta(pg_temp.u('72')) >= 0, true, 'nunca negativo');

-- Ahora está saldada: otra devolución se rechaza.
select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table r2 on commit drop as
  select pg_temp.push1(pg_temp.op('02'), 'insert', pg_temp.dev(pg_temp.u('e2'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')))) as r;
grant select on r2 to authenticated;
select is((select r ->> 'outcome' from r2), 'invalid', 'sobre la venta saldada, la devolución es invalid');
select is((select r ->> 'code' from r2), '23514', 'con 23514');
select ok((select r ->> 'message' from r2) like 'Esta venta ya está saldada%', 'y un aviso que dice qué pasó y qué hacer');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.devolucion where id = pg_temp.u('e2')), 0, 'no dejó nada');

-- El reintento de la que entró: duplicate, aunque la venta ya esté saldada por ella misma.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.dev(pg_temp.u('e1'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 2, '84')))) ->> 'outcome'),
          'duplicate', 'el mismo job otra vez: duplicate');
select is((select pg_temp.push1(pg_temp.op('03'), 'insert', pg_temp.dev(pg_temp.u('e1'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 2, '84')))) ->> 'outcome'),
          'duplicate', 'y el mismo id con otro client_op_id (un reintento tras reinstalar): duplicate, no invalid');

-- La que entra ya anulada (registrada y anulada sin conexión) pasa sin juicio de la venta saldada. (Desde 0172 la
-- anulación sí se juzga con la hora del teléfono, por eso la fecha y la baja son de hace unas horas.)
select is((select pg_temp.push1(pg_temp.op('04'), 'insert',
                                pg_temp.dev(pg_temp.u('e3'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')))
                                  || jsonb_build_object('fecha_devolucion', now() - interval '2 hours',
                                                        'deleted_at', now() - interval '1 hour')) ->> 'outcome'),
          'accepted', 'una devolución que ya llega anulada se acepta aunque la venta esté saldada');

-- Directo por la API: lo mismo.
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                              values (pg_temp.u('e4'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')), now()) $$),
          '23514 devolucion_venta_con_saldo', 'por la API directa, 23514 devolucion_venta_con_saldo');

-- Anular un cobro vuelve a abrir la venta.
select pg_temp.actuar_como_servidor();
update public.cobranza set anulado_at = now(), motivo_anulacion = 'Monto equivocado' where id = pg_temp.u('c4');
select is(pg_temp.saldo('72'), 60000::bigint, 'anular el cobro de $ 1.000: el saldo es $ 600 (2.600 − 2.000 devueltos)');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.push1(pg_temp.op('05'), 'insert', pg_temp.dev(pg_temp.u('e5'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')))) ->> 'outcome'),
          'accepted', 'con la venta otra vez con saldo, la devolución entra');
select pg_temp.actuar_como_servidor();
select is(pg_temp.saldo('72'), 0::bigint, 'y la deja en 0');

-- Anular una devolución también la reabre: sale del valor devuelto.
update public.devolucion set deleted_at = now() where id = pg_temp.u('e5');
select is(pg_temp.saldo('72'), 60000::bigint, 'anulada la e5, el saldo vuelve');

-- Una venta que no es de quien sube: la RLS manda (42501), no el saldo.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                              values (pg_temp.u('e6'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')), now()) $$),
          '42501 ', 'b1 sobre la venta de b2: 42501, sin revelar su saldo');
select pg_temp.actuar_como_servidor();

-- El servidor (sin sesión) no pasa por el control: es la salida para corregir a mano.
update public.cobranza set anulado_at = null, motivo_anulacion = null where id = pg_temp.u('c4');
select is(pg_temp.saldo('72'), 0::bigint, 'la venta 72 vuelve a estar saldada');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('e7'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')), now(), pg_temp.u('b2')) $$),
          'ok', 'sin sesión (migraciones, service_role) la devolución entra');

-- ---------------------------------------------------------------------------
-- 4. Privilegios y forma
-- ---------------------------------------------------------------------------
select is(has_function_privilege('anon', 'public.saldo_de_la_venta(uuid, uuid)', 'execute'), false, 'anon no calcula saldos');
select is(has_function_privilege('authenticated', 'public.saldo_de_la_venta(uuid, uuid)', 'execute'), false, 'authenticated tampoco: sería ver el saldo de una venta ajena');
select is(has_function_privilege('authenticated', 'public.valor_devuelto_de_la_venta(uuid, uuid)', 'execute'), false, 'ni lo devuelto');
select is(has_function_privilege('service_role', 'public.saldo_de_la_venta(uuid, uuid)', 'execute'), false, 'ni service_role');
select is(has_function_privilege('authenticated', 'public.tg_devolucion_venta_con_saldo()', 'execute'), false, 'ni el trigger');
select is((select prosecdef from pg_proc where oid = 'public.tg_devolucion_venta_con_saldo()'::regprocedure), true,
          'el trigger es DEFINER: mide con todos los cobros');
select is((select proconfig from pg_proc where oid = 'public.tg_devolucion_venta_con_saldo()'::regprocedure),
          array['search_path=""'], 'con el search_path vacío');

select * from finish();
rollback;
