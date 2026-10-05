-- Datos con el esquema de 0024: precios de zonas de la misma ciudad de la campaña que valen distinto
-- al mismo tiempo. 0027 aborta, no cambia nada y nombra cada caso. Ver scripts/db-test-migracion.sh.
--   1  «Libro de choque A» en Norte (250,00) y en Sur (270,00), los dos desde el 01/01, sin fin.
--   2  «Colección de choque» en Norte (450,00 hasta el 30/06) y en Oeste, zona dada de baja (460,00
--      desde el 01/06): también se pisan, y la zona dada de baja se nombra como tal.
-- Y estos NO se listan:
--   3  «Libro de choque B»: Norte [01/01–31/03] 300,00 y Sur [01/04–sin fin] 310,00 (contiguos).
--   4  «Libro de choque C»: Norte 100,00 vigente y Sur 110,00 dado de baja (el de baja no cuenta).
--   5  «Libro de choque D»: mismo importe en Norte y en Sur (se unificaría sin avisar).
--   6  «Libro de choque E»: importes distintos pero en campania_ciudad distintas.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-00000000a2c0', 'Pais migración 27b', 'ZW');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-00000000a2c1', 'Montevideo', '01920000-0000-7000-8000-00000000a2c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-00000000a2c2', 'Salto',      '01920000-0000-7000-8000-00000000a2c0', -31.38, -57.96);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-00000000a2e1', 'Verano', 'VERANO', '2026-01-05', '2026-12-20');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-00000000a2f1', '01920000-0000-7000-8000-00000000a2e1', '01920000-0000-7000-8000-00000000a2c1'),
  ('01920000-0000-7000-8000-00000000a2f2', '01920000-0000-7000-8000-00000000a2e1', '01920000-0000-7000-8000-00000000a2c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, deleted_at) values
  ('01920000-0000-7000-8000-00000000a2d1', 'Norte', '01920000-0000-7000-8000-00000000a2f1', 'RADIAL', -34.88, -56.16, 300, null),
  ('01920000-0000-7000-8000-00000000a2d2', 'Sur',   '01920000-0000-7000-8000-00000000a2f1', 'RADIAL', -34.92, -56.16, 300, null),
  ('01920000-0000-7000-8000-00000000a2d3', 'Oeste', '01920000-0000-7000-8000-00000000a2f1', 'RADIAL', -34.90, -56.20, 300, now()),
  ('01920000-0000-7000-8000-00000000a2d4', 'Centro Salto', '01920000-0000-7000-8000-00000000a2f2', 'RADIAL', -31.38, -57.96, 300, null);

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-00000000a2a1', 'Libro de choque A', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a2a2', 'Libro de choque B', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a2a3', 'Libro de choque C', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a2a4', 'Libro de choque D', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a2a5', 'Libro de choque E', 'LIBRO');
insert into public.coleccion (id, nombre) values ('01920000-0000-7000-8000-00000000a2b1', 'Colección de choque');

insert into public.precio_por_zona
  (id, producto_id, coleccion_id, zona_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  -- 1
  ('01920000-0000-7000-8000-00000000a201', '01920000-0000-7000-8000-00000000a2a1', null, '01920000-0000-7000-8000-00000000a2d1', 25000, '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a202', '01920000-0000-7000-8000-00000000a2a1', null, '01920000-0000-7000-8000-00000000a2d2', 27000, '2026-01-01', null, null),
  -- 2
  ('01920000-0000-7000-8000-00000000a211', null, '01920000-0000-7000-8000-00000000a2b1', '01920000-0000-7000-8000-00000000a2d1', 45000, '2026-01-01', '2026-06-30', null),
  ('01920000-0000-7000-8000-00000000a212', null, '01920000-0000-7000-8000-00000000a2b1', '01920000-0000-7000-8000-00000000a2d3', 46000, '2026-06-01', null, null),
  -- 3
  ('01920000-0000-7000-8000-00000000a221', '01920000-0000-7000-8000-00000000a2a2', null, '01920000-0000-7000-8000-00000000a2d1', 30000, '2026-01-01', '2026-03-31', null),
  ('01920000-0000-7000-8000-00000000a222', '01920000-0000-7000-8000-00000000a2a2', null, '01920000-0000-7000-8000-00000000a2d2', 31000, '2026-04-01', null, null),
  -- 4
  ('01920000-0000-7000-8000-00000000a231', '01920000-0000-7000-8000-00000000a2a3', null, '01920000-0000-7000-8000-00000000a2d1', 10000, '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a232', '01920000-0000-7000-8000-00000000a2a3', null, '01920000-0000-7000-8000-00000000a2d2', 11000, '2026-01-01', null, '2026-05-01 10:00:00+00'),
  -- 5
  ('01920000-0000-7000-8000-00000000a241', '01920000-0000-7000-8000-00000000a2a4', null, '01920000-0000-7000-8000-00000000a2d1', 7000,  '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a242', '01920000-0000-7000-8000-00000000a2a4', null, '01920000-0000-7000-8000-00000000a2d2', 7000,  '2026-01-01', null, null),
  -- 6
  ('01920000-0000-7000-8000-00000000a251', '01920000-0000-7000-8000-00000000a2a5', null, '01920000-0000-7000-8000-00000000a2d1', 6000,  '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a252', '01920000-0000-7000-8000-00000000a2a5', null, '01920000-0000-7000-8000-00000000a2d4', 6600,  '2026-01-01', null, null);
