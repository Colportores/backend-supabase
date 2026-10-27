-- Datos con el esquema de 0120 (el depósito todavía no sube por push y no tiene vínculo con los cobros) para
-- probar que 0122 solo suma: el depósito que ya había, su ticket, los cobros y la venta quedan idénticos (ni se
-- enteran los teléfonos); las dos entidades nuevas entran a sync.entidad sin tocar las demás; la tabla de
-- vínculos nace vacía y se puede vincular un cobro de antes con un depósito de antes. Ver
-- scripts/db-test-migracion.sh.
--
-- Una colportora (b1) inscripta en la campaña del coordinador (c1), con un depósito de alquiler en el banco
-- (con su ticket de depósito validado), un cobro en efectivo, otro en efectivo que el depósito no incluye y un
-- cobro con tarjeta. La foto de antes queda en prueba_0122_* de public: db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000122a0', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000122c1', 'Ciudad 121', 'Departamento 121', '01920000-0000-7000-8000-0000000122a0', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000122b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion121-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000122d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion121-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000122b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000122d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000122e1', 'Campaña 121', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000122d1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000122e1', '01920000-0000-7000-8000-0000000122b1', now() - interval '10 days');

insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, estado, revisado_por, revisado_en) values
  ('01920000-0000-7000-8000-0000000122a1', '01920000-0000-7000-8000-0000000122b1', 'DEPOSITO',
   now() - interval '5 days', 950000, now() - interval '5 days', 'VALIDADO',
   '01920000-0000-7000-8000-0000000122d1', now() - interval '4 days');
insert into public.deposito (id, colportor_id, monto, destino, concepto, ticket_id, campania_id) values
  ('01920000-0000-7000-8000-0000000122f1', '01920000-0000-7000-8000-0000000122b1', 950000, 'BANCO', 'ALQUILER',
   '01920000-0000-7000-8000-0000000122a1', '01920000-0000-7000-8000-0000000122e1');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000122f2', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000122c1', '01920000-0000-7000-8000-0000000122b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000122f3', '01920000-0000-7000-8000-0000000122f2', '01920000-0000-7000-8000-0000000122b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000122f4', '01920000-0000-7000-8000-0000000122f3',
   '01920000-0000-7000-8000-0000000122f5', '01920000-0000-7000-8000-0000000122b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000012201', '01920000-0000-7000-8000-0000000122f4', 'T-12101', 950000,
   now() - interval '6 days', '01920000-0000-7000-8000-0000000122b1', '01920000-0000-7000-8000-0000000122b1');
insert into public.cobranza (id, venta_id, monto, medio, fecha, numero_cuota, created_by) values
  ('01920000-0000-7000-8000-000000012231', '01920000-0000-7000-8000-000000012201', 600000, 'EFECTIVO',
   now() - interval '6 days', 1, '01920000-0000-7000-8000-0000000122b1'),
  ('01920000-0000-7000-8000-000000012232', '01920000-0000-7000-8000-000000012201', 150000, 'EFECTIVO',
   now() - interval '5 days', 2, '01920000-0000-7000-8000-0000000122b1'),
  ('01920000-0000-7000-8000-000000012233', '01920000-0000-7000-8000-000000012201', 200000, 'TARJETA',
   now() - interval '5 days', 3, '01920000-0000-7000-8000-0000000122b1');

-- La foto de antes: las filas enteras y el registro de sync.
create table public.prueba_0122_deposito as select * from public.deposito;
create table public.prueba_0122_ticket   as select * from public.ticket;
create table public.prueba_0122_cobranza as select * from public.cobranza;
create table public.prueba_0122_venta    as select * from public.venta;
create table public.prueba_0122_entidad  as select nombre, tabla::text as tabla, columna_pk, permite_push, columnas_servidor,
                                                   sigue_campanias, columna_duenio
                                              from sync.entidad;
