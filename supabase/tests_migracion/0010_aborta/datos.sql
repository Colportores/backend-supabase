-- Ubicaciones cuya zona hoy le abre la casa a un colportor y que por su posición quedarían en
-- otra zona o en ninguna: 0010 tiene que abortar y nombrar cada una. Ver
-- scripts/db-test-migracion.sh.
--   a1 con Centro (Verano, vigente), fuera de toda zona
--   a2 con Centro, dentro de Cordón
--   a3 con Centro y dentro de Centro: está bien, no aparece

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000093c0', 'Pais migración 10b', 'ZW');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000093c1', 'Montevideo', '01920000-0000-7000-8000-0000000093c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000093e1', 'Verano', 'VERANO', current_date - 10, current_date + 30);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000093f1', '01920000-0000-7000-8000-0000000093e1', '01920000-0000-7000-8000-0000000093c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m) values
  ('01920000-0000-7000-8000-0000000093d1', 'Centro', '01920000-0000-7000-8000-0000000093f1', 'RADIAL', -34.90, -56.18, 300),
  ('01920000-0000-7000-8000-0000000093d2', 'Cordón', '01920000-0000-7000-8000-0000000093f1', 'RADIAL', -34.90, -56.14, 300);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, zona_id) values
  ('01920000-0000-7000-8000-0000000093a1', 'CASA', 'Rivera', '100', -34.95, -56.25, '01920000-0000-7000-8000-0000000093c1', '01920000-0000-7000-8000-0000000093d1'),
  ('01920000-0000-7000-8000-0000000093a2', 'CASA', 'Rivera', '200', -34.90, -56.14, '01920000-0000-7000-8000-0000000093c1', '01920000-0000-7000-8000-0000000093d1'),
  ('01920000-0000-7000-8000-0000000093a3', 'CASA', 'Rivera', '300', -34.90, -56.18, '01920000-0000-7000-8000-0000000093c1', '01920000-0000-7000-8000-0000000093d1');
