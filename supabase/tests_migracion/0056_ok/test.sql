-- pgTAP · 0056 deja las ventas de antes con su producto y sin colección, y los componentes de las colecciones
-- de antes en 1 unidad, sin tocar ninguna otra columna ni la versión de sync de ninguna fila. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.venta_item), 2, 'los 2 ítems de la venta siguen: no se perdió ninguno');
select is((select count(*)::int from public.venta_item where coleccion_id is not null), 0,
          'ninguno apunta a una colección: eran de producto');
select is((select count(*)::int from public.venta_item where producto_id is null), 0,
          'y ninguno perdió su producto');
select is((select count(*)::int from public.venta_item i join public.prueba_0056_venta_item s using (id)
            where to_jsonb(i) - 'coleccion_id' is distinct from to_jsonb(s)), 0,
          'los ítems quedaron idénticos (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');

select is((select count(*)::int from public.producto_coleccion), 2, 'los 2 vínculos siguen (el vivo y el dado de baja)');
select is((select count(*)::int from public.producto_coleccion where cantidad = 1), 2, 'cada componente quedó en 1 unidad');
select is((select count(*)::int from public.producto_coleccion c join public.prueba_0056_producto_coleccion s using (id)
            where to_jsonb(c) - 'cantidad' is distinct from to_jsonb(s)), 0,
          'los vínculos quedaron idénticos (versión de sync, updated_at, xmin_w y baja incluidos) salvo la columna nueva');
select is((select deleted_at from public.producto_coleccion where id = '01920000-0000-7000-8000-0000000056a3'),
          '2026-09-01 10:00:00+00'::timestamptz, 'el vínculo dado de baja sigue dado de baja');

-- Lo nuevo anda sobre los datos de antes: el combo se vende con el mismo esquema, y la venta de antes no cambia.
select lives_ok(
  $$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-0000000056f4', '01920000-0000-7000-8000-0000000056f1',
             '01920000-0000-7000-8000-0000000056d0', 1, 30000, 30000) $$,
  'la colección de antes se vende como un ítem');
select is((select count(*)::int from public.venta_item where venta_id = '01920000-0000-7000-8000-0000000056f1'), 3,
          'la venta de antes ahora tiene 3 ítems: 2 de producto y el combo');
select throws_ok(
  $$ insert into public.venta_item (id, venta_id, producto_id, coleccion_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-0000000056f5', '01920000-0000-7000-8000-0000000056f1',
             '01920000-0000-7000-8000-000000005611', '01920000-0000-7000-8000-0000000056d0', 1, 1000, 1000) $$,
  '23514', null, 'y producto y colección a la vez se rechaza');

select * from finish();
rollback;
