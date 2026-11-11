-- Zonas vivas de la misma campaña y ciudad que chocan (superposición y nombre repetido): 0008
-- tiene que abortar y nombrar cada par. Ver scripts/db-test-migracion.sh.
insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000082c0', 'Pais migración', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000082c1', 'Montevideo', '01920000-0000-7000-8000-0000000082c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, ciudad_id) values
  ('01920000-0000-7000-8000-0000000082e1', 'Verano', 'VERANO', current_date - 10, '01920000-0000-7000-8000-0000000082c1');

insert into public.zona (id, nombre, ciudad_id, campania_id, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000082d1', 'Norte', '01920000-0000-7000-8000-0000000082c1', '01920000-0000-7000-8000-0000000082e1',
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.90],[-56.17,-34.91]]]}'),
  ('01920000-0000-7000-8000-0000000082d2', 'Sur', '01920000-0000-7000-8000-0000000082c1', '01920000-0000-7000-8000-0000000082e1',
   '{"type":"Polygon","coordinates":[[[-56.165,-34.91],[-56.155,-34.91],[-56.155,-34.90],[-56.165,-34.90],[-56.165,-34.91]]]}'),
  ('01920000-0000-7000-8000-0000000082d3', 'Centro', '01920000-0000-7000-8000-0000000082c1', '01920000-0000-7000-8000-0000000082e1',
   '{"type":"Polygon","coordinates":[[[-56.10,-34.91],[-56.09,-34.91],[-56.09,-34.90],[-56.10,-34.90],[-56.10,-34.91]]]}'),
  ('01920000-0000-7000-8000-0000000082d4', 'Centro', '01920000-0000-7000-8000-0000000082c1', '01920000-0000-7000-8000-0000000082e1',
   '{"type":"Polygon","coordinates":[[[-56.08,-34.91],[-56.07,-34.91],[-56.07,-34.90],[-56.08,-34.90],[-56.08,-34.91]]]}');
