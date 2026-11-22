-- pgTAP · 0070 suma producto.codigo_editor en null a lo que ya había y crea parametro_global con su única
-- fila (15 días). No toca ninguna fila de producto: ni sus columnas, ni sync_version, ni xmin_w. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.producto where id::text like '01920000-0000-7000-8000-0000000070%'), 3,
          'los 3 productos siguen: no se perdió ninguno');
select is((select count(*)::int from public.producto where codigo_editor is not null), 0,
          'ningún producto trae código hasta que Administración lo cargue: se encuentran por nombre');
select is((select count(*)::int from public.producto p join public.prueba_0070_producto s using (id)
            where to_jsonb(p) - 'codigo_editor' is distinct from to_jsonb(s)), 0,
          'los 3 productos quedaron idénticos (baja, versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select deleted_at is not null from public.producto where id = '01920000-0000-7000-8000-0000000070d3'), true,
          'y el dado de baja sigue de baja');

-- La tabla nueva trae solo la fila de referencia.
select is((select count(*)::int from public.parametro_global), 1, 'parametro_global arranca con una sola fila');
select is((select valor from public.parametro_global where clave = 'dias_antiguedad_precios' and deleted_at is null), 15,
          'los días de antigüedad de los precios valen 15');
select is((select permite_push from sync.entidad where nombre = 'parametro_global'), false,
          'y baja por el pull como réplica de solo lectura');

-- Lo nuevo anda sobre los datos de antes.
update public.producto set codigo_editor = 'EDI-70' where id = '01920000-0000-7000-8000-0000000070d1';
select is((select codigo_editor from public.producto where id = '01920000-0000-7000-8000-0000000070d1'), 'EDI-70',
          'un producto de antes recibe su código');

select * from finish();
rollback;
