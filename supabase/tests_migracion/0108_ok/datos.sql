-- Datos con el esquema de 0107 (sin la tabla devolucion) para probar que 0108 solo suma: la venta, sus ítems y
-- su cobro quedan idénticos, y la tabla nueva nace vacía y guarda una devolución de una venta que ya existía.
-- Ver scripts/db-test-migracion.sh.
--
-- Una colportora con una venta de dos productos, un cobro, y otra venta dada de baja. La primera venta se
-- corrige una vez (sync_version 1 y un xmin_w propio). La foto de antes queda en prueba_0108_* de public:
-- db-reset.sh la borra con el resto.

insert into public.pais (id, nombre, iso_code) values
  ('01920000-0000-7000-8000-0000000108a1', 'Uruguay', 'UY');
insert into public.ciudad (id, nombre, departamento, pais_id, lat_centro, lon_centro, zoom_inicial) values
  ('01920000-0000-7000-8000-0000000108c1', 'Ciudad 108', 'Departamento 108', '01920000-0000-7000-8000-0000000108a1', -34.9011, -56.1645, 13);
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, confirmed_at, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000108b1', '00000000-0000-0000-0000-000000000000',
   'authenticated', 'authenticated', 'migracion108@example.com', 'x', now(), now(), now());

insert into public.producto (id, nombre, tipo) values
  ('01920000-0000-7000-8000-000000010811', 'Libro 1 m108', 'LIBRO'),
  ('01920000-0000-7000-8000-000000010812', 'Libro 2 m108', 'LIBRO');

insert into public.ubicacion (id, tipo, calle, numero, lat, lon, ciudad_id, created_by) values
  ('01920000-0000-7000-8000-0000000108f1', 'CASA', 'Av. Italia', '100', -34.9000, -56.2000,
   '01920000-0000-7000-8000-0000000108c1', '01920000-0000-7000-8000-0000000108b1');
insert into public.espacio (id, ubicacion_id, created_by) values
  ('01920000-0000-7000-8000-0000000108f2', '01920000-0000-7000-8000-0000000108f1', '01920000-0000-7000-8000-0000000108b1');
insert into public.espacio_persona (id, espacio_id, persona_id, created_by) values
  ('01920000-0000-7000-8000-0000000108f3', '01920000-0000-7000-8000-0000000108f2',
   '01920000-0000-7000-8000-0000000108f4', '01920000-0000-7000-8000-0000000108b1');

insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id, created_by, deleted_at) values
  ('01920000-0000-7000-8000-000000010801', '01920000-0000-7000-8000-0000000108f3', 'T-10801', 450000,
   '2026-10-01 15:00:00+00', '01920000-0000-7000-8000-0000000108b1', '01920000-0000-7000-8000-0000000108b1', null),
  ('01920000-0000-7000-8000-000000010802', '01920000-0000-7000-8000-0000000108f3', 'T-10802', 100000,
   '2026-10-02 15:00:00+00', '01920000-0000-7000-8000-0000000108b1', '01920000-0000-7000-8000-0000000108b1', now());
insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, created_by) values
  ('01920000-0000-7000-8000-000000010821', '01920000-0000-7000-8000-000000010801',
   '01920000-0000-7000-8000-000000010811', 2, 150000, 300000, '01920000-0000-7000-8000-0000000108b1'),
  ('01920000-0000-7000-8000-000000010822', '01920000-0000-7000-8000-000000010801',
   '01920000-0000-7000-8000-000000010812', 1, 150000, 150000, '01920000-0000-7000-8000-0000000108b1');
insert into public.cobranza (id, venta_id, monto, medio, fecha, numero_cuota, created_by) values
  ('01920000-0000-7000-8000-000000010831', '01920000-0000-7000-8000-000000010801', 250000, 'EFECTIVO',
   '2026-10-01 15:30:00+00', 1, '01920000-0000-7000-8000-0000000108b1');
-- Una corrección sobre la venta: sync_version 1 y un xmin_w propio.
update public.venta set monto_total = 460000 where id = '01920000-0000-7000-8000-000000010801';

-- La foto de antes: las filas enteras y el registro de sync.
create table public.prueba_0108_venta      as select * from public.venta;
create table public.prueba_0108_venta_item as select * from public.venta_item;
create table public.prueba_0108_cobranza   as select * from public.cobranza;
create table public.prueba_0108_entidad    as select nombre, tabla::text as tabla, columna_pk, permite_push, columnas_servidor,
                                                     sigue_campanias, columna_duenio
                                                from sync.entidad;
