-- pgTAP · sin una Montevideo completable, 0031 agrega las columnas y no toca ni una fila: la migración no
-- aborta por datos viejos raros (un centro cargado al revés, una baja, otro país).
begin;
select * from no_plan();

select is((select count(*)::int from public.ciudad), 4, 'las 4 ciudades siguen');
select is((select count(*)::int from public.ciudad where bbox_oeste is not null), 0, 'ninguna recibió el rectángulo');
select is((select count(*)::int
             from public.ciudad c join public.prueba_0031_ciudad s using (id)
            where (to_jsonb(c) - 'bbox_oeste' - 'bbox_sur' - 'bbox_este' - 'bbox_norte') is distinct from to_jsonb(s)), 0,
          'y las 4 quedaron idénticas, sync_version y xmin_w incluidos');
select is((select lat_centro from public.ciudad where id = '01920000-0000-7000-8000-0000000031c2'), -56.1645::float8,
          'el centro cargado al revés sigue como estaba: la migración no lo «arregla» sin que nadie lo decida');

select * from finish();
rollback;
