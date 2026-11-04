-- Datos con el esquema de 0168 para probar la 0169 (backend-supabase#243, «Tipo acomp.»): la jornada deja de guardar
-- `tipo_acompaniamiento` y todo lo demás de la jornada queda igual. Ver scripts/db-test-migracion.sh.
--
-- Una colportora con dos jornadas: una con el tipo de acompañamiento escrito y otra sin él, y una dada de baja.
-- La foto de antes queda en prueba_0169_jornada de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000169b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion169-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000169b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion169-b2@example.com', 'x', now(), now(), now());

insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id, tipo_acompaniamiento, total_visitas, total_ventas, deleted_at) values
  ('01920000-0000-7000-8000-000000016911', '01920000-0000-7000-8000-0000000169b1', '2026-10-01 12:00:00+00',
   '2026-10-01 18:00:00+00', '01920000-0000-7000-8000-0000000169b2', 'DE_PRUEBA', 12, 3, null),
  ('01920000-0000-7000-8000-000000016912', '01920000-0000-7000-8000-0000000169b1', '2026-10-02 12:00:00+00',
   null, null, null, 0, 0, null),
  ('01920000-0000-7000-8000-000000016913', '01920000-0000-7000-8000-0000000169b1', '2026-10-03 12:00:00+00',
   '2026-10-03 13:00:00+00', null, 'OTRO', 1, 0, now());

-- La foto de antes: las filas enteras.
create table public.prueba_0169_jornada as select * from public.jornada;
