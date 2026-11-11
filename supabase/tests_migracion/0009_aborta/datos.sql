-- Zonas de colportores que 0009 no puede pasar a la inscripción: tiene que abortar y nombrar
-- cada caso. Ver scripts/db-test-migracion.sh.
--   a1 zona directa Centro, sin inscripción en Verano
--   a2 zona directa Centro, pero su inscripción en Verano ya tiene Cordón
--   a3 zona directa Vieja (dada de baja), inscripción en Verano sin zona
--   a4 inscripción en Otra con Centro, que es de Verano
--   a5 zona directa Centro, con su inscripción en Verano dada de baja (otro qué hacer que a1)

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000091c0', 'Pais migración', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000091c1', 'Montevideo', '01920000-0000-7000-8000-0000000091c0', -34.90, -56.16);
insert into public.campania (id, nombre, tipo, fecha_inicio) values
  ('01920000-0000-7000-8000-0000000091e1', 'Verano', 'VERANO',     current_date - 10),
  ('01920000-0000-7000-8000-0000000091e2', 'Otra',   'PERMANENTE', current_date - 10);
insert into public.campania_ciudad (id, campania_id, ciudad_id) values
  ('01920000-0000-7000-8000-0000000091f1', '01920000-0000-7000-8000-0000000091e1', '01920000-0000-7000-8000-0000000091c1'),
  ('01920000-0000-7000-8000-0000000091f2', '01920000-0000-7000-8000-0000000091e2', '01920000-0000-7000-8000-0000000091c1');
insert into public.zona (id, nombre, campania_ciudad_id, tipo_forma, centro_lat, centro_lon, radio_m, deleted_at) values
  ('01920000-0000-7000-8000-0000000091d1', 'Centro', '01920000-0000-7000-8000-0000000091f1', 'RADIAL', -34.90, -56.18, 300, null),
  ('01920000-0000-7000-8000-0000000091d2', 'Cordón', '01920000-0000-7000-8000-0000000091f1', 'RADIAL', -34.90, -56.14, 300, null),
  ('01920000-0000-7000-8000-0000000091d3', 'Vieja',  '01920000-0000-7000-8000-0000000091f1', 'RADIAL', -34.90, -56.10, 300, now());

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at)
select ('01920000-0000-7000-8000-0000000091' || s)::uuid, '00000000-0000-0000-0000-000000000000',
       'authenticated', 'authenticated', 'mig9b-' || s || '@example.com', 'x', now(), now()
  from unnest(array['a1','a2','a3','a4','a5']) s;

update public.usuario u set nombre = x.nombre, apellido = x.apellido, zona_id = x.zona::uuid
  from (values ('a1', 'Uno',    'Sin inscripción', '01920000-0000-7000-8000-0000000091d1'),
               ('a2', 'Dos',    'Otra zona',       '01920000-0000-7000-8000-0000000091d1'),
               ('a3', 'Tres',   'Zona borrada',    '01920000-0000-7000-8000-0000000091d3'),
               ('a4', 'Cuatro', 'Otra campaña',    null),
               ('a5', 'Cinco',  'De baja',         '01920000-0000-7000-8000-0000000091d1')) x(s, nombre, apellido, zona)
 where u.id = ('01920000-0000-7000-8000-0000000091' || x.s)::uuid;

insert into public.campania_colportor (campania_id, usuario_id, zona_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000091e1', '01920000-0000-7000-8000-0000000091a2', '01920000-0000-7000-8000-0000000091d2', null),
  ('01920000-0000-7000-8000-0000000091e1', '01920000-0000-7000-8000-0000000091a3', null, null),
  ('01920000-0000-7000-8000-0000000091e2', '01920000-0000-7000-8000-0000000091a4', '01920000-0000-7000-8000-0000000091d1', null),
  ('01920000-0000-7000-8000-0000000091e1', '01920000-0000-7000-8000-0000000091a5', null, now());
