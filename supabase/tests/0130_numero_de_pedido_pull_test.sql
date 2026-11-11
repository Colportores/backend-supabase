-- pgTAP · migración 0130 (backend-supabase#180): el número visible del pedido baja al teléfono por el pull. Tras
-- reinstalar, la colportora baja sus pedidos con el número que puso el servidor (cada uno el suyo, distinto, en
-- el orden en que se crearon); el de otra colportora no baja; y si el teléfono sube el pedido con otro número en
-- el payload, el que baja después es el del servidor.
--
-- Como 0004, 0014, 0041, 0108 y 0124, NO va en una transacción: el delta solo sirve filas commiteadas (en
-- producción el push y el pull son dos requests). Limpia al final, y también al empezar: si una corrida se
-- cortó antes de la limpieza, la siguiente no choca con lo que dejó.

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

-- Ids (prefijo 31): usuarios 31b1.., pedidos 31a1..; client_op_id: 31 y dos caracteres.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '31' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000031' || p)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.pedido_item where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.pedido_casa_editora where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.campania_colportor where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.campania where id = pg_temp.u('e1');
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'));
end $$;

create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns text language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0 ->> 'outcome';
$$;

-- Los ids (últimos dos caracteres) de las filas de la entidad en un pull, ordenadas por id.
create or replace function pg_temp.ids(p_delta jsonb, p_entidad text) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;
-- El número de cada pedido del pull como «id=número», ordenado por id.
create or replace function pg_temp.numeros(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || '=' || coalesce(e ->> 'numero', '-') order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'pedido_casa_editora', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 y b2 colportoras en la campaña e1, c1 la coordina.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pedido31-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 pedido31', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days');

-- ---------------------------------------------------------------------------
-- 1. Los teléfonos suben: b1 dos pedidos (el primero con un número inventado en el payload), b2 uno
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a1'), 'estado', 'PENDIENTE_AUTORIZACION', 'numero', 424242)),
          'accepted', 'b1 sube su primer pedido, con un número inventado en el payload');
select is(pg_temp.push1(pg_temp.op('02'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a2'), 'estado', 'PENDIENTE_AUTORIZACION')),
          'accepted', 'b1 sube un segundo pedido');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('03'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a3'), 'estado', 'PENDIENTE_AUTORIZACION')),
          'accepted', 'b2 sube el suyo');

-- ---------------------------------------------------------------------------
-- 2. Reinstalar: pull de cero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pull_b1 as
select sync.pull(array['pedido_casa_editora'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'pedido_casa_editora'), array['a1', 'a2'], 'b1 baja sus dos pedidos y no el de b2') from pull_b1;
select is((select count(*)::int from pull_b1, jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e
            where e ? 'numero' and jsonb_typeof(e -> 'numero') = 'number'), 2,
          'cada uno baja con su número (un entero)');
select is((select count(distinct e ->> 'numero')::int from pull_b1, jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e), 2,
          'distintos entre sí');
select isnt((select (e ->> 'numero')::bigint from pull_b1, jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e
              where right(e ->> 'id', 2) = 'a1'), 424242::bigint, 'y no es el que inventó el teléfono');
select is((select (select (e ->> 'numero')::bigint from jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e where right(e ->> 'id', 2) = 'a2')
                 - (select (e ->> 'numero')::bigint from jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e where right(e ->> 'id', 2) = 'a1')
             from pull_b1),
          1::bigint, 'en el orden en que se crearon');

-- Lo que baja es lo que tiene el servidor.
select pg_temp.como_servidor();
select is((select array_agg(right(id::text, 2) || '=' || numero order by id) from public.pedido_casa_editora
            where colportor_id = pg_temp.u('b1')),
          (select pg_temp.numeros(d) from pull_b1), 'el número del pull es el de la tabla');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.ids(sync.pull(array['pedido_casa_editora'], '{}'::jsonb, 1000), 'pedido_casa_editora'), array['a3'],
          'b2 baja solo el suyo, con su número');
select isnt((select e ->> 'numero' from jsonb_array_elements(sync.pull(array['pedido_casa_editora'], '{}'::jsonb, 1000) -> 'rows' -> 'pedido_casa_editora') e),
            (select e ->> 'numero' from pull_b1, jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e where right(e ->> 'id', 2) = 'a1'),
            'que no es el de b1');

-- ---------------------------------------------------------------------------
-- 3. Un cambio posterior llega por el delta con el mismo número
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('10'), 'pedido_casa_editora', 'update',
                        jsonb_build_object('id', pg_temp.u('a2'), 'estado', 'CANCELADO'),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('a2'))),
          'accepted', 'b1 cancela el a2 con la versión que bajó');
create temp table delta_b1 as
select sync.pull(array['pedido_casa_editora'], d -> 'watermark', 1000) as d from pull_b1;
select is(pg_temp.ids(d, 'pedido_casa_editora'), array['a2'], 'el delta trae solo el a2') from delta_b1;
select is((select e ->> 'numero' from delta_b1, jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e),
          (select e ->> 'numero' from pull_b1, jsonb_array_elements(d -> 'rows' -> 'pedido_casa_editora') e where right(e ->> 'id', 2) = 'a2'),
          'con el mismo número que tenía');

select pg_temp.como_servidor();
select pg_temp.limpiar();
select is((select count(*)::int from public.pedido_casa_editora where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'))), 0,
          'limpio: no quedó nada de este archivo');

select * from finish();
