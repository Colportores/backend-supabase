-- pgTAP · 0148 (backend-supabase#221, respuestas de Cristian del 28/10): cuatro casas de stock y transferencias.
--   1. Ajuste de stock desde el teléfono («Ajuste stock»): la colportora sube un movimiento AJUSTE de su propio stock
--      (cantidad con signo, motivo de una lista); el stock se recalcula; la coordinadora lo ve; el replay no suma
--      dos veces; el stock puede quedar en negativo (S46).
--   2. La devolución suma al stock solo lo entregado («Devol. s/ent»): vendió 3, entregó 1, devuelve 3 → suma 1 y los
--      2 no entregados salen de la entrega pendiente sin tocar el stock. Acumulado, anulación y venta sin entregas.
--   3. La transferencia baja a las dos puntas («Ver transf.»): quien da y quien recibe, la arme quien la arme; nadie
--      más (tampoco la coordinadora si no es una punta); los cambios de estado llegan a las dos.
--   4. Quien pidió la transferencia la puede cancelar («Cancelar tr.»): solo mientras está por autorizar, sin
--      conflicto de versión; el alta que nace cancelada se acepta.
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
  select ('01920000-0000-7000-8000-0000000148' || p)::uuid;
$$;
-- «sqlstate restricción» o «ok» de lo que hace una sentencia (como el rol de ahora).
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
-- Cuántas filas toca una sentencia como ese usuario (o el sqlstate si falla). Vuelve a ser el servidor.
create or replace function pg_temp.filas_de(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare
  v_n integer;
  v_r text;
begin
  perform pg_temp.actuar_como(p_uid);
  begin
    execute p_sql;
    get diagnostics v_n = row_count;
    v_r := v_n::text;
  exception when others then
    v_r := sqlstate;
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.push(p_uid uuid, p_op text, p_entidad text, p_tipo text, p_payload jsonb,
                                        p_version bigint default null) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(p_uid);
  v_r := sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.stock(p_col text, p_prod text) returns text language sql as $$
  select coalesce((select s.cantidad_disponible::text from public.stock s
                    where s.usuario_id = pg_temp.u(p_col) and s.producto_id = pg_temp.u(p_prod)), 'sin fila');
$$;
create or replace function pg_temp.evento(p_tipo text, p_fila uuid) returns integer language sql as $$
  select count(*)::int from auditoria.audit_log a where a.event_type = p_tipo and a.fila_id = p_fila;
$$;
create or replace function pg_temp.estado(p_t text) returns text language sql as $$
  select estado from public.transferencia_stock where id = pg_temp.u(p_t);
$$;
create or replace function pg_temp.dev(p_id text, p_venta text, p_prod text, p_cant int, p_renglon text) returns text language plpgsql as $$
begin
  return pg_temp.error_de(format($q$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                                  values (%L, %L, %L::jsonb, '2026-10-05 12:00+00', %L) $q$,
                                  pg_temp.u(p_id), pg_temp.u(p_venta),
                                  jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u(p_prod), 'cantidad', p_cant,
                                                                       'venta_item_id', pg_temp.u(p_renglon)))::text,
                                  pg_temp.u('b1')));
end $$;
-- Un renglón vendido, sus entregas y el stock de partida (se fija a mano después de las entregas, que lo descuentan).
create or replace function pg_temp.ent(p_id text, p_venta text, p_prod text, p_cant int, p_pendiente boolean) returns void language sql as $$
  insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, fecha_entrega)
  values (pg_temp.u(p_id), pg_temp.u(p_venta), pg_temp.u(p_prod), p_cant, p_pendiente,
          case when p_pendiente then null else now() end);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Staff: c1 coordinador de la campaña en curso. Colportores b1, b2 y b3 inscriptos en ella; b4 sin campaña.
-- Libros 11, 12 y 13. Ventas de b1: 71 (11 × 3), 72 (11 × 3), 73 (11 × 4), 74 (11 × 3), 75 (11 × 2, sin entregas).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev148-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','ad','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'),
               ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Actual 148', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '40 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('11'), 'Libro 1 t148', 'LIBRO', 1500), (pg_temp.u('12'), 'Libro 2 t148', 'LIBRO', 2500),
  (pg_temp.u('13'), 'Libro 3 t148', 'LIBRO', 3500);

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev148', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev148', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('e2'), pg_temp.u('01'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e2'), pg_temp.u('c2'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u('51'), 'T-148' || x.v, 300000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1')
  from unnest(array['71','72','73','74','75']) x(v);
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('82'), pg_temp.u('72'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('83'), pg_temp.u('73'), pg_temp.u('11'), 4, 100000, 400000),
  (pg_temp.u('84'), pg_temp.u('74'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('85'), pg_temp.u('75'), pg_temp.u('11'), 2, 100000, 200000);

-- ---------------------------------------------------------------------------
-- 1. Ajuste de stock desde el teléfono
-- ---------------------------------------------------------------------------
select has_column('public', 'movimiento_stock', 'motivo', 'movimiento_stock.motivo');
select results_eq($$ select permite_push, columna_duenio from sync.entidad where nombre = 'movimiento_stock' $$,
                  $$ values (true, 'usuario_id'::text) $$, 'movimiento_stock: push y pull de los propios');
select ok(sync.columnas_escribibles('movimiento_stock') @> array['producto_id','tipo','cantidad','motivo'],
          'el teléfono escribe el libro, el tipo, la cantidad y el motivo');
select ok(not ('usuario_id' = any (sync.columnas_escribibles('movimiento_stock')))
          and not ('fecha' = any (sync.columnas_escribibles('movimiento_stock')))
          and not ('devolucion_id' = any (sync.columnas_escribibles('movimiento_stock'))),
          'pero no la dueña, la fecha ni el origen');
select is((select array_agg(p.policyname::text order by p.policyname) from pg_policies p
            where p.schemaname = 'public' and p.tablename = 'movimiento_stock' and p.cmd <> 'SELECT'),
          array['movimiento_stock_insert_propio'], 'una sola política de escritura: el alta del ajuste propio');
select is((select has_table_privilege('authenticated', 'public.movimiento_stock', 'update')
           or has_table_privilege('authenticated', 'public.movimiento_stock', 'delete')), false,
          'el teléfono ni actualiza ni borra un movimiento');

-- Stock inicial: +5 del libro 11 (b1 no tenía fila de stock).
select is(pg_temp.push(pg_temp.u('b1'), 'a1', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a1'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', 5,
                               'motivo', 'STOCK_INICIAL')) ->> 'outcome',
          'accepted', 'b1 sube un ajuste de +5 con el motivo «Stock inicial»: accepted');
select is(pg_temp.stock('b1', '11'), '5', 'el stock se recalcula: 5 (sin fila antes)');
select is((select usuario_id from public.movimiento_stock where id = pg_temp.u('a1')), pg_temp.u('b1'), 'la dueña sale del JWT');
select ok((select fecha > now() - interval '1 minute' from public.movimiento_stock where id = pg_temp.u('a1')),
          'y la fecha es la de llegada');
select is(pg_temp.evento('stock_ajustado', pg_temp.u('a1')), 1, 'con su evento en audit_log');
select is((select metadata ->> 'stock_antes' || '>' || (metadata ->> 'stock_despues') || ' ' || (metadata ->> 'motivo')
             from auditoria.audit_log where event_type = 'stock_ajustado' and fila_id = pg_temp.u('a1')),
          '0>5 STOCK_INICIAL', 'el evento dice de cuánto a cuánto y por qué (sin texto libre)');

-- Libros dañados: -2.
select is(pg_temp.push(pg_temp.u('b1'), 'a2', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a2'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', -2,
                               'motivo', 'LIBROS_DANIADOS')) ->> 'outcome',
          'accepted', 'un ajuste de -2 por «Libros dañados»: accepted');
select is(pg_temp.stock('b1', '11'), '3', 'el stock baja a 3');

-- El reintento y el replay no suman dos veces.
select is(pg_temp.push(pg_temp.u('b1'), 'a2', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a2'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', -2,
                               'motivo', 'LIBROS_DANIADOS')) ->> 'outcome',
          'duplicate', 'el mismo envío otra vez: duplicate');
select is(pg_temp.push(pg_temp.u('b1'), 'a3', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a2'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', -2,
                               'motivo', 'LIBROS_DANIADOS')) ->> 'outcome',
          'duplicate', 'la misma fila con otro envío (el motor reenvía): duplicate');
select is(pg_temp.stock('b1', '11'), '3', 'pero el stock no se mueve otra vez');
select is((select count(*)::int from public.movimiento_stock where id = pg_temp.u('a2')), 1, 'ni queda duplicado el movimiento');

-- Conteo: baja por debajo de cero (S46: el stock nunca frena nada, solo se corrige).
select is(pg_temp.push(pg_temp.u('b1'), 'a4', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a4'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', -10,
                               'motivo', 'CONTEO')) ->> 'outcome',
          'accepted', 'un conteo de -10 con 3 en el stock: accepted');
select is(pg_temp.stock('b1', '11'), '-7', 'el stock queda en -7 (S46: puede ser negativo)');

-- Lo que el teléfono no puede subir.
select is(pg_temp.push(pg_temp.u('b1'), 'a5', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a5'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', 1,
                               'motivo', 'OTRO')) ->> 'code',
          '23514', 'un motivo que no está en la lista: invalid 23514');
select is(pg_temp.push(pg_temp.u('b1'), 'a6', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a6'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', 1,
                               'motivo', 'se me cayeron al agua')) ->> 'code',
          '23514', 'un texto libre como motivo: invalid 23514 (el motivo es de una lista)');
select is(pg_temp.push(pg_temp.u('b1'), 'a7', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a7'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', 1)) ->> 'code',
          '23514', 'un ajuste sin motivo: invalid 23514');
select is(pg_temp.push(pg_temp.u('b1'), 'a8', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a8'), 'producto_id', pg_temp.u('11'), 'tipo', 'AJUSTE', 'cantidad', 0,
                               'motivo', 'CONTEO')) ->> 'code',
          '23514', 'un ajuste de cero unidades: invalid 23514');
select is(pg_temp.push(pg_temp.u('b1'), 'a9', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('a9'), 'producto_id', pg_temp.u('11'), 'tipo', 'ENTRADA_PEDIDO', 'cantidad', 50)) ->> 'code',
          '42501', 'inventar una entrada de pedido: invalid 42501 (desde el teléfono solo entra un ajuste)');
select is(pg_temp.push(pg_temp.u('b1'), 'aa', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('aa'), 'producto_id', pg_temp.u('11'), 'tipo', 'ENTRADA_DEVOLUCION', 'cantidad', 5,
                               'motivo', 'CONTEO')) ->> 'code',
          '42501', 'ni una devolución inventada: invalid 42501');
select is(pg_temp.stock('b1', '11'), '-7', 'nada de lo rechazado movió el stock');

-- Ajeno: el servidor fija la dueña; el stock del otro no se toca.
select is(pg_temp.push(pg_temp.u('b1'), 'ab', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('ab'), 'usuario_id', pg_temp.u('b2'), 'producto_id', pg_temp.u('12'),
                               'tipo', 'AJUSTE', 'cantidad', 9, 'motivo', 'CONTEO')) ->> 'outcome',
          'accepted', 'un ajuste que dice ser de b2: accepted, pero la dueña es b1');
select is(pg_temp.stock('b2', '12') || '/' || pg_temp.stock('b1', '12'), 'sin fila/9', 'el stock de b2 no se toca; el ajuste fue al de b1');
-- Directo por SQL con el JWT de b1: ni update ni delete, ni insertar a nombre de otro.
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.movimiento_stock set cantidad = 99 where id = %L $$, pg_temp.u('a1'))),
          '42501', 'cambiar un ajuste ya subido: 42501');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ delete from public.movimiento_stock where id = %L $$, pg_temp.u('a1'))),
          '42501', 'borrarlo: 42501');

-- La coordinadora lo ve en el historial (vista 34) y b2 no ve el de b1.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.movimiento_stock where tipo = 'AJUSTE' and usuario_id = pg_temp.u('b1')), 4,
          'la coordinadora de la campaña ve los ajustes de b1 en el historial');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.movimiento_stock where usuario_id = pg_temp.u('b1')), 0, 'b2 no ve los movimientos de b1');
select pg_temp.actuar_como_servidor();

-- Un ajuste que llega dado de baja no mueve el stock.
select is(pg_temp.push(pg_temp.u('b1'), 'ac', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('ac'), 'producto_id', pg_temp.u('13'), 'tipo', 'AJUSTE', 'cantidad', 4,
                               'motivo', 'CONTEO', 'deleted_at', now())) ->> 'outcome',
          'accepted', 'un ajuste armado y dado de baja sin conexión: accepted');
select is(pg_temp.stock('b1', '13'), 'sin fila', 'y no mueve el stock');

-- Una fila de stock dada de baja cuenta como cero.
select pg_temp.actuar_como_servidor();
insert into public.stock (usuario_id, producto_id, cantidad_disponible, deleted_at) values (pg_temp.u('b3'), pg_temp.u('12'), 40, now());
select is(pg_temp.push(pg_temp.u('b3'), 'ad', 'movimiento_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('ad'), 'producto_id', pg_temp.u('12'), 'tipo', 'AJUSTE', 'cantidad', 3,
                               'motivo', 'CONTEO')) ->> 'outcome', 'accepted', 'ajuste sobre una fila de stock dada de baja');
select is(pg_temp.stock('b3', '12') || '/' || (select (deleted_at is null)::text from public.stock
                                                where usuario_id = pg_temp.u('b3') and producto_id = pg_temp.u('12')),
          '3/true', 'la fila vuelve a vivir con lo ajustado (la baja cuenta como cero)');

-- ---------------------------------------------------------------------------
-- 2. La devolución suma al stock solo lo entregado
-- ---------------------------------------------------------------------------
-- Venta 71: vendió 3, entregó 1 (y quedan 2 por entregar). Stock de partida 10.
select pg_temp.ent('e1', '71', '11', 1, false);
select pg_temp.ent('e2', '71', '11', 2, true);
-- Venta 72: vendió 3, entregó los 3.
select pg_temp.ent('e3', '72', '11', 3, false);
-- Venta 73: vendió 4, entregó 2 y hay una pendiente de 2.
select pg_temp.ent('e4', '73', '11', 2, false);
select pg_temp.ent('e5', '73', '11', 2, true);
-- Venta 74: vendió 3 y no entregó nada: una pendiente de 3.
select pg_temp.ent('e6', '74', '11', 3, true);
update public.stock set cantidad_disponible = 10 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('11');
select is(pg_temp.stock('b1', '11'), '10', 'partida: el stock del 11 está en 10');

-- 2.1 El caso del issue: vendió 3, entregó 1, devuelve 3.
select is(pg_temp.dev('d1', '71', '11', 3, '81'), 'ok', 'devolver los 3 de una venta donde se entregó 1: ok');
select is(pg_temp.stock('b1', '11'), '11', 'al stock vuelve solo 1 (lo entregado)');
select is((select cantidad::text || '/' || tipo from public.movimiento_stock where devolucion_id = pg_temp.u('d1')),
          '1/ENTRADA_DEVOLUCION', 'con un movimiento ENTRADA_DEVOLUCION de 1');
select is((select (deleted_at is not null)::text from public.entrega where id = pg_temp.u('e2')), 'true',
          'los 2 no entregados salen de la entrega pendiente (queda dada de baja)');
select is((select (deleted_at is null)::text from public.entrega where id = pg_temp.u('e1')), 'true', 'y la entrega hecha no se toca');
select is(pg_temp.evento('stock_devuelto_por_devolucion', pg_temp.u('d1')), 1, 'queda el evento de lo que volvió al stock');
select is((select metadata ->> 'cantidad' from auditoria.audit_log
            where event_type = 'entrega_pendiente_quitada_por_devolucion' and fila_id = pg_temp.u('d1')), '2',
          'y el de lo que salió de la entrega pendiente (2)');

-- 2.2 Entregó todo: vuelve todo, y acumulado.
select is(pg_temp.dev('d2', '72', '11', 2, '82'), 'ok', 'venta 72 (entregó 3): devolver 2');
select is(pg_temp.stock('b1', '11'), '13', 'vuelven los 2');
select is(pg_temp.dev('d3', '72', '11', 1, '82'), 'ok', 'y el que falta, en otra devolución');
select is(pg_temp.stock('b1', '11'), '14', 'vuelve 1 más: en total 3 de 3');

-- 2.3 Entregó 2 de 4: devoluciones parciales, la segunda se pasa de lo entregado.
select is(pg_temp.dev('d4', '73', '11', 1, '83'), 'ok', 'venta 73 (entregó 2 de 4): devolver 1');
select is(pg_temp.stock('b1', '11') || '/' || (select cantidad::text from public.entrega where id = pg_temp.u('e5')), '15/2',
          'vuelve 1 al stock y la pendiente de 2 queda como estaba');
select is(pg_temp.dev('d5', '73', '11', 2, '83'), 'ok', 'devolver 2 más (ya devolvió 1 de las 2 entregadas)');
select is(pg_temp.stock('b1', '11') || '/' || (select cantidad::text from public.entrega where id = pg_temp.u('e5')), '16/1',
          'vuelve 1 (lo entregado que faltaba) y la otra sale de la pendiente (de 2 a 1)');
select is(pg_temp.dev('d6', '73', '11', 1, '83'), 'ok', 'devolver el último');
select is(pg_temp.stock('b1', '11') || '/' || (select (deleted_at is not null)::text from public.entrega where id = pg_temp.u('e5')),
          '16/true', 'no vuelve nada al stock (ya volvió todo lo entregado) y la pendiente se da de baja');

-- 2.4 No entregó nada.
select is(pg_temp.dev('d7', '74', '11', 3, '84'), 'ok', 'venta 74 (sin entregar nada): devolver los 3');
select is(pg_temp.stock('b1', '11') || '/' || (select count(*)::int from public.movimiento_stock where devolucion_id = pg_temp.u('d7')),
          '16/0', 'el stock no se mueve y no hay movimiento');
select is((select (deleted_at is not null)::text from public.entrega where id = pg_temp.u('e6')), 'true', 'la entrega pendiente se da de baja');

-- 2.5 Venta sin ninguna fila de entrega: no falla y no suma.
select is(pg_temp.dev('d8', '75', '11', 2, '85'), 'ok', 'venta sin filas de entrega: la devolución entra');
select is(pg_temp.stock('b1', '11'), '16', 'y no suma nada al stock');

-- 2.6 Anular resta solo lo que la devolución sumó.
update public.devolucion set deleted_at = now() where id = pg_temp.u('d1');
select is(pg_temp.stock('b1', '11'), '15', 'anular la devolución de 71 resta el 1 que sumó (no los 3)');
update public.devolucion set deleted_at = now() where id = pg_temp.u('d7');
select is(pg_temp.stock('b1', '11'), '15', 'anular la que no sumó nada no resta nada');

-- ---------------------------------------------------------------------------
-- 3. La transferencia baja a las dos puntas
-- ---------------------------------------------------------------------------
select has_column('public', 'transferencia_item', 'origen_id', 'transferencia_item.origen_id');
select has_column('public', 'transferencia_item', 'destino_id', 'transferencia_item.destino_id');
select results_eq($$ select columna_duenio from sync.entidad where nombre in ('transferencia_stock', 'transferencia_item') order by nombre $$,
                  $$ values ('origen_id,destino_id'::text), ('origen_id,destino_id'::text) $$,
                  'las dos entidades bajan por origen_id y destino_id');

-- T1: la arma la coordinadora (sin solicitante), b1 da y b2 recibe. T2: la pidió b3, b1 da y b3 recibe.
-- T3: b2 da y b3 recibe (no es de b1).
insert into public.transferencia_stock (id, origen_id, destino_id, estado, coordinador_id) values
  (pg_temp.u('b1'), pg_temp.u('b1'), pg_temp.u('b2'), 'PENDIENTE_AUTORIZACION', pg_temp.u('c1'));
insert into public.transferencia_stock (id, origen_id, destino_id, estado, solicitante_id) values
  (pg_temp.u('b2'), pg_temp.u('b1'), pg_temp.u('b3'), 'PENDIENTE_AUTORIZACION', pg_temp.u('b3')),
  (pg_temp.u('b3'), pg_temp.u('b2'), pg_temp.u('b3'), 'PENDIENTE_AUTORIZACION', pg_temp.u('b3'));
insert into public.transferencia_item (id, transferencia_id, producto_id, cantidad) values
  (pg_temp.u('c1'), pg_temp.u('b1'), pg_temp.u('11'), 2),
  (pg_temp.u('c2'), pg_temp.u('b2'), pg_temp.u('12'), 1),
  (pg_temp.u('c3'), pg_temp.u('b3'), pg_temp.u('12'), 1);

select is((select origen_id::text || '>' || destino_id::text from public.transferencia_item where id = pg_temp.u('c1')),
          pg_temp.u('b1')::text || '>' || pg_temp.u('b2')::text, 'la línea copia las dos puntas del encabezado');
select is((select solicitante_id from public.transferencia_item where id = pg_temp.u('c1')), null,
          'y la armada por la coordinadora no tiene solicitante');

-- ---------------------------------------------------------------------------
-- 4. Quien pidió la transferencia la puede cancelar
-- ---------------------------------------------------------------------------
-- b1 pide una a b2 (compañeros) y le suma una línea.
select is(pg_temp.push(pg_temp.u('b1'), 'f1', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('f1'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b1'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'outcome', 'accepted', 'b1 pide libros a b2');
select is(pg_temp.push(pg_temp.u('b1'), 'f2', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('f2'), 'transferencia_id', pg_temp.u('f1'), 'producto_id', pg_temp.u('11'),
                               'cantidad', 2)) ->> 'outcome', 'accepted', 'con su línea');
select is((select origen_id::text || '>' || destino_id::text from public.transferencia_item where id = pg_temp.u('f2')),
          pg_temp.u('b2')::text || '>' || pg_temp.u('b1')::text, 'la línea que sube el teléfono también lleva las dos puntas');

-- La cancela con la versión vieja que tenía el teléfono (la del alta): no hay conflicto.
select is(pg_temp.push(pg_temp.u('b1'), 'f3', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f1'), 'estado', 'CANCELADO'), 0) ->> 'outcome',
          'accepted', 'cancelar con una versión vieja: accepted (la cancelación no compara versión)');
select is(pg_temp.estado('f1'), 'CANCELADO', 'queda cancelada');
select is(pg_temp.push(pg_temp.u('b1'), 'f3', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f1'), 'estado', 'CANCELADO'), 0) ->> 'outcome',
          'duplicate', 'el mismo envío otra vez: duplicate');
select is(pg_temp.push(pg_temp.u('b1'), 'f4', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f1'), 'estado', 'CANCELADO'), 0) ->> 'outcome',
          'accepted', 'cancelar una ya cancelada con otro envío: accepted (idempotente)');
select is(pg_temp.estado('f1'), 'CANCELADO', 'sigue cancelada');
select is((select count(*)::int from public.transferencia_stock where id = pg_temp.u('f1') and deleted_at is null), 1,
          'la cancelada no se borra: queda el registro');

-- Las que no se pueden cancelar desde el teléfono.
insert into public.transferencia_stock (id, origen_id, destino_id, estado, solicitante_id, coordinador_id, decidido_en, monto_deuda) values
  (pg_temp.u('f5'), pg_temp.u('b2'), pg_temp.u('b1'), 'AUTORIZADO', pg_temp.u('b1'), pg_temp.u('c1'), now(), 0);
insert into public.transferencia_stock (id, origen_id, destino_id, estado, solicitante_id, coordinador_id, decidido_en, motivo_rechazo) values
  (pg_temp.u('f6'), pg_temp.u('b2'), pg_temp.u('b1'), 'RECHAZADO', pg_temp.u('b1'), pg_temp.u('c1'), now(), 'No hay');
select is(pg_temp.push(pg_temp.u('b1'), 'f7', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f5'), 'estado', 'CANCELADO'), 0) ->> 'code',
          '42501', 'cancelar una autorizada: invalid 42501');
select is(pg_temp.estado('f5'), 'AUTORIZADO', 'la autorizada sigue autorizada');
select ok(position('ya autorizó' in coalesce(pg_temp.push(pg_temp.u('b1'), 'f8', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f5'), 'estado', 'CANCELADO'), 0) ->> 'message', '')) > 0,
          'y el aviso dice qué hacer: hablar con el coordinador');
select is(pg_temp.push(pg_temp.u('b1'), 'f9', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f6'), 'estado', 'CANCELADO'), 0) ->> 'code',
          '42501', 'cancelar una rechazada: invalid 42501');
select is(pg_temp.estado('f6'), 'RECHAZADO', 'la rechazada sigue rechazada');

-- Solo quien la pidió: la otra punta y la armada por la coordinadora no.
insert into public.transferencia_stock (id, origen_id, destino_id, estado, solicitante_id) values
  (pg_temp.u('fa'), pg_temp.u('b2'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', pg_temp.u('b1'));
select is(pg_temp.filas_de(pg_temp.u('b2'), format($$ update public.transferencia_stock set estado = 'CANCELADO' where id = %L $$, pg_temp.u('fa'))),
          '0', 'la otra punta (b2) no puede cancelarla: 0 filas');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'CANCELADO' where id = %L $$, pg_temp.u('b1'))),
          '0', 'la armada por la coordinadora no tiene solicitante: tampoco b1');
select is(pg_temp.filas_de(pg_temp.u('b3'), format($$ update public.transferencia_stock set estado = 'CANCELADO' where id = %L $$, pg_temp.u('fa'))),
          '0', 'ni quien no es punta');
select is(pg_temp.estado('fa') || '/' || pg_temp.estado('b1'), 'PENDIENTE_AUTORIZACION/PENDIENTE_AUTORIZACION', 'ninguna cambió');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'CANCELADO' where id = %L $$, pg_temp.u('fa'))),
          '1', 'quien la pidió sí: 1 fila');

-- Lo único que cambia es el estado.
insert into public.transferencia_stock (id, origen_id, destino_id, estado, solicitante_id) values
  (pg_temp.u('fb'), pg_temp.u('b2'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', pg_temp.u('b1'));
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'AUTORIZADO' where id = %L $$, pg_temp.u('fb'))),
          '42501', 'autorizarse sola: 42501');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'CANCELADO', monto_deuda = 1 where id = %L $$, pg_temp.u('fb'))),
          '42501', 'cancelar y tocar otra columna: 42501 (privilegio por columna)');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set deleted_at = now() where id = %L $$, pg_temp.u('fb'))),
          '42501', 'borrarla: 42501 (una transferencia no se borra, se cancela)');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set origen_id = %L where id = %L $$, pg_temp.u('b3'), pg_temp.u('fb'))),
          '42501', 'cambiar de quién da: 42501');
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ delete from public.transferencia_stock where id = %L $$, pg_temp.u('fb'))),
          '42501', 'borrar la fila: 42501');
select is(pg_temp.estado('fb'), 'PENDIENTE_AUTORIZACION', 'sigue como estaba');
-- Volver atrás una cancelada no se puede: lo dice el trigger (desde el teléfono solo se cancela).
select is(pg_temp.filas_de(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'PENDIENTE_AUTORIZACION' where id = %L $$, pg_temp.u('fa'))),
          '42501', 'una cancelada no vuelve a por autorizar: 42501');
-- El servidor sí cambia lo que quiera (la coordinadora autoriza por la RPC).
select is(pg_temp.error_de(format($$ update public.transferencia_stock set estado = 'AUTORIZADO' where id = %L $$, pg_temp.u('fb'))),
          'ok', 'el servidor no pasa por el trigger del teléfono');

-- El alta que nace cancelada (armada y cancelada sin conexión: el motor funde las dos cosas en el alta).
select is(pg_temp.push(pg_temp.u('b1'), '91', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('91'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b4'),
                               'estado', 'CANCELADO')) ->> 'outcome',
          'accepted', 'una que nace CANCELADO: accepted (aunque el otro no sea compañero: no hay nada que autorizar)');
select is(pg_temp.estado('91'), 'CANCELADO', 'queda cancelada');
select is(pg_temp.push(pg_temp.u('b1'), '92', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('92'), 'transferencia_id', pg_temp.u('91'), 'producto_id', pg_temp.u('11'),
                               'cantidad', 1)) ->> 'outcome',
          'accepted', 'sus líneas entran también');
select is(pg_temp.push(pg_temp.u('b1'), '93', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('93'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b3'),
                               'estado', 'CANCELADO')) ->> 'code',
          '42501', 'nacer cancelada pero ajena (ni da ni recibe b1): invalid 42501');
select is(pg_temp.push(pg_temp.u('b1'), '94', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('94'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b2'),
                               'estado', 'AUTORIZADO')) ->> 'code',
          '23514', 'nacer autorizada sigue sin poder: invalid 23514');
select is(pg_temp.push(pg_temp.u('b1'), '95', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('95'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b4'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'code',
          '42501', 'y por autorizar con alguien que no es compañero sigue sin poder: invalid 42501');
-- Una línea a una autorizada no entra.
select is(pg_temp.push(pg_temp.u('b1'), '96', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('96'), 'transferencia_id', pg_temp.u('f5'), 'producto_id', pg_temp.u('11'),
                               'cantidad', 1)) ->> 'code',
          '42501', 'una línea nueva a una transferencia autorizada: invalid 42501');

select * from finish();
rollback;
