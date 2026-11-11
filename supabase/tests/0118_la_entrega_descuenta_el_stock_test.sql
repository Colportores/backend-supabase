-- pgTAP · 0118 (backend-supabase#147, HU-STK-007, S46): una entrega ENTREGADA descuenta el stock del colportor de
-- la venta producto por producto, agrega un movimiento SALIDA_ENTREGA y deja el evento en audit_log; si el stock
-- registrado no alcanzaba, la entrega se registra igual y queda marcada (stock_inconsistente), y la marca es
-- solo del servidor. Cubre:
--   1. La forma: la columna, su default, las columnas del servidor, los dos triggers y el índice único.
--   2. Entrega inmediata con stock suficiente, justo y de menos (S46), sin fila de stock y un combo.
--   3. Entrega diferida: pendiente no descuenta; al entregarla sí, y una sola vez (UPDATE de otra columna,
--      vuelta a pendiente y entrega de nuevo, replay del push).
--   4. La marca es del servidor: ni el push ni PostgREST la eligen.
--   5. Lo que no se toca: el stock de otro colportor, una entrega de baja, la entrega anulada después.
--   6. La fecha del movimiento y la auditoría (quién, sobre quién, números y sin texto libre).
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
  select ('01920000-0000-7000-8000-0000000118' || p)::uuid;
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- El stock de un colportor y un producto ('sin fila' si no la hay).
create or replace function pg_temp.stock(p_quien text, p_producto text) returns text language sql as $$
  select coalesce((select s.cantidad_disponible::text from public.stock s
                    where s.usuario_id = pg_temp.u(p_quien) and s.producto_id = pg_temp.u(p_producto)), 'sin fila');
$$;
-- Cuántos movimientos SALIDA_ENTREGA tiene una entrega.
create or replace function pg_temp.salidas(p_entrega text) returns integer language sql as $$
  select count(*)::int from public.movimiento_stock m
   where m.entrega_id = pg_temp.u(p_entrega) and m.tipo = 'SALIDA_ENTREGA';
$$;
create or replace function pg_temp.marca(p_entrega text) returns boolean language sql as $$
  select stock_inconsistente from public.entrega where id = pg_temp.u(p_entrega);
$$;
-- Una entrega tal como la inserta quien la registra: 'ok' o el SQLSTATE.
create or replace function pg_temp.ent(p_id text, p_venta text, p_producto text, p_cantidad integer,
                                       p_pendiente boolean default false, p_fecha timestamptz default null,
                                       p_baja timestamptz default null)
returns text language plpgsql as $$
begin
  insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, fecha_entrega, deleted_at)
  values (pg_temp.u(p_id), pg_temp.u(p_venta), pg_temp.u(p_producto), p_cantidad, p_pendiente, p_fecha, p_baja);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000118d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_op_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'entrega', 'op', p_op_tipo,
                            'sync_version', p_version, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Los eventos stock_descontado_por_entrega de una entrega (se lee como el servidor).
create or replace function pg_temp.eventos(p_entrega text) returns integer language sql as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = 'stock_descontado_por_entrega' and a.fila_id = pg_temp.u(p_entrega);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 colportores. Ventas: 51 y 52 de b1, 53 de b2. Productos: d1 (Libro A), d2 (Libro B), d3 (Libro C).
-- Stock de b1: d1 = 10, d2 = 2, d3 sin fila. Stock de b2: d1 = 7, d3 = 50 (lo de b2 no cuenta para b1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'entrega118-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais entrega', 'ZB');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad entrega', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Entrega 01', '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA', 'Entrega 02', '2', -34.92, -56.2, pg_temp.u('c1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), 'T-' || x.v, 100000, now(), pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('51', '21', 'b1'), ('52', '21', 'b1'), ('53', '22', 'b2')) x(v, ep, quien);
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('d1'), 'Libro A', 'LIBRO'), (pg_temp.u('d2'), 'Libro B', 'LIBRO'), (pg_temp.u('d3'), 'Libro C', 'LIBRO');
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('d1'), 10), (pg_temp.u('b1'), pg_temp.u('d2'), 2), (pg_temp.u('b2'), pg_temp.u('d1'), 7),
  (pg_temp.u('b2'), pg_temp.u('d3'), 50);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'entrega', 'stock_inconsistente', 'boolean', 'entrega.stock_inconsistente es boolean');
select col_not_null('public', 'entrega', 'stock_inconsistente', 'y no es null');
select col_default_is('public', 'entrega', 'stock_inconsistente', 'false', 'y arranca en false');
select is((select 'stock_inconsistente' = any (columnas_servidor) from sync.entidad where nombre = 'entrega'), true,
          'el push la descarta: es columna del servidor de entrega');
select is((select 'stock_inconsistente' = any (sync.columnas_escribibles('entrega'))), false,
          'y no está entre las que el cliente puede escribir');
select has_trigger('public', 'entrega', 'entrega_stock_inconsistente', 'entrega tiene el trigger de la marca');
select has_trigger('public', 'entrega', 'entrega_descuenta_stock', 'y el del descuento');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.tg_entrega_descuenta_stock()'::regprocedure), true,
          'el del descuento es SECURITY DEFINER (el push no puede escribir stock)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.tg_entrega_stock_inconsistente()'::regprocedure), false,
          'el de la marca no lo es (necesita ver quién escribe)');
select is(has_function_privilege('authenticated', 'public.tg_entrega_descuenta_stock()', 'execute')
          or has_function_privilege('anon', 'public.tg_entrega_descuenta_stock()', 'execute')
          or has_function_privilege('authenticated', 'public.tg_entrega_stock_inconsistente()', 'execute'), false,
          'nadie con JWT puede llamar a las funciones de los triggers');
select hasnt_index('public', 'movimiento_stock', 'movimiento_stock_salida_entrega_key', 'ya no hay un índice único de la salida por entrega (0135: una entrega deshecha y vuelta a entregar descuenta otra vez)');

-- ---------------------------------------------------------------------------
-- 2. Entrega inmediata (como el servidor)
-- ---------------------------------------------------------------------------
-- 10 libros y entrego 3: pasa a 7, sin marca.
select is(pg_temp.ent('e1', '51', 'd1', 3), 'ok', 'b1 entrega 3 del Libro A con 10 de stock');
select is(pg_temp.stock('b1', 'd1'), '7', 'el stock pasa a 7');
select is(pg_temp.marca('e1'), false, 'sin marca de inconsistencia');
select is(pg_temp.salidas('e1'), 1, 'y queda un movimiento de salida');
select is((select m.usuario_id::text || '/' || m.producto_id::text || '/' || m.cantidad
             from public.movimiento_stock m where m.entrega_id = pg_temp.u('e1')),
          pg_temp.u('b1')::text || '/' || pg_temp.u('d1')::text || '/3', 'del colportor, del producto y por 3');
select is(pg_temp.eventos('e1'), 1, 'y un evento en audit_log');

-- Justo lo que hay: queda en 0 y sin marca.
select is(pg_temp.ent('e2', '51', 'd1', 7), 'ok', 'entrega los 7 que le quedan');
select is(pg_temp.stock('b1', 'd1'), '0', 'el stock queda en 0');
select is(pg_temp.marca('e2'), false, 'justo lo que había no es inconsistencia');

-- Stock de 2 y entrega 5: se registra igual y queda marcada (S46).
select is(pg_temp.ent('e3', '51', 'd2', 5), 'ok', 'b1 entrega 5 del Libro B con 2 de stock: se registra igual');
select is(pg_temp.stock('b1', 'd2'), '-3', 'el stock queda en -3 (entregar de más se permite)');
select is(pg_temp.marca('e3'), true, 'y la entrega queda marcada como inconsistente');
select is((select count(*)::int from public.entrega where id = pg_temp.u('e3') and cantidad = 5), 1,
          'con la cantidad que entregó, sin recortar');
select is((select m.cantidad from public.movimiento_stock m where m.entrega_id = pg_temp.u('e3')), 5,
          'y el movimiento es por las 5');

-- Con el saldo en 0 (o negativo), la siguiente también.
select is(pg_temp.ent('e4', '51', 'd1', 1), 'ok', 'una más del Libro A con el stock en 0');
select is(pg_temp.marca('e4'), true, 'queda marcada');
select is(pg_temp.stock('b1', 'd1'), '-1', 'y el stock en -1');

-- Sin fila de stock el saldo vale 0: se crea la fila en negativo y la entrega queda marcada.
select is(pg_temp.stock('b1', 'd3'), 'sin fila', 'b1 no tiene stock registrado del Libro C (aunque b2 sí)');
select is(pg_temp.ent('e5', '52', 'd3', 2), 'ok', 'entrega 2 del Libro C');
select is(pg_temp.stock('b1', 'd3'), '-2', 'se crea la fila de stock en -2');
select is(pg_temp.marca('e5'), true, 'y la entrega queda marcada');

-- Un combo se entrega como una fila por componente: cada producto descuenta lo suyo.
update public.stock set cantidad_disponible = 6 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d1');
update public.stock set cantidad_disponible = 1 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d2');
select is(pg_temp.ent('e6', '52', 'd1', 2), 'ok', 'combo: el Libro A viene 2 veces');
select is(pg_temp.ent('e7', '52', 'd2', 1), 'ok', 'combo: el Libro B una vez');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.stock('b1', 'd2'), '4/0', 'cada componente descuenta su producto');
select is(pg_temp.marca('e6') or pg_temp.marca('e7'), false, 'con stock para los dos no hay marca');

-- Una cantidad de un componente que no alcanza marca solo esa fila.
select is(pg_temp.ent('e8', '52', 'd2', 1), 'ok', 'otro Libro B con el stock en 0');
select is(pg_temp.marca('e8'), true, 'esa fila queda marcada');
select is(pg_temp.marca('e6'), false, 'y la del otro componente no');

-- ---------------------------------------------------------------------------
-- 3. Entrega diferida: descuenta al entregarse, y una sola vez
-- ---------------------------------------------------------------------------
update public.stock set cantidad_disponible = 10 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d1');
select is(pg_temp.ent('f1', '51', 'd1', 4, true), 'ok', 'b1 registra una entrega pendiente de 4');
select is(pg_temp.stock('b1', 'd1'), '10', 'pendiente no descuenta');
select is(pg_temp.salidas('f1'), 0, 'ni deja movimiento');
select is(pg_temp.marca('f1'), false, 'ni marca');
select is(pg_temp.eventos('f1'), 0, 'ni evento');

update public.entrega set fecha_prevista = now() + interval '2 days' where id = pg_temp.u('f1');
select is(pg_temp.stock('b1', 'd1'), '10', 'cambiarle la fecha prevista tampoco');

update public.entrega set pendiente = false, fecha_entrega = '2026-10-20 15:00:00+00' where id = pg_temp.u('f1');
select is(pg_temp.stock('b1', 'd1'), '6', 'al entregarla descuenta las 4');
select is(pg_temp.salidas('f1'), 1, 'con su movimiento');
select is((select m.fecha from public.movimiento_stock m where m.entrega_id = pg_temp.u('f1')),
          '2026-10-20 15:00:00+00'::timestamptz, 'fechado el día real de la entrega');
select is(pg_temp.marca('f1'), false, 'sin marca: había stock');

-- Otro UPDATE de la fila ya entregada no vuelve a descontar.
update public.entrega set fecha_entrega = '2026-10-21 15:00:00+00' where id = pg_temp.u('f1');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('f1'), '6/1', 'corregir la fecha de una entregada no descuenta de nuevo');

-- Vuelve a pendiente (0135: el stock vuelve, con su movimiento) y se entrega otra vez: descuenta de nuevo, y cada
-- paso deja su salida y su evento.
update public.entrega set pendiente = true where id = pg_temp.u('f1');
update public.entrega set pendiente = false where id = pg_temp.u('f1');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('f1') || '/' || pg_temp.eventos('f1'), '6/2/2',
          'pendiente y entregada otra vez: el stock termina igual (6), con dos salidas y dos eventos de descuento');

-- Una entrega diferida de más de lo que hay: se marca al entregarla, no al registrarla.
select is(pg_temp.ent('f2', '51', 'd1', 9, true), 'ok', 'otra pendiente, de 9, con 6 de stock');
select is(pg_temp.marca('f2'), false, 'mientras está pendiente no se marca');
update public.entrega set pendiente = false where id = pg_temp.u('f2');
select is(pg_temp.marca('f2'), true, 'al entregarla queda marcada');
select is(pg_temp.stock('b1', 'd1'), '-3', 'y el stock en -3');
select is((select m.fecha is not null from public.movimiento_stock m where m.entrega_id = pg_temp.u('f2')), true,
          'sin fecha real, el movimiento lleva la hora del registro');

-- Corregir una entrega ya descontada no recalcula la marca con el stock de hoy.
select is(pg_temp.stock('b1', 'd1'), '-3', 'el stock de b1 está por debajo de lo que entregó en e1');
update public.entrega set fecha_entrega = '2026-10-25 15:00:00+00' where id = pg_temp.u('e1');
select is(pg_temp.marca('e1') or pg_temp.stock('b1', 'd1') <> '-3', false,
          'corregir e1 no la marca ni mueve el stock: la marca es de cuando se entregó');

-- ---------------------------------------------------------------------------
-- 4. Lo que no se toca
-- ---------------------------------------------------------------------------
select is(pg_temp.stock('b2', 'd1'), '7', 'el stock de b2 sigue en 7: lo de b1 no lo mueve');
select is(pg_temp.ent('90', '53', 'd1', 2), 'ok', 'b2 entrega 2');
select is(pg_temp.stock('b2', 'd1') || '/' || pg_temp.stock('b1', 'd1'), '5/-3', 'descuenta a b2 y no a b1');

-- Una entrega que se inserta ya anulada no descuenta.
select is(pg_temp.ent('91', '53', 'd1', 3, false, null, now()), 'ok', 'una entrega que llega de baja');
select is(pg_temp.stock('b2', 'd1') || '/' || pg_temp.salidas('91'), '5/0', 'no descuenta ni deja movimiento');

-- Ni se marca la que llega de baja aunque el stock no alcance.
select is(pg_temp.ent('95', '53', 'd1', 50, false, null, now()), 'ok', 'una entrega de baja de 50 con 5 de stock');
select is(pg_temp.marca('95'), false, 'no se marca: no es una entrega');

-- Anular una entrega ya descontada devuelve el stock (0135, decisión «Entrega desh» del 27/10), con su movimiento.
update public.entrega set deleted_at = now() where id = pg_temp.u('90');
select is(pg_temp.stock('b2', 'd1') || '/' || pg_temp.salidas('90'), '7/1', 'anular una entrega descontada devuelve sus 2 al stock (5 + 2), la salida original sigue en el historial');

-- Una entrega anterior, entregada sin movimiento (como las de antes de la 0118), no descuenta si se le cambia algo.
alter table public.entrega disable trigger entrega_descuenta_stock;
alter table public.entrega disable trigger entrega_stock_inconsistente;
select is(pg_temp.ent('92', '53', 'd1', 2), 'ok', 'una entrega entregada de antes de la 0118 (sin pasar por los triggers)');
alter table public.entrega enable trigger entrega_descuenta_stock;
alter table public.entrega enable trigger entrega_stock_inconsistente;
update public.entrega set fecha_prevista = now() where id = pg_temp.u('92');
select is(pg_temp.stock('b2', 'd1') || '/' || pg_temp.salidas('92'), '7/0', 'editarla no descuenta: solo cuenta el paso a entregada');
select is(pg_temp.marca('92'), false, 'y sigue sin marca');

-- La marca no se recalcula si la entrega vuelve a pendiente y se entrega otra vez sin stock.
update public.stock set cantidad_disponible = 5 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d1');
select is(pg_temp.ent('96', '51', 'd1', 1, true), 'ok', 'b1 registra una pendiente de 1');
update public.entrega set pendiente = false where id = pg_temp.u('96');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.marca('96'), '4/false', 'la entrega con stock: descuenta y sin marca');
update public.stock set cantidad_disponible = 0 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d1');
update public.entrega set pendiente = true where id = pg_temp.u('96');
update public.entrega set pendiente = false where id = pg_temp.u('96');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.marca('96') || '/' || pg_temp.salidas('96'), '0/false/2',
          'deshecha y entregada otra vez: el stock que volvió (1) se descuenta de nuevo; la marca no cambia');

-- Una entrega de antes de la 0118 (entregada, sin movimiento) que se anula y se restaura vuelve a contar como
-- entregada: descuenta una vez.
alter table public.entrega disable trigger entrega_descuenta_stock;
alter table public.entrega disable trigger entrega_stock_inconsistente;
select is(pg_temp.ent('97', '51', 'd1', 1), 'ok', 'otra entrega entregada de antes de la 0118');
alter table public.entrega enable trigger entrega_descuenta_stock;
alter table public.entrega enable trigger entrega_stock_inconsistente;
update public.entrega set deleted_at = now() where id = pg_temp.u('97');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('97'), '0/0', 'anularla no toca el stock');
update public.entrega set deleted_at = null where id = pg_temp.u('97');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('97') || '/' || pg_temp.marca('97'), '-1/1/true',
          'restaurarla la cuenta como entrega: descuenta una vez y, sin stock, queda marcada');

-- Una de antes con el stock de hoy por debajo de lo que entregó: editarla no la marca.
alter table public.entrega disable trigger entrega_descuenta_stock;
alter table public.entrega disable trigger entrega_stock_inconsistente;
select is(pg_temp.ent('98', '51', 'd1', 3), 'ok', 'una entrega de antes de la 0118 de 3 con el stock en -1');
alter table public.entrega enable trigger entrega_descuenta_stock;
alter table public.entrega enable trigger entrega_stock_inconsistente;
update public.entrega set fecha_prevista = now() where id = pg_temp.u('98');
select is(pg_temp.marca('98') or pg_temp.stock('b1', 'd1') <> '-1', false, 'editarla no la marca ni descuenta');

-- ---------------------------------------------------------------------------
-- 5. El teléfono sube las entregas (sync_push como b1)
-- ---------------------------------------------------------------------------
update public.stock set cantidad_disponible = 10 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d1');
select pg_temp.actuar_como(pg_temp.u('b1'));

select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('a1', 'insert', jsonb_build_object('id', pg_temp.u('a6'), 'venta_id', pg_temp.u('51'),
                          'producto_id', pg_temp.u('d1'), 'cantidad', 3, 'pendiente', false))))), array['accepted'],
          'el teléfono sube una entrega inmediata con stock');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('a6') || '/' || pg_temp.marca('a6'), '7/1/false',
          'descuenta (el push corre sin permiso de escribir stock), con su movimiento y sin marca');
select is((select a.actor_user_id::text || '/' || a.target_user_id::text from auditoria.audit_log a
            where a.event_type = 'stock_descontado_por_entrega' and a.fila_id = pg_temp.u('a6')),
          pg_temp.u('b1')::text || '/' || pg_temp.u('b1')::text, 'el evento lleva a b1 como actor y como sobre quién');

-- Entrega de más: se acepta, descuenta y queda marcada aunque el teléfono diga lo contrario.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('a2', 'insert', jsonb_build_object('id', pg_temp.u('a7'), 'venta_id', pg_temp.u('51'),
                          'producto_id', pg_temp.u('d1'), 'cantidad', 20, 'pendiente', false,
                          'stock_inconsistente', false))))), array['accepted'],
          'una entrega de 20 con 7 de stock se acepta: nunca se frena una venta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.marca('a7'), '-13/true',
          'descuenta las 20 y queda marcada aunque el payload dijera false');

-- El teléfono tampoco puede inventar la marca.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('a3', 'insert', jsonb_build_object('id', pg_temp.u('a8'), 'venta_id', pg_temp.u('51'),
                          'producto_id', pg_temp.u('d1'), 'cantidad', 1, 'pendiente', true,
                          'stock_inconsistente', true))))), array['accepted'],
          'una entrega pendiente que dice venir marcada se acepta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.marca('a8'), false, 'y la marca que mandó se descartó');

-- Replay: el mismo id con otra operación no vuelve a descontar.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('a4', 'insert', jsonb_build_object('id', pg_temp.u('a6'), 'venta_id', pg_temp.u('51'),
                          'producto_id', pg_temp.u('d1'), 'cantidad', 3, 'pendiente', false))))), array['duplicate'],
          'la misma entrega subida otra vez es un duplicado');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('a6') || '/' || pg_temp.eventos('a6'), '-13/1/1',
          'y no descuenta de nuevo: ni stock, ni movimiento, ni evento');

-- El teléfono entrega la pendiente (UPDATE por push): descuenta ahí.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job('a5', 'update', jsonb_build_object('id', pg_temp.u('a8'), 'pendiente', false,
                          'fecha_entrega', '2026-10-22 12:00:00+00'),
                        (select e.sync_version from public.entrega e where e.id = pg_temp.u('a8')))))), array['accepted'],
          'el teléfono marca entregada la pendiente');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.salidas('a8') || '/' || pg_temp.marca('a8'), '-14/1/true',
          'descuenta al pasar a entregada y, sin stock, queda marcada');

-- ---------------------------------------------------------------------------
-- 6. PostgREST: ni la marca ni el stock son de quien escribe
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.entrega set stock_inconsistente = false where id = pg_temp.u('a7') $$), 'ok',
          'b1 puede escribir su entrega');
select pg_temp.actuar_como_servidor();
select is(pg_temp.marca('a7'), true, 'pero la marca sigue como la dejó el servidor');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ent('93', '52', 'd2', 1, true), 'ok', 'b1 inserta directo una pendiente');
select is(pg_temp.error_de($$ insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, stock_inconsistente)
                             values (pg_temp.u('94'), pg_temp.u('52'), pg_temp.u('d2'), 1, true, true) $$), 'ok',
          'b1 inserta directo una pendiente que dice venir marcada');
select pg_temp.actuar_como_servidor();
select is(pg_temp.marca('94'), false, 'y la marca no entra');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.stock), 3,
          'b1 ve sus tres renglones de stock (y no el de b2)');
select is(pg_temp.error_de($$ update public.stock set cantidad_disponible = 999 $$), '42501',
          'pero no puede escribir su stock');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. La auditoría
-- ---------------------------------------------------------------------------
select is((select a.metadata from auditoria.audit_log a
            where a.event_type = 'stock_descontado_por_entrega' and a.fila_id = pg_temp.u('e3')),
          jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 5, 'stock_antes', 2, 'stock_despues', -3,
                             'inconsistente', true),
          'el evento de una entrega de más: producto, cantidad, stock antes y después, y la marca');
select is((select a.tabla from auditoria.audit_log a
            where a.event_type = 'stock_descontado_por_entrega' and a.fila_id = pg_temp.u('e1')),
          'entrega', 'y apunta a la fila de entrega');
select is((select a.metadata ->> 'inconsistente' from auditoria.audit_log a
            where a.event_type = 'stock_descontado_por_entrega' and a.fila_id = pg_temp.u('e1')),
          'false', 'una entrega con stock lo dice: inconsistente = false');

select * from finish();
rollback;
