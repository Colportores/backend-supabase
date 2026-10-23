-- pgTAP · el departamento de cada ciudad (migración 0063, backend-supabase#92, HU-ADM-005, HU-CAM-008)
-- public.ciudad.departamento: la columna, su restricción (sin blancos ni espacios en los costados, hasta
-- 60 caracteres) y el trigger que lo exige hacia adelante (CD001: una ciudad nueva sin departamento y
-- borrárselo a una que lo tenía se rechazan; las ciudades viejas sin él se siguen actualizando y dando de
-- baja); ciudades_de_campania() y ciudades_del_catalogo() lo devuelven;
-- ciudades_del_catalogo() además BUSCA por él (sin mayúsculas ni tildes, texto literal) y lo usa para
-- distinguir dos ciudades con el mismo nombre; los privilegios y el permiso de la 0033 siguen igual; y el
-- pull lo lleva con la ciudad. La carga de Montevideo y que no se pierda ni una fila de antes: en
-- supabase/tests_migracion/0063_*.
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

create or replace function pg_temp.actuar_como_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', 'anon', true);
  perform set_config('role', 'anon', true);
end $$;

-- El rol `authenticated` pero sin sesión: auth.uid() es null.
create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

-- Una sentencia con el trigger del departamento apagado: arma una ciudad «vieja» (sin departamento), como
-- las que ya estaban cargadas cuando llegó la 0063. Lo vuelve a prender siempre (también si falla).
create or replace function pg_temp.sin_trigger(p_sql text) returns void language plpgsql as $$
begin
  alter table public.ciudad disable trigger ciudad_departamento_obligatorio;
  begin
    execute p_sql;
  exception when others then
    alter table public.ciudad enable trigger ciudad_departamento_obligatorio;
    raise;
  end;
  alter table public.ciudad enable trigger ciudad_departamento_obligatorio;
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000055' || p_sufijo)::uuid
$$;

-- Los nombres del catálogo para un texto, en el orden en que vuelven, con su departamento
-- («Nombre/Departamento», «-» si no tiene). Se filtra por los ids de este archivo: la base puede traer
-- otras ciudades (el seed).
create or replace function pg_temp.catalogo(p_camp text, p_texto text) returns text language sql as $$
  select coalesce(string_agg(format('%s/%s', r.nombre, coalesce(r.departamento, '-')), ' | ' order by r.o), '(vacío)')
    from (select r.*, row_number() over () o
            from public.ciudades_del_catalogo(pg_temp.u(p_camp), p_texto) r
           where r.ciudad_id::text like '01920000-0000-7000-8000-0000000055%') r
$$;

-- SQLSTATE|mensaje del error que da una sentencia ('ok' si no da ninguno).
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || '|' || sqlerrm;
end $$;

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de e1, e2 y e3; ad admin; a0 colportor; a3 sin ningún rol.
-- Campañas: e1 Verano (vigente)  e2 Vieja (terminada)  e3 Futura (empieza en 10 días).
-- Ciudades (departamento): c1 Montevideo q55 (Montevideo)  c2 Salto q55 (Salto)
--   c3 y c4 San José q55 (Dpto Beta q55 y Dpto Alfa q55: la misma ciudad en dos departamentos)
--   c5 Belén q55 (Salto)  c6 Constitución q55 (Salto; su fila en Verano está dada de baja)
--   c7 Sin dato q55 (sin departamento: una ciudad «vieja», cargada con el trigger apagado)  c8 Baja q55 (Salto, dada de baja del catálogo)
--   c9 Villa Salto q55 (Artigas q55)  ca Paysandú q55 (Paysandú)  cb Ya está q55 (Salto, en Verano)
--   cc Young q55 (Río Negro: un departamento con tilde y un espacio, para buscarlo sin ellos)
-- campania_ciudad: 71 Verano/c1  72 Verano/cb  73 Verano/c6 (de baja)  74 Vieja/c1  75 Futura/c2
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'dep55-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a3','ad']) s;

insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais dep55', 'ZD');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial, deleted_at) values
  (pg_temp.u('c1'), 'Montevideo q55',    'Montevideo',   pg_temp.u('c0'), -34.90, -56.16, 13, null),
  (pg_temp.u('c2'), 'Salto q55',         'Salto',        pg_temp.u('c0'), -31.40, -57.96, 12, null),
  (pg_temp.u('c3'), 'San José q55',      'Dpto Beta q55',  pg_temp.u('c0'), -34.34, -56.71, 12, null),
  (pg_temp.u('c4'), 'San José q55',      'Dpto Alfa q55',  pg_temp.u('c0'), -34.40, -56.00, 12, null),
  (pg_temp.u('c5'), 'Belén q55',         'Salto',        pg_temp.u('c0'), -30.79, -57.78, 12, null),
  (pg_temp.u('c6'), 'Constitución q55',  'Salto',        pg_temp.u('c0'), -31.08, -57.83, 12, null),
  (pg_temp.u('c8'), 'Baja q55',          'Salto',        pg_temp.u('c0'), -31.00, -57.00, 11, now()),
  (pg_temp.u('c9'), 'Villa Salto q55',   'Artigas q55',  pg_temp.u('c0'), -31.50, -57.90, 11, null),
  (pg_temp.u('ca'), 'Paysandú q55',      'Paysandú',     pg_temp.u('c0'), -32.32, -58.08, 12, null),
  (pg_temp.u('cb'), 'Ya está q55',       'Salto',        pg_temp.u('c0'), -31.20, -57.50, 11, null),
  (pg_temp.u('cc'), 'Young q55',         'Río Negro',    pg_temp.u('c0'), -32.70, -57.63, 11, null);
-- La ciudad vieja: sin departamento (con el trigger prendido no se podría cargar).
select pg_temp.sin_trigger($$ insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial)
  values ('01920000-0000-7000-8000-0000000055c7', 'Sin dato q55', '01920000-0000-7000-8000-0000000055c0', -33.00, -56.00, 11) $$);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano q55', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Vieja q55',  'VERANO', public.hoy_montevideo() - 90, public.hoy_montevideo() - 30, pg_temp.u('a1')),
  (pg_temp.u('e3'), 'Futura q55', 'VERANO', public.hoy_montevideo() + 10, public.hoy_montevideo() + 40, pg_temp.u('a1'));
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'), null),
  (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('cb'), null),
  (pg_temp.u('73'), pg_temp.u('e1'), pg_temp.u('c6'), now()),
  (pg_temp.u('74'), pg_temp.u('e2'), pg_temp.u('c1'), null),
  (pg_temp.u('75'), pg_temp.u('e3'), pg_temp.u('c2'), null);

-- ---------------------------------------------------------------------------
-- 1. La columna y su restricción
-- ---------------------------------------------------------------------------
select has_column('public', 'ciudad', 'departamento', 'ciudad tiene la columna departamento');
select col_type_is('public', 'ciudad', 'departamento', 'text', 'es texto');
select col_is_null('public', 'ciudad', 'departamento', 'y admite null en la base (las ciudades que ya estaban, todavía sin cargar)');
select is((select col_description('public.ciudad'::regclass,
                                  (select attnum from pg_attribute where attrelid = 'public.ciudad'::regclass and attname = 'departamento')))
          like '%0063%', true, 'la columna tiene su comentario');

select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z q55', 'Salto', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$), 'ok',
          'una ciudad con departamento se carga');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro)
                             values ('Z2 q55', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          'CD001|Cargá el departamento de la ciudad',
          'una ciudad NUEVA sin departamento se rechaza (CD001): la columna no se llena sola');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z2b q55', null, '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          'CD001|Cargá el departamento de la ciudad', 'también si se manda null a propósito');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro, deleted_at)
                             values ('Z2c q55', null, '01920000-0000-7000-8000-0000000055c0', 0, 0, now()) $$),
          'CD001|Cargá el departamento de la ciudad', 'y una nueva ya dada de baja tampoco entra sin departamento');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro) values
                               ('Z2d q55', 'Salto', '01920000-0000-7000-8000-0000000055c0', 0, 0),
                               ('Z2e q55', null, '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          'CD001|Cargá el departamento de la ciudad', 'en un insert de varias, una sola sin departamento lo rechaza');
select is((select count(*)::int from public.ciudad where nombre in ('Z2 q55', 'Z2b q55', 'Z2c q55', 'Z2d q55', 'Z2e q55')), 0,
          'y no queda ninguna de esas filas (el insert es atómico)');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z3 q55', repeat('x', 60), '01920000-0000-7000-8000-0000000055c0', 0, 0) $$), 'ok',
          'un departamento de 60 caracteres entra');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z4 q55', repeat('x', 61), '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'uno de 61 se rechaza con la restricción por nombre');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z5 q55', '', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'uno vacío se rechaza');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z6 q55', '   ', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'uno en blanco se rechaza');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z7 q55', ' Salto', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'con un espacio al principio se rechaza (así «Salto» y « Salto» no son dos grupos)');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z8 q55', 'Salto ', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'y con uno al final también');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Z9 q55', E'Salto\n', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'y con un salto de línea al final');
select is(pg_temp.error_de($$ insert into public.ciudad (nombre, departamento, pais_id, lat_centro, lon_centro)
                             values ('Za q55', 'Río Negro', '01920000-0000-7000-8000-0000000055c0', 0, 0) $$), 'ok',
          'un departamento con un espacio en el medio y tilde («Río Negro») entra');
select is(pg_temp.error_de($$ update public.ciudad set departamento = '  ' where id = '01920000-0000-7000-8000-0000000055c7' $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'un UPDATE a un valor en blanco también se rechaza');
select is(pg_temp.error_de($$ update public.ciudad set departamento = 'Colonia' where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'cargar el departamento de una ciudad que no lo tenía anda');
select is(pg_temp.error_de($$ update public.ciudad set departamento = null where id = '01920000-0000-7000-8000-0000000055c7' $$),
          'CD001|Cargá el departamento de la ciudad', 'pero volver a null (borrárselo a la que ya lo tiene) se rechaza');
select is((select departamento from public.ciudad where id = pg_temp.u('c7')), 'Colonia', 'y el departamento sigue');
select is(pg_temp.error_de($$ update public.ciudad set departamento = null where id = '01920000-0000-7000-8000-0000000055c3' $$),
          'CD001|Cargá el departamento de la ciudad', 'a una que ya venía con departamento tampoco se le borra');
select is((select departamento from public.ciudad where id = pg_temp.u('c3')), 'Dpto Beta q55', 'y conserva el suyo');
select is(pg_temp.error_de($$ update public.ciudad set departamento = 'Otro q55' where id = '01920000-0000-7000-8000-0000000055c3' $$), 'ok',
          'cambiarle el departamento a otro sí se puede');
select is(pg_temp.error_de($$ update public.ciudad set departamento = 'Dpto Beta q55' where id = '01920000-0000-7000-8000-0000000055c3' $$), 'ok',
          'y volverlo');
select is(pg_temp.error_de($$ update public.ciudad set nombre = 'San José q55', departamento = null where id = '01920000-0000-7000-8000-0000000055c3' $$),
          'CD001|Cargá el departamento de la ciudad', 'borrarlo junto con otras columnas también se rechaza');

-- Las ciudades VIEJAS sin departamento (c7, otra vez sin él) siguen funcionando como siempre.
select pg_temp.sin_trigger($$ update public.ciudad set departamento = null where id = '01920000-0000-7000-8000-0000000055c7' $$);
select is((select departamento from public.ciudad where id = pg_temp.u('c7')), null, 'c7 es una ciudad vieja sin departamento');
select is(pg_temp.error_de($$ update public.ciudad set zoom_inicial = 12, lat_centro = -33.1, lon_centro = -56.1
                              where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'una ciudad vieja sin departamento se sigue actualizando (zoom, centro)');
select is(pg_temp.error_de($$ update public.ciudad set bbox_oeste = -57.0, bbox_sur = -34.0, bbox_este = -55.0, bbox_norte = -32.0
                              where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'también se le carga el rectángulo');
select is(pg_temp.error_de($$ update public.ciudad set departamento = null where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'un UPDATE que nombra el departamento y lo deja en null donde ya era null pasa (sigue sin cargar)');
select is(pg_temp.error_de($$ update public.ciudad set departamento = departamento where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'igual con departamento = departamento');
select is(pg_temp.error_de($$ update public.ciudad set deleted_at = now() where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'se puede dar de baja');
select is(pg_temp.error_de($$ update public.ciudad set deleted_at = null where id = '01920000-0000-7000-8000-0000000055c7' $$), 'ok',
          'y reactivar');
select is(pg_temp.error_de($$ update public.ciudad set departamento = '  ' where id = '01920000-0000-7000-8000-0000000055c7' $$),
          '23514|new row for relation "ciudad" violates check constraint "ciudad_departamento_check"',
          'y un valor en blanco lo sigue frenando la restricción, no el trigger');

-- El trigger.
select has_trigger('public', 'ciudad', 'ciudad_departamento_obligatorio', 'ciudad tiene su trigger del departamento');
select is((select tgenabled::text from pg_trigger where tgrelid = 'public.ciudad'::regclass and tgname = 'ciudad_departamento_obligatorio'), 'O',
          'y está prendido');
select is((select (tgtype & 1) = 1 and (tgtype & 2) = 2 and (tgtype & 4) = 4 and (tgtype & 16) = 16
             from pg_trigger where tgrelid = 'public.ciudad'::regclass and tgname = 'ciudad_departamento_obligatorio'),
          true, 'por fila, BEFORE, para INSERT y UPDATE');
select is((select pg_get_triggerdef(oid) like '%UPDATE OF departamento%' from pg_trigger
            where tgrelid = 'public.ciudad'::regclass and tgname = 'ciudad_departamento_obligatorio'),
          true, 'y el UPDATE solo mira la columna departamento');
select is((select string_agg(r, ',' order by r) from unnest(array['anon', 'authenticated', 'service_role']) r
            where has_function_privilege(r, 'public.tg_ciudad_departamento_obligatorio()'::regprocedure, 'execute')),
          null, 'la función del trigger no la ejecuta nadie a mano (corre igual)');
select is((select obj_description('public.tg_ciudad_departamento_obligatorio()'::regprocedure, 'pg_proc') like '%CD001%'), true,
          'y tiene su comentario');

-- ---------------------------------------------------------------------------
-- 2. La forma de las dos lecturas y sus privilegios (los de la 0033)
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.ciudades_de_campania(uuid)'::regprocedure)),
          'TABLE(campania_ciudad_id uuid, ciudad_id uuid, nombre text, departamento text, lat_centro double precision, lon_centro double precision, zoom_inicial smallint, cantidad_zonas integer)',
          'ciudades_de_campania(): la forma de la respuesta, con el departamento después del nombre');
select is((select pg_get_function_result('public.ciudades_del_catalogo(uuid,text)'::regprocedure)),
          'TABLE(ciudad_id uuid, nombre text, departamento text)', 'ciudades_del_catalogo(): la forma de la respuesta');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('ciudades_de_campania', 'ciudades_del_catalogo')), 2,
          'quedó una sola versión de cada función (la vieja se eliminó)');

select is((select string_agg(f || ':' || r, ',' order by f, r)
             from unnest(array['public.ciudades_de_campania(uuid)', 'public.ciudades_del_catalogo(uuid,text)']) f,
                  unnest(array['anon', 'authenticated', 'service_role']) r
            where has_function_privilege(r, f::regprocedure, 'execute')),
          'public.ciudades_de_campania(uuid):authenticated,public.ciudades_del_catalogo(uuid,text):authenticated',
          'solo authenticated ejecuta las dos, como en la 0033: ni anon ni service_role');
select is((select count(*)::int
             from pg_proc p, aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
            where p.oid in ('public.ciudades_de_campania(uuid)'::regprocedure, 'public.ciudades_del_catalogo(uuid,text)'::regprocedure)
              and a.grantee = 0), 0, 'y public no las ejecuta');
select is((select bool_and(p.prosecdef) from pg_proc p
            where p.oid in ('public.ciudades_de_campania(uuid)'::regprocedure, 'public.ciudades_del_catalogo(uuid,text)'::regprocedure)),
          true, 'siguen siendo SECURITY DEFINER');
select is((select bool_and(p.provolatile = 'v') from pg_proc p
            where p.oid in ('public.ciudades_de_campania(uuid)'::regprocedure, 'public.ciudades_del_catalogo(uuid,text)'::regprocedure)),
          true, 'y VOLATILE (supabase-js las manda por POST, como antes)');
select is((select bool_and(p.proconfig = array['search_path=""']) from pg_proc p
            where p.oid in ('public.ciudades_de_campania(uuid)'::regprocedure, 'public.ciudades_del_catalogo(uuid,text)'::regprocedure)),
          true, 'con search_path vacío');
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.ciudades_de_campania(uuid)'::regprocedure, 'public.ciudades_del_catalogo(uuid,text)'::regprocedure)
              and obj_description(p.oid, 'pg_proc') like '%0063%'), 2, 'las dos tienen su comentario al día');

-- ---------------------------------------------------------------------------
-- 3. El permiso, primero (el de la 0033)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_anon();
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') $$, '42501', null, 'anon no llama a ciudades_de_campania()');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000055e1', 'salto') $$, '42501', null, 'anon no llama a ciudades_del_catalogo()');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') $$, '42501', null, 'authenticated sin sesión: ciudades_de_campania() falla');
select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') $$, '42501', null, 'un colportor no lista las ciudades');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000055e1', 'salto') $$, '42501', null, 'un colportor no busca en el catálogo (ni por departamento)');
select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000055e1', 'salto') $$, '42501', null, 'un usuario sin ningún rol tampoco');
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055ff') $$, 'CZ001', null, 'campaña inexistente: CZ001 (ciudades)');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000055ff', 'salto') $$, 'CZ001', null, 'campaña inexistente: CZ001 (catálogo)');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e2') $$, 'CZ011', null, 'campaña terminada: CZ011 (ciudades)');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000055e2', 'salto') $$, 'CZ011', null, 'campaña terminada: CZ011 (catálogo)');

-- ---------------------------------------------------------------------------
-- 4. ciudades_de_campania() devuelve el departamento
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select results_eq(
  $$ select ciudad_id, nombre, departamento, cantidad_zonas from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') order by nombre $$,
  $$ values (pg_temp.u('c1'), 'Montevideo q55'::text, 'Montevideo'::text, 0),
            (pg_temp.u('cb'), 'Ya está q55'::text, 'Salto'::text, 0) $$,
  'Verano: sus dos ciudades vivas, cada una con su departamento (la fila dada de baja no aparece)');
select results_eq(
  $$ select departamento from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e3') $$,
  $$ values ('Salto'::text) $$, 'una campaña por empezar también lo trae');
select pg_temp.actuar_como_servidor();
select pg_temp.sin_trigger($$ update public.ciudad set departamento = null where id = '01920000-0000-7000-8000-0000000055cb' $$);
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select departamento from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') where ciudad_id = pg_temp.u('cb')),
          null, 'una ciudad sin departamento vuelve con null, sin error');
select pg_temp.actuar_como_servidor();
update public.ciudad set departamento = 'Salto' where id = pg_temp.u('cb');
select pg_temp.actuar_como(pg_temp.u('ad'));
select results_eq(
  $$ select departamento from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') order by nombre $$,
  $$ values ('Montevideo'::text), ('Salto') $$, 'un ADMIN lo ve igual');
select pg_temp.actuar_como(pg_temp.u('a1'));

-- ---------------------------------------------------------------------------
-- 5. ciudades_del_catalogo(): el departamento en cada resultado
-- ---------------------------------------------------------------------------
select is(pg_temp.catalogo('e1', null),
          'Belén q55/Salto | Constitución q55/Salto | Paysandú q55/Paysandú | Salto q55/Salto | San José q55/Dpto Alfa q55'
          || ' | San José q55/Dpto Beta q55 | Sin dato q55/- | Villa Salto q55/Artigas q55 | Young q55/Río Negro',
          'sin texto: todas las vivas que no están (vivas) en Verano, cada una con su departamento (null = «-»); '
          'no la que ya está (Montevideo, Ya está), ni la dada de baja del catálogo; sí Constitución, cuya fila en Verano está dada de baja');
select is(pg_temp.catalogo('e1', '   '), pg_temp.catalogo('e1', null), 'un texto en blanco es como no escribir nada');
select is(pg_temp.catalogo('e3', null) like 'Belén q55/Salto%', true, 'una campaña por empezar también ofrece el catálogo');

-- Dos ciudades con el mismo nombre: el departamento las distingue y las ordena (el caso de Marta).
select is(pg_temp.catalogo('e1', 'san jose'),
          'San José q55/Dpto Alfa q55 | San José q55/Dpto Beta q55',
          'dos «San José»: salen una detrás de la otra, cada una con su departamento (a igual nombre, por departamento)');
select is(pg_temp.catalogo('e1', 'SAN JOSÉ'), pg_temp.catalogo('e1', 'san jose'), 'sin mayúsculas ni tildes');

-- Buscar por departamento.
select is(pg_temp.catalogo('e1', 'salto'),
          'Salto q55/Salto | Belén q55/Salto | Constitución q55/Salto | Villa Salto q55/Artigas q55',
          '«salto» encuentra Salto (nombre) y las demás del departamento de Salto; primero la que empieza con él, '
          'después A-Z; no la dada de baja del catálogo ni la que ya está en la campaña');
select is(pg_temp.catalogo('e1', '  SALTO '), pg_temp.catalogo('e1', 'salto'), 'los espacios de los costados y las mayúsculas no cuentan');
select is(pg_temp.catalogo('e1', 'artigas'), 'Villa Salto q55/Artigas q55',
          'una ciudad que solo coincide por su departamento aparece (el nombre no lo contiene)');
select is(pg_temp.catalogo('e1', 'dpto'), 'San José q55/Dpto Alfa q55 | San José q55/Dpto Beta q55',
          'el departamento se busca por parte de su texto (contiene)');
select is(pg_temp.catalogo('e1', 'dpto beta'), 'San José q55/Dpto Beta q55', 'y distingue cuál de las dos «San José»');
select is(pg_temp.catalogo('e1', 'beta'), 'San José q55/Dpto Beta q55',
          'el texto puede estar en el medio del departamento (no solo al principio)');
select is(pg_temp.catalogo('e1', 'rio negro'), 'Young q55/Río Negro',
          'sin tildes también en el departamento: «rio negro» encuentra Río Negro (la ciudad no lo dice en su nombre)');
select is(pg_temp.catalogo('e1', 'RÍO  NEGRO'), 'Young q55/Río Negro', 'con mayúsculas, tilde y espacios de más');
select is(pg_temp.catalogo('e1', 'belen'), 'Belén q55/Salto', 'sin tildes: «belen» encuentra Belén');
select is(pg_temp.catalogo('e1', 'paysandu'), 'Paysandú q55/Paysandú',
          'una ciudad que coincide por nombre Y por departamento sale una sola vez');
select is(pg_temp.catalogo('e1', 'PAYSANDÚ'), 'Paysandú q55/Paysandú', 'con mayúsculas y tilde');
select is(pg_temp.catalogo('e1', 'montevideo'), '(vacío)', 'la ciudad que ya está en la campaña no se ofrece, aunque coincida por su departamento');
select is(pg_temp.catalogo('e1', 'sin dato'), 'Sin dato q55/-',
          'una ciudad sin departamento se encuentra por su nombre, con departamento null');
select is(pg_temp.catalogo('e1', 'null'), '(vacío)', 'y un departamento null no se busca como el texto «null»');
select is(pg_temp.catalogo('e1', '%'), '(vacío)', 'un «%» no es un comodín');
select is(pg_temp.catalogo('e1', '_'), '(vacío)', 'un «_» tampoco');
select is(pg_temp.catalogo('e1', 'no existe ninguna asi'), '(vacío)', 'sin coincidencias: lista vacía, no error');

-- Un departamento con un carácter especial se busca literal.
select pg_temp.actuar_como_servidor();
update public.ciudad set departamento = 'Dpto 100% q55' where id = pg_temp.u('c7');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.catalogo('e1', '100%'), 'Sin dato q55/Dpto 100% q55', 'un «%» escrito se busca literal, también en el departamento');
select is(pg_temp.catalogo('e1', '0_ q'), '(vacío)', 'y un «_» no coincide con cualquier carácter');
select pg_temp.actuar_como_servidor();
select pg_temp.sin_trigger($$ update public.ciudad set departamento = null where id = '01920000-0000-7000-8000-0000000055c7' $$);
select pg_temp.actuar_como(pg_temp.u('a1'));

-- Agregar una ciudad la saca del buscador, también al buscar por su departamento.
select lives_ok($$ select public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000055e1', '01920000-0000-7000-8000-0000000055c5') $$,
                'a1 agrega Belén a Verano');
select is(pg_temp.catalogo('e1', 'salto'), 'Salto q55/Salto | Constitución q55/Salto | Villa Salto q55/Artigas q55',
          'Belén ya no se ofrece, tampoco al buscar por «salto»');
select results_eq(
  $$ select nombre, departamento from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') where ciudad_id = pg_temp.u('c5') $$,
  $$ values ('Belén q55'::text, 'Salto'::text) $$, 'y aparece en las ciudades de la campaña, con su departamento');

-- Dar de baja una ciudad del catálogo la saca del buscador aunque coincida por departamento.
select pg_temp.actuar_como_servidor();
update public.ciudad set deleted_at = now() where id = pg_temp.u('c2');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.catalogo('e1', 'salto'), 'Constitución q55/Salto | Villa Salto q55/Artigas q55',
          'dada de baja Salto, sale del buscador; las demás del departamento siguen');
select pg_temp.actuar_como_servidor();
update public.ciudad set deleted_at = null where id = pg_temp.u('c2');

-- ---------------------------------------------------------------------------
-- 6. Que leer no escribe, y el pull lleva el departamento
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
create temp table antes as select id, sync_version, updated_at, departamento from public.ciudad
 where id::text like '01920000-0000-7000-8000-0000000055%';
select pg_temp.actuar_como(pg_temp.u('a1'));
select lives_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000055e1') $$, 'lee las ciudades de la campaña');
select lives_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000055e1', 'salto') $$, 'y busca en el catálogo');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.ciudad c join antes a using (id)
            where (c.sync_version, c.updated_at, c.departamento) is distinct from (a.sync_version, a.updated_at, a.departamento)), 0,
          'leer las ciudades no cambia ninguna fila');

create or replace function pg_temp.fila_del_pull(p_id uuid) returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  execute format('select %s from public.ciudad t where t.id = $1', sync.expresion_json('public.ciudad'::regclass))
     into v using p_id;
  return v;
end $$;
select is(pg_temp.fila_del_pull(pg_temp.u('c3')) ->> 'departamento', 'Dpto Beta q55',
          'la fila de la ciudad que baja en el pull trae departamento (sync.expresion_json manda todas las columnas)');
select ok(pg_temp.fila_del_pull(pg_temp.u('c7')) ? 'departamento' and pg_temp.fila_del_pull(pg_temp.u('c7')) -> 'departamento' = 'null'::jsonb,
          'y una ciudad sin departamento lo trae en null (la clave no falta)');

select * from finish();
rollback;
