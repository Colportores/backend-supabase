-- pgTAP · migración 0067 (backend-supabase#100): Stock y cuenta (V2), solo esquema.
--   1. La forma: las nueve tablas, sus columnas, el cursor del delta, la auditoría, una sola política de
--      lectura por tabla, privilegios (authenticated solo SELECT, anon nada, service_role todo) y que
--      ninguna entra todavía a sync.entidad.
--   2. Las columnas nuevas de campania (alquiler_monto) y de campania_colportor (tipo_beca,
--      meta_monto_ces; el limite_pedido salió en la 0120: el límite es de la campaña) y sus CHECK; viajan en el pull
--      del colportor.
--   3. Quién cambia la beca y la meta: el ADMIN, el coordinador DE ESA campaña y el servidor; no otro
--      coordinador ni el propio colportor.
--   4. Los CHECK de cada tabla: estados, origen, destino, concepto, montos y cantidades.
--   5. El ticket: rechazar exige motivo; uno resuelto no se edita (TK001) salvo la foto y la baja.
--   6. Lectura: el dueño, el ADMIN y quien coordina al colportor (aun con la inscripción dada de baja);
--      no otro colportor ni un coordinador de otra campaña ni uno sin campañas. Una transferencia la ven
--      las dos puntas.
--   7. Escritura: nadie con JWT (42501), anon tampoco lee.
--   8. La función estado_cuenta() de 0004 sigue andando (la tabla se llama cuenta_colportor desde 0119).
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
create or replace function pg_temp.actuar_como_rol(p_rol text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', p_rol, true);
  perform set_config('role', p_rol, true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000067' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- Cuántas filas de la tabla ve quien llama (con su rol y su JWT).
create or replace function pg_temp.n(p_tabla text) returns integer language plpgsql as $$
declare n integer;
begin
  execute format('select count(*)::int from public.%I', p_tabla) into n;
  return n;
end $$;
-- Cuántas filas de la tabla, de las del conjunto de prueba, ve quien llama (por el id terminado en…).
create or replace function pg_temp.ve(p_tabla text, p_ids text[]) returns text language plpgsql as $$
declare r text;
begin
  execute format('select coalesce(string_agg(right(id::text, 2), '','' order by right(id::text, 2)), ''-'') from public.%I where id::text like ''01920000-0000-7000-8000-0000000067__'' and right(id::text, 2) = any($1)', p_tabla)
    into r using p_ids;
  return r;
end $$;
-- El SQLSTATE y el mensaje de lo que tira una sentencia ('ok' si no tira nada).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ': ' || sqlerrm;
end $$;
-- Filas que toca un UPDATE (la RLS que no deja ver una fila no falla: toca 0).
create or replace function pg_temp.filas(p_sql text) returns integer language plpgsql as $$
declare n integer;
begin
  execute p_sql;
  get diagnostics n = row_count;
  return n;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Usuarios: ad ADMIN; a1 coordina e1; a2 coordina e2; a5 COORDINADOR sin campañas.
-- b1 está inscripto en e1; b2 en e2; b3 en ninguna; b4 estuvo en e1 (inscripción dada de baja).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'stock67-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','a1','a2','a5','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 stock67', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 stock67', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a2'));
-- `created_at` explícito: desde 0113 el coordinador lee un ticket solo dentro de la ventana de la inscripción.
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('c1'), pg_temp.u('e1'), pg_temp.u('b1'), null, now() - interval '5 days'),
  (pg_temp.u('c2'), pg_temp.u('e2'), pg_temp.u('b2'), null, now() - interval '5 days');
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, created_at, deleted_at) values
  (pg_temp.u('c4'), pg_temp.u('e1'), pg_temp.u('b4'), null, now() - interval '5 days', now());

insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('11'), 'Libro p1 stock67', 'LIBRO', 1500),
  (pg_temp.u('12'), 'Libro p2 stock67', 'LIBRO', 2500);

-- Una fila de cada tabla por colportor (sufijo = dueño): b1, b2, b3, b4.
insert into public.stock (id, usuario_id, producto_id, cantidad_disponible)
select pg_temp.u('a' || right(s, 1)), pg_temp.u(s), pg_temp.u('11'), 5 from unnest(array['b1','b2','b3','b4']) s;
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
select pg_temp.u('b' || right(s, 1)), pg_temp.u(s), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR'
  from unnest(array['b1','b2','b3','b4']) s;
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario)
select pg_temp.u('d' || right(s, 1)), pg_temp.u('b' || right(s, 1)), pg_temp.u('11'), 1, 1500
  from unnest(array['b1','b2','b3','b4']) s;
insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, pedido_id)
select pg_temp.u('f' || right(s, 1)), pg_temp.u(s), pg_temp.u('11'), 'ENTRADA_PEDIDO', 1, pg_temp.u('b' || right(s, 1))
  from unnest(array['b1','b2','b3','b4']) s;
insert into public.ticket (id, usuario_id, tipo, monto, subido_en)
select pg_temp.u('7' || right(s, 1)), pg_temp.u(s), 'DEPOSITO', 1000, now() - interval '1 day' from unnest(array['b1','b2','b3','b4']) s;
insert into public.deposito (id, colportor_id, monto, destino, concepto, ticket_id)
select pg_temp.u('8' || right(s, 1)), pg_temp.u(s), 1000, 'BANCO', 'CASA_EDITORA', pg_temp.u('7' || right(s, 1)) from unnest(array['b1','b2','b3','b4']) s;
insert into public.cuenta_colportor (id, usuario_id, deuda_total)
select pg_temp.u('9' || right(s, 1)), pg_temp.u(s), 1500 from unnest(array['b1','b2','b3','b4']) s;
-- Una transferencia de b1 a b2 (e1 -> e2) y otra de b3 a b4.
insert into public.transferencia_stock (id, origen_id, destino_id) values
  (pg_temp.u('e5'), pg_temp.u('b1'), pg_temp.u('b2')),
  (pg_temp.u('e6'), pg_temp.u('b3'), pg_temp.u('b4'));
insert into public.transferencia_item (id, transferencia_id, producto_id, cantidad) values
  (pg_temp.u('d5'), pg_temp.u('e5'), pg_temp.u('11'), 2),
  (pg_temp.u('d6'), pg_temp.u('e6'), pg_temp.u('11'), 2);

-- ============================================================================
-- 1. La forma
-- ============================================================================
select has_table('public', t, format('existe %s', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','deposito','ticket','cuenta_colportor']) t;

select has_column('public', 'campania', 'alquiler_monto', 'campania.alquiler_monto');
select col_type_is('public', 'campania', 'alquiler_monto', 'bigint', 'alquiler_monto es bigint (centavos)');
select col_is_null('public', 'campania', 'alquiler_monto', 'alquiler_monto es opcional');
select has_column('public', 'campania_colportor', c, format('campania_colportor.%s', c))
  from unnest(array['tipo_beca','meta_monto_ces']) c;
select col_is_null('public', 'campania_colportor', c, format('campania_colportor.%s es opcional', c))
  from unnest(array['tipo_beca','meta_monto_ces']) c;
select has_column('public', 'pedido_casa_editora', c, format('pedido_casa_editora.%s', c))
  from unnest(array['origen','excede_limite','estado','monto_total','colportor_id','coordinador_id','fecha_pedido']) c;
select has_column('public', 'cuenta_colportor', 'deuda_alquiler', 'cuenta_colportor.deuda_alquiler');
select has_column('public', 'deposito', c, format('deposito.%s', c)) from unnest(array['destino','concepto']) c;
select has_column('public', 'ticket', c, format('ticket.%s', c))
  from unnest(array['numero_autorizacion','tarjeta_tipo','tarjeta_marca','monto','fecha','estado','motivo_rechazo']) c;

-- Cursor del delta y auditoría: las exige el resto del sistema en toda tabla de public.
select col_type_is('public', t, 'xmin_w', 'xid8', format('%s.xmin_w es xid8', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','deposito','ticket','cuenta_colportor']) t;
select has_trigger('public', t, t || '_auditoria_insert', format('%s tiene auditoría de alta', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','deposito','ticket','cuenta_colportor']) t;

-- Una política de lectura y ninguna de escritura en cada una (el ticket, desde 0113, y el depósito, desde 0122,
-- tienen las de su dueña: supabase/tests/0113_ticket_sube_por_push_test.sql y 0122_deposito_sube_por_push_test.sql).
select is((select count(*)::int from pg_policies
            where schemaname = 'public' and tablename = t and cmd = 'SELECT'), 1,
          format('%s tiene una política de lectura', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','deposito','ticket','cuenta_colportor']) t;
select is((select count(*)::int from pg_policies
            where schemaname = 'public' and tablename = t and cmd <> 'SELECT'), 0,
          format('%s no tiene políticas de escritura: nadie con JWT escribe', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','cuenta_colportor']) t;
select is((select string_agg(privilege_type, ',' order by privilege_type)
             from information_schema.role_table_grants
            where table_schema = 'public' and table_name = t and grantee = 'authenticated'), 'SELECT',
          format('authenticated solo tiene SELECT sobre %s', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','cuenta_colportor']) t;
select is((select count(*)::int from information_schema.role_table_grants
            where table_schema = 'public' and table_name = t and grantee = 'anon'), 0,
          format('anon no tiene privilegios sobre %s', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','deposito','ticket','cuenta_colportor']) t;
select is((select count(*)::int from information_schema.role_table_grants
            where table_schema = 'public' and table_name = t and grantee = 'service_role'), 7,
          format('service_role tiene todos los privilegios sobre %s', t))
  from unnest(array['stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                    'transferencia_item','deposito','ticket','cuenta_colportor']) t;

select is((select count(*)::int from sync.entidad
            where nombre in ('stock','pedido_casa_editora','pedido_item','movimiento_stock','transferencia_stock',
                             'transferencia_item','cuenta_colportor')), 0,
          'ninguna entra todavía a sync.entidad: el contrato espera su PR de docs (el ticket entró en 0113, el depósito en 0122)');

select is((select prosecdef from pg_proc where oid = 'public.coordina_al_colportor(uuid)'::regprocedure), true,
          'coordina_al_colportor es SECURITY DEFINER');
select is((select has_function_privilege('anon', 'public.coordina_al_colportor(uuid)', 'execute')), false,
          'anon no ejecuta coordina_al_colportor');
select is((select has_function_privilege('authenticated', 'public.coordina_al_colportor(uuid)', 'execute')), true,
          'authenticated sí (las políticas la llaman con su rol)');

-- ============================================================================
-- 2. Alquiler, beca y límite: los CHECK
-- ============================================================================
select is(pg_temp.error_de($$ update public.campania set alquiler_monto = -1 where id = '01920000-0000-7000-8000-0000000067e1' $$),
          '23514: new row for relation "campania" violates check constraint "campania_alquiler_monto_check"',
          'un alquiler negativo se rechaza');
select is(pg_temp.error_de($$ update public.campania set alquiler_monto = 150000 where id = '01920000-0000-7000-8000-0000000067e1' $$),
          'ok', 'un alquiler en centavos se carga');
select is(pg_temp.error_de($$ update public.campania set alquiler_monto = 0 where id = '01920000-0000-7000-8000-0000000067e1' $$),
          'ok', 'y cero también (no rompe nada; null sigue siendo «no cobra»)');
select is(pg_temp.error_de($$ update public.campania set alquiler_monto = null where id = '01920000-0000-7000-8000-0000000067e1' $$),
          'ok', 'y se puede volver a null');
select is(pg_temp.error_de($$ update public.campania_colportor set tipo_beca = 'TOTAL' where id = '01920000-0000-7000-8000-0000000067c1' $$),
          '23514: new row for relation "campania_colportor" violates check constraint "campania_colportor_tipo_beca_check"',
          'un tipo de beca fuera de MEDIA / COMPLETA se rechaza');
select is(pg_temp.error_de($$ update public.campania_colportor set meta_monto_ces = -5 where id = '01920000-0000-7000-8000-0000000067c1' $$),
          '23514: new row for relation "campania_colportor" violates check constraint "campania_colportor_meta_monto_ces_check"',
          'una meta de monto negativa se rechaza');
select is(pg_temp.error_de($$ update public.campania_colportor
                                 set tipo_beca = 'COMPLETA', meta_monto_ces = 6000000
                               where id = '01920000-0000-7000-8000-0000000067c1' $$),
          'ok', 'el servidor carga beca completa y meta');
select is(pg_temp.error_de($$ update public.campania_colportor set tipo_beca = null, meta_monto_ces = null
                               where id = '01920000-0000-7000-8000-0000000067c1' $$),
          'ok', 'y los vuelve a null (sin beca, sin meta)');

-- ============================================================================
-- 3. Quién cambia la beca y la meta
-- ============================================================================
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.filas($$ update public.campania_colportor set meta_monto_ces = 2000000
                            where id = '01920000-0000-7000-8000-0000000067c1' $$), 1,
          'el coordinador de la campaña fija la meta de monto de su colportor');
select is(pg_temp.filas($$ update public.campania_colportor set tipo_beca = 'MEDIA', meta_monto_ces = 3000000
                            where id = '01920000-0000-7000-8000-0000000067c1' $$), 1,
          'y la beca con su meta de monto');
select is(pg_temp.error_de($$ update public.campania_colportor set meta_monto_ces = 1
                               where id = '01920000-0000-7000-8000-0000000067c2' $$),
          '42501: La beca y la meta las fija el coordinador de la campaña',
          'pero no el de otra campaña (b2 está en e2)');
select is(pg_temp.filas($$ update public.campania_colportor set meta_libros = 10
                            where id = '01920000-0000-7000-8000-0000000067c1' $$), 1,
          'lo que no es beca ni meta de monto sigue como estaba (meta_libros)');
select is(pg_temp.filas($$ update public.campania_colportor set meta_monto_ces = meta_monto_ces
                            where id = '01920000-0000-7000-8000-0000000067c2' $$), 1,
          'y un UPDATE que nombra la columna sin cambiarla no se rechaza');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ update public.campania_colportor set tipo_beca = 'COMPLETA'
                               where id = '01920000-0000-7000-8000-0000000067c1' $$),
          '42501: La beca y la meta las fija el coordinador de la campaña',
          'el coordinador de e2 no le da beca a un colportor de e1');
select pg_temp.actuar_como(pg_temp.u('a5'));
select is(pg_temp.error_de($$ update public.campania_colportor set meta_monto_ces = 5
                               where id = '01920000-0000-7000-8000-0000000067c1' $$),
          '42501: La beca y la meta las fija el coordinador de la campaña',
          'ni un coordinador sin campañas');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.filas($$ update public.campania_colportor set meta_monto_ces = 3000000
                            where id = '01920000-0000-7000-8000-0000000067c2' $$), 1,
          'el ADMIN lo cambia en cualquier campaña');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.filas($$ update public.campania_colportor set meta_monto_ces = null, tipo_beca = 'COMPLETA'
                            where id = '01920000-0000-7000-8000-0000000067c1' $$), 0,
          'el colportor no toca su propia beca ni su meta (no ve la fila para escribirla)');
select is((select meta_monto_ces from public.campania_colportor where id = pg_temp.u('c1')), 3000000::bigint,
          'su meta sigue siendo la que fijó el coordinador y él la lee');
select is((select tipo_beca from public.campania_colportor where id = pg_temp.u('c1')), 'MEDIA',
          'y su tipo de beca también');
select pg_temp.actuar_como_servidor();

-- Viaja en el pull: el motor serializa las columnas de la tabla (sync.expresion_json), sin lista aparte, así que
-- la inscripción trae la beca y la meta, y la campaña el alquiler. (El delta solo sirve filas commiteadas:
-- este test va en una transacción, por eso se mira la expresión y no un pull.)
select ok(sync.expresion_json('public.campania_colportor'::regclass) ~ 'tipo_beca'
          and sync.expresion_json('public.campania_colportor'::regclass) ~ 'meta_monto_ces'
          and sync.expresion_json('public.campania_colportor'::regclass) !~ 'limite_pedido',
          'el pull de campania_colportor serializa tipo_beca y meta_monto_ces (limite_pedido ya no existe: 0120)');
select ok(sync.expresion_json('public.campania'::regclass) ~ 'alquiler_monto',
          'el pull de campania serializa alquiler_monto');
select is((select permite_push from sync.entidad where nombre = 'campania_colportor'), false,
          'campania_colportor sigue siendo solo de lectura para el teléfono: la app no escribe su beca ni su meta');

-- ============================================================================
-- 4. Los CHECK de cada tabla
-- ============================================================================
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (colportor_id, estado, origen)
                              values ('01920000-0000-7000-8000-0000000067b1', 'PENDIENTE', 'COLPORTOR') $$),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_estado_check"',
          'el estado viejo PENDIENTE del esquema no existe: es PENDIENTE_AUTORIZACION');
select is(pg_temp.error_de(format($$ insert into public.pedido_casa_editora (colportor_id, estado, origen)
                                      values ('01920000-0000-7000-8000-0000000067b1', %L, 'COORDINADOR') $$, e)), 'ok',
          format('el pedido admite el estado %s', e))
  from unnest(array['BORRADOR','PENDIENTE_AUTORIZACION','AUTORIZADO','DESPACHADO','RECIBIDO','RECHAZADO','CANCELADO']) e;
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (colportor_id, estado, origen)
                              values ('01920000-0000-7000-8000-0000000067b1', 'BORRADOR', 'OTRO') $$),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_origen_check"',
          'el origen del pedido es COLPORTOR o COORDINADOR');
select is(pg_temp.error_de($$ insert into public.pedido_casa_editora (colportor_id, estado, origen, monto_total)
                              values ('01920000-0000-7000-8000-0000000067b1', 'BORRADOR', 'COLPORTOR', -1) $$),
          '23514: new row for relation "pedido_casa_editora" violates check constraint "pedido_casa_editora_monto_total_check"',
          'un monto total negativo se rechaza');
select is((select excede_limite from public.pedido_casa_editora where id = pg_temp.u('b1')), false,
          'excede_limite arranca en false: nadie lo calcula todavía');
select is(pg_temp.error_de($$ insert into public.pedido_item (pedido_id, producto_id, cantidad, precio_unitario)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711', 0, 10) $$),
          '23514: new row for relation "pedido_item" violates check constraint "pedido_item_cantidad_check"',
          'una línea de pedido de cero unidades se rechaza');
select is(pg_temp.error_de($$ insert into public.pedido_item (pedido_id, producto_id, cantidad, precio_unitario)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711', 1, 10) $$),
          '23505: duplicate key value violates unique constraint "pedido_item_pedido_producto_key"',
          'un producto aparece una sola vez por pedido');
select is(pg_temp.error_de($$ insert into public.pedido_item (pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006712', 3, 10, 0) $$),
          'ok', 'se puede recibir cero (llegó incompleto) y la cantidad recibida es opcional');
select is(pg_temp.error_de($$ insert into public.pedido_item (pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida)
                              values ('01920000-0000-7000-8000-0000000067b2', '01920000-0000-7000-8000-000000006712', 3, 10, -1) $$),
          '23514: new row for relation "pedido_item" violates check constraint "pedido_item_cantidad_recibida_check"',
          'pero no una cantidad recibida negativa');

select is(pg_temp.error_de($$ insert into public.stock (usuario_id, producto_id, cantidad_reservada)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006712', -1) $$),
          '23514: new row for relation "stock" violates check constraint "stock_cantidad_reservada_check"',
          'lo reservado no es negativo');
select is(pg_temp.error_de($$ insert into public.stock (usuario_id, producto_id, cantidad_disponible)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006712', -2) $$),
          'ok', 'lo disponible sí puede quedar negativo: entregar de más se permite (S46)');
select is(pg_temp.error_de($$ insert into public.stock (usuario_id, producto_id)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711') $$),
          '23505: duplicate key value violates unique constraint "stock_usuario_producto_key"',
          'una sola fila de stock por colportor y producto');

select is(pg_temp.error_de($$ insert into public.transferencia_stock (origen_id, destino_id)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-0000000067b1') $$),
          '23514: new row for relation "transferencia_stock" violates check constraint "transferencia_stock_puntas_distintas_check"',
          'no se transfiere a uno mismo');
select is((select estado from public.transferencia_stock where id = pg_temp.u('e5')), 'PENDIENTE_AUTORIZACION',
          'una transferencia nace pendiente de autorización');
select is(pg_temp.error_de($$ update public.transferencia_stock set estado = 'EJECUTADA'
                              where id = '01920000-0000-7000-8000-0000000067e5' $$),
          '23514: new row for relation "transferencia_stock" violates check constraint "transferencia_stock_estado_check"',
          'el estado EJECUTADA del esquema viejo no existe: es EJECUTADO');
select is(pg_temp.error_de(format($$ update public.transferencia_stock set estado = %L
                                    where id = '01920000-0000-7000-8000-0000000067e5' $$, e)), 'ok',
          format('la transferencia admite %s', e))
  from unnest(array['AUTORIZADO','EJECUTADO','RECHAZADO','CANCELADO','PENDIENTE_AUTORIZACION']) e;
select is(pg_temp.error_de($$ insert into public.transferencia_item (transferencia_id, producto_id, cantidad)
                              values ('01920000-0000-7000-8000-0000000067e5', '01920000-0000-7000-8000-000000006712', 0) $$),
          '23514: new row for relation "transferencia_item" violates check constraint "transferencia_item_cantidad_check"',
          'una línea de transferencia de cero unidades se rechaza');

select is(pg_temp.error_de($$ insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711', 'AJUSTE', 1) $$),
          '23514: new row for relation "movimiento_stock" violates check constraint "movimiento_stock_tipo_check"',
          'el tipo de movimiento es uno de los cuatro');
select is(pg_temp.error_de($$ insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711', 'SALIDA_ENTREGA', 0) $$),
          '23514: new row for relation "movimiento_stock" violates check constraint "movimiento_stock_cantidad_check"',
          'la cantidad de un movimiento es positiva');
select is(pg_temp.error_de($$ insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, pedido_id, transferencia_id)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711', 'ENTRADA_PEDIDO', 1,
                                      '01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-0000000067e5') $$),
          '23514: new row for relation "movimiento_stock" violates check constraint "movimiento_stock_un_origen_check"',
          'un movimiento viene de un solo origen');
select is(pg_temp.error_de($$ insert into public.movimiento_stock (usuario_id, producto_id, tipo, cantidad, transferencia_id)
                              values ('01920000-0000-7000-8000-0000000067b1', '01920000-0000-7000-8000-000000006711', 'SALIDA_TRANSFERENCIA', 2,
                                      '01920000-0000-7000-8000-0000000067e5') $$),
          'ok', 'y sin origen o con uno solo se carga');

select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto)
                              values ('01920000-0000-7000-8000-0000000067b1', 500, 'CAJERO', 'ALQUILER') $$),
          '23514: new row for relation "deposito" violates check constraint "deposito_destino_check"',
          'el destino del depósito es banco, oficina o retiro del coordinador');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto)
                              values ('01920000-0000-7000-8000-0000000067b1', 500, 'BANCO', 'DIEZMO') $$),
          '23514: new row for relation "deposito" violates check constraint "deposito_concepto_check"',
          'el concepto es casa editora o alquiler');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto)
                              values ('01920000-0000-7000-8000-0000000067b1', 0, 'BANCO', 'ALQUILER') $$),
          '23514: new row for relation "deposito" violates check constraint "deposito_monto_check"',
          'un depósito de cero se rechaza');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino, concepto, campania_id)
                              values ('01920000-0000-7000-8000-0000000067b4', 500, 'RETIRO_COORDINADOR', 'ALQUILER',
                                      '01920000-0000-7000-8000-0000000067e1') $$),
          'ok', 'un retiro por el coordinador no lleva ticket');
select is(pg_temp.error_de($$ insert into public.deposito (colportor_id, monto, destino)
                              values ('01920000-0000-7000-8000-0000000067b1', 500, 'BANCO') $$),
          '23502: null value in column "concepto" of relation "deposito" violates not-null constraint',
          'el concepto lo elige el colportor: no tiene valor por defecto');

select is((select deuda_alquiler from public.cuenta_colportor where id = pg_temp.u('91')), 0::bigint,
          'la deuda de alquiler arranca en cero, aparte de la deuda total');
select is(pg_temp.error_de($$ insert into public.cuenta_colportor (usuario_id) values ('01920000-0000-7000-8000-0000000067b1') $$),
          '23505: duplicate key value violates unique constraint "cuenta_colportor_usuario_key"',
          'una sola cuenta por usuario');

-- ============================================================================
-- 5. El ticket
-- ============================================================================
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, estado) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 'RECHAZADO') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_motivo_rechazo_check"',
          'rechazar sin motivo se rechaza');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, estado, motivo_rechazo) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 'RECHAZADO', '   ') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_motivo_rechazo_check"',
          'y un motivo en blanco tampoco cuenta');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, estado, motivo_rechazo) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 'PENDIENTE', 'sin motivo que dar') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_motivo_rechazo_check"',
          'un ticket que no está rechazado no lleva motivo');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, estado) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 'REVISADO') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_estado_check"',
          'REVISADO e INCONSISTENTE ya no existen (S66)');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo) values
          ('01920000-0000-7000-8000-0000000067b1', 'RECIBO') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_tipo_check"',
          'el tipo del ticket es cobro con tarjeta, depósito u otro');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, tarjeta_tipo) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 'PREPAGA') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_tarjeta_tipo_check"',
          'la tarjeta es crédito o débito');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, monto) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 0) $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_monto_check"',
          'el monto del ticket es positivo');
select is(pg_temp.error_de($$ insert into public.ticket (usuario_id, tipo, numero_autorizacion) values
          ('01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', '  ') $$),
          '23514: new row for relation "ticket" violates check constraint "ticket_numero_autorizacion_check"',
          'el número de autorización no puede ser un blanco');
select is(pg_temp.error_de($$ insert into public.ticket (id, usuario_id, tipo, monto, fecha, numero_autorizacion,
                                                          tarjeta_tipo, tarjeta_marca, url_cloud) values
          ('01920000-0000-7000-8000-00000000677a', '01920000-0000-7000-8000-0000000067b1', 'COBRO_TARJETA', 5000, now(),
           '123456', 'CREDITO', 'VISA', 'tickets/x.jpg') $$),
          'ok', 'un ticket de tarjeta completo se carga');
select is((select estado from public.ticket where id = '01920000-0000-7000-8000-00000000677a'), 'PENDIENTE',
          'y nace PENDIENTE');

-- Pendiente: se edita; resuelto: no.
select is(pg_temp.error_de($$ update public.ticket set monto = 5500
                              where id = '01920000-0000-7000-8000-00000000677a' $$), 'ok',
          'un ticket pendiente se corrige');
select is(pg_temp.error_de(format($$ update public.ticket set estado = 'VALIDADO', revisado_por = %L, revisado_en = now()
                                      where id = '01920000-0000-7000-8000-00000000677a' $$, pg_temp.u('a1'))), 'ok',
          'el coordinador lo valida');
select is(pg_temp.error_de($$ update public.ticket set monto = 9000 where id = '01920000-0000-7000-8000-00000000677a' $$),
          'TK001: Un ticket validado o rechazado no se edita: subí uno nuevo',
          'un ticket validado no se edita: el monto queda');
select is(pg_temp.error_de($$ update public.ticket set estado = 'PENDIENTE' where id = '01920000-0000-7000-8000-00000000677a' $$),
          'TK001: Un ticket validado o rechazado no se edita: subí uno nuevo',
          'ni se vuelve a abrir');
select is(pg_temp.error_de($$ update public.ticket set estado = 'RECHAZADO', motivo_rechazo = 'me arrepentí'
                              where id = '01920000-0000-7000-8000-00000000677a' $$),
          'TK001: Un ticket validado o rechazado no se edita: subí uno nuevo',
          'ni pasa a rechazado');
select is(pg_temp.error_de($$ update public.ticket set tarjeta_marca = 'MASTER' where id = '01920000-0000-7000-8000-00000000677a' $$),
          'TK001: Un ticket validado o rechazado no se edita: subí uno nuevo',
          'ni cambia la tarjeta');
select is(pg_temp.error_de($$ update public.ticket set url_cloud = null where id = '01920000-0000-7000-8000-00000000677a' $$), 'ok',
          'pero la foto vence a los 4 meses y se vacía');
select is((select monto from public.ticket where id = '01920000-0000-7000-8000-00000000677a'), 5500::bigint,
          'los datos del ticket validado siguen: solo se fue la foto');
select is(pg_temp.error_de($$ update public.ticket set deleted_at = now() where id = '01920000-0000-7000-8000-00000000677a' $$), 'ok',
          'y se puede dar de baja');
select is(pg_temp.error_de(format($$ insert into public.ticket (id, usuario_id, tipo, estado, motivo_rechazo, revisado_por, revisado_en)
                                      values ('01920000-0000-7000-8000-00000000677b', %L, 'DEPOSITO', 'RECHAZADO',
                                              'El monto no coincide con el cobro', %L, now()) $$,
                                    pg_temp.u('b1'), pg_temp.u('a1'))), 'ok',
          'un rechazo con motivo se carga');
select is(pg_temp.error_de($$ update public.ticket set motivo_rechazo = 'otro motivo' where id = '01920000-0000-7000-8000-00000000677b' $$),
          'TK001: Un ticket validado o rechazado no se edita: subí uno nuevo',
          'y un ticket rechazado tampoco se edita: se sube uno nuevo');

-- ============================================================================
-- 6. Lectura
-- ============================================================================
-- Cada tabla tiene una fila de b1, b2, b3 y b4 (ids …67X1..X4, con X distinto por tabla).
-- El colportor b1 ve solo lo suyo.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ve('stock', array['a1','a2','a3','a4']), 'a1', 'b1 ve solo su fila de stock');
select is(pg_temp.ve('pedido_casa_editora', array['b1','b2','b3','b4']), 'b1', 'b1 ve solo su pedido');
select is(pg_temp.ve('movimiento_stock', array['f1','f2','f3','f4']), 'f1', 'b1 ve solo sus movimientos');
select is(pg_temp.ve('deposito', array['81','82','83','84']), '81', 'b1 ve solo su depósito');
select is(pg_temp.ve('cuenta_colportor', array['91','92','93','94']), '91', 'b1 ve solo su cuenta');
select is(pg_temp.ve('pedido_item', array['d1','d2','d3','d4']), 'd1', 'b1 ve las líneas de su pedido y no las de otros');
select is(pg_temp.ve('transferencia_stock', array['e5','e6']), 'e5', 'b1 ve la transferencia en la que es origen y no la ajena');
select is(pg_temp.ve('transferencia_item', array['d5','d6']), 'd5', 'y sus líneas');
select is(pg_temp.ve('ticket', array['71','72','73','74']), '71', 'b1 ve solo sus tickets');

-- b2 (destino de la transferencia) la ve también.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.ve('transferencia_stock', array['e5','e6']), 'e5', 'b2, que recibe, ve la transferencia');
select is(pg_temp.ve('transferencia_item', array['d5','d6']), 'd5', 'y sus líneas');
select is(pg_temp.ve('stock', array['a1','a2','a3','a4']), 'a2', 'pero de stock solo el suyo');

-- b3 no está en ninguna campaña: ve lo suyo y nada más.
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.ve('pedido_casa_editora', array['b1','b2','b3','b4']), 'b3', 'b3, sin campaña, ve su pedido y ningún otro');
select is(pg_temp.ve('transferencia_stock', array['e5','e6']), 'e6', 'y su transferencia');
select is(pg_temp.ve('deposito', array['81','82','83','84']), '83', 'y su depósito');

-- El coordinador de e1 (a1) ve a b1 y a b4 (inscripción dada de baja), no a b2 ni a b3.
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.ve('stock', array['a1','a2','a3','a4']), 'a1,a4', 'a1 ve el stock de sus colportores, aun el de una inscripción dada de baja');
select is(pg_temp.ve('pedido_casa_editora', array['b1','b2','b3','b4']), 'b1,b4', 'sus pedidos');
select is(pg_temp.ve('pedido_item', array['d1','d2','d3','d4']), 'd1,d4', 'las líneas de esos pedidos');
select is(pg_temp.ve('movimiento_stock', array['f1','f2','f3','f4']), 'f1,f4', 'sus movimientos');
select is(pg_temp.ve('ticket', array['71','72','73','74']), '71,74', 'sus tickets');
select is(pg_temp.ve('deposito', array['81','82','83','84']), '81,84', 'sus depósitos');
select is(pg_temp.ve('cuenta_colportor', array['91','92','93','94']), '91,94', 'su estado de cuenta');
select is(pg_temp.ve('transferencia_stock', array['e5','e6']), 'e5,e6',
          'a1 ve la transferencia de b1 a b2 (b1 es suyo) y la de b3 a b4 (b4 es suyo)');
select is(pg_temp.ve('transferencia_item', array['d5','d6']), 'd5,d6', 'y sus líneas');

-- El coordinador de e2 (a2) ve a b2; de las transferencias, la de b1 a b2 (b2 es suyo).
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.ve('pedido_casa_editora', array['b1','b2','b3','b4']), 'b2', 'a2 ve solo los pedidos de su colportor');
select is(pg_temp.ve('transferencia_stock', array['e5','e6']), 'e5', 'y la transferencia donde su colportor recibe');
select is(pg_temp.ve('cuenta_colportor', array['91','92','93','94']), '92', 'y su cuenta');

-- Un coordinador sin campañas no ve nada ajeno.
select pg_temp.actuar_como(pg_temp.u('a5'));
select is(pg_temp.ve('stock', array['a1','a2','a3','a4']), '-', 'a5, sin campañas, no ve stock ajeno');
select is(pg_temp.ve('ticket', array['71','72','73','74']), '-', 'ni tickets');
select is(pg_temp.ve('transferencia_stock', array['e5','e6']), '-', 'ni transferencias');

-- El ADMIN ve todo.
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.ve('stock', array['a1','a2','a3','a4']), 'a1,a2,a3,a4', 'el ADMIN ve todo el stock');
select is(pg_temp.ve('pedido_item', array['d1','d2','d3','d4']), 'd1,d2,d3,d4', 'todas las líneas');
select is(pg_temp.ve('transferencia_item', array['d5','d6']), 'd5,d6', 'todas las transferencias');
select is(pg_temp.ve('cuenta_colportor', array['91','92','93','94']), '91,92,93,94', 'y todas las cuentas');

-- Las bajas lógicas también se leen (el tombstone).
select pg_temp.actuar_como_servidor();
update public.stock set deleted_at = now() where id = pg_temp.u('a1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.ve('stock', array['a1']), 'a1', 'la baja lógica sigue a la vista del dueño');
select pg_temp.actuar_como_servidor();

-- ============================================================================
-- 7. Escritura: nadie con JWT (el ticket, desde 0113, y el depósito, desde 0122, los crea su dueña)
-- ============================================================================
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de(x.s), '42501: permission denied for table ' || x.t,
          format('ni el ADMIN inserta en %s con su JWT', x.t))
  from (values
    ('stock', $$ insert into public.stock (usuario_id, producto_id) values ('01920000-0000-7000-8000-0000000067b3', '01920000-0000-7000-8000-000000006712') $$),
    ('pedido_casa_editora', $$ insert into public.pedido_casa_editora (colportor_id, estado, origen) values ('01920000-0000-7000-8000-0000000067b3', 'BORRADOR', 'COORDINADOR') $$),
    ('cuenta_colportor', $$ insert into public.cuenta_colportor (usuario_id) values ('01920000-0000-7000-8000-0000000067b3') $$)
  ) x(t, s);
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(x.s), '42501: permission denied for table ' || x.t,
          format('el colportor no actualiza %s', x.t))
  from (values
    ('stock', $$ update public.stock set cantidad_disponible = 99 where id = '01920000-0000-7000-8000-0000000067a1' $$),
    ('pedido_casa_editora', $$ update public.pedido_casa_editora set estado = 'AUTORIZADO' where id = '01920000-0000-7000-8000-0000000067b1' $$),
    ('transferencia_stock', $$ update public.transferencia_stock set estado = 'AUTORIZADO' where id = '01920000-0000-7000-8000-0000000067e5' $$),
    ('cuenta_colportor', $$ update public.cuenta_colportor set deuda_total = 0 where id = '01920000-0000-7000-8000-000000006791' $$)
  ) x(t, s);
select is(pg_temp.error_de($$ delete from public.stock where id = '01920000-0000-7000-8000-0000000067a1' $$),
          '42501: permission denied for table stock', 'y nadie borra');
select pg_temp.actuar_como_rol('anon');
select is(pg_temp.error_de($$ select count(*) from public.cuenta_colportor $$), '42501: permission denied for table cuenta_colportor',
          'anon no lee la cuenta');
select pg_temp.actuar_como_servidor();
select is((select cantidad_disponible from public.stock where id = pg_temp.u('a1')), 5,
          'el stock de b1 no se movió');

-- ============================================================================
-- 8. La función estado_cuenta() de 0004 sigue andando
-- ============================================================================
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(public.estado_cuenta(), 'ACTIVA', 'estado_cuenta() sigue devolviendo ACTIVA al colportor inscripto');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(public.estado_cuenta(), 'PENDIENTE_ASIGNACION', 'y PENDIENTE_ASIGNACION al que no tiene campaña');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
