-- Ubicaciones que 0010 recalcula sin preguntar (nadie deja de ver nada). Ver
-- scripts/db-test-migracion.sh.
--   u1 en Centro (Verano, vigente) y con Centro: queda igual. Su house_status tenía la zona
--      de Vieja: se alinea con la ubicación.
--   u2 sin zona, dentro de Centro: pasa a Centro (y su house_status también).
--   u3 con la zona de Vieja (campaña terminada), dentro de Centro: pasa a Centro.
--   u4 con la zona de Vieja, fuera de toda zona: pasa a null.
--   u5 dada de baja con Centro, fuera de Centro: no se toca (el tombstone conserva su zona).

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000092c0', 'Pais migración 10', 'ZY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000092c1', 'Montevideo', '01920000-0000-7000-8000-0000000092c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000092e1', 'Verano', 'VERANO', current_date - 10, current_date + 30),
  ('01920000-0000-7000-8000-0000000092e2', 'Vieja',  'VERANO', current_date - 90, current_date - 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000092f1', '01920000-0000-7000-8000-0000000092e1', '01920000-0000-7000-8000-0000000092c1'),
  ('01920000-0000-7000-8000-0000000092f2', '01920000-0000-7000-8000-0000000092e2', '01920000-0000-7000-8000-0000000092c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000092d1', 'Centro', '01920000-0000-7000-8000-0000000092f1', 'RADIAL', -34.90, -56.18, 300),
  ('01920000-0000-7000-8000-0000000092d2', 'Vieja',  '01920000-0000-7000-8000-0000000092f2', 'RADIAL', -34.90, -56.18, 300);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000092a1', 'CASA', 'Rivera', '1', -34.90,  -56.18,  '01920000-0000-7000-8000-0000000092c1', '01920000-0000-7000-8000-0000000092d1', null),
  ('01920000-0000-7000-8000-0000000092a2', 'CASA', 'Rivera', '2', -34.901, -56.181, '01920000-0000-7000-8000-0000000092c1', null, null),
  ('01920000-0000-7000-8000-0000000092a3', 'CASA', 'Rivera', '3', -34.899, -56.179, '01920000-0000-7000-8000-0000000092c1', '01920000-0000-7000-8000-0000000092d2', null),
  ('01920000-0000-7000-8000-0000000092a4', 'CASA', 'Rivera', '4', -34.95,  -56.25,  '01920000-0000-7000-8000-0000000092c1', '01920000-0000-7000-8000-0000000092d2', null),
  ('01920000-0000-7000-8000-0000000092a5', 'CASA', 'Rivera', '5', -34.95,  -56.25,  '01920000-0000-7000-8000-0000000092c1', '01920000-0000-7000-8000-0000000092d1', now());

insert into public.house_status (ubicacion_id, lat, lon, tipo_ubicacion, zona_id, color, prioridad) values
  ('01920000-0000-7000-8000-0000000092a1', -34.90,  -56.18,  'CASA', '01920000-0000-7000-8000-0000000092d2', 'RECHAZO', 7),
  ('01920000-0000-7000-8000-0000000092a2', -34.901, -56.181, 'CASA', null, 'SIN_CONTESTAR', 6);
