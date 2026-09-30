-- Duplicados vivos que 0017 limpia sola: los que no tienen nada colgado quedan de baja. Ver
-- scripts/db-test-migracion.sh. En P0 = (-34.90, -56.20); 0,0001° de longitud ≈ 9,1 m.
--   a1/a2/a3  Av. Italia 100 con tildes, espacios y mayúsculas distintas. a2 está a ~50 m de a1:
--             duplicada, de baja. a3 está a ~146 m de a1 y a ~96 m de a2: como a2 sale, se queda.
--   a4/a5     Rivera 5 a ~10 m, cada una con su espacio único (sin departamento): a5 de baja.
--   a6/a7     Rivera 6 a ~150 m: se quedan las dos.
--   a8/a9     Rivera sin número a ~1 m: no participan.
--   aa/ab     Rivera 7 a ~1 m, pero aa ya estaba de baja: no se toca ninguna.
--   ac/ad     Rivera 8 en el mismo punto, de ciudades distintas: se quedan las dos.
--   ae/af     Rivera 9 a ~20 m: la primera en darse de alta es af (created_at), aunque su id
--             sea mayor; ae queda de baja.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000096c0', 'Pais migración 17', 'ZU');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000096c1', 'Montevideo', '01920000-0000-7000-8000-0000000096c0', -34.90, -56.20),
  ('01920000-0000-7000-8000-0000000096c2', 'Canelones',  '01920000-0000-7000-8000-0000000096c0', -34.52, -56.28);

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_at, deleted_at) values
  ('01920000-0000-7000-8000-0000000096a1', 'CASA', 'Av. Italia',  '100', -34.90, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-01', null),
  ('01920000-0000-7000-8000-0000000096a2', 'CASA', 'av.  itália', '100', -34.90, -56.19945,  '01920000-0000-7000-8000-0000000096c1', '2026-09-02', null),
  ('01920000-0000-7000-8000-0000000096a3', 'CASA', 'AV. ITALIA',  '100', -34.90, -56.19840,  '01920000-0000-7000-8000-0000000096c1', '2026-09-03', null),
  ('01920000-0000-7000-8000-0000000096a4', 'CASA', 'Rivera',      '5',   -34.91, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-01', null),
  ('01920000-0000-7000-8000-0000000096a5', 'CASA', 'rivera ',     ' 5',  -34.91, -56.19989,  '01920000-0000-7000-8000-0000000096c1', '2026-09-02', null),
  ('01920000-0000-7000-8000-0000000096a6', 'CASA', 'Rivera',      '6',   -34.92, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-01', null),
  ('01920000-0000-7000-8000-0000000096a7', 'CASA', 'Rivera',      '6',   -34.92, -56.19835,  '01920000-0000-7000-8000-0000000096c1', '2026-09-02', null),
  ('01920000-0000-7000-8000-0000000096a8', 'CASA', 'Rivera',      null,  -34.93, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-01', null),
  ('01920000-0000-7000-8000-0000000096a9', 'CASA', 'Rivera',      null,  -34.93, -56.199989, '01920000-0000-7000-8000-0000000096c1', '2026-09-02', null),
  ('01920000-0000-7000-8000-0000000096aa', 'CASA', 'Rivera',      '7',   -34.94, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-01', '2026-09-10'),
  ('01920000-0000-7000-8000-0000000096ab', 'CASA', 'Rivera',      '7',   -34.94, -56.199989, '01920000-0000-7000-8000-0000000096c1', '2026-09-02', null),
  ('01920000-0000-7000-8000-0000000096ac', 'CASA', 'Rivera',      '8',   -34.95, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-01', null),
  ('01920000-0000-7000-8000-0000000096ad', 'CASA', 'Rivera',      '8',   -34.95, -56.20,     '01920000-0000-7000-8000-0000000096c2', '2026-09-02', null),
  ('01920000-0000-7000-8000-0000000096ae', 'CASA', 'Rivera',      '9',   -34.96, -56.20,     '01920000-0000-7000-8000-0000000096c1', '2026-09-05', null),
  ('01920000-0000-7000-8000-0000000096af', 'CASA', 'Rivera',      '9',   -34.96, -56.19978,  '01920000-0000-7000-8000-0000000096c1', '2026-09-04', null);

insert into public.espacio (id, ubicacion_id) values
  ('01920000-0000-7000-8000-0000000096b4', '01920000-0000-7000-8000-0000000096a4'),
  ('01920000-0000-7000-8000-0000000096b5', '01920000-0000-7000-8000-0000000096a5');
