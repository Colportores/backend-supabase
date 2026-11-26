-- pgTAP · los compañeros de campaña bajan al teléfono por el sync
-- (migración 0208, backend-supabase#313, «Nombres camp.»; decisión de Cristian del 24/11)
--
-- Juan quiere pedirle libros a Ana: el teléfono tiene que leer el nombre y la ciudad de los colportores de su campaña, y nada más
-- de ellos. Casos:
--   1. forma: solo usuario_id, nombre, apellido y ciudad_id (nunca correo, teléfono, cédula ni stock); en el sync, solo bajada;
--   2. la tabla se mantiene sola: una inscripción nueva, un cambio de zona, una baja y la vuelta, y un cambio de nombre;
--   3. quién lee: la persona inscripta en la campaña (y su propia fila); no un colportor de otra campaña, ni el ADMIN, ni el
--      coordinador, ni alguien de una campaña que ya terminó o con la inscripción dada de baja; la cuenta suspendida no ve nada;
--   4. nadie la escribe con su JWT.
-- Va en una transacción (el pull se prueba en 0208_..._pull_test.sql).
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000208' || p)::uuid;
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;
-- Lo que lee quien actúa: «usuario:nombre apellido/ciudad[/baja],…» ordenado por usuario.
create or replace function pg_temp.lista(p_campania text) returns text language sql as $$
  select coalesce(string_agg(right(c.usuario_id::text, 2) || ':' || c.nombre || ' ' || c.apellido || '/' || coalesce(ci.nombre, '-')
                             || case when c.deleted_at is null then '' else '/baja' end, ',' order by c.usuario_id), '-')
    from public.campania_companiero c
    left join public.ciudad ci on ci.id = c.ciudad_id
   where c.campania_id = pg_temp.u(p_campania)
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Campaña e1 «Primavera» (en curso) con ciudades c1 Montevideo (zona d1) y c2 Salto (zona d2); campaña e2 (otra), y e3 terminada.
--   b1 Juan (zona d1), b2 Ana (zona d1), b3 Bruno (sin zona), b4 Valentina (zona d2), b5 (solo en e2), cr coordinador de e1,
--   ad ADMIN, b6 (en e3, terminada), b7 (suspendido, en e1).
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'comp208-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['b1','b2','b3','b4','b5','b6','b7','c9','a9']) s;
update public.usuario u set nombre = x.n, apellido = x.a
  from (values ('b1','Juan','Perez'), ('b2','Ana','Pereira'), ('b3','Bruno','Techera'), ('b4','Valentina','Silva'),
               ('b5','Otra','Campania'), ('b6','Vieja','Terminada'), ('b7','Susana','Suspendida')) x(s, n, a)
 where u.id = pg_temp.u(x.s);
update public.usuario set suspendido_en = now() where id = pg_temp.u('b7');
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1','COLPORTOR'), ('b2','COLPORTOR'), ('b3','COLPORTOR'), ('b4','COLPORTOR'), ('b5','COLPORTOR'), ('b6','COLPORTOR'),
               ('b7','COLPORTOR'), ('c9','COORDINADOR'), ('a9','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais comp', 'ZC');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  (pg_temp.u('c1'), 'Montevideo q208', 'Departamento de prueba', pg_temp.u('c0'), -34.91, -56.18, 13),
  (pg_temp.u('c2'), 'Salto q208',      'Departamento de prueba', pg_temp.u('c0'), -31.39, -57.96, 13);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'Primavera', 'VERANO', public.hoy_montevideo() - 20, public.hoy_montevideo() + 30, pg_temp.u('c9')),
  (pg_temp.u('e2'), 'Otra',      'VERANO', public.hoy_montevideo() - 20, public.hoy_montevideo() + 30, pg_temp.u('c9')),
  (pg_temp.u('e3'), 'Terminada', 'VERANO', public.hoy_montevideo() - 60, public.hoy_montevideo() - 30, pg_temp.u('c9'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('71'), pg_temp.u('e1'), pg_temp.u('c1')), (pg_temp.u('72'), pg_temp.u('e1'), pg_temp.u('c2'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  (pg_temp.u('d1'), 'Centro', pg_temp.u('71'), 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb),
  (pg_temp.u('d2'), 'Costanera', pg_temp.u('72'), 'ESQUINAS', '#445566',
   '{"type":"Polygon","coordinates":[[[-57.97,-31.40],[-57.95,-31.40],[-57.95,-31.38],[-57.97,-31.38],[-57.97,-31.40]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id, created_at) values
  (pg_temp.u('e1'), pg_temp.u('b1'), pg_temp.u('d1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b2'), pg_temp.u('d1'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b3'), null,            now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b4'), pg_temp.u('d2'), now() - interval '10 days'),
  (pg_temp.u('e1'), pg_temp.u('b7'), null,            now() - interval '10 days'),
  (pg_temp.u('e2'), pg_temp.u('b5'), null,            now() - interval '10 days'),
  (pg_temp.u('e3'), pg_temp.u('b6'), null,            now() - interval '50 days');

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select has_table('public', 'campania_companiero', 'la tabla existe');
select is((select array_agg(column_name::text order by column_name) from information_schema.columns
            where table_schema = 'public' and table_name = 'campania_companiero'
              and column_name not in ('id','created_at','updated_at','created_by','deleted_at','sync_version','xmin_w')),
          array['apellido','campania_id','ciudad_id','nombre','usuario_id'],
          'solo lleva campaña, usuario, nombre, apellido y ciudad (ni correo, ni teléfono, ni cédula, ni stock)');
select ok(exists (select 1 from sync.entidad where nombre = 'campania_companiero' and not permite_push and sigue_campanias),
          'está en el sync como solo bajada y sigue las campañas que ve la persona');
select ok(not has_function_privilege('anon', 'public.puedo_ver_a_los_companieros(uuid)', 'execute'), 'anon no ejecuta el predicado');

-- ---------------------------------------------------------------------------
-- 2. Se mantiene sola
-- ---------------------------------------------------------------------------
select is(pg_temp.lista('e1'),
          'b1:Juan Perez/Montevideo q208,b2:Ana Pereira/Montevideo q208,b3:Bruno Techera/-,b4:Valentina Silva/Salto q208,b7:Susana Suspendida/-',
          'las inscripciones de la campaña, con el nombre y la ciudad de su zona (sin zona, sin ciudad)');
select is(pg_temp.lista('e2'), 'b5:Otra Campania/-', 'la otra campaña, la suya');
select is(pg_temp.lista('e3'), 'b6:Vieja Terminada/-', 'y la terminada');
select is((select count(*)::int from public.campania_companiero), (select count(*)::int from public.campania_colportor),
          'una fila por inscripción');

-- Una inscripción nueva.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values (pg_temp.u('b8'), '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'comp208-b8@example.com', 'x', now(), now(), now());
update public.usuario set nombre = 'Nuevo', apellido = 'Ingreso' where id = pg_temp.u('b8');
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values (pg_temp.u('e1'), pg_temp.u('b8'), pg_temp.u('d2'));
select is((select c.nombre || ' ' || c.apellido || '/' || ci.nombre from public.campania_companiero c join public.ciudad ci on ci.id = c.ciudad_id
            where c.campania_id = pg_temp.u('e1') and c.usuario_id = pg_temp.u('b8')),
          'Nuevo Ingreso/Salto q208', 'una inscripción nueva suma la fila con la ciudad de su zona');

-- Un cambio de zona.
update public.campania_colportor set zona_id = pg_temp.u('d1') where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8');
select is((select ci.nombre from public.campania_companiero c join public.ciudad ci on ci.id = c.ciudad_id
            where c.campania_id = pg_temp.u('e1') and c.usuario_id = pg_temp.u('b8')),
          'Montevideo q208', 'al cambiarle la zona, la ciudad la sigue');
update public.campania_colportor set zona_id = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8');
select is((select ciudad_id from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8')),
          null, 'sin zona, sin ciudad');

-- Un cambio de nombre.
update public.usuario set apellido = 'Ingresado' where id = pg_temp.u('b8');
select is((select apellido from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8')),
          'Ingresado', 'si la persona cambia de nombre, la copia la sigue');

-- La baja y la vuelta.
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8');
select ok((select deleted_at is not null from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8')),
          'la baja de la inscripción deja la fila con deleted_at (baja al teléfono como baja)');
update public.campania_colportor set deleted_at = null where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8');
select ok((select deleted_at is null from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8')),
          'la vuelta la reactiva (una sola fila por persona y campaña)');
select is((select count(*)::int from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b8')), 1,
          'sigue siendo una sola fila');

-- Sin cambios no se toca la fila (cada escritura es una fila nueva en el delta).
create temp table v0 as select sync_version as v from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
update public.campania_colportor set zona_id = zona_id where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1');
update public.usuario set nombre = nombre where id = pg_temp.u('b1');
select is((select sync_version from public.campania_companiero where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b1')),
          (select v from v0), 'un update que no cambia nada no toca la fila');

-- ---------------------------------------------------------------------------
-- 3. Quién lee
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.lista('e1'),
          'b1:Juan Perez/Montevideo q208,b2:Ana Pereira/Montevideo q208,b3:Bruno Techera/-,b4:Valentina Silva/Salto q208,b7:Susana Suspendida/-,b8:Nuevo Ingresado/-',
          'Juan lee a sus compañeros de campaña (y su propia fila), con nombre y ciudad');
select is(pg_temp.lista('e2'), '-', 'pero no a los de otra campaña');
select is((select count(*)::int from public.campania_companiero), 6, 'y en total, solo los de la suya');

select pg_temp.actuar_como(pg_temp.u('b5'));
select is(pg_temp.lista('e1'), '-', 'un colportor de otra campaña no lee a los de e1');
select is(pg_temp.lista('e2'), 'b5:Otra Campania/-', 'solo la suya, su propia fila');

select pg_temp.actuar_como(pg_temp.u('b6'));
select is((select count(*)::int from public.campania_companiero), 1, 'quien está en una campaña terminada solo lee su fila: no baja a los compañeros');

select pg_temp.actuar_como(pg_temp.u('b7'));
select is(pg_temp.lista('e1'), 'b7:Susana Suspendida/-', 'la cuenta suspendida solo lee su fila');

select pg_temp.como_servidor();
update public.campania_colportor set deleted_at = now() where campania_id = pg_temp.u('e1') and usuario_id = pg_temp.u('b3');
select pg_temp.actuar_como(pg_temp.u('b3'));
select is(pg_temp.lista('e1'), 'b3:Bruno Techera/-/baja', 'quien se dio de baja de la campaña ya no lee a los demás: solo su fila (con su baja)');

select pg_temp.actuar_como(pg_temp.u('c9'));
select is((select count(*)::int from public.campania_companiero), 0, 'el coordinador no la lee por esta tabla (tiene las lecturas del panel)');
select pg_temp.actuar_como(pg_temp.u('a9'));
select is((select count(*)::int from public.campania_companiero), 0, 'ni el ADMIN: el pull de quien usa la app no baja a todos los colportores de todas las campañas');

-- ---------------------------------------------------------------------------
-- 4. Nadie la escribe con su JWT
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de(format($$insert into public.campania_companiero (campania_id, usuario_id) values (%L, %L)$$, pg_temp.u('e1'), pg_temp.u('b1'))),
          '42501', 'insertar: sin privilegio (42501)');
select is(pg_temp.error_de(format($$update public.campania_companiero set nombre = 'x' where usuario_id = %L$$, pg_temp.u('b2'))),
          '42501', 'actualizar: sin privilegio (42501)');
select is(pg_temp.error_de($$delete from public.campania_companiero$$), '42501', 'borrar: sin privilegio (42501)');

select * from finish();
rollback;
