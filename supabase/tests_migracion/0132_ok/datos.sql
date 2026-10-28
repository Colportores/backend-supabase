-- Datos con el esquema de 0131 (todavía no existe cuenta_alquiler ni el límite de becas en una permanente) para
-- probar que 0132 solo suma: ninguna fila de antes cambia (ni su versión de sync), cada inscripción que ya había
-- tiene su fila de alquiler con la cuenta de siempre (quien estaba de baja ya no debe), una beca de antes en una
-- campaña permanente no se toca, y la corrección de carrera recalcula la meta. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (c1) con la campaña E (Verano, alquiler 150000) y la campaña P (permanente). Colportores:
-- b1 (en E con 50000 validados y 20000 por validar de alquiler, y en P con una beca de antes), b2 (en E, dada de
-- baja, con 70000 validados) y b3 (en E, sin pagos, con carrera y media beca). Y un ADMIN (ad).
-- La foto de antes queda en prueba_0132_* de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000132b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion132-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000132b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion132-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000132b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion132-b3@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000132c1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion132-c1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000132ad', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion132-ad@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000132b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000132b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000132b3', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000132c1', 'COORDINADOR'),
               ('01920000-0000-7000-8000-0000000132ad', 'ADMIN')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  ('01920000-0000-7000-8000-0000000132e1', 'Campaña 132 E', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000132c1', 150000),
  ('01920000-0000-7000-8000-0000000132e2', 'Campaña 132 P', 'PERMANENTE', current_date - 10, null,
   '01920000-0000-7000-8000-0000000132c1', null);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000132e1', '01920000-0000-7000-8000-0000000132b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000132e1', '01920000-0000-7000-8000-0000000132b2', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000132e1', '01920000-0000-7000-8000-0000000132b3', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000132e2', '01920000-0000-7000-8000-0000000132b1', now() - interval '10 days');
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = '01920000-0000-7000-8000-0000000132e1' and usuario_id = '01920000-0000-7000-8000-0000000132b2';

-- Becas de antes: b1 en la permanente (hoy ya no se podría asignar) y b3 con Teología y media beca.
insert into public.carrera (id, nombre) values
  ('01920000-0000-7000-8000-0000000132a1', 'Teología 132'),
  ('01920000-0000-7000-8000-0000000132a2', 'Sistemas 132');
insert into public.meta_beca (id, carrera_id, tipo_campania, meta_media, meta_completa, meta_media_monto, meta_completa_monto) values
  ('01920000-0000-7000-8000-0000000132f1', '01920000-0000-7000-8000-0000000132a1', 'VERANO', 60, 120, 3000000, 6000000),
  ('01920000-0000-7000-8000-0000000132f2', '01920000-0000-7000-8000-0000000132a2', 'VERANO', 10, 20, 500000, 1000000);
update public.usuario set carrera_id = '01920000-0000-7000-8000-0000000132a1'
 where id = '01920000-0000-7000-8000-0000000132b3';
update public.campania_colportor set tipo_beca = 'MEDIA', meta_libros = 60, meta_monto_ces = 3000000
 where campania_id = '01920000-0000-7000-8000-0000000132e2' and usuario_id = '01920000-0000-7000-8000-0000000132b1';
update public.campania_colportor set tipo_beca = 'MEDIA', meta_libros = 60, meta_monto_ces = 3000000
 where campania_id = '01920000-0000-7000-8000-0000000132e1' and usuario_id = '01920000-0000-7000-8000-0000000132b3';

-- Depósitos de alquiler de la campaña E: b1 pagó 50000 (validado) y tiene 20000 por validar; b2 pagó 70000 (validado)
-- y se dio de baja; b3 no pagó.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  ('01920000-0000-7000-8000-000000013221', '01920000-0000-7000-8000-0000000132b1', 50000, now() - interval '3 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000132e1', now() - interval '2 days',
   '01920000-0000-7000-8000-0000000132c1'),
  ('01920000-0000-7000-8000-000000013222', '01920000-0000-7000-8000-0000000132b2', 70000, now() - interval '5 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000132e1', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000132c1');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  ('01920000-0000-7000-8000-000000013223', '01920000-0000-7000-8000-0000000132b1', 20000, now() - interval '1 day',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000132e1');

-- La foto de antes: las filas enteras.
create table public.prueba_0132_inscripcion as select * from public.campania_colportor;
create table public.prueba_0132_deposito    as select * from public.deposito;
create table public.prueba_0132_campania    as select * from public.campania;
create table public.prueba_0132_usuario     as select * from public.usuario;
