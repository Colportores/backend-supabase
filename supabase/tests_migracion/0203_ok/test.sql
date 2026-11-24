-- pgTAP · 0203 sobre los datos de antes: los cobros no cambian (salvo la columna nueva, en null), ni su versión de sync, y lo
-- nuevo anda sobre ellos: el coordinador anula con «Otro» y su detalle, la colportora no lo lee, y el cobro anulado antes
-- queda sin anulador (no se inventa). Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde.
select is((select count(*)::int from public.cobranza), 3, 'los 3 cobros siguen, también el dado de baja');
select is((select count(*)::int from public.cobranza c join public.prueba_0203_cobranza s using (id)
            where to_jsonb(c) - 'anulado_por' is distinct from to_jsonb(s)), 0,
          'los cobros quedaron idénticos (versión de sync, updated_at y xmin_w incluidos) salvo la columna nueva');
select is((select count(*)::int from public.cobranza where anulado_por is not null), 0,
          'y ninguno trae anulador: el que anuló la colportora antes no se inventa');
select is((select sync_version from public.cobranza where id = '01920000-0000-7000-8000-000000020312'), 1::bigint,
          'el cobro anulado conserva su versión de sync (1): ningún teléfono baja ni sube nada por esto');
select is((select count(*)::int from public.cobranza_anulacion_detalle), 0, 'la tabla del detalle empieza vacía');

-- Lo nuevo anda sobre los datos de antes: el coordinador anula el cobro vivo con «Otro».
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000203d1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000203d1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);
select lives_ok($$ select public.anular_cobro('01920000-0000-7000-8000-000000020311', 'Otro', 'Cobré de más a otra persona') $$,
                'el coordinador anula el cobro vivo con «Otro» y su detalle');
select throws_ok($$ select public.anular_cobro('01920000-0000-7000-8000-000000020311', 'Otro') $$, '22023', null,
                 'y sin detalle, «Otro» no se acepta, ni sobre uno ya anulado');
select is((select detalle from public.cobranza_anulacion_detalle), 'Cobré de más a otra persona', 'el detalle queda y el coordinador lo lee');
select set_config('role', 'postgres', true);
select is((select anulado_por from public.cobranza where id = '01920000-0000-7000-8000-000000020311'),
          '01920000-0000-7000-8000-0000000203d1'::uuid, 'con el coordinador como quien anuló');

select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000203b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000203b1', true);
select set_config('role', 'authenticated', true);
select is((select count(*)::int from public.cobranza_anulacion_detalle), 0, 'la colportora, dueña del cobro, no lo lee');
select set_config('role', 'postgres', true);
select is((select anulado_por is null and anulado_at is not null from public.cobranza where id = '01920000-0000-7000-8000-000000020312'), true,
          'el anulado de antes sigue sin anulador');

select * from finish();
rollback;
