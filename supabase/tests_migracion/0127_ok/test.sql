-- pgTAP · 0127 sobre los datos de antes: numera las transferencias que ya había por fecha de solicitud y no toca
-- nada más (la versión de sync y el xmin_w quedan iguales). Las nuevas siguen la secuencia. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.transferencia_stock), 3, 'las tres transferencias siguen');
select is((select string_agg(right(id::text, 2) || '=' || numero, ',' order by numero) from public.transferencia_stock),
          '13=1,12=2,11=3', 'se numeran por fecha de solicitud: la más vieja es la 1');
select is((select count(*)::int
             from public.transferencia_stock t
             join public.prueba_0127_transferencia s using (id)
            where to_jsonb(t) - 'numero' is distinct from to_jsonb(s)), 0,
          'idénticas en todas sus columnas de antes, sync_version y xmin_w incluidos');

-- La secuencia sigue después de la última.
insert into public.transferencia_stock (id, origen_id, destino_id)
values ('01920000-0000-7000-8000-000000012714', '01920000-0000-7000-8000-0000000127b2',
        '01920000-0000-7000-8000-0000000127b1');
select is((select numero from public.transferencia_stock where id = '01920000-0000-7000-8000-000000012714'), 4::bigint,
          'la próxima transferencia es la 4');

select * from finish();
rollback;
