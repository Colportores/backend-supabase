-- pgTAP · idempotencia de supabase/seed.sql (issue #16)
--
-- Corre el seed de ejemplo dos veces dentro de la misma transacción y verifica
-- que la segunda pasada no duplica filas ni lanza error: el `on conflict do
-- nothing` sin conflict_target de cada insert cubre tanto el conflicto por id
-- fijo como el anti-solape de precio_por_ciudad y de precio_general (constraint distinta del id, que
-- un `on conflict (id)` NO habría cubierto).
--
-- Todo en un `begin ... rollback`, como 0001-0003: no deja datos de ejemplo
-- para los demás archivos. En particular 0002_rls_test.sql asume el catálogo
-- vacío salvo su propio fixture (`count(*) from public.producto = 1`), así que
-- este seed nunca corre fuera de una transacción que se deshace.
--
-- Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
--
-- "Idempotente" acá es "no duplica ni falla", no "converge al contenido
-- actual del archivo": son conteos, no valores — si se edita un precio por id
-- ya existente y se re-siembra una base ya sembrada, la fila vieja queda tal
-- cual (ver cabecera de supabase/seed.sql).
begin;
select * from no_plan();

\i supabase/seed.sql

select is((select count(*) from public.pais),               1::bigint, 'primera pasada: 1 país');
select is((select count(*) from public.ciudad),              3::bigint, 'primera pasada: 3 ciudades (dos de ejemplo y Montevideo)');
select is((select count(*) from public.campania),            2::bigint, 'primera pasada: 2 campañas');
select is((select count(*) from public.zona),                4::bigint, 'primera pasada: 4 zonas');
select is((select count(*) from public.campania_ciudad),     3::bigint, 'primera pasada: 3 ciudades de campaña');
select is((select count(*) from public.zona_vertice),        8::bigint, 'primera pasada: 8 esquinas');
select is((select count(*) from public.producto),            5::bigint, 'primera pasada: 5 productos');
select is((select count(*) from public.coleccion),           2::bigint, 'primera pasada: 2 colecciones (una serie y el combo)');
select is((select count(*) from public.producto_coleccion),  4::bigint, 'primera pasada: 4 vínculos producto-colección');
select is((select count(*) from public.precio_por_ciudad),   7::bigint, 'primera pasada: 7 precios');
select is((select count(*) from public.precio_general),      7::bigint, 'primera pasada: 7 precios generales (5 productos y las 2 colecciones)');

-- Montevideo trae su rectángulo (0031); las dos ciudades de ejemplo no.
select is((select count(*) from public.ciudad where bbox_oeste is not null), 1::bigint,
          'solo Montevideo trae rectángulo');
select results_eq(
  $$ select bbox_oeste, bbox_sur, bbox_este, bbox_norte from public.ciudad where nombre = 'Montevideo' $$,
  $$ values (-56.433::float8, -34.945::float8, -55.948::float8, -34.701::float8) $$,
  'Montevideo: su rectángulo (oeste, sur, este, norte), el de la guía de carga manual');

-- El precio general (0034): ningún producto del seed queda sin uno, y public.precio_vigente() combina
-- general y modificado como dice la decisión de Cristian del 06/10 (el modificado vigente gana; si no
-- hay, rige el general). Libro A (producto 1) tiene precio propio en la ciudad de campaña 1 y no en la 3.
select is((select count(*) from public.producto p
            where not exists (select 1 from public.precio_general g
                               where g.producto_id = p.id and g.deleted_at is null)),
          0::bigint, 'todo producto del seed tiene precio general');
select results_eq(
  $$ select origen, precio_venta from public.precio_vigente(
       '09990000-0000-7000-8009-000000000001', '09990000-0000-7000-8005-000000000001') $$,
  $$ values ('MODIFICADO'::text, 25000) $$,
  'Libro A en la primera ciudad de campaña: vale el modificado');
select results_eq(
  $$ select origen, precio_venta from public.precio_vigente(
       '09990000-0000-7000-8009-000000000003', '09990000-0000-7000-8005-000000000001') $$,
  $$ values ('GENERAL'::text, 24000) $$,
  'Libro A en la tercera ciudad de campaña: sin modificado, vale el general');

-- El combo del seed (migración 0056): «Pack Familiar de Ejemplo» lleva 1 libro y 2 revistas, tiene su
-- propio general (36000, no la suma de sus partes) y una excepción en la segunda ciudad de campaña;
-- se vende como un solo ítem, así que public.precio_vigente() lo resuelve como a un producto.
select results_eq(
  $$ select p.nombre, pc.cantidad from public.producto_coleccion pc
       join public.producto p on p.id = pc.producto_id
      where pc.coleccion_id = '09990000-0000-7000-8006-000000000002' order by p.nombre $$,
  $$ values ('Libro de Ejemplo A'::text, 1), ('Revista de Ejemplo'::text, 2) $$,
  'el combo del seed lleva 1 libro y 2 revistas');
select results_eq(
  $$ select origen, precio_venta from public.precio_vigente(
       '09990000-0000-7000-8009-000000000001', null, '09990000-0000-7000-8006-000000000002') $$,
  $$ values ('GENERAL'::text, 36000) $$,
  'el combo en la primera ciudad de campaña: sin excepción, vale el general');
select results_eq(
  $$ select origen, precio_venta from public.precio_vigente(
       '09990000-0000-7000-8009-000000000002', null, '09990000-0000-7000-8006-000000000002') $$,
  $$ values ('MODIFICADO'::text, 38000) $$,
  'el combo en la segunda ciudad de campaña: vale la excepción');

-- Segunda pasada: mismo archivo, no debe duplicar ni fallar.
\i supabase/seed.sql

select is((select count(*) from public.pais),               1::bigint, 'segunda pasada: sigue en 1 país');
select is((select count(*) from public.ciudad),              3::bigint, 'segunda pasada: sigue en 3 ciudades');
select is((select count(*) from public.campania),            2::bigint, 'segunda pasada: sigue en 2 campañas');
select is((select count(*) from public.zona),                4::bigint, 'segunda pasada: sigue en 4 zonas');
select is((select count(*) from public.campania_ciudad),     3::bigint, 'segunda pasada: sigue en 3 ciudades de campaña');
select is((select count(*) from public.zona_vertice),        8::bigint, 'segunda pasada: sigue en 8 esquinas');
select is((select count(*) from public.producto),            5::bigint, 'segunda pasada: sigue en 5 productos');
select is((select count(*) from public.coleccion),           2::bigint, 'segunda pasada: sigue en 2 colecciones');
select is((select count(*) from public.producto_coleccion),  4::bigint, 'segunda pasada: sigue en 4 vínculos producto-colección');
select is((select count(*) from public.precio_por_ciudad),   7::bigint, 'segunda pasada: sigue en 7 precios');
select is((select count(*) from public.precio_general),      7::bigint, 'segunda pasada: sigue en 7 precios generales');

select * from finish();
rollback;
