-- pgTAP · 0110 suma el registro en audit_log de los cambios de parametro_global sin tocar lo que ya había:
-- la fila queda idéntica (valor, sync_version, updated_at y xmin_w incluidos) y audit_log no recibe ningún
-- evento retroactivo. Después, un cambio nuevo sí queda. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.parametro_global), 1, 'parametro_global sigue con su única fila');
select is((select valor from public.parametro_global where clave = 'dias_antiguedad_precios' and deleted_at is null), 20,
          'con los 20 días que tenía antes de la migración');
select is((select count(*)::int from public.parametro_global p join public.prueba_0110_parametro_global s using (id)
            where to_jsonb(p) is distinct from to_jsonb(s)), 0,
          'la fila quedó idéntica (versión de sync, updated_at y xmin_w incluidos)');
select is((select count(*)::int from auditoria.audit_log
            where tabla = 'parametro_global' or event_type like 'parametro_global%'), 0,
          'el cambio anterior al registro no se inventa: audit_log arranca sin eventos de parametro_global');

-- Lo nuevo anda sobre los datos de antes.
update public.parametro_global set valor = 30 where clave = 'dias_antiguedad_precios' and deleted_at is null;
select is((select (metadata ->> 'valor_anterior') || '>' || (metadata ->> 'valor_nuevo')
             from auditoria.audit_log where event_type = 'parametro_global_cambio'), '20>30',
          'el primer cambio después de la migración queda con su valor anterior y el nuevo');

select * from finish();
rollback;
