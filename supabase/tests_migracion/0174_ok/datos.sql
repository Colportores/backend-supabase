-- Datos con el esquema de 0173 para probar la 0174 (backend-supabase#254, «Coord. camp.»): el coordinador que cada campaña
-- guardaba en `campania.coordinador_id` pasa a la tabla `campania_coordinador` sin perderse, y las campañas quedan intactas.
-- Ver scripts/db-test-migracion.sh.
--
-- Dos coordinadores (c1, c2) y tres campañas: una de c1, una de c2 dada de baja, una sin coordinador.
-- La foto de antes queda en prueba_0174_campania de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
values
  ('01920000-0000-7000-8000-0000000174c1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion174-c1@example.com', 'x', now(), now(), now(),
   '{"nombre": "Luis", "apellido": "Pérez"}'),
  ('01920000-0000-7000-8000-0000000174c2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion174-c2@example.com', 'x', now(), now(), now(),
   '{"nombre": "Daniel", "apellido": "Ruiz"}');
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000174c1', 'COORDINADOR'),
               ('01920000-0000-7000-8000-0000000174c2', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, created_at, deleted_at) values
  ('01920000-0000-7000-8000-0000000174e1', 'Campaña 174 E1', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000174c1', now() - interval '20 days', null),
  ('01920000-0000-7000-8000-0000000174e2', 'Campaña 174 E2 (de baja)', 'INVIERNO', current_date - 100, current_date - 50,
   '01920000-0000-7000-8000-0000000174c2', now() - interval '120 days', now() - interval '40 days'),
  ('01920000-0000-7000-8000-0000000174e3', 'Campaña 174 E3 (sin coordinador)', 'PERMANENTE', current_date - 10, null,
   null, now() - interval '5 days', null);

-- La foto de antes: las filas enteras.
create table public.prueba_0174_campania as select * from public.campania;
