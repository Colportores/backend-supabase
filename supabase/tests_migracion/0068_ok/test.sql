-- pgTAP · 0068 renombra los estados de la agenda (PENDIENTE → PROGRAMADA, COMPLETADA → CUMPLIDA), le pone a
-- cada cita el espacio de su vínculo y suma las columnas nuevas (venta, entrega, monto previsto; en la
-- entrega, la fecha prevista) en null, sin perder ninguna fila ni tocar ninguna otra columna. Ver
-- scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.agenda where id::text like '01920000-0000-7000-8000-0000000068%'), 5,
          'las 5 citas siguen, la dada de baja también: no se perdió ninguna');
select is((select count(*)::int from public.entrega where id::text like '01920000-0000-7000-8000-0000000068%'), 2,
          'las 2 entregas siguen');

-- Los estados.
select is((select estado from public.agenda where id = '01920000-0000-7000-8000-000000006831'), 'PROGRAMADA',
          'PENDIENTE pasó a PROGRAMADA');
select is((select estado from public.agenda where id = '01920000-0000-7000-8000-000000006832'), 'CUMPLIDA',
          'COMPLETADA pasó a CUMPLIDA');
select is((select estado from public.agenda where id = '01920000-0000-7000-8000-000000006833'), 'CANCELADA',
          'CANCELADA se queda');
select is((select estado from public.agenda where id = '01920000-0000-7000-8000-000000006834'), 'PROGRAMADA',
          'la PENDIENTE dada de baja también se renombra');
select is((select count(*)::int from public.agenda where estado in ('PENDIENTE', 'COMPLETADA')), 0,
          'no queda ningún estado con el nombre viejo');
select is((select deleted_at is not null from public.agenda where id = '01920000-0000-7000-8000-000000006834'), true,
          'y la dada de baja sigue de baja');

-- El espacio de cada cita es el de su vínculo.
select is((select count(*)::int from public.agenda a join public.espacio_persona ep on ep.id = a.espacio_persona_id
            where a.id::text like '01920000-0000-7000-8000-0000000068%' and a.espacio_id is distinct from ep.espacio_id), 0,
          'cada cita cuelga del espacio de su vínculo');
select is((select espacio_id from public.agenda where id = '01920000-0000-7000-8000-000000006831'),
          '01920000-0000-7000-8000-0000000068f1'::uuid, 'la del depto 1 en el depto 1');
select is((select espacio_id from public.agenda where id = '01920000-0000-7000-8000-000000006835'),
          '01920000-0000-7000-8000-0000000068f2'::uuid, 'y la del depto 2 en el depto 2');
select is((select count(*)::int from public.agenda a where a.id::text like '01920000-0000-7000-8000-0000000068%'
              and a.espacio_persona_id is null), 0,
          'todas conservan su persona: nada se desvinculó');

-- Lo nuevo arranca vacío y no cambia ninguna otra columna: solo estado, espacio, versión de sync y fechas
-- de auditoría (el UPDATE de la migración las mueve una vez).
select is((select count(*)::int from public.agenda
            where venta_id is not null or entrega_id is not null or monto_previsto is not null), 0,
          'ninguna cita trae venta, entrega ni monto previsto: no se inventa lo que no se sabía');
select is((select count(*)::int from public.agenda a join public.prueba_0068_agenda s using (id)
            where to_jsonb(a) - 'estado' - 'espacio_id' - 'venta_id' - 'entrega_id' - 'monto_previsto'
                              - 'sync_version' - 'updated_at' - 'xmin_w'
               is distinct from to_jsonb(s) - 'estado' - 'sync_version' - 'updated_at' - 'xmin_w'), 0,
          'el resto de las columnas de las 5 citas quedó idéntico (persona, casa alternativa, visita, baja, fechas)');
select is((select count(*)::int from public.agenda a join public.prueba_0068_agenda s using (id)
            where a.sync_version <> s.sync_version + 1), 0,
          'cada cita subió su versión de sync una vez: un teléfono con la edición vieja recibe conflicto');
select is((select ubicacion_alt_id from public.agenda where id = '01920000-0000-7000-8000-000000006831'),
          '01920000-0000-7000-8000-0000000068e2'::uuid, 'la casa alternativa sigue');
select is((select visita_id from public.agenda where id = '01920000-0000-7000-8000-000000006832'),
          '01920000-0000-7000-8000-000000006811'::uuid, 'y la visita que cumplió la cita también');

-- Las entregas: idénticas salvo la columna nueva, en null.
select is((select count(*)::int from public.entrega where fecha_prevista is not null), 0,
          'ninguna entrega trae fecha prevista hasta que alguien la cargue');
select is((select count(*)::int from public.entrega e join public.prueba_0068_entrega s using (id)
            where to_jsonb(e) - 'fecha_prevista' is distinct from to_jsonb(s)), 0,
          'las 2 entregas quedaron idénticas (versión de sync y xmin_w incluidos) salvo la columna nueva');

-- Lo nuevo anda sobre los datos de antes.
select set_config('request.jwt.claims',
                  json_build_object('sub', '01920000-0000-7000-8000-0000000068b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000068b1', true);
select set_config('role', 'authenticated', true);
select lives_ok($$ update public.entrega set fecha_prevista = '2026-11-14 15:00:00+00'
                    where id = '01920000-0000-7000-8000-000000006861' $$,
                'la entrega pendiente de antes recibe su fecha prevista');
select lives_ok($$ insert into public.agenda (id, espacio_id, tipo, fecha_programada, colportor_id, entrega_id)
                   values ('01920000-0000-7000-8000-000000006841', '01920000-0000-7000-8000-0000000068f1', 'ENTREGA',
                           '2026-11-14 15:00:00+00', '01920000-0000-7000-8000-0000000068b1',
                           '01920000-0000-7000-8000-000000006861') $$,
                'y su cita de entrega, sin persona, cuelga del espacio');
select is((select estado from public.agenda where id = '01920000-0000-7000-8000-000000006841'), 'PROGRAMADA',
          'que arranca PROGRAMADA');
select lives_ok($$ update public.agenda set estado = 'NO_CUMPLIDA' where id = '01920000-0000-7000-8000-000000006831' $$,
                'una cita de antes pasa a NO_CUMPLIDA');
select set_config('role', 'postgres', true);

select * from finish();
rollback;
