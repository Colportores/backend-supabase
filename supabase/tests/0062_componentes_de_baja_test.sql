-- pgTAP · migración 0057 (backend-supabase#99, HU-CAT-009): precios_de_la_ciudad() suma componentes_de_baja,
-- cuántos componentes vivos de un combo son productos dados de baja («si un componente se da de baja, el combo
-- deja de ofrecerse hasta corregirlo y se avisa qué combos quedaron afectados»).
--   1. La forma: columna integer, última, no nula; la función sigue SECURITY DEFINER, STABLE, search_path
--      vacío y con EXECUTE solo para authenticated.
--   2. El conteo: combo sano (0), con uno y con dos componentes de baja, vínculo quitado del combo (no
--      cuenta), combo sin componentes (0), componente solo dado de baja y vuelto a dar de alta, producto (0).
--   3. El precio no se quita: el combo con un componente de baja sigue con su general, su modificado y el
--      que rige.
--   4. Lo demás no cambia: la ciudad, la fecha y el permiso (colportor y coordinador de otra campaña, 42501;
--      el coordinador de la campaña sí), un combo dado de baja no aparece y la lectura no modifica nada.
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
  select ('01920000-0000-7000-8000-0000000062' || p)::uuid;
$$;
create or replace function pg_temp.h() returns date language sql as $$
  select public.hoy_montevideo();
$$;
-- Los componentes de baja de una fila (por nombre), o -1 si la función no devuelve esa fila.
create or replace function pg_temp.cdb(p_cc text, p_nombre text) returns integer language sql as $$
  select coalesce((select r.componentes_de_baja from public.precios_de_la_ciudad(pg_temp.u(p_cc)) r
                    where r.nombre = p_nombre), -1);
$$;
create or replace function pg_temp.error_de(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate;
end $$;

-- --- fixtures (como postgres) --------------------------------------------------
-- ad es ADMIN; a1 coordina e1 (ciudad f1); a2 coordina e2; b1 es colportor inscripto en e1.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'baja62-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['ad','a1','a2','b1']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('ad','ADMIN'), ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('b1','COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais baja62', 'ZB');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  (pg_temp.u('c1'), 'Ciudad c1 baja62', 'Departamento de prueba', pg_temp.u('c0'), -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  (pg_temp.u('e1'), 'e1 baja62', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a1')),
  (pg_temp.u('e2'), 'e2 baja62', 'VERANO', pg_temp.h() - 10, pg_temp.h() + 30, pg_temp.u('a2'));
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('c1'));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  (pg_temp.u('e1'), pg_temp.u('b1'), null);

-- Productos p1..p4; los combos t0 (sano), t1 (un componente de baja), t2 (dos), t3 (el vínculo de baja se
-- quitó del combo), t4 (sin componentes) y t5 (dado de baja entero).
insert into public.producto (id, nombre, tipo) values
  (pg_temp.u('11'), 'Libro p1 baja62', 'LIBRO'),
  (pg_temp.u('12'), 'Revista p2 baja62', 'REVISTA'),
  (pg_temp.u('13'), 'Revista p3 baja62', 'REVISTA'),
  (pg_temp.u('14'), 'Libro p4 baja62', 'LIBRO');
insert into public.coleccion (id, nombre) values
  (pg_temp.u('d0'), 'Combo t0 sano baja62'),
  (pg_temp.u('d1'), 'Combo t1 un componente de baja baja62'),
  (pg_temp.u('d2'), 'Combo t2 dos componentes de baja baja62'),
  (pg_temp.u('d3'), 'Combo t3 vinculo quitado baja62'),
  (pg_temp.u('d4'), 'Combo t4 sin componentes baja62'),
  (pg_temp.u('d5'), 'Combo t5 dado de baja baja62');
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  (pg_temp.u('a1'), pg_temp.u('11'), pg_temp.u('d0'), 1),
  (pg_temp.u('a2'), pg_temp.u('12'), pg_temp.u('d0'), 2),
  (pg_temp.u('a3'), pg_temp.u('11'), pg_temp.u('d1'), 1),
  (pg_temp.u('a4'), pg_temp.u('13'), pg_temp.u('d1'), 2),
  (pg_temp.u('a5'), pg_temp.u('13'), pg_temp.u('d2'), 1),
  (pg_temp.u('a6'), pg_temp.u('14'), pg_temp.u('d2'), 1),
  (pg_temp.u('a7'), pg_temp.u('11'), pg_temp.u('d3'), 1),
  (pg_temp.u('a8'), pg_temp.u('13'), pg_temp.u('d3'), 1),
  (pg_temp.u('a9'), pg_temp.u('13'), pg_temp.u('d5'), 1);
-- Los precios de los combos: general para todos y una excepción en f1 para t1.
insert into public.precio_general (id, producto_id, coleccion_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('21'), null, pg_temp.u('d0'), 100000, pg_temp.h() - 100, null),
  (pg_temp.u('22'), null, pg_temp.u('d1'), 120000, pg_temp.h() - 100, null),
  (pg_temp.u('23'), null, pg_temp.u('d2'), 130000, pg_temp.h() - 100, null);
insert into public.precio_por_ciudad (id, producto_id, coleccion_id, campania_ciudad_id, precio_venta, valido_desde, valido_hasta) values
  (pg_temp.u('31'), null, pg_temp.u('d1'), pg_temp.u('f1'), 110000, pg_temp.h() - 100, null);
-- Los productos p3 y p4 se dan de baja (t1 lleva p3; t2 lleva p3 y p4; t3 lleva p3 pero su vínculo se quitó
-- del combo; t5 lleva p3 pero el combo está dado de baja). El vínculo a8 se quita ANTES de la baja de p3.
update public.producto_coleccion set deleted_at = now() where id = pg_temp.u('a8');
update public.producto set deleted_at = now() where id in (pg_temp.u('13'), pg_temp.u('14'));
update public.coleccion set deleted_at = now() where id = pg_temp.u('d5');

-- ---------------------------------------------------------------------------
-- 1. La forma
-- ---------------------------------------------------------------------------
select is((select array_to_string(proargnames[3:], ',') from pg_proc
            where oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'tipo,id,nombre,es_bonificable,precio_general,precio_modificado,precio_vigente,origen,valido_desde,valido_hasta,componentes_de_baja,libros_a_elegir',
          'las columnas de la función: las de la 0037, componentes_de_baja (0057) y libros_a_elegir (0071) al final');
select is((select (proallargtypes::oid[])[array_length(proallargtypes, 1) - 1]::regtype::text from pg_proc
            where oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'integer', 'componentes_de_baja es integer');
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and p.proname = 'precios_de_la_ciudad'), 1,
          'hay una sola precios_de_la_ciudad (la de la 0037 se reemplazó, no quedó otra)');
select is((select p.prosecdef from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          true, 'sigue siendo SECURITY DEFINER');
select is((select p.provolatile::text from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          's', 'sigue siendo STABLE');
select ok((select 'search_path=""' = any (p.proconfig) from pg_proc p where p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure),
          'y con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.precios_de_la_ciudad(uuid,date)', 'execute'),
          'authenticated la ejecuta');
select ok(not has_function_privilege('anon', 'public.precios_de_la_ciudad(uuid,date)', 'execute'), 'anon no');
select ok(not has_function_privilege('service_role', 'public.precios_de_la_ciudad(uuid,date)', 'execute'), 'service_role tampoco');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where a.grantee = 0 and a.privilege_type = 'EXECUTE'
              and p.oid = 'public.precios_de_la_ciudad(uuid,date)'::regprocedure), 0, 'ni PUBLIC');

-- ---------------------------------------------------------------------------
-- 2. El conteo (como ADMIN)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.cdb('f1', 'Combo t0 sano baja62'), 0, 'un combo con todos sus componentes vivos: 0');
select is(pg_temp.cdb('f1', 'Combo t1 un componente de baja baja62'), 1, 'con un componente dado de baja: 1');
select is(pg_temp.cdb('f1', 'Combo t2 dos componentes de baja baja62'), 2, 'con dos componentes dados de baja: 2');
select is(pg_temp.cdb('f1', 'Combo t3 vinculo quitado baja62'), 0,
          'si el componente de baja se quitó del combo (el vínculo está dado de baja), ya no cuenta: 0');
select is(pg_temp.cdb('f1', 'Combo t4 sin componentes baja62'), 0, 'un combo sin componentes: 0 (que no se ofrezca lo decide el teléfono)');
select is(pg_temp.cdb('f1', 'Combo t5 dado de baja baja62'), -1, 'un combo dado de baja no aparece');
select is(pg_temp.cdb('f1', 'Libro p1 baja62'), 0, 'un producto vivo: 0');
select is(pg_temp.cdb('f1', 'Revista p3 baja62'), -1, 'un producto dado de baja no aparece (como antes)');
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f1')) r
            where r.componentes_de_baja is null), 0, 'la columna nunca viene null');
select is((select count(*)::int from public.precios_de_la_ciudad(pg_temp.u('f1')) r
            where r.tipo = 'PRODUCTO' and r.componentes_de_baja <> 0), 0, 'ningún producto trae componentes de baja');
-- La misma cuenta para otra fecha: no depende de la fecha pedida.
select is((select r.componentes_de_baja from public.precios_de_la_ciudad(pg_temp.u('f1'), pg_temp.h() + 5) r
            where r.nombre = 'Combo t2 dos componentes de baja baja62'), 2, 'con otra fecha, la misma cuenta');

-- ---------------------------------------------------------------------------
-- 3. El precio no se quita
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select precio_general, precio_modificado, precio_vigente, origen, componentes_de_baja
       from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000062f1')
      where nombre = 'Combo t1 un componente de baja baja62' $$,
  $$ values (120000, 110000, 110000, 'MODIFICADO'::text, 1) $$,
  'el combo con un componente de baja sigue con su general, su excepción y el que rige');
select results_eq(
  $$ select precio_vigente, origen, componentes_de_baja
       from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000062f1')
      where nombre = 'Combo t2 dos componentes de baja baja62' $$,
  $$ values (130000, 'GENERAL'::text, 2) $$,
  'y el que tiene dos, con su general');

-- Dar de baja un componente suma uno; volver a darlo de alta lo quita.
select pg_temp.actuar_como_servidor();
update public.producto set deleted_at = now() where id = pg_temp.u('12');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.cdb('f1', 'Combo t0 sano baja62'), 1, 'se da de baja un componente del combo sano: pasa a 1');
select pg_temp.actuar_como_servidor();
update public.producto set deleted_at = null where id = pg_temp.u('12');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.cdb('f1', 'Combo t0 sano baja62'), 0, 'se da de alta de nuevo: vuelve a 0');

-- ---------------------------------------------------------------------------
-- 4. Lo demás no cambia
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como(pg_temp.u('a1'));
select is(pg_temp.cdb('f1', 'Combo t2 dos componentes de baja baja62'), 2, 'el coordinador de la campaña lo lee');
select pg_temp.actuar_como(pg_temp.u('a2'));
select is(pg_temp.error_de($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000062f1') $$),
          '42501', 'el coordinador de otra campaña recibe 42501');
select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.error_de($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-0000000062f1') $$),
          '42501', 'el colportor también (lee por el sync)');
select pg_temp.actuar_como(pg_temp.u('ad'));
select is(pg_temp.error_de($$ select * from public.precios_de_la_ciudad('01920000-0000-7000-8000-000000006200') $$),
          'CZ012', 'una ciudad de campaña que no existe sigue dando CZ012');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.producto where deleted_at is not null and id::text like '01920000-0000-7000-8000-0000000062%'),
          2, 'la lectura no tocó ningún producto (siguen los 2 de baja)');
select is((select count(*)::int from public.producto_coleccion where id::text like '01920000-0000-7000-8000-0000000062%'), 9,
          'ni ningún vínculo');

select * from finish();
rollback;
