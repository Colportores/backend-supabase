-- pgTAP · 0136 (backend-supabase#201, decisiones «Devol. combo», «Motivo devol.» y «Devol. stock» del 27/10):
--   1. devolucion_renglones_validos(): tres claves por elemento (libro, cantidad, renglón), sin repetir el par.
--   2. El trigger BEFORE: el renglón existe, es de la venta y el libro es el suyo o un componente del combo.
--   3. El motivo: opcional, acotado a 500, sin espacios en los bordes; viaja por el push y NO se copia a audit_log.
--   4. Los libros devueltos vuelven al stock del colportor (un movimiento ENTRADA_DEVOLUCION por libro), una sola
--      vez; la devolución que llega anulada no suma; anularla después no resta (pendiente de decisión).
--   5. Por sync.push: la forma vieja (dos claves) es invalid, el reintento no suma dos veces.
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
  select ('01920000-0000-7000-8000-0000000136' || p)::uuid;
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
                            'dinero_retenido', 0, 'fecha_devolucion', '2026-10-05T12:00:00Z');
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Colportores b1 y b2. Libros 11, 12, 13 y 14. Un combo (colección d0: 11 × 1 y 13 × 2).
-- Venta 71 de b1 con los renglones: 81 (11 × 3), 82 (12 × 3), 83 (combo × 2), 85 (11 × 2, el mismo libro aparte).
-- Venta 72 de b2 con el renglón 84 (11 × 3).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev136-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 t136', 'LIBRO'), (pg_temp.u('12'), 'Libro 2 t136', 'LIBRO'),
  (pg_temp.u('13'), 'Revista 3 t136', 'REVISTA'), (pg_temp.u('14'), 'Libro 4 t136', 'LIBRO');
insert into public.coleccion (id, nombre) values (pg_temp.u('d0'), 'Pack t136');
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  (pg_temp.u('a1'), pg_temp.u('11'), pg_temp.u('d0'), 1), (pg_temp.u('a2'), pg_temp.u('13'), pg_temp.u('d0'), 2);
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev136', 'ZT');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev136', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e1'), pg_temp.u('01'), pg_temp.u('b1')), (pg_temp.u('e2'), pg_temp.u('02'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e1'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e2'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-13671', 450000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-13672', 260000, '2026-10-01 16:00:00+00', pg_temp.u('b2'), pg_temp.u('b2'));
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 3, 100000, 300000),
  (pg_temp.u('82'), pg_temp.u('71'), pg_temp.u('12'), 3, 50000, 150000),
  (pg_temp.u('85'), pg_temp.u('71'), pg_temp.u('11'), 2, 100000, 200000),
  (pg_temp.u('84'), pg_temp.u('72'), pg_temp.u('11'), 3, 100000, 300000);
insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes) values
  (pg_temp.u('83'), pg_temp.u('71'), pg_temp.u('d0'), 2, 110000, 220000,
   jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1),
                     jsonb_build_object('producto_id', pg_temp.u('13'), 'cantidad', 2)));
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('11'), 10), (pg_temp.u('b1'), pg_temp.u('12'), 0);

-- ---------------------------------------------------------------------------
-- 1. La forma del JSON
-- ---------------------------------------------------------------------------
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81'))), true, 'un libro, un renglón');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81'), pg_temp.el('12', 2, '82'))), true,
          'dos libros de dos renglones');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81'), pg_temp.el('11', 2, '85'))), true,
          'el mismo libro en dos renglones distintos: dos elementos');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81'), pg_temp.el('11', 2, '81'))), false,
          'el mismo par (libro, renglón) dos veces no');
select is(public.devolucion_renglones_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1))),
          false, 'la forma vieja, sin renglón, ya no vale');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81') || jsonb_build_object('precio', 5))),
          false, 'con una clave de más no');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 0, '81'))), false, 'cantidad 0 no');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', -1, '81'))), false, 'cantidad negativa no');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81') || jsonb_build_object('cantidad', 1.5))),
          false, 'cantidad con decimales no');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81') || jsonb_build_object('cantidad', '1'))),
          false, 'cantidad como texto no');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81') || jsonb_build_object('venta_item_id', 'x'))),
          false, 'un renglón que no es uuid: false, no una excepción');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81') || jsonb_build_object('venta_item_id', 7))),
          false, 'ni un número');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81') || jsonb_build_object('producto_id', 'no'))),
          false, 'ni un libro que no es uuid');
select is(public.devolucion_renglones_validos('[]'::jsonb), false, 'vacío no');
select is(public.devolucion_renglones_validos(null), false, 'null no');
select is(public.devolucion_renglones_validos('{}'::jsonb), false, 'un objeto no');
select is(public.devolucion_renglones_validos('[1]'::jsonb), false, 'un arreglo de números no');
select is(public.devolucion_renglones_validos(jsonb_build_array(pg_temp.el('11', 1, '81'), 'x')), false, 'uno bueno y uno malo no');
select is((select has_function_privilege('anon', 'public.devolucion_renglones_validos(jsonb)', 'execute')), false, 'anon no la ejecuta');
select is((select has_function_privilege('authenticated', 'public.devolucion_renglones_validos(jsonb)', 'execute')), true,
          'authenticated sí (la llama un CHECK)');

-- ---------------------------------------------------------------------------
-- 2. El renglón y el libro
-- ---------------------------------------------------------------------------
select is(pg_temp.ins('d1', '71', jsonb_build_array(pg_temp.el('11', 2, '81'))), 'ok', 'un libro de su renglón: ok');
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('11', 1, '8f'))), '23503 devolucion_renglon_existe',
          'un renglón que no existe: 23503');
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('11', 1, '84'))), '23514 devolucion_renglon_de_la_venta',
          'un renglón de otra venta: 23514');
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('12', 1, '81'))), '23514 devolucion_libro_del_renglon',
          'un libro que no es del renglón: 23514');
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('9f', 1, '81'))), '23503 devolucion_producto_existe',
          'un libro que no existe: 23503');
select is(pg_temp.ins('d3', '71', jsonb_build_array(pg_temp.el('13', 2, '83'))), 'ok',
          'un componente del combo (la revista) con el renglón del combo: ok');
select is(pg_temp.ins('d4', '71', jsonb_build_array(pg_temp.el('11', 1, '83'), pg_temp.el('13', 1, '83'))), 'ok',
          'dos componentes del mismo combo, cada uno por su cuenta (Devol. combo: por renglón)');
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('12', 1, '83'))), '23514 devolucion_libro_del_renglon',
          'un libro que no es del combo, con el renglón del combo: 23514');
select is(pg_temp.ins('d5', '71', jsonb_build_array(pg_temp.el('11', 1, '81'), pg_temp.el('11', 1, '85'))), 'ok',
          'el mismo libro de dos renglones de la misma venta: ok');
select is(pg_temp.ins('d2', '71', jsonb_build_array(pg_temp.el('11', 1, '81'), pg_temp.el('11', 2, '81'))), '23514 devolucion_productos_validos',
          'el mismo par dos veces: lo frena el CHECK');
select is(pg_temp.error_de(format($$ update public.devolucion set productos_devueltos = %L::jsonb where id = %L $$,
                                  jsonb_build_array(pg_temp.el('12', 1, '82'))::text, pg_temp.u('d1'))), 'ok',
          'cambiar los libros revalida (y estos están bien)');
select is(pg_temp.error_de(format($$ update public.devolucion set productos_devueltos = %L::jsonb where id = %L $$,
                                  jsonb_build_array(pg_temp.el('12', 1, '81'))::text, pg_temp.u('d1'))), '23514 devolucion_libro_del_renglon',
          'cambiar los libros por uno que no es del renglón: 23514');
select is(pg_temp.error_de(format($$ update public.devolucion set venta_id = %L where id = %L $$, pg_temp.u('72'), pg_temp.u('d1'))),
          '23514 devolucion_renglon_de_la_venta', 'pasarla a otra venta con los mismos renglones: 23514');

-- ---------------------------------------------------------------------------
-- 3. El motivo
-- ---------------------------------------------------------------------------
select is((select data_type from information_schema.columns where table_name = 'devolucion' and column_name = 'motivo'),
          'text', 'devolucion.motivo es texto');
select is((select is_nullable from information_schema.columns where table_name = 'devolucion' and column_name = 'motivo'),
          'YES', 'y opcional');
select is(pg_temp.ins('e1', '71', jsonb_build_array(pg_temp.el('12', 1, '82')), 'Se rompió el lomo'), 'ok', 'con motivo: ok');
select is(pg_temp.ins('e2', '71', jsonb_build_array(pg_temp.el('12', 1, '82')), repeat('x', 500)), 'ok', 'de 500 caracteres: ok');
select is(pg_temp.ins('e3', '71', jsonb_build_array(pg_temp.el('12', 1, '82')), repeat('x', 501)), '23514 devolucion_motivo_forma',
          'de 501: 23514');
select is(pg_temp.ins('e3', '71', jsonb_build_array(pg_temp.el('12', 1, '82')), '   '), '23514 devolucion_motivo_forma',
          'en blanco: 23514');
select is(pg_temp.ins('e3', '71', jsonb_build_array(pg_temp.el('12', 1, '82')), ' con espacio'), '23514 devolucion_motivo_forma',
          'con espacio al principio: 23514');
select is(pg_temp.ins('e3', '71', jsonb_build_array(pg_temp.el('12', 1, '82')), 'con espacio '), '23514 devolucion_motivo_forma',
          'o al final: 23514');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'devolucion_registrada' and a.fila_id = pg_temp.u('e1')
              and a.metadata::text like '%lomo%'), 0, 'el motivo no se copia a audit_log');
select is((select (a.metadata ? 'motivo') from auditoria.audit_log a
            where a.event_type = 'devolucion_registrada' and a.fila_id = pg_temp.u('e1') limit 1), false,
          'ni como clave');

-- ---------------------------------------------------------------------------
-- 4. Los libros vuelven al stock
-- ---------------------------------------------------------------------------
-- Se parte de cero (sin devoluciones, con el stock del 11 en 10) para no depender de lo de arriba.
delete from public.movimiento_stock where devolucion_id is not null;
delete from public.devolucion;
update public.stock set cantidad_disponible = 10 where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('11');
delete from public.stock where usuario_id = pg_temp.u('b1') and producto_id <> pg_temp.u('11');

select is(pg_temp.ins('f1', '71', jsonb_build_array(pg_temp.el('11', 2, '81'), pg_temp.el('12', 1, '82'))), 'ok',
          'una devolución de 2 del libro 11 y 1 del 12');
select is(pg_temp.stock('11') || '/' || pg_temp.stock('12'), '12/1', 'el 11 sube 2 y el 12, que no tenía fila, queda en 1');
select is(pg_temp.entradas('f1') || '/' || pg_temp.movs('f1'), '3/2', 'con un movimiento ENTRADA_DEVOLUCION por libro (3 unidades)');
select is((select min(m.fecha) from public.movimiento_stock m where m.devolucion_id = pg_temp.u('f1')),
          '2026-10-05 12:00+00'::timestamptz, 'fechado el día de la devolución');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_devolucion' and a.fila_id = pg_temp.u('f1')), 2,
          'y un evento stock_devuelto_por_devolucion por libro');
select is((select array(select k from jsonb_object_keys(a.metadata) k order by k) from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_devolucion' and a.fila_id = pg_temp.u('f1') limit 1),
          array['cantidad','producto_id','stock_antes','stock_despues'], 'el evento lleva solo ids y números');

-- El mismo libro de dos renglones: una sola entrada con la suma.
select is(pg_temp.ins('f2', '71', jsonb_build_array(pg_temp.el('11', 1, '81'), pg_temp.el('11', 2, '85'))), 'ok', 'el 11 de dos renglones');
select is(pg_temp.stock('11') || '/' || pg_temp.entradas('f2') || '/' || pg_temp.movs('f2'), '15/3/1',
          'el stock sube 3 con un solo movimiento');
-- Un componente de combo vuelve como libro suelto.
select is(pg_temp.ins('f3', '71', jsonb_build_array(pg_temp.el('13', 2, '83'))), 'ok', 'la revista de un combo');
select is(pg_temp.stock('13') || '/' || pg_temp.entradas('f3'), '2/2', 'entra a su stock como cualquier libro');

-- No descuenta nada más: modificar la devolución no mueve el stock.
update public.devolucion set dinero_retenido = 100 where id = pg_temp.u('f1');
update public.devolucion set productos_devueltos = jsonb_build_array(pg_temp.el('11', 1, '81')) where id = pg_temp.u('f1');
select is(pg_temp.stock('11') || '/' || pg_temp.stock('12') || '/' || pg_temp.movs('f1'), '15/1/2',
          'modificarla después no mueve el stock (ni suma ni resta)');
-- Anularla: no resta (pendiente de decisión).
update public.devolucion set deleted_at = now() where id = pg_temp.u('f2');
select is(pg_temp.stock('11') || '/' || pg_temp.entradas('f2'), '15/3', 'anularla no resta el stock (queda como pendiente de decisión)');

-- Llega anulada: no suma.
insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id, deleted_at)
values (pg_temp.u('f4'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81')), now(), pg_temp.u('b1'), now());
select is(pg_temp.stock('11') || '/' || pg_temp.movs('f4'), '15/0', 'una devolución que llega anulada no suma');

-- Un stock dado de baja se reactiva.
update public.stock set deleted_at = now() where usuario_id = pg_temp.u('b1') and producto_id = pg_temp.u('12');
select is(pg_temp.ins('f5', '71', jsonb_build_array(pg_temp.el('12', 2, '82'))), 'ok', 'devolver un libro cuyo stock está de baja');
select is((select (s.cantidad_disponible, s.deleted_at is null)::text from public.stock s
            where s.usuario_id = pg_temp.u('b1') and s.producto_id = pg_temp.u('12')), '(2,t)', 'cuenta como cero y se reactiva');

-- ---------------------------------------------------------------------------
-- 5. Por sync.push
-- ---------------------------------------------------------------------------
delete from public.movimiento_stock where devolucion_id is not null;
delete from public.devolucion;
delete from public.stock where usuario_id = pg_temp.u('b1');
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values (pg_temp.u('b1'), pg_temp.u('11'), 10);

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.u('c1'), 'insert',
            pg_temp.dev(pg_temp.u('91'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 2, '81')))
              || jsonb_build_object('motivo', 'Lo devolvió')) ->> 'outcome', 'accepted', 'el push acepta la forma nueva con motivo');
select is(pg_temp.push1(pg_temp.u('c2'), 'insert',
            pg_temp.dev(pg_temp.u('92'), pg_temp.u('71'), jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1)))) ->> 'code',
          '23514', 'la forma vieja (dos claves) vuelve invalid 23514');
select is(pg_temp.push1(pg_temp.u('c3'), 'insert',
            pg_temp.dev(pg_temp.u('93'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '84')))) ->> 'code',
          '23514', 'un renglón de otra venta: invalid 23514');
select is(pg_temp.push1(pg_temp.u('c4'), 'insert',
            pg_temp.dev(pg_temp.u('94'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 1, '81'))) || jsonb_build_object('motivo', repeat('x', 501))) ->> 'code',
          '23514', 'un motivo de 501: invalid 23514');
select is(pg_temp.push1(pg_temp.u('c5'), 'insert',
            pg_temp.dev(pg_temp.u('95'), pg_temp.u('72'), jsonb_build_array(pg_temp.el('11', 1, '84')))) ->> 'code',
          '42501', 'la venta de otro colportor: invalid 42501 (la política, con un renglón que sí es de esa venta)');
-- El reintento (mismo client_op_id y mismo id con otro) no suma dos veces.
select is(pg_temp.push1(pg_temp.u('c1'), 'insert',
            pg_temp.dev(pg_temp.u('91'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 2, '81')))) ->> 'outcome', 'duplicate',
          'el mismo client_op_id: duplicate');
select is(pg_temp.push1(pg_temp.u('c6'), 'insert',
            pg_temp.dev(pg_temp.u('91'), pg_temp.u('71'), jsonb_build_array(pg_temp.el('11', 2, '81')))) ->> 'outcome', 'duplicate',
          'y el mismo id con otro client_op_id (reinstalar y reintentar): duplicate');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('11') || '/' || pg_temp.entradas('91') || '/' || pg_temp.movs('91'), '12/2/1',
          'el stock subió una sola vez (10 + 2) y con un solo movimiento');
select is((select motivo from public.devolucion where id = pg_temp.u('91')), 'Lo devolvió', 'y el motivo quedó guardado');
select is((select count(*)::int from auditoria.audit_log a
            where a.event_type = 'stock_devuelto_por_devolucion' and a.fila_id = pg_temp.u('91')), 1, 'con un solo evento');
select is((select count(*)::int from public.devolucion where id in (pg_temp.u('92'), pg_temp.u('93'), pg_temp.u('94'), pg_temp.u('95'))), 0,
          'lo rechazado no deja devolución ni stock');

select * from finish();
rollback;
