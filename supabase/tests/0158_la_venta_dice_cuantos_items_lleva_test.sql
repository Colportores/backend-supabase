-- pgTAP · 0158 (backend-supabase#234, decisión «Total arriba» del 03/11): venta.items_esperados y el motivo del
-- total exigido en los dos sentidos cuando ya llegaron todos los ítems; sin items_esperados rige solo la 0150.
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
  select ('01920000-0000-7000-8000-0000000158' || p)::uuid;
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
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000158d0',
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
       'authenticated', 'authenticated', 't0158-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais t0158', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 t0158', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 t0158', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t0158', 'LIBRO');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));


-- Una venta con items_esperados, como postgres. Devuelve el SQLSTATE o 'ok'.
create or replace function pg_temp.venta_e(p_id text, p_total integer, p_esperados integer, p_motivo text default null)
returns text language plpgsql as $$
begin
  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, motivo_monto_manual, items_esperados)
  values (pg_temp.u(p_id), pg_temp.u('ca'), 'E-' || p_id, p_total, now(), pg_temp.u('b1'), p_motivo, p_esperados);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.upd(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- ---------------------------------------------------------------------------
-- 1. La columna
-- ---------------------------------------------------------------------------
select has_column('public', 'venta', 'items_esperados', 'venta tiene items_esperados');
select col_type_is('public', 'venta', 'items_esperados', 'integer', 'entero');
select col_is_null('public', 'venta', 'items_esperados', 'opcional: las ventas de antes y los teléfonos viejos no la mandan');
select col_hasnt_default('public', 'venta', 'items_esperados', 'sin default');
select ok('items_esperados' = any (sync.columnas_escribibles('venta')), 'es una columna del push');
select is(pg_temp.venta_e('01', 1000, 0), '23514', '0 ítems no es una venta: 23514');
select is(pg_temp.venta_e('02', 1000, -1), '23514', 'ni negativo: 23514');
select is(pg_temp.venta_e('03', 1000, 1), 'ok', '1 ítem esperado entra');
select is(pg_temp.venta_e('04', 1000, null), 'ok', 'y sin items_esperados también');

-- ---------------------------------------------------------------------------
-- 2. Con ítems por llegar, no se juzga el total por encima
-- ---------------------------------------------------------------------------
select is(pg_temp.venta_e('10', 3000, 3), 'ok', 'la venta de $ 30 con 3 ítems esperados entra sin ítems');
select is(pg_temp.item('a1', '10', 1000), 'ok', 'el primer ítem ($ 10) entra: faltan dos');
select is(pg_temp.item('a2', '10', 1000), 'ok', 'el segundo ($ 10) entra: falta uno');
select is(pg_temp.item('a3', '10', 1000), 'ok', 'el tercero ($ 10) cierra la suma en $ 30: igual al total, sin motivo hace falta');

-- ---------------------------------------------------------------------------
-- 3. Con todos los ítems llegados, el total arriba pide motivo
-- ---------------------------------------------------------------------------
select is(pg_temp.venta_e('11', 3000, 2), 'ok', 'venta de $ 30 con 2 ítems esperados');
select is(pg_temp.item('b1', '11', 1000), 'ok', 'el primero entra');
select is(pg_temp.item('b2', '11', 1500), '23514', 'el segundo suma $ 25 y el total es $ 30 sin motivo: 23514');
select is((select count(*)::int from public.venta_item where venta_id = pg_temp.u('11')), 1, 'y el segundo no quedó guardado');

select is(pg_temp.venta_e('12', 3000, 2, 'redondeo a favor del cliente'), 'ok', 'la misma venta con motivo');
select is(pg_temp.item('c1', '12', 1000), 'ok', 'el primero entra');
select is(pg_temp.item('c2', '12', 1500), 'ok', 'el segundo suma $ 25, total $ 30: con motivo entra');

-- El total por debajo sigue pidiendo motivo, con o sin items_esperados.
select is(pg_temp.venta_e('13', 2000, 2), 'ok', 'venta de $ 20, 2 ítems esperados');
select is(pg_temp.item('d1', '13', 1000), 'ok', 'el primero, $ 10');
select is(pg_temp.item('d2', '13', 1500), '23514', 'el segundo suma $ 25 sobre un total de $ 20 sin motivo: 23514');
select is(pg_temp.venta_e('14', 2000, null), 'ok', 'venta de $ 20 sin items_esperados');
select is(pg_temp.item('e1', '14', 1500), 'ok', 'el primero, $ 15');
select is(pg_temp.item('e2', '14', 1000), '23514', 'el segundo suma $ 25 sobre $ 20 sin motivo: sigue la regla de la 0150');

-- Sin items_esperados, el total por encima nunca se juzga.
select is(pg_temp.venta_e('15', 9000, null), 'ok', 'venta de $ 90 sin items_esperados');
select is(pg_temp.item('f1', '15', 1000), 'ok', 'con un ítem de $ 10 entra: sin la cuenta, no hay forma de saber que es el último');

-- Más ítems que los esperados también cuenta como «todos llegaron».
select is(pg_temp.venta_e('16', 1000, 1), 'ok', 'venta de $ 10 con 1 ítem esperado');
select is(pg_temp.item('a7', '16', 1000), 'ok', 'el único ítem');
select is(pg_temp.item('a8', '16', 500), '23514', 'un segundo ítem de más pasa el total y no hay motivo: 23514');

-- ---------------------------------------------------------------------------
-- 4. Cambios sobre la venta ya completa
-- ---------------------------------------------------------------------------
select is(pg_temp.venta_e('20', 2000, 2), 'ok', 'venta de $ 20, 2 ítems');
select is(pg_temp.item('a9', '20', 1000), 'ok', 'ítem de $ 10');
select is(pg_temp.item('b7', '20', 1000), 'ok', 'ítem de $ 10: suma $ 20 = total');
select is(pg_temp.upd(format('update public.venta set monto_total = 2500 where id = %L', pg_temp.u('20'))), '23514',
          'subir el total a $ 25 sin motivo: 23514');
select is(pg_temp.upd(format('update public.venta set monto_total = 2500, motivo_monto_manual = %L where id = %L',
                             'propina', pg_temp.u('20'))), 'ok', 'con motivo se puede');
select is(pg_temp.upd(format('update public.venta set motivo_monto_manual = null where id = %L', pg_temp.u('20'))), '23514',
          'y no se puede borrar el motivo mientras el total no cierra');
select is(pg_temp.upd(format('update public.venta set monto_total = 2000, motivo_monto_manual = null where id = %L', pg_temp.u('20'))), 'ok',
          'volver al total que cierra y sacar el motivo, sí');
select is(pg_temp.upd(format('update public.venta set items_esperados = 3 where id = %L', pg_temp.u('20'))), 'ok',
          'subir items_esperados a 3 (falta un ítem): no se juzga');
select is(pg_temp.upd(format('update public.venta_item set subtotal = 800, precio_unitario = 800 where id = %L', pg_temp.u('a9'))), 'ok',
          'con un ítem por llegar, un subtotal que deja la suma ($ 18) por debajo del total no se juzga');
select is(pg_temp.upd(format('update public.venta set items_esperados = 2 where id = %L', pg_temp.u('20'))), '23514',
          'bajar items_esperados a 2: ahora llegaron todos y la suma ($ 18) no cierra con $ 20: 23514');

-- Una venta dada de baja no se juzga; un ítem dado de baja no dispara el chequeo.
select is(pg_temp.upd(format('update public.venta set deleted_at = now(), items_esperados = 2 where id = %L', pg_temp.u('20'))), 'ok',
          'una venta dada de baja no se juzga');
select is(pg_temp.venta_e('21', 2000, 2), 'ok', 'otra venta de $ 20, 2 ítems');
select is(pg_temp.item('b8', '21', 1000), 'ok', 'ítem de $ 10');
select is(pg_temp.item('b9', '21', 500, true), 'ok', 'un ítem dado de baja no se cuenta ni se suma');
select is(pg_temp.item('c7', '21', 1000), 'ok', 'el segundo vivo: $ 20 = total');

-- ---------------------------------------------------------------------------
-- 5. Por el push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('01', 'venta', pg_temp.payload_venta('30', 'P-30', 3000) || jsonb_build_object('items_esperados', 2)),
  pg_temp.job('02', 'venta_item', pg_temp.payload_item('c8', '30', 1000)),
  pg_temp.job('03', 'venta_item', pg_temp.payload_item('c9', '30', 1500)))) as r;
grant select on r_push to authenticated;
select is(pg_temp.resultados((select r from r_push)), array['accepted', 'accepted', 'invalid'],
          'la venta y su primer ítem entran; el último, que la deja sin cerrar y sin motivo, es invalid');
select is(pg_temp.codigos((select r from r_push)), array['-', '-', '23514'], 'con 23514');
select ok((select r -> 'results' -> 2 ->> 'message' from r_push) like 'El total de la venta no coincide%',
          'y un mensaje que le dice a la colportora qué hacer');

create temp table r_push2 on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('04', 'venta', pg_temp.payload_venta('31', 'P-31', 3000, 'redondeo') || jsonb_build_object('items_esperados', 2)),
  pg_temp.job('05', 'venta_item', pg_temp.payload_item('d7', '31', 1000)),
  pg_temp.job('06', 'venta_item', pg_temp.payload_item('d8', '31', 1500)))) as r;
grant select on r_push2 to authenticated;
select is(pg_temp.resultados((select r from r_push2)), array['accepted', 'accepted', 'accepted'], 'con el motivo entra todo');

-- La venta de un teléfono viejo (sin items_esperados) sigue entrando como siempre.
create temp table r_push3 on commit drop as
select pg_temp.push(jsonb_build_array(
  pg_temp.job('07', 'venta', pg_temp.payload_venta('32', 'P-32', 3000)),
  pg_temp.job('08', 'venta_item', pg_temp.payload_item('d9', '32', 1000)))) as r;
grant select on r_push3 to authenticated;
select is(pg_temp.resultados((select r from r_push3)), array['accepted', 'accepted'],
          'un teléfono viejo, sin items_esperados, sube sin cambios');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Forma
-- ---------------------------------------------------------------------------
select is(has_function_privilege('authenticated', 'public.tg_venta_exige_motivo_si_el_total_baja()', 'execute'), false,
          'el trigger sigue sin ser ejecutable por authenticated');
select is((select count(*)::int from pg_trigger t
            where t.tgrelid = 'public.venta'::regclass and t.tgname = 'venta_exige_motivo_si_el_total_baja'), 1,
          'un solo trigger del motivo en venta');

select * from finish();
rollback;
