-- pgTAP · 0169 sobre los datos de antes: la columna se fue y las tres jornadas quedan idénticas en todo lo demás (quien
-- acompañó, las horas, los totales, la baja y la versión del sync). Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select hasnt_column('public', 'jornada', 'tipo_acompaniamiento', 'la jornada ya no guarda el tipo de acompañamiento');
select is((select count(*)::int from public.jornada), 3, 'siguen las tres jornadas');
select is((select count(*)::int from public.jornada j join public.prueba_0169_jornada s using (id)
            where to_jsonb(j) is distinct from (to_jsonb(s) - 'tipo_acompaniamiento')), 0,
          'idénticas en todo lo demás, sync_version incluida (la migración no las toca)');
select is((select acompaniante_id from public.jornada where id = '01920000-0000-7000-8000-000000016911'),
          '01920000-0000-7000-8000-0000000169b2'::uuid, 'quien acompañó sigue en la jornada');
select is((select count(*)::int from public.jornada where deleted_at is not null), 1, 'y la jornada dada de baja sigue dada de baja');
select is((select count(*)::int from unnest(sync.columnas_escribibles('jornada')) c where c = 'tipo_acompaniamiento'), 0,
          'el push ya no la escribe');

select * from finish();
rollback;
