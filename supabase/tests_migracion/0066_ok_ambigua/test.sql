-- pgTAP · con dos «Montevideo» vivas, 0066 agrega la columna, no le carga el departamento a ninguna y no
-- toca ni una fila (ni siquiera su sync_version).
begin;
select * from no_plan();

select is((select count(*)::int from public.ciudad), 2, 'las dos ciudades siguen');
select is((select count(*)::int from public.ciudad where departamento is not null), 0,
          'ninguna recibió el departamento: no se adivina cuál es la buena');
select is((select count(*)::int
             from public.ciudad c join public.prueba_0066_ciudad s using (id)
            where (to_jsonb(c) - 'departamento') is distinct from to_jsonb(s)), 0,
          'y las dos quedaron idénticas, sync_version y xmin_w incluidos: ni el trigger de auditoría las tocó');

select * from finish();
rollback;
