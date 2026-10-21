-- pgTAP · lecturas del panel sin BFF (migración 0033, backend-supabase#54, ADR-013)
-- mi_perfil(), campanias_del_coordinador(), ciudades_de_campania(), ciudades_del_catalogo() y
-- zonas_de_ciudad(): el permiso primero (sin JWT, anon, colportor, sin rol, rol vencido,
-- coordinador de otra campaña), los códigos de campaña (CZ001, CZ011, CZ012; una campaña por
-- empezar se lee y una terminada no), el contenido de cada respuesta y que no devuelven nada de
-- más (ni email, ni clientes, ni personas). También colportores_de_campania() y zonas_asignables(),
-- que 0033 alinea con el mismo criterio (la vista 24 de una campaña por empezar).
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

-- --- fixtures ------------------------------------------------------------------
-- Staff: a1 coordinador de Verano, Vieja, Borrada y Futura (Montevideo); a2 coordinador de Salto
--        y de Vacía; ad admin; a0 colportor; a3 sin ningún rol; a4 coordinador con el rol
--        vencido; a5 coordinador dado de baja; a6 coordinador de campañas en el borde de «hoy».
-- Colportores de Verano: b1 (Zeta), b2 (Alfa), b3 (Beta, suspendido) y b4 (usuario dado de
--        baja) en la zona Centro; b6 sin zona. b5 está en Salto.
-- Campañas: e1 Verano (vigente, a1)  e2 Salto (vigente, a2)  e3 Vieja (terminada, a1)
--        e4 Borrada (a1)  e5 Futura (empieza en 10 días, a1)  e6 Vacía (vigente, a2, sin ciudades)
--        De a6 (el día de Montevideo, sin ciudades): e7 termina hoy  e8 terminó ayer
--        e9 empieza hoy  ea empieza mañana  eb sin fin (empezó hace 5 días)  ec empieza en 30 días
-- Ciudades del catálogo: c1 Montevideo  c2 Salto  c3 Paysandú  c4 Baja (dada de baja del
--        catálogo pero en Verano)  c5 Ñandú  c6 Villa Salto (su fila en Verano está dada de baja)
--        c7 Borrada (dada de baja, en ninguna campaña)  c8 Azeta  c9 Zeta
-- campania_ciudad: 71 Verano/Montevideo  72 Verano/Baja  73 Verano/Villa Salto (de baja)
--        74 Salto/Salto  75 Vieja/Montevideo  76 Futura/Montevideo
-- Zonas: d1 Centro (radial)  d2 Cordón (esquinas)  d3 Borrada  (las tres en 71)  d4 Salto centro
--        (en 74)  d5 Ajena (en 75)  d6 Zona futura (en 76, la campaña que no empezó)
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000042' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'panel-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a0','a1','a2','a3','a4','a5','a6','ad','b1','b2','b3','b4','b5','b6']) s;

update public.usuario set nombre = x.n, apellido = x.a
  from (values ('a1','Coor','Uno'), ('a2','Coor','Dos'), ('a6','Coor','Seis'), ('ad','Admi','Nistra'),
               ('b1','Uno','Zeta'), ('b2','Ana','Alfa'), ('b3','Beto','Beta'), ('b4','Dani','Borrado'),
               ('b5','Eva','Salto'), ('b6','Fer','Sinzona')) x(s, n, a)
 where id = ('01920000-0000-7000-8000-0000000042' || x.s)::uuid;

insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000042' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('a5','COORDINADOR'), ('a6','COORDINADOR'), ('ad','ADMIN'),
               ('a0','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.usuario_rol (usuario_id, rol_id, valido_desde, valido_hasta)
select '01920000-0000-7000-8000-0000000042a4'::uuid, r.id, now() - interval '10 days', now() - interval '1 day'
  from public.rol r where r.codigo = 'COORDINADOR';
update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000042a5';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000042c0', 'Pais panel', 'ZP');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial, deleted_at) values
  ('01920000-0000-7000-8000-0000000042c1', 'Montevideo q54',     '01920000-0000-7000-8000-0000000042c0', -34.90, -56.16, 13, null),
  ('01920000-0000-7000-8000-0000000042c2', 'Salto q54',          '01920000-0000-7000-8000-0000000042c0', -31.40, -57.96, 12, null),
  ('01920000-0000-7000-8000-0000000042c3', 'Paysandú q54',       '01920000-0000-7000-8000-0000000042c0', -32.32, -58.08, 12, null),
  ('01920000-0000-7000-8000-0000000042c4', 'Baja q54',           '01920000-0000-7000-8000-0000000042c0', -33.00, -56.00, 11, now()),
  ('01920000-0000-7000-8000-0000000042c5', 'Ñandú q54',          '01920000-0000-7000-8000-0000000042c0', -33.50, -56.50, 11, null),
  ('01920000-0000-7000-8000-0000000042c6', 'Villa Salto q54',    '01920000-0000-7000-8000-0000000042c0', -31.50, -57.90, 11, null),
  ('01920000-0000-7000-8000-0000000042c7', 'Borrada q54',        '01920000-0000-7000-8000-0000000042c0', -30.00, -56.00, 11, now()),
  ('01920000-0000-7000-8000-0000000042c8', 'Azeta q54',          '01920000-0000-7000-8000-0000000042c0', -33.10, -55.90, 11, null),
  ('01920000-0000-7000-8000-0000000042c9', 'Zeta q54',           '01920000-0000-7000-8000-0000000042c0', -33.20, -55.80, 11, null);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000042e1', 'Verano',  'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000042a1', null),
  ('01920000-0000-7000-8000-0000000042e2', 'Salto',   'VERANO',     current_date - 10, null,              '01920000-0000-7000-8000-0000000042a2', null),
  ('01920000-0000-7000-8000-0000000042e3', 'Vieja',   'VERANO',     current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000042a1', null),
  ('01920000-0000-7000-8000-0000000042e4', 'Borrada', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000042a1', now()),
  ('01920000-0000-7000-8000-0000000042e5', 'Futura',  'VERANO',     current_date + 10, current_date + 40, '01920000-0000-7000-8000-0000000042a1', null),
  ('01920000-0000-7000-8000-0000000042e6', 'Vacía',   'PERMANENTE', current_date - 10, null,              '01920000-0000-7000-8000-0000000042a2', null);
-- Las de a6, contadas con el día de Montevideo (el que usa la base) y no con el de la sesión.
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000042e7', 'Termina hoy',    'VERANO',     public.hoy_montevideo() - 20, public.hoy_montevideo(),      '01920000-0000-7000-8000-0000000042a6'),
  ('01920000-0000-7000-8000-0000000042e8', 'Terminó ayer',   'VERANO',     public.hoy_montevideo() - 20, public.hoy_montevideo() - 1,  '01920000-0000-7000-8000-0000000042a6'),
  ('01920000-0000-7000-8000-0000000042e9', 'Empieza hoy',    'INVIERNO',   public.hoy_montevideo(),      public.hoy_montevideo() + 20, '01920000-0000-7000-8000-0000000042a6'),
  ('01920000-0000-7000-8000-0000000042ea', 'Empieza mañana', 'PERMANENTE', public.hoy_montevideo() + 1,  null,                         '01920000-0000-7000-8000-0000000042a6'),
  ('01920000-0000-7000-8000-0000000042eb', 'Sin fin',        'PERMANENTE', public.hoy_montevideo() - 5,  null,                         '01920000-0000-7000-8000-0000000042a6'),
  ('01920000-0000-7000-8000-0000000042ec', 'En 30 días',     'VERANO',     public.hoy_montevideo() + 30, public.hoy_montevideo() + 60, '01920000-0000-7000-8000-0000000042a6');
insert into public.campania_ciudad (id, campania_id, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-000000004271', '01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042c1', null),
  ('01920000-0000-7000-8000-000000004272', '01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042c4', null),
  ('01920000-0000-7000-8000-000000004273', '01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042c6', now()),
  ('01920000-0000-7000-8000-000000004274', '01920000-0000-7000-8000-0000000042e2', '01920000-0000-7000-8000-0000000042c2', null),
  ('01920000-0000-7000-8000-000000004275', '01920000-0000-7000-8000-0000000042e3', '01920000-0000-7000-8000-0000000042c1', null),
  ('01920000-0000-7000-8000-000000004276', '01920000-0000-7000-8000-0000000042e5', '01920000-0000-7000-8000-0000000042c1', null);

-- Centro: radial de 500 m. Cordón: un rectángulo por esquinas (la quinta esquina está dada de baja).
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color, deleted_at) values
  ('01920000-0000-7000-8000-0000000042d1', 'Centro',       '01920000-0000-7000-8000-000000004271', 'RADIAL', -34.905, -56.18, 500, '#112233', null),
  ('01920000-0000-7000-8000-0000000042d3', 'Borrada',      '01920000-0000-7000-8000-000000004271', 'RADIAL', -34.905, -56.18, 300, '#445566', now()),
  ('01920000-0000-7000-8000-0000000042d4', 'Salto centro', '01920000-0000-7000-8000-000000004274', 'RADIAL', -31.40,  -57.96, 300, null,      null),
  ('01920000-0000-7000-8000-0000000042d5', 'Ajena',        '01920000-0000-7000-8000-000000004275', 'RADIAL', -34.90,  -56.18, 300, null,      null),
  ('01920000-0000-7000-8000-0000000042d6', 'Zona futura',  '01920000-0000-7000-8000-000000004276', 'RADIAL', -34.93,  -56.20, 200, '#778899', null);
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000042d2', 'Cordón', '01920000-0000-7000-8000-000000004271', 'ESQUINAS', '#AABBCC',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);
insert into public.zona_vertice (zona_id, orden, lat, lon, calle_a, calle_b, deleted_at) values
  ('01920000-0000-7000-8000-0000000042d2', 1, -34.92, -56.19, 'Grecia', 'Vigo', null),
  ('01920000-0000-7000-8000-0000000042d2', 2, -34.92, -56.17, 'Vigo', 'Rivera', null),
  ('01920000-0000-7000-8000-0000000042d2', 3, -34.91, -56.17, 'Rivera', 'Mayo', null),
  ('01920000-0000-7000-8000-0000000042d2', 4, -34.91, -56.19, 'Mayo', 'Grecia', null),
  ('01920000-0000-7000-8000-0000000042d2', 5, -34.915, -56.19, 'Borrada', 'Borrada', now());

insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b1', '01920000-0000-7000-8000-0000000042d1'),
  ('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b2', '01920000-0000-7000-8000-0000000042d1'),
  ('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b3', '01920000-0000-7000-8000-0000000042d1'),
  ('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b4', '01920000-0000-7000-8000-0000000042d1'),
  ('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b6', null),
  ('01920000-0000-7000-8000-0000000042e2', '01920000-0000-7000-8000-0000000042b5', '01920000-0000-7000-8000-0000000042d4');
update public.usuario set suspendido_en = now() where id = '01920000-0000-7000-8000-0000000042b3';
update public.usuario set deleted_at = now() where id = '01920000-0000-7000-8000-0000000042b4';

-- Ubicaciones de Montevideo: f1 y f2 (en el borde) caen en Cordón, f6 en Centro; f3 está dada de
-- baja; f4 queda afuera de las dos; f5 es de otra ciudad, en el mismo lugar que f1.
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-000000004291', 'CASA', -34.915, -56.18,  '01920000-0000-7000-8000-0000000042c1', null),
  ('01920000-0000-7000-8000-000000004292', 'CASA', -34.915, -56.17,  '01920000-0000-7000-8000-0000000042c1', null),
  ('01920000-0000-7000-8000-000000004293', 'CASA', -34.915, -56.185, '01920000-0000-7000-8000-0000000042c1', now()),
  ('01920000-0000-7000-8000-000000004294', 'CASA', -34.95,  -56.18,  '01920000-0000-7000-8000-0000000042c1', null),
  ('01920000-0000-7000-8000-000000004295', 'CASA', -34.915, -56.18,  '01920000-0000-7000-8000-0000000042c2', null),
  ('01920000-0000-7000-8000-000000004296', 'CASA', -34.905, -56.18,  '01920000-0000-7000-8000-0000000042c1', null);

-- ---------------------------------------------------------------------------
-- 1. Forma y privilegios
-- ---------------------------------------------------------------------------
select is((select pg_get_function_result('public.mi_perfil()'::regprocedure)),
          'TABLE(usuario_id uuid, nombre text, apellido text)', 'mi_perfil(): la forma de la respuesta');
select is((select pg_get_function_result('public.campanias_del_coordinador()'::regprocedure)),
          'TABLE(id uuid, nombre text, tipo text, fecha_inicio date, fecha_fin date)',
          'campanias_del_coordinador(): la forma de la respuesta');
select is((select pg_get_function_result('public.ciudades_de_campania(uuid)'::regprocedure)),
          'TABLE(campania_ciudad_id uuid, ciudad_id uuid, nombre text, departamento text, lat_centro double precision, lon_centro double precision, zoom_inicial smallint, cantidad_zonas integer)',
          'ciudades_de_campania(): la forma de la respuesta');
select is((select pg_get_function_result('public.ciudades_del_catalogo(uuid,text)'::regprocedure)),
          'TABLE(ciudad_id uuid, nombre text, departamento text)', 'ciudades_del_catalogo(): la forma de la respuesta');
select is((select pg_get_function_result('public.zonas_de_ciudad(uuid,uuid)'::regprocedure)),
          'TABLE(zona_id uuid, nombre text, tipo_forma text, color text, centro_lat double precision, centro_lon double precision, radio_m integer, poligono_geojson jsonb, esquinas jsonb, colportores jsonb, ubicaciones_registradas integer)',
          'zonas_de_ciudad(): la forma de la respuesta (sin email, sin clientes, sin personas)');

select is((select pg_get_function_result('public.colportores_de_campania(uuid)'::regprocedure)),
          'TABLE(usuario_id uuid, nombre text, apellido text, zona_id uuid, zona_nombre text, suspendido boolean, email text, estado text)',
          'colportores_de_campania(): la forma de la respuesta no cambió al alinear el criterio');
select is((select pg_get_function_result('public.zonas_asignables(uuid)'::regprocedure)),
          'TABLE(id uuid, nombre text, de_esta_campania boolean)',
          'zonas_asignables(): la forma de la respuesta no cambió al alinear el criterio');

select is((select p.prosecdef from pg_proc p where p.oid = 'public.mi_perfil()'::regprocedure), false,
          'mi_perfil() es SECURITY INVOKER: la RLS de usuario le basta (solo la fila propia)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.campanias_del_coordinador()'::regprocedure), false,
          'campanias_del_coordinador() es SECURITY INVOKER: filtra por coordinador_id = auth.uid() sobre campania');
select is((select p.provolatile from pg_proc p where p.oid = 'public.campanias_del_coordinador()'::regprocedure), 's',
          'campanias_del_coordinador() es STABLE (solo lee)');
select is((select array_agg(p.prosecdef order by p.proname) from pg_proc p
            where p.oid in ('public.ciudades_de_campania(uuid)'::regprocedure,
                            'public.ciudades_del_catalogo(uuid,text)'::regprocedure,
                            'public.zonas_de_ciudad(uuid,uuid)'::regprocedure)),
          array[true, true, true], 'las tres lecturas de campaña son SECURITY DEFINER');
select is((select count(*)::int from pg_proc p
            where p.oid in ('public.mi_perfil()'::regprocedure,
                            'public.campanias_del_coordinador()'::regprocedure,
                            'public.ciudades_de_campania(uuid)'::regprocedure,
                            'public.ciudades_del_catalogo(uuid,text)'::regprocedure,
                            'public.zonas_de_ciudad(uuid,uuid)'::regprocedure,
                            'public.exigir_lectura_de_campania(uuid)'::regprocedure)
              and p.proconfig = array['search_path=""']), 6, 'las seis fijan search_path vacío');

select ok(has_function_privilege('authenticated', f, 'execute'), 'authenticated ejecuta ' || f)
  from unnest(array['public.mi_perfil()', 'public.campanias_del_coordinador()', 'public.ciudades_de_campania(uuid)',
                    'public.ciudades_del_catalogo(uuid,text)', 'public.zonas_de_ciudad(uuid,uuid)']) f;
select ok(not has_function_privilege('anon', f, 'execute'), 'anon NO ejecuta ' || f)
  from unnest(array['public.mi_perfil()', 'public.campanias_del_coordinador()', 'public.ciudades_de_campania(uuid)',
                    'public.ciudades_del_catalogo(uuid,text)', 'public.zonas_de_ciudad(uuid,uuid)',
                    'public.exigir_lectura_de_campania(uuid)']) f;
select ok(not has_function_privilege('service_role', f, 'execute'), 'service_role NO ejecuta ' || f)
  from unnest(array['public.mi_perfil()', 'public.campanias_del_coordinador()', 'public.ciudades_de_campania(uuid)',
                    'public.ciudades_del_catalogo(uuid,text)', 'public.zonas_de_ciudad(uuid,uuid)']) f;
select is((select count(*)::int
             from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid in ('public.mi_perfil()'::regprocedure,
                            'public.campanias_del_coordinador()'::regprocedure,
                            'public.ciudades_de_campania(uuid)'::regprocedure,
                            'public.ciudades_del_catalogo(uuid,text)'::regprocedure,
                            'public.zonas_de_ciudad(uuid,uuid)'::regprocedure,
                            'public.exigir_lectura_de_campania(uuid)'::regprocedure)),
          0, 'ninguna tiene EXECUTE para PUBLIC');
select ok(not has_function_privilege('authenticated', 'public.exigir_lectura_de_campania(uuid)', 'execute'),
          'authenticated NO ejecuta la comprobación interna');

-- ---------------------------------------------------------------------------
-- 2. Acceso: el permiso es lo primero
-- ---------------------------------------------------------------------------
-- Sin JWT: ni el servidor (sin sesión) ni authenticated sin claims ni anon.
select pg_temp.actuar_como_servidor();
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'sin JWT, mi_perfil() falla');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'sin JWT, campanias_del_coordinador() falla');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'sin JWT, ciudades_de_campania() falla');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', null) $$, '42501', null, 'sin JWT, ciudades_del_catalogo() falla');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null, 'sin JWT, zonas_de_ciudad() falla');

select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'authenticated sin sesión: mi_perfil() falla');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'authenticated sin sesión: campanias_del_coordinador() falla');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'authenticated sin sesión: ciudades_de_campania() falla');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', null) $$, '42501', null, 'authenticated sin sesión: ciudades_del_catalogo() falla');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null, 'authenticated sin sesión: zonas_de_ciudad() falla');

select pg_temp.actuar_como_servidor();
select set_config('role', 'anon', true);
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'anon no llama a mi_perfil()');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'anon no llama a campanias_del_coordinador()');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'anon no llama a ciudades_de_campania()');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', null) $$, '42501', null, 'anon no llama a ciudades_del_catalogo()');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null, 'anon no llama a zonas_de_ciudad()');
select pg_temp.actuar_como_servidor();

-- Un colportor, un usuario sin rol, un coordinador con el rol vencido y uno dado de baja: nadie
-- de ellos llama, ni siquiera sobre una campaña que existe.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a0');
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'un colportor no llama a mi_perfil()');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'un colportor no llama a campanias_del_coordinador()');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'un colportor no lista las ciudades');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', null) $$, '42501', null, 'un colportor no lista el catálogo');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null, 'un colportor no lista las zonas');
-- El permiso va antes que la existencia: un colportor no averigua qué campañas existen.
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042ff') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501, no CZ001');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042ff', '01920000-0000-7000-8000-000000004271') $$,
  '42501', null, 'un colportor con una campaña inexistente: 42501 también en zonas_de_ciudad()');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a3');
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'un usuario sin ningún rol no llama a mi_perfil()');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'un usuario sin ningún rol no llama a campanias_del_coordinador()');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'un usuario sin ningún rol no lista las ciudades');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', null) $$, '42501', null, 'un usuario sin ningún rol no lista el catálogo');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null, 'un usuario sin ningún rol no lista las zonas');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a4');
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'con el rol de coordinador vencido, mi_perfil() falla');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'con el rol vencido, campanias_del_coordinador() falla');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'con el rol vencido no lista las ciudades');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null, 'con el rol vencido no lista las zonas');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a5');
select throws_ok($$ select * from public.mi_perfil() $$, '42501', null, 'un coordinador dado de baja no llama a mi_perfil()');
select throws_ok($$ select * from public.campanias_del_coordinador() $$, '42501', null, 'un coordinador dado de baja no llama a campanias_del_coordinador()');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null, 'un coordinador dado de baja no lista las ciudades');

-- El coordinador de OTRA campaña no ve la mía, ni con la ciudad de la suya.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$, '42501', null,
  'el coordinador de otra campaña no lista las ciudades');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', null) $$, '42501', null,
  'el coordinador de otra campaña no lista el catálogo');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$, '42501', null,
  'el coordinador de otra campaña no lista las zonas');
-- Aunque la campaña sea la suya, la ciudad no: CZ012 y no las zonas de Verano.
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e2', '01920000-0000-7000-8000-000000004271') $$, 'CZ012', null,
  'con su campaña y la ciudad de otra: CZ012, no las zonas ajenas');
-- Y el permiso va antes que la vigencia: no averigua si la campaña ajena terminó (ni si empezó).
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e3') $$, '42501', null,
  'una campaña ajena y terminada: 42501, no CZ011');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e5') $$, '42501', null,
  'una campaña ajena que todavía no empezó: 42501');
-- Lo que sí se sabe: si la campaña no existe (o se dio de baja), CZ001 aun siendo de otro (mismo orden
-- de comprobación que las escrituras del mapa; con ids UUIDv7 no se puede sondear qué campañas hay).
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042ff') $$, 'CZ001', null,
  'un coordinador con una campaña inexistente: CZ001');
select pg_temp.actuar_como_servidor();

-- ---------------------------------------------------------------------------
-- 3. Errores de campaña (mismos códigos que asignar_zona)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042ff') $$,
  'CZ001', null, 'campaña inexistente: CZ001 (ciudades)');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042ff', null) $$,
  'CZ001', null, 'campaña inexistente: CZ001 (catálogo)');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042ff', '01920000-0000-7000-8000-000000004271') $$,
  'CZ001', null, 'campaña inexistente: CZ001 (zonas)');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e4') $$,
  'CZ001', null, 'campaña dada de baja: CZ001 (ciudades)');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e4', null) $$,
  'CZ001', null, 'campaña dada de baja: CZ001 (catálogo)');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e4', '01920000-0000-7000-8000-000000004271') $$,
  'CZ001', null, 'campaña dada de baja: CZ001 (zonas)');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e3') $$,
  'CZ011', null, 'campaña terminada: CZ011 (ciudades)');
select throws_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e3', null) $$,
  'CZ011', null, 'campaña terminada: CZ011 (catálogo)');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e3', '01920000-0000-7000-8000-000000004275') $$,
  'CZ011', null, 'campaña terminada: CZ011 (zonas)');

-- Los mensajes guían (la fuente de datos del panel muestra el `message` de la base).
select throws_like($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e3') $$,
  'La campaña ya terminó%', 'el mensaje de CZ011 dice qué pasó');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$,
  '42501', 'Solo el coordinador de la campaña puede ver sus ciudades y zonas. Entrá con la cuenta del coordinador de esta campaña.',
  'el mensaje del 42501 habla de ver, no de cambiar el mapa');

-- Una campaña que todavía no empezó SÍ se lee (la vista 24 prepara el mapa antes del inicio, y
-- guardar_zona() ya lo permite): e5 Futura, de a1, empieza en 10 días.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select results_eq(
  $$ select ciudad_id, cantidad_zonas from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  $$ values ('01920000-0000-7000-8000-0000000042c1'::uuid, 1) $$,
  'campaña por empezar: se lee (ciudades)');
select isnt_empty(
  $$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e5', 'salto') $$,
  'campaña por empezar: se lee (catálogo)');
select results_eq(
  $$ select zona_id, nombre from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e5', '01920000-0000-7000-8000-000000004276') $$,
  $$ values ('01920000-0000-7000-8000-0000000042d6'::uuid, 'Zona futura'::text) $$,
  'campaña por empezar: se lee (zonas)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042ad');
select results_eq(
  $$ select ciudad_id from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  $$ values ('01920000-0000-7000-8000-0000000042c1'::uuid) $$,
  'un ADMIN también lee una campaña por empezar');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e3') $$,
  'CZ011', null, 'y a un ADMIN la terminada también le da CZ011');

-- colportores_de_campania() y zonas_asignables() leen con el mismo criterio (0033): la vista 24 de
-- una campaña por empezar carga zonas, zonas asignables y colportores sin error. Inscribir exige que
-- la campaña haya empezado, así que la lista de colportores de una por empezar es vacía, no un error.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select is_empty(
  $$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  'campaña por empezar: colportores_de_campania() sin filas, no CZ002');
select results_eq(
  $$ select id, nombre, de_esta_campania from public.zonas_asignables('01920000-0000-7000-8000-0000000042e5') $$,
  $$ values ('01920000-0000-7000-8000-0000000042d6'::uuid, 'Zona futura'::text, true) $$,
  'campaña por empezar: zonas_asignables() lista sus zonas, no CZ002');
select results_eq(
  $$ select usuario_id from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e1') order by apellido, nombre, usuario_id $$,
  $$ values ('01920000-0000-7000-8000-0000000042b2'::uuid), ('01920000-0000-7000-8000-0000000042b3'::uuid),
            ('01920000-0000-7000-8000-0000000042b6'::uuid), ('01920000-0000-7000-8000-0000000042b1'::uuid) $$,
  'campaña en curso: colportores_de_campania() sigue listando sus inscriptos vivos (Alfa, Beta, Sinzona, Zeta)');
select results_eq(
  $$ select id from public.zonas_asignables('01920000-0000-7000-8000-0000000042e1') order by nombre $$,
  $$ values ('01920000-0000-7000-8000-0000000042d1'::uuid), ('01920000-0000-7000-8000-0000000042d2'::uuid) $$,
  'campaña en curso: zonas_asignables() sigue listando las vivas (Centro, Cordón)');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e3') $$,
  'CZ011', null, 'campaña terminada: CZ011 (colportores)');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e3') $$,
  'CZ011', null, 'campaña terminada: CZ011 (zonas asignables)');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042ff') $$,
  'CZ001', null, 'campaña inexistente: CZ001 (colportores)');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042ff') $$,
  'CZ001', null, 'campaña inexistente: CZ001 (zonas asignables)');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e4') $$,
  'CZ001', null, 'campaña dada de baja: CZ001 (colportores)');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e4') $$,
  'CZ001', null, 'campaña dada de baja: CZ001 (zonas asignables)');
-- Asignar zona sigue pidiendo una campaña que empezó: la regla de escritura no cambia.
select throws_ok(
  $$ select public.asignar_zona('01920000-0000-7000-8000-0000000042e5', '01920000-0000-7000-8000-0000000042b1', '01920000-0000-7000-8000-0000000042d6') $$,
  'CZ002', null, 'asignar_zona() en una campaña por empezar sigue en CZ002');
-- El permiso va primero: el coordinador de otra campaña, el colportor y quien no tiene sesión no
-- leen una por empezar.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  '42501', null, 'el coordinador de otra campaña no lista los colportores de una por empezar');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e5') $$,
  '42501', null, 'el coordinador de otra campaña no lista las zonas asignables de una por empezar');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a0');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  '42501', null, 'un colportor no lista los colportores de una por empezar');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e5') $$,
  '42501', null, 'un colportor no lista las zonas asignables de una por empezar');
select pg_temp.actuar_sin_jwt();
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  '42501', null, 'sin sesión: 42501 (colportores)');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e5') $$,
  '42501', null, 'sin sesión: 42501 (zonas asignables)');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042ad');
select isnt_empty($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e5') $$,
  'un ADMIN lista las zonas asignables de una por empezar');
select lives_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e5') $$,
  'y sus colportores');

-- El borde del día (en Montevideo): la que termina hoy todavía se lee, la que terminó ayer no; la que
-- empieza hoy y la que empieza mañana, sí. Son de a6 y no tienen ciudades.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a6');
select lives_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e7') $$,
  'la campaña que termina hoy todavía se lee');
select throws_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e8') $$,
  'CZ011', null, 'la que terminó ayer: CZ011 (ciudades)');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e8', '01920000-0000-7000-8000-000000004271') $$,
  'CZ011', null, 'la que terminó ayer: CZ011 (zonas), antes de mirar la ciudad');
select lives_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e9') $$,
  'la que empieza hoy se lee');
select lives_ok($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042ea') $$,
  'la que empieza mañana se lee');
select lives_ok($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042eb', 'sal') $$,
  'una sin fin se lee');
select lives_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e7') $$,
  'la que termina hoy: colportores_de_campania() todavía se lee');
select lives_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e7') $$,
  'la que termina hoy: zonas_asignables() todavía se lee');
select throws_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042e8') $$,
  'CZ011', null, 'la que terminó ayer: CZ011 (colportores)');
select throws_ok($$ select * from public.zonas_asignables('01920000-0000-7000-8000-0000000042e8') $$,
  'CZ011', null, 'la que terminó ayer: CZ011 (zonas asignables)');
select lives_ok($$ select * from public.colportores_de_campania('01920000-0000-7000-8000-0000000042ea') $$,
  'la que empieza mañana: colportores_de_campania() se lee');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');

-- zonas_de_ciudad: la ciudad tiene que ser una ciudad VIVA de ESTA campaña.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004274') $$, 'CZ012', null,
  'una ciudad de otra campaña: CZ012');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042ff') $$, 'CZ012', null,
  'una ciudad que no existe: CZ012 (igual que la ajena)');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004273') $$, 'CZ012', null,
  'una ciudad dada de baja en la campaña: CZ012');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042d1') $$, 'CZ012', null,
  'el id de una zona en lugar del de una ciudad: CZ012');
select throws_ok($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', null) $$, 'CZ012', null,
  'sin ciudad: CZ012');

-- ---------------------------------------------------------------------------
-- 4. mi_perfil
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select results_eq($$ select usuario_id, nombre, apellido from public.mi_perfil() $$,
  $$ values ('01920000-0000-7000-8000-0000000042a1'::uuid, 'Coor'::text, 'Uno'::text) $$,
  'el coordinador ve su nombre y su apellido');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select results_eq($$ select usuario_id, nombre, apellido from public.mi_perfil() $$,
  $$ values ('01920000-0000-7000-8000-0000000042a2'::uuid, 'Coor'::text, 'Dos'::text) $$,
  'otro coordinador ve el suyo, no el de a1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042ad');
select results_eq($$ select usuario_id, nombre, apellido from public.mi_perfil() $$,
  $$ values ('01920000-0000-7000-8000-0000000042ad'::uuid, 'Admi'::text, 'Nistra'::text) $$,
  'un ADMIN ve el suyo');

-- ---------------------------------------------------------------------------
-- 4b. campanias_del_coordinador
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select results_eq($$ select id from public.campanias_del_coordinador() $$,
  $$ values ('01920000-0000-7000-8000-0000000042e1'::uuid), ('01920000-0000-7000-8000-0000000042e5'::uuid) $$,
  'a1: las suyas que no terminaron, la en curso (Verano) y después la por empezar (Futura); no la terminada '
  '(Vieja), ni la dada de baja (Borrada), ni las de otros coordinadores');
select results_eq(
  $$ select nombre, tipo, fecha_inicio = current_date - 10, fecha_fin = current_date + 30
       from public.campanias_del_coordinador() where id = '01920000-0000-7000-8000-0000000042e1' $$,
  $$ values ('Verano'::text, 'VERANO'::text, true, true) $$,
  'las columnas: nombre, tipo, fecha_inicio y fecha_fin');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select results_eq($$ select id from public.campanias_del_coordinador() $$,
  $$ values ('01920000-0000-7000-8000-0000000042e2'::uuid), ('01920000-0000-7000-8000-0000000042e6'::uuid) $$,
  'a2: las suyas (Salto y Vacía, que empezaron el mismo día: por id), ninguna de a1');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042ad');
select is_empty($$ select * from public.campanias_del_coordinador() $$,
  'un ADMIN ve solo las que coordina él (ninguna), no todas las campañas');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a6');
select results_eq(
  $$ select nombre, tipo, fecha_inicio - public.hoy_montevideo(), fecha_fin - public.hoy_montevideo()
       from public.campanias_del_coordinador() $$,
  $$ values ('Empieza hoy'::text, 'INVIERNO'::text, 0, 20),
            ('Sin fin',    'PERMANENTE', -5, null),
            ('Termina hoy', 'VERANO',   -20, 0),
            ('Empieza mañana', 'PERMANENTE', 1, null),
            ('En 30 días', 'VERANO', 30, 60) $$,
  'a6: primero las en curso, la que empezó más tarde primero (la que empieza hoy cuenta como en curso; la '
  'que termina hoy sigue; sin fin vale); después las por empezar, la más próxima primero; no la que terminó ayer');

-- El día es el de Montevideo y no el de la sesión: con la zona horaria de la sesión muy adelantada o muy
-- atrasada (al menos una de las dos cae en otro día que Montevideo a cualquier hora), el resultado no cambia.
select ok((now() at time zone 'Pacific/Kiritimati')::date <> public.hoy_montevideo()
          or (now() at time zone 'Etc/GMT+12')::date <> public.hoy_montevideo(),
          'control: alguna de las dos zonas de prueba cae en otro día que Montevideo');
select set_config('TimeZone', 'Pacific/Kiritimati', true);   -- UTC+14
select results_eq($$ select nombre from public.campanias_del_coordinador() $$,
  $$ values ('Empieza hoy'::text), ('Sin fin'), ('Termina hoy'), ('Empieza mañana'), ('En 30 días') $$,
  'con la sesión en UTC+14: las mismas, en el mismo orden');
select set_config('TimeZone', 'Etc/GMT+12', true);           -- UTC-12
select results_eq($$ select nombre from public.campanias_del_coordinador() $$,
  $$ values ('Empieza hoy'::text), ('Sin fin'), ('Termina hoy'), ('Empieza mañana'), ('En 30 días') $$,
  'con la sesión en UTC-12: las mismas, en el mismo orden');
select set_config('TimeZone', 'UTC', true);

-- ---------------------------------------------------------------------------
-- 5. ciudades_de_campania
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select results_eq(
  $$ select ciudad_id, nombre, lat_centro, lon_centro, zoom_inicial, cantidad_zonas
       from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') $$,
  $$ values ('01920000-0000-7000-8000-0000000042c4'::uuid, 'Baja q54'::text, -33.00::float8, -56.00::float8, 11::smallint, 0),
            ('01920000-0000-7000-8000-0000000042c1'::uuid, 'Montevideo q54'::text, -34.90::float8, -56.16::float8, 13::smallint, 2) $$,
  'Verano: sus ciudades vivas por nombre (la dada de baja del catálogo sigue en su campaña, sin zonas; '
  'la fila de campaña dada de baja no aparece), con centro, zoom y las zonas VIVAS (la borrada no cuenta)');
select results_eq(
  $$ select campania_ciudad_id from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') order by nombre $$,
  $$ values ('01920000-0000-7000-8000-000000004272'::uuid), ('01920000-0000-7000-8000-000000004271'::uuid) $$,
  'campania_ciudad_id es el id de la pestaña (lo que recibe guardar_zona), ciudad_id el del catálogo');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select results_eq(
  $$ select ciudad_id, cantidad_zonas from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e2') $$,
  $$ values ('01920000-0000-7000-8000-0000000042c2'::uuid, 1) $$,
  'el coordinador de Salto ve la suya, no la de Verano');
select is_empty($$ select * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e6') $$,
  'una campaña sin ciudades: lista vacía, no error');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042ad');
select results_eq(
  $$ select ciudad_id from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e2') $$,
  $$ values ('01920000-0000-7000-8000-0000000042c2'::uuid) $$,
  'un ADMIN lista las de cualquier campaña vigente');

-- ---------------------------------------------------------------------------
-- 6. ciudades_del_catalogo
-- ---------------------------------------------------------------------------
-- (Se filtra por los ids de este archivo: la base puede traer otras ciudades.)
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
select set_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ values ('Salto q54'), ('Paysandú q54'), ('Ñandú q54'), ('Villa Salto q54'), ('Azeta q54'), ('Zeta q54') $$,
  'sin texto: todas las vivas que no están (vivas) en Verano. No la que ya está (Montevideo), ni las '
  'dadas de baja del catálogo (Baja, Borrada); sí Villa Salto, cuya fila en Verano está dada de baja');
select set_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', '   ')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  'un texto en blanco es como no escribir nada');
select results_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'SAL')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ values ('Salto q54'::text), ('Villa Salto q54') $$,
  'el texto se busca sin mayúsculas, dentro del nombre; primero la que empieza con él');
select results_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'zeta')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ values ('Zeta q54'::text), ('Azeta q54') $$,
  'la que empieza con lo escrito va antes que otra que lo contiene y es alfabéticamente anterior');
select results_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'paysandu')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ values ('Paysandú q54'::text) $$, 'sin tildes: «paysandu» encuentra Paysandú');
select results_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'ÑANDU')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ values ('Ñandú q54'::text) $$, 'ÑANDU encuentra Ñandú (mayúsculas, eñe y tilde)');
select results_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', '  salto Q54 ')
      where ciudad_id::text like '01920000-0000-7000-8000-0000000042%' $$,
  $$ values ('Salto q54'::text), ('Villa Salto q54') $$, 'los espacios de los costados no cuentan');
select is_empty($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'montevideo q54') $$,
  'la ciudad que ya está en la campaña no se ofrece, la busquen por su nombre o no');
select is_empty($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'borrada q54') $$,
  'la dada de baja del catálogo no se ofrece');
select is_empty($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', '%') $$,
  'un «%» no es un comodín: no encuentra nada');
select is_empty($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', '_') $$,
  'un «_» tampoco');
select is_empty($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'no existe ninguna asi') $$,
  'sin coincidencias: lista vacía, no error');

-- Agregar una ciudad la saca del buscador y la suma a la lista de la campaña.
select lives_ok($$ select public.agregar_ciudad_a_campania('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042c3') $$, 'a1 agrega Paysandú a Verano');
select is_empty($$ select * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'paysandu') $$,
  'Paysandú ya no se ofrece');
select results_eq(
  $$ select ciudad_id, cantidad_zonas from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1') where ciudad_id = '01920000-0000-7000-8000-0000000042c3' $$,
  $$ values ('01920000-0000-7000-8000-0000000042c3'::uuid, 0) $$, 'y aparece en las ciudades de la campaña, sin zonas');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select results_eq(
  $$ select nombre from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e2', 'paysandu') $$,
  $$ values ('Paysandú q54'::text) $$,
  'lo que se agrega a Verano no cambia el catálogo de Salto: se excluye por campaña');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');

-- ---------------------------------------------------------------------------
-- 7. zonas_de_ciudad
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select zona_id, nombre, tipo_forma, color, centro_lat, centro_lon, radio_m,
            esquinas, colportores, ubicaciones_registradas
       from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') where tipo_forma = 'RADIAL' $$,
  $$ values ('01920000-0000-7000-8000-0000000042d1'::uuid, 'Centro'::text, 'RADIAL'::text, '#112233'::text, -34.905::float8, -56.18::float8, 500,
             null::jsonb,
             jsonb_build_array(
               jsonb_build_object('usuario_id', '01920000-0000-7000-8000-0000000042b2', 'nombre', 'Ana', 'apellido', 'Alfa', 'suspendido', false),
               jsonb_build_object('usuario_id', '01920000-0000-7000-8000-0000000042b3', 'nombre', 'Beto', 'apellido', 'Beta', 'suspendido', true),
               jsonb_build_object('usuario_id', '01920000-0000-7000-8000-0000000042b1', 'nombre', 'Uno', 'apellido', 'Zeta', 'suspendido', false)),
             1) $$,
  'Centro (radial): centro y radio, sin esquinas; sus colportores por apellido con la cuenta suspendida '
  'marcada y SIN el dado de baja ni el email; 1 ubicación adentro');
select results_eq(
  $$ select zona_id, nombre, tipo_forma, color, centro_lat, centro_lon, radio_m,
            esquinas, colportores, ubicaciones_registradas
       from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') where tipo_forma = 'ESQUINAS' $$,
  $$ values ('01920000-0000-7000-8000-0000000042d2'::uuid, 'Cordón'::text, 'ESQUINAS'::text, '#AABBCC'::text, null::float8, null::float8, null::int,
             jsonb_build_array(
               jsonb_build_object('orden', 1, 'lat', -34.92, 'lon', -56.19, 'calle_a', 'Grecia', 'calle_b', 'Vigo'),
               jsonb_build_object('orden', 2, 'lat', -34.92, 'lon', -56.17, 'calle_a', 'Vigo', 'calle_b', 'Rivera'),
               jsonb_build_object('orden', 3, 'lat', -34.91, 'lon', -56.17, 'calle_a', 'Rivera', 'calle_b', 'Mayo'),
               jsonb_build_object('orden', 4, 'lat', -34.91, 'lon', -56.19, 'calle_a', 'Mayo', 'calle_b', 'Grecia')),
             '[]'::jsonb,
             2) $$,
  'Cordón (esquinas): sin centro ni radio; las 4 esquinas vivas por orden con los nombres de las calles '
  '(la quinta, dada de baja, no); sin colportores; 2 ubicaciones (la del borde cuenta; la dada de baja y '
  'la de otra ciudad no)');
select results_eq(
  $$ select nombre from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$,
  $$ values ('Centro'::text), ('Cordón') $$,
  'solo las zonas vivas, por nombre (la Borrada no está)');
select results_eq(
  $$ select poligono_geojson ->> 'type', jsonb_array_length(poligono_geojson -> 'coordinates' -> 0)
       from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') order by nombre $$,
  $$ values ('Polygon'::text, 129), ('Polygon', 5) $$,
  'cada zona trae su polígono GeoJSON: el círculo de 128 lados cerrado y el rectángulo');
select is((select poligono_geojson from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') where zona_id = '01920000-0000-7000-8000-0000000042d2'),
          '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb,
          'el polígono de Cordón es el guardado');
select is_empty($$ select * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004272') $$,
  'una ciudad de la campaña sin zonas: lista vacía, no error');

-- Lo que hacen las otras RPC se ve en la lectura siguiente.
select lives_ok($$ select public.asignar_zona('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b6', '01920000-0000-7000-8000-0000000042d2') $$, 'a1 asigna a Fer a Cordón');
select results_eq(
  $$ select colportores from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') where zona_id = '01920000-0000-7000-8000-0000000042d2' $$,
  $$ values (jsonb_build_array(jsonb_build_object('usuario_id', '01920000-0000-7000-8000-0000000042b6', 'nombre', 'Fer', 'apellido', 'Sinzona', 'suspendido', false))) $$,
  'Cordón ahora lista a Fer');
select lives_ok($$ select public.quitar_zona('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-0000000042b6') $$, 'a1 le quita la zona');
select results_eq(
  $$ select colportores from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') where zona_id = '01920000-0000-7000-8000-0000000042d2' $$,
  $$ values ('[]'::jsonb) $$, 'y Cordón vuelve a no tener colportores');
select lives_ok($$ select public.baja_zona('01920000-0000-7000-8000-0000000042d2', false) $$, 'a1 da de baja Cordón');
select results_eq(
  $$ select zona_id from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$,
  $$ values ('01920000-0000-7000-8000-0000000042d1'::uuid) $$, 'y la zona dada de baja ya no se lista');

-- Cada coordinador, lo suyo; el ADMIN, cualquiera.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a2');
select results_eq(
  $$ select zona_id, nombre, color, ubicaciones_registradas,
            colportores -> 0 ->> 'nombre'
       from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e2', '01920000-0000-7000-8000-000000004274') $$,
  $$ values ('01920000-0000-7000-8000-0000000042d4'::uuid, 'Salto centro'::text, null::text, 0, 'Eva'::text) $$,
  'el coordinador de Salto ve la zona de Salto (sin color: null, no un color por defecto) con su colportora; '
  'las ubicaciones de Montevideo no cuentan');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042ad');
select results_eq(
  $$ select zona_id from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271') $$,
  $$ values ('01920000-0000-7000-8000-0000000042d1'::uuid) $$, 'un ADMIN lista las zonas de la campaña de otro');

-- ---------------------------------------------------------------------------
-- 8. Las lecturas no escriben
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
-- (Lo único que cambió son las escrituras de las RPC de arriba: asignar, quitar y baja. Se compara
-- contra una lectura nueva, no contra la foto del principio.)
create temp table despues_de_leer on commit drop as
select (select coalesce(sum(sync_version), 0) from public.zona) as zona,
       (select coalesce(sum(sync_version), 0) from public.campania_ciudad) as ciudad,
       (select coalesce(sum(sync_version), 0) from public.campania_colportor) as inscripcion,
       (select coalesce(sum(sync_version), 0) from public.usuario) as usuario,
       (select count(*) from public.zona_vertice) as vertices;
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000042a1');
do $$ begin
  perform * from public.mi_perfil();
  perform * from public.campanias_del_coordinador();
  perform * from public.ciudades_de_campania('01920000-0000-7000-8000-0000000042e1');
  perform * from public.ciudades_del_catalogo('01920000-0000-7000-8000-0000000042e1', 'sal');
  perform * from public.zonas_de_ciudad('01920000-0000-7000-8000-0000000042e1', '01920000-0000-7000-8000-000000004271');
end $$;
select pg_temp.actuar_como_servidor();
select results_eq(
  $$ select coalesce(sum(sync_version), 0) from public.zona $$,
  $$ select zona from despues_de_leer $$, 'leer no sube la versión de ninguna zona');
select results_eq(
  $$ select (select coalesce(sum(sync_version), 0) from public.campania_ciudad),
            (select coalesce(sum(sync_version), 0) from public.campania_colportor),
            (select coalesce(sum(sync_version), 0) from public.usuario),
            (select count(*) from public.zona_vertice) $$,
  $$ select ciudad, inscripcion, usuario, vertices from despues_de_leer $$,
  'ni la de ciudades, inscripciones y usuarios, ni cambia las esquinas');

select * from finish();
rollback;
