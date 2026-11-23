-- pgTAP · migración 0201 (backend-supabase#301, seguimiento de front-colportores-mobile#389, HU-CTA-007): la decisión del alquiler de
-- una baja baja al teléfono por el sync.
--   1. El registro: `alquiler_decision` es una entidad de solo bajada con la dueña en `usuario_id` (sin ubicación ni campañas), con
--      el índice del delta con la dueña primero; el teléfono no la escribe (sin privilegios, sin push).
--   2. La cuenta del teléfono: con lo que baja (los pagos de alquiler y las decisiones) el teléfono saca lo POR DECIDIR de la campaña
--      de la baja con la misma cuenta que el servidor (`cuenta_alquiler.alquiler_por_decidir`): sin decidir, a cuenta, se lo queda
--      el coordinador, un pago de después de la decisión, devolver solo lo nuevo, y la decisión deshecha por reactivar a la persona.
--   3. «Cuándo se decidió»: el corte de lo nuevo es `created_at` de la decisión (la hora real), no `decidido_en`.
-- El pull mismo (quién baja qué, el delta y la baja lógica) se prueba en `0201_..._pull_test.sql`, que no va en una transacción.
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
  select ('01920000-0000-7000-8000-0000000201' || p)::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Lo que devuelve la RPC, en una línea: «decision|decidido|por_decidir».
create or replace function pg_temp.dec(p_us text, p_camp text, p_decision text)
returns text language plpgsql as $$
declare r record;
begin
  select * into r from public.decidir_alquiler_pagado(pg_temp.u(p_us), pg_temp.u(p_camp), p_decision);
  return format('%s|%s|%s', r.decision, r.monto_decidido, r.por_decidir);
end $$;
-- Lo POR DECIDIR del servidor (SECURITY DEFINER: sin RLS).
create or replace function pg_temp.por_decidir_del_servidor(p_us text, p_camp text) returns bigint language sql security definer as $$
  select coalesce((select ca.alquiler_por_decidir from public.cuenta_alquiler ca
                    where ca.usuario_id = pg_temp.u(p_us) and ca.campania_id = pg_temp.u(p_camp)), -1)
$$;
-- LO QUE HARÍA EL TELÉFONO con las filas que bajan (`deposito` y `alquiler_decision`, tal cual las lee la persona): lo pagado y
-- validado, sin anular ni dar de baja, menos la suma de lo decidido vigente a cuenta o que se queda el coordinador (devolver no
-- resta: sus pagos ya están anulados), sin bajar de 0.
-- Solo cuenta si lo pagado lo decide el coordinador: la inscripción está dada de baja o la campaña no cobra alquiler (las dos cosas
-- bajan: `campania_colportor.deleted_at` y `campania.alquiler_monto`). Con la inscripción viva en una campaña que cobra, el sobrante
-- pasa solo a la deuda y no hay nada por decidir.
create or replace function pg_temp.por_decidir_en_el_telefono(p_us text, p_camp text) returns bigint language sql security definer as $$
  select case when not (
      exists (select 1 from public.campania_colportor i
               where i.usuario_id = pg_temp.u(p_us) and i.campania_id = pg_temp.u(p_camp) and i.deleted_at is not null)
      or exists (select 1 from public.campania c where c.id = pg_temp.u(p_camp) and c.alquiler_monto is null)) then 0::bigint
    else greatest(
    coalesce((select sum(d.monto) from public.deposito d
               where d.colportor_id = pg_temp.u(p_us) and d.campania_id = pg_temp.u(p_camp) and d.concepto = 'ALQUILER'
                 and d.validado_en is not null and d.deleted_at is null and d.anulado_at is null), 0)
    - coalesce((select sum(ad.monto) from public.alquiler_decision ad
                 where ad.usuario_id = pg_temp.u(p_us) and ad.campania_id = pg_temp.u(p_camp) and ad.deleted_at is null
                   and ad.decision in ('A_CUENTA_PROXIMO_DEPOSITO', 'SE_LO_QUEDA_EL_COORDINADOR')), 0),
    0) end
$$;
-- Los dos juntos: «servidor|teléfono».
create or replace function pg_temp.ambos(p_us text, p_camp text) returns text language sql as $$
  select pg_temp.por_decidir_del_servidor(p_us, p_camp) || '|' || pg_temp.por_decidir_en_el_telefono(p_us, p_camp)
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- e1 cobra un alquiler de 250000 y la coordina c1. b1 (Ana) pagó 50000 y 20000 y se dio de baja; b2 pagó 40000 y se dio de baja;
-- b3 pagó 9000 y sigue inscripta. ad es ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'alq201-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 alq201', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 250000);
insert into public.campania_colportor (campania_id, usuario_id, created_at)
select pg_temp.u('e1'), pg_temp.u(s), now() - interval '10 days' from unnest(array['b1','b2','b3']) s;
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado)
select pg_temp.u(s), 500000, 0 from unnest(array['b1','b2','b3']) s;
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('21'), pg_temp.u('b1'), 50000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1')),
  (pg_temp.u('22'), pg_temp.u('b1'), 20000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1')),
  (pg_temp.u('23'), pg_temp.u('b2'), 40000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1')),
  (pg_temp.u('24'), pg_temp.u('b3'), 9000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1'));
update public.campania_colportor set deleted_at = now() - interval '1 day'
 where campania_id = pg_temp.u('e1') and usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 1. El registro
-- ---------------------------------------------------------------------------
select is((select count(*)::int from sync.entidad where tabla = 'public.alquiler_decision'::regclass), 1, 'alquiler_decision está en sync.entidad');
select results_eq(
  $$ select nombre, columna_pk, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where tabla = 'public.alquiler_decision'::regclass $$,
  $$ values ('alquiler_decision'::text, 'id'::text, false, false, null::text, 'usuario_id'::text) $$,
  'solo bajada, sin ubicación ni campañas, con la dueña en usuario_id');
select has_index('public', 'alquiler_decision', 'alquiler_decision_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'el cursor del pull por dueña: (usuario_id, xmin_w, id)');
select is(has_table_privilege('authenticated', 'public.alquiler_decision', 'insert')
          or has_table_privilege('authenticated', 'public.alquiler_decision', 'update')
          or has_table_privilege('authenticated', 'public.alquiler_decision', 'delete'), false,
          'el teléfono (authenticated) sigue sin escribir una decisión');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'alquiler_decision'),
          0, 'no va a Realtime (ADR-012)');
-- Sin texto libre: ninguna columna de la fila admite texto que no sea el código de la decisión.
select is((select array_agg(a.attname::text order by a.attname) from pg_attribute a
            where a.attrelid = 'public.alquiler_decision'::regclass and a.attnum > 0 and not a.attisdropped
              and a.atttypid = 'text'::regtype),
          array['decision'], 'la única columna de texto es el código de la decisión (nada de texto libre)');

-- ---------------------------------------------------------------------------
-- 2. La cuenta que hace el teléfono da lo mismo que el servidor
-- ---------------------------------------------------------------------------
select is(pg_temp.ambos('b1', 'e1'), '70000|70000', 'Ana (baja, pagó 70000): todo por decidir, igual en el servidor y en el teléfono');
select is(pg_temp.ambos('b2', 'e1'), '40000|40000', 'b2 (baja, pagó 40000): todo por decidir');
select is(pg_temp.ambos('b3', 'e1'), '0|0', 'b3 (inscripta, pagó de menos): el alquiler vigente no se decide, nada por decidir');

-- A cuenta del próximo depósito.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b1', 'e1', 'A_CUENTA_PROXIMO_DEPOSITO'), 'A_CUENTA_PROXIMO_DEPOSITO|70000|0', 'Luis deja a cuenta los 70000 de Ana');
select pg_temp.actuar_como_servidor();
select is(pg_temp.ambos('b1', 'e1'), '0|0', 'Ana ve la decisión y nada por decidir');
select is((select count(*)::int from public.alquiler_decision where usuario_id = pg_temp.u('b1') and campania_id = pg_temp.u('e1')
              and decision = 'A_CUENTA_PROXIMO_DEPOSITO' and monto = 70000 and deleted_at is null
              and decidido_por = pg_temp.u('c1') and decidido_en is not null), 1,
          'la fila de la decisión trae el destino, el monto, quién decidió y cuándo');
select ok((select created_at >= decidido_en from public.alquiler_decision where usuario_id = pg_temp.u('b1')),
          'created_at es la hora real de la decisión: nunca antes de decidido_en (el inicio de la transacción)');

-- Un pago de después de la decisión (validado con la hora real): vuelve a quedar por decidir solo lo nuevo.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('25'), pg_temp.u('b1'), 10000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), clock_timestamp(), pg_temp.u('c1'));
select is(pg_temp.ambos('b1', 'e1'), '10000|10000', 'Ana paga 10000 más: «lo nuevo vuelve a por decidir», igual en los dos lados');
select is((select d.validado_en > (select max(ad.created_at) from public.alquiler_decision ad
                                    where ad.usuario_id = d.colportor_id and ad.campania_id = d.campania_id and ad.deleted_at is null)
             from public.deposito d where d.id = pg_temp.u('25')),
          true, 'y el pago nuevo es posterior al created_at de la última decisión');

-- Devolver solo lo nuevo: los 70000 siguen a cuenta, los 10000 se anulan.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.dec('b1', 'e1', 'DEVOLVER_AL_COLPORTOR'), 'DEVOLVER_AL_COLPORTOR|10000|0', 'Luis le devuelve los 10000 nuevos');
select pg_temp.actuar_como_servidor();
select is(pg_temp.ambos('b1', 'e1'), '0|0', 'nada por decidir: el pago devuelto está anulado y la decisión de devolver no resta');
select is((select count(*)::int from public.deposito where colportor_id = pg_temp.u('b1') and anulado_at is not null), 1,
          'el pago devuelto baja con anulado_at, no se borra');
select is((select string_agg(decision, ',' order by created_at) from public.alquiler_decision
            where usuario_id = pg_temp.u('b1') and deleted_at is null),
          'A_CUENTA_PROXIMO_DEPOSITO,DEVOLVER_AL_COLPORTOR', 'las dos decisiones de Ana, en orden');

-- Se lo queda el coordinador.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.dec('b2', 'e1', 'SE_LO_QUEDA_EL_COORDINADOR'), 'SE_LO_QUEDA_EL_COORDINADOR|40000|0', 'el administrador se lo queda por b2');
select pg_temp.actuar_como_servidor();
select is(pg_temp.ambos('b2', 'e1'), '0|0', 'b2: nada por decidir, igual en los dos lados');

-- Reactivar a la persona deshace «a cuenta» y «se lo queda» (se dan de baja) y no «devolver».
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select is((select count(*)::int from public.alquiler_decision where usuario_id = pg_temp.u('b2') and deleted_at is not null), 1,
          'b2 vuelve a la campaña: su decisión queda dada de baja (baja lógica, para que el teléfono la saque)');
select is(pg_temp.ambos('b2', 'e1'), '0|0', 'y ya no hay nada que decidir (el alquiler vuelve a ser vigente)');
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b2');
select is(pg_temp.ambos('b2', 'e1'), '40000|40000', 'si vuelve a darse de baja, lo pagado queda por decidir otra vez y las decisiones dadas de baja no cuentan');

select * from finish();
rollback;
