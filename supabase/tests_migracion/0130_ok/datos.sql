-- Datos con el esquema de 0112 (el pedido todavía no tiene número visible) para probar que 0130 numera los que ya
-- había por fecha de pedido, sin tocar nada más (ni su versión de sync ni su xmin_w: ni se enteran los teléfonos).
-- Ver scripts/db-test-migracion.sh.
--
-- Dos colportoras (b1 y b2) y cuatro pedidos, cargados en un orden que no es el de la fecha: el 03 es el más
-- viejo (hace 4 días) y el 01 el más nuevo. El 02 lo cargó el coordinador (BORRADOR), el 04 es de b2 y está
-- cancelado. La foto de antes queda en prueba_0130_pedido: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000130b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion130-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000130b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion130-b2@example.com', 'x', now(), now(), now());

insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, excede_limite, fecha_pedido) values
  ('01920000-0000-7000-8000-000000013001', '01920000-0000-7000-8000-0000000130b1',
   'PENDIENTE_AUTORIZACION', 500000, 'COLPORTOR', true,  now() - interval '1 day'),
  ('01920000-0000-7000-8000-000000013002', '01920000-0000-7000-8000-0000000130b1',
   'BORRADOR',               150000, 'COORDINADOR', false, now() - interval '2 days'),
  ('01920000-0000-7000-8000-000000013003', '01920000-0000-7000-8000-0000000130b1',
   'RECIBIDO',               300000, 'COORDINADOR', false, now() - interval '4 days'),
  ('01920000-0000-7000-8000-000000013004', '01920000-0000-7000-8000-0000000130b2',
   'CANCELADO',                   0, 'COLPORTOR', false, now() - interval '3 days');

-- Una corrección sobre el recibido: sync_version 1 y un xmin_w propio.
update public.pedido_casa_editora set monto_total = 300000 where id = '01920000-0000-7000-8000-000000013003';

-- La foto de antes: las filas enteras.
create table public.prueba_0130_pedido as select * from public.pedido_casa_editora;
