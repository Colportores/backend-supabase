-- Datos con el esquema de 0144 (el stock existe pero no baja por el sync) para probar que 0145 solo suma: las
-- filas de stock que ya había quedan idénticas (con su versión de sync y su xmin_w: ni se enteran los teléfonos),
-- las entidades de antes quedan como estaban y la única nueva es `stock`; y después de migrar la colportora baja
-- por el pull el stock que ya tenía, y solo el suyo. Ver scripts/db-test-migracion.sh.
--
-- Dos colportoras (b1 y b2) de la campaña de un coordinador (d1): b1 con dos productos (uno en negativo, S46) y
-- b2 con uno. La foto de antes queda en prueba_0145_* de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000145b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion145-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000145b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion145-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000145d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion145-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000145b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000145b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000145d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000145e1', 'Campaña 145', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000145d1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000145e1', '01920000-0000-7000-8000-0000000145b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000145e1', '01920000-0000-7000-8000-0000000145b2', now() - interval '10 days');
insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-0000000145a1', 'Libro 1 145', 'LIBRO'),
  ('01920000-0000-7000-8000-0000000145a2', 'Libro 2 145', 'LIBRO');

insert into public.stock (id, usuario_id, producto_id, cantidad_disponible, cantidad_reservada) values
  ('01920000-0000-7000-8000-0000000145c1', '01920000-0000-7000-8000-0000000145b1', '01920000-0000-7000-8000-0000000145a1', 10, 2),
  ('01920000-0000-7000-8000-0000000145c2', '01920000-0000-7000-8000-0000000145b1', '01920000-0000-7000-8000-0000000145a2', -2, 0),
  ('01920000-0000-7000-8000-0000000145c3', '01920000-0000-7000-8000-0000000145b2', '01920000-0000-7000-8000-0000000145a1', 7, 0);

-- La foto de antes: las filas enteras y el registro de sync.
create table public.prueba_0145_stock   as select * from public.stock;
create table public.prueba_0145_entidad as select nombre, tabla::text as tabla, columna_pk, permite_push, columnas_servidor,
                                                  sigue_campanias, columna_duenio
                                             from sync.entidad;
