-- Datos con el esquema de 0115 (jornada sin «quién cargó el acompañamiento») para probar que 0116 solo suma
-- la columna, en null, sin tocar ninguna fila ni su sincronización. Ver scripts/db-test-migracion.sh.
--
-- Una campaña con coordinador (a1), dos colportores (b1 y b2) y cuatro jornadas de b1: una acompañada por
-- el coordinador desde el panel (origen COORDINADOR y nota, de antes de la 0116), una que el colportor marcó
-- en el celular (origen COLPORTOR), una acompañada de antes de la 0100 (sin origen) y una sin acompañante,
-- todavía por completar. La foto de antes queda en prueba_0116_jornada (db-reset.sh la borra con el resto).

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select s.id::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'migracion116-' || s.n || '@example.com', 'x', now(), now(), now()
  from (values ('01920000-0000-7000-8000-0000000116a1', 'a1'), ('01920000-0000-7000-8000-0000000116b1', 'b1'),
               ('01920000-0000-7000-8000-0000000116b2', 'b2')) s(id, n);
update public.usuario set nombre = 'Mariela', apellido = 'Pereyra' where id = '01920000-0000-7000-8000-0000000116a1';
update public.usuario set nombre = 'Ana', apellido = 'Alfa' where id = '01920000-0000-7000-8000-0000000116b1';
update public.usuario set nombre = 'Beto', apellido = 'Bravo' where id = '01920000-0000-7000-8000-0000000116b2';
insert into public.usuario_rol (usuario_id, rol_id)
select x.id::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000116a1', 'COORDINADOR'), ('01920000-0000-7000-8000-0000000116b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000116b2', 'COLPORTOR')) x(id, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000116e1', 'Campaña 116', 'VERANO', current_date - 60, null,
   '01920000-0000-7000-8000-0000000116a1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000116e1', '01920000-0000-7000-8000-0000000116b1', now() - interval '50 days'),
  ('01920000-0000-7000-8000-0000000116e1', '01920000-0000-7000-8000-0000000116b2', now() - interval '50 days');

insert into public.jornada (id, colportor_id, inicio, fin, acompaniante_id) values
  ('01920000-0000-7000-8000-000000011601', '01920000-0000-7000-8000-0000000116b1',
   now() - interval '10 days', now() - interval '10 days' + interval '3 hours', '01920000-0000-7000-8000-0000000116a1'),
  ('01920000-0000-7000-8000-000000011602', '01920000-0000-7000-8000-0000000116b1',
   now() - interval '8 days', now() - interval '8 days' + interval '2 hours', '01920000-0000-7000-8000-0000000116b2'),
  ('01920000-0000-7000-8000-000000011603', '01920000-0000-7000-8000-0000000116b1',
   now() - interval '6 days', now() - interval '6 days' + interval '2 hours', '01920000-0000-7000-8000-0000000116a1'),
  ('01920000-0000-7000-8000-000000011604', '01920000-0000-7000-8000-0000000116b1',
   now() - interval '3 days', now() - interval '3 days' + interval '2 hours', null);
-- El servidor (postgres) fija el origen y la nota como los dejaría la 0100.
update public.jornada set acompaniamiento_origen = 'COORDINADOR', acompaniamiento_nota = 'Buena presentación'
 where id = '01920000-0000-7000-8000-000000011601';
update public.jornada set acompaniamiento_origen = 'COLPORTOR'
 where id = '01920000-0000-7000-8000-000000011602';

-- La foto de antes: las filas enteras.
create table public.prueba_0116_jornada as select * from public.jornada;
