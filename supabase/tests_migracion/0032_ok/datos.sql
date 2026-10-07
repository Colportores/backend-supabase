-- Datos con el esquema de 0031 (sin ubicacion_par_decidido) para probar que 0032 solo suma: la tabla, su
-- registro en sync.entidad y la función de R21, sin tocar una fila de lo que ya había. Ver
-- scripts/db-test-migracion.sh.
--
-- Una ciudad con tres ubicaciones (una dada de baja), con sus versiones de sync ya movidas, y el registro
-- de sync.entidad tal como lo deja 0031. La foto de antes queda en prueba_0032_* de public: db-reset.sh
-- las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000032a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000032c1', 'Ciudad 32', '01920000-0000-7000-8000-0000000032a1', -34.9011, -56.1645, 13);
insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000032b1', 'CASA',   'Av. Italia',  '100', -34.9000, -56.2000, '01920000-0000-7000-8000-0000000032c1', null),
  ('01920000-0000-7000-8000-0000000032b2', 'CASA',   'Calle Dos',   '2',   -34.9050, -56.1950, '01920000-0000-7000-8000-0000000032c1', null),
  ('01920000-0000-7000-8000-0000000032b3', 'NEGOCIO','Calle Tres',  '3',   -34.9100, -56.1900, '01920000-0000-7000-8000-0000000032c1', '2026-09-01 10:00:00+00');
-- Una corrección sobre una de ellas: sync_version 1 y un xmin_w propio.
update public.ubicacion set numero = '2 bis' where id = '01920000-0000-7000-8000-0000000032b2';

-- La foto de antes: las filas enteras.
create table public.prueba_0032_ubicacion as select * from public.ubicacion;
create table public.prueba_0032_entidad   as select nombre, tabla::text as tabla, columna_pk, permite_push, columnas_servidor,
                                                    sigue_campanias, columna_duenio
                                               from sync.entidad;
