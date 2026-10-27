-- pgTAP · 0116 sobre los datos de antes: las jornadas no cambian (salvo la columna nueva, en null), ni su
-- versión de sync, y lo nuevo anda sobre ellas: las lecturas del panel la traen en null para lo de antes y el
-- coordinador, al completar una jornada de antes, queda como quien la cargó. Ver scripts/db-test-migracion.sh y
-- datos.sql.
begin;
select * from no_plan();

-- Nada se pierde.
select is((select count(*)::int from public.jornada), 4, 'las 4 jornadas siguen');
select is((select count(*)::int from public.jornada j join public.prueba_0116_jornada s using (id)
            where to_jsonb(j) - 'acompaniamiento_cargado_por' is distinct from to_jsonb(s)), 0,
          'las jornadas quedaron idénticas (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.jornada where acompaniamiento_cargado_por is not null), 0,
          'ninguna trae quién cargó: de las de antes no se sabe, y no se inventa');
select is((select sync_version from public.jornada where id = '01920000-0000-7000-8000-000000011601'), 1::bigint,
          'la jornada corregida conserva su versión de sync: ningún teléfono re-sube nada');

-- Lo nuevo anda sobre los datos de antes, con la sesión del coordinador.
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000116a1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000116a1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);

select is((select string_agg(format('%s|%s|%s', r.acompaniante_nombre, coalesce(r.acompaniamiento_origen, 'null'),
                                    coalesce(r.acompaniamiento_cargado_por::text, 'null')), ';' order by r.dia, r.jornada_id)
             from public.historial_de_acompaniamientos('01920000-0000-7000-8000-0000000116e1') r),
          'Mariela|COORDINADOR|null;Beto|COLPORTOR|null;Mariela|null|null',
          'el historial lee las jornadas de antes con quién cargó en null (el origen de cada una no cambia)');
select is((select count(*)::int from public.jornadas_cerradas_de_colportor('01920000-0000-7000-8000-0000000116e1',
              '01920000-0000-7000-8000-0000000116b1') r where r.acompaniamiento_cargado_por is null), 4,
          'y las jornadas cerradas de b1, también');

-- El coordinador completa la que estaba libre: queda como quien la cargó. Las otras no se tocan.
select is((select r.acompaniamiento_origen
             from public.agregar_acompaniamiento('01920000-0000-7000-8000-0000000116e1', '01920000-0000-7000-8000-000000011604',
                                                 '01920000-0000-7000-8000-0000000116b2', 'Sector norte') r),
          'COORDINADOR', 'el coordinador suma a b2 a la jornada libre de antes');
select is((select r.acompaniamiento_cargado_por_nombre || ' ' || r.acompaniamiento_cargado_por_apellido
             from public.historial_de_acompaniamientos('01920000-0000-7000-8000-0000000116e1', '01920000-0000-7000-8000-0000000116b1') r
            where r.jornada_id = '01920000-0000-7000-8000-000000011604'),
          'Mariela Pereyra', 'y el historial dice que la cargó Mariela');
select is((select count(*)::int from public.jornadas_cerradas_de_colportor('01920000-0000-7000-8000-0000000116e1',
              '01920000-0000-7000-8000-0000000116b1') r where r.acompaniamiento_cargado_por is null), 3,
          'las otras tres siguen sin quién cargó');
select set_config('role', 'postgres', true);
select is((select count(*)::int from public.jornada j join public.prueba_0116_jornada s using (id)
            where j.id <> '01920000-0000-7000-8000-000000011604'
              and to_jsonb(j) - 'acompaniamiento_cargado_por' is distinct from to_jsonb(s)), 0,
          'y ninguna de las anteriores cambió');

select * from finish();
rollback;
