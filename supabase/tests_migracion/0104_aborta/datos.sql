-- Datos con el esquema de 0103: espacios con un texto en la descripción. 0104 aborta, no cambia nada y
-- nombra cada caso (sin copiar el texto). Ver scripts/db-test-migracion.sh.
--   e1  depto 3B de Av. Italia 100, con texto: se lista.
--   e2  espacio único de una casa sin dirección (marcador manual), dado de baja, con texto: también se
--       lista (no se borra un texto aunque el espacio esté dado de baja), y sin calle ni número.
-- Y estos NO se listan:
--   e3  descripción en blanco ('   ').
--   e4  descripción null.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000104d0', 'Pais migración 102b', 'ZW');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000104d1', 'Montevideo', 'Montevideo', '01920000-0000-7000-8000-0000000104d0', -34.90, -56.20);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-0000000104e1', 'EDIFICIO', 'Av. Italia', '100', -34.90, -56.20, '01920000-0000-7000-8000-0000000104d1'),
  ('01920000-0000-7000-8000-0000000104e2', 'CASA', null, null, -34.95, -56.25, '01920000-0000-7000-8000-0000000104d1');

insert into public.espacio (id, ubicacion_id, numero_depto, piso, descripcion, deleted_at) values
  ('01920000-0000-7000-8000-0000000104f1', '01920000-0000-7000-8000-0000000104e1', '3B', '3', 'timbre roto, tocar fuerte', null),
  ('01920000-0000-7000-8000-0000000104f2', '01920000-0000-7000-8000-0000000104e2', null, null, 'la señora Pérez, jubilada', '2026-10-01 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000104f3', '01920000-0000-7000-8000-0000000104e1', '5D', '5', '   ', null),
  ('01920000-0000-7000-8000-0000000104f4', '01920000-0000-7000-8000-0000000104e1', '6E', '6', null, null);
