-- pgTAP · migración 0152 (backend-supabase#220, seguimiento de #135, #110 y #200; respuestas de Cristian del 28/10
-- «Cobro en dep.», «Rechazo ret.» y «Alquiler fav»).
--   1. La forma: deposito_cobro se fue; las columnas del rechazo; privilegios; qué escribe el teléfono.
--   2. «Cobro en dep.»: «en mano» = efectivo cobrado menos lo depositado (sin los rechazados); la vista previa compara el
--      monto del depósito con lo que había en mano antes de él y la diferencia avisa sin frenar.
--   3. «Rechazo ret.»: el permiso, el motivo, el reintento, dos coordinadoras, lo rechazado no se edita ni se confirma,
--      no toca la cuenta y vuelve a estar en mano; el teléfono no se rechaza solo.
--   4. «Alquiler fav»: lo pagado de más del alquiler baja la deuda con la casa editora (y se lee), en una sola cuenta que
--      sigue a la baja, la reactivación y el cambio del monto de la campaña; una campaña sin alquiler traslada todo.
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
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000152' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000152' || p)::uuid;
$$;
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
create or replace function pg_temp.mensaje_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
-- Lo que devuelve cada RPC, en una línea (un valor null sale vacío).
create or replace function pg_temp.pr(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validacion_de_retiro(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s', r.monto, r.en_mano, r.diferencia, r.deuda_antes, r.deuda_despues, r.supera_deuda,
                r.a_la_casa_editora);
end $$;
create or replace function pg_temp.pt(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validacion_de_ticket(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s|%s|%s', r.monto, r.cobros_vinculados, r.en_mano, r.diferencia, r.deuda_antes,
                r.deuda_despues, r.supera_deuda, r.a_favor_despues, r.a_la_casa_editora);
end $$;
create or replace function pg_temp.vt(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validar_ticket(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s', r.estado, r.monto, r.en_mano, r.diferencia, r.supera_deuda, r.a_la_casa_editora,
                r.ya_estaba);
end $$;
create or replace function pg_temp.cr(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.confirmar_retiro(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s', r.estado, r.monto, r.en_mano, r.diferencia, r.supera_deuda, r.a_la_casa_editora,
                r.ya_estaba);
end $$;
create or replace function pg_temp.rr(p text, p_motivo text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.rechazar_retiro(pg_temp.u(p), p_motivo);
  return format('%s|%s', r.rechazado_en is not null, r.ya_estaba);
end $$;
create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;
-- La plata de una colportora: «deuda|depositado|trasladado» (sin cuenta viva: «-»).
create or replace function pg_temp.cuenta(p text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s|%s', deuda_total, dinero_depositado, alquiler_trasladado) from public.cuenta_colportor
                    where usuario_id = pg_temp.u(p) and deleted_at is null), '-')
$$;
-- La fila guardada del alquiler: «pagado|debe|trasladado» (SECURITY DEFINER: sin RLS).
create or replace function pg_temp.fila(p_us text, p_camp text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s|%s', ca.alquiler_pagado, coalesce(ca.alquiler_debe::text, 'n'), ca.alquiler_trasladado)
                     from public.cuenta_alquiler ca
                    where ca.usuario_id = pg_temp.u(p_us) and ca.campania_id = pg_temp.u(p_camp)), 'sin fila')
$$;
-- La lectura del panel de una colportora de la campaña, como ADMIN.
create or replace function pg_temp.panel(p_camp text, p_us text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.actuar_como(pg_temp.u('ad'));
  select format('%s|%s|%s|%s|%s|%s', r.dinero_en_mano, r.alquiler_pagado, r.alquiler_por_validar, r.alquiler_debe,
                r.alquiler_trasladado, coalesce(r.alquiler_monto::text, 'n'))
    into v
    from public.cuentas_de_campania(pg_temp.u(p_camp)) r
   where r.colportor_id = pg_temp.u(p_us);
  perform pg_temp.actuar_como_servidor();
  return v;
end $$;
create or replace function pg_temp.estado_t(p text) returns text language sql security definer as $$
  select estado from public.ticket where id = pg_temp.u(p)
$$;
create or replace function pg_temp.en_mano(p text) returns bigint language sql security definer as $$
  select public.efectivo_en_mano(pg_temp.u(p))
$$;
create or replace function pg_temp.n_audit(p_evento text, p text) returns bigint language sql security definer as $$
  select count(*) from auditoria.audit_log where event_type = p_evento and fila_id = pg_temp.u(p)
$$;
create or replace function pg_temp.audit_claves(p_evento text, p text) returns text[] language sql security definer as $$
  select array_agg(k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
   where a.event_type = p_evento and a.fila_id = pg_temp.u(p)
$$;
create or replace function pg_temp.audit_meta(p_evento text, p text) returns text language sql security definer as $$
  select a.metadata::text from auditoria.audit_log a where a.event_type = p_evento and a.fila_id = pg_temp.u(p)
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 (en e1, coordina c1) con cobros; b3 (en e1) sin cobros; b4 «Lucía» (en e1, alquiler); b2 (en e2, coordina c2);
-- ad ADMIN. e1 cobra un alquiler de 250000; e2 no cobra.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dep152-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('c1','COORDINADOR'),
               ('c2','COORDINADOR'), ('ad','ADMIN'), ('c1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 dep152', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 250000),
  (pg_temp.u('e2'), 'e2 dep152', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'), null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '10 days');

-- Una venta de b1 con cobros: 100000 y 50000 en efectivo (150000 en mano), 30000 con tarjeta, uno anulado y uno dado de baja.
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dep152', 'ZV');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dep152', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('a7'), 'CASA', 'Av. Italia', '152', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('f3'), pg_temp.u('a7'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('51'), pg_temp.u('f3'), pg_temp.u('f5'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
values (pg_temp.u('71'), pg_temp.u('51'), 'T-2152', 900000, now(), pg_temp.u('b1'), pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by) values
  (pg_temp.u('a1'), pg_temp.u('71'), 100000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('a2'), pg_temp.u('71'), 50000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('a3'), pg_temp.u('71'), 30000, 'TARJETA', now(), pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion, created_by) values
  (pg_temp.u('a4'), pg_temp.u('71'), 20000, 'EFECTIVO', now(), now(), 'Monto equivocado', pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, deleted_at, created_by) values
  (pg_temp.u('a5'), pg_temp.u('71'), 11111, 'EFECTIVO', now(), now(), pg_temp.u('b1'));

-- La plata: b1 debe 1000000; b4 (Lucía) debe 100000; b3, b2 y c1 sin cuenta.
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  (pg_temp.u('b1'), 1000000, 0),
  (pg_temp.u('b4'), 100000, 0);

-- Tickets: t1 depósito 80000 (pendiente); t2 depósito de 10000 rechazado; t4 alquiler de 300000 (b4); t5 alquiler 1000
-- (b2, e2 no cobra); t6 alquiler pendiente de 5000 (b4); t7 depósito de 20000 de b1 (otro tipo de gasto).
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, motivo_rechazo, revisado_por, revisado_en) values
  (pg_temp.u('11'), pg_temp.u('b1'), 'DEPOSITO', 80000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('12'), pg_temp.u('b1'), 'DEPOSITO', 10000, now(), 'RECHAZADO', 'No se lee', pg_temp.u('c1'), now()),
  (pg_temp.u('14'), pg_temp.u('b4'), 'DEPOSITO', 300000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('15'), pg_temp.u('b2'), 'DEPOSITO', 1000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('16'), pg_temp.u('b4'), 'DEPOSITO', 5000, now(), 'PENDIENTE', null, null, null);
-- Depósitos: d1 con t1 (80000); d2 con el ticket rechazado (10000); d3 retiro 40000 y d4 retiro 20000 (b1); d5 retiro de
-- b2 (otra campaña); d6 retiro propio de c1; d7 retiro de b3 de 100000 (sin nada en mano); d8 alquiler de b4 con t4.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('21'), pg_temp.u('b1'), 80000,  now(), pg_temp.u('11'), 'BANCO', 'CASA_EDITORA', null),
  (pg_temp.u('22'), pg_temp.u('b1'), 10000,  now(), pg_temp.u('12'), 'BANCO', 'CASA_EDITORA', null),
  (pg_temp.u('23'), pg_temp.u('b1'), 40000,  now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null),
  (pg_temp.u('24'), pg_temp.u('b1'), 20000,  now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null),
  (pg_temp.u('25'), pg_temp.u('b2'), 5000,   now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null),
  (pg_temp.u('26'), pg_temp.u('c1'), 3000,   now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('27'), pg_temp.u('b3'), 100000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null),
  (pg_temp.u('28'), pg_temp.u('b4'), 300000, now(), pg_temp.u('14'), 'BANCO', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('29'), pg_temp.u('b2'), 1000,   now(), pg_temp.u('15'), 'BANCO', 'ALQUILER', pg_temp.u('e2')),
  (pg_temp.u('2a'), pg_temp.u('b4'), 5000,   now(), pg_temp.u('16'), 'BANCO', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('2b'), pg_temp.u('b4'), 20000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('2c'), pg_temp.u('b4'), 40000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('2d'), pg_temp.u('b3'), 260000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('2e'), pg_temp.u('b3'), 7000,   now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select hasnt_table('public', 'deposito_cobro', 'deposito_cobro se retiró');
select is((select count(*)::int from sync.entidad where nombre = 'deposito_cobro'), 0, 'y ya no es entidad del push');
select hasnt_function('public', 'cobro_no_entra_en_deposito', 'ni la función que servía a sus vínculos');
select hasnt_function('public', 'tg_deposito_cobro_del_cliente', 'ni el trigger de la dueña');
select hasnt_function('public', 'tg_deposito_cobro_de_ticket_rechazado', 'ni el del ticket rechazado');
select has_column('public', 'deposito', 'rechazado_en', 'deposito.rechazado_en existe');
select has_column('public', 'deposito', 'rechazado_por', 'deposito.rechazado_por existe');
select has_column('public', 'deposito', 'motivo_rechazo', 'deposito.motivo_rechazo existe');
select col_is_fk('public', 'deposito', 'rechazado_por', 'rechazado_por es FK a usuario');
select has_index('public', 'deposito', 'deposito_rechazado_por_idx', 'índice sobre la FK rechazado_por');
select has_trigger('public', 'deposito', 'deposito_rechazado_no_se_edita', 'un retiro rechazado no se edita');
select ok(exists (select 1 from pg_constraint where conname = 'deposito_rechazo_completo_check'), 'el rechazo va completo');
select ok(exists (select 1 from pg_constraint where conname = 'deposito_rechazado_o_validado_check'), 'validado o rechazado, no las dos');
select ok(exists (select 1 from pg_constraint where conname = 'deposito_rechazo_solo_de_retiro_check'), 'solo un retiro sin ticket se rechaza');
select is((select columnas_servidor @> array['rechazado_en', 'rechazado_por', 'motivo_rechazo'] from sync.entidad where nombre = 'deposito'),
          true, 'el rechazo es columna del servidor: se descarta del push');
select ok(not (sync.columnas_escribibles('deposito') && array['rechazado_en', 'rechazado_por', 'motivo_rechazo']),
          'el teléfono no escribe el rechazo');
select has_column('public', 'cuenta_colportor', 'alquiler_trasladado', 'cuenta_colportor.alquiler_trasladado existe');
select has_column('public', 'cuenta_alquiler', 'alquiler_trasladado', 'cuenta_alquiler.alquiler_trasladado existe');
select hasnt_column('public', 'cuenta_alquiler', 'alquiler_a_favor', 'y alquiler_a_favor se fue (se renombró)');
select is((select has_function_privilege(r, f, 'execute')), r = 'authenticated', format('%s: %s', f, r))
  from unnest(array['public.rechazar_retiro(uuid,text)']) f, unnest(array['anon', 'authenticated']) r;
select is((select has_function_privilege(r, f, 'execute')), false, format('interna %s: %s', f, r))
  from unnest(array['public.efectivo_en_mano(uuid,uuid)', 'public.trasladar_alquiler_a_la_deuda(uuid,bigint)',
                    'public.alquiler_calculado(uuid,uuid)', 'public.refrescar_cuenta_alquiler(uuid,uuid)',
                    'public.tg_deposito_rechazado_no_se_edita()']) f,
       unnest(array['anon', 'authenticated', 'service_role']) r;
select is((select p.prosecdef and p.provolatile = 'v' from pg_proc p where p.oid = 'public.rechazar_retiro(uuid,text)'::regprocedure),
          true, 'rechazar_retiro es SECURITY DEFINER y VOLATILE');
select hasnt_column('public', 'cobranza', 'deposito_id', 'el cobro no lleva su depósito');
select is((select count(*)::int from information_schema.columns
            where table_schema = 'public' and table_name = 'deposito' and column_name like '%cobro%'), 0,
          'ni el depósito sus cobros');

-- ---------------------------------------------------------------------------
-- 2. «En mano»: efectivo cobrado menos lo depositado
-- ---------------------------------------------------------------------------
-- b1 cobró 150000 en efectivo (el de tarjeta, el anulado y el dado de baja no cuentan) y tiene depositado 80000 (con
-- ticket pendiente) + 40000 + 20000 (retiros por confirmar): le quedan 10000 en mano. El depósito del ticket rechazado
-- (10000) no cuenta como depositado.
select pg_temp.actuar_como_servidor();
select is(pg_temp.en_mano('b1'), 10000::bigint, 'en mano = 150000 en efectivo - 140000 depositados (sin el ticket rechazado)');
select is(pg_temp.en_mano('b3'), 0::bigint, 'sin cobros en efectivo, 0 (no baja de 0)');
select is(public.efectivo_en_mano(pg_temp.u('b1'), pg_temp.u('21')), 90000::bigint, 'dejando afuera el depósito d1: 90000');
select is(pg_temp.panel('e1', 'b1'), '10000|0|0|250000|0|250000', 'cuentas_de_campania muestra el «en mano» calculado');
-- La vista previa compara el monto del depósito con lo que había en mano ANTES de él; la diferencia avisa y no frena.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.pt('11'), '80000||90000|-10000|1000000|920000|0|0|', 'el ticket de 80000 con 90000 en mano antes: diferencia -10000, sin frenar');
select is(pg_temp.pr('23'), '40000|50000|-10000|1000000|960000|0|', 'el retiro de 40000 con 50000 en mano antes: diferencia -10000');
select is(pg_temp.pr('24'), '20000|30000|-10000|1000000|980000|0|', 'el de 20000 con 30000 en mano antes');
select is(pg_temp.pr('27'), '100000|0|100000|0|0|100000|', 'b3 deposita 100000 sin nada en mano: diferencia 100000 (aviso, no frena); la deuda queda a favor');
select is((select cobros_vinculados from public.validacion_de_ticket(pg_temp.u('11'))), null, 'un depósito no tiene cobros vinculados');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '1000000|0|0', 'la vista previa no cambió la cuenta');
-- Un aviso que no frena: el retiro de 100000 sin nada en mano se confirma igual.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('27'), 'VALIDADO|100000|0|100000|100000||f', 'c1 confirma el retiro de b3 aunque supere lo que tenía en mano');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b3'), '-100000|100000|0', 'la cuenta de b3 se crea: deuda a favor 100000 y depositado 100000');
-- El ticket de tarjeta sigue comparando con los cobros que apuntan a él.
select pg_temp.actuar_como_servidor();
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('17'), pg_temp.u('b1'), 'COBRO_TARJETA', 40000, now(), 'PENDIENTE');
update public.cobranza set ticket_id = pg_temp.u('17') where id = pg_temp.u('a3');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.pt('17'), '40000|30000||10000|1000000|960000|0|0|', 'el cobro con tarjeta: los cobros del ticket (30000) y la diferencia 10000');

-- ---------------------------------------------------------------------------
-- 3. «Rechazo ret.»: rechazar un retiro con motivo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'no') $$), '42501 ', 'sin sesión: 42501');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'no') $$), '42501 ', 'anon: sin EXECUTE');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'no') $$), '42501 ', 'una colportora no rechaza (ni su propio retiro)');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'no') $$), 'DP002 ', 'el coordinador de OTRA campaña: DP002');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('ff'), 'no') $$), 'DP002 ', 'un retiro que no existe: el mismo DP002');
select is(pg_temp.mensaje_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'no') $$),
          pg_temp.mensaje_de($$ select * from public.rechazar_retiro(pg_temp.u('ff'), 'no') $$),
          'con el mismo mensaje: no se averigua qué retiros hay');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('26'), 'no') $$), '42501 ', 'c1 no rechaza su propio retiro: 42501');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('21'), 'no') $$), 'DP003 ',
          'un depósito con ticket se rechaza con su ticket: DP003');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), null) $$), 'DP006 ', 'sin motivo: DP006');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), '   ') $$), 'DP006 ', 'motivo en blanco: DP006');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), repeat('x', 501)) $$), 'DP006 ', 'de más de 500: DP006');
select is(pg_temp.mensaje_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), '') $$),
          'Escribí el motivo del rechazo (hasta 500 caracteres) para que la colportora sepa qué corregir.', 'con su aviso, que dice qué hacer');
select pg_temp.actuar_como_servidor();
select is((select rechazado_en is null from public.deposito where id = pg_temp.u('24')), true, 'sigue sin rechazar');
-- Marta recibió 5000 de Lucía, pero Lucía cargó 6000: la coordinadora rechaza con el motivo.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.rr('24', '   Recibí 15000, no 20000  '), 't|f', 'c1 rechaza el retiro de 20000');
select pg_temp.actuar_como_servidor();
select is((select (rechazado_en is not null and rechazado_por = pg_temp.u('c1') and motivo_rechazo = 'Recibí 15000, no 20000'
                   and validado_en is null and deleted_at is null)
             from public.deposito where id = pg_temp.u('24')),
          true, 'queda rechazado, por c1, con el motivo recortado; no se valida y no se borra: es historia');
select is(pg_temp.cuenta('b1'), '1000000|0|0', 'la deuda y lo depositado no cambian');
select is(pg_temp.en_mano('b1'), 30000::bigint, 'y los 20000 vuelven a estar en mano: 150000 - 120000');
select is(pg_temp.panel('e1', 'b1'), '30000|0|0|250000|0|250000', 'el panel lo ve en mano');
select is(pg_temp.n_audit('retiro_rechazado', '24'), 1::bigint, 'deja un evento en la auditoría');
select is(pg_temp.audit_claves('retiro_rechazado', '24'), array['concepto', 'monto'], 'con solo el concepto y el monto');
select ok(position('Recib' in pg_temp.audit_meta('retiro_rechazado', '24')) = 0, 'el motivo escrito no se copia a la auditoría');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.rr('24', 'Recibí 15000, no 20000'), 't|t', 'un reintento de quien ya lo rechazó con el mismo motivo: ya_estaba');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'Otro motivo') $$), 'DP005 ', 'con otro motivo: DP005');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('24')) $$), 'DP005 ', 'un retiro rechazado no se confirma: DP005');
select is(pg_temp.mensaje_de($$ select * from public.confirmar_retiro(pg_temp.u('24')) $$),
          'Este retiro ya se rechazó: no se puede confirmar. Pedile a la colportora que cargue uno nuevo.', 'con su aviso');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'Recibí 15000, no 20000') $$), 'DP005 ',
          'otra persona (el ADMIN) sobre un retiro ya rechazado: DP005, aun con el mismo motivo');
select is(pg_temp.mensaje_de($$ select * from public.rechazar_retiro(pg_temp.u('24'), 'x') $$),
          'Este retiro ya lo rechazó otra persona. Recargá la lista para ver cómo quedó.', 'con su aviso');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n_audit('retiro_rechazado', '24'), 1::bigint, 'los reintentos y los errores no suman eventos');
-- Un retiro confirmado no se rechaza; uno rechazado no se edita ni se da de baja (ni el servidor).
select is(pg_temp.error_de($$ update public.deposito set monto = 1 where id = pg_temp.u('24') $$), 'DP005 ', 'el servidor no cambia el monto de un rechazado');
select is(pg_temp.error_de($$ update public.deposito set deleted_at = now() where id = pg_temp.u('24') $$), 'DP005 ', 'ni lo da de baja');
select is(pg_temp.error_de($$ update public.deposito set rechazado_en = null, rechazado_por = null, motivo_rechazo = null where id = pg_temp.u('24') $$),
          'DP005 ', 'ni le saca el rechazo');
select is(pg_temp.error_de($$ update public.deposito set motivo_rechazo = 'otro' where id = pg_temp.u('24') $$), 'DP005 ', 'ni le cambia el motivo');
select is(pg_temp.error_de($$ update public.deposito set updated_at = now() where id = pg_temp.u('24') $$), 'ok', 'lo que no cambia ningún dato no falla');
select is(pg_temp.error_de($$ update public.deposito set validado_en = now() where id = pg_temp.u('24') $$), 'DP005 ', 'ni se valida por fuera');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('23'), 'VALIDADO|40000|70000|-30000|0||f', 'c1 confirma el otro retiro (40000), con 70000 en mano antes (el rechazado ya no cuenta)');
select is(pg_temp.error_de($$ select * from public.rechazar_retiro(pg_temp.u('23'), 'tarde') $$), 'DP004 ', 'un retiro confirmado no se rechaza: DP004');
select is(pg_temp.mensaje_de($$ select * from public.rechazar_retiro(pg_temp.u('23'), 'tarde') $$),
          'Este retiro ya lo confirmó otra persona. Recargá la lista para ver cómo quedó.', 'con su aviso');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '960000|40000|0', 'la cuenta de b1 solo acredita lo confirmado (40000)');
select is(pg_temp.error_de($$ update public.deposito set rechazado_en = now(), motivo_rechazo = 'x' where id = pg_temp.u('23') $$),
          '23514 deposito_rechazado_o_validado_check', 'el servidor no deja un retiro validado y rechazado a la vez');
select is(pg_temp.error_de($$ update public.deposito set rechazado_en = now(), motivo_rechazo = 'x' where id = pg_temp.u('21') $$),
          '23514 deposito_rechazo_solo_de_retiro_check', 'ni rechaza un depósito con ticket por esta vía');
select is(pg_temp.error_de($$ update public.deposito set rechazado_en = now() where id = pg_temp.u('25') $$),
          '23514 deposito_rechazo_completo_check', 'ni un rechazo sin motivo');
-- Lo que el teléfono no puede: cargarse un retiro ya rechazado.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, rechazado_en, motivo_rechazo)
                              values (pg_temp.u('42'), 1000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', now(), 'x') $$),
          '42501 ', 'b1 no se carga un retiro ya rechazado por la API directa: 42501');
select is(pg_temp.mensaje_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, motivo_rechazo)
                               values (pg_temp.u('42'), 1000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', 'x') $$),
          'Un retiro lo rechaza tu coordinador, no se carga desde el teléfono. Registralo sin rechazar.', 'con su aviso');
select is(pg_temp.push1(pg_temp.op('01'), 'deposito', 'insert',
                        jsonb_build_object('id', pg_temp.u('43'), 'monto', 4000,
                                           'fecha', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                           'destino', 'RETIRO_COORDINADOR', 'concepto', 'CASA_EDITORA',
                                           'rechazado_en', '2026-10-27T00:00:00Z', 'motivo_rechazo', 'x',
                                           'rechazado_por', pg_temp.u('b1'))) ->> 'outcome',
          'accepted', 'por el push, el rechazo del payload se descarta y el depósito entra sin rechazar');
select pg_temp.actuar_como_servidor();
select is((select rechazado_en is null and rechazado_por is null and motivo_rechazo is null
             from public.deposito where id = pg_temp.u('43')), true, 'queda sin rechazo');
-- El teléfono recibe el motivo: el retiro rechazado baja con sus columnas por el sync.
select is((select sync.expresion_json('public.deposito'::regclass) like '%motivo_rechazo%'), true,
          'el pull de deposito baja motivo_rechazo (todas las columnas) para que Lucía vea el motivo');
-- Lucía carga uno nuevo y no hay nada que lo trabe.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                              values (pg_temp.u('44'), 15000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA') $$), 'ok',
          'b1 carga un retiro nuevo por el monto correcto');
select pg_temp.actuar_como_servidor();
select is(pg_temp.en_mano('b1'), 11000::bigint, 'y en mano: 150000 - 80000 - 40000 - 4000 (el del push) - 15000');

-- ---------------------------------------------------------------------------
-- 4. «Alquiler fav»: lo pagado de más del alquiler va a la deuda con la casa editora
-- ---------------------------------------------------------------------------
-- Lucía (b4) debe 100000 a la casa editora y 250000 de alquiler en e1.
select is(pg_temp.cuenta('b4'), '100000|0|0', 'Lucía debe 100000 a la casa editora');
select is(pg_temp.fila('b4', 'e1'), '0|250000|0', 'y 250000 de alquiler, sin pagar');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.pt('14'), '300000||0|300000|250000|0|50000|0|50000',
          'la vista previa: paga 300000 de un alquiler de 250000; 50000 superan y pasan a la casa editora (a favor del alquiler: 0)');
select is((select format('%s|%s', v.supera_deuda, v.a_la_casa_editora) from public.validacion_de_ticket(pg_temp.u('14')) v), '50000|50000',
          'supera_deuda y a_la_casa_editora dicen lo mismo en un alquiler');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b4'), '100000|0|0', 'y la vista previa no movió nada');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('14'), 'VALIDADO|300000|0|300000|50000|50000|f', 'c1 valida el depósito de alquiler de 300000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('b4', 'e1'), '300000|0|50000', 'el alquiler de e1 queda en 0 (debe 0) y registra los 50000 trasladados');
select is(pg_temp.cuenta('b4'), '50000|300000|50000', 'la deuda con la casa editora baja 50000 (de 100000 a 50000); Depositado sube 300000');
select is(pg_temp.panel('e1', 'b4'), '0|300000|65000|0|50000|250000', 'el panel lee pagado 300000, por validar 65000 (t6 y dos retiros), debe 0 y trasladado 50000');
-- Un depósito de alquiler pendiente no traslada nada hasta que se valida.
select is(pg_temp.panel('e1', 'b3'), '0|0|267000|250000|0|250000', 'b3: dos retiros de alquiler por validar (260000 y 7000), nada trasladado todavía');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('2b'), 'VALIDADO|20000|0|20000|20000|20000|f', 'Lucía confirma un retiro de alquiler de 20000: ya estaba todo pagado, todo traslada');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b4'), '30000|320000|70000', 'deuda 30000, Depositado 320000, trasladado 70000');
select is(pg_temp.fila('b4', 'e1'), '320000|0|70000', 'la fila guardada sigue');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('2c'), 'VALIDADO|40000|0|40000|40000|40000|f', 'otro de 40000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b4'), '-10000|360000|110000', 'la deuda con la casa editora queda a favor (-10000) y registra 110000 trasladados');
-- Un ticket de alquiler pendiente o rechazado no traslada.
select is(pg_temp.fila('b4', 'e1'), '360000|0|110000', 'la fila no cuenta lo pendiente (t6, 5000)');
-- La baja: quien se da de baja no debe nada, todo lo pagado se traslada; al reactivarla vuelve a deber y el traslado se deshace.
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
select is(pg_temp.fila('b4', 'e1'), '360000|0|360000', 'de baja: debe 0 y se traslada todo lo pagado');
select is(pg_temp.cuenta('b4'), '-260000|360000|360000', 'la deuda con la casa editora baja los 250000 de más');
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');
select is(pg_temp.fila('b4', 'e1'), '360000|0|110000', 'reactivada: vuelve a deber el alquiler (regla R7) y el traslado se deshace');
select is(pg_temp.cuenta('b4'), '-10000|360000|110000', 'la deuda vuelve a lo de antes: nada desaparece sin explicación');
-- El monto del alquiler de la campaña cambia.
update public.campania set alquiler_monto = 340000 where id = pg_temp.u('e1');
select is(pg_temp.fila('b4', 'e1'), '360000|0|20000', 'si el alquiler sube a 340000, se traslada menos (20000)');
select is(pg_temp.cuenta('b4'), '80000|360000|20000', 'y la deuda sube lo que se deshizo');
update public.campania set alquiler_monto = 250000 where id = pg_temp.u('e1');
select is(pg_temp.cuenta('b4'), '-10000|360000|110000', 'al volver a 250000 queda como antes');
-- Un depósito que no llega a cubrir el alquiler no traslada.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('2d'), 'VALIDADO|260000|0|260000|10000|10000|f', 'b3 confirma 260000 de un alquiler de 250000: supera por 10000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b3'), '-110000|360000|10000',
          'b3: antes tenía -100000 por el depósito de casa editora; el de más del alquiler suma 10000 a favor');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.rr('2e', 'No lo recibí'), 't|f', 'c1 rechaza el retiro de alquiler de 7000 de b3');
select pg_temp.actuar_como_servidor();
select is(pg_temp.panel('e1', 'b3'), '0|260000|0|0|10000|250000',
          'el retiro rechazado deja de contar como por validar (0), y lo pagado y lo trasladado no cambian');
select is(pg_temp.cuenta('b3'), '-110000|360000|10000', 'la cuenta de b3 no cambia por el rechazo');
-- Una campaña que no cobra alquiler: todo lo pagado pasa a la deuda con la casa editora.
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.pt('15'), '1000||0|1000|||||1000', 'e2 no cobra alquiler: la vista previa dice que los 1000 pasan a la casa editora');
select is(pg_temp.vt('15'), 'VALIDADO|1000|0|1000||1000|f', 'c2 valida el de b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.fila('b2', 'e2'), '1000|n|1000', 'sin alquiler en la campaña: debe n (no cobra) y se traslada todo');
select is(pg_temp.cuenta('b2'), '-1000|1000|1000', 'b2: la deuda queda a favor 1000');
select is(pg_temp.panel('e2', 'b2'), '0|1000|0||1000|n', 'el panel de e2 lo lee (debe vacío: no cobra)');

select * from finish();
rollback;
