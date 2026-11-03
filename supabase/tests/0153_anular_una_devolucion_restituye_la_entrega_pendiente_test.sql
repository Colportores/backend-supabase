-- pgTAP · 0153 (backend-supabase#226, seguimiento de #221; decisión del 29/10, regla R1 y precedente «Entrega desh»):
--   anular una devolución restituye la entrega pendiente que había quitado.
--   Caso base: vendió 3, entregó 1 y devolvió los 3 (vuelve 1 al stock, los 2 pendientes salen de la entrega pendiente);
--   al anular la devolución el stock vuelve a restarse Y esos 2 vuelven a estar pendientes, en la misma entrega.
--   Casos: devolución total y parcial, varias entregas pendientes, la entrega que ya se entregó entre una cosa y otra
--   (vuelve como pendiente nueva), dos devoluciones sobre la misma venta, anular dos veces, devolución sin pendiente
--   que quitar, devolución anterior a la 0153 (evento sin entrega_id) y anulación por sync.push.
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
  select ('01920000-0000-7000-8000-0000000153' || p)::uuid;
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
       'authenticated', 'authenticated', 'dev153-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','ad','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'),
               ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Actual 153', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '40 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('11'), 'Libro 1 t153', 'LIBRO', 1500), (pg_temp.u('12'), 'Libro 2 t153', 'LIBRO', 2500),
  (pg_temp.u('13'), 'Libro 3 t153', 'LIBRO', 3500);

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev153', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev153', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('e2'), pg_temp.u('01'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e2'), pg_temp.u('c2'), pg_temp.u('b1'));
-- --- más helpers ----------------------------------------------------------------
create or replace function pg_temp.pend(p_venta text) returns text language sql as $$
  -- «filas vivas pendientes / unidades pendientes» de una venta y el libro 11
  select count(*)::text || '/' || coalesce(sum(e.cantidad), 0)::text
    from public.entrega e
   where e.venta_id = pg_temp.u(p_venta) and e.producto_id = pg_temp.u('11') and e.pendiente and e.deleted_at is null;
$$;
create or replace function pg_temp.anular(p_dev text) returns void language sql as $$
  update public.devolucion set deleted_at = now() where id = pg_temp.u(p_dev);
$$;
create or replace function pg_temp.eventos(p_tipo text, p_dev text) returns integer language sql as $$
  select count(*)::int from auditoria.audit_log a where a.event_type = p_tipo and a.fila_id = pg_temp.u(p_dev);
$$;
create or replace function pg_temp.el(p_prod text, p_cant int, p_renglon text) returns jsonb language sql as $$
  select jsonb_build_object('producto_id', pg_temp.u(p_prod), 'cantidad', p_cant, 'venta_item_id', pg_temp.u(p_renglon));
$$;

-- Ventas de b1 (cada caso la suya) y sus renglones.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, motivo_monto_manual)
select pg_temp.u(x.v), pg_temp.u('51'), 'T-153' || x.v, 300000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1'),
       'fixture: ítems que no cuadran con el total (0150)'
  from unnest(array['71','72','73','74','75','76','77','79','80']) x(v);
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('82'), pg_temp.u('72'), pg_temp.u('11'), 4, 100000, 400000),
  (pg_temp.u('83'), pg_temp.u('73'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('84'), pg_temp.u('74'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('85'), pg_temp.u('75'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('86'), pg_temp.u('76'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('87'), pg_temp.u('77'), pg_temp.u('11'), 2, 100000, 200000),
  (pg_temp.u('89'), pg_temp.u('79'), pg_temp.u('11'), 2, 100000, 200000),
  (pg_temp.u('90'), pg_temp.u('80'), pg_temp.u('11'), 3, 100000, 300000);

-- Entregas: 71 entregó 1 y quedan 2 · 72 entregó 1 y quedan 3 · 73 dos pendientes (2 y 1) · 74 pendiente de 3
-- · 75 pendiente de 3 · 76 pendiente de 3 · 77 y 79 sin entregas · 80 entregó 1 y quedan 2.
select pg_temp.ent('e1', '71', '11', 1, false);
select pg_temp.ent('e2', '71', '11', 2, true);
select pg_temp.ent('e3', '72', '11', 1, false);
select pg_temp.ent('e4', '72', '11', 3, true);
select pg_temp.ent('e5', '73', '11', 2, true);
select pg_temp.ent('e6', '73', '11', 1, true);
select pg_temp.ent('e7', '74', '11', 3, true);
select pg_temp.ent('e8', '75', '11', 3, true);
select pg_temp.ent('e9', '76', '11', 3, true);
select pg_temp.ent('f4', '80', '11', 1, false);
select pg_temp.ent('f5', '80', '11', 2, true);
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values (pg_temp.u('b1'), pg_temp.u('11'), 10)
  on conflict (usuario_id, producto_id) do update set cantidad_disponible = 10;
select is(pg_temp.stock('b1', '11'), '10', 'partida: el stock del 11 está en 10');

-- ---------------------------------------------------------------------------
-- 1. El caso del issue: vendió 3, entregó 1, devolvió 3 y anula
-- ---------------------------------------------------------------------------
select is(pg_temp.dev('d1', '71', '11', 3, '81'), 'ok', 'devolver los 3 (se entregó 1): ok');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('71'), '11 · 0/0',
          'vuelve 1 al stock y los 2 pendientes salen de la entrega pendiente');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'entrega_pendiente_quitada_por_devolucion' and a.fila_id = pg_temp.u('d1')
              and a.metadata ->> 'entrega_id' = pg_temp.u('e2')::text and a.metadata ->> 'cantidad' = '2'
              and a.metadata ->> 'baja' = 'true'), 1,
          'la traza dice qué entrega se dio de baja y con cuánta cantidad');
create temp table t153_ver as
  select e.sync_version as v, e.created_at as alta from public.entrega e where e.id = pg_temp.u('e2');

select pg_temp.anular('d1');
select is(pg_temp.stock('b1', '11'), '10', 'anular resta el stock que sumó la devolución (como antes)');
select is(pg_temp.pend('71'), '1/2', 'y los 2 libros que el cliente espera vuelven a estar pendientes');
select is((select (e.deleted_at is null and e.pendiente and e.cantidad = 2)::text from public.entrega e where e.id = pg_temp.u('e2')),
          'true', 'en la MISMA entrega (la fila vuelve a vivir con su cantidad)');
select is((select (e.created_at = t.alta)::text from public.entrega e, t153_ver t where e.id = pg_temp.u('e2')), 'true',
          'con su fecha de alta de siempre');
select is((select (e.sync_version > t.v)::text from public.entrega e, t153_ver t where e.id = pg_temp.u('e2')), 'true',
          'sube su sync_version: el teléfono la recibe por el pull');
select is((select count(*)::int from public.entrega where venta_id = pg_temp.u('71')), 2, 'no se creó ninguna entrega nueva');
select is((select (e.cantidad = 1 and not e.pendiente and e.deleted_at is null)::text from public.entrega e where e.id = pg_temp.u('e1')),
          'true', 'y la entrega que ya se hizo no se toca');
select is(pg_temp.eventos('entrega_pendiente_restituida_por_anulacion', 'd1'), 1, 'queda el evento de lo restituido');
select is((select array(select k from jsonb_object_keys(a.metadata) k order by k) from auditoria.audit_log a
            where a.event_type = 'entrega_pendiente_restituida_por_anulacion' and a.fila_id = pg_temp.u('d1')),
          array['cantidad','entrega_id','producto_id'], 'solo con ids y números');

-- ---------------------------------------------------------------------------
-- 2. Devolución parcial: la entrega pendiente solo baja su cantidad
-- ---------------------------------------------------------------------------
-- Venta 72: vendió 4, entregó 1, pendiente de 3. Devuelve 3: 1 al stock y 2 de la pendiente (3 → 1).
select is(pg_temp.dev('d2', '72', '11', 3, '82'), 'ok', 'devolver 3 de 4 (se entregó 1)');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('72'), '11 · 1/1', 'vuelve 1 al stock y la pendiente baja de 3 a 1');
select is((select a.metadata ->> 'baja' from auditoria.audit_log a
            where a.event_type = 'entrega_pendiente_quitada_por_devolucion' and a.fila_id = pg_temp.u('d2')), 'false',
          'la traza dice que no se dio de baja, solo bajó su cantidad');
select pg_temp.anular('d2');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('72'), '10 · 1/3', 'anular: el stock vuelve y la pendiente recupera sus 3');
select is((select count(*)::int from public.entrega where venta_id = pg_temp.u('72')), 2, 'en la misma fila: no se creó otra');

-- ---------------------------------------------------------------------------
-- 3. Varias entregas pendientes de la misma venta
-- ---------------------------------------------------------------------------
-- Venta 73: pendientes de 2 y 1, nada entregado. Devuelve 3: se dan de baja las dos y el stock no se mueve.
select is(pg_temp.dev('d3', '73', '11', 3, '83'), 'ok', 'devolver los 3 con dos pendientes (2 y 1)');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('73'), '10 · 0/0', 'las dos salen de la pendiente y el stock no se mueve');
select is(pg_temp.eventos('entrega_pendiente_quitada_por_devolucion', 'd3'), 2, 'un evento por cada entrega tocada');
select pg_temp.anular('d3');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('73'), '10 · 2/3', 'anular: vuelven las dos, con lo que tenía cada una');
select is((select string_agg(e.cantidad::text, ',' order by e.id) from public.entrega e
            where e.venta_id = pg_temp.u('73') and e.deleted_at is null), '2,1', 'cada una con su cantidad');
select is((select count(*)::int from public.entrega where venta_id = pg_temp.u('73')), 2, 'sin filas nuevas');

-- ---------------------------------------------------------------------------
-- 4. La entrega ya no puede recibirlo: vuelve como pendiente nueva
-- ---------------------------------------------------------------------------
-- Venta 74: pendiente de 3, devuelve 2 (queda 1), y esa 1 se entrega antes de anular (descuenta 1 del stock).
select is(pg_temp.dev('d4', '74', '11', 2, '84'), 'ok', 'devolver 2 de una pendiente de 3');
select is(pg_temp.pend('74'), '1/1', 'queda una pendiente de 1');
update public.entrega set pendiente = false, fecha_entrega = now() where id = pg_temp.u('e7');
select is(pg_temp.stock('b1', '11'), '9', 'se entrega esa 1: el stock baja a 9');
select pg_temp.anular('d4');
select is(pg_temp.pend('74'), '1/2', 'anular: los 2 quitados vuelven a estar pendientes, en una entrega nueva');
select is((select (e.cantidad = 1 and not e.pendiente and e.deleted_at is null)::text from public.entrega e where e.id = pg_temp.u('e7')),
          'true', 'la que ya se entregó queda como estaba');
select is(pg_temp.stock('b1', '11'), '9', 'y la entrega nueva, pendiente, no toca el stock');
select is((select a.metadata ->> 'entrega_id' = pg_temp.u('e7')::text
              and (a.metadata ->> 'entrega_nueva_id')::uuid = (select e.id from public.entrega e
                                                              where e.venta_id = pg_temp.u('74') and e.pendiente and e.deleted_at is null)
             from auditoria.audit_log a
            where a.event_type = 'entrega_pendiente_restituida_por_anulacion' and a.fila_id = pg_temp.u('d4')), true,
          'el evento dice de qué entrega venía y cuál es la nueva');
update public.stock set cantidad_disponible = 10 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('11');

-- ---------------------------------------------------------------------------
-- 5. Dos devoluciones sobre la misma venta: se anula cada una por separado
-- ---------------------------------------------------------------------------
-- Venta 75: pendiente de 3. «da» devuelve 1 (3 → 2) y «db» devuelve 2 (se da de baja la de 2).
select is(pg_temp.dev('da', '75', '11', 1, '85'), 'ok', 'primera devolución: 1');
select is(pg_temp.dev('db', '75', '11', 2, '85'), 'ok', 'segunda devolución: 2');
select is(pg_temp.pend('75'), '0/0', 'no queda nada pendiente');
select pg_temp.anular('da');
select is(pg_temp.pend('75'), '1/1', 'anular la primera: vuelve 1 (la parte que ella quitó), no más');
select pg_temp.anular('db');
select is(pg_temp.pend('75'), '2/3', 'anular también la segunda: vuelven los 3 en total');
select is((select string_agg(e.cantidad::text, ',' order by e.cantidad) from public.entrega e
            where e.venta_id = pg_temp.u('75') and e.deleted_at is null), '1,2', 'una fila con 2 (la original) y otra con 1');

-- ---------------------------------------------------------------------------
-- 6. Anular dos veces no duplica
-- ---------------------------------------------------------------------------
select is(pg_temp.dev('d5', '76', '11', 3, '86'), 'ok', 'venta 76: devolver los 3 de una pendiente de 3');
select is(pg_temp.pend('76'), '0/0', 'sale de la pendiente');
select pg_temp.anular('d5');
select is(pg_temp.pend('76'), '1/3', 'anulada: vuelve');
-- La devolución se reabre y se vuelve a anular (no devuelve nada de nuevo a pendiente: ya se restituyó).
update public.devolucion set deleted_at = null where id = pg_temp.u('d5');
select pg_temp.anular('d5');
select is(pg_temp.pend('76') || ' · ' || (select count(*)::int from public.entrega where venta_id = pg_temp.u('76')), '1/3 · 1',
          'anular otra vez la misma devolución no duplica la entrega');
select is(pg_temp.eventos('entrega_pendiente_restituida_por_anulacion', 'd5'), 1, 'ni el evento');
-- Tocar una devolución ya anulada (otra columna, otra hora) no hace nada.
update public.devolucion set deleted_at = now() + interval '1 minute' where id = pg_temp.u('d5');
select is(pg_temp.pend('76'), '1/3', 'cambiarle la hora a una anulada no mueve nada');

-- ---------------------------------------------------------------------------
-- 7. Sin nada que restituir
-- ---------------------------------------------------------------------------
-- Venta 77: sin ninguna fila de entrega. La devolución entra y su anulación también, sin crear nada.
select is(pg_temp.dev('d6', '77', '11', 2, '87'), 'ok', 'venta sin entregas: la devolución entra');
select pg_temp.anular('d6');
select is((select count(*)::int from public.entrega where venta_id = pg_temp.u('77')), 0, 'anularla no inventa una entrega');
select is(pg_temp.eventos('entrega_pendiente_restituida_por_anulacion', 'd6'), 0, 'ni deja evento');

-- Una devolución anterior a 0153: su evento de «quitada» no dice de qué entrega (sin entrega_id). No hay de dónde
-- restituir: se saltea, la anulación entra igual.
select is(pg_temp.dev('d8', '79', '11', 2, '89'), 'ok', 'devolución sobre la venta 79');
select auditoria.registrar('entrega_pendiente_quitada_por_devolucion', 'devolucion', pg_temp.u('d8'), pg_temp.u('b1'),
                           jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 2));
select pg_temp.anular('d8');
select is((select count(*)::int from public.entrega where venta_id = pg_temp.u('79')), 0,
          'un evento viejo sin entrega_id se saltea: no se crea nada');
select is(pg_temp.eventos('entrega_pendiente_restituida_por_anulacion', 'd8'), 0, 'y no deja evento de restitución');

-- ---------------------------------------------------------------------------
-- 8. Por sync.push: registrar la devolución y anularla después
-- ---------------------------------------------------------------------------
-- Venta 80: entregó 1 y quedan 2 pendientes. La devolución de los 3 sube por el push; la anulación, también.
update public.stock set cantidad_disponible = 10 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('11');
select is(pg_temp.push(pg_temp.u('b1'), 'ee', 'devolucion', 'insert',
            jsonb_build_object('id', pg_temp.u('d9'), 'venta_id', pg_temp.u('80'),
                               'productos_devueltos', jsonb_build_array(pg_temp.el('11', 3, '90')),
                               'dinero_retenido', 0, 'fecha_devolucion', '2026-10-05T12:00:00Z')) ->> 'outcome',
          'accepted', 'el push de la devolución de los 3: accepted');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('80'), '11 · 0/0', 'vuelve 1 al stock y la pendiente de 2 sale');
select is(pg_temp.push(pg_temp.u('b1'), 'ef', 'devolucion', 'update',
            jsonb_build_object('id', pg_temp.u('d9'), 'deleted_at', now()),
            (select d.sync_version from public.devolucion d where d.id = pg_temp.u('d9'))) ->> 'outcome',
          'accepted', 'el push que anula la devolución: accepted');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('80'), '10 · 1/2',
          'el stock se resta y la entrega pendiente vuelve, en la misma transacción');
select is((select (e.deleted_at is null and e.pendiente and e.cantidad = 2)::text from public.entrega e where e.id = pg_temp.u('f5')),
          'true', 'es la misma entrega (f5), con su cantidad');
-- El reintento del push de anulación no restituye de más.
select is(pg_temp.push(pg_temp.u('b1'), 'ef', 'devolucion', 'update',
            jsonb_build_object('id', pg_temp.u('d9'), 'deleted_at', now())) ->> 'outcome',
          'duplicate', 'el mismo envío otra vez: duplicate');
select is(pg_temp.stock('b1', '11') || ' · ' || pg_temp.pend('80'), '10 · 1/2', 'y no se mueve nada más');

select * from finish();
rollback;
