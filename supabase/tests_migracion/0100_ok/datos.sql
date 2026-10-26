-- Datos con el esquema de 0072 (jornada sin origen ni nota del acompañamiento, campania_colportor sin tramos
-- afuera) para probar que 0100 solo suma las columnas, en null y vacías, sin tocar ninguna fila ni su
-- sincronización. Ver scripts/db-test-migracion.sh.
--
-- Una campaña con coordinador (a1), tres colportores (b1 y b3 vivos, b2 dado de baja) y tres jornadas de b1:
-- una acompañada por el coordinador (de antes: sin origen), una acompañada por b2 y una sin acompañante, la
-- tercera todavía por completar. La foto de antes queda en prueba_0100_jornada y prueba_0100_inscripcion
-- (db-reset.sh las borra con el resto).

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000100f0', 'Uruguay', 'UY');
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select s.id::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'migracion100-' || s.n || '@example.com', 'x', now(), now(), now()
  from (values ('01920000-0000-7000-8000-0000000100a1', 'a1'), ('01920000-0000-7000-8000-0000000100b1', 'b1'),
               ('01920000-0000-7000-8000-0000000100b2', 'b2'), ('01920000-0000-7000-8000-0000000100b3', 'b3')) s(id, n);
insert into public.usuario_rol (usuario_id, rol_id)
select x.id::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000100a1', 'COORDINADOR'), ('01920000-0000-7000-8000-0000000100b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000100b2', 'COLPORTOR'), ('01920000-0000-7000-8000-0000000100b3', 'COLPORTOR')) x(id, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000100e1', 'Campaña 100', 'VERANO', current_date - 60, null,
   '01920000-0000-7000-8000-0000000100a1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000100e1', '01920000-0000-7000-8000-0000000100b1', now() - interval '50 days'),
  ('01920000-0000-7000-8000-0000000100e1', '01920000-0000-7000-8000-0000000100b2', now() - interval '50 days'),
  ('01920000-0000-7000-8000-0000000100e1', '01920000-0000-7000-8000-0000000100b3', now() - interval '50 days');
update public.campania_colportor set deleted_at = now() - interval '5 days'
 where usuario_id = '01920000-0000-7000-8000-0000000100b2';

insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id) values
  ('01920000-0000-7000-8000-000000010101', '01920000-0000-7000-8000-0000000100b1',
   now() - interval '10 days', now() - interval '10 days' + interval '3 hours', '01920000-0000-7000-8000-0000000100a1'),
  ('01920000-0000-7000-8000-000000010102', '01920000-0000-7000-8000-0000000100b1',
   now() - interval '8 days', now() - interval '8 days' + interval '2 hours', '01920000-0000-7000-8000-0000000100b2'),
  ('01920000-0000-7000-8000-000000010103', '01920000-0000-7000-8000-0000000100b1',
   now() - interval '3 days', now() - interval '3 days' + interval '2 hours', null);
-- Una corrección sobre la primera: sync_version 1 y un xmin_w propio.
update public.jornada set inicio = inicio + interval '5 minutes' where id = '01920000-0000-7000-8000-000000010101';

-- La foto de antes: las filas enteras.
create table public.prueba_0100_jornada as select * from public.jornada;
create table public.prueba_0100_inscripcion as select * from public.campania_colportor;
