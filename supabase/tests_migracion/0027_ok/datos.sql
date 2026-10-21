-- Datos con el esquema de 0024 (el precio de venta cuelga de la zona), para probar que 0027 pasa
-- cada precio a la campania_ciudad de su zona, unifica los que valen lo mismo y se pisan, y no
-- pierde ni cambia nada más. Ver scripts/db-test-migracion.sh.
--
-- Todas son zonas de la misma campania_ciudad f1 (Verano en Montevideo), salvo las de f2 y f3:
--   d1 Norte · d2 Sur · d3 Oeste (dada de baja) · d4 en f2 (Verano en Salto) · d5 en f3 (Permanente en Montevideo)
-- Los precios (todos con zona), por grupo:
--   A  p1 en d1 y en d2, 250,00, los dos sin fin, desde el mismo día          → se unifican: queda a1; a2, de baja
--   B  p2 en d1 [01/01–31/03] y en d2 [01/03–30/06], 300,00 (se pisan)         → queda b1, estirado hasta 30/06; b2, de baja
--   C  p3 en d1 [01/01–28/02], d2 [15/02–30/04], d3 [01/04–sin fin], 120,00    → cadena: queda c1, sin fin; c2 y c3, de baja
--   D  p4 en d1 [01/01–31/03] y en d2 [01/04–sin fin], 80,00 (contiguos)       → no se tocan
--   E  p1 en d4 (f2) y p1 en d5 (f3), otro importe cada uno                    → no se tocan: otra campania_ciudad
--   F  p5 en d1, 90,00, dado de baja, y p5 en d2, 95,00, vigente (importes distintos, vigencias que se pisan)
--                                                                              → el de baja no cuenta: no aborta, no se toca
--   G  k1 (colección) en d1 y en d2, 450,00 (se pisan)                         → queda g1, sin fin; g2, de baja
--   H  p6 en d1 [01/01–28/02] 50,00 y en d2 [01/03–sin fin] 55,00 (distintos, no se pisan) → no se tocan
-- La foto de antes queda en prueba_0027_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-00000000a1c0', 'Pais migración 27', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-00000000a1c1', 'Montevideo', '01920000-0000-7000-8000-00000000a1c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-00000000a1c2', 'Salto',      '01920000-0000-7000-8000-00000000a1c0', -31.38, -57.96);
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-00000000a1e1', 'Verano',     'VERANO',     '2026-01-05', '2026-12-20'),
  ('01920000-0000-7000-8000-00000000a1e2', 'Permanente', 'PERMANENTE', '2026-01-01', null);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-00000000a1f1', '01920000-0000-7000-8000-00000000a1e1', '01920000-0000-7000-8000-00000000a1c1'),
  ('01920000-0000-7000-8000-00000000a1f2', '01920000-0000-7000-8000-00000000a1e1', '01920000-0000-7000-8000-00000000a1c2'),
  ('01920000-0000-7000-8000-00000000a1f3', '01920000-0000-7000-8000-00000000a1e2', '01920000-0000-7000-8000-00000000a1c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, deleted_at) values
  ('01920000-0000-7000-8000-00000000a1d1', 'Norte',  '01920000-0000-7000-8000-00000000a1f1', 'RADIAL', -34.88, -56.16, 300, null),
  ('01920000-0000-7000-8000-00000000a1d2', 'Sur',    '01920000-0000-7000-8000-00000000a1f1', 'RADIAL', -34.92, -56.16, 300, null),
  ('01920000-0000-7000-8000-00000000a1d3', 'Oeste',  '01920000-0000-7000-8000-00000000a1f1', 'RADIAL', -34.90, -56.20, 300, now()),
  ('01920000-0000-7000-8000-00000000a1d4', 'Centro Salto', '01920000-0000-7000-8000-00000000a1f2', 'RADIAL', -31.38, -57.96, 300, null),
  ('01920000-0000-7000-8000-00000000a1d5', 'Norte (permanente)', '01920000-0000-7000-8000-00000000a1f3', 'RADIAL', -34.88, -56.16, 300, null);

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-00000000a1a1', 'Libro p1', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a1a2', 'Libro p2', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a1a3', 'Libro p3', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a1a4', 'Libro p4', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a1a5', 'Libro p5', 'LIBRO'),
  ('01920000-0000-7000-8000-00000000a1a6', 'Libro p6', 'LIBRO');
insert into public.coleccion (id, nombre) values ('01920000-0000-7000-8000-00000000a1b1', 'Colección k1');

insert into public.precio_por_zona
  (id, producto_id, coleccion_id, zona_id, precio_venta, valido_desde, valido_hasta, deleted_at) values
  -- A
  ('01920000-0000-7000-8000-00000000a101', '01920000-0000-7000-8000-00000000a1a1', null, '01920000-0000-7000-8000-00000000a1d1', 25000, '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a102', '01920000-0000-7000-8000-00000000a1a1', null, '01920000-0000-7000-8000-00000000a1d2', 25000, '2026-01-01', null, null),
  -- B
  ('01920000-0000-7000-8000-00000000a111', '01920000-0000-7000-8000-00000000a1a2', null, '01920000-0000-7000-8000-00000000a1d1', 30000, '2026-01-01', '2026-03-31', null),
  ('01920000-0000-7000-8000-00000000a112', '01920000-0000-7000-8000-00000000a1a2', null, '01920000-0000-7000-8000-00000000a1d2', 30000, '2026-03-01', '2026-06-30', null),
  -- C
  ('01920000-0000-7000-8000-00000000a121', '01920000-0000-7000-8000-00000000a1a3', null, '01920000-0000-7000-8000-00000000a1d1', 12000, '2026-01-01', '2026-02-28', null),
  ('01920000-0000-7000-8000-00000000a122', '01920000-0000-7000-8000-00000000a1a3', null, '01920000-0000-7000-8000-00000000a1d2', 12000, '2026-02-15', '2026-04-30', null),
  ('01920000-0000-7000-8000-00000000a123', '01920000-0000-7000-8000-00000000a1a3', null, '01920000-0000-7000-8000-00000000a1d3', 12000, '2026-04-01', null, null),
  -- D
  ('01920000-0000-7000-8000-00000000a131', '01920000-0000-7000-8000-00000000a1a4', null, '01920000-0000-7000-8000-00000000a1d1', 8000,  '2026-01-01', '2026-03-31', null),
  ('01920000-0000-7000-8000-00000000a132', '01920000-0000-7000-8000-00000000a1a4', null, '01920000-0000-7000-8000-00000000a1d2', 8000,  '2026-04-01', null, null),
  -- E (a1 y a2 usan p1 en f1; estos usan p1 en otras campania_ciudad)
  ('01920000-0000-7000-8000-00000000a141', '01920000-0000-7000-8000-00000000a1a1', null, '01920000-0000-7000-8000-00000000a1d4', 25000, '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a142', '01920000-0000-7000-8000-00000000a1a1', null, '01920000-0000-7000-8000-00000000a1d5', 26000, '2026-01-01', null, null),
  -- F
  ('01920000-0000-7000-8000-00000000a151', '01920000-0000-7000-8000-00000000a1a5', null, '01920000-0000-7000-8000-00000000a1d1', 9000,  '2026-01-01', null, '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-00000000a152', '01920000-0000-7000-8000-00000000a1a5', null, '01920000-0000-7000-8000-00000000a1d2', 9500,  '2026-01-01', null, null),
  -- G
  ('01920000-0000-7000-8000-00000000a161', null, '01920000-0000-7000-8000-00000000a1b1', '01920000-0000-7000-8000-00000000a1d1', 45000, '2026-01-01', null, null),
  ('01920000-0000-7000-8000-00000000a162', null, '01920000-0000-7000-8000-00000000a1b1', '01920000-0000-7000-8000-00000000a1d2', 45000, '2026-02-01', null, null),
  -- H
  ('01920000-0000-7000-8000-00000000a171', '01920000-0000-7000-8000-00000000a1a6', null, '01920000-0000-7000-8000-00000000a1d1', 5000,  '2026-01-01', '2026-02-28', null),
  ('01920000-0000-7000-8000-00000000a172', '01920000-0000-7000-8000-00000000a1a6', null, '01920000-0000-7000-8000-00000000a1d2', 5500,  '2026-03-01', null, null);

-- La foto de antes, con la campania_ciudad que le toca a cada precio por su zona.
create table public.prueba_0027_precio as
select p.*, z.campania_ciudad_id as cc_esperada
  from public.precio_por_zona p
  join public.zona z on z.id = p.zona_id;
