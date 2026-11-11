-- Datos con el esquema de 0124 (la transferencia todavía no tiene deuda, fecha de decisión ni motivo, y sus líneas
-- no guardan el costo) para probar que 0126 solo suma: las transferencias y las líneas que ya había quedan idénticas
-- (con su versión de sync y su xmin_w: ni se enteran los teléfonos) salvo una rechazada cargada a mano SIN motivo,
-- a la que la migración le deja «Sin motivo registrado» para que la regla nueva no la tire; el stock y las cuentas
-- no se tocan; y la coordinadora puede autorizar una de antes. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (d1) con su campaña y dos colportoras inscriptas (b1 da, b2 recibe). b1 tiene 5 unidades del
-- libro y una deuda de 3000. Tres transferencias de b1 a b2: una por autorizar (11), una rechazada sin motivo (12)
-- y una autorizada (13), cada una con su línea. La foto de antes queda en prueba_0126_* de public: db-reset.sh la
-- borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000125b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion125-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000125b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion125-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000125d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion125-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000125b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000125b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000125d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000125e1', 'Campaña 125', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000125d1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000125e1', '01920000-0000-7000-8000-0000000125b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000125e1', '01920000-0000-7000-8000-0000000125b2', now() - interval '10 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  ('01920000-0000-7000-8000-0000000125a1', 'Libro 125', 'LIBRO', 1000);

insert into public.stock (usuario_id, producto_id, cantidad_disponible) values
  ('01920000-0000-7000-8000-0000000125b1', '01920000-0000-7000-8000-0000000125a1', 5);
insert into public.cuenta_colportor (usuario_id, deuda_total) values
  ('01920000-0000-7000-8000-0000000125b1', 3000);

insert into public.transferencia_stock (id, origen_id, destino_id, estado, fecha_solicitud, coordinador_id) values
  ('01920000-0000-7000-8000-000000012511', '01920000-0000-7000-8000-0000000125b1',
   '01920000-0000-7000-8000-0000000125b2', 'PENDIENTE_AUTORIZACION', now() - interval '2 days', null),
  ('01920000-0000-7000-8000-000000012512', '01920000-0000-7000-8000-0000000125b1',
   '01920000-0000-7000-8000-0000000125b2', 'RECHAZADO', now() - interval '3 days', null),
  ('01920000-0000-7000-8000-000000012513', '01920000-0000-7000-8000-0000000125b1',
   '01920000-0000-7000-8000-0000000125b2', 'AUTORIZADO', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000125d1');
insert into public.transferencia_item (transferencia_id, producto_id, cantidad) values
  ('01920000-0000-7000-8000-000000012511', '01920000-0000-7000-8000-0000000125a1', 2),
  ('01920000-0000-7000-8000-000000012512', '01920000-0000-7000-8000-0000000125a1', 1),
  ('01920000-0000-7000-8000-000000012513', '01920000-0000-7000-8000-0000000125a1', 1);

-- La foto de antes: las filas enteras.
create table public.prueba_0126_transferencia as select * from public.transferencia_stock;
create table public.prueba_0126_item          as select * from public.transferencia_item;
create table public.prueba_0126_stock         as select * from public.stock;
create table public.prueba_0126_cuenta        as select * from public.cuenta_colportor;
