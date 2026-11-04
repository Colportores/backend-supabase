-- pgTAP · migración 0159 (backend-supabase#234, casilla «Baja y alq.», decisión de Cristian del 03/11):
--   1. La forma: alquiler_decision, las columnas nuevas de cuenta_alquiler, privilegios y RLS.
--   2. Lo pagado por quien está de baja, o en una campaña sin alquiler, queda POR DECIDIR y no mueve la deuda; el
--      sobrante de una inscripción viva sigue pasando solo a la deuda («Alquiler fav»).
--   3. decidir_alquiler_pagado(): permisos, errores, decidir por monto y acumulando, trasladar baja la deuda, dejar a favor
--      no la toca, el reintento sin monto no hace nada, auditoría, concurrencia de dos decisiones seguidas.
--   4. Reactivar a la persona deshace lo decidido (R7) y darla de baja otra vez decide de nuevo; la vista previa de validar.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000159' || p)::uuid;
$$;
-- «sqlstate» o «ok» de lo que hace una sentencia (en subtransacción).
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
  return sqlerrm;
end $$;
-- Lo que devuelve la RPC, en una línea: «decision|decidido|por_decidir|trasladado|a_favor|ya_estaba».
create or replace function pg_temp.dec(p_us text, p_camp text, p_decision text, p_monto bigint default null)
returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.decidir_alquiler_pagado(pg_temp.u(p_us), pg_temp.u(p_camp), p_decision, p_monto);
  return format('%s|%s|%s|%s|%s|%s', r.decision, r.monto_decidido, r.por_decidir, r.trasladado, r.a_favor, r.ya_estaba);
end $$;
-- La fila guardada: «pagado|debe|trasladado|a_favor|por_decidir» (SECURITY DEFINER: sin RLS).
create or replace function pg_temp.fila(p_us text, p_camp text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s|%s|%s|%s', ca.alquiler_pagado, coalesce(ca.alquiler_debe::text, 'n'),
                                 ca.alquiler_trasladado, ca.alquiler_a_favor, ca.alquiler_por_decidir)
                     from public.cuenta_alquiler ca
                    where ca.usuario_id = pg_temp.u(p_us) and ca.campania_id = pg_temp.u(p_camp)), 'sin fila')
$$;
-- La deuda con la casa editora y lo trasladado en todas las campañas: «deuda|trasladado».
create or replace function pg_temp.deuda(p text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s', deuda_total, alquiler_trasladado) from public.cuenta_colportor
                    where usuario_id = pg_temp.u(p) and deleted_at is null), '-')
$$;
create or replace function pg_temp.n_dec(p_us text, p_camp text, p_solo_vivas boolean default false) returns bigint
language sql security definer as $$
  select count(*) from public.alquiler_decision
   where usuario_id = pg_temp.u(p_us) and campania_id = pg_temp.u(p_camp) and (not p_solo_vivas or deleted_at is null)
$$;
create or replace function pg_temp.n_audit(p_us text) returns bigint language sql security definer as $$
  select count(*) from auditoria.audit_log
   where event_type = 'alquiler_pagado_decidido' and target_user_id = pg_temp.u(p_us)
$$;
create or replace function pg_temp.pt(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validacion_de_ticket(pg_temp.u(p));
  return format('%s|%s|%s|%s', r.monto, r.supera_deuda, r.a_favor_despues, r.a_la_casa_editora);
end $$;
create or replace function pg_temp.pr(p text) returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.validacion_de_retiro(pg_temp.u(p));
  return format('%s|%s|%s|%s', r.monto, r.supera_deuda, r.a_favor_despues, r.a_la_casa_editora);
end $$;
-- La lectura del panel como ADMIN: «debe|trasladado|a_favor|por_decidir».
create or replace function pg_temp.panel(p_camp text, p_us text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.actuar_como(pg_temp.u('ad'));
  select format('%s|%s|%s|%s', coalesce(r.alquiler_debe::text, 'n'), r.alquiler_trasladado, r.alquiler_a_favor,
                r.alquiler_por_decidir)
    into v
    from public.cuentas_de_campania(pg_temp.u(p_camp)) r
   where r.colportor_id = pg_temp.u(p_us);
  perform pg_temp.actuar_como_servidor();
  return v;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- e1 (coordina c1) cobra un alquiler de 250000: b1 viva (pagó 300000), b2 que se dio de baja (pagó 40000), b4 viva sin
-- pagar; e2 (coordina c2) no cobra alquiler: b3 pagó 10000. ad es ADMIN. c1 también es colportor de e1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'alq159-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('c1','COORDINADOR'),
               ('c2','COORDINADOR'), ('ad','ADMIN'), ('c1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 alq159', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 250000),
  (pg_temp.u('e2'), 'e2 alq159', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'), null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('c1'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b3'), now() - interval '10 days');
-- Todos deben a la casa editora 500000.
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado)
select pg_temp.u(s), 500000, 0 from unnest(array['b1','b2','b3','b4','c1']) s;
-- Depósitos de alquiler ya validados: b1 300000 (50000 de más), b2 40000, b3 10000 (e2 no cobra), c1 5000.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('21'), pg_temp.u('b1'), 300000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1')),
  (pg_temp.u('22'), pg_temp.u('b2'), 40000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1')),
  (pg_temp.u('23'), pg_temp.u('b3'), 10000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e2'), now(), pg_temp.u('c2')),
  (pg_temp.u('24'), pg_temp.u('c1'), 5000,   now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('ad'));
-- b2 se da de baja, con lo pagado.
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_table('public', 'alquiler_decision', 'existe alquiler_decision');
select has_column('public', 'cuenta_alquiler', 'alquiler_a_favor', 'cuenta_alquiler.alquiler_a_favor');
select has_column('public', 'cuenta_alquiler', 'alquiler_por_decidir', 'cuenta_alquiler.alquiler_por_decidir');
select col_is_fk('public', 'alquiler_decision', 'usuario_id', 'usuario_id es FK');
select col_is_fk('public', 'alquiler_decision', 'campania_id', 'campania_id es FK');
select col_is_fk('public', 'alquiler_decision', 'decidido_por', 'decidido_por es FK');
select has_index('public', 'alquiler_decision', 'alquiler_decision_decidido_por_idx', 'índice sobre decidido_por');
select is((select relrowsecurity from pg_class where oid = 'public.alquiler_decision'::regclass), true, 'con RLS');
select is(has_table_privilege('authenticated', 'public.alquiler_decision', 'insert')
          or has_table_privilege('authenticated', 'public.alquiler_decision', 'update')
          or has_table_privilege('authenticated', 'public.alquiler_decision', 'delete'), false,
          'authenticated no escribe las decisiones directo');
select is(has_table_privilege('anon', 'public.alquiler_decision', 'select'), false, 'anon no las lee');
select is((select count(*)::int from sync.entidad where tabla = 'public.alquiler_decision'::regclass), 0, 'no es entidad del push');
select is(pg_temp.error_de($$ insert into public.alquiler_decision (usuario_id, campania_id, decision, monto)
                              values (pg_temp.u('b2'), pg_temp.u('e1'), 'OTRA', 1) $$), '23514', 'una decisión desconocida: CHECK');
select is(pg_temp.error_de($$ insert into public.alquiler_decision (usuario_id, campania_id, decision, monto)
                              values (pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR', 0) $$), '23514', 'monto 0: CHECK');
select is(pg_temp.error_de($$ insert into public.cuenta_alquiler (usuario_id, campania_id, alquiler_por_decidir)
                              values (pg_temp.u('b4'), pg_temp.u('e2'), -1) $$), '23514', 'por decidir negativo: CHECK');
select is((select has_function_privilege(r, 'public.decidir_alquiler_pagado(uuid,uuid,text,bigint)', 'execute')),
          r = 'authenticated', format('decidir_alquiler_pagado: %s', r))
  from unnest(array['anon', 'authenticated', 'service_role']) r;
select is((select p.prosecdef and p.provolatile = 'v' from pg_proc p
            where p.oid = 'public.decidir_alquiler_pagado(uuid,uuid,text,bigint)'::regprocedure),
          true, 'es SECURITY DEFINER y VOLATILE');

-- ---------------------------------------------------------------------------
-- 2. Qué queda por decidir y qué sigue pasando solo
-- ---------------------------------------------------------------------------
select is(pg_temp.fila('b1', 'e1'), '300000|0|50000|0|0', 'b1 (viva): el sobrante de 50000 pasa solo a la deuda («Alquiler fav»), nada por decidir');
select is(pg_temp.deuda('b1'), '450000|50000', 'y la deuda baja 50000');
select is(pg_temp.fila('b2', 'e1'), '40000|0|0|0|40000', 'b2 (de baja): debe 0, no se traslada nada y los 40000 quedan por decidir');
select is(pg_temp.deuda('b2'), '500000|0', 'la deuda de b2 no se movió');
select is(pg_temp.fila('b3', 'e2'), '10000|n|0|0|10000', 'b3 (campaña sin alquiler): no debe y los 10000 quedan por decidir');
select is(pg_temp.deuda('b3'), '500000|0', 'la deuda de b3 tampoco');
select is(pg_temp.fila('b4', 'e1'), '0|250000|0|0|0', 'b4 (viva, sin pagar): debe 250000');
select is(pg_temp.panel('e1', 'b2'), '0|0|0|40000', 'el panel lee por decidir: debe 0, trasladado 0, a favor 0, por decidir 40000');
select is(pg_temp.panel('e2', 'b3'), 'n|0|0|10000', 'el de la campaña sin alquiler, igual');
select is(pg_temp.panel('e1', 'b1'), '0|50000|0|0', 'y el sobrante de b1 figura trasladado');

-- La vista previa de validar no mueve nada para una baja.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado) values
  (pg_temp.u('12'), pg_temp.u('b4'), 'DEPOSITO', 300000, now(), 'PENDIENTE');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('25'), pg_temp.u('b2'), 5000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1')),
  (pg_temp.u('26'), pg_temp.u('b4'), 300000, now(), pg_temp.u('12'), 'BANCO', 'ALQUILER', pg_temp.u('e1'));
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.pr('25'), '5000|5000|0|0', 'la vista previa de un retiro de una baja: supera 5000 (queda por decidir) y a la casa editora 0');
select is(pg_temp.pt('12'), '300000|50000|0|50000', 'la de una viva que paga de más: 50000 pasan solos a la casa editora, como antes');
select pg_temp.actuar_como_servidor();
delete from public.deposito where id in (pg_temp.u('25'), pg_temp.u('26'));
delete from public.ticket where id = pg_temp.u('12');
select is(pg_temp.fila('b2', 'e1'), '40000|0|0|0|40000', 'lo pendiente no cuenta');

-- ---------------------------------------------------------------------------
-- 3. decidir_alquiler_pagado
-- ---------------------------------------------------------------------------
-- Permisos.
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR') $$),
          '42501', 'anon: sin permiso');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR') $$),
          '42501', 'una colportora no decide');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR') $$),
          'AQ001', 'el coordinador de otra campaña: AQ001 (no revela si existe)');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b3'), pg_temp.u('e2'), 'DEJAR_A_FAVOR', 1) $$),
          'ok', 'pero sí el de la suya (e2)');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b3'), pg_temp.u('e2'), 'DEJAR_A_FAVOR') $$),
          'AQ001', 'c1 no decide en la campaña de c2');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('99'), 'DEJAR_A_FAVOR') $$),
          'AQ001', 'una campaña que no existe: AQ001');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('99'), pg_temp.u('e1'), 'DEJAR_A_FAVOR') $$),
          'AQ001', 'una persona que no está en la campaña: AQ001');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('c1'), pg_temp.u('e1'), 'DEJAR_A_FAVOR') $$),
          '42501', 'c1 no decide lo de su propio alquiler');
-- Errores de datos.
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'REGALARLO') $$),
          'AQ002', 'una decisión desconocida: AQ002');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), null) $$),
          'AQ002', 'sin decisión: AQ002');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR', 0) $$),
          'AQ003', 'monto 0: AQ003');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR', -5) $$),
          'AQ003', 'monto negativo: AQ003');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR', 40001) $$),
          'AQ003', 'más de lo que queda: AQ003');
select ok(pg_temp.mensaje_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR', 40001) $$)
          like 'El monto tiene que ser mayor que cero%', 'con un aviso que dice qué hacer');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b1'), pg_temp.u('e1'), 'TRASLADAR_A_LA_DEUDA') $$),
          'AQ004', 'la inscripción viva en una campaña que cobra no se decide: AQ004');
select is(pg_temp.n_dec('b2', 'e1'), 0::bigint, 'ningún error dejó una decisión');
select is(pg_temp.n_audit('b2'), 0::bigint, 'ni un evento');

-- Trasladar una parte baja la deuda.
select is(pg_temp.dec('b2', 'e1', 'TRASLADAR_A_LA_DEUDA', 15000), 'TRASLADAR_A_LA_DEUDA|15000|25000|15000|0|f',
          'c1 traslada 15000 de los 40000 de b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.deuda('b2'), '485000|15000', 'la deuda de b2 baja 15000 y se lee trasladado');
select is(pg_temp.fila('b2', 'e1'), '40000|0|15000|0|25000', 'la fila guardada queda al día: quedan 25000 por decidir');
select is(pg_temp.n_audit('b2'), 1::bigint, 'queda un evento en audit_log');
select is((select a.metadata from auditoria.audit_log a where a.event_type = 'alquiler_pagado_decidido' and a.target_user_id = pg_temp.u('b2')),
          jsonb_build_object('campania_id', pg_temp.u('e1'), 'decision', 'TRASLADAR_A_LA_DEUDA', 'monto', 15000,
                             'por_decidir_antes', 40000),
          'con la campaña, la decisión y los montos, sin texto libre');
select is((select a.actor_user_id from auditoria.audit_log a where a.event_type = 'alquiler_pagado_decidido' and a.target_user_id = pg_temp.u('b2')),
          pg_temp.u('c1'), 'el actor es el coordinador');
select is((select a.tabla || '/' || (a.fila_id = (select ca.id from public.cuenta_alquiler ca
                                                   where ca.usuario_id = pg_temp.u('b2') and ca.campania_id = pg_temp.u('e1')))
             from auditoria.audit_log a where a.event_type = 'alquiler_pagado_decidido' and a.target_user_id = pg_temp.u('b2')),
          'cuenta_alquiler/true', 'sobre la cuenta de alquiler de la persona');
select is((select decidido_por from public.alquiler_decision where usuario_id = pg_temp.u('b2')), pg_temp.u('c1'),
          'y el registro dice quién decidió');

-- Dejar a favor otra parte no toca la deuda.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b2', 'e1', 'DEJAR_A_FAVOR', 10000), 'DEJAR_A_FAVOR|10000|15000|15000|10000|f', 'deja 10000 a favor');
select pg_temp.actuar_como_servidor();
select is(pg_temp.deuda('b2'), '485000|15000', 'la deuda no se movió');
select is(pg_temp.fila('b2', 'e1'), '40000|0|15000|10000|15000', 'quedan 15000 por decidir');
select is(pg_temp.panel('e1', 'b2'), '0|15000|10000|15000', 'el panel lee las tres cifras');

-- Sin monto: todo lo que queda. Un ADMIN también puede.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.dec('b2', 'e1', 'DEJAR_A_FAVOR'), 'DEJAR_A_FAVOR|15000|0|15000|25000|f', 'el ADMIN decide el resto: todo a favor');
-- El reintento (un doble toque): no hace nada.
select is(pg_temp.dec('b2', 'e1', 'DEJAR_A_FAVOR'), 'DEJAR_A_FAVOR|0|0|15000|25000|t', 'el segundo toque no cambia nada: ya_estaba');
select is(pg_temp.dec('b2', 'e1', 'TRASLADAR_A_LA_DEUDA'), 'TRASLADAR_A_LA_DEUDA|0|0|15000|25000|t',
          'ni con la otra decisión: ya no queda nada por decidir');
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEJAR_A_FAVOR', 1) $$),
          'AQ003', 'con un monto explícito, ya no hay de dónde: AQ003');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n_dec('b2', 'e1'), 3::bigint, 'tres decisiones registradas, no cinco');
select is(pg_temp.n_audit('b2'), 3::bigint, 'y tres eventos');
select is(pg_temp.deuda('b2'), '485000|15000', 'la deuda sigue en 485000');
select is(pg_temp.fila('b2', 'e1'), '40000|0|15000|25000|0', 'todo decidido: 15000 a la deuda y 25000 a favor');

-- Campaña sin alquiler: se traslada todo lo pagado.
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.dec('b3', 'e2', 'TRASLADAR_A_LA_DEUDA'), 'TRASLADAR_A_LA_DEUDA|9999|0|9999|1|f',
          'c2 traslada lo que queda de lo de b3 (9999: 1 ya se dejó a favor arriba)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.deuda('b3'), '490001|9999', 'la deuda de b3 baja 9999');

-- Una persona ve lo que se decidió con su plata y la ajena no.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.alquiler_decision), 3, 'b2 lee sus tres decisiones');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is((select count(*)::int from public.alquiler_decision), 0, 'b4 no lee las de otros');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is((select count(*)::int from public.alquiler_decision), 2, 'c2 lee las de su campaña');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.alquiler_decision), 3, 'c1 las de la suya');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Reactivar y volver a dar de baja
-- ---------------------------------------------------------------------------
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select is(pg_temp.fila('b2', 'e1'), '40000|210000|0|0|0', 'reactivada: vuelve a deber 210000, nada trasladado ni a favor ni por decidir');
select is(pg_temp.deuda('b2'), '500000|0', 'la deuda vuelve a la de antes: lo trasladado se devuelve (R7)');
select is(pg_temp.n_dec('b2', 'e1', true), 0::bigint, 'las decisiones de antes se dieron de baja');
select is(pg_temp.n_dec('b2', 'e1'), 3::bigint, 'pero siguen en el registro');
select is(pg_temp.n_audit('b2'), 3::bigint, 'y en audit_log');
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select is(pg_temp.fila('b2', 'e1'), '40000|0|0|0|40000', 'si vuelve a darse de baja, lo pagado queda por decidir otra vez, desde cero');
select is(pg_temp.deuda('b2'), '500000|0', 'sin mover la deuda');

-- Una campaña que pasa a cobrar alquiler: lo que b3 pagó cubre el alquiler y lo decidido deja de valer.
update public.campania set alquiler_monto = 8000 where id = pg_temp.u('e2');
select is(pg_temp.fila('b3', 'e2'), '10000|0|2000|0|0', 'e2 pasa a cobrar 8000: b3 pagó 10000, sobran 2000 que pasan solos a la deuda');
select is(pg_temp.deuda('b3'), '498000|2000', 'y los 9999 de la decisión anterior se devuelven');
select is(pg_temp.n_dec('b3', 'e2', true), 0::bigint, 'la decisión de b3 se dio de baja');

-- Un depósito validado no se edita ni se da de baja (DP001): lo pagado nunca baja, así que lo decidido no puede pasarse.
select is(pg_temp.error_de($$ update public.deposito set deleted_at = now() where id = pg_temp.u('23') $$), 'DP001',
          'un depósito validado no se da de baja (DP001)');

select * from finish();
rollback;
