-- pgTAP · migración 0167 (backend-supabase#243, casilla «Alq. baja»; decisión de Cristian del 04/11): lo pagado del alquiler
-- de una baja tiene tres destinos y se decide todo junto.
--   1. La forma: `deposito.anulado_at` / `anulado_por` (CHECK, el push no las escribe, el teléfono no las manda),
--      los tres valores de `alquiler_decision.decision`, `decidir_alquiler_pagado` sin monto.
--   2. DEVOLVER_AL_COLPORTOR: los pagos validados quedan anulados (nunca borrados) y dejan de contar: no suman a lo pagado,
--      ni a «Depositado», y el efectivo vuelve «en mano»; la deuda con la casa editora no se mueve; queda la decisión y el
--      evento de auditoría; el doble toque no hace nada; lo anulado no se edita (DP007); no se deshace al reactivar.
--   3. AQ005: devolver cuando parte de lo pagado ya se decidió antes no anula nada; los otros dos destinos siguen sirviendo.
--   4. Campaña sin alquiler, nada por decidir (solo hay un pago por validar), alquiler vigente (AQ004), un pago nuevo después.
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
  select ('01920000-0000-7000-8000-0000000167' || p)::uuid;
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
create or replace function pg_temp.dec(p_us text, p_camp text, p_decision text)
returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.decidir_alquiler_pagado(pg_temp.u(p_us), pg_temp.u(p_camp), p_decision);
  return format('%s|%s|%s|%s|%s|%s', r.decision, r.monto_decidido, r.por_decidir, r.trasladado, r.a_favor, r.ya_estaba);
end $$;
-- La fila guardada: «pagado|debe|trasladado|a_favor|por_decidir» (SECURITY DEFINER: sin RLS).
create or replace function pg_temp.fila(p_us text, p_camp text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s|%s|%s|%s', ca.alquiler_pagado, coalesce(ca.alquiler_debe::text, 'n'),
                                 ca.alquiler_trasladado, ca.alquiler_a_favor, ca.alquiler_por_decidir)
                     from public.cuenta_alquiler ca
                    where ca.usuario_id = pg_temp.u(p_us) and ca.campania_id = pg_temp.u(p_camp)), 'sin fila')
$$;
-- La cuenta de la persona: «deuda|trasladado|depositado».
create or replace function pg_temp.cuenta(p text) returns text language sql security definer as $$
  select coalesce((select format('%s|%s|%s', deuda_total, alquiler_trasladado, dinero_depositado) from public.cuenta_colportor
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
-- Cuántos pagos de alquiler de la persona están anulados y cuántos existen (nunca se borran).
create or replace function pg_temp.pagos(p text) returns text language sql security definer as $$
  select format('%s/%s', count(*) filter (where anulado_at is not null), count(*))
    from public.deposito where colportor_id = pg_temp.u(p) and concepto = 'ALQUILER'
$$;
-- La lectura del panel como ADMIN: «pagado|debe|trasladado|a_favor|por_decidir».
create or replace function pg_temp.panel(p_camp text, p_us text) returns text language plpgsql as $$
declare v text;
begin
  perform pg_temp.actuar_como(pg_temp.u('ad'));
  select format('%s|%s|%s|%s|%s', r.alquiler_pagado, coalesce(r.alquiler_debe::text, 'n'), r.alquiler_trasladado,
                r.alquiler_a_favor, r.alquiler_por_decidir)
    into v
    from public.cuentas_de_campania(pg_temp.u(p_camp)) r
   where r.colportor_id = pg_temp.u(p_us);
  perform pg_temp.actuar_como_servidor();
  return v;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- e1 (coordina c1) cobra 250000: b1, b2 y b4 se dieron de baja, b5 sigue viva; e2 (coordina c2) no cobra: b3.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'alq167-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'),
               ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 alq167', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 250000),
  (pg_temp.u('e2'), 'e2 alq167', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'), null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b5'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b3'), now() - interval '10 days');
-- Todos deben a la casa editora 500000; lo depositado es lo que sumaron los pagos de alquiler validados de cada uno.
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  (pg_temp.u('b1'), 500000, 70000), (pg_temp.u('b2'), 500000, 40000), (pg_temp.u('b3'), 500000, 10000),
  (pg_temp.u('b4'), 500000, 0),     (pg_temp.u('b5'), 500000, 250000);
-- Pagos de alquiler: b1 dos validados (40000 + 30000); b2 uno (40000); b3 uno en la campaña sin alquiler (10000);
-- b4 uno todavía por validar (5000); b5 (viva) paga lo justo (250000).
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('21'), pg_temp.u('b1'), 40000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1')),
  (pg_temp.u('22'), pg_temp.u('b1'), 30000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1')),
  (pg_temp.u('23'), pg_temp.u('b2'), 40000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1')),
  (pg_temp.u('24'), pg_temp.u('b3'), 10000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e2'), now(), pg_temp.u('c2')),
  (pg_temp.u('25'), pg_temp.u('b5'), 250000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1'));
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('26'), pg_temp.u('b4'), 5000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'));
-- Un depósito de la casa editora de b1 (nunca se anula) y una venta cobrada en efectivo por b1 (100000), para el «en mano».
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('27'), pg_temp.u('b1'), 1000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null, now(), pg_temp.u('c1'));
insert into public.producto (id, nombre, tipo) values (pg_temp.u('11'), 'Libro 1 t167', 'LIBRO');
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais alq167', 'ZV');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad alq167', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('01'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('a1'), pg_temp.u('01'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('a1'), pg_temp.u('c9'), pg_temp.u('b1'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-16771', 100000, now(), pg_temp.u('b1'), pg_temp.u('b1'));
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 1, 100000, 100000);
insert into public.cobranza (id, venta_id, monto, medio, fecha) values
  (pg_temp.u('c1'), pg_temp.u('71'), 100000, 'EFECTIVO', now());
-- b1, b2 y b4 se dan de baja de e1, con lo pagado.
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('e1') and usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b4'));

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'deposito', 'anulado_at', 'deposito.anulado_at');
select has_column('public', 'deposito', 'anulado_por', 'deposito.anulado_por');
select col_is_fk('public', 'deposito', 'anulado_por', 'anulado_por es FK');
select is((select count(*)::int from unnest(sync.columnas_escribibles('deposito')) c where c in ('anulado_at', 'anulado_por')),
          0, 'el push no escribe la anulación');
select is((select columnas_servidor @> array['anulado_at', 'anulado_por'] from sync.entidad where nombre = 'deposito'), true,
          'y son columnas del servidor');
select is((select pg_get_constraintdef(oid) from pg_constraint where conname = 'alquiler_decision_decision_check'),
          $$CHECK ((decision = ANY (ARRAY['DEVOLVER_AL_COLPORTOR'::text, 'A_CUENTA_PROXIMO_DEPOSITO'::text, 'SE_LO_QUEDA_EL_COORDINADOR'::text])))$$,
          'alquiler_decision.decision tiene los tres destinos');
select is(pg_temp.error_de($$ insert into public.alquiler_decision (usuario_id, campania_id, decision, monto)
                              values (pg_temp.u('b2'), pg_temp.u('e1'), 'TRASLADAR_A_LA_DEUDA', 1) $$), '23514', 'el nombre viejo: CHECK');
-- Solo se anula un pago de alquiler validado.
select is(pg_temp.error_de($$ update public.deposito set anulado_at = now() where id = pg_temp.u('27') $$), '23514',
          'un depósito de la casa editora no se anula (CHECK)');
select is(pg_temp.error_de($$ update public.deposito set anulado_at = now() where id = pg_temp.u('26') $$), '23514',
          'ni un pago de alquiler que todavía no se validó (CHECK)');
select is(pg_temp.error_de($$ update public.deposito set anulado_por = pg_temp.u('c1') where id = pg_temp.u('25') $$), '23514',
          'ni anulado_por sin anulado_at (CHECK)');
-- El teléfono no manda la anulación (INVOKER como authenticated, aviso que dice qué hacer).
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.mensaje_de($$ insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto, campania_id, anulado_at)
                               values (pg_temp.u('99'), pg_temp.u('b5'), 1000, now(), 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now()) $$),
          'Un pago de alquiler lo devuelve tu coordinador, no se carga desde el teléfono. Registralo sin anular.',
          'cargar un pago ya anulado desde el teléfono: 42501 con un aviso');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.deposito where id = pg_temp.u('99')), 0, 'y no dejó nada');
select is((select p.pronargs from pg_proc p where p.oid = 'public.decidir_alquiler_pagado(uuid,uuid,text)'::regprocedure), 3::smallint,
          'decidir_alquiler_pagado no recibe monto');

-- Los puntos de partida.
select is(pg_temp.fila('b1', 'e1'), '70000|0|0|0|70000', 'b1 (baja): 70000 pagados, todo por decidir');
select is(pg_temp.cuenta('b1'), '500000|0|70000', 'su cuenta: la deuda intacta y 70000 depositados');
select is(public.efectivo_en_mano(pg_temp.u('b1')), 29000::bigint, 'en mano: 100000 cobrados − 70000 − 1000 depositados = 29000');

-- ---------------------------------------------------------------------------
-- 2. Devolver al colportor
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b1', 'e1', 'DEVOLVER_AL_COLPORTOR'), 'DEVOLVER_AL_COLPORTOR|70000|0|0|0|f',
          'Luis devuelve los 70000 de b1: todo de una vez');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pagos('b1'), '2/2', 'los dos pagos quedan anulados y siguen existiendo (nunca borrados)');
select is((select count(*)::int from public.deposito where colportor_id = pg_temp.u('b1') and concepto = 'ALQUILER'
              and anulado_por = pg_temp.u('c1') and anulado_at is not null and deleted_at is null), 2, 'anulados por quien decidió, sin darlos de baja');
select is((select count(*)::int from public.deposito where id = pg_temp.u('27') and anulado_at is null), 1,
          'el depósito de la casa editora de b1 no se tocó');
select is(pg_temp.fila('b1', 'e1'), '0|0|0|0|0', 'dejan de contar: nada pagado, nada por decidir (y debe 0 por estar de baja)');
select is(pg_temp.cuenta('b1'), '500000|0|0', 'ya no suman a «Depositado» y la deuda con la casa editora no se movió');
select is(public.efectivo_en_mano(pg_temp.u('b1')), 99000::bigint, 'el efectivo vuelve a figurar en mano: 100000 − 1000 depositados');
select is(pg_temp.panel('e1', 'b1'), '0|0|0|0|0', 'el panel lee todo en cero');
select is(pg_temp.n_dec('b1', 'e1'), 1::bigint, 'queda una decisión registrada');
select is((select decision || '|' || monto || '|' || (decidido_por = pg_temp.u('c1')) from public.alquiler_decision
            where usuario_id = pg_temp.u('b1') and campania_id = pg_temp.u('e1')),
          'DEVOLVER_AL_COLPORTOR|70000|true', 'con el destino, el monto devuelto y quién decidió');
select is((select a.metadata from auditoria.audit_log a where a.event_type = 'alquiler_pagado_decidido' and a.target_user_id = pg_temp.u('b1')),
          jsonb_build_object('campania_id', pg_temp.u('e1'), 'decision', 'DEVOLVER_AL_COLPORTOR', 'monto', 70000,
                             'por_decidir_antes', 70000, 'depositos_anulados', 2),
          'y un evento con los montos y cuántos pagos se anularon, sin texto libre');
-- El doble toque no hace nada.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b1', 'e1', 'DEVOLVER_AL_COLPORTOR'), 'DEVOLVER_AL_COLPORTOR|0|0|0|0|t', 'el segundo toque: ya_estaba');
select is(pg_temp.dec('b1', 'e1', 'A_CUENTA_PROXIMO_DEPOSITO'), 'A_CUENTA_PROXIMO_DEPOSITO|0|0|0|0|t', 'ni con otra decisión');
select pg_temp.actuar_como_servidor();
select is(pg_temp.n_dec('b1', 'e1'), 1::bigint, 'una sola decisión');
select is(pg_temp.n_audit('b1'), 1::bigint, 'y un solo evento');
select is(pg_temp.cuenta('b1'), '500000|0|0', 'Depositado no se restó dos veces');

-- Lo anulado queda como historia: no se edita ni se da de baja ni se des-anula.
select is(pg_temp.error_de($$ update public.deposito set monto = 1 where id = pg_temp.u('21') $$), 'DP007', 'no se edita (DP007)');
select is(pg_temp.error_de($$ update public.deposito set deleted_at = now() where id = pg_temp.u('21') $$), 'DP007', 'ni se da de baja (DP007)');
select is(pg_temp.error_de($$ update public.deposito set anulado_at = null, anulado_por = null where id = pg_temp.u('21') $$), 'DP007',
          'ni se des-anula (DP007)');

-- Reactivar a la persona no deshace «devolver»: la plata ya volvió.
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.fila('b1', 'e1'), '0|250000|0|0|0', 'b1 reactivada: debe todo el alquiler (los pagos anulados no cuentan)');
select is(pg_temp.pagos('b1'), '2/2', 'los pagos siguen anulados');
select is(pg_temp.n_dec('b1', 'e1', true), 1::bigint, 'y la decisión de devolver sigue vigente');
select is(pg_temp.cuenta('b1'), '500000|0|0', 'la deuda tampoco cambió');
-- Si vuelve a darse de baja y paga otra vez, lo nuevo queda por decidir y se puede decidir (devolver no bloquea).
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('28'), pg_temp.u('b1'), 8000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1'));
select is(pg_temp.fila('b1', 'e1'), '8000|0|0|0|8000', 'un pago nuevo de 8000: solo lo nuevo queda por decidir');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.dec('b1', 'e1', 'SE_LO_QUEDA_EL_COORDINADOR'), 'SE_LO_QUEDA_EL_COORDINADOR|8000|0|0|8000|f',
          'se lo queda el coordinador: la devolución de antes no estorba');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pagos('b1'), '2/3', 'y el pago nuevo no se anula');

-- ---------------------------------------------------------------------------
-- 3. AQ005: devolver cuando parte de lo pagado ya se decidió
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b2', 'e1', 'A_CUENTA_PROXIMO_DEPOSITO'), 'A_CUENTA_PROXIMO_DEPOSITO|40000|0|40000|0|f', 'b2: Luis deja a cuenta los 40000');
select pg_temp.actuar_como_servidor();
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('29'), pg_temp.u('b2'), 10000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now(), pg_temp.u('c1'));
select is(pg_temp.fila('b2', 'e1'), '50000|0|40000|0|10000', 'b2 paga 10000 más: quedan por decidir');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR') $$),
          'AQ005', 'devolver ahora no se puede: AQ005');
select ok(pg_temp.mensaje_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR') $$)
          like 'Una parte de lo que pagó ya se decidió antes%Dejá lo que falta%', 'con un aviso que dice qué hacer');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pagos('b2'), '0/2', 'no anuló ningún pago');
select is(pg_temp.cuenta('b2'), '460000|40000|40000', 'ni tocó la cuenta');
select is(pg_temp.n_dec('b2', 'e1'), 1::bigint, 'ni dejó otra decisión');
select is(pg_temp.n_audit('b2'), 1::bigint, 'ni otro evento');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b2', 'e1', 'SE_LO_QUEDA_EL_COORDINADOR'), 'SE_LO_QUEDA_EL_COORDINADOR|10000|0|40000|10000|f',
          'lo que falta sí se puede dejar o quedárselo');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Otros casos
-- ---------------------------------------------------------------------------
-- Campaña sin alquiler: c2 devuelve lo de b3.
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.dec('b3', 'e2', 'DEVOLVER_AL_COLPORTOR'), 'DEVOLVER_AL_COLPORTOR|10000|0|0|0|f', 'e2 sin alquiler: c2 devuelve los 10000 de b3');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pagos('b3'), '1/1', 'el pago de b3 queda anulado');
select is(pg_temp.cuenta('b3'), '500000|0|0', 'y su Depositado vuelve a 0');
select is(pg_temp.fila('b3', 'e2'), '0|n|0|0|0', 'la fila de b3, en cero');

-- Nada validado todavía (solo un pago por validar): no hay nada que devolver y el pago pendiente no se toca.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b4', 'e1', 'DEVOLVER_AL_COLPORTOR'), 'DEVOLVER_AL_COLPORTOR|0|0|0|0|t', 'b4: sin nada validado, ya_estaba');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pagos('b4'), '0/1', 'el pago por validar queda como estaba');
select is(pg_temp.n_dec('b4', 'e1'), 0::bigint, 'sin decisión');
-- Cuando se valida, queda por decidir y se puede devolver.
update public.deposito set validado_en = now(), validado_por = pg_temp.u('c1') where id = pg_temp.u('26');
select is(pg_temp.fila('b4', 'e1'), '5000|0|0|0|5000', 'al validarse, queda por decidir');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b4', 'e1', 'DEVOLVER_AL_COLPORTOR'), 'DEVOLVER_AL_COLPORTOR|5000|0|0|0|f', 'y se devuelve');
select pg_temp.actuar_como_servidor();

-- La inscripción viva en una campaña que cobra no se decide: AQ004, también para devolver.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b5'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR') $$),
          'AQ004', 'b5 (viva, pagó lo justo): AQ004');
-- Permisos: una colportora no devuelve, y c2 no devuelve en la campaña de c1.
select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b2'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR') $$),
          '42501', 'una colportora no decide');
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.error_de($$ select * from public.decidir_alquiler_pagado(pg_temp.u('b4'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR') $$),
          'AQ001', 'el coordinador de otra campaña: AQ001');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pagos('b5'), '0/1', 'el pago de b5 sigue vivo');

select * from finish();
rollback;
