-- Datos con el esquema de 0126 (el depósito todavía no lleva validación) para probar que 0129 solo suma: los
-- depósitos de antes siguen todos, con sus datos; solo el que respaldaba un ticket VALIDADO pasa a estar validado
-- (con la fecha y el revisor del ticket) para que el alquiler pagado siga pagado; los demás (con el ticket
-- pendiente, rechazado, o un retiro sin ticket) quedan por validar. Y la coordinadora valida con el RPC un
-- ticket de antes. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (d1) con su campaña de alquiler 150000 y una colportora inscripta (b1) que debe 500000 a la
-- casa editora. Tres tickets de depósito (validado, pendiente, rechazado), cuatro depósitos de antes (los tres de
-- los tickets y un retiro de alquiler sin ticket) y un cuarto depósito de casa editora con el ticket pendiente.
-- La foto de antes queda en prueba_0129_* de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000129b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion127-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000129d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion127-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000129b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000129d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  ('01920000-0000-7000-8000-0000000129e1', 'Campaña 127', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000129d1', 150000);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000129e1', '01920000-0000-7000-8000-0000000129b1', now() - interval '10 days');
insert into public.cuenta_colportor (usuario_id, deuda_total) values
  ('01920000-0000-7000-8000-0000000129b1', 500000);

insert into public.ticket (id, usuario_id, tipo, monto, fecha, estado, motivo_rechazo, revisado_por, revisado_en) values
  ('01920000-0000-7000-8000-000000012911', '01920000-0000-7000-8000-0000000129b1', 'DEPOSITO', 50000,
   now() - interval '3 days', 'VALIDADO', null, '01920000-0000-7000-8000-0000000129d1', now() - interval '2 days'),
  ('01920000-0000-7000-8000-000000012912', '01920000-0000-7000-8000-0000000129b1', 'DEPOSITO', 30000,
   now() - interval '1 day', 'PENDIENTE', null, null, null),
  ('01920000-0000-7000-8000-000000012913', '01920000-0000-7000-8000-0000000129b1', 'DEPOSITO', 99000,
   now() - interval '1 day', 'RECHAZADO', 'No se lee el monto', '01920000-0000-7000-8000-0000000129d1', now()),
  ('01920000-0000-7000-8000-000000012914', '01920000-0000-7000-8000-0000000129b1', 'DEPOSITO', 70000,
   now(), 'PENDIENTE', null, null, null);

insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  ('01920000-0000-7000-8000-000000012921', '01920000-0000-7000-8000-0000000129b1', 50000, now() - interval '3 days',
   '01920000-0000-7000-8000-000000012911', 'BANCO', 'ALQUILER', '01920000-0000-7000-8000-0000000129e1'),
  ('01920000-0000-7000-8000-000000012922', '01920000-0000-7000-8000-0000000129b1', 30000, now() - interval '1 day',
   '01920000-0000-7000-8000-000000012912', 'BANCO', 'ALQUILER', '01920000-0000-7000-8000-0000000129e1'),
  ('01920000-0000-7000-8000-000000012923', '01920000-0000-7000-8000-0000000129b1', 99000, now() - interval '1 day',
   '01920000-0000-7000-8000-000000012913', 'BANCO', 'ALQUILER', '01920000-0000-7000-8000-0000000129e1'),
  ('01920000-0000-7000-8000-000000012924', '01920000-0000-7000-8000-0000000129b1', 20000, now() - interval '1 day',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000129e1'),
  ('01920000-0000-7000-8000-000000012925', '01920000-0000-7000-8000-0000000129b1', 70000, now(),
   '01920000-0000-7000-8000-000000012914', 'OFICINA', 'CASA_EDITORA', null);

-- La foto de antes: las filas enteras.
create table public.prueba_0129_deposito as select * from public.deposito;
create table public.prueba_0129_ticket   as select * from public.ticket;
create table public.prueba_0129_cuenta   as select * from public.cuenta_colportor;
