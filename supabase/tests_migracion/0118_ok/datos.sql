-- Datos con el esquema de 0117 (entrega sin la marca de inconsistencia, sin triggers de stock) para probar que
-- 0118 solo suma la columna, en false, sin tocar ninguna entrega ni ningún saldo de stock y sin inventar
-- movimientos de salida de lo que ya se entregó. Ver scripts/db-test-migracion.sh.
--
-- Un colportor (b1) con una venta y tres entregas de antes: una ya entregada (2 del Libro 118), una pendiente
-- (1) y una entregada de más de lo que tenía (5 con el saldo registrado en 3). Su stock del Libro 118 es 3.
-- La foto de antes queda en prueba_0118_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000118a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000118c1', 'Ciudad 118', 'Departamento 118', '01920000-0000-7000-8000-0000000118a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000118b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion118@example.com', 'x', now(), now(), now());

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000118e1', 'CASA', 'Calle Uno', '1', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000118c1', '01920000-0000-7000-8000-0000000118b1');
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  ('01920000-0000-7000-8000-0000000118f1', '01920000-0000-7000-8000-0000000118e1', null, '01920000-0000-7000-8000-0000000118b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-000000011801', '01920000-0000-7000-8000-0000000118f1', '01920000-0000-7000-8000-000000011891',
   '01920000-0000-7000-8000-0000000118b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000011821', '01920000-0000-7000-8000-000000011801', 'T-11821', 100000, now(),
   '01920000-0000-7000-8000-0000000118b1', '01920000-0000-7000-8000-0000000118b1');
insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000011851', 'Libro 118', 'LIBRO');
insert into public.stock (id, usuario_id, producto_id, cantidad_disponible) values
  ('01920000-0000-7000-8000-000000011871', '01920000-0000-7000-8000-0000000118b1',
   '01920000-0000-7000-8000-000000011851', 3);
insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente, created_by) values
  ('01920000-0000-7000-8000-000000011861', '01920000-0000-7000-8000-000000011821', '01920000-0000-7000-8000-000000011851', 2,
   '2026-10-01 15:00:00+00', false, '01920000-0000-7000-8000-0000000118b1'),
  ('01920000-0000-7000-8000-000000011862', '01920000-0000-7000-8000-000000011821', '01920000-0000-7000-8000-000000011851', 1,
   null, true, '01920000-0000-7000-8000-0000000118b1'),
  ('01920000-0000-7000-8000-000000011863', '01920000-0000-7000-8000-000000011821', '01920000-0000-7000-8000-000000011851', 5,
   '2026-10-02 15:00:00+00', false, '01920000-0000-7000-8000-0000000118b1');
-- Una corrección sobre una: sync_version 1 y un xmin_w propio.
update public.entrega set fecha_entrega = '2026-10-01 16:00:00+00' where id = '01920000-0000-7000-8000-000000011861';

-- La foto de antes: las filas enteras.
create table public.prueba_0118_entrega as select * from public.entrega;
create table public.prueba_0118_stock as select * from public.stock;
