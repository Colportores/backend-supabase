-- Datos con el esquema de 0067 (agenda con PENDIENTE / COMPLETADA / CANCELADA, siempre con persona y sin
-- espacio, venta ni entrega; entrega sin fecha_prevista) para probar que 0068 renombra los estados, le
-- pone a cada cita el espacio de su vínculo y suma la fecha prevista de la entrega, sin perder ninguna
-- fila. Ver scripts/db-test-migracion.sh.
--
-- Una casa con dos espacios (un depto en cada uno), una persona en cada espacio, una venta y una entrega
-- pendiente y otra ya entregada. Cinco citas: PENDIENTE (con casa alternativa), COMPLETADA (con su
-- visita), CANCELADA, una PENDIENTE dada de baja y una COBRANZA PENDIENTE del otro depto. La foto de antes
-- queda en prueba_0068_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000068a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000068c1', 'Ciudad 68', 'Departamento 68', '01920000-0000-7000-8000-0000000068a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000068b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion68@example.com', 'x', now(), now(), now());

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000068e1', 'EDIFICIO', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000068c1', '01920000-0000-7000-8000-0000000068b1'),
  ('01920000-0000-7000-8000-0000000068e2', 'CASA', 'Calle Dos', '2', -34.9050, -56.1950,
   '01920000-0000-7000-8000-0000000068c1', '01920000-0000-7000-8000-0000000068b1');
insert into public.espacio (id, ubicacion_id, numero_depto, created_by) values
  ('01920000-0000-7000-8000-0000000068f1', '01920000-0000-7000-8000-0000000068e1', '1', '01920000-0000-7000-8000-0000000068b1'),
  ('01920000-0000-7000-8000-0000000068f2', '01920000-0000-7000-8000-0000000068e1', '2', '01920000-0000-7000-8000-0000000068b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-000000006801', '01920000-0000-7000-8000-0000000068f1', '01920000-0000-7000-8000-000000006891', '01920000-0000-7000-8000-0000000068b1'),
  ('01920000-0000-7000-8000-000000006802', '01920000-0000-7000-8000-0000000068f2', '01920000-0000-7000-8000-000000006892', '01920000-0000-7000-8000-0000000068b1');

insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000006811', '01920000-0000-7000-8000-000000006801', now(), 'ENTREVISTA',
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000006821', '01920000-0000-7000-8000-000000006801', 'T-6821', 100000, now(),
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1');
insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000006851', 'Libro 68', 'LIBRO');
insert into public.entrega (id, venta_id, producto_id, cantidad, fecha_entrega, pendiente, created_by) values
  ('01920000-0000-7000-8000-000000006861', '01920000-0000-7000-8000-000000006821', '01920000-0000-7000-8000-000000006851', 1,
   null, true, '01920000-0000-7000-8000-0000000068b1'),
  ('01920000-0000-7000-8000-000000006862', '01920000-0000-7000-8000-000000006821', '01920000-0000-7000-8000-000000006851', 2,
   '2026-09-01 15:00:00+00', false, '01920000-0000-7000-8000-0000000068b1');

insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, estado, colportor_id, created_by,
                           ubicacion_alt_id, visita_id, deleted_at) values
  ('01920000-0000-7000-8000-000000006831', '01920000-0000-7000-8000-000000006801', 'ENTREVISTA', '2026-11-02 14:00:00+00', 'PENDIENTE',
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068e2', null, null),
  ('01920000-0000-7000-8000-000000006832', '01920000-0000-7000-8000-000000006801', 'ENTREVISTA', '2026-10-01 14:00:00+00', 'COMPLETADA',
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1', null, '01920000-0000-7000-8000-000000006811', null),
  ('01920000-0000-7000-8000-000000006833', '01920000-0000-7000-8000-000000006802', 'COBRANZA', '2026-10-05 14:00:00+00', 'CANCELADA',
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1', null, null, null),
  ('01920000-0000-7000-8000-000000006834', '01920000-0000-7000-8000-000000006802', 'COBRANZA', '2026-10-06 14:00:00+00', 'PENDIENTE',
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1', null, null, '2026-10-07 10:00:00+00'),
  ('01920000-0000-7000-8000-000000006835', '01920000-0000-7000-8000-000000006802', 'COBRANZA', '2026-11-09 14:00:00+00', 'PENDIENTE',
   '01920000-0000-7000-8000-0000000068b1', '01920000-0000-7000-8000-0000000068b1', null, null, null);
-- Una corrección sobre una de ellas: sync_version 1 y un xmin_w propio.
update public.agenda set es_estricta = true where id = '01920000-0000-7000-8000-000000006835';

-- La foto de antes: las filas enteras.
create table public.prueba_0068_agenda as select * from public.agenda;
create table public.prueba_0068_entrega as select * from public.entrega;
