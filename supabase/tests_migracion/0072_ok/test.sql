-- pgTAP · 0072 sobre los datos de antes: los cobros no cambian (salvo las columnas nuevas, todas en null), ni su
-- versión de sync, y lo nuevo anda sobre ellos: la colportora anula uno dentro de plazo y el trigger controla
-- el resto. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

-- Nada se pierde.
select is((select count(*)::int from public.cobranza), 4, 'los 4 cobros siguen, también el dado de baja');
select is((select count(*)::int from public.cobranza c join public.prueba_0072_cobranza s using (id)
            where to_jsonb(c) - 'tarjeta_tipo' - 'tarjeta_marca' - 'numero_aprobacion' - 'referencia_transferencia'
                  - 'banco_origen' - 'ticket_id' - 'anulado_at' - 'motivo_anulacion' is distinct from to_jsonb(s)), 0,
          'los cobros quedaron idénticos (versión de sync, updated_at y xmin_w incluidos) salvo las columnas nuevas');
select is((select count(*)::int from public.cobranza
            where tarjeta_tipo is not null or tarjeta_marca is not null or numero_aprobacion is not null
               or referencia_transferencia is not null or banco_origen is not null or ticket_id is not null
               or anulado_at is not null or motivo_anulacion is not null), 0,
          'y ninguno trae datos de tarjeta, de transferencia, ticket ni anulación: nada se inventa');
select is((select sync_version from public.cobranza where id = '01920000-0000-7000-8000-000000007211'), 1::bigint,
          'el cobro corregido conserva su versión de sync (1): ningún teléfono re-sube nada');

-- Lo nuevo anda sobre los datos de antes. El servidor completa la tarjeta y la transferencia...
update public.cobranza set tarjeta_tipo = 'DEBITO', tarjeta_marca = 'Visa', numero_aprobacion = '123456'
 where id = '01920000-0000-7000-8000-000000007212';
update public.cobranza set referencia_transferencia = '88213', banco_origen = 'BROU'
 where id = '01920000-0000-7000-8000-000000007213';
select is((select tarjeta_marca from public.cobranza where id = '01920000-0000-7000-8000-000000007212'), 'Visa',
          'la tarjeta del cobro de antes guarda su marca');
select is((select banco_origen from public.cobranza where id = '01920000-0000-7000-8000-000000007213'), 'BROU',
          'y la transferencia su banco');
select throws_ok($$ update public.cobranza set tarjeta_marca = 'Visa' where id = '01920000-0000-7000-8000-000000007211' $$,
                 '23514', null, 'pero el efectivo no lleva marca');

-- ...y la colportora anula uno dentro de las 72 h desde el cobro, con la sesión de ella.
update public.cobranza set fecha = now() - interval '2 hours' where id = '01920000-0000-7000-8000-000000007211';
update public.cobranza set fecha = now() - interval '100 hours' where id = '01920000-0000-7000-8000-000000007212';
select set_config('request.jwt.claims', json_build_object('sub', '01920000-0000-7000-8000-0000000072b1', 'role', 'authenticated')::text, true);
select set_config('request.jwt.claim.sub', '01920000-0000-7000-8000-0000000072b1', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select set_config('role', 'authenticated', true);
select lives_ok($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Monto equivocado'
                    where id = '01920000-0000-7000-8000-000000007211' $$, 'anula un cobro de hace 2 h');
select throws_ok($$ update public.cobranza set anulado_at = now(), motivo_anulacion = 'Monto equivocado'
                    where id = '01920000-0000-7000-8000-000000007212' $$, 'CB001', null, 'y no uno de hace 100 h');
select throws_ok($$ update public.cobranza set anulado_at = null, motivo_anulacion = null
                    where id = '01920000-0000-7000-8000-000000007211' $$, 'CB003', null, 'y el anulado no se reabre');

select * from finish();
rollback;
