-- Datos con el esquema de 0122 (los pedidos todavía no suben por push y la línea no tiene dueña propia) para
-- probar que 0124 solo suma: los pedidos y las líneas que ya había quedan idénticos (con su versión de sync y su
-- xmin_w: ni se enteran los teléfonos) salvo la dueña de la línea, que se completa desde el pedido; las dos
-- entidades nuevas entran a sync.entidad sin tocar las demás; y la colportora puede mandar un pedido nuevo. Ver
-- scripts/db-test-migracion.sh.
--
-- Una colportora (b1) inscripta en la campaña del coordinador (d1, límite de deuda 10000), con un pedido ya
-- autorizado y otro por autorizar, cada uno con su línea. La foto de antes queda en prueba_0124_* de public:
-- db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000123b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion123-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000123d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion123-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000123b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000123d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, limite_deuda) values
  ('01920000-0000-7000-8000-0000000123e1', 'Campaña 123', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000123d1', 10000);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000123e1', '01920000-0000-7000-8000-0000000123b1', now() - interval '10 days');
insert into public.producto (id, nombre, tipo, precio_base_compra) values
  ('01920000-0000-7000-8000-0000000123a1', 'Libro 123', 'LIBRO', 1000);

insert into public.pedido_casa_editora (id, colportor_id, estado, monto_total, origen, excede_limite, fecha_pedido) values
  ('01920000-0000-7000-8000-0000000123f1', '01920000-0000-7000-8000-0000000123b1', 'AUTORIZADO', 2000, 'COLPORTOR', false, now() - interval '3 days'),
  ('01920000-0000-7000-8000-0000000123f2', '01920000-0000-7000-8000-0000000123b1', 'PENDIENTE_AUTORIZACION', 5000, 'COLPORTOR', false, now() - interval '1 day');
insert into public.pedido_item (id, pedido_id, producto_id, cantidad, precio_unitario) values
  ('01920000-0000-7000-8000-0000000123c1', '01920000-0000-7000-8000-0000000123f1', '01920000-0000-7000-8000-0000000123a1', 2, 1000),
  ('01920000-0000-7000-8000-0000000123c2', '01920000-0000-7000-8000-0000000123f2', '01920000-0000-7000-8000-0000000123a1', 5, 1000);

-- La foto de antes: las filas enteras y el registro de sync.
create table public.prueba_0124_pedido  as select * from public.pedido_casa_editora;
create table public.prueba_0124_item    as select * from public.pedido_item;
create table public.prueba_0124_entidad as select nombre, tabla::text as tabla, columna_pk, permite_push, columnas_servidor,
                                                  sigue_campanias, columna_duenio
                                             from sync.entidad;
