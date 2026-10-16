-- pgTAP · migración 0031 (backend-supabase#42, etapa 2): el rectángulo de la ciudad y el enlace al paquete de
-- mapa de la zona. Esta prueba mira la base ya migrada y lo que hacen las restricciones y los permisos;
-- que la migración conserve los datos y cargue el rectángulo de Montevideo lo prueba
-- supabase/tests_migracion/0031_ok (con datos, a través de la migración) y que las columnas viajen en el
-- pull, 0039.
begin;
select * from no_plan();

create or replace function pg_temp.u(p_sufijo text) returns uuid language sql as $$
  select ('01920000-0000-7000-8000-0000000038' || p_sufijo)::uuid;
$$;

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

-- --- las columnas ---------------------------------------------------------------------------
select has_column('public', 'ciudad', 'bbox_oeste', 'ciudad tiene bbox_oeste');
select has_column('public', 'ciudad', 'bbox_sur',   'ciudad tiene bbox_sur');
select has_column('public', 'ciudad', 'bbox_este',  'ciudad tiene bbox_este');
select has_column('public', 'ciudad', 'bbox_norte', 'ciudad tiene bbox_norte');
select col_type_is('public', 'ciudad', 'bbox_oeste', 'double precision', 'en grados, como lat_centro y lon_centro');
select col_is_null('public', 'ciudad', 'bbox_oeste', 'el rectángulo es opcional: una ciudad sin mapa propio no lo tiene');
select col_is_null('public', 'ciudad', 'bbox_norte', 'también el norte');
select has_column('public', 'zona', 'paquete_mapa', 'zona tiene paquete_mapa');
select col_type_is('public', 'zona', 'paquete_mapa', 'jsonb', 'es un jsonb');
select col_is_null('public', 'zona', 'paquete_mapa', 'y es opcional: NULL es «todavía no se publicó»');
select ok(col_description('public.zona'::regclass, (select attnum from pg_attribute
                                                     where attrelid = 'public.zona'::regclass and attname = 'paquete_mapa')) is not null,
          'paquete_mapa tiene su comentario (la forma del jsonb está documentada)');

-- --- el rectángulo: lo que acepta y lo que no -------------------------------------------------
insert into public.pais (id, nombre, iso_code) values (pg_temp.u('c0'), 'Pais bbox38', 'ZW');

select lives_ok(
  $$ insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
       ('01920000-0000-7000-8000-000000003801', 'Sin rectángulo 38', '01920000-0000-7000-8000-0000000038c0', -34.9, -56.2) $$,
  'una ciudad sin rectángulo sigue entrando (las del seed y las recién cargadas)');
select lives_ok(
  $$ insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('01920000-0000-7000-8000-000000003802', 'Con rectángulo 38', '01920000-0000-7000-8000-0000000038c0',
        -34.9, -56.2, -56.433, -34.945, -55.948, -34.701) $$,
  'una ciudad con su rectángulo entero entra');
select lives_ok(
  $$ update public.ciudad set bbox_oeste = -56.5, bbox_sur = -35.0, bbox_este = -55.9, bbox_norte = -34.6
      where id = '01920000-0000-7000-8000-000000003801' $$,
  'a una ciudad cargada sin rectángulo se le puede cargar después (UPDATE de los cuatro a la vez)');
select lives_ok(
  $$ update public.ciudad set bbox_oeste = null, bbox_sur = null, bbox_este = null, bbox_norte = null
      where id = '01920000-0000-7000-8000-000000003801' $$,
  'y quitárselo');

select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste) values
       ('Incompleta 38', '01920000-0000-7000-8000-0000000038c0', -34.9, -56.2, -56.4) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_completo_check"',
  'un rectángulo a medias (solo el oeste) se rechaza: viene entero o no viene');
select throws_ok(
  $$ update public.ciudad set bbox_norte = null where id = '01920000-0000-7000-8000-000000003802' $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_completo_check"',
  'y no se le puede quitar un lado a uno entero');
select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('Fuera de rango 38', '01920000-0000-7000-8000-0000000038c0', -34.5, -100, -190, -35, -56, -34) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_rango_check"',
  'una longitud fuera de -180..180 se rechaza');
select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('Latitud 38', '01920000-0000-7000-8000-0000000038c0', -34.5, -56.2, -57, -95, -56, -34) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_rango_check"',
  'una latitud fuera de -90..90 se rechaza');
select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('Al revés 38', '01920000-0000-7000-8000-0000000038c0', -34.9, -56.2, -55.948, -34.945, -56.433, -34.701) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_orden_check"',
  'el oeste a la derecha del este se rechaza, y el error dice «orden», no «centro»');
select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('Sur y norte 38', '01920000-0000-7000-8000-0000000038c0', -34.9, -56.2, -56.433, -34.701, -55.948, -34.945) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_orden_check"',
  'el sur arriba del norte también');
select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('Sin área 38', '01920000-0000-7000-8000-0000000038c0', -34.9, -56.2, -56.2, -34.945, -56.2, -34.701) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_orden_check"',
  'un rectángulo sin ancho no es un área');
select throws_ok(
  $$ insert into public.ciudad (nombre, pais_id, lat_centro, lon_centro, bbox_oeste, bbox_sur, bbox_este, bbox_norte) values
       ('Lat y lon al revés 38', '01920000-0000-7000-8000-0000000038c0', -56.2, -34.9, -56.433, -34.945, -55.948, -34.701) $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_contiene_centro_check"',
  'un centro con la latitud y la longitud cargadas al revés queda fuera del rectángulo y se rechaza');
select throws_ok(
  $$ update public.ciudad set lat_centro = -30 where id = '01920000-0000-7000-8000-000000003802' $$,
  '23514', 'new row for relation "ciudad" violates check constraint "ciudad_bbox_contiene_centro_check"',
  'y mover el centro fuera del rectángulo de una ciudad ya cargada también');

-- --- el enlace de la zona ---------------------------------------------------------------------
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  (pg_temp.u('e1'), 'Campaña bbox38', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  (pg_temp.u('f1'), pg_temp.u('e1'), pg_temp.u('02'));
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color) values
  (pg_temp.u('a1'), 'Zona bbox38 A', pg_temp.u('f1'), 'RADIAL', -34.9, -56.2, 500, '#3A7BD5'),
  (pg_temp.u('a2'), 'Zona bbox38 B', pg_temp.u('f1'), 'RADIAL', -34.9, -56.1, 500, '#E07A5F');

select is((select paquete_mapa from public.zona where id = pg_temp.u('a1')), null::jsonb,
          'una zona nueva no trae paquete: todavía no se publicó');
select lives_ok(
  $$ update public.zona set paquete_mapa = '{"archivo":"zonas/0123456789abcdef0123456789abcdef.pmtiles","tamano_bytes":4812345,"sha256":"aa","zoom_max":15,"actualizado_en":"2026-10-08T12:00:00Z","anteriores":[]}'::jsonb
      where id = '01920000-0000-7000-8000-0000000038a1' $$,
  'el publicador (postgres, como el SQL Editor y la clave de servicio) le pone su paquete');
select is((select paquete_mapa ->> 'archivo' from public.zona where id = pg_temp.u('a1')),
          'zonas/0123456789abcdef0123456789abcdef.pmtiles', 'queda guardado');
select is((select (paquete_mapa -> 'zoom_max')::int from public.zona where id = pg_temp.u('a1')), 15,
          'con sus números como números');
select throws_ok(
  $$ update public.zona set paquete_mapa = '["zonas/x.pmtiles"]'::jsonb where id = '01920000-0000-7000-8000-0000000038a1' $$,
  '23514', 'new row for relation "zona" violates check constraint "zona_paquete_mapa_objeto_check"',
  'un arreglo no es un enlace: tiene que ser un objeto');
select throws_ok(
  $$ update public.zona set paquete_mapa = '"zonas/x.pmtiles"'::jsonb where id = '01920000-0000-7000-8000-0000000038a1' $$,
  '23514', 'new row for relation "zona" violates check constraint "zona_paquete_mapa_objeto_check"',
  'ni un texto suelto');
select lives_ok(
  $$ update public.zona set paquete_mapa = null where id = '01920000-0000-7000-8000-0000000038a1' $$,
  'y se puede dejar sin paquete (NULL)');

-- Poner el enlace NO es cambiar la forma: tg_zona_mapa sale antes de buscar superposiciones (las dos
-- zonas de esta ciudad se tocan en nada, pero aunque se solaparan no habría error).
select lives_ok(
  $$ update public.zona set paquete_mapa = '{"archivo":"zonas/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pmtiles"}'::jsonb
      where id = '01920000-0000-7000-8000-0000000038a2' $$,
  'poner el paquete no vuelve a validar la forma de la zona');
select is((select sync_version from public.zona where id = pg_temp.u('a2')), 1::bigint,
          'pero sí sube sync_version: el teléfono baja el enlace nuevo por delta');

-- --- quién lo escribe -------------------------------------------------------------------------
select is(has_table_privilege('authenticated', 'public.zona', 'UPDATE'), false,
          'authenticated no puede UPDATE sobre zona: el enlace no lo escribe un usuario');
select is(has_table_privilege('authenticated', 'public.zona', 'INSERT'), false, 'ni INSERT');
select is(has_table_privilege('anon', 'public.zona', 'UPDATE'), false, 'anon tampoco');
select is(has_column_privilege('authenticated', 'public.zona', 'paquete_mapa', 'UPDATE'), false,
          'ni la columna sola');
select is(has_table_privilege('authenticated', 'public.zona', 'SELECT'), true,
          'pero sí lo lee, con la política de zona (quien ve la zona ve su enlace)');
select is(has_table_privilege('service_role', 'public.zona', 'UPDATE'), true,
          'la clave de servicio del publicador sí puede');
-- --- quién escribe el rectángulo: el ADMIN, como el resto de la ciudad (HU-ADM-005) -------------
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select pg_temp.u(x.s), '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'bbox38-' || x.s || '@example.com', 'x', now(), now(), now()
  from (values ('b1'), ('b2')) x(s);
insert into public.usuario_rol (usuario_id, rol_id)
select pg_temp.u(x.s), r.id
  from (values ('b1', 'ADMIN'), ('b2', 'COLPORTOR')) x(s, codigo)
  join public.rol r on r.codigo = x.codigo;

-- Cuántas filas deja actualizar la política: un UPDATE dentro de una función (un WITH con UPDATE no puede ir
-- adentro de un select is(...)).
create or replace function pg_temp.cargar_este(p_este float8) returns int language plpgsql as $$
declare n int;
begin
  update public.ciudad set bbox_este = p_este where id = '01920000-0000-7000-8000-000000003802';
  get diagnostics n = row_count;
  return n;
end $$;

select pg_temp.actuar_como(pg_temp.u('b1'));
select is(pg_temp.cargar_este(-55.9), 1,
          'el ADMIN carga el rectángulo de una ciudad (es una política de ciudad que ya existía: 0001)');

select pg_temp.actuar_como(pg_temp.u('b2'));
select is(pg_temp.cargar_este(-55.8), 0,
          'un colportor no: la política no le deja ninguna fila');
select throws_ok(
  $$ update public.zona set paquete_mapa = '{"archivo":"zonas/x.pmtiles"}'::jsonb where id = '01920000-0000-7000-8000-0000000038a1' $$,
  '42501', 'permission denied for table zona',
  'y el enlace de una zona no lo escribe un usuario (aquí un colportor): zona no tiene UPDATE para authenticated');
select is((select count(*)::int from public.ciudad where id = '01920000-0000-7000-8000-000000003802'), 1,
          'pero un colportor lee las ciudades, con su rectángulo');

select pg_temp.actuar_como_servidor();

select * from finish();
rollback;
