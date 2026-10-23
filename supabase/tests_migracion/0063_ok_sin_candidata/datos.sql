-- Datos con el esquema de 0059, el anterior a la 0063: una sola «Montevideo» viva en Uruguay, pero con el centro FUERA de la
-- caja de Montevideo (p. ej. cargada al revés o en otro lugar). 0063 no le carga el departamento: no
-- hay candidata segura. Una «Montevideo» dada de baja y una Montevideo de otro país tampoco cuentan.
-- Ver scripts/db-test-migracion.sh.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000048a1', 'Uruguay', 'UY'),
  ('01920000-0000-7000-8000-0000000048a2', 'Chile',   'CL');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, deleted_at) values
  ('01920000-0000-7000-8000-0000000048c1', 'Montevideo', '01920000-0000-7000-8000-0000000048a1', -31.0, -57.0, null),
  ('01920000-0000-7000-8000-0000000048c2', 'Montevideo', '01920000-0000-7000-8000-0000000048a1', -34.9011, -56.1645, '2026-05-01 10:00:00+00'),
  ('01920000-0000-7000-8000-0000000048c3', 'Montevideo', '01920000-0000-7000-8000-0000000048a2', -34.9011, -56.1645, null);

create table public.prueba_0063_ciudad as select * from public.ciudad;
