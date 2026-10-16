-- Datos con el esquema de 0034 (sin ubicacion_union ni espacio_union) para probar que 0035 solo suma:
-- tablas, funciones y triggers, y reemplaza marcar_como_duplicado, sin tocar una fila de lo que ya había
-- y sin perder nada si después se une un par con datos de antes. Ver scripts/db-test-migracion.sh.
--
-- Una ciudad con cuatro ubicaciones (la última dada de baja): A (e1) y B (e2) con su espacio único; la
-- persona 1 está en las dos, la persona 2 solo en B (con la casa B como cobranza alternativa); una
-- visita y una venta de la persona 1 en B, una agenda en A que nombra a B como casa alternativa, y una
-- decisión sobre el par (B, X). Todo con sus versiones de sync ya movidas. La foto de antes queda en
-- prueba_0035_* de public: db-reset.sh las borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000035a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000035c1', 'Ciudad 35', '01920000-0000-7000-8000-0000000035a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000035b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion35@example.com', 'x', now(), now(), now());

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-0000000035e1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000, '01920000-0000-7000-8000-0000000035c1', '01920000-0000-7000-8000-0000000035b1', null),
  ('01920000-0000-7000-8000-0000000035e2', 'CASA', 'Calle Dos',  '2',   -34.9050, -56.1950, '01920000-0000-7000-8000-0000000035c1', '01920000-0000-7000-8000-0000000035b1', null),
  ('01920000-0000-7000-8000-0000000035e3', 'CASA', 'Calle Tres', '3',   -34.9100, -56.1900, '01920000-0000-7000-8000-0000000035c1', '01920000-0000-7000-8000-0000000035b1', null),
  ('01920000-0000-7000-8000-0000000035e4', 'CASA', 'Calle Cuatro', '4', -34.9150, -56.1850, '01920000-0000-7000-8000-0000000035c1', '01920000-0000-7000-8000-0000000035b1', '2026-09-01 10:00:00+00');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000035f1', '01920000-0000-7000-8000-0000000035e1', '01920000-0000-7000-8000-0000000035b1'),
  ('01920000-0000-7000-8000-0000000035f2', '01920000-0000-7000-8000-0000000035e2', '01920000-0000-7000-8000-0000000035b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by, ubicacion_cobranza_alt_id) values
  ('01920000-0000-7000-8000-000000003501', '01920000-0000-7000-8000-0000000035f1', '01920000-0000-7000-8000-000000003591', '01920000-0000-7000-8000-0000000035b1', null),
  ('01920000-0000-7000-8000-000000003502', '01920000-0000-7000-8000-0000000035f2', '01920000-0000-7000-8000-000000003591', '01920000-0000-7000-8000-0000000035b1', null),
  ('01920000-0000-7000-8000-000000003503', '01920000-0000-7000-8000-0000000035f2', '01920000-0000-7000-8000-000000003592', '01920000-0000-7000-8000-0000000035b1',
   '01920000-0000-7000-8000-0000000035e2');
insert into public.visita (id, espacio_persona_id, fecha, tipo_resultado, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000003511', '01920000-0000-7000-8000-000000003502', now(), 'ENTREVISTA',
   '01920000-0000-7000-8000-0000000035b1', '01920000-0000-7000-8000-0000000035b1');
insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by) values
  ('01920000-0000-7000-8000-000000003521', '01920000-0000-7000-8000-000000003502', 'T-3521', 100000, now(),
   '01920000-0000-7000-8000-0000000035b1', '01920000-0000-7000-8000-0000000035b1');
insert into public.agenda (id, espacio_persona_id, tipo, fecha_programada, colportor_id, created_by, ubicacion_alt_id) values
  ('01920000-0000-7000-8000-000000003531', '01920000-0000-7000-8000-000000003501', 'ENTREVISTA', now(),
   '01920000-0000-7000-8000-0000000035b1', '01920000-0000-7000-8000-0000000035b1', '01920000-0000-7000-8000-0000000035e2');
insert into public.ubicacion_par_decidido (id, ubicacion_a_id, ubicacion_b_id, decision, decidido_en, created_by) values
  ('01920000-0000-7000-8000-000000003541', '01920000-0000-7000-8000-0000000035e2', '01920000-0000-7000-8000-0000000035e3',
   'CONSERVAR_AMBOS', '2026-10-04 10:00:00+00', '01920000-0000-7000-8000-0000000035b1');
-- Una corrección sobre una de ellas: sync_version 1 y un xmin_w propio.
update public.ubicacion set numero = '2 bis' where id = '01920000-0000-7000-8000-0000000035e2';

-- La foto de antes: las filas enteras.
create table public.prueba_0035_ubicacion as select * from public.ubicacion;
create table public.prueba_0035_espacio as select * from public.espacio;
create table public.prueba_0035_espacio_persona as select * from public.espacio_persona;
create table public.prueba_0035_visita as select * from public.visita;
create table public.prueba_0035_venta as select * from public.venta;
create table public.prueba_0035_agenda as select * from public.agenda;
create table public.prueba_0035_par as select * from public.ubicacion_par_decidido;
