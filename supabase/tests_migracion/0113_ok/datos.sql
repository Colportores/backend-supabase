-- Datos con el esquema de 0111 (el ticket todavía no sube por push) para probar que 0113 solo suma: los tickets
-- que ya había, su depósito y el cobro que apunta a uno quedan idénticos (ni se enteran los teléfonos); la
-- entidad nueva entra a sync.entidad sin tocar las demás; y los tickets de antes se pueden leer en el historial del
-- coordinador y completar con su foto. Ver scripts/db-test-migracion.sh.
--
-- Una colportora (b1) inscripta en la campaña del coordinador (c1), con tres tickets: uno de tarjeta por validar
-- (a1), uno de depósito validado (a2) con su depósito, y uno rechazado (a3); y un cobro con tarjeta que apunta al
-- primero. La foto de antes queda en prueba_0113_* de public: db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000113a0', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000113c1', 'Ciudad 113', 'Departamento 113', '01920000-0000-7000-8000-0000000113a0', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000113b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion113-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000113d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion113-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000113b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000113d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000113e1', 'Campaña 113', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000113d1');
insert into public.campania_colportor (campania_id, usuario_id) values
  ('01920000-0000-7000-8000-0000000113e1', '01920000-0000-7000-8000-0000000113b1');

-- Los tickets de antes (los cargaba el servidor: todavía no subían del teléfono).
insert into public.ticket (id, usuario_id, tipo, subido_en, monto, fecha, numero_autorizacion, tarjeta_tipo, tarjeta_marca,
                           estado, revisado_por, revisado_en, motivo_rechazo) values
  ('01920000-0000-7000-8000-0000000113a1', '01920000-0000-7000-8000-0000000113b1', 'COBRO_TARJETA',
   now() - interval '3 days', 480000, now() - interval '3 days', '004512', 'DEBITO', 'VISA',
   'PENDIENTE', null, null, null),
  ('01920000-0000-7000-8000-0000000113a2', '01920000-0000-7000-8000-0000000113b1', 'DEPOSITO',
   now() - interval '5 days', 950000, now() - interval '5 days', null, null, null,
   'VALIDADO', '01920000-0000-7000-8000-0000000113d1', now() - interval '4 days', null),
  ('01920000-0000-7000-8000-0000000113a3', '01920000-0000-7000-8000-0000000113b1', 'COBRO_TARJETA',
   now() - interval '7 days', 90000, now() - interval '7 days', '000222', 'CREDITO', null,
   'RECHAZADO', '01920000-0000-7000-8000-0000000113d1', now() - interval '6 days', 'No se lee');
insert into public.deposito (id, colportor_id, monto, destino, concepto, ticket_id) values
  ('01920000-0000-7000-8000-0000000113f1', '01920000-0000-7000-8000-0000000113b1', 950000, 'BANCO', 'ALQUILER',
   '01920000-0000-7000-8000-0000000113a2');

-- Una venta y su cobro con tarjeta, que apunta al ticket por validar.
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000113f2', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000113c1', '01920000-0000-7000-8000-0000000113b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000113f3', '01920000-0000-7000-8000-0000000113f2', '01920000-0000-7000-8000-0000000113b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000113f4', '01920000-0000-7000-8000-0000000113f3',
   '01920000-0000-7000-8000-0000000113f5', '01920000-0000-7000-8000-0000000113b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000011301', '01920000-0000-7000-8000-0000000113f4', 'T-11301', 480000,
   now() - interval '3 days', '01920000-0000-7000-8000-0000000113b1', '01920000-0000-7000-8000-0000000113b1');
insert into public.cobranza (id, venta_id, monto, medio, fecha, numero_cuota, ticket_id, tarjeta_tipo, created_by) values
  ('01920000-0000-7000-8000-000000011331', '01920000-0000-7000-8000-000000011301', 480000, 'TARJETA',
   now() - interval '3 days', 1, '01920000-0000-7000-8000-0000000113a1', 'DEBITO', '01920000-0000-7000-8000-0000000113b1');

-- La foto de antes: las filas enteras y el registro de sync.
create table public.prueba_0113_ticket   as select * from public.ticket;
create table public.prueba_0113_deposito as select * from public.deposito;
create table public.prueba_0113_cobranza as select * from public.cobranza;
create table public.prueba_0113_venta    as select * from public.venta;
create table public.prueba_0113_entidad  as select nombre, tabla::text as tabla, columna_pk, permite_push, columnas_servidor,
                                                   sigue_campanias, columna_duenio
                                              from sync.entidad;
