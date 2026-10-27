-- pgTAP · migración 0071 (backend-supabase#138, HU-CAT-009 y HU-VEN-001; decisiones de Cristian del 23/10):
--   1. «Colección N»: coleccion.libros_a_elegir (integer NOT NULL, default 0, >= 0) y precios_de_la_ciudad() lo
--      trae (null en un producto, el de la colección en una colección).
--   2. «Combo vendido»: la forma de venta_item.componentes (componentes_de_venta_validos), caso por caso.
--   3. venta_item.componentes en la tabla: obligatorio en un combo, nulo en un producto suelto, la forma;
--      repetidos y varias unidades; el UPDATE; el push (aceptado, inválido, reintento) y el pull.
--   4. «Monto manual»: venta.motivo_monto_manual (null, texto, 500 caracteres y no bytes, extremos con espacio,
--      en blanco), directo y por sync_push.
--   5. «Talonario por año»: único por colportor + número + año de la fecha en hora de Uruguay (el índice viejo ya
--      no está), el borde de año contra UTC, la baja lógica, otro colportor, la zona horaria de la sesión y el push.
--   6. Privilegios de las dos funciones nuevas.
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
  select ('01920000-0000-7000-8000-0000000071' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- SQLSTATE o 'ok' de lo que hace una sentencia (en subtransacción: no deja nada si falla).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.sobre() returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000071d0',
                            'app_version', '1.4.2', 'schema_version', 1);
$$;
create or replace function pg_temp.push(p_jobs jsonb) returns jsonb language sql as $$
  select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', p_jobs));
$$;
create or replace function pg_temp.job(p_op text, p_entidad text, p_payload jsonb) returns jsonb language sql as $$
  select jsonb_build_object('client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', 'insert',
                            'sync_version', null, 'payload', p_payload);
$$;
create or replace function pg_temp.resultados(p_r jsonb) returns text[] language sql as $$
  select array_agg(e ->> 'outcome' order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
create or replace function pg_temp.codigos(p_r jsonb) returns text[] language sql as $$
  select array_agg(coalesce(e ->> 'code', '-') order by i) from jsonb_array_elements(p_r -> 'results') with ordinality x(e, i);
$$;
-- Lo que traía el Pack Familiar: 1 libro (11) y 2 revistas (12).
create or replace function pg_temp.pack() returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1),
                           jsonb_build_object('producto_id', pg_temp.u('12'), 'cantidad', 2));
$$;
create or replace function pg_temp.payload_venta(p_id text, p_talonario text, p_fecha timestamptz, p_motivo text default null)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object('id', pg_temp.u(p_id), 'espacio_persona_id', pg_temp.u('ca'),
         'numero_talonario', p_talonario, 'monto_total', 85000, 'fecha', p_fecha, 'motivo_monto_manual', p_motivo));
$$;
create or replace function pg_temp.payload_item(p_id text, p_venta text, p_prod text, p_col text, p_comp jsonb)
returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'id', pg_temp.u(p_id), 'venta_id', pg_temp.u(p_venta),
    'producto_id', pg_temp.u(p_prod), 'coleccion_id', pg_temp.u(p_col),
    'cantidad', 1, 'precio_unitario', 1000, 'subtotal', 1000, 'componentes', p_comp));
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- ad es ADMIN; b1 y b2 son colportores; b1 está inscripto en la campaña e1 (ciudad f1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'combo71-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais combo71', 'ZK');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 combo71', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'e1 combo71', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);
-- Una campaña larga que ya había empezado en las fechas fijas de las ventas del push (2026 y 2027): el
-- servidor rechaza una venta anterior al inicio de la campaña del colportor (0102).
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e0'), 'e0 combo71 larga', 'PERMANENTE', '2026-01-01', '2027-12-31');
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e0'), pg_temp.u('b1'), null);

-- Catálogo: un libro (11), una revista (12), otro libro (13). El «Pack Familiar» (d0) es fijo: 1 libro y 2 revistas.
-- La «Colección de 2 libros» (d1) no lleva nada fijo y deja elegir 2 libros.
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 t71', 'LIBRO'),
  (pg_temp.u('12'), 'Revista 2 t71', 'REVISTA'),
  (pg_temp.u('13'), 'Libro 3 t71', 'LIBRO');
insert into public.coleccion (id, nombre) values (pg_temp.u('d0'), 'Pack Familiar t71');
insert into public.coleccion (id, nombre, libros_a_elegir) values (pg_temp.u('d1'), 'Coleccion de 2 libros t71', 2);
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  (pg_temp.u('a1'), pg_temp.u('11'), pg_temp.u('d0'), 1),
  (pg_temp.u('a2'), pg_temp.u('12'), pg_temp.u('d0'), 2);
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('21'), null, pg_temp.u('d0'), 120000, pg_temp.h() - 100, null),
  (pg_temp.u('22'), null, pg_temp.u('d1'),  90000, pg_temp.h() - 100, null);
-- Una casa y un vínculo para las ventas de b1 y b2.
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id)
values (pg_temp.u('c8'), 'CASA', -34.88, -56.15, pg_temp.u('c1'));
insert into public.espacio (id, ubicacion_id) values (pg_temp.u('c9'), pg_temp.u('c8'));
insert into public.espacio_persona (id, espacio_id, persona_id)
values (pg_temp.u('ca'), pg_temp.u('c9'), pg_temp.u('cb'));

-- ---------------------------------------------------------------------------
-- 1. «Colección N»: libros_a_elegir
-- ---------------------------------------------------------------------------
select has_column('public', 'coleccion', 'libros_a_elegir', 'coleccion tiene libros_a_elegir');
select col_type_is('public', 'coleccion', 'libros_a_elegir', 'integer', 'libros_a_elegir es integer');
select col_not_null('public', 'coleccion', 'libros_a_elegir', 'libros_a_elegir es obligatoria');
select col_default_is('public', 'coleccion', 'libros_a_elegir', '0', 'y vale 0 si no se manda: un combo fijo');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.coleccion'::regclass and conname = 'coleccion_libros_a_elegir_no_negativo'),
          'CHECK ((libros_a_elegir >= 0))', 'no puede ser negativa');
select is((select libros_a_elegir from public.coleccion where id = pg_temp.u('d0')), 0,
          'una colección cargada sin decir nada es un combo fijo (0)');
select is((select libros_a_elegir from public.coleccion where id = pg_temp.u('d1')), 2,
          'la «Colección de 2 libros» deja elegir 2');
select is(pg_temp.error_de($$ insert into public.coleccion (id, nombre, libros_a_elegir)
     values ('01920000-0000-7000-8000-0000000071d2', 'x t71', -1) $$), '23514', 'libros_a_elegir negativo: rechazado');
select is(pg_temp.error_de($$ insert into public.coleccion (id, nombre, libros_a_elegir)
     values ('01920000-0000-7000-8000-0000000071d2', 'x t71', null) $$), '23502', 'libros_a_elegir null: rechazado (NOT NULL)');
select is(pg_temp.error_de($$ insert into public.coleccion (id, nombre, libros_a_elegir)
     values ('01920000-0000-7000-8000-0000000071d2', 'Coleccion de 3 libros t71', 3) $$), 'ok', 'otro tamaño es otra colección');
select is(pg_temp.error_de($$ update public.coleccion set libros_a_elegir = -2
      where id = '01920000-0000-7000-8000-0000000071d1' $$), '23514', 'bajarla de 2 a -2 también se rechaza');
select is(pg_temp.error_de($$ update public.coleccion set libros_a_elegir = 0
      where id = '01920000-0000-7000-8000-0000000071d2' $$), 'ok', 'y 0 vale: una colección que se vuelve fija');
select is(pg_temp.error_de($$ update public.coleccion set libros_a_elegir = 3
      where id = '01920000-0000-7000-8000-0000000071d2' $$), 'ok', 'y cambiarla de tamaño');
select is((select sync.expresion_json('public.coleccion'::regclass) like '%''libros_a_elegir''%'), true,
          'el pull de coleccion la serializa');

select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq(
  $$ select tipo, nombre, libros_a_elegir
       from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000071f1')
      where nombre like '%t71' order by tipo, nombre $$,
  $$ values ('COLECCION'::text, 'Coleccion de 2 libros t71'::text, 2),
            ('COLECCION', 'Coleccion de 3 libros t71', 3),
            ('COLECCION', 'Pack Familiar t71', 0),
            ('PRODUCTO', 'Libro 1 t71', null),
            ('PRODUCTO', 'Libro 3 t71', null),
            ('PRODUCTO', 'Revista 2 t71', null) $$,
  'precios_de_la_ciudad trae libros_a_elegir: el de cada colección y null en un producto');
select results_eq(
  $$ select precio_general, precio_modificado, precio_vigente, origen
       from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000071f1')
      where id = '01920000-0000-7000-8000-0000000071d1' $$,
  $$ values (90000, null::integer, 90000, 'GENERAL'::text) $$,
  'y el precio de la «Colección de 2 libros» es el de cualquier combo: su general');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 2. La forma de componentes, caso por caso
-- ---------------------------------------------------------------------------
select is(public.componentes_de_venta_validos(v.j::jsonb), v.esperado, v.caso)
from (values
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]', true, 'un componente'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007112", "cantidad": 2}]', true, 'lo fijo: 1 libro y 2 revistas'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007113", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007113", "cantidad": 1}]', true, 'lo elegido puede repetirse en dos elementos'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007113", "cantidad": 2}]', true, 'o en uno solo con cantidad 2'),
  ('[{"cantidad": 999999999, "producto_id": "01920000-0000-7000-8000-000000007113"}]', true, 'el orden de las claves no importa y 999999999 es el tope'),
  ('[{"producto_id": "01920000-0000-7000-8000-00000000AB13", "cantidad": 1}]', true, 'el uuid en mayúsculas vale'),
  (null, false, 'null (sin lista)'),
  ('null', false, 'el JSON null'),
  ('{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}', false, 'un objeto suelto en vez de una lista'),
  ('"x"', false, 'un texto'),
  ('7', false, 'un número'),
  ('[]', false, 'la lista vacía: un combo siempre trae algo'),
  ('[1]', false, 'un elemento que no es objeto (número)'),
  ('["x"]', false, 'un elemento que no es objeto (texto)'),
  ('[[]]', false, 'un elemento que no es objeto (lista)'),
  ('[null]', false, 'un elemento null'),
  ('[{}]', false, 'un objeto vacío'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111"}]', false, 'sin cantidad'),
  ('[{"cantidad": 1}]', false, 'sin producto_id'),
  ('[{"cantidad": 1, "nombre": "x"}]', false, 'sin producto_id aunque haya otra clave (dos claves no alcanzan)'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "nombre": "x"}]', false, 'sin cantidad aunque haya otra clave'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1, "nombre": "x"}]', false, 'una clave de más'),
  ('[{"producto_id": 5, "cantidad": 1}]', false, 'producto_id que no es texto'),
  ('[{"producto_id": null, "cantidad": 1}]', false, 'producto_id null'),
  ('[{"producto_id": "abc", "cantidad": 1}]', false, 'producto_id que no es un uuid'),
  ('[{"producto_id": "01920000000070008000000000007111", "cantidad": 1}]', false, 'un uuid sin guiones'),
  ('[{"producto_id": "{01920000-0000-7000-8000-000000007111}", "cantidad": 1}]', false, 'un uuid entre llaves'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111 ", "cantidad": 1}]', false, 'un uuid con espacio al final'),
  ('[{"producto_id": "x01920000-0000-7000-8000-000000007111", "cantidad": 1}]', false, 'un uuid con basura al principio'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 0}]', false, 'cantidad 0'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": -1}]', false, 'cantidad negativa'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1.5}]', false, 'cantidad con decimales'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 2.0}]', false, 'cantidad 2.0 (el teléfono manda enteros)'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1e2}]', true, 'cantidad 1e2: jsonb la guarda como 100, un entero'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": "2"}]', false, 'cantidad como texto'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": true}]', false, 'cantidad booleana'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": null}]', false, 'cantidad null'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1000000000}]', false, 'cantidad de más de 999999999'),
  ('[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "x", "cantidad": 1}]', false, 'uno bueno y uno malo: se rechaza todo')
) v(j, esperado, caso);

-- ---------------------------------------------------------------------------
-- 3. venta_item.componentes en la tabla
-- ---------------------------------------------------------------------------
select has_column('public', 'venta_item', 'componentes', 'venta_item tiene componentes');
select col_type_is('public', 'venta_item', 'componentes', 'jsonb', 'componentes es jsonb');
select col_is_null('public', 'venta_item', 'componentes', 'es opcional: un producto suelto no lo lleva');
select col_hasnt_default('public', 'venta_item', 'componentes', 'y no tiene default');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.venta_item'::regclass and conname = 'venta_item_componentes_solo_en_combo'),
          'CHECK (((coleccion_id IS NULL) = (componentes IS NULL)))',
          'obligatorio en un combo y nulo en un producto suelto');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.venta_item'::regclass and conname = 'venta_item_componentes_forma'),
          'CHECK (((componentes IS NULL) OR componentes_de_venta_validos(componentes)))',
          'y con la forma de componentes_de_venta_validos');
select is((select bool_and(convalidated) from pg_constraint
            where conrelid = 'public.venta_item'::regclass
              and conname in ('venta_item_componentes_solo_en_combo', 'venta_item_componentes_forma')),
          true, 'las dos están validadas (en una base sin ítems de combo viejos sin componentes)');
select is('componentes' = any (sync.columnas_escribibles('venta_item')), true, 'componentes es una columna que el teléfono puede escribir');
select is('motivo_monto_manual' = any (sync.columnas_escribibles('venta')), true, 'y motivo_monto_manual, en venta');
select is((select sync.expresion_json('public.venta_item'::regclass) like '%''componentes''%'), true, 'el pull de venta_item la serializa');
select is((select sync.expresion_json('public.venta'::regclass) like '%''motivo_monto_manual''%'), true, 'y el de venta, el motivo');

-- Las ventas de b1 y b2 (como postgres: el dueño va explícito).
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  (pg_temp.u('b0'), pg_temp.u('ca'), 'T-71', 220000, now(), pg_temp.u('b1'));

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b1', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 2, 110000, 220000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007112", "cantidad": 2}]') $$),
          'ok', 'el colportor vende dos Pack Familiar: el ítem copia lo que traía UNO (1 libro y 2 revistas)');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b2', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d1', 1, 90000, 90000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]') $$),
          'ok', 'la «Colección de 2 libros» con el mismo libro elegido dos veces (dos elementos)');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b3', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d1', 1, 90000, 90000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007113", "cantidad": 2}]') $$),
          'ok', 'o con un elemento de cantidad 2');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-0000000071b4', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-000000007111', 1, 24000, 24000) $$),
          'ok', 'un libro suelto sigue entrando sin componentes');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000) $$),
          '23514', 'un combo SIN componentes: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-000000007111', 1, 24000, 24000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]') $$),
          '23514', 'un producto suelto CON componentes: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000, '[]') $$),
          '23514', 'un combo con la lista vacía: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 0}]') $$),
          '23514', 'un combo con cantidad 0 en un componente: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000, '{"producto_id": "x"}') $$),
          '23514', 'un combo con componentes que no son una lista: rechazado');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000, 'null'::jsonb) $$),
          '23514', 'un combo con el JSON null en componentes: rechazado (no es lo mismo que sin valor)');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-000000007111', 1, 24000, 24000, 'null'::jsonb) $$),
          '23514', 'y un producto suelto con el JSON null tampoco (no es null de SQL)');
-- Las dos reglas del combo siguen donde estaban.
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 2, 110000, 999,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]') $$),
          '23514', 'el subtotal que no cuadra se rechaza igual');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071ee', 1, 1000, 1000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]') $$),
          '23503', 'una colección que no existe sigue siendo 23503');
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b5', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000,
             '[{"producto_id": "01920000-0000-7000-8000-0000000071ee", "cantidad": 1}]') $$),
          'ok', 'un producto del combo que no existe en el catálogo NO se rechaza: la venta no mira el catálogo');
-- Lo guardado es lo mandado, con el orden.
select is((select componentes from public.venta_item where id = pg_temp.u('b1')),
          '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007112", "cantidad": 2}]'::jsonb,
          'el ítem guarda lo que trajo el combo, en el orden que lo mandó el teléfono');
-- UPDATE: el teléfono manda la fila entera.
select is(pg_temp.error_de($$ update public.venta_item set componentes = null
      where id = '01920000-0000-7000-8000-0000000071b1' $$), '23514', 'borrar los componentes de un ítem de combo: rechazado');
select is(pg_temp.error_de($$ update public.venta_item set componentes = '[]'
      where id = '01920000-0000-7000-8000-0000000071b1' $$), '23514', 'dejarlos vacíos también');
select is(pg_temp.error_de($$ update public.venta_item set componentes = '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 3}]'
      where id = '01920000-0000-7000-8000-0000000071b1' $$), 'ok', 'corregirlos (una venta se corrige) vale');
select is(pg_temp.error_de($$ update public.venta_item set componentes = '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]'
      where id = '01920000-0000-7000-8000-0000000071b4' $$), '23514', 'ponérselos a un producto suelto: rechazado');
select is(pg_temp.error_de($$ update public.venta_item set producto_id = '01920000-0000-7000-8000-000000007111', coleccion_id = null
      where id = '01920000-0000-7000-8000-0000000071b1' $$), '23514', 'convertir el combo en producto sin quitarle los componentes: rechazado');
select is(pg_temp.error_de($$ update public.venta_item set cantidad = 3, subtotal = 330000
      where id = '01920000-0000-7000-8000-0000000071b1' $$), 'ok', 'cambiar solo la cantidad del combo no pide tocar los componentes');
select is((select componentes from public.venta_item where id = pg_temp.u('b1')),
          '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 3}]'::jsonb,
          'y los componentes corregidos quedaron');
-- Otro colportor no agrega un combo a la venta de b1 (el permiso es el de siempre).
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-0000000071b6', '01920000-0000-7000-8000-0000000071b0',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]') $$),
          '42501', 'b2 no agrega un combo a la venta de b1');
select is((select count(*)::int from public.venta_item), 0, 'y b2 no ve los componentes de b1');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3b. Por el sync, que es el camino real
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('c1', 'venta', pg_temp.payload_venta('b3', 'T-72', now())),
    pg_temp.job('c2', 'venta_item', pg_temp.payload_item('b7', 'b3', null, 'd0', pg_temp.pack())),
    pg_temp.job('c3', 'venta_item', pg_temp.payload_item('b8', 'b3', null, 'd1',
      jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1),
                        jsonb_build_object('producto_id', pg_temp.u('13'), 'cantidad', 1)))),
    pg_temp.job('c4', 'venta_item', pg_temp.payload_item('b9', 'b3', '11', null, null)))) as r;
grant select on r_push to authenticated;
select is(pg_temp.resultados((select r from r_push)), array['accepted', 'accepted', 'accepted', 'accepted'],
          'push: la venta, el Pack Familiar, la «Colección de 2 libros» con sus libros elegidos y un libro suelto entran');
select results_eq(
  $$ select coleccion_id is not null, componentes from public.venta_item
      where venta_id = '01920000-0000-7000-8000-0000000071b3' order by id $$,
  $$ values (true, '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007112", "cantidad": 2}]'::jsonb),
            (true, '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007113", "cantidad": 1}]'::jsonb),
            (false, null::jsonb) $$,
  'cada ítem quedó con lo que mandó el teléfono: la lista del combo, los libros elegidos y nada en el suelto');
create temp table r_push2 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('c2', 'venta_item', pg_temp.payload_item('b7', 'b3', null, 'd0', pg_temp.pack())))) as r;
grant select on r_push2 to authenticated;
select is(pg_temp.resultados((select r from r_push2)), array['duplicate'], 'el reintento del mismo ítem es idempotente (duplicate)');
create temp table r_push3 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('d1', 'venta_item', pg_temp.payload_item('ba', 'b3', null, 'd0', null)),
    pg_temp.job('d2', 'venta_item', pg_temp.payload_item('bb', 'b3', '11', null, pg_temp.pack())),
    pg_temp.job('d3', 'venta_item', pg_temp.payload_item('bc', 'b3', null, 'd0', '[]'::jsonb)),
    pg_temp.job('d4', 'venta_item', pg_temp.payload_item('bd', 'b3', null, 'd0',
      '[{"producto_id": "no-es-un-uuid", "cantidad": 1}]'::jsonb)),
    pg_temp.job('d5', 'venta_item', pg_temp.payload_item('be', 'b3', null, 'd0',
      '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1.5}]'::jsonb)),
    pg_temp.job('d6', 'venta_item', pg_temp.payload_item('bf', 'b3', null, 'd1', pg_temp.pack())))) as r;
grant select on r_push3 to authenticated;
select is(pg_temp.resultados((select r from r_push3)),
          array['invalid', 'invalid', 'invalid', 'invalid', 'invalid', 'accepted'],
          'push: el combo sin componentes, el suelto con componentes, la lista vacía y las dos formas malas vuelven invalid y el lote sigue');
select is(pg_temp.codigos((select r from r_push3)), array['23514', '23514', '23514', '23514', '23514', '-'],
          'cada uno con 23514');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta_item where venta_id = pg_temp.u('b3')), 4,
          'la venta del push quedó con sus 4 ítems buenos (los rechazados no dejaron nada)');

-- ---------------------------------------------------------------------------
-- 4. «Monto manual»: venta.motivo_monto_manual
-- ---------------------------------------------------------------------------
select has_column('public', 'venta', 'motivo_monto_manual', 'venta tiene motivo_monto_manual');
select col_type_is('public', 'venta', 'motivo_monto_manual', 'text', 'es text');
select col_is_null('public', 'venta', 'motivo_monto_manual', 'es opcional');
select col_hasnt_default('public', 'venta', 'motivo_monto_manual', 'y no tiene default');
select is((select pg_get_constraintdef(oid) from pg_constraint
            where conrelid = 'public.venta'::regclass and conname = 'venta_motivo_monto_manual_forma'),
          'CHECK (((motivo_monto_manual IS NULL) OR ((motivo_monto_manual ~ ''^\S(.*\S)?$''::text) AND (char_length(motivo_monto_manual) <= 500))))',
          'null, o un texto sin espacios en los extremos de hasta 500 caracteres');

create or replace function pg_temp.venta_con_motivo(p_n text, p_motivo text) returns text language plpgsql as $$
begin
  insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, motivo_monto_manual)
  values (pg_temp.u('e' || p_n), pg_temp.u('ca'), 'M-' || p_n, 85000, now(), pg_temp.u('b1'), p_motivo);
  return 'ok';
exception when others then
  return sqlstate;
end $$;

select is(v.r, v.esperado, v.caso)
from (values
  ('0', pg_temp.venta_con_motivo('0', null), 'ok', 'sin motivo (null): la venta de siempre'),
  ('1', pg_temp.venta_con_motivo('1', 'descuento por pago en efectivo'), 'ok', 'el motivo de Ana'),
  ('2', pg_temp.venta_con_motivo('2', 'a'), 'ok', 'una letra'),
  ('3', pg_temp.venta_con_motivo('3', repeat('a', 500)), 'ok', '500 caracteres'),
  ('4', pg_temp.venta_con_motivo('4', repeat('a', 501)), '23514', '501 caracteres: pasa el tope'),
  ('5', pg_temp.venta_con_motivo('5', repeat('ñ', 500)), 'ok', '500 caracteres de 2 bytes: se cuentan caracteres y no bytes'),
  ('6', pg_temp.venta_con_motivo('6', repeat('ñ', 501)), '23514', '501 caracteres de 2 bytes'),
  ('7', pg_temp.venta_con_motivo('7', 'rebaja' || E'\n' || 'por pago al contado'), 'ok', 'un salto de línea adentro vale'),
  ('8', pg_temp.venta_con_motivo('8', ' descuento'), '23514', 'espacio al principio'),
  ('9', pg_temp.venta_con_motivo('9', 'descuento '), '23514', 'espacio al final'),
  ('a', pg_temp.venta_con_motivo('a', 'descuento' || E'\n'), '23514', 'salto de línea al final'),
  ('b', pg_temp.venta_con_motivo('b', E'\t' || 'descuento'), '23514', 'tabulación al principio'),
  ('c', pg_temp.venta_con_motivo('c', ''), '23514', 'vacío: se manda null y no un texto vacío'),
  ('d', pg_temp.venta_con_motivo('d', '   '), '23514', 'solo espacios'),
  ('f', pg_temp.venta_con_motivo('f', E'\n'), '23514', 'solo un salto de línea')
) v(n, r, esperado, caso);
select is((select motivo_monto_manual from public.venta where id = pg_temp.u('e1')), 'descuento por pago en efectivo',
          'el motivo se guarda tal cual');
select is((select count(*)::int from public.venta where id::text like '01920000-0000-7000-8000-0000000071e%'), 6,
          'las ventas rechazadas no dejaron nada: quedan las 6 buenas');

-- El dueño la corrige; el motivo viaja con la venta.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.venta set motivo_monto_manual = 'cambio de precio acordado'
      where id = '01920000-0000-7000-8000-0000000071e0' $$), 'ok', 'el colportor agrega el motivo después');
select is(pg_temp.error_de($$ update public.venta set motivo_monto_manual = repeat('x', 501)
      where id = '01920000-0000-7000-8000-0000000071e0' $$), '23514', 'y el tope rige también en el UPDATE');
select is(pg_temp.error_de($$ update public.venta set motivo_monto_manual = null
      where id = '01920000-0000-7000-8000-0000000071e1' $$), 'ok', 'o lo borra');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select count(*)::int from public.venta), 0, 'otro colportor no lee la venta de b1 ni su motivo');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_push4 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('e1', 'venta', pg_temp.payload_venta('c1', 'T-73', now(), 'descuento por pago en efectivo')),
    pg_temp.job('e2', 'venta', pg_temp.payload_venta('c2', 'T-74', now(), repeat('a', 501))),
    pg_temp.job('e3', 'venta', pg_temp.payload_venta('c3', 'T-75', now(), ' con espacio')),
    pg_temp.job('e4', 'venta', pg_temp.payload_venta('c4', 'T-76', now())))) as r;
grant select on r_push4 to authenticated;
select is(pg_temp.resultados((select r from r_push4)), array['accepted', 'invalid', 'invalid', 'accepted'],
          'push: el motivo bueno y la venta sin motivo entran; el de 501 y el que empieza con espacio vuelven invalid');
select is(pg_temp.codigos((select r from r_push4)), array['-', '23514', '23514', '-'], 'los rechazados con 23514');
select pg_temp.actuar_como_servidor();
select is((select motivo_monto_manual from public.venta where id = pg_temp.u('c1')), 'descuento por pago en efectivo',
          'la venta del push guardó el motivo');
select is((select motivo_monto_manual from public.venta where id = pg_temp.u('c4')), null, 'y la otra quedó sin motivo');
select is((select count(*)::int from public.venta where id in (pg_temp.u('c2'), pg_temp.u('c3'))), 0,
          'las rechazadas no dejaron nada');

-- ---------------------------------------------------------------------------
-- 5. «Talonario por año»
-- ---------------------------------------------------------------------------
select hasnt_index('public', 'venta', 'venta_talonario_por_colportor_idx', 'el índice viejo (sin año) ya no está');
select has_index('public', 'venta', 'venta_talonario_por_colportor_y_anio_idx', 'el índice por año está');
select is((select indisunique from pg_index where indexrelid = 'public.venta_talonario_por_colportor_y_anio_idx'::regclass),
          true, 'es único');
select is((select pg_get_expr(indpred, indrelid) from pg_index
            where indexrelid = 'public.venta_talonario_por_colportor_y_anio_idx'::regclass),
          '(deleted_at IS NULL)', 'y solo de las ventas vivas');
select is((select regexp_replace(pg_get_indexdef(indexrelid), '^.* USING ', '') from pg_index
            where indexrelid = 'public.venta_talonario_por_colportor_y_anio_idx'::regclass),
          'btree (colportor_id, numero_talonario, anio_de_la_venta(fecha)) WHERE (deleted_at IS NULL)',
          'por colportor, número y año de la fecha de la venta');

select is(public.anio_de_la_venta('2026-06-15 12:00:00+00'), 2026, 'el año de una fecha cualquiera');
select is(public.anio_de_la_venta('2027-01-01 02:30:00+00'), 2026, 'el 01/01 a las 02:30 UTC todavía es 2026 en Uruguay (-03)');
select is(public.anio_de_la_venta('2027-01-01 03:00:00+00'), 2027, 'y a las 03:00 UTC ya es 2027');
select is(public.anio_de_la_venta('2026-12-31 22:30:00-03'), 2026, 'el 31/12 a las 22:30 de Uruguay es 2026 (aunque en UTC ya sea 2027)');
select is(public.anio_de_la_venta('2027-01-01 00:00:00-03'), 2027, 'y la medianoche de Uruguay es 2027');
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(public.anio_de_la_venta('2026-12-31 22:30:00-03'), 2026, 'con la sesión en Kiritimati (+14) sigue siendo el año de Uruguay');
select set_config('TimeZone', 'Etc/GMT+12', true);
select is(public.anio_de_la_venta('2027-01-01 00:00:00-03'), 2027, 'y con la sesión en GMT-12 también');
select set_config('TimeZone', 'UTC', true);
select is((select provolatile from pg_proc where oid = 'public.anio_de_la_venta(timestamptz)'::regprocedure), 'i',
          'es IMMUTABLE (la usa un índice)');
select is((select provolatile from pg_proc where oid = 'public.componentes_de_venta_validos(jsonb)'::regprocedure), 'i',
          'y componentes_de_venta_validos también (la usa un CHECK)');

-- Las ventas de prueba van con la fecha explícita. T-1 de b1 en 2026 y de nuevo T-1 de b1 en 2026: 23505.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  (pg_temp.u('01'), pg_temp.u('ca'), 'T-1', 10000, '2026-03-12 15:00:00+00', pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f2', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2026-11-02 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          '23505', 'el mismo talonario del mismo colportor en el mismo año: rechazado');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f2', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2027-03-12 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          'ok', 'el mismo número el año siguiente: vale (una venta real del 2027 no se rechaza)');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f3', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2025-03-12 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          'ok', 'y el año anterior también');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f4', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2026-03-12 15:00:00+00', '01920000-0000-7000-8000-0000000071b2') $$),
          'ok', 'otro colportor puede usar el mismo número el mismo año');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f5', '01920000-0000-7000-8000-0000000071ca', 'T-2', 10000,
             '2026-03-12 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          'ok', 'otro número, el mismo año y colportor: vale');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f6', '01920000-0000-7000-8000-0000000071ca', 't-1', 10000,
             '2026-03-12 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          'ok', 'el número se compara tal cual (T-1 y t-1 son distintos: la normalización es del teléfono)');

-- El borde del año es el de Uruguay, no el de UTC.
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  (pg_temp.u('02'), pg_temp.u('ca'), 'B-1', 10000, '2028-12-31 22:30:00-03', pg_temp.u('b1'));  -- 2028 en Uruguay, 2029 en UTC
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f7', '01920000-0000-7000-8000-0000000071ca', 'B-1', 10000,
             '2029-01-01 00:30:00-03', '01920000-0000-7000-8000-0000000071b1') $$),
          'ok', 'el 31/12 a las 22:30 y el 01/01 a las 00:30 de Uruguay son años distintos aunque los dos sean 2029 en UTC');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f8', '01920000-0000-7000-8000-0000000071ca', 'B-1', 10000,
             '2028-12-31 12:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          '23505', 'y el 31/12 a las 12:00 UTC (09:00 de Uruguay) es el mismo año 2028 que el de las 22:30: rechazado');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  (pg_temp.u('03'), pg_temp.u('ca'), 'B-2', 10000, '2030-01-01 01:30:00+00', pg_temp.u('b1'));  -- 2029 en Uruguay, 2030 en UTC
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071f9', '01920000-0000-7000-8000-0000000071ca', 'B-2', 10000,
             '2029-12-31 12:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          '23505', 'una venta de las 22:30 del 31/12 de Uruguay (01:30 UTC del 01/01) cuenta para el año que termina');
select set_config('TimeZone', 'Pacific/Kiritimati', true);
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071fa', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2026-05-05 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          '23505', 'con la sesión en otra zona horaria el duplicado del año se rechaza igual');
select set_config('TimeZone', 'UTC', true);

-- La baja lógica libera el número del año.
update public.venta set deleted_at = now() where id = pg_temp.u('01');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071fb', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2026-03-12 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          'ok', 'una venta dada de baja libera su número de talonario del año');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-0000000071fc', '01920000-0000-7000-8000-0000000071ca', 'T-1', 10000,
             '2026-03-13 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$),
          '23505', 'pero el nuevo ya lo ocupa');
-- Cambiar la fecha de una venta a otro año se puede; a un año ocupado, no.
select is(pg_temp.error_de($$ update public.venta set fecha = '2031-03-13 15:00:00+00'
      where id = '01920000-0000-7000-8000-0000000071fb' $$), 'ok', 'corregir la fecha a un año libre vale');
select is(pg_temp.error_de($$ update public.venta set fecha = '2027-03-13 15:00:00+00'
      where id = '01920000-0000-7000-8000-0000000071fb' $$), '23505', 'y a un año donde ya está ese número, no');

-- Como colportor (el índice evalúa la función con el rol de la sesión) y por el push.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha)
     values ('01920000-0000-7000-8000-0000000071fd', '01920000-0000-7000-8000-0000000071ca', 'AUTH-1', 10000, now()) $$),
          'ok', 'el colportor inserta su venta con el índice nuevo (tiene EXECUTE sobre anio_de_la_venta)');
select is(pg_temp.error_de($$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha)
     values ('01920000-0000-7000-8000-0000000071fe', '01920000-0000-7000-8000-0000000071ca', 'AUTH-1', 10000, now()) $$),
          '23505', 'y el segundo con el mismo número y año es rechazado');
create temp table r_push5 on commit drop as
  select pg_temp.push(jsonb_build_array(
    pg_temp.job('f1', 'venta', pg_temp.payload_venta('d1', 'PUSH-1', '2026-02-02 15:00:00+00')),
    pg_temp.job('f2', 'venta', pg_temp.payload_venta('d2', 'PUSH-1', '2026-09-09 15:00:00+00')),
    pg_temp.job('f3', 'venta', pg_temp.payload_venta('d3', 'PUSH-1', '2027-02-02 15:00:00+00')),
    pg_temp.job('f4', 'venta', pg_temp.payload_venta('d4', 'PUSH-2', '2026-02-02 15:00:00+00')))) as r;
grant select on r_push5 to authenticated;
select is(pg_temp.resultados((select r from r_push5)), array['accepted', 'invalid', 'accepted', 'accepted'],
          'push: el talonario repetido del mismo año vuelve invalid y el lote sigue; el del año siguiente entra');
select is(pg_temp.codigos((select r from r_push5)), array['-', '23505', '-', '-'], 'con 23505');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.venta where numero_talonario = 'PUSH-1'), 2,
          'quedaron las dos ventas buenas del PUSH-1 (2026 y 2027)');

-- ---------------------------------------------------------------------------
-- 6. Privilegios de las funciones nuevas
-- ---------------------------------------------------------------------------
select is(has_function_privilege('anon', 'public.anio_de_la_venta(timestamptz)', 'execute'), false, 'anio_de_la_venta: anon no ejecuta');
select is(has_function_privilege('authenticated', 'public.anio_de_la_venta(timestamptz)', 'execute'), true, 'authenticated sí (el índice la evalúa con su rol)');
select is(has_function_privilege('service_role', 'public.anio_de_la_venta(timestamptz)', 'execute'), true, 'service_role también');
select is(has_function_privilege('anon', 'public.componentes_de_venta_validos(jsonb)', 'execute'), false, 'componentes_de_venta_validos: anon no ejecuta');
select is(has_function_privilege('authenticated', 'public.componentes_de_venta_validos(jsonb)', 'execute'), true, 'authenticated sí (el CHECK la evalúa con su rol)');
select is(has_function_privilege('service_role', 'public.componentes_de_venta_validos(jsonb)', 'execute'), true, 'service_role también');
select is((select prosecdef from pg_proc where oid = 'public.componentes_de_venta_validos(jsonb)'::regprocedure), false,
          'es INVOKER: no hace falta más');
select is((select prosecdef from pg_proc where oid = 'public.anio_de_la_venta(timestamptz)'::regprocedure), false, 'anio_de_la_venta también');

select * from finish();
rollback;
