-- pgTAP · migración 0154 (backend-supabase#231, seguimiento de front-colportores-mobile#173): el depósito baja al
-- teléfono con su validación o rechazo.
--   · el registro: `deposito` es push + pull con el dueño en `colportor_id` (sin ubicación ni campañas), el índice del
--     delta con el dueño primero, sin Realtime; las columnas del estado son del servidor (el push las descarta);
--   · el pull: la colportora baja SOLO sus depósitos (otra colportora no ve los suyos; la coordinadora, que la RLS deja
--     leer los de sus colportoras, y el ADMIN no bajan los ajenos); un depósito validado y uno rechazado bajan con su
--     estado (validado_en/validado_por; rechazado_en/rechazado_por/motivo_rechazo), y uno por validar con todo nulo;
--   · el delta: sin cambios no baja nada; cuando el servidor valida o rechaza baja el estado nuevo solo a su dueña; un
--     depósito nuevo baja; una baja lógica baja como tombstone;
--   · el teléfono no se valida ni se rechaza solo: el push de un update se rechaza y no cambia el estado del servidor.
--
-- Como 0004, 0108_devolucion_pull y 0145, NO va en una transacción: el delta solo sirve lo commiteado.
-- Limpia al empezar y al final.

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

-- Ids con el prefijo 154: usuarios 154b1.., depósitos 15451.., campaña 154e1.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000154' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.deposito where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
  delete from public.cuenta_colportor where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
  delete from public.campania_colportor where campania_id = pg_temp.u('e1');
  delete from public.campania where id = pg_temp.u('e1');
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
end $$;

-- Los sufijos de los ids de los depósitos que bajaron, ordenados; con «x» si vienen dados de baja.
create or replace function pg_temp.filas(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || case when e ->> 'deleted_at' is not null then 'x' else '' end
                            order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'deposito', '[]'::jsonb)) e;
$$;

-- «sufijo=estado» de cada depósito que bajó: validado, rechazado o por validar.
create or replace function pg_temp.estados(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || '=' ||
                            case when e ->> 'validado_en' is not null then 'validado'
                                 when e ->> 'rechazado_en' is not null then 'rechazado'
                                 else 'por validar' end
                            order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'deposito', '[]'::jsonb)) e;
$$;

-- La fila bajada del depósito con ese sufijo.
create or replace function pg_temp.fila(p_delta jsonb, p_sufijo text) returns jsonb
language sql as $$
  select e from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'deposito', '[]'::jsonb)) e
   where right(e ->> 'id', 2) = p_sufijo;
$$;

-- ---------------------------------------------------------------------------
-- 1. El registro, el índice, Realtime y qué escribe el teléfono
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where nombre = 'deposito' $$,
  $$ values ('deposito'::text, 'deposito'::text, 'id'::text, true, false, null::text, 'colportor_id'::text) $$,
  'la entidad de sync: deposito, push + pull, con el dueño en colportor_id y sin filtro por campaña ni ubicación');
select has_index('public', 'deposito', 'deposito_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'el índice del delta, con el dueño primero');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'deposito'),
          0, 'deposito no va a Realtime (ADR-012: solo catálogo y autorizaciones)');
select ok((select columnas_servidor @> array['colportor_id', 'validado_en', 'validado_por',
                                             'rechazado_en', 'rechazado_por', 'motivo_rechazo']
             from sync.entidad where nombre = 'deposito'),
          'la dueña y el estado (validación y rechazo) son columnas del servidor: el push las descarta');
select ok(not (sync.columnas_escribibles('deposito') && array['validado_en', 'validado_por', 'rechazado_en',
                                                              'rechazado_por', 'motivo_rechazo']),
          'y el teléfono no puede escribir ninguna de ellas');
select matches((select obj_description('public.deposito'::regclass, 'pg_class')), 'baja al teléfono',
               'la tabla lo dice en su comentario');

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). c1 coordina la campaña e1, donde están inscriptas b1 (Lucía) y b2; ad es ADMIN.
-- Depósitos (retiros por el coordinador, sin ticket): b1 tiene uno validado (51), uno rechazado (52) y uno por
-- validar (53); b2 tiene uno por validar (54); c1 tiene uno propio (55).
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dep154-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 dep154', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id,
                             validado_en, validado_por, rechazado_en, rechazado_por, motivo_rechazo) values
  (pg_temp.u('51'), pg_temp.u('b1'), 40000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   now(), pg_temp.u('c1'), null, null, null),
  (pg_temp.u('52'), pg_temp.u('b1'), 15000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   null, null, now(), pg_temp.u('c1'), 'El monto no coincide con lo que entregaste'),
  (pg_temp.u('53'), pg_temp.u('b1'), 20000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   null, null, null, null, null),
  (pg_temp.u('54'), pg_temp.u('b2'), 30000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   null, null, null, null, null),
  (pg_temp.u('55'), pg_temp.u('c1'), 5000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null,
   null, null, null, null, null);

-- ---------------------------------------------------------------------------
-- 2. Primer pull: cada una baja solo sus depósitos
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['deposito'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['51','52','53'],
          'Lucía (b1) baja sus tres depósitos y nada de b2 ni de la coordinadora') from p1;
select is(pg_temp.estados(d), array['51=validado','52=rechazado','53=por validar'],
          'el validado, el rechazado y el que está por validar bajan con su estado') from p1;
select is((select (pg_temp.fila(d, '51') ->> 'validado_por')::uuid from p1), pg_temp.u('c1'),
          'el validado dice quién lo validó') from p1;
select is((select pg_temp.fila(d, '52') ->> 'motivo_rechazo' from p1),
          'El monto no coincide con lo que entregaste', 'el rechazado baja con su motivo (Lucía lo ve en su teléfono)') from p1;
select ok((select pg_temp.fila(d, '52') ->> 'rechazado_en' is not null
                  and (pg_temp.fila(d, '52') ->> 'rechazado_por')::uuid = pg_temp.u('c1')
                  and pg_temp.fila(d, '52') ->> 'validado_en' is null
             from p1), 'con la fecha y quién lo rechazó, y sin validación') from p1;
select ok((select pg_temp.fila(d, '53') ->> 'validado_en' is null and pg_temp.fila(d, '53') ->> 'rechazado_en' is null
                  and pg_temp.fila(d, '53') ->> 'motivo_rechazo' is null
             from p1), 'el que está por validar baja con el estado vacío') from p1;
select is((select (pg_temp.fila(d, '51') ->> 'monto')::int from p1), 40000, 'y el monto') from p1;
select ok((select bool_and((e ->> 'colportor_id') = pg_temp.u('b1')::text)
             from p1, jsonb_array_elements(d -> 'rows' -> 'deposito') e), 'todos suyos') from p1;
select ok((select bool_and(e ? 'sync_version' and e ? 'updated_at' and e ? 'deleted_at' and not (e ? 'xmin_w'))
             from p1, jsonb_array_elements(d -> 'rows' -> 'deposito') e),
          'la fila lleva la versión y la baja lógica, y no la maquinaria del delta') from p1;
select is((select d ->> 'has_more' from p1), 'false', 'sin más páginas') from p1;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['deposito'], '{}'::jsonb, 1000) as d;
select is(pg_temp.estados(d), array['54=por validar'], 'b2 baja solo el suyo, y no ve los de Lucía') from q1;

-- La coordinadora: la RLS le deja leer los depósitos de b1 y b2 (el panel), pero su teléfono baja el propio y nada más.
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.deposito
            where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'))), 5,
          'la coordinadora lee por RLS los depósitos de sus colportoras (para el panel)');
create temp table c1 as select sync.pull(array['deposito'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['55'], 'pero en su teléfono baja solo el suyo') from c1;

select pg_temp.actuar_como(pg_temp.u('ad'));
create temp table m1 as select sync.pull(array['deposito'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array[]::text[], 'el ADMIN, que lee todo por RLS, no baja el de nadie') from m1;

-- Sin cambios, el pull siguiente no trae nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['deposito'], d -> 'watermark', 1000) -> 'rows' from p1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. El delta: cuando el servidor valida o rechaza, el estado nuevo baja
-- ---------------------------------------------------------------------------
-- El coordinador confirma el retiro 53 y rechaza uno nuevo (56).
select pg_temp.como_servidor();
update public.deposito set validado_en = now(), validado_por = pg_temp.u('c1') where id = pg_temp.u('53');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  (pg_temp.u('56'), pg_temp.u('b1'), 7000, now(), null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null);

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['deposito'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.estados(d), array['53=validado','56=por validar'],
          'el servidor validó el 53 y llegó un 56 nuevo: bajan solo esos dos, con el estado nuevo') from p2;
select ok((select (pg_temp.fila(d, '53') ->> 'sync_version')::int > 0 from p2), 'el validado, con su versión subida') from p2;

select pg_temp.como_servidor();
update public.deposito
   set rechazado_en = now(), rechazado_por = pg_temp.u('c1'), motivo_rechazo = 'No lo recibí'
 where id = pg_temp.u('56');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select sync.pull(array['deposito'], (select d -> 'watermark' from p2), 1000) as d;
select is(pg_temp.estados(d), array['56=rechazado'], 'rechazar el 56 baja solo ese, ya rechazado') from p3;
select is((select pg_temp.fila(d, '56') ->> 'motivo_rechazo' from p3), 'No lo recibí', 'con el motivo nuevo') from p3;

-- El estado de Lucía no le llega a b2.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas(sync.pull(array['deposito'], (select d -> 'watermark' from q1), 1000)), array[]::text[],
          'el cambio de los depósitos de Lucía no le llega a b2');

-- Una baja lógica baja como tombstone, para que el teléfono borre su réplica.
select pg_temp.como_servidor();
update public.deposito set deleted_at = now() where id = pg_temp.u('54');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas(sync.pull(array['deposito'], (select d -> 'watermark' from q1), 1000)), array['54x'],
          'la baja lógica de un depósito por validar baja como tombstone');

-- ---------------------------------------------------------------------------
-- 4. El teléfono no se valida ni se rechaza solo
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000154b01', 'entity', 'deposito', 'op', 'update',
    'sync_version', 1,
    'payload', jsonb_build_object('id', pg_temp.u('56'), 'validado_en', '2026-10-30T10:00:00Z', 'rechazado_en', null))))
    #>> '{results,0,outcome}',
  'invalid', 'subir una validación desde el teléfono vuelve invalid');
select pg_temp.como_servidor();
select is((select rechazado_en is not null and validado_en is null from public.deposito where id = pg_temp.u('56')),
          true, 'y el depósito sigue rechazado y sin validar en el servidor');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table p1, p2, p3, q1, c1, m1;
select pg_temp.limpiar();
select is((select count(*)::int from public.deposito
            where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'))),
          0, 'limpieza: no quedan depósitos de la prueba');

select * from finish();
