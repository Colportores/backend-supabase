-- pgTAP · 0071 con un ítem de combo que nunca tuvo componentes: la migración se aplica, no borra ni inventa
-- nada, completa lo que sí se puede, deja la regla «solo en combo» NOT VALID y esa regla sigue valiendo para
-- toda fila nueva. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.venta_item), 3, 'los 3 ítems siguen');
select is((select componentes from public.venta_item where id = '01920000-0000-7000-8000-000000007212'),
          '[{"producto_id": "01920000-0000-7000-8000-000000007211", "cantidad": 2}]'::jsonb,
          'el combo con composición se completó');
select is((select componentes from public.venta_item where id = '01920000-0000-7000-8000-000000007213'), null,
          'el combo que nunca tuvo un componente quedó sin componentes: no se inventa nada');
select is((select count(*)::int from public.venta_item i join public.prueba_0071s_venta_item s using (id)
            where i.id = '01920000-0000-7000-8000-000000007213' and to_jsonb(i) - 'componentes' = to_jsonb(s)), 1,
          'y esa fila es idéntica a la de antes (versión de sync y xmin_w incluidos): no se tocó');
select is((select count(*)::int from public.venta_item i join public.prueba_0071s_venta_item s using (id)
            where i.id = '01920000-0000-7000-8000-000000007211' and to_jsonb(i) - 'componentes' = to_jsonb(s)), 1,
          'el ítem suelto tampoco');

select is((select convalidated from pg_constraint
            where conrelid = 'public.venta_item'::regclass and conname = 'venta_item_componentes_solo_en_combo'),
          false, 'la regla «solo en combo» quedó NOT VALID');
select is((select convalidated from pg_constraint
            where conrelid = 'public.venta_item'::regclass and conname = 'venta_item_componentes_forma'),
          true, 'y la de la forma, validada');

-- Rige para lo nuevo.
select throws_ok(
  $$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-000000007221', '01920000-0000-7000-8000-000000007201',
             '01920000-0000-7000-8000-0000000072d0', 1, 50000, 50000) $$,
  '23514', null, 'un combo nuevo sin componentes se rechaza aunque la regla sea NOT VALID');
select lives_ok(
  $$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-000000007222', '01920000-0000-7000-8000-000000007201',
             '01920000-0000-7000-8000-0000000072d1', 1, 26000, 26000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007211", "cantidad": 1}]') $$,
  'y con componentes entra');
select throws_ok(
  $$ insert into public.venta_item (id, venta_id, producto_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-000000007223', '01920000-0000-7000-8000-000000007201',
             '01920000-0000-7000-8000-000000007211', 1, 24000, 24000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007211", "cantidad": 1}]') $$,
  '23514', null, 'un producto suelto con componentes también');

select * from finish();
rollback;
