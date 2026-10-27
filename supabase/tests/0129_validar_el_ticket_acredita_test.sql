-- pgTAP · migración 0129 (backend-supabase#110, BACK-HU-COB-008, HU-COB-008 / HU-CTA-003 / HU-CTA-004): validar el
-- ticket acredita el depósito y baja la deuda.
--   1. La forma: las dos columnas de validación, los triggers, los privilegios de los RPC y qué escribe el teléfono.
--   2. El permiso: sin sesión, colportor, coordinador de otra campaña (igual que un ticket que no existe), el propio
--      ticket de un coordinador que también es colportor, el ADMIN.
--   3. Lo que se ve antes de confirmar (la vista previa): casa editora, pago de más, alquiler, tarjeta, otro tipo y
--      retiro; y que no cambia nada.
--   4. Validar: el depósito y el ticket, la cuenta (Depositado y deuda, que puede quedar a favor), el alquiler por
--      campaña, el cobro con tarjeta, un ticket de otro tipo, las cuentas que se crean o se reactivan, la
--      auditoría, el reintento y los errores (sin monto, depósito que no llegó, ya resuelto).
--   5. Rechazar: el motivo, el reintento, los cobros que vuelven a estar en mano y que no se acredita nada.
--   6. Confirmar un retiro sin ticket.
--   7. Un depósito validado no se edita; el teléfono no se valida solo.
--   8. cuentas_de_campania cuenta como alquiler pagado lo validado.
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

-- Ids (prefijo 27, sufijo de dos caracteres hex).
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '27' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000027' || p)::uuid;
$$;

-- «sqlstate restricción» (la restricción puede ir vacía), u «ok», de lo que hace una sentencia.
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
create or replace function pg_temp.vt(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validar_ticket(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s|%s|%s', r.estado, r.monto, r.cobros_vinculados, r.diferencia, r.deuda_antes,
                r.deuda_despues, r.supera_deuda, r.a_favor_despues, r.ya_estaba);
end $$;
create or replace function pg_temp.cr(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.confirmar_retiro(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s|%s|%s', r.estado, r.monto, r.cobros_vinculados, r.diferencia, r.deuda_antes,
                r.deuda_despues, r.supera_deuda, r.a_favor_despues, r.ya_estaba);
end $$;
create or replace function pg_temp.rt(p text, p_motivo text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.rechazar_ticket(pg_temp.u(p), p_motivo);
  return format('%s|%s|%s', r.estado, r.cobros_liberados, r.ya_estaba);
end $$;
create or replace function pg_temp.pv(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validacion_de_ticket(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s|%s|%s', r.tipo, r.concepto, r.monto, r.cobros_vinculados, r.diferencia,
                r.deuda_antes, r.deuda_despues, r.supera_deuda, r.a_favor_despues);
end $$;
create or replace function pg_temp.pr(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validacion_de_retiro(pg_temp.u(p));
  return format('%s|%s|%s|%s|%s|%s|%s|%s|%s', r.tipo, r.concepto, r.monto, r.cobros_vinculados, r.diferencia,
                r.deuda_antes, r.deuda_despues, r.supera_deuda, r.a_favor_despues);
end $$;
create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- Estado de la plata de una colportora: «deuda|depositado» (sin cuenta viva: «-»).
create or replace function pg_temp.cuenta(p text) returns text language sql as $$
  select coalesce((select format('%s|%s', deuda_total, dinero_depositado) from public.cuenta_colportor
                    where usuario_id = pg_temp.u(p) and deleted_at is null), '-')
$$;
create or replace function pg_temp.estado_t(p text) returns text language sql as $$
  select estado from public.ticket where id = pg_temp.u(p)
$$;
create or replace function pg_temp.validado(p text) returns boolean language sql as $$
  select validado_en is not null from public.deposito where id = pg_temp.u(p)
$$;
-- ¿Cuántos eventos de auditoría hay de ese tipo sobre esa fila? (audit_log solo lo lee el servidor.)
create or replace function pg_temp.n_audit(p_evento text, p text) returns bigint language sql security definer as $$
  select count(*) from auditoria.audit_log where event_type = p_evento and fila_id = pg_temp.u(p)
$$;
create or replace function pg_temp.audit_claves(p_evento text, p text) returns text[] language sql security definer as $$
  select array_agg(k order by k) from auditoria.audit_log a, jsonb_object_keys(a.metadata) k
   where a.event_type = p_evento and a.fila_id = pg_temp.u(p)
$$;
create or replace function pg_temp.audit_texto(p_evento text, p text) returns text language sql security definer as $$
  select (a.actor_user_id, a.target_user_id, a.tabla)::text from auditoria.audit_log a
   where a.event_type = p_evento and a.fila_id = pg_temp.u(p)
$$;
create or replace function pg_temp.audit_meta(p_evento text, p text) returns text language sql security definer as $$
  select a.metadata::text from auditoria.audit_log a where a.event_type = p_evento and a.fila_id = pg_temp.u(p)
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 (en e1, coordina c1) y b3 (en e1) y b2 (en e2, coordina c2) colportoras; ad ADMIN; ca coordina e3 y además es
-- colportor de e3 (su propio ticket no lo valida).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'vt27-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','c1','c2','ad','ca']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('c1','COORDINADOR'),
               ('c2','COORDINADOR'), ('ad','ADMIN'), ('ca','COORDINADOR'), ('ca','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 vt27', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 150000),
  (pg_temp.u('e2'), 'e2 vt27', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'), null),
  (pg_temp.u('e3'), 'e3 vt27', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('ca'), null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '10 days'),
  (pg_temp.u('e3'), pg_temp.u('ca'), now() - interval '10 days');

-- Una venta de b1 con sus cobros: a1..a3 y a6 en efectivo (a6 anulado), a4 y a5 con tarjeta (ticket t4).
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais vt27', 'ZW');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad vt27', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('a7'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('f3'), pg_temp.u('a7'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('51'), pg_temp.u('f3'), pg_temp.u('f5'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
values (pg_temp.u('71'), pg_temp.u('51'), 'T-2771', 900000, now(), pg_temp.u('b1'), pg_temp.u('b1'));

-- Tickets: t0 validado antes (alquiler de 100000), t1 depósito 180000, t2 depósito 800000 (pago de más), t3 alquiler
-- 80000, t4 tarjeta 120000, t5 otro, t6 depósito sin depósito (no llegó), t7 tarjeta sin monto, t8 depósito para
-- rechazar, t9 depósito de b2, ta ticket de ca, tb pendiente de alquiler, tc rechazado de alquiler, td depósito
-- nuevo de b1, te depósito de b3.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, motivo_rechazo, revisado_por, revisado_en) values
  (pg_temp.u('10'), pg_temp.u('b1'), 'DEPOSITO', 100000, now() - interval '3 days', 'VALIDADO', null, pg_temp.u('c1'), now() - interval '2 days'),
  (pg_temp.u('11'), pg_temp.u('b1'), 'DEPOSITO', 180000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('12'), pg_temp.u('b1'), 'DEPOSITO', 800000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('13'), pg_temp.u('b1'), 'DEPOSITO', 80000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('14'), pg_temp.u('b1'), 'COBRO_TARJETA', 120000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('15'), pg_temp.u('b1'), 'OTRO', 5000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('16'), pg_temp.u('b1'), 'DEPOSITO', 1000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('17'), pg_temp.u('b1'), 'COBRO_TARJETA', null, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('18'), pg_temp.u('b1'), 'DEPOSITO', 90000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('19'), pg_temp.u('b2'), 'DEPOSITO', 60000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('1a'), pg_temp.u('ca'), 'DEPOSITO', 10000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('1b'), pg_temp.u('b1'), 'DEPOSITO', 15000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('1c'), pg_temp.u('b1'), 'DEPOSITO', 7000, now(), 'RECHAZADO', 'No se lee', pg_temp.u('c1'), now()),
  (pg_temp.u('1d'), pg_temp.u('b1'), 'DEPOSITO', 30000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('1e'), pg_temp.u('b3'), 'DEPOSITO', 1000, now(), 'PENDIENTE', null, null, null);
-- tf: un ticket dado de baja (no existe para el coordinador).
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, deleted_at) values
  (pg_temp.u('1f'), pg_temp.u('b1'), 'DEPOSITO', 1000, now(), 'PENDIENTE', now());

-- Cobros de b1.
insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id, created_by) values
  (pg_temp.u('a1'), pg_temp.u('71'), 100000, 'EFECTIVO', now(), null, pg_temp.u('b1')),
  (pg_temp.u('a2'), pg_temp.u('71'), 50000, 'EFECTIVO', now(), null, pg_temp.u('b1')),
  (pg_temp.u('a3'), pg_temp.u('71'), 30000, 'EFECTIVO', now(), null, pg_temp.u('b1')),
  (pg_temp.u('a4'), pg_temp.u('71'), 70000, 'TARJETA', now(), pg_temp.u('14'), pg_temp.u('b1')),
  (pg_temp.u('a5'), pg_temp.u('71'), 50000, 'TARJETA', now(), pg_temp.u('14'), pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion, ticket_id, created_by) values
  (pg_temp.u('a6'), pg_temp.u('71'), 20000, 'EFECTIVO', now(), now(), 'Monto equivocado', null, pg_temp.u('b1')),
  (pg_temp.u('a7'), pg_temp.u('71'), 9999, 'TARJETA', now(), now(), 'Monto equivocado', pg_temp.u('14'), pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, deleted_at, ticket_id, created_by) values
  (pg_temp.u('a8'), pg_temp.u('71'), 11111, 'EFECTIVO', now(), now(), null, pg_temp.u('b1')),
  (pg_temp.u('ab'), pg_temp.u('71'), 44444, 'TARJETA', now(), now(), pg_temp.u('14'), pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion, created_by) values
  (pg_temp.u('aa'), pg_temp.u('71'), 33333, 'EFECTIVO', now(), now(), 'Monto equivocado', pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by) values
  (pg_temp.u('a9'), pg_temp.u('71'), 22222, 'EFECTIVO', now(), pg_temp.u('b1'));

-- Depósitos: d0 alquiler ya validado (100000); d1 casa editora 180000 con dos cobros (150000); d2 800000 sin cobros;
-- d3 alquiler 80000; d8 para rechazar (con un cobro vivo y uno anulado); d9 de b2; da de ca; d11 retiro de casa
-- editora 500000; d12 retiro de alquiler 20000 (queda por validar); d13 retiro de b2; d14 alquiler 15000 con
-- ticket pendiente; d15 alquiler 7000 con ticket rechazado; d17 retiro de alquiler 6000 (se confirma); d18 de b3.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('20'), pg_temp.u('b1'), 100000, now() - interval '3 days', pg_temp.u('10'), 'BANCO',   'ALQUILER',     pg_temp.u('e1')),
  (pg_temp.u('21'), pg_temp.u('b1'), 180000, now(), pg_temp.u('11'), 'BANCO',   'CASA_EDITORA', null),
  (pg_temp.u('22'), pg_temp.u('b1'), 800000, now(), pg_temp.u('12'), 'OFICINA', 'CASA_EDITORA', null),
  (pg_temp.u('23'), pg_temp.u('b1'), 80000,  now(), pg_temp.u('13'), 'BANCO',   'ALQUILER',     pg_temp.u('e1')),
  (pg_temp.u('28'), pg_temp.u('b1'), 90000,  now(), pg_temp.u('18'), 'BANCO',   'CASA_EDITORA', null),
  (pg_temp.u('29'), pg_temp.u('b2'), 60000,  now(), pg_temp.u('19'), 'BANCO',   'CASA_EDITORA', null),
  (pg_temp.u('2a'), pg_temp.u('ca'), 10000,  now(), pg_temp.u('1a'), 'BANCO',   'CASA_EDITORA', null),
  (pg_temp.u('2b'), pg_temp.u('b1'), 500000, now(), null,            'RETIRO_COORDINADOR', 'CASA_EDITORA', null),
  (pg_temp.u('2c'), pg_temp.u('b1'), 20000,  now() + interval '2 hours', null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('2d'), pg_temp.u('b2'), 40000,  now(), null,            'RETIRO_COORDINADOR', 'CASA_EDITORA', null),
  (pg_temp.u('2e'), pg_temp.u('b1'), 15000,  now(), pg_temp.u('1b'), 'BANCO',   'ALQUILER',     pg_temp.u('e1')),
  (pg_temp.u('2f'), pg_temp.u('b1'), 7000,   now(), pg_temp.u('1c'), 'BANCO',   'ALQUILER',     pg_temp.u('e1')),
  (pg_temp.u('30'), pg_temp.u('b1'), 6000,   now(), null,            'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('31'), pg_temp.u('b3'), 1000,   now(), pg_temp.u('1e'), 'BANCO',   'CASA_EDITORA', null),
  (pg_temp.u('34'), pg_temp.u('b1'), 5000,   now(), null,            'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e2')),
  (pg_temp.u('35'), pg_temp.u('c1'), 3000,   now(), null,            'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'));
-- d32: un retiro de alquiler validado pero dado de baja; d33: uno validado de otra campaña. Ninguno cuenta en e1.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por, deleted_at) values
  (pg_temp.u('32'), pg_temp.u('b1'), 11000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1'), now());
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('33'), pg_temp.u('b1'), 9000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e2'), now(), pg_temp.u('c2'));
-- d0 estaba validado (su ticket t0 también).
update public.deposito set validado_en = now() - interval '2 days', validado_por = pg_temp.u('c1')
 where id = pg_temp.u('20');
insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id) values
  (pg_temp.u('e1'), pg_temp.u('21'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('e2'), pg_temp.u('21'), pg_temp.u('a2'), pg_temp.u('b1')),
  (pg_temp.u('e3'), pg_temp.u('28'), pg_temp.u('a3'), pg_temp.u('b1')),
  (pg_temp.u('e4'), pg_temp.u('28'), pg_temp.u('a6'), pg_temp.u('b1')),
  (pg_temp.u('e5'), pg_temp.u('21'), pg_temp.u('a8'), pg_temp.u('b1')),
  (pg_temp.u('e7'), pg_temp.u('21'), pg_temp.u('aa'), pg_temp.u('b1'));
-- Un vínculo dado de baja (a9 vive pero ya no está en el depósito d1).
insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id, deleted_at) values
  (pg_temp.u('e6'), pg_temp.u('21'), pg_temp.u('a9'), pg_temp.u('b1'), now());

-- La plata de b1 (debe 500000) y de b2 (una cuenta dada de baja, que se reactiva).
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado, deleted_at) values
  (pg_temp.u('b1'), 500000, 0, null),
  (pg_temp.u('b2'), 777, 777, now());

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'deposito', 'validado_en', 'deposito.validado_en existe');
select has_column('public', 'deposito', 'validado_por', 'deposito.validado_por existe');
select col_is_fk('public', 'deposito', 'validado_por', 'validado_por es FK a usuario');
select col_is_null('public', 'deposito', 'validado_en', 'validado_en es opcional (null = por validar)');
select has_index('public', 'deposito', 'deposito_validado_por_idx', 'índice sobre la FK validado_por');
select has_trigger('public', 'deposito', 'deposito_validado_del_servidor', 'el teléfono no escribe la validación');
select has_trigger('public', 'deposito', 'deposito_validado_no_se_edita', 'un depósito validado no se edita');
select ok(exists (select 1 from pg_constraint where conname = 'deposito_validado_por_con_fecha_check'),
          'quien validó va con la fecha');
select is((select columnas_servidor @> array['validado_en', 'validado_por'] from sync.entidad where nombre = 'deposito'),
          true, 'la validación es columna del servidor: se descarta del push');
select ok(not (sync.columnas_escribibles('deposito') && array['validado_en', 'validado_por']),
          'el teléfono no escribe validado_en ni validado_por');
select is((select has_function_privilege('authenticated', 'public.tg_deposito_validado_del_servidor()', 'execute')), false,
          'la función del trigger de alta no se llama a mano');
select is((select has_function_privilege('authenticated', 'public.tg_deposito_validado_no_se_edita()', 'execute')), false,
          'ni la del trigger de edición');

select is((select has_function_privilege(r, f, 'execute')), r = 'authenticated', format('%s: %s', f, r))
  from unnest(array['public.validacion_de_ticket(uuid)', 'public.validacion_de_retiro(uuid)',
                    'public.validar_ticket(uuid)', 'public.confirmar_retiro(uuid)',
                    'public.rechazar_ticket(uuid,text)']) f,
       unnest(array['anon', 'authenticated']) r;
select is((select has_function_privilege(r, f, 'execute')), false, format('interna %s: %s', f, r))
  from unnest(array['public.validacion_calculada(uuid,uuid)', 'public.acreditar_en_la_cuenta(uuid,bigint,boolean)',
                    'public.ticket_para_validar(uuid,boolean)', 'public.retiro_para_confirmar(uuid,boolean)']) f,
       unnest(array['anon', 'authenticated', 'service_role']) r;
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.validacion_de_ticket(uuid)'::regprocedure, 'public.validacion_de_retiro(uuid)'::regprocedure,
                            'public.validar_ticket(uuid)'::regprocedure, 'public.confirmar_retiro(uuid)'::regprocedure,
                            'public.rechazar_ticket(uuid,text)'::regprocedure)
              and p.prosecdef and p.provolatile = 'v'), 5, 'los cinco RPC son SECURITY DEFINER y VOLATILE');

-- ---------------------------------------------------------------------------
-- 2. El permiso
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt();
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$), '42501 ', 'sin sesión: 42501');
select is(pg_temp.error_de($$ select * from public.validacion_de_ticket(pg_temp.u('11')) $$), '42501 ', 'la vista previa también');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$), '42501 ', 'anon: sin EXECUTE');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$), '42501 ', 'un colportor no valida (ni lo suyo)');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('11'), 'no') $$), '42501 ', 'ni rechaza');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('2b')) $$), '42501 ', 'ni confirma un retiro');
select is(pg_temp.error_de($$ select * from public.validacion_de_retiro(pg_temp.u('2b')) $$), '42501 ', 'ni mira su vista previa');

select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$), 'TV001 ',
          'el coordinador de OTRA campaña: TV001');
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('ff')) $$), 'TV001 ',
          'un ticket que no existe: el mismo TV001');
select is(pg_temp.mensaje_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$),
          pg_temp.mensaje_de($$ select * from public.validar_ticket(pg_temp.u('ff')) $$),
          'con el mismo mensaje: no se averigua qué tickets hay');
select is(pg_temp.error_de($$ select * from public.validacion_de_ticket(pg_temp.u('11')) $$), 'TV001 ', 'la vista previa, igual');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('11'), 'no') $$), 'TV001 ', 'rechazar, igual');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('2b')) $$), 'DP002 ', 'un retiro de otra campaña: DP002');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('ff')) $$), 'DP002 ', 'uno que no existe: DP002');
select pg_temp.actuar_como_servidor();
select is(pg_temp.estado_t('11'), 'PENDIENTE', 'y no cambió nada');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('19')) $$), 'TV001 ',
          'c1 no valida el ticket de b2 (otra campaña)');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('2d')) $$), 'DP002 ', 'ni el retiro de b2');

select pg_temp.actuar_como(pg_temp.u('ca'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('1a')) $$), '42501 ',
          'un coordinador no valida su propio ticket aunque coordine esa campaña');
select is(pg_temp.mensaje_de($$ select * from public.validar_ticket(pg_temp.u('1a')) $$),
          'No podés validar ni rechazar tu propio ticket. Pedile a otro coordinador o a un administrador que lo haga.',
          'con su aviso');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('1a'), 'no') $$), '42501 ', 'ni lo rechaza');
select is(pg_temp.error_de($$ select * from public.validacion_de_ticket(pg_temp.u('1a')) $$), '42501 ', 'ni mira su vista previa');

-- ---------------------------------------------------------------------------
-- 3. La vista previa (c1): no cambia nada
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.pv('11'), 'DEPOSITO|CASA_EDITORA|180000|150000|30000|500000|320000|0|0',
          'depósito de 180000 con dos cobros (150000): diferencia 30000 y la deuda baja a 320000');
select is(pg_temp.pv('12'), 'DEPOSITO|CASA_EDITORA|800000|0|800000|500000|0|300000|300000',
          'pago de más: 800000 contra una deuda de 500000 supera por 300000 y queda 300000 a favor');
select is(pg_temp.pv('13'), 'DEPOSITO|ALQUILER|80000|0|80000|50000|0|30000|30000',
          'alquiler: debe 150000 - 100000 = 50000; paga 80000: supera por 30000, a favor 30000');
select is(pg_temp.pv('14'), 'COBRO_TARJETA|CASA_EDITORA|120000|120000|0|500000|380000|0|0',
          'cobro con tarjeta: casa editora, y los dos cobros del ticket suman lo mismo');
select is(pg_temp.pv('15'), 'OTRO' || repeat('|', 8), 'un ticket de otro tipo: no acredita nada');
select is(pg_temp.pv('1b'), 'DEPOSITO|ALQUILER|15000|0|15000|50000|35000|0|0', 'alquiler que no supera la deuda');
select is(pg_temp.pr('2b'), '|CASA_EDITORA|500000|0|500000|500000|0|0|0', 'un retiro sin ticket: tipo vacío');
select is(pg_temp.error_de($$ select * from public.validacion_de_retiro(pg_temp.u('21')) $$), 'DP003 ',
          'la vista previa de retiro de un depósito con ticket: DP003');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('21')) $$), 'DP003 ',
          'confirmar un depósito con ticket: DP003 (se valida desde su ticket)');
select is(pg_temp.mensaje_de($$ select * from public.confirmar_retiro(pg_temp.u('21')) $$),
          'Este depósito tiene ticket: se valida desde su ticket, en la lista de tickets.', 'con su aviso');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '500000|0', 'la cuenta de b1 no cambió');
select is(pg_temp.estado_t('11'), 'PENDIENTE', 'ni el ticket');
select is(pg_temp.validado('21'), false, 'ni el depósito');

-- ---------------------------------------------------------------------------
-- 4. Validar
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('11'), 'VALIDADO|180000|150000|30000|500000|320000|0|0|f', 'c1 valida el ticket de b1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.estado_t('11'), 'VALIDADO', 'el ticket queda VALIDADO');
select is((select (revisado_por = pg_temp.u('c1') and revisado_en is not null) from public.ticket where id = pg_temp.u('11')),
          true, 'con quién y cuándo');
select is((select (validado_por = pg_temp.u('c1') and validado_en is not null) from public.deposito where id = pg_temp.u('21')),
          true, 'y el depósito queda validado, por el mismo');
select is((select validado_en = revisado_en from public.deposito d join public.ticket t on t.id = d.ticket_id
            where d.id = pg_temp.u('21')), true, 'en el mismo instante');
select is(pg_temp.cuenta('b1'), '320000|180000', 'Depositado sube 180000 y la deuda baja de 500000 a 320000');
select is(pg_temp.n_audit('ticket_validado', '11'), 1::bigint, 'deja un evento en la auditoría');
select is(pg_temp.audit_claves('ticket_validado', '11'),
          array['cobros_vinculados', 'concepto', 'deposito_id', 'deuda_antes', 'deuda_despues', 'monto', 'tipo'],
          'con solo ids, montos y estados');
select is(pg_temp.audit_texto('ticket_validado', '11'), format('(%s,%s,ticket)', pg_temp.u('c1'), pg_temp.u('b1')),
          'quién lo validó, sobre quién y en qué tabla');
select ok(auditoria.metadata_sin_datos_personales(pg_temp.audit_meta('ticket_validado', '11')::jsonb),
          'el detalle no lleva datos personales');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('11'), 'VALIDADO|180000|150000|30000|||||t', 'un reintento de quien ya lo validó: ya_estaba, sin cifras de deuda');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '320000|180000', 'no acredita dos veces');
select is(pg_temp.n_audit('ticket_validado', '11'), 1::bigint, 'ni deja otro evento');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$), 'TV002 ',
          'otra persona (el ADMIN) sobre un ticket ya validado: TV002');
select is(pg_temp.mensaje_de($$ select * from public.validar_ticket(pg_temp.u('11')) $$),
          'Este ticket ya no está pendiente: otra persona lo resolvió. Recargá la lista para ver cómo quedó.', 'con su aviso');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('11'), 'tarde') $$), 'TV002 ', 'ni lo rechaza después');

-- Pago de más: queda a favor (deuda negativa).
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('12'), 'VALIDADO|800000|0|800000|320000|0|480000|480000|f',
          'pago de más: 800000 contra 320000 supera por 480000 y queda 480000 a favor');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-480000|980000', 'la deuda queda en -480000 (a favor) y Depositado sube');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.pr('2b'), '|CASA_EDITORA|500000|0|500000|-480000|0|500000|980000',
          'el saldo a favor se descuenta de la próxima deuda: el próximo depósito lo suma a lo que ya estaba a favor');

-- Alquiler: no toca la deuda con la casa editora y se cuenta por campaña.
select is(pg_temp.vt('13'), 'VALIDADO|80000|0|80000|50000|0|30000|30000|f', 'alquiler: supera la deuda de la campaña por 30000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-480000|1060000', 'la deuda con la casa editora no cambia; Depositado sube 80000');
select is(pg_temp.validado('23'), true, 'y su depósito queda validado');

-- Cobro con tarjeta: el ticket acredita su monto como casa editora y no tiene depósito.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('14'), 'VALIDADO|120000|120000|0|-480000|0|120000|600000|f', 'cobro con tarjeta: acredita 120000');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-600000|1180000', 'la deuda baja y Depositado sube');
select is(pg_temp.estado_t('14'), 'VALIDADO', 'el ticket queda validado');

-- Un ticket de otro tipo: validado, sin acreditar.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('15'), 'VALIDADO' || repeat('|', 7) || '|f', 'un ticket de otro tipo queda validado sin cifras');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-600000|1180000', 'y no toca la cuenta');
select is(pg_temp.estado_t('15'), 'VALIDADO', 'queda validado');

-- Los errores de validar.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('16')) $$), 'TV005 ',
          'ticket de depósito cuyo depósito no llegó: TV005');
select is(pg_temp.mensaje_de($$ select * from public.validar_ticket(pg_temp.u('16')) $$),
          'Todavía no llegó el depósito de este ticket: el teléfono del colportor tiene que sincronizar. Probá de nuevo más tarde.',
          'con su aviso');
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('17')) $$), 'TV004 ', 'ticket de tarjeta sin monto: TV004');
select is(pg_temp.rt('17', repeat('x', 500)), 'RECHAZADO|0|f', 'un motivo de justo 500 caracteres pasa (y un ticket de tarjeta no libera cobros)');
select is(pg_temp.estado_t('16'), 'PENDIENTE', 'el de TV005 sigue pendiente');
select is(pg_temp.estado_t('17'), 'RECHAZADO', 'el de TV004 se pudo rechazar en cambio');

-- El ADMIN valida el de cualquier campaña; la cuenta dada de baja se reactiva desde cero.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.vt('19'), 'VALIDADO|60000|0|60000|0|0|60000|60000|f', 'el ADMIN valida el ticket de b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b2'), '-60000|60000', 'la cuenta de b2, que estaba dada de baja, se reactiva desde cero');

-- Una cuenta que no existía se crea.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.vt('1e'), 'VALIDADO|1000|0|1000|0|0|1000|1000|f', 'b3 no tenía cuenta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b3'), '-1000|1000', 'y se crea con lo acreditado');

-- ---------------------------------------------------------------------------
-- 5. Rechazar
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('18'), null) $$), 'TV003 ', 'sin motivo: TV003');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('18'), '   ') $$), 'TV003 ', 'motivo en blanco: TV003');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('18'), repeat('x', 501)) $$), 'TV003 ', 'de más de 500: TV003');
select is(pg_temp.mensaje_de($$ select * from public.rechazar_ticket(pg_temp.u('18'), '') $$),
          'Escribí el motivo del rechazo (hasta 500 caracteres) para que el colportor sepa qué corregir.', 'con su aviso');
select is(pg_temp.estado_t('18'), 'PENDIENTE', 'sigue pendiente');
select is(pg_temp.rt('18', '   El monto no coincide con el cobro  '), 'RECHAZADO|2|f',
          'rechazar: libera los dos vínculos del depósito');
select pg_temp.actuar_como_servidor();
select is((select motivo_rechazo from public.ticket where id = pg_temp.u('18')), 'El monto no coincide con el cobro',
          'el motivo se guarda recortado');
select is((select (estado = 'RECHAZADO' and revisado_por = pg_temp.u('c1') and revisado_en is not null)
             from public.ticket where id = pg_temp.u('18')), true, 'ticket RECHAZADO, con quién y cuándo');
select is((select count(*)::int from public.deposito_cobro where deposito_id = pg_temp.u('28') and deleted_at is not null),
          2, 'los vínculos del depósito quedan dados de baja');
select is(pg_temp.validado('28'), false, 'el depósito no se valida');
select is(pg_temp.cuenta('b1'), '-600000|1180000', 'la cuenta no cambia: la deuda no cambia');
select is(pg_temp.n_audit('ticket_rechazado', '18'), 1::bigint, 'deja un evento en la auditoría');
select is(pg_temp.audit_claves('ticket_rechazado', '18'), array['cobros_liberados', 'tipo'], 'con solo el tipo y los cobros liberados');
select ok(position('coincide' in pg_temp.audit_meta('ticket_rechazado', '18')) = 0, 'el motivo escrito no se copia a la auditoría');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.rt('18', 'El monto no coincide con el cobro'), 'RECHAZADO|0|t', 'un reintento con el mismo motivo: ya_estaba');
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('18'), 'Otro motivo') $$), 'TV002 ',
          'con otro motivo: TV002');
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('18')) $$), 'TV002 ', 'un ticket rechazado no se valida');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n_audit('ticket_rechazado', '18'), 1::bigint, 'el reintento no suma eventos');

-- El colportor sube el depósito nuevo y vuelve a incluir el cobro que había quedado libre.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('40'), 30000, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('1d')) $$), 'ok',
          'b1 sube el depósito nuevo con el ticket corregido');
select is(pg_temp.error_de($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                              values (pg_temp.u('41'), pg_temp.u('40'), pg_temp.u('a3')) $$), 'ok',
          'y vuelve a incluir el cobro que estaba en el depósito rechazado');

-- El depósito y sus vínculos llegan DESPUÉS de que el ticket fue rechazado (otro lote del push): el vínculo nace
-- dado de baja y el cobro queda libre para el depósito corregido.
select pg_temp.actuar_como_servidor();
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('3a'), pg_temp.u('b1'), 'DEPOSITO', 22222, now(), 'PENDIENTE'),
  (pg_temp.u('3c'), pg_temp.u('b1'), 'DEPOSITO', 22222, now(), 'PENDIENTE');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.rt('3a', 'No se lee la foto'), 'RECHAZADO|0|f', 'se rechaza antes de que llegue el depósito: nada que liberar');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('3b'), 22222, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('3a')) $$), 'ok',
          'después llega el depósito del ticket rechazado');
select is(pg_temp.error_de($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                              values (pg_temp.u('3e'), pg_temp.u('3b'), pg_temp.u('a9')) $$), 'ok',
          'y su vínculo con el cobro: entra sin error');
select pg_temp.actuar_como_servidor();
select is((select deleted_at is not null from public.deposito_cobro where id = pg_temp.u('3e')), true,
          'pero nace dado de baja: el cobro no queda atrapado');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('3d'), 22222, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('3c')) $$), 'ok',
          'b1 sube el depósito corregido');
select is(pg_temp.error_de($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                              values (pg_temp.u('3f'), pg_temp.u('3d'), pg_temp.u('a9')) $$), 'ok',
          'y vuelve a incluir el mismo cobro (sin 23505)');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select format('%s|%s', p.cobros_vinculados, p.diferencia) from public.validacion_de_ticket(pg_temp.u('3c')) p),
          '22222|0', 'la vista previa del corregido ve su cobro y no marca diferencia');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.deposito_cobro where cobranza_id = pg_temp.u('a9') and deleted_at is null), 1,
          'el cobro está en un solo depósito vivo');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.rechazar_ticket(pg_temp.u('3a'), 'Otra vez') $$), 'TV002 ',
          'rechazar el mismo ticket otra vez da TV002, y ya no hace falta');
select pg_temp.actuar_como_servidor();
select has_trigger('public', 'deposito_cobro', 'deposito_cobro_de_ticket_rechazado', 'el trigger que da de baja el vínculo tardío');

-- ---------------------------------------------------------------------------
-- 6. Confirmar un retiro sin ticket
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('2b'), 'VALIDADO|500000|0|500000|-600000|0|500000|1100000|f',
          'c1 confirma el retiro de 500000: se acredita como casa editora');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-1100000|1680000', 'la cuenta de b1 sube y baja');
select is((select (validado_por = pg_temp.u('c1') and validado_en is not null) from public.deposito where id = pg_temp.u('2b')),
          true, 'el retiro queda validado, por c1');
select is(pg_temp.n_audit('retiro_confirmado', '2b'), 1::bigint, 'deja un evento en la auditoría');
select is(pg_temp.audit_claves('retiro_confirmado', '2b'),
          array['cobros_vinculados', 'concepto', 'deuda_antes', 'deuda_despues', 'monto'], 'con solo montos y ids');
select is(pg_temp.audit_texto('retiro_confirmado', '2b'), format('(%s,%s,deposito)', pg_temp.u('c1'), pg_temp.u('b1')),
          'quién, sobre quién y en qué tabla');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('2b'), 'VALIDADO|500000|0|500000' || repeat('|', 4) || '|t', 'un reintento de c1: ya_estaba');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('2b')) $$), 'DP004 ', 'otra persona: DP004');
select is(pg_temp.mensaje_de($$ select * from public.confirmar_retiro(pg_temp.u('2b')) $$),
          'Este retiro ya lo confirmó otra persona. Recargá la lista para ver cómo quedó.', 'con su aviso');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-1100000|1680000', 'el reintento y el error no acreditan de nuevo');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.cr('30'), 'VALIDADO|6000|0|6000|0|0|6000|36000|f', 'un retiro de alquiler: se compara con la deuda de la campaña');
select pg_temp.actuar_como_servidor();
select is(pg_temp.cuenta('b1'), '-1100000|1686000', 'el alquiler suma a Depositado y no toca la deuda con la casa editora');

-- ---------------------------------------------------------------------------
-- 7. Un depósito validado no se edita; el teléfono no se valida solo
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de($$ update public.deposito set monto = 1 where id = pg_temp.u('21') $$), 'DP001 ',
          'el servidor no cambia el monto de un depósito validado');
select is(pg_temp.error_de($$ update public.deposito set deleted_at = now() where id = pg_temp.u('21') $$), 'DP001 ',
          'ni lo da de baja');
select is(pg_temp.error_de($$ update public.deposito set validado_en = null, validado_por = null where id = pg_temp.u('21') $$), 'DP001 ',
          'ni le saca la validación');
select is(pg_temp.error_de($$ update public.deposito set concepto = 'ALQUILER', campania_id = pg_temp.u('e1') where id = pg_temp.u('21') $$),
          'DP001 ', 'ni le cambia el concepto');
select is(pg_temp.error_de($$ update public.deposito set fecha = fecha + interval '1 day' where id = pg_temp.u('21') $$), 'DP001 ', 'ni la fecha');
select is(pg_temp.error_de($$ update public.deposito set colportor_id = pg_temp.u('b3') where id = pg_temp.u('21') $$), 'DP001 ', 'ni la dueña');
select is(pg_temp.error_de($$ update public.deposito set ticket_id = null where id = pg_temp.u('21') $$), 'DP001 ', 'ni el ticket');
select is(pg_temp.error_de($$ update public.deposito set destino = 'OFICINA' where id = pg_temp.u('21') $$), 'DP001 ', 'ni el destino');
select is(pg_temp.error_de($$ update public.deposito set campania_id = pg_temp.u('e1') where id = pg_temp.u('21') $$), 'DP001 ', 'ni la campaña');
select is(pg_temp.error_de($$ update public.deposito set validado_por = pg_temp.u('ad') where id = pg_temp.u('21') $$), 'DP001 ', 'ni quién validó');
select is(pg_temp.error_de($$ update public.deposito set validado_en = now() where id = pg_temp.u('21') $$), 'DP001 ', 'ni cuándo');
select is(pg_temp.error_de($$ update public.deposito set updated_at = now() where id = pg_temp.u('21') $$), 'ok',
          'lo que no cambia ningún dato no falla');
select is(pg_temp.error_de($$ update public.deposito set monto = 25000 where id = pg_temp.u('2c') $$), 'ok',
          'uno sin validar, el servidor lo corrige');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, validado_en, validado_por)
                              values (pg_temp.u('42'), 1000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', now(), pg_temp.u('b1')) $$),
          '42501 ', 'b1 no se carga un depósito ya validado por la API directa: 42501');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, validado_por)
                              values (pg_temp.u('44'), 1000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', pg_temp.u('b1')) $$),
          '42501 ', 'ni solo con quién validó: 42501');
select is(pg_temp.mensaje_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, validado_en)
                               values (pg_temp.u('42'), 1000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', now()) $$),
          'Un depósito lo valida tu coordinador, no se carga desde el teléfono. Registralo sin validar y esperá su confirmación.',
          'con su aviso');
select is(pg_temp.push1(pg_temp.op('01'), 'deposito', 'insert',
                        jsonb_build_object('id', pg_temp.u('43'), 'monto', 4000, 'fecha', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
                                           'destino', 'RETIRO_COORDINADOR', 'concepto', 'CASA_EDITORA',
                                           'validado_en', '2026-10-27T00:00:00Z', 'validado_por', pg_temp.u('b1'))) ->> 'outcome',
          'accepted', 'por el push, la validación del payload se descarta y el depósito entra sin validar');
select pg_temp.actuar_como_servidor();
select is(pg_temp.validado('43'), false, 'queda por validar');
select is((select validado_por from public.deposito where id = pg_temp.u('43')), null::uuid, 'sin quién validó');

-- Bordes de los permisos.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.validar_ticket(pg_temp.u('1f')) $$), 'TV001 ', 'un ticket dado de baja no existe: TV001');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('34')) $$), 'DP002 ',
          'un retiro de la campaña de otra coordinadora: DP002, aunque la fecha caiga en la de c1');
select is(pg_temp.error_de($$ select * from public.confirmar_retiro(pg_temp.u('35')) $$), '42501 ',
          'c1 no confirma un retiro propio: 42501');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 8. cuentas_de_campania: el alquiler pagado es lo validado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select c.alquiler_pagado from public.cuentas_de_campania(pg_temp.u('e1')) c where c.colportor_id = pg_temp.u('b1')),
          186000::bigint, 'alquiler pagado = 100000 (ya validado) + 80000 (ticket validado) + 6000 (retiro confirmado)');
select is((select c.alquiler_por_validar from public.cuentas_de_campania(pg_temp.u('e1')) c where c.colportor_id = pg_temp.u('b1')),
          40000::bigint, 'por validar = el retiro sin confirmar (25000) + el ticket pendiente (15000); no el rechazado (7000)');
select is((select c.alquiler_debe from public.cuentas_de_campania(pg_temp.u('e1')) c where c.colportor_id = pg_temp.u('b1')),
          0::bigint, 'debe 0: el excedente es el saldo a favor (pagado - monto)');
select is((select c.alquiler_ultimo_pago_fecha = now() from public.cuentas_de_campania(pg_temp.u('e1')) c
            where c.colportor_id = pg_temp.u('b1')), true,
          'con la fecha del último pago validado (no la del retiro sin confirmar, que es más nueva)');
select is((select format('%s|%s', c.deuda_total, c.dinero_depositado)
             from public.cuentas_de_campania(pg_temp.u('e1')) c where c.colportor_id = pg_temp.u('b1')),
          '-1100000|1686000', 'las cifras de la cuenta de b1: la deuda a favor y Depositado');

select * from finish();
rollback;
