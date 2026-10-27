-- pgTAP · migración 0113 (backend-supabase#108): ticket en el pull. Tras reinstalar, la app baja de cero los
-- tickets de la colportora (con su estado, el motivo del rechazo y la ruta de la foto); lo que decide el
-- coordinador (validar, rechazar) llega por el delta; y nadie baja los de otra: ni el coordinador ni el ADMIN
-- (el panel los lee por tickets_de_campania(), no por el pull).
--
-- Como 0004, 0014, 0041 y 0108, NO va en una transacción: el delta solo sirve filas commiteadas (en producción
-- el push y el pull son dos requests). Limpia al final, y también al empezar.

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

-- Ids (prefijo 83): usuarios 83b1.., tickets 83a1..; los client_op_id, 83 y dos dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '83' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000083' || p)::uuid;
$$;

-- Borra todo lo de este archivo (como postgres). Los tickets primero: borrar al usuario con ellos puestos
-- daría 23503 (tg_auditoria_update deshace el ON DELETE SET NULL).
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.ticket where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('b2'), pg_temp.u('c1'), pg_temp.u('ad'));
end $$;

-- Un job de push de la entidad; devuelve el resultado.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns text language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'ticket', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0 ->> 'outcome';
$$;
create or replace function pg_temp.tk(p_id uuid, p_extra jsonb default '{}'::jsonb) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'tipo', 'COBRO_TARJETA', 'monto', 480000, 'fecha', now(),
                            'numero_autorizacion', '004512', 'tarjeta_tipo', 'DEBITO', 'tarjeta_marca', 'VISA') || p_extra;
$$;

-- Una columna de las filas de la entidad en un pull, ordenadas por id.
create or replace function pg_temp.col(p_delta jsonb, p_col text) returns text[] language sql as $$
  select coalesce(array_agg(coalesce(e ->> p_col, '-') order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ticket', '[]'::jsonb)) e;
$$;
-- Los sufijos de los ids (los dos últimos caracteres) de lo que bajó.
create or replace function pg_temp.ids(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ticket', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 y b2 colportoras, c1 coordinador, ad ADMIN.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tkp83-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','c1','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('c1','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- ---------------------------------------------------------------------------
-- 1. El teléfono de b1 sube tres tickets y el de b2, uno
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.tk(pg_temp.u('a1'))), 'accepted', 'b1 sube un ticket de tarjeta');
select is(pg_temp.push1(pg_temp.op('02'), 'insert',
                        pg_temp.tk(pg_temp.u('a2'), jsonb_build_object('tipo', 'DEPOSITO', 'numero_autorizacion', 'OP-1'))
                          - 'tarjeta_tipo' - 'tarjeta_marca'),
          'accepted', 'uno de un depósito, sin tarjeta');
select is(pg_temp.push1(pg_temp.op('03'), 'insert',
                        pg_temp.tk(pg_temp.u('a3'), jsonb_build_object('url_cloud', pg_temp.u('b1')::text || '/' || pg_temp.u('a3')::text || '.jpg'))),
          'accepted', 'y uno con su foto');
select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.push1(pg_temp.op('04'), 'insert', pg_temp.tk(pg_temp.u('a4'))), 'accepted', 'b2 sube el suyo');

-- ---------------------------------------------------------------------------
-- 2. Reinstalar: pull de cero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table pull_b1 as
select sync.pull(array['ticket'], '{}'::jsonb, 1000) as d;
select is(pg_temp.ids(d), array['a1', 'a2', 'a3'], 'b1 baja sus tres tickets y nada más (no el a4 de b2)') from pull_b1;
select is(pg_temp.col(d, 'estado'), array['PENDIENTE', 'PENDIENTE', 'PENDIENTE'], 'todos por validar') from pull_b1;
select is(pg_temp.col(d, 'monto'), array['480000', '480000', '480000'], 'con el monto tal cual') from pull_b1;
select is(pg_temp.col(d, 'numero_autorizacion'), array['004512', 'OP-1', '004512'], 'la autorización (o el nº de operación)') from pull_b1;
select is(pg_temp.col(d, 'tarjeta_tipo'), array['DEBITO', '-', 'DEBITO'], 'la tarjeta, donde la hay') from pull_b1;
select is(pg_temp.col(d, 'url_cloud'), array['-', '-', pg_temp.u('b1')::text || '/' || pg_temp.u('a3')::text || '.jpg'],
          'y la ruta de la foto, donde la hay (la URL firmada se pide a Storage con ella)') from pull_b1;
select is(pg_temp.col(d, 'usuario_id'), array[pg_temp.u('b1')::text, pg_temp.u('b1')::text, pg_temp.u('b1')::text], 'todos suyos') from pull_b1;
select is((select d ->> 'has_more' from pull_b1), 'false', 'sin más páginas');
select ok((select not jsonb_path_exists(d, '$.rows.ticket[*].xmin_w') from pull_b1), 'xmin_w no viaja');
select ok((select jsonb_path_exists(d, '$.rows.ticket[*].sync_version') from pull_b1),
          'sync_version sí (el teléfono la manda en el próximo update)');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.ids(sync.pull(array['ticket'], '{}'::jsonb, 1000))), array['a4'], 'b2 baja solo el suyo');

-- Ni el coordinador ni el ADMIN bajan tickets (la RLS les deja leer, pero el pull es de la dueña).
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.ids(sync.pull(array['ticket'], '{}'::jsonb, 1000)), array[]::text[], 'el coordinador no baja tickets de nadie por el pull');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.ids(sync.pull(array['ticket'], '{}'::jsonb, 1000)), array[]::text[], 'el ADMIN tampoco');

-- Sin cambios, el pull siguiente no trae nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['ticket'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. Lo que decide el coordinador llega por el delta
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.ticket set estado = 'VALIDADO', revisado_por = pg_temp.u('c1'), revisado_en = now() where id = pg_temp.u('a1');
update public.ticket set estado = 'RECHAZADO', revisado_por = pg_temp.u('c1'), revisado_en = now(),
                         motivo_rechazo = 'La foto no se lee' where id = pg_temp.u('a2');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table delta_b1 as
select sync.pull(array['ticket'], d -> 'watermark', 1000) as d from pull_b1;
select is(pg_temp.ids(d), array['a1', 'a2'], 'el delta trae solo lo que cambió: a1 y a2') from delta_b1;
select is(pg_temp.col(d, 'estado'), array['VALIDADO', 'RECHAZADO'], 'validado y rechazado') from delta_b1;
select is(pg_temp.col(d, 'motivo_rechazo'), array['-', 'La foto no se lee'], 'el rechazo con su motivo, para mostrárselo a la colportora') from delta_b1;
select is(pg_temp.col(d, 'revisado_por'), array[pg_temp.u('c1')::text, pg_temp.u('c1')::text], 'y quién lo revisó') from delta_b1;

-- La colportora completa la foto del a1 ya validado: la política no lo ve (conflict). El del a3 sí se puede.
select is(pg_temp.push1(pg_temp.op('05'), 'update',
                        jsonb_build_object('id', pg_temp.u('a1'), 'url_cloud', pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg'),
                        (select (e ->> 'sync_version')::bigint from delta_b1, jsonb_array_elements(d -> 'rows' -> 'ticket') e
                          where e ->> 'id' = pg_temp.u('a1')::text)),
          'conflict', 'subir la foto de un ticket ya validado vuelve conflict: gana el servidor');
-- El servidor suelta la foto vencida del a3: baja al teléfono como url_cloud null.
select pg_temp.como_servidor();
select is(public.soltar_foto_de_ticket(pg_temp.u('a3')), true, 'el servidor suelta la foto vencida del a3');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table delta2_b1 as
select sync.pull(array['ticket'], (select d -> 'watermark' from delta_b1), 1000) as d;
select is(pg_temp.ids(d), array['a3'], 'el delta siguiente trae el a3') from delta2_b1;
select is(pg_temp.col(d, 'url_cloud'), array['-'], 'sin la ruta de la foto: el teléfono muestra «la foto venció»') from delta2_b1;
select is(pg_temp.col(d, 'monto'), array['480000'], 'pero con todos sus datos') from delta2_b1;

-- El teléfono de b2 no se entera de nada de lo de b1.
select pg_temp.actuar_como(pg_temp.u('b2'));
select is((select pg_temp.ids(sync.pull(array['ticket'], '{}'::jsonb, 1000))), array['a4'], 'b2 sigue bajando solo el suyo');

select pg_temp.como_servidor();
select pg_temp.limpiar();
select is((select count(*)::int from public.ticket where usuario_id in (pg_temp.u('b1'), pg_temp.u('b2'))), 0,
          'limpio: no quedó nada de este archivo');

select * from finish();
