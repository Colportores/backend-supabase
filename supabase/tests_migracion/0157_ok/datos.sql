-- Datos con el esquema de 0154 para probar la 0157 (backend-supabase#234, «Devol. saldo»).
-- Ver scripts/db-test-migracion.sh.
--
-- Una colportora con una venta de dos productos, un cobro, y otra venta dada de baja. La primera venta se
-- corrige una vez (sync_version 1 y un xmin_w propio). La foto de antes queda en prueba_0157_* de public:
-- db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000157a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000157c1', 'Ciudad 157', 'Departamento 157', '01920000-0000-7000-8000-0000000157a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000157b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion157@example.com', 'x', now(), now(), now());

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000015711', 'Libro 1 m157', 'LIBRO'),
  ('01920000-0000-7000-8000-000000015712', 'Libro 2 m157', 'LIBRO');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000157f1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000157c1', '01920000-0000-7000-8000-0000000157b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000157f2', '01920000-0000-7000-8000-0000000157f1', '01920000-0000-7000-8000-0000000157b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000157f3', '01920000-0000-7000-8000-0000000157f2',
   '01920000-0000-7000-8000-0000000157f4', '01920000-0000-7000-8000-0000000157b1');

insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000015701', '01920000-0000-7000-8000-0000000157f3', 'T-15701', 450000,
   '2026-10-01 15:00:00+00', '01920000-0000-7000-8000-0000000157b1', '01920000-0000-7000-8000-0000000157b1', null),
  ('01920000-0000-7000-8000-000000015702', '01920000-0000-7000-8000-0000000157f3', 'T-15702', 100000,
   '2026-10-02 15:00:00+00', '01920000-0000-7000-8000-0000000157b1', '01920000-0000-7000-8000-0000000157b1', now());
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, created_by) values
  ('01920000-0000-7000-8000-000000015721', '01920000-0000-7000-8000-000000015701',
   '01920000-0000-7000-8000-000000015711', 2, 150000, 300000, '01920000-0000-7000-8000-0000000157b1'),
  ('01920000-0000-7000-8000-000000015722', '01920000-0000-7000-8000-000000015701',
   '01920000-0000-7000-8000-000000015712', 1, 150000, 150000, '01920000-0000-7000-8000-0000000157b1');
insert into public.cobranza (id, venta_id, monto, medio, fecha, numero_cuota, created_by) values
  ('01920000-0000-7000-8000-000000015731', '01920000-0000-7000-8000-000000015701', 250000, 'EFECTIVO',
   '2026-10-01 15:30:00+00', 1, '01920000-0000-7000-8000-0000000157b1');
-- Una corrección sobre la venta: sync_version 1 y un xmin_w propio.
update public.venta set monto_total = 460000 where id = '01920000-0000-7000-8000-000000015701';

-- Una devolución de antes: un libro 2 (150000) con la plata que retuvo y la que devolvió, que la 0157 saca de la tabla.
insert into public.devolucion (id, venta_id, productos_devueltos, dinero_retenido, monto_reembolsado, fecha_devolucion, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000015741', '01920000-0000-7000-8000-000000015701',
   jsonb_build_array(jsonb_build_object('producto_id', '01920000-0000-7000-8000-000000015712', 'cantidad', 1,
                                         'venta_item_id', '01920000-0000-7000-8000-000000015722')),
   5000, 2000, '2026-10-03 15:00:00+00', '01920000-0000-7000-8000-0000000157b1', '01920000-0000-7000-8000-0000000157b1');

-- La foto de antes: las filas enteras.
create table public.prueba_0157_venta      as select * from public.venta;
create table public.prueba_0157_venta_item as select * from public.venta_item;
create table public.prueba_0157_cobranza   as select * from public.cobranza;
create table public.prueba_0157_devolucion as select * from public.devolucion;
