-- Datos con el esquema de 0126 (la transferencia todavía no tiene número visible) para probar que 0127 numera las
-- que ya había por fecha de solicitud, sin tocar nada más (ni su versión de sync ni su xmin_w: ni se enteran los
-- teléfonos). Ver scripts/db-test-migracion.sh.
--
-- Dos colportores (b1 da, b2 recibe) y tres transferencias de b1 a b2, pedidas en este orden: la 11 hace 2 días, la
-- 12 hace 3 y la 13 hace 4 (autorizada, con su deuda). La foto de antes queda en prueba_0127_transferencia: db-reset.sh
-- la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000127b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion127-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000127b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion127-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000127d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion127-c1@example.com', 'x', now(), now(), now());

insert into public.transferencia_stock (id, origen_id, destino_id, estado, fecha_solicitud, coordinador_id,
                                        monto_deuda, decidido_en) values
  ('01920000-0000-7000-8000-000000012711', '01920000-0000-7000-8000-0000000127b1',
   '01920000-0000-7000-8000-0000000127b2', 'PENDIENTE_AUTORIZACION', now() - interval '2 days', null, null, null),
  ('01920000-0000-7000-8000-000000012712', '01920000-0000-7000-8000-0000000127b1',
   '01920000-0000-7000-8000-0000000127b2', 'PENDIENTE_AUTORIZACION', now() - interval '3 days', null, null, null),
  ('01920000-0000-7000-8000-000000012713', '01920000-0000-7000-8000-0000000127b1',
   '01920000-0000-7000-8000-0000000127b2', 'AUTORIZADO', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000127d1', 3000, now() - interval '3 days');

-- La foto de antes: las filas enteras.
create table public.prueba_0127_transferencia as select * from public.transferencia_stock;
