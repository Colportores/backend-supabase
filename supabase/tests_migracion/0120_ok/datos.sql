-- Datos con el esquema de 0119 (el límite de pedido es de cada inscripción) para probar que 0120 saca esa columna sin
-- tocar ninguna otra, suma campania.limite_deuda en null y no pierde ninguna campaña ni inscripción, la dada de baja
-- incluida. Ver scripts/db-test-migracion.sh.
--
-- Una coordinadora (d1) con dos campañas (c1 en curso, c2 que terminó) y tres colportores: b1 y b2 en c1 con un límite
-- de pedido cada uno, b3 en c2 dada de baja y con límite. b1 tiene una cuenta con deuda.
-- La foto de antes queda en prueba_0120_* de public: db-reset.sh las borra con el resto.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000120b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion120-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000120b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion120-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000120b3', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion120-b3@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000120d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion120-d1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000120b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000120b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000120b3', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000120d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000120c1', 'Campaña 120 en curso', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000120d1'),
  ('01920000-0000-7000-8000-0000000120c2', 'Campaña 120 vieja', 'VERANO', current_date - 120, current_date - 60,
   '01920000-0000-7000-8000-0000000120d1');
insert into public.campania_colportor (id, campania_id, usuario_id, meta_libros, created_at) values
  ('01920000-0000-7000-8000-0000000120e1', '01920000-0000-7000-8000-0000000120c1', '01920000-0000-7000-8000-0000000120b1', 120, now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000120e2', '01920000-0000-7000-8000-0000000120c1', '01920000-0000-7000-8000-0000000120b2', 80, now() - interval '9 days'),
  ('01920000-0000-7000-8000-0000000120e3', '01920000-0000-7000-8000-0000000120c2', '01920000-0000-7000-8000-0000000120b3', 60, now() - interval '100 days');
-- Los límites por colportor de antes (el servidor los carga) y la baja de b3.
update public.campania_colportor set limite_pedido = 2000000 where id = '01920000-0000-7000-8000-0000000120e1';
update public.campania_colportor set limite_pedido = 3500000 where id = '01920000-0000-7000-8000-0000000120e2';
update public.campania_colportor set limite_pedido = 1000000, deleted_at = now() - interval '70 days'
 where id = '01920000-0000-7000-8000-0000000120e3';
insert into public.cuenta_colportor (usuario_id, deuda_total) values ('01920000-0000-7000-8000-0000000120b1', 1800000);

-- La foto de antes.
create table public.prueba_0120_campania as select * from public.campania;
create table public.prueba_0120_campania_colportor as select * from public.campania_colportor;
create table public.prueba_0120_cuenta as select * from public.cuenta_colportor;
