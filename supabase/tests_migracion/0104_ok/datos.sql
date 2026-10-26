-- Datos con el esquema de 0103: espacios con la descripción vacía (null, '' y en blanco) y uno dado de
-- baja. 0104 se aplica sin avisar y saca la columna. Ver scripts/db-test-migracion.sh.
--   e1  depto 3B de Av. Italia 100, descripción null.
--   e2  depto 4C de la misma casa, descripción ''.
--   e3  depto 5D, descripción en blanco ('   '): no es un texto, no frena la migración.
--   e4  espacio único (sin depto) de una casa sin dirección (marcador manual), dado de baja, null.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000104c0', 'Pais migración 102a', 'ZW');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000104c1', 'Montevideo', 'Montevideo', '01920000-0000-7000-8000-0000000104c0', -34.90, -56.20);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id) values
  ('01920000-0000-7000-8000-0000000104a1', 'EDIFICIO', 'Av. Italia', '100', -34.90, -56.20, '01920000-0000-7000-8000-0000000104c1'),
  ('01920000-0000-7000-8000-0000000104a2', 'CASA', null, null, -34.95, -56.25, '01920000-0000-7000-8000-0000000104c1');

insert into public.espacio (id, ubicacion_id, numero_depto, piso, descripcion, deleted_at) values
  ('01920000-0000-7000-8000-0000000104b1', '01920000-0000-7000-8000-0000000104a1', '3B', '3', null,  null),
  ('01920000-0000-7000-8000-0000000104b2', '01920000-0000-7000-8000-0000000104a1', '4C', '4', '',    null),
  ('01920000-0000-7000-8000-0000000104b3', '01920000-0000-7000-8000-0000000104a1', '5D', '5', '   ', null),
  ('01920000-0000-7000-8000-0000000104b4', '01920000-0000-7000-8000-0000000104a2', null, null, null, '2026-10-01 10:00:00+00');

-- Foto de cómo estaban, para comparar fila por fila (versión de sync y xmin_w incluidos).
create table public.prueba_0104_espacio as select * from public.espacio;
