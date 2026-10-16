-- Datos con el esquema de 0030: ninguna «Montevideo» que 0031 pueda completar. No carga nada y no aborta:
--   c1 Montevideo (UY) de baja                               → no
--   c2 Montevideo (UY) viva con el centro cargado al revés   → no: su centro queda fuera del rectángulo
--                                                              (el CHECK ciudad_bbox_contiene_centro_check
--                                                              lo rechazaría; la migración no lo intenta)
--   c3 Montevideo (CL), otro país                            → no
--   c4 Montevideo Este (UY)                                  → no: no es el mismo nombre
-- Ver scripts/db-test-migracion.sh.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000031a1', 'Uruguay', 'UY'),
  ('01920000-0000-7000-8000-0000000031a2', 'Chile',   'CL');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, deleted_at) values
  ('01920000-0000-7000-8000-0000000031c1', 'Montevideo',      '01920000-0000-7000-8000-0000000031a1', -34.9011, -56.1645, '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000031c2', 'Montevideo',      '01920000-0000-7000-8000-0000000031a1', -56.1645, -34.9011, null),
  ('01920000-0000-7000-8000-0000000031c3', 'Montevideo',      '01920000-0000-7000-8000-0000000031a2', -34.9011, -56.1645, null),
  ('01920000-0000-7000-8000-0000000031c4', 'Montevideo Este', '01920000-0000-7000-8000-0000000031a1', -34.9011, -56.1645, null);

create table public.prueba_0031_ciudad as select * from public.ciudad;
