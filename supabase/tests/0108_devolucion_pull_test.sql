-- pgTAP · migración 0108 (backend-supabase#134): devolucion en el pull. Tras reinstalar, la app baja de
-- cero las devoluciones de la colportora (fase 3 de recover(), contrato §7), con los productos devueltos y la
-- plata tal cual; los cambios siguientes (corregir, dar de baja) llegan por el delta; y nadie baja las de otro.
--
-- Como 0004, 0014 y 0041, NO va en una transacción: el delta solo sirve filas commiteadas (en producción el
-- push y el pull son dos requests). Limpia al final, y también al empezar: si una corrida se cortó antes de
-- la limpieza, la siguiente no choca con lo que dejó.

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

-- Ids (prefijo 82): usuarios 82b1.., productos 8211.., ventas 8271.., devoluciones 82d1..; los client_op_id,
-- 82 y dos dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '82' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000082' || p)::uuid;
$$;

-- Borra todo lo de este archivo (como postgres). Las devoluciones primero: borrar al usuario con ellas
-- puestas daría 23503 (tg_auditoria_update deshace el ON DELETE SET NULL).
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.devolucion where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('ad'));
  delete from public.venta where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.espacio_persona where created_by in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.espacio where created_by in (pg_temp.u('b1'), pg_temp.u('b2'));
  delete from public.ubicacion where ciudad_id = pg_temp.u('f1');
  delete from public.producto where id in (pg_temp.u('11'), pg_temp.u('12'));
  delete from public.ciudad where id = pg_temp.u('f1');
  delete from public.pais where id = pg_temp.u('f0');
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('ad'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('ad'));
end $$;

-- Un job de push de la entidad; devuelve el resultado.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns text language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'devolucion', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0 ->> 'outcome';
$$;
create or replace function pg_temp.dev(p_id uuid, p_venta uuid, p_items jsonb, p_retenido int default 0)
returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'venta_id', p_venta, 'productos_devueltos', p_items,
                            'dinero_retenido', p_retenido, 'fecha_devolucion', '2026-10-05T12:00:00Z');
$$;
create or replace function pg_temp.item(p_producto text, p_cantidad int) returns jsonb language sql as $$
  select jsonb_build_object('producto_id', pg_temp.u(p_producto), 'cantidad', p_cantidad);
$$;

-- Una columna de las filas de la entidad en un pull, ordenadas por id.
create or replace function pg_temp.col(p_delta jsonb, p_col text) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> p_col, '-') order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'devolucion', '[]'::jsonb)) e;
$$;
-- Los sufijos de los ids (los dos últimos caracteres) de lo que bajó.
create or replace function pg_temp.ids(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'devolucion', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 y b2 colportoras, ad ADMIN; una venta de cada una; dos productos.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dev82-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro 1 t82', 'LIBRO'),
  (pg_temp.u('12'), 'Libro 2 t82', 'LIBRO');
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('f0'), 'Pais dev82', 'ZS');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('f1'), 'Ciudad dev82', 'Departamento de prueba', pg_temp.u('f0'), -34.90, -56.20);
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
  (pg_temp.u('71'), pg_temp.u('51'), 'T-8271', 450000, '2026-10-01 15:00:00+00', pg_temp.u('b1'), pg_temp.u('b1')),
  (pg_temp.u('72'), pg_temp.u('53'), 'T-8272', 260000, '2026-10-01 16:00:00+00', pg_temp.u('b2'), pg_temp.u('b2'));

-- ---------------------------------------------------------------------------
-- 1. El teléfono de b1 sube tres devoluciones y el de b2, una
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert',
                        pg_temp.dev(pg_temp.u('d1'), pg_temp.u('71'), jsonb_build_array(pg_temp.item('11', 2), pg_temp.item('12', 1)))
                          || jsonb_build_object('monto_reembolsado', 190000)),
          'accepted', 'b1 sube una devolución de dos productos con un reembolso en el momento');
select is(pg_temp.push1(pg_temp.op('02'), 'insert',
                        pg_temp.dev(pg_temp.u('d2'), pg_temp.u('71'), jsonb_build_array(pg_temp.item('11', 1)), 50000)),
          'accepted', 'b1 sube otra con una retención y sin reembolso');
select is(pg_temp.push1(pg_temp.op('03'), 'insert',
                        pg_temp.dev(pg_temp.u('d3'), pg_temp.u('71'), jsonb_build_array(pg_temp.item('12', 1)))),
          'accepted', 'y una tercera sin plata de por medio');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('04'), 'insert',
                        pg_temp.dev(pg_temp.u('d4'), pg_temp.u('72'), jsonb_build_array(pg_temp.item('11', 1)))),
          'accepted', 'b2 sube la suya');

-- ---------------------------------------------------------------------------
-- 2. Reinstalar: pull de cero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pull_b1 as
select sync.pull(array['devolucion'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d), array['d1', 'd2', 'd3'], 'b1 baja sus tres devoluciones y nada más (no la d4 de b2)') from pull_b1;
select is(pg_temp.col(d, 'monto_reembolsado'), array['190000', '-', '-'],
          'con el reembolso en el momento donde lo hubo, y sin él (null) donde no') from pull_b1;
select is(pg_temp.col(d, 'dinero_retenido'), array['0', '50000', '0'], 'y la retención') from pull_b1;
select is(pg_temp.col(d, 'venta_id'), array[pg_temp.u('71')::text, pg_temp.u('71')::text, pg_temp.u('71')::text],
          'de la venta que corresponde') from pull_b1;
select is((select (e -> 'productos_devueltos')
             from pull_b1, jsonb_array_elements(d -> 'rows' -> 'devolucion') e
            where e ->> 'id' = pg_temp.u('d1')::text),
          jsonb_build_array(pg_temp.item('11', 2), pg_temp.item('12', 1)),
          'los productos devueltos bajan como un arreglo, tal cual se subieron') from pull_b1;
select is((select bool_and((e ->> 'fecha_devolucion')::timestamptz = '2026-10-05T12:00:00Z'::timestamptz)
             from pull_b1, jsonb_array_elements(d -> 'rows' -> 'devolucion') e), true,
          'con la fecha que registró el teléfono') from pull_b1;
select is(pg_temp.col(d, 'colportor_id'), array[pg_temp.u('b1')::text, pg_temp.u('b1')::text, pg_temp.u('b1')::text],
          'todas suyas') from pull_b1;
select is((select d ->> 'has_more' from pull_b1), 'false', 'sin más páginas');
select ok((select not jsonb_path_exists(d, '$.rows.devolucion[*].xmin_w') from pull_b1), 'xmin_w no viaja');
select ok((select jsonb_path_exists(d, '$.rows.devolucion[*].sync_version') from pull_b1),
          'sync_version sí (el teléfono la manda en el próximo update)');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.ids(sync.pull(array['devolucion'], '{}'::jsonb, 1000))), array['d4'], 'b2 baja solo la suya');

select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.ids(sync.pull(array['devolucion'], '{}'::jsonb, 1000)), array[]::text[],
          'el ADMIN no baja las de nadie');

-- Sin cambios, el pull siguiente no trae nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['devolucion'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. Los cambios llegan por el delta
-- ---------------------------------------------------------------------------
-- b1 corrige la retención de la d2 y da de baja la d3.
select is(pg_temp.push1(pg_temp.op('05'), 'update', jsonb_build_object('id', pg_temp.u('d2'), 'dinero_retenido', 60000), 0),
          'accepted', 'b1 corrige la retención de la d2');
select is(pg_temp.push1(pg_temp.op('06'), 'delete', jsonb_build_object('id', pg_temp.u('d3')), 0),
          'accepted', 'y da de baja la d3');
create temp table delta_b1 as
select sync.pull(array['devolucion'], d -> 'watermark', 1000) as d from pull_b1;
select is(pg_temp.ids(d), array['d2', 'd3'], 'el delta trae solo lo que cambió: d2 y d3') from delta_b1;
select is(pg_temp.col(d, 'dinero_retenido'), array['60000', '0'], 'la d2 con la retención corregida') from delta_b1;
select is((select (e ->> 'deleted_at') is not null
             from delta_b1, jsonb_array_elements(d -> 'rows' -> 'devolucion') e
            where e ->> 'id' = pg_temp.u('d3')::text), true,
          'y la d3 baja como tombstone (deleted_at), no desaparece') from delta_b1;

-- El teléfono de b2 no se entera de nada de lo de b1.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.ids(sync.pull(array['devolucion'], '{}'::jsonb, 1000))), array['d4'], 'b2 sigue bajando solo la suya');

select pg_temp.como_servidor();
select pg_temp.limpiar();
select is((select count(*)::int from public.devolucion where colportor_id in (pg_temp.u('b1'), pg_temp.u('b2'))), 0,
          'limpio: no quedó nada de este archivo');

select * from finish();
