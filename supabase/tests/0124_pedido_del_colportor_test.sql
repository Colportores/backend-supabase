-- pgTAP · migración 0124 (backend-supabase#102, HU-STK-009): el colportor arma su pedido a la casa editora.
--   1. La forma: la dueña de la línea, los índices del delta, los triggers, las políticas, los privilegios por
--      columna, las dos entidades de sync.entidad y qué columnas escribe el teléfono.
--   2. El alta del pedido por la API directa (como authenticated): nace por autorizar y con origen COLPORTOR, la
--      dueña sale del JWT, tiene que estar en una campaña, nada del servidor se escribe.
--   3. Las líneas: el pedido es suyo y está por autorizar, el precio es la foto de producto.precio_base_compra, el
--      monto y el aviso del límite (la deuda con el pedido contra el límite de la campaña; justo en el límite no
--      avisa) los recalcula el servidor.
--   4. Cancelar: solo PENDIENTE_AUTORIZACION a CANCELADO; autorizado lo cancela el coordinador; ningún otro cambio.
--   5. La RLS: cada una ve lo suyo; el coordinador y el ADMIN leen; nadie más escribe.
--   6. Por sync.push (el pull, en 0124_pedido_del_colportor_pull_test.sql): idempotente, lo del servidor se descarta, lo que llega mal vuelve `invalid` con su
--      código, el reintento de lo que ya entró no se re-valida, cancelar con versión vieja es `conflict`.
--   7. El servidor carga a mano sin pasar por los triggers del teléfono.
--   8. situacion_para_pedido: deuda, deuda con el pedido, por cobrar, libros por entregar, límite y stock.
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
create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;
-- Ids: usuarios 23b1.., productos 23d1.., pedidos 23a1.., líneas 23e1..; client_op_id: 23 + 2 caracteres.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '23' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000023' || p)::uuid;
$$;

-- «sqlstate restricción» (la restricción puede ir vacía), u «ok», de lo que hace una sentencia.
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
create or replace function pg_temp.mensaje_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare
  v_n integer;
begin
  execute p_sql;
  get diagnostics v_n = row_count;
  return v_n;
end $$;
create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;
-- El pedido tal como lo manda el teléfono, y una línea.
create or replace function pg_temp.pd(p_id uuid, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'estado', 'PENDIENTE_AUTORIZACION') || p_extra;
$$;
create or replace function pg_temp.ln(p_id uuid, p_pedido uuid, p_producto uuid, p_cantidad integer, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'pedido_id', p_pedido, 'producto_id', p_producto, 'cantidad', p_cantidad) || p_extra;
$$;
-- Monto, aviso y versión del pedido, como los ve el servidor.
create or replace function pg_temp.pedido(p_id uuid) returns text language sql as $$
  select p.monto_total || '/' || p.excede_limite || '/' || p.estado || '/' || p.origen
    from public.pedido_casa_editora p where p.id = p_id;
$$;
create or replace function pg_temp.sitem(p_items jsonb default null) returns jsonb language sql as $$
  select to_jsonb(s) from public.situacion_para_pedido(p_items) s;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1: inscripta en e1 (límite de deuda $U 200,00 = 20000), debe 12000 y tiene 3000 por cobrar; b2: en e2 (sin
-- límite); b3: sin campaña; b4: inscripta en e1 y dada de baja ayer; c1 coordina e1 y e2; ad es ADMIN.
-- Productos: d1 (1500), d2 (2000), d3 (sin precio de compra), d4 (con precio, dado de baja).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pedido23-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','ab','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('ab','COLPORTOR'),
               ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, limite_deuda) values
  (pg_temp.u('e1'), 'e1 pedido23', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), 20000),
  (pg_temp.u('e2'), 'e2 pedido23', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'), null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('ab'), now() - interval '10 days');
-- ab: inscripta en e1 pero con la cuenta suspendida.
update public.usuario set suspendido_en = now() - interval '1 day' where id = pg_temp.u('ab');
insert into public.campania_colportor (campania_id, usuario_id, created_at, deleted_at) values
  (pg_temp.u('e1'), pg_temp.u('b4'), now() - interval '10 days', now() - interval '1 day');

insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('d1'), 'Libro uno pedido23', 'LIBRO', 1500),
  (pg_temp.u('d2'), 'Revista dos pedido23', 'REVISTA', 2000),
  (pg_temp.u('d3'), 'Libro sin precio pedido23', 'LIBRO', null),
  (pg_temp.u('d5'), 'Libro cinco pedido23', 'LIBRO', 100);
insert into public.producto (id, nombre, tipo, precio_base_compra, deleted_at) values
  (pg_temp.u('d4'), 'Libro de baja pedido23', 'LIBRO', 900, now());

insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_por_cobrar) values
  (pg_temp.u('b1'), 12000, 3000), (pg_temp.u('b2'), 500, 0);
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('d1'), 5), (pg_temp.u('b1'), pg_temp.u('d2'), -1), (pg_temp.u('b2'), pg_temp.u('d1'), 9);
insert into public.stock (usuario_id, producto_id, cantidad_disponible, deleted_at) values
  (pg_temp.u('b1'), pg_temp.u('d3'), 40, now());

-- Libros por entregar: b1 vendió 2 + 1 sin entregar, 4 ya entregados y 6 de una entrega dada de baja; b2 tiene 8.
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais pedido23', 'ZV');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad pedido23', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  (pg_temp.u('a1'), 'CASA', 'Av. Italia', '100', -34.900, -56.200, pg_temp.u('f1'), pg_temp.u('b1')),
  (pg_temp.u('a2'), 'CASA', 'Calle Dos',  '2',   -34.905, -56.195, pg_temp.u('f1'), pg_temp.u('b2'));
insert into public.espacio (id, ubicacion_id, created_by) values
  (pg_temp.u('e3'), pg_temp.u('a1'), pg_temp.u('b1')),
  (pg_temp.u('e4'), pg_temp.u('a2'), pg_temp.u('b2'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  (pg_temp.u('51'), pg_temp.u('e3'), pg_temp.u('c2'), pg_temp.u('b1')),
  (pg_temp.u('53'), pg_temp.u('e4'), pg_temp.u('c4'), pg_temp.u('b2'));
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  (pg_temp.u('71'), pg_temp.u('51'), 'T-2371', 450000, now(), pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('51'), 'T-2372', 450000, now(), pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('73'), pg_temp.u('53'), 'T-2373', 260000, now(), pg_temp.u('b2'), pg_temp.u('b2'));
insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, fecha_entrega) values
  (pg_temp.u('91'), pg_temp.u('71'), pg_temp.u('d1'), 2, true, null),
  (pg_temp.u('92'), pg_temp.u('72'), pg_temp.u('d2'), 1, true, null),
  (pg_temp.u('93'), pg_temp.u('71'), pg_temp.u('d1'), 4, false, now()),
  (pg_temp.u('95'), pg_temp.u('73'), pg_temp.u('d1'), 8, true, null);
insert into public.entrega (id, venta_id, producto_id, cantidad, pendiente, deleted_at) values
  (pg_temp.u('94'), pg_temp.u('71'), pg_temp.u('d1'), 6, true, now());

-- Un pedido de b2 y otro de b1 que el servidor ya autorizó, para las pruebas de lo ajeno y de lo decidido.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, motivo_rechazo) values
  (pg_temp.u('a2'), pg_temp.u('b2'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', null),
  (pg_temp.u('a9'), pg_temp.u('b1'), 'AUTORIZADO', 3000, 'COLPORTOR', null),
  (pg_temp.u('a8'), pg_temp.u('b1'), 'RECHAZADO', 3000, 'COLPORTOR', 'Excede capacidad de pago actual'),
  (pg_temp.u('a7'), pg_temp.u('b1'), 'BORRADOR', 0, 'COORDINADOR', null);
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario) values
  (pg_temp.u('e2'), pg_temp.u('a2'), pg_temp.u('d1'), 1, 1500),
  (pg_temp.u('e9'), pg_temp.u('a9'), pg_temp.u('d1'), 2, 1500);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_not_null('public', 'pedido_item', 'colportor_id', 'pedido_item.colportor_id es obligatoria');
select is((select colportor_id from public.pedido_item where id = pg_temp.u('e9')), pg_temp.u('b1'),
          'la dueña de una línea cargada por el servidor es la del pedido');
select is((select colportor_id from public.pedido_item where id = pg_temp.u('e2')), pg_temp.u('b2'), 'y la de b2 es b2');
select col_has_default('public', 'pedido_casa_editora', 'colportor_id', 'la dueña del pedido sale del JWT (default auth.uid())');
select has_index('public', 'pedido_casa_editora', 'pedido_casa_editora_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'el delta del pedido: la dueña primero');
select has_index('public', 'pedido_item', 'pedido_item_delta_idx', array['colportor_id', 'xmin_w', 'id'],
                 'el delta de la línea: la dueña primero');
select has_trigger('public', 'pedido_casa_editora', 'pedido_casa_editora_del_cliente', 'trigger del alta del teléfono');
select has_trigger('public', 'pedido_casa_editora', 'pedido_casa_editora_cancelar_del_cliente', 'trigger de la cancelación');
select has_trigger('public', 'pedido_item', 'pedido_item_colportor', 'trigger de la dueña de la línea');
select has_trigger('public', 'pedido_item', 'pedido_item_del_cliente', 'trigger de la línea del teléfono');
select has_trigger('public', 'pedido_item', 'pedido_item_recalcular_del_cliente', 'trigger que recalcula el monto');

select is(
  (select array_agg(p.policyname || ' ' || p.cmd || ' {' || array_to_string(p.roles, ',') || '}' order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'pedido_casa_editora'),
  array['pedido_casa_editora_insert_propio INSERT {authenticated}', 'pedido_casa_editora_select SELECT {authenticated}',
        'pedido_casa_editora_update_propio UPDATE {authenticated}'],
  'pedido_casa_editora: lectura (0067), alta y cambio de la dueña; sin DELETE');
select is(
  (select array_agg(p.policyname || ' ' || p.cmd || ' {' || array_to_string(p.roles, ',') || '}' order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = 'pedido_item'),
  array['pedido_item_insert_propio INSERT {authenticated}', 'pedido_item_select SELECT {authenticated}'],
  'pedido_item: lectura (0067) y alta de la dueña; ni UPDATE ni DELETE');
select table_privs_are('public', 'pedido_item', 'anon', array[]::text[], 'anon no tiene nada en pedido_item');
select table_privs_are('public', 'pedido_casa_editora', 'anon', array[]::text[], 'ni en pedido_casa_editora');
select is((select string_agg(privilege_type, ',' order by privilege_type)
             from information_schema.role_table_grants
            where table_schema = 'public' and table_name = 'pedido_casa_editora' and grantee = 'authenticated'),
          'SELECT', 'authenticated no tiene privilegios de tabla de escritura sobre el pedido (solo por columna)');
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'pedido_casa_editora' and grantee = 'authenticated'
              and privilege_type = 'INSERT'),
          'created_at,deleted_at,estado,id', 'el teléfono inserta del pedido solo id, estado, created_at y deleted_at');
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'pedido_casa_editora' and grantee = 'authenticated'
              and privilege_type = 'UPDATE'),
          'created_at,deleted_at,estado,id', 'y cambia solo esas');
select is((select string_agg(column_name, ',' order by column_name) from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'pedido_item' and grantee = 'authenticated'
              and privilege_type = 'INSERT'),
          'cantidad,created_at,deleted_at,id,pedido_id,producto_id', 'de la línea: id, pedido, producto, cantidad');
select is((select count(*)::int from information_schema.column_privileges
            where table_schema = 'public' and table_name = 'pedido_item' and grantee = 'authenticated'
              and privilege_type = 'UPDATE'), 0, 'y de la línea no cambia nada');

select results_eq(
  $$ select nombre, permite_push, columna_pk, columna_duenio, sigue_campanias
       from sync.entidad where nombre in ('pedido_casa_editora', 'pedido_item') order by nombre $$,
  $$ values ('pedido_casa_editora'::text, true, 'id'::text, 'colportor_id'::text, false),
            ('pedido_item'::text, true, 'id'::text, 'colportor_id'::text, false) $$,
  'las dos entidades: push y pull de las propias');
select is((select array_agg(c order by c) from unnest(sync.columnas_escribibles('pedido_casa_editora')) c
            where c not in ('created_at', 'deleted_at')),
          array['estado', 'id'], 'el teléfono escribe del pedido el id y el estado');
select is((select array_agg(c order by c) from unnest(sync.columnas_escribibles('pedido_item')) c
            where c not in ('created_at', 'deleted_at')),
          array['cantidad', 'id', 'pedido_id', 'producto_id'], 'de la línea, el pedido, el producto y la cantidad');

select is((select has_function_privilege('authenticated', 'public.situacion_para_pedido(jsonb)', 'execute')), true,
          'authenticated puede llamar a situacion_para_pedido');
select is((select has_function_privilege('anon', 'public.situacion_para_pedido(jsonb)', 'execute')), false,
          'anon no');
select is((select has_function_privilege('authenticated', 'public.recalcular_pedido_del_colportor(uuid)', 'execute')
              and has_function_privilege('authenticated', 'public.pedido_no_acepta_lineas(uuid)', 'execute')
              and has_function_privilege('authenticated', 'public.tengo_campania_para_pedir(timestamptz)', 'execute')
              and has_function_privilege('authenticated', 'public.mi_cuenta_esta_suspendida()', 'execute')), true,
          'los cuatro ayudantes los llama el trigger del teléfono');
select is((select has_function_privilege('anon', 'public.recalcular_pedido_del_colportor(uuid)', 'execute')
              or has_function_privilege('anon', 'public.pedido_no_acepta_lineas(uuid)', 'execute')
              or has_function_privilege('anon', 'public.tengo_campania_para_pedir(timestamptz)', 'execute')
              or has_function_privilege('anon', 'public.mi_cuenta_esta_suspendida()', 'execute')), false,
          'y anon ninguno');
select is((select bool_and(prosecdef) from pg_proc
            where oid in ('public.recalcular_pedido_del_colportor(uuid)'::regprocedure,
                          'public.pedido_no_acepta_lineas(uuid)'::regprocedure,
                          'public.tengo_campania_para_pedir(timestamptz)'::regprocedure,
                          'public.mi_cuenta_esta_suspendida()'::regprocedure,
                          'public.situacion_para_pedido(jsonb)'::regprocedure)),
          true, 'los ayudantes y la lectura son SECURITY DEFINER');

-- ---------------------------------------------------------------------------
-- 2. El alta del pedido por la API directa (b1)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023a1', 'PENDIENTE_AUTORIZACION') $$),
          'ok', 'b1 envía un pedido');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a1')), '0/false/PENDIENTE_AUTORIZACION/COLPORTOR',
          'nace por autorizar, de origen COLPORTOR, en cero y sin aviso');
select is((select colportor_id from public.pedido_casa_editora where id = pg_temp.u('a1')), pg_temp.u('b1'),
          'la dueña sale del JWT');
select is((select abs(extract(epoch from now() - fecha_pedido)) < 5 from public.pedido_casa_editora where id = pg_temp.u('a1')),
          true, 'fecha_pedido es la del servidor');
select is((select coordinador_id from public.pedido_casa_editora where id = pg_temp.u('a1')), null, 'sin coordinador');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023a1', 'PENDIENTE_AUTORIZACION') $$),
          '23505 pedido_casa_editora_pkey', 'el mismo id por la API directa: 23505 (el push lo toma como duplicate)');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b0', 'BORRADOR') $$),
          '23514 pedido_del_colportor_nace_por_autorizar', 'un pedido que nace en BORRADOR: 23514');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b0', 'AUTORIZADO') $$),
          '23514 pedido_del_colportor_nace_por_autorizar', 'ni autorizado de entrada: 23514');
select is(pg_temp.mensaje_de($$ insert into public.pedido_casa_editora (id, estado)
                                values ('01920000-0000-7000-8000-0000000023b0', 'AUTORIZADO') $$),
          'El pedido se envía para que lo autorice tu coordinador. Envialo desde la pantalla de pedidos.',
          'y el aviso le dice qué hacer');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, colportor_id)
                              values ('01920000-0000-7000-8000-0000000023b0', 'PENDIENTE_AUTORIZACION', '01920000-0000-7000-8000-0000000023b2') $$),
          '42501 ', 'a nombre de otra: permission denied (la dueña no se escribe)');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, origen)
                              values ('01920000-0000-7000-8000-0000000023b0', 'PENDIENTE_AUTORIZACION', 'COORDINADOR') $$),
          '42501 ', 'el origen no se escribe');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, monto_total)
                              values ('01920000-0000-7000-8000-0000000023b0', 'PENDIENTE_AUTORIZACION', 1) $$),
          '42501 ', 'el monto no se escribe');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, excede_limite)
                              values ('01920000-0000-7000-8000-0000000023b0', 'PENDIENTE_AUTORIZACION', true) $$),
          '42501 ', 'ni el aviso del límite');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, fecha_pedido)
                              values ('01920000-0000-7000-8000-0000000023b0', 'PENDIENTE_AUTORIZACION', '2020-01-01') $$),
          '42501 ', 'ni la fecha');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, coordinador_id)
                              values ('01920000-0000-7000-8000-0000000023b0', 'PENDIENTE_AUTORIZACION', '01920000-0000-7000-8000-0000000023c1') $$),
          '42501 ', 'ni el coordinador');

-- Sin campaña, en una campaña ajena que ya terminó o con la inscripción dada de baja: no se pide.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b3', 'PENDIENTE_AUTORIZACION') $$),
          '42501 ', 'b3, sin campaña, no pide');
select is(pg_temp.mensaje_de($$ insert into public.pedido_casa_editora (id, estado)
                               values ('01920000-0000-7000-8000-0000000023b3', 'PENDIENTE_AUTORIZACION') $$),
          'No estás en una campaña en curso, así que no podés pedir libros todavía. Hablá con tu coordinador para que te inscriba.',
          'y el aviso le dice a quién hablarle');
select pg_temp.actuar_como(pg_temp.u('b4'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b4', 'PENDIENTE_AUTORIZACION') $$),
          '42501 ', 'b4, dada de baja ayer, tampoco');
-- Suspendida pero inscripta en una campaña en curso: tampoco (decisión del 27/10).
select pg_temp.actuar_como(pg_temp.u('ab'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b7', 'PENDIENTE_AUTORIZACION') $$),
          '42501 ', 'ab, con la cuenta suspendida, no pide aunque siga inscripta');
select is(pg_temp.mensaje_de($$ insert into public.pedido_casa_editora (id, estado)
                               values ('01920000-0000-7000-8000-0000000023b7', 'PENDIENTE_AUTORIZACION') $$),
          'Tu cuenta está suspendida, así que no podés pedir libros. Hablá con el administrador.',
          'y el aviso le dice a quién hablarle');
select pg_temp.actuar_como_servidor();
update public.usuario set suspendido_en = null where id = pg_temp.u('ab');
select pg_temp.actuar_como(pg_temp.u('ab'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b7', 'PENDIENTE_AUTORIZACION') $$),
          'ok', 'levantada la suspensión, ab pide');
select pg_temp.actuar_como_servidor();
delete from public.pedido_casa_editora where id = pg_temp.u('b7');
update public.usuario set suspendido_en = now() - interval '1 day' where id = pg_temp.u('ab');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, colportor_id)
                              values ('01920000-0000-7000-8000-0000000023b5', 'PENDIENTE_AUTORIZACION', '01920000-0000-7000-8000-0000000023b1') $$),
          '42501 ', 'el coordinador no registra pedidos a nombre de un colportor por esta vía');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado, colportor_id)
                              values ('01920000-0000-7000-8000-0000000023b5', 'PENDIENTE_AUTORIZACION', '01920000-0000-7000-8000-0000000023b1') $$),
          '42501 ', 'ni el ADMIN');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023b6', 'PENDIENTE_AUTORIZACION') $$),
          '42501 ', 'anon no pide');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.pedido_casa_editora where id::text like '01920000-0000-7000-8000-0000000023b%'),
          0, 'ninguno de los rechazados dejó una fila');

-- ---------------------------------------------------------------------------
-- 3. Las líneas (b1, sobre el pedido a1): precio del servidor, monto y aviso del límite
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e1', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d1', 3) $$),
          'ok', 'b1 suma 3 del producto uno a su pedido');
select pg_temp.actuar_como_servidor();
select is((select precio_unitario::int from public.pedido_item where id = pg_temp.u('e1')), 1500,
          'el precio es el de producto.precio_base_compra');
select is((select colportor_id from public.pedido_item where id = pg_temp.u('e1')), pg_temp.u('b1'), 'la dueña de la línea es b1');
select is(pg_temp.pedido(pg_temp.u('a1')), '4500/false/PENDIENTE_AUTORIZACION/COLPORTOR',
          'el monto del pedido es 3 × 1500 y no supera: 12000 + 4500 = 16500 contra 20000');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e3', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d2', 4) $$),
          'ok', 'suma 4 del producto dos');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a1')), '12500/true/PENDIENTE_AUTORIZACION/COLPORTOR',
          'ahora 12500 y avisa: 12000 + 12500 = 24500 supera el límite de 20000 (sigue por autorizar: solo avisa)');

-- Cambia el precio del catálogo después: la línea guarda su foto.
update public.producto set precio_base_compra = 9999 where id = pg_temp.u('d1');
select is((select precio_unitario::int from public.pedido_item where id = pg_temp.u('e1')), 1500,
          'un cambio de precio posterior no toca la línea');
update public.producto set precio_base_compra = 1500 where id = pg_temp.u('d1');

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d1', 1, 1) $$),
          '42501 ', 'el precio no se escribe');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad, colportor_id)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d1', 1, '01920000-0000-7000-8000-0000000023b2') $$),
          '42501 ', 'ni la dueña de la línea');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad, cantidad_recibida)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d1', 1, 1) $$),
          '42501 ', 'ni lo recibido');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d1', 1) $$),
          '23505 pedido_item_pedido_producto_key', 'el mismo producto dos veces en un pedido: 23505');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d3', 1) $$),
          '23514 pedido_item_producto_con_precio', 'un producto sin precio de compra: 23514');
select is(pg_temp.mensaje_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                               values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                       '01920000-0000-7000-8000-0000000023d3', 1) $$),
          'Ese producto todavía no tiene precio de compra cargado. Sacalo del pedido y avisale a tu coordinador.',
          'y el aviso dice qué hacer');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d4', 1) $$),
          '23503 ', 'un producto dado de baja: 23503');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023ff', 1) $$),
          '23503 ', 'y uno que no existe: 23503');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d2', 0) $$),
          '23514 pedido_item_cantidad_check', 'cantidad cero: 23514 (el CHECK de siempre)');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a2',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '42501 ', 'una línea en el pedido de otra: 42501');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023ee',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '42501 ', 'o en uno que no existe: 42501 (no se distingue)');
select is(pg_temp.mensaje_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                               values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a2',
                                       '01920000-0000-7000-8000-0000000023d2', 1) $$),
          'Ese pedido no es tuyo. Sumá productos solo a tus pedidos.', 'con el aviso de qué hacer');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a9',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '23514 pedido_item_pedido_por_autorizar', 'una línea en un pedido ya autorizado: 23514');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a8',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '23514 pedido_item_pedido_por_autorizar', 'o rechazado: 23514');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a7',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '23514 pedido_item_pedido_por_autorizar', 'o en un borrador del coordinador: 23514');
select is(pg_temp.mensaje_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                               values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a9',
                                       '01920000-0000-7000-8000-0000000023d2', 1) $$),
          'Ese pedido ya no está por autorizar, así que no se le pueden sumar productos. Armá un pedido nuevo.',
          'con el aviso de qué hacer');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '42501 ', 'b3 no suma líneas al pedido de b1');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e4', '01920000-0000-7000-8000-0000000023a1',
                                      '01920000-0000-7000-8000-0000000023d2', 1) $$),
          '42501 ', 'anon tampoco');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a1')), '12500/true/PENDIENTE_AUTORIZACION/COLPORTOR',
          'ningún intento fallido tocó el monto ni el aviso');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('a1')), 2, 'ni dejó líneas');

-- Justo en el límite no avisa: 12000 + 8000 = 20000 (un pedido nuevo de b1: 4 del producto dos).
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023a3', 'PENDIENTE_AUTORIZACION') $$),
          'ok', 'b1 envía otro pedido');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e5', '01920000-0000-7000-8000-0000000023a3',
                                      '01920000-0000-7000-8000-0000000023d2', 4) $$),
          'ok', 'un pedido de 4 del producto dos');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a3')), '8000/false/PENDIENTE_AUTORIZACION/COLPORTOR',
          'justo en el límite (12000 + 8000 = 20000) no avisa');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e6', '01920000-0000-7000-8000-0000000023a3',
                                      '01920000-0000-7000-8000-0000000023d1', 1) $$),
          'ok', 'y le suma 1 del producto uno');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a3')), '9500/true/PENDIENTE_AUTORIZACION/COLPORTOR', 'un peso más (1500): avisa');

-- Una campaña sin límite (b2) nunca avisa.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (id, estado)
                              values ('01920000-0000-7000-8000-0000000023a4', 'PENDIENTE_AUTORIZACION') $$),
          'ok', 'b2 envía un pedido');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e7', '01920000-0000-7000-8000-0000000023a4',
                                      '01920000-0000-7000-8000-0000000023d2', 500) $$),
          'ok', 'con 500 del producto dos');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a4')), '1000000/false/PENDIENTE_AUTORIZACION/COLPORTOR',
          'sin límite en la campaña, ni un pedido enorme avisa');

-- ---------------------------------------------------------------------------
-- 4. Cancelar
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'AUTORIZADO'
                              where id = '01920000-0000-7000-8000-0000000023a1' $$),
          '42501 ', 'b1 no se autoriza el pedido');
select is(pg_temp.mensaje_de($$ update public.pedido_casa_editora set estado = 'AUTORIZADO'
                               where id = '01920000-0000-7000-8000-0000000023a1' $$),
          'Desde el teléfono un pedido solo se puede cancelar.', 'con el aviso de qué hacer');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set monto_total = 1
                              where id = '01920000-0000-7000-8000-0000000023a1' $$),
          '42501 ', 'ni cambia el monto (permission denied)');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set colportor_id = '01920000-0000-7000-8000-0000000023b2'
                              where id = '01920000-0000-7000-8000-0000000023a1' $$),
          '42501 ', 'ni se lo pasa a otra');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set excede_limite = false
                              where id = '01920000-0000-7000-8000-0000000023a1' $$),
          '42501 ', 'ni apaga el aviso');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set deleted_at = now()
                              where id = '01920000-0000-7000-8000-0000000023a1' $$),
          '42501 ', 'ni lo borra');
select is(pg_temp.mensaje_de($$ update public.pedido_casa_editora set deleted_at = now()
                               where id = '01920000-0000-7000-8000-0000000023a1' $$),
          'Un pedido no se borra: se cancela mientras esté por autorizar.', 'con el aviso de qué hacer');
select is(pg_temp.filas($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                          where id = '01920000-0000-7000-8000-0000000023a2' $$),
          0, 'el pedido de otra no se ve: no se cancela (0 filas)');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                              where id = '01920000-0000-7000-8000-0000000023a9' $$),
          '42501 ', 'uno autorizado no se cancela desde el teléfono');
select is(pg_temp.mensaje_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                               where id = '01920000-0000-7000-8000-0000000023a9' $$),
          'Tu coordinador ya autorizó este pedido: pedile a él que lo cancele.', 'con el aviso de a quién pedírselo');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                              where id = '01920000-0000-7000-8000-0000000023a8' $$),
          '42501 ', 'uno rechazado tampoco');
select is(pg_temp.mensaje_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                               where id = '01920000-0000-7000-8000-0000000023a8' $$),
          'Este pedido ya no se puede cancelar: ya no está por autorizar.', 'con su aviso');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                              where id = '01920000-0000-7000-8000-0000000023a7' $$),
          '42501 ', 'ni el borrador del coordinador');
select is(pg_temp.filas($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                          where id = '01920000-0000-7000-8000-0000000023a3' $$),
          1, 'b1 cancela su pedido por autorizar');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a3')), '9500/true/CANCELADO/COLPORTOR', 'queda CANCELADO y el resto como estaba');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                              where id = '01920000-0000-7000-8000-0000000023a3' $$),
          'ok', 'cancelar otra vez lo cancelado no falla (reintento)');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'PENDIENTE_AUTORIZACION'
                              where id = '01920000-0000-7000-8000-0000000023a3' $$),
          '42501 ', 'y no se "des-cancela" desde el teléfono');
select is(pg_temp.error_de($$ insert into public.pedido_item (id, pedido_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000023e8', '01920000-0000-7000-8000-0000000023a3',
                                      '01920000-0000-7000-8000-0000000023d5', 1) $$),
          'ok', 'un pedido cancelado acepta líneas (como parte del pedido cancelado)');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('a3')), '9500/true/CANCELADO/COLPORTOR', 'sin efecto en su monto');
select pg_temp.actuar_como(pg_temp.u('b1'));
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.filas($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                          where id = '01920000-0000-7000-8000-0000000023a1' $$),
          0, 'el coordinador no cancela por la API: nada lo deja (0 filas)');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.filas($$ update public.pedido_casa_editora set estado = 'CANCELADO'
                          where id = '01920000-0000-7000-8000-0000000023a1' $$),
          0, 'otra colportora tampoco (0 filas)');
select is(pg_temp.error_de($$ delete from public.pedido_casa_editora where id = '01920000-0000-7000-8000-0000000023a4' $$),
          '42501 ', 'nadie borra un pedido');
select is(pg_temp.error_de($$ update public.pedido_item set cantidad = 99 where id = '01920000-0000-7000-8000-0000000023e7' $$),
          '42501 ', 'ni cambia una línea');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. La RLS
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select string_agg(right(id::text, 2), ',' order by right(id::text, 2)) from public.pedido_casa_editora
            where id::text like '01920000-0000-7000-8000-0000000023a_'), 'a1,a3,a7,a8,a9', 'b1 ve solo los suyos');
select is((select string_agg(right(id::text, 2), ',' order by right(id::text, 2)) from public.pedido_item
            where id::text like '01920000-0000-7000-8000-0000000023e_'), 'e1,e3,e5,e6,e8,e9', 'b1 ve solo sus líneas');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select string_agg(right(id::text, 2), ',' order by right(id::text, 2)) from public.pedido_casa_editora
            where id::text like '01920000-0000-7000-8000-0000000023a_'), 'a1,a2,a3,a4,a7,a8,a9',
          'c1, que coordina a b1 y a b2, lee los pedidos de los dos');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.pedido_casa_editora where id::text like '01920000-0000-7000-8000-0000000023a_'), 7,
          'el ADMIN lee todos');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is((select count(*)::int from public.pedido_casa_editora where id::text like '01920000-0000-7000-8000-0000000023a_'), 0,
          'b3 no ve ninguno');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Por sync.push (b1); el pull va en 0124_pedido_del_colportor_pull_test.sql
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'pedido_casa_editora', 'insert',
                        pg_temp.pd(pg_temp.u('b5'), jsonb_build_object('colportor_id', pg_temp.u('b2'), 'monto_total', 999,
                                                                      'origen', 'COORDINADOR', 'excede_limite', true,
                                                                      'coordinador_id', pg_temp.u('c1'),
                                                                      'fecha_pedido', '2020-01-01T00:00:00Z'))) ->> 'outcome',
          'accepted', 'b1 sube un pedido, aunque el payload traiga lo que decide el servidor');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('b5')), '0/false/PENDIENTE_AUTORIZACION/COLPORTOR', 'monto, aviso y origen: los del servidor');
select is((select colportor_id from public.pedido_casa_editora where id = pg_temp.u('b5')), pg_temp.u('b1'), 'la dueña sale del JWT');
select is((select coordinador_id from public.pedido_casa_editora where id = pg_temp.u('b5')), null, 'sin coordinador');
select is((select abs(extract(epoch from now() - fecha_pedido)) < 5 from public.pedido_casa_editora where id = pg_temp.u('b5')),
          true, 'y la fecha es la de llegada');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'pedido_casa_editora', 'insert', pg_temp.pd(pg_temp.u('b5'))) ->> 'outcome', 'duplicate',
          'el mismo client_op_id otra vez: duplicate (idempotente)');
select is(pg_temp.push1(pg_temp.op('02'), 'pedido_casa_editora', 'insert', pg_temp.pd(pg_temp.u('b5'))) ->> 'outcome', 'duplicate',
          'el mismo id con otro client_op_id (reinstalado): duplicate');

-- La línea antes que su pedido (otro pedido que todavía no subió): invalid.
select is(pg_temp.push1(pg_temp.op('10'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f1'), pg_temp.u('b6'), pg_temp.u('d1'), 2)) ->> 'code',
          '42501', 'una línea antes que su pedido vuelve invalid 42501');
select is(pg_temp.push1(pg_temp.op('11'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f1'), pg_temp.u('b5'), pg_temp.u('d1'), 2,
                                   jsonb_build_object('precio_unitario', 1, 'colportor_id', pg_temp.u('b2'),
                                                      'cantidad_recibida', 5))) ->> 'outcome',
          'accepted', 'sube una línea, aunque traiga precio, dueña y recibida');
select is(pg_temp.push1(pg_temp.op('12'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f2'), pg_temp.u('b5'), pg_temp.u('d2'), 5)) ->> 'outcome',
          'accepted', 'y otra');
select pg_temp.actuar_como_servidor();
select is((select array[precio_unitario::text, colportor_id::text, coalesce(cantidad_recibida::text, '-')]
             from public.pedido_item where id = pg_temp.u('f1')),
          array['1500', pg_temp.u('b1')::text, '-'], 'el precio, la dueña y lo recibido son del servidor');
select is(pg_temp.pedido(pg_temp.u('b5')), '13000/true/PENDIENTE_AUTORIZACION/COLPORTOR',
          '2 × 1500 + 5 × 2000 = 13000 y avisa (12000 + 13000 > 20000)');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('13'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f3'), pg_temp.u('b5'), pg_temp.u('d3'), 1)) ->> 'code',
          '23514', 'un producto sin precio: invalid 23514');
select is(pg_temp.push1(pg_temp.op('14'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f3'), pg_temp.u('b5'), pg_temp.u('ff'), 1)) ->> 'code',
          '23503', 'un producto inexistente: invalid 23503');
select is(pg_temp.push1(pg_temp.op('15'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f3'), pg_temp.u('b5'), pg_temp.u('d1'), 1)) ->> 'code',
          '23505', 'un producto repetido: invalid 23505');
select is(pg_temp.push1(pg_temp.op('16'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f3'), pg_temp.u('a2'), pg_temp.u('d1'), 1)) ->> 'code',
          '42501', 'una línea en el pedido de otra: invalid 42501');
select is(pg_temp.push1(pg_temp.op('17'), 'pedido_casa_editora', 'insert',
                        pg_temp.pd(pg_temp.u('b7'), '{"estado": "BORRADOR"}')) ->> 'code',
          '23514', 'un pedido que no nace por autorizar: invalid 23514');
select is(pg_temp.push1(pg_temp.op('18'), 'pedido_casa_editora', 'insert', pg_temp.pd(pg_temp.u('b7')) - 'estado') ->> 'code',
          '23514', 'sin estado: invalid 23514');
select is(pg_temp.push1(pg_temp.op('19'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f3'), pg_temp.u('b5'), pg_temp.u('d2'), 1) - 'cantidad') ->> 'code',
          '23502', 'una línea sin cantidad: invalid 23502');

-- El reintento de lo que ya entró no se re-valida aunque el pedido haya cambiado de estado.
select pg_temp.actuar_como_servidor();
update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = pg_temp.u('b5');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('20'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f1'), pg_temp.u('b5'), pg_temp.u('d1'), 2)) ->> 'outcome',
          'duplicate', 'la línea que ya había entrado, con otro client_op_id y el pedido ya autorizado: duplicate');
select is(pg_temp.push1(pg_temp.op('21'), 'pedido_casa_editora', 'insert', pg_temp.pd(pg_temp.u('b5'))) ->> 'outcome',
          'duplicate', 'y el pedido: duplicate');
select is(pg_temp.push1(pg_temp.op('22'), 'pedido_item', 'insert',
                        pg_temp.ln(pg_temp.u('f4'), pg_temp.u('b5'), pg_temp.u('d1'), 2)) ->> 'code',
          '23514', 'pero una línea nueva en el pedido autorizado: invalid 23514');
select is(pg_temp.pedido(pg_temp.u('b5')), '13000/true/AUTORIZADO/COLPORTOR', 'el pedido autorizado no cambió');

-- Cancelar por el push.
select pg_temp.actuar_como_servidor();
insert into public.pedido_casa_editora (id, colportor_id, estado, origen) values
  (pg_temp.u('b8'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 'COLPORTOR');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('30'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('b8'), 'estado', 'CANCELADO'), 7) ->> 'outcome',
          'conflict', 'cancelar con una versión vieja: conflict');
select is(pg_temp.push1(pg_temp.op('31'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('b8'), 'estado', 'CANCELADO'), 7) -> 'server_row' ->> 'estado',
          'PENDIENTE_AUTORIZACION', 'con la fila del servidor para resolver');
select is(pg_temp.push1(pg_temp.op('32'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('b8'), 'estado', 'CANCELADO'),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('b8'))) ->> 'outcome',
          'accepted', 'con la versión al día: accepted');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('b8')), '0/false/CANCELADO/COLPORTOR', 'queda cancelado');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('33'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('b5'), 'estado', 'CANCELADO'),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('b5'))) ->> 'code',
          '42501', 'cancelar uno autorizado, con la versión al día: invalid 42501');
select is(pg_temp.push1(pg_temp.op('34'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('b5'), 'monto_total', 1),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('b5'))) ->> 'outcome',
          'accepted', 'cambiar el monto por el push: el monto se descarta del payload');
select is(pg_temp.pedido(pg_temp.u('b5')), '13000/true/AUTORIZADO/COLPORTOR', 'y el monto sigue como estaba');
select is(pg_temp.push1(pg_temp.op('35'), 'pedido_casa_editora', 'delete', jsonb_build_object('id', pg_temp.u('b5')),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('b5'))) ->> 'code',
          '42501', 'borrar un pedido: invalid 42501');
select is(pg_temp.push1(pg_temp.op('36'), 'pedido_item', 'update', jsonb_build_object('id', pg_temp.u('f1'), 'cantidad', 50), 0) ->> 'code',
          '42501', 'cambiar una línea: invalid 42501');
select is(pg_temp.push1(pg_temp.op('37'), 'pedido_item', 'delete', jsonb_build_object('id', pg_temp.u('f1')), 0) ->> 'code',
          '42501', 'borrar una línea: invalid 42501');

-- Un lote con el pedido y sus dos líneas: la versión que devolvió el push del pedido sigue valiendo para cancelar
-- (las líneas recalculan el monto sin subir la sync_version) y el delta baja el monto nuevo.
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote_ba as
select sync.push(jsonb_build_array(
         jsonb_build_object('client_op_id', pg_temp.op('60'), 'entity', 'pedido_casa_editora', 'op', 'insert',
                            'payload', pg_temp.pd(pg_temp.u('ba'))),
         jsonb_build_object('client_op_id', pg_temp.op('61'), 'entity', 'pedido_item', 'op', 'insert',
                            'payload', pg_temp.ln(pg_temp.u('ca'), pg_temp.u('ba'), pg_temp.u('d1'), 2)),
         jsonb_build_object('client_op_id', pg_temp.op('62'), 'entity', 'pedido_item', 'op', 'insert',
                            'payload', pg_temp.ln(pg_temp.u('cb'), pg_temp.u('ba'), pg_temp.u('d2'), 1)))) -> 'results' as r;
grant select on lote_ba to authenticated;
select is((select string_agg(e ->> 'outcome', ',') from lote_ba, jsonb_array_elements(r) e), 'accepted,accepted,accepted',
          'el pedido y sus dos líneas entran en un lote');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('ba')), '5000/false/PENDIENTE_AUTORIZACION/COLPORTOR', 'con el monto de las dos líneas');
select is((select p.sync_version from public.pedido_casa_editora p where p.id = pg_temp.u('ba')),
          (select (r -> 0 ->> 'sync_version')::bigint from lote_ba),
          'y su sync_version es la que devolvió el push del pedido: las líneas no la movieron');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('63'), 'pedido_casa_editora', 'update', jsonb_build_object('id', pg_temp.u('ba'), 'estado', 'CANCELADO'),
                        (select (r -> 0 ->> 'sync_version')::bigint from lote_ba)) ->> 'outcome',
          'accepted', 'cancelar con la versión que devolvió el push, sin bajar antes: accepted');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('ba')), '5000/false/CANCELADO/COLPORTOR', 'queda cancelado');

-- Armó el pedido sin conexión y lo canceló antes de subir: el motor sube un alta que nace CANCELADA, con sus
-- líneas. Se acepta todo, aunque no esté en una campaña (b3), sin efecto en monto, aviso, deuda ni stock.
select pg_temp.actuar_como(pg_temp.u('b3'));
create temp table lote_bb as
select sync.push(jsonb_build_array(
         jsonb_build_object('client_op_id', pg_temp.op('64'), 'entity', 'pedido_casa_editora', 'op', 'insert',
                            'payload', pg_temp.pd(pg_temp.u('bb'), '{"estado": "CANCELADO"}')),
         jsonb_build_object('client_op_id', pg_temp.op('65'), 'entity', 'pedido_item', 'op', 'insert',
                            'payload', pg_temp.ln(pg_temp.u('cc'), pg_temp.u('bb'), pg_temp.u('d1'), 2)),
         jsonb_build_object('client_op_id', pg_temp.op('66'), 'entity', 'pedido_item', 'op', 'insert',
                            'payload', pg_temp.ln(pg_temp.u('cd'), pg_temp.u('bb'), pg_temp.u('d2'), 1)))) -> 'results' as r;
grant select on lote_bb to authenticated;
select is((select string_agg(e ->> 'outcome', ',') from lote_bb, jsonb_array_elements(r) e), 'accepted,accepted,accepted',
          'el alta que nace CANCELADA y sus dos líneas entran, sin errores');
select pg_temp.actuar_como_servidor();
select is(pg_temp.pedido(pg_temp.u('bb')), '0/false/CANCELADO/COLPORTOR', 'queda cancelado, en cero y sin aviso');
select is((select count(*)::int from public.pedido_item where pedido_id = pg_temp.u('bb') and colportor_id = pg_temp.u('b3')),
          2, 'con sus dos líneas, de b3');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('67'), 'pedido_casa_editora', 'insert',
                        pg_temp.pd(pg_temp.u('bc'), '{"estado": "AUTORIZADO"}')) ->> 'code',
          '23514', 'pero un alta que nace autorizada sigue siendo invalid 23514');

-- b3, sin campaña, sube un pedido.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.push1(pg_temp.op('40'), 'pedido_casa_editora', 'insert', pg_temp.pd(pg_temp.u('b9'))) ->> 'code',
          '42501', 'sin campaña: invalid 42501');
select is(pg_temp.push1(pg_temp.op('40'), 'pedido_casa_editora', 'insert', pg_temp.pd(pg_temp.u('b9'))) ->> 'message',
          'No estás en una campaña en curso, así que no podés pedir libros todavía. Hablá con tu coordinador para que te inscriba.',
          'con el aviso que le dice qué hacer');

select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 7. El servidor carga a mano
-- ---------------------------------------------------------------------------
insert into public.pedido_casa_editora (id, colportor_id, coordinador_id, estado, monto_total, origen, excede_limite, fecha_pedido) values
  (pg_temp.u('c5'), pg_temp.u('b3'), pg_temp.u('c1'), 'BORRADOR', 777, 'COORDINADOR', true, '2020-01-01');
select is(pg_temp.pedido(pg_temp.u('c5')), '777/true/BORRADOR/COORDINADOR',
          'un pedido que carga el servidor (sin campaña de la colportora, otro origen) queda como se escribió');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario) values
  (pg_temp.u('c6'), pg_temp.u('c5'), pg_temp.u('d1'), 2, 4321);
select is((select precio_unitario::int from public.pedido_item where id = pg_temp.u('c6')), 4321, 'una línea del servidor conserva su precio');
select is((select colportor_id from public.pedido_item where id = pg_temp.u('c6')), pg_temp.u('b3'), 'y toma la dueña del pedido');
select is(pg_temp.pedido(pg_temp.u('c5')), '777/true/BORRADOR/COORDINADOR', 'y no recalcula el monto del pedido');
select is(pg_temp.error_de($$ update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = '01920000-0000-7000-8000-0000000023c5' $$),
          'ok', 'el servidor cambia el estado sin pasar por el trigger del teléfono');

-- ---------------------------------------------------------------------------
-- 8. situacion_para_pedido
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.sitem() - 'campania_id', jsonb_build_object('deuda_actual', 12000, 'monto_pedido', 0, 'deuda_con_pedido', 12000,
                'por_cobrar', 3000, 'libros_por_entregar', 3, 'limite_deuda', 20000, 'supera_limite_por', null,
                'stock', jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d1'), 'cantidad', 1),
                                           jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', -1))),
          'b1 sin pedido: debe 12000, 3000 por cobrar, 3 libros por entregar, límite 20000 y su stock (5 menos las 4 que entregó; el negativo se muestra)');
select is(pg_temp.sitem() ->> 'campania_id', pg_temp.u('e1')::text, 'la campaña es la de hoy');
select is(pg_temp.sitem('[]'::jsonb), pg_temp.sitem(), 'una lista vacía es lo mismo que nada');
select is(pg_temp.sitem(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d1'), 'cantidad', 2),
                                          jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 4))) ->> 'monto_pedido',
          '11000', 'un pedido de 2 × 1500 + 4 × 2000');
select is((pg_temp.sitem(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d1'), 'cantidad', 2),
                                           jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 4))) ->> 'deuda_con_pedido')
          || '/' || (pg_temp.sitem(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d1'), 'cantidad', 2),
                                           jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 4))) ->> 'supera_limite_por'),
          '23000/3000', 'deuda con el pedido 23000 y supera el límite por 3000');
select is(pg_temp.sitem(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 4))) ->> 'supera_limite_por',
          null, 'justo en el límite (12000 + 8000) no lo supera');
select is(pg_temp.sitem(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 4),
                                          jsonb_build_object('producto_id', pg_temp.u('d1'), 'cantidad', 1))) ->> 'supera_limite_por',
          '1500', 'y 1500 más lo supera por 1500');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('{"producto_id": "x"}'::jsonb) $$), '22023 ',
          'algo que no es una lista: 22023');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('[{"producto_id": "01920000-0000-7000-8000-0000000023d1", "cantidad": 0}]'::jsonb) $$),
          '22023 ', 'cantidad cero: 22023');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('[{"producto_id": "01920000-0000-7000-8000-0000000023d1", "cantidad": 1},
                                                                           {"producto_id": "01920000-0000-7000-8000-0000000023d1", "cantidad": 2}]'::jsonb) $$),
          '22023 ', 'un producto repetido: 22023');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('[{"producto_id": "01920000-0000-7000-8000-0000000023d3", "cantidad": 1}]'::jsonb) $$),
          '22023 ', 'un producto sin precio: 22023');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('[{"producto_id": "01920000-0000-7000-8000-0000000023d4", "cantidad": 1}]'::jsonb) $$),
          '22023 ', 'uno de baja: 22023');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('[{"producto_id": "01920000-0000-7000-8000-0000000023ff", "cantidad": 1}]'::jsonb) $$),
          '22023 ', 'uno que no existe: 22023');
select is(pg_temp.mensaje_de($$ select * from public.situacion_para_pedido('[{"producto_id": "01920000-0000-7000-8000-0000000023ff", "cantidad": 1}]'::jsonb) $$),
          'Hay un producto que ya no está en el catálogo o no tiene precio de compra. Sacalo del pedido.', 'con el aviso de qué hacer');
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido('null'::jsonb) $$), '22023 ', 'un null de JSON: 22023');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.sitem() - 'campania_id', jsonb_build_object('deuda_actual', 500, 'monto_pedido', 0, 'deuda_con_pedido', 500,
                'por_cobrar', 0, 'libros_por_entregar', 8, 'limite_deuda', null, 'supera_limite_por', null,
                'stock', jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d1'), 'cantidad', 9))),
          'b2: lo suyo, sin límite en su campaña (y nada de b1)');
select is(pg_temp.sitem(jsonb_build_array(jsonb_build_object('producto_id', pg_temp.u('d2'), 'cantidad', 1000))) ->> 'supera_limite_por',
          null, 'sin límite nunca supera');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.sitem(), jsonb_build_object('campania_id', null, 'deuda_actual', 0, 'monto_pedido', 0, 'deuda_con_pedido', 0,
                'por_cobrar', 0, 'libros_por_entregar', 0, 'limite_deuda', null, 'supera_limite_por', null, 'stock', '[]'::jsonb),
          'b3, sin campaña ni cuenta: todo en cero, sin límite y sin stock');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.sitem() ->> 'deuda_actual', '0', 'el coordinador consulta lo suyo: no se ve la cuenta de nadie más');
select pg_temp.actuar_como_anon();
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido() $$), '42501 ', 'anon: permission denied');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ select * from public.situacion_para_pedido() $$), '42501 ', 'sin sesión (sin JWT): 42501');

select * from finish();
rollback;
