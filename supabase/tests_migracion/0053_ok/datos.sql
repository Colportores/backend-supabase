-- Datos con el esquema de 0051 (usuario sin ultimo_push_at) para probar que 0053 solo suma la columna,
-- en null, sin tocar ninguna fila de usuario ni su sincronización. Ver scripts/db-test-migracion.sh.
--
-- Tres usuarios (el perfil lo crea el trigger de auth.users): uno con nombre y apellido cargados, uno con
-- el perfil recién creado y uno suspendido. La foto de antes queda en prueba_0053_usuario de public:
-- db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000053b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion53-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000053b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion53-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000053b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion53-b3@example.com', 'x', now(), now(), now());

update public.usuario set nombre = 'Ana', apellido = 'Alfa'
 where id = '01920000-0000-7000-8000-0000000053b1';
update public.usuario set suspendido_en = '2026-10-01 10:00:00+00'
 where id = '01920000-0000-7000-8000-0000000053b3';

-- La foto de antes: las filas enteras.
create table public.prueba_0053_usuario as
select * from public.usuario where id::text like '01920000-0000-7000-8000-0000000053%';
