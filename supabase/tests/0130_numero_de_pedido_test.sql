-- pgTAP · número visible del pedido a la casa editora (migración 0130, backend-supabase#180, vista 35
-- «Pedido #231»)
-- La columna numero: única, no nula, de una secuencia global que crece y nunca se reutiliza; el default y su
-- función (interna: anon no la ejecuta); es del servidor (el teléfono no la escribe ni por el push ni por SQL);
-- y pedidos_de_campania() y pedido_contexto() la devuelven. El pull va en 0130_numero_de_pedido_pull_test.sql.
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

-- Ids: usuarios 30b1.., productos 30d1.., pedidos 30a1.., campañas 30e1..; client_op_id: 0130 y dos caracteres.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '30' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000030' || p)::uuid;
$$;

-- «sqlstate» (o «ok») de lo que hace una sentencia.
create or replace function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
create or replace function pg_temp.push1(p_op uuid, p_entidad text, p_tipo text, p_payload jsonb, p_version bigint default null)
returns text language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0 ->> 'outcome';
$$;
create or replace function pg_temp.numero(p_ped text) returns bigint language sql as $$
  select numero from public.pedido_casa_editora where id = pg_temp.u(p_ped);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- c1 coordina e1 (en curso) y b1 y b2 están inscriptas; a3 es una coordinadora de otra campaña. ad es ADMIN.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pedido30-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 pedido30', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '10 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  (pg_temp.u('d1'), 'Libro uno pedido30', 'LIBRO', 1500);

-- Tres pedidos cargados por el servidor, con fechas distintas: el a1 el más viejo, el a3 el más nuevo.
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido) values
  (pg_temp.u('a1'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 3000, 'COLPORTOR', now() - interval '5 days');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido) values
  (pg_temp.u('a2'), pg_temp.u('b2'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', now() - interval '3 days');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, fecha_pedido) values
  (pg_temp.u('a3'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 1500, 'COLPORTOR', now() - interval '1 day');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario) values
  (pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('d1'), 2, 1500),
  (pg_temp.u('e2'), pg_temp.u('a2'), pg_temp.u('d1'), 1, 1500),
  (pg_temp.u('e3'), pg_temp.u('a3'), pg_temp.u('d1'), 1, 1500);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select has_column('public', 'pedido_casa_editora', 'numero', 'pedido_casa_editora.numero existe');
select col_type_is('public', 'pedido_casa_editora', 'numero', 'bigint', 'es bigint');
select col_not_null('public', 'pedido_casa_editora', 'numero', 'y obligatoria');
select col_has_default('public', 'pedido_casa_editora', 'numero', 'con default (la secuencia)');
select is((select count(*)::int
             from pg_constraint c
            where c.conrelid = 'public.pedido_casa_editora'::regclass and c.contype = 'u'
              and c.conname = 'pedido_casa_editora_numero_key'), 1, 'con un UNIQUE propio');

-- La función del default: interna, DEFINER con search_path fijo.
select is((select has_function_privilege('anon', 'public.siguiente_numero_de_pedido()', 'execute')), false,
          'anon no ejecuta la función del número');
select is((select has_function_privilege('authenticated', 'public.siguiente_numero_de_pedido()', 'execute')), true,
          'authenticated sí (el push inserta como authenticated y evalúa el default)');
select is((select has_function_privilege('service_role', 'public.siguiente_numero_de_pedido()', 'execute')), true,
          'service_role también');
select is((select count(*)::int
             from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.siguiente_numero_de_pedido()'::regprocedure), 0,
          'PUBLIC no tiene EXECUTE');
select is((select p.prosecdef and p.proconfig is not null from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = 'siguiente_numero_de_pedido'), true,
          'es SECURITY DEFINER con search_path fijo');

-- La secuencia es una sola, global, y la columna es su dueña (se borra con ella).
select is((select count(*)::int from pg_class where relkind = 'S' and relname = 'pedido_casa_editora_numero_seq'), 1,
          'una sola secuencia global');
select is((select count(*)::int from pg_depend d join pg_class s on s.oid = d.objid
            where d.refobjid = 'public.pedido_casa_editora'::regclass and d.deptype = 'a'
              and s.relname = 'pedido_casa_editora_numero_seq'), 1,
          'la columna es la dueña de la secuencia');

-- Es del servidor: se descarta del payload del push.
select is((select columnas_servidor @> array['numero'] from sync.entidad where nombre = 'pedido_casa_editora'), true,
          'numero está en columnas_servidor de pedido_casa_editora');
select is((select count(*)::int from sync.entidad where nombre <> 'pedido_casa_editora' and tabla = 'public.pedido_casa_editora'::regclass),
          0, 'y solo esa entidad la apunta');
select is((select count(*)::int from sync.entidad where nombre = 'pedido_item' and columnas_servidor @> array['numero']), 0,
          'pedido_item no tiene número ni lo descarta');

-- ---------------------------------------------------------------------------
-- 2. Cada pedido nace con su número, único, en el orden en que se crean
-- ---------------------------------------------------------------------------
select is((select count(distinct numero)::int from public.pedido_casa_editora
            where id in (pg_temp.u('a1'), pg_temp.u('a2'), pg_temp.u('a3'))), 3, 'cada pedido nace con su propio número');
select is((select (pg_temp.numero('a2') - pg_temp.numero('a1'), pg_temp.numero('a3') - pg_temp.numero('a2'))::text),
          '(1,1)', 'y se numeran en el orden en que se crean');
select is(pg_temp.err(format($$ update public.pedido_casa_editora set numero = %s where id = %L $$,
                             pg_temp.numero('a1'), pg_temp.u('a2'))),
          '23505', 'dos pedidos no pueden tener el mismo número');
select is(pg_temp.err(format($$ update public.pedido_casa_editora set numero = null where id = %L $$, pg_temp.u('a2'))),
          '23502', 'ni quedar sin número');

-- Dar de baja o cancelar un pedido no libera su número: el que viene es siempre mayor que todos.
create temp table num_previo as select pg_temp.numero('a3') as n;
update public.pedido_casa_editora set deleted_at = now() where id = pg_temp.u('a3');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values (pg_temp.u('a4'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 0, 'COLPORTOR');
select is((select pg_temp.numero('a4') - n from num_previo), 1::bigint,
          'el pedido dado de baja no devuelve su número: el siguiente es el que sigue');
update public.pedido_casa_editora set estado = 'CANCELADO' where id = pg_temp.u('a4');
insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen)
values (pg_temp.u('a5'), pg_temp.u('b1'), 'PENDIENTE_AUTORIZACION', 0, 'COLPORTOR');
select is((select pg_temp.numero('a5') - n from num_previo), 2::bigint, 'ni el cancelado');
select is(pg_temp.numero('a4'), (select n + 1 from num_previo), 'y el número del cancelado sigue siendo el suyo');

-- Un cambio del servidor (autorizar) no toca el número.
select pg_temp.actuar_como(pg_temp.u('c1'));
create temp table num_antes_autorizar as select pg_temp.numero('a1') as n;
select is((select estado from public.autorizar_pedido(pg_temp.u('a1'))), 'AUTORIZADO', 'el coordinador autoriza el a1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.numero('a1'), (select n from num_antes_autorizar), 'y su número no cambia');

-- ---------------------------------------------------------------------------
-- 3. El teléfono no elige ni cambia el número
-- ---------------------------------------------------------------------------
-- Por SQL directo: los grants por columna de 0124 no abren numero.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.err(format($$ update public.pedido_casa_editora set numero = 99999 where id = %L $$, pg_temp.u('a2'))),
          '42501', 'b2 no puede cambiar el número de su pedido');
select is(pg_temp.err(format($$ insert into public.pedido_casa_editora (id, estado, numero) values (%L, 'PENDIENTE_AUTORIZACION', 99999) $$,
                             pg_temp.u('b9'))),
          '42501', 'ni elegir uno al crearlo');

-- Por el push, aunque el payload lo traiga (porque bajó del pull o porque lo inventa).
select is(pg_temp.push1(pg_temp.op('01'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a6'), 'estado', 'PENDIENTE_AUTORIZACION', 'numero', 99999)),
          'accepted', 'b2 sube un pedido aunque el payload traiga un número');
select pg_temp.actuar_como_servidor();
select isnt(pg_temp.numero('a6'), 99999::bigint, 'el número no es el del payload');
select is(pg_temp.numero('a6') - (select n from num_previo), 3::bigint, 'es el que sigue en la secuencia');
select is((select numero > 0 from public.pedido_casa_editora where id = pg_temp.u('a6')), true, 'y es de verdad un número');

-- Un reintento (el mismo client_op_id, o el mismo id con otro) no cambia el número.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('01'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a6'), 'estado', 'PENDIENTE_AUTORIZACION', 'numero', 5)),
          'duplicate', 'el mismo client_op_id otra vez: duplicate');
select is(pg_temp.push1(pg_temp.op('02'), 'pedido_casa_editora', 'insert',
                        jsonb_build_object('id', pg_temp.u('a6'), 'estado', 'PENDIENTE_AUTORIZACION', 'numero', 5)),
          'duplicate', 'el mismo id con otro client_op_id: duplicate');
select pg_temp.actuar_como_servidor();
select is(pg_temp.numero('a6') - (select n from num_previo), 3::bigint, 'y el pedido conserva su número');

-- Un update del push que lleva el número (la fila tal como bajó) lo descarta y cancela igual.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('03'), 'pedido_casa_editora', 'update',
                        jsonb_build_object('id', pg_temp.u('a6'), 'estado', 'CANCELADO', 'numero', 7),
                        (select sync_version from public.pedido_casa_editora where id = pg_temp.u('a6'))),
          'accepted', 'b2 cancela con la fila tal como bajó, número incluido');
select pg_temp.actuar_como_servidor();
select is(pg_temp.numero('a6') - (select n from num_previo), 3::bigint, 'el número sigue siendo el de antes');
select is((select estado from public.pedido_casa_editora where id = pg_temp.u('a6')), 'CANCELADO', 'y quedó cancelado');

-- ---------------------------------------------------------------------------
-- 4. La bandeja y el detalle traen el número
-- ---------------------------------------------------------------------------
select is((select proargnames from pg_proc where oid = 'public.pedidos_de_campania(uuid)'::regprocedure)[1:3],
          array['p_campania_id','pedido_id','numero'], 'pedidos_de_campania: el número es la segunda columna de salida');
select is((select proargnames from pg_proc where oid = 'public.pedido_contexto(uuid)'::regprocedure)[1:3],
          array['p_pedido_id','numero','colportor_id'], 'pedido_contexto: el número es la primera columna de salida');
select is(has_function_privilege(r, f, 'execute')::text, case when r = 'authenticated' then 'true' else 'false' end,
          format('%s %s EXECUTE en %s', r, case when r = 'authenticated' then 'tiene' else 'no tiene' end, f))
  from unnest(array['public.pedidos_de_campania(uuid)', 'public.pedido_contexto(uuid)']) f,
       unnest(array['anon', 'authenticated', 'service_role']) r;
select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace
            and p.proname in ('pedidos_de_campania', 'pedido_contexto')), 2,
          'una sola firma de cada una (el drop + create no dejó una sobrecarga)');

select pg_temp.actuar_como(pg_temp.u('c1'));
create temp table bandeja as select * from public.pedidos_de_campania(pg_temp.u('e1'));
select pg_temp.actuar_como_servidor();
select is((select string_agg(right(b.pedido_id::text, 2) || '=' || (b.numero - p.n)::text, ',' order by b.fecha_pedido)
             from bandeja b, (select pg_temp.numero('a1') as n) p),
          'a1=0,a2=1,a5=4', 'la bandeja trae el número de cada pedido (no salen el a3 de baja ni el a4 y el a6, cancelados)');
select is((select count(*)::int from bandeja where numero is null), 0, 'ninguna fila sin número');
select is((select count(*)::int from bandeja b join public.pedido_casa_editora p on p.id = b.pedido_id and p.numero = b.numero),
          (select count(*)::int from bandeja), 'y es el de la tabla');

select pg_temp.actuar_como(pg_temp.u('c1'));
select is((select numero from public.pedido_contexto(pg_temp.u('a2'))), (select pg_temp.numero('a2')),
          'el detalle (pedido_contexto) trae el número del pedido');
select is((select numero from public.pedido_contexto(pg_temp.u('a1'))), (select pg_temp.numero('a1')),
          'también el de otro pedido: cada uno el suyo');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select numero from public.pedido_contexto(pg_temp.u('a2'))), (select pg_temp.numero('a2')),
          'el administrador lo ve igual');
select pg_temp.actuar_como_servidor();

-- El permiso no cambia: un colportor no lee ni la bandeja ni el detalle.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.err(format('select * from public.pedidos_de_campania(%L)', pg_temp.u('e1'))), '42501',
          'un colportor no lee la bandeja (con o sin número)');
select is(pg_temp.err(format('select * from public.pedido_contexto(%L)', pg_temp.u('a1'))), '42501',
          'ni el detalle de un pedido');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
