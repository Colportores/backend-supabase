-- Datos con el esquema de 0111 (pedido_casa_editora sin monto_autorizado, decidido_por, decidido_en ni
-- motivo_rechazo; pedido_item sin cantidad_autorizada) para probar que 0112 solo suma las columnas, en null,
-- sin tocar ninguna fila ni su sincronización. Ver scripts/db-test-migracion.sh.
--
-- Una colportora con cuatro pedidos (por autorizar, autorizado, recibido y un rechazado de antes) y sus líneas. La foto de antes queda
-- en prueba_0112_* de public: db-reset.sh las borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000112b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion112@example.com', 'x', now(), now(), now());

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000011211', 'Libro 1 m112', 'LIBRO'),
  ('01920000-0000-7000-8000-000000011212', 'Libro 2 m112', 'LIBRO');

insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, excede_limite, fecha_pedido) values
  ('01920000-0000-7000-8000-000000011201', '01920000-0000-7000-8000-0000000112b1',
   'PENDIENTE_AUTORIZACION', 500000, 'COLPORTOR', true,  '2026-10-20 15:00:00+00'),
  ('01920000-0000-7000-8000-000000011202', '01920000-0000-7000-8000-0000000112b1',
   'AUTORIZADO',             150000, 'COLPORTOR', false, '2026-10-21 15:00:00+00'),
  ('01920000-0000-7000-8000-000000011203', '01920000-0000-7000-8000-0000000112b1',
   'RECIBIDO',               300000, 'COORDINADOR', false, '2026-10-22 15:00:00+00'),
  -- Un rechazado cargado a mano, de antes de que existiera el motivo (ninguna función rechazaba).
  ('01920000-0000-7000-8000-000000011204', '01920000-0000-7000-8000-0000000112b1',
   'RECHAZADO',               50000, 'COLPORTOR', false, '2026-10-23 15:00:00+00');

insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario, cantidad_recibida) values
  ('01920000-0000-7000-8000-000000011221', '01920000-0000-7000-8000-000000011201',
   '01920000-0000-7000-8000-000000011211', 2, 150000, null),
  ('01920000-0000-7000-8000-000000011222', '01920000-0000-7000-8000-000000011201',
   '01920000-0000-7000-8000-000000011212', 2, 100000, null),
  ('01920000-0000-7000-8000-000000011223', '01920000-0000-7000-8000-000000011202',
   '01920000-0000-7000-8000-000000011211', 1, 150000, null),
  ('01920000-0000-7000-8000-000000011224', '01920000-0000-7000-8000-000000011203',
   '01920000-0000-7000-8000-000000011212', 3, 100000, 3);

-- Una corrección sobre el pedido recibido: sync_version 1 y un xmin_w propio.
update public.pedido_casa_editora set monto_total = 300000 where id = '01920000-0000-7000-8000-000000011203';

-- La foto de antes: las filas enteras.
create table public.prueba_0112_pedido as select * from public.pedido_casa_editora;
create table public.prueba_0112_pedido_item as select * from public.pedido_item;
