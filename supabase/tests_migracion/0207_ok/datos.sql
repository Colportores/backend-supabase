-- Datos con el esquema de 0206 para probar la 0207 (preferencias de avisos por el sync) y la 0208 (compañeros de campaña): las
-- personas que ya existen reciben su fila de preferencias con lo que ya tenían guardado, y las inscripciones que ya existen (la
-- viva con zona, la viva sin zona y la dada de baja) pasan a campania_companiero sin tocar ninguna fila de las de antes.
-- Ver scripts/db-test-migracion.sh.
--
-- Tres colportores (b1 con preferencias guardadas, b2 sin ellas, b3 dado de baja de la campaña) y un coordinador, en una
-- campaña con una ciudad y una zona. La foto de antes queda en prueba_0207_usuario y prueba_0207_inscripcion de public:
-- db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000207a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000207c1', 'Ciudad 207', 'Departamento 207', '01920000-0000-7000-8000-0000000207a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at, raw_user_meta_data)
values
  ('01920000-0000-7000-8000-0000000207b1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion207b1@example.com', 'x', now(), now(), now(), '{"nombre": "Juan", "apellido": "Perez"}'),
  ('01920000-0000-7000-8000-0000000207b2', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion207b2@example.com', 'x', now(), now(), now(), '{"nombre": "Ana", "apellido": "Pereira"}'),
  ('01920000-0000-7000-8000-0000000207b3', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion207b3@example.com', 'x', now(), now(), now(), '{"nombre": "Bruno", "apellido": "Techera"}'),
  ('01920000-0000-7000-8000-0000000207d1', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
   'migracion207d1@example.com', 'x', now(), now(), now(), '{"nombre": "Luis", "apellido": "Ruiz"}');
insert into public.usuario_rol (usuario_id, rol_id)
select x.u::uuid, r.id
  from (values ('01920000-0000-7000-8000-0000000207b1', 'COLPORTOR'), ('01920000-0000-7000-8000-0000000207b2', 'COLPORTOR'),
               ('01920000-0000-7000-8000-0000000207b3', 'COLPORTOR'), ('01920000-0000-7000-8000-0000000207d1', 'COORDINADOR')) x(u, codigo)
  join public.rol r on r.codigo = x.codigo;
-- Juan ya guardó la hora de sus avisos (0166).
update public.usuario set notif_preferences = '{"hora_cuota": "10:30", "tickets": false}'
 where id = '01920000-0000-7000-8000-0000000207b1';

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, coordinador_id) values
  ('01920000-0000-7000-8000-0000000207e1', 'Verano 207', 'VERANO', public.hoy_montevideo() - 10, public.hoy_montevideo() + 30,
   '01920000-0000-7000-8000-0000000207d1');
insert into public.campania_ciudad (id, campania_id, ciudad_id)
values ('01920000-0000-7000-8000-0000000207f1', '01920000-0000-7000-8000-0000000207e1', '01920000-0000-7000-8000-0000000207c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, color, poligono_geojson) values
  ('01920000-0000-7000-8000-0000000207f2', 'Centro 207', '01920000-0000-7000-8000-0000000207f1', 'ESQUINAS', '#112233',
   '{"type":"Polygon","coordinates":[[[-56.19,-34.92],[-56.17,-34.92],[-56.17,-34.91],[-56.19,-34.91],[-56.19,-34.92]]]}'::jsonb);
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000207e1', '01920000-0000-7000-8000-0000000207b1', '01920000-0000-7000-8000-0000000207f2'),
  ('01920000-0000-7000-8000-0000000207e1', '01920000-0000-7000-8000-0000000207b2', null),
  ('01920000-0000-7000-8000-0000000207e1', '01920000-0000-7000-8000-0000000207b3', null);
update public.campania_colportor set deleted_at = now() - interval '1 day'
 where usuario_id = '01920000-0000-7000-8000-0000000207b3';

-- La foto de antes: las filas enteras.
create table public.prueba_0207_usuario as select * from public.usuario;
create table public.prueba_0207_inscripcion as select * from public.campania_colportor;
