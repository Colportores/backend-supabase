-- pgTAP · 0031 agrega el rectángulo de la ciudad y el enlace de la zona SIN tocar los datos, y carga el
-- rectángulo de Montevideo (la única viva de UY, sin rectángulo y con el centro adentro). Ver
-- scripts/db-test-migracion.sh y los datos de datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen --------------------------------------------------------------
select is((select count(*)::int from public.ciudad), 4, 'las 4 ciudades siguen: no se perdió ninguna');
select is((select count(*)::int from public.zona), 2, 'las 2 zonas siguen');
select is((select count(*)::int from public.zona z join public.prueba_0031_zona s using (id)), 2, 'y son las mismas');

-- Todas las columnas de antes de cada ciudad (menos el rectángulo) iguales; la de Montevideo cambia solo
-- por la auditoría (updated_at y sync_version: el UPDATE del rectángulo llega a los teléfonos por delta).
select is((select count(*)::int
             from public.ciudad c
             join public.prueba_0031_ciudad s on s.id = c.id
            where c.id <> '01920000-0000-7000-8000-0000000031c1'
              and (to_jsonb(c) - 'bbox_oeste' - 'bbox_sur' - 'bbox_este' - 'bbox_norte') is distinct from to_jsonb(s)), 0,
          'Salto, Maldonado y la Montevideo de Chile quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos');
select is((select count(*)::int
             from public.ciudad c
             join public.prueba_0031_ciudad s on s.id = c.id
            where c.id = '01920000-0000-7000-8000-0000000031c1'
              and (to_jsonb(c) - 'bbox_oeste' - 'bbox_sur' - 'bbox_este' - 'bbox_norte' - 'updated_at' - 'sync_version' - 'xmin_w')
                  is distinct from (to_jsonb(s) - 'updated_at' - 'sync_version' - 'xmin_w')), 0,
          'y Montevideo conserva nombre, país, centro, zoom y baja: lo único que cambia es el rectángulo (y la auditoría)');
select is((select count(*)::int
             from public.zona z
             join public.prueba_0031_zona s on s.id = z.id
            where (to_jsonb(z) - 'paquete_mapa') is distinct from to_jsonb(s)), 0,
          'las zonas quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos');
select is((select count(*)::int from public.zona where paquete_mapa is not null), 0, 'y ninguna trae paquete todavía');
select is((select deleted_at is not null from public.ciudad where id = '01920000-0000-7000-8000-0000000031c3'), true,
          'la ciudad dada de baja sigue de baja');

-- --- el rectángulo de Montevideo --------------------------------------------------------------
select results_eq(
  $$ select bbox_oeste, bbox_sur, bbox_este, bbox_norte from public.ciudad where id = '01920000-0000-7000-8000-0000000031c1' $$,
  $$ values (-56.433::float8, -34.945::float8, -55.948::float8, -34.701::float8) $$,
  'Montevideo (la única viva de UY) recibió su rectángulo (el de la guía de carga manual)');
select ok((select c.sync_version > s.sync_version and c.updated_at >= s.updated_at
             from public.ciudad c join public.prueba_0031_ciudad s using (id)
            where c.id = '01920000-0000-7000-8000-0000000031c1'),
          'el UPDATE pasó por la auditoría: sube su sync_version y los teléfonos la bajan por delta');
select is((select count(*)::int from public.ciudad where bbox_oeste is not null), 1,
          'y es la única ciudad con rectángulo: Salto, Maldonado y la Montevideo de Chile siguen sin él');
select is((select c.xmin_w::text::bigint > s.xmin_w::text::bigint
             from public.ciudad c join public.prueba_0031_ciudad s using (id)
            where c.id = '01920000-0000-7000-8000-0000000031c1'), true,
          'su xmin_w avanzó: el delta del pull la incluye');

select * from finish();
rollback;
