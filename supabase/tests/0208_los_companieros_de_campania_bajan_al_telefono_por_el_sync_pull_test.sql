-- pgTAP · migración 0208 (backend-supabase#313, «Nombres camp.»), el pull: los compañeros de campaña bajan al teléfono.
--   1. Cada colportor baja a los de SU campaña (con la suya), con usuario_id, nombre, apellido y ciudad; los de otra campaña no.
--   2. El coordinador y el ADMIN no la bajan por acá.
--   3. La fila no trae nada más de la persona: ni correo, ni teléfono, ni cédula, ni stock, ni la maquinaria del delta.
--   4. El delta: uno que se suma baja solo (aunque a quien lo mira no le cambie la lista de campañas), un cambio de zona baja con la
--      ciudad nueva, un cambio de nombre baja, y quien se da de baja baja como baja.
--   5. Quien se suma a una campaña baja a los compañeros de esa campaña (cambió la huella de sus campañas).
-- Como 0201, NO va en una transacción (el delta solo sirve lo commiteado). Limpia al empezar y al final.

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
create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000208' || p_sufijo)::uuid;
$$;
create or replace function pg_temp.limpiar() returns void language plpgsql as $$
declare v uuid[] := array[pg_temp.u('a1'), pg_temp.u('a2'), pg_temp.u('a3'), pg_temp.u('a4'), pg_temp.u('a5'), pg_temp.u('c9'), pg_temp.u('a9')];
begin
  delete from public.campania_colportor where usuario_id = any (v);
  delete from public.zona where id in (pg_temp.u('d1'), pg_temp.u('d2'));
  delete from public.campania_ciudad where id in (pg_temp.u('71'), pg_temp.u('72'));
  delete from public.campania where id in (pg_temp.u('e1'), pg_temp.u('e2'));
  delete from public.ciudad where id in (pg_temp.u('c1'), pg_temp.u('c2'));
  delete from public.pais where id = pg_temp.u('c0');
  delete from public.usuario_rol where usuario_id = any (v);
  delete from auth.users where id = any (v) or id = pg_temp.u('a5');
end $$;
create or replace function pg_temp.pull_de(p text, p_marca jsonb default '{}'::jsonb) returns jsonb
language plpgsql as $$
declare d jsonb;
begin
  perform pg_temp.actuar_como(pg_temp.u(p));
  d := sync.pull(array['campania_companiero'], p_marca, 1000);
  perform pg_temp.como_servidor();
  return d;
end $$;
-- Las filas que bajaron: «usuario:nombre apellido/ciudad[/baja],…» ('-' si ninguna).
create or replace function pg_temp.filas(p_delta jsonb) returns text language sql as $$
  select coalesce(string_agg(right(e ->> 'usuario_id', 2) || ':' || (e ->> 'nombre') || ' ' || (e ->> 'apellido') || '/'
                             || coalesce((select c.nombre from public.ciudad c where c.id = (e ->> 'ciudad_id')::uuid), '-')
                             || case when e ->> 'deleted_at' is null then '' else '/baja' end, ',' order by e ->> 'usuario_id'), '-')
    from jsonb_array_elements(coalesce(p_delta -> 'rows' -> 'campania_companiero', '[]'::jsonb)) e
$$;

-- e1 «Primavera» con a1 Juan, a2 Ana (zona de Montevideo) y a3 Bruno (sin zona); e2 con a4 (otra campaña); c9 coordinador de e1; a9 ADMIN.
select pg_temp.limpiar();
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'comp208p-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','a3','a4','c9','a9']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('a1','Juan','Perez'), ('a2','Ana','Pereira'), ('a3','Bruno','Techera'), ('a4','Otra','Campania')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COLPORTOR'), ('a2','COLPORTOR'), ('a3','COLPORTOR'), ('a4','COLPORTOR'), ('c9','COORDINADOR'), ('a9','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais comp p', 'ZP');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Montevideo q208p', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Salto q208p',      'Departamento de prueba', pg_temp.u('c0'), -31.39, -57.96, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Primavera p', 'VERANO', public.hoy_montevideo() - 20, public.hoy_montevideo() + 30, pg_temp.u('c9')),
  (pg_temp.u('e2'), 'Otra p',      'VERANO', public.hoy_montevideo() - 20, public.hoy_montevideo() + 30, pg_temp.u('c9'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')), (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro p', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costanera p', pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-57.97,-31.40],[-57.95,-31.40],[-57.95,-31.38],[-57.97,-31.38],[-57.97,-31.40]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('a1'), pg_temp.u('d1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('a2'), pg_temp.u('d1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('a3'), null,            now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('a4'), null,            now() - interval '10 days');

-- 1. Cada colportor baja a los de su campaña
create temp table p1 as select pg_temp.pull_de('a1') as d;
select is(pg_temp.filas((select d from p1)), 'a1:Juan Perez/Montevideo q208p,a2:Ana Pereira/Montevideo q208p,a3:Bruno Techera/-',
          'Juan baja a los de su campaña, con nombre, apellido y ciudad de su zona (y la suya), y no a la de la otra campaña');
create temp table p4 as select pg_temp.pull_de('a4') as d;
select is(pg_temp.filas((select d from p4)), 'a4:Otra Campania/-', 'el de la otra campaña baja solo la suya');

-- 2. El coordinador y el ADMIN no
select is(pg_temp.filas(pg_temp.pull_de('c9')), '-', 'el coordinador no la baja por acá');
select is(pg_temp.filas(pg_temp.pull_de('a9')), '-', 'el ADMIN tampoco: el pull de quien usa la app no trae a todos los colportores');

-- 3. La fila no trae nada más
select is((select array_agg(k order by k) from (select distinct jsonb_object_keys(e) k
             from jsonb_array_elements((select d -> 'rows' -> 'campania_companiero' from p1)) e) s),
          array['apellido', 'campania_id', 'ciudad_id', 'created_at', 'created_by', 'deleted_at', 'id', 'nombre', 'sync_version', 'updated_at', 'usuario_id'],
          'la fila trae solo ids, nombre, apellido, ciudad y las columnas comunes: ni correo, ni teléfono, ni cédula, ni stock, ni xmin_w');

-- 4. El delta
create temp table m1 as select d -> 'watermark' as w from p1;
select is(pg_temp.filas(pg_temp.pull_de('a1', (select w from m1))), '-', 'sin cambios, el delta no trae nada');

-- Se suma otro colportor a e1 (a Juan no le cambia su lista de campañas): baja solo el nuevo.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('a5'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'comp208p-a5@example.com', 'x', now(), now(), now());
update public.usuario set nombre = 'Nuevo', apellido = 'Ingreso' where id = pg_temp.u('a5');
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values (pg_temp.u('e1'), pg_temp.u('a5'), pg_temp.u('d2'));
select is(pg_temp.filas(pg_temp.pull_de('a1', (select w from m1))), 'a5:Nuevo Ingreso/Salto q208p', 'uno que se suma baja solo, con la ciudad de su zona');

-- Cambio de zona, de nombre y una baja.
create temp table m2 as select pg_temp.pull_de('a1', (select w from m1)) -> 'watermark' as w;
update public.campania_colportor set zona_id = pg_temp.u('d1') where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('a5');
update public.usuario set apellido = 'Ingresado' where id = pg_temp.u('a2');
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('a3');
select is(pg_temp.filas(pg_temp.pull_de('a1', (select w from m2))),
          'a2:Ana Ingresado/Montevideo q208p,a3:Bruno Techera/-/baja,a5:Nuevo Ingreso/Montevideo q208p',
          'el cambio de nombre, la baja (como baja) y el cambio de zona bajan como cambios de sus filas');

-- 5. Quien se suma a una campaña baja a los compañeros de esa campaña
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values (pg_temp.u('e2'), pg_temp.u('a1'), null);
select is(pg_temp.filas(pg_temp.pull_de('a1', (select w from m2))),
          'a1:Juan Perez/Montevideo q208p,a1:Juan Perez/-,a2:Ana Ingresado/Montevideo q208p,a3:Bruno Techera/-/baja,a4:Otra Campania/-,a5:Nuevo Ingreso/Montevideo q208p',
          'al sumarse a e2 cambia la huella de sus campañas y la entidad baja completa: los de e1 y los de e2');

select pg_temp.limpiar();
select * from finish();
