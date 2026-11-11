-- pgTAP · migración 0072 (backend-supabase#133, decisiones de Cristian del 23/10 «Datos cobro»,
-- «Anulación» y «Anular 72 h»): el cobro guarda los datos de la tarjeta y de la transferencia, y se puede
-- anular con fecha y motivo, dentro de las 72 h, por la colportora y por el coordinador.
--   1. La forma: columnas nuevas, restricciones, trigger, privilegios.
--   2. Los datos de la tarjeta y de la transferencia: opcionales, largos y coherencia con el medio.
--   3. La forma de la anulación: fecha y motivo juntos, motivo de la lista.
--   4. La ventana de 72 h desde el cobro, para la colportora (hora 71, 72 justas, 73).
--   5. El ticket validado: la colportora no anula, el coordinador sí; el ticket no se esquiva.
--   5b. La fecha del cobro y un ticket validado no se mueven en un UPDATE anterior a anular (CB006, CB005),
--       tampoco por push.
--   6. Un cobro anulado no se reabre; el mismo valor es idempotente; el servidor sí puede corregir.
--   7. anular_cobro() del coordinador: permisos, motivo, ventana, idempotencia.
--   8. Por sync_push: la anulación entra, vuelve invalid con su código sin tumbar el lote, y un reenvío
--      del alta no se juzga de nuevo.
--   9. El saldo de la cuota (AG002) no cuenta el cobro anulado.
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
  select ('01920000-0000-7000-8000-0000000072' || p)::uuid;
$$;
-- El id de un cobro (n hasta 65535).
create or replace function pg_temp.uc(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000072' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Un cobro tal como lo inserta quien llama: 'ok' o el SQLSTATE.
create or replace function pg_temp.ins(
  p_n integer, p_medio text default 'EFECTIVO', p_fecha timestamptz default null, p_venta text default '51',
  p_tipo text default null, p_marca text default null, p_aprob text default null, p_ref text default null,
  p_banco text default null, p_anulado timestamptz default null, p_motivo text default null,
  p_ticket text default null)
returns text language plpgsql as $$
begin
  insert into public.cobranza (id, venta_id, monto, medio, fecha, tarjeta_tipo, tarjeta_marca, numero_aprobacion,
                               referencia_transferencia, banco_origen, anulado_at, motivo_anulacion, ticket_id)
  values (pg_temp.uc(p_n), pg_temp.u(p_venta), 1000, p_medio, coalesce(p_fecha, now()), p_tipo, p_marca, p_aprob,
          p_ref, p_banco, p_anulado, p_motivo, pg_temp.u(p_ticket));
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Anular un cobro como quien llama (UPDATE directo): 'ok' o el SQLSTATE.
create or replace function pg_temp.anular(p_n integer, p_motivo text default 'Monto equivocado') returns text
language plpgsql as $$
begin
  update public.cobranza set anulado_at = now(), motivo_anulacion = p_motivo where id = pg_temp.uc(p_n);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.mensaje_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create or replace function pg_temp.anulado(p_n integer) returns boolean language sql as $$
  select anulado_at is not null from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000072d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- El job de anular un cobro que ya existe (update), con la versión de sync que tiene el servidor.
create or replace function pg_temp.job_anular(p_op text, p_n integer, p_motivo text default 'Monto equivocado')
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'cobranza', 'op', 'update',
                            'sync_version', (select c.sync_version from public.cobranza c where c.id = pg_temp.uc(p_n)),
                            'payload', jsonb_build_object('id', pg_temp.uc(p_n), 'anulado_at', now(),
                                                          'motivo_anulacion', p_motivo));
$$;
-- El job de alta de un cobro (insert), como lo sube el teléfono.
create or replace function pg_temp.job_alta(p_op text, p_n integer, p_fecha timestamptz, p_venta text default '51',
                                            p_anulado timestamptz default null, p_motivo text default null)
returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'cobranza', 'op', 'insert',
                            'sync_version', null,
                            'payload', jsonb_strip_nulls(jsonb_build_object(
                              'id', pg_temp.uc(p_n), 'venta_id', pg_temp.u(p_venta), 'monto', 1000, 'medio', 'EFECTIVO',
                              'fecha', p_fecha, 'anulado_at', p_anulado, 'motivo_anulacion', p_motivo,
                              'created_at', now())));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 (dueña de las ventas 51 y 54), b2 (venta 52) y b3 (venta 53) colportoras; d1 coordinador de la campaña
-- c5 (b1 y b3 inscriptos, la de b3 dada de baja); d2 coordinador de c6 (b2 inscripta); a1 ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cobro72-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','d1','d2','a1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('d2', 'COORDINADOR'), ('a1', 'ADMIN'),
               ('b1', 'COLPORTOR'), ('b2', 'COLPORTOR'), ('b3', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais cobro', 'ZC');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad cobro', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('c5'), 'Verano cobro', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1')),
  (pg_temp.u('c6'), 'Invierno cobro', 'INVIERNO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d2'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  (pg_temp.u('c5'), pg_temp.u('b1'), null, null),
  (pg_temp.u('c5'), pg_temp.u('b3'), null, now()),
  (pg_temp.u('c6'), pg_temp.u('b2'), null, null);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Cobro 01', '1', -34.91, -56.2, pg_temp.u('c1'), pg_temp.u('b1')),
  (pg_temp.u('02'), 'CASA', 'Cobro 02', '2', -34.92, -56.2, pg_temp.u('c1'), pg_temp.u('b2')),
  (pg_temp.u('03'), 'CASA', 'Cobro 03', '3', -34.93, -56.2, pg_temp.u('c1'), pg_temp.u('b3'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  (pg_temp.u('11'), pg_temp.u('01'), null, pg_temp.u('b1')),
  (pg_temp.u('12'), pg_temp.u('02'), null, pg_temp.u('b2')),
  (pg_temp.u('13'), pg_temp.u('03'), null, pg_temp.u('b3'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('21'), pg_temp.u('11'), pg_temp.u('a2'), pg_temp.u('b1')),
  (pg_temp.u('22'), pg_temp.u('12'), pg_temp.u('a3'), pg_temp.u('b2')),
  (pg_temp.u('23'), pg_temp.u('13'), pg_temp.u('a4'), pg_temp.u('b3'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u(x.ep), 'T-' || x.v, x.monto, now(), pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('51', '21', 1000000, 'b1'), ('52', '22', 1000000, 'b2'), ('53', '23', 1000000, 'b3'),
               ('54', '21', 50000, 'b1')) x(v, ep, monto, quien);
-- Los tickets (V2): e1 validado, e2 pendiente, e3 rechazado, e4 validado pero dado de baja.
insert into public.ticket (id, usuario_id, tipo, estado, revisado_por, revisado_en, motivo_rechazo, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), 'COBRO_TARJETA', 'VALIDADO', pg_temp.u('d1'), now(), null, null),
  (pg_temp.u('e2'), pg_temp.u('b1'), 'COBRO_TARJETA', 'PENDIENTE', null, null, null, null),
  (pg_temp.u('e3'), pg_temp.u('b1'), 'COBRO_TARJETA', 'RECHAZADO', pg_temp.u('d1'), now(), 'No se lee', null),
  (pg_temp.u('e4'), pg_temp.u('b1'), 'COBRO_TARJETA', 'VALIDADO', pg_temp.u('d1'), now(), null, now());
-- Los cobros de b1 (venta 51) a distintas horas. Los inserta el servidor: sin sesión nada se controla.
create or replace function pg_temp.fx(p_n integer, p_medio text default 'EFECTIVO', p_fecha timestamptz default null,
                                        p_venta text default '51', p_ticket text default null,
                                        p_anulado timestamptz default null, p_motivo text default null)
returns void language plpgsql as $$
declare
  v_r text := pg_temp.ins(p_n, p_medio, p_fecha, p_venta, p_ticket => p_ticket, p_anulado => p_anulado, p_motivo => p_motivo);
begin
  if v_r <> 'ok' then raise exception 'fixture del cobro %: %', p_n, v_r; end if;
end $$;
do $fx$
begin
  perform pg_temp.fx(1,  p_fecha => now() - interval '1 hour');
  perform pg_temp.fx(2,  p_fecha => now() - interval '71 hours');
  perform pg_temp.fx(3,  p_fecha => now() - interval '73 hours');
  perform pg_temp.fx(4,  p_fecha => now() - interval '72 hours');
  perform pg_temp.fx(5,  p_fecha => now() - interval '72 hours 1 second');
  perform pg_temp.fx(6,  'TARJETA', now() - interval '30 hours', p_ticket => 'e1');
  perform pg_temp.fx(7,  'TARJETA', now() - interval '30 hours', p_ticket => 'e2');
  perform pg_temp.fx(8,  'TARJETA', now() - interval '30 hours', p_ticket => 'e3');
  perform pg_temp.fx(9,  'TARJETA', now() - interval '30 hours', p_ticket => 'e4');
  perform pg_temp.fx(10, 'TARJETA', now() - interval '73 hours', p_ticket => 'e1');
  perform pg_temp.fx(11, 'TARJETA', now() - interval '30 hours', p_ticket => 'e1');
  perform pg_temp.fx(12, p_fecha => now() - interval '1 hour', p_anulado => now() - interval '30 minutes',
                   p_motivo => 'Monto equivocado');
  perform pg_temp.fx(13, p_fecha => now() - interval '1 hour', p_venta => '52');
  perform pg_temp.fx(14, p_fecha => now() - interval '30 hours');
  perform pg_temp.fx(15, p_fecha => now() - interval '30 hours');
  update public.cobranza set deleted_at = now() where id = pg_temp.uc(15);
  perform pg_temp.fx(16, p_fecha => now() - interval '73 hours');
  perform pg_temp.fx(17, p_fecha => now() - interval '30 hours', p_venta => '52');
  perform pg_temp.fx(18, p_fecha => now() - interval '30 hours', p_venta => '53');
  perform pg_temp.fx(19, p_fecha => now() - interval '1 hour');
  perform pg_temp.fx(20, p_fecha => now() - interval '73 hours');
  perform pg_temp.fx(21, 'TARJETA', now() - interval '30 hours', p_ticket => 'e1');
  perform pg_temp.fx(22, p_fecha => now() - interval '1 hour');
  perform pg_temp.fx(23, p_fecha => now() - interval '1 hour');
  perform pg_temp.fx(24, p_fecha => now() - interval '1 hour', p_venta => '54');
  update public.cobranza set monto = 30000 where id = pg_temp.uc(24);
  perform pg_temp.fx(25, p_fecha => now() - interval '73 hours');
  perform pg_temp.fx(26, 'TARJETA', now() - interval '30 hours', p_ticket => 'e1');
  perform pg_temp.fx(27, 'TARJETA', now() - interval '30 hours', p_ticket => 'e3');
  perform pg_temp.fx(28, 'TARJETA', now() - interval '30 hours', p_ticket => 'e2');
  perform pg_temp.fx(29, p_fecha => now() - interval '30 hours');
  perform pg_temp.fx(95, 'TARJETA', now() - interval '30 hours', p_ticket => 'e1');
end
$fx$;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'cobranza', 'tarjeta_tipo', 'text', 'cobranza.tarjeta_tipo es texto');
select col_type_is('public', 'cobranza', 'tarjeta_marca', 'text', 'cobranza.tarjeta_marca es texto');
select col_type_is('public', 'cobranza', 'numero_aprobacion', 'text', 'cobranza.numero_aprobacion es texto');
select col_type_is('public', 'cobranza', 'referencia_transferencia', 'text', 'cobranza.referencia_transferencia es texto');
select col_type_is('public', 'cobranza', 'banco_origen', 'text', 'cobranza.banco_origen es texto, no una lista cerrada');
select col_type_is('public', 'cobranza', 'ticket_id', 'uuid', 'cobranza.ticket_id es uuid');
select col_type_is('public', 'cobranza', 'anulado_at', 'timestamp with time zone', 'cobranza.anulado_at es timestamptz');
select col_type_is('public', 'cobranza', 'motivo_anulacion', 'text', 'cobranza.motivo_anulacion es texto');
select is((select count(*)::int from pg_attribute a
            where a.attrelid = 'public.cobranza'::regclass and a.attnum > 0 and not a.attisdropped
              and a.attname in ('tarjeta_tipo','tarjeta_marca','numero_aprobacion','referencia_transferencia',
                                'banco_origen','ticket_id','anulado_at','motivo_anulacion') and not a.attnotnull), 8,
          'las ocho columnas son opcionales: la migración solo suma');
select is((select count(*)::int from public.cobranza
            where tarjeta_tipo is not null or tarjeta_marca is not null or numero_aprobacion is not null
               or referencia_transferencia is not null or banco_origen is not null),
          0, 'ningún cobro de antes trae datos de tarjeta ni de transferencia');
select is((select array_agg(tgname::text order by tgname::text collate "C") from pg_trigger
            where tgrelid = 'public.cobranza'::regclass and not tgisinternal and (tgtype & 4) = 4),
          array['cobranza_anulacion', 'cobranza_auditoria_insert', 'cobranza_avisa_al_ticket', 'cobranza_ticket_propio'],
          'al insertar corren, en este orden, el control de la anulación, la auditoría, (desde 0146, AFTER) el aviso al ticket y (desde 0113) que el ticket sea de quien vendió');
select is((select array_agg(tgname::text order by tgname::text collate "C") from pg_trigger
            where tgrelid = 'public.cobranza'::regclass and not tgisinternal and (tgtype & 16) = 16),
          array['cobranza_anulacion', 'cobranza_auditoria_update', 'cobranza_avisa_al_ticket', 'cobranza_ticket_propio'],
          'y al actualizar también');
select ok(not has_function_privilege('authenticated', 'public.tg_cobranza_anulacion()', 'execute')
          and not has_function_privilege('anon', 'public.tg_cobranza_anulacion()', 'execute'),
          'la función del trigger no la ejecuta nadie desde afuera');
select ok(has_function_privilege('authenticated', 'public.anular_cobro(uuid, text)', 'execute')
          and not has_function_privilege('anon', 'public.anular_cobro(uuid, text)', 'execute')
          and not has_function_privilege('service_role', 'public.anular_cobro(uuid, text)', 'execute'),
          'anular_cobro() la ejecuta authenticated y nadie más');
select ok((select prosecdef from pg_proc where oid = 'public.anular_cobro(uuid, text)'::regprocedure)
          and (select proconfig::text from pg_proc where oid = 'public.anular_cobro(uuid, text)'::regprocedure) like '%search_path=%'
          and (select prosecdef from pg_proc where oid = 'public.tg_cobranza_anulacion()'::regprocedure),
          'la RPC y el trigger son SECURITY DEFINER con search_path fijo');
select is((select permite_push from sync.entidad where nombre = 'cobranza'), true, 'el cobro sigue en el push');
select is((select array_agg(policyname::text order by policyname::text collate "C") from pg_policies
            where schemaname = 'public' and tablename = 'cobranza'),
          array['cobranza_propio'], 'la RLS sigue siendo una sola: la de la dueña de la venta');
select has_index('public', 'cobranza', 'cobranza_ticket_idx', 'el ticket_id tiene su índice');

-- ---------------------------------------------------------------------------
-- 2. Los datos de la tarjeta y de la transferencia
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ins(30, 'TARJETA'), 'ok', 'un cobro con tarjeta sin ningún dato extra entra (opcionales en V1)');
select is(pg_temp.ins(31, 'TARJETA', p_tipo => 'DEBITO', p_marca => 'Visa', p_aprob => '123456'), 'ok',
          'con débito, marca y aprobación entra');
select is(pg_temp.ins(32, 'TARJETA', p_tipo => 'CREDITO', p_marca => 'Mastercard'), 'ok', 'con crédito y marca, sin aprobación, también');
select is((select tarjeta_tipo || '/' || tarjeta_marca || '/' || numero_aprobacion from public.cobranza where id = pg_temp.uc(31)),
          'DEBITO/Visa/123456', 'y se guarda tal cual');
select is(pg_temp.ins(33, 'TARJETA', p_tipo => 'debito'), '23514', 'el tipo en minúsculas no');
select is(pg_temp.ins(34, 'TARJETA', p_tipo => 'PREPAGA'), '23514', 'ni un tipo inventado');
select is(pg_temp.ins(35, 'TARJETA', p_marca => ''), '23514', 'una marca vacía no');
select is(pg_temp.ins(36, 'TARJETA', p_marca => '   '), '23514', 'ni una marca en blanco');
select is(pg_temp.ins(37, 'TARJETA', p_marca => repeat('M', 40)), 'ok', 'una marca de 40 caracteres entra');
select is(pg_temp.ins(38, 'TARJETA', p_marca => repeat('M', 41)), '23514', 'una de 41 no');
select is(pg_temp.ins(39, 'TARJETA', p_aprob => ''), '23514', 'una aprobación vacía no');
select is(pg_temp.ins(40, 'TARJETA', p_aprob => repeat('9', 40)), 'ok', 'una aprobación de 40 entra');
select is(pg_temp.ins(41, 'TARJETA', p_aprob => repeat('9', 41)), '23514', 'una de 41 no');
select is(pg_temp.ins(42, 'TRANSFERENCIA'), 'ok', 'una transferencia sin referencia ni banco entra');
select is(pg_temp.ins(43, 'TRANSFERENCIA', p_ref => '88213', p_banco => 'BROU'), 'ok', 'con referencia y banco entra');
select is(pg_temp.ins(44, 'TRANSFERENCIA', p_banco => 'Banco de la Plaza Sociedad Anónima'), 'ok', 'un banco que no está en la lista del canvas también: es texto');
select is(pg_temp.ins(45, 'TRANSFERENCIA', p_ref => ''), '23514', 'una referencia vacía no');
select is(pg_temp.ins(46, 'TRANSFERENCIA', p_ref => repeat('1', 40)), 'ok', 'una referencia de 40 entra');
select is(pg_temp.ins(47, 'TRANSFERENCIA', p_ref => repeat('1', 41)), '23514', 'una de 41 no');
select is(pg_temp.ins(48, 'TRANSFERENCIA', p_banco => ''), '23514', 'un banco vacío no');
select is(pg_temp.ins(49, 'TRANSFERENCIA', p_banco => repeat('B', 60)), 'ok', 'un banco de 60 entra');
select is(pg_temp.ins(50, 'TRANSFERENCIA', p_banco => repeat('B', 61)), '23514', 'uno de 61 no');
-- Coherencia con el medio.
select is(pg_temp.ins(51, 'EFECTIVO', p_marca => 'Visa'), '23514', 'el efectivo no lleva marca');
select is(pg_temp.ins(52, 'EFECTIVO', p_tipo => 'DEBITO'), '23514', 'ni tipo de tarjeta');
select is(pg_temp.ins(53, 'EFECTIVO', p_aprob => '1'), '23514', 'ni aprobación');
select is(pg_temp.ins(54, 'EFECTIVO', p_ref => '1'), '23514', 'ni referencia de transferencia');
select is(pg_temp.ins(55, 'EFECTIVO', p_banco => 'BROU'), '23514', 'ni banco');
select is(pg_temp.ins(56, 'TRANSFERENCIA', p_marca => 'Visa'), '23514', 'la transferencia no lleva marca');
select is(pg_temp.ins(57, 'TRANSFERENCIA', p_tipo => 'CREDITO'), '23514', 'ni tipo de tarjeta');
select is(pg_temp.ins(58, 'TRANSFERENCIA', p_aprob => '1'), '23514', 'ni aprobación');
select is(pg_temp.ins(59, 'TARJETA', p_ref => '1'), '23514', 'la tarjeta no lleva referencia de transferencia');
select is(pg_temp.ins(60, 'TARJETA', p_banco => 'BROU'), '23514', 'ni banco de origen');
select is(pg_temp.error_de($$ update public.cobranza set medio = 'EFECTIVO' where id = pg_temp.uc(31) $$), '23514',
          'y cambiar un cobro con datos de tarjeta a efectivo, sin sacarlos, tampoco');

-- ---------------------------------------------------------------------------
-- 3. La forma de la anulación
-- ---------------------------------------------------------------------------
select is(pg_temp.ins(70, p_anulado => now()), '23514', 'una fecha de anulación sin motivo no');
select is(pg_temp.ins(71, p_motivo => 'Monto equivocado'), '23514', 'ni un motivo sin fecha');
select is(pg_temp.ins(72, p_anulado => now(), p_motivo => 'Porque sí'), '23514', 'ni un motivo que no es de la lista');
select is(pg_temp.ins(73, p_anulado => now(), p_motivo => 'otro'), '23514', 'ni «otro» en minúsculas');
select is(pg_temp.ins(74, p_anulado => now(), p_motivo => 'Monto equivocado'), 'ok', '«Monto equivocado» entra');
select is(pg_temp.ins(75, p_anulado => now(), p_motivo => 'Cliente equivocado'), 'ok', '«Cliente equivocado» entra');
select is(pg_temp.ins(76, p_anulado => now(), p_motivo => 'Lo registré dos veces'), 'ok', '«Lo registré dos veces» entra');
select is(pg_temp.ins(77, p_anulado => now(), p_motivo => 'Otro'), 'ok', '«Otro» entra (lo que escribió no sube)');
select is(pg_temp.ins(78, p_anulado => null, p_motivo => null), 'ok', 'un cobro sin anular sigue entrando');
select is(pg_temp.error_de($$ update public.cobranza set motivo_anulacion = 'Otro' where id = pg_temp.uc(1) $$), '23514',
          'poner el motivo sin la fecha en un cobro vivo tampoco');

-- ---------------------------------------------------------------------------
-- 4. La ventana de 72 h desde el cobro (la colportora b1)
-- ---------------------------------------------------------------------------
select is(pg_temp.anular(1), 'ok', 'a la hora 1 anula');
select is(pg_temp.anulado(1), true, 'y queda anulado');
select is((select motivo_anulacion from public.cobranza where id = pg_temp.uc(1)), 'Monto equivocado', 'con su motivo');
select is(pg_temp.anular(2, 'Cliente equivocado'), 'ok', 'a la hora 71 anula');
select is(pg_temp.anular(4, 'Lo registré dos veces'), 'ok', 'a las 72 justas todavía anula (el plazo es inclusive)');
select is(pg_temp.anular(5), 'CB001', 'a las 72 h y un segundo ya no');
select is(pg_temp.anulado(5), false, 'y el cobro sigue vivo');
select is(pg_temp.anular(3), 'CB001', 'a la hora 73 no');
select is(pg_temp.anulado(3), false, 'y sigue vivo');
select is(pg_temp.mensaje_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro' where id = pg_temp.uc(3) $$),
          'CB001: Pasaron más de 72 horas desde el cobro: ya no se puede anular.', 'el mensaje dice qué pasó');
select is(pg_temp.ins(80, p_fecha => now() - interval '71 hours', p_anulado => now(), p_motivo => 'Otro'), 'ok',
          'un cobro nuevo que ya llega anulado a la hora 71 entra');
select is(pg_temp.ins(81, p_fecha => now() - interval '73 hours', p_anulado => now(), p_motivo => 'Otro'), 'CB001',
          'uno que llega anulado a la hora 73 no');
select is((select count(*)::int from public.cobranza where id = pg_temp.uc(81)), 0, 'y no se guardó');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(3) $$), 'CB007',
          'cambiar el monto de un cobro pasadas las 72 h ya no se puede: el cobro quedó fijo (0131)');
select is(pg_temp.error_de($$ update public.cobranza set monto = monto where id = pg_temp.uc(3) $$), 'ok',
          'pero el reenvío idéntico de un cobro viejo pasa');
select is(pg_temp.anular(19), 'ok', 'otro cobro de la hora 1 (el 19)');
-- Desde 0131 el reloj que cuenta es la hora del teléfono (anulado_at): una hora fuera de las 72 h desde el cobro no vale.
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = now() - interval '30 minutes', motivo_anulacion = 'Otro'
                               where id = pg_temp.uc(20) $$), 'CB001',
          'una hora de anulación a las 72 h y 30 min del cobro (cobro de hace 73 h) no vale');
select is(pg_temp.anulado(20), false, 'y el cobro sigue vivo');
-- Otra colportora no toca el cobro de b1: la RLS lo esconde.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.anular(22), 'ok', 'b2 intenta anular un cobro de b1: no ve la fila (0 filas, sin efecto)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(22), false, 'y el cobro de b1 sigue vivo');

-- ---------------------------------------------------------------------------
-- 5. El ticket validado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.anular(6), 'CB002', 'con el ticket validado, la colportora no anula');
select is(pg_temp.mensaje_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro' where id = pg_temp.uc(6) $$),
          'CB002: El coordinador ya validó el ticket de este cobro. Pedile que lo anule él.', 'y el mensaje le dice a quién pedírselo');
select is(pg_temp.anulado(6), false, 'el cobro sigue vivo');
select is(pg_temp.anular(7), 'ok', 'con el ticket pendiente anula');
select is(pg_temp.anular(8), 'ok', 'con el ticket rechazado anula');
select is(pg_temp.anular(9), 'ok', 'con el ticket validado pero dado de baja anula');
select is(pg_temp.anular(10), 'CB001', 'validado y a la hora 73: manda la ventana (nadie anula)');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = null, anulado_at = now(), motivo_anulacion = 'Otro'
                               where id = pg_temp.uc(11) $$), 'CB005',
          'soltar el ticket validado en el mismo UPDATE que anula tampoco se puede (CB005, antes de mirar la anulación)');
select is(pg_temp.anulado(11), false, 'y el cobro sigue vivo con su ticket');
select is((select ticket_id from public.cobranza where id = pg_temp.uc(11)), pg_temp.u('e1'), 'que sigue apuntando al ticket');
select is(pg_temp.ins(82, 'TARJETA', now() - interval '1 hour', p_ticket => 'e1', p_anulado => now(), p_motivo => 'Otro'), 'CB002',
          'un cobro nuevo que llega anulado con el ticket validado tampoco');

-- ---------------------------------------------------------------------------
-- 5b. Lo que sostiene la ventana y el ticket no se mueve en un UPDATE anterior (CB005, CB006)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
-- La fecha: correrla para adelante y después anular no esquiva las 72 h.
select is(pg_temp.error_de($$ update public.cobranza set fecha = now() where id = pg_temp.uc(25) $$), 'CB007',
          'mover la fecha de un cobro de la hora 73 a hoy no se puede (desde 0131 el cobro pasado el plazo está fijo: CB007)');
select is(pg_temp.mensaje_de($$ update public.cobranza set fecha = now() where id = pg_temp.uc(29) $$),
          'CB006: La fecha de un cobro no se puede cambiar. Si te equivocaste, anulalo y cargalo de nuevo.',
          'y dentro del plazo el mensaje dice qué hacer (CB006)');
select is(pg_temp.anular(25), 'CB001', 'y anular después sigue siendo CB001: la fecha no se movió');
select is((select fecha from public.cobranza where id = pg_temp.uc(25)) < now() - interval '72 hours', true, 'el cobro conserva su fecha');
select is(pg_temp.error_de($$ update public.cobranza set fecha = now() - interval '1 hour' where id = pg_temp.uc(29) $$), 'CB006',
          'tampoco hacia atrás ni en un cobro vivo');
select is(pg_temp.error_de($$ update public.cobranza set fecha = fecha, monto = 1100 where id = pg_temp.uc(29) $$), 'ok',
          'mandar la misma fecha (el teléfono sube la fila entera) no falla');
select is(pg_temp.error_de($$ update public.cobranza set fecha = fecha where id = pg_temp.uc(29) $$), 'ok', 'ni sin cambiar nada más');
-- El ticket validado: soltarlo o cambiarlo y después anular no esquiva CB002.
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = null where id = pg_temp.uc(26) $$), 'CB005',
          'soltar un ticket validado no se puede');
select is(pg_temp.mensaje_de($$ update public.cobranza set ticket_id = null where id = pg_temp.uc(26) $$),
          'CB005: El coordinador ya validó el ticket de este cobro: no se puede cambiar ni soltar.', 'y el mensaje dice qué pasó');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = pg_temp.u('e2') where id = pg_temp.uc(26) $$), 'CB005',
          'ni cambiarlo por otro');
select is(pg_temp.anular(26), 'CB002', 'y anular después sigue siendo CB002');
select is((select ticket_id from public.cobranza where id = pg_temp.uc(26)), pg_temp.u('e1'), 'el cobro sigue con su ticket validado');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = ticket_id where id = pg_temp.uc(26) $$), 'ok',
          'mandar el mismo ticket (fila entera) no falla');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = ticket_id, monto = 1100 where id = pg_temp.uc(26) $$), 'CB007',
          'pero con el ticket validado el monto ya no cambia (cobro fijo, 0131)');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = null where id = pg_temp.uc(27) $$), 'ok',
          'un ticket rechazado sí se suelta (para cargar otro)');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = pg_temp.u('e2') where id = pg_temp.uc(27) $$), 'ok',
          'y se puede colgar otro después');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = null where id = pg_temp.uc(28) $$), 'ok', 'un ticket pendiente también');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = pg_temp.u('e2') where id = pg_temp.uc(29) $$), 'ok',
          'y un cobro sin ticket puede recibir uno');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = null where id = pg_temp.uc(26) $$), 'ok',
          'sin sesión (servidor) sí se puede corregir un ticket');
select is(pg_temp.error_de($$ update public.cobranza set fecha = fecha - interval '1 hour' where id = pg_temp.uc(26) $$), 'ok',
          'y una fecha');
update public.cobranza set ticket_id = pg_temp.u('e1'), fecha = now() - interval '30 hours' where id = pg_temp.uc(26);
-- Lo mismo por el push: dos jobs seguidos, el de mover y el de anular, vuelven los dos invalid.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote2 as
select pg_temp.push(jsonb_build_array(
  jsonb_build_object('client_op_id', pg_temp.u('ca'), 'entity', 'cobranza', 'op', 'update',
                     'sync_version', (select c.sync_version from public.cobranza c where c.id = pg_temp.uc(25)),
                     'payload', jsonb_build_object('id', pg_temp.uc(25), 'fecha', now())),
  pg_temp.job_anular('cb', 25),
  jsonb_build_object('client_op_id', pg_temp.u('cc'), 'entity', 'cobranza', 'op', 'update',
                     'sync_version', (select c.sync_version from public.cobranza c where c.id = pg_temp.uc(95)),
                     'payload', jsonb_build_object('id', pg_temp.uc(95), 'ticket_id', null)),
  pg_temp.job_anular('cd', 95)
)) as r;
select is(pg_temp.codigos((select r from lote2)), array['CB007', 'CB001', 'CB005', 'CB002'],
          'por el push: mover la fecha (CB007, el cobro pasó el plazo) o soltar el ticket (CB005) y anular después sigue siendo CB001 / CB002');
select is(pg_temp.resultados((select r from lote2)), array['invalid', 'invalid', 'invalid', 'invalid'], 'los cuatro vuelven invalid sin tumbar el lote');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(25) or pg_temp.anulado(95), false, 'y ninguno de los dos cobros quedó anulado');
select is((select ticket_id from public.cobranza where id = pg_temp.uc(95)), pg_temp.u('e1'), 'ni perdió el ticket');
select pg_temp.actuar_como(pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 6. Un cobro anulado no se reabre
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = null, motivo_anulacion = null where id = pg_temp.uc(12) $$), 'CB003',
          'no se vuelve a habilitar');
select is(pg_temp.error_de($$ update public.cobranza set motivo_anulacion = 'Otro' where id = pg_temp.uc(12) $$), 'CB003',
          'ni se le cambia el motivo');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = now() where id = pg_temp.uc(12) $$), 'CB003',
          'ni la fecha');
select is(pg_temp.mensaje_de($$ update public.cobranza set motivo_anulacion = 'Otro' where id = pg_temp.uc(12) $$),
          'CB003: Este cobro ya está anulado y no se puede volver a habilitar ni cambiarle el motivo.', 'el mensaje dice qué pasó');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = (select c.anulado_at from public.cobranza c where c.id = pg_temp.uc(12)),
                                                      motivo_anulacion = 'Monto equivocado' where id = pg_temp.uc(12) $$), 'ok',
          'mandar de nuevo lo mismo es un reintento: no falla');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = (select c.anulado_at from public.cobranza c where c.id = pg_temp.uc(12)),
                                                      motivo_anulacion = 'Monto equivocado', monto = 2000 where id = pg_temp.uc(12) $$), 'ok',
          'también con otra columna cambiada: lo único que se cuida es la anulación');
-- Un cobro anulado hace más de 72 h sigue pudiendo recibir el mismo valor (el reintento llega tarde).
select pg_temp.actuar_como_servidor();
update public.cobranza set fecha = now() - interval '100 hours' where id = pg_temp.uc(12);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = (select c.anulado_at from public.cobranza c where c.id = pg_temp.uc(12)),
                                                      motivo_anulacion = 'Monto equivocado' where id = pg_temp.uc(12) $$), 'ok',
          'el reintento de una anulación vieja pasada la ventana no falla');
-- Sin sesión (el servidor) puede corregir lo que haga falta.
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = null, motivo_anulacion = null where id = pg_temp.uc(12) $$), 'ok',
          'el servidor (sin sesión) puede reabrir un cobro: es la salida para corregir a mano');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro' where id = pg_temp.uc(3) $$), 'ok',
          'y anular fuera de plazo');
select is(pg_temp.error_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro' where id = pg_temp.uc(6) $$), 'ok',
          'y con el ticket validado');

-- ---------------------------------------------------------------------------
-- 7. anular_cobro() del coordinador
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('d1'));
create temp table r14 as select public.anular_cobro(pg_temp.uc(14), 'Monto equivocado') as r;
grant select on r14 to authenticated;
select is((select r ->> 'ya_estaba' from r14), 'false', 'el coordinador de la campaña anula el cobro de su colportora (hora 30)');
select is((select r ->> 'motivo' from r14), 'Monto equivocado', 'y devuelve el motivo');
select is((select r ->> 'cobranza_id' from r14), pg_temp.uc(14)::text, 'y el cobro');
select pg_temp.actuar_como_servidor();
select is((select anulado_at from public.cobranza where id = pg_temp.uc(14)), now(), 'anulado_at es la hora del servidor');
select is((select motivo_anulacion from public.cobranza where id = pg_temp.uc(14)), 'Monto equivocado', 'con el motivo de la lista');
select ok((select (r ->> 'anulado_at')::timestamptz from r14) = now(), 'y la respuesta trae la misma fecha');
create temp table v14 as select sync_version from public.cobranza where id = pg_temp.uc(14);
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((public.anular_cobro(pg_temp.uc(14), 'Otro')) ->> 'ya_estaba', 'true', 'anular de nuevo devuelve ya_estaba');
select pg_temp.actuar_como_servidor();
select is((select motivo_anulacion from public.cobranza where id = pg_temp.uc(14)), 'Monto equivocado', 'y no pisa el motivo');
select is((select sync_version from public.cobranza where id = pg_temp.uc(14)), (select sync_version from v14),
          'ni sube la versión de sync: un doble toque no cuenta dos veces');
select is((select sync_version from v14) > 0, true, 'la anulación sí había subido la versión (el teléfono recibe conflict si manda algo viejo)');
-- Con el ticket validado, el coordinador sí anula (es lo que Cristian decidió).
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((public.anular_cobro(pg_temp.uc(21), 'Monto equivocado')) ->> 'ya_estaba', 'false',
          'con el ticket validado y dentro de las 72 h, el coordinador anula');
-- Pasadas las 72 h, nadie.
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(16), 'Monto equivocado') $$), 'CB001',
          'pasadas las 72 h, tampoco el coordinador');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(16), false, 'y el cobro sigue vivo');
-- Permisos.
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(23), 'Otro') $$), 'CB004',
          'el coordinador de OTRA campaña no ve el cobro: CB004');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(13), 'Otro') $$), 'ok', 'pero sí el de su colportora (b2)');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(17), 'Otro') $$), 'CB004', 'd1 no anula el cobro de b2');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(18), 'Otro') $$), 'CB004',
          'ni el de b3, cuya inscripción en su campaña está dada de baja');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(15), 'Otro') $$), 'CB004', 'ni un cobro dado de baja');
select is(pg_temp.error_de($$ select public.anular_cobro('01920000-0000-7000-8000-000000729999', 'Otro') $$), 'CB004',
          'ni uno que no existe: el mismo error, no se averigua qué cobros hay');
select is(pg_temp.mensaje_de($$ select public.anular_cobro('01920000-0000-7000-8000-000000729999', 'Otro') $$),
          'CB004: No encontramos ese cobro entre los de tu equipo.', 'y el mensaje dice qué pasó');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(19), null) $$), '22023', 'sin motivo, 22023');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(19), 'Porque sí') $$), '22023', 'con un motivo que no es de la lista, 22023');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(19), '') $$), '22023', 'con el motivo vacío, 22023');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(19), true, 'el 19 ya lo había anulado b1 (sección 4)');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((public.anular_cobro(pg_temp.uc(17), 'Cliente equivocado')) ->> 'ya_estaba', 'false', 'un ADMIN anula el cobro de cualquier equipo (b2)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(23), 'Otro') $$), '42501',
          'una colportora no usa la RPC del coordinador (ni para su propio cobro): 42501');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(13), 'Otro') $$), '42501', 'ni otra colportora');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(23), 'Otro') $$), '42501', 'sin sesión, 42501');
select set_config('role', 'anon', true);
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(23), 'Otro') $$), '42501', 'un anónimo no ejecuta la función');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(23), false, 'y el cobro 23 sigue vivo');

-- ---------------------------------------------------------------------------
-- 8. Por sync_push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote as
select pg_temp.push(jsonb_build_array(
  pg_temp.job_anular('aa', 22),                                        -- hora 1: entra
  pg_temp.job_anular('ab', 20),                                        -- hora 73: CB001
  pg_temp.job_anular('ac', 11),                                        -- ticket validado: CB002
  pg_temp.job_anular('ad', 14, 'Otro'),                                        -- ya anulado por el coordinador: CB003 si cambia
  pg_temp.job_alta('ae', 90, now() - interval '2 hours', '51', now(), 'Otro'),   -- alta ya anulada, dentro de plazo
  pg_temp.job_alta('af', 91, now() - interval '80 hours', '51', now(), 'Otro')   -- alta anulada fuera de plazo
)) as r;
grant select on lote to authenticated;
select is(pg_temp.resultados((select r from lote)), array['accepted', 'invalid', 'invalid', 'invalid', 'accepted', 'invalid'],
          'el lote: entra la de la hora 1, vuelven invalid las otras y el resto sigue');
select is(pg_temp.codigos((select r from lote)), array['-', 'CB001', 'CB002', 'CB003', '-', 'CB001'],
          'cada invalid trae su código: CB001 (fuera de plazo), CB002 (ticket validado), CB003 (ya anulado por otro)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(22), true, 'el cobro de la hora 1 quedó anulado');
select is(pg_temp.anulado(20), false, 'el de la hora 73 sigue vivo');
select is(pg_temp.anulado(11), false, 'el del ticket validado sigue vivo');
select is(pg_temp.anulado(90), true, 'el alta ya anulada dentro de plazo se guardó anulada');
select is((select count(*)::int from public.cobranza where id = pg_temp.uc(91)), 0, 'la de fuera de plazo no se guardó');
-- Un reenvío del alta (el teléfono no vio la respuesta) llega pasadas las 72 h: duplicate, no invalid.
update public.cobranza set fecha = now() - interval '100 hours' where id = pg_temp.uc(90);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            pg_temp.job_alta('ba', 90, now() - interval '100 hours', '51', now(), 'Otro')))),
          array['duplicate'], 'el reenvío de un alta ya anulada pasado el plazo es duplicate, no se juzga de nuevo');
-- La anulación entra con todos los datos de la tarjeta y de la transferencia en el mismo upsert.
select is(pg_temp.resultados(pg_temp.push(jsonb_build_array(
            jsonb_build_object('client_op_id', pg_temp.u('bb'), 'entity', 'cobranza', 'op', 'insert', 'sync_version', null,
                               'payload', jsonb_build_object('id', pg_temp.uc(92), 'venta_id', pg_temp.u('51'), 'monto', 1200,
                                 'medio', 'TARJETA', 'fecha', now(), 'tarjeta_tipo', 'CREDITO', 'tarjeta_marca', 'Visa',
                                 'numero_aprobacion', '445566', 'created_at', now())),
            jsonb_build_object('client_op_id', pg_temp.u('bc'), 'entity', 'cobranza', 'op', 'insert', 'sync_version', null,
                               'payload', jsonb_build_object('id', pg_temp.uc(93), 'venta_id', pg_temp.u('51'), 'monto', 800,
                                 'medio', 'TRANSFERENCIA', 'fecha', now(), 'referencia_transferencia', '88213',
                                 'banco_origen', 'Itaú', 'created_at', now())),
            jsonb_build_object('client_op_id', pg_temp.u('bd'), 'entity', 'cobranza', 'op', 'insert', 'sync_version', null,
                               'payload', jsonb_build_object('id', pg_temp.uc(94), 'venta_id', pg_temp.u('51'), 'monto', 800,
                                 'medio', 'EFECTIVO', 'fecha', now(), 'tarjeta_marca', 'Visa', 'created_at', now()))))),
          array['accepted', 'accepted', 'invalid'], 'por el push suben los datos de la tarjeta y de la transferencia; la marca en efectivo es invalid');
select pg_temp.actuar_como_servidor();
select is((select tarjeta_marca || '/' || numero_aprobacion from public.cobranza where id = pg_temp.uc(92)), 'Visa/445566',
          'y quedan guardados (tarjeta)');
select is((select referencia_transferencia || '/' || banco_origen from public.cobranza where id = pg_temp.uc(93)), '88213/Itaú',
          'y (transferencia)');

-- ---------------------------------------------------------------------------
-- 9. El saldo de la cuota no cuenta el cobro anulado (AG002)
-- ---------------------------------------------------------------------------
-- La venta 54 vale 500,00; el cobro 24 es de 300,00: el saldo es 200,00.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                               values (pg_temp.u('f5'), pg_temp.u('11'), 'COBRANZA', public.hoy_montevideo() + 3, pg_temp.u('b1'),
                                       pg_temp.u('54'), 25000) $$), 'AG002', 'con el cobro vivo el saldo es 200,00 y una cuota de 250,00 no entra');
select is(pg_temp.anular(24), 'ok', 'b1 anula ese cobro (hora 1)');
select is(pg_temp.error_de($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                               values (pg_temp.u('f5'), pg_temp.u('11'), 'COBRANZA', public.hoy_montevideo() + 3, pg_temp.u('b1'),
                                       pg_temp.u('54'), 25000) $$), 'ok', 'anulado, el saldo vuelve a 500,00 y la misma cuota entra');
select is(pg_temp.error_de($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, venta_id, monto_previsto)
                               values (pg_temp.u('f6'), pg_temp.u('11'), 'COBRANZA', public.hoy_montevideo() + 4, pg_temp.u('b1'),
                                       pg_temp.u('54'), 50001) $$), 'AG002', 'pero una de 500,01 sigue sin entrar');

select * from finish();
rollback;
