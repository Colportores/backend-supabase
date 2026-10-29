-- pgTAP · migración 0151 (backend-supabase#220, seguimiento de #200; respuestas de Cristian del 28/10 «Reloj adel.»,
-- «Corregir off» y «Anular sin c.»).
--   1. La forma: la columna nueva y la función de la gracia.
--   2. «Reloj adel.»: hasta 5 minutos «del futuro» vale (anular y corregir); 5 minutos y un segundo, no (CB008).
--   3. «Corregir off»: la corrección se mide con la hora del teléfono (71 h vale aunque suba a las 80 h; 72 h inclusive;
--      72 h y un segundo, CB007); sin esa hora se mide con la del servidor; una hora anterior al cobro o del futuro es
--      CB008; con el ticket validado, fijo; dos correcciones seguidas; fuera de la gracia, CB009; un cobro nuevo que ya
--      trae su hora de corrección entra sin juzgarla.
--   4. «Anular sin c.»: sin campaña o con la gracia ya vencida al cobrar, 15 días desde el cobro (inclusive); con la
--      gracia abierta al cobrar, la de la campaña (CB009 si ya cerró); el coordinador no tiene CB009.
--   5. Por sync_push: la corrección con su hora entra y los rechazos vuelven invalid con su código.
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
  select ('01920000-0000-7000-8000-0000000151' || p)::uuid;
$$;
create or replace function pg_temp.uc(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000151' || lpad(to_hex(p_n), 4, '0'))::uuid;
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
-- Un cobro cargado por el servidor (sin sesión nada se controla); la dueña es la de la venta.
create or replace function pg_temp.cb(p_n integer, p_venta text, p_fecha timestamptz, p_medio text default 'EFECTIVO',
                                      p_ticket text default null) returns void language sql as $$
  insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id, created_by)
  values (pg_temp.uc(p_n), pg_temp.u(p_venta), 1000, p_medio, p_fecha, pg_temp.u(p_ticket),
          (select v.colportor_id from public.venta v where v.id = pg_temp.u(p_venta)));
$$;
create or replace function pg_temp.fecha_de(p_n integer) returns timestamptz language sql as $$
  select fecha from public.cobranza where id = pg_temp.uc(p_n);
$$;
-- Anular como quien llama con la hora del teléfono que se le dice: 'ok' o el SQLSTATE.
create or replace function pg_temp.anular_a(p_n integer, p_hora timestamptz) returns text language plpgsql as $$
begin
  update public.cobranza set anulado_at = p_hora, motivo_anulacion = 'Otro' where id = pg_temp.uc(p_n);
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.anular_msg(p_n integer, p_hora timestamptz) returns text language plpgsql as $$
begin
  update public.cobranza set anulado_at = p_hora, motivo_anulacion = 'Otro' where id = pg_temp.uc(p_n);
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
-- Corregir el monto con la hora del teléfono (null = la app no la manda): 'ok' o el SQLSTATE.
create or replace function pg_temp.corregir(p_n integer, p_monto integer, p_hora timestamptz) returns text language plpgsql as $$
begin
  if p_hora is null then
    update public.cobranza set monto = p_monto where id = pg_temp.uc(p_n);
  else
    update public.cobranza set monto = p_monto, corregido_at = p_hora where id = pg_temp.uc(p_n);
  end if;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.corregir_msg(p_n integer, p_monto integer, p_hora timestamptz) returns text language plpgsql as $$
begin
  update public.cobranza set monto = p_monto, corregido_at = p_hora where id = pg_temp.uc(p_n);
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
create or replace function pg_temp.anulado(p_n integer) returns boolean language sql as $$
  select anulado_at is not null from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.monto_de(p_n integer) returns integer language sql as $$
  select monto from public.cobranza where id = pg_temp.uc(p_n);
$$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000151d0',
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
create or replace function pg_temp.job_upd(p_op text, p_n integer, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', 'cobranza', 'op', 'update',
                            'sync_version', (select c.sync_version from public.cobranza c where c.id = pg_temp.uc(p_n)),
                            'payload', jsonb_build_object('id', pg_temp.uc(p_n)) || p_payload);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Campañas: c1 en curso (d1); c4 terminada hace 16 días (su gracia cerró ayer); c5 vieja, terminada hace 60 días;
-- c6 en curso (d2). Colportoras: b1 en c1; b4 en c4; b6 en c5 y c6; b7 en c6 con una venta de hace 200 días que no cae
-- en ninguna campaña. d1 y d2 coordinan; a1 es ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cobro151-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b4','b6','b7','d1','d2','a1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('d2', 'COORDINADOR'), ('a1', 'ADMIN'),
               ('b1', 'COLPORTOR'), ('b4', 'COLPORTOR'), ('b6', 'COLPORTOR'), ('b7', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('c1'), 'c1 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1')),
  (pg_temp.u('c4'), 'c4 hace 16 dias', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 16, pg_temp.u('d2')),
  (pg_temp.u('c5'), 'c5 vieja', 'VERANO', public.hoy_montevideo() - 120, public.hoy_montevideo() - 60, pg_temp.u('d1')),
  (pg_temp.u('c6'), 'c6 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('c1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('c4'), pg_temp.u('b4'), now() - interval '59 days'),
  (pg_temp.u('c5'), pg_temp.u('b6'), now() - interval '119 days'),
  (pg_temp.u('c6'), pg_temp.u('b6'), now() - interval '9 days'),
  (pg_temp.u('c6'), pg_temp.u('b7'), now() - interval '9 days');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais cobro151', 'ZY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad cobro151', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('f2'), 'CASA', 'Cobro 151', '1', -34.91, -56.2, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('f3'), pg_temp.u('f2'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('f4'), pg_temp.u('f3'), pg_temp.u('f5'), pg_temp.u('b1'));
-- Una venta por colportora, en la fecha que cae (o no) en su campaña.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u('f4'), 'T-151-' || x.v, 1000000, now() - x.hace, pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('71', interval '0 days', 'b1'), ('74', interval '30 days', 'b4'), ('76', interval '90 days', 'b6'),
               ('77', interval '200 days', 'b7')) x(v, hace, quien);
-- Un ticket de tarjeta de b1 ya validado.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, revisado_por, revisado_en) values
  (pg_temp.u('e1'), pg_temp.u('b1'), 'COBRO_TARJETA', 1000, now(), 'VALIDADO', pg_temp.u('d1'), now());

do $fx$
begin
  -- «Reloj adel.»
  perform pg_temp.cb(1, '71', now() - interval '5 hours');
  perform pg_temp.cb(2, '71', now() - interval '5 hours');
  perform pg_temp.cb(3, '71', now() - interval '1 hour');
  perform pg_temp.cb(4, '71', now() - interval '1 hour');
  perform pg_temp.cb(5, '71', now() - interval '1 hour');
  -- «Corregir off»: cobros de hace 80 h (la hora 71 vale; subir a la hora 80 no importa)
  perform pg_temp.cb(10, '71', now() - interval '80 hours');
  perform pg_temp.cb(11, '71', now() - interval '80 hours');
  perform pg_temp.cb(12, '71', now() - interval '80 hours');
  perform pg_temp.cb(13, '71', now() - interval '80 hours');
  perform pg_temp.cb(17, '71', now() - interval '80 hours');
  perform pg_temp.cb(18, '71', now() - interval '10 hours', 'TARJETA', 'e1');
  perform pg_temp.cb(19, '71', now() - interval '80 hours');
  perform pg_temp.cb(20, '71', now() - interval '80 hours');
  perform pg_temp.cb(21, '71', now() - interval '80 hours');
  update public.cobranza set corregido_at = fecha + interval '1 hour' where id = pg_temp.uc(20);
  -- dentro de las 72 h con la hora del servidor (como siempre)
  perform pg_temp.cb(22, '71', now() - interval '10 hours');
  -- la gracia de la corrección
  perform pg_temp.cb(23, '74', now() - interval '2 days');
  perform pg_temp.cb(24, '77', now() - interval '16 days');
  perform pg_temp.cb(25, '77', now() - interval '14 days');
  -- por el push
  perform pg_temp.cb(30, '71', now() - interval '80 hours');
  perform pg_temp.cb(31, '71', now() - interval '80 hours');
  perform pg_temp.cb(32, '74', now() - interval '2 days');
  -- «Anular sin c.»
  perform pg_temp.cb(40, '77', now() - interval '16 days');
  perform pg_temp.cb(41, '77', now() - interval '14 days');
  perform pg_temp.cb(42, '77', now() - interval '15 days');
  perform pg_temp.cb(43, '77', now() - interval '15 days' - interval '1 second');
  perform pg_temp.cb(44, '76', now() - interval '16 days');
  perform pg_temp.cb(45, '76', now() - interval '14 days');
  perform pg_temp.cb(46, '74', now() - interval '2 days');
  perform pg_temp.cb(47, '74', now() - interval '1 hour');
  perform pg_temp.cb(48, '71', now() - interval '2 days');
  perform pg_temp.cb(49, '74', now() - interval '2 days');
end
$fx$;

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'cobranza', 'corregido_at', 'cobranza.corregido_at existe');
select col_type_is('public', 'cobranza', 'corregido_at', 'timestamp with time zone', 'es timestamptz');
select col_is_null('public', 'cobranza', 'corregido_at', 'y es opcional: una app vieja no la manda');
select is(has_function_privilege('authenticated', 'public.cobro_fuera_de_gracia(uuid, timestamptz, timestamptz)', 'execute'), false,
          'cobro_fuera_de_gracia es interna: authenticated no la ejecuta');
select is(has_function_privilege('anon', 'public.cobro_fuera_de_gracia(uuid, timestamptz, timestamptz)', 'execute'), false,
          'ni anon');
select is(has_function_privilege('service_role', 'public.cobro_fuera_de_gracia(uuid, timestamptz, timestamptz)', 'execute'), false,
          'ni service_role');
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname = 'cobro_fuera_de_gracia' and p.prosecdef and p.proconfig = array['search_path=""']),
          1, 'es SECURITY DEFINER con search_path vacío');
select is(public.cobro_fuera_de_gracia(pg_temp.u('b7'), now() - interval '200 days', now() - interval '16 days'), 'COBRO',
          'la venta sin campaña, cobrada hace 16 días: COBRO');
select is(public.cobro_fuera_de_gracia(pg_temp.u('b7'), now() - interval '200 days', now() - interval '14 days'), null,
          'cobrada hace 14 días: a tiempo');
select is(public.cobro_fuera_de_gracia(pg_temp.u('b4'), now() - interval '30 days', now() - interval '2 days'), 'CAMPANIA',
          'la gracia de la campaña estaba abierta al cobrar y ya cerró: CAMPANIA');
select is(public.cobro_fuera_de_gracia(pg_temp.u('b4'), now() - interval '30 days', now() - interval '1 hour'), null,
          'con la gracia ya cerrada al cobrar, rigen los 15 días desde el cobro: a tiempo');
select is(public.cobro_fuera_de_gracia(pg_temp.u('b1'), now(), now() - interval '2 days'), null,
          'con la campaña en curso, a tiempo');

-- ---------------------------------------------------------------------------
-- 2. «Reloj adel.»: 5 minutos de margen
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.anular_a(1, now() + interval '5 minutes'), 'ok',
          'anular con el reloj del teléfono 5 minutos adelantado vale');
select is(pg_temp.anulado(1), true, 'y queda anulado');
select is(pg_temp.anular_a(2, now() + interval '5 minutes 1 second'), 'CB008', 'a 5 minutos y un segundo no: CB008');
select is(pg_temp.mensaje_de($$ update public.cobranza set anulado_at = now() + interval '6 minutes', motivo_anulacion = 'Otro'
                                where id = pg_temp.uc(2) $$),
          'CB008: La hora de la anulación no es válida: no puede ser del futuro ni anterior al cobro. Revisá la fecha y la hora de tu teléfono.',
          'con su aviso, que manda a revisar la hora del teléfono');
select is(pg_temp.anulado(2), false, 'y el cobro sigue vivo');
select is(pg_temp.anular_a(2, pg_temp.fecha_de(2) - interval '1 second'), 'CB008', 'una hora anterior al cobro sigue siendo CB008');
select is(pg_temp.anular_a(2, now() - interval '4 minutes'), 'ok', 'y una hora razonable vale');

-- ---------------------------------------------------------------------------
-- 3. «Corregir off»: la corrección se mide con la hora del teléfono
-- ---------------------------------------------------------------------------
-- Ana corrige sin señal a la hora 71 de un cobro de hace 80 h; la corrección sube ahora (a la hora 80).
select is(pg_temp.corregir(10, 1500, now() - interval '9 hours'), 'ok', 'la corrección de la hora 71 vale aunque suba a la hora 80');
select is(pg_temp.monto_de(10), 1500, 'el monto cambió');
select is((select corregido_at from public.cobranza where id = pg_temp.uc(10)), now() - interval '9 hours',
          'y queda la hora del teléfono');
select is(pg_temp.corregir(11, 1500, pg_temp.fecha_de(11) + interval '72 hours'), 'ok', 'a las 72 h justas vale (inclusive)');
select is(pg_temp.corregir(12, 1500, pg_temp.fecha_de(12) + interval '72 hours 1 second'), 'CB007', 'a las 72 h y un segundo, el cobro está fijo: CB007');
select is(pg_temp.mensaje_de($$ update public.cobranza set monto = 1500, corregido_at = fecha + interval '73 hours' where id = pg_temp.uc(12) $$),
          'CB007: Este cobro ya no se puede cambiar. Si está mal, pedile a tu coordinador que lo revise.', 'con su aviso');
select is(pg_temp.monto_de(12), 1000, 'y el monto no cambió');
-- Sin la hora del teléfono (una versión vieja de la app) se mide con la del servidor, como hoy.
select is(pg_temp.corregir(13, 1500, null), 'CB007', 'sin hora del teléfono: la hora del servidor (80 h) lo encuentra fijo');
select is(pg_temp.corregir(22, 1500, null), 'ok', 'y un cobro de hace 10 h se corrige sin hora, como siempre');
-- Con la hora anterior al cobro o del futuro, CB008.
select is(pg_temp.corregir(17, 1500, pg_temp.fecha_de(17) - interval '1 second'), 'CB008', 'una hora anterior al cobro: CB008');
select is(pg_temp.mensaje_de($$ update public.cobranza set monto = 1500, corregido_at = fecha - interval '1 hour' where id = pg_temp.uc(17) $$),
          'CB008: La hora de la corrección no es válida: no puede ser del futuro ni anterior al cobro. Revisá la fecha y la hora de tu teléfono.',
          'con su aviso');
select is(pg_temp.corregir(3, 1500, now() + interval '5 minutes'), 'ok', 'con el reloj 5 minutos adelantado vale');
select is(pg_temp.corregir(4, 1500, now() + interval '5 minutes 1 second'), 'CB008', 'a 5 minutos y un segundo no');
select is(pg_temp.monto_de(4), 1000, 'y no cambió nada');
-- Una corrección que NO cambia la hora (la app reenvía la fila) se mide con la hora del servidor: el cobro de 80 h está fijo.
select is(pg_temp.corregir(20, 1500, (select corregido_at from public.cobranza where id = pg_temp.uc(20))), 'CB007',
          'la misma hora de antes cuenta como "sin hora nueva": rige la del servidor');
-- Con el ticket validado, fijo aunque la hora sea buena.
select is(pg_temp.corregir(18, 1500, pg_temp.fecha_de(18) + interval '1 hour'), 'CB007', 'con el ticket validado el cobro sigue fijo');
-- Dos correcciones seguidas, cada una con su hora.
select is(pg_temp.corregir(19, 1200, pg_temp.fecha_de(19) + interval '10 hours'), 'ok', 'primera corrección, a la hora 10');
select is(pg_temp.corregir(19, 1700, pg_temp.fecha_de(19) + interval '20 hours'), 'ok', 'segunda corrección, a la hora 20');
select is(pg_temp.monto_de(19), 1700, 'queda la segunda');
select is((select corregido_at from public.cobranza where id = pg_temp.uc(19)), pg_temp.fecha_de(19) + interval '20 hours',
          'con la hora de la segunda');
select is(pg_temp.corregir(19, 1900, pg_temp.fecha_de(19) + interval '73 hours'), 'CB007', 'y una tercera fuera de las 72 h ya no');
select is(pg_temp.monto_de(19), 1700, 'que no pisa la segunda');
-- La corrección con hora también tiene que subir dentro de la gracia.
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.corregir(23, 1500, pg_temp.fecha_de(23) + interval '1 hour'), 'CB009',
          'la gracia de la campaña de la venta cerró entre el cobro y la subida: CB009');
select is(pg_temp.corregir_msg(23, 1500, pg_temp.fecha_de(23) + interval '1 hour'),
          'CB009: La campaña de esta venta terminó hace más de 15 días: el cobro ya no se puede corregir. Pedile a tu coordinador que lo revise.',
          'con el aviso de la campaña');
select pg_temp.actuar_como(pg_temp.u('b7'));
select is(pg_temp.corregir(24, 1500, pg_temp.fecha_de(24) + interval '1 hour'), 'CB009', 'una venta sin campaña, cobrada hace 16 días: CB009');
select is(pg_temp.corregir_msg(24, 1500, pg_temp.fecha_de(24) + interval '1 hour'),
          'CB009: Pasaron más de 15 días desde el cobro: ya no se puede corregir. Pedile a tu coordinador que lo revise.',
          'con el aviso de los 15 días');
select is(pg_temp.corregir(25, 1500, pg_temp.fecha_de(25) + interval '1 hour'), 'ok', 'cobrada hace 14 días: sube a tiempo');
-- Un cobro nuevo que ya trae su hora de corrección.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, corregido_at)
                              values (pg_temp.uc(60), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '3 hours',
                                      now() - interval '2 hours') $$), 'ok', 'un cobro nuevo ya corregido en el teléfono entra');
-- Un cobro nuevo con la hora de corrección rara (reloj adelantado o atrasado) entra igual: perderlo sería perder un cobro vivo.
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, corregido_at)
                              values (pg_temp.uc(61), pg_temp.u('71'), 1000, 'EFECTIVO', now() + interval '10 minutes',
                                      now() + interval '11 minutes') $$), 'ok',
          'un cobro de un teléfono con el reloj adelantado, corregido un minuto después, entra');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, corregido_at)
                              values (pg_temp.uc(62), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '3 hours',
                                      now() - interval '4 hours') $$), 'ok',
          'uno cuya corrección quedó antes del cobro (el reloj se atrasó) también entra');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, corregido_at)
                              values (pg_temp.uc(63), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '3 hours',
                                      now() + interval '1 day') $$), 'ok', 'ni aunque la hora sea de mañana');
select is(pg_temp.error_de($$ insert into public.cobranza (id, venta_id, monto, medio, fecha, corregido_at)
                              values (pg_temp.uc(60), pg_temp.u('71'), 1000, 'EFECTIVO', now() - interval '3 hours',
                                      now() + interval '1 day') on conflict do nothing $$), 'ok',
          'reenviar un alta que ya está se resuelve como duplicate');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.cobranza where id in (pg_temp.uc(60), pg_temp.uc(61), pg_temp.uc(62), pg_temp.uc(63))), 4,
          'los cuatro cobros llegaron: ninguno se perdió');
select pg_temp.actuar_como(pg_temp.u('b1'));
-- Pero una corrección posterior sobre un cobro que ya está sí se juzga.
select is(pg_temp.corregir(62, 1500, now() + interval '6 minutes'), 'CB008', 'una corrección posterior con hora del futuro sigue siendo CB008');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. «Anular sin c.»: 15 días desde el cobro
-- ---------------------------------------------------------------------------
-- Sin campaña (la venta de b7 es de hace 200 días).
select pg_temp.actuar_como(pg_temp.u('b7'));
select is(pg_temp.anular_a(40, pg_temp.fecha_de(40) + interval '1 hour'), 'CB009',
          'la venta no cae en ninguna campaña y el cobro es de hace 16 días: la anulación sube tarde, CB009');
select is(pg_temp.anular_msg(40, pg_temp.fecha_de(40) + interval '1 hour'),
          'CB009: Pasaron más de 15 días desde el cobro: ya no se puede anular. Pedile a tu coordinador que lo revise.',
          'con su aviso');
select is(pg_temp.anulado(40), false, 'el cobro sigue vivo');
select is(pg_temp.anular_a(41, pg_temp.fecha_de(41) + interval '1 hour'), 'ok', 'cobrado hace 14 días: sube a tiempo');
select is(pg_temp.anular_a(42, pg_temp.fecha_de(42) + interval '1 hour'), 'ok', 'a los 15 días justos todavía vale (inclusive)');
select is(pg_temp.anular_a(43, pg_temp.fecha_de(43) + interval '1 hour'), 'CB009', 'a los 15 días y un segundo no');
-- La gracia de la campaña ya estaba vencida al cobrar (c5, terminada hace 60 días).
select pg_temp.actuar_como(pg_temp.u('b6'));
select is(pg_temp.anular_a(44, pg_temp.fecha_de(44) + interval '1 hour'), 'CB009', 'campaña vieja, cobro de hace 16 días: CB009');
select is(pg_temp.anular_a(45, pg_temp.fecha_de(45) + interval '1 hour'), 'ok', 'campaña vieja, cobro de hace 14 días: vale');
-- Ana cobra HOY una cuota de una venta de una campaña que terminó hace 16 días y a los 10 minutos la anula.
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.anular_a(47, now() - interval '50 minutes'), 'ok',
          'cobrada hoy, con la campaña ya fuera de gracia: se anula a los 10 minutos (antes daba CB009)');
-- Con la gracia abierta al cobrar, rige la de la campaña: cerró ayer y el cobro es de hace 2 días.
select is(pg_temp.anular_a(46, pg_temp.fecha_de(46) + interval '1 hour'), 'CB009',
          'la gracia de la campaña estaba abierta al cobrar y ya cerró: CB009');
select is(pg_temp.anular_msg(46, pg_temp.fecha_de(46) + interval '1 hour'),
          'CB009: La campaña de esta venta terminó hace más de 15 días: el cobro ya no se puede anular. Pedile a tu coordinador que lo revise.',
          'con el aviso de la campaña');
-- Con la campaña en curso, sigue la regla de hoy.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.anular_a(48, pg_temp.fecha_de(48) + interval '1 hour'), 'ok', 'campaña en curso: vale');
-- El coordinador y el ADMIN no tienen esa gracia: anulan con la hora del servidor dentro de las 72 h.
select pg_temp.actuar_como(pg_temp.u('d2'));
select is(pg_temp.error_de($$ select public.anular_cobro(pg_temp.uc(49), 'Otro') $$), 'ok',
          'el coordinador de la campaña anula aunque la gracia haya cerrado');
select pg_temp.actuar_como_servidor();
select is(pg_temp.anulado(49), true, 'y queda anulado');

-- ---------------------------------------------------------------------------
-- 5. Por sync_push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote as
select pg_temp.push(jsonb_build_array(
  pg_temp.job_upd('e0', 30, jsonb_build_object('monto', 1500, 'corregido_at', now() - interval '9 hours')),  -- hora 71: entra
  pg_temp.job_upd('e1', 31, jsonb_build_object('monto', 1500, 'corregido_at', now() - interval '7 hours')),  -- hora 73: CB007
  pg_temp.job_upd('e2', 3, jsonb_build_object('monto', 1600, 'corregido_at', now() + interval '7 minutes')) -- futura: CB008
)) as r;
grant select on lote to authenticated;
select is(pg_temp.resultados((select r from lote)), array['accepted', 'invalid', 'invalid'],
          'el lote: la corrección de la hora 71 entra y las otras vuelven invalid sin tumbar al resto');
select is(pg_temp.codigos((select r from lote)), array['-', 'CB007', 'CB008'], 'con su código: CB007 y CB008');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.codigos(pg_temp.push(jsonb_build_array(
            pg_temp.job_upd('e3', 32, jsonb_build_object('monto', 1500, 'corregido_at', now() - interval '47 hours'))))),
          array['CB009'], 'por el push, CB009 de la corrección fuera de la gracia');
select pg_temp.actuar_como_servidor();
select is(pg_temp.monto_de(30), 1500, 'la corrección aceptada quedó');
select is(pg_temp.monto_de(31), 1000, 'la rechazada por CB007 no cambió el monto');
select is(pg_temp.monto_de(32), 1000, 'ni la rechazada por CB009');

select * from finish();
rollback;
