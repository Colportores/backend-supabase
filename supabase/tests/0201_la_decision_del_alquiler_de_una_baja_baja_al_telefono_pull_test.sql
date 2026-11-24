-- pgTAP · migración 0201 (backend-supabase#301, seguimiento de front-colportores-mobile#389, HU-CTA-007), el pull: la decisión del
-- alquiler de una baja baja al teléfono.
--   1. Cada persona baja SOLO sus decisiones: Ana, la otra colportora, un coordinador que también es colportora y el
--      administrador (que la RLS deja leer todas) bajan cada uno las suyas.
--   2. Con las decisiones bajan, ya desde antes, lo que el teléfono necesita para la línea de «Mi alquiler» de la campaña de la
--      baja: la inscripción dada de baja (`deleted_at`), la campaña y los pagos de alquiler (el anulado con `anulado_at`).
--   3. La fila trae lo que el teléfono usa (destino, monto, quién y cuándo) y nada de la maquinaria del delta.
--   4. El delta: una decisión nueva baja sola, la deshecha (baja lógica) baja como baja, y lo de otra persona no se cuela.
-- Como 0145, NO va en una transacción (el delta solo sirve lo commiteado). Inserta las decisiones directo, como el servidor (no
-- pasa por decidir_alquiler_pagado(), que deja eventos en audit_log, que solo se agrega). Limpia al empezar y al final.
-- La equivalencia de lo por decidir con el servidor se prueba en `0201_..._test.sql`.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

-- Ids con el prefijo 201: usuarios 201b1.., campañas 201e1.., pagos 20121.., decisiones 201d1..
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000201' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
declare v uuid[] := array[pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('ad')];
begin
  delete from public.alquiler_decision where usuario_id = any (v);
  delete from public.deposito where colportor_id = any (v);
  delete from public.cuenta_alquiler where usuario_id = any (v);
  delete from public.cuenta_colportor where usuario_id = any (v);
  delete from public.campania_colportor where usuario_id = any (v);
  delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.usuario_rol where usuario_id = any (v);
  delete from auth.users where id = any (v);
end $$;

create or replace function pg_temp.pull_de(p text, p_entidades text[], p_marca jsonb default '{}'::jsonb) returns jsonb
language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(p_entidades, p_marca, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;

-- Las filas de una entidad.
create or replace function pg_temp.filas(p_delta jsonb, p_entidad text) returns setof jsonb language sql as $$
  select e from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e
$$;

-- Las decisiones que bajaron: «sufijo:DESTINO/monto[/baja],…» ordenadas por sufijo del id.
create or replace function pg_temp.decisiones(p_delta jsonb) returns text language sql as $$
  select coalesce(string_agg(right(e ->> 'id', 2) || ':' || (e ->> 'decision') || '/' || (e ->> 'monto')
                             || case when e ->> 'deleted_at' is null then '' else '/baja' end, ',' order by e ->> 'id'), '-')
    from pg_temp.filas(p_delta, 'alquiler_decision') e
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). Ana (b1) se dio de baja de e1 (la coordina c1) después de pagar 70000 y 10000; c1 decidió a cuenta
-- de los 70000. b2 también se dio de baja y c1 se lo quedó. c1 además es colportor de e2 (la coordina c2), donde c2 le decidió
-- algo a él. ad es ADMIN.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'alq201p-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('c1','COLPORTOR'), ('c2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  (pg_temp.u('e1'), 'e1 alq201', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 250000),
  (pg_temp.u('e2'), 'e2 alq201', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'), null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('c1'), now() - interval '10 days');
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado)
select pg_temp.u(s), 500000, 0 from unnest(array['b1','b2','c1']) s;
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  (pg_temp.u('21'), pg_temp.u('b1'), 70000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1')),
  (pg_temp.u('22'), pg_temp.u('b1'), 10000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1')),
  (pg_temp.u('23'), pg_temp.u('b2'), 40000, now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e1'), now() - interval '2 days', pg_temp.u('c1')),
  (pg_temp.u('24'), pg_temp.u('c1'), 5000,  now(), null, 'RETIRO_COORDINADOR', 'ALQUILER', pg_temp.u('e2'), now() - interval '2 days', pg_temp.u('c2'));
update public.campania_colportor set deleted_at = now() - interval '1 day'
 where campania_id = pg_temp.u('e1') and usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'));
-- Los pagos de la baja: el de 10000 se devolvió (anulado, no se borra).
update public.deposito set anulado_at = now(), anulado_por = pg_temp.u('c1') where id = pg_temp.u('22');
insert into public.alquiler_decision (id, usuario_id, campania_id, decision, monto, decidido_por, created_at) values
  (pg_temp.u('d1'), pg_temp.u('b1'), pg_temp.u('e1'), 'A_CUENTA_PROXIMO_DEPOSITO', 70000, pg_temp.u('c1'), now()),
  (pg_temp.u('d2'), pg_temp.u('b1'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR', 10000, pg_temp.u('c1'), now()),
  (pg_temp.u('d3'), pg_temp.u('b2'), pg_temp.u('e1'), 'SE_LO_QUEDA_EL_COORDINADOR', 40000, pg_temp.u('c1'), now()),
  (pg_temp.u('d4'), pg_temp.u('c1'), pg_temp.u('e2'), 'DEVOLVER_AL_COLPORTOR', 5000, pg_temp.u('c2'), now());

-- ---------------------------------------------------------------------------
-- 1. Cada persona baja las suyas
-- ---------------------------------------------------------------------------
create temp table pa as select pg_temp.pull_de('b1', array['alquiler_decision', 'campania_colportor', 'campania', 'deposito']) as d;
select is(pg_temp.decisiones((select d from pa)), 'd1:A_CUENTA_PROXIMO_DEPOSITO/70000,d2:DEVOLVER_AL_COLPORTOR/10000',
          'Ana baja sus dos decisiones: a cuenta los 70000 y devolver los 10000');
select ok((select bool_and((e ->> 'usuario_id') = pg_temp.u('b1')::text) from pg_temp.filas((select d from pa), 'alquiler_decision') e),
          'y son todas suyas (la RLS también le deja leerlas a un coordinador y al administrador, pero acá no bajan)');

create temp table pb as select pg_temp.pull_de('b2', array['alquiler_decision']) as d;
select is(pg_temp.decisiones((select d from pb)), 'd3:SE_LO_QUEDA_EL_COORDINADOR/40000', 'la otra colportora baja la suya, no las de Ana');

create temp table pc as select pg_temp.pull_de('c1', array['alquiler_decision']) as d;
select is(pg_temp.decisiones((select d from pc)), 'd4:DEVOLVER_AL_COLPORTOR/5000',
          'el coordinador que también es colportora baja la que le tomó c2, no las de las personas que él coordina');

create temp table pd as select pg_temp.pull_de('ad', array['alquiler_decision']) as d;
select is(pg_temp.decisiones((select d from pd)), '-', 'el administrador, que no tiene decisiones propias, no baja ninguna');
select is((select (d -> 'rows') ? 'alquiler_decision' from pd), false, 'y la entidad queda ausente de rows (sin cambios)');

-- ---------------------------------------------------------------------------
-- 2. Lo que el teléfono necesita para la campaña de la baja ya baja
-- ---------------------------------------------------------------------------
select is((select count(*)::int from pg_temp.filas((select d from pa), 'campania_colportor') e
            where e ->> 'campania_id' = pg_temp.u('e1')::text and e ->> 'deleted_at' is not null), 1,
          'la inscripción de Ana en e1 baja con deleted_at (la dada de baja baja igual)');
select is((select count(*)::int from pg_temp.filas((select d from pa), 'campania') e where e ->> 'id' = pg_temp.u('e1')::text), 1,
          'baja la campaña de la baja, con el nombre y el alquiler');
select is((select (e ->> 'alquiler_monto')::bigint from pg_temp.filas((select d from pa), 'campania') e where e ->> 'id' = pg_temp.u('e1')::text),
          250000::bigint, 'incluido el alquiler_monto');
select is((select string_agg(right(e ->> 'id', 2) || '/' || (e ->> 'monto') || case when e ->> 'anulado_at' is null then '' else '/anulado' end,
                             ',' order by e ->> 'id')
             from pg_temp.filas((select d from pa), 'deposito') e where e ->> 'concepto' = 'ALQUILER' and e ->> 'validado_en' is not null),
          '21/70000,22/10000/anulado', 'bajan sus pagos de alquiler validados, el devuelto con anulado_at (sin borrarse)');

-- ---------------------------------------------------------------------------
-- 3. La fila
-- ---------------------------------------------------------------------------
select ok((select bool_and(e ?& array['id', 'usuario_id', 'campania_id', 'decision', 'monto', 'decidido_por', 'decidido_en',
                                      'created_at', 'updated_at', 'deleted_at'])
             from pg_temp.filas((select d from pa), 'alquiler_decision') e),
          'la fila trae id, usuario_id, campania_id, decision, monto, decidido_por, decidido_en, created_at, updated_at y deleted_at');
select ok((select bool_and(not (e ? 'xmin_w')) from pg_temp.filas((select d from pa), 'alquiler_decision') e),
          'y no trae la maquinaria del delta (xmin_w)');
select is((select e ->> 'decidido_por' from pg_temp.filas((select d from pa), 'alquiler_decision') e where e ->> 'id' = pg_temp.u('d1')::text),
          pg_temp.u('c1')::text, 'dice quién decidió (el id, no un nombre)');
select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(e) k
             from pg_temp.filas((select d from pa), 'alquiler_decision') e) s
            where k in ('observaciones', 'motivo', 'nota', 'comentario', 'texto', 'detalle')),
          null, 'ninguna clave de texto libre');

-- ---------------------------------------------------------------------------
-- 4. El delta
-- ---------------------------------------------------------------------------
create temp table m1 as select d -> 'watermark' as w from pa;
create temp table dsin as select pg_temp.pull_de('b1', array['alquiler_decision'], (select w from m1)) as d;
select is(pg_temp.decisiones((select d from dsin)), '-', 'sin cambios, el delta no trae nada');

-- Una decisión nueva de Ana, y una de otra persona (no se cuela).
insert into public.alquiler_decision (id, usuario_id, campania_id, decision, monto, decidido_por, created_at) values
  (pg_temp.u('d5'), pg_temp.u('b1'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR', 3000, pg_temp.u('c1'), now()),
  (pg_temp.u('d6'), pg_temp.u('b2'), pg_temp.u('e1'), 'DEVOLVER_AL_COLPORTOR', 1000, pg_temp.u('c1'), now());
create temp table d1 as select pg_temp.pull_de('b1', array['alquiler_decision'], (select w from m1)) as d;
select is(pg_temp.decisiones((select d from d1)), 'd5:DEVOLVER_AL_COLPORTOR/3000', 'una decisión nueva baja sola, y la de b2 no se cuela');

-- Se deshace «a cuenta» (la persona volvió a la campaña): baja como baja.
create temp table m2 as select d -> 'watermark' as w from d1;
update public.alquiler_decision set deleted_at = now() where id = pg_temp.u('d1');
create temp table d2 as select pg_temp.pull_de('b1', array['alquiler_decision'], (select w from m2)) as d;
select is(pg_temp.decisiones((select d from d2)), 'd1:A_CUENTA_PROXIMO_DEPOSITO/70000/baja',
          'la decisión deshecha baja con deleted_at, y el teléfono la saca de lo que muestra');

-- Un teléfono nuevo, desde cero: las vivas y la dada de baja (la historia).
create temp table d3 as select pg_temp.pull_de('b1', array['alquiler_decision']) as d;
select is(pg_temp.decisiones((select d from d3)),
          'd1:A_CUENTA_PROXIMO_DEPOSITO/70000/baja,d2:DEVOLVER_AL_COLPORTOR/10000,d5:DEVOLVER_AL_COLPORTOR/3000',
          'desde cero bajan las tres de Ana, con la deshecha marcada como baja');

select pg_temp.limpiar();
select * from finish();
