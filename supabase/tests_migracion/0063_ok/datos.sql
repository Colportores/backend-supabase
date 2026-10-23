-- Datos con el esquema de 0059, el anterior a la 0063 (ciudad sin departamento) para probar que 0063 agrega la columna sin
-- tocar una fila y carga 'Montevideo' en la única Montevideo viva de Uruguay. Ver
-- scripts/db-test-migracion.sh. Los casos 0063_ok_ambigua y 0063_ok_sin_candidata prueban cuándo NO se
-- carga.
--
-- Uruguay con tres ciudades (Montevideo, Salto y una dada de baja) y Chile con otra «Montevideo»:
--   c1 Montevideo (UY), centro adentro del rectángulo  -> recibe el departamento
--   c2 Salto (UY)                                       -> no se toca (no se adivina)
--   c3 Maldonado (UY), dada de baja                     -> no se toca
--   c4 Montevideo (CL), otro país, mismo nombre         -> no se toca
-- Una campaña de verano en c1 y en c2, y una zona en c1.
-- La foto de antes queda en prueba_0063_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000048a1', 'Uruguay', 'UY'),
  ('01920000-0000-7000-8000-0000000048a2', 'Chile',   'CL');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial, deleted_at) values
  ('01920000-0000-7000-8000-0000000048c1', 'Montevideo', '01920000-0000-7000-8000-0000000048a1', -34.9011, -56.1645, 13, null),
  ('01920000-0000-7000-8000-0000000048c2', 'Salto',      '01920000-0000-7000-8000-0000000048a1', -31.3833, -57.9667, 14, null),
  ('01920000-0000-7000-8000-0000000048c3', 'Maldonado',  '01920000-0000-7000-8000-0000000048a1', -34.9000, -54.9500, 13, '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000048c4', 'Montevideo', '01920000-0000-7000-8000-0000000048a2', -34.9011, -56.1645, 13, null);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin) values
  ('01920000-0000-7000-8000-0000000048e1', 'Verano 48', 'VERANO', '2026-01-05', '2026-12-20');
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000048f1', '01920000-0000-7000-8000-0000000048e1', '01920000-0000-7000-8000-0000000048c1'),
  ('01920000-0000-7000-8000-0000000048f2', '01920000-0000-7000-8000-0000000048e1', '01920000-0000-7000-8000-0000000048c2');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, color) values
  ('01920000-0000-7000-8000-0000000048b1', 'Zona Montevideo 48', '01920000-0000-7000-8000-0000000048f1', 'RADIAL', -34.90, -56.16, 500, '#3A7BD5');

-- La foto de antes: las filas enteras.
create table public.prueba_0063_ciudad as select * from public.ciudad;
create table public.prueba_0063_zona   as select * from public.zona;
create table public.prueba_0063_campania_ciudad as select * from public.campania_ciudad;
