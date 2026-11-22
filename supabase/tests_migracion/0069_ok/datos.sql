-- Datos con el esquema de 0068 (visita siempre con persona, sin espacio ni horas de entrevista, con los
-- cuatro resultados de antes) para probar que 0069 le pone a cada visita el espacio de su vínculo y suma
-- las columnas nuevas, sin perder ninguna fila. Ver scripts/db-test-migracion.sh.
--
-- Un edificio con dos deptos (una persona en cada uno) y cuatro visitas: ENTREVISTA y VENTA del depto 1
-- (la VENTA dada de baja), NO_CONTESTO y RECHAZO del depto 2, con una cita de agenda que cumplió la primera.
-- La foto de antes queda en prueba_0069_visita de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000069a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000069c1', 'Ciudad 69', 'Departamento 69', '01920000-0000-7000-8000-0000000069a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000069b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion69@example.com', 'x', now(), now(), now());

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000069e1', 'EDIFICIO', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000069c1', '01920000-0000-7000-8000-0000000069b1');
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  ('01920000-0000-7000-8000-0000000069f1', '01920000-0000-7000-8000-0000000069e1', '1', '01920000-0000-7000-8000-0000000069b1'),
  ('01920000-0000-7000-8000-0000000069f2', '01920000-0000-7000-8000-0000000069e1', '2', '01920000-0000-7000-8000-0000000069b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-000000006901', '01920000-0000-7000-8000-0000000069f1', '01920000-0000-7000-8000-000000006991', '01920000-0000-7000-8000-0000000069b1'),
  ('01920000-0000-7000-8000-000000006902', '01920000-0000-7000-8000-0000000069f2', '01920000-0000-7000-8000-000000006992', '01920000-0000-7000-8000-0000000069b1');

insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000006911', '01920000-0000-7000-8000-000000006901', '2026-10-20 14:00:00+00', 'ENTREVISTA',
   '01920000-0000-7000-8000-0000000069b1', '01920000-0000-7000-8000-0000000069b1', null),
  ('01920000-0000-7000-8000-000000006912', '01920000-0000-7000-8000-000000006901', '2026-10-21 14:00:00+00', 'VENTA',
   '01920000-0000-7000-8000-0000000069b1', '01920000-0000-7000-8000-0000000069b1', '2026-10-22 10:00:00+00'),
  ('01920000-0000-7000-8000-000000006913', '01920000-0000-7000-8000-000000006902', '2026-10-20 15:00:00+00', 'NO_CONTESTO',
   '01920000-0000-7000-8000-0000000069b1', '01920000-0000-7000-8000-0000000069b1', null),
  ('01920000-0000-7000-8000-000000006914', '01920000-0000-7000-8000-000000006902', '2026-10-22 15:00:00+00', 'RECHAZO',
   '01920000-0000-7000-8000-0000000069b1', '01920000-0000-7000-8000-0000000069b1', null);
insert into public.agenda (id, espacio_persona_id, espacio_id, tipo, fecha_programada, estado, colportor_id, created_by, visita_id) values
  ('01920000-0000-7000-8000-000000006931', '01920000-0000-7000-8000-000000006901', '01920000-0000-7000-8000-0000000069f1',
   'ENTREVISTA', '2026-10-20 14:00:00+00', 'CUMPLIDA',
   '01920000-0000-7000-8000-0000000069b1', '01920000-0000-7000-8000-0000000069b1', '01920000-0000-7000-8000-000000006911');
-- Una corrección sobre una: sync_version 1 y un xmin_w propio.
update public.visita set fecha = '2026-10-22 15:30:00+00' where id = '01920000-0000-7000-8000-000000006914';

-- La foto de antes: las filas enteras.
create table public.prueba_0069_visita as select * from public.visita;
