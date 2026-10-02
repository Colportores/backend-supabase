-- pgTAP · migración 0024 (backend-supabase#59): el nombre de una zona tiene hasta 40 caracteres
-- (HU-CAM-006, decisión de Cristian del 02/10), validado en guardar_zona() y no solo en el formulario.
--   1. 40 caracteres entra; 41, CZ009 con un mensaje que dice cuánto se pasó. Se miden caracteres
--      (no bytes) y sin los espacios de los costados.
--   2. Rige al crear, al editar y en la vista previa; el rechazo no deja nada guardado.
--   3. Una zona que ya tenía un nombre más largo (de antes de 0024) no se toca, y al editarla hay que
--      acortarlo.
--   4. No cambia nada más de guardar_zona(): el nombre vacío y el repetido siguen en CZ009, y la
--      función conserva sus privilegios y su definición (SECURITY DEFINER, search_path vacío).
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000030' || p)::uuid;
$$;
create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;
create or replace function pg_temp.esquinas(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('orden', 1, 'lon', x0, 'lat', y0, 'calle_a', 'Oeste', 'calle_b', 'Sur'),
    jsonb_build_object('orden', 2, 'lon', x1, 'lat', y0, 'calle_a', 'Este',  'calle_b', 'Sur'),
    jsonb_build_object('orden', 3, 'lon', x1, 'lat', y1, 'calle_a', 'Este',  'calle_b', 'Norte'),
    jsonb_build_object('orden', 4, 'lon', x0, 'lat', y1, 'calle_a', 'Oeste', 'calle_b', 'Norte'));
$$;
-- Guarda (o edita, con p_zona; o solo previsualiza, con p_previa) una zona rectangular con ese nombre.
-- Cada zona nueva usa un rectángulo propio (p_n): las zonas se pueden superponer, pero así el test no
-- depende de eso.
create or replace function pg_temp.guardar(p_nombre text, p_n integer default 0, p_zona uuid default null,
                                           p_previa boolean default false)
returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => pg_temp.u('f1'), p_nombre => p_nombre,
                             p_tipo_forma => 'ESQUINAS',
                             p_vertices => pg_temp.esquinas(-56.20 + p_n * 0.01, -34.91, -56.19 + p_n * 0.01, -34.90),
                             p_poligono_geojson => pg_temp.rect(-56.20 + p_n * 0.01, -34.91, -56.19 + p_n * 0.01, -34.90),
                             p_zona_id => p_zona, p_vista_previa => p_previa);
$$;
create or replace function pg_temp.mensaje_de_exceso(p_largo integer) returns text language sql as $$
  select 'El nombre de la zona puede tener hasta 40 caracteres y el que escribiste tiene ' || p_largo || '. Acortalo.';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 coordina e1 (en curso), con una ciudad de campaña (f1). a2 no coordina nada.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'nombre30-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais nombre30', 'ZN');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad nombre30', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano nombre30', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
-- Una zona de antes de 0024, con un nombre de 50 caracteres (ningún CHECK lo impide: la regla vive en
-- guardar_zona()).
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  (pg_temp.u('d9'), repeat('L', 50), pg_temp.u('f1'), 'ESQUINAS', pg_temp.rect(-56.50, -34.91, -56.49, -34.90));

-- ---------------------------------------------------------------------------
-- 1. El tope: 40 sí, 41 no
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((pg_temp.guardar(repeat('a', 40), 1) ->> 'guardada'), 'true', 'un nombre de 40 caracteres se guarda');
select throws_ok(format('select pg_temp.guardar(%L, 2)', repeat('a', 41)), 'CZ009', pg_temp.mensaje_de_exceso(41),
                 'uno de 41: CZ009 con cuánto se pasó y qué hacer');
select throws_ok(format('select pg_temp.guardar(%L, 2)', repeat('a', 100)), 'CZ009', pg_temp.mensaje_de_exceso(100),
                 'uno de 100: CZ009 y el mensaje trae el largo real');

-- Sin contar los espacios de los costados: 40 + espacios entra, y se guarda recortado.
select is((pg_temp.guardar('   ' || repeat('b', 40) || '  ', 3) -> 'zona' ->> 'nombre'), repeat('b', 40),
          '40 caracteres con espacios de los costados: entra y se guarda sin ellos');
select throws_ok(format('select pg_temp.guardar(%L, 4)', '  ' || repeat('c', 41) || '  '), 'CZ009', pg_temp.mensaje_de_exceso(41),
                 '41 caracteres con espacios de los costados: CZ009, y dice 41 (los espacios no cuentan)');
-- Los espacios del medio sí cuentan.
select throws_ok(format('select pg_temp.guardar(%L, 4)', repeat('d', 20) || '          ' || repeat('d', 11)), 'CZ009',
                 pg_temp.mensaje_de_exceso(41), 'los espacios del medio cuentan');

-- Caracteres, no bytes: 40 «ñ» son 80 bytes, 40 emojis son 160.
select is((pg_temp.guardar(repeat('ñ', 40), 5) ->> 'guardada'), 'true', '40 «ñ» (80 bytes): entra');
select throws_ok(format('select pg_temp.guardar(%L, 6)', repeat('ñ', 41)), 'CZ009', pg_temp.mensaje_de_exceso(41), '41 «ñ»: CZ009');
select is((pg_temp.guardar(repeat('🏠', 40), 6) ->> 'guardada'), 'true', '40 emojis (160 bytes): entra');
select throws_ok(format('select pg_temp.guardar(%L, 7)', repeat('🏠', 41)), 'CZ009', pg_temp.mensaje_de_exceso(41), '41 emojis: CZ009');

-- Un nombre de un solo carácter sigue entrando; el vacío y el solo de espacios siguen en CZ009.
select is((pg_temp.guardar('Z', 7) ->> 'guardada'), 'true', 'un carácter: entra');
select throws_ok($$ select pg_temp.guardar('   ', 8) $$, 'CZ009', 'La zona necesita un nombre. Escribí uno.',
                 'solo espacios: sigue siendo «necesita un nombre»');
select throws_ok(format('select pg_temp.guardar(%L, 8)', repeat('a', 40)), 'CZ009',
                 'Ya hay una zona «' || repeat('a', 40) || '» en esta ciudad de la campaña. Elegí otro nombre.',
                 'el repetido sigue en CZ009 con su mensaje');

-- ---------------------------------------------------------------------------
-- 2. Al editar y en la vista previa; el rechazo no deja nada guardado
-- ---------------------------------------------------------------------------
create temp table zona_e on commit drop as select pg_temp.guardar('Para editar', 9) as z;
select throws_ok(
  format('select pg_temp.guardar(%L, 9, %L)', repeat('e', 41), (select z -> 'zona' ->> 'id' from zona_e)),
  'CZ009', pg_temp.mensaje_de_exceso(41), 'al editar una zona: 41 caracteres, CZ009');
select is((pg_temp.guardar(repeat('e', 40), 9, ((select z -> 'zona' ->> 'id' from zona_e))::uuid) -> 'zona' ->> 'nombre'),
          repeat('e', 40), 'al editarla con 40: se renombra');
select throws_ok(format('select pg_temp.guardar(%L, 10, null, true)', repeat('f', 41)), 'CZ009', pg_temp.mensaje_de_exceso(41),
                 'en la vista previa: 41 caracteres, CZ009 (el formulario no la deja pasar por alto)');
select is((pg_temp.guardar(repeat('f', 40), 10, null, true) ->> 'guardada'), 'false', 'en la vista previa con 40: entra y no guarda');

select pg_temp.actuar_como_servidor();
select is((select count(*) from public.zona where nombre like repeat('a', 41) || '%' or nombre like repeat('c', 41) || '%'
                                                 or nombre like repeat('f', 41) || '%' or nombre like repeat('ñ', 41) || '%'
                                                 or nombre like repeat('🏠', 41) || '%'),
          0::bigint, 'ninguno de los rechazados dejó una zona');
select is((select count(*) from public.zona where nombre = repeat('f', 40)), 0::bigint, 'la vista previa no guardó nada');
select is((select count(*) from public.zona where nombre = 'Para editar'), 0::bigint, 'la zona editada ya no se llama como antes');
select is((select count(*) from public.zona where nombre = repeat('e', 40)), 1::bigint, 'y quedó con el nombre nuevo');

-- ---------------------------------------------------------------------------
-- 3. Una zona de antes, con un nombre más largo: no se toca; al editarla hay que acortarlo
-- ---------------------------------------------------------------------------
select is((select nombre from public.zona where id = pg_temp.u('d9')), repeat('L', 50), 'la zona de antes conserva su nombre de 50 caracteres');
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok(format('select pg_temp.guardar(%L, 11, %L)', repeat('L', 50), pg_temp.u('d9')), 'CZ009', pg_temp.mensaje_de_exceso(50),
                 'editarla conservando los 50 caracteres: CZ009 (hay que acortarlo)');
select is((pg_temp.guardar('Zona corta', 11, pg_temp.u('d9')) -> 'zona' ->> 'nombre'), 'Zona corta', 'acortándolo, se guarda');

-- ---------------------------------------------------------------------------
-- 4. Lo demás de guardar_zona() sigue igual
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok(format('select pg_temp.guardar(%L, 12)', repeat('g', 41)), '42501', null,
                 'otro coordinador con un nombre largo: el permiso va primero (42501), como siempre');
select pg_temp.actuar_como_servidor();
select ok(has_function_privilege('authenticated',
            'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)',
            'execute'), 'authenticated sigue ejecutando guardar_zona');
select ok(not has_function_privilege('anon',
            'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)',
            'execute'), 'anon sigue sin ejecutarla');
select is((select p.prosecdef and p.proconfig = array['search_path=""']
             from pg_proc p where p.oid = 'public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)'::regprocedure),
          true, 'sigue siendo SECURITY DEFINER con search_path vacío');
select matches(obj_description('public.guardar_zona(uuid,text,text,text,double precision,double precision,integer,jsonb,jsonb,uuid,boolean)'::regprocedure, 'pg_proc'),
               '40 caracteres', 'su comentario nombra el tope');

select * from finish();
rollback;
