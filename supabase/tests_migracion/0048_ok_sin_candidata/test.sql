-- pgTAP · sin una Montevideo viva de UY con el centro adentro de su caja, 0048 agrega la columna y no
-- toca ni una fila.
begin;
select * from no_plan();

select is((select count(*)::int from public.ciudad), 3, 'las tres ciudades siguen');
select is((select count(*)::int from public.ciudad where departamento is not null), 0,
          'ninguna recibió departamento: ni la de centro afuera, ni la dada de baja, ni la de Chile');
select is((select count(*)::int
             from public.ciudad c join public.prueba_0048_ciudad s using (id)
            where (to_jsonb(c) - 'departamento') is distinct from to_jsonb(s)), 0,
          'y las tres quedaron idénticas, sync_version y xmin_w incluidos');

select * from finish();
rollback;
