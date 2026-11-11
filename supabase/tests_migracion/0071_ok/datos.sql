-- Datos con el esquema de 0069 (venta_item con coleccion_id pero sin componentes, coleccion sin libros_a_elegir,
-- venta sin motivo_monto_manual y el índice de talonario por colportor + número) para probar que 0071 no pierde
-- ni cambia nada de lo que ya estaba, completa los ítems de combo con la composición del combo y deja el
-- talonario más flojo. Ver scripts/db-test-migracion.sh.
--
-- Un colportor con una venta de tres ítems: un libro suelto, dos «Pack Familiar» (1 libro y 2 revistas; además
-- un tercer vínculo dado de baja que no cuenta) y un combo cuyos únicos vínculos están dados de baja. Una
-- segunda venta con otro número de talonario. La foto de antes queda en prueba_0071_* de public: db-reset.sh
-- las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000071a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000071c1', 'Ciudad 71', 'Departamento 71', '01920000-0000-7000-8000-0000000071a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000071b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion71@example.com', 'x', now(), now(), now());

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000007111', 'Libro 71', 'LIBRO'),
  ('01920000-0000-7000-8000-000000007112', 'Revista 71', 'REVISTA'),
  ('01920000-0000-7000-8000-000000007113', 'Folleto 71', 'MATERIAL');
insert into public.coleccion (id, nombre) values
  ('01920000-0000-7000-8000-0000000071d0', 'Pack Familiar 71'),
  ('01920000-0000-7000-8000-0000000071d1', 'Combo dado de baja 71');
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  ('01920000-0000-7000-8000-0000000071e1', '01920000-0000-7000-8000-000000007111', '01920000-0000-7000-8000-0000000071d0', 1),
  ('01920000-0000-7000-8000-0000000071e2', '01920000-0000-7000-8000-000000007112', '01920000-0000-7000-8000-0000000071d0', 2),
  ('01920000-0000-7000-8000-0000000071e3', '01920000-0000-7000-8000-000000007113', '01920000-0000-7000-8000-0000000071d0', 5),
  ('01920000-0000-7000-8000-0000000071e4', '01920000-0000-7000-8000-000000007111', '01920000-0000-7000-8000-0000000071d1', 3),
  ('01920000-0000-7000-8000-0000000071e5', '01920000-0000-7000-8000-000000007112', '01920000-0000-7000-8000-0000000071d1', 4);
-- Un vínculo del Pack Familiar y los dos del otro combo, dados de baja.
update public.producto_coleccion set deleted_at = '2026-09-01 10:00:00+00'
 where id in ('01920000-0000-7000-8000-0000000071e3', '01920000-0000-7000-8000-0000000071e4',
              '01920000-0000-7000-8000-0000000071e5');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000071f1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000071c1', '01920000-0000-7000-8000-0000000071b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000071f2', '01920000-0000-7000-8000-0000000071f1', '01920000-0000-7000-8000-0000000071b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000071f3', '01920000-0000-7000-8000-0000000071f2',
   '01920000-0000-7000-8000-0000000071f4', '01920000-0000-7000-8000-0000000071b1');

insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000007101', '01920000-0000-7000-8000-0000000071f3', 'T-7101', 270000,
   '2026-10-01 15:00:00+00', '01920000-0000-7000-8000-0000000071b1', '01920000-0000-7000-8000-0000000071b1'),
  ('01920000-0000-7000-8000-000000007102', '01920000-0000-7000-8000-0000000071f3', 'T-7102', 24000,
   '2026-10-02 15:00:00+00', '01920000-0000-7000-8000-0000000071b1', '01920000-0000-7000-8000-0000000071b1');
insert into public.venta_item (id, venta_id, producto_id, coleccion_id, cantidad, precio_unitario, subtotal) values
  ('01920000-0000-7000-8000-000000007111', '01920000-0000-7000-8000-000000007101',
   '01920000-0000-7000-8000-000000007111', null, 1, 24000, 24000),
  ('01920000-0000-7000-8000-000000007112', '01920000-0000-7000-8000-000000007101',
   null, '01920000-0000-7000-8000-0000000071d0', 2, 110000, 220000),
  ('01920000-0000-7000-8000-000000007113', '01920000-0000-7000-8000-000000007101',
   null, '01920000-0000-7000-8000-0000000071d1', 1, 26000, 26000),
  ('01920000-0000-7000-8000-000000007114', '01920000-0000-7000-8000-000000007102',
   '01920000-0000-7000-8000-000000007111', null, 1, 24000, 24000);
-- Una corrección sobre el ítem suelto: sync_version 1 y un xmin_w propio.
update public.venta_item set cantidad = 1 where id = '01920000-0000-7000-8000-000000007114';

-- La foto de antes: las filas enteras.
create table public.prueba_0071_venta as select * from public.venta;
create table public.prueba_0071_venta_item as select * from public.venta_item;
create table public.prueba_0071_coleccion as select * from public.coleccion;
create table public.prueba_0071_producto_coleccion as select * from public.producto_coleccion;
