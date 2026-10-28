-- pgTAP · migración 0108 (backend-supabase#134): la tabla devolucion sube al servidor.
--   1. La forma: columnas, tipos, defaults, los CHECK, los índices (el delta con el dueño primero), los
--      triggers, la RLS, los privilegios y el registro en sync.entidad.
--   2. productos_devueltos_validos(): lo que es un arreglo de {producto_id, cantidad} y lo que no.
--   3. Las restricciones, con el SQLSTATE que el motor devuelve como `invalid`.
--   4. La RLS contra la tabla: la escribe solo la colportora dueña, y sobre una venta suya; la lee ella, el
--      ADMIN y el coordinador de su campaña (0141); sin DELETE.
--   5. Por sync.push: idempotente por client_op_id, el dueño sale del JWT y no del payload, lo que llega
--      mal vuelve `invalid` con su código y lo ajeno no se toca.
-- El pull (reinstalar) está en 0108_devolucion_pull_test.sql: el delta solo sirve filas commiteadas.
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
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- Ids (prefijo 81): usuarios 81b1.., productos 8111.., ventas 8171.., devoluciones 81d1..; los client_op_id,
-- 81 y dos dígitos (los otros llevan una letra, no se pisan).
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '81' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000081' || p)::uuid;
$$;

-- «sqlstate restricción», u «ok», de lo que hace una sentencia (la excepción no deja la transacción rota).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
declare
  v_restriccion text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_restriccion = constraint_name;
  return sqlstate || ' ' || coalesce(v_restriccion, '');
end $$;

-- Cuántas filas tocó una sentencia de escritura.
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare
  v_n integer;
begin
  execute p_sql;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- El arreglo de productos tal como lo manda el teléfono.
create or replace function pg_temp.items(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', pg_temp.u(x.p), 'cantidad', x.n))
    from (select p[i] as p, p[i + 1]::int as n from generate_series(1, array_length(p, 1), 2) i) x;
$$;

-- Lo mismo con el renglón de la venta (0136): tres claves. ren() son los renglones de la venta 71; ren72(), los de la 72.
create or replace function pg_temp.ren(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', pg_temp.u(x.p), 'cantidad', x.n,
                                      'venta_item_id', pg_temp.u(case x.p when '11' then '81' when '12' then '82'
                                                                           when '13' then '83' else '8f' end)))
    from (select p[i] as p, p[i + 1]::int as n from generate_series(1, array_length(p, 1), 2) i) x;
$$;
create or replace function pg_temp.ren72(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', pg_temp.u(x.p), 'cantidad', x.n,
                                      'venta_item_id', pg_temp.u(case x.p when '11' then '84' when '12' then '85'
                                                                           when '13' then '86' else '8f' end)))
    from (select p[i] as p, p[i + 1]::int as n from generate_series(1, array_length(p, 1), 2) i) x;
$$;

-- El payload de una devolución tal como lo manda el teléfono.
create or replace function pg_temp.dev(p_id uuid, p_venta uuid, p_items jsonb default null)
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'venta_id', p_venta,
                            'productos_devueltos', coalesce(p_items, pg_temp.ren('11', '1')),
                            'dinero_retenido', 0, 'fecha_devolucion', '2026-10-05T12:00:00Z');
$$;
-- Un job de push de la entidad; devuelve el resultado.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'devolucion', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Colportoras b1 y b2, un coordinador y un ADMIN. Productos 11, 12 y 13. Una venta de b1 (71) y una de b2 (72).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev81-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 t81', 'LIBRO'),
  (pg_temp.u('12'), 'Libro 2 t81', 'LIBRO'),
  (pg_temp.u('13'), 'Revista 3 t81', 'REVISTA');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev81', 'ZR');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev81', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('e2'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e1'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e2'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-8171', 450000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-8172', 260000, '2026-10-01 16:00:00+00', pg_temp.u('b2'), pg_temp.u('b2'));

-- Cantidades holgadas: lo que se devuelve no pasa del tope del renglón (0142).
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  (pg_temp.u('81'), pg_temp.u('71'), pg_temp.u('11'), 30, 100000, 3000000),
  (pg_temp.u('82'), pg_temp.u('71'), pg_temp.u('12'), 30, 50000, 1500000),
  (pg_temp.u('83'), pg_temp.u('71'), pg_temp.u('13'), 30, 20000, 600000),
  (pg_temp.u('84'), pg_temp.u('72'), pg_temp.u('11'), 30, 100000, 3000000),
  (pg_temp.u('85'), pg_temp.u('72'), pg_temp.u('12'), 30, 50000, 1500000),
  (pg_temp.u('86'), pg_temp.u('72'), pg_temp.u('13'), 30, 20000, 600000);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_table('public', 'devolucion', 'existe la tabla');
select columns_are('public', 'devolucion',
  array['id', 'venta_id', 'productos_devueltos', 'dinero_retenido', 'monto_reembolsado', 'fecha_devolucion',
        'colportor_id', 'created_at', 'updated_at', 'created_by', 'deleted_at', 'sync_version', 'xmin_w', 'motivo'],
  'las columnas: la devolución, la plata, el motivo (0136, opcional y acotado) y las de siempre');
select col_is_pk('public', 'devolucion', 'id', 'la clave es un uuid');
select col_type_is('public', 'devolucion', 'productos_devueltos', 'jsonb', 'productos_devueltos es jsonb (ADR-002)');
select col_not_null('public', 'devolucion', 'productos_devueltos', 'y es obligatorio');
select col_type_is('public', 'devolucion', 'dinero_retenido', 'integer', 'dinero_retenido en centavos (integer, como monto_total)');
select col_not_null('public', 'devolucion', 'dinero_retenido', 'dinero_retenido es obligatorio');
select col_default_is('public', 'devolucion', 'dinero_retenido', '0', 'y vale 0 si no retiene nada');
select col_type_is('public', 'devolucion', 'monto_reembolsado', 'integer', 'monto_reembolsado en centavos');
select col_is_null('public', 'devolucion', 'monto_reembolsado', 'monto_reembolsado es opcional: la mayoría no devuelve plata');
select col_hasnt_default('public', 'devolucion', 'monto_reembolsado', 'y sin default');
select col_type_is('public', 'devolucion', 'fecha_devolucion', 'timestamp with time zone', 'fecha_devolucion timestamptz');
select col_not_null('public', 'devolucion', 'fecha_devolucion', 'fecha_devolucion es obligatoria (la fecha va del teléfono)');
select col_hasnt_default('public', 'devolucion', 'fecha_devolucion', 'y sin default: el servidor no la inventa');
select col_not_null('public', 'devolucion', 'venta_id', 'venta_id es obligatoria');
select fk_ok('public', 'devolucion', 'venta_id', 'public', 'venta', 'id', 'cuelga de la venta');
select col_not_null('public', 'devolucion', 'colportor_id', 'colportor_id es obligatoria');
select col_has_default('public', 'devolucion', 'colportor_id', 'colportor_id se fija desde el JWT (default auth.uid())');
select fk_ok('public', 'devolucion', 'colportor_id', 'public', 'usuario', 'id', 'colportor_id cuelga de usuario');
select col_type_is('public', 'devolucion', 'xmin_w', 'xid8', 'xmin_w xid8, como todas');
select is((select count(*)::int from pg_constraint
            where conrelid = 'public.devolucion'::regclass and contype = 'c'
              and conname in ('devolucion_productos_validos', 'devolucion_dinero_retenido_no_negativo',
                              'devolucion_monto_reembolsado_no_negativo')), 3, 'los tres CHECK están');
select has_index('public', 'devolucion', 'devolucion_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'el delta: el dueño primero, para que entre en el Index Cond');
select has_index('public', 'devolucion', 'devolucion_venta_idx', array['venta_id'], 'índice por la venta (la FK)');
select has_trigger('public', 'devolucion', 'devolucion_auditoria_insert', 'auditoría al insertar');
select has_trigger('public', 'devolucion', 'devolucion_auditoria_update', 'auditoría al modificar');
select has_trigger('public', 'devolucion', 'devolucion_productos', 'y el que mira que cada producto exista');
select ok((select relrowsecurity from pg_class where oid = 'public.devolucion'::regclass), 'RLS habilitada');
select is(
  (select array_agg(p.policyname || ' ' || p.cmd || ' {' || array_to_string(p.roles, ',') || '}' order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'devolucion'),
  array['devolucion_insert_propia INSERT {authenticated}',
        'devolucion_select_coordinacion SELECT {authenticated}',
        'devolucion_select_propia SELECT {authenticated}',
        'devolucion_update_propia UPDATE {authenticated}'],
  'cuatro políticas (la de la coordinación es de 0141), solo para authenticated, y ninguna de DELETE');
-- USING = lo que ve; WITH CHECK = lo que escribe (0021). Cada una se mide contra el dueño; las de escritura,
-- además, contra el dueño de la venta.
select ok((select coalesce(p.qual, '') like '%colportor_id%auth.uid()%' from pg_policies p
            where p.policyname = 'devolucion_select_propia'),
          'SELECT: lo que ve (USING) se mide contra el dueño');
select ok((select coalesce(p.qual, '') like '%colportor_id%auth.uid()%' from pg_policies p
            where p.policyname = 'devolucion_update_propia'),
          'UPDATE: lo que ve (USING) se mide contra el dueño');
select ok((select coalesce(p.with_check, '') like '%colportor_id%auth.uid()%venta%colportor_id%auth.uid()%' from pg_policies p
            where p.policyname = 'devolucion_update_propia'),
          'UPDATE: lo que escribe (WITH CHECK) se mide contra el dueño y contra la venta');
select ok((select coalesce(p.with_check, '') like '%colportor_id%auth.uid()%venta%colportor_id%auth.uid()%' from pg_policies p
            where p.policyname = 'devolucion_insert_propia'),
          'INSERT: lo que escribe (WITH CHECK) se mide contra el dueño y contra la venta');
select ok((select bool_and(coalesce(p.qual, '') || coalesce(p.with_check, '') ~* '\(\s*select auth\.uid\(\)')
             from pg_policies p where p.schemaname = 'public' and p.tablename = 'devolucion'
              and p.policyname <> 'devolucion_select_coordinacion'),
          'auth.uid() va envuelta en (select …): se evalúa una vez por consulta, no por fila');
select table_privs_are('public', 'devolucion', 'authenticated', array['SELECT', 'INSERT', 'UPDATE'],
                       'authenticated: select, insert y update; nunca delete');
select table_privs_are('public', 'devolucion', 'anon', array[]::text[], 'anon no tiene nada');
select is((select count(*)::int from information_schema.role_table_grants
            where table_schema = 'public' and table_name = 'devolucion' and grantee = 'service_role'), 7,
          'service_role tiene todos los privilegios');

select results_eq(
  $$ select permite_push, columna_pk, columna_duenio, sigue_campanias
       from sync.entidad where nombre = 'devolucion' $$,
  $$ values (true, 'id'::text, 'colportor_id'::text, false) $$,
  'registrada en sync.entidad como push, PK id, bajando solo lo del dueño (colportor_id), sin campañas');
select is((select tabla::text from sync.entidad where nombre = 'devolucion'), 'devolucion', 'apunta a la tabla');
select ok(not ('colportor_id' = any (sync.columnas_escribibles('devolucion'))),
          'colportor_id no es escribible por el cliente: lo fija el servidor');
select ok(not ('sync_version' = any (sync.columnas_escribibles('devolucion'))), 'ni sync_version');
select ok(sync.columnas_escribibles('devolucion') @>
            array['venta_id', 'productos_devueltos', 'dinero_retenido', 'monto_reembolsado', 'fecha_devolucion', 'deleted_at'],
          'la venta, los productos, la plata, la fecha y la baja sí');

select is((select has_function_privilege('authenticated', 'public.productos_devueltos_validos(jsonb)', 'execute')), true,
          'authenticated ejecuta productos_devueltos_validos (la llama un CHECK)');
select is((select has_function_privilege('service_role', 'public.productos_devueltos_validos(jsonb)', 'execute')), true,
          'service_role también');
select is((select has_function_privilege('anon', 'public.productos_devueltos_validos(jsonb)', 'execute')), false,
          'anon no');
select is((select has_function_privilege('authenticated', 'public.tg_devolucion_productos()', 'execute')), false,
          'la función del trigger no se llama a mano');

-- ---------------------------------------------------------------------------
-- 2. productos_devueltos_validos()
-- ---------------------------------------------------------------------------
select is(public.productos_devueltos_validos(pg_temp.items('11', '1')), true, 'un producto, una unidad');
select is(public.productos_devueltos_validos(pg_temp.items('11', '2', '12', '1', '13', '5')), true, 'tres productos');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object(
            'producto_id', upper(pg_temp.u('11')::text), 'cantidad', 1))), true, 'el uuid en mayúsculas también');
select is(public.productos_devueltos_validos(null), false, 'null no');
select is(public.productos_devueltos_validos('[]'::jsonb), false, 'un arreglo vacío no: una devolución devuelve algo');
select is(public.productos_devueltos_validos('{}'::jsonb), false, 'un objeto no');
select is(public.productos_devueltos_validos('"a"'::jsonb), false, 'un texto no');
select is(public.productos_devueltos_validos('null'::jsonb), false, 'el null de JSON no');
select is(public.productos_devueltos_validos('[1]'::jsonb), false, 'un arreglo de números no');
select is(public.productos_devueltos_validos('[null]'::jsonb), false, 'ni de nulls');
select is(public.productos_devueltos_validos('[[]]'::jsonb), false, 'ni de arreglos');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11')))), false,
          'sin cantidad no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('cantidad', 1))), false,
          'sin producto no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object(
            'producto_id', pg_temp.u('11'), 'cantidad', 1, 'precio', 100))), false,
          'con una clave de más no (sin precios: salen de venta_item)');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 0))),
          false, 'cantidad 0 no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', -1))),
          false, 'cantidad negativa no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1.5))),
          false, 'cantidad con decimales no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', '1'))),
          false, 'cantidad como texto no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', null))),
          false, 'cantidad null no');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', 'no-es-uuid', 'cantidad', 1))),
          false, 'un producto_id que no es uuid no (false, no una excepción)');
select is(public.productos_devueltos_validos(jsonb_build_array(jsonb_build_object('producto_id', 7, 'cantidad', 1))),
          false, 'ni un número');
select is(public.productos_devueltos_validos(pg_temp.items('11', '1', '11', '2')), false,
          'el mismo producto dos veces no: es un renglón con la suma');
select is(public.productos_devueltos_validos(jsonb_build_array(
            jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1),
            jsonb_build_object('producto_id', upper(pg_temp.u('11')::text), 'cantidad', 1))), false,
          'ni con el uuid en otra capitalización');
select is(public.productos_devueltos_validos(jsonb_build_array(
            jsonb_build_object('producto_id', pg_temp.u('11'), 'cantidad', 1), 'x')), false,
          'un renglón bueno y uno malo: no');

-- ---------------------------------------------------------------------------
-- 3. Las restricciones (como postgres: sin RLS de por medio)
-- ---------------------------------------------------------------------------
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d0'), pg_temp.u('71'), pg_temp.ren('11', '1', '12', '2'),
                                      '2026-10-05 12:00+00', pg_temp.u('b1')) $$),
          'ok', 'una devolución mínima: sin reembolso y sin retención');
select is((select array[dinero_retenido::text, coalesce(monto_reembolsado::text, '-')]
             from public.devolucion where id = pg_temp.u('d0')), array['0', '-'],
          'dinero_retenido 0 y sin reembolso: así sale la mayoría');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, dinero_retenido, monto_reembolsado,
                                                              fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), 50000, 190000, '2026-10-05 12:00+00', pg_temp.u('b1')) $$),
          'ok', 'con retención y reembolso en el momento');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, monto_reembolsado, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('13', '1'), 0, '2026-10-05 12:00+00', pg_temp.u('b1')) $$),
          'ok', 'un reembolso de 0 no se rechaza (el teléfono no queda atascado)');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), '2026-10-05 12:00+00', pg_temp.u('b1')),
                                     (pg_temp.u('71'), pg_temp.ren('11', '1'), '2026-10-06 12:00+00', pg_temp.u('b1')) $$),
          'ok', 'una venta puede tener varias devoluciones parciales');

select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), '[]'::jsonb, now(), pg_temp.u('b1')) $$),
          '23514 devolucion_productos_validos', 'sin productos: 23514');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), '{"producto_id": "x"}'::jsonb, now(), pg_temp.u('b1')) $$),
          '23514 devolucion_productos_validos', 'un objeto en vez de un arreglo: 23514');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), jsonb_build_array(jsonb_build_object('producto_id', 'x', 'cantidad', 1)),
                                      now(), pg_temp.u('b1')) $$),
          '23514 devolucion_productos_validos', 'un producto_id que no es uuid: 23514, no 22P02 (el trigger no castea lo que no vio el CHECK)');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '0'), now(), pg_temp.u('b1')) $$),
          '23514 devolucion_productos_validos', 'cantidad 0: 23514');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1', '11', '1'), now(), pg_temp.u('b1')) $$),
          '23514 devolucion_productos_validos', 'el mismo producto dos veces: 23514');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), null, now(), pg_temp.u('b1')) $$) like '23502%', true,
          'sin productos (null): not null');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1', '99', '1'), now(), pg_temp.u('b1')) $$),
          '23503 devolucion_producto_existe', 'un producto que no existe: 23503, como una FK');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, dinero_retenido, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), -1, now(), pg_temp.u('b1')) $$),
          '23514 devolucion_dinero_retenido_no_negativo', 'una retención negativa: 23514');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, monto_reembolsado, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), -1, now(), pg_temp.u('b1')) $$),
          '23514 devolucion_monto_reembolsado_no_negativo', 'un reembolso negativo: 23514');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, dinero_retenido, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), null, now(), pg_temp.u('b1')) $$) like '23502%', true,
          'dinero_retenido null: not null (0 es 0)');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), null, pg_temp.u('b1')) $$) like '23502%', true,
          'sin fecha: not null');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('7f'), pg_temp.ren('11', '1'), now(), pg_temp.u('b1')) $$),
          '23503 devolucion_venta_id_fkey', 'una venta que no existe: foreign key');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (null, pg_temp.ren('11', '1'), now(), pg_temp.u('b1')) $$) like '23502%', true,
          'sin venta: not null');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d0'), pg_temp.u('71'), pg_temp.ren('11', '1'), now(), pg_temp.u('b1')) $$),
          '23505 devolucion_pkey', 'el mismo id dos veces: clave primaria');

-- Cambiar los productos de una devolución existente también los juzga el CHECK y el trigger.
select is(pg_temp.error_de($$ update public.devolucion set productos_devueltos = pg_temp.ren('99', '1') where id = pg_temp.u('d0') $$),
          '23503 devolucion_producto_existe', 'al modificar los productos, un producto que no existe: 23503');
select is(pg_temp.error_de($$ update public.devolucion set productos_devueltos = '[]'::jsonb where id = pg_temp.u('d0') $$),
          '23514 devolucion_productos_validos', 'y vaciarlos: 23514');
select is(pg_temp.error_de($$ update public.devolucion set productos_devueltos = pg_temp.ren('13', '3') where id = pg_temp.u('d0') $$),
          'ok', 'cambiar a otros productos que existen, ok');

-- ---------------------------------------------------------------------------
-- 4. La RLS contra la tabla
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, dinero_retenido, monto_reembolsado, fecha_devolucion)
                              values (pg_temp.u('d1'), pg_temp.u('71'), pg_temp.ren('11', '1'), 0, 190000, '2026-10-04 10:00+00') $$),
          'ok', 'b1 guarda una devolución de su venta, sin mandar colportor_id');
select is((select colportor_id from public.devolucion where id = pg_temp.u('d1')), pg_temp.u('b1'),
          'colportor_id sale del JWT, sin que nadie lo mande');
select is((select created_by from public.devolucion where id = pg_temp.u('d1')), pg_temp.u('b1'), 'y created_by también');
select is((select monto_reembolsado from public.devolucion where id = pg_temp.u('d1')), 190000, 'el reembolso en el momento se guarda');
select is((select fecha_devolucion from public.devolucion where id = pg_temp.u('d1')), '2026-10-04 10:00+00'::timestamptz,
          'la fecha es la del teléfono, no la de ahora');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d9'), pg_temp.u('71'), pg_temp.ren('11', '1'), now(), pg_temp.u('b2')) $$),
          '42501 ', 'b1 no puede escribir una devolución a nombre de b2 (WITH CHECK)');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                              values (pg_temp.u('d9'), pg_temp.u('72'), pg_temp.ren72('11', '1'), now()) $$),
          '42501 ', 'ni sobre la venta de b2, aunque el dueño de la devolución sea él');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d9'), pg_temp.u('72'), pg_temp.ren72('11', '1'), now(), pg_temp.u('b2')) $$),
          '42501 ', 'ni a nombre de b2 sobre la venta de b2');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion, colportor_id)
                              values (pg_temp.u('d9'), pg_temp.u('71'), pg_temp.ren('11', '1'), now(), null) $$),
          '42501 ', 'ni sin dueño (colportor_id null)');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                              values (pg_temp.u('d2'), pg_temp.u('72'), pg_temp.ren72('12', '1'), '2026-10-04 11:00+00') $$),
          'ok', 'b2 guarda la suya, sobre su venta');
select is(pg_temp.error_de($$ insert into public.devolucion (id, venta_id, productos_devueltos, fecha_devolucion)
                              values (pg_temp.u('d9'), pg_temp.u('71'), pg_temp.ren('12', '1'), now()) $$),
          '42501 ', 'b2 no anota una devolución sobre la venta de b1');

-- Quién ve qué: cada uno, lo suyo.
select is((select array_agg(right(id::text, 2) order by id) from public.devolucion), array['d2'], 'b2 ve solo la suya');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select count(*)::int from public.devolucion where id in (pg_temp.u('d0'), pg_temp.u('d1'))), 2,
          'b1 ve las suyas: la mínima y la del reembolso');
select is((select count(*)::int from public.devolucion where id = pg_temp.u('d2')), 0, 'y no la de b2');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select count(*)::int from public.devolucion), 0, 'un coordinador que no coordina a nadie no ve las de nadie por la tabla');
select pg_temp.actuar_como(pg_temp.u('ad'));
select ok((select count(*)::int from public.devolucion) >= 3, 'el ADMIN ve todas (0141)');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de('select count(*) from public.devolucion'), '42501 ', 'anon: permission denied');
select is(pg_temp.error_de($$ insert into public.devolucion (venta_id, productos_devueltos, fecha_devolucion)
                              values (pg_temp.u('71'), pg_temp.ren('11', '1'), now()) $$), '42501 ', 'ni escribe');

-- Lo ajeno no se toca: ni modificar, ni dar de baja, ni borrar.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas($$ update public.devolucion set dinero_retenido = 1 where id = pg_temp.u('d1') $$), 0,
          'b2 no modifica la devolución de b1 (la fila ni se ve)');
select is(pg_temp.filas($$ update public.devolucion set deleted_at = now() where id = pg_temp.u('d1') $$), 0, 'ni la da de baja');
select is(pg_temp.error_de($$ delete from public.devolucion where id = pg_temp.u('d2') $$), '42501 ',
          'nadie borra: ni lo propio (una baja es deleted_at)');
-- Pasar la propia a una venta ajena: el WITH CHECK lo frena.
select is(pg_temp.error_de($$ update public.devolucion set venta_id = pg_temp.u('71'), productos_devueltos = pg_temp.ren('11', '1')
                                where id = pg_temp.u('d2') $$), '42501 ',
          'b2 no le cuelga su devolución a la venta de b1');
select is(pg_temp.error_de($$ update public.devolucion set colportor_id = pg_temp.u('b1') where id = pg_temp.u('d2') $$), '42501 ',
          'ni se la regala a b1');
select pg_temp.actuar_como_servidor();
select is((select array[colportor_id::text, venta_id::text] from public.devolucion where id = pg_temp.u('d2')),
          array[pg_temp.u('b2')::text, pg_temp.u('72')::text], 'y la fila de b2 sigue donde estaba');

-- Lo propio: corregir y dar de baja (la anulación de una devolución).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas($$ update public.devolucion set monto_reembolsado = 100000 where id = pg_temp.u('d1') $$), 1,
          'b1 corrige el reembolso de la suya');
select is((select sync_version from public.devolucion where id = pg_temp.u('d1')), 1::bigint, 'y sube sync_version (el teléfono ve el cambio)');
select is(pg_temp.filas($$ update public.devolucion set deleted_at = now() where id = pg_temp.u('d1') $$), 1,
          'b1 da de baja la suya: tombstone');
select is((select count(*)::int from public.devolucion where id = pg_temp.u('d1') and deleted_at is not null), 1,
          'y la ve, con deleted_at (el teléfono la baja como tombstone)');

-- ---------------------------------------------------------------------------
-- 5. Por sync.push
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table r_alta as
  select pg_temp.push1(pg_temp.op('01'), 'insert',
                       pg_temp.dev(pg_temp.u('d3'), pg_temp.u('71'), pg_temp.ren('11', '2', '12', '1'))
                         || jsonb_build_object('monto_reembolsado', 190000, 'colportor_id', pg_temp.u('b2'))) as r;
select is((select r ->> 'outcome' from r_alta), 'accepted', 'el push de una devolución se acepta');
select is((select colportor_id from public.devolucion where id = pg_temp.u('d3')), pg_temp.u('b1'),
          'el dueño es quien sube (JWT): el colportor_id del payload se descarta');
select is((select monto_reembolsado from public.devolucion where id = pg_temp.u('d3')), 190000, 'el reembolso llegó');
select is((select productos_devueltos from public.devolucion where id = pg_temp.u('d3')),
          pg_temp.ren('11', '2', '12', '1'), 'y los productos, tal cual');

select is((select pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.dev(pg_temp.u('d3'), pg_temp.u('71'))) ->> 'outcome'),
          'duplicate', 'el mismo client_op_id otra vez: duplicate (idempotente)');
select is((select pg_temp.push1(pg_temp.op('02'), 'insert', pg_temp.dev(pg_temp.u('d3'), pg_temp.u('71'))) ->> 'outcome'),
          'duplicate', 'el mismo id con otro client_op_id (un reintento tras reinstalar): duplicate');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.devolucion where id = pg_temp.u('d3')), 1, 'una sola fila');
select is((select monto_reembolsado from public.devolucion where id = pg_temp.u('d3')), 190000, 'y el reintento no la pisó');

-- Sin reembolso: la mayoría.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('03'), 'insert', pg_temp.dev(pg_temp.u('d4'), pg_temp.u('71'))) ->> 'outcome'),
          'accepted', 'una devolución sin reembolso (el campo ni viaja) se acepta');
select is((select monto_reembolsado from public.devolucion where id = pg_temp.u('d4')), null, 'y queda sin reembolso');

-- Modificar: LWW por sync_version.
select is((select pg_temp.push1(pg_temp.op('04'), 'update',
                                jsonb_build_object('id', pg_temp.u('d3'), 'dinero_retenido', 50000), 0) ->> 'outcome'),
          'accepted', 'b1 corrige la retención con la versión que tiene');
select is((select dinero_retenido from public.devolucion where id = pg_temp.u('d3')), 50000, 'quedó cambiada');
select is((select pg_temp.push1(pg_temp.op('05'), 'update',
                                jsonb_build_object('id', pg_temp.u('d3'), 'dinero_retenido', 1), 0) ->> 'outcome'),
          'conflict', 'con una versión vieja es conflict (gana el servidor)');
select is((select dinero_retenido from public.devolucion where id = pg_temp.u('d3')), 50000, 'y no se pisó');

-- Lo ajeno por push: no existe para quien sube.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.push1(pg_temp.op('06'), 'update',
                                jsonb_build_object('id', pg_temp.u('d3'), 'dinero_retenido', 1), 1) ->> 'code'),
          'FILA_INEXISTENTE', 'b2 intenta modificar la de b1: FILA_INEXISTENTE (para él no existe)');
select is((select pg_temp.push1(pg_temp.op('07'), 'delete', jsonb_build_object('id', pg_temp.u('d3')), 1) ->> 'outcome'),
          'invalid', 'ni darla de baja');
select is((select pg_temp.push1(pg_temp.op('08'), 'insert', pg_temp.dev(pg_temp.u('d5'), pg_temp.u('71'))) ->> 'outcome'),
          'invalid', 'b2 sube una devolución sobre la venta de b1: invalid');
select is((select pg_temp.push1(pg_temp.op('09'), 'insert', pg_temp.dev(pg_temp.u('d5'), pg_temp.u('71'))) ->> 'code'),
          '42501', 'con 42501');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.devolucion where id = pg_temp.u('d5')), 0, 'y no escribió nada');
select is((select array[dinero_retenido::text, deleted_at::text] from public.devolucion where id = pg_temp.u('d3')),
          array['50000', null], 'la fila de b1 no cambió ni se dio de baja');

-- La baja propia (tombstone), por push.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.push1(pg_temp.op('10'), 'delete', jsonb_build_object('id', pg_temp.u('d4')), 0) ->> 'outcome'),
          'accepted', 'b1 da de baja la suya');
select ok((select deleted_at is not null from public.devolucion where id = pg_temp.u('d4')), 'queda con deleted_at: la fila no se borra');

-- Lo que llega mal vuelve invalid con su código (y no tumba al lote).
select is((select pg_temp.push1(pg_temp.op('11'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71'), '[]'::jsonb)) ->> 'code'),
          '23514', 'sin productos: invalid 23514');
select is((select pg_temp.push1(pg_temp.op('12'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71'), pg_temp.ren('11', '0'))) ->> 'code'),
          '23514', 'cantidad 0: invalid 23514');
select is((select pg_temp.push1(pg_temp.op('13'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71'), pg_temp.ren('11', '1', '99', '1'))) ->> 'code'),
          '23503', 'un producto desconocido: invalid 23503');
select is((select pg_temp.push1(pg_temp.op('14'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('7f'))) ->> 'code'),
          '42501', 'una venta desconocida: invalid 42501 (la política no la encuentra, como en cobranza)');
select is((select pg_temp.push1(pg_temp.op('15'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71')) - 'fecha_devolucion') ->> 'code'),
          '23502', 'sin fecha: invalid 23502');
select is((select pg_temp.push1(pg_temp.op('16'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71')) || jsonb_build_object('dinero_retenido', -5)) ->> 'code'),
          '23514', 'una retención negativa: invalid 23514');
select is((select pg_temp.push1(pg_temp.op('17'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71')) || jsonb_build_object('monto_reembolsado', -5)) ->> 'code'),
          '23514', 'un reembolso negativo: invalid 23514');
select is((select pg_temp.push1(pg_temp.op('18'), 'insert',
                                pg_temp.dev(pg_temp.u('d6'), pg_temp.u('71')) || jsonb_build_object('productos_devueltos', '{"a": 1}'::jsonb)) ->> 'outcome'),
          'invalid', 'productos que no son un arreglo: invalid');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.devolucion where id = pg_temp.u('d6')), 0, 'ninguna de esas escribió nada');

select * from finish();
rollback;
