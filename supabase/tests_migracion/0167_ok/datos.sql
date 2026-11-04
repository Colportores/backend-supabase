-- Datos con el esquema de 0166 para probar la 0167 (backend-supabase#243, «Alq. baja»): las decisiones que ya había
-- (`TRASLADAR_A_LA_DEUDA`, `DEJAR_A_FAVOR`) se renombran a los nuevos destinos sin mover un centavo, y el coordinador
-- puede devolver lo pagado de quien tenía algo por decidir. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (c1) con la campaña E (Verano, alquiler 150000). Tres personas que se dieron de baja:
--   b1 pagó 70000 y el coordinador ya decidió 50000 a la deuda y 20000 a favor;
--   b2 pagó 30000 y se los quedó a favor;
--   b3 pagó 20000 y todavía no se decidió.
-- La foto de antes queda en prueba_0167_* de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000167b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion167-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000167b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion167-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000167b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion167-b3@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000167c1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion167-c1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000167b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000167b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000167b3', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000167c1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  ('01920000-0000-7000-8000-0000000167e1', 'Campaña 167 E', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000167c1', 150000);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000167e1', '01920000-0000-7000-8000-0000000167b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000167e1', '01920000-0000-7000-8000-0000000167b2', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000167e1', '01920000-0000-7000-8000-0000000167b3', now() - interval '10 days');

insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  ('01920000-0000-7000-8000-0000000167b1', 100000, 70000),
  ('01920000-0000-7000-8000-0000000167b2', 100000, 30000),
  ('01920000-0000-7000-8000-0000000167b3', 100000, 20000);

insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  ('01920000-0000-7000-8000-000000016721', '01920000-0000-7000-8000-0000000167b1', 70000, now() - interval '5 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000167e1', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000167c1'),
  ('01920000-0000-7000-8000-000000016722', '01920000-0000-7000-8000-0000000167b2', 30000, now() - interval '5 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000167e1', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000167c1'),
  ('01920000-0000-7000-8000-000000016723', '01920000-0000-7000-8000-0000000167b3', 20000, now() - interval '5 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000167e1', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000167c1');

-- Se dan de baja, con lo pagado: queda por decidir.
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = '01920000-0000-7000-8000-0000000167e1';

-- Lo que el coordinador ya decidió, con los nombres de antes (la 0159).
insert into public.alquiler_decision (id, usuario_id, campania_id, decision, monto, decidido_por, decidido_en) values
  ('01920000-0000-7000-8000-000000016731', '01920000-0000-7000-8000-0000000167b1', '01920000-0000-7000-8000-0000000167e1',
   'TRASLADAR_A_LA_DEUDA', 50000, '01920000-0000-7000-8000-0000000167c1', now() - interval '1 day'),
  ('01920000-0000-7000-8000-000000016732', '01920000-0000-7000-8000-0000000167b1', '01920000-0000-7000-8000-0000000167e1',
   'DEJAR_A_FAVOR', 20000, '01920000-0000-7000-8000-0000000167c1', now() - interval '1 day'),
  ('01920000-0000-7000-8000-000000016733', '01920000-0000-7000-8000-0000000167b2', '01920000-0000-7000-8000-0000000167e1',
   'DEJAR_A_FAVOR', 30000, '01920000-0000-7000-8000-0000000167c1', now() - interval '1 day');
-- La cuenta al día con lo decidido: b1 le baja 50000 a su deuda.
select public.refrescar_cuenta_alquiler('01920000-0000-7000-8000-0000000167e1', null);

-- La foto de antes: las filas enteras.
create table public.prueba_0167_decision         as select * from public.alquiler_decision;
create table public.prueba_0167_cuenta_alquiler as select * from public.cuenta_alquiler;
create table public.prueba_0167_cuenta           as select * from public.cuenta_colportor;
create table public.prueba_0167_deposito         as select * from public.deposito;
