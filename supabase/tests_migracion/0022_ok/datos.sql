-- Datos con el esquema de 0021, para probar que 0022 (historial de zonas) abre un tramo inicial por
-- cada inscripción con zona y no pierde ni cambia ninguna inscripción. Ver scripts/db-test-migracion.sh.
--   b1 con Norte, viva
--   b2 sin zona
--   b3 con Sur, inscripción dada de baja (conserva su zona, 0012)
--   b4 con Norte, en otra campaña
-- La foto de antes queda en prueba_0022_* de public: db-reset.sh las borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000099b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mig22-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000099b2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mig22-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000099b3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mig22-b3@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000099b4', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mig22-b4@example.com', 'x', now(), now(), now());

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000099c0', 'Pais migración 22', 'ZY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000099c1', 'Montevideo', '01920000-0000-7000-8000-0000000099c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000099e1', 'Verano', 'VERANO',     current_date - 10, current_date + 30),
  ('01920000-0000-7000-8000-0000000099e2', 'Otra',   'PERMANENTE', current_date - 10, null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000099f1', '01920000-0000-7000-8000-0000000099e1', '01920000-0000-7000-8000-0000000099c1'),
  ('01920000-0000-7000-8000-0000000099f2', '01920000-0000-7000-8000-0000000099e2', '01920000-0000-7000-8000-0000000099c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000099d1', 'Norte',        '01920000-0000-7000-8000-0000000099f1', 'RADIAL', -34.88, -56.16, 300),
  ('01920000-0000-7000-8000-0000000099d2', 'Sur',          '01920000-0000-7000-8000-0000000099f1', 'RADIAL', -34.92, -56.16, 300),
  ('01920000-0000-7000-8000-0000000099d3', 'Norte (otra)', '01920000-0000-7000-8000-0000000099f2', 'RADIAL', -34.88, -56.16, 300);
insert into public.campania_colportor (id, campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000099a1', '01920000-0000-7000-8000-0000000099e1', '01920000-0000-7000-8000-0000000099b1', '01920000-0000-7000-8000-0000000099d1'),
  ('01920000-0000-7000-8000-0000000099a2', '01920000-0000-7000-8000-0000000099e1', '01920000-0000-7000-8000-0000000099b2', null),
  ('01920000-0000-7000-8000-0000000099a3', '01920000-0000-7000-8000-0000000099e1', '01920000-0000-7000-8000-0000000099b3', '01920000-0000-7000-8000-0000000099d2'),
  ('01920000-0000-7000-8000-0000000099a4', '01920000-0000-7000-8000-0000000099e2', '01920000-0000-7000-8000-0000000099b4', '01920000-0000-7000-8000-0000000099d3');
update public.campania_colportor set deleted_at = now() where id = '01920000-0000-7000-8000-0000000099a3';

-- La foto de antes: toda la fila de la inscripción.
create table public.prueba_0022_campania_colportor as
select id, campania_id, usuario_id, zona_id, meta_libros, created_at, updated_at, created_by, deleted_at,
       sync_version, xmin_w::text as xmin_w
  from public.campania_colportor;
