-- pgTAP · migración 0145 (backend-supabase#218): el stock del colportor baja al teléfono por el sync.
--   · el registro: entidad de solo bajada con el dueño en `usuario_id` (sin ubicación ni campañas), el índice
--     del delta con el dueño primero, sin Realtime y sin tocar las políticas de lectura de la 0067;
--   · el pull: cada uno baja SOLO su stock (Ana no baja el de su compañero; el coordinador, que la RLS deja
--     leer el de sus colportores, baja el suyo propio y nada más; el ADMIN no baja el de nadie); la fila lleva
--     las cantidades (también las negativas, S46) y no la maquinaria del delta;
--   · el delta: sin cambios no baja nada; cuando el servidor mueve el stock baja la cantidad nueva solo a su
--     dueña; la baja lógica baja como tombstone;
--   · solo bajada: el teléfono no escribe el stock (ni lo crea ni lo cambia).
--
-- Como 0004, 0108_devolucion_pull y 0144, NO va en una transacción: el delta solo sirve lo commiteado.
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

-- Ids con el prefijo 145: usuarios 145a1.., productos 14501.., filas de stock 14551.., campaña 145e1.
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000145' || p_sufijo)::uuid;
$$;

create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.stock where usuario_id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('ad'));
  delete from public.campania_colportor where campania_id = pg_temp.u('e1');
  delete from public.campania where id = pg_temp.u('e1');
  delete from public.producto where id in (pg_temp.u('01'), pg_temp.u('02'), pg_temp.u('03'));
  delete from public.usuario_rol where usuario_id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('ad'));
  delete from auth.users where id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('ad'));
end $$;

-- Los sufijos de los ids de las filas de `stock` que bajaron, ordenados; con «x» si vienen dados de baja.
create or replace function pg_temp.filas(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || case when e ->> 'deleted_at' is not null then 'x' else '' end
                            order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'stock', '[]'::jsonb)) e;
$$;

-- «sufijo=cantidad_disponible» de cada fila que bajó, ordenado por id.
create or replace function pg_temp.cantidades(p_delta jsonb) returns text[]
language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || '=' || (e ->> 'cantidad_disponible') order by e ->> 'id'),
                  array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'stock', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- 1. El registro, el índice, Realtime y las políticas
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select nombre, tabla::text, columna_pk, permite_push, sigue_campanias, columna_ubicacion, columna_duenio
       from sync.entidad where nombre = 'stock' $$,
  $$ values ('stock'::text, 'stock'::text, 'id'::text, false, false, null::text, 'usuario_id'::text) $$,
  'la entidad de sync: stock, de solo bajada, con el dueño en usuario_id y sin filtro por campaña ni ubicación');
select has_index('public', 'stock', 'stock_delta_idx', array['usuario_id', 'xmin_w', 'id'],
                 'el índice del delta, con el dueño primero');
select is((select count(*)::int from pg_publication_tables
            where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'stock'),
          0, 'stock no va a Realtime (ADR-012: solo catálogo y autorizaciones)');
select bag_eq(
  $$ select policyname::text from pg_policies where schemaname = 'public' and tablename = 'stock' $$,
  array['stock_select'],
  'la única política es la de lectura de la 0067: no se agregó ninguna de escritura');
select is((select string_agg(privilege_type, ',' order by privilege_type) from information_schema.role_table_grants
            where table_schema = 'public' and table_name = 'stock' and grantee = 'authenticated'),
          'SELECT', 'y el teléfono solo tiene SELECT sobre la tabla');

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). a1 coordina la campaña e1, donde están inscriptos b1 y b2; b3 no tiene stock;
-- ad es ADMIN. Stock: b1 tiene dos productos (uno en negativo: entregó de más, S46), b2 uno, a1 uno propio.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'stock145-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 stock145', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1'));
insert into public.campania_colportor (campania_id, usuario_id) values
  (pg_temp.u('e1'), pg_temp.u('b1')),
  (pg_temp.u('e1'), pg_temp.u('b2'));
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('01'), 'Libro 1 stock145', 'LIBRO'),
  (pg_temp.u('02'), 'Libro 2 stock145', 'LIBRO'),
  (pg_temp.u('03'), 'Libro 3 stock145', 'LIBRO');
insert into public.stock (id, usuario_id, producto_id, cantidad_disponible, cantidad_reservada) values
  (pg_temp.u('51'), pg_temp.u('b1'), pg_temp.u('01'), 10, 2),
  (pg_temp.u('52'), pg_temp.u('b1'), pg_temp.u('02'), -2, 0),
  (pg_temp.u('53'), pg_temp.u('b2'), pg_temp.u('01'), 7, 0),
  (pg_temp.u('54'), pg_temp.u('a1'), pg_temp.u('03'), 5, 0);

-- ---------------------------------------------------------------------------
-- 2. Primer pull: cada uno baja solo su stock
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p1 as select sync.pull(array['stock'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array['51','52'], 'Ana (b1) baja sus dos filas de stock y nada del compañero (b2) ni del coordinador') from p1;
select is(pg_temp.cantidades(d), array['51=10','52=-2'], 'con la cantidad de cada producto, también la negativa (entregó de más)') from p1;
select is((select (e ->> 'cantidad_reservada')::int
             from p1, jsonb_array_elements(d -> 'rows' -> 'stock') e
            where right(e ->> 'id', 2) = '51'), 2, 'y la reservada') from p1;
select is((select array_agg(e ->> 'producto_id' order by e ->> 'id')
             from p1, jsonb_array_elements(d -> 'rows' -> 'stock') e),
          array[pg_temp.u('01')::text, pg_temp.u('02')::text], 'de qué producto es cada una') from p1;
select ok((select bool_and((e ->> 'usuario_id') = pg_temp.u('b1')::text)
             from p1, jsonb_array_elements(d -> 'rows' -> 'stock') e), 'todas suyas') from p1;
select ok((select bool_and(e ? 'sync_version' and e ? 'updated_at' and e ? 'deleted_at' and not (e ? 'xmin_w'))
             from p1, jsonb_array_elements(d -> 'rows' -> 'stock') e),
          'la fila lleva la versión y la baja lógica, y no la maquinaria del delta') from p1;
select is((select d ->> 'has_more' from p1), 'false', 'sin más páginas') from p1;

select pg_temp.actuar_como(pg_temp.u('b2'));
create temp table q1 as select sync.pull(array['stock'], '{}'::jsonb, 1000) as d;
select is(pg_temp.cantidades(d), array['53=7'], 'b2 baja solo la suya') from q1;

-- El coordinador de la campaña: la RLS le deja leer el stock de b1 y b2 (el panel), pero su teléfono baja el
-- propio y nada más (columna_duenio).
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*)::int from public.stock), 4, 'el coordinador lee por RLS el stock de sus colportores (para el panel)');
create temp table c1 as select sync.pull(array['stock'], '{}'::jsonb, 1000) as d;
select is(pg_temp.cantidades(d), array['54=5'], 'pero en su teléfono baja solo el suyo') from c1;

select pg_temp.actuar_como(pg_temp.u('ad'));
create temp table m1 as select sync.pull(array['stock'], '{}'::jsonb, 1000) as d;
select is(pg_temp.filas(d), array[]::text[], 'el ADMIN, que lee todo por RLS, no baja el de nadie') from m1;

select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.filas(sync.pull(array['stock'], '{}'::jsonb, 1000)), array[]::text[],
          'quien no tiene stock no baja nada (y no falla)');

-- Sin cambios, el pull siguiente no trae nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['stock'], d -> 'watermark', 1000) -> 'rows' from p1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. Cuando el servidor mueve el stock (una entrega lo descuenta, 0118), el delta trae la cantidad nueva
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.stock set cantidad_disponible = cantidad_disponible - 3 where id = pg_temp.u('51');

select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p2 as select sync.pull(array['stock'], (select d -> 'watermark' from p1), 1000) as d;
select is(pg_temp.cantidades(d), array['51=7'], 'el servidor descontó 3: baja solo esa fila, con la cantidad nueva') from p2;
select ok((select (e ->> 'sync_version')::int > 0 from p2, jsonb_array_elements(d -> 'rows' -> 'stock') e),
          'con su versión subida') from p2;

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas(sync.pull(array['stock'], (select d -> 'watermark' from q1), 1000)), array[]::text[],
          'el cambio del stock de b1 no le llega a b2');

-- Una baja lógica baja como tombstone, para que el teléfono borre su réplica.
select pg_temp.como_servidor();
update public.stock set deleted_at = now() where id = pg_temp.u('52');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table p3 as select sync.pull(array['stock'], (select d -> 'watermark' from p2), 1000) as d;
select is(pg_temp.filas(d), array['52x'], 'la baja lógica baja como tombstone') from p3;

-- Un producto nuevo en el stock (llegó un pedido) también baja por el delta.
select pg_temp.como_servidor();
insert into public.stock (id, usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('55'), pg_temp.u('b1'), pg_temp.u('03'), 12);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cantidades(sync.pull(array['stock'], (select d -> 'watermark' from p3), 1000)), array['55=12'],
          'y una fila nueva (un producto que no tenía) baja por el delta');

-- ---------------------------------------------------------------------------
-- 4. Solo bajada: el teléfono no escribe el stock
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000145b01', 'entity', 'stock', 'op', 'insert',
    'payload', jsonb_build_object('id', pg_temp.u('f1'), 'usuario_id', pg_temp.u('b1'), 'producto_id', pg_temp.u('02'),
                                  'cantidad_disponible', 999))))
    #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA', 'subir una fila de stock inventada se rechaza (la réplica es de solo lectura)');
select is(
  sync.push(jsonb_build_array(jsonb_build_object(
    'client_op_id', '01920000-0000-7000-8000-000000145b02', 'entity', 'stock', 'op', 'update',
    'sync_version', 1,
    'payload', jsonb_build_object('id', pg_temp.u('51'), 'cantidad_disponible', 999))))
    #>> '{results,0,code}',
  'ENTIDAD_DE_SOLO_LECTURA', 'y cambiar la cantidad de la propia también');
select pg_temp.como_servidor();
select is((select count(*)::int from public.stock where id = pg_temp.u('f1')), 0, 'la fila inventada no quedó escrita');
select is((select cantidad_disponible from public.stock where id = pg_temp.u('51')), 7, 'y la cantidad sigue siendo la del servidor');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table p1, p2, p3, q1, c1, m1;
select pg_temp.limpiar();
select is((select count(*)::int from public.stock
            where usuario_id in (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('ad'))),
          0, 'limpieza: no queda stock de la prueba');

select * from finish();
