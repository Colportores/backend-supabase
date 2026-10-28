-- pgTAP · migración 0131 (backend-supabase#200, seguimiento de #133 y #108; decisiones de Cristian del 27/10
-- «Anular offline», «Cobro fijo» y «Ticket libre»).
--   1. La forma: funciones, privilegios y lo que se fue (puede_ver_ticket_de).
--   2. «Anular offline»: la hora del teléfono manda (71 h vale aunque suba a las 80 h), inclusive a las 72 h, una hora
--      del futuro o anterior al cobro no (CB008), la gracia de 15 días de la campaña de la venta (CB009), el ticket
--      validado sigue frenando a la colportora (CB002) y el coordinador usa la hora del servidor.
--   3. «Cobro fijo»: dentro de las 72 h y sin ticket validado se corrige monto y medio; pasado el plazo o con el ticket
--      validado, no (CB007); el reenvío idéntico, atarle el ticket y anular siguen; el servidor corrige a mano.
--   4. Por sync_push: cada rechazo vuelve invalid con su código sin tumbar el lote.
--   5. «Ticket libre»: el ticket de un cobro lo ve y lo valida la campaña de su venta (aunque haya terminado hace
--      más de 15 días); el de un depósito, la de su fecha; sin campaña, la dueña y el ADMIN.
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
-- Ids: usuarios, campañas, ventas y tickets con dos caracteres hex.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000131' || p)::uuid;
$$;
-- El id de un cobro (n hasta 65535).
create or replace function pg_temp.uc(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000131' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
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
-- Un cobro cargado por el servidor (sin sesión nada se controla): lo dueño es el de la venta.
create or replace function pg_temp.cb(p_n integer, p_venta text, p_fecha timestamptz, p_medio text default 'EFECTIVO',
                                      p_ticket text default null) returns void language sql as $$
  insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id, created_by)
  values (pg_temp.uc(p_n), pg_temp.u(p_venta), 1000, p_medio, p_fecha, pg_temp.u(p_ticket),
          (select v.colportor_id from public.venta v where v.id = pg_temp.u(p_venta)));
$$;
-- Anular como quien llama con la hora del teléfono que se le dice: 'ok' o el SQLSTATE.
create or replace function pg_temp.anular_a(p_n integer, p_hora timestamptz) returns text language plpgsql as $$
begin
  update public.cobranza set anulado_at = p_hora, motivo_anulacion = 'Otro' where id = pg_temp.uc(p_n);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.fecha_de(p_n integer) returns timestamptz language sql as $$
  select fecha from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.anulado(p_n integer) returns boolean language sql as $$
  select anulado_at is not null from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.monto_de(p_n integer) returns integer language sql as $$
  select monto from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000131d0',
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
-- El job de un update de un cobro que ya existe, con la versión de sync que tiene el servidor.
create or replace function pg_temp.job_upd(p_op text, p_n integer, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'cobranza', 'op', 'update',
                            'sync_version', (select c.sync_version from public.cobranza c where c.id = pg_temp.uc(p_n)),
                            'payload', jsonb_build_object('id', pg_temp.uc(p_n)) || p_payload);
$$;
-- Los tickets que ve quien llama, de una lista, en una línea.
create or replace function pg_temp.ve(variadic p_ids text[]) returns text language sql as $$
  select coalesce(string_agg(x, ',' order by x), '-')
    from (select t.id, right(t.id::text, 2) as x from public.ticket t
           where t.id = any (select pg_temp.u(i) from unnest(p_ids) i)) q;
$$;
create or replace function pg_temp.sale(p_campania text) returns text language sql as $$
  select coalesce(string_agg(right(r.ticket_id::text, 2), ',' order by r.ticket_id), '-')
    from public.tickets_de_campania(pg_temp.u(p_campania)) r;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Campañas: c1 en curso (d1), c2 terminada hace 20 días, c3 terminada hace 15 días (todavía en gracia) y c4 hace 16
-- días (ya no), las tres de d2; c5 vieja terminada hace 60 días (d1); c6 en curso (d2).
-- Colportoras: b1 en c1; b2 en c2; b3 en c3; b4 en c4; b5 sin campaña; b6 en c5 y c6; b7 en c6 (su venta es de hace 200 días,
-- de ninguna campaña). a1 es ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cobro131-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','b6','b7','d1','d2','a1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('d2', 'COORDINADOR'), ('a1', 'ADMIN'),
               ('b1', 'COLPORTOR'), ('b2', 'COLPORTOR'), ('b3', 'COLPORTOR'), ('b4', 'COLPORTOR'),
               ('b5', 'COLPORTOR'), ('b6', 'COLPORTOR'), ('b7', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('c1'), 'c1 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1')),
  (pg_temp.u('c2'), 'c2 hace 20 dias', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 20, pg_temp.u('d2')),
  (pg_temp.u('c3'), 'c3 hace 15 dias', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 15, pg_temp.u('d2')),
  (pg_temp.u('c4'), 'c4 hace 16 dias', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 16, pg_temp.u('d2')),
  (pg_temp.u('c5'), 'c5 vieja', 'VERANO', public.hoy_montevideo() - 120, public.hoy_montevideo() - 60, pg_temp.u('d1')),
  (pg_temp.u('c6'), 'c6 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('c1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('c2'), pg_temp.u('b2'), now() - interval '59 days'),
  (pg_temp.u('c3'), pg_temp.u('b3'), now() - interval '59 days'),
  (pg_temp.u('c4'), pg_temp.u('b4'), now() - interval '59 days'),
  (pg_temp.u('c5'), pg_temp.u('b6'), now() - interval '119 days'),
  (pg_temp.u('c6'), pg_temp.u('b6'), now() - interval '9 days'),
  (pg_temp.u('c6'), pg_temp.u('b7'), now() - interval '9 days');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais cobro131', 'ZX');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad cobro131', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('f2'), 'CASA', 'Cobro 131', '1', -34.91, -56.2, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('f3'), pg_temp.u('f2'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('f4'), pg_temp.u('f3'), pg_temp.u('f5'), pg_temp.u('b1'));
-- Una venta por colportora, en la fecha que cae (o no) en su campaña.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u('f4'), 'T-131-' || x.v, 1000000, now() - x.hace, pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('71', interval '0 days', 'b1'), ('72', interval '30 days', 'b2'), ('73', interval '30 days', 'b3'),
               ('74', interval '30 days', 'b4'), ('75', interval '5 days', 'b5'), ('76', interval '90 days', 'b6'),
               ('77', interval '200 days', 'b7'), ('78', interval '1 hour', 'b6'),
               ('79', interval '0 days', 'b1')) x(v, hace, quien);
-- Tickets de tarjeta de b1: e1 validado, e2 pendiente, e3 rechazado.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, revisado_por, revisado_en, motivo_rechazo) values
  (pg_temp.u('e1'), pg_temp.u('b1'), 'COBRO_TARJETA', 1000, now(), 'VALIDADO', pg_temp.u('d1'), now(), null),
  (pg_temp.u('e2'), pg_temp.u('b1'), 'COBRO_TARJETA', 1000, now(), 'PENDIENTE', null, null, null),
  (pg_temp.u('e3'), pg_temp.u('b1'), 'COBRO_TARJETA', 1000, now(), 'RECHAZADO', pg_temp.u('d1'), now(), 'No se lee');

-- Los cobros de las secciones 2 a 4.
do $fx$
begin
  -- «Anular offline»
  perform pg_temp.cb(1,  '71', now() - interval '80 hours');
  perform pg_temp.cb(2,  '71', now() - interval '80 hours');
  perform pg_temp.cb(3,  '71', now() - interval '80 hours');
  perform pg_temp.cb(4,  '71', now() - interval '5 hours');
  perform pg_temp.cb(5,  '71', now() - interval '5 hours');
  perform pg_temp.cb(6,  '71', now() - interval '5 hours');
  perform pg_temp.cb(7,  '71', now() - interval '80 hours', 'TARJETA', 'e1');
  perform pg_temp.cb(8,  '72', now() - interval '2 hours');
  perform pg_temp.cb(9,  '73', now() - interval '2 hours');
  perform pg_temp.cb(10, '74', now() - interval '2 hours');
  perform pg_temp.cb(11, '75', now() - interval '2 hours');
  perform pg_temp.cb(12, '74', now() - interval '2 hours');
  perform pg_temp.cb(13, '71', now() - interval '80 hours');
  perform pg_temp.cb(14, '73', now() - interval '2 hours');
  perform pg_temp.cb(15, '72', now() - interval '2 hours');
  -- «Cobro fijo»: dentro del plazo
  perform pg_temp.cb(20, '71', now() - interval '10 hours');
  perform pg_temp.cb(21, '71', now() - interval '10 hours');
  perform pg_temp.cb(22, '71', now() - interval '10 hours');
  perform pg_temp.cb(23, '71', now() - interval '10 hours', 'TARJETA', 'e2');
  perform pg_temp.cb(24, '71', now() - interval '10 hours', 'TARJETA', 'e3');
  perform pg_temp.cb(25, '71', now() - interval '10 hours', 'TARJETA', 'e1');
  perform pg_temp.cb(26, '71', now() - interval '10 hours', 'TARJETA', 'e1');
  perform pg_temp.cb(27, '71', now() - interval '10 hours', 'TARJETA', 'e1');
  perform pg_temp.cb(28, '71', now() - interval '10 hours', 'TARJETA', 'e1');
  perform pg_temp.cb(29, '71', now() - interval '10 hours');
  -- pasado el plazo
  perform pg_temp.cb(30, '71', now() - interval '73 hours');
  perform pg_temp.cb(31, '71', now() - interval '73 hours');
  perform pg_temp.cb(32, '71', now() - interval '73 hours');
  perform pg_temp.cb(33, '71', now() - interval '73 hours');
  perform pg_temp.cb(34, '71', now() - interval '73 hours');
  perform pg_temp.cb(35, '71', now() - interval '73 hours');
  perform pg_temp.cb(36, '71', now() - interval '73 hours');
  update public.cobranza set deleted_at = now() where id = pg_temp.uc(36);
  -- los datos de la tarjeta, de la transferencia y la cuota
  perform pg_temp.cb(42, '71', now() - interval '73 hours', 'TARJETA');
  perform pg_temp.cb(43, '71', now() - interval '73 hours', 'TRANSFERENCIA');
  perform pg_temp.cb(44, '71', now() - interval '73 hours');
  perform pg_temp.cb(45, '71', now() - interval '10 hours', 'TARJETA');
  perform pg_temp.cb(46, '71', now() - interval '10 hours', 'TARJETA', 'e1');
  update public.cobranza set tarjeta_tipo = 'DEBITO', tarjeta_marca = 'Visa', numero_aprobacion = '123456'
   where id in (pg_temp.uc(42), pg_temp.uc(45), pg_temp.uc(46));
  update public.cobranza set referencia_transferencia = '88213', banco_origen = 'BROU' where id = pg_temp.uc(43);
  update public.cobranza set numero_cuota = 1 where id = pg_temp.uc(44);
  -- el borde
  perform pg_temp.cb(40, '71', now() - interval '72 hours');
  perform pg_temp.cb(41, '71', now() - interval '72 hours 1 second');
  -- el push
  perform pg_temp.cb(50, '71', now() - interval '73 hours');
  perform pg_temp.cb(51, '71', now() - interval '10 hours');
  perform pg_temp.cb(52, '71', now() - interval '73 hours');
  perform pg_temp.cb(53, '71', now() - interval '80 hours');
  perform pg_temp.cb(54, '71', now() - interval '80 hours');
  perform pg_temp.cb(55, '74', now() - interval '3 hours');
  perform pg_temp.cb(56, '71', now() - interval '5 hours');
end
$fx$;

-- Los tickets de la sección 5 y sus cobros.
-- t1 de un cobro de b6 en la venta vieja (c5, terminada hace 60 días); t2 de un depósito de b6 de hoy; t3 de un cobro de
-- b7 cuya venta no es de ninguna campaña; t4 sin cobro; t5 con un cobro dado de baja; t6 sin cobro todavía.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('91'), pg_temp.u('b6'), 'COBRO_TARJETA', 5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('92'), pg_temp.u('b6'), 'DEPOSITO',      5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('93'), pg_temp.u('b7'), 'COBRO_TARJETA', 5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('94'), pg_temp.u('b6'), 'COBRO_TARJETA', 5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('95'), pg_temp.u('b6'), 'COBRO_TARJETA', 5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('96'), pg_temp.u('b6'), 'COBRO_TARJETA', 5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('97'), pg_temp.u('b6'), 'COBRO_TARJETA', 5000, now() - interval '1 hour', 'PENDIENTE'),
  (pg_temp.u('98'), pg_temp.u('b7'), 'COBRO_TARJETA', 5000, now() - interval '100 days', 'PENDIENTE');
select pg_temp.cb(60, '76', now() - interval '1 hour', 'TARJETA', '91');
select pg_temp.cb(61, '77', now() - interval '1 hour', 'TARJETA', '93');
select pg_temp.cb(62, '76', now() - interval '1 hour', 'TARJETA', '95');
update public.cobranza set deleted_at = now() where id = pg_temp.uc(62);
select pg_temp.cb(63, '76', now() - interval '1 hour', 'TARJETA', '97');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id)
values (pg_temp.u('a2'), pg_temp.u('b6'), 5000, now() - interval '1 hour', pg_temp.u('92'), 'BANCO', 'CASA_EDITORA', null);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_function('public', 'campania_que_valida_el_ticket', array['uuid', 'uuid', 'timestamp with time zone'],
                    'existe campania_que_valida_el_ticket');
select has_function('public', 'puede_ver_ticket', array['uuid', 'uuid', 'timestamp with time zone'], 'existe puede_ver_ticket');
select ok(to_regprocedure('public.puede_ver_ticket_de(uuid, timestamptz)') is null, 'puede_ver_ticket_de ya no existe');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname in ('campania_que_valida_el_ticket', 'puede_ver_ticket')
            and p.prosecdef and p.proconfig = array['search_path=""']),
          2, 'las dos son SECURITY DEFINER con search_path vacío');
select is(has_function_privilege('authenticated', 'public.campania_que_valida_el_ticket(uuid, uuid, timestamptz)', 'execute'),
          false, 'la campaña que valida es interna: authenticated no la ejecuta');
select is(has_function_privilege('authenticated', 'public.puede_ver_ticket(uuid, uuid, timestamptz)', 'execute'), true,
          'puede_ver_ticket la ejecuta authenticated (la llama la política ticket_select)');
select is(has_function_privilege('anon', 'public.puede_ver_ticket(uuid, uuid, timestamptz)', 'execute'), false, 'anon no');
select is((select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'ticket' and policyname = 'ticket_select'),
          1, 'ticket_select sigue siendo una política');

-- ---------------------------------------------------------------------------
-- 2. «Anular offline»: la hora del teléfono
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
-- Ana: cobra a la hora 0, anula sin señal a la hora 71 (el teléfono dice now() - 9 h; el cobro es de hace 80 h) y sube a la hora 80.
select is(pg_temp.anular_a(1, now() - interval '9 hours'), 'ok',
          'el cobro de hace 80 h, anulado en el teléfono a la hora 71, vale aunque suba a la hora 80');
select is(pg_temp.anulado(1), true, 'y queda anulado');
select is((select anulado_at from public.cobranza where id = pg_temp.uc(1)), now() - interval '9 hours',
          'con la hora del teléfono, no la del servidor');
select is(pg_temp.anular_a(2, now() - interval '8 hours'), 'ok', 'a las 72 h justas desde el cobro todavía vale (inclusive)');
select is(pg_temp.anular_a(3, now() - interval '8 hours' + interval '1 second'), 'CB001', 'a las 72 h y un segundo no');
select is(pg_temp.mensaje_de($$ update public.cobranza set anulado_at = now() - interval '7 hours', motivo_anulacion = 'Otro'
                                where id = pg_temp.uc(3) $$),
          'CB001: Pasaron más de 72 horas desde el cobro: ya no se puede anular.', 'el mensaje dice qué pasó');
select is(pg_temp.anulado(3), false, 'y el cobro sigue vivo');
select is(pg_temp.anular_a(3, now()), 'CB001', 'con la hora del servidor (80 h) tampoco: lo que cuenta es la hora que dice el teléfono');
-- Una hora del futuro, o anterior al cobro, no es de fiar.
select is(pg_temp.anular_a(4, now() + interval '1 minute'), 'CB008', 'una hora del futuro no vale');
select is(pg_temp.mensaje_de($$ update public.cobranza set anulado_at = now() + interval '1 hour', motivo_anulacion = 'Otro'
                                where id = pg_temp.uc(4) $$),
          'CB008: La hora de la anulación no es válida: no puede ser del futuro ni anterior al cobro. Revisá la fecha y la hora de tu teléfono.',
          'y el aviso guía: revisar la hora del teléfono');
select is(pg_temp.anular_a(4, pg_temp.fecha_de(4) - interval '1 second'), 'CB008', 'una hora anterior al cobro tampoco');
select is(pg_temp.anulado(4), false, 'el cobro sigue vivo');
select is(pg_temp.anular_a(4, pg_temp.fecha_de(4)), 'ok', 'la misma hora del cobro vale (la colportora lo anula al instante)');
select is(pg_temp.anular_a(5, now()), 'ok', 'ahora vale');
-- Un cobro nuevo que ya llega anulado.
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion)
                              values (pg_temp.uc(70), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '80 hours',
                                      now() - interval '9 hours', 'Otro') $$), 'ok',
          'un cobro nuevo de hace 80 h que llega anulado a la hora 71 entra');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion)
                              values (pg_temp.uc(71), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '80 hours',
                                      now() - interval '7 hours', 'Otro') $$), 'CB001',
          'uno anulado a la hora 73 no');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, anulado_at, motivo_anulacion)
                              values (pg_temp.uc(72), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '1 hour',
                                      now() + interval '1 hour', 'Otro') $$), 'CB008', 'ni uno anulado en el futuro');
-- El reintento de una anulación que ya está.
select is(pg_temp.anular_a(1, now() - interval '9 hours'), 'ok', 'reenviar la misma anulación no falla');
select is(pg_temp.anular_a(1, now() - interval '8 hours'), 'CB003', 'pero cambiarle la hora sí: un cobro anulado no se reabre');
-- El ticket validado sigue frenando a la colportora, con la hora del teléfono.
select is(pg_temp.anular_a(7, now() - interval '9 hours'), 'CB002', 'con el ticket validado la colportora no anula, tampoco offline');
-- Los 15 días de gracia de las ventas: la campaña de la venta.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.anular_a(8, now()), 'CB009', 'la venta es de una campaña que terminó hace 20 días: ya no se anula');
select is(pg_temp.mensaje_de($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro' where id = pg_temp.uc(15) $$),
          'CB009: La campaña de esta venta terminó hace más de 15 días: el cobro ya no se puede anular. Pedile a tu coordinador que lo revise.',
          'y el aviso dice a quién pedírselo');
select is(pg_temp.anulado(8), false, 'el cobro sigue vivo');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.anular_a(9, now()), 'ok', 'a los 15 días justos del fin de la campaña todavía vale');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.anular_a(10, now()), 'CB009', 'a los 16 días no');
select is(pg_temp.anular_a(10, now() - interval '1 hour'), 'CB009', 'ni con una hora vieja del teléfono: la gracia mira cuándo sube');
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.anular_a(11, now()), 'ok', 'una venta que no es de ninguna campaña: no hay gracia que medir, vale la ventana de 72 h');
-- El coordinador usa la hora del servidor.
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(13), 'Otro') $$), 'CB001',
          'el coordinador anula con la hora del servidor: el cobro de hace 80 h no');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(6), 'Otro') $$), 'ok', 'el de hace 5 h sí');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(14), 'Otro') $$), 'ok', 'el coordinador de c3 (en gracia) anula');
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(15), 'Otro') $$), 'ok',
          'y el de c2, terminada hace 20 días, también: la gracia es de la colportora, no del coordinador');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(15), true, 'el cobro de c2 queda anulado');
-- El ADMIN igual; y un cobro con fecha en el futuro del servidor (reloj adelantado del teléfono) lo anula el coordinador.
select pg_temp.cb(16, '72', now() - interval '2 hours');
select pg_temp.cb(17, '71', now() + interval '1 hour');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(16), 'Otro') $$), 'ok', 'el ADMIN anula tras la gracia');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(17), 'Otro') $$), 'ok',
          'y el coordinador anula un cobro con fecha adelantada: CB008 no es suyo');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(16) and pg_temp.anulado(17), true, 'los dos quedan anulados');

-- ---------------------------------------------------------------------------
-- 3. «Cobro fijo»
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
-- Dentro del plazo y sin ticket validado, la dueña corrige.
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(20) $$), 'ok', 'dentro de las 72 h corrige el monto');
select is(pg_temp.monto_de(20), 1500, 'y queda');
select is(pg_temp.error_de($$ update public.cobranza set medio = 'TRANSFERENCIA' where id = pg_temp.uc(21) $$), 'ok', 'o el medio');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1200 where id = pg_temp.uc(21) $$), 'ok', 'y otra vez: dos correcciones seguidas');
select is(pg_temp.error_de($$ update public.cobranza set deleted_at = now() where id = pg_temp.uc(22) $$), 'ok', 'o lo da de baja');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(23) $$), 'ok', 'con el ticket pendiente corrige');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(24) $$), 'ok', 'con el ticket rechazado también');
select is(pg_temp.error_de($$ update public.cobranza set fecha = now() where id = pg_temp.uc(29) $$), 'CB006',
          'la fecha dentro del plazo sigue sin cambiar (CB006)');
-- Con el ticket validado, aunque estemos dentro de las 72 h.
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(25) $$), 'CB007', 'con el ticket validado no cambia el monto');
select is(pg_temp.error_de($$ update public.cobranza set medio = 'EFECTIVO' where id = pg_temp.uc(26) $$), 'CB007', 'ni el medio');
select is(pg_temp.error_de($$ update public.cobranza set deleted_at = now() where id = pg_temp.uc(27) $$), 'CB007', 'ni se da de baja');
select is(pg_temp.error_de($$ update public.cobranza set fecha = now() where id = pg_temp.uc(28) $$), 'CB007',
          'y a la fecha le contesta lo mismo que a todo: el cobro está fijo');
select is(pg_temp.mensaje_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(25) $$),
          'CB007: Este cobro ya no se puede cambiar. Si está mal, pedile a tu coordinador que lo revise.', 'con el texto que guía');
select is(pg_temp.monto_de(25), 1000, 'el cobro no cambió');
select is(pg_temp.error_de($$ update public.cobranza set monto = monto, medio = medio, fecha = fecha, deleted_at = deleted_at, ticket_id = ticket_id
                              where id = pg_temp.uc(25) $$), 'ok', 'el reenvío idéntico de la fila entera pasa');
-- Pasado el plazo.
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(30) $$), 'CB007', 'pasadas las 72 h no cambia el monto');
select is(pg_temp.error_de($$ update public.cobranza set medio = 'TRANSFERENCIA' where id = pg_temp.uc(31) $$), 'CB007', 'ni el medio');
select is(pg_temp.error_de($$ update public.cobranza set fecha = now() where id = pg_temp.uc(32) $$), 'CB007', 'ni la fecha');
select is(pg_temp.error_de($$ update public.cobranza set deleted_at = now() where id = pg_temp.uc(33) $$), 'CB007', 'ni se da de baja');
select is(pg_temp.error_de($$ update public.cobranza set deleted_at = null where id = pg_temp.uc(36) $$), 'CB007', 'ni se reactiva uno dado de baja');
select is(pg_temp.error_de($$ update public.cobranza set monto = monto, medio = medio, fecha = fecha, deleted_at = deleted_at
                              where id = pg_temp.uc(30) $$), 'ok', 'el reenvío idéntico pasa (la falla de señal no deja el cobro trabado)');
select is(pg_temp.error_de($$ update public.cobranza set ticket_id = pg_temp.u('e2') where id = pg_temp.uc(34) $$), 'ok', 'atarle su ticket pasa');
select is((select ticket_id from public.cobranza where id = pg_temp.uc(34)), pg_temp.u('e2'), 'y queda atado');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(34) $$), 'CB007', 'pero el cobro sigue fijo');
-- Anular sigue siendo la corrección: con la hora del teléfono, dentro del plazo, aunque suba pasado.
select is(pg_temp.error_de($$ update public.cobranza set monto = monto, anulado_at = now() - interval '2 hours',
                                     motivo_anulacion = 'Monto equivocado' where id = pg_temp.uc(35) $$), 'ok',
          'un cobro de hace 73 h anulado en el teléfono a la hora 71 se anula, con la fila entera');
select is(pg_temp.anulado(35), true, 'y queda anulado');
select is(pg_temp.error_de($$ update public.cobranza set venta_id = pg_temp.u('79') where id = pg_temp.uc(30) $$), 'CB007',
          'pasado el plazo el cobro no se pasa a otra venta');
select is(pg_temp.error_de($$ update public.cobranza set venta_id = pg_temp.u('79') where id = pg_temp.uc(25) $$), 'CB007',
          'ni con el ticket validado');
-- Fijo es todo el cobro: también los datos de la tarjeta, de la transferencia y el número de cuota (decisión del mapa, P2 de #200).
select is(pg_temp.error_de($$ update public.cobranza set tarjeta_tipo = 'CREDITO' where id = pg_temp.uc(42) $$), 'CB007', 'pasado el plazo no cambia el tipo de tarjeta');
select is(pg_temp.error_de($$ update public.cobranza set tarjeta_marca = 'OCA' where id = pg_temp.uc(42) $$), 'CB007', 'ni la marca');
select is(pg_temp.error_de($$ update public.cobranza set numero_aprobacion = '999999' where id = pg_temp.uc(42) $$), 'CB007', 'ni la aprobación');
select is(pg_temp.error_de($$ update public.cobranza set referencia_transferencia = '1' where id = pg_temp.uc(43) $$), 'CB007', 'ni la referencia de la transferencia');
select is(pg_temp.error_de($$ update public.cobranza set banco_origen = 'Itaú' where id = pg_temp.uc(43) $$), 'CB007', 'ni el banco');
select is(pg_temp.error_de($$ update public.cobranza set numero_cuota = 2 where id = pg_temp.uc(44) $$), 'CB007', 'ni el número de cuota');
select is(pg_temp.error_de($$ update public.cobranza set tarjeta_tipo = tarjeta_tipo, tarjeta_marca = tarjeta_marca, numero_aprobacion = numero_aprobacion,
                                     referencia_transferencia = referencia_transferencia, banco_origen = banco_origen, numero_cuota = numero_cuota
                              where id = pg_temp.uc(42) $$), 'ok', 'el reenvío idéntico con esos datos pasa');
select is(pg_temp.error_de($$ update public.cobranza set tarjeta_marca = 'OCA', numero_aprobacion = '999999', numero_cuota = 2 where id = pg_temp.uc(45) $$), 'ok',
          'dentro del plazo se corrigen junto con el monto y el medio');
select is(pg_temp.error_de($$ update public.cobranza set tarjeta_marca = 'OCA' where id = pg_temp.uc(46) $$), 'CB007', 'con el ticket validado, la marca tampoco');
-- El borde: 72 h inclusive.
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(40) $$), 'ok', 'a las 72 h justas todavía corrige');
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(41) $$), 'CB007', 'a las 72 h y un segundo no');
-- Corregir y anular, dos acciones seguidas dentro del plazo.
select is(pg_temp.error_de($$ update public.cobranza set monto = 1700 where id = pg_temp.uc(29) $$), 'ok', 'corrige el monto');
select is(pg_temp.anular_a(29, now()), 'ok', 'y después lo anula');
-- Otra colportora no toca el cobro de b1.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500 where id = pg_temp.uc(21) $$), 'ok',
          'b2 intenta corregir un cobro de b1: la RLS esconde la fila, sin efecto');
select pg_temp.actuar_como_servidor();
select is(pg_temp.monto_de(21), 1200, 'y el cobro de b1 quedó como estaba');
-- El servidor sí corrige a mano.
select is(pg_temp.error_de($$ update public.cobranza set monto = 1500, fecha = fecha - interval '1 hour' where id = pg_temp.uc(25) $$), 'ok',
          'sin sesión (el servidor) puede corregir un cobro fijo');

-- ---------------------------------------------------------------------------
-- 4. Por sync_push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote as
select pg_temp.push(jsonb_build_array(
  pg_temp.job_upd('e0', 50, jsonb_build_object('monto', 1500)),                                     -- fijo: CB007
  pg_temp.job_upd('e1', 51, jsonb_build_object('monto', 1500, 'medio', 'TRANSFERENCIA')),           -- dentro del plazo: entra
  pg_temp.job_upd('e2', 52, jsonb_build_object('monto', 1000)),                                     -- fijo, idéntico: entra
  pg_temp.job_upd('e3', 53, jsonb_build_object('anulado_at', now() - interval '9 hours',
                                               'motivo_anulacion', 'Otro')),                         -- offline, hora 71: entra
  pg_temp.job_upd('e4', 54, jsonb_build_object('anulado_at', now() + interval '1 hour',
                                               'motivo_anulacion', 'Otro')),                         -- futura: CB008
  pg_temp.job_upd('e6', 56, jsonb_build_object('anulado_at', now() - interval '1 hour',
                                               'motivo_anulacion', 'Otro'))                          -- la venta es de b1 y vale
)) as r;
grant select on lote to authenticated;
select is(pg_temp.resultados((select r from lote)),
          array['invalid', 'accepted', 'accepted', 'accepted', 'invalid', 'accepted'],
          'el lote: cada rechazo vuelve invalid y el resto sigue');
select is(pg_temp.codigos((select r from lote)), array['CB007', '-', '-', '-', 'CB008', '-'],
          'con su código: CB007 (cobro fijo) y CB008 (hora futura)');
-- La gracia: la venta es de una campaña terminada hace 16 días.
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job_upd('e5', 55, jsonb_build_object('anulado_at', now() - interval '1 hour', 'motivo_anulacion', 'Otro'))))),
          array['CB009'], 'por el push, CB009: la campaña de la venta terminó hace más de 15 días');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(55), false, 'y el cobro no se anuló');
select pg_temp.actuar_como_servidor();
select is(pg_temp.monto_de(50), 1000, 'el cobro fijo no cambió');
select is(pg_temp.monto_de(51), 1500, 'el corregido dentro del plazo sí');
select is(pg_temp.anulado(53), true, 'la anulación offline de la hora 71 quedó');
select is(pg_temp.anulado(54), false, 'la de la hora futura no');
select is(pg_temp.anulado(56), true, 'la de ahora quedó');

-- ---------------------------------------------------------------------------
-- 5. «Ticket libre»: la campaña que valida el ticket
-- ---------------------------------------------------------------------------
select is(public.campania_que_valida_el_ticket(pg_temp.u('91'), pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c5'),
          'el ticket de un cobro de una venta vieja es de la campaña de la venta (c5, terminada hace 60 días)');
select is(public.campania_del_ticket(pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c6'),
          'por su fecha habría sido de c6: la regla nueva manda');
select is(public.campania_que_valida_el_ticket(pg_temp.u('92'), pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c6'),
          'el ticket de un depósito sigue yendo por su fecha (c6)');
select is(public.campania_que_valida_el_ticket(pg_temp.u('93'), pg_temp.u('b7'), now() - interval '1 hour'), null,
          'el de un cobro cuya venta no es de ninguna campaña no es de ninguna, aunque por su fecha fuera de c6');
select is(public.campania_que_valida_el_ticket(pg_temp.u('94'), pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c6'),
          'un ticket sin cobro va por su fecha');
select is(public.campania_que_valida_el_ticket(pg_temp.u('95'), pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c6'),
          'con el cobro dado de baja, también por su fecha');
select is(public.campania_que_valida_el_ticket(null, pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c6'),
          'sin ticket (null) se comporta por la fecha');
select is(public.campania_que_valida_el_ticket(pg_temp.u('98'), pg_temp.u('b7'), now() - interval '100 days'), null,
          'un ticket sin cobro cuya fecha no cae en ninguna inscripción no es de ninguna (no se prueba con hoy)');
-- Un ticket que llega antes que el cobro que lo apunta cambia de campaña cuando el cobro llega.
select is(public.campania_que_valida_el_ticket(pg_temp.u('96'), pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c6'),
          'el ticket 96, sin cobro todavía, es de c6');
select pg_temp.cb(64, '76', now() - interval '1 hour', 'TARJETA', '96');
select is(public.campania_que_valida_el_ticket(pg_temp.u('96'), pg_temp.u('b6'), now() - interval '1 hour'), pg_temp.u('c5'),
          'y cuando el cobro lo apunta, de c5');

-- puede_ver_ticket(), llamada directa.
select pg_temp.actuar_como(pg_temp.u('b6'));
select is(public.puede_ver_ticket(pg_temp.u('91'), pg_temp.u('b6'), now()), true, 'la dueña lo ve');
select is(public.puede_ver_ticket(pg_temp.u('91'), pg_temp.u('b7'), now()), false, 'y el de otro colportor no');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(public.puede_ver_ticket(pg_temp.u('93'), pg_temp.u('b7'), now()), true, 'el ADMIN ve el de ninguna campaña');
select pg_temp.actuar_como_servidor();

-- Quién lo ve (RLS de ticket).
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.ve('91', '92', '93', '94', '95', '96', '97'), '91,96,97', 'd1 (coordina c5) ve los tickets de los cobros de la venta vieja');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.ve('91', '92', '93', '94', '95', '96', '97'), '92,94,95', 'd2 (coordina c6) ve el depósito y los que no tienen cobro vivo, no los de la venta vieja');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.ve('91', '92', '93', '94', '95', '96', '97'), '91,92,93,94,95,96,97', 'el ADMIN ve todos, también el de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('b6'));
select is(pg_temp.ve('91', '92', '93', '94', '95', '96', '97'), '91,92,94,95,96,97', 'la dueña ve los suyos');
select pg_temp.actuar_como(pg_temp.u('b7'));
select is(pg_temp.ve('91', '92', '93', '94', '95', '96', '97'), '93', 'y b7, el suyo, de ninguna campaña');
-- La foto del bucket sigue la misma regla.
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(public.puede_ver_foto_de_ticket(pg_temp.u('b6')::text || '/' || pg_temp.u('91')::text), true, 'd1 ve la foto del ticket de la venta vieja');
select is(public.puede_ver_foto_de_ticket(pg_temp.u('b6')::text || '/' || pg_temp.u('92')::text || '.jpg'), false, 'y no la del depósito de c6');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(public.puede_ver_foto_de_ticket(pg_temp.u('b6')::text || '/' || pg_temp.u('91')::text), false, 'd2 no ve la del ticket de la venta vieja');
select is(public.puede_ver_foto_de_ticket(pg_temp.u('b6')::text || '/' || pg_temp.u('92')::text || '.jpg'), true, 'pero sí la del depósito');
select is(public.puede_ver_foto_de_ticket(pg_temp.u('b7')::text || '/' || pg_temp.u('93')::text), false, 'y no la de ninguna campaña');

-- El historial (vista 29): cada ticket sale en la campaña que lo valida.
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.sale('c5'), '91,96,97', 'c5 lista los tickets de los cobros de su venta, aunque la campaña terminó hace 60 días');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.sale('c6'), '92,94,95', 'c6 lista el depósito y los sin cobro; el de b7, de ninguna campaña, no sale en ninguna');

-- Validar y rechazar siguen a la misma campaña.
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('91')) $$), 'TV001', 'd2 no valida el ticket de la venta de c5');
select is(pg_temp.error_de($$ select public.rechazar_ticket(pg_temp.u('97'), 'No se lee') $$), 'TV001', 'ni lo rechaza');
select is(pg_temp.error_de($$ select * from public.validacion_de_ticket(pg_temp.u('91')) $$), 'TV001', 'ni mira la previa');
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('93')) $$), 'TV001', 'el de ninguna campaña tampoco');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('93')) $$), 'TV001', 'ni d1');
select is(pg_temp.error_de($$ select * from public.validacion_de_ticket(pg_temp.u('91')) $$), 'ok', 'd1 sí mira la previa del de la venta de su campaña');
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('91')) $$), 'ok', 'y lo valida, aunque el cobro se haya hecho con la campaña terminada');
select is(pg_temp.error_de($$ select public.rechazar_ticket(pg_temp.u('97'), 'No se lee') $$), 'ok', 'y rechaza otro');
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('92')) $$), 'TV001', 'pero no el depósito de c6');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('93')) $$), 'ok', 'el ADMIN valida el de ninguna campaña');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.error_de($$ select public.validar_ticket(pg_temp.u('94')) $$), 'ok', 'd2 valida el que no tiene cobro, por su fecha');

select * from finish();
rollback;
