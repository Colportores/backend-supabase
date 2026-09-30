-- pgTAP · migración 0017 — dirección única a menos de 100 m (D1) y normalización con espacios y
-- tildes (backend-supabase#34).
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

-- Un punto a p_metros de (p_lat, p_lon) con rumbo p_grados (0 = norte, 90 = este), sobre el
-- elipsoide: la misma medida que usa la regla (ST_Distance sobre geography).
create or replace function pg_temp.a(p_metros float8, p_grados float8 default 90,
                                     p_lat float8 default -34.90, p_lon float8 default -56.20,
                                     out lat float8, out lon float8)
language sql as $$
  select extensions.st_y(g), extensions.st_x(g)
    from (select extensions.geometry(extensions.st_project(public.ubicacion_geografia(p_lat, p_lon),
                                                           p_metros, radians(p_grados))) g) x;
$$;

create or replace function pg_temp.distancia(p_a uuid, p_b uuid) returns float8 language sql as $$
  select extensions.st_distance(public.ubicacion_geografia(a.lat, a.lon), public.ubicacion_geografia(b.lat, b.lon))
    from public.ubicacion a, public.ubicacion b where a.id = p_a and b.id = p_b;
$$;

-- Un job de push de ubicacion; devuelve su resultado.
create or replace function pg_temp.push_ubicacion(p_op_id uuid, p_id uuid, p_calle text, p_numero text,
                                                  p_lat float8, p_lon float8,
                                                  p_ciudad uuid default '01920000-0000-7000-8000-0000000020c1')
returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', p_op_id, 'entity', 'ubicacion', 'op', 'insert',
           'payload', jsonb_build_object('id', p_id, 'tipo', 'CASA', 'calle', p_calle, 'numero', p_numero,
                                         'lat', p_lat, 'lon', p_lon, 'ciudad_id', p_ciudad)))) -> 'results' -> 0;
$$;

create or replace function pg_temp.push_update(p_id uuid, p_payload jsonb) returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update',
           'sync_version', (select u.sync_version from public.ubicacion u where u.id = p_id),
           'payload', p_payload || jsonb_build_object('id', p_id)))) -> 'results' -> 0;
$$;

-- Qué error da una sentencia: «sqlstate restricción», u «ok».
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

create or replace function pg_temp.insertar(p_calle text, p_numero text, p_lat float8, p_lon float8,
                                            p_ciudad text default '01920000-0000-7000-8000-0000000020c1')
returns text language sql as $$
  select format('insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id) values '
                '(''CASA'', %L, %L, %s, %s, %L)', p_calle, p_numero, p_lat, p_lon, p_ciudad);
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- x1 registró A (Av. Italia 100, en P0 = -34.90, -56.20). y1 no está inscripto en nada: la RLS
-- solo le muestra lo suyo, así que A no la ve. c2 es otra ciudad.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000020' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'd1-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2']) s;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000020c0', 'Pais D1', 'ZD');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000020c1', 'Ciudad D1',      '01920000-0000-7000-8000-0000000020c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000020c2', 'Otra ciudad D1', '01920000-0000-7000-8000-0000000020c0', -34.9, -56.2);

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select ok(exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace
                   where e.extname = 'unaccent' and n.nspname = 'extensions'),
          'unaccent instalada en extensions');
select has_trigger('public', 'ubicacion', 'ubicacion_direccion_unica_insert', 'D1 al insertar');
select has_trigger('public', 'ubicacion', 'ubicacion_direccion_unica_update', 'D1 al modificar');
select has_index('public', 'ubicacion', 'ubicacion_direccion_idx', 'el índice de dirección de 0010, rehecho');
select hasnt_index('public', 'ubicacion', 'ubicacion_direccion_uidx', 'sin índice único: la regla mira la distancia');
select ok((select p.prosecdef from pg_proc p where p.oid = 'public.tg_ubicacion_direccion_unica()'::regprocedure),
          'el trigger es SECURITY DEFINER: ve las ubicaciones que la RLS le esconde a quien escribe');
select ok((select p.proconfig @> array['search_path=""'] from pg_proc p
            where p.oid = 'public.tg_ubicacion_direccion_unica()'::regprocedure),
          'con search_path vacío');
select ok(not has_function_privilege(r, 'public.tg_ubicacion_direccion_unica()', 'execute'),
          r || ' no ejecuta el trigger a mano')
  from unnest(array['anon', 'authenticated']) r;
select ok(has_function_privilege('authenticated', 'public.direccion_normalizada(text)', 'execute'),
          'authenticated sigue ejecutando direccion_normalizada (la evalúa el índice al escribir)');
select is((select provolatile::text from pg_proc where oid = 'public.direccion_normalizada(text)'::regprocedure),
          'i', 'direccion_normalizada sigue IMMUTABLE');

-- ---------------------------------------------------------------------------
-- 2. Normalización: tildes, espacios (también los raros), mayúsculas
-- ---------------------------------------------------------------------------
select is(public.direccion_normalizada('  Av.  Itália '), 'av. italia', 'tildes y espacios dobles');
select is(public.direccion_normalizada('AV. ITALIA'), 'av. italia', 'mayúsculas');
select is(public.direccion_normalizada(E'Av.\tItalia'), 'av. italia', 'tab');
select is(public.direccion_normalizada(E'Av.\n \r Italia'), 'av. italia', 'saltos de línea juntados con los espacios');
select is(public.direccion_normalizada('Av.' || chr(160) || 'Italia'), 'av. italia', 'espacio duro (U+00A0)');
select is(public.direccion_normalizada('Av.' || chr(8239) || chr(8199) || 'Italia'), 'av. italia',
          'espacios finos (U+202F, U+2007)');
select is(public.direccion_normalizada(chr(12288) || 'Av. Italia' || chr(65279)), 'av. italia',
          'espacio ideográfico (U+3000) y BOM (U+FEFF) en los bordes');
select is(public.direccion_normalizada('ÁÉÍÓÚ áéíóú Ü'), 'aeiou aeiou u', 'todas las tildes y la diéresis');
select is(public.direccion_normalizada('Peña'), 'pena', 'unaccent también pasa ñ a n (la app tiene que hacer lo mismo)');
select is(public.direccion_normalizada(' 1234 '), '1234', 'número con espacios');
select is(public.direccion_normalizada('12   B'), public.direccion_normalizada('12 b'), 'número con letra');
select is(public.direccion_normalizada(''), null, 'vacío = null');
select is(public.direccion_normalizada(E' \t' || chr(160) || ' '), null, 'solo espacios (también raros) = null');
select is(public.direccion_normalizada(null), null, 'null = null');

-- ---------------------------------------------------------------------------
-- 3. El push: misma dirección a menos de 100 m → conflicto y no escribe
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000020b1');
select is(pg_temp.push_ubicacion('01920000-0000-7000-8000-0000000020f1', '01920000-0000-7000-8000-0000000020a1',
                                 'Av. Italia', '100', -34.90, -56.20) ->> 'outcome',
          'accepted', 'x1 registra A (Av. Italia 100)');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000020b2');
select is((select count(*) from public.ubicacion where id = '01920000-0000-7000-8000-0000000020a1'), 0::bigint,
          'y1 no ve A (la RLS se la esconde)');

select is(pg_temp.push_ubicacion('01920000-0000-7000-8000-0000000020f2', '01920000-0000-7000-8000-0000000020a2',
                                 'Av. Italia', '100', (pg_temp.a(99.9)).lat, (pg_temp.a(99.9)).lon),
          jsonb_build_object('client_op_id', '01920000-0000-7000-8000-0000000020f2', 'outcome', 'conflict',
                             'code', '23505', 'constraint', 'ubicacion_direccion_unica',
                             'message', 'Ya hay otra ubicación en «Av. Italia 100» a menos de 100 m.'),
          'a 99,9 m: conflicto 23505 con la restricción y el mensaje, sin server_row (aunque y1 no vea A)');
select is((select count(*) from public.ubicacion where id = '01920000-0000-7000-8000-0000000020a2'), 0::bigint,
          'el conflicto no escribe la fila');
select is((select count(*) from sync.op_cache where client_op_id = '01920000-0000-7000-8000-0000000020f2'), 0::bigint,
          'ni el cache de client_op_id: un reintento se vuelve a revisar');
select is(pg_temp.push_ubicacion('01920000-0000-7000-8000-0000000020f2', '01920000-0000-7000-8000-0000000020a2',
                                 'Av. Italia', '100', (pg_temp.a(99.9)).lat, (pg_temp.a(99.9)).lon) ->> 'outcome',
          'conflict', 'el reintento con el mismo client_op_id vuelve a dar conflicto (no duplicate)');

select is(pg_temp.push_ubicacion(gen_random_uuid(), gen_random_uuid(), v.calle, v.numero,
                                 (pg_temp.a(40, v.rumbo)).lat, (pg_temp.a(40, v.rumbo)).lon) ->> 'outcome',
          'conflict', format('«%s %s» cuenta como la misma dirección que «Av. Italia 100»', v.calle, v.numero))
  from (values ('Av.  Italia', '100', 0), ('Av. Itália', '100', 45), ('av. italia', '100', 90),
               ('  AV. ITÁLIA ', ' 100 ', 135), (E'Av.\tItalia', '100', 180),
               ('Av.' || chr(160) || 'Italia', '100', 225)) v(calle, numero, rumbo);

select is(pg_temp.push_ubicacion(gen_random_uuid(), '01920000-0000-7000-8000-0000000020a3',
                                 'av. itália', '100', (pg_temp.a(100)).lat, (pg_temp.a(100)).lon) ->> 'outcome',
          'accepted', 'a 100 m justos: se aceptan las dos');
select pg_temp.actuar_como_servidor();
select ok(pg_temp.distancia('01920000-0000-7000-8000-0000000020a1', '01920000-0000-7000-8000-0000000020a3') >= 100,
          'precondición: A y la de 100 m están a 100 m o más');
select ok(pg_temp.distancia('01920000-0000-7000-8000-0000000020a1', '01920000-0000-7000-8000-0000000020a3') < 100.001,
          'precondición: y no mucho más (el borde es el borde)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000020b2');
select is(pg_temp.push_ubicacion(gen_random_uuid(), '01920000-0000-7000-8000-0000000020a4',
                                 'Av. Italia', '100', (pg_temp.a(250, 270)).lat, (pg_temp.a(250, 270)).lon) ->> 'outcome',
          'accepted', 'a 250 m: se acepta');

-- El advisory lock de la dirección queda tomado hasta el final de la transacción.
select ok(exists (
  select 1 from pg_locks l,
         lateral (select hashtextextended('direccion_unica:01920000-0000-7000-8000-0000000020c1:av. italia:100', 0) k) h
   where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.mode = 'ExclusiveLock'
     and l.classid::bigint = (h.k >> 32) & 4294967295 and l.objid::bigint = h.k & 4294967295),
  'lock advisory por (ciudad, calle, número) normalizados, hasta el commit');

-- ---------------------------------------------------------------------------
-- 4. Lo que no participa: bajas, sin calle o número, otra ciudad, otra calle u otro número
-- ---------------------------------------------------------------------------
select is(pg_temp.push_ubicacion(gen_random_uuid(), gen_random_uuid(), 'Av. Italia', '100',
                                 (pg_temp.a(5)).lat, (pg_temp.a(5)).lon, '01920000-0000-7000-8000-0000000020c2') ->> 'outcome',
          'accepted', 'la misma calle y número en otra ciudad, a 5 m: se acepta');
select is(pg_temp.push_ubicacion(gen_random_uuid(), gen_random_uuid(), 'Av. Italia', '101',
                                 (pg_temp.a(5)).lat, (pg_temp.a(5)).lon) ->> 'outcome',
          'accepted', 'otro número a 5 m: se acepta');
select is(pg_temp.push_ubicacion(gen_random_uuid(), gen_random_uuid(), 'Rivera', '100',
                                 (pg_temp.a(5)).lat, (pg_temp.a(5)).lon) ->> 'outcome',
          'accepted', 'otra calle a 5 m: se acepta');
select is(pg_temp.push_ubicacion(gen_random_uuid(), gen_random_uuid(), v.calle, v.numero,
                                 (pg_temp.a(1, v.rumbo)).lat, (pg_temp.a(1, v.rumbo)).lon) ->> 'outcome',
          'accepted', format('sin calle o sin número («%s» «%s»), a 1 m de A: no participa', v.calle, v.numero))
  from (values ('Av. Italia', null, 0), ('Av. Italia', null, 180), (null, '100', 90), (null, '100', 270),
               ('   ', '100', 45), ('Av. Italia', '  ', 225)) v(calle, numero, rumbo);

select pg_temp.actuar_como_servidor();
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000020a5', 'CASA', 'Av. Italia', '200', -34.90, -56.21,
   '01920000-0000-7000-8000-0000000020c1', now());
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000020b2');
select is(pg_temp.push_ubicacion(gen_random_uuid(), '01920000-0000-7000-8000-0000000020a6', 'Av. Italia', '200',
                                 (pg_temp.a(3, 0, -34.90, -56.21)).lat, (pg_temp.a(3, 0, -34.90, -56.21)).lon) ->> 'outcome',
          'accepted', 'a 3 m de una dada de baja con la misma dirección: se acepta');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de($$ update public.ubicacion set deleted_at = null
                              where id = '01920000-0000-7000-8000-0000000020a5' $$),
          '23505 ubicacion_direccion_unica', 'reactivar la baja con la otra viva a 3 m: choca');
select is(pg_temp.error_de($$ update public.ubicacion set deleted_at = now()
                              where id = '01920000-0000-7000-8000-0000000020a6' $$),
          'ok', 'dar de baja nunca choca');
select is(pg_temp.error_de($$ update public.ubicacion set deleted_at = null
                              where id = '01920000-0000-7000-8000-0000000020a5' $$),
          'ok', 'con la otra de baja, la reactivación pasa');

-- ---------------------------------------------------------------------------
-- 5. Modificar: mover, cambiar la dirección, cambiar otra cosa
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000020b2');
select is(pg_temp.push_update('01920000-0000-7000-8000-0000000020a4',
                              jsonb_build_object('lat', (pg_temp.a(60, 270)).lat, 'lon', (pg_temp.a(60, 270)).lon)) ->> 'outcome',
          'conflict', 'mover la de 250 m a 60 m de A: conflicto');
select is((select array[round(lat::numeric, 9), round(lon::numeric, 9)] from public.ubicacion
            where id = '01920000-0000-7000-8000-0000000020a4'),
          array[round((pg_temp.a(250, 270)).lat::numeric, 9), round((pg_temp.a(250, 270)).lon::numeric, 9)],
          'y la fila del servidor no cambió');
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-0000000020a4'), 0::bigint,
          'ni su sync_version');
select is(pg_temp.push_update('01920000-0000-7000-8000-0000000020a4', '{"tipo": "NEGOCIO"}'::jsonb) ->> 'outcome',
          'accepted', 'cambiar otra cosa de una fila con la misma dirección (a 250 m) no choca');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-0000000020a7', 'CASA', 'Rivera', '7', (pg_temp.a(30, 0)).lat, (pg_temp.a(30, 0)).lon,
   '01920000-0000-7000-8000-0000000020c1');
select is(pg_temp.push_update('01920000-0000-7000-8000-0000000020a7',
                              '{"calle": "Av. ITALIA", "numero": "100"}'::jsonb) ->> 'outcome',
          'conflict', 'cambiarle la dirección a la de A estando a 30 m: conflicto');
select is(pg_temp.push_update('01920000-0000-7000-8000-0000000020a7', '{"numero": "8"}'::jsonb) ->> 'outcome',
          'accepted', 'cambiarla a otra dirección: se acepta');
select is(pg_temp.error_de($$ update public.ubicacion set ciudad_id = '01920000-0000-7000-8000-0000000020c2'
                              where id = '01920000-0000-7000-8000-0000000020a4' $$),
          'ok', 'pasarla a otra ciudad (que no tiene esa dirección cerca) no choca');

-- Directo, sin el push (PostgREST o el panel): el 23505 con el mensaje y lo que hay que hacer.
select throws_ok(pg_temp.insertar('Av. Itália', '100', (pg_temp.a(10)).lat, (pg_temp.a(10)).lon),
                 '23505', 'Ya hay otra ubicación en «Av. Itália 100» a menos de 100 m.',
                 'insert directo con JWT: 23505 con el mensaje');
select pg_temp.actuar_como_servidor();
select is(pg_temp.error_de(pg_temp.insertar('av. italia', '100', (pg_temp.a(10)).lat, (pg_temp.a(10)).lon)),
          '23505 ubicacion_direccion_unica', 'también como servidor, sin JWT');
select is(pg_temp.error_de($$ insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id) values
                              ('CASA', 'Colonia', '9', -34.80, -56.10, '01920000-0000-7000-8000-0000000020c1'),
                              ('CASA', 'colonia ', '9', -34.80001, -56.10, '01920000-0000-7000-8000-0000000020c1') $$),
          '23505 ubicacion_direccion_unica', 'dos iguales en la misma sentencia también chocan');

-- ---------------------------------------------------------------------------
-- 6. El resto del push no cambia
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000020b1');
select is(pg_temp.push_ubicacion(gen_random_uuid(), '01920000-0000-7000-8000-0000000020a1',
                                 'Av. Italia', '100', -34.90, -56.20) ->> 'outcome',
          'duplicate', 'reenviar el alta de A (misma PK) sigue siendo duplicate, no choca consigo misma');

select is(sync.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', gen_random_uuid(), 'entity', 'espacio', 'op', 'insert',
            'payload', jsonb_build_object('id', '01920000-0000-7000-8000-0000000020e1',
                                          'ubicacion_id', '01920000-0000-7000-8000-0000000020a1')))) #>> '{results,0,outcome}',
          'accepted', 'x1 carga el espacio de A');
select is(sync.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', gen_random_uuid(), 'entity', 'espacio_persona', 'op', 'insert',
            'payload', jsonb_build_object('id', '01920000-0000-7000-8000-0000000020e2',
                                          'espacio_id', '01920000-0000-7000-8000-0000000020e1',
                                          'persona_id', '01920000-0000-7000-8000-0000000020e9')))) #>> '{results,0,outcome}',
          'accepted', 'y le asocia una persona');
select is((sync.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', gen_random_uuid(), 'entity', 'espacio_persona', 'op', 'insert',
            'payload', jsonb_build_object('id', '01920000-0000-7000-8000-0000000020e3',
                                          'espacio_id', '01920000-0000-7000-8000-0000000020e1',
                                          'persona_id', '01920000-0000-7000-8000-0000000020e9')))) -> 'results' -> 0)
          - 'client_op_id' - 'message',
          '{"outcome": "invalid", "code": "23505"}'::jsonb,
          'otro 23505 (la misma persona dos veces en el espacio) sigue siendo invalid');

-- ---------------------------------------------------------------------------
-- 7. El aviso de posible duplicado (0010) usa la normalización nueva
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select is(
  (select misma_direccion from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000020c1', 'AV.  ITÁLIA', ' 100', -34.70, -56.00)
    where ubicacion_id = '01920000-0000-7000-8000-0000000020a1'),
  true, 'posibles_duplicados_de_ubicacion: «AV.  ITÁLIA 100» es la misma dirección que A');

select * from finish();
rollback;
