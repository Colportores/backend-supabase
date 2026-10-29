-- pgTAP · 0148 y 0149 sobre datos de antes: los productos reciben su categoría sin perder nada, las líneas de
-- transferencia reciben las dos puntas y el movimiento de stock queda igual. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Productos
select is((select count(*)::int from public.producto where id::text like '01920000-0000-7000-8000-0000000149a%'), 7,
          'los 7 productos siguen: no se perdió ninguno');
select is((select string_agg(right(id::text, 2) || '=' || categoria, ',' order by id) from public.producto
            where id::text like '01920000-0000-7000-8000-0000000149a%'),
          'a1=BONIFICABLES,a2=MISIONEROS,a3=ESPIRITUALES,a4=REVISTAS,a5=MISIONEROS,a6=MATERIAL,a7=ESPIRITUALES',
          'cada tipo fue a su categoría (la revista bonificable, a Revistas; el libro bonificable, a Bonificables)');
select is((select count(*)::int from public.producto p join public.prueba_0149_producto s using (id)
            where to_jsonb(p) - 'categoria' - 'sync_version' - 'updated_at' - 'xmin_w'
                  is distinct from to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w'), 0,
          'los productos quedaron idénticos salvo la categoría (el tipo heredado se conserva)');
select is((select count(*)::int from public.producto p join public.prueba_0149_producto s using (id)
            where p.sync_version <= s.sync_version), 0,
          'y todos subieron su versión de sync: la categoría baja al teléfono con el próximo pull');
select is((select deleted_at is not null from public.producto where id = '01920000-0000-7000-8000-0000000149a7'), true,
          'el dado de baja sigue de baja');

-- Transferencias
select is((select count(*)::int from public.transferencia_stock where id::text like '01920000-0000-7000-8000-0000000149c%'), 2,
          'las 2 transferencias siguen');
select is((select count(*)::int from public.transferencia_stock t join public.prueba_0149_transferencia s using (id)
            where to_jsonb(t) - 'sync_version' - 'updated_at' - 'xmin_w'
                  is distinct from to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w'), 0,
          'idénticas salvo la versión (se tocan para que las puntas las reciban por el delta)');
select is((select count(*)::int from public.transferencia_stock t join public.prueba_0149_transferencia s using (id)
            where t.sync_version <= s.sync_version), 0, 'y subieron su versión de sync');
select is((select count(*)::int from public.transferencia_item i
            join public.transferencia_stock t on t.id = i.transferencia_id
           where i.id::text like '01920000-0000-7000-8000-0000000149e%'
             and i.origen_id = t.origen_id and i.destino_id = t.destino_id), 2,
          'las dos líneas de antes tienen las puntas de su encabezado');
select is((select count(*)::int from public.transferencia_item i join public.prueba_0149_item s using (id)
            where to_jsonb(i) - 'origen_id' - 'destino_id' - 'sync_version' - 'updated_at' - 'xmin_w'
                  is distinct from to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w'), 0,
          'y quedaron idénticas salvo las puntas');

-- Movimientos y sync
select is((select count(*)::int from public.movimiento_stock m join public.prueba_0149_movimiento s using (id)
            where to_jsonb(m) - 'motivo' is distinct from to_jsonb(s)), 0,
          'el movimiento de stock de antes quedó idéntico (solo suma la columna motivo, vacía)');
select is((select count(*)::int from sync.entidad), (select n + 1 from public.prueba_0149_entidades),
          'la única entidad nueva de sync es movimiento_stock');
select is((select columna_duenio from sync.entidad where nombre = 'transferencia_item'), 'origen_id,destino_id',
          'y las transferencias bajan a las dos puntas');

-- Lo nuevo anda sobre los datos de antes
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000149b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000149b1', true);
select set_config('role', 'authenticated', true);
select is(sync.push(jsonb_build_array(jsonb_build_object(
            'client_op_id', '01920000-0000-7000-8000-0000000149a0', 'entity', 'movimiento_stock', 'op', 'insert',
            'payload', jsonb_build_object('id', '01920000-0000-7000-8000-0000000149f2',
                                          'producto_id', '01920000-0000-7000-8000-0000000149a1', 'tipo', 'AJUSTE',
                                          'cantidad', -2, 'motivo', 'LIBROS_DANIADOS')))) #>> '{results,0,outcome}',
          'accepted', 'la colportora ajusta su stock de un libro de antes');
select set_config('role', 'postgres', true);
select is((select cantidad_disponible from public.stock
            where usuario_id = '01920000-0000-7000-8000-0000000149b1' and producto_id = '01920000-0000-7000-8000-0000000149a1'), -2,
          'el ajuste mueve el stock (queda en negativo: S46)');
update public.producto set categoria = 'MATERIAL' where id = '01920000-0000-7000-8000-0000000149a3';
select is((select tipo from public.producto where id = '01920000-0000-7000-8000-0000000149a3'), 'MATERIAL',
          'y cambiar la categoría de un producto de antes mueve su tipo heredado');

select * from finish();
rollback;
