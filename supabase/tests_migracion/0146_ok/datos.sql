-- Datos con el esquema de 0144 (el ticket todavía no dice quién lo valida) para probar que 0146 solo suma una
-- columna calculada: los tickets que ya había conservan todos sus datos; los vivos reciben una vez la campaña que los
-- valida (por la venta de su cobro o, sin cobro, por su fecha; nula = Administración) y su versión de sync sube para
-- que los teléfonos la bajen; el dado de baja no se toca. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (d1) con su campaña (e1) y una colportora (b1) inscripta hace 10 días. Siete tickets de b1:
--   a1 depósito de ayer, por validar            → e1 (por su fecha)
--   a2 depósito de hace 100 días, por validar   → nulo (su fecha no cae en ninguna inscripción)
--   a3 tarjeta de hoy, por validar, con un cobro de una venta de hace 100 días → nulo («Ticket libre»: manda la venta)
--   a4 tarjeta de hoy, por validar, con un cobro de una venta de ayer          → e1 (por la venta)
--   a5 depósito de ayer, VALIDADO               → e1 (también los resueltos: la columna no entra en TK001)
--   a6 depósito de ayer, RECHAZADO              → e1
--   a7 depósito de ayer, dado de baja           → queda sin calcular (nulo) y sin tocar
-- La foto de antes queda en prueba_0146_* de public: db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000146a0', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000146c1', 'Ciudad 146', 'Departamento 146', '01920000-0000-7000-8000-0000000146a0', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000146b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion146-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000146d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion146-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000146b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000146d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000146e1', 'Campaña 146', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000146d1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000146e1', '01920000-0000-7000-8000-0000000146b1', now() - interval '10 days');

insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, numero_autorizacion, tarjeta_tipo, tarjeta_marca,
                           estado, revisado_por, revisado_en, motivo_rechazo, deleted_at) values
  ('01920000-0000-7000-8000-0000000146a1', '01920000-0000-7000-8000-0000000146b1', 'DEPOSITO',
   now() - interval '1 day', 50000, now() - interval '1 day', null, null, null, 'PENDIENTE', null, null, null, null),
  ('01920000-0000-7000-8000-0000000146a2', '01920000-0000-7000-8000-0000000146b1', 'DEPOSITO',
   now() - interval '100 days', 30000, now() - interval '100 days', null, null, null, 'PENDIENTE', null, null, null, null),
  ('01920000-0000-7000-8000-0000000146a3', '01920000-0000-7000-8000-0000000146b1', 'COBRO_TARJETA',
   now(), 480000, now(), '004512', 'DEBITO', 'VISA', 'PENDIENTE', null, null, null, null),
  ('01920000-0000-7000-8000-0000000146a4', '01920000-0000-7000-8000-0000000146b1', 'COBRO_TARJETA',
   now(), 90000, now(), '004513', 'CREDITO', null, 'PENDIENTE', null, null, null, null),
  ('01920000-0000-7000-8000-0000000146a5', '01920000-0000-7000-8000-0000000146b1', 'DEPOSITO',
   now() - interval '1 day', 70000, now() - interval '1 day', null, null, null,
   'VALIDADO', '01920000-0000-7000-8000-0000000146d1', now() - interval '12 hours', null, null),
  ('01920000-0000-7000-8000-0000000146a6', '01920000-0000-7000-8000-0000000146b1', 'DEPOSITO',
   now() - interval '1 day', 99000, now() - interval '1 day', null, null, null,
   'RECHAZADO', '01920000-0000-7000-8000-0000000146d1', now() - interval '12 hours', 'No se lee el monto', null),
  ('01920000-0000-7000-8000-0000000146a7', '01920000-0000-7000-8000-0000000146b1', 'DEPOSITO',
   now() - interval '1 day', 11000, now() - interval '1 day', null, null, null, 'PENDIENTE', null, null, null, now());

-- Las ventas y los cobros con tarjeta que apuntan a los tickets a3 y a4.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000146f2', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000146c1', '01920000-0000-7000-8000-0000000146b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000146f3', '01920000-0000-7000-8000-0000000146f2', '01920000-0000-7000-8000-0000000146b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000146f4', '01920000-0000-7000-8000-0000000146f3',
   '01920000-0000-7000-8000-0000000146f5', '01920000-0000-7000-8000-0000000146b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000014671', '01920000-0000-7000-8000-0000000146f4', 'T-14671', 480000,
   now() - interval '100 days', '01920000-0000-7000-8000-0000000146b1', '01920000-0000-7000-8000-0000000146b1'),
  ('01920000-0000-7000-8000-000000014672', '01920000-0000-7000-8000-0000000146f4', 'T-14672', 90000,
   now() - interval '1 day', '01920000-0000-7000-8000-0000000146b1', '01920000-0000-7000-8000-0000000146b1');
insert into public.cobranza (id, venta_id, monto, medio, fecha, numero_cuota, ticket_id, tarjeta_tipo, created_by) values
  ('01920000-0000-7000-8000-000000014631', '01920000-0000-7000-8000-000000014671', 480000, 'TARJETA',
   now() - interval '1 hour', 1, '01920000-0000-7000-8000-0000000146a3', 'DEBITO', '01920000-0000-7000-8000-0000000146b1'),
  ('01920000-0000-7000-8000-000000014632', '01920000-0000-7000-8000-000000014672', 90000, 'TARJETA',
   now() - interval '1 hour', 1, '01920000-0000-7000-8000-0000000146a4', 'CREDITO', '01920000-0000-7000-8000-0000000146b1');

-- La foto de antes: las filas enteras.
create table public.prueba_0146_ticket   as select * from public.ticket;
create table public.prueba_0146_cobranza as select * from public.cobranza;
