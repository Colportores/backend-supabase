-- pgTAP · migración 0022 — las puertas del sync en public (backend-supabase#53, ADR-013):
-- public.sync_push y public.sync_pull devuelven lo mismo que sync.*, con la RLS de quien llama;
-- el sobre y los topes se rechazan con CS001 a CS003; sin sesión, 42501; y desde la Data API no
-- hay otro camino a sync.*.
--
-- Como 0004 y 0014, NO va en una transacción: el delta solo sirve filas commiteadas. Limpia al
-- final.

select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, false);
  perform set_config('request.jwt.claim.sub', p_uid::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

-- authenticated sin JWT, o anon: lo que llega por PostgREST sin sesión o con una sesión rota.
create or replace function pg_temp.actuar_sin_jwt(p_rol text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
  perform set_config('role', p_rol, false);
end $$;

create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', false);
  perform set_config('request.jwt.claims', '', false);
  perform set_config('request.jwt.claim.sub', '', false);
end $$;

create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000027' || p)::uuid;
$$;

create or replace function pg_temp.sobre(p_schema_version jsonb default '1') returns jsonb language sql as $$
  select jsonb_build_object('device_id', '01920000-0000-7000-8000-0000000027d0',
                            'app_version', '1.4.2', 'schema_version', p_schema_version);
$$;

-- El sync.push() de referencia, deshecho: lo que habría devuelto, sin dejar nada escrito. Las
-- variables de plpgsql no vuelven atrás con la subtransacción.
create or replace function pg_temp.push_de_referencia(p_jobs jsonb, p_device uuid) returns jsonb
language plpgsql as $$
declare
  v jsonb;
begin
  begin
    v := sync.push(p_jobs, p_device);
    raise exception 'deshacer' using errcode = 'ZZ999';
  exception when sqlstate 'ZZ999' then
    return v;
  end;
end $$;

-- Los ids de una entidad en la respuesta de un pull, ordenados.
create or replace function pg_temp.ids(p_delta jsonb, p_entidad text) returns text[] language sql as $$
  select coalesce(array_agg(e ->> 'id' order by e ->> 'id'), array[]::text[])
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> p_entidad, '[]'::jsonb)) e;
$$;

create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;

-- ---------------------------------------------------------------------------
-- Fixtures (como postgres). b1 está en Verano (c1) con la zona Z1; c2 es de otra campaña.
--   01 en Z1      02 en c1, fuera de Z1      03 en c2 (no la ve)
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('b1'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'entrada-b1@example.com', 'x', now(), now(), now());

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais entrada', 'ZE');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad entrada', pg_temp.u('c0'), -34.9, -56.2),
  (pg_temp.u('c2'), 'Otra entrada',   pg_temp.u('c0'), -34.8, -56.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'Verano entrada', 'VERANO',     current_date - 10, current_date + 30),
  (pg_temp.u('e2'), 'Otra entrada',   'PERMANENTE', current_date - 10, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1')),
  (pg_temp.u('f2'), pg_temp.u('e2'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson)
values (pg_temp.u('d1'), 'Z1 entrada', pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91));
insert into public.campania_colportor (campania_id, usuario_id, zona_id)
values (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'));

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  (pg_temp.u('01'), 'CASA', 'Entrada', '1', -34.915, -56.185, pg_temp.u('c1')),
  (pg_temp.u('02'), 'CASA', 'Entrada', '2', -34.915, -56.215, pg_temp.u('c1')),
  (pg_temp.u('03'), 'CASA', 'Entrada', '3', -34.8,   -56.0,   pg_temp.u('c2'));

-- ---------------------------------------------------------------------------
-- 1. Privilegios: solo authenticated llama a las puertas
-- ---------------------------------------------------------------------------
select function_privs_are('public', 'sync_push', array['jsonb'], 'anon', array[]::text[],
                          'anon no puede llamar a sync_push');
select function_privs_are('public', 'sync_pull', array['jsonb'], 'anon', array[]::text[],
                          'anon no puede llamar a sync_pull');
select function_privs_are('public', 'sync_push', array['jsonb'], 'authenticated', array['EXECUTE'],
                          'authenticated puede llamar a sync_push');
select function_privs_are('public', 'sync_pull', array['jsonb'], 'authenticated', array['EXECUTE'],
                          'authenticated puede llamar a sync_pull');
select is(
  (select count(*)::integer
     from pg_proc p, aclexplode(p.proacl) a
    where p.oid in ('public.sync_push(jsonb)'::regprocedure, 'public.sync_pull(jsonb)'::regprocedure)
      and a.grantee = 0),
  0,
  'PUBLIC no tiene EXECUTE sobre las puertas (el default de CREATE FUNCTION se revocó)'
);
select is(
  (select array_agg(p.proname::text || ':' || p.prosecdef::text order by p.proname)
     from pg_proc p
    where p.oid in ('public.sync_push(jsonb)'::regprocedure, 'public.sync_pull(jsonb)'::regprocedure)),
  array['sync_pull:false', 'sync_push:false'],
  'las dos son SECURITY INVOKER'
);
select is(
  (select array_agg(p.proname::text order by p.proname)
     from pg_proc p
    where p.oid in ('public.sync_push(jsonb)'::regprocedure, 'public.sync_pull(jsonb)'::regprocedure)
      and p.proconfig @> array['search_path=""']),
  array['sync_pull', 'sync_push'],
  'las dos con search_path vacío'
);

-- ---------------------------------------------------------------------------
-- 2. Sin sesión: 42501
-- ---------------------------------------------------------------------------
select pg_temp.actuar_sin_jwt('anon');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', '[]'::jsonb)) $$,
                 '42501', null, 'anon: sync_push falla con 42501 (sin EXECUTE)');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '[]'::jsonb)) $$,
                 '42501', null, 'anon: sync_pull falla con 42501 (sin EXECUTE)');

select pg_temp.actuar_sin_jwt('authenticated');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', '[]'::jsonb)) $$,
                 '42501', 'sync_push requiere un usuario autenticado', 'authenticated sin JWT: sync_push falla con 42501');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '[]'::jsonb)) $$,
                 '42501', 'sync_pull requiere un usuario autenticado', 'authenticated sin JWT: sync_pull falla con 42501');
select throws_ok($$ select public.sync_push('{}'::jsonb) $$,
                 '42501', null, 'sin JWT, la sesión se mira antes que el sobre: no se le dice nada del pedido');

-- ---------------------------------------------------------------------------
-- 3. Push: lo mismo que sync.push(), con la RLS del colportor
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
create temp table lote as
select jsonb_build_array(
  -- Alta de una casa en su ciudad: entra.
  jsonb_build_object('client_op_id', pg_temp.u('a1'), 'entity', 'ubicacion', 'op', 'insert', 'sync_version', null,
                     'payload', jsonb_build_object('id', pg_temp.u('04'), 'tipo', 'CASA', 'calle', 'Entrada', 'numero', '4',
                                                   'lat', -34.916, 'lon', -56.186, 'ciudad_id', pg_temp.u('c1'))),
  -- Corregir una casa de c2, que la RLS no le muestra: no entra.
  jsonb_build_object('client_op_id', pg_temp.u('a2'), 'entity', 'ubicacion', 'op', 'update', 'sync_version', 1,
                     'payload', jsonb_build_object('id', pg_temp.u('03'), 'numero', '33')),
  -- Un depto en esa casa: tampoco.
  jsonb_build_object('client_op_id', pg_temp.u('a3'), 'entity', 'espacio', 'op', 'insert', 'sync_version', null,
                     'payload', jsonb_build_object('id', pg_temp.u('05'), 'ubicacion_id', pg_temp.u('03')))
) as jobs;

create temp table push_ref as
select pg_temp.push_de_referencia((select jobs from lote), pg_temp.u('d0')) as r;
select is((select count(*)::integer from public.ubicacion where id = pg_temp.u('04')), 0,
          'la referencia de sync.push() se deshizo: no dejó la casa');

create temp table push_puerta as
select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', (select jobs from lote))) as r;

select is((select r - 'server_time' from push_puerta), (select r - 'server_time' from push_ref),
          'sync_push devuelve lo mismo que sync.push() (salvo server_time)');
select ok((select r ? 'server_time' from push_puerta), 'con su server_time');
select is((select jsonb_path_query_array(r, '$.results[*].outcome') from push_puerta),
          '["accepted", "invalid", "invalid"]'::jsonb,
          'la RLS es la del colportor: entra lo de su ciudad, lo de c2 no');
select is((select count(*)::integer from public.ubicacion where id = pg_temp.u('04')), 1,
          'la casa quedó escrita');

select pg_temp.como_servidor();
select is((select device_id from sync.op_cache where client_op_id = pg_temp.u('a1')), pg_temp.u('d0'),
          'el device_id del sobre llega al cache de client_op_id');
select is((select ubicacion.created_by from public.ubicacion where id = pg_temp.u('04')), pg_temp.u('b1'),
          'y la fila es del colportor del JWT');

-- Reintentar el mismo lote por la puerta: duplicate, como sync.push().
select pg_temp.actuar_como(pg_temp.u('b1'));
select is((select jsonb_path_query_array(
             public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', (select jobs from lote))),
             '$.results[0].outcome')),
          '["duplicate"]'::jsonb, 'el reintento del lote vuelve duplicate');

-- ---------------------------------------------------------------------------
-- 4. Pull: lo mismo que sync.pull() con alcance ciudad, y el watermark como string
-- ---------------------------------------------------------------------------
create temp table pull_ref as
select sync.pull(array['ubicacion'], '{}'::jsonb, 1000, pg_temp.u('d0'), 'ciudad') as d;
create temp table pull_puerta as
select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '["ubicacion"]'::jsonb,
                                           'limit', 1000)) as d;

select is((select jsonb_typeof(d -> 'watermark') from pull_puerta), 'string',
          'el watermark sale como string: para el motor es opaco');
select is((select (d ->> 'watermark')::jsonb from pull_puerta), (select d -> 'watermark' from pull_ref),
          'y adentro es el watermark de sync.pull()');
select is((select d - 'server_time' - 'watermark' from pull_puerta), (select d - 'server_time' - 'watermark' from pull_ref),
          'sync_pull devuelve lo mismo que sync.pull() con alcance ciudad (salvo server_time)');
select is(pg_temp.ids(d, 'ubicacion'),
          array[pg_temp.u('01')::text, pg_temp.u('02')::text, pg_temp.u('04')::text],
          'toda la ciudad de su zona (contrato 0.9.8), también fuera de Z1; c2 no')
  from pull_puerta;
select isnt(pg_temp.ids(sync.pull(array['ubicacion'], '{}'::jsonb, 1000, pg_temp.u('d0')), 'ubicacion'),
            (select pg_temp.ids(d, 'ubicacion') from pull_puerta),
            'el default de sync.pull() (zona) bajaría otra cosa: la puerta no lo usa');

-- Paginado: has_more y el watermark de vuelta, como string.
create temp table pagina_1 as
select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '["ubicacion"]'::jsonb, 'limit', 2)) as d;
select is((select d -> 'has_more' from pagina_1), 'true'::jsonb, 'con limit 2 y tres casas, has_more');
create temp table pagina_2 as
select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '["ubicacion"]'::jsonb, 'limit', 2,
                                           'watermark', (select d -> 'watermark' from pagina_1))) as d;
select is((select d - 'server_time' - 'watermark' from pagina_2),
          (select sync.pull(array['ubicacion'], (select (d ->> 'watermark')::jsonb from pagina_1), 2, pg_temp.u('d0'), 'ciudad')
                  - 'server_time' - 'watermark'),
          'la página siguiente, con el watermark devuelto, es la de sync.pull()');
select is((select pg_temp.ids(p1.d, 'ubicacion') || pg_temp.ids(p2.d, 'ubicacion') from pagina_1 p1, pagina_2 p2),
          array[pg_temp.u('01')::text, pg_temp.u('02')::text, pg_temp.u('04')::text],
          'entre las dos páginas, las tres casas');
select is((select d -> 'has_more' from pagina_2), 'false'::jsonb, 'y la segunda cierra');

-- ---------------------------------------------------------------------------
-- 5. El sobre: CS001 inválido, CS002 viejo o ausente
-- ---------------------------------------------------------------------------
select throws_ok($$ select public.sync_push('{"jobs": []}'::jsonb) $$,
                 'CS002', null, 'push sin sobre: CS002 (app anterior al sobre, como el 426)');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre('0'), 'jobs', '[]'::jsonb)) $$,
                 'CS002', 'schema_version 0 es vieja: la mínima es 1', 'push con schema_version vieja: CS002');
select throws_ok($$ select public.sync_push('{"device": "x", "jobs": []}'::jsonb) $$,
                 'CS001', null, 'push con un sobre que no es objeto: CS001');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre() || '{"device_id": "no-uuid"}', 'jobs', '[]'::jsonb)) $$,
                 'CS001', 'device_id tiene que ser un UUID', 'push con device_id que no es UUID: CS001');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre() - 'device_id', 'jobs', '[]'::jsonb)) $$,
                 'CS001', null, 'push sin device_id: CS001');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre('"1"'), 'jobs', '[]'::jsonb)) $$,
                 'CS001', 'schema_version tiene que ser un entero', 'push con schema_version string: CS001');
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre('1.5'), 'jobs', '[]'::jsonb)) $$,
                 'CS001', null, 'push con schema_version no entera: CS001');
select lives_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre() - 'app_version', 'jobs', '[]'::jsonb)) $$,
                'sin app_version entra igual: es telemetría');

select throws_ok($$ select public.sync_pull('{"entities": ["ubicacion"]}'::jsonb) $$,
                 'CS002', null, 'pull sin sobre: CS002');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre('0'), 'entities', '[]'::jsonb)) $$,
                 'CS002', null, 'pull con schema_version vieja: CS002');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre() || '{"device_id": 7}', 'entities', '[]'::jsonb)) $$,
                 'CS001', null, 'pull con device_id que no es UUID: CS001');

-- El resto del cuerpo con otra forma: 22023, como sync.push() con p_jobs que no es array.
select throws_ok($$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', '{}'::jsonb)) $$,
                 '22023', null, 'push con jobs que no es array: 22023');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', 'ubicacion')) $$,
                 '22023', null, 'pull con entities que no es array (la lista con comas del GET): 22023');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '["ubicacion"]'::jsonb,
                                                               'watermark', '{}'::jsonb)) $$,
                 '22023', null, 'pull con el watermark como objeto y no como el string devuelto: 22023');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '["ubicacion"]'::jsonb,
                                                               'watermark', 'eyJ0cyI6')) $$,
                 '22023', null, 'pull con un watermark que no salió del pull: 22023');
select throws_ok($$ select public.sync_pull(jsonb_build_object('device', pg_temp.sobre(), 'entities', '["ubicacion"]'::jsonb,
                                                               'limit', 1.5)) $$,
                 '22023', null, 'pull con limit no entero: 22023');

-- ---------------------------------------------------------------------------
-- 6. Topes del lote en la puerta: CS003
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs',
       (select jsonb_agg(jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'delete',
                                            'sync_version', 1, 'payload', '{}'::jsonb))
          from generate_series(1, 501)))) $$,
  'CS003', 'lote de 501 jobs: el máximo es 500', '501 jobs: CS003');
select throws_ok(
  $$ select public.sync_push(jsonb_build_object('device', pg_temp.sobre(), 'jobs', jsonb_build_array(
       jsonb_build_object('client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update', 'sync_version', 1,
                          'payload', jsonb_build_object('id', pg_temp.u('01'), 'calle', repeat('x', 1024 * 1024)))))) $$,
  'CS003', null, 'más de 1 MB: CS003, aunque sea un solo job');
select is((select count(*)::integer from public.ubicacion where id = pg_temp.u('01') and length(calle) > 100), 0,
          'y no escribió nada');

-- sync.push() conserva sus topes, y el hint del de 500 ya no nombra al BFF.
select pg_temp.como_servidor();
select ok(pg_get_functiondef('sync.push(jsonb,uuid)'::regprocedure) not ilike '%BFF%',
          'sync.push() ya no menciona al BFF');
select ok(pg_get_functiondef('sync.push(jsonb,uuid)'::regprocedure) ilike '%8 * 1024 * 1024%',
          'y conserva su tope de 8 MB como defensa');

-- ---------------------------------------------------------------------------
-- 7. La Data API no llega a sync.*
-- ---------------------------------------------------------------------------
-- PostgREST solo resuelve funciones de los schemas expuestos (config.toml: public y
-- graphql_public; sync no está). Lo que la base puede garantizar: anon no tiene nada en sync, y
-- las únicas funciones de los schemas expuestos que authenticated puede llamar y que entran a
-- sync.push() o sync.pull() son las dos puertas.
select ok(not has_schema_privilege('anon', 'sync', 'usage'), 'anon no tiene USAGE sobre sync');
select is(
  (select count(*)::integer
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'sync' and has_function_privilege('anon', p.oid, 'execute')),
  0,
  'anon no puede ejecutar ninguna función de sync, tampoco sync.validar_sobre'
);
select is(
  (select array_agg(n.nspname || '.' || p.proname order by p.proname)
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'graphql_public')
      and (has_function_privilege('authenticated', p.oid, 'execute')
           or has_function_privilege('anon', p.oid, 'execute'))
      and p.prosrc ~ 'sync\.(push|pull)\s*\('),
  array['public.sync_pull', 'public.sync_push'],
  'desde los schemas expuestos, las únicas entradas a sync.push() y sync.pull() son las dos puertas'
);
select is(
  (select count(*)::integer
     from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname in ('public', 'graphql_public') and p.prosecdef
      and has_function_privilege('authenticated', p.oid, 'execute')
      and p.prosrc ~ 'sync\.(push|pull|aplicar_job)'),
  0,
  'ninguna función SECURITY DEFINER de los schemas expuestos entra al sync con otros privilegios'
);

-- ---------------------------------------------------------------------------
-- Limpieza
-- ---------------------------------------------------------------------------
select pg_temp.como_servidor();
drop table lote, push_ref, push_puerta, pull_ref, pull_puerta, pagina_1, pagina_2;
delete from sync.op_cache where client_op_id in (pg_temp.u('a1'), pg_temp.u('a2'), pg_temp.u('a3'));
delete from public.espacio where ubicacion_id::text like '01920000-0000-7000-8000-00000000270%';
delete from public.house_status where ubicacion_id::text like '01920000-0000-7000-8000-00000000270%';
delete from public.ubicacion where id::text like '01920000-0000-7000-8000-00000000270%';
delete from public.campania_colportor where campania_id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.zona where campania_ciudad_id in (pg_temp.u('f1'), pg_temp.u('f2'));
delete from public.campania_ciudad where id in (pg_temp.u('f1'), pg_temp.u('f2'));
delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'));
delete from public.pais where id = pg_temp.u('c0');
delete from auth.users where id = pg_temp.u('b1');

select * from finish();
