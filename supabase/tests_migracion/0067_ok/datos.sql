-- Datos con el esquema de 0066 (campania sin alquiler_monto; campania_colportor sin tipo_beca,
-- meta_monto_ces ni limite_pedido) para probar que 0067 solo suma las columnas, en null, sin tocar ninguna
-- fila ni su sincronización. Ver scripts/db-test-migracion.sh.
--
-- Dos campañas (una con coordinador, una terminada) y tres inscripciones: una con meta de libros, una sin
-- nada y una dada de baja. La foto de antes queda en prueba_0067_* de public: db-reset.sh las borra con el
-- resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000067a1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion67-a1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000067b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion67-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000067b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion67-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000067b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion67-b3@example.com', 'x', now(), now(), now());

insert into public.usuario_rol (usuario_id, rol_id)
select '01920000-0000-7000-8000-0000000067a1', r.id from public.rol r where r.codigo = 'COORDINADOR';

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000067e1', 'Verano 67', 'VERANO', '2026-01-05', '2026-12-20',
   '01920000-0000-7000-8000-0000000067a1'),
  ('01920000-0000-7000-8000-0000000067e2', 'Invierno 67', 'INVIERNO', '2025-06-01', '2025-08-30', null);

insert into public.campania_colportor (id, campania_id, usuario_id, zona_id, meta_libros, deleted_at) values
  ('01920000-0000-7000-8000-0000000067c1', '01920000-0000-7000-8000-0000000067e1',
   '01920000-0000-7000-8000-0000000067b1', null, 120, null),
  ('01920000-0000-7000-8000-0000000067c2', '01920000-0000-7000-8000-0000000067e1',
   '01920000-0000-7000-8000-0000000067b2', null, null, null),
  ('01920000-0000-7000-8000-0000000067c3', '01920000-0000-7000-8000-0000000067e2',
   '01920000-0000-7000-8000-0000000067b3', null, 60, '2025-07-01 10:00:00+00');

-- La foto de antes: las filas enteras.
create table public.prueba_0067_campania as
select * from public.campania where id::text like '01920000-0000-7000-8000-0000000067%';
create table public.prueba_0067_campania_colportor as
select * from public.campania_colportor where id::text like '01920000-0000-7000-8000-0000000067%';
