-- Datos con el esquema de 0154 (el alquiler pagado de más, y todo lo pagado por quien se dio de baja, ya se trasladó
-- solo a la deuda con la casa editora) para probar la 0159 (backend-supabase#234, «Baja y alq.»): lo pagado de una baja
-- vuelve a la deuda y queda POR DECIDIR por el coordinador, sin perder un centavo; quien sigue inscripto en una campaña
-- que cobra conserva su traslado automático. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (c1) con la campaña E (Verano, alquiler 150000). b1 (en E, 200000 de alquiler validado: 50000 de más;
-- debe 100000) y b2 (en E, dada de baja, con 70000 validados; debe 10000). Un tercero, b3, sin pagos.
-- La foto de antes (ya con el traslado automático aplicado) queda en prueba_0159_* de public.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000159b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion159-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000159b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion159-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000159b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion159-b3@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000159c1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion159-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000159b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000159b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000159b3', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000159c1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  ('01920000-0000-7000-8000-0000000159e1', 'Campaña 159 E', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000159c1', 150000);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000159e1', '01920000-0000-7000-8000-0000000159b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000159e1', '01920000-0000-7000-8000-0000000159b2', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000159e1', '01920000-0000-7000-8000-0000000159b3', now() - interval '10 days');
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = '01920000-0000-7000-8000-0000000159e1' and usuario_id = '01920000-0000-7000-8000-0000000159b2';

insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  ('01920000-0000-7000-8000-0000000159b1', 100000, 200000),
  ('01920000-0000-7000-8000-0000000159b2', 10000, 70000),
  ('01920000-0000-7000-8000-0000000159b3', 5000, 0);

insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  ('01920000-0000-7000-8000-000000015921', '01920000-0000-7000-8000-0000000159b1', 200000, now() - interval '3 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000159e1', now() - interval '2 days',
   '01920000-0000-7000-8000-0000000159c1'),
  ('01920000-0000-7000-8000-000000015922', '01920000-0000-7000-8000-0000000159b2', 70000, now() - interval '5 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000159e1', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000159c1');

-- Con la lógica de antes, el traslado automático: b1 los 50000 de más, b2 todo lo pagado (70000).
select public.refrescar_cuenta_alquiler('01920000-0000-7000-8000-0000000159e1', '01920000-0000-7000-8000-0000000159b1');
select public.refrescar_cuenta_alquiler('01920000-0000-7000-8000-0000000159e1', '01920000-0000-7000-8000-0000000159b2');

-- La foto de antes: las filas enteras.
create table public.prueba_0159_deposito as select * from public.deposito;
create table public.prueba_0159_cuenta   as select * from public.cuenta_colportor;
create table public.prueba_0159_inscripcion as select * from public.campania_colportor;
