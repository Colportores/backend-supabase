-- pgTAP · migración 0032 (backend-supabase#35): ubicacion_par_decidido en el pull. Tras reinstalar, la
-- app baja de cero las decisiones del colportor (fase 3 de recover(), contrato §7); los cambios
-- siguientes (decidir de nuevo, dar de baja) llegan por el delta; y nadie baja las de otro.
--
-- Como 0004, 0014 y 0017, NO va en una transacción: el delta solo sirve filas commiteadas (en
-- producción el push y el pull son dos requests). Limpia al final, y también al empezar: si una
-- corrida se cortó antes de la limpieza, la siguiente no choca con lo que dejó.

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

-- Ids (prefijo 41, el número del archivo): usuarios 41b1.., ubicaciones 41a1.., decisiones 41d1..; los
-- client_op_id, 41 y dos dígitos (los otros llevan una letra, no se pisan).
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '41' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '41' || p)::uuid;
$$;

-- Borra todo lo de este archivo (como postgres). Las decisiones primero: borrar al usuario con ellas
-- puestas daría 23503 (tg_auditoria_update deshace el ON DELETE SET NULL).
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.ubicacion_par_decidido
   where created_by in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('ad'))
      or ubicacion_a_id in (select id from public.ubicacion where ciudad_id = pg_temp.u('f1'));
  delete from public.ubicacion where ciudad_id = pg_temp.u('f1');
  delete from public.ciudad where id = pg_temp.u('f1');
  delete from public.pais where id = pg_temp.u('f0');
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('ad'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('ad'));
end $$;

-- Un job de push de la entidad; devuelve el resultado.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns text language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'ubicacion_par_decidido', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0 ->> 'outcome';
$$;
create or replace function pg_temp.par(p_id uuid, p_a uuid, p_b uuid, p_decision text default 'CONSERVAR_AMBOS')
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'ubicacion_a_id', p_a, 'ubicacion_b_id', p_b,
                            'decision', p_decision, 'decidido_en', '2026-10-05T12:00:00Z');
$$;

-- Una columna de las filas de la entidad en un pull, ordenadas por id.
create or replace function pg_temp.col(p_delta jsonb, p_col text) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> p_col, '-') order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ubicacion_par_decidido', '[]'::jsonb)) e;
$$;
-- Los sufijos de los ids (los dos últimos caracteres) de lo que bajó.
create or replace function pg_temp.ids(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ubicacion_par_decidido', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 y b2 colportores, ad ADMIN; cuatro ubicaciones.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'par41-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais par41', 'ZP');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad par41', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia',   '100', -34.900, -56.200, pg_temp.u('f1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',    '2',   -34.905, -56.195, pg_temp.u('f1')),
  (pg_temp.u('a3'), 'CASA', 'Calle Tres',   '3',   -34.910, -56.190, pg_temp.u('f1')),
  (pg_temp.u('a4'), 'CASA', 'Calle Cuatro', '4',   -34.915, -56.185, pg_temp.u('f1'));

-- ---------------------------------------------------------------------------
-- 1. El teléfono de b1 sube tres decisiones y el de b2, una (el mismo par que una de b1)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.par(pg_temp.u('d1'), pg_temp.u('a1'), pg_temp.u('a2'))),
          'accepted', 'b1 sube (a1, a2) «Conservar ambos»');
select is(pg_temp.push1(pg_temp.op('02'), 'insert', pg_temp.par(pg_temp.u('d2'), pg_temp.u('a1'), pg_temp.u('a3'), 'IGNORAR')),
          'accepted', 'b1 sube (a1, a3) «Ignorar»');
select is(pg_temp.push1(pg_temp.op('03'), 'insert', pg_temp.par(pg_temp.u('d3'), pg_temp.u('a2'), pg_temp.u('a3'))),
          'accepted', 'b1 sube (a2, a3) «Conservar ambos»');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('04'), 'insert', pg_temp.par(pg_temp.u('d4'), pg_temp.u('a1'), pg_temp.u('a2'), 'IGNORAR')),
          'accepted', 'b2 sube (a1, a2) «Ignorar»: el mismo par que b1, otra decisión, otra fila');

-- ---------------------------------------------------------------------------
-- 2. Reinstalar: pull de cero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pull_b1 as
select sync.pull(array['ubicacion_par_decidido'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d), array['d1', 'd2', 'd3'], 'b1 baja sus tres decisiones y nada más (no la d4 de b2)') from pull_b1;
select is(pg_temp.col(d, 'decision'), array['CONSERVAR_AMBOS', 'IGNORAR', 'CONSERVAR_AMBOS'],
          'con su decisión') from pull_b1;
select is(pg_temp.col(d, 'ubicacion_a_id'),
          array[pg_temp.u('a1')::text, pg_temp.u('a1')::text, pg_temp.u('a2')::text], 'y el par: a') from pull_b1;
select is(pg_temp.col(d, 'ubicacion_b_id'),
          array[pg_temp.u('a2')::text, pg_temp.u('a3')::text, pg_temp.u('a3')::text], 'y el par: b') from pull_b1;
select is((select bool_and((e ->> 'decidido_en')::timestamptz = '2026-10-05T12:00:00Z'::timestamptz)
             from pull_b1, jsonb_array_elements(d -> 'rows' -> 'ubicacion_par_decidido') e), true,
          'con la fecha que decidió el teléfono') from pull_b1;
select is(pg_temp.col(d, 'created_by'), array[pg_temp.u('b1')::text, pg_temp.u('b1')::text, pg_temp.u('b1')::text],
          'todas suyas') from pull_b1;
select is((select d ->> 'has_more' from pull_b1), 'false', 'sin más páginas');
select ok((select not jsonb_path_exists(d, '$.rows.ubicacion_par_decidido[*].xmin_w') from pull_b1), 'xmin_w no viaja');
select ok((select jsonb_path_exists(d, '$.rows.ubicacion_par_decidido[*].sync_version') from pull_b1),
          'sync_version sí (el teléfono la manda en el próximo update)');

-- Un teléfono nuevo (otro dispositivo, otra instalación) del mismo colportor: lo mismo.
select is((select pg_temp.ids(sync.pull(array['ubicacion_par_decidido'], '{}'::jsonb, 1000, pg_temp.op('99')))),
          array['d1', 'd2', 'd3'], 'otro dispositivo de b1: las mismas tres');

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table pull_b2 as
select sync.pull(array['ubicacion_par_decidido'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d), array['d4'], 'b2 baja solo la suya') from pull_b2;

select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.ids(sync.pull(array['ubicacion_par_decidido'], '{}'::jsonb, 1000)), array[]::text[],
          'el ADMIN no baja las de nadie (ni las de b1 ni las de b2): la cuenta de todos es R21');

-- Sin cambios, el pull siguiente no trae nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['ubicacion_par_decidido'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- Por páginas (el delta es por (xmin_w, id)): dos filas por vez, sin repetir ni saltear.
create temp table pag1 as
select sync.pull(array['ubicacion_par_decidido'], '{}'::jsonb, 2) as d;
select is((select jsonb_array_length(d -> 'rows' -> 'ubicacion_par_decidido') from pag1), 2, 'primera página: dos filas');
select is((select (d ->> 'has_more')::boolean from pag1), true, 'y avisa que hay más');
select is((select pg_temp.ids(sync.pull(array['ubicacion_par_decidido'], d -> 'watermark', 2)) from pag1),
          array['d3'], 'la segunda trae la que falta');

-- ---------------------------------------------------------------------------
-- 3. Los cambios llegan por el delta
-- ---------------------------------------------------------------------------
-- b1 se arrepiente de (a1, a3): «Ignorar» pasa a «Conservar ambos».
select is(pg_temp.push1(pg_temp.op('05'), 'update',
                        jsonb_build_object('id', pg_temp.u('d2'), 'decision', 'CONSERVAR_AMBOS', 'decidido_en', '2026-10-06T09:00:00Z'), 0),
          'accepted', 'b1 decide de nuevo (a1, a3)');
create temp table pull_b1_cambio as
select sync.pull(array['ubicacion_par_decidido'], (select d -> 'watermark' from pull_b1), 1000) as d;
select is(pg_temp.ids(d), array['d2'], 'llega solo esa fila') from pull_b1_cambio;
select is(pg_temp.col(d, 'decision'), array['CONSERVAR_AMBOS'], 'con la decisión nueva') from pull_b1_cambio;
select is(pg_temp.col(d, 'sync_version'), array['1'], 'y su versión') from pull_b1_cambio;
select is((select ((e ->> 'decidido_en')::timestamptz = '2026-10-06T09:00:00Z'::timestamptz)
             from pull_b1_cambio, jsonb_array_elements(d -> 'rows' -> 'ubicacion_par_decidido') e), true,
          'y la fecha nueva') from pull_b1_cambio;

-- Y la da de baja: llega como tombstone.
select is(pg_temp.push1(pg_temp.op('06'), 'delete', jsonb_build_object('id', pg_temp.u('d3')), 0),
          'accepted', 'b1 da de baja (a2, a3)');
create temp table pull_b1_baja as
select sync.pull(array['ubicacion_par_decidido'], (select d -> 'watermark' from pull_b1_cambio), 1000) as d;
select is(pg_temp.ids(d), array['d3'], 'llega la baja') from pull_b1_baja;
select is((pg_temp.col(d, 'deleted_at'))[1] <> '-', true, 'como tombstone: con deleted_at') from pull_b1_baja;

-- Nada de lo de b1 le llega a b2.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select sync.pull(array['ubicacion_par_decidido'], d -> 'watermark', 1000) -> 'rows' from pull_b2), '{}'::jsonb,
          'a b2 no le llega nada de los cambios de b1');

-- Un reinstalado baja la decisión de nuevo con la versión que tenía el servidor, incluida la baja:
-- el teléfono no la resucita (viene con deleted_at).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((pg_temp.col(sync.pull(array['ubicacion_par_decidido'], '{}'::jsonb, 1000), 'deleted_at'))[3] <> '-', true,
          'tras reinstalar, la dada de baja baja con su deleted_at (no vuelve a estar viva)');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table pull_b1, pull_b2, pag1, pull_b1_cambio, pull_b1_baja;
select pg_temp.limpiar();

select * from finish();
