-- pgTAP · migración 0155 (backend-supabase#234, casilla «Talonario =»): el índice único del talonario compara sin
--   mayúsculas ni espacios en los extremos (t-100 = T-100; 0100 ≠ 100), por colportor y año, en INSERT, UPDATE y push.
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
  select ('01920000-0000-7000-8000-0000000155' || p)::uuid;
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
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000155d0',
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
       'authenticated', 'authenticated', 't0155-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais t0155', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 t0155', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 t0155', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t0155', 'LIBRO');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));


-- ---------------------------------------------------------------------------
-- 1. El índice compara sin mayúsculas ni espacios en los extremos
-- ---------------------------------------------------------------------------
select is((select regexp_replace(pg_get_indexdef(indexrelid), '^.* USING ', '') from pg_index
            where indexrelid = 'public.venta_talonario_por_colportor_y_anio_idx'::regclass),
          'btree (colportor_id, lower(btrim(numero_talonario)), anio_de_la_venta(fecha)) WHERE (deleted_at IS NULL)',
          'por colportor, talonario en minúscula y recortado, y año');
select is((select indisunique from pg_index where indexrelid = 'public.venta_talonario_por_colportor_y_anio_idx'::regclass),
          true, 'sigue siendo único');

select is(pg_temp.venta('01', 'T-100', 1000), 'ok', 'el primer T-100 entra');
select is(pg_temp.venta('02', 't-100', 1000), '23505', 't-100 es el mismo talonario que T-100');
select is(pg_temp.venta('03', 'T-100', 1000), '23505', 'el idéntico también choca');
select is(pg_temp.venta('04', 't-100', 1000), '23505', 'otra vez en minúscula');
select is(pg_temp.venta('05', ' T-100', 1000), '23514', 'con un espacio al principio ni llega al índice: lo frena el tope de 0150');
select is(pg_temp.venta('06', 'T-100 ', 1000), '23514', 'con un espacio al final, igual');
select is(pg_temp.venta('07', 'T-101', 1000), 'ok', 'otro número vale');
select is(pg_temp.venta('08', '100', 1000), 'ok', 'el 100...');
select is(pg_temp.venta('09', '0100', 1000), 'ok', '...y el 0100 son distintos');
select is(pg_temp.venta('0a', 'ÁB-1', 1000), 'ok', 'una letra con tilde entra');
select is(pg_temp.venta('0b', 'áb-1', 1000), '23505', 'y su minúscula es la misma');

-- Otro colportor o otro año: se puede repetir.
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
  values (pg_temp.u('0c'), pg_temp.u('ca'), 'T-100', 1000, now(), pg_temp.u('b2')) $$), 'ok',
  'otro colportor puede usar T-100');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
  values (pg_temp.u('0d'), pg_temp.u('ca'), 't-100', 1000, now() + interval '2 years', pg_temp.u('b1')) $$), 'ok',
  'el mismo talonario en otro año vale');

-- Una venta dada de baja no ocupa el talonario.
update public.venta set deleted_at = now() where id = pg_temp.u('01');
select is(pg_temp.venta('0e', 't-100', 1000), 'ok', 'con la venta T-100 dada de baja, t-100 entra');
select is(pg_temp.error_de($$ update public.venta set deleted_at = null where id = pg_temp.u('01') $$), '23505',
          'y reactivar la dada de baja choca con ella');

-- El UPDATE del texto también compara sin mayúsculas.
select is(pg_temp.error_de($$ update public.venta set numero_talonario = 'T-102' where id = pg_temp.u('0e') $$), 'ok',
          'cambiar el talonario a uno libre');
select is(pg_temp.error_de($$ update public.venta set numero_talonario = 't-101' where id = pg_temp.u('09') $$), '23505',
          'cambiar a «t-101» choca con T-101');

-- Por el push: el segundo, en mayúscula distinta, vuelve invalid con 23505.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push1 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('a1', 'venta', pg_temp.payload_venta('a1', 'Q-1', 1000)),
    pg_temp.job('a2', 'venta', pg_temp.payload_venta('a2', 'q-1', 1000)),
    pg_temp.job('a3', 'venta', pg_temp.payload_venta('a3', 'Q-2', 1000)))) as r;
grant select on r_push1 to authenticated;
select is(pg_temp.resultados((select r from r_push1)), array['accepted', 'invalid', 'accepted'],
          'push: q-1 choca con Q-1 (invalid) y el lote sigue');
select is(pg_temp.codigos((select r from r_push1)), array['-', '23505', '-'], 'con 23505');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
