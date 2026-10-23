-- pgTAP · casas de una zona para el panel (migración 0039, backend-supabase#72, ADR-003/004)
-- casas_de_zona(): el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido, coordinador
-- de otra campaña), los códigos de campaña y de zona (CZ001, CZ011, CZ004), las casas de la zona
-- (vivas, de la ciudad, dentro de la forma, borde incluido), los siete estados de house_status, el
-- estado null, que la respuesta no trae nada de más (ni personas, ni importes, ni dirección) y el
-- tope con paginado (un tope no esconde resultados).
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

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- Recorre todas las páginas de a p_limite, siguiendo el último ubicacion_id, hasta una página con
-- menos filas que p_limite. Devuelve «<páginas>:<ids separados por coma>».
create or replace function pg_temp.paginar(p_campania uuid, p_zona uuid, p_limite integer)
returns text language plpgsql as $$
declare
  v_todas  uuid[] := '{}';
  v_pagina uuid[];
  v_ultima uuid := null;
  v_n      integer := 0;
begin
  loop
    select coalesce(array_agg(c.ubicacion_id), '{}') into v_pagina
      from public.casas_de_zona(p_campania, p_zona, v_ultima, p_limite) c;
    v_n := v_n + 1;
    if v_n > 100 then
      raise exception 'paginar: el recorrido no termina (¿el cursor no avanza?)';
    end if;
    v_todas := v_todas || v_pagina;
    exit when coalesce(array_length(v_pagina, 1), 0) < p_limite;
    v_ultima := v_pagina[array_length(v_pagina, 1)];
  end loop;
  return v_n || ':' || array_to_string(v_todas, ',');
end $$;

-- Cuánto tarda (en ms) una página.
create or replace function pg_temp.ms_de_una_pagina(p_campania uuid, p_zona uuid, p_limite integer)
returns numeric language plpgsql as $$
declare
  v_t0 timestamptz := clock_timestamp();
begin
  perform * from public.casas_de_zona(p_campania, p_zona, null, p_limite);
  return extract(epoch from clock_timestamp() - v_t0) * 1000;
end $$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Verano, Vieja, Borrada y Futura; a2 coordinador de Otra; ad admin;
--        a0 colportor; a3 sin ningún rol; a4 coordinador con el rol vencido. b1 colportor
--        inscripto en Verano, en la zona Centro.
-- Campañas: e1 Verano (vigente, a1)  e2 Otra (vigente, a2)  e3 Vieja (terminada, a1)
--        e4 Borrada (a1)  e5 Futura (empieza en 10 días, a1)
-- Ciudades: c1 y c2.
-- campania_ciudad: 71 Verano/c1  72 Otra/c2  73 Vieja/c1  74 Futura/c1  75 Verano/c2 (de baja)
-- Zonas (todas son rectángulos de 0,02 grados de ancho y 0,01 de alto):
--        d1 Centro (en 71, lat -34.92..-34.91)  d2 Norte (en 71, lat -34.90..-34.89)
--        d3 Borrada (en 71, de baja)  d4 Otra (en 72, como Centro pero en c2)
--        d5 Vieja (en 73)  d6 Zona futura (en 74, lat -34.95..-34.94)
--        d7 En ciudad quitada (en 75)  d8 Cordón (en 71, se superpone con Centro)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000049' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'casas-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','ad','b1']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000049' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select '01920000-0000-7000-8000-0000000049a4'::uuid, r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000049c0', 'Pais casas', 'ZQ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000049c1', 'Ciudad uno q72', 'Departamento de prueba', '01920000-0000-7000-8000-0000000049c0', -34.91, -56.18, 13),
  ('01920000-0000-7000-8000-0000000049c2', 'Ciudad dos q72', 'Departamento de prueba', '01920000-0000-7000-8000-0000000049c0', -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000049e1', 'Verano',  'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000049a1', null),
  ('01920000-0000-7000-8000-0000000049e2', 'Otra',    'VERANO', current_date - 10, null,              '01920000-0000-7000-8000-0000000049a2', null),
  ('01920000-0000-7000-8000-0000000049e3', 'Vieja',   'VERANO', current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000049a1', null),
  ('01920000-0000-7000-8000-0000000049e4', 'Borrada', 'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000049a1', now()),
  ('01920000-0000-7000-8000-0000000049e5', 'Futura',  'VERANO', current_date + 10, current_date + 40, '01920000-0000-7000-8000-0000000049a1', null);
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-000000004971', '01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004972', '01920000-0000-7000-8000-0000000049e2', '01920000-0000-7000-8000-0000000049c2', null),
  ('01920000-0000-7000-8000-000000004973', '01920000-0000-7000-8000-0000000049e3', '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004974', '01920000-0000-7000-8000-0000000049e5', '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004975', '01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049c2', now());

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson, deleted_at) values
  ('01920000-0000-7000-8000-0000000049d1', 'Centro',  '01920000-0000-7000-8000-000000004971', 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  ('01920000-0000-7000-8000-0000000049d2', 'Norte',   '01920000-0000-7000-8000-000000004971', 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb, null),
  ('01920000-0000-7000-8000-0000000049d3', 'Borrada', '01920000-0000-7000-8000-000000004971', 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, now()),
  ('01920000-0000-7000-8000-0000000049d4', 'Otra',    '01920000-0000-7000-8000-000000004972', 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  ('01920000-0000-7000-8000-0000000049d5', 'Vieja',   '01920000-0000-7000-8000-000000004973', 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  ('01920000-0000-7000-8000-0000000049d6', 'Zona futura', '01920000-0000-7000-8000-000000004974', 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.95],[-56.17,-34.95],[-56.17,-34.94],[-56.19,-34.94],[-56.19,-34.95]]]}'::jsonb, null),
  ('01920000-0000-7000-8000-0000000049d7', 'En ciudad quitada', '01920000-0000-7000-8000-000000004975', 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  ('01920000-0000-7000-8000-0000000049d8', 'Cordón',  '01920000-0000-7000-8000-000000004971', 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.925],[-56.17,-34.925],[-56.17,-34.9155],[-56.19,-34.9155],[-56.19,-34.925]]]}'::jsonb, null);

insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049b1', '01920000-0000-7000-8000-0000000049d1');

-- Ubicaciones de c1 (los ids siguen el orden de las filas):
--   01..07 dentro de Centro, una por cada uno de los siete estados (01 casa, 02 negocio, 03 edificio)
--   08 dentro de Centro, sin house_status
--   09 dentro de Centro, dada de baja (su house_status sigue vivo)
--   0a dentro de Centro, con el house_status dado de baja
--   0b sobre el borde sur de Centro
--   0c afuera de todas las zonas
--   0d dentro de Norte
--   0e es de c2, en el mismo lugar que 01 (adentro de «Otra»)
--   0f dentro de «Zona futura»
-- Con una dirección y un espacio en 01, para que la prueba de privacidad tenga algo que filtrar.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-000000004901', 'CASA',     'Mataojo', '2044', -34.915,  -56.18,  '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004902', 'NEGOCIO',  null,      null,   -34.9155, -56.181, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004903', 'EDIFICIO', null,      null,   -34.916,  -56.182, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004904', 'CASA',     null,      null,   -34.9165, -56.183, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004905', 'CASA',     null,      null,   -34.917,  -56.184, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004906', 'CASA',     null,      null,   -34.9175, -56.185, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004907', 'CASA',     null,      null,   -34.918,  -56.186, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004908', 'CASA',     null,      null,   -34.9185, -56.187, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-000000004909', 'CASA',     null,      null,   -34.919,  -56.188, '01920000-0000-7000-8000-0000000049c1', now()),
  ('01920000-0000-7000-8000-00000000490a', 'CASA',     null,      null,   -34.9195, -56.189, '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-00000000490b', 'CASA',     null,      null,   -34.92,   -56.18,  '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-00000000490c', 'CASA',     null,      null,   -34.97,   -56.18,  '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-00000000490d', 'CASA',     null,      null,   -34.895,  -56.18,  '01920000-0000-7000-8000-0000000049c1', null),
  ('01920000-0000-7000-8000-00000000490e', 'CASA',     null,      null,   -34.915,  -56.18,  '01920000-0000-7000-8000-0000000049c2', null),
  ('01920000-0000-7000-8000-00000000490f', 'CASA',     null,      null,   -34.945,  -56.18,  '01920000-0000-7000-8000-0000000049c1', null);

insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, deleted_at) values
  ('01920000-0000-7000-8000-000000004901', -34.915,  -56.18,  'CASA',     'ENTREGA_Y_COBRANZA_PENDIENTE', 1, null),
  ('01920000-0000-7000-8000-000000004902', -34.9155, -56.181, 'NEGOCIO',  'COBRANZA_PENDIENTE',           2, null),
  ('01920000-0000-7000-8000-000000004903', -34.916,  -56.182, 'EDIFICIO', 'ENTREVISTA_PROGRAMADA',        3, null),
  ('01920000-0000-7000-8000-000000004904', -34.9165, -56.183, 'CASA',     'VENTA_COMPLETA',               4, null),
  ('01920000-0000-7000-8000-000000004905', -34.917,  -56.184, 'CASA',     'ENTREVISTA_SIN_VENTA',         5, null),
  ('01920000-0000-7000-8000-000000004906', -34.9175, -56.185, 'CASA',     'SIN_CONTESTAR',                6, null),
  ('01920000-0000-7000-8000-000000004907', -34.918,  -56.186, 'CASA',     'RECHAZO',                      7, null),
  ('01920000-0000-7000-8000-000000004909', -34.919,  -56.188, 'CASA',     'RECHAZO',                      7, null),
  ('01920000-0000-7000-8000-00000000490a', -34.9195, -56.189, 'CASA',     'RECHAZO',                      7, now()),
  ('01920000-0000-7000-8000-00000000490b', -34.92,   -56.18,  'CASA',     'SIN_CONTESTAR',                6, null),
  ('01920000-0000-7000-8000-00000000490c', -34.97,   -56.18,  'CASA',     'RECHAZO',                      7, null),
  ('01920000-0000-7000-8000-00000000490d', -34.895,  -56.18,  'CASA',     'SIN_CONTESTAR',                6, null),
  ('01920000-0000-7000-8000-00000000490e', -34.915,  -56.18,  'CASA',     'RECHAZO',                      7, null),
  ('01920000-0000-7000-8000-00000000490f', -34.945,  -56.18,  'CASA',     'SIN_CONTESTAR',                6, null);

-- Las casas de Centro, por ubicacion_id: 01 02 03 04 05 06 07 08 0a 0b.
create temp table esperadas_centro (ubicacion_id uuid, lat double precision, lon double precision,
                                    tipo text, estado text) on commit drop;
insert into esperadas_centro values
  ('01920000-0000-7000-8000-000000004901', -34.915,  -56.18,  'CASA',     'ENTREGA_Y_COBRANZA_PENDIENTE'),
  ('01920000-0000-7000-8000-000000004902', -34.9155, -56.181, 'NEGOCIO',  'COBRANZA_PENDIENTE'),
  ('01920000-0000-7000-8000-000000004903', -34.916,  -56.182, 'EDIFICIO', 'ENTREVISTA_PROGRAMADA'),
  ('01920000-0000-7000-8000-000000004904', -34.9165, -56.183, 'CASA',     'VENTA_COMPLETA'),
  ('01920000-0000-7000-8000-000000004905', -34.917,  -56.184, 'CASA',     'ENTREVISTA_SIN_VENTA'),
  ('01920000-0000-7000-8000-000000004906', -34.9175, -56.185, 'CASA',     'SIN_CONTESTAR'),
  ('01920000-0000-7000-8000-000000004907', -34.918,  -56.186, 'CASA',     'RECHAZO'),
  ('01920000-0000-7000-8000-000000004908', -34.9185, -56.187, 'CASA',     null),
  ('01920000-0000-7000-8000-00000000490a', -34.9195, -56.189, 'CASA',     null),
  ('01920000-0000-7000-8000-00000000490b', -34.92,   -56.18,  'CASA',     'SIN_CONTESTAR');
grant select on esperadas_centro to authenticated;
-- La cuenta interna de «Incluye N ubicaciones» (solo service_role la ejecuta), calculada acá.
create temp table incluidas_centro on commit drop as
select public.zona_ubicaciones_incluidas('01920000-0000-7000-8000-000000004971', z.poligono_geojson) as n
  from public.zona z where z.id = '01920000-0000-7000-8000-0000000049d1';
grant select on incluidas_centro to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.casas_de_zona(uuid,uuid,uuid,integer)'::regprocedure)),
          'TABLE(ubicacion_id uuid, lat double precision, lon double precision, tipo text, estado text)',
          'casas_de_zona(): la forma de la respuesta (sin dirección, sin personas, sin importes)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.casas_de_zona(uuid,uuid,uuid,integer)'::regprocedure),
          true, 'casas_de_zona() es SECURITY DEFINER (el coordinador no lee ubicacion ni house_status)');
select is((select p.provolatile from pg_proc p where p.oid = 'public.casas_de_zona(uuid,uuid,uuid,integer)'::regprocedure),
          'v', 'casas_de_zona() es VOLATILE (llama a exigir_lectura_de_campania())');
select is((select p.proconfig from pg_proc p where p.oid = 'public.casas_de_zona(uuid,uuid,uuid,integer)'::regprocedure),
          array['search_path=""'], 'casas_de_zona() fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.casas_de_zona(uuid,uuid,uuid,integer)', 'execute'),
          'authenticated ejecuta casas_de_zona()');
select ok(not has_function_privilege('anon', 'public.casas_de_zona(uuid,uuid,uuid,integer)', 'execute'),
          'anon NO ejecuta casas_de_zona()');
select ok(not has_function_privilege('service_role', 'public.casas_de_zona(uuid,uuid,uuid,integer)', 'execute'),
          'service_role NO ejecuta casas_de_zona() (sin sesión no hay permiso que comprobar)');
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.casas_de_zona(uuid,uuid,uuid,integer)'::regprocedure),
          0, 'casas_de_zona() no tiene EXECUTE para PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'sin JWT (el servidor), casas_de_zona() falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'authenticated sin sesión: casas_de_zona() falla');

select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'anon no llama a casas_de_zona()');
select pg_temp.actuar_como_servidor();

-- Un colportor (aunque esté inscripto en la campaña y en esa zona), un usuario sin rol y un
-- coordinador con el rol vencido: nadie de ellos llama.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a0');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'un colportor no llama a casas_de_zona()');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049b1');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'un colportor inscripto en la zona tampoco');
-- El permiso va antes que la existencia: un colportor no averigua qué campañas ni qué zonas hay.
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049ff', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049ff') $$,
  '42501', null, 'un colportor con una zona inexistente: 42501, no CZ004');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 0) $$,
  '42501', null, 'un colportor con un tamaño de página inválido: 42501, no 22023');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a3');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'un usuario sin ningún rol no llama a casas_de_zona()');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a4');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'con el rol de coordinador vencido, casas_de_zona() falla');

-- El coordinador de OTRA campaña no ve las casas de la mía, ni con su propia campaña y mi zona.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a2');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  '42501', null, 'el coordinador de otra campaña no ve las casas de esta');
select throws_like($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  'Solo el coordinador de la campaña%', 'el mensaje del 42501 dice quién puede');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e2', '01920000-0000-7000-8000-0000000049d1') $$,
  'CZ004', null, 'con su campaña y una zona de otra: CZ004, no las casas ajenas');
-- El permiso va antes que la vigencia: no averigua si la campaña ajena terminó (ni si empezó).
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e3', '01920000-0000-7000-8000-0000000049d5') $$,
  '42501', null, 'una campaña ajena y terminada: 42501, no CZ011');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e5', '01920000-0000-7000-8000-0000000049d6') $$,
  '42501', null, 'una campaña ajena que todavía no empezó: 42501');
-- Lo que sí se sabe: una campaña inexistente es CZ001 aun siendo de otro (mismo orden que el resto
-- de las lecturas del mapa; con ids UUIDv7 no se puede sondear qué campañas hay).
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049ff', '01920000-0000-7000-8000-0000000049d1') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña y de zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a1');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049ff', '01920000-0000-7000-8000-0000000049d1') $$,
  'CZ001', null, 'campaña inexistente: CZ001');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e4', '01920000-0000-7000-8000-0000000049d1') $$,
  'CZ001', null, 'campaña dada de baja: CZ001');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e3', '01920000-0000-7000-8000-0000000049d5') $$,
  'CZ011', null, 'campaña terminada: CZ011');
select throws_like($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e3', '01920000-0000-7000-8000-0000000049d5') $$,
  'La campaña ya terminó%', 'el mensaje de CZ011 dice qué pasó');
-- La vigencia va antes que la zona: una campaña terminada con una zona que no existe sigue siendo CZ011.
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e3', '01920000-0000-7000-8000-0000000049ff') $$,
  'CZ011', null, 'campaña terminada y zona inexistente: CZ011');

select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049ff') $$,
  'CZ004', null, 'zona inexistente: CZ004');
select throws_like($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049ff') $$,
  'La zona no existe o ya se dio de baja%', 'el mensaje de CZ004 dice qué hacer (recargar el mapa)');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d3') $$,
  'CZ004', null, 'zona dada de baja: CZ004');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d4') $$,
  'CZ004', null, 'zona de otra campaña (la de Otra, con las casas de Ciudad dos): CZ004');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d7') $$,
  'CZ004', null, 'zona de una ciudad que se quitó de la campaña: CZ004');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d6') $$,
  'CZ004', null, 'zona de otra campaña de la misma persona (Futura, con Verano): CZ004');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', null) $$,
  'CZ004', null, 'sin zona: CZ004');

-- Una campaña que todavía no empezó SÍ se lee (la vista 24 prepara el mapa antes del inicio).
select results_eq(
  $$ select ubicacion_id, estado from public.casas_de_zona('01920000-0000-7000-8000-0000000049e5', '01920000-0000-7000-8000-0000000049d6') $$,
  $$ values ('01920000-0000-7000-8000-00000000490f'::uuid, 'SIN_CONTESTAR') $$,
  'una campaña por empezar se lee: las casas de su zona');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Qué casas trae una zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a1');
-- Centro: las 10 vivas de Ciudad uno dentro de su forma, por ubicacion_id, con los siete estados.
select results_eq(
  $$ select ubicacion_id, lat, lon, tipo, estado
       from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') $$,
  $$ select ubicacion_id, lat, lon, tipo, estado from esperadas_centro order by ubicacion_id $$,
  'Centro: punto, tipo y estado de cada casa viva de la zona, en orden de ubicacion_id');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1')),
  (select n from incluidas_centro),
  'la cantidad de puntos es la misma cuenta que «Incluye N ubicaciones»');
select is((select count(*)::int from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-000000004971')
            where zona_id = '01920000-0000-7000-8000-0000000049d1' and ubicaciones_registradas = 10), 1,
  'y es la ubicaciones_registradas que lee la pestaña de la ciudad');
select is((select array_agg(distinct c.estado order by c.estado) filter (where c.estado is not null)
             from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c),
  array['COBRANZA_PENDIENTE', 'ENTREGA_Y_COBRANZA_PENDIENTE', 'ENTREVISTA_PROGRAMADA', 'ENTREVISTA_SIN_VENTA',
        'RECHAZO', 'SIN_CONTESTAR', 'VENTA_COMPLETA'],
  'los siete estados, también los de cobranza pendiente y el de venta pagada (decisión «Cobro panel»)');
select is((select array_agg(distinct c.tipo order by c.tipo)
             from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c),
  array['CASA', 'EDIFICIO', 'NEGOCIO'], 'los tres tipos de ubicación');
-- El estado es null si la casa no tiene house_status (08) o si el suyo está dado de baja (0a).
select is((select array_agg(c.ubicacion_id order by c.ubicacion_id)
             from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c
            where c.estado is null),
  array['01920000-0000-7000-8000-000000004908'::uuid, '01920000-0000-7000-8000-00000000490a'::uuid],
  'una casa sin house_status, o con el suyo dado de baja, viene con estado null (el punto está)');
-- No trae: 09 (ubicación dada de baja, aunque su house_status viva), 0c (afuera), 0d (Norte), 0e (otra ciudad).
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c
            where c.ubicacion_id in ('01920000-0000-7000-8000-000000004909', '01920000-0000-7000-8000-00000000490c',
                                     '01920000-0000-7000-8000-00000000490d', '01920000-0000-7000-8000-00000000490e')),
  0, 'no trae la dada de baja, la de afuera, la de otra zona ni la de otra ciudad');
select is((select c.estado from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c
            where c.ubicacion_id = '01920000-0000-7000-8000-00000000490b'),
  'SIN_CONTESTAR', 'una casa sobre el borde de la zona cuenta (ST_Covers)');

-- Norte: su única casa.
select results_eq(
  $$ select ubicacion_id, estado from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2') $$,
  $$ values ('01920000-0000-7000-8000-00000000490d'::uuid, 'SIN_CONTESTAR') $$,
  'Norte: solo la casa de Norte');
-- Cordón se superpone con Centro: las casas del cruce salen en las dos (la zona es solo visual).
select results_eq(
  $$ select ubicacion_id from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d8') $$,
  $$ values ('01920000-0000-7000-8000-000000004902'::uuid), ('01920000-0000-7000-8000-000000004903'::uuid),
            ('01920000-0000-7000-8000-000000004904'::uuid), ('01920000-0000-7000-8000-000000004905'::uuid), ('01920000-0000-7000-8000-000000004906'::uuid),
            ('01920000-0000-7000-8000-000000004907'::uuid), ('01920000-0000-7000-8000-000000004908'::uuid), ('01920000-0000-7000-8000-00000000490a'::uuid),
            ('01920000-0000-7000-8000-00000000490b'::uuid) $$,
  'Cordón (lat -34.925..-34.9155) trae las 9 de Centro que caen adentro (la 01, más al norte, no), sin repetir ninguna');

-- La misma posición en otra ciudad: la zona de Otra solo trae las casas de Ciudad dos.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a2');
select results_eq(
  $$ select ubicacion_id from public.casas_de_zona('01920000-0000-7000-8000-0000000049e2', '01920000-0000-7000-8000-0000000049d4') $$,
  $$ values ('01920000-0000-7000-8000-00000000490e'::uuid) $$,
  'la zona de Ciudad dos no trae las casas de Ciudad uno que están en el mismo lugar');

-- Un ADMIN lee las casas de la campaña de otro.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049ad');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1')), 10,
  'un ADMIN lee las casas de la zona de la campaña de otro');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Sin personas, sin importes, sin dirección
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a1');
select is((select array_agg(k order by k)
             from (select distinct jsonb_object_keys(to_jsonb(c)) k
                     from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c) x),
  array['estado', 'lat', 'lon', 'tipo', 'ubicacion_id'],
  'cada fila trae solo ubicacion_id, lat, lon, tipo y estado: ni calle ni número, ni personas, ni importes');
select is((select count(*)::int
             from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1') c
            where to_jsonb(c)::text ilike '%Mataojo%' or to_jsonb(c)::text like '%2044%'),
  0, 'la dirección de la casa 01 («Mataojo 2044») no viaja con el punto');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Tope y paginado: un tope no esconde resultados
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a1');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 0) $$,
  '22023', null, 'p_limite = 0: 22023');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, -5) $$,
  '22023', null, 'p_limite negativo: 22023');
select throws_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 5001) $$,
  '22023', null, 'p_limite = 5001: 22023, no se recorta en silencio');
select throws_like($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 5001) $$,
  'El tamaño de la página tiene que estar entre 1 y 5000%', 'el mensaje de 22023 dice qué hacer');
select lives_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 5000) $$,
  'p_limite = 5000 es el máximo');
select lives_ok($$ select * from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 1) $$,
  'p_limite = 1 es el mínimo');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, null)), 10,
  'p_limite null no es un error: trae todo lo que hay si cabe en la página por defecto');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 4)), 4,
  'una página trae a lo sumo p_limite casas');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 1000)), 10,
  'y menos si no hay más: una página corta es la última');

-- Recorrer todas las páginas trae las 10, sin repetir ni saltear ninguna, con cualquier tamaño.
create temp table ids_centro on commit drop as
select string_agg(ubicacion_id::text, ',' order by ubicacion_id) as ids from esperadas_centro;
grant select on ids_centro to authenticated;
select is(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', 1),
  '11:' || (select ids from ids_centro), 'de a 1: 11 páginas (la última, vacía) y las 10 casas');
select is(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', 3),
  '4:' || (select ids from ids_centro), 'de a 3: 4 páginas y las 10 casas');
select is(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', 4),
  '3:' || (select ids from ids_centro), 'de a 4: 3 páginas y las 10 casas');
select is(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', 9),
  '2:' || (select ids from ids_centro), 'de a 9: 2 páginas y las 10 casas');
select is(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', 10),
  '2:' || (select ids from ids_centro), 'de a 10 justo: la segunda página, vacía, dice que no hay más');
select is(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', 11),
  '1:' || (select ids from ids_centro), 'de a 11: una sola página');
-- La página siguiente a la última casa está vacía; con un cursor que ya no existe también anda.
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1',
                                                          '01920000-0000-7000-8000-00000000490b', 5)), 0,
  'después de la última casa no hay más');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1',
                                                          '01920000-0000-7000-8000-000000004909', 100)), 2,
  'el cursor es una clave de orden: la casa 09 está dada de baja y la página sigue en 0a y 0b');

-- Una casa que se da de baja entre dos páginas no rompe el recorrido.
create temp table primera_pagina on commit drop as
select array_agg(c.ubicacion_id order by c.ubicacion_id) as ids
  from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1', null, 3) c;
select pg_temp.actuar_como_servidor();
update public.ubicacion set deleted_at = now() where id = '01920000-0000-7000-8000-000000004903';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a1');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d1',
                                                          (select ids[3] from primera_pagina), 100)), 7,
  'la última de la primera página se dio de baja: la segunda trae las 7 que siguen');
select is((select ids[3] from primera_pagina), '01920000-0000-7000-8000-000000004903'::uuid,
  '(era la tercera de la primera página)');

-- ---------------------------------------------------------------------------
-- 7. Una zona grande: el tope manda y el recorrido las trae todas
-- ---------------------------------------------------------------------------
-- 6000 casas dentro de Norte (80 × 75 puntos), la mitad con estado.
insert into public.ubicacion (tipo, lat, lon, ciudad_id)
select 'CASA', -34.8995 + (n / 80) * 0.00012, -56.1895 + (n % 80) * 0.00024,
       '01920000-0000-7000-8000-0000000049c1'
  from generate_series(0, 5999) n;
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad)
select u.id, u.lat, u.lon, 'CASA', 'COBRANZA_PENDIENTE', 2
  from public.ubicacion u
 where u.ciudad_id = '01920000-0000-7000-8000-0000000049c1'
   and u.lat > -34.9 and u.lat < -34.89
   and u.id <> '01920000-0000-7000-8000-00000000490d'
   and mod(('x' || substr(md5(u.id::text), 1, 4))::bit(16)::int, 2) = 0;

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000049a1');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2')),
  1000, 'sin pedir tamaño, una zona grande trae 1000 y no las 6001');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2', null, null)),
  1000, 'con p_limite null, también 1000 (el valor por defecto)');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2', null, 5000)),
  5000, 'con el máximo, 5000');
select is((select count(*)::int from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2',
            (select c.ubicacion_id from public.casas_de_zona('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2', null, 5000) c order by c.ubicacion_id desc limit 1), 5000)),
  1001, 'la página siguiente al máximo trae las 1001 que faltan (6000 + la 0d)');
select is(split_part(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2', 2500), ':', 1),
  '3', 'de a 2500: 3 páginas');
select is((select count(distinct x)::int from unnest(string_to_array(
            split_part(pg_temp.paginar('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2', 2500), ':', 2), ',')) x),
  6001, 'y las 6001 casas distintas: ninguna repetida, ninguna salteada');
select cmp_ok(pg_temp.ms_de_una_pagina('01920000-0000-7000-8000-0000000049e1', '01920000-0000-7000-8000-0000000049d2', 5000), '<', 4000::numeric,
  'una página de 5000 tarda menos de 4 s (el statement timeout de Supabase es de 8 s)');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
