-- Datos con el esquema de 0188 para probar la 0190 (backend-supabase#266, P1): las fichas que la 0188 guardó como
-- llegaron pasan a solo dígitos, la que ya estaba en dígitos no se toca, y la dada de baja también se normaliza.
-- Ver scripts/db-test-migracion.sh.
--   d1  «4.567.890-1»      → 45678901
--   d2  «1234567»          → igual (no se actualiza: sync_version no sube)
--   d3  «1.234.567-8»      → 12345678 (la 0188 ya sacó los espacios de los extremos)
--   d4  «1.234.567», ficha dada de baja → 1234567
--   d5  sin cédula: sin ficha, sigue sin ficha.
-- La foto de antes queda en prueba_0190_ficha de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
values
  ('01920000-0000-7000-8000-0000000190d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d1@example.com', 'x', now(), now(), now(), '{"nombre": "Rocío", "apellido": "Alfa", "cedula": "4.567.890-1"}'),
  ('01920000-0000-7000-8000-0000000190d2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d2@example.com', 'x', now(), now(), now(), '{"nombre": "Beto", "apellido": "Bravo", "cedula": "1234567"}'),
  ('01920000-0000-7000-8000-0000000190d3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d3@example.com', 'x', now(), now(), now(), '{"nombre": "Ceci", "apellido": "Charlie", "cedula": " 1.234.567-8 "}'),
  ('01920000-0000-7000-8000-0000000190d4', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d4@example.com', 'x', now(), now(), now(), '{"nombre": "Dani", "apellido": "Delta", "cedula": "1.234.567"}'),
  ('01920000-0000-7000-8000-0000000190d5', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion189-d5@example.com', 'x', now(), now(), now(), '{"nombre": "Eva", "apellido": "Eco"}');

update public.ficha_administrativa set deleted_at = now() where usuario_id = '01920000-0000-7000-8000-0000000190d4';

create table public.prueba_0190_ficha as select * from public.ficha_administrativa;
