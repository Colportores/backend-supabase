-- Datos con el esquema de 0010, para probar que 0011 (la zona se calcula al descargar) no pierde
-- ni cambia nada. Ver scripts/db-test-migracion.sh.
--   u1 en Centro (la zona de b1), con estado, un espacio, su vínculo y una venta
--   u2 en Montevideo, fuera de Centro, con estado
--   u3 en Centro, dada de baja
--   u4 en Canelones, donde ninguna campaña trabaja
-- La foto de antes queda en tablas prueba_0011_* de public: db-reset.sh las borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000094b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mig11-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000094b2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mig11-b2@example.com', 'x', now(), now(), now());

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000094c0', 'Pais migración 11', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000094c1', 'Montevideo', '01920000-0000-7000-8000-0000000094c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-0000000094c2', 'Canelones',  '01920000-0000-7000-8000-0000000094c0', -34.52, -56.28);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000094e1', 'Verano', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000094f1', '01920000-0000-7000-8000-0000000094e1', '01920000-0000-7000-8000-0000000094c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000094d1', 'Centro', '01920000-0000-7000-8000-0000000094f1', 'RADIAL', -34.90, -56.18, 300);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000094e1', '01920000-0000-7000-8000-0000000094b1', '01920000-0000-7000-8000-0000000094d1'),
  ('01920000-0000-7000-8000-0000000094e1', '01920000-0000-7000-8000-0000000094b2', null);

-- 0010 les pone la zona por posición.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000094a1', 'CASA', 'Rivera', '1', -34.90,  -56.18,  '01920000-0000-7000-8000-0000000094c1', '01920000-0000-7000-8000-0000000094b1'),
  ('01920000-0000-7000-8000-0000000094a2', 'CASA', 'Rivera', '2', -34.95,  -56.25,  '01920000-0000-7000-8000-0000000094c1', null),
  ('01920000-0000-7000-8000-0000000094a3', 'CASA', 'Rivera', '3', -34.901, -56.181, '01920000-0000-7000-8000-0000000094c1', null),
  ('01920000-0000-7000-8000-0000000094a4', 'CASA', 'Rivera', '4', -34.52,  -56.28,  '01920000-0000-7000-8000-0000000094c2', null);
update public.ubicacion set deleted_at = now() where id = '01920000-0000-7000-8000-0000000094a3';

insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_by) values
  ('01920000-0000-7000-8000-0000000094a1', -34.90, -56.18, 'CASA', 'COBRANZA_PENDIENTE', 2, '01920000-0000-7000-8000-0000000094b1'),
  ('01920000-0000-7000-8000-0000000094a2', -34.95, -56.25, 'CASA', 'RECHAZO', 7, null);
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000094e5', '01920000-0000-7000-8000-0000000094a1', '01920000-0000-7000-8000-0000000094b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000094e6', '01920000-0000-7000-8000-0000000094e5', '01920000-0000-7000-8000-0000000094e7',
   '01920000-0000-7000-8000-0000000094b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-0000000094e8', '01920000-0000-7000-8000-0000000094e6', 'M11-1', 45000, now(),
   '01920000-0000-7000-8000-0000000094b1', '01920000-0000-7000-8000-0000000094b1');

-- La foto de antes: todo menos zona_id, que es lo único que se va.
create table public.prueba_0011_ubicacion as
select id, tipo, calle, numero, lat, lon, ciudad_id, created_at, updated_at, created_by, deleted_at,
       sync_version, xmin_w::text as xmin_w, zona_id
  from public.ubicacion;
create table public.prueba_0011_house_status as
select ubicacion_id, lat, lon, tipo_ubicacion, color, prioridad, created_at, updated_at, created_by, deleted_at,
       sync_version, xmin_w::text as xmin_w
  from public.house_status;
create table public.prueba_0011_espacio as select id, ubicacion_id, sync_version, xmin_w::text as xmin_w from public.espacio;
create table public.prueba_0011_venta as select id, espacio_persona_id, monto_total, sync_version from public.venta;
