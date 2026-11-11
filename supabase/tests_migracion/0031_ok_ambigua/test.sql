-- pgTAP · con dos «Montevideo» vivas, 0031 agrega las columnas, no le carga el rectángulo a ninguna y no
-- toca ni una fila (ni siquiera su sync_version).
begin;
select * from no_plan();

select is((select count(*)::int from public.ciudad), 2, 'las dos ciudades siguen');
select is((select count(*)::int from public.ciudad where bbox_oeste is not null), 0,
          'ninguna recibió el rectángulo: no se adivina cuál es la buena');
select is((select count(*)::int
             from public.ciudad c join public.prueba_0031_ciudad s using (id)
            where (to_jsonb(c) - 'bbox_oeste' - 'bbox_sur' - 'bbox_este' - 'bbox_norte') is distinct from to_jsonb(s)), 0,
          'y las dos quedaron idénticas, sync_version y xmin_w incluidos: ni el trigger de auditoría las tocó');

select * from finish();
rollback;
