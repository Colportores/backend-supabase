-- Datos con el esquema de 0116 (sin carreras, sin metas por carrera) para probar que 0117 solo suma las tablas
-- y la columna usuario.carrera_id, en null, sin tocar ninguna fila ni su sincronización, y que la beca que ya
-- tenía una inscripción (las columnas de 0067) se conserva. Ver scripts/db-test-migracion.sh.
--
-- Una campaña con coordinador (a1) y tres colportores: b1 con media beca ya cargada a mano (tipo, meta_libros y
-- meta_monto_ces), b2 sin beca y b3 con la inscripción dada de baja. La foto de antes queda en
-- prueba_0117_usuario y prueba_0117_inscripcion (db-reset.sh las borra con el resto).

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at)
select s.id::uuid, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'migracion117-' || s.n || '@example.com', 'x', now(), now(), now()
  from (values ('01920000-0000-7000-8000-0000000117a1', 'a1'), ('01920000-0000-7000-8000-0000000117b1', 'b1'),
               ('01920000-0000-7000-8000-0000000117b2', 'b2'), ('01920000-0000-7000-8000-0000000117b3', 'b3')) s(id, n);
update public.usuario set nombre = 'Mariela', apellido = 'Pereyra' where id = '01920000-0000-7000-8000-0000000117a1';
update public.usuario set nombre = 'Ana', apellido = 'Alfa' where id = '01920000-0000-7000-8000-0000000117b1';
update public.usuario set nombre = 'Beto', apellido = 'Bravo' where id = '01920000-0000-7000-8000-0000000117b2';
update public.usuario set nombre = 'Carla', apellido = 'Cruz' where id = '01920000-0000-7000-8000-0000000117b3';
insert into public.usuario_rol (usuario_id, rol_id)
select x.id::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000117a1', 'COORDINADOR'), ('01920000-0000-7000-8000-0000000117b1', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000117b2', 'COLPORTOR'), ('01920000-0000-7000-8000-0000000117b3', 'COLPORTOR')) x(id, codigo)
  join public.rol r on r.codigo = x.codigo;

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000117e1', 'Campaña 117', 'VERANO', current_date - 60, null,
   '01920000-0000-7000-8000-0000000117a1');
insert into public.campania_colportor (campania_id, usuario_id, created_at) values
  ('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b1', now() - interval '50 days'),
  ('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b2', now() - interval '50 days'),
  ('01920000-0000-7000-8000-0000000117e1', '01920000-0000-7000-8000-0000000117b3', now() - interval '50 days');
-- El servidor (postgres) deja la beca de b1 como la dejaría un alta a mano con las columnas de 0067, y da de baja a b3.
update public.campania_colportor
   set tipo_beca = 'MEDIA', meta_libros = 55, meta_monto_ces = 2750000
 where campania_id = '01920000-0000-7000-8000-0000000117e1' and usuario_id = '01920000-0000-7000-8000-0000000117b1';
update public.campania_colportor set deleted_at = now() - interval '5 days'
 where campania_id = '01920000-0000-7000-8000-0000000117e1' and usuario_id = '01920000-0000-7000-8000-0000000117b3';

-- La foto de antes: las filas enteras.
create table public.prueba_0117_usuario as select * from public.usuario;
create table public.prueba_0117_inscripcion as select * from public.campania_colportor;
