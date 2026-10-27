-- pgTAP · migración 0113 (backend-supabase#108, HU-COB-007/008/009): el ticket sube del teléfono.
--   1. La forma: la dueña por default, el delta, el trigger, las políticas, los privilegios, el registro en
--      sync.entidad y qué columnas escribe el teléfono.
--   2. Crear un ticket por la API directa (como authenticated): nace PENDIENTE; los datos que pide la HU
--      (monto, fecha no futura, autorización y tarjeta del cobro con tarjeta); lo del servidor no se manda.
--   3. Después de subirlo, lo único que el teléfono cambia es la foto, una sola vez y en su carpeta.
--   4. La RLS: cada una ve y toca lo suyo; el servidor valida y TK001 sigue.
--   5. Por sync.push: idempotente, la dueña sale del JWT, lo que llega mal vuelve `invalid` con su código,
--      un ticket resuelto vuelve `conflict`.
--   6. El ticket de un cobro es de quien hizo la venta.
--   7. La foto vence a los 4 meses (el servidor).
-- El historial del coordinador está en 0113_tickets_de_campania_test.sql, el pull en
-- 0113_ticket_pull_test.sql y el bucket en 0113_bucket_tickets_test.sql. Va en una transacción.
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

-- Ids (prefijo 13): usuarios 13b1.., tickets 13c1.., ventas 1371.., cobros 13a1..; client_op_id: 13 + 2 dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '13' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000013' || p)::uuid;
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
-- El mensaje de lo que hace una sentencia («ok» si anduvo).
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

-- La ruta de la foto de un ticket de un usuario: <usuario>/<ticket>.jpg
create or replace function pg_temp.foto(p_usuario text, p_ticket text, p_ext text default '.jpg')
returns text language sql as $$
  select pg_temp.u(p_usuario)::text || '/' || pg_temp.u(p_ticket)::text || p_ext;
$$;

-- Un ticket de tarjeta completo, tal como lo manda el teléfono.
create or replace function pg_temp.tk(p_id uuid, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'tipo', 'COBRO_TARJETA', 'monto', 480000, 'fecha', '2026-10-23T15:00:00Z',
                            'numero_autorizacion', '004512', 'tarjeta_tipo', 'DEBITO') || p_extra;
$$;
-- Un job de push de la entidad; devuelve el resultado completo.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'ticket', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 y b2 colportoras, c1 coordinador de una campaña con b1, ad ADMIN. Una venta de cada una.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tk13-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 ticket13', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'));
-- `created_at` explícito: lo que b1 hace cuenta desde su alta (la coordinadora ve los tickets de su ventana).
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais tk13', 'ZV');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad tk13', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e2'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('e3'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e2'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e3'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-1371', 450000, now(), pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-1372', 260000, now(), pg_temp.u('b2'), pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_has_default('public', 'ticket', 'usuario_id', 'usuario_id sale del JWT (default auth.uid())');
select col_not_null('public', 'ticket', 'usuario_id', 'y sigue siendo obligatorio');
select has_index('public', 'ticket', 'ticket_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'el delta: la dueña primero, para que entre en el Index Cond');
select has_trigger('public', 'ticket', 'ticket_del_cliente', 'el trigger de lo que hace el teléfono');
select has_trigger('public', 'cobranza', 'cobranza_ticket_propio', 'y la guarda del ticket de un cobro');
select is(
  (select array_agg(p.policyname || ' ' || p.cmd || ' {' || array_to_string(p.roles, ',') || '}' order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'ticket'),
  array['ticket_insert_propio INSERT {authenticated}',
        'ticket_select SELECT {authenticated}',
        'ticket_update_propio UPDATE {authenticated}'],
  'tres políticas, solo para authenticated, y ninguna de DELETE');
select ok((select coalesce(p.with_check, '') like '%usuario_id%auth.uid()%' from pg_policies p
            where p.policyname = 'ticket_insert_propio'), 'INSERT: se mide contra la dueña');
select ok((select coalesce(p.qual, '') like '%usuario_id%auth.uid()%PENDIENTE%deleted_at IS NULL%' from pg_policies p
            where p.policyname = 'ticket_update_propio'),
          'UPDATE: lo que ve (USING) es lo suyo, por validar y vivo');
select ok((select coalesce(p.with_check, '') like '%usuario_id%auth.uid()%PENDIENTE%' from pg_policies p
            where p.policyname = 'ticket_update_propio'), 'UPDATE: lo que deja (WITH CHECK) sigue siendo suyo y por validar');
select ok((select bool_and(coalesce(p.qual, '') || coalesce(p.with_check, '') ~* '\(\s*select auth\.uid\(\)'
                           or p.policyname = 'ticket_select')
             from pg_policies p where p.schemaname = 'public' and p.tablename = 'ticket'),
          'auth.uid() va envuelta en (select …) en las de escritura');
select table_privs_are('public', 'ticket', 'authenticated', array['SELECT', 'INSERT', 'UPDATE'],
                       'authenticated: select, insert y update; nunca delete');
select table_privs_are('public', 'ticket', 'anon', array[]::text[], 'anon no tiene nada');

select results_eq(
  $$ select permite_push, columna_pk, columna_duenio, sigue_campanias
       from sync.entidad where nombre = 'ticket' $$,
  $$ values (true, 'id'::text, 'usuario_id'::text, false) $$,
  'registrada en sync.entidad como push, PK id, bajando solo lo de la dueña (usuario_id), sin campañas');
select is((select tabla::text from sync.entidad where nombre = 'ticket'), 'ticket', 'apunta a la tabla');
select ok(not (sync.columnas_escribibles('ticket') && array['usuario_id', 'subido_en', 'estado', 'revisado_por',
                                                            'revisado_en', 'motivo_rechazo', 'sync_version']),
          'el teléfono no escribe la dueña, cuándo llegó, el estado ni la revisión: lo fija el servidor');
select ok(sync.columnas_escribibles('ticket') @>
            array['tipo', 'monto', 'fecha', 'numero_autorizacion', 'tarjeta_tipo', 'tarjeta_marca', 'url_cloud'],
          'sí el tipo, el monto, la fecha, la autorización, la tarjeta y la foto');

select is((select has_function_privilege('authenticated', 'public.tg_ticket_del_cliente()', 'execute')), false,
          'la función del trigger no se llama a mano');
select is((select has_function_privilege('authenticated', 'public.tg_cobranza_ticket_propio()', 'execute')), false,
          'ni la de la guarda de cobranza');
select is((select has_function_privilege('authenticated', 'public.ticket_ajeno_a_la_venta(uuid, uuid)', 'execute')), true,
          'authenticated ejecuta ticket_ajeno_a_la_venta (la llama el trigger como él)');
select is((select has_function_privilege('anon', 'public.ticket_ajeno_a_la_venta(uuid, uuid)', 'execute')), false, 'anon no');
select is((select prosecdef from pg_proc where oid = 'public.ticket_ajeno_a_la_venta(uuid, uuid)'::regprocedure), true,
          'ticket_ajeno_a_la_venta es SECURITY DEFINER (la RLS esconde los ajenos)');
select is((select has_function_privilege(r, 'public.tickets_con_foto_vencida(timestamptz)', 'execute')), false,
          format('%s no ejecuta tickets_con_foto_vencida', r)) from unnest(array['anon', 'authenticated']) r;
select is((select has_function_privilege('service_role', 'public.tickets_con_foto_vencida(timestamptz)', 'execute')), true,
          'service_role sí');
select is((select has_function_privilege(r, 'public.soltar_foto_de_ticket(uuid)', 'execute')), false,
          format('%s no ejecuta soltar_foto_de_ticket', r)) from unnest(array['anon', 'authenticated']) r;
select is((select has_function_privilege('service_role', 'public.soltar_foto_de_ticket(uuid)', 'execute')), true, 'service_role sí');

-- ---------------------------------------------------------------------------
-- 2. Crear un ticket por la API directa (b1)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo, tarjeta_marca,
                                                                 url_cloud, subido_en)
                                     values (pg_temp.u('c1'), 'COBRO_TARJETA', 480000, now(), '004512', 'DEBITO', 'VISA', %L,
                                             '2020-01-01 00:00+00') $$, pg_temp.foto('b1', 'c1'))),
          'ok', 'b1 crea el ticket de su cobro con tarjeta, sin mandar la dueña');
select is((select usuario_id from public.ticket where id = pg_temp.u('c1')), pg_temp.u('b1'), 'la dueña sale del JWT');
select is((select created_by from public.ticket where id = pg_temp.u('c1')), pg_temp.u('b1'), 'y created_by también');
select is((select estado from public.ticket where id = pg_temp.u('c1')), 'PENDIENTE', 'nace por validar');
select is((select subido_en from public.ticket where id = pg_temp.u('c1')), now(),
          'cuándo llegó lo cuenta el servidor: la fecha vieja que mandó el teléfono se pisa');
select is((select array[revisado_por::text, revisado_en::text, motivo_rechazo] from public.ticket where id = pg_temp.u('c1')),
          array[null, null, null]::text[], 'sin revisión');

-- Los datos que pide la HU.
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c2'), 'COBRO_TARJETA', now(), '1', 'DEBITO') $$),
          '23514 ticket_monto_obligatorio', 'sin monto: 23514');
select is(pg_temp.mensaje_de($$ insert into public.ticket (id, tipo, fecha, numero_autorizacion, tarjeta_tipo)
                                values (pg_temp.u('c2'), 'COBRO_TARJETA', now(), '1', 'DEBITO') $$),
          'Ingresá el monto del ticket.', 'y el mensaje dice qué hacer');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c2'), 'COBRO_TARJETA', 0, now(), '1', 'DEBITO') $$),
          '23514 ticket_monto_check', 'monto 0: el CHECK de siempre');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c2'), 'COBRO_TARJETA', 100, '1', 'DEBITO') $$),
          '23514 ticket_fecha_obligatoria', 'sin fecha: 23514');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c2'), 'COBRO_TARJETA', 100, now() + interval '2 days', '1', 'DEBITO') $$),
          '23514 ticket_fecha_no_futura', 'fecha futura: 23514');
select is(pg_temp.mensaje_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                                values (pg_temp.u('c2'), 'COBRO_TARJETA', 100, now() + interval '2 days', '1', 'DEBITO') $$),
          'La fecha del ticket no puede ser futura. Revisá el día.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('cc'), 'COBRO_TARJETA', 100, now() + interval '5 minutes', '1', 'DEBITO') $$),
          'ok', 'la fecha de hoy, aunque sea unos minutos adelante en el reloj del teléfono, pasa: se mira el día');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, tarjeta_tipo)
                              values (pg_temp.u('c3'), 'COBRO_TARJETA', 100, now(), 'DEBITO') $$),
          '23514 ticket_autorizacion_obligatoria', 'el cobro con tarjeta sin número de autorización: 23514');
select is(pg_temp.mensaje_de($$ insert into public.ticket (id, tipo, monto, fecha, tarjeta_tipo)
                                values (pg_temp.u('c3'), 'COBRO_TARJETA', 100, now(), 'DEBITO') $$),
          'Ingresá el número de autorización del ticket.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c3'), 'COBRO_TARJETA', 100, now(), '   ', 'DEBITO') $$),
          '23514 ticket_numero_autorizacion_check', 'una autorización en blanco: el CHECK de 0067');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion)
                              values (pg_temp.u('c3'), 'COBRO_TARJETA', 100, now(), '1') $$),
          '23514 ticket_tarjeta_obligatoria', 'sin crédito ni débito: 23514');
select is(pg_temp.mensaje_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion)
                                values (pg_temp.u('c3'), 'COBRO_TARJETA', 100, now(), '1') $$),
          'Elegí si la tarjeta es de crédito o de débito.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c3'), 'COBRO_TARJETA', 100, now(), '1', 'PREPAGA') $$),
          '23514 ticket_tarjeta_tipo_check', 'ni una tarjeta que no es de crédito ni de débito');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion, tarjeta_tipo)
                              values (pg_temp.u('c4'), 'COBRO_TARJETA', 100, now(), '1', 'CREDITO') $$),
          'ok', 'sin la marca («cuál») pasa: el canvas todavía no la dibuja');
-- El ticket de un depósito no pide tarjeta ni autorización.
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha) values (pg_temp.u('c5'), 'DEPOSITO', 950000, now()) $$),
          'ok', 'el ticket de un depósito: foto, fecha y monto');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, numero_autorizacion)
                              values (pg_temp.u('c6'), 'DEPOSITO', 950000, now(), 'OP-77') $$),
          'ok', 'con el número de operación del banco en numero_autorizacion');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto) values (pg_temp.u('c7'), 'DEPOSITO', 950000) $$),
          '23514 ticket_fecha_obligatoria', 'pero la fecha y el monto los pide todo ticket');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha) values (pg_temp.u('c7'), 'OTRO', 100, now()) $$),
          'ok', 'un ticket de otro tipo, con los datos de todos');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha) values (pg_temp.u('c7'), 'RECIBO', 100, now()) $$),
          '23514 ticket_tipo_check', 'un tipo que no existe: el CHECK de siempre');

-- Lo del servidor no se manda.
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, estado)
                              values (pg_temp.u('c8'), 'DEPOSITO', 100, now(), 'VALIDADO') $$),
          '42501 ', 'un ticket nuevo no entra validado');
select is(pg_temp.mensaje_de($$ insert into public.ticket (id, tipo, monto, fecha, estado)
                                values (pg_temp.u('c8'), 'DEPOSITO', 100, now(), 'VALIDADO') $$),
          'Un ticket nuevo entra siempre por validar: lo valida o lo rechaza tu coordinador.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, estado, motivo_rechazo)
                              values (pg_temp.u('c8'), 'DEPOSITO', 100, now(), 'RECHAZADO', 'No se lee') $$),
          '42501 ', 'ni rechazado');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, revisado_por)
                                     values (pg_temp.u('c8'), 'DEPOSITO', 100, now(), %L) $$, pg_temp.u('c1'))),
          '42501 ', 'ni con un revisor');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, revisado_en)
                              values (pg_temp.u('c8'), 'DEPOSITO', 100, now(), now()) $$),
          '42501 ', 'ni con la fecha de una revisión');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, motivo_rechazo)
                              values (pg_temp.u('c8'), 'DEPOSITO', 100, now(), 'No se lee') $$),
          '42501 ', 'ni con un motivo de rechazo');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, usuario_id, tipo, monto, fecha)
                                     values (pg_temp.u('c8'), %L, 'DEPOSITO', 100, now()) $$, pg_temp.u('b2'))),
          '42501 ', 'b1 no crea un ticket a nombre de b2 (WITH CHECK)');
select is(pg_temp.error_de($$ insert into public.ticket (id, usuario_id, tipo, monto, fecha)
                              values (pg_temp.u('c8'), null, 'DEPOSITO', 100, now()) $$),
          '42501 ', 'ni sin dueña');
select is((select count(*)::int from public.ticket where id = pg_temp.u('c8')), 0, 'y no escribió nada');

-- La foto, en su carpeta y con el id del ticket.
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, url_cloud)
                                     values (pg_temp.u('c9'), 'DEPOSITO', 100, now(), %L) $$, pg_temp.foto('b2', 'c9'))),
          '23514 ticket_foto_en_tu_carpeta', 'una foto en la carpeta de b2: 23514');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, url_cloud)
                                     values (pg_temp.u('c9'), 'DEPOSITO', 100, now(), %L) $$, pg_temp.foto('b1', 'c1'))),
          '23514 ticket_foto_en_tu_carpeta', 'ni la foto de otro ticket suyo');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha, url_cloud)
                              values (pg_temp.u('c9'), 'DEPOSITO', 100, now(), 'tickets/x.jpg') $$),
          '23514 ticket_foto_en_tu_carpeta', 'ni una ruta cualquiera');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, url_cloud)
                                     values (pg_temp.u('c9'), 'DEPOSITO', 100, now(), %L) $$, pg_temp.foto('b1', 'c9', '.gif'))),
          '23514 ticket_foto_en_tu_carpeta', 'ni un .gif');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, url_cloud)
                                     values (pg_temp.u('c9'), 'DEPOSITO', 100, now(), %L) $$, pg_temp.foto('b1', 'c9', '.png'))),
          'ok', 'un .png sí');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, tipo, monto, fecha, url_cloud)
                                     values (pg_temp.u('ca'), 'DEPOSITO', 100, now(), %L) $$, pg_temp.foto('b1', 'ca', ''))),
          'ok', 'y sin extensión');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha) values (pg_temp.u('cb'), 'DEPOSITO', 100, now()) $$),
          'ok', 'el ticket sin foto todavía (la sube el motor después) entra');

-- ---------------------------------------------------------------------------
-- 3. Después de subirlo, el teléfono solo completa la foto, una vez
-- ---------------------------------------------------------------------------
select is(pg_temp.filas(format($$ update public.ticket set url_cloud = %L where id = pg_temp.u('cb') $$, pg_temp.foto('b1', 'cb'))), 1,
          'b1 completa la foto del ticket que subió sin ella');
select is((select url_cloud from public.ticket where id = pg_temp.u('cb')), pg_temp.foto('b1', 'cb'), 'quedó la ruta');
select is((select sync_version from public.ticket where id = pg_temp.u('cb')), 1::bigint, 'y sube sync_version (el teléfono ve el cambio)');
select is(pg_temp.error_de(format($$ update public.ticket set url_cloud = %L where id = pg_temp.u('cb') $$, pg_temp.foto('b1', 'cb', '.png'))),
          '42501 ', 'cambiar la foto ya puesta: 42501');
select is(pg_temp.mensaje_de($$ update public.ticket set url_cloud = null where id = pg_temp.u('cb') $$),
          'La foto de un ticket ya subido no se cambia ni se quita.', 'quitarla también, con su aviso');
select is(pg_temp.error_de(format($$ update public.ticket set url_cloud = %L where id = pg_temp.u('c5') $$, pg_temp.foto('b2', 'c5'))),
          '23514 ticket_foto_en_tu_carpeta', 'completar la foto con una ruta de otro: 23514');
select is(pg_temp.error_de($$ update public.ticket set url_cloud = 'tickets/x.jpg' where id = pg_temp.u('c5') $$),
          '23514 ticket_foto_en_tu_carpeta', 'o una cualquiera');
select is(pg_temp.error_de($$ update public.ticket set url_cloud = null where id = pg_temp.u('c5') $$),
          'ok', 'dejarla vacía (sin cambio) no es un cambio');

select is(pg_temp.error_de($$ update public.ticket set monto = 1 where id = pg_temp.u('c5') $$), '42501 ',
          'corregir el monto de un ticket ya subido: 42501');
select is(pg_temp.mensaje_de($$ update public.ticket set monto = 1 where id = pg_temp.u('c5') $$),
          'Un ticket que ya subiste no se puede cambiar ni dar de baja. Si tiene un error, pedile a tu coordinador que lo rechace y cargalo de nuevo.',
          'con el aviso que dice qué hacer');
select is(pg_temp.error_de($$ update public.ticket set fecha = now() - interval '1 day' where id = pg_temp.u('c5') $$), '42501 ', 'ni la fecha');
select is(pg_temp.error_de($$ update public.ticket set numero_autorizacion = 'X' where id = pg_temp.u('c5') $$), '42501 ', 'ni la autorización');
select is(pg_temp.error_de($$ update public.ticket set tarjeta_tipo = 'CREDITO' where id = pg_temp.u('c5') $$), '42501 ', 'ni la tarjeta');
select is(pg_temp.error_de($$ update public.ticket set tarjeta_marca = 'OCA' where id = pg_temp.u('c5') $$), '42501 ', 'ni la marca');
select is(pg_temp.error_de($$ update public.ticket set tipo = 'OTRO' where id = pg_temp.u('c5') $$), '42501 ', 'ni el tipo');
select is(pg_temp.error_de($$ update public.ticket set deleted_at = now() where id = pg_temp.u('c5') $$), '42501 ',
          'ni darlo de baja: una baja es del servidor');
select is(pg_temp.error_de($$ update public.ticket set estado = 'VALIDADO' where id = pg_temp.u('c5') $$), '42501 ', 'ni validarlo');
select is(pg_temp.error_de(format($$ update public.ticket set revisado_por = %L where id = pg_temp.u('c5') $$, pg_temp.u('b1'))),
          '42501 ', 'ni ponerse de revisor');
select is(pg_temp.error_de($$ update public.ticket set subido_en = now() - interval '1 day' where id = pg_temp.u('c5') $$), '42501 ',
          'ni mover cuándo llegó');
select is(pg_temp.error_de(format($$ update public.ticket set usuario_id = %L where id = pg_temp.u('c5') $$, pg_temp.u('b2'))),
          '42501 ', 'ni pasárselo a otra (la política o el trigger lo frenan)');
select is((select monto from public.ticket where id = pg_temp.u('c5')), 950000::bigint, 'y el ticket sigue como se subió');

-- ---------------------------------------------------------------------------
-- 4. La RLS y el servidor
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.ticket), 0, 'b2 no ve ningún ticket de b1');
select is(pg_temp.filas($$ update public.ticket set url_cloud = null where id = pg_temp.u('c5') $$), 0, 'ni toca uno de b1 (la fila ni se ve)');
select is(pg_temp.error_de($$ delete from public.ticket where id = pg_temp.u('c5') $$), '42501 ', 'nadie borra');
select is(pg_temp.error_de($$ insert into public.ticket (id, tipo, monto, fecha) values (pg_temp.u('d1'), 'DEPOSITO', 100, now()) $$),
          'ok', 'b2 crea el suyo');
select pg_temp.actuar_como(pg_temp.u('c1'));
select ok((select count(*) >= 8 from public.ticket where usuario_id = pg_temp.u('b1')), 'el coordinador de b1 lee los tickets de b1 (0067)');
select is((select count(*)::int from public.ticket where usuario_id = pg_temp.u('b2')), 0, 'y no los de b2, que no coordina');
select pg_temp.actuar_como(pg_temp.u('ad'));
select ok((select count(*) >= 9 from public.ticket), 'el ADMIN los lee todos');
select is(pg_temp.filas($$ update public.ticket set url_cloud = null where id = pg_temp.u('c5') $$), 0, 'pero no los toca por la API');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de('select count(*) from public.ticket'), '42501 ', 'anon: permission denied');
select pg_temp.actuar_como_servidor();

-- El servidor valida: no pasa por el trigger del teléfono. TK001 sigue (0067).
select is(pg_temp.error_de(format($$ update public.ticket set estado = 'VALIDADO', revisado_por = %L, revisado_en = now()
                                     where id = pg_temp.u('c1') $$, pg_temp.u('c1'))),
          'ok', 'el servidor valida un ticket (service_role / postgres no pasan por el trigger del teléfono)');
select is(pg_temp.error_de($$ update public.ticket set monto = 5 where id = pg_temp.u('c1') $$), 'TK001 ',
          'y un ticket validado no se edita: TK001 de 0067 sigue en pie');

-- Un ticket resuelto no lo toca su dueña: la política no lo ve.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas($$ update public.ticket set url_cloud = null where id = pg_temp.u('c1') $$), 0,
          'b1 no toca su ticket ya validado (la política de UPDATE no lo ve)');
select is(pg_temp.filas(format($$ update public.ticket set url_cloud = %L where id = pg_temp.u('c1') $$, pg_temp.foto('b1', 'c1', '.png'))), 0,
          'ni le cambia la foto');
select is((select url_cloud from public.ticket where id = pg_temp.u('c1')), pg_temp.foto('b1', 'c1'), 'la foto de la prueba sigue');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Por sync.push (b1)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert',
                        pg_temp.tk(pg_temp.u('e1'), jsonb_build_object('usuario_id', pg_temp.u('b2'), 'estado', 'VALIDADO',
                                                                       'revisado_por', pg_temp.u('c1'), 'motivo_rechazo', 'x',
                                                                       'subido_en', '2020-01-01T00:00:00Z'))) ->> 'outcome',
          'accepted', 'el push de un ticket de tarjeta completo se acepta');
select is((select usuario_id from public.ticket where id = pg_temp.u('e1')), pg_temp.u('b1'),
          'la dueña es quien sube (JWT): el usuario_id del payload se descarta');
select is((select array[estado, revisado_por::text, motivo_rechazo] from public.ticket where id = pg_temp.u('e1')),
          array['PENDIENTE', null, null]::text[], 'y estado, revisor y motivo del payload también: nace por validar');
select is((select subido_en from public.ticket where id = pg_temp.u('e1')), now(), 'cuándo llegó lo pone el servidor');
select is((select array[monto::text, numero_autorizacion, tarjeta_tipo] from public.ticket where id = pg_temp.u('e1')),
          array['480000', '004512', 'DEBITO'], 'el monto, la autorización y la tarjeta llegaron');
select is(pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.tk(pg_temp.u('e1'))) ->> 'outcome', 'duplicate',
          'el mismo client_op_id otra vez: duplicate (idempotente)');
select is(pg_temp.push1(pg_temp.op('02'), 'insert', pg_temp.tk(pg_temp.u('e1'), '{"monto": 1}')) ->> 'outcome', 'duplicate',
          'el mismo id con otro client_op_id (un reintento tras reinstalar): duplicate');
select is((select monto from public.ticket where id = pg_temp.u('e1')), 480000::bigint, 'y el reintento no pisó nada');

-- La foto: por update, con la versión que tiene el teléfono.
select is(pg_temp.push1(pg_temp.op('03'), 'update',
                        jsonb_build_object('id', pg_temp.u('e1'), 'url_cloud', pg_temp.foto('b1', 'e1')), 0) ->> 'outcome',
          'accepted', 'b1 completa la foto por update');
select is((select url_cloud from public.ticket where id = pg_temp.u('e1')), pg_temp.foto('b1', 'e1'), 'quedó la ruta');
select is(pg_temp.push1(pg_temp.op('04'), 'update',
                        jsonb_build_object('id', pg_temp.u('e1'), 'url_cloud', pg_temp.foto('b1', 'e1', '.png')), 1) ->> 'code',
          '42501', 'cambiarla después: invalid 42501');
select is(pg_temp.push1(pg_temp.op('05'), 'update', jsonb_build_object('id', pg_temp.u('e1'), 'monto', 1), 1) ->> 'outcome',
          'invalid', 'corregir el monto de un ticket ya subido: invalid');
select is(pg_temp.push1(pg_temp.op('06'), 'delete', jsonb_build_object('id', pg_temp.u('e1')), 1) ->> 'code',
          '42501', 'darlo de baja: invalid 42501');
select is((select array[monto::text, deleted_at::text] from public.ticket where id = pg_temp.u('e1')),
          array['480000', null], 'y el ticket no cambió');

-- Lo que llega mal vuelve invalid con su código (y no tumba al lote).
select is(pg_temp.push1(pg_temp.op('10'), 'insert', pg_temp.tk(pg_temp.u('e2')) - 'monto') ->> 'code',
          '23514', 'sin monto: invalid 23514');
select is(pg_temp.push1(pg_temp.op('11'), 'insert', pg_temp.tk(pg_temp.u('e2')) - 'numero_autorizacion') ->> 'code',
          '23514', 'sin autorización: invalid 23514');
select is(pg_temp.push1(pg_temp.op('12'), 'insert', pg_temp.tk(pg_temp.u('e2')) - 'tarjeta_tipo') ->> 'code',
          '23514', 'sin tipo de tarjeta: invalid 23514');
select is(pg_temp.push1(pg_temp.op('13'), 'insert', pg_temp.tk(pg_temp.u('e2')) - 'fecha') ->> 'code',
          '23514', 'sin fecha: invalid 23514');
select is(pg_temp.push1(pg_temp.op('14'), 'insert', pg_temp.tk(pg_temp.u('e2'), '{"fecha": "2099-01-01T00:00:00Z"}')) ->> 'code',
          '23514', 'con fecha futura: invalid 23514');
select is(pg_temp.push1(pg_temp.op('15'), 'insert', pg_temp.tk(pg_temp.u('e2'), '{"monto": -5}')) ->> 'code',
          '23514', 'con monto negativo: invalid 23514');
select is(pg_temp.push1(pg_temp.op('16'), 'insert', pg_temp.tk(pg_temp.u('e2'), jsonb_build_object('url_cloud', pg_temp.foto('b2', 'e2')))) ->> 'code',
          '23514', 'con la foto en la carpeta de otra: invalid 23514');
select is(pg_temp.push1(pg_temp.op('17'), 'insert', pg_temp.tk(pg_temp.u('e2'), '{"tipo": "RECIBO"}')) ->> 'code',
          '23514', 'con un tipo que no existe: invalid 23514');
select is(pg_temp.push1(pg_temp.op('18'), 'insert', pg_temp.tk(pg_temp.u('e2'), '{"tarjeta_tipo": "PREPAGA"}')) ->> 'code',
          '23514', 'con una tarjeta que no es crédito ni débito: invalid 23514');
select is((select count(*)::int from public.ticket where id = pg_temp.u('e2')), 0, 'ninguna escribió nada');

-- En un lote, una mala no tumba a las buenas.
create temp table r_lote as
  select sync.push(jsonb_build_array(
           jsonb_build_object('client_op_id', pg_temp.op('20'), 'entity', 'ticket', 'op', 'insert', 'payload', pg_temp.tk(pg_temp.u('e3'))),
           jsonb_build_object('client_op_id', pg_temp.op('21'), 'entity', 'ticket', 'op', 'insert', 'payload', pg_temp.tk(pg_temp.u('e4')) - 'monto'),
           jsonb_build_object('client_op_id', pg_temp.op('22'), 'entity', 'ticket', 'op', 'insert', 'payload', pg_temp.tk(pg_temp.u('e5'))))) as r;
select is((select array_agg(x ->> 'outcome' order by ord) from r_lote, jsonb_array_elements(r -> 'results') with ordinality t(x, ord)),
          array['accepted', 'invalid', 'accepted'], 'en un lote, la mala vuelve invalid y las buenas se aplican');

-- Un ticket que el coordinador ya resolvió: el update del teléfono vuelve conflict (la política no lo ve).
select pg_temp.actuar_como_servidor();
update public.ticket set estado = 'VALIDADO', revisado_por = pg_temp.u('c1'), revisado_en = now() where id = pg_temp.u('e3');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('23'), 'update',
                        jsonb_build_object('id', pg_temp.u('e3'), 'url_cloud', pg_temp.foto('b1', 'e3')),
                        (select sync_version from public.ticket where id = pg_temp.u('e3'))) ->> 'outcome',
          'conflict', 'completar la foto de un ticket ya validado, aun con la versión al día: conflict (la política no lo ve)');
select is(pg_temp.push1(pg_temp.op('24'), 'update',
                        jsonb_build_object('id', pg_temp.u('e3'), 'url_cloud', pg_temp.foto('b1', 'e3')),
                        (select sync_version from public.ticket where id = pg_temp.u('e3'))) -> 'server_row' ->> 'estado',
          'VALIDADO', 'con la fila del servidor, que dice VALIDADO');
select is((select url_cloud from public.ticket where id = pg_temp.u('e3')), null, 'y la foto no cambió');

-- Lo ajeno por push: no existe para quien sube.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('30'), 'update',
                        jsonb_build_object('id', pg_temp.u('e1'), 'url_cloud', pg_temp.foto('b2', 'e1')), 1) ->> 'code',
          'FILA_INEXISTENTE', 'b2 intenta completar la foto de un ticket de b1: FILA_INEXISTENTE (para él no existe)');
select is(pg_temp.push1(pg_temp.op('31'), 'delete', jsonb_build_object('id', pg_temp.u('e1')), 1) ->> 'outcome',
          'invalid', 'ni darlo de baja');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ticket where id = pg_temp.u('e1') and deleted_at is null and usuario_id = pg_temp.u('b1')), 1,
          'el ticket de b1 sigue intacto');

-- ---------------------------------------------------------------------------
-- 6. El ticket de un cobro es de quien hizo la venta
-- ---------------------------------------------------------------------------
-- Tickets: c1 (b1, validado), c4 (b1), d1 (b2).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                              values (pg_temp.u('a1'), pg_temp.u('71'), 1000, 'TARJETA', now(), pg_temp.u('c4')) $$),
          'ok', 'b1 liga a su cobro el ticket que subió');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                              values (pg_temp.u('a2'), pg_temp.u('71'), 1000, 'TARJETA', now(), pg_temp.u('d1')) $$),
          '42501 ', 'pero no el de b2');
select is(pg_temp.mensaje_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                                values (pg_temp.u('a2'), pg_temp.u('71'), 1000, 'TARJETA', now(), pg_temp.u('d1')) $$),
          'Ese ticket no es de quien hizo esta venta. Cargá el ticket de tu cobro desde tu teléfono.', 'con su aviso');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                              values (pg_temp.u('a2'), pg_temp.u('71'), 1000, 'TARJETA', now(), pg_temp.u('ff')) $$),
          '23503 cobranza_ticket_id_fkey', 'un ticket que no existe: lo dice la FK, no la guarda');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha) values (pg_temp.u('a3'), pg_temp.u('71'), 1000, 'EFECTIVO', now()) $$),
          'ok', 'un cobro sin ticket no cambia');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = pg_temp.u('d1') where id = pg_temp.u('a3') $$),
          '42501 ', 'ni ligarle después el de otra');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = pg_temp.u('c4') where id = pg_temp.u('a3') $$),
          'ok', 'pero sí el suyo');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1100 where id = pg_temp.u('a3') $$),
          'ok', 'y un cobro con ticket se corrige en lo demás sin que la guarda estorbe');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                              values (pg_temp.u('a4'), pg_temp.u('72'), 1000, 'TARJETA', now(), pg_temp.u('c4')) $$),
          '42501 ', 'b2 tampoco liga a su venta el ticket de b1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id)
                              values (pg_temp.u('a4'), pg_temp.u('72'), 1000, 'TARJETA', now(), pg_temp.u('c4')) $$),
          'ok', 'el servidor puede corregir a mano lo que haga falta');
select is(public.ticket_ajeno_a_la_venta(pg_temp.u('c4'), pg_temp.u('72')), true, 'ticket_ajeno_a_la_venta: de b1 sobre la venta de b2, ajeno');
select is(public.ticket_ajeno_a_la_venta(pg_temp.u('c4'), pg_temp.u('71')), false, 'sobre la venta de b1, no');
select is(public.ticket_ajeno_a_la_venta(pg_temp.u('ff'), pg_temp.u('71')), false, 'un ticket que no existe, no (habla la FK)');
select is(public.ticket_ajeno_a_la_venta(pg_temp.u('c4'), pg_temp.u('ff')), false, 'una venta que no existe, no (habla la RLS)');

-- ---------------------------------------------------------------------------
-- 7. La foto vence a los 4 meses
-- ---------------------------------------------------------------------------
-- Con foto: c1, cb y e1 (de hoy), c9 y d1 (de hace 5 meses), ca (de hace 110 días: todavía no vence).
update public.ticket set subido_en = now() - interval '5 months' where id in (pg_temp.u('c9'), pg_temp.u('d1'));
update public.ticket set subido_en = now() - interval '110 days' where id = pg_temp.u('ca');
update public.ticket set url_cloud = pg_temp.foto('b2', 'd1') where id = pg_temp.u('d1');
select is((select array_agg(right(ticket_id::text, 2) order by ticket_id) from public.tickets_con_foto_vencida()),
          array['c9', 'd1'], 'vencidas: las de hace más de 4 meses; la de 110 días todavía no');
select is((select ruta from public.tickets_con_foto_vencida() where ticket_id = pg_temp.u('d1')), pg_temp.foto('b2', 'd1'),
          'con su ruta, para borrar el archivo por la API de Storage');
select is((select array_agg(right(ticket_id::text, 2) order by ticket_id) from public.tickets_con_foto_vencida(now() + interval '30 days')),
          array['c9', 'ca', 'd1'], 'con otra fecha de corte cuenta con ella: 30 días después vence también la de 110 días');
select is((select count(*)::int from public.tickets_con_foto_vencida(
             (select subido_en + interval '4 months' from public.ticket where id = pg_temp.u('c9')))
            where ticket_id = pg_temp.u('c9')), 1, 'justo a los 4 meses ya vence (el borde cuenta)');
select is((select count(*)::int from public.tickets_con_foto_vencida(
             (select subido_en + interval '4 months' - interval '1 second' from public.ticket where id = pg_temp.u('c9')))
            where ticket_id = pg_temp.u('c9')), 0, 'un segundo antes, no');
select is((select ticket_id from public.tickets_con_foto_vencida() order by ticket_id limit 1), pg_temp.u('c9'),
          'salen por orden de antigüedad y de id');
select is(public.soltar_foto_de_ticket(pg_temp.u('c9')), true, 'soltar la foto de un ticket vencido: true');
select is((select url_cloud from public.ticket where id = pg_temp.u('c9')), null, 'queda sin foto');
select is((select monto from public.ticket where id = pg_temp.u('c9')), 100::bigint, 'y conserva sus datos');
select is(public.soltar_foto_de_ticket(pg_temp.u('c9')), false, 'soltarla otra vez: false (idempotente)');
select is(public.soltar_foto_de_ticket(pg_temp.u('ff')), false, 'un ticket que no existe: false');
select is((select array_agg(right(ticket_id::text, 2) order by ticket_id) from public.tickets_con_foto_vencida()),
          array['d1'], 'y ya no figura entre las vencidas');
-- Un ticket validado también la suelta (TK001 deja pasar url_cloud).
select is(public.soltar_foto_de_ticket(pg_temp.u('c1')), true, 'la foto de un ticket validado también se suelta (TK001 deja pasar url_cloud)');
select is((select estado from public.ticket where id = pg_temp.u('c1')), 'VALIDADO', 'y el ticket sigue validado');
-- Un ticket dado de baja con foto vencida sigue en la lista: el archivo hay que borrarlo igual.
update public.ticket set deleted_at = now() where id = pg_temp.u('d1');
select is((select count(*)::int from public.tickets_con_foto_vencida() where ticket_id = pg_temp.u('d1')), 1,
          'un ticket dado de baja con foto vencida sigue en la lista: el archivo se borra igual');

select * from finish();
rollback;
