-- pgTAP · 0176 sobre los datos de antes: cada acompañante que guardaba una jornada pasa a la tabla (también el de la jornada dada
-- de baja y quien lo cargó), la jornada sin acompañante no suma nada, el origen y la nota quedan con su acompañante, y las jornadas
-- quedan idénticas (la columna se conserva y no sube de versión). Ver scripts/db-test-migracion.sh.
begin;
select * from no_plan();

select is((select count(*)::int from public.jornada_acompaniante), 3, 'una fila por cada jornada que tenía acompañante (también la de baja)');
select is((select count(*)::int from public.jornada_acompaniante a
            join public.prueba_0176_jornada j on j.id = a.jornada_id and j.acompaniante_id = a.acompaniante_id
             and j.colportor_id = a.colportor_id and j.acompaniamiento_cargado_por is not distinct from a.cargado_por
             and j.deleted_at is not distinct from a.deleted_at), 3,
          'cada una con su acompañante, su dueña, quien la cargó y la baja de la jornada');
select is((select count(*)::int from public.jornada_acompaniante where jornada_id = '01920000-0000-7000-8000-0000000176f3'), 0,
          'la jornada sin acompañante no suma ninguno');
select is((select a.cargado_por from public.jornada_acompaniante a where a.jornada_id = '01920000-0000-7000-8000-0000000176f1'),
          '01920000-0000-7000-8000-0000000176a1'::uuid, 'quien cargó el acompañamiento de f1 sigue siendo el coordinador');
select is((select a.cargado_por from public.jornada_acompaniante a where a.jornada_id = '01920000-0000-7000-8000-0000000176f2'),
          null, 'y el que marcó ella misma sigue sin quien cargó');
select is((select a.created_at from public.jornada_acompaniante a where a.jornada_id = '01920000-0000-7000-8000-0000000176f1'),
          (select j.created_at from public.prueba_0176_jornada j where j.id = '01920000-0000-7000-8000-0000000176f1'),
          'el alta conserva la fecha de la jornada');

select is((select count(*)::int from public.jornada j join public.prueba_0176_jornada s using (id)
            where to_jsonb(j) is distinct from to_jsonb(s)), 0,
          'las cuatro jornadas quedan idénticas, sync_version incluida (la migración no las toca)');

-- El origen y la nota, ahora una fila por acompañante.
select is((select count(*)::int from public.jornada_acompaniamiento), (select count(*)::int from public.prueba_0176_detalle),
          'no se pierde ninguna fila de origen y nota');
select is((select count(*)::int from public.jornada_acompaniamiento d
            join public.jornada j on j.id = d.jornada_id and j.acompaniante_id = d.acompaniante_id),
          (select count(*)::int from public.prueba_0176_detalle), 'cada una quedó con el acompañante de su jornada');
select is((select d.nota from public.jornada_acompaniamiento d where d.jornada_id = '01920000-0000-7000-8000-0000000176f1'),
          'Sector norte', 'y la nota de f1 sigue ahí');
select is((select d.origen from public.jornada_acompaniamiento d where d.jornada_id = '01920000-0000-7000-8000-0000000176f1'),
          'COORDINADOR', 'con su origen');
select is((select is_nullable from information_schema.columns
            where table_schema = 'public' and table_name = 'jornada_acompaniamiento' and column_name = 'acompaniante_id'), 'NO',
          'acompaniante_id es obligatorio');

select * from finish();
rollback;
