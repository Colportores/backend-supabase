-- pgTAP · migración 0156 (backend-supabase#234, casilla «N.º de cuota»): cobranza.numero_cuota se fue; el cobro, el cobro
--   fijo (CB007) y la anulación siguen andando con el trigger reescrito; un push viejo que manda numero_cuota entra igual.
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
  select ('01920000-0000-7000-8000-0000000156' || p)::uuid;
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
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000156d0',
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
       'authenticated', 'authenticated', 't0156-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais t0156', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 t0156', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 t0156', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t0156', 'LIBRO');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));


-- ---------------------------------------------------------------------------
-- 1. La columna se fue, el cobro sigue
-- ---------------------------------------------------------------------------
select hasnt_column('public', 'cobranza', 'numero_cuota', 'cobranza ya no guarda el número de cuota');
select has_column('public', 'cobranza', 'monto', 'y conserva el monto');
select has_column('public', 'cobranza', 'medio', 'el medio');
select has_column('public', 'cobranza', 'fecha', 'y la fecha');
select is((select count(*)::int from pg_constraint where conrelid = 'public.cobranza'::regclass
            and pg_get_constraintdef(oid) like '%numero_cuota%'), 0, 'ningún CHECK la nombra');

select is(pg_temp.venta('01', 'T-156', 5000), 'ok', 'una venta de $ 50');

-- Un teléfono que todavía manda numero_cuota: el cobro entra, el campo se descarta.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push1 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('c1', 'cobranza', jsonb_build_object('id', pg_temp.u('c1'), 'venta_id', pg_temp.u('01'), 'monto', 1000,
                                                      'medio', 'EFECTIVO', 'fecha', now(), 'numero_cuota', 2)),
    pg_temp.job('c2', 'cobranza', jsonb_build_object('id', pg_temp.u('c2'), 'venta_id', pg_temp.u('01'), 'monto', 500,
                                                      'medio', 'EFECTIVO', 'fecha', now())))) as r;
grant select on r_push1 to authenticated;
select is(pg_temp.resultados((select r from r_push1)), array['accepted', 'accepted'],
          'push: con y sin numero_cuota, los dos cobros entran');
select pg_temp.actuar_como_servidor();
select is((select array_agg(monto order by monto) from public.cobranza where venta_id = pg_temp.u('01')), array[500, 1000],
          'los cobros quedaron con su monto');

-- El cobro fijo (CB007) y la corrección siguen funcionando con el trigger reescrito.
update public.cobranza set fecha = now() - interval '73 hours' where id = pg_temp.u('c1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.cobranza set monto = 1100 where id = pg_temp.u('c1') $$), 'CB007',
          'pasadas las 72 h el monto no cambia');
select is(pg_temp.error_de($$ update public.cobranza set monto = 600 where id = pg_temp.u('c2') $$), 'ok',
          'dentro del plazo, la dueña corrige el monto');
select is(pg_temp.error_de($$ update public.cobranza set fecha = now() - interval '1 hour' where id = pg_temp.u('c2') $$), 'CB006',
          'la fecha del cobro no se mueve');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Monto equivocado' where id = pg_temp.u('c2') $$), 'ok',
          'y se puede anular dentro del plazo');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
