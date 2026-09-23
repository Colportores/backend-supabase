-- pgTAP · idempotencia de supabase/seed.sql (issue #16)
--
-- Corre el seed de ejemplo dos veces dentro de la misma transacción y verifica
-- que la segunda pasada no duplica filas ni lanza error: el `on conflict do
-- nothing` sin conflict_target de cada insert cubre tanto el conflicto por id
-- fijo como el anti-solape de precio_por_zona (constraint distinta del id, que
-- un `on conflict (id)` NO habría cubierto).
--
-- Todo en un `begin ... rollback`, como 0001-0003: no deja datos de ejemplo
-- para los demás archivos. En particular 0002_rls_test.sql asume el catálogo
-- vacío salvo su propio fixture (`count(*) from public.producto = 1`), así que
-- este seed nunca corre fuera de una transacción que se deshace.
--
-- Requiere invocarse con cwd = raíz del repo (así lo hace scripts/db-test.sh).
begin;
select * from no_plan();

\i supabase/seed.sql

select is((select count(*) from public.pais),               1::bigint, 'primera pasada: 1 país');
select is((select count(*) from public.ciudad),              2::bigint, 'primera pasada: 2 ciudades');
select is((select count(*) from public.campania),            2::bigint, 'primera pasada: 2 campañas');
select is((select count(*) from public.zona),                3::bigint, 'primera pasada: 3 zonas');
select is((select count(*) from public.producto),            5::bigint, 'primera pasada: 5 productos');
select is((select count(*) from public.coleccion),           1::bigint, 'primera pasada: 1 colección');
select is((select count(*) from public.producto_coleccion),  2::bigint, 'primera pasada: 2 vínculos producto-colección');
select is((select count(*) from public.precio_por_zona),     6::bigint, 'primera pasada: 6 precios');

-- Segunda pasada: mismo archivo, no debe duplicar ni fallar.
\i supabase/seed.sql

select is((select count(*) from public.pais),               1::bigint, 'segunda pasada: sigue en 1 país');
select is((select count(*) from public.ciudad),              2::bigint, 'segunda pasada: sigue en 2 ciudades');
select is((select count(*) from public.campania),            2::bigint, 'segunda pasada: sigue en 2 campañas');
select is((select count(*) from public.zona),                3::bigint, 'segunda pasada: sigue en 3 zonas');
select is((select count(*) from public.producto),            5::bigint, 'segunda pasada: sigue en 5 productos');
select is((select count(*) from public.coleccion),           1::bigint, 'segunda pasada: sigue en 1 colección');
select is((select count(*) from public.producto_coleccion),  2::bigint, 'segunda pasada: sigue en 2 vínculos producto-colección');
select is((select count(*) from public.precio_por_zona),     6::bigint, 'segunda pasada: sigue en 6 precios');

select * from finish();
rollback;
