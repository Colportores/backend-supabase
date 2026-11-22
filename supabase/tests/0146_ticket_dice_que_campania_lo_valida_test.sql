-- pgTAP · migración 0146 (backend-supabase#209, seguimiento de #200, «Ticket libre»): el ticket que baja al teléfono
-- dice quién lo valida (`ticket.campania_validadora_id`, nulo = Administración).
--   1. La forma: columna, FK, índice, triggers, funciones internas sin EXECUTE, y la columna es del servidor.
--   2. Al nacer: un ticket con campaña, uno sin campaña y uno de depósito por su fecha.
--   3. Un cobro que lo apunta: gana la campaña de la venta (con campaña, sin campaña); se da de baja y vuelve a la
--      fecha del ticket; la venta cambia de fecha.
--   4. Cambian las inscripciones: un tramo afuera, una baja con fecha anterior al ticket, la reactivación, un alta
--      nueva; el fin de la campaña (la gracia de 15 días) y su baja.
--   5. Solo se toca lo que cambia y sin subir sync_version (solo xmin_w); un ticket resuelto o dado de baja no se
--      recalcula.
--   6. El teléfono no la escribe (API directa, push) y nadie ve más ni menos tickets que antes.
--   8. El lote [ticket, cobro] y la foto con la versión que devolvió el push: entra, no da conflict.
-- El pull (que la clave baja y que el delta la lleva) está en 0146_ticket_validadora_pull_test.sql. Va en una
-- transacción.
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
-- Ids con dos caracteres hex al final.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000146' || p)::uuid;
$$;
create or replace function pg_temp.uc(p_n integer) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000146' || lpad(to_hex(p_n), 4, '0'))::uuid;
$$;
-- La campaña que valida un ticket, como el sufijo de su id (o '-' si es Administración).
create or replace function pg_temp.quien(p_ticket text) returns text language sql as $$
  select coalesce(right(t.campania_validadora_id::text, 2), '-') from public.ticket t where t.id = pg_temp.u(p_ticket);
$$;
create or replace function pg_temp.version(p_ticket text) returns bigint language sql as $$
  select t.sync_version from public.ticket t where t.id = pg_temp.u(p_ticket);
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000146d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.resultado(p_r jsonb) returns text language sql as $$
  select (p_r -> 'results' -> 0) ->> 'outcome';
$$;
-- Un cobro cargado por el servidor.
create or replace function pg_temp.cb(p_n integer, p_venta text, p_fecha timestamptz, p_ticket text) returns void language sql as $$
  insert into public.cobranza (id, venta_id, monto, medio, fecha, ticket_id, created_by)
  values (pg_temp.uc(p_n), pg_temp.u(p_venta), 1000, 'TARJETA', p_fecha, pg_temp.u(p_ticket),
          (select v.colportor_id from public.venta v where v.id = pg_temp.u(p_venta)));
$$;
-- Un ticket cargado por el servidor (nace PENDIENTE).
create or replace function pg_temp.tk(p_id text, p_usuario text, p_tipo text, p_fecha timestamptz) returns void language sql as $$
  insert into public.ticket (id, usuario_id, tipo, monto, fecha)
  values (pg_temp.u(p_id), pg_temp.u(p_usuario), p_tipo, 1000, p_fecha);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Campañas: c1 (d1) y c2 (d2) en curso; c3 (d1) terminó hace 20 días (su gracia vence en 5).
-- Colportoras: b1 en c1 (alta hace 10 días); b2 sin campaña; b3 en c3 (alta hace 50 días); b4 sin campaña. a1 ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'quien146-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','b6','b7','d1','d2','a1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('d1', 'COORDINADOR'), ('d2', 'COORDINADOR'), ('a1', 'ADMIN'),
               ('b1', 'COLPORTOR'), ('b2', 'COLPORTOR'), ('b3', 'COLPORTOR'), ('b4', 'COLPORTOR'),
               ('b5', 'COLPORTOR'), ('b6', 'COLPORTOR'), ('b7', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('c1'), 'c1 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d1')),
  (pg_temp.u('c2'), 'c2 en curso', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('d2')),
  (pg_temp.u('c3'), 'c3 hace 20 dias', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 20, pg_temp.u('d1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('c1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('c3'), pg_temp.u('b3'), now() - interval '50 days');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais quien146', 'ZY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad quien146', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values (pg_temp.u('f2'), 'CASA', 'Quien 146', '1', -34.91, -56.2, pg_temp.u('f1'), pg_temp.u('b1'));
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values (pg_temp.u('f3'), pg_temp.u('f2'), null, pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values (pg_temp.u('f4'), pg_temp.u('f3'), pg_temp.u('f5'), pg_temp.u('b1'));
-- Ventas de b1: v1 de hace un día (cae en c1) y v2 de hace 100 días (de ninguna campaña).
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
select pg_temp.u(x.v), pg_temp.u('f4'), 'T-146-' || x.v, 1000000, now() - x.hace, pg_temp.u(x.quien), pg_temp.u(x.quien)
  from (values ('71', interval '1 day', 'b1'), ('72', interval '100 days', 'b1')) x(v, hace, quien);

-- =================================================================================
-- 1. La forma
-- =================================================================================
select has_column('public', 'ticket', 'campania_validadora_id', 'ticket.campania_validadora_id existe');
select col_type_is('public', 'ticket', 'campania_validadora_id', 'uuid', 'es un uuid');
select col_is_null('public', 'ticket', 'campania_validadora_id', 'y puede ser nulo (Administración)');
select col_is_fk('public', 'ticket', 'campania_validadora_id', 'apunta a una campaña');
select fk_ok('public', 'ticket', 'campania_validadora_id', 'public', 'campania', 'id', 'la campaña de verdad');
select has_index('public', 'ticket', 'ticket_campania_validadora_idx', array['campania_validadora_id'], 'con su índice');
select has_trigger('public', 'ticket', 'ticket_quien_lo_valida', 'el ticket nuevo la recibe del servidor');
select has_trigger('public', 'cobranza', 'cobranza_avisa_al_ticket', 'un cobro avisa al ticket');
select has_trigger('public', 'venta', 'venta_avisa_al_ticket', 'una venta avisa al ticket de sus cobros');
select has_trigger('public', 'campania_colportor', 'campania_colportor_avisa_al_ticket', 'una inscripción avisa a los tickets de la colportora');
select has_trigger('public', 'campania', 'campania_avisa_al_ticket', 'una campaña avisa a los tickets de sus inscriptas');
select is((select columnas_servidor @> array['campania_validadora_id'] from sync.entidad where nombre = 'ticket'), true,
          'el push la descarta (columnas_servidor)');
select ok(sync.expresion_json('public.ticket'::regclass) like '%''campania_validadora_id'', t.campania_validadora_id%',
          'y el pull y el server_row la llevan con el resto de la fila');
-- Las funciones nuevas son internas: nadie las ejecuta (las llaman los triggers, que corren igual).
select is((select count(*)::int
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('recalcular_quien_valida_tickets', 'tg_ticket_quien_lo_valida', 'tg_cobranza_avisa_al_ticket',
                                'tg_venta_avisa_al_ticket', 'tg_inscripcion_avisa_al_ticket', 'tg_campania_avisa_al_ticket')
              and (has_function_privilege('authenticated', p.oid, 'execute')
                   or has_function_privilege('anon', p.oid, 'execute')
                   or has_function_privilege('service_role', p.oid, 'execute'))), 0,
          'ninguna de las funciones nuevas la ejecuta authenticated, anon ni service_role');
select is((select count(*)::int
             from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public'
              and p.proname in ('recalcular_quien_valida_tickets', 'tg_ticket_quien_lo_valida', 'tg_cobranza_avisa_al_ticket',
                                'tg_venta_avisa_al_ticket', 'tg_inscripcion_avisa_al_ticket', 'tg_campania_avisa_al_ticket')
              and p.prosecdef), 6, 'las seis son SECURITY DEFINER (leen cobros, ventas e inscripciones que la dueña no ve)');
select is(has_function_privilege('authenticated', 'public.campania_que_valida_el_ticket(uuid, uuid, timestamptz)', 'execute'),
          false, 'campania_que_valida_el_ticket sigue sin abrirse como RPC (no averigua la campaña de un ticket ajeno)');

-- =================================================================================
-- 2. Al nacer
-- =================================================================================
-- b1 está en c1 desde hace 10 días: un ticket de ayer (de depósito o de tarjeta sin cobro) cae en c1; uno de hace 100
-- días, en ninguna. b2 no tiene campaña.
select pg_temp.tk('e1', 'b1', 'DEPOSITO', now() - interval '1 day');
select pg_temp.tk('e2', 'b1', 'DEPOSITO', now() - interval '100 days');
select pg_temp.tk('e3', 'b1', 'COBRO_TARJETA', now());
select pg_temp.tk('e7', 'b2', 'DEPOSITO', now() - interval '1 day');
select is(pg_temp.quien('e1'), 'c1', 'un ticket de depósito cae en la campaña de su fecha');
select is(pg_temp.quien('e2'), '-', 'uno cuya fecha no cae en ninguna inscripción lo valida Administración (nulo)');
select is(pg_temp.quien('e3'), 'c1', 'un ticket de tarjeta sin cobro todavía, también por su fecha');
select is(pg_temp.quien('e7'), '-', 'y el de una colportora sin campaña, Administración');
-- Venga lo que venga en la fila, el valor es el del servidor.
select pg_temp.tk('e0', 'b1', 'DEPOSITO', now() - interval '1 day');
insert into public.ticket (id, usuario_id, tipo, monto, fecha, campania_validadora_id)
values (pg_temp.u('e8'), pg_temp.u('b1'), 'DEPOSITO', 1000, now() - interval '1 day', pg_temp.u('c2'));
select is(pg_temp.quien('e8'), 'c1', 'si la fila nueva trae otra campaña, el servidor la pisa');

-- =================================================================================
-- 3. Un cobro lo apunta
-- =================================================================================
-- e3 se cobra en la venta v2 (hace 100 días, de ninguna campaña): el ticket de la cuota no cae en ninguna campaña,
-- aunque su fecha sí (decisión «Ticket libre»).
select pg_temp.cb(1, '72', now() - interval '1 hour', 'e3');
select is(pg_temp.quien('e3'), '-', 'el cobro de una venta de ninguna campaña lo deja a Administración, aunque la fecha del ticket caiga en c1');
-- El cobro se da de baja: vuelve a valer la fecha del ticket.
update public.cobranza set deleted_at = now() where id = pg_temp.uc(1);
select is(pg_temp.quien('e3'), 'c1', 'dado de baja el cobro, vuelve a la campaña de la fecha del ticket');
update public.cobranza set deleted_at = null where id = pg_temp.uc(1);
select is(pg_temp.quien('e3'), '-', 'reactivado el cobro, otra vez Administración');
-- Un cobro que cambia de venta: a v1 (de ayer, cae en c1).
update public.cobranza set venta_id = pg_temp.u('71') where id = pg_temp.uc(1);
select is(pg_temp.quien('e3'), 'c1', 'si el cobro pasa a una venta de c1, valida c1');
-- Un cobro que suelta el ticket.
update public.cobranza set ticket_id = null, medio = 'EFECTIVO' where id = pg_temp.uc(1);
select is(pg_temp.quien('e3'), 'c1', 'sin cobro, por la fecha del ticket');

-- Un ticket con campaña por la venta: e4 en un cobro de la venta v1 (c1).
select pg_temp.tk('e4', 'b1', 'COBRO_TARJETA', now());
select pg_temp.cb(2, '71', now() - interval '1 hour', 'e4');
select is(pg_temp.quien('e4'), 'c1', 'un ticket cuyo cobro es de una venta de c1 lo valida c1');
-- La venta cambia de fecha: ahora cae en ninguna campaña.
update public.venta set fecha = now() - interval '100 days' where id = pg_temp.u('71');
select is(pg_temp.quien('e4'), '-', 'si la venta del cobro cambia a una fecha de ninguna campaña, Administración');
update public.venta set fecha = now() - interval '1 day' where id = pg_temp.u('71');
select is(pg_temp.quien('e4'), 'c1', 'y de vuelta en c1 cuando la fecha vuelve');
-- Un cobro anulado (no dado de baja) sigue contando: anular no lo cambia de campaña.
update public.cobranza set anulado_at = now(), motivo_anulacion = 'Otro' where id = pg_temp.uc(2);
select is(pg_temp.quien('e4'), 'c1', 'un cobro anulado sigue fijando la campaña del ticket');

-- =================================================================================
-- 4. Cambian las inscripciones
-- =================================================================================
-- e1 (depósito de ayer) vale c1 por la ventana de la inscripción de b1.
-- Un tramo afuera que cubre ayer: ese día b1 no estaba en la campaña.
update public.campania_colportor
   set tramos_afuera = array[tstzrange(now() - interval '2 days', now() - interval '12 hours')]
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1'), '-', 'un hueco en la inscripción que cubre la fecha del ticket: Administración');
select is(pg_temp.quien('e0'), '-', 'y también el otro ticket de ayer');
select is(pg_temp.quien('e3'), 'c1', 'el de hoy no se mueve');
update public.campania_colportor set tramos_afuera = '{}'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1'), 'c1', 'cerrado el hueco, vuelve a c1');
-- Una baja anterior al ticket.
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1'), '-', 'baja de la inscripción antes de la fecha del ticket: Administración');
select is(pg_temp.quien('e3'), '-', 'y el de hoy');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
-- Reactivar deja el hueco [baja, vuelta) en tramos_afuera (0100): el ticket de ayer queda adentro del hueco, el de hoy no.
select is(pg_temp.quien('e1') || pg_temp.quien('e3'), '-c1',
          'reactivada la inscripción, el hueco deja afuera al ticket de ayer y el de hoy vuelve a c1');
update public.campania_colportor set tramos_afuera = '{}'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1') || pg_temp.quien('e3'), 'c1c1', 'sin el hueco, los dos están en c1');
-- Una baja posterior al ticket no lo cambia (el ticket de ayer sigue dentro de la ventana).
update public.campania_colportor set deleted_at = now()
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1'), 'c1', 'una baja de hoy no saca el ticket de ayer de la campaña');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
-- Un alta nueva: b2 se inscribe en c2 hace 5 días, y su ticket de ayer cae ahí.
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('c2'), pg_temp.u('b2'), now() - interval '5 days');
select is(pg_temp.quien('e7'), 'c2', 'el alta de la colportora en c2 hace que su ticket de ayer lo valide c2');
-- La inscripción pasa a otra campaña.
update public.campania_colportor set campania_id = pg_temp.u('c1')
 where campania_id = pg_temp.u('c2') and usuario_id = pg_temp.u('b2');
select is(pg_temp.quien('e7'), 'c1', 'si la inscripción cambia de campaña, el ticket la sigue');

-- El fin de la campaña: la gracia de 15 días.
select pg_temp.tk('e5', 'b3', 'DEPOSITO', now() - interval '10 days');
select is(pg_temp.quien('e5'), 'c3', 'un ticket de hace 10 días, con la campaña que terminó hace 20 (gracia hasta hace 5): c3');
update public.campania set fecha_fin = public.hoy_montevideo() - 40 where id = pg_temp.u('c3');
select is(pg_temp.quien('e5'), '-', 'si la campaña terminó antes, la gracia ya venció para ese ticket: Administración');
update public.campania set fecha_fin = public.hoy_montevideo() - 20 where id = pg_temp.u('c3');
select is(pg_temp.quien('e5'), 'c3', 'y de vuelta en c3 cuando el fin vuelve');
update public.campania set deleted_at = now() where id = pg_temp.u('c3');
select is(pg_temp.quien('e5'), '-', 'una campaña dada de baja ya no valida');
update public.campania set deleted_at = null where id = pg_temp.u('c3');
select is(pg_temp.quien('e5'), 'c3', 'repuesta, vuelve');

-- =================================================================================
-- 5. Solo se toca lo que cambia
-- =================================================================================
create temp table versiones as
select t.id, t.sync_version, t.xmin_w::text as xmin_w from public.ticket t;
-- Una baja de b1 dentro de una hora (no saca a ninguno de sus tickets de la ventana) y la reactivación (no deja hueco:
-- la baja es posterior a la vuelta).
update public.campania_colportor set deleted_at = now() + interval '1 hour'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
-- Un update de la inscripción que no cambia nada.
update public.campania_colportor set tramos_afuera = tramos_afuera
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
-- Una venta que no cambia de fecha ni de colportora.
update public.venta set monto_total = monto_total + 1 where id = pg_temp.u('71');
update public.campania set nombre = 'c1 en curso (editada)' where id = pg_temp.u('c1');
select is((select count(*)::int from public.ticket t join versiones v using (id)
            where t.usuario_id = pg_temp.u('b1') and (t.sync_version <> v.sync_version or t.xmin_w::text <> v.xmin_w)), 0,
          'si la respuesta no cambia, la fila del ticket no se toca (el delta vacío lo prueba 0146_ticket_validadora_pull_test)');
-- Y cuando sí cambia, la versión de sync NO sube: avanza solo xmin_w (republicado de 0011), para que el delta lo lleve
-- sin que el update del teléfono con la versión que le devolvió el push dé conflict.
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1'), '-', 'una baja anterior al ticket de ayer lo deja a Administración');
select is(pg_temp.version('e1'), (select sync_version from versiones where id = pg_temp.u('e1')),
          'cuando cambia de verdad, la versión de sync del ticket no sube (solo xmin_w: el teléfono lo baja por delta)');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
update public.campania_colportor set tramos_afuera = '{}'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e1'), 'c1', 'reactivada y sin hueco, de vuelta');

-- Un ticket VALIDADO o RECHAZADO conserva la campaña que lo resolvió; recalcular no tropieza con TK001.
select pg_temp.tk('e6', 'b1', 'DEPOSITO', now() - interval '1 day');
update public.ticket set estado = 'VALIDADO', revisado_por = pg_temp.u('d1'), revisado_en = now() where id = pg_temp.u('e6');
select pg_temp.tk('e9', 'b1', 'DEPOSITO', now() - interval '1 day');
update public.ticket set estado = 'RECHAZADO', revisado_por = pg_temp.u('d1'), revisado_en = now(), motivo_rechazo = 'No se lee'
 where id = pg_temp.u('e9');
-- Y uno dado de baja.
select pg_temp.tk('ea', 'b1', 'DEPOSITO', now() - interval '1 day');
update public.ticket set deleted_at = now() where id = pg_temp.u('ea');
select is(pg_temp.quien('e6') || pg_temp.quien('e9') || pg_temp.quien('ea'), 'c1c1c1', 'resuelto o dado de baja, queda con c1');
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
select is(pg_temp.quien('e6') || pg_temp.quien('e9') || pg_temp.quien('ea'), 'c1c1c1',
          'una baja de la inscripción no cambia a los tickets resueltos ni al dado de baja (y no falla con TK001)');
select is(pg_temp.quien('e1') || pg_temp.quien('e0'), '--', 'mientras los que siguen por validar sí cambian');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');
update public.campania_colportor set tramos_afuera = '{}'
 where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b1');

-- =================================================================================
-- 6. El teléfono no la escribe y nadie ve de más
-- =================================================================================
select pg_temp.actuar_como(pg_temp.u('b1'));
-- API directa: un valor distinto en un ticket propio por validar es 42501.
select is(pg_temp.error_de(format('update public.ticket set campania_validadora_id = %L where id = %L',
                                  pg_temp.u('c2'), pg_temp.u('e1'))), '42501',
          'por la API directa, b1 no cambia la campaña que valida su ticket');
select is(pg_temp.error_de(format('update public.ticket set campania_validadora_id = null where id = %L', pg_temp.u('e1'))), '42501',
          'ni la deja en nulo');
select is(pg_temp.quien('e1'), 'c1', 'y el ticket queda como estaba');
-- Un ticket nuevo por la API directa: el servidor decide.
insert into public.ticket (id, usuario_id, tipo, monto, fecha, campania_validadora_id)
values (pg_temp.u('eb'), pg_temp.u('b1'), 'DEPOSITO', 1000, now() - interval '1 day', pg_temp.u('c2'));
select is(pg_temp.quien('eb'), 'c1', 'un ticket nuevo de b1 por la API directa nace con la del servidor, no con la que mandó');
-- Por el push: la clave del payload se descarta (insert y update).
select is(pg_temp.resultado(pg_temp.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', pg_temp.u('d1'), 'entity', 'ticket', 'op', 'insert',
            'payload', jsonb_build_object('id', pg_temp.u('ec'), 'tipo', 'DEPOSITO', 'monto', 1000, 'fecha', now() - interval '1 day',
                                          'campania_validadora_id', pg_temp.u('c2')))))),
          'accepted', 'el push de un ticket nuevo con la clave de más se acepta');
select is(pg_temp.quien('ec'), 'c1', 'y la clave del payload se descarta');
select is(pg_temp.resultado(pg_temp.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', pg_temp.u('d2'), 'entity', 'ticket', 'op', 'update', 'sync_version', pg_temp.version('ec'),
            'payload', jsonb_build_object('id', pg_temp.u('ec'), 'url_cloud', pg_temp.u('b1')::text || '/' || pg_temp.u('ec')::text || '.jpg',
                                          'campania_validadora_id', null))))),
          'accepted', 'el update de la foto, con la clave del servidor en el payload, se acepta');
select is(pg_temp.quien('ec'), 'c1', 'y no la cambia');

-- Quién ve qué, igual que antes: b1 sus tickets; d1 (c1) los de c1; d2 (c2) ninguno; ADMIN todos.
select is((select count(*)::int from public.ticket where usuario_id = pg_temp.u('b1')), 11, 'b1 ve sus tickets');
select is((select count(*)::int from public.ticket where usuario_id = pg_temp.u('b2')), 0, 'y no los de b2');
select pg_temp.actuar_como(pg_temp.u('d1'));
select is((select string_agg(right(id::text, 2), ',' order by id) from public.ticket where usuario_id = pg_temp.u('b1')
            and campania_validadora_id is not distinct from pg_temp.u('c1')),
          'e0,e1,e3,e4,e6,e8,e9,ea,eb,ec', 'la coordinadora de c1 ve los tickets de c1 (la columna no abre nada)');
select is((select count(*)::int from public.ticket where campania_validadora_id is null), 0,
          'y no ve los que valida Administración');
select pg_temp.actuar_como(pg_temp.u('d2'));
select is((select count(*)::int from public.ticket), 0, 'la coordinadora de c2 no ve ninguno de c1');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select string_agg(right(id::text, 2), ',' order by id) from public.ticket where campania_validadora_id is null), 'e2',
          'el ADMIN ve el que valida Administración (e2) y todos los demás');
select is((select count(*)::int from public.ticket where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'))), 13,
          'el ADMIN ve todos los tickets');

-- =================================================================================
-- 7. Más movimientos (como el servidor)
-- =================================================================================
select pg_temp.actuar_como_servidor();
-- Un cobro que se borra suelta el ticket: vuelve a la fecha.
select pg_temp.tk('f6', 'b1', 'COBRO_TARJETA', now());
select pg_temp.tk('f7', 'b1', 'COBRO_TARJETA', now());
select pg_temp.cb(3, '72', now(), 'f6');
select is(pg_temp.quien('f6'), '-', 'f6 tiene un cobro de una venta de ninguna campaña: Administración');
delete from public.cobranza where id = pg_temp.uc(3);
select is(pg_temp.quien('f6'), 'c1', 'borrado el cobro, vuelve a la campaña de su fecha');
-- Un cobro que cambia de ticket: el que suelta y el que toma se recalculan.
select pg_temp.cb(4, '72', now(), 'f6');
update public.cobranza set ticket_id = pg_temp.u('f7') where id = pg_temp.uc(4);
select is(pg_temp.quien('f6') || pg_temp.quien('f7'), 'c1-', 'el cobro pasa de f6 a f7: f6 vuelve a la fecha y f7 sigue a la venta');
update public.cobranza set ticket_id = null, medio = 'EFECTIVO' where id = pg_temp.uc(4);
select is(pg_temp.quien('f7'), 'c1', 'y al soltarlo, f7 también');
-- La venta de un cobro cambia de colportora.
update public.venta set colportor_id = pg_temp.u('b4') where id = pg_temp.u('71');
select is(pg_temp.quien('e4'), '-', 'si la venta del cobro pasa a una colportora sin campaña, Administración');
update public.venta set colportor_id = pg_temp.u('b1') where id = pg_temp.u('71');
select is(pg_temp.quien('e4'), 'c1', 'y de vuelta');
-- Una inscripción que se borra.
delete from public.campania_colportor where campania_id = pg_temp.u('c1') and usuario_id = pg_temp.u('b2');
select is(pg_temp.quien('e7'), '-', 'borrada la inscripción de b2, su ticket vuelve a Administración');
-- Una inscripción que pasa de una colportora a otra: se recalculan las dos.
select pg_temp.tk('f9', 'b5', 'DEPOSITO', now() - interval '1 day');
select pg_temp.tk('fa', 'b6', 'DEPOSITO', now() - interval '1 day');
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('c2'), pg_temp.u('b5'), now() - interval '5 days');
select is(pg_temp.quien('f9') || pg_temp.quien('fa'), 'c2-', 'b5 entra a c2: su ticket de ayer es de c2');
update public.campania_colportor set usuario_id = pg_temp.u('b6')
 where campania_id = pg_temp.u('c2') and usuario_id = pg_temp.u('b5');
select is(pg_temp.quien('f9') || pg_temp.quien('fa'), '-c2', 'la inscripción pasa a b6: el de b5 vuelve a Administración y el de b6 es de c2');
-- Una campaña dada de baja afecta también a quien ya se dio de baja de ella.
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('c3'), pg_temp.u('b7'), now() - interval '50 days');
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = pg_temp.u('c3') and usuario_id = pg_temp.u('b7');
select pg_temp.tk('fb', 'b7', 'DEPOSITO', now() - interval '10 days');
select is(pg_temp.quien('fb'), 'c3', 'un ticket de hace 10 días, de una colportora dada de baja de c3 hace 2: c3');
update public.campania set deleted_at = now() where id = pg_temp.u('c3');
select is(pg_temp.quien('fb'), '-', 'dada de baja c3, la colportora que ya se había ido de ella también queda con Administración');

-- =================================================================================
-- 8. El caso «Ticket libre» en un solo lote: ticket + cobro + foto
-- =================================================================================
-- Ana (b1, inscripta en c1) cobra con tarjeta una cuota de una venta de hace 100 días (de ninguna campaña). El
-- teléfono sube en el mismo lote el ticket (de hoy: nace con c1) y el cobro que lo apunta (lo pasa a Administración).
-- El push le devuelve al ticket su versión; la foto que sube después, con esa versión, tiene que entrar: el recálculo
-- que hizo el cobro no puede haber subido sync_version.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote as
select pg_temp.push(jsonb_build_array(
         jsonb_build_object('client_op_id', pg_temp.u('d3'), 'entity', 'ticket', 'op', 'insert',
           'payload', jsonb_build_object('id', pg_temp.u('ed'), 'tipo', 'COBRO_TARJETA', 'monto', 1000, 'fecha', now(),
                                         'numero_autorizacion', '0001', 'tarjeta_tipo', 'DEBITO')),
         jsonb_build_object('client_op_id', pg_temp.u('d4'), 'entity', 'cobranza', 'op', 'insert',
           'payload', jsonb_build_object('id', pg_temp.uc(20), 'venta_id', pg_temp.u('72'), 'monto', 1000, 'medio', 'TARJETA',
                                         'fecha', now(), 'numero_cuota', 1, 'ticket_id', pg_temp.u('ed'),
                                         'tarjeta_tipo', 'DEBITO')))) as r;
select pg_temp.actuar_como_servidor();
select is((select array[(r -> 'results' -> 0) ->> 'outcome', (r -> 'results' -> 1) ->> 'outcome'] from lote),
          array['accepted', 'accepted'], 'el lote [ticket, cobro de una venta de ninguna campaña] se acepta entero');
select is(pg_temp.quien('ed'), '-', 'y el ticket queda para Administración, aunque su fecha caiga en c1');
select is(pg_temp.version('ed'), (select ((r -> 'results' -> 0) ->> 'sync_version')::bigint from lote),
          'la versión del ticket en el servidor es la que le devolvió el push: el recálculo no la subió');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.resultado(pg_temp.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', pg_temp.u('d5'), 'entity', 'ticket', 'op', 'update',
            'sync_version', (select ((r -> 'results' -> 0) ->> 'sync_version')::bigint from lote),
            'payload', jsonb_build_object('id', pg_temp.u('ed'),
                                          'url_cloud', pg_temp.u('b1')::text || '/' || pg_temp.u('ed')::text || '.jpg'))))),
          'accepted', 'la foto, con la versión que devolvió el push, entra (no da conflict)');
select pg_temp.actuar_como_servidor();
select is((select url_cloud from public.ticket where id = pg_temp.u('ed')), pg_temp.u('b1')::text || '/' || pg_temp.u('ed')::text || '.jpg',
          'y el ticket tiene la ruta de la foto');
select is(pg_temp.quien('ed'), '-', 'sin perder lo que dice quién lo valida');

select * from finish();
rollback;
