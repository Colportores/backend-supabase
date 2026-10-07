-- Datos con el esquema de 0030: DOS «Montevideo» vivas en Uruguay, las dos sin rectángulo. 0031 no
-- adivina cuál es la buena: no le carga el rectángulo a ninguna y no aborta (una base con una carga
-- duplicada tiene que poder migrar). El publicador de mapas se detiene, con el nombre de las dos, hasta
-- que se deje una sola. Ver scripts/db-test-migracion.sh.

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000031a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000031c1', 'Montevideo', '01920000-0000-7000-8000-0000000031a1', -34.9011, -56.1645),
  ('01920000-0000-7000-8000-0000000031c2', 'Montevideo', '01920000-0000-7000-8000-0000000031a1', -34.9100, -56.1700);

create table public.prueba_0031_ciudad as select * from public.ciudad;
