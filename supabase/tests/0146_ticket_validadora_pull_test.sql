-- pgTAP · migración 0146 (backend-supabase#209): la campaña que valida el ticket baja al teléfono con el pull.
-- La colportora sube dos tickets: uno cuya fecha cae en su campaña y uno que no cae en ninguna. Al reinstalar, el pull
-- trae `campania_validadora_id` en cada fila (el id de la campaña, o null = lo valida Administración, siempre con la
-- clave); cuando una inscripción cambia y con ella la respuesta, el delta lleva solo el ticket que cambió (avanza
-- `xmin_w`, no `sync_version`); y el teléfono que completa la foto con la versión que bajó antes del cambio no recibe
-- un `conflict`. Ni la coordinadora de otra campaña ni el ADMIN bajan tickets por el pull.
--
-- Como 0004, 0014, 0041, 0108 y 0113, NO va en una transacción: el delta solo sirve filas commiteadas (en producción
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

-- Ids (prefijo 47): usuarios 47b1.., campañas 47e1.., tickets 47a1..; los client_op_id, 47 y dos dígitos.
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-00000000' || '47' || p)::uuid;
$$;
create or replace function pg_temp.op(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000047' || p)::uuid;
$$;

-- Borra todo lo de este archivo (como postgres). Los tickets primero: borrar al usuario con ellos puestos daría 23503.
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
begin
  delete from public.ticket where usuario_id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('ad'));
  delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.usuario_rol where usuario_id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('ad'));
  delete from auth.users where id in (pg_temp.u('b1'), pg_temp.u('c1'), pg_temp.u('c2'), pg_temp.u('ad'));
end $$;

-- Un job de push de la entidad; devuelve el resultado completo.
create or replace function pg_temp.push1(p_op uuid, p_tipo text, p_payload jsonb, p_version bigint default null)
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
           'client_op_id', p_op, 'entity', 'ticket', 'op', p_tipo,
           'sync_version', p_version, 'payload', p_payload)))) -> 'results' -> 0;
$$;
create or replace function pg_temp.tk(p_id uuid, p_fecha timestamptz) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'tipo', 'DEPOSITO', 'monto', 480000, 'fecha', p_fecha, 'numero_autorizacion', 'OP-1');
$$;

-- La clave de las filas de la entidad en un pull, ordenada por id: el sufijo de la campaña, '-' si es null.
create or replace function pg_temp.validadora(p_delta jsonb) returns text[] language sql as $$
  select coalesce(array_agg(right(e ->> 'id', 2) || '=' || coalesce(right(e ->> 'campania_validadora_id', 2), '-') order by e ->> 'id'),
                  array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'ticket', '[]'::jsonb)) e;
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 colportora en e1 (c1); c2 coordina e2, a la que b1 no pertenece; ad ADMIN.
-- ---------------------------------------------------------------------------
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'tkv47-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','c1','c2','ad']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('c1','COORDINADOR'), ('c2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 tkv47', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c1')),
  (pg_temp.u('e2'), 'e2 tkv47', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('c2'));
insert into public.campania_colportor (campania_id, usuario_id, created_at)
values (pg_temp.u('e1'), pg_temp.u('b1'), now() - interval '10 days');

-- ---------------------------------------------------------------------------
-- 1. El teléfono de b1 sube dos tickets
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.push1(pg_temp.op('01'), 'insert', pg_temp.tk(pg_temp.u('a1'), now() - interval '1 day')) ->> 'outcome', 'accepted',
          'b1 sube un ticket de ayer, de su campaña');
select is(pg_temp.push1(pg_temp.op('02'), 'insert', pg_temp.tk(pg_temp.u('a2'), now() - interval '100 days')) ->> 'outcome', 'accepted',
          'y uno de hace 100 días, que no cae en ninguna');

-- ---------------------------------------------------------------------------
-- 2. Reinstalar: pull de cero
-- ---------------------------------------------------------------------------
create temp table pull_b1 as
select sync.pull(array['ticket'], '{}'::jsonb, 1000) as d;
select is(pg_temp.validadora(d), array['a1=e1', 'a2=-'],
          'el pull trae la campaña que valida el a1 (e1) y null, Administración, en el a2') from pull_b1;
select is((select count(*)::int from pull_b1, jsonb_array_elements(d -> 'rows' -> 'ticket') e where not (e ? 'campania_validadora_id')), 0,
          'la clave viaja siempre, también cuando vale null') from pull_b1;
select is((select (e -> 'campania_validadora_id')::text from pull_b1, jsonb_array_elements(d -> 'rows' -> 'ticket') e
            where e ->> 'id' = pg_temp.u('a2')::text), 'null', 'y el valor es un null de json, no un texto') from pull_b1;
select is((select (e -> 'campania_validadora_id')::text from pull_b1, jsonb_array_elements(d -> 'rows' -> 'ticket') e
            where e ->> 'id' = pg_temp.u('a1')::text), '"' || pg_temp.u('e1')::text || '"', 'el del a1 es el id de la campaña') from pull_b1;

-- Ni la coordinadora de otra campaña ni la de la suya ni el ADMIN bajan tickets por el pull.
select pg_temp.actuar_como(pg_temp.u('c2'));
select is(pg_temp.validadora(sync.pull(array['ticket'], '{}'::jsonb, 1000)), array[]::text[], 'la coordinadora de otra campaña no baja nada');
select pg_temp.actuar_como(pg_temp.u('c1'));
select is(pg_temp.validadora(sync.pull(array['ticket'], '{}'::jsonb, 1000)), array[]::text[], 'la de su campaña tampoco (los lee por tickets_de_campania)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.validadora(sync.pull(array['ticket'], '{}'::jsonb, 1000)), array[]::text[], 'ni el ADMIN');

-- Sin cambios, el pull siguiente no trae nada.
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select sync.pull(array['ticket'], d -> 'watermark', 1000) -> 'rows' from pull_b1), '{}'::jsonb,
          'sin cambios, el pull siguiente no trae nada');

-- ---------------------------------------------------------------------------
-- 3. La inscripción cambia y con ella la respuesta: el delta lleva solo el ticket que cambió
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
update public.campania_colportor set tramos_afuera = array[tstzrange(now() - interval '2 days', now() - interval '12 hours')]
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table delta1 as
select sync.pull(array['ticket'], d -> 'watermark', 1000) as d from pull_b1;
select is(pg_temp.validadora(d), array['a1=-'],
          'con un hueco en la inscripción que cubre la fecha del ticket, el delta trae el a1 con null (y no el a2, que no cambió)') from delta1;

-- El hueco se cierra: el ticket otra vez es de e1.
select pg_temp.como_servidor();
update public.campania_colportor set tramos_afuera = '{}'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table delta2 as
select sync.pull(array['ticket'], (select d -> 'watermark' from delta1), 1000) as d;
select is(pg_temp.validadora(d), array['a1=e1'], 'cerrado el hueco, el delta lleva el a1 con la campaña de nuevo') from delta2;

-- Un cambio que no cambia la respuesta (una baja que llega más tarde que el ticket) no mueve el ticket.
select pg_temp.como_servidor();
update public.campania_colportor set deleted_at = now() + interval '1 hour'
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
update public.campania_colportor set deleted_at = null
 where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select pg_temp.validadora(sync.pull(array['ticket'], (select d -> 'watermark' from delta2), 1000))), array[]::text[],
          'una baja y una reactivación que no cambian la respuesta no mueven ningún ticket: el delta viene vacío');

-- ---------------------------------------------------------------------------
-- 4. El teléfono completa la foto con la versión que bajó antes de que cambiara la campaña
-- ---------------------------------------------------------------------------
-- La campaña del a1 cambió dos veces desde el pull de cero (e1 → null → e1), siempre por el servidor y sin subir
-- sync_version: la app manda la foto con la versión que bajó en ese pull y tiene que entrar.
create temp table viejo as
select (e ->> 'sync_version')::bigint as v from pull_b1, jsonb_array_elements(d -> 'rows' -> 'ticket') e
 where e ->> 'id' = pg_temp.u('a1')::text;
select is((select sync_version from public.ticket where id = pg_temp.u('a1')), (select v from viejo),
          'el servidor sigue en la versión del pull de cero: los recálculos no subieron sync_version');
select is(pg_temp.push1(pg_temp.op('03'), 'update',
                        jsonb_build_object('id', pg_temp.u('a1'), 'url_cloud', pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg',
                                           'campania_validadora_id', null),
                        (select v from viejo)) ->> 'outcome',
          'accepted', 'completar la foto con esa versión entra (aunque el payload traiga la clave del servidor)');
select is((select url_cloud from public.ticket where id = pg_temp.u('a1')), pg_temp.u('b1')::text || '/' || pg_temp.u('a1')::text || '.jpg',
          'y la ruta de la foto quedó puesta');
select is((select campania_validadora_id from public.ticket where id = pg_temp.u('a1')), pg_temp.u('e1'),
          'y la campaña sigue siendo la del servidor');

select pg_temp.como_servidor();
select pg_temp.limpiar();
select is((select count(*)::int from public.ticket where usuario_id in (pg_temp.u('b1'))), 0, 'limpio: no quedó nada de este archivo');

select * from finish();
