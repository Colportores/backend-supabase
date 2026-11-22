-- pgTAP · 0148, el pull (backend-supabase#221, «Ver transf.», «Ajuste stock» y «Cancelar tr.» del 28/10):
--   · movimiento_stock baja a su dueña (también la baja lógica) y a nadie más;
--   · transferencia_stock y transferencia_item bajan a las dos puntas, la arme quien la arme, y a nadie más (ni a la
--     coordinadora que no es una punta, ni al ADMIN);
--   · el cambio de estado (rechazar, cancelar) llega a las dos puntas por el delta.
--
-- Como 0004, 0124_pedido_del_colportor_pull y 0145, NO va en una transacción: el delta solo sirve lo commiteado.
-- Limpia al empezar y al final. Los eventos de audit_log no se pueden borrar (AU001) y cuelgan de los usuarios, así
-- que acá no se dispara ninguno (los ajustes en vivo, que registran uno, se prueban en 0148_ajuste_de_stock_…).

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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000149' || p)::uuid;
$$;
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.movimiento_stock where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'));
  delete from public.transferencia_item where transferencia_id in
    (select id from public.transferencia_stock where origen_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'))
        or destino_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4')));
  delete from public.transferencia_stock where origen_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'))
     or destino_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'));
  delete from public.campania_colportor where campania_id = pg_temp.u('e1');
  delete from public.campania where id = pg_temp.u('e1');
  delete from public.producto where id in (pg_temp.u('11'), pg_temp.u('12'));
  delete from public.usuario_rol where usuario_id in (pg_temp.u('c1'), pg_temp.u('ad'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'));
  delete from auth.users where id in (pg_temp.u('c1'), pg_temp.u('ad'), pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'));
end $$;
create or replace function pg_temp.pull(p_uid uuid, p_entidad text, p_cursor jsonb default '{}'::jsonb) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(p_uid);
  v_r := sync.pull(array[p_entidad], p_cursor, 1000);
  perform pg_temp.como_servidor();
  return v_r;
end $$;
create or replace function pg_temp.ids(p_delta jsonb, p_entidad text) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || case when e ->> 'deleted_at' is not null then 'x' else '' end
                            order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;
create or replace function pg_temp.push(p_uid uuid, p_op text, p_entidad text, p_tipo text, p_payload jsonb,
                                        p_version bigint default null) returns jsonb language plpgsql as $$
declare
  v_r jsonb;
begin
  perform pg_temp.actuar_como(p_uid);
  v_r := sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', ('01920000-0000-7000-8000-0000000149' || p_op)::uuid, 'entity', p_entidad, 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
  perform pg_temp.como_servidor();
  return v_r;
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). c1 coordina la campaña e1, donde están b1, b2 y b3; b4 no tiene campaña; ad es ADMIN.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pull149-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['c1','ad','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('c1','COORDINADOR'), ('ad','ADMIN'), ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'),
               ('b4','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 pull149', 'VERANO', public.hoy_montevideo() - 30, public.hoy_montevideo() + 10, pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), now() - interval '40 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), now() - interval '40 days');
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 pull149', 'LIBRO'), (pg_temp.u('12'), 'Libro 2 pull149', 'LIBRO');

-- T1: la arma la coordinadora (sin solicitante), b1 da y b2 recibe. T2: la pidió b3, b1 da y b3 recibe.
-- T3: b2 da y b3 recibe (no es de b1).
insert into public.transferencia_stock (id, origen_id, destino_id, estado, coordinador_id) values
  (pg_temp.u('a1'), pg_temp.u('b1'), pg_temp.u('b2'), 'PENDIENTE_AUTORIZACION', pg_temp.u('c1'));
insert into public.transferencia_stock (id, origen_id, destino_id, estado, solicitante_id) values
  (pg_temp.u('a2'), pg_temp.u('b1'), pg_temp.u('b3'), 'PENDIENTE_AUTORIZACION', pg_temp.u('b3')),
  (pg_temp.u('a3'), pg_temp.u('b2'), pg_temp.u('b3'), 'PENDIENTE_AUTORIZACION', pg_temp.u('b3'));
insert into public.transferencia_item (id, transferencia_id, producto_id, cantidad) values
  (pg_temp.u('c1'), pg_temp.u('a1'), pg_temp.u('11'), 2),
  (pg_temp.u('c2'), pg_temp.u('a2'), pg_temp.u('12'), 1),
  (pg_temp.u('c3'), pg_temp.u('a3'), pg_temp.u('12'), 1);
-- Movimientos que hace el servidor (no son ajustes en vivo: no registran evento) y una baja lógica.
insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, transferencia_id) values
  (pg_temp.u('d1'), pg_temp.u('b1'), pg_temp.u('11'), 'SALIDA_TRANSFERENCIA', 2, pg_temp.u('a1')),
  (pg_temp.u('d2'), pg_temp.u('b2'), pg_temp.u('11'), 'ENTRADA_TRANSFERENCIA', 2, pg_temp.u('a1'));
insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad, motivo, deleted_at) values
  (pg_temp.u('d3'), pg_temp.u('b1'), pg_temp.u('12'), 'AJUSTE_ENTRADA', 3, 'CONTEO', now());

-- ---------------------------------------------------------------------------
-- 1. movimiento_stock: cada una baja los suyos
-- ---------------------------------------------------------------------------
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b1'), 'movimiento_stock'), 'movimiento_stock'), array['d1','d3x'],
          'b1 baja sus movimientos, también el ajuste dado de baja como tombstone');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'movimiento_stock'), 'movimiento_stock'), array['d2'], 'b2 baja el suyo');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b3'), 'movimiento_stock'), 'movimiento_stock'), array[]::text[], 'b3 no tiene ninguno');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('c1'), 'movimiento_stock'), 'movimiento_stock'), array[]::text[],
          'la coordinadora no los baja a su teléfono (los lee por RLS en el panel)');
select is((select count(*)::int from jsonb_array_elements(pg_temp.pull(pg_temp.u('b1'), 'movimiento_stock') -> 'rows' -> 'movimiento_stock') e
            where e ? 'motivo' and e ? 'cantidad' and e ? 'tipo' and not (e ? 'xmin_w')), 2,
          'la fila trae el motivo, la cantidad y el tipo');

-- ---------------------------------------------------------------------------
-- 2. transferencia_stock y transferencia_item: las dos puntas
-- ---------------------------------------------------------------------------
create temp table tb1 as select pg_temp.pull(pg_temp.u('b1'), 'transferencia_stock') as d,
                                pg_temp.pull(pg_temp.u('b1'), 'transferencia_item') as i;
select is(pg_temp.ids(d, 'transferencia_stock'), array['a1','a2'],
          'b1 (da en T1 y en T2) baja las dos, la arme quien la arme, y no la de otros') from tb1;
select is(pg_temp.ids(i, 'transferencia_item'), array['c1','c2'], 'con sus líneas') from tb1;
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'transferencia_stock'), 'transferencia_stock'), array['a1','a3'],
          'b2 (recibe T1, da T3) baja esas dos, también la que armó la coordinadora');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'transferencia_item'), 'transferencia_item'), array['c1','c3'], 'y sus líneas');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b3'), 'transferencia_stock'), 'transferencia_stock'), array['a2','a3'],
          'b3 (recibe T2 y T3) baja las suyas');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b3'), 'transferencia_item'), 'transferencia_item'), array['c2','c3'],
          'y las líneas de las suyas');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b4'), 'transferencia_stock'), 'transferencia_stock'), array[]::text[],
          'quien no es punta de ninguna no baja nada (y no falla)');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('c1'), 'transferencia_stock'), 'transferencia_stock'), array[]::text[],
          'la coordinadora que no es punta no las baja a su teléfono');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('c1'), 'transferencia_item'), 'transferencia_item'), array[]::text[], 'ni las líneas');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('ad'), 'transferencia_stock'), 'transferencia_stock'), array[]::text[], 'ni el ADMIN');
select is((select (e ->> 'baja_a_1') || '>' || (e ->> 'baja_a_2')
             from jsonb_array_elements(pg_temp.pull(pg_temp.u('b2'), 'transferencia_item') -> 'rows' -> 'transferencia_item') e
            where right(e ->> 'id', 2) = 'c1'),
          pg_temp.u('b1')::text || '>' || pg_temp.u('b2')::text, 'la línea baja con quién da y quién recibe');

-- ---------------------------------------------------------------------------
-- 3. Los cambios de estado llegan a las dos puntas
-- ---------------------------------------------------------------------------
create temp table tb3 as select pg_temp.pull(pg_temp.u('b3'), 'transferencia_stock') as d;
select pg_temp.como_servidor();
update public.transferencia_stock set estado = 'RECHAZADO', motivo_rechazo = 'Sin existencias', decidido_en = now(),
       coordinador_id = pg_temp.u('c1') where id = pg_temp.u('a1');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b1'), 'transferencia_stock', (select d -> 'watermark' from tb1)), 'transferencia_stock'),
          array['a1'], 'al rechazarla, baja de nuevo a quien da');
select is((select e ->> 'estado' from jsonb_array_elements(
             pg_temp.pull(pg_temp.u('b2'), 'transferencia_stock') -> 'rows' -> 'transferencia_stock') e
           where right(e ->> 'id', 2) = 'a1'), 'RECHAZADO', 'y a quien recibe, con su estado');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b3'), 'transferencia_stock', (select d -> 'watermark' from tb3)), 'transferencia_stock'),
          array[]::text[], 'y a quien no es punta de esa, nada');

-- b1 pide a b2 (compañeros) una transferencia y la cancela: las dos puntas ven el estado.
select is(pg_temp.push(pg_temp.u('b1'), 'f1', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('f1'), 'origen_id', pg_temp.u('b2'), 'destino_id', pg_temp.u('b1'),
                               'estado', 'PENDIENTE_AUTORIZACION')) ->> 'outcome', 'accepted', 'b1 le pide libros a b2');
select is(pg_temp.push(pg_temp.u('b1'), 'f2', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('f2'), 'transferencia_id', pg_temp.u('f1'), 'producto_id', pg_temp.u('11'),
                               'cantidad', 2)) ->> 'outcome', 'accepted', 'con su línea');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'transferencia_stock'), 'transferencia_stock'), array['a1','a3','f1'],
          'b2 (da) ve la que pidió b1');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'transferencia_item'), 'transferencia_item'), array['c1','c3','f2'],
          'y su línea');
create temp table tb2 as select pg_temp.pull(pg_temp.u('b2'), 'transferencia_stock') as d;
select is(pg_temp.push(pg_temp.u('b1'), 'f3', 'transferencia_stock', 'update',
            jsonb_build_object('id', pg_temp.u('f1'), 'estado', 'CANCELADO'), 0) ->> 'outcome',
          'accepted', 'b1 la cancela con la versión vieja que tenía: accepted (sin conflicto de versión)');
select is((select e ->> 'estado' from jsonb_array_elements(
             pg_temp.pull(pg_temp.u('b2'), 'transferencia_stock', (select d -> 'watermark' from tb2)) -> 'rows' -> 'transferencia_stock') e),
          'CANCELADO', 'b2 baja la cancelación por el delta');
select is((select e ->> 'estado' from jsonb_array_elements(
             pg_temp.pull(pg_temp.u('b1'), 'transferencia_stock') -> 'rows' -> 'transferencia_stock') e
           where right(e ->> 'id', 2) = 'f1'), 'CANCELADO', 'y b1 la ve cancelada');

-- Una que b1 sube ya cancelada (se arrepintió antes de mandarla) para b2: baja solo a b1; b2 no la recibe.
select is(pg_temp.push(pg_temp.u('b1'), 'f4', 'transferencia_stock', 'insert',
            jsonb_build_object('id', pg_temp.u('f4'), 'origen_id', pg_temp.u('b1'), 'destino_id', pg_temp.u('b2'),
                               'estado', 'CANCELADO')) ->> 'outcome', 'accepted', 'b1 sube una que nace cancelada');
select is(pg_temp.push(pg_temp.u('b1'), 'f5', 'transferencia_item', 'insert',
            jsonb_build_object('id', pg_temp.u('f5'), 'transferencia_id', pg_temp.u('f4'), 'producto_id', pg_temp.u('11'),
                               'cantidad', 1)) ->> 'outcome', 'accepted', 'con su línea');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b1'), 'transferencia_stock'), 'transferencia_stock'), array['a1','a2','f1','f4'],
          'b1 la baja (la pidió él)');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b1'), 'transferencia_item'), 'transferencia_item'), array['c1','c2','f2','f5'],
          'con su línea');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'transferencia_stock'), 'transferencia_stock'), array['a1','a3','f1'],
          'b2, la otra punta, no la recibe (sigue con las tres de antes)');
select is(pg_temp.ids(pg_temp.pull(pg_temp.u('b2'), 'transferencia_item'), 'transferencia_item'), array['c1','c3','f2'],
          'ni su línea');

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
drop table tb1, tb2, tb3;
select pg_temp.limpiar();
select is((select count(*)::int from public.transferencia_stock
            where origen_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('b3'), pg_temp.u('b4'))), 0,
          'limpieza: no queda ninguna transferencia de la prueba');

select * from finish();
