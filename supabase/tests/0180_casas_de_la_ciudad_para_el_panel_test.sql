-- pgTAP · migración 0180 (backend-supabase#254, casilla «Casas ciudad»): todas las casas de la ciudad de la campaña para el panel.
-- casas_de_la_ciudad(): la forma y los privilegios; el permiso primero (los mismos que casas_de_zona(): sin JWT, anon,
-- colportor, sin rol, rol vencido, coordinador de otra campaña) y que sí entran un coordinador de la campaña, su segundo
-- coordinador (0175) y el ADMIN; los códigos (CZ001, CZ011, CZ012, 22023); las casas de la ciudad con y sin zona (vivas,
-- de esa ciudad, también las que caen fuera de toda zona); la zona de cada una (null si no tiene; con zonas superpuestas, la
-- primera por nombre; sin las zonas dadas de baja); los siete estados y el estado null; la dirección y quién la registró;
-- que la respuesta no trae personas, importes ni notas; y el paginado.
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

create or replace function pg_temp.actuar_sin_jwt() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql immutable as $$
  select ('01920000-0000-7000-8000-0000000180' || p_sufijo)::uuid
$$;

-- Recorre todas las páginas de a p_limite, siguiendo el último ubicacion_id. Devuelve «<páginas>:<sufijos de los ids>».
create or replace function pg_temp.paginar(p_campania uuid, p_cc uuid, p_limite integer)
returns text language plpgsql as $$
declare
  v_todas  text[] := '{}';
  v_pagina uuid[];
  v_ultima uuid := null;
  v_n      integer := 0;
begin
  loop
    select coalesce(array_agg(c.ubicacion_id order by c.ubicacion_id), '{}') into v_pagina
      from public.casas_de_la_ciudad(p_campania, p_cc, v_ultima, p_limite) c;
    v_n := v_n + 1;
    if v_n > 100 then raise exception 'paginar: el recorrido no termina'; end if;
    v_todas := v_todas || (select coalesce(array_agg(right(x::text, 2) order by x), '{}') from unnest(v_pagina) x);
    exit when coalesce(array_length(v_pagina, 1), 0) < p_limite;
    v_ultima := v_pagina[array_length(v_pagina, 1)];
  end loop;
  return v_n || ':' || array_to_string(v_todas, ',');
end $$;

-- ---------------------------------------------------------------------------
-- Fixtures. Staff: a1 coordinador de Verano; a5 su segundo coordinador (campania_coordinador); a2 coordinador de Otra; ad admin;
--   a0 colportor; a3 sin rol; a4 coordinador con el rol vencido. b1 «Rosa Pérez» registró las casas; b2 «Luis Gómez», dado de baja.
-- Campañas: e1 Verano (vigente, a1)  e2 Otra (vigente, a2)  e3 Vieja (terminada, a1)
-- Ciudades c1 y c2. campania_ciudad: 71 Verano/c1  72 Otra/c2  73 Vieja/c1  75 Verano/c2 (de baja)
-- Zonas (rectángulos): d1 Centro (en 71, lat -34.92..-34.91)  d2 Norte (en 71, lat -34.90..-34.89)  d3 Borrada (en 71, de baja,
--   sobre Centro)  d4 Otra (en 72)  d5 Vieja (en 73, sobre Centro)  d8 Cordón (en 71, lat -34.925..-34.9155, se superpone con Centro)
-- ---------------------------------------------------------------------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at, raw_user_meta_data)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'ciudad180-' || s || '@example.com', 'x', now(), now(), now(),
       case s when 'b1' then jsonb_build_object('nombre', 'Rosa', 'apellido', 'Pérez')
              when 'b2' then jsonb_build_object('nombre', 'Luis', 'apellido', 'Gómez')
              else jsonb_build_object('nombre', 'N' || s, 'apellido', 'A' || s) end
  from unnest(array['a0','a1','a2','a3','a4','a5','ad','b1','b2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'), ('ad','ADMIN'), ('a0','COLPORTOR'),
               ('b1','COLPORTOR'), ('b2','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select pg_temp.u('a4'), r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';
update public.usuario set deleted_at = now() where id = pg_temp.u('b2');

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais ciudad180', 'ZR');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Ciudad uno q180', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Ciudad dos q180', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Verano180', 'VERANO', current_date - 10, current_date + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'Otra180',   'VERANO', current_date - 10, null,              pg_temp.u('a2')),
  (pg_temp.u('e3'), 'Vieja180',  'VERANO', current_date - 90, current_date - 30, pg_temp.u('a1'));
insert into public.campania_coordinador (campania_id, usuario_id) values (pg_temp.u('e1'), pg_temp.u('a5'));
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1'), null),
  (pg_temp.u('72'), pg_temp.u('e2'), pg_temp.u('c2'), null),
  (pg_temp.u('73'), pg_temp.u('e3'), pg_temp.u('c1'), null),
  (pg_temp.u('75'), pg_temp.u('e1'), pg_temp.u('c2'), now());

insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson, deleted_at) values
  (pg_temp.u('d1'), 'Centro',  pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  (pg_temp.u('d2'), 'Norte',   pg_temp.u('71'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.90],[-56.17,-34.90],[-56.17,-34.89],[-56.19,-34.89],[-56.19,-34.90]]]}'::jsonb, null),
  (pg_temp.u('d3'), 'Borrada', pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, now()),
  (pg_temp.u('d4'), 'Otra',    pg_temp.u('72'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  (pg_temp.u('d5'), 'Aaa Vieja', pg_temp.u('73'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb, null),
  (pg_temp.u('d8'), 'Cordón',  pg_temp.u('71'), 'ESQUINAS', null,
   '{"type":"Polygon","coordinates":[[[-56.19,-34.925],[-56.17,-34.925],[-56.17,-34.9155],[-56.19,-34.9155],[-56.19,-34.925]]]}'::jsonb, null);

-- Ubicaciones de c1 (los ids siguen el orden de las filas):
--   01..07 dentro de Centro, una por cada estado (01 casa con dirección, registrada por b1; 02 negocio; 03 edificio)
--   08 dentro de Centro, sin house_status    09 dada de baja    0a dentro de Centro y de Cordón, registrada por b2 (de baja)
--   0b sobre el borde sur de Centro          0c FUERA de toda zona (con estado)    0d dentro de Norte
--   0e es de c2 (otra ciudad)                0f FUERA de toda zona, sin estado, sin registrador
--   10 solo dentro de Cordón (no de Centro)
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at) values
  (pg_temp.u('01'), 'CASA',     'Mataojo', '2044', -34.915,  -56.18,  pg_temp.u('c1'), pg_temp.u('b1'), null),
  (pg_temp.u('02'), 'NEGOCIO',  null,      null,   -34.9155, -56.181, pg_temp.u('c1'), null, null),
  (pg_temp.u('03'), 'EDIFICIO', null,      null,   -34.916,  -56.182, pg_temp.u('c1'), null, null),
  (pg_temp.u('04'), 'CASA',     null,      null,   -34.9165, -56.183, pg_temp.u('c1'), null, null),
  (pg_temp.u('05'), 'CASA',     null,      null,   -34.917,  -56.184, pg_temp.u('c1'), null, null),
  (pg_temp.u('06'), 'CASA',     null,      null,   -34.9175, -56.185, pg_temp.u('c1'), null, null),
  (pg_temp.u('07'), 'CASA',     null,      null,   -34.918,  -56.186, pg_temp.u('c1'), null, null),
  (pg_temp.u('08'), 'CASA',     null,      null,   -34.9185, -56.187, pg_temp.u('c1'), null, null),
  (pg_temp.u('09'), 'CASA',     null,      null,   -34.919,  -56.188, pg_temp.u('c1'), null, now()),
  (pg_temp.u('0a'), 'CASA',     null,      null,   -34.9195, -56.189, pg_temp.u('c1'), pg_temp.u('b2'), null),
  (pg_temp.u('0b'), 'CASA',     null,      null,   -34.92,   -56.18,  pg_temp.u('c1'), null, null),
  (pg_temp.u('0c'), 'CASA',     'Sin zona', '12',  -34.97,   -56.18,  pg_temp.u('c1'), pg_temp.u('b1'), null),
  (pg_temp.u('0d'), 'CASA',     null,      null,   -34.895,  -56.18,  pg_temp.u('c1'), null, null),
  (pg_temp.u('0e'), 'CASA',     null,      null,   -34.915,  -56.18,  pg_temp.u('c2'), null, null),
  (pg_temp.u('0f'), 'CASA',     null,      null,   -34.98,   -56.18,  pg_temp.u('c1'), null, null),
  (pg_temp.u('10'), 'CASA',     null,      null,   -34.923,  -56.18,  pg_temp.u('c1'), null, null);

insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, deleted_at) values
  (pg_temp.u('01'), -34.915,  -56.18,  'CASA',     'ENTREGA_Y_COBRANZA_PENDIENTE', 1, null),
  (pg_temp.u('02'), -34.9155, -56.181, 'NEGOCIO',  'COBRANZA_PENDIENTE',           2, null),
  (pg_temp.u('03'), -34.916,  -56.182, 'EDIFICIO', 'ENTREVISTA_PROGRAMADA',        3, null),
  (pg_temp.u('04'), -34.9165, -56.183, 'CASA',     'VENTA_COMPLETA',               4, null),
  (pg_temp.u('05'), -34.917,  -56.184, 'CASA',     'ENTREVISTA_SIN_VENTA',         5, null),
  (pg_temp.u('06'), -34.9175, -56.185, 'CASA',     'SIN_CONTESTAR',                6, null),
  (pg_temp.u('07'), -34.918,  -56.186, 'CASA',     'RECHAZO',                      7, null),
  (pg_temp.u('09'), -34.919,  -56.188, 'CASA',     'RECHAZO',                      7, null),
  (pg_temp.u('0a'), -34.9195, -56.189, 'CASA',     'RECHAZO',                      7, now()),
  (pg_temp.u('0b'), -34.92,   -56.18,  'CASA',     'SIN_CONTESTAR',                6, null),
  (pg_temp.u('0c'), -34.97,   -56.18,  'CASA',     'RECHAZO',                      7, null),
  (pg_temp.u('0d'), -34.895,  -56.18,  'CASA',     'SIN_CONTESTAR',                6, null),
  (pg_temp.u('0e'), -34.915,  -56.18,  'CASA',     'RECHAZO',                      7, null);

-- Un vínculo con una persona (id opaco: la persona existe solo en el teléfono) en 01, para que la prueba de privacidad tenga algo que filtrar.
insert into public.espacio (id, ubicacion_id, created_by) values (pg_temp.u('a1'), pg_temp.u('01'), pg_temp.u('b1'));
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values (pg_temp.u('51'), pg_temp.u('a1'), pg_temp.u('f2'), pg_temp.u('b1'));

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.casas_de_la_ciudad(uuid,uuid,uuid,integer)'::regprocedure)),
          'TABLE(ubicacion_id uuid, lat double precision, lon double precision, tipo text, estado text, ultimo_cambio timestamp with time zone, zona_id uuid, zona_nombre text, calle text, numero text, registrada_por uuid, registrada_por_nombre text, registrada_por_apellido text)',
          'casas_de_la_ciudad(): la forma de la respuesta (la ubicación, la zona, la dirección y quién la registró; sin personas, importes ni notas)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.casas_de_la_ciudad(uuid,uuid,uuid,integer)'::regprocedure),
          true, 'es SECURITY DEFINER');
select is((select p.proconfig from pg_proc p where p.oid = 'public.casas_de_la_ciudad(uuid,uuid,uuid,integer)'::regprocedure),
          array['search_path=""'], 'fija search_path vacío');
select ok(has_function_privilege('authenticated', 'public.casas_de_la_ciudad(uuid,uuid,uuid,integer)', 'execute'), 'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.casas_de_la_ciudad(uuid,uuid,uuid,integer)', 'execute'), 'anon NO la ejecuta');
select ok(not has_function_privilege('service_role', 'public.casas_de_la_ciudad(uuid,uuid,uuid,integer)', 'execute'), 'service_role NO la ejecuta');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE' and p.oid = 'public.casas_de_la_ciudad(uuid,uuid,uuid,integer)'::regprocedure),
          0, 'sin EXECUTE para PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. El permiso es lo primero (los mismos que casas_de_zona)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'sin JWT (el servidor) falla');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'authenticated sin sesión falla');
select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'anon no la llama');
select pg_temp.actuar_como_servidor();

select pg_temp.actuar_como(pg_temp.u('a0'));
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'un colportor no la llama');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180ff', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071', null, 0) $$,
  '42501', null, 'un colportor con un tamaño de página inválido: 42501, no 22023');
select pg_temp.actuar_como(pg_temp.u('a3'));
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'un usuario sin ningún rol no la llama');
select pg_temp.actuar_como(pg_temp.u('a4'));
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'con el rol de coordinador vencido falla');
select pg_temp.actuar_como(pg_temp.u('a2'));
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  '42501', null, 'el coordinador de otra campaña no ve las casas de esta');
select throws_like($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071') $$,
  'Solo el coordinador de la campaña%', 'el mensaje del 42501 dice quién puede');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e3', '01920000-0000-7000-8000-000000018073') $$,
  '42501', null, 'una campaña ajena y terminada: 42501, no CZ011');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180ff', '01920000-0000-7000-8000-000000018071') $$,
  'CZ001', null, 'un coordinador con una campaña inexistente: CZ001');
-- Con su propia campaña y la ciudad de otra: CZ012, no las casas ajenas.
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e2', '01920000-0000-7000-8000-000000018071') $$,
  'CZ012', null, 'su campaña con la ciudad de otra campaña: CZ012');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña y ciudad
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180ff', '01920000-0000-7000-8000-000000018071') $$,
  'CZ001', null, 'campaña inexistente: CZ001');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e3', '01920000-0000-7000-8000-000000018073') $$,
  'CZ011', null, 'campaña terminada: CZ011');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-0000000180ff') $$,
  'CZ012', null, 'ciudad inexistente: CZ012');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018075') $$,
  'CZ012', null, 'ciudad quitada de la campaña: CZ012');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018073') $$,
  'CZ012', null, 'la ciudad de otra campaña (la misma ciudad real, otro campania_ciudad): CZ012');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071', null, 0) $$,
  '22023', null, 'tamaño de página 0: 22023');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071', null, 5001) $$,
  '22023', null, 'tamaño de página 5001: 22023');
select throws_ok($$ select * from public.casas_de_la_ciudad('01920000-0000-7000-8000-0000000180e1', '01920000-0000-7000-8000-000000018071', null, -3) $$,
  '22023', null, 'tamaño de página negativo: 22023');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 4. Las casas de la ciudad, con y sin zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
create temp table r1 as
  select right(ubicacion_id::text, 2) as id, tipo, estado, ultimo_cambio is not null as con_cambio,
         right(zona_id::text, 2) as zona, zona_nombre, calle, numero, registrada_por, registrada_por_nombre, registrada_por_apellido
    from public.casas_de_la_ciudad(pg_temp.u('e1'), pg_temp.u('71'));
grant select on r1 to authenticated;
select pg_temp.actuar_como_servidor();

select is((select array_agg(id order by id) from r1),
          array['01','02','03','04','05','06','07','08','0a','0b','0c','0d','0f','10'],
          'las 14 casas vivas de la ciudad c1, también las que están fuera de toda zona (0c, 0f); sin la dada de baja (09) ni la de c2 (0e)');
select is((select array_agg(id order by id) from r1 where zona is null), array['0c','0f'],
          'las que no están en ninguna zona traen zona_id y zona_nombre en null');
select is((select zona_nombre from r1 where id = '0f'), null, 'zona_nombre null en la que no tiene zona');
select is((select array_agg(id order by id) from r1 where zona = 'd1'),
          array['01','02','03','04','05','06','07','08','0a','0b'], 'dentro de Centro: 01..08, 0a y 0b (el borde incluido)');
select is((select zona_nombre from r1 where id = '01'), 'Centro', 'el nombre de la zona');
select is((select zona_nombre from r1 where id = '0a'), 'Centro',
          'con dos zonas que la cubren (Centro y Cordón) figura la primera por nombre; ni la zona dada de baja ni la de otra campaña cuentan');
select is((select zona_nombre from r1 where id = '10'), 'Cordón', 'la que solo cubre Cordón figura en Cordón');
select is((select zona_nombre from r1 where id = '0d'), 'Norte', 'dentro de Norte');
select is((select array_agg(id || '=' || coalesce(estado, 'null') order by id) from r1 where id <= '08'),
          array['01=ENTREGA_Y_COBRANZA_PENDIENTE','02=COBRANZA_PENDIENTE','03=ENTREVISTA_PROGRAMADA','04=VENTA_COMPLETA',
                '05=ENTREVISTA_SIN_VENTA','06=SIN_CONTESTAR','07=RECHAZO','08=null'],
          'los siete estados y, sin house_status, estado null');
select is((select estado from r1 where id = '0a'), null, 'un house_status dado de baja no cuenta: estado null');
select is((select con_cambio from r1 where id = '01'), true, 'ultimo_cambio de la que tiene estado');
select is((select con_cambio from r1 where id = '08'), false, 'y null en la que no lo tiene');
select is((select tipo from r1 where id = '02'), 'NEGOCIO', 'el tipo de la ubicación');
select is((select calle || ' ' || numero from r1 where id = '01'), 'Mataojo 2044', 'la dirección, como se guardó');
select is((select calle is null and numero is null from r1 where id = '02'), true, 'una casa marcada en el mapa sin dirección trae la dirección en null');
select is((select registrada_por_nombre || ' ' || registrada_por_apellido from r1 where id = '01'), 'Rosa Pérez', 'quién la registró (nombre y apellido)');
select is((select registrada_por from r1 where id = '01'), pg_temp.u('b1'), 'y su id');
select is((select registrada_por_nombre from r1 where id = '0a'), null, 'si quien la registró se dio de baja del sistema, no se sabe: null');
select is((select registrada_por is null from r1 where id = '0a'), true, 'y su id también');
select is((select registrada_por is null from r1 where id = '02'), true, 'sin created_by: null');
select is((select calle from r1 where id = '0c'), 'Sin zona', 'las que no tienen zona traen su dirección y quién las registró');
select is((select registrada_por_nombre from r1 where id = '0c'), 'Rosa', 'y quién las registró');

-- La respuesta no trae personas, importes ni notas (ADR-004).
select is((select string_agg(attname, ',' order by attnum) from pg_attribute
            where attrelid = 'r1'::regclass and attnum > 0 and not attisdropped),
          'id,tipo,estado,con_cambio,zona,zona_nombre,calle,numero,registrada_por,registrada_por_nombre,registrada_por_apellido',
          'solo las columnas pedidas');
select is((select count(*)::int from information_schema.columns
            where table_schema = 'public' and table_name = 'ubicacion' and column_name in ('nota', 'notas', 'observaciones')), 0,
          'la ubicación no tiene notas que filtrar');
select pg_temp.actuar_como(pg_temp.u('a1'));
select is((select count(*)::int from public.casas_de_la_ciudad(pg_temp.u('e1'), pg_temp.u('71')) c
            where c::text ilike '%' || pg_temp.u('f2')::text || '%' or c::text ilike '%' || pg_temp.u('51')::text || '%'), 0,
          'ninguna fila trae el id de la persona ni del vínculo de la casa 01');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 5. Quiénes entran: el segundo coordinador (0175) y el ADMIN
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a5'));
select is((select count(*)::int from public.casas_de_la_ciudad(pg_temp.u('e1'), pg_temp.u('71'))), 14,
          'el segundo coordinador de la campaña (campania_coordinador) lee las mismas 14');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is((select count(*)::int from public.casas_de_la_ciudad(pg_temp.u('e1'), pg_temp.u('71'))), 14, 'el ADMIN también');
select is((select count(*)::int from public.casas_de_la_ciudad(pg_temp.u('e2'), pg_temp.u('72'))), 1,
          'y la ciudad de otra campaña: c2 tiene una sola casa (0e), sin zona de c1 ni de Verano');
select is((select zona_nombre from public.casas_de_la_ciudad(pg_temp.u('e2'), pg_temp.u('72'))), 'Otra', 'con la zona de su propia campaña_ciudad');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 6. Paginado
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.paginar(pg_temp.u('e1'), pg_temp.u('71'), 5), '3:01,02,03,04,05,06,07,08,0a,0b,0c,0d,0f,10', 'de a 5: tres páginas, todas las casas, una vez cada una');
select is(pg_temp.paginar(pg_temp.u('e1'), pg_temp.u('71'), 14), '2:01,02,03,04,05,06,07,08,0a,0b,0c,0d,0f,10',
          'una página justo llena: la siguiente viene vacía, nada se pierde ni se repite');
select is(pg_temp.paginar(pg_temp.u('e1'), pg_temp.u('71'), 1000), '1:01,02,03,04,05,06,07,08,0a,0b,0c,0d,0f,10', 'el tope por defecto sirve para todas');
select is(pg_temp.paginar(pg_temp.u('e1'), pg_temp.u('71'), 1), '15:01,02,03,04,05,06,07,08,0a,0b,0c,0d,0f,10', 'de a 1: una por página (y una última vacía)');
select pg_temp.actuar_como_servidor();

-- La lectura no cambia nada.
select is((select count(*)::int from public.ubicacion where ciudad_id = pg_temp.u('c1') and deleted_at is null), 14,
          'leer no modificó ubicaciones');

select * from finish();
rollback;
