-- Datos con el esquema de 0188: fichas cuya cédula no queda en 7 u 8 dígitos. La 0190 aborta, no cambia nada y nombra
-- cada cuenta (sin la cédula: es dato personal). Ver scripts/db-test-migracion.sh.
--   d1  «4.567.890-1»: se normalizaría, no se lista.
--   d2  «abc12»: se lista.
--   d3  «123», ficha dada de baja: también se lista.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
values
  ('01920000-0000-7000-8000-0000000190d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d1@example.com', 'x', now(), now(), now(), '{"cedula": "4.567.890-1"}'),
  ('01920000-0000-7000-8000-0000000190d2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d2@example.com', 'x', now(), now(), now(), '{"cedula": "abc12"}'),
  ('01920000-0000-7000-8000-0000000190d3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d3@example.com', 'x', now(), now(), now(), '{"cedula": "123"}');

update public.ficha_administrativa set deleted_at = now() where usuario_id = '01920000-0000-7000-8000-0000000190d3';
