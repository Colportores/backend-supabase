-- pgTAP · 0139 (backend-supabase#201, decisión «Quién pide» del 27/10, seguimiento de 0126): la transferencia de
-- stock la pide el colportor desde el teléfono (push) o la arma el coordinador (RPC «Pedir prestado»). Cubre:
--   1. La forma: solicitante_id, las entidades de sync, los índices, la RLS y los privilegios por columna.
--   2. El push del colportor: el servidor fija el solicitante y la fecha; nace por autorizar; una de las dos
--      puntas; un compañero de campaña; las líneas; lo que el teléfono no puede escribir; el reintento.
--   3. pedir_transferencia_de_stock: quién puede, qué rechaza (TR007) y qué deja (fila, líneas, auditoría).
--   4. Las dos formas llegan a la bandeja y se autorizan con lo de 0126.
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
create or replace function pg_temp.u(p text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000139' || p)::uuid;
$$;
-- El SQLSTATE de una sentencia ejecutada como ese usuario ('ok' si no tira). Vuelve a ser el servidor.
create or replace function pg_temp.err_dml(p_uid uuid, p_sql text) returns text language plpgsql as $$
declare
  v_r text;
begin
  perform pg_temp.actuar_como(p_uid);
  begin
    execute p_sql;
    v_r := 'ok';
  exception when others then
    v_r := sqlstate;
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
-- Una consulta como ese usuario: sus filas como jsonb, o {"error": SQLSTATE}.
create or replace function pg_temp.como(p_uid uuid, p_sql text) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(p_uid);
  begin
    execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from (%s) t', p_sql) into v_r;
  exception when others then
    v_r := jsonb_build_object('error', sqlstate, 'mensaje', sqlerrm);
  end;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.push(p_uid uuid, p_op text, p_entidad text, p_tipo text, p_payload jsonb) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(p_uid);
  v_r := sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', pg_temp.u(p_op), 'entity', p_entidad, 'op', p_tipo, 'payload', p_payload))) -> 'results' -> 0;
  perform pg_temp.actuar_como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.estado(p_t text) returns text language sql as $$
  select estado from public.transferencia_stock where id = pg_temp.u(p_t)
$$;
create or replace function pg_temp.stock(p_col text, p_prod text) returns integer language sql as $$
  select coalesce((select cantidad_disponible from public.stock
                    where usuario_id = pg_temp.u(p_col) and producto_id = pg_temp.u(p_prod) and deleted_at is null), -1)
$$;
create or replace function pg_temp.items(variadic p text[]) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object('producto_id', pg_temp.u(x.p), 'cantidad', x.n))
    from (select p[i] as p, p[i + 1]::int as n from generate_series(1, array_length(p, 1), 2) i) x;
$$;
create or replace function pg_temp.rpc(p_uid uuid, p_origen text, p_destino text, p_items jsonb) returns jsonb language sql as $$
  select pg_temp.como(p_uid, format('select * from public.pedir_transferencia_de_stock(%L, %L, %L::jsonb)',
                                    pg_temp.u(p_origen), pg_temp.u(p_destino), p_items::text))
$$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: c1 coordinador de Actual (e1, en curso); c2 de Proxima (e2, empieza en 20 días); ad admin.
-- Colportores: b1 y b2 en Actual y en Proxima; b3 solo en Actual; b4 sin campaña; b5 y b6 solo en Proxima.
-- Libros: 91 (1500) y 92 (2500).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'transf139-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','c2','ad','b1','b2','b3','b4','b5','b6']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'),
               ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'), ('b6','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Actual 139',  'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'Proxima 139', 'VERANO', public.hoy_montevideo() + 20, public.hoy_montevideo() + 80, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b5'), now() - interval '40 days'),
  (pg_temp.u('e2'), pg_temp.u('b6'), now() - interval '40 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('91'), 'Libro Uno t139', 'LIBRO', 1500), (pg_temp.u('92'), 'Libro Dos t139', 'LIBRO', 2500);
insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  (pg_temp.u('b1'), pg_temp.u('91'), 5), (pg_temp.u('b1'), pg_temp.u('92'), 3), (pg_temp.u('b5'), pg_temp.u('91'), 4),
  (pg_temp.u('b2'), pg_temp.u('91'), 6), (pg_temp.u('b2'), pg_temp.u('92'), 1);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select col_type_is('public', 'transferencia_stock', 'solicitante_id', 'uuid', 'transferencia_stock.solicitante_id es uuid');
select col_is_null('public', 'transferencia_stock', 'solicitante_id', 'y es opcional (la del coordinador no lo tiene)');
select fk_ok('public', 'transferencia_stock', 'solicitante_id', 'public', 'usuario', 'id', 'cuelga de usuario');
select col_type_is('public', 'transferencia_item', 'solicitante_id', 'uuid', 'transferencia_item.solicitante_id es uuid');
select results_eq($$ select permite_push, columna_pk, columna_duenio, sigue_campanias from sync.entidad where nombre = 'transferencia_stock' $$,
                  $$ values (true, 'id'::text, 'solicitante_id'::text, false) $$,
                  'transferencia_stock: push y pull de las propias (solicitante_id), sin campañas');
select results_eq($$ select permite_push, columna_pk, columna_duenio, sigue_campanias from sync.entidad where nombre = 'transferencia_item' $$,
                  $$ values (true, 'id'::text, 'solicitante_id'::text, false) $$,
                  'transferencia_item: igual');
select is((select columnas_servidor @> array['solicitante_id','coordinador_id','fecha_solicitud','numero','monto_deuda','decidido_en','motivo_rechazo']
             from sync.entidad where nombre = 'transferencia_stock'), true, 'las columnas del servidor de la transferencia');
select is((select columnas_servidor @> array['solicitante_id','precio_unitario'] from sync.entidad where nombre = 'transferencia_item'), true,
          'y de la línea');
select ok(sync.columnas_escribibles('transferencia_stock') @> array['origen_id','destino_id','estado','deleted_at'],
          'el teléfono escribe las puntas, el estado inicial y la baja');
select ok(not ('solicitante_id' = any (sync.columnas_escribibles('transferencia_stock'))), 'pero no el solicitante');
select ok(not ('precio_unitario' = any (sync.columnas_escribibles('transferencia_item'))), 'ni el costo de una línea');
select has_index('public', 'transferencia_stock', 'transferencia_stock_delta_idx', array['solicitante_id', 'xmin_w', 'id'],
                 'el delta con el dueño primero');
select has_index('public', 'transferencia_item', 'transferencia_item_delta_idx', array['solicitante_id', 'xmin_w', 'id'], 'y el de las líneas');
select is((select array_agg(p.policyname::text order by p.policyname) from pg_policies p
            where p.schemaname = 'public' and p.tablename = 'transferencia_stock' and p.cmd <> 'SELECT'),
          array['transferencia_stock_insert_propia'], 'transferencia_stock: solo una política de escritura, el alta propia');
select is((select array_agg(p.policyname::text order by p.policyname) from pg_policies p
            where p.schemaname = 'public' and p.tablename = 'transferencia_item' and p.cmd <> 'SELECT'),
          array['transferencia_item_insert_propia'], 'transferencia_item: igual');
select is((select has_table_privilege('authenticated', 'public.transferencia_stock', 'update')), false, 'el teléfono no actualiza la transferencia');
select is((select has_table_privilege('authenticated', 'public.transferencia_stock', 'delete')), false, 'ni la borra');
select is((select has_column_privilege('authenticated', 'public.transferencia_stock', 'solicitante_id', 'insert')), false,
          'ni escribe el solicitante');
select is((select has_column_privilege('authenticated', 'public.transferencia_stock', 'origen_id', 'insert')), true, 'pero sí las puntas');
select is((select has_column_privilege('authenticated', 'public.transferencia_item', 'precio_unitario', 'insert')), false,
          'ni el costo de la línea');
select is((select has_function_privilege('authenticated', 'public.pedir_transferencia_de_stock(uuid,uuid,jsonb)', 'execute')), true,
          'authenticated ejecuta «Pedir prestado»');
select is((select has_function_privilege('anon', 'public.pedir_transferencia_de_stock(uuid,uuid,jsonb)', 'execute')), false, 'anon no');

-- ---------------------------------------------------------------------------
-- 2. El push del colportor
-- ---------------------------------------------------------------------------
select is(pg_temp.push(pg_temp.u('b1'), 'a1', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('11'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b1'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'outcome',
          'accepted', 'b1 le pide libros a b2 (b1 recibe): accepted');
select is((select solicitante_id from public.transferencia_stock where id = pg_temp.u('11')), pg_temp.u('b1'),
          'el solicitante sale del JWT');
select is((select numero is not null from public.transferencia_stock where id = pg_temp.u('11')), true, 'con su número visible');
select ok((select fecha_solicitud > now() - interval '1 minute' from public.transferencia_stock where id = pg_temp.u('11')),
          'y la fecha de solicitud es la de llegada');
select is(pg_temp.push(pg_temp.u('b1'), 'a2', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('21'), 'transferencia_id', pg_temp.u('11'), 'producto_id', pg_temp.u('91'),
                               'cantidad', 2)) ->> 'outcome',
          'accepted', 'sube su línea');
select is((select solicitante_id from public.transferencia_item where id = pg_temp.u('21')), pg_temp.u('b1'),
          'el solicitante de la línea es el del encabezado');
select is((select precio_unitario from public.transferencia_item where id = pg_temp.u('21')), null, 'y sin costo fijado todavía');

-- Reintento (replay y mismo id con otro client_op_id): no se valida otra vez ni se duplica.
select is(pg_temp.push(pg_temp.u('b1'), 'a1', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('11'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b1'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'outcome', 'duplicate', 'el mismo client_op_id: duplicate');
select is(pg_temp.push(pg_temp.u('b1'), 'a3', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('11'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b1'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'outcome', 'duplicate',
          'el mismo id con otro client_op_id: duplicate (no vuelve invalid)');
select is((select count(*)::int from public.transferencia_stock where solicitante_id = pg_temp.u('b1')), 1, 'una sola fila');

-- Lo que el servidor decide, aunque el teléfono lo mande.
select is(pg_temp.push(pg_temp.u('b1'), 'a4', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('12'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b2'),
                               'estado', 'PENDIENTE_AUTORIZACION', 'solicitante_id', pg_temp.u('b2'),
                               'coordinador_id', pg_temp.u('c1'), 'monto_deuda', 99999, 'numero', 12345,
                               'motivo_rechazo', 'x', 'fecha_solicitud', '2020-01-01T00:00:00Z')) ->> 'outcome',
          'accepted', 'b1 le ofrece a b2 (b1 da) y manda campos del servidor');
select is((select (solicitante_id, coordinador_id is null, monto_deuda is null, numero <> 12345, motivo_rechazo is null,
                   fecha_solicitud > now() - interval '1 minute')::text
             from public.transferencia_stock where id = pg_temp.u('12')),
          '(' || pg_temp.u('b1')::text || ',t,t,t,t,t)', 'se descartan: solicitante, coordinador, deuda, número, motivo y fecha');

-- Lo que se rechaza (invalid, con su código).
select is(pg_temp.push(pg_temp.u('b1'), 'b1', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('13'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b2'),
                               'estado', 'AUTORIZADO')) ->> 'code', '23514', 'nacer autorizada: 23514');
select is(pg_temp.push(pg_temp.u('b1'), 'b2', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('13'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b3'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'code', '42501', 'una entre dos terceros: 42501');
select is(pg_temp.push(pg_temp.u('b1'), 'b3', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('13'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b4'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'code', '42501', 'con alguien de ninguna campaña: 42501');
select is(pg_temp.push(pg_temp.u('b3'), 'b4', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('13'), 'origen_id', pg_temp.u('b3'), 'destino_id', pg_temp.u('b5'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'code', '42501',
          'con alguien con quien no comparte campaña (b3 solo está en Actual y b5 en Proxima): 42501');
select is(pg_temp.push(pg_temp.u('b1'), 'b5', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('13'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b1'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'code', '23514', 'consigo misma: 23514');
select is(pg_temp.push(pg_temp.u('b1'), 'b6', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('13'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b3'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'outcome', 'accepted',
          'con b3, que comparte Actual: accepted (la comparte alguna campaña, no hace falta la de la coordinadora)');
select is(pg_temp.err_dml(pg_temp.u('b1'), format($$ update public.transferencia_stock set estado = 'CANCELADO' where id = %L $$, pg_temp.u('11'))),
          '42501', 'el teléfono no actualiza la transferencia (cancelarla no está pedido)');
select is(pg_temp.err_dml(pg_temp.u('b1'), format($$ delete from public.transferencia_stock where id = %L $$, pg_temp.u('11'))),
          '42501', 'ni la borra');

-- Las líneas.
select is(pg_temp.push(pg_temp.u('b1'), 'c1', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('22'), 'transferencia_id', pg_temp.u('11'), 'producto_id', pg_temp.u('91'),
                               'cantidad', 1)) ->> 'code', '23505', 'el mismo libro dos veces en la transferencia: 23505');
select is(pg_temp.push(pg_temp.u('b1'), 'c2', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('22'), 'transferencia_id', pg_temp.u('11'), 'producto_id', pg_temp.u('92'),
                               'cantidad', 0)) ->> 'code', '23514', 'cantidad 0: 23514');
select is(pg_temp.push(pg_temp.u('b1'), 'c3', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('22'), 'transferencia_id', pg_temp.u('11'), 'producto_id', pg_temp.u('9f'),
                               'cantidad', 1)) ->> 'code', '23503', 'un libro que no existe: 23503');
select is(pg_temp.push(pg_temp.u('b2'), 'c4', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('22'), 'transferencia_id', pg_temp.u('11'), 'producto_id', pg_temp.u('92'),
                               'cantidad', 1)) ->> 'code', '42501', 'una línea en la transferencia de otro (aunque sea la otra punta): 42501');
select is(pg_temp.push(pg_temp.u('b1'), 'c5', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('22'), 'transferencia_id', pg_temp.u('ff'), 'producto_id', pg_temp.u('92'),
                               'cantidad', 1)) ->> 'code', '42501', 'una línea en una transferencia que no existe: 42501');
select is(pg_temp.push(pg_temp.u('b1'), 'c6', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('22'), 'transferencia_id', pg_temp.u('11'), 'producto_id', pg_temp.u('92'),
                               'cantidad', 1, 'precio_unitario', 5, 'solicitante_id', pg_temp.u('b2'))) ->> 'outcome', 'accepted',
          'una línea con costo y solicitante inventados: accepted y se descartan');
select is((select (precio_unitario is null, solicitante_id = pg_temp.u('b1'))::text from public.transferencia_item where id = pg_temp.u('22')),
          '(t,t)', 'sin costo y con el solicitante del encabezado');

-- Ya decidida: no se le suman líneas.
update public.transferencia_stock set estado = 'AUTORIZADO', coordinador_id = pg_temp.u('c1'), decidido_en = now() where id = pg_temp.u('12');
select is(pg_temp.push(pg_temp.u('b1'), 'c7', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('23'), 'transferencia_id', pg_temp.u('12'), 'producto_id', pg_temp.u('91'),
                               'cantidad', 1)) ->> 'code', '42501', 'a una transferencia ya autorizada: 42501');
update public.transferencia_stock set estado = 'PENDIENTE_AUTORIZACION', coordinador_id = null, decidido_en = null where id = pg_temp.u('12');

-- Doble envío del mismo job en un lote: el segundo es duplicate.

-- ---------------------------------------------------------------------------
-- 3. «Pedir prestado»: el coordinador la arma
-- ---------------------------------------------------------------------------
select is((pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', pg_temp.items('91', '2', '92', '1')) -> 0 ->> 'estado'), 'PENDIENTE_AUTORIZACION',
          'c1 arma una de b1 a b2: queda por autorizar');
select is((select count(*)::int from public.transferencia_stock t where t.solicitante_id is null and t.created_by = pg_temp.u('c1')), 1,
          'sin solicitante, con c1 como quien la creó');
select is((select count(*)::int from public.transferencia_item i
             join public.transferencia_stock t on t.id = i.transferencia_id where t.created_by = pg_temp.u('c1')), 2, 'con sus dos líneas');
select is((pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', pg_temp.items('91', '1')) -> 0 ->> 'numero')::bigint
            > (select min(numero) from public.transferencia_stock where created_by = pg_temp.u('c1')), true,
          'cada una tiene su número, creciente');
select is((select count(*)::int from auditoria.audit_log a where a.event_type = 'transferencia_pedida'
              and a.metadata ->> 'desde' = 'panel'), 2, 'y deja el evento transferencia_pedida');
select is((select array(select k from jsonb_object_keys(a.metadata) k order by k) from auditoria.audit_log a
            where a.event_type = 'transferencia_pedida' limit 1),
          array['desde','destino_id','origen_id','productos','unidades'], 'con solo ids y números');
select is(pg_temp.rpc(pg_temp.u('ad'), 'b5', 'b6', pg_temp.items('91', '1')) -> 0 ->> 'estado', 'PENDIENTE_AUTORIZACION',
          'el ADMIN arma una entre dos colportores de la próxima campaña (cualquiera)');
select is(pg_temp.rpc(pg_temp.u('c2'), 'b5', 'b6', pg_temp.items('91', '1')) ->> 'error', '42501',
          'c2 no: la próxima campaña no empezó, y lo de antes del inicio lo decide el ADMIN («Campaña tr.»)');
select is(pg_temp.rpc(pg_temp.u('b1'), 'b1', 'b2', pg_temp.items('91', '1')) ->> 'error', '42501', 'un colportor no la arma: 42501');
select is(pg_temp.rpc(null, 'b1', 'b2', pg_temp.items('91', '1')) ->> 'error', '42501', 'sin sesión: 42501');
select is(pg_temp.rpc(pg_temp.u('c2'), 'b3', 'b1', pg_temp.items('91', '1')) ->> 'error', '42501',
          'un coordinador de otra campaña (b3 no está en Proxima): 42501');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b4', pg_temp.items('91', '1')) ->> 'error', '42501', 'con alguien sin campaña: 42501');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b1', pg_temp.items('91', '1')) ->> 'error', 'TR007', 'consigo mismo: TR007');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', '[]'::jsonb) ->> 'error', 'TR007', 'sin libros: TR007');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', null) ->> 'error', 'TR007', 'sin lista: TR007');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', pg_temp.items('91', '1', '91', '2')) ->> 'error', 'TR007', 'un libro repetido: TR007');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', pg_temp.items('91', '0')) ->> 'error', 'TR007', 'cantidad 0: TR007');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', pg_temp.items('9f', '1')) ->> 'error', 'TR007', 'un libro que no existe: TR007');
select is(pg_temp.rpc(pg_temp.u('c1'), 'b1', 'b2', '{"a": 1}'::jsonb) ->> 'error', 'TR007', 'una lista que no es lista: TR007');
select is((select count(*)::int from public.transferencia_stock where created_by = pg_temp.u('c1')), 2, 'lo rechazado no deja nada');

-- ---------------------------------------------------------------------------
-- 4. Las dos formas se autorizan con lo de 0126
-- ---------------------------------------------------------------------------
select is(pg_temp.como(pg_temp.u('c1'), format('select * from public.autorizar_transferencia(%L)', pg_temp.u('11'))) -> 0 ->> 'estado',
          'AUTORIZADO', 'c1 autoriza la que pidió b1 por el teléfono (b2 da)');
select is(pg_temp.estado('11'), 'AUTORIZADO', 'queda autorizada');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.stock('b1', '92') || '/' || pg_temp.stock('b2', '91') || '/' || pg_temp.stock('b2', '92'),
          '7/4/4/0', 'b2 dio 2 y 1 y b1 los recibió (b2 queda sin el Libro Dos: stock 0)');
select is(pg_temp.como(pg_temp.u('c1'), format('select * from public.autorizar_transferencia(%L)',
                         (select id from public.transferencia_stock where created_by = pg_temp.u('c1') order by numero limit 1))) -> 0 ->> 'estado',
          'AUTORIZADO', 'y la que armó ella misma');
select is(pg_temp.stock('b1', '91') || '/' || pg_temp.stock('b1', '92') || '/' || pg_temp.stock('b2', '91') || '/' || pg_temp.stock('b2', '92'),
          '5/3/6/1', 'y la que armó c1 devuelve lo mismo en sentido contrario: los dos terminan donde empezaron');

select * from finish();
rollback;
