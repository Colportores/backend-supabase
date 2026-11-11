-- Datos con el esquema de 0069 para probar el caso raro de 0071: un ítem de combo vendido de una colección que
-- NUNCA tuvo un componente (ni vivo ni dado de baja). Sus componentes no se pueden completar sin inventar:
-- la migración no se cae ni borra nada, deja esa fila como estaba y agrega la regla «solo en combo» NOT VALID
-- (rige para lo nuevo). Ver scripts/db-test-migracion.sh.
--
-- Una venta con un libro suelto, un combo con composición y un combo sin ninguna. La foto de antes queda en
-- prueba_0071s_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000072a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000072c1', 'Ciudad 72', 'Departamento 72', '01920000-0000-7000-8000-0000000072a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000072b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion72@example.com', 'x', now(), now(), now());

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000007211', 'Libro 72', 'LIBRO');
insert into public.coleccion (id, nombre) values
  ('01920000-0000-7000-8000-0000000072d0', 'Combo con composicion 72'),
  ('01920000-0000-7000-8000-0000000072d1', 'Combo vacio 72');
insert into public.producto_coleccion (id, producto_id, coleccion_id, cantidad) values
  ('01920000-0000-7000-8000-0000000072e1', '01920000-0000-7000-8000-000000007211', '01920000-0000-7000-8000-0000000072d0', 2);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000072f1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000072c1', '01920000-0000-7000-8000-0000000072b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000072f2', '01920000-0000-7000-8000-0000000072f1', '01920000-0000-7000-8000-0000000072b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000072f3', '01920000-0000-7000-8000-0000000072f2',
   '01920000-0000-7000-8000-0000000072f4', '01920000-0000-7000-8000-0000000072b1');

insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000007201', '01920000-0000-7000-8000-0000000072f3', 'T-7201', 100000,
   '2026-10-01 15:00:00+00', '01920000-0000-7000-8000-0000000072b1', '01920000-0000-7000-8000-0000000072b1');
insert into public.venta_item (id, venta_id, producto_id, coleccion_id, cantidad, precio_unitario, subtotal) values
  ('01920000-0000-7000-8000-000000007211', '01920000-0000-7000-8000-000000007201',
   '01920000-0000-7000-8000-000000007211', null, 1, 24000, 24000),
  ('01920000-0000-7000-8000-000000007212', '01920000-0000-7000-8000-000000007201',
   null, '01920000-0000-7000-8000-0000000072d0', 1, 50000, 50000),
  ('01920000-0000-7000-8000-000000007213', '01920000-0000-7000-8000-000000007201',
   null, '01920000-0000-7000-8000-0000000072d1', 1, 26000, 26000);

-- La foto de antes: las filas enteras.
create table public.prueba_0071s_venta_item as select * from public.venta_item;
