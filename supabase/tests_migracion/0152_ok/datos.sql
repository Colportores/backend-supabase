-- Datos con el esquema de 0150 (todavía existe deposito_cobro, el alquiler pagado de más queda «a favor» y el depósito no
-- tiene rechazo) para probar la 0152 (backend-supabase#220): se va la tabla de vínculos sin perder ningún cobro ni
-- depósito; el alquiler pagado de más de antes se traslada a la deuda con la casa editora (una vez, sin duplicar); y
-- «en mano» sale de lo cobrado en efectivo menos lo depositado. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (c1) con la campaña E (Verano, alquiler 150000). Colportoras: b1 (en E con 200000 de alquiler validado:
-- 50000 de más; 150000, 50000 y 100000 cobrados en efectivo; un retiro de casa editora de 30000 que incluía el primer cobro; debe
-- 100000), b2 (en E, dada de baja, con 70000 validados; debe 10000) y b3 (en E, sin pagos; debe 5000). Un ADMIN (ad).
-- La foto de antes queda en prueba_0152_* de public: db-reset.sh la borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
values
  ('01920000-0000-7000-8000-0000000152b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion152-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000152b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion152-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000152b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion152-b3@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000152c1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion152-c1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000152ad', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion152-ad@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000152b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000152b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000152b3', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000152c1', 'COORDINADOR'),
               ('01920000-0000-7000-8000-0000000152ad', 'ADMIN')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id, alquiler_monto) values
  ('01920000-0000-7000-8000-0000000152e1', 'Campaña 152 E', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000152c1', 150000);
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000152e1', '01920000-0000-7000-8000-0000000152b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000152e1', '01920000-0000-7000-8000-0000000152b2', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000152e1', '01920000-0000-7000-8000-0000000152b3', now() - interval '10 days');
update public.campania_colportor set deleted_at = now() - interval '2 days'
 where campania_id = '01920000-0000-7000-8000-0000000152e1' and usuario_id = '01920000-0000-7000-8000-0000000152b2';

-- La plata de antes.
insert into public.cuenta_colportor (usuario_id, deuda_total, dinero_depositado) values
  ('01920000-0000-7000-8000-0000000152b1', 100000, 200000),
  ('01920000-0000-7000-8000-0000000152b2', 10000, 70000),
  ('01920000-0000-7000-8000-0000000152b3', 5000, 0);

-- Una venta de b1 con tres cobros en efectivo.
insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000152f0', 'Pais mig152', 'ZU');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro)
values ('01920000-0000-7000-8000-0000000152f1', 'Ciudad mig152', 'Departamento de prueba',
        '01920000-0000-7000-8000-0000000152f0', -34.90, -56.20);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by)
values ('01920000-0000-7000-8000-0000000152a7', 'CASA', 'Av. Italia', '152', -34.900, -56.200,
        '01920000-0000-7000-8000-0000000152f1', '01920000-0000-7000-8000-0000000152b1');
insert into public.espacio (id, ubicacion_id, created_by)
values ('01920000-0000-7000-8000-0000000152f3', '01920000-0000-7000-8000-0000000152a7',
        '01920000-0000-7000-8000-0000000152b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by)
values ('01920000-0000-7000-8000-000000015251', '01920000-0000-7000-8000-0000000152f3',
        '01920000-0000-7000-8000-0000000152f5', '01920000-0000-7000-8000-0000000152b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by)
values ('01920000-0000-7000-8000-000000015271', '01920000-0000-7000-8000-000000015251', 'T-1152', 900000, now(),
        '01920000-0000-7000-8000-0000000152b1', '01920000-0000-7000-8000-0000000152b1');
insert into public.cobranza (id, venta_id, monto, medio, fecha, created_by) values
  ('01920000-0000-7000-8000-0000000152a1', '01920000-0000-7000-8000-000000015271', 150000, 'EFECTIVO', now(),
   '01920000-0000-7000-8000-0000000152b1'),
  ('01920000-0000-7000-8000-0000000152a2', '01920000-0000-7000-8000-000000015271', 50000, 'EFECTIVO', now(),
   '01920000-0000-7000-8000-0000000152b1'),
  ('01920000-0000-7000-8000-0000000152a3', '01920000-0000-7000-8000-000000015271', 100000, 'EFECTIVO', now(),
   '01920000-0000-7000-8000-0000000152b1');

-- Depósitos: b1 pagó 200000 de alquiler (validado) y depositó 30000 de casa editora (retiro por confirmar) que incluía el
-- primer cobro; b2 pagó 70000 (validado) y se dio de baja.
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id, validado_en, validado_por) values
  ('01920000-0000-7000-8000-000000015221', '01920000-0000-7000-8000-0000000152b1', 200000, now() - interval '3 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000152e1', now() - interval '2 days',
   '01920000-0000-7000-8000-0000000152c1'),
  ('01920000-0000-7000-8000-000000015222', '01920000-0000-7000-8000-0000000152b2', 70000, now() - interval '5 days',
   null, 'RETIRO_COORDINADOR', 'ALQUILER', '01920000-0000-7000-8000-0000000152e1', now() - interval '4 days',
   '01920000-0000-7000-8000-0000000152c1');
insert into public.deposito (id, colportor_id, monto, fecha, ticket_id, destino, concepto, campania_id) values
  ('01920000-0000-7000-8000-000000015223', '01920000-0000-7000-8000-0000000152b1', 30000, now() - interval '1 day',
   null, 'RETIRO_COORDINADOR', 'CASA_EDITORA', null);
insert into public.deposito_cobro (id, deposito_id, cobranza_id, colportor_id) values
  ('01920000-0000-7000-8000-000000015231', '01920000-0000-7000-8000-000000015223',
   '01920000-0000-7000-8000-0000000152a1', '01920000-0000-7000-8000-0000000152b1');

-- La foto de antes: las filas enteras.
create table public.prueba_0152_deposito as select * from public.deposito;
create table public.prueba_0152_cobranza as select * from public.cobranza;
create table public.prueba_0152_cuenta   as select * from public.cuenta_colportor;
create table public.prueba_0152_inscripcion as select * from public.campania_colportor;
