-- pgTAP · migración 0124 (backend-supabase#102): pedido_casa_editora y pedido_item en el pull. Tras reinstalar, la
-- app baja de cero los pedidos de la colportora con lo que decidió el servidor (monto, aviso del límite, origen,
-- precio de cada línea); lo que cambia después (autorizar, cancelar) llega por el delta; y nadie baja los de otra.
--
-- Como 0004, 0014, 0041 y 0108, NO va en una transacción: el delta solo sirve filas commiteadas (en producción el
-- push y el pull son dos requests). Limpia al final, y también al empezar: si una corrida se cortó antes de la
-- limpieza, la siguiente no choca con lo que dejó.

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

-- Ids (prefijo 83): usuarios 83b1.., productos 8311.., pedidos 83a1.., líneas 83e1..; client_op_id: 83 y dos dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '83' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000083' || p)::uuid;
$$;

-- Borra todo lo de este archivo (como postgres): las líneas, los pedidos, las inscripciones y los usuarios.
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.pedido_item where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.pedido_casa_editora where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.campania_colportor where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.campania where id = pg_temp.u('e1');
  delete from public.producto where id in (pg_temp.u('11'), pg_temp.u('12'));
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'));
end $$;

create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns text language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0 ->> 'outcome';
$$;

-- Una columna de las filas de la entidad en un pull, ordenadas por id.
create or replace function pg_temp.col(p_delta jsonb, p_entidad text, p_col text) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> p_col, '-') order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;
create or replace function pg_temp.ids(p_delta jsonb, p_entidad text) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 y b2 colportoras en la campaña e1 (límite de deuda 20000), c1 la coordina.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pedido83-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, limite_deuda) values
  (pg_temp.u('e1'), 'e1 pedido83', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 1000);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('11'), 'Libro 1 t83', 'LIBRO', 700),
  (pg_temp.u('12'), 'Libro 2 t83', 'LIBRO', 300);

-- ---------------------------------------------------------------------------
-- 1. Los teléfonos suben: b1 dos pedidos (uno con dos líneas, uno con una), b2 uno
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a1'), 'estado', 'PENDIENTE_AUTORIZACION')),
          'accepted', 'b1 sube su primer pedido');
select is(pg_temp.push1(pg_temp.op('02'), 'pedido_item', 'insert',
                        jsonb_build_object('id', pg_temp.u('e1'), 'pedido_id', pg_temp.u('a1'), 'producto_id', pg_temp.u('11'), 'cantidad', 2)),
          'accepted', 'con una línea');
select is(pg_temp.push1(pg_temp.op('03'), 'pedido_item', 'insert',
                        jsonb_build_object('id', pg_temp.u('e2'), 'pedido_id', pg_temp.u('a1'), 'producto_id', pg_temp.u('12'), 'cantidad', 1)),
          'accepted', 'y otra');
select is(pg_temp.push1(pg_temp.op('04'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a2'), 'estado', 'PENDIENTE_AUTORIZACION')),
          'accepted', 'b1 sube un segundo pedido');
select is(pg_temp.push1(pg_temp.op('05'), 'pedido_item', 'insert',
                        jsonb_build_object('id', pg_temp.u('e3'), 'pedido_id', pg_temp.u('a2'), 'producto_id', pg_temp.u('12'), 'cantidad', 1)),
          'accepted', 'con una línea');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('06'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a3'), 'estado', 'PENDIENTE_AUTORIZACION')),
          'accepted', 'b2 sube el suyo');
select is(pg_temp.push1(pg_temp.op('07'), 'pedido_item', 'insert',
                        jsonb_build_object('id', pg_temp.u('e4'), 'pedido_id', pg_temp.u('a3'), 'producto_id', pg_temp.u('11'), 'cantidad', 9)),
          'accepted', 'con su línea');

-- ---------------------------------------------------------------------------
-- 2. Reinstalar: pull de cero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pull_b1 as
select sync.pull(array['pedido_casa_editora', 'pedido_item'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d, 'pedido_casa_editora'), array['a1', 'a2'], 'b1 baja sus dos pedidos y no el de b2') from pull_b1;
select is(pg_temp.col(d, 'pedido_casa_editora', 'monto_total'), array['1700', '300'],
          'con el monto que calculó el servidor (2 × 700 + 1 × 300, y 1 × 300)') from pull_b1;
select is(pg_temp.col(d, 'pedido_casa_editora', 'excede_limite'), array['true', 'false'],
          'y el aviso del límite de 1000: el primero lo supera, el segundo no') from pull_b1;
select is(pg_temp.col(d, 'pedido_casa_editora', 'origen'), array['COLPORTOR', 'COLPORTOR'], 'de origen COLPORTOR') from pull_b1;
select is(pg_temp.col(d, 'pedido_casa_editora', 'estado'), array['PENDIENTE_AUTORIZACION', 'PENDIENTE_AUTORIZACION'],
          'por autorizar') from pull_b1;
select is(pg_temp.col(d, 'pedido_casa_editora', 'colportor_id'), array[pg_temp.u('b1')::text, pg_temp.u('b1')::text], 'todos suyos') from pull_b1;
select is(pg_temp.ids(d, 'pedido_item'), array['e1', 'e2', 'e3'], 'baja sus tres líneas y no la de b2') from pull_b1;
select is(pg_temp.col(d, 'pedido_item', 'precio_unitario'), array['700', '300', '300'], 'con el precio de la foto del servidor') from pull_b1;
select is(pg_temp.col(d, 'pedido_item', 'pedido_id'), array[pg_temp.u('a1')::text, pg_temp.u('a1')::text, pg_temp.u('a2')::text],
          'de su pedido') from pull_b1;
select is(pg_temp.col(d, 'pedido_item', 'colportor_id'), array[pg_temp.u('b1')::text, pg_temp.u('b1')::text, pg_temp.u('b1')::text],
          'y la dueña de cada línea') from pull_b1;
select ok((select not jsonb_path_exists(d, '$.rows.pedido_casa_editora[*].xmin_w') from pull_b1), 'xmin_w no viaja');
select ok((select jsonb_path_exists(d, '$.rows.pedido_casa_editora[*].sync_version') from pull_b1),
          'sync_version sí (el teléfono la manda en el próximo update)');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.ids(sync.pull(array['pedido_casa_editora'], '{}'::jsonb, 1000), 'pedido_casa_editora'), array['a3'], 'b2 baja solo el suyo');
select is(pg_temp.ids(sync.pull(array['pedido_item'], '{}'::jsonb, 1000), 'pedido_item'), array['e4'], 'y su línea');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.ids(sync.pull(array['pedido_casa_editora', 'pedido_item'], '{}'::jsonb, 1000), 'pedido_casa_editora'), array[]::text[],
          'el coordinador no baja los pedidos de nadie por el pull (los lee por el panel)');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['pedido_casa_editora', 'pedido_item'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. Los cambios llegan por el delta
-- ---------------------------------------------------------------------------
-- El coordinador autoriza el a1 (el servidor) y b1 cancela el a2.
select pg_temp.como_servidor();
update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = pg_temp.u('a1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('10'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('a2'), 'estado', 'CANCELADO'),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('a2'))),
          'accepted', 'b1 cancela el a2 con la versión que bajó');
select is(pg_temp.push1(pg_temp.op('11'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('a1'), 'estado', 'CANCELADO'),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('a1'))),
          'invalid', 'y no puede cancelar el a1, que ya autorizó el coordinador');
create temp table delta_b1 as
select sync.pull(array['pedido_casa_editora', 'pedido_item'], d -> 'watermark', 1000) as d from pull_b1;
select is(pg_temp.ids(d, 'pedido_casa_editora'), array['a1', 'a2'], 'el delta trae solo lo que cambió: a1 y a2') from delta_b1;
select is(pg_temp.col(d, 'pedido_casa_editora', 'estado'), array['AUTORIZADO', 'CANCELADO'], 'con su estado nuevo') from delta_b1;
select is(pg_temp.ids(d, 'pedido_item'), array[]::text[], 'y ninguna línea') from delta_b1;

-- El teléfono de b2 no se entera de nada de lo de b1.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.ids(sync.pull(array['pedido_casa_editora'], '{}'::jsonb, 1000), 'pedido_casa_editora'), array['a3'], 'b2 sigue bajando solo el suyo');

select pg_temp.como_servidor();
select pg_temp.limpiar();
select is((select count(*)::int from public.pedido_casa_editora where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'))), 0,
          'limpio: no quedó nada de este archivo');

select * from finish();
