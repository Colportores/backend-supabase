-- Datos con el esquema de 0071 (cobranza sin datos de tarjeta ni de transferencia, sin anulación y sin
-- ticket_id) para probar que 0072 solo suma las columnas, en null, sin tocar ninguna fila ni su sincronización.
-- Ver scripts/db-test-migracion.sh.
--
-- Una colportora con una venta y cuatro cobros: en efectivo, con tarjeta, por transferencia y uno dado de
-- baja. El de efectivo se corrige una vez (sync_version 1 y un xmin_w propio). La foto de antes queda en
-- prueba_0072_cobranza de public: db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000072a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000072c1', 'Ciudad 72', 'Departamento 72', '01920000-0000-7000-8000-0000000072a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000072b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion72@example.com', 'x', now(), now(), now());

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000072f1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000072c1', '01920000-0000-7000-8000-0000000072b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000072f2', '01920000-0000-7000-8000-0000000072f1', '01920000-0000-7000-8000-0000000072b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000072f3', '01920000-0000-7000-8000-0000000072f2',
   '01920000-0000-7000-8000-0000000072f4', '01920000-0000-7000-8000-0000000072b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000007201', '01920000-0000-7000-8000-0000000072f3', 'T-7201', 270000,
   '2026-10-01 15:00:00+00', '01920000-0000-7000-8000-0000000072b1', '01920000-0000-7000-8000-0000000072b1');

insert into public.cobranza (id, venta_id, monto, medio, fecha, numero_cuota, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000007211', '01920000-0000-7000-8000-000000007201', 50000, 'EFECTIVO',
   '2026-10-01 15:30:00+00', 1, '01920000-0000-7000-8000-0000000072b1', null),
  ('01920000-0000-7000-8000-000000007212', '01920000-0000-7000-8000-000000007201', 120000, 'TARJETA',
   '2026-10-05 15:30:00+00', null, '01920000-0000-7000-8000-0000000072b1', null),
  ('01920000-0000-7000-8000-000000007213', '01920000-0000-7000-8000-000000007201', 80000, 'TRANSFERENCIA',
   '2026-10-08 15:30:00+00', null, '01920000-0000-7000-8000-0000000072b1', null),
  ('01920000-0000-7000-8000-000000007214', '01920000-0000-7000-8000-000000007201', 20000, 'EFECTIVO',
   '2026-10-09 15:30:00+00', null, '01920000-0000-7000-8000-0000000072b1', now());
-- Una corrección sobre el cobro en efectivo: sync_version 1 y un xmin_w propio.
update public.cobranza set monto = 55000 where id = '01920000-0000-7000-8000-000000007211';

-- La foto de antes: las filas enteras.
create table public.prueba_0072_cobranza as select * from public.cobranza;
