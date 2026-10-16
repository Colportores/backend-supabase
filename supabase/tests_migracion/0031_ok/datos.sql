-- Datos con el esquema de 0030 (ciudad sin rectángulo, zona sin paquete) para probar que 0031 agrega las
-- columnas sin tocar una fila y carga el rectángulo de Montevideo, la única Montevideo viva de Uruguay.
-- Ver scripts/db-test-migracion.sh. Los casos 0031_ok_ambigua y 0031_ok_sin_candidata prueban cuándo NO
-- se lo carga.
--
-- Uruguay con tres ciudades (Montevideo, Salto y una dada de baja) y Chile con otra «Montevideo»:
--   c1 Montevideo (UY), centro adentro de su rectángulo  → recibe el rectángulo
--   c2 Salto (UY)                                         → no se toca
--   c3 Maldonado (UY), dada de baja                       → no se toca
--   c4 Montevideo (CL), otro país, mismo nombre           → no se toca
-- Una campaña de verano en c1 y en c2, y dos zonas (una RADIAL en c1 con color y una en c2).
-- La foto de antes queda en prueba_0031_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000031a1', 'Uruguay', 'UY'),
  ('01920000-0000-7000-8000-0000000031a2', 'Chile',   'CL');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial, deleted_at) values
  ('01920000-0000-7000-8000-0000000031c1', 'Montevideo', '01920000-0000-7000-8000-0000000031a1', -34.9011, -56.1645, 13, null),
  ('01920000-0000-7000-8000-0000000031c2', 'Salto',      '01920000-0000-7000-8000-0000000031a1', -31.3833, -57.9667, 14, null),
  ('01920000-0000-7000-8000-0000000031c3', 'Maldonado',  '01920000-0000-7000-8000-0000000031a1', -34.9000, -54.9500, 13, '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000031c4', 'Montevideo', '01920000-0000-7000-8000-0000000031a2', -34.9011, -56.1645, 13, null);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000031e1', 'Verano 31', 'VERANO', '2026-01-05', '2026-12-20');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000031f1', '01920000-0000-7000-8000-0000000031e1', '01920000-0000-7000-8000-0000000031c1'),
  ('01920000-0000-7000-8000-0000000031f2', '01920000-0000-7000-8000-0000000031e1', '01920000-0000-7000-8000-0000000031c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color) values
  ('01920000-0000-7000-8000-0000000031b1', 'Zona Montevideo 31', '01920000-0000-7000-8000-0000000031f1', 'RADIAL', -34.90, -56.16, 500, '#3A7BD5'),
  ('01920000-0000-7000-8000-0000000031b2', 'Zona Salto 31',      '01920000-0000-7000-8000-0000000031f2', 'RADIAL', -31.38, -57.96, 400, '#E07A5F');

-- La foto de antes: las filas enteras.
create table public.prueba_0031_ciudad as select * from public.ciudad;
create table public.prueba_0031_zona   as select * from public.zona;
