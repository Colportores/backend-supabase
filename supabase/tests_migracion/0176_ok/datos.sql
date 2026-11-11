-- Datos con el esquema de 0175 para probar la 0176 (backend-supabase#254, «Dos acomp.»): el acompañante que cada jornada
-- guardaba en `jornada.acompaniante_id` pasa a la tabla `jornada_acompaniante` sin perderse (con quien lo cargó y la baja de la
-- jornada), el origen y la nota internos quedan con su acompañante, y las jornadas quedan intactas.
-- Ver scripts/db-test-migracion.sh.
--
-- Colportora b1 (Ana) con tres jornadas: f1 acompañada por b2 y cargada por el coordinador a1 (con nota), f2 acompañada por b2
-- sin quien cargó (la marcó ella), f3 sin acompañante; b2 tiene una jornada f4 dada de baja que ya tenía acompañante b1.
-- La foto de antes queda en prueba_0176_* de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at,
                        raw_user_meta_data)
values
  ('01920000-0000-7000-8000-0000000176a1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion176-a1@example.com', 'x', now(), now(), now(),
   '{"nombre": "Luis", "apellido": "Pérez"}'),
  ('01920000-0000-7000-8000-0000000176b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion176-b1@example.com', 'x', now(), now(), now(),
   '{"nombre": "Ana", "apellido": "Alfa"}'),
  ('01920000-0000-7000-8000-0000000176b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion176-b2@example.com', 'x', now(), now(), now(),
   '{"nombre": "Beto", "apellido": "Bravo"}');
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000176a1', 'COORDINADOR'),
               ('01920000-0000-7000-8000-0000000176b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000176b2', 'COLPORTOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id, acompaniamiento_cargado_por, created_at, deleted_at)
values
  ('01920000-0000-7000-8000-0000000176f1', '01920000-0000-7000-8000-0000000176b1', now() - interval '10 days',
   now() - interval '10 days' + interval '2 hours', '01920000-0000-7000-8000-0000000176b2',
   '01920000-0000-7000-8000-0000000176a1', now() - interval '10 days', null),
  ('01920000-0000-7000-8000-0000000176f2', '01920000-0000-7000-8000-0000000176b1', now() - interval '9 days',
   now() - interval '9 days' + interval '2 hours', '01920000-0000-7000-8000-0000000176b2',
   null, now() - interval '9 days', null),
  ('01920000-0000-7000-8000-0000000176f3', '01920000-0000-7000-8000-0000000176b1', now() - interval '8 days',
   now() - interval '8 days' + interval '2 hours', null, null, now() - interval '8 days', null),
  ('01920000-0000-7000-8000-0000000176f4', '01920000-0000-7000-8000-0000000176b2', now() - interval '7 days',
   now() - interval '7 days' + interval '2 hours', '01920000-0000-7000-8000-0000000176b1',
   null, now() - interval '7 days', now() - interval '6 days');

-- El origen y la nota de la 0133: f1 la anotó el coordinador con una nota; las demás quedan con el origen que les puso el trigger.
update public.jornada_acompaniamiento set origen = 'COORDINADOR', nota = 'Sector norte'
 where jornada_id = '01920000-0000-7000-8000-0000000176f1';

-- La foto de antes: las filas enteras.
create table public.prueba_0176_jornada as select * from public.jornada;
create table public.prueba_0176_detalle as select * from public.jornada_acompaniamiento;
