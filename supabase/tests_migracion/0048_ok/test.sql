-- pgTAP · 0048 agrega el departamento de la ciudad SIN tocar los datos, y carga 'Montevideo' en la única
-- Montevideo viva de UY (con el centro adentro de su rectángulo). Ver scripts/db-test-migracion.sh y
-- los datos de datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen --------------------------------------------------------------
select is((select count(*)::int from public.ciudad), 4, 'las 4 ciudades siguen: no se perdió ninguna');
select is((select count(*)::int from public.zona), 1, 'la zona sigue');
select is((select count(*)::int from public.campania_ciudad cc join public.prueba_0048_campania_ciudad s using (id)
            where to_jsonb(cc) = to_jsonb(s)), 2, 'las dos ciudades de la campaña siguen idénticas');
select is((select count(*)::int from public.zona z join public.prueba_0048_zona s using (id)
            where to_jsonb(z) = to_jsonb(s)), 1, 'la zona quedó idéntica en todas sus columnas');

-- Salto, Maldonado y la Montevideo de Chile idénticas en todo (sync_version y xmin_w incluidos), con la
-- columna nueva en null.
select is((select count(*)::int
             from public.ciudad c
             join public.prueba_0048_ciudad s on s.id = c.id
            where c.id <> '01920000-0000-7000-8000-0000000048c1'
              and (to_jsonb(c) - 'departamento') is distinct from to_jsonb(s)), 0,
          'Salto, Maldonado y la Montevideo de Chile quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos');
select is((select count(*)::int from public.ciudad where id <> '01920000-0000-7000-8000-0000000048c1' and departamento is not null), 0,
          'y ninguna de ellas recibió departamento: no se adivina');
select is((select count(*)::int
             from public.ciudad c
             join public.prueba_0048_ciudad s on s.id = c.id
            where c.id = '01920000-0000-7000-8000-0000000048c1'
              and (to_jsonb(c) - 'departamento' - 'updated_at' - 'sync_version' - 'xmin_w')
                  is distinct from (to_jsonb(s) - 'updated_at' - 'sync_version' - 'xmin_w')), 0,
          'Montevideo conserva nombre, país, centro, zoom y baja: lo único que cambia es el departamento (y la auditoría)');
select is((select deleted_at is not null from public.ciudad where id = '01920000-0000-7000-8000-0000000048c3'), true,
          'la ciudad dada de baja sigue de baja');

-- --- Montevideo ---------------------------------------------------------------------------------
select is((select departamento from public.ciudad where id = '01920000-0000-7000-8000-0000000048c1'), 'Montevideo',
          'la única Montevideo viva de UY recibió su departamento');
select ok((select c.sync_version > s.sync_version and c.updated_at >= s.updated_at
             from public.ciudad c join public.prueba_0048_ciudad s using (id)
            where c.id = '01920000-0000-7000-8000-0000000048c1'),
          'el UPDATE pasó por la auditoría: sube su sync_version y los teléfonos la bajan por delta');
select is((select c.xmin_w::text::bigint > s.xmin_w::text::bigint
             from public.ciudad c join public.prueba_0048_ciudad s using (id)
            where c.id = '01920000-0000-7000-8000-0000000048c1'), true,
          'su xmin_w avanzó: el delta del pull la incluye');
select is((select count(*)::int from public.ciudad where departamento is not null), 1,
          'es la única ciudad con departamento');

-- --- la restricción vale también sobre lo migrado -----------------------------------------------
select throws_ok($$ update public.ciudad set departamento = ' Salto' where id = '01920000-0000-7000-8000-0000000048c2' $$,
                 '23514', null, 'un departamento con espacios en los costados se rechaza');
select lives_ok($$ update public.ciudad set departamento = 'Salto' where id = '01920000-0000-7000-8000-0000000048c2' $$,
                'y se puede cargar el de Salto a mano');

select * from finish();
rollback;
