-- pgTAP · 0198 sobre datos de antes: sale la columna `tipo` y nada más cambia en los productos. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select hasnt_column('public', 'producto', 'tipo', 'producto.tipo ya no existe');
select is((select count(*)::int from public.producto where id::text like '01920000-0000-7000-8000-0000000198a%'), 6,
          'los 6 productos siguen: no se perdió ninguno');
select is((select string_agg(right(id::text, 2) || '=' || categoria, ',' order by id) from public.producto
            where id::text like '01920000-0000-7000-8000-0000000198a%'),
          'a1=BONIFICABLES,a2=ESPIRITUALES,a3=MISIONEROS,a4=REVISTAS,a5=MATERIAL,a6=ESPIRITUALES',
          'cada producto conserva su categoría (la revista bonificable sigue en Revistas)');
select is((select count(*)::int from public.producto p join public.prueba_0198_producto s using (id)
            where to_jsonb(p) - 'tipo' is distinct from to_jsonb(s) - 'tipo'), 0,
          'los productos quedaron idénticos salvo la columna que se saca (versión de sync, updated_at y xmin_w incluidos)');
select is((select count(*)::int from public.prueba_0198_producto s where not (to_jsonb(s) ? 'tipo')), 0,
          'y la foto de antes sí traía el tipo');
select is((select deleted_at is not null from public.producto where id = '01920000-0000-7000-8000-0000000198a6'), true,
          'el dado de baja sigue de baja');
select is((select count(*)::int from public.pedido_item i join public.prueba_0198_pedido_item s using (id)
            where to_jsonb(i) is distinct from to_jsonb(s)), 0, 'las líneas de pedido quedaron iguales');

-- Las lecturas ya no traen producto_tipo (con datos, las prueban 0111, 0112, 0126 y 0137).
select is((select count(*)::int from pg_proc p
            where p.pronamespace = 'public'::regnamespace and 'producto_tipo' = any (coalesce(p.proargnames, array[]::text[]))),
          0, 'ninguna función de public devuelve ya producto_tipo');

select * from finish();
rollback;
