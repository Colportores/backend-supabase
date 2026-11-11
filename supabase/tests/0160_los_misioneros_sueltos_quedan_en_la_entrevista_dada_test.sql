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
  select ('01920000-0000-7000-8000-0000000160' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
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
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000160d0',
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
create or replace function pg_temp.payload_venta(p_id text, p_talonario text, p_total integer, p_motivo text default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('id', pg_temp.u(p_id), 'espacio_persona_id', pg_temp.u('ca'),
         'numero_talonario', p_talonario, 'monto_total', p_total, 'fecha', now(), 'motivo_monto_manual', p_motivo));
$$;
-- Un ítem de un solo libro (11): cantidad 1, así que el subtotal es el precio.
create or replace function pg_temp.payload_item(p_id text, p_venta text, p_subtotal integer)
returns jsonb language sql as $$
  select jsonb_build_object('id', pg_temp.u(p_id), 'venta_id', pg_temp.u(p_venta), 'producto_id', pg_temp.u('11'),
                            'cantidad', 1, 'precio_unitario', p_subtotal, 'subtotal', p_subtotal);
$$;
-- Una venta como postgres (sin ítems) y, aparte, un ítem. Devuelven el SQLSTATE o 'ok'.
create or replace function pg_temp.venta(p_id text, p_talonario text, p_total integer, p_motivo text default null)
returns text language plpgsql as $$
begin
  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, motivo_monto_manual)
  values (pg_temp.u(p_id), pg_temp.u('ca'), p_talonario, p_total, now(), pg_temp.u('b1'), p_motivo);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.item(p_id text, p_venta text, p_subtotal integer, p_baja boolean default false)
returns text language plpgsql as $$
begin
  insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, deleted_at)
  values (pg_temp.u(p_id), pg_temp.u(p_venta), pg_temp.u('11'), 1, p_subtotal, p_subtotal,
          case when p_baja then now() end);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 es colportor inscripto en la campaña e1; b2, otro colportor.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 't0160-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais t0160', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 t0160', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 t0160', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t0160', 'LIBRO');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));


-- Productos misioneros (tipo MISIONERO -> categoria MISIONEROS) y un stock inicial de b1.
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('21'), 'Misionero 1 t0160', 'MISIONERO'),
  (pg_temp.u('22'), 'Misionero 2 t0160', 'MISIONERO'),
  (pg_temp.u('23'), 'Misionero 3 t0160', 'MISIONERO');
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('21'), 10);
-- Dos visitas de b1 y una de b2 (ENTREVISTA, sin persona, en la casa c9).
insert into public.visita (id, espacio_id, fecha, tipo_resultado, colportor_id) values
  (pg_temp.u('a1'), pg_temp.u('c9'), now(), 'ENTREVISTA', pg_temp.u('b1')),
  (pg_temp.u('a2'), pg_temp.u('c9'), now(), 'ENTREVISTA', pg_temp.u('b1')),
  (pg_temp.u('a3'), pg_temp.u('c9'), now(), 'ENTREVISTA', pg_temp.u('b2'));

create or replace function pg_temp.mis(p_id text, p_visita text, p_prod text, p_cant int, p_dueno text default 'b1')
returns text language plpgsql as $$
begin
  insert into public.visita_misionero (id, visita_id, producto_id, cantidad, colportor_id)
  values (pg_temp.u(p_id), pg_temp.u(p_visita), pg_temp.u(p_prod), p_cant, pg_temp.u(p_dueno));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.stock(p_prod text, p_uid text default 'b1') returns integer language sql as $$
  select coalesce((select s.cantidad_disponible from public.stock s
                    where s.usuario_id = pg_temp.u(p_uid) and s.producto_id = pg_temp.u(p_prod)), 0);
$$;
create or replace function pg_temp.movs(p_renglon text) returns text language sql as $$
  select coalesce(string_agg(m.tipo || ':' || m.cantidad, ',' order by m.id), '-')
    from public.movimiento_stock m where m.visita_misionero_id = pg_temp.u(p_renglon);
$$;

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select has_table('public', 'visita_misionero', 'existe visita_misionero');
select has_column('public', 'movimiento_stock', 'visita_misionero_id', 'movimiento_stock tiene el origen nuevo');
select is((select relrowsecurity from pg_class where oid = 'public.visita_misionero'::regclass), true, 'con RLS');
select is((select count(*)::int from pg_policies where tablename = 'visita_misionero'), 3, 'tres políticas: select, insert, update');
select is(has_table_privilege('authenticated', 'public.visita_misionero', 'delete'), false, 'sin DELETE');
select is(has_table_privilege('anon', 'public.visita_misionero', 'select'), false, 'anon no lee');
select is((select permite_push from sync.entidad where nombre = 'visita_misionero'), true, 'entidad de push registrada');
select is((select columna_duenio from sync.entidad where nombre = 'visita_misionero'), 'colportor_id', 'con su dueña');
select ok(not ('colportor_id' = any (sync.columnas_escribibles('visita_misionero'))), 'colportor_id no se escribe desde el payload');
select ok('cantidad' = any (sync.columnas_escribibles('visita_misionero')), 'cantidad sí');
select ok('visita_id' = any (sync.columnas_escribibles('visita_misionero')), 'visita_id sí');
select ok(not ('visita_misionero_id' = any (sync.columnas_escribibles('movimiento_stock'))), 'el teléfono no manda el origen del movimiento');
select is(has_function_privilege('authenticated', 'public.mover_stock_de_misionero(uuid, uuid, uuid, integer, timestamptz)', 'execute'), false,
          'mover_stock_de_misionero no es ejecutable por authenticated');
select is(has_function_privilege('authenticated', 'public.tg_visita_misionero_mueve_el_stock()', 'execute'), false,
          'el trigger tampoco');

-- ---------------------------------------------------------------------------
-- 2. Un renglón descuenta del stock
-- ---------------------------------------------------------------------------
select is(pg_temp.mis('01', 'a1', '21', 3), 'ok', 'dejar 3 misioneros en la visita a1');
select is(pg_temp.stock('21'), 7, 'el stock baja de 10 a 7');
select is(pg_temp.movs('01'), 'SALIDA_MISIONERO:3', 'queda un SALIDA_MISIONERO de 3');
select is((select count(*)::int from auditoria.audit_log where event_type = 'stock_descontado_por_misionero' and fila_id = pg_temp.u('01')), 1,
          'y su evento en audit_log');
select is((select metadata ->> 'stock_despues' from auditoria.audit_log
            where event_type = 'stock_descontado_por_misionero' and fila_id = pg_temp.u('01')), '7', 'con el stock de después');
select is((select count(*)::int from public.venta where colportor_id = pg_temp.u('b1')), 0, 'no se creó ninguna venta');

-- Producto sin stock previo: queda en negativo (S46), sin rechazar.
select is(pg_temp.mis('02', 'a1', '22', 2), 'ok', 'dejar un misionero sin stock registrado entra');
select is(pg_temp.stock('22'), -2, 'el stock queda en -2');

-- ---------------------------------------------------------------------------
-- 3. Reglas
-- ---------------------------------------------------------------------------
select is(pg_temp.mis('03', 'a1', '11', 1), '23514', 'un libro común no se deja sin venta: 23514');
select is(pg_temp.mis('04', 'a2', '21', 0), '23514', 'cantidad 0: 23514');
select is(pg_temp.mis('05', 'a2', '21', -1), '23514', 'cantidad negativa: 23514');
select is(pg_temp.mis('06', 'a2', 'ff', 1), '23503', 'producto inexistente: 23503');
select is(pg_temp.mis('07', 'a1', '21', 1), '23505', 'el mismo producto dos veces en la visita: 23505');
select is(pg_temp.stock('21'), 7, 'y lo rechazado no movió el stock');
select is((select count(*)::int from public.movimiento_stock where visita_misionero_id is not null), 2, 'ni dejó movimientos');

-- ---------------------------------------------------------------------------
-- 4. Corregir y dar de baja devuelve
-- ---------------------------------------------------------------------------
update public.visita_misionero set cantidad = 5 where id = pg_temp.u('01');
select is(pg_temp.stock('21'), 5, 'subir de 3 a 5 descuenta 2 más');
select is(pg_temp.movs('01'), 'SALIDA_MISIONERO:3,SALIDA_MISIONERO:2', 'otra salida de 2');
update public.visita_misionero set cantidad = 4 where id = pg_temp.u('01');
select is(pg_temp.stock('21'), 6, 'bajar de 5 a 4 devuelve 1');
select ok(pg_temp.movs('01') like '%ENTRADA_MISIONERO_ANULADO:1%', 'con su entrada de 1');
update public.visita_misionero set deleted_at = now() where id = pg_temp.u('01');
select is(pg_temp.stock('21'), 10, 'dar de baja devuelve los 4 que quedaban: vuelve a 10');
update public.visita_misionero set deleted_at = now() where id = pg_temp.u('01');
select is(pg_temp.stock('21'), 10, 'dar de baja otra vez no devuelve de más');
select is((select sum(case when tipo = 'SALIDA_MISIONERO' then cantidad else -cantidad end)::int
             from public.movimiento_stock where visita_misionero_id = pg_temp.u('01')), 0, 'el historial del renglón netea a 0');
update public.visita_misionero set deleted_at = null where id = pg_temp.u('01');
select is(pg_temp.stock('21'), 6, 'reactivarlo vuelve a descontar 4');
select is(pg_temp.mis('08', 'a1', '21', 1), '23505', 'y ocupa de nuevo el lugar del producto en la visita');

-- Cambiar de producto: devuelve el anterior y descuenta el nuevo.
update public.visita_misionero set producto_id = pg_temp.u('23') where id = pg_temp.u('01');
select is(pg_temp.stock('21'), 10, 'cambiar de producto devuelve el anterior');
select is(pg_temp.stock('23'), -4, 'y descuenta el nuevo (-4)');
select is(pg_temp.error_de(format('update public.visita_misionero set producto_id = %L where id = %L', pg_temp.u('11'), pg_temp.u('01'))),
          '23514', 'cambiar a un libro común: 23514');

-- Un renglón que nace dado de baja no mueve nada.
select is(pg_temp.error_de(format('insert into public.visita_misionero (id, visita_id, producto_id, cantidad, colportor_id, deleted_at) values (%L, %L, %L, 2, %L, now())',
            pg_temp.u('09'), pg_temp.u('a2'), pg_temp.u('21'), pg_temp.u('b1'))), 'ok', 'un renglón que llega dado de baja entra');
select is(pg_temp.stock('21'), 10, 'sin mover el stock');
select is(pg_temp.movs('09'), '-', 'ni dejar movimientos');

-- Un movimiento tiene a lo sumo un origen.
select is(pg_temp.error_de(format('insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, visita_misionero_id, devolucion_id) values (%L, %L, %L, 1, %L, %L)',
            pg_temp.u('b1'), pg_temp.u('21'), 'SALIDA_MISIONERO', pg_temp.u('01'), pg_temp.u('d0'))), '23514', 'dos orígenes en un movimiento: 23514');

-- ---------------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.visita_misionero), 0, 'b2 no ve los renglones de b1');
select is(pg_temp.mis('10', 'a1', '21', 1, 'b2'), '42501', 'b2 no puede colgar un renglón de la visita de b1');
select is(pg_temp.mis('11', 'a3', '21', 1, 'b2'), 'ok', 'pero sí de la suya');
select is(pg_temp.error_de(format('update public.visita_misionero set visita_id = %L where id = %L', pg_temp.u('a1'), pg_temp.u('11'))), '42501',
          'mover un renglón a una visita ajena: 42501 (WITH CHECK)');
select is((select visita_id from public.visita_misionero where id = pg_temp.u('11')), pg_temp.u('a3'), 'y sigue en su visita');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.visita_misionero), 3, 'b1 ve los suyos (01, 02, 09) y no el de b2');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Por el push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('01', 'visita', jsonb_build_object('id', pg_temp.u('a5'), 'espacio_id', pg_temp.u('c9'), 'fecha', now(),
                                                  'tipo_resultado', 'ENTREVISTA')),
  pg_temp.job('02', 'visita_misionero', jsonb_build_object('id', pg_temp.u('50'), 'visita_id', pg_temp.u('a5'),
                                                            'producto_id', pg_temp.u('21'), 'cantidad', 2)))) as r;
grant select on r_push to authenticated;
select is(pg_temp.resultados((select r from r_push)), array['accepted', 'accepted'], 'la visita y su misionero suben');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('21'), 8, 'el stock bajó 2 (de 10 a 8)');
select is(pg_temp.movs('50'), 'SALIDA_MISIONERO:2', 'con su movimiento');
select is((select colportor_id from public.visita_misionero where id = pg_temp.u('50')), pg_temp.u('b1'), 'la dueña la puso el servidor');

-- Reintento del mismo lote: no descuenta otra vez.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push2 on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('02', 'visita_misionero', jsonb_build_object('id', pg_temp.u('50'), 'visita_id', pg_temp.u('a5'),
                                                            'producto_id', pg_temp.u('21'), 'cantidad', 2)))) as r;
grant select on r_push2 to authenticated;
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('21'), 8, 'el reintento no vuelve a descontar');
select is((select count(*)::int from public.movimiento_stock where visita_misionero_id = pg_temp.u('50')), 1, 'ni repite el movimiento');

-- Casos rechazados.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push3 on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('03', 'visita_misionero', jsonb_build_object('id', pg_temp.u('51'), 'visita_id', pg_temp.u('a5'),
                                                            'producto_id', pg_temp.u('11'), 'cantidad', 1)),
  pg_temp.job('04', 'visita_misionero', jsonb_build_object('id', pg_temp.u('52'), 'visita_id', pg_temp.u('a3'),
                                                            'producto_id', pg_temp.u('22'), 'cantidad', 1)),
  pg_temp.job('05', 'visita_misionero', jsonb_build_object('id', pg_temp.u('53'), 'visita_id', pg_temp.u('a5'),
                                                            'producto_id', pg_temp.u('22'), 'cantidad', 0)))) as r;
grant select on r_push3 to authenticated;
select is(pg_temp.resultados((select r from r_push3)), array['invalid', 'invalid', 'invalid'], 'libro común, visita ajena y cantidad 0 son invalid');
select is(pg_temp.codigos((select r from r_push3)), array['23514', '42501', '23514'], 'con 23514, 42501 y 23514');
select pg_temp.actuar_como_servidor();
select is(pg_temp.stock('22'), -2, 'y no movieron el stock');

-- La dueña del payload se ignora: b1 no puede subir un renglón a nombre de b2.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push4 on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('06', 'visita_misionero', jsonb_build_object('id', pg_temp.u('54'), 'visita_id', pg_temp.u('a5'),
                                                            'producto_id', pg_temp.u('22'), 'cantidad', 1,
                                                            'colportor_id', pg_temp.u('b2'))))) as r;
grant select on r_push4 to authenticated;
select pg_temp.actuar_como_servidor();
select is((select colportor_id from public.visita_misionero where id = pg_temp.u('54')), pg_temp.u('b1'), 'colportor_id del payload se descarta');
select is(pg_temp.stock('22'), -3, 'y el stock que baja es el de b1');

-- El teléfono no manda el origen del movimiento ni un movimiento de misioneros.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format('insert into public.movimiento_stock (id, producto_id, tipo, cantidad, motivo, visita_misionero_id) values (%L, %L, %L, 1, %L, %L)',
            pg_temp.u('90'), pg_temp.u('21'), 'AJUSTE_ENTRADA', 'CONTEO', pg_temp.u('50'))), '42501', 'mandar visita_misionero_id: sin privilegio (42501)');
select is(pg_temp.error_de(format('insert into public.movimiento_stock (id, producto_id, tipo, cantidad) values (%L, %L, %L, 1)',
            pg_temp.u('91'), pg_temp.u('21'), 'SALIDA_MISIONERO')), '42501', 'ni un SALIDA_MISIONERO por su cuenta: 42501');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
