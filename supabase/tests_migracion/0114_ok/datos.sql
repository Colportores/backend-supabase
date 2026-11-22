-- Datos con el esquema de 0113 (el depósito todavía no lleva campaña) para probar que 0114 no pierde ningún
-- depósito y completa la campaña de los de ALQUILER: b1 está inscripta en una campaña en curso (c1) y b2 solo en
-- una que terminó hace 60 días (c2). Depósitos: f1 de b1, ALQUILER de hace 3 días (cae en la ventana de c1);
-- f2 de b2, ALQUILER de hace 5 días (ya no cae en ninguna ventana: se le asigna su inscripción más nueva, c2);
-- f3 de b1, CASA_EDITORA (no necesita campaña: queda como estaba). Ver scripts/db-test-migracion.sh.

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000114b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion114-b1@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000114b2', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion114-b2@example.com', 'x', now(), now(), now()),
  ('01920000-0000-7000-8000-0000000114d1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion114-d1@example.com', 'x', now(), now(), now());
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000114b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000114b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000114d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000114c1', 'Campaña 114 en curso', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000114d1'),
  ('01920000-0000-7000-8000-0000000114c2', 'Campaña 114 vieja', 'VERANO', current_date - 120, current_date - 60,
   '01920000-0000-7000-8000-0000000114d1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000114c1', '01920000-0000-7000-8000-0000000114b1', now() - interval '10 days'),
  ('01920000-0000-7000-8000-0000000114c2', '01920000-0000-7000-8000-0000000114b2', now() - interval '100 days');

insert into public.deposito (id, colportor_id, monto, fecha, destino, concepto) values
  ('01920000-0000-7000-8000-0000000114f1', '01920000-0000-7000-8000-0000000114b1', 150000,
   now() - interval '3 days', 'BANCO', 'ALQUILER'),
  ('01920000-0000-7000-8000-0000000114f2', '01920000-0000-7000-8000-0000000114b2', 90000,
   now() - interval '5 days', 'OFICINA', 'ALQUILER'),
  ('01920000-0000-7000-8000-0000000114f3', '01920000-0000-7000-8000-0000000114b1', 12000,
   now() - interval '2 days', 'BANCO', 'CASA_EDITORA');

-- La foto de antes.
create table public.prueba_0114_deposito as select * from public.deposito;
