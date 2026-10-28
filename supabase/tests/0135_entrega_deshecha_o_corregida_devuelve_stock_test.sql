-- pgTAP · 0135 (backend-supabase#201, decisión «Entrega desh» del 27/10, seguimiento de 0118): una entrega que se
-- anula, vuelve a pendiente, cambia de libro o baja de cantidad devuelve el stock con su movimiento; una vez
-- vuelta a entregar descuenta otra vez. Cubre:
--   1. La forma: los tipos nuevos, la columna devolucion_id, el origen único, la función interna.
--   2. Anular, anular otra vez (idempotente), restaurar, bajar y subir la cantidad, volver a pendiente.
--   3. Cambio de libro: el viejo recupera y el nuevo descuenta (y marca si no alcanza).
--   4. El tope: una entrega de antes de la 0118 (sin salida en el historial) no devuelve lo que nunca descontó;
--      nunca se devuelve más de lo descontado.
--   5. Lo que no se toca: el stock de otro colportor, el combo, el stock negativo.
--   6. La auditoría: stock_devuelto_por_entrega, sin texto libre.
begin;
select * from no_plan();

-- --- helpers -------------------------------------------------------------------
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000135' || p)::uuid;
$$;
create or replace function pg_temp.stock(p_quien text, p_producto text) returns text language sql as $$
  select coalesce((select s.cantidad_disponible::text from public.stock s
                    where s.usuario_id = pg_temp.u(p_quien) and s.producto_id = pg_temp.u(p_producto)), 'sin fila');
$$;
-- salidas/anuladas/corregidas de una entrega, como texto «S/A/C» (unidades).
create or replace function pg_temp.movs(p_entrega text) returns text language sql as $$
  select coalesce(sum(m.cantidad) filter (where m.tipo = 'SALIDA_ENTREGA'), 0) || '/' ||
         coalesce(sum(m.cantidad) filter (where m.tipo = 'ENTRADA_ENTREGA_ANULADA'), 0) || '/' ||
         coalesce(sum(m.cantidad) filter (where m.tipo = 'ENTRADA_ENTREGA_CORREGIDA'), 0)
    from public.movimiento_stock m where m.entrega_id = pg_temp.u(p_entrega);
$$;
create or replace function pg_temp.marca(p_entrega text) returns boolean language sql as $$
  select stock_inconsistente from public.entrega where id = pg_temp.u(p_entrega);
$$;
create or replace function pg_temp.devueltos_ev(p_entrega text) returns integer language sql as $$
  select count(*)::int from auditoria.audit_log a
   where a.event_type = 'stock_devuelto_por_entrega' and a.fila_id = pg_temp.u(p_entrega);
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.ent(p_id text, p_venta text, p_producto text, p_cantidad integer,
                                       p_pendiente boolean default false)
returns void language sql as $$
  insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, fecha_entrega)
  values (pg_temp.u(p_id), pg_temp.u(p_venta), pg_temp.u(p_producto), p_cantidad, p_pendiente,
          case when p_pendiente then null else now() end);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 colportores. Ventas 51 (b1) y 53 (b2). Libros d1, d2 y d3. Stock de b1: d1 = 10, d2 = 2; b2: d1 = 7.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'entrega135-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais entrega 135', 'ZC');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad entrega 135', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
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
  from (values ('51', '21', 'b1'), ('53', '22', 'b2')) x(v, ep, quien);
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('d1'), 'Libro A', 'LIBRO'), (pg_temp.u('d2'), 'Libro B', 'LIBRO'), (pg_temp.u('d3'), 'Libro C', 'LIBRO');
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('d1'), 10), (pg_temp.u('b1'), pg_temp.u('d2'), 2), (pg_temp.u('b2'), pg_temp.u('d1'), 7);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'movimiento_stock', 'devolucion_id', 'uuid', 'movimiento_stock.devolucion_id es uuid');
select fk_ok('public', 'movimiento_stock', 'devolucion_id', 'public', 'devolucion', 'id', 'y cuelga de la devolución');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.movimiento_stock'::regclass and conname = 'movimiento_stock_tipo_check')
          ~ 'ENTRADA_ENTREGA_ANULADA.*ENTRADA_ENTREGA_CORREGIDA.*ENTRADA_DEVOLUCION', true,
          'el CHECK de tipos trae los tres de entrada nuevos');
select hasnt_index('public', 'movimiento_stock', 'movimiento_stock_salida_entrega_key', 'ya no hay un índice único de la salida');
select is((select has_function_privilege('authenticated', 'public.mover_stock_de_entrega(uuid,uuid,uuid,integer,boolean,timestamptz,boolean)', 'execute')),
          false, 'nadie con JWT llama a la función que mueve el stock');
select is((select prosecdef from pg_proc where oid = 'public.mover_stock_de_entrega(uuid,uuid,uuid,integer,boolean,timestamptz,boolean)'::regprocedure),
          true, 'es SECURITY DEFINER (el push corre como authenticated y no escribe stock)');

-- ---------------------------------------------------------------------------
-- 2. Anular, restaurar, corregir, volver a pendiente
-- ---------------------------------------------------------------------------
select pg_temp.ent('60', '51', 'd1', 4);
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '6/4/0/0', 'entregada: descuenta 4');

update public.entrega set deleted_at = now() where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '10/4/4/0', 'anulada: el stock vuelve (10) con su movimiento');
select is(pg_temp.devueltos_ev('60'), 1, 'y deja un evento stock_devuelto_por_entrega');

-- Idempotente: anularla otra vez (un replay, otro UPDATE) no devuelve dos veces.
update public.entrega set deleted_at = now() + interval '1 second' where id = pg_temp.u('60');
update public.entrega set fecha_prevista = now() where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '10/4/4/0', 'anularla otra vez no devuelve de más');
select is(pg_temp.devueltos_ev('60'), 1, 'ni suma otro evento');

-- Restaurada vuelve a descontar.
update public.entrega set deleted_at = null where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '6/8/4/0', 'restaurada: vuelve a descontar (6)');

-- Corregir la cantidad a la baja devuelve la diferencia; a la suba descuenta la diferencia.
update public.entrega set cantidad = 3 where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '7/8/4/1', 'de 4 a 3: vuelve 1 (corregida)');
update public.entrega set cantidad = 5 where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '5/10/4/1', 'de 3 a 5: descuenta 2 más');
update public.entrega set cantidad = 5, fecha_prevista = now() where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '5/10/4/1', 'cambiar otra columna no mueve nada');

-- Vuelve a pendiente: devuelve todo lo que seguía descontado (5).
update public.entrega set pendiente = true where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '10/10/9/1', 'vuelta a pendiente: devuelve las 5 que seguían descontadas');
select is(pg_temp.marca('60'), false, 'y ya no está marcada');
-- Pendiente otra vez no devuelve de más.
update public.entrega set pendiente = true, fecha_prevista = now() + interval '1 day' where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1'), '10', 'pendiente de nuevo: nada de más');
-- Y se entrega otra vez: descuenta.
update public.entrega set pendiente = false, fecha_entrega = now() where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('60'), '5/15/9/1', 'entregada otra vez: descuenta las 5');

-- El neto del historial de la entrega es lo que sigue descontado: 15 - 9 - 1 = 5.
select is((select sum(case when m.tipo = 'SALIDA_ENTREGA' then m.cantidad else -m.cantidad end)::int
             from public.movimiento_stock m where m.entrega_id = pg_temp.u('60')), 5,
          'el neto del historial es lo que sigue descontado (5)');

-- ---------------------------------------------------------------------------
-- 3. Cambio de libro
-- ---------------------------------------------------------------------------
update public.entrega set producto_id = pg_temp.u('d2') where id = pg_temp.u('60');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.stock('b1', 'd2'), '10/-3',
          'cambia de libro: el viejo recupera sus 5 y el nuevo descuenta (2 - 5 = -3)');
select is(pg_temp.marca('60'), true, 'y se marca: el libro nuevo no tenía stock (S46)');
select is((select count(*)::int from public.movimiento_stock m
            where m.entrega_id = pg_temp.u('60') and m.producto_id = pg_temp.u('d2') and m.tipo = 'SALIDA_ENTREGA'), 1,
          'con la salida del libro nuevo');

-- ---------------------------------------------------------------------------
-- 4. El tope: lo que el historial no descontó no se devuelve
-- ---------------------------------------------------------------------------
-- Una entrega anterior a la 0118: entregada sin pasar por los triggers (sin salida en el historial).
alter table public.entrega disable trigger entrega_descuenta_stock;
alter table public.entrega disable trigger entrega_stock_inconsistente;
select pg_temp.ent('61', '51', 'd1', 3);
alter table public.entrega enable trigger entrega_descuenta_stock;
alter table public.entrega enable trigger entrega_stock_inconsistente;
select is(pg_temp.stock('b1', 'd1'), '10', 'la entrega vieja no tocó el stock');
update public.entrega set deleted_at = now() where id = pg_temp.u('61');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('61'), '10/0/0/0',
          'anularla no devuelve lo que nunca descontó (no hay salida en el historial)');
select is(pg_temp.devueltos_ev('61'), 0, 'ni deja evento');
-- Restaurada: pasa a "entregada" sin lo que la 0118 llama agregar... descuenta una vez (su diferencia es 3).
update public.entrega set deleted_at = null where id = pg_temp.u('61');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('61'), '7/3/0/0', 'restaurada: descuenta una vez');
update public.entrega set deleted_at = now() where id = pg_temp.u('61');
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('61'), '10/3/3/0', 'y vuelve a anularse: devuelve esa vez');

-- ---------------------------------------------------------------------------
-- 5. Lo que no se toca
-- ---------------------------------------------------------------------------
select is(pg_temp.stock('b2', 'd1'), '7', 'el stock de b2 no cambió con nada de esto');
select pg_temp.ent('62', '53', 'd1', 2);
update public.entrega set deleted_at = now() where id = pg_temp.u('62');
select is(pg_temp.stock('b2', 'd1') || '/' || pg_temp.stock('b1', 'd1'), '7/10', 'anular la de b2 devuelve a b2 y no a b1');

-- Una entrega que llega de baja no descuenta ni, al restaurarse, devuelve nada.
select pg_temp.ent('63', '51', 'd1', 2);
insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, fecha_entrega, deleted_at)
values (pg_temp.u('64'), pg_temp.u('51'), pg_temp.u('d1'), 9, false, now(), now());
select is(pg_temp.stock('b1', 'd1') || '/' || pg_temp.movs('64'), '8/0/0/0', 'una entrega que llega anulada no mueve el stock');

-- El stock dado de baja se reactiva al devolver.
update public.stock set deleted_at = now() where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('d1');
update public.entrega set deleted_at = now() where id = pg_temp.u('63');
select is((select (s.cantidad_disponible, s.deleted_at is null)::text from public.stock s
            where s.usuario_id = pg_temp.u('b1') and s.producto_id = pg_temp.u('d1')),
          '(2,t)', 'una fila de stock dada de baja cuenta como cero y se reactiva con lo devuelto (2)');

-- ---------------------------------------------------------------------------
-- 6. Auditoría
-- ---------------------------------------------------------------------------
select is((select array(select k from jsonb_object_keys(a.metadata) k order by k) from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_entrega' and a.fila_id = pg_temp.u('63') limit 1),
          array['cantidad','motivo','producto_id','stock_antes','stock_despues'],
          'el evento lleva solo ids y números, y el motivo de un conjunto cerrado');
select is((select a.metadata ->> 'motivo' from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_entrega' and a.fila_id = pg_temp.u('63') limit 1), 'anulada',
          'el motivo de una anulación es «anulada»');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_entrega' and a.fila_id = pg_temp.u('60')
              and a.metadata ->> 'motivo' = 'anulada'), 2, 'la 60 devolvió por anulación dos veces (anulada y vuelta a pendiente)');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_entrega' and a.fila_id = pg_temp.u('60')
              and a.metadata ->> 'motivo' = 'corregida'), 2, 'y por corrección dos (de 4 a 3 y el cambio de libro: el viejo recupera)');
select ok((select bool_and(auditoria.metadata_sin_datos_personales(a.metadata)) from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_entrega'), 'ningún evento tiene datos personales');

select * from finish();
rollback;
