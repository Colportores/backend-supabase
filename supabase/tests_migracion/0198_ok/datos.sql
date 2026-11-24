-- Datos con el esquema de 0197 (la última antes de 0198) para probar que 0198 saca `producto.tipo` sin perder ni
-- cambiar nada de lo demás: cada producto sigue, con su categoría y todas sus columnas menos el tipo.
-- Ver scripts/db-test-migracion.sh. La foto de antes queda en prueba_0198_* de public: db-reset.sh la borra con el resto.
--
-- Productos: uno de cada categoría (con su tipo heredado, que es lo que se saca), uno bonificable que es revista y uno
-- dado de baja. Un colportor con stock de un producto y un pedido con una línea (las lecturas de después los miran).

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000198b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion198-b1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000198b1'::uuid, r.id from public.rol r where r.codigo = 'COLPORTOR';

insert into public.producto (id, nombre, categoria, es_bonificable, es_misionero, deleted_at) values
  ('01920000-0000-7000-8000-0000000198a1', 'Bonificable 198', 'BONIFICABLES', true,  false, null),
  ('01920000-0000-7000-8000-0000000198a2', 'Espiritual 198',   'ESPIRITUALES', false, false, null),
  ('01920000-0000-7000-8000-0000000198a3', 'Misionero 198',    'MISIONEROS',   false, true,  null),
  ('01920000-0000-7000-8000-0000000198a4', 'Revista 198',      'REVISTAS',     true,  false, null),
  ('01920000-0000-7000-8000-0000000198a5', 'Material 198',     'MATERIAL',     false, false, null),
  ('01920000-0000-7000-8000-0000000198a6', 'De baja 198',      'ESPIRITUALES', false, false, '2026-09-01 10:00:00+00');

insert into public.pedido_casa_editora (id, colportor_id, fecha_pedido, estado, origen) values
  ('01920000-0000-7000-8000-0000000198c1', '01920000-0000-7000-8000-0000000198b1', now() - interval '3 days', 'RECIBIDO', 'COLPORTOR');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario) values
  ('01920000-0000-7000-8000-0000000198e1', '01920000-0000-7000-8000-0000000198c1', '01920000-0000-7000-8000-0000000198a1', 4, 1500);

-- La foto de antes: las filas enteras.
create table public.prueba_0198_producto as
select * from public.producto where id::text like '01920000-0000-7000-8000-0000000198a%';
create table public.prueba_0198_pedido_item as
select * from public.pedido_item where id::text like '01920000-0000-7000-8000-0000000198e%';
