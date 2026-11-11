-- pgTAP · migración 0171 (backend-supabase#248, HU-CAT-005): precios_de_la_ciudad() suma, al final,
-- `categoria` y `codigo_editor`.
--   1. La forma: las dos columnas al final, una sola función, mismos privilegios (solo authenticated).
--   2. Contenido: la categoría y el código del editor de cada producto (con y sin código); null en una
--      colección; las columnas anteriores no cambian de valor.
--   3. El permiso sigue igual: el coordinador de otra campaña recibe 42501.
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
create or replace function pg_temp.u(p text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000171' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- a1 coordina e1 (ciudad f1); a2 coordina e2.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'cat171-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais cat171', 'ZQ');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Montevideo cat171', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 cat171', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 cat171', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a2'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));

-- Un producto de cada categoría (la 0149 la fija con el trigger; se la pasa explícita), con y sin código.
insert into public.producto (id, nombre, tipo, categoria, es_bonificable, codigo_editor) values
  (pg_temp.u('11'), 'Bonificable t171',  'LIBRO',    'BONIFICABLES', true,  'ED-0001'),
  (pg_temp.u('12'), 'Misionero t171',    'LIBRO',    'MISIONEROS',   false, 'ED-0002'),
  (pg_temp.u('13'), 'Espiritual t171',   'LIBRO',    'ESPIRITUALES', false, null),
  (pg_temp.u('14'), 'Revista t171',      'REVISTA',  'REVISTAS',     false, 'REV-7'),
  (pg_temp.u('15'), 'Material t171',     'MATERIAL', 'MATERIAL',     false, null);
insert into public.coleccion (id, nombre) values (pg_temp.u('d1'), 'Combo t171');
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde) values
  (pg_temp.u('21'), pg_temp.u('11'), null, 24000, pg_temp.h() - 100),
  (pg_temp.u('22'), null, pg_temp.u('d1'), 44000, pg_temp.h() - 100);
insert into public.precio_por_ciudad (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde) values
  (pg_temp.u('31'), pg_temp.u('11'), null, pg_temp.u('f1'), 25000, pg_temp.h() - 30);

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'precios_de_la_ciudad'),
          1, 'hay una sola precios_de_la_ciudad (la de la 0071 se reemplazó)');
select is(pg_get_function_result('public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'TABLE(tipo text, id uuid, nombre text, es_bonificable boolean, precio_general integer, precio_modificado integer, precio_vigente integer, origen text, valido_desde date, valido_hasta date, componentes_de_baja integer, libros_a_elegir integer, categoria text, codigo_editor text)',
          'las dos columnas nuevas van al final, después de libros_a_elegir');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          true, 'sigue siendo SECURITY DEFINER');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          's', 'sigue siendo STABLE');
select ok((select 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.precios_de_la_ciudad(uuid,date)', 'execute'), 'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.precios_de_la_ciudad(uuid,date)', 'execute'), 'anon no');
select ok(not has_function_privilege('service_role', 'public.precios_de_la_ciudad(uuid,date)', 'execute'), 'service_role tampoco');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure and a.grantee = 0), 0, 'ni PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. El contenido
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
create or replace function pg_temp.cc(p_nombre text) returns text language sql as $$
  select coalesce(
    (select coalesce(r.categoria, '~') || '|' || coalesce(r.codigo_editor, '~')
       from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = p_nombre),
    'SIN FILA');
$$;
select is(pg_temp.cc('Bonificable t171'), 'BONIFICABLES|ED-0001', 'BONIFICABLES con código');
select is(pg_temp.cc('Misionero t171'),   'MISIONEROS|ED-0002',   'MISIONEROS con código (la insignia «Misionero» sale de acá)');
select is(pg_temp.cc('Espiritual t171'),  'ESPIRITUALES|~',        'ESPIRITUALES sin código: codigo_editor null');
select is(pg_temp.cc('Revista t171'),     'REVISTAS|REV-7',        'REVISTAS con código');
select is(pg_temp.cc('Material t171'),    'MATERIAL|~',            'MATERIAL sin código');
select is(pg_temp.cc('Combo t171'),       '~|~',                   'una COLECCION trae las dos en null');
select is((select r.tipo from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Combo t171'),
          'COLECCION', 'y es una colección');

-- Lo anterior no cambia de valor.
select is((select concat_ws('|', r.precio_general, r.precio_modificado, r.precio_vigente, r.origen, r.es_bonificable)
             from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Bonificable t171'),
          '24000|25000|25000|MODIFICADO|t', 'general, modificado, vigente, origen y es_bonificable siguen igual');
select is((select concat_ws('|', r.precio_general, r.precio_vigente, r.origen, r.componentes_de_baja, r.libros_a_elegir)
             from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre = 'Combo t171'),
          '44000|44000|GENERAL|0|0', 'y los del combo (componentes_de_baja y libros_a_elegir) también');
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f1')) r where r.nombre like '%t171'),
          6, 'sigue una fila por producto y colección vivos');

-- ---------------------------------------------------------------------------
-- 3. El permiso no cambia
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000171f1') $$),
          '42501', 'el coordinador de otra campaña sigue recibiendo 42501');
select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
