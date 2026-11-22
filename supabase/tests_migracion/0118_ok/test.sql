-- pgTAP · 0118 sobre los datos de antes: las entregas y el stock no cambian (salvo la columna nueva, en false), ni su
-- versión de sync, no se inventa ninguna salida de lo que ya se entregó, y lo nuevo anda sobre ellas: entregar la
-- pendiente descuenta una vez, y editar una entregada de antes no descuenta. Ver scripts/db-test-migracion.sh y
-- datos.sql.
begin;
select * from no_plan();

-- Nada se pierde ni cambia.
select is((select count(*)::int from public.entrega), 3, 'las 3 entregas siguen');
select is((select count(*)::int from public.entrega e join public.prueba_0118_entrega s using (id)
            where to_jsonb(e) - 'stock_inconsistente' is distinct from to_jsonb(s)), 0,
          'las entregas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.entrega where stock_inconsistente), 0,
          'ninguna trae la marca: de las de antes no se sabe, y no se inventa');
select is((select sync_version from public.entrega where id = '01920000-0000-7000-8000-000000011861'), 1::bigint,
          'la entrega corregida conserva su versión de sync: ningún teléfono re-sube nada');
select is((select count(*)::int from public.stock s join public.prueba_0118_stock t using (id)
            where to_jsonb(s) is distinct from to_jsonb(t)), 0, 'el stock quedó idéntico: la migración no descuenta lo ya entregado');
select is((select count(*)::int from public.movimiento_stock), 0, 'y no se inventó ningún movimiento de salida');

-- Lo nuevo anda sobre los datos de antes.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000118b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000118b1', true);
select set_config('role', 'authenticated', true);

-- Editar una entregada de antes no descuenta.
update public.entrega set fecha_entrega = '2026-10-03 15:00:00+00' where id = '01920000-0000-7000-8000-000000011863';
select set_config('role', 'postgres', true);
select is((select cantidad_disponible from public.stock where id = '01920000-0000-7000-8000-000000011871'), 3,
          'corregir una entrega de antes no mueve el stock');
select is((select count(*)::int from public.movimiento_stock), 0, 'ni deja movimiento');
select is((select stock_inconsistente from public.entrega where id = '01920000-0000-7000-8000-000000011863'), false,
          'ni la marca');

-- Entregar la pendiente (1 con saldo 3) descuenta una vez.
select set_config('role', 'authenticated', true);
update public.entrega set pendiente = false, fecha_entrega = '2026-10-10 15:00:00+00'
 where id = '01920000-0000-7000-8000-000000011862';
select set_config('role', 'postgres', true);
select is((select cantidad_disponible from public.stock where id = '01920000-0000-7000-8000-000000011871'), 2,
          'entregar la pendiente descuenta 1: el stock pasa de 3 a 2');
select is((select count(*)::int from public.movimiento_stock
            where entrega_id = '01920000-0000-7000-8000-000000011862' and tipo = 'SALIDA_ENTREGA' and cantidad = 1), 1,
          'con su movimiento de salida');
select is((select stock_inconsistente from public.entrega where id = '01920000-0000-7000-8000-000000011862'), false,
          'y sin marca: había stock');

select * from finish();
rollback;
