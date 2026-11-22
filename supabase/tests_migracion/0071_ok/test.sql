-- pgTAP · 0071 sobre los datos de antes: las ventas y las colecciones no cambian (salvo la columna nueva), los
-- ítems de combo reciben la composición del combo y suben su versión de sync una vez, el ítem suelto no se
-- toca, las dos reglas de componentes quedan validadas, y el talonario deja usar el mismo número otro año sin
-- perder la regla del año. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde.
select is((select count(*)::int from public.venta), 2, 'las 2 ventas siguen');
select is((select count(*)::int from public.venta_item), 4, 'los 4 ítems siguen');
select is((select count(*)::int from public.coleccion), 2, 'las 2 colecciones siguen');
select is((select count(*)::int from public.producto_coleccion), 5, 'los 5 vínculos siguen (también los dados de baja)');
select is((select count(*)::int from public.venta v join public.prueba_0071_venta s using (id)
            where to_jsonb(v) - 'motivo_monto_manual' is distinct from to_jsonb(s)), 0,
          'las ventas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.venta where motivo_monto_manual is not null), 0,
          'y ninguna tiene motivo: es null');
select is((select count(*)::int from public.coleccion c join public.prueba_0071_coleccion s using (id)
            where to_jsonb(c) - 'libros_a_elegir' is distinct from to_jsonb(s)), 0,
          'las colecciones quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.coleccion where libros_a_elegir = 0), 2,
          'y todas son combos fijos (0 libros a elegir)');
select is((select count(*)::int from public.producto_coleccion c join public.prueba_0071_producto_coleccion s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'los vínculos no se tocaron');

-- Los ítems de producto no cambian.
select is((select count(*)::int from public.venta_item i join public.prueba_0071_venta_item s using (id)
            where i.producto_id is not null and to_jsonb(i) - 'componentes' is distinct from to_jsonb(s)), 0,
          'los ítems de producto quedaron idénticos (versión de sync y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.venta_item where producto_id is not null and componentes is not null), 0,
          'y ninguno tiene componentes');

-- Los ítems de combo: la composición viva del combo, por producto, y una versión de sync más.
select is((select componentes from public.venta_item where id = '01920000-0000-7000-8000-000000007112'),
          '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}, {"producto_id": "01920000-0000-7000-8000-000000007112", "cantidad": 2}]'::jsonb,
          'el Pack Familiar queda con 1 libro y 2 revistas (el vínculo dado de baja no cuenta)');
select is((select componentes from public.venta_item where id = '01920000-0000-7000-8000-000000007113'),
          '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 3}, {"producto_id": "01920000-0000-7000-8000-000000007112", "cantidad": 4}]'::jsonb,
          'el combo sin vínculos vivos queda con los de los vínculos dados de baja: la mejor foto posible');
select is((select count(*)::int from public.venta_item i join public.prueba_0071_venta_item s using (id)
            where i.coleccion_id is not null
              and (to_jsonb(i) - 'componentes' - 'sync_version' - 'updated_at' - 'xmin_w')
                  is distinct from (to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w')), 0,
          'el resto de las columnas de los ítems de combo no cambió');
select is((select count(*)::int from public.venta_item i join public.prueba_0071_venta_item s using (id)
            where i.coleccion_id is not null and i.sync_version = s.sync_version + 1), 2,
          'los dos ítems de combo suben su versión de sync una vez: los teléfonos reciben los componentes');

-- Las reglas quedaron en pie y validadas.
select is((select bool_and(convalidated) from pg_constraint
            where conrelid = 'public.venta_item'::regclass
              and conname in ('venta_item_componentes_solo_en_combo', 'venta_item_componentes_forma')),
          true, 'las dos reglas de componentes están validadas: ningún ítem de combo quedó sin completar');
select throws_ok(
  $$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal)
     values ('01920000-0000-7000-8000-000000007121', '01920000-0000-7000-8000-000000007101',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000) $$,
  '23514', null, 'un combo nuevo sin componentes se rechaza');
select lives_ok(
  $$ insert into public.venta_item (id, venta_id, coleccion_id, cantidad, precio_unitario, subtotal, componentes)
     values ('01920000-0000-7000-8000-000000007122', '01920000-0000-7000-8000-000000007101',
             '01920000-0000-7000-8000-0000000071d0', 1, 110000, 110000,
             '[{"producto_id": "01920000-0000-7000-8000-000000007111", "cantidad": 1}]') $$,
  'y con componentes entra');

-- El talonario: el mismo número otro año vale; el mismo año no. Los de antes siguen donde estaban.
select hasnt_index('public', 'venta', 'venta_talonario_por_colportor_idx', 'el índice viejo ya no está');
select has_index('public', 'venta', 'venta_talonario_por_colportor_y_anio_idx', 'el índice por año está');
select lives_ok(
  $$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-000000007131', '01920000-0000-7000-8000-0000000071f3', 'T-7101', 1000,
             '2027-03-01 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$,
  'el número T-7101 de la venta de 2026 se usa en 2027');
select throws_ok(
  $$ insert into public.venta (id, espacio_persona_id, numero_talonario, monto_total, fecha, colportor_id)
     values ('01920000-0000-7000-8000-000000007132', '01920000-0000-7000-8000-0000000071f3', 'T-7101', 1000,
             '2026-12-01 15:00:00+00', '01920000-0000-7000-8000-0000000071b1') $$,
  '23505', null, 'pero no otra vez en 2026');

select * from finish();
rollback;
