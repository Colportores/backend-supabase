-- Zonas que 0008 no puede migrar sin inventar o perder datos: tiene que abortar y nombrarlas.
-- Ver scripts/db-test-migracion.sh.
insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000081c0', 'Pais migración', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000081c1', 'Montevideo', '01920000-0000-7000-8000-0000000081c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio, ciudad_id) values
  ('01920000-0000-7000-8000-0000000081e1', 'Verano', 'VERANO', current_date - 10, '01920000-0000-7000-8000-0000000081c1');

insert into public.zona (id, nombre, ciudad_id, campania_id, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000081d1', 'Sin campaña', '01920000-0000-7000-8000-0000000081c1', null,
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.91]]]}'),
  ('01920000-0000-7000-8000-0000000081d2', 'Sin forma', '01920000-0000-7000-8000-0000000081c1',
   '01920000-0000-7000-8000-0000000081e1', null),
  ('01920000-0000-7000-8000-0000000081d3', 'Forma rota', '01920000-0000-7000-8000-0000000081c1',
   '01920000-0000-7000-8000-0000000081e1',
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.90],[-56.16,-34.91],[-56.17,-34.90],[-56.17,-34.91]]]}');
