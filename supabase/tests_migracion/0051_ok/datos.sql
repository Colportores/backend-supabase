-- Datos con el esquema de 0047 (la unión solo en la nube) para probar que 0051 solo toca a las B de las
-- uniones ya registradas, sin cambiar ningún valor, y no toca nada más. Ver scripts/db-test-migracion.sh.
--
-- Una ciudad con cuatro ubicaciones: A (e1), B (e2, ya dada de baja por unirse a A, con su registro en
-- ubicacion_union), C (e3, viva, sin unión) y D (e4, dada de baja común). La foto de antes queda en
-- prueba_0051_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000051a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000051c1', 'Ciudad 51', '01920000-0000-7000-8000-0000000051a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000051b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion51@example.com', 'x', now(), now(), now());

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-0000000051e1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000, '01920000-0000-7000-8000-0000000051c1', '01920000-0000-7000-8000-0000000051b1', null),
  ('01920000-0000-7000-8000-0000000051e2', 'CASA', 'Calle Dos',  '2',   -34.9050, -56.1950, '01920000-0000-7000-8000-0000000051c1', '01920000-0000-7000-8000-0000000051b1', '2026-10-10 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000051e3', 'CASA', 'Calle Tres', '3',   -34.9100, -56.1900, '01920000-0000-7000-8000-0000000051c1', '01920000-0000-7000-8000-0000000051b1', null),
  ('01920000-0000-7000-8000-0000000051e4', 'CASA', 'Calle Cuatro', '4', -34.9150, -56.1850, '01920000-0000-7000-8000-0000000051c1', '01920000-0000-7000-8000-0000000051b1', '2026-09-01 10:00:00+00');
-- La unión de B (e2) a A (e1), registrada como lo hace marcar_como_duplicado.
insert into public.ubicacion_union (id, duplicada_id, conservada_id, created_by) values
  ('01920000-0000-7000-8000-000000005161', '01920000-0000-7000-8000-0000000051e2',
   '01920000-0000-7000-8000-0000000051e1', '01920000-0000-7000-8000-0000000051b1');
-- Una corrección sobre la C: sync_version 1 y un xmin_w propio.
update public.ubicacion set numero = '3 bis' where id = '01920000-0000-7000-8000-0000000051e3';

-- La foto de antes: las filas enteras.
create table public.prueba_0051_ubicacion as select * from public.ubicacion;
create table public.prueba_0051_union as select * from public.ubicacion_union;
