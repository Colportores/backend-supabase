-- pgTAP · 0069 le pone a cada visita el espacio de su vínculo y suma las columnas nuevas (horas de la
-- entrevista) en null, sin perder ninguna fila ni tocar ninguna otra columna; y lo nuevo anda sobre los
-- datos de antes. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

select is((select count(*)::int from public.visita where id::text like '01920000-0000-7000-8000-0000000069%'), 4,
          'las 4 visitas siguen, la dada de baja también: no se perdió ninguna');
select is((select count(*)::int from public.visita where id::text like '01920000-0000-7000-8000-0000000069%'
              and espacio_persona_id is null), 0,
          'todas conservan su persona: nada se desvinculó');
select is((select count(*)::int from public.visita vi join public.espacio_persona ep on ep.id = vi.espacio_persona_id
            where vi.id::text like '01920000-0000-7000-8000-0000000069%' and vi.espacio_id is distinct from ep.espacio_id), 0,
          'cada visita cuelga del espacio de su vínculo');
select is((select espacio_id from public.visita where id = '01920000-0000-7000-8000-000000006911'),
          '01920000-0000-7000-8000-0000000069f1'::uuid, 'la del depto 1 en el depto 1');
select is((select espacio_id from public.visita where id = '01920000-0000-7000-8000-000000006913'),
          '01920000-0000-7000-8000-0000000069f2'::uuid, 'y la del depto 2 en el depto 2');
select is((select deleted_at is not null from public.visita where id = '01920000-0000-7000-8000-000000006912'), true,
          'la dada de baja sigue de baja');
select is((select count(*)::int from public.visita where tipo_resultado = 'COBRANZA'), 0,
          'ninguna visita pasó a COBRANZA: no se inventa lo que no se sabía');
select is((select count(*)::int from public.visita
            where entrevista_entrada is not null or entrevista_salida is not null), 0,
          'ninguna trae horas de entrevista hasta que la app las suba');

-- Solo cambian el espacio, la versión de sync y su xmin: el resto de la fila, idéntico.
select is((select count(*)::int from public.visita vi join public.prueba_0069_visita s using (id)
            where to_jsonb(vi) - 'espacio_id' - 'entrevista_entrada' - 'entrevista_salida'
                              - 'sync_version' - 'updated_at' - 'xmin_w'
               is distinct from to_jsonb(s) - 'sync_version' - 'updated_at' - 'xmin_w'), 0,
          'el resto de las columnas de las 4 visitas quedó idéntico (persona, fecha, resultado, baja, autor)');
select is((select count(*)::int from public.visita vi join public.prueba_0069_visita s using (id)
            where vi.sync_version <> s.sync_version + 1), 0,
          'cada visita subió su versión de sync una vez: un teléfono con la edición vieja recibe conflicto');
select is((select visita_id from public.agenda where id = '01920000-0000-7000-8000-000000006931'),
          '01920000-0000-7000-8000-000000006911'::uuid, 'y la cita que cumplió la visita sigue apuntándola');

-- Lo nuevo anda sobre los datos de antes.
select set_config('request.jwt.claims',
                  json_build_object('sub', '01920000-0000-7000-8000-0000000069b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000069b1', true);
select set_config('role', 'authenticated', true);
select lives_ok($$ update public.visita set entrevista_entrada = '2026-10-20 14:00:00+00', entrevista_salida = '2026-10-20 14:22:00+00'
                    where id = '01920000-0000-7000-8000-000000006911' $$,
                'la entrevista de antes recibe su hora de entrada y de salida');
select lives_ok($$ insert into public.visita (id, espacio_id, fecha, tipo_resultado, colportor_id)
                   values ('01920000-0000-7000-8000-000000006941', '01920000-0000-7000-8000-0000000069f1',
                           '2026-10-25 14:00:00+00', 'COBRANZA', '01920000-0000-7000-8000-0000000069b1') $$,
                'una visita de cobranza, sin persona, cuelga del depto');
select lives_ok($$ update public.visita set tipo_resultado = 'COBRANZA' where id = '01920000-0000-7000-8000-000000006913' $$,
                'y una visita de antes puede quedar como cobranza');
select set_config('role', 'postgres', true);

select * from finish();
rollback;
