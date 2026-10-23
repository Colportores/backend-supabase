-- Datos con el esquema de 0055 (venta_item solo de producto, producto_coleccion sin cantidad) para probar que
-- 0056 deja las ventas y los vínculos de antes como estaban: cada ítem sigue apuntando a su producto y cada
-- componente de una colección queda en 1 unidad. Ver scripts/db-test-migracion.sh.
--
-- Una venta de un colportor con dos ítems de producto, y una colección con dos productos. La foto de antes
-- queda en prueba_0056_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000056a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000056c1', 'Ciudad 56', '01920000-0000-7000-8000-0000000056a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000056b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion56@example.com', 'x', now(), now(), now());

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000005611', 'Libro 56', 'LIBRO'),
  ('01920000-0000-7000-8000-000000005612', 'Revista 56', 'REVISTA');
insert into public.coleccion (id, nombre) values
  ('01920000-0000-7000-8000-0000000056d0', 'Coleccion 56');
insert into public.producto_coleccion (id, producto_id, coleccion_id) values
  ('01920000-0000-7000-8000-0000000056a2', '01920000-0000-7000-8000-000000005611', '01920000-0000-7000-8000-0000000056d0'),
  ('01920000-0000-7000-8000-0000000056a3', '01920000-0000-7000-8000-000000005612', '01920000-0000-7000-8000-0000000056d0');
-- Un vínculo dado de baja, para ver que la migración tampoco lo toca.
update public.producto_coleccion set deleted_at = '2026-09-01 10:00:00+00'
 where id = '01920000-0000-7000-8000-0000000056a3';

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000056e1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000056c1', '01920000-0000-7000-8000-0000000056b1');
insert into public.espacio (id, ubicacion_id) values
  ('01920000-0000-7000-8000-0000000056e2', '01920000-0000-7000-8000-0000000056e1');
insert into public.espacio_persona (id, espacio_id, persona_id) values
  ('01920000-0000-7000-8000-0000000056e3', '01920000-0000-7000-8000-0000000056e2',
   '01920000-0000-7000-8000-0000000056e4');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id) values
  ('01920000-0000-7000-8000-0000000056f1', '01920000-0000-7000-8000-0000000056e3', 'T-56', 55000,
   '2026-10-01 15:00:00+00', '01920000-0000-7000-8000-0000000056b1');
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal) values
  ('01920000-0000-7000-8000-0000000056f2', '01920000-0000-7000-8000-0000000056f1',
   '01920000-0000-7000-8000-000000005611', 2, 24000, 48000),
  ('01920000-0000-7000-8000-0000000056f3', '01920000-0000-7000-8000-0000000056f1',
   '01920000-0000-7000-8000-000000005612', 1, 7500, 7500);

-- La foto de antes: las filas enteras.
create table public.prueba_0056_venta_item as select * from public.venta_item;
create table public.prueba_0056_producto_coleccion as select * from public.producto_coleccion;
