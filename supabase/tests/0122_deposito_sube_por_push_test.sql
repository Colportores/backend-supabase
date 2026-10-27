-- pgTAP · migración 0122 (backend-supabase#135, HU-CTA-004): el depósito de efectivo sube del teléfono, con los
-- cobros que incluye.
--   1. La forma: la dueña por default, los índices, el CHECK, los triggers, las políticas, los privilegios, las
--      dos entidades en sync.entidad y qué columnas escribe el teléfono.
--   2. Registrar un depósito por la API directa (como authenticated): la dueña sale del JWT, fecha no futura,
--      campaña propia, ticket propio y de tipo DEPOSITO, un retiro sin ticket, un ticket respalda un solo depósito.
--   3. Incluir cobros: efectivo, propios, vivos y no anulados; un cobro entra a un solo depósito.
--   4. La RLS: cada una ve lo suyo; la coordinadora y el ADMIN leen; nadie con JWT actualiza ni borra.
--   5. Por sync.push: idempotente, la dueña sale del JWT, lo que llega mal vuelve `invalid` con su código, el
--      vínculo puede ir antes que su depósito en el lote, un update o una baja vuelven `invalid` 42501.
--   6. El servidor corrige a mano (sin pasar por los triggers del cliente), y la baja de un vínculo libera el cobro.
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
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- Ids (prefijo 21): usuarios 21b1.., tickets 21c1.., ventas 2171.., cobros 21a1.., depósitos 21d1..;
-- client_op_id: 21 + 2 dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '21' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000021' || p)::uuid;
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
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare
  v_n integer;
begin
  execute p_sql;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Un depósito completo, tal como lo manda el teléfono.
create or replace function pg_temp.dp(p_id uuid, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'monto', 180000, 'fecha', '2026-10-23T15:00:00Z',
                            'destino', 'BANCO', 'concepto', 'CASA_EDITORA',
                            'ticket_id', '01920000-0000-7000-8000-0000000021c9') || p_extra;
$$;
create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 colportoras, c1 coordinador de una campaña con b1, ad ADMIN. Una venta de cada una.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dp21-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
-- e1: la campaña de b1 (coordina c1); e2: otra, sin b1. Fechas que no se pisan para b1 no hacen falta: b1 solo
-- está en e1.
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 deposito21', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 deposito21', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
       (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '10 days');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dp21', 'ZW');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dp21', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e3'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('e4'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e3'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e4'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-2171', 450000, now(), pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-2172', 260000, now(), pg_temp.u('b2'), pg_temp.u('b2'));

-- Cobros de b1 (a1..a3 y a9 en efectivo, a4 con tarjeta, a5 anulado, a6 dado de baja, a7 por transferencia) y de b2 (a8).
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by) values
  (pg_temp.u('a1'), pg_temp.u('71'), 100000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('a2'), pg_temp.u('71'), 50000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('a3'), pg_temp.u('71'), 30000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('a4'), pg_temp.u('71'), 20000, 'TARJETA', now(), pg_temp.u('b1')),
  (pg_temp.u('a9'), pg_temp.u('71'), 10000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('aa'), pg_temp.u('71'), 10000, 'EFECTIVO', now(), pg_temp.u('b1')),
  (pg_temp.u('a7'), pg_temp.u('71'), 10000, 'TRANSFERENCIA', now(), pg_temp.u('b1')),
  (pg_temp.u('a8'), pg_temp.u('72'), 40000, 'EFECTIVO', now(), pg_temp.u('b2'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion, created_by) values
  (pg_temp.u('a5'), pg_temp.u('71'), 15000, 'EFECTIVO', now(), now(), 'Monto equivocado', pg_temp.u('b1'));
insert into public.cobranza (id, venta_id, monto, medio, fecha, deleted_at, created_by) values
  (pg_temp.u('a6'), pg_temp.u('71'), 15000, 'EFECTIVO', now(), now(), pg_temp.u('b1'));

-- Tickets: de depósito de b1 (c1..c4, c7..cb; c9 es el «de tanteo» de los depósitos que tienen que fallar), de cobro
-- con tarjeta de b1 (c5), de depósito de b2 (c6).
insert into public.ticket (id, usuario_id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo) values
  (pg_temp.u('c1'), pg_temp.u('b1'), 'DEPOSITO', 180000, now(), null, null),
  (pg_temp.u('c2'), pg_temp.u('b1'), 'DEPOSITO', 180000, now(), null, null),
  (pg_temp.u('c3'), pg_temp.u('b1'), 'DEPOSITO', 180000, now(), null, null),
  (pg_temp.u('c4'), pg_temp.u('b1'), 'DEPOSITO', 180000, now(), null, null),
  (pg_temp.u('c5'), pg_temp.u('b1'), 'COBRO_TARJETA', 20000, now(), '0045', 'DEBITO'),
  (pg_temp.u('c6'), pg_temp.u('b2'), 'DEPOSITO', 180000, now(), null, null),
  (pg_temp.u('c7'), pg_temp.u('b1'), 'DEPOSITO', 150000, now(), null, null),
  (pg_temp.u('c8'), pg_temp.u('b1'), 'DEPOSITO', 150000, now(), null, null),
  (pg_temp.u('c9'), pg_temp.u('b1'), 'DEPOSITO', 100, now(), null, null),
  (pg_temp.u('ca'), pg_temp.u('b1'), 'DEPOSITO', 95000, now(), null, null),
  (pg_temp.u('cb'), pg_temp.u('b1'), 'DEPOSITO', 100, now(), null, null);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_has_default('public', 'deposito', 'colportor_id', 'colportor_id sale del JWT (default auth.uid())');
select col_not_null('public', 'deposito', 'colportor_id', 'y sigue siendo obligatorio');
select has_index('public', 'deposito', 'deposito_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'el delta de deposito: la dueña primero, para que entre en el Index Cond');
select has_index('public', 'deposito', 'deposito_ticket_unico', array['ticket_id'], 'un ticket, un depósito vivo');
select has_trigger('public', 'deposito', 'deposito_del_cliente', 'el trigger de lo que hace el teléfono con un depósito');
select has_table('public', 'deposito_cobro', 'existe deposito_cobro');
select has_index('public', 'deposito_cobro', 'deposito_cobro_cobro_unico', array['cobranza_id'], 'un cobro, un depósito vivo');
select has_index('public', 'deposito_cobro', 'deposito_cobro_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'el delta del vínculo: la dueña primero');
select has_trigger('public', 'deposito_cobro', 'deposito_cobro_del_cliente', 'el trigger de lo que hace el teléfono con un vínculo');
select has_trigger('public', 'deposito_cobro', 'deposito_cobro_auditoria_insert', 'auditoría de alta');
select has_trigger('public', 'deposito_cobro', 'deposito_cobro_auditoria_update', 'y de cambio');
select col_has_default('public', 'deposito_cobro', 'colportor_id', 'el vínculo también toma la dueña del JWT');
select ok((select relrowsecurity from pg_class where oid = 'public.deposito_cobro'::regclass), 'RLS activa en deposito_cobro');

select is(
  (select array_agg(p.policyname || ' ' || p.cmd || ' {' || array_to_string(p.roles, ',') || '}' order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'deposito'),
  array['deposito_insert_propio INSERT {authenticated}', 'deposito_select SELECT {authenticated}'],
  'deposito: solo lectura (0067) y alta de la dueña; ni UPDATE ni DELETE');
select is(
  (select array_agg(p.policyname || ' ' || p.cmd || ' {' || array_to_string(p.roles, ',') || '}' order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'deposito_cobro'),
  array['deposito_cobro_insert_propio INSERT {authenticated}', 'deposito_cobro_select SELECT {authenticated}'],
  'deposito_cobro: lectura y alta de la dueña; ni UPDATE ni DELETE');
select ok((select coalesce(p.with_check, '') like '%colportor_id%auth.uid()%' from pg_policies p
            where p.policyname = 'deposito_insert_propio'), 'el alta de depósito se mide contra la dueña');
select ok((select coalesce(p.with_check, '') like '%colportor_id%auth.uid()%deposito%' from pg_policies p
            where p.policyname = 'deposito_cobro_insert_propio'),
          'el alta de un vínculo se mide contra la dueña y contra un depósito suyo');
select table_privs_are('public', 'deposito', 'authenticated', array['SELECT', 'INSERT'], 'deposito: authenticated lee y da de alta');
select table_privs_are('public', 'deposito_cobro', 'authenticated', array['SELECT', 'INSERT'],
                       'deposito_cobro: authenticated lee y da de alta');
select table_privs_are('public', 'deposito_cobro', 'anon', array[]::text[], 'anon no tiene nada en deposito_cobro');
select is((select count(*)::int from information_schema.role_table_grants
            where table_schema = 'public' and table_name = 'deposito_cobro' and grantee = 'service_role'), 7,
          'service_role tiene todos los privilegios sobre deposito_cobro');

select results_eq(
  $$ select nombre, permite_push, columna_pk, columna_duenio, sigue_campanias
       from sync.entidad where nombre in ('deposito', 'deposito_cobro') order by nombre $$,
  $$ values ('deposito'::text, true, 'id'::text, 'colportor_id'::text, false),
            ('deposito_cobro'::text, true, 'id'::text, 'colportor_id'::text, false) $$,
  'las dos entidades: push, PK id, bajando solo lo de la dueña, sin campañas');
select ok(not (sync.columnas_escribibles('deposito') && array['colportor_id', 'sync_version']),
          'el teléfono no escribe la dueña de un depósito');
select ok(sync.columnas_escribibles('deposito') @>
            array['monto', 'fecha', 'destino', 'concepto', 'ticket_id', 'campania_id'],
          'sí el monto, la fecha, el destino, el concepto, el ticket y la campaña');
select ok(not (sync.columnas_escribibles('deposito_cobro') && array['colportor_id', 'sync_version']),
          'ni la dueña de un vínculo');
select ok(sync.columnas_escribibles('deposito_cobro') @> array['deposito_id', 'cobranza_id'],
          'sí el depósito y el cobro');

select is((select has_function_privilege('authenticated', 'public.tg_deposito_del_cliente()', 'execute')), false,
          'la función del trigger de deposito no se llama a mano');
select is((select has_function_privilege('authenticated', 'public.tg_deposito_cobro_del_cliente()', 'execute')), false,
          'ni la del vínculo');
select is((select has_function_privilege(r, 'public.ticket_no_sirve_de_deposito(uuid)', 'execute')), r = 'authenticated',
          format('ticket_no_sirve_de_deposito: %s', r)) from unnest(array['anon', 'authenticated']) r;
select is((select has_function_privilege(r, 'public.cobro_no_entra_en_deposito(uuid)', 'execute')), r = 'authenticated',
          format('cobro_no_entra_en_deposito: %s', r)) from unnest(array['anon', 'authenticated']) r;
select is((select has_function_privilege(r, 'public.estuvo_inscripta_en_campania(uuid)', 'execute')), r = 'authenticated',
          format('estuvo_inscripta_en_campania: %s', r)) from unnest(array['anon', 'authenticated']) r;
select is((select prosecdef from pg_proc where oid = 'public.ticket_no_sirve_de_deposito(uuid)'::regprocedure), true,
          'ticket_no_sirve_de_deposito es SECURITY DEFINER (la RLS esconde los ajenos)');
select is((select prosecdef from pg_proc where oid = 'public.cobro_no_entra_en_deposito(uuid)'::regprocedure), true,
          'cobro_no_entra_en_deposito es SECURITY DEFINER');

-- ---------------------------------------------------------------------------
-- 2. Registrar un depósito por la API directa (b1)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d1'), 180000, now(), 'BANCO', 'CASA_EDITORA', %L) $$, pg_temp.u('c1'))),
          'ok', 'b1 registra un depósito en el banco con su ticket, sin mandar la dueña');
select is((select colportor_id from public.deposito where id = pg_temp.u('d1')), pg_temp.u('b1'), 'la dueña sale del JWT');
select is((select created_by from public.deposito where id = pg_temp.u('d1')), pg_temp.u('b1'), 'y created_by también');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d2'), 95000, now(), 'OFICINA', 'CASA_EDITORA', pg_temp.u('ca')) $$),
          'ok', 'en la oficina, con su ticket');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                              values (pg_temp.u('d3'), 500000, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA') $$),
          'ok', 'un retiro por el coordinador, sin ticket');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, campania_id, ticket_id)
                                     values (pg_temp.u('d4'), 150000, now(), 'BANCO', 'ALQUILER', %L, pg_temp.u('c7')) $$, pg_temp.u('e1'))),
          'ok', 'un depósito de alquiler con su campaña');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, campania_id, ticket_id)
                                     values (pg_temp.u('d5'), 150000, now() + interval '5 minutes', 'BANCO', 'CASA_EDITORA', %L, pg_temp.u('c8')) $$, pg_temp.u('e1'))),
          'ok', 'un depósito de casa editora con campaña también; y la fecha de hoy, unos minutos adelante en el reloj del teléfono, pasa');

-- Lo que ya cuidaban los CHECK de 0067 y 0114.
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 0, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('c9')) $$),
          '23514 deposito_monto_check', 'monto 0: el CHECK de siempre');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 100, now(), 'CAJA', 'CASA_EDITORA', pg_temp.u('c9')) $$),
          '23514 deposito_destino_check', 'un destino que no existe');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 100, now(), 'BANCO', 'OTRO', pg_temp.u('c9')) $$),
          '23514 deposito_concepto_check', 'un concepto que no existe');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 100, now(), 'BANCO', 'ALQUILER', pg_temp.u('c9')) $$),
          '23514 deposito_pago_de_alquiler_con_campania_check', 'el alquiler sin campaña');

-- Lo que decide el servidor.
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 100, now() + interval '2 days', 'BANCO', 'CASA_EDITORA', pg_temp.u('c9')) $$),
          '23514 deposito_fecha_no_futura', 'fecha futura: 23514');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 100, now() + interval '1 day', 'BANCO', 'CASA_EDITORA', pg_temp.u('c9')) $$),
          '23514 deposito_fecha_no_futura', 'mañana también: 23514');
select is(pg_temp.mensaje_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                               values (pg_temp.u('d6'), 100, now() + interval '2 days', 'BANCO', 'CASA_EDITORA', pg_temp.u('c9')) $$),
          'La fecha del depósito no puede ser futura. Revisá el día.', 'con su aviso');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d6'), %L, 100, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('c9')) $$, pg_temp.u('b2'))),
          '42501 ', 'b1 no registra un depósito a nombre de b2 (WITH CHECK)');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, campania_id, ticket_id)
                                     values (pg_temp.u('d6'), 100, now(), 'BANCO', 'ALQUILER', %L, pg_temp.u('c9')) $$, pg_temp.u('e2'))),
          '42501 ', 'ni a una campaña donde no está inscripta');
select is(pg_temp.mensaje_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, campania_id, ticket_id)
                                      values (pg_temp.u('d6'), 100, now(), 'BANCO', 'ALQUILER', %L, pg_temp.u('c9')) $$, pg_temp.u('e2'))),
          'No estás inscripto en esa campaña. Elegí una campaña tuya.', 'con su aviso');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA', %L) $$, pg_temp.u('c6'))),
          '42501 ', 'el ticket de b2 no respalda un depósito de b1');
select is(pg_temp.mensaje_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                      values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA', %L) $$, pg_temp.u('c6'))),
          'Ese ticket no es tuyo. Cargá el ticket de tu depósito desde tu teléfono.', 'con su aviso');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA', %L) $$, pg_temp.u('c5'))),
          '42501 ', 'el ticket de un cobro con tarjeta no es comprobante de un depósito');
select is(pg_temp.mensaje_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                      values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA', %L) $$, pg_temp.u('c5'))),
          'Ese ticket no es de un depósito. Cargá el ticket del banco o de la oficina.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('ff')) $$),
          '42501 ', 'un ticket que no existe: igual que uno ajeno (no se averigua cuál existe)');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA', %L) $$, pg_temp.u('c1'))),
          '23505 deposito_ticket_unico', 'el mismo ticket en dos depósitos vivos: 23505');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d6'), 100, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', %L) $$, pg_temp.u('c2'))),
          '23514 deposito_retiro_sin_ticket', 'un retiro por el coordinador con ticket: 23514');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                              values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA') $$),
          '23514 deposito_ticket_obligatorio', 'un depósito de banco sin ticket: 23514');
select is(pg_temp.mensaje_de($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                               values (pg_temp.u('d6'), 100, now(), 'BANCO', 'CASA_EDITORA') $$),
          'Cargá el ticket del banco o de la oficina para registrar el depósito.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.deposito (id, monto, fecha, destino, concepto)
                              values (pg_temp.u('d6'), 100, now(), 'OFICINA', 'ALQUILER') $$),
          '23514 deposito_ticket_obligatorio', 'y uno de la oficina');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, monto, fecha, destino, concepto, campania_id)
                                     values (pg_temp.u('d6'), 100, now(), 'BANCO', 'ALQUILER', %L) $$, pg_temp.u('e1'))),
          '23514 deposito_ticket_obligatorio', 'también el de alquiler con su campaña');
select is((select count(*)::int from public.deposito where id = pg_temp.u('d6')), 0, 'y ninguna de las malas escribió nada');

-- Un depósito ya registrado no lo cambia el teléfono.
select is(pg_temp.error_de($$ update public.deposito set monto = 1 where id = pg_temp.u('d1') $$), '42501 ',
          'b1 no actualiza su depósito: sin privilegio de UPDATE');
select is(pg_temp.error_de($$ delete from public.deposito where id = pg_temp.u('d1') $$), '42501 ',
          'ni lo borra (sin privilegio de DELETE)');
select is((select monto from public.deposito where id = pg_temp.u('d1')), 180000::bigint, 'y el monto sigue igual');

-- ---------------------------------------------------------------------------
-- 3. Incluir cobros en un depósito (b1)
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('01'), %L, %L) $$, pg_temp.u('d1'), pg_temp.u('a1'))),
          'ok', 'b1 incluye un cobro en efectivo suyo en su depósito, sin mandar la dueña');
select is((select colportor_id from public.deposito_cobro where id = pg_temp.u('01')), pg_temp.u('b1'), 'la dueña sale del JWT');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('02'), %L, %L) $$, pg_temp.u('d1'), pg_temp.u('a2'))),
          'ok', 'y otro: un depósito incluye varios cobros');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a1'))),
          '23505 deposito_cobro_cobro_unico', 'el mismo cobro en otro depósito: 23505');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a4'))),
          '23514 deposito_cobro_en_efectivo', 'un cobro con tarjeta no es efectivo: 23514');
select is(pg_temp.mensaje_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                      values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a7'))),
          'Solo los cobros en efectivo se incluyen en un depósito de efectivo.', 'ni una transferencia, con su aviso');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a5'))),
          '23514 deposito_cobro_anulado', 'un cobro anulado: 23514');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a6'))),
          '23514 deposito_cobro_dado_de_baja', 'un cobro dado de baja: 23514');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a8'))),
          '42501 ', 'el cobro de la venta de b2: 42501');
select is(pg_temp.mensaje_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                      values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a8'))),
          'Ese cobro no es de una venta tuya. Incluí en el depósito solo tus cobros.', 'con su aviso');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('ee'))),
          '42501 ', 'un cobro que no existe: igual que uno ajeno (no se averigua cuál existe)');

-- Los ayudantes SECURITY DEFINER no reciben al usuario: b2 no averigua nada de b1 (ni de lo que no existe).
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(public.ticket_no_sirve_de_deposito(pg_temp.u('c1')), 'AJENO', 'b2 ante un ticket de b1: AJENO');
select is(public.ticket_no_sirve_de_deposito(pg_temp.u('ff')), 'AJENO', 'y ante uno que no existe: lo mismo');
select is(public.ticket_no_sirve_de_deposito(pg_temp.u('c6')), null, 'el suyo de depósito sirve');
select is(public.estuvo_inscripta_en_campania(pg_temp.u('e1')), false, 'b2 no estuvo inscripta en la campaña de b1');
select is(public.cobro_no_entra_en_deposito(pg_temp.u('a1')), 'AJENO', 'b2 ante un cobro de una venta de b1: AJENO');
select is(public.cobro_no_entra_en_deposito(pg_temp.u('ee')), 'AJENO', 'y ante uno que no existe: lo mismo');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.cobro_no_entra_en_deposito(pg_temp.u('a1')), null, 'b1 ante su cobro en efectivo: puede entrar');
select is(public.estuvo_inscripta_en_campania(pg_temp.u('e1')), true, 'b1 estuvo inscripta en su campaña');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id)
                                     values (pg_temp.u('03'), %L, %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a3'), pg_temp.u('b2'))),
          '42501 ', 'un vínculo a nombre de b2: 42501');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('ee'), pg_temp.u('a3'))),
          '42501 ', 'a un depósito que no existe: 42501 (la política no lo encuentra)');
select pg_temp.actuar_como_servidor();
insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, ticket_id)
values (pg_temp.u('d9'), pg_temp.u('b2'), 100, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('c6'));
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('03'), %L, %L) $$, pg_temp.u('d9'), pg_temp.u('a3'))),
          '42501 ', 'al depósito de b2: 42501');
select is((select count(*)::int from public.deposito_cobro where id = pg_temp.u('03')), 0, 'ninguna escribió nada');
select is(pg_temp.error_de($$ update public.deposito_cobro set cobranza_id = pg_temp.u('a3') where id = pg_temp.u('01') $$), '42501 ',
          'cambiar el cobro de un vínculo: sin privilegio de UPDATE');
select is(pg_temp.error_de($$ delete from public.deposito_cobro where id = pg_temp.u('01') $$), '42501 ',
          'y sacarlo del depósito, tampoco');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id)
                                     values (pg_temp.u('04'), %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a3'))),
          'ok', 'un depósito parcial: a3 queda para otro depósito, y no pasa nada');

-- ---------------------------------------------------------------------------
-- 4. La RLS
-- ---------------------------------------------------------------------------
select is((select count(*)::int from public.deposito where id in (select pg_temp.u(x) from unnest(array['d1','d2','d3','d4','d5','d9']) x)),
          5, 'b1 ve sus 5 depósitos y no el de b2');
select is((select count(*)::int from public.deposito_cobro), 3, 'y sus 3 vínculos');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.deposito where id in (select pg_temp.u(x) from unnest(array['d1','d2','d3','d4','d5','d9']) x)),
          1, 'b2 ve solo el suyo');
select is((select count(*)::int from public.deposito_cobro), 0, 'y ningún vínculo de b1');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.deposito where colportor_id = pg_temp.u('b1')), 5,
          'c1, que coordina a b1, lee sus depósitos');
select is((select count(*)::int from public.deposito_cobro), 3, 'y sus vínculos');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('d6'), %L, 100, now(), 'BANCO', 'CASA_EDITORA', pg_temp.u('c9')) $$, pg_temp.u('b1'))),
          '42501 ', 'pero el coordinador no registra depósitos a nombre de un colportor');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.deposito where id in (select pg_temp.u(x) from unnest(array['d1','d2','d3','d4','d5','d9']) x)),
          6, 'el ADMIN lee todos');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select * from public.deposito_cobro $$), '42501 ', 'anon: permission denied en deposito_cobro');
select is(pg_temp.error_de($$ insert into public.deposito (monto, fecha, destino, concepto) values (1, now(), 'BANCO', 'CASA_EDITORA') $$),
          '42501 ', 'y no registra depósitos');

-- ---------------------------------------------------------------------------
-- 5. Por sync.push (b1)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'deposito', 'insert',
                        pg_temp.dp(pg_temp.u('e5'), jsonb_build_object('ticket_id', pg_temp.u('c3'), 'colportor_id', pg_temp.u('b2')))) ->> 'outcome',
          'accepted', 'b1 sube un depósito, aunque el payload traiga otra dueña');
select is((select colportor_id from public.deposito where id = pg_temp.u('e5')), pg_temp.u('b1'),
          'la dueña sale del JWT: la del payload se descarta');
select is((select array[monto::text, destino, concepto, ticket_id::text] from public.deposito where id = pg_temp.u('e5')),
          array['180000', 'BANCO', 'CASA_EDITORA', pg_temp.u('c3')::text], 'el monto, el destino, el concepto y el ticket llegaron');
select is(pg_temp.push1(pg_temp.op('01'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e5'))) ->> 'outcome', 'duplicate',
          'el mismo client_op_id otra vez: duplicate (idempotente)');
select is(pg_temp.push1(pg_temp.op('02'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e5'), '{"monto": 1}')) ->> 'outcome', 'duplicate',
          'el mismo id con otro client_op_id (reintento tras reinstalar): duplicate');
select is((select monto from public.deposito where id = pg_temp.u('e5')), 180000::bigint, 'y el reintento no pisó nada');

select is(pg_temp.push1(pg_temp.op('03'), 'deposito', 'update', jsonb_build_object('id', pg_temp.u('e5'), 'monto', 1), 0) ->> 'code',
          '42501', 'cambiar el monto de un depósito ya subido: invalid 42501');
select is(pg_temp.push1(pg_temp.op('04'), 'deposito', 'delete', jsonb_build_object('id', pg_temp.u('e5')), 0) ->> 'code',
          '42501', 'darlo de baja: invalid 42501');
select is((select monto from public.deposito where id = pg_temp.u('e5')), 180000::bigint, 'y el monto no cambió');

-- Lo que llega mal vuelve invalid con su código (y no tumba al lote).
select is(pg_temp.push1(pg_temp.op('10'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6')) - 'monto') ->> 'code',
          '23502', 'sin monto: invalid 23502');
select is(pg_temp.push1(pg_temp.op('11'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), '{"monto": -5}')) ->> 'code',
          '23514', 'monto negativo: invalid 23514');
select is(pg_temp.push1(pg_temp.op('12'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), '{"fecha": "2099-01-01T00:00:00Z"}')) ->> 'code',
          '23514', 'fecha futura: invalid 23514');
select is(pg_temp.push1(pg_temp.op('13'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), '{"destino": "CAJA"}')) ->> 'code',
          '23514', 'destino que no existe: invalid 23514');
select is(pg_temp.push1(pg_temp.op('14'), 'deposito', 'insert',
                        pg_temp.dp(pg_temp.u('e6'), jsonb_build_object('destino', 'RETIRO_COORDINADOR', 'ticket_id', pg_temp.u('c4')))) ->> 'code',
          '23514', 'un retiro con ticket: invalid 23514');
select is(pg_temp.push1(pg_temp.op('1a'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6')) - 'ticket_id') ->> 'code',
          '23514', 'un depósito de banco sin ticket: invalid 23514');
select is(pg_temp.push1(pg_temp.op('15'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), jsonb_build_object('ticket_id', pg_temp.u('c6')))) ->> 'code',
          '42501', 'el ticket de otra: invalid 42501');
select is(pg_temp.push1(pg_temp.op('16'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), jsonb_build_object('ticket_id', pg_temp.u('c3')))) ->> 'code',
          '23505', 'un ticket ya usado: invalid 23505');
select is(pg_temp.push1(pg_temp.op('17'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), jsonb_build_object('ticket_id', pg_temp.u('ff')))) ->> 'code',
          '42501', 'un ticket que no existe: invalid 42501 (igual que uno ajeno)');
select is(pg_temp.push1(pg_temp.op('18'), 'deposito', 'insert',
                        pg_temp.dp(pg_temp.u('e6'), jsonb_build_object('concepto', 'ALQUILER', 'campania_id', pg_temp.u('e2')))) ->> 'code',
          '42501', 'una campaña donde no está inscripta: invalid 42501');
select is(pg_temp.push1(pg_temp.op('19'), 'deposito', 'insert', pg_temp.dp(pg_temp.u('e6'), '{"concepto": "ALQUILER"}')) ->> 'code',
          '23514', 'alquiler sin campaña: invalid 23514');
select is((select count(*)::int from public.deposito where id = pg_temp.u('e6')), 0, 'ninguna escribió nada');

-- Un lote en el orden del teléfono: el depósito, su vínculo y otro depósito malo, que no tumba a los buenos.
create temp table r_lote as
  select sync.push(jsonb_build_array(
           jsonb_build_object('client_op_id', pg_temp.op('20'), 'entity', 'deposito', 'op', 'insert',
                              'payload', pg_temp.dp(pg_temp.u('e7'), '{"monto": 10000}')),
           jsonb_build_object('client_op_id', pg_temp.op('21'), 'entity', 'deposito_cobro', 'op', 'insert',
                              'payload', jsonb_build_object('id', pg_temp.u('11'), 'deposito_id', pg_temp.u('e7'), 'cobranza_id', pg_temp.u('a9'))),
           jsonb_build_object('client_op_id', pg_temp.op('22'), 'entity', 'deposito', 'op', 'insert',
                              'payload', pg_temp.dp(pg_temp.u('e8')) - 'monto'))) as r;
select is((select array_agg(x ->> 'outcome' order by ord) from r_lote, jsonb_array_elements(r -> 'results') with ordinality t(x, ord)),
          array['accepted', 'accepted', 'invalid'],
          'en un lote, el depósito y su vínculo se aplican, y el malo vuelve invalid sin tumbar a los buenos');
select is((select count(*)::int from public.deposito_cobro where deposito_id = pg_temp.u('e7') and cobranza_id = pg_temp.u('a9')), 1,
          'el vínculo quedó');
select is(pg_temp.push1(pg_temp.op('23'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('14'), 'deposito_id', pg_temp.u('e9'), 'cobranza_id', pg_temp.u('aa'))) ->> 'code',
          '42501', 'un vínculo antes que su depósito (que todavía no llegó): invalid 42501, el teléfono sube el depósito primero');

select is(pg_temp.push1(pg_temp.op('30'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('12'), 'deposito_id', pg_temp.u('e7'), 'cobranza_id', pg_temp.u('a4'))) ->> 'code',
          '23514', 'un vínculo con un cobro con tarjeta: invalid 23514');
select is(pg_temp.push1(pg_temp.op('31'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('12'), 'deposito_id', pg_temp.u('e7'), 'cobranza_id', pg_temp.u('a1'))) ->> 'code',
          '23505', 'con un cobro ya incluido en otro depósito: invalid 23505');
select is(pg_temp.push1(pg_temp.op('32'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('12'), 'deposito_id', pg_temp.u('e7'), 'cobranza_id', pg_temp.u('a8'))) ->> 'code',
          '42501', 'con el cobro de otra: invalid 42501');
select is(pg_temp.push1(pg_temp.op('33'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('12'), 'deposito_id', pg_temp.u('d9'), 'cobranza_id', pg_temp.u('a3'))) ->> 'code',
          '42501', 'en el depósito de otra: invalid 42501');
select is(pg_temp.push1(pg_temp.op('34'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('12'), 'deposito_id', pg_temp.u('e7'), 'cobranza_id', pg_temp.u('ee'))) ->> 'code',
          '42501', 'con un cobro que no existe: invalid 42501 (igual que uno ajeno)');
select is(pg_temp.push1(pg_temp.op('35'), 'deposito_cobro', 'insert',
                        jsonb_build_object('id', pg_temp.u('12'), 'deposito_id', pg_temp.u('e7'), 'cobranza_id', pg_temp.u('aa'),
                                           'colportor_id', pg_temp.u('b2'))) ->> 'outcome',
          'accepted', 'si el payload trae otra dueña, se descarta y entra como b1');
select is((select colportor_id from public.deposito_cobro where id = pg_temp.u('12')), pg_temp.u('b1'), 'la dueña sale del JWT');

-- Lo ajeno por push: no existe para quien sube.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('40'), 'deposito', 'update', jsonb_build_object('id', pg_temp.u('e5'), 'monto', 1), 0) ->> 'code',
          'FILA_INEXISTENTE', 'b2 intenta cambiar el depósito de b1: FILA_INEXISTENTE (para él no existe)');

-- ---------------------------------------------------------------------------
-- 6. El servidor corrige a mano
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, ticket_id)
                              values (pg_temp.u('da'), pg_temp.u('b1'), 100, now() + interval '2 days', 'BANCO', 'CASA_EDITORA', pg_temp.u('cb')) $$),
          'ok', 'el servidor carga un depósito sin pasar por los avisos del teléfono');
select is(pg_temp.error_de($$ update public.deposito set monto = 190000 where id = pg_temp.u('d1') $$), 'ok',
          'y corrige el monto de uno');
select is((select sync_version from public.deposito where id = pg_temp.u('d1')), 1::bigint, 'que sube sync_version (el teléfono se entera)');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto)
                                     values (pg_temp.u('dc'), %L, 100, now(), 'BANCO', 'CASA_EDITORA') $$, pg_temp.u('b1'))),
          '23514 deposito_ticket_obligatorio', 'un depósito de banco sin ticket no pasa ni por el servidor (CHECK)');
select is(pg_temp.error_de(format($$ insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, ticket_id)
                                     values (pg_temp.u('db'), %L, 100, now(), 'RETIRO_COORDINADOR', 'CASA_EDITORA', %L) $$,
                                pg_temp.u('b1'), pg_temp.u('c4'))),
          '23514 deposito_retiro_sin_ticket', 'pero un retiro con ticket no pasa ni por el servidor (CHECK)');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id)
                                     values (pg_temp.u('15'), %L, %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a4'), pg_temp.u('b1'))),
          'ok', 'el servidor vincula a mano hasta un cobro con tarjeta (no pasa por los avisos del teléfono)');
select is(pg_temp.error_de($$ update public.deposito_cobro set deleted_at = now() where id = pg_temp.u('01') $$), 'ok',
          'el servidor da de baja un vínculo');
select is(pg_temp.error_de(format($$ insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id)
                                     values (pg_temp.u('13'), %L, %L, %L) $$, pg_temp.u('d2'), pg_temp.u('a1'), pg_temp.u('b1'))),
          'ok', 'y el cobro queda libre para otro depósito');

select * from finish();
rollback;
