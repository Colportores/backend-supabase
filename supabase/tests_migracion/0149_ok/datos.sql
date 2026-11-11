-- Datos con el esquema de 0147 (la última antes de 0148) para probar que 0148 y 0149 solo suman y completan:
--   · cada producto de antes recibe su categoría sin perder ninguna fila ni cambiar otra columna (0149);
--   · cada línea de transferencia de antes recibe las dos puntas de su encabezado, y el movimiento de stock de antes
--     queda igual (0148);
--   · lo nuevo anda sobre los datos de antes.
-- Ver scripts/db-test-migracion.sh. La foto de antes queda en prueba_0149_* de public: db-reset.sh la borra con el resto.
--
-- Productos: libro bonificable, libro misionero, libro común, revista, misionero, material y uno dado de baja.
-- Colportoras b1 y b2 con una transferencia armada por el coordinador d1 (b1 da, b2 recibe) y una que pidió b2.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000149b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion149-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000149b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion149-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000149d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion149-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000149b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000149b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000149d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.producto (id, nombre, tipo, es_bonificable, es_misionero, deleted_at) values
  ('01920000-0000-7000-8000-0000000149a1', 'Libro bonif 149', 'LIBRO', true, false, null),
  ('01920000-0000-7000-8000-0000000149a2', 'Libro misionero 149', 'LIBRO', false, true, null),
  ('01920000-0000-7000-8000-0000000149a3', 'Libro comun 149', 'LIBRO', false, false, null),
  ('01920000-0000-7000-8000-0000000149a4', 'Revista 149', 'REVISTA', true, false, null),
  ('01920000-0000-7000-8000-0000000149a5', 'Misionero 149', 'MISIONERO', false, true, null),
  ('01920000-0000-7000-8000-0000000149a6', 'Material 149', 'MATERIAL', false, false, null),
  ('01920000-0000-7000-8000-0000000149a7', 'Libro de baja 149', 'LIBRO', false, false, '2026-09-01 10:00:00+00');

insert into public.transferencia_stock (id, origen_id, destino_id, estado, coordinador_id, solicitante_id) values
  ('01920000-0000-7000-8000-0000000149c1', '01920000-0000-7000-8000-0000000149b1', '01920000-0000-7000-8000-0000000149b2',
   'PENDIENTE_AUTORIZACION', '01920000-0000-7000-8000-0000000149d1', null),
  ('01920000-0000-7000-8000-0000000149c2', '01920000-0000-7000-8000-0000000149b1', '01920000-0000-7000-8000-0000000149b2',
   'PENDIENTE_AUTORIZACION', null, '01920000-0000-7000-8000-0000000149b2');
insert into public.transferencia_item (id, transferencia_id, producto_id, cantidad) values
  ('01920000-0000-7000-8000-0000000149e1', '01920000-0000-7000-8000-0000000149c1', '01920000-0000-7000-8000-0000000149a1', 2),
  ('01920000-0000-7000-8000-0000000149e2', '01920000-0000-7000-8000-0000000149c2', '01920000-0000-7000-8000-0000000149a3', 1);

insert into public.movimiento_stock (id, usuario_id, producto_id, tipo, cantidad) values
  ('01920000-0000-7000-8000-0000000149f1', '01920000-0000-7000-8000-0000000149b1',
   '01920000-0000-7000-8000-0000000149a1', 'ENTRADA_PEDIDO', 5);

-- La foto de antes: las filas enteras.
create table public.prueba_0149_producto as
select * from public.producto where id::text like '01920000-0000-7000-8000-0000000149a%';
create table public.prueba_0149_transferencia as
select * from public.transferencia_stock where id::text like '01920000-0000-7000-8000-0000000149c%';
create table public.prueba_0149_item as
select * from public.transferencia_item where id::text like '01920000-0000-7000-8000-0000000149e%';
create table public.prueba_0149_movimiento as
select * from public.movimiento_stock where id::text like '01920000-0000-7000-8000-0000000149f%';
create table public.prueba_0149_entidades as select count(*)::int as n from sync.entidad;
