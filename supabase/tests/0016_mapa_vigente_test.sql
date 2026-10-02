-- pgTAP · migración 0013 (backend-supabase#39, S56): el colportor ve el mapa de sus campañas
-- en curso o por empezar (decisión del 30/09), no el de las terminadas, y las casas con la misma
-- regla (decisión del 02/10); el coordinador, el de las
-- que coordina (terminadas incluidas); y ya no
-- hay regla de superposición. Lo que baja en el delta (necesita filas commiteadas) lo prueba
-- 0011_zonas_mapa_sync; las zonas superpuestas por los RPC, 0010.
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

-- Lo que el usuario actual ve del mapa de estas campañas: las zonas, las ciudades de campaña y
-- las esquinas, por nombre de zona.
create or replace function pg_temp.zonas() returns text[] language sql as $$
  select coalesce(array_agg(z.nombre order by z.nombre), array[]::text[])
    from public.zona z where z.nombre like 'M16 %';
$$;
create or replace function pg_temp.ciudades_de_campania() returns uuid[] language sql as $$
  select coalesce(array_agg(cc.id order by cc.id), array[]::uuid[])
    from public.campania_ciudad cc where cc.id::text like '01920000-0000-7000-8000-0000000016f%';
$$;
create or replace function pg_temp.esquinas() returns bigint language sql as $$
  select count(*) from public.zona_vertice v where v.id::text like '01920000-0000-7000-8000-00000000169%';
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Vigente (e1, coordina a1), Terminada (e2, coordina a1), Futura (e3, coordina a2). Una
-- ciudad por campaña y una zona por ciudad; la de Vigente con 3 esquinas.
-- b1: Vigente y Terminada. b2: solo Terminada. b3: solo Futura. b4: Vigente, con su
-- inscripción dada de baja.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000016' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mapa16-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','a2','ad','b1','b2','b3','b4']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select ('01920000-0000-7000-8000-0000000016' || x.s)::uuid, r.id
  from (values ('a1','COORDINADOR'), ('a2','COORDINADOR'), ('ad','ADMIN')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000016c0', 'Pais mapa16', 'ZV');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000016c1', 'Ciudad mapa16', '01920000-0000-7000-8000-0000000016c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000016e1', 'Vigente',   'VERANO', current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000016a1'),
  ('01920000-0000-7000-8000-0000000016e2', 'Terminada', 'VERANO', current_date - 90, current_date - 30, '01920000-0000-7000-8000-0000000016a1'),
  ('01920000-0000-7000-8000-0000000016e3', 'Futura',    'VERANO', current_date + 30, current_date + 90, '01920000-0000-7000-8000-0000000016a2');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000016f1', '01920000-0000-7000-8000-0000000016e1', '01920000-0000-7000-8000-0000000016c1'),
  ('01920000-0000-7000-8000-0000000016f2', '01920000-0000-7000-8000-0000000016e2', '01920000-0000-7000-8000-0000000016c1'),
  ('01920000-0000-7000-8000-0000000016f3', '01920000-0000-7000-8000-0000000016e3', '01920000-0000-7000-8000-0000000016c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000016d2', 'M16 Terminada', '01920000-0000-7000-8000-0000000016f2', 'RADIAL', -34.90, -56.16, 300),
  ('01920000-0000-7000-8000-0000000016d3', 'M16 Futura',    '01920000-0000-7000-8000-0000000016f3', 'RADIAL', -34.90, -56.16, 300);
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000016d1', 'M16 Vigente', '01920000-0000-7000-8000-0000000016f1', 'ESQUINAS',
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.91]]]}');
insert into public.zona_vertice (id, zona_id, orden, lat, lon) values
  ('01920000-0000-7000-8000-000000001691', '01920000-0000-7000-8000-0000000016d1', 1, -34.91, -56.17),
  ('01920000-0000-7000-8000-000000001692', '01920000-0000-7000-8000-0000000016d1', 2, -34.91, -56.16),
  ('01920000-0000-7000-8000-000000001693', '01920000-0000-7000-8000-0000000016d1', 3, -34.90, -56.16);
insert into public.campania_colportor (campania_id, usuario_id, deleted_at)
select ('01920000-0000-7000-8000-0000000016' || x.e)::uuid, ('01920000-0000-7000-8000-0000000016' || x.b)::uuid,
       case when x.baja then now() end
  from (values ('e1','b1',false), ('e2','b1',false), ('e2','b2',false), ('e3','b3',false), ('e1','b4',true)) x(e, b, baja);

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select hasnt_function('public', f, 'se fue ' || f)
  from unnest(array['zona_superposicion', 'zona_superposiciones', 'lanzar_superposicion',
                    'tg_campania_colportor_republicar_mapa']) f;
select hasnt_trigger('public', 'campania_colportor', 'campania_colportor_republicar_mapa',
                     'inscribir ya no republica el mapa: lo reemplaza la huella de las campañas en el pull');
select results_eq(
  $$ select nombre from sync.entidad where sigue_campanias order by nombre $$,
  $$ values ('campania_ciudad'), ('zona'), ('zona_vertice') $$,
  'el mapa (y nada más) baja según las campañas que ve');
select ok(has_function_privilege('authenticated', 'public.mis_campanias_del_mapa()', 'execute'),
          'authenticated ejecuta mis_campanias_del_mapa (la usa la huella, que corre como él)');
select ok(has_function_privilege('authenticated', 'sync.huella_del_mapa()', 'execute'),
          'authenticated ejecuta sync.huella_del_mapa (la llama el pull)');
select ok(not has_function_privilege('anon', 'public.mis_campanias_del_mapa()', 'execute'), 'anon no');

-- ---------------------------------------------------------------------------
-- 2. El colportor: el mapa de sus campañas en curso o por empezar, no el de las terminadas
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b1');
select results_eq($$ select * from public.mis_campanias_del_mapa() $$,
                  $$ values ('01920000-0000-7000-8000-0000000016e1'::uuid) $$,
                  'b1 (Vigente y Terminada): solo Vigente');
select is(pg_temp.zonas(), array['M16 Vigente'], 'b1 ve la zona de la campaña vigente, no la de la terminada');
select is(pg_temp.ciudades_de_campania(), array['01920000-0000-7000-8000-0000000016f1']::uuid[],
          'ni la ciudad de la terminada');
select is(pg_temp.esquinas(), 3::bigint, 'y ve las esquinas de la zona vigente');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b2');
select is(pg_temp.zonas(), array[]::text[], 'b2 (solo Terminada) no ve ninguna zona');
select is(pg_temp.ciudades_de_campania(), array[]::uuid[], 'ni ciudades de campaña');
select is(pg_temp.esquinas(), 0::bigint, 'ni esquinas');

-- Decisión del 30/09: el mapa de una campaña por empezar se baja antes del primer día.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
select results_eq($$ select * from public.mis_campanias_del_mapa() $$,
                  $$ values ('01920000-0000-7000-8000-0000000016e3'::uuid) $$,
                  'b3 (solo Futura): la campaña por empezar');
select is(pg_temp.zonas(), array['M16 Futura'], 'b3 ve la zona de la campaña por empezar');
select is(pg_temp.ciudades_de_campania(), array['01920000-0000-7000-8000-0000000016f3']::uuid[],
          'y su ciudad');
create temp table huella_b3 on commit drop as select sync.huella_del_mapa() as h;
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = public.hoy_montevideo() where id = '01920000-0000-7000-8000-0000000016e3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
select is(sync.huella_del_mapa(), (select h from huella_b3),
          'cuando la campaña empieza, su huella no cambia: el mapa ya había bajado');
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = public.hoy_montevideo() - 1, fecha_fin = public.hoy_montevideo() - 1
 where id = '01920000-0000-7000-8000-0000000016e3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
select is(pg_temp.zonas(), array[]::text[], 'terminada, b3 deja de ver su mapa');
select isnt(sync.huella_del_mapa(), (select h from huella_b3), 'y cambia su huella');
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = current_date + 30, fecha_fin = current_date + 90
 where id = '01920000-0000-7000-8000-0000000016e3';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b4');
select is(pg_temp.zonas(), array[]::text[], 'b4 (inscripción dada de baja) no ve nada');

-- La huella cambia cuando termina una de sus campañas.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b1');
create temp table huella_b1 on commit drop as select sync.huella_del_mapa() as h;
select pg_temp.actuar_como_servidor();
update public.campania set fecha_fin = public.hoy_montevideo() - 1 where id = '01920000-0000-7000-8000-0000000016e1';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b1');
select is(pg_temp.zonas(), array[]::text[], 'terminada Vigente, b1 deja de ver su mapa');
select isnt(sync.huella_del_mapa(), (select h from huella_b1), 'y cambia su huella');
select pg_temp.actuar_como_servidor();
update public.campania set fecha_fin = current_date + 30 where id = '01920000-0000-7000-8000-0000000016e1';

-- ---------------------------------------------------------------------------
-- 3. El coordinador y el ADMIN
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016a1');
select is(pg_temp.zonas(), array['M16 Terminada', 'M16 Vigente'],
          'el coordinador ve el mapa de las campañas que coordina, también la terminada');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016a2');
select is(pg_temp.zonas(), array['M16 Futura'], 'y el de la futura que coordina');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016ad');
select is(pg_temp.zonas(), array['M16 Futura', 'M16 Terminada', 'M16 Vigente'], 'el ADMIN ve todo');
select isnt(sync.huella_del_mapa(),
            (select md5('mapa|' || coalesce(string_agg(c.id::text, ',' order by c.id), ''))
               from public.mis_campanias_del_mapa() c (id)),
            'la huella del ADMIN es otra que la de un usuario con sus mismas campañas');

-- ---------------------------------------------------------------------------
-- 4. Zonas superpuestas (S56): el trigger ya no las rechaza
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
select lives_ok(
  $$ insert into public.zona (nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m)
     values ('M16 Encima', '01920000-0000-7000-8000-0000000016f1', 'RADIAL', -34.905, -56.165, 500) $$,
  'una zona radial encima de otra de la misma ciudad de la campaña → se guarda');
select lives_ok(
  $$ update public.zona set radio_m = 800 where nombre = 'M16 Encima' $$,
  'agrandarla sobre la otra → también');
select is((select extensions.st_intersects(public.zona_geometria(a.poligono_geojson), public.zona_geometria(b.poligono_geojson))
             from public.zona a, public.zona b where a.nombre = 'M16 Encima' and b.nombre = 'M16 Vigente'),
          true, 'y las dos quedan superpuestas');
select throws_ok(
  $$ update public.zona set radio_m = 3001 where nombre = 'M16 Encima' $$,
  'CZ008', null, 'los parámetros de 0008 siguen (radio de hasta 3000 m)');

-- ---------------------------------------------------------------------------
-- 5. Las casas, con la misma regla que el mapa (decisión del 02/10): toda campaña con
--    inscripción viva que no terminó, con o sin zona. Escribir sigue pidiendo campaña vigente.
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
-- 81 cae en M16 Futura (radial de 300 m) y en M16 Vigente (borde); 82 es de la ciudad, lejos de
-- toda zona.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001681', 'CASA', 'Mapa16', '1', -34.90, -56.16, '01920000-0000-7000-8000-0000000016c1'),
  ('01920000-0000-7000-8000-000000001682', 'CASA', 'Mapa16', '2', -34.95, -56.30, '01920000-0000-7000-8000-0000000016c1');

create or replace function pg_temp.casas() returns text[] language sql as $$
  select coalesce(array_agg(u.numero order by u.numero), array[]::text[])
    from public.ubicacion u where u.id in ('01920000-0000-7000-8000-000000001681', '01920000-0000-7000-8000-000000001682');
$$;

select ok(not has_function_privilege('authenticated', 'public.mis_inscripciones_no_terminadas()', 'execute'),
          'mis_inscripciones_no_terminadas es interna (la llaman funciones SECURITY DEFINER)');

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
-- Es interna: se mira como su dueño, con el JWT de b3.
select set_config('role', 'postgres', true);
select results_eq($$ select * from public.mis_inscripciones_no_terminadas() $$,
                  $$ values ('01920000-0000-7000-8000-0000000016e3'::uuid, null::uuid) $$,
                  'b3 (solo Futura): su inscripción en la campaña por empezar, sin zona');
select set_config('role', 'authenticated', true);
select results_eq($$ select * from public.mis_ciudades_de_trabajo() $$,
                  $$ values ('01920000-0000-7000-8000-0000000016c1'::uuid) $$,
                  'sin zona, su ciudad de trabajo es la de la campaña por empezar');
select is(pg_temp.casas(), array['1', '2'], 'y ve sus casas antes del primer día (RLS de lectura)');
select is((select count(*) from public.mis_ciudades_de_campania()), 0::bigint,
          'pero escribir sigue pidiendo una campaña vigente: no tiene ciudades de escritura');
select throws_ok($$ update public.ubicacion set numero = '2b' where id = '01920000-0000-7000-8000-000000001682' $$,
                 '42501', null, 'corregir una casa ajena antes del primer día: 42501 visible (0021; antes 0 filas, en silencio)');
select is((select numero from public.ubicacion where id = '01920000-0000-7000-8000-000000001682'), '2',
          'y no toca nada');

select pg_temp.actuar_como_servidor();
update public.campania_colportor set zona_id = '01920000-0000-7000-8000-0000000016d3'
 where campania_id = '01920000-0000-7000-8000-0000000016e3' and usuario_id = '01920000-0000-7000-8000-0000000016b3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
select results_eq($$ select * from public.mis_zonas() $$, $$ values ('01920000-0000-7000-8000-0000000016d3'::uuid) $$,
                  'con zona en la campaña por empezar, mis_zonas() la incluye');
select is((select ciudades from sync.area_del_pull()), array['01920000-0000-7000-8000-0000000016c1']::uuid[],
          'y el pull baja toda la ciudad de su zona (0023), también la casa de afuera de la zona');
create temp table area_b3 on commit drop as select (sync.area_del_pull()).huella as h;

select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = public.hoy_montevideo() where id = '01920000-0000-7000-8000-0000000016e3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
select is((sync.area_del_pull()).huella, (select h from area_b3),
          'cuando la campaña empieza, la huella del área no cambia: sus casas ya habían bajado');

select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = public.hoy_montevideo() - 1, fecha_fin = public.hoy_montevideo() - 1 where id = '01920000-0000-7000-8000-0000000016e3';
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b3');
select is(pg_temp.casas(), array[]::text[], 'terminada, b3 deja de ver sus casas');
select is((select count(*) from public.mis_zonas()), 0::bigint, 'y su zona');
select isnt((sync.area_del_pull()).huella, (select h from area_b3), 'y cambia la huella del área');
select pg_temp.actuar_como_servidor();
update public.campania set fecha_inicio = current_date + 30, fecha_fin = current_date + 90 where id = '01920000-0000-7000-8000-0000000016e3';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b2');
select is(pg_temp.casas(), array[]::text[], 'b2 (solo Terminada) no ve las casas');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000016b4');
select is(pg_temp.casas(), array[]::text[], 'b4 (inscripción dada de baja) tampoco');

select * from finish();
rollback;
