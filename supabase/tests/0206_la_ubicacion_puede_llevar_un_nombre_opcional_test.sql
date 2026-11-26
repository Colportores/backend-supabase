-- pgTAP · la ubicación puede llevar un nombre opcional
-- (migración 0206, backend-supabase#313, «Nombre ubic.»; decisión de Cristian del 24/11)
--
-- Lucía carga una casa o una ubicación alternativa con un nombre («Farmacia Italia», hasta 80 caracteres). Casos:
--   1. forma de la columna: texto, nullable, con su CHECK y su trigger;
--   2. el push lleva el nombre en el alta y en el cambio, y la fila que baja con el pull lo trae como cualquier columna;
--   3. el nombre se recorta, y vacío o solo espacios es lo mismo que sin nombre (null);
--   4. 80 caracteres entran y 81 no (23514: `invalid` por trabajo, el lote sigue);
--   5. sin nombre sigue andando todo igual (el alta de siempre).
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000206' || p)::uuid;
$$;

-- Un job de push de ubicacion con el payload dado; devuelve su resultado.
create or replace function pg_temp.push_alta(p_id uuid, p_extra jsonb) returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'insert',
           'payload', jsonb_build_object('id', p_id, 'tipo', 'NEGOCIO', 'calle', 'Av. Italia', 'numero', p_id::text,
                                         'lat', -34.9 - (random() / 100), 'lon', -56.2 - (random() / 100),
                                         'ciudad_id', pg_temp.u('c1')) || p_extra))) -> 'results' -> 0;
$$;
create or replace function pg_temp.push_cambio(p_id uuid, p_payload jsonb) returns jsonb language sql as $$
  select sync.push(jsonb_build_array(jsonb_build_object(
           'client_op_id', gen_random_uuid(), 'entity', 'ubicacion', 'op', 'update',
           'sync_version', (select x.sync_version from public.ubicacion x where x.id = p_id),
           'payload', p_payload || jsonb_build_object('id', p_id)))) -> 'results' -> 0;
$$;
create or replace function pg_temp.nombre(p_id uuid) returns text language sql as $$
  select coalesce(u.nombre, '(null)') from public.ubicacion u where u.id = p_id;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- b1 colportor inscripto (sin zona) en una campaña vigente de la ciudad c1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('b1'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
        'nombre-ubic@example.com', 'x', now(), now(), now());
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais nombre', 'ZN');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values (pg_temp.u('c1'), 'Ciudad nombre', 'Departamento de prueba', pg_temp.u('c0'), -34.9, -56.2);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin)
values (pg_temp.u('e1'), 'Verano nombre', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select has_column('public', 'ubicacion', 'nombre', 'ubicacion.nombre existe');
select col_type_is('public', 'ubicacion', 'nombre', 'text', 'es texto');
select col_is_null('public', 'ubicacion', 'nombre', 'es opcional');
select has_trigger('public', 'ubicacion', 'ubicacion_nombre_normalizado', 'tiene su trigger de normalización');
select ok(not has_function_privilege('authenticated', 'public.tg_ubicacion_nombre_normalizado()', 'execute'),
          'authenticated no ejecuta el trigger a mano');
select ok(exists (select 1 from pg_constraint where conrelid = 'public.ubicacion'::regclass and conname = 'ubicacion_nombre_forma'),
          'tiene su CHECK de 1 a 80 caracteres');

-- ---------------------------------------------------------------------------
-- 2. Por el push (como la colportora): con nombre, sin nombre, cambio de nombre
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));

select is(pg_temp.push_alta(pg_temp.u('a1'), '{"nombre":"Farmacia Italia"}'::jsonb) ->> 'outcome', 'accepted', 'el alta con nombre se acepta');
select is(pg_temp.nombre(pg_temp.u('a1')), 'Farmacia Italia', 'y el nombre queda guardado');
select is(pg_temp.push_alta(pg_temp.u('a2'), '{}'::jsonb) ->> 'outcome', 'accepted', 'el alta de siempre, sin nombre, se acepta');
select is(pg_temp.nombre(pg_temp.u('a2')), '(null)', 'y queda sin nombre');
select is(pg_temp.push_cambio(pg_temp.u('a2'), '{"nombre":"Almacén de Doña Rosa"}'::jsonb) ->> 'outcome', 'accepted', 'se le pone nombre después con un cambio');
select is(pg_temp.nombre(pg_temp.u('a2')), 'Almacén de Doña Rosa', 'el cambio queda');
select is(pg_temp.push_cambio(pg_temp.u('a2'), '{"nombre":null}'::jsonb) ->> 'outcome', 'accepted', 'y se le saca mandando null');
select is(pg_temp.nombre(pg_temp.u('a2')), '(null)', 'sin nombre otra vez');

-- ---------------------------------------------------------------------------
-- 3. Se recorta; vacío es sin nombre
-- ---------------------------------------------------------------------------
select is(pg_temp.push_alta(pg_temp.u('a3'), '{"nombre":"   Kiosco   "}'::jsonb) ->> 'outcome', 'accepted', 'un nombre con espacios en los extremos se acepta');
select is(pg_temp.nombre(pg_temp.u('a3')), 'Kiosco', 'y queda recortado');
select is(pg_temp.push_alta(pg_temp.u('a4'), '{"nombre":""}'::jsonb) ->> 'outcome', 'accepted', 'un nombre vacío se acepta');
select is(pg_temp.nombre(pg_temp.u('a4')), '(null)', 'y es lo mismo que no tener nombre');
select is(pg_temp.push_alta(pg_temp.u('a5'), '{"nombre":"   "}'::jsonb) ->> 'outcome', 'accepted', 'un nombre de solo espacios se acepta');
select is(pg_temp.nombre(pg_temp.u('a5')), '(null)', 'y también queda sin nombre');
select is(pg_temp.push_cambio(pg_temp.u('a3'), '{"nombre":"  "}'::jsonb) ->> 'outcome', 'accepted', 'cambiar el nombre por espacios lo saca');
select is(pg_temp.nombre(pg_temp.u('a3')), '(null)', 'y queda sin nombre');

-- ---------------------------------------------------------------------------
-- 4. Hasta 80 caracteres
-- ---------------------------------------------------------------------------
select is(pg_temp.push_alta(pg_temp.u('a6'), jsonb_build_object('nombre', repeat('ñ', 80))) ->> 'outcome', 'accepted', '80 caracteres entran (también con tildes y eñes)');
select is(char_length(pg_temp.nombre(pg_temp.u('a6'))), 80, 'se guardan los 80');
select is(pg_temp.push_alta(pg_temp.u('a7'), jsonb_build_object('nombre', repeat('x', 81))) ->> 'outcome', 'invalid',
          '81 caracteres: el trabajo vuelve invalid, no tumba el lote');
select is((select count(*)::int from public.ubicacion where id = pg_temp.u('a7')), 0, 'y no escribe nada');
select is(pg_temp.push_cambio(pg_temp.u('a1'), jsonb_build_object('nombre', repeat('x', 81))) ->> 'outcome', 'invalid',
          'el cambio a 81 caracteres también vuelve invalid');
select is(pg_temp.nombre(pg_temp.u('a1')), 'Farmacia Italia', 'y el nombre anterior queda como estaba');

-- ---------------------------------------------------------------------------
-- 5. Sube y baja con el motor: no hay nada que registrar
-- ---------------------------------------------------------------------------
select ok('nombre' = any (sync.columnas_escribibles('ubicacion')), 'el push puede escribir la columna (es del cliente)');
select ok(sync.expresion_json('public.ubicacion'::regclass) like '%''nombre'', t.nombre%', 'la fila que baja con el pull lleva el nombre');

select * from finish();
rollback;
