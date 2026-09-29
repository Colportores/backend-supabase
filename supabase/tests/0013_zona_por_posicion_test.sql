-- pgTAP · migración 0010 — la zona de cada ubicación sale de su posición (backend-supabase#24).
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

create or replace function pg_temp.rect(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_object('type', 'Polygon', 'coordinates', jsonb_build_array(jsonb_build_array(
    jsonb_build_array(x0, y0), jsonb_build_array(x1, y0), jsonb_build_array(x1, y1),
    jsonb_build_array(x0, y1), jsonb_build_array(x0, y0))));
$$;

create or replace function pg_temp.esquinas(x0 numeric, y0 numeric, x1 numeric, y1 numeric)
returns jsonb language sql as $$
  select jsonb_build_array(
    jsonb_build_object('orden', 1, 'lon', x0, 'lat', y0), jsonb_build_object('orden', 2, 'lon', x1, 'lat', y0),
    jsonb_build_object('orden', 3, 'lon', x1, 'lat', y1), jsonb_build_object('orden', 4, 'lon', x0, 'lat', y1));
$$;

create or replace function pg_temp.guardar_rect(p_nombre text, x0 numeric, y0 numeric, x1 numeric, y1 numeric,
                                                p_zona uuid default null, p_previa boolean default false)
returns jsonb language sql as $$
  select public.guardar_zona(p_campania_ciudad_id => '01920000-0000-7000-8000-0000000013f1', p_nombre => p_nombre,
                             p_tipo_forma => 'ESQUINAS', p_vertices => pg_temp.esquinas(x0, y0, x1, y1),
                             p_poligono_geojson => pg_temp.rect(x0, y0, x1, y1),
                             p_zona_id => p_zona, p_vista_previa => p_previa);
$$;

-- Un punto a p_metros al este de (p_lat, p_lon), sobre el elipsoide.
create or replace function pg_temp.al_este(p_lat float8, p_lon float8, p_metros float8, out lat float8, out lon float8)
language sql as $$
  select extensions.st_y(g), extensions.st_x(g)
    from (select extensions.geometry(extensions.st_project(public.ubicacion_geografia(p_lat, p_lon),
                                                           p_metros, radians(90))) g) x;
$$;

create or replace function pg_temp.zona_de(p_ubicacion uuid) returns uuid language sql as $$
  select zona_id from public.ubicacion where id = p_ubicacion;
$$;

-- --- fixtures (como postgres) --------------------------------------------------
-- Montevideo (c1). Verano (e1, coordina a1) y Otra (e2) vigentes; Vieja (e3) terminó.
-- Zonas de Verano (f1): A y B comparten el borde lon -56.19; C se mete 0,46 m en B (franja
-- aceptada como borde); W para los recálculos. O es de Otra (f2), en el mismo lugar que A.
-- V es de Vieja (f3). Los ids ordenan A < B < O < V < C < W.
-- b1 (zona A) y b2 (zona B) en Verano; b3 (zona O) en Otra.
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000013' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'pos-' || s || '@example.com', 'x', now(), now(), now()
  from unnest(array['a1','b1','b2','b3']) s;
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000013a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000013c0', 'Pais pos', 'ZP');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000013c1', 'Montevideo pos', '01920000-0000-7000-8000-0000000013c0', -34.9, -56.2),
  ('01920000-0000-7000-8000-0000000013c2', 'Otra ciudad pos', '01920000-0000-7000-8000-0000000013c0', -34.8, -56.0);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000013e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30, '01920000-0000-7000-8000-0000000013a1'),
  ('01920000-0000-7000-8000-0000000013e2', 'Otra',   'PERMANENTE', current_date - 10, null,              null),
  ('01920000-0000-7000-8000-0000000013e3', 'Vieja',  'VERANO',     current_date - 90, current_date - 30, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000013f1', '01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-0000000013f2', '01920000-0000-7000-8000-0000000013e2', '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-0000000013f3', '01920000-0000-7000-8000-0000000013e3', '01920000-0000-7000-8000-0000000013c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000013d1', 'A', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.20, -34.92, -56.19, -34.91)),
  ('01920000-0000-7000-8000-0000000013d2', 'B', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.19, -34.92, -56.18, -34.91)),
  ('01920000-0000-7000-8000-0000000013d3', 'O', '01920000-0000-7000-8000-0000000013f2', 'ESQUINAS', pg_temp.rect(-56.20, -34.92, -56.19, -34.91)),
  ('01920000-0000-7000-8000-0000000013d4', 'V', '01920000-0000-7000-8000-0000000013f3', 'ESQUINAS', pg_temp.rect(-56.16, -34.92, -56.15, -34.91)),
  ('01920000-0000-7000-8000-0000000013d5', 'C', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.180005, -34.92, -56.17, -34.91)),
  ('01920000-0000-7000-8000-0000000013d6', 'W', '01920000-0000-7000-8000-0000000013f1', 'ESQUINAS', pg_temp.rect(-56.30, -34.92, -56.29, -34.91));
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b1', '01920000-0000-7000-8000-0000000013d1'),
  ('01920000-0000-7000-8000-0000000013e1', '01920000-0000-7000-8000-0000000013b2', '01920000-0000-7000-8000-0000000013d2'),
  ('01920000-0000-7000-8000-0000000013e2', '01920000-0000-7000-8000-0000000013b3', '01920000-0000-7000-8000-0000000013d3');

-- ---------------------------------------------------------------------------
-- 1. Forma
-- ---------------------------------------------------------------------------
select has_trigger('public', 'ubicacion', 'ubicacion_zona_por_posicion', 'ubicacion calcula su zona por posición');
select has_trigger('public', 'house_status', 'house_status_zona_de_su_ubicacion', 'house_status sigue a su ubicación');
select has_trigger('public', 'zona', 'zona_recalcular_ubicaciones', 'cambiar una zona recalcula las ubicaciones');
select has_trigger('public', 'campania_colportor', 'campania_colportor_republicar_zona', 'asignar una zona la republica');
select hasnt_trigger('public', 'ubicacion', 'ubicacion_zona_propia', 'tg_zona_propia se fue de ubicacion');
select hasnt_trigger('public', 'house_status', 'house_status_zona_propia', 'y de house_status');
select ok((select bool_and(columnas_servidor @> array['zona_id']) from sync.entidad
            where nombre in ('ubicacion', 'house_status')),
          'zona_id es columna del servidor en ubicacion y house_status (el push la descarta)');
select has_index('public', 'ubicacion', 'ubicacion_geografia_idx', 'índice geography + GiST para los 5 m');
select hasnt_index('public', 'ubicacion', 'ubicacion_direccion_uidx', 'sin índice único de dirección: espera D1');
select ok(not has_function_privilege('authenticated', f, 'execute'), 'authenticated NO ejecuta la interna ' || f)
  from unnest(array[
    'public.zona_de_posicion(double precision,double precision,uuid,uuid[],uuid,uuid,uuid,jsonb)',
    'public.ubicacion_campanias_preferidas(uuid,uuid)',
    'public.recalcular_zona_de_ubicaciones(uuid,uuid,extensions.geometry,extensions.geometry)']) f;
select ok(has_function_privilege('authenticated',
            'public.posibles_duplicados_de_ubicacion(uuid,text,text,double precision,double precision,uuid)', 'execute'),
          'authenticated ejecuta posibles_duplicados_de_ubicacion (la RLS decide qué filas)');

-- ---------------------------------------------------------------------------
-- 2. La zona sale de la posición (el colportor b1 registra desde la app)
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id, zona_id) values
  ('01920000-0000-7000-8000-000000001301', 'CASA', -34.915, -56.195, '01920000-0000-7000-8000-0000000013c1',
   '01920000-0000-7000-8000-0000000013d2'),
  ('01920000-0000-7000-8000-000000001302', 'CASA', -34.95, -56.25, '01920000-0000-7000-8000-0000000013c1',
   '01920000-0000-7000-8000-0000000013d1');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001301'), '01920000-0000-7000-8000-0000000013d1'::uuid,
          'punto dentro de A → A, aunque el cliente mande B (su zona_id se ignora)');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001302'), null::uuid,
          'punto fuera de toda zona → null, aunque el cliente mande A');

update public.ubicacion set lat = -34.915, lon = -56.185 where id = '01920000-0000-7000-8000-000000001302';
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001302'), '01920000-0000-7000-8000-0000000013d2'::uuid,
          'mover el punto adentro de B → B (R-CM04: la zona de otro colportor, y b1 puede)');
update public.ubicacion set zona_id = '01920000-0000-7000-8000-0000000013d1' where id = '01920000-0000-7000-8000-000000001302';
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001302'), '01920000-0000-7000-8000-0000000013d2'::uuid,
          'un UPDATE que solo cambia zona_id no la cambia: sale de la posición');

-- Borde compartido y franja: gana la de menor id.
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001303', 'CASA', -34.915, -56.19, '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001304', 'CASA', -34.915, -56.1800025, '01920000-0000-7000-8000-0000000013c1');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001303'), '01920000-0000-7000-8000-0000000013d1'::uuid,
          'punto justo en el borde entre A y B → A (menor id)');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001304'), '01920000-0000-7000-8000-0000000013d2'::uuid,
          'punto en la franja de 0,46 m entre B y C → B (menor id)');

-- Una zona de una campaña terminada no cuenta; la de otra ciudad tampoco.
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001305', 'CASA', -34.915, -56.155, '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001306', 'CASA', -34.915, -56.195, '01920000-0000-7000-8000-0000000013c2');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001305'), null::uuid,
          'punto solo dentro de una zona de una campaña terminada → null');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001306'), null::uuid,
          'punto dentro de A pero de otra ciudad → null (la zona es de la ciudad de la ubicación)');

-- R-CM04: b1 ve lo que registró en la zona de b2, y b2 también.
select ok(exists (select 1 from public.ubicacion where id = '01920000-0000-7000-8000-000000001302'),
          'b1 ve la casa que registró en la zona de b2');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b2');
select ok(exists (select 1 from public.ubicacion where id = '01920000-0000-7000-8000-000000001302'),
          'b2 ve la casa que b1 registró en su zona');

-- ---------------------------------------------------------------------------
-- 3. D2 (a): con dos campañas vigentes en la ciudad, la del colportor que registra o mueve
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b3');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001307', 'CASA', -34.912, -56.198, '01920000-0000-7000-8000-0000000013c1');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001307'), '01920000-0000-7000-8000-0000000013d3'::uuid,
          'b3 (Otra) registra donde se superponen A y O → O, la de su campaña');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001308', 'CASA', -34.912, -56.197, '01920000-0000-7000-8000-0000000013c1');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001308'), '01920000-0000-7000-8000-0000000013d1'::uuid,
          'b1 (Verano) registra en el mismo lugar → A, la de su campaña');
select pg_temp.actuar_como_servidor();
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001309', 'CASA', -34.912, -56.196, '01920000-0000-7000-8000-0000000013c1');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001309'), '01920000-0000-7000-8000-0000000013d1'::uuid,
          'sin colportor (servidor, sin created_by) → la de menor id (A)');
update public.ubicacion set tipo = 'NEGOCIO' where id = '01920000-0000-7000-8000-000000001307';
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001307'), '01920000-0000-7000-8000-0000000013d3'::uuid,
          'un UPDATE que no la mueve conserva la campaña de su zona (O), aunque A tenga menor id');

-- Mover a otra zona: solo casas propias. 1309 la cargó el servidor en A (zona de b1): b1 la
-- puede corregir dentro de A, pero no mandarla a B.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
select lives_ok(
  $$ update public.ubicacion set lat = -34.913 where id = '01920000-0000-7000-8000-000000001309' $$,
  'una casa ajena de su zona se puede corregir dentro de la zona');
select throws_ok(
  $$ update public.ubicacion set lon = -56.185 where id = '01920000-0000-7000-8000-000000001309' $$,
  '42501', null,
  'una casa ajena NO se puede mover a la zona de otro (solo casas propias)');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001309'), '01920000-0000-7000-8000-0000000013d1'::uuid,
          'y sigue en A');

-- ---------------------------------------------------------------------------
-- 4. house_status sigue a su ubicación; una baja conserva su zona
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013b1');
insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, zona_id, color, prioridad) values
  ('01920000-0000-7000-8000-000000001302', -34.915, -56.185, 'CASA', '01920000-0000-7000-8000-0000000013d1', 'RECHAZO', 7);
select is((select zona_id from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001302'),
          '01920000-0000-7000-8000-0000000013d2'::uuid,
          'house_status toma la zona de su ubicación (B), no la que manda el cliente; y b1 lo puede crear aunque sea la zona de b2');
update public.ubicacion set lon = -56.195 where id = '01920000-0000-7000-8000-000000001302';
select is((select zona_id from public.house_status where ubicacion_id = '01920000-0000-7000-8000-000000001302'),
          '01920000-0000-7000-8000-0000000013d1'::uuid,
          'al mover la ubicación a A, su house_status la sigue');

update public.ubicacion set deleted_at = now(), lon = -56.185 where id = '01920000-0000-7000-8000-000000001308';
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001308'), '01920000-0000-7000-8000-0000000013d1'::uuid,
          'una baja conserva su zona aunque la mueva: el tombstone le llega a quien tenía la fila');

-- ---------------------------------------------------------------------------
-- 5. Recálculo al cambiar una zona (vista 24): cuántas cambian, antes y después de guardar
-- ---------------------------------------------------------------------------
select pg_temp.actuar_como_servidor();
insert into public.ubicacion (id, tipo, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001310', 'CASA', -34.915, -56.295, '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001311', 'CASA', -34.915, -56.298, '01920000-0000-7000-8000-0000000013c1'),
  ('01920000-0000-7000-8000-000000001312', 'CASA', -34.915, -56.275, '01920000-0000-7000-8000-0000000013c1');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001310'), '01920000-0000-7000-8000-0000000013d6'::uuid,
          'fixture: Q en W');
create temp table version_q on commit drop as
select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-000000001310';

select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((pg_temp.guardar_rect('W', -56.30, -34.92, -56.296, -34.91, '01920000-0000-7000-8000-0000000013d6', true)
            -> 'ubicaciones_que_cambian'), '1'::jsonb,
          'vista previa: achicar W deja 1 ubicación afuera');
select pg_temp.actuar_como_servidor();
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001310'), '01920000-0000-7000-8000-0000000013d6'::uuid,
          'la vista previa no cambia nada');
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((pg_temp.guardar_rect('W', -56.30, -34.92, -56.296, -34.91, '01920000-0000-7000-8000-0000000013d6')
            -> 'ubicaciones_que_cambian'), '1'::jsonb,
          'al guardar, confirma 1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001310'), null::uuid,
          'la que quedó afuera pasa a null');
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-000000001310'),
          (select sync_version + 1 from version_q),
          'y se actualizó (sube su versión y su xmin_w: sale en el próximo delta)');
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001311'), '01920000-0000-7000-8000-0000000013d6'::uuid,
          'la que sigue adentro no cambia');

-- Zona nueva alrededor de S.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((pg_temp.guardar_rect('N', -56.28, -34.92, -56.27, -34.91, null, true) -> 'ubicaciones_que_cambian'),
          '1'::jsonb, 'vista previa de una zona nueva: 1 ubicación entra');
create temp table zona_n on commit drop as
select (pg_temp.guardar_rect('N', -56.28, -34.92, -56.27, -34.91) -> 'zona' ->> 'id')::uuid as id;
select pg_temp.actuar_como_servidor();
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001312'), (select id from zona_n),
          'al crear la zona, la ubicación que cae adentro la toma');

-- Baja de W: sus puntos quedan en null.
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000013a1');
select is((public.baja_zona('01920000-0000-7000-8000-0000000013d6', true) -> 'ubicaciones_que_cambian'), '1'::jsonb,
          'vista previa de la baja de W: 1 ubicación queda sin zona');
select is((public.baja_zona('01920000-0000-7000-8000-0000000013d6') -> 'ubicaciones_que_cambian'), '1'::jsonb,
          'baja de W: confirma 1');
select pg_temp.actuar_como_servidor();
select is(pg_temp.zona_de('01920000-0000-7000-8000-000000001311'), null::uuid,
          'dar de baja la zona deja sus puntos en null');

-- ---------------------------------------------------------------------------
-- 6. Posible duplicado (aviso): a menos de 5 m, o la misma dirección normalizada
-- ---------------------------------------------------------------------------
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-000000001320', 'CASA', 'Av. Italia', '2000', -34.95, -56.30, '01920000-0000-7000-8000-0000000013c1');
select is(
  (select array_agg(ubicacion_id) from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000013c1', null, null,
     (pg_temp.al_este(-34.95, -56.30, 4)).lat, (pg_temp.al_este(-34.95, -56.30, 4)).lon)),
  array['01920000-0000-7000-8000-000000001320'::uuid],
  'posible duplicado a 4 m → aparece');
select is(
  (select count(*) from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000013c1', null, null,
     (pg_temp.al_este(-34.95, -56.30, 6)).lat, (pg_temp.al_este(-34.95, -56.30, 6)).lon)),
  0::bigint,
  'a 6 m → no');
select is(
  (select array_agg(ubicacion_id::text || ' ' || misma_direccion) from public.posibles_duplicados_de_ubicacion(
     '01920000-0000-7000-8000-0000000013c1', '  AV. ITALIA ', '2000 ', -34.80, -56.10)),
  array['01920000-0000-7000-8000-000000001320 true'],
  'la misma dirección con mayúsculas y espacios distintos, lejos → aparece como misma dirección');
-- D1 pendiente: hoy no hay único, así que se guarda (con el aviso).
select lives_ok(
  $$ insert into public.ubicacion (tipo, calle, numero, lat, lon, ciudad_id)
     values ('CASA', 'av. italia', ' 2000', -34.80, -56.10, '01920000-0000-7000-8000-0000000013c1') $$,
  'la misma dirección se guarda mientras D1 esté pendiente (el aviso no bloquea)');

-- ---------------------------------------------------------------------------
-- 7. Lock por ciudad contra la carrera guardar_zona / push (la carrera en sí, con dos
--    sesiones, no entra en pgTAP: ver el PR). Esta transacción escribió ubicaciones de c1
--    (compartido) y recalculó zonas de c1 (exclusivo); los dos quedan tomados hasta el final.
-- ---------------------------------------------------------------------------
create or replace function pg_temp.tiene_lock_ciudad(p_ciudad uuid, p_modo text) returns boolean language sql as $$
  select exists (
    select 1 from pg_locks l
     where l.locktype = 'advisory' and l.pid = pg_backend_pid() and l.mode = p_modo and l.objsubid = 1
       and ((l.classid::bigint << 32) | l.objid::bigint) = hashtextextended('mapa_ciudad:' || p_ciudad::text, 0));
$$;
select ok(pg_temp.tiene_lock_ciudad('01920000-0000-7000-8000-0000000013c1', 'ShareLock'),
          'escribir una ubicación toma el lock de su ciudad compartido');
select ok(pg_temp.tiene_lock_ciudad('01920000-0000-7000-8000-0000000013c1', 'ExclusiveLock'),
          'recalcular las zonas de una ciudad lo toma exclusivo');

select * from finish();
rollback;
