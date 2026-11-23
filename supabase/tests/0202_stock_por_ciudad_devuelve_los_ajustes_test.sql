-- pgTAP · 0202 (backend-supabase#304, seguimiento de front-coordinadores-web#91): `stock_por_ciudad` devuelve, en cada
-- fila (colportor × producto), los ajustes de stock que la colportora cargó desde su teléfono (0148): la forma de la
-- columna y de cada elemento, la cantidad con signo, el orden (los más nuevos primero), el motivo de la lista, quién lo
-- cargó, que los dados de baja y los demás movimientos no salen, que solo salen los de las inscriptas en la campaña
-- (de cualquier fecha, también la de baja), que sin ajustes es `[]`, que el permiso no se movió y que lo de antes
-- (lo que tiene) cierra con la suma de los ajustes.
begin;
select * from no_plan();

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

-- El uuid de un personaje del test (sufijo de dos caracteres HEX).
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000202' || p_sufijo)::uuid
$$;

-- Los ajustes de una colportora y un producto en la campaña: el arreglo jsonb de su fila.
create or replace function pg_temp.ajustes(p_camp text, p_colp text, p_prod text)
returns jsonb language sql as $$
  select r.ajustes
    from public.stock_por_ciudad(pg_temp.u(p_camp)) r
   where r.colportor_id = pg_temp.u(p_colp) and r.producto_id = pg_temp.u(p_prod)
$$;

-- Un campo de cada ajuste, en el orden del arreglo, como arreglo de texto.
create or replace function pg_temp.campo(p_ajustes jsonb, p_campo text)
returns text[] language sql as $$
  select coalesce(array_agg(e ->> p_campo order by ord), array[]::text[])
    from jsonb_array_elements(p_ajustes) with ordinality t(e, ord)
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinadora de Cierre (Marta Coord); a2 coordinador de Otra; a0 colportor.
-- Colportoras de Cierre: b1 Ana Alfa (con ajustes), b2 Beto Bravo (una entrada y una salida que se anulan),
--        b4 Diego Duarte (inscripción de baja, con un ajuste), b5 sin nombre (con un ajuste), b6 Fede Fuentes (sin nada).
-- Colportora de Otra: b3 Carla Cruz (con un ajuste de Otra que Cierre no ve).
-- Productos: 91 Libro Uno, 92 Libro Dos.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'ajustes-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','b1','b2','b3','b4','b5','b6']) s;

update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Marta','Coord'), ('b1','Ana','Alfa'), ('b2','Beto','Bravo'), ('b3','Carla','Cruz'),
               ('b4','Diego','Duarte'), ('b6','Fede','Fuentes')) x(s, n, a)
 where u.id = pg_temp.u(x.s);

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a0','COLPORTOR'), ('b1','COLPORTOR'),
               ('b2','COLPORTOR'), ('b3','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Cierre ajustes', 'VERANO', '2026-08-03', '2026-09-30', pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otra ajustes',   'VERANO', '2026-08-03', null,         pg_temp.u('a2'));

insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null, '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b2'), null, '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b4'), null, '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b5'), null, '2026-08-01 10:00-03'),
  (pg_temp.u('e1'), pg_temp.u('b6'), null, '2026-08-01 10:00-03'),
  (pg_temp.u('e2'), pg_temp.u('b3'), null, '2026-08-01 10:00-03');
update public.campania_colportor set deleted_at = '2026-09-15 12:00:00+00'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b4');

insert into public.producto (id, nombre, categoria) values
  (pg_temp.u('91'), 'Libro Uno', 'ESPIRITUALES'),
  (pg_temp.u('92'), 'Libro Dos', 'BONIFICABLES');

-- Los movimientos los inserta el servidor (el teléfono pasa por el push, que está en 0148 y 0067): el AFTER INSERT de
-- cada ajuste mueve el stock. `created_by` null = lo cargó la dueña del movimiento; el de la fila «a1» lo cargó otra.
insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, motivo, fecha, created_by, deleted_at) values
  -- b1 × Libro Uno: stock inicial 10, libros dañados 2 (cargado por la coordinadora), conteo +1 dado de baja
  (pg_temp.u('01'), pg_temp.u('b1'), pg_temp.u('91'), 'AJUSTE_ENTRADA', 10, 'STOCK_INICIAL',   '2026-09-01 10:00:00+00', null,           null),
  (pg_temp.u('02'), pg_temp.u('b1'), pg_temp.u('91'), 'AJUSTE_SALIDA',   2,  'LIBROS_DANIADOS', '2026-09-05 10:00:00+00', pg_temp.u('a1'), null),
  (pg_temp.u('03'), pg_temp.u('b1'), pg_temp.u('91'), 'AJUSTE_ENTRADA', 1,  'CONTEO',          '2026-09-10 10:00:00+00', null,           '2026-09-10 11:00:00+00'),
  -- b1 × Libro Uno: un movimiento que no es un ajuste (no sale)
  (pg_temp.u('04'), pg_temp.u('b1'), pg_temp.u('91'), 'ENTRADA_PEDIDO',  5,  null,              '2026-09-02 10:00:00+00', null,           null),
  -- b1 × Libro Dos: una salida sola, el stock queda en negativo
  (pg_temp.u('05'), pg_temp.u('b1'), pg_temp.u('92'), 'AJUSTE_SALIDA',   3,  'CONTEO',          '2026-09-03 10:00:00+00', null,           null),
  -- b2 × Libro Uno: entra y sale lo mismo (el stock queda en cero y el historial se ve igual)
  (pg_temp.u('06'), pg_temp.u('b2'), pg_temp.u('91'), 'AJUSTE_ENTRADA', 5,  'CONTEO',          '2026-09-04 10:00:00+00', null,           null),
  (pg_temp.u('07'), pg_temp.u('b2'), pg_temp.u('91'), 'AJUSTE_SALIDA',   5,  'LIBROS_DANIADOS', '2026-09-06 10:00:00+00', null,           null),
  -- b3 (Otra): no se ve desde Cierre
  (pg_temp.u('08'), pg_temp.u('b3'), pg_temp.u('91'), 'AJUSTE_ENTRADA', 7,  'STOCK_INICIAL',   '2026-09-01 10:00:00+00', null,           null),
  -- b4 (inscripción de baja de Cierre): se ve, con de_baja
  (pg_temp.u('09'), pg_temp.u('b4'), pg_temp.u('91'), 'AJUSTE_ENTRADA', 4,  'CONTEO',          '2026-09-01 10:00:00+00', null,           null),
  -- b5 (sin nombre): cargado_por null
  (pg_temp.u('0a'), pg_temp.u('b5'), pg_temp.u('92'), 'AJUSTE_ENTRADA', 6,  'STOCK_INICIAL',   '2026-09-01 10:00:00+00', null,           null);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is((select proargnames[array_length(proargnames, 1)] from pg_proc where oid = 'public.stock_por_ciudad(uuid)'::regprocedure),
          'ajustes', 'stock_por_ciudad: `ajustes` es la última columna');
select ok(pg_get_function_result('public.stock_por_ciudad(uuid)'::regprocedure) like '%, ajustes jsonb)',
          'stock_por_ciudad: `ajustes` es jsonb');
select is((select count(*)::int from pg_proc p
            where p.oid = 'public.stock_por_ciudad(uuid)'::regprocedure
              and p.prosecdef and p.provolatile = 'v' and p.proconfig = array['search_path=""']
              and has_function_privilege('authenticated', p.oid, 'execute')
              and not has_function_privilege('anon', p.oid, 'execute')
              and not has_function_privilege('service_role', p.oid, 'execute')),
          1, 'sigue siendo SECURITY DEFINER, VOLATILE, de search_path vacío y solo para authenticated');

-- ---------------------------------------------------------------------------
-- 2. Los ajustes de cada colportora (como la coordinadora de Cierre)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));

select is((select array(select k from jsonb_object_keys(pg_temp.ajustes('e1', 'b1', '91') -> 0) k order by k collate "C")),
          array['cantidad','cargado_por','cuando','id','motivo'],
          'cada ajuste trae id, cantidad, motivo, cuando y cargado_por, y nada más');
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b1', '91'), 'cantidad'), array['-2','10'],
          'b1 × Libro Uno: la cantidad con signo (la salida resta), los más nuevos primero; el dado de baja y el pedido no salen');
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b1', '91'), 'motivo'), array['LIBROS_DANIADOS','STOCK_INICIAL'],
          'el motivo es el código de la lista');
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b1', '91'), 'id'),
          array[pg_temp.u('02')::text, pg_temp.u('01')::text], 'el id de cada ajuste es el del movimiento');
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b1', '91'), 'cargado_por'), array['Marta Coord','Ana Alfa'],
          'quién lo cargó: created_by si está y, si no, la dueña del movimiento');
select is(((pg_temp.ajustes('e1', 'b1', '91') -> 0 ->> 'cuando')::timestamptz), '2026-09-05 10:00:00+00'::timestamptz,
          'cuando es el momento en que llegó el ajuste');
select is(jsonb_typeof(pg_temp.ajustes('e1', 'b1', '91') -> 0 -> 'cantidad'), 'number', 'la cantidad es un número');

select is(pg_temp.campo(pg_temp.ajustes('e1', 'b1', '92'), 'cantidad'), array['-3'],
          'b1 × Libro Dos: una salida sola, con signo negativo');
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b2', '91'), 'cantidad'), array['-5','5'],
          'b2 × Libro Uno: entra y sale lo mismo y el historial muestra las dos');
select is(pg_temp.ajustes('e1', 'b2', '92'), '[]'::jsonb, 'b2 × Libro Dos: sin ajustes, arreglo vacío (no null)');
select is(pg_temp.ajustes('e1', 'b6', '91'), '[]'::jsonb, 'una colportora sin ningún ajuste: arreglo vacío');
select is(pg_temp.ajustes('e1', 'b6', '92'), '[]'::jsonb, 'una colportora sin ningún ajuste: arreglo vacío en cada producto');

-- Las inscriptas: la de baja se ve (con de_baja); la de otra campaña no; sin nombre, cargado_por es null.
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b4', '91'), 'cantidad'), array['4'], 'b4, de baja de la campaña: sus ajustes salen');
select is((select r.de_baja from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b4') and r.producto_id = pg_temp.u('91')), true, 'y se marca de_baja');
select is(pg_temp.campo(pg_temp.ajustes('e1', 'b5', '92'), 'cantidad'), array['6'], 'b5: su ajuste sale');
select is((pg_temp.ajustes('e1', 'b5', '92') -> 0 -> 'cargado_por'), 'null'::jsonb,
          'sin nombre ni apellido, cargado_por es null (no un texto vacío)');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r where r.colportor_id = pg_temp.u('b3')), 0,
          'b3 es de otra campaña: no tiene filas en Cierre, así que sus ajustes no salen');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r, jsonb_array_elements(r.ajustes) e
            where e ->> 'id' = pg_temp.u('08')::text), 0, 'el ajuste de b3 no aparece en ninguna fila de Cierre');

-- Solo cantidades y códigos: ningún texto libre ni dato de más en el arreglo.
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r, jsonb_array_elements(r.ajustes) e
            where e ->> 'motivo' not in ('STOCK_INICIAL', 'LIBROS_DANIADOS', 'CONTEO')), 0,
          'todos los motivos son de la lista cerrada');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r, jsonb_array_elements(r.ajustes) e
            where (e ->> 'cantidad')::int = 0), 0, 'ninguna cantidad es cero');

-- Lo de antes cierra: el stock que tiene la colportora es la suma de sus ajustes (el pedido de la fila 04 no movió stock).
select is((select r.tiene from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1') and r.producto_id = pg_temp.u('91')),
          (select sum((e ->> 'cantidad')::int)::int from jsonb_array_elements(pg_temp.ajustes('e1', 'b1', '91')) e),
          'b1 × Libro Uno: lo que tiene es la suma de sus ajustes');
select is((select r.tiene from public.stock_por_ciudad(pg_temp.u('e1')) r
            where r.colportor_id = pg_temp.u('b1') and r.producto_id = pg_temp.u('92')), -3,
          'b1 × Libro Dos: tiene -3 (negativo, tal cual) y el ajuste lo explica');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e1')) r), 10,
          'la cantidad de filas no cambió: cinco inscriptas × dos productos');

-- ---------------------------------------------------------------------------
-- 3. El permiso no se movió
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000202e1') $$,
  '42501', null, 'el coordinador de otra campaña no ve los ajustes de Cierre');
select is(pg_temp.campo(pg_temp.ajustes('e2', 'b3', '91'), 'cantidad'), array['7'],
          'cada coordinador ve los ajustes de su campaña: Otra ve los de b3');
select is((select count(*)::int from public.stock_por_ciudad(pg_temp.u('e2')) r, jsonb_array_elements(r.ajustes) e
            where e ->> 'id' <> pg_temp.u('08')::text), 0, 'y solo los suyos');

select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000202e1') $$,
  '42501', null, 'una colportora no puede leer los ajustes de nadie');
select pg_temp.actuar_como(pg_temp.u('b1'));
select throws_ok($$ select * from public.stock_por_ciudad('01920000-0000-7000-8000-0000000202e1') $$,
  '42501', null, 'ni siquiera los suyos por esta lectura');

select pg_temp.actuar_como_servidor();
select * from finish();
rollback;
