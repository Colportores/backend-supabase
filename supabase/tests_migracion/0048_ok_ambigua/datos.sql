-- Datos con el esquema de 0047: DOS «Montevideo» vivas en Uruguay, las dos sin departamento. 0048 no
-- adivina cuál es la buena: no le carga el departamento a ninguna y no aborta (una base con una carga
-- duplicada tiene que poder migrar). Ver scripts/db-test-migracion.sh.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000048a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000048c1', 'Montevideo', '01920000-0000-7000-8000-0000000048a1', -34.9011, -56.1645),
  ('01920000-0000-7000-8000-0000000048c2', 'Montevideo', '01920000-0000-7000-8000-0000000048a1', -34.9100, -56.1700);

create table public.prueba_0048_ciudad as select * from public.ciudad;
