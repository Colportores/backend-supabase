-- Datos con el esquema de 0167 para probar la 0168 (backend-supabase#243, «Variación semanal»): cada cuenta que ya existe
-- recibe una primera fila en el historial de la deuda con su deuda de hoy (no hay datos de antes y no se inventan), y a
-- partir de ahí cada cambio deja la suya. Ver scripts/db-test-migracion.sh.
--
-- Tres colportoras: b1 con una cuenta viva que debe 100000, b2 con la cuenta dada de baja (debía 777) y b3 sin cuenta.
-- La foto de antes queda en prueba_0168_cuenta de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000168b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion168-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000168b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion168-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000168b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion168-b3@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000168b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000168b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000168b3', 'COLPORTOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  ('01920000-0000-7000-8000-0000000168b1', 100000, 4000);
insert into public.cuenta_colportor (usuario_id, deuda_total, deleted_at) values
  ('01920000-0000-7000-8000-0000000168b2', 777, now());

-- La foto de antes: las filas enteras.
create table public.prueba_0168_cuenta as select * from public.cuenta_colportor;
