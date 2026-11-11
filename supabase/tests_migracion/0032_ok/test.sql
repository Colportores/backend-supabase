-- pgTAP · 0032 suma ubicacion_par_decidido SIN tocar los datos de antes: las ubicaciones (con sus versiones
-- de sync) y las 22 entidades registradas quedan idénticas; la tabla nace vacía y puede guardar una
-- decisión sobre una ubicación que ya existía. Ver scripts/db-test-migracion.sh y los datos de datos.sql.
begin;
select * from no_plan();

-- --- los datos de antes siguen --------------------------------------------------------------
select is((select count(*)::int from public.ubicacion), 3, 'las 3 ubicaciones siguen: no se perdió ninguna');
select is((select count(*)::int
             from public.ubicacion u
             join public.prueba_0032_ubicacion s using (id)
            where to_jsonb(u) is distinct from to_jsonb(s)), 0,
          'y quedaron idénticas en todas sus columnas, sync_version y xmin_w incluidos: ni se enteran los teléfonos');
select is((select deleted_at is not null from public.ubicacion where id = '01920000-0000-7000-8000-0000000032b3'), true,
          'la dada de baja sigue de baja');
select is((select sync_version from public.ubicacion where id = '01920000-0000-7000-8000-0000000032b2'), 1::bigint,
          'la corregida conserva su versión de sync');

-- --- el registro de sync -----------------------------------------------------------------------
select is((select count(*)::int from sync.entidad), 23, 'hay 23 entidades: las 22 de antes más la nueva');
select is((select count(*)::int
             from sync.entidad e
             join public.prueba_0032_entidad s using (nombre)
            where (e.tabla::text, e.columna_pk, e.permite_push, e.columnas_servidor, e.sigue_campanias, e.columna_duenio)
                  is distinct from (s.tabla, s.columna_pk, s.permite_push, s.columnas_servidor, s.sigue_campanias, s.columna_duenio)), 0,
          'las 22 de antes quedaron idénticas');
select is((select array_agg(nombre) from sync.entidad e
            where not exists (select 1 from public.prueba_0032_entidad s where s.nombre = e.nombre)),
          array['ubicacion_par_decidido'], 'y la única nueva es ubicacion_par_decidido');

-- --- la tabla nueva ------------------------------------------------------------------------------
select is((select count(*)::int from public.ubicacion_par_decidido), 0, 'nace vacía: hasta hoy ningún teléfono la sube');
select lives_ok($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en, created_by)
                   values ('01920000-0000-7000-8000-0000000032b1', '01920000-0000-7000-8000-0000000032b2', 'CONSERVAR_AMBOS', now(), null) $$,
                'y guarda una decisión sobre dos ubicaciones que ya existían (la dada de baja también se puede nombrar)');
select lives_ok($$ insert into public.ubicacion_par_decidido (ubicacion_a_id, ubicacion_b_id, decision, decidido_en, created_by)
                   values ('01920000-0000-7000-8000-0000000032b1', '01920000-0000-7000-8000-0000000032b3', 'IGNORAR', now(), null) $$,
                'incluso una ubicación dada de baja (una decisión previa a la baja no se pierde)');

select * from finish();
rollback;
