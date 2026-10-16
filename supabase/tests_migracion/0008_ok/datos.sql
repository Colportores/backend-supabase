-- Datos con el esquema de 0007 (campania.ciudad_id, zona.ciudad_id, zona.campania_id) para
-- probar que 0008 los migra sin perder nada. Ver scripts/db-test-migracion.sh.
--   d1 Centro       Verano, Montevideo (la ciudad de la campaña), con precio, inscripción y
--                   zona directa de un usuario
--   d2 Las Piedras  Verano, pero de Las Piedras: otra ciudad → fila nueva de campania_ciudad
--   d3 Centro       Verano, Montevideo, dada de baja: se superpone con d1 y repite el nombre,
--                   pero una baja no choca
--   d4 Otra         de Otra, una campaña dada de baja

insert into public.pais (id, nombre, iso_code) values ('01920000-0000-7000-8000-0000000080c0', 'Pais migración', 'ZX');
insert into public.ciudad (id, nombre, pais_id, lat_centro, lon_centro) values
  ('01920000-0000-7000-8000-0000000080c1', 'Montevideo', '01920000-0000-7000-8000-0000000080c0', -34.90, -56.16),
  ('01920000-0000-7000-8000-0000000080c2', 'Las Piedras', '01920000-0000-7000-8000-0000000080c0', -34.73, -56.22);

insert into public.campania (id, nombre, tipo, fecha_inicio, fecha_fin, ciudad_id, deleted_at) values
  ('01920000-0000-7000-8000-0000000080e1', 'Verano', 'VERANO', current_date - 10, current_date + 30,
   '01920000-0000-7000-8000-0000000080c1', null),
  ('01920000-0000-7000-8000-0000000080e2', 'Otra', 'PERMANENTE', current_date - 10, null,
   '01920000-0000-7000-8000-0000000080c2', now());

insert into public.zona (id, nombre, ciudad_id, campania_id, poligono_geojson, deleted_at) values
  ('01920000-0000-7000-8000-0000000080d1', 'Centro', '01920000-0000-7000-8000-0000000080c1',
   '01920000-0000-7000-8000-0000000080e1',
   '{"type":"Polygon","coordinates":[[[-56.17,-34.91],[-56.16,-34.91],[-56.16,-34.90],[-56.17,-34.90],[-56.17,-34.91]]]}', null),
  ('01920000-0000-7000-8000-0000000080d2', 'Las Piedras', '01920000-0000-7000-8000-0000000080c2',
   '01920000-0000-7000-8000-0000000080e1',
   '{"type":"Polygon","coordinates":[[[-56.23,-34.74],[-56.22,-34.74],[-56.22,-34.73],[-56.23,-34.74]]]}', null),
  ('01920000-0000-7000-8000-0000000080d3', 'Centro', '01920000-0000-7000-8000-0000000080c1',
   '01920000-0000-7000-8000-0000000080e1',
   '{"type":"Polygon","coordinates":[[[-56.165,-34.91],[-56.155,-34.91],[-56.155,-34.90],[-56.165,-34.90],[-56.165,-34.91]]]}', now()),
  ('01920000-0000-7000-8000-0000000080d4', 'Otra', '01920000-0000-7000-8000-0000000080c2',
   '01920000-0000-7000-8000-0000000080e2',
   '{"type":"Polygon","coordinates":[[[-56.23,-34.74],[-56.22,-34.74],[-56.22,-34.73],[-56.23,-34.74]]]}', null);

insert into public.producto (id, nombre, tipo) values ('01920000-0000-7000-8000-0000000080f1', 'Libro', 'LIBRO');
insert into public.precio_por_zona (producto_id, zona_id, precio_venta, valido_desde) values
  ('01920000-0000-7000-8000-0000000080f1', '01920000-0000-7000-8000-0000000080d1', 25000, '2026-01-01');

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('01920000-0000-7000-8000-0000000080a1', '00000000-0000-0000-0000-000000000000', 'authenticated',
   'authenticated', 'migracion@example.com', 'x', now(), now());
update public.usuario set zona_id = '01920000-0000-7000-8000-0000000080d1'
 where id = '01920000-0000-7000-8000-0000000080a1';
insert into public.campania_colportor (campania_id, usuario_id, zona_id) values
  ('01920000-0000-7000-8000-0000000080e1', '01920000-0000-7000-8000-0000000080a1', '01920000-0000-7000-8000-0000000080d1');
