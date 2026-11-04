-- pgTAP · 0167 sobre los datos de antes: las decisiones que ya había se renombran a los nuevos destinos sin cambiar monto,
-- persona, campaña ni quién decidió; las cuentas, la deuda y los depósitos quedan idénticos (salvo las dos columnas nuevas
-- de la anulación, en null); y con la regla nueva el coordinador devuelve lo que estaba por decidir, que anula los pagos,
-- sin tocar la deuda. Ver scripts/db-test-migracion.sh y datos.sql.
begin;
select * from no_plan();

create or replace function pg_temp.actuar_como(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', p_uid::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config('role', 'authenticated', true);
end $$;
create or replace function pg_temp.actuar_como_servidor() returns void language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);
end $$;

-- --- la foto de antes ----------------------------------------------------------------------------------
select is((select count(*)::int from public.prueba_0167_decision where decision in ('TRASLADAR_A_LA_DEUDA', 'DEJAR_A_FAVOR')), 3,
          'antes de la 0167 las tres decisiones tenían los nombres viejos');
select is((select format('%s|%s', deuda_total, alquiler_trasladado) from public.prueba_0167_cuenta
            where usuario_id = '01920000-0000-7000-8000-0000000167b1'), '50000|50000',
          'y b1 ya había bajado 50000 su deuda');

-- --- las decisiones se renombran -----------------------------------------------------------------------
select is((select count(*)::int from public.alquiler_decision), 3, 'siguen las tres decisiones');
select is((select count(*)::int from public.alquiler_decision where decision in ('TRASLADAR_A_LA_DEUDA', 'DEJAR_A_FAVOR')), 0,
          'ninguna conserva el nombre viejo');
select is((select decision from public.alquiler_decision where id = '01920000-0000-7000-8000-000000016731'),
          'A_CUENTA_PROXIMO_DEPOSITO', 'TRASLADAR_A_LA_DEUDA es ahora A_CUENTA_PROXIMO_DEPOSITO');
select is((select decision from public.alquiler_decision where id = '01920000-0000-7000-8000-000000016732'),
          'SE_LO_QUEDA_EL_COORDINADOR', 'DEJAR_A_FAVOR es ahora SE_LO_QUEDA_EL_COORDINADOR');
select is((select decision from public.alquiler_decision where id = '01920000-0000-7000-8000-000000016733'),
          'SE_LO_QUEDA_EL_COORDINADOR', 'también la de b2');
select is((select count(*)::int from public.alquiler_decision d join public.prueba_0167_decision s using (id)
            where (to_jsonb(d) - 'decision' - 'updated_at' - 'sync_version' - 'xmin_w')
                  is distinct from (to_jsonb(s) - 'decision' - 'updated_at' - 'sync_version' - 'xmin_w')), 0,
          'el resto de cada decisión, idéntico: monto, persona, campaña, quién decidió y cuándo');

-- --- nada se mueve --------------------------------------------------------------------------------------
select is((select count(*)::int from public.cuenta_colportor c join public.prueba_0167_cuenta s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'las cuentas de plata, idénticas (deuda incluida)');
select is((select count(*)::int from public.cuenta_alquiler c join public.prueba_0167_cuenta_alquiler s using (id)
            where to_jsonb(c) is distinct from to_jsonb(s)), 0, 'las cuentas del alquiler, idénticas');
select is((select count(*)::int from public.deposito d join public.prueba_0167_deposito s using (id)
            where (to_jsonb(d) - 'anulado_at' - 'anulado_por') is distinct from to_jsonb(s)), 0,
          'los depósitos, idénticos salvo las dos columnas nuevas');
select is((select count(*)::int from public.deposito where anulado_at is not null or anulado_por is not null), 0,
          'y ninguno quedó anulado');
select is((select format('%s|%s|%s', alquiler_trasladado, alquiler_a_favor, alquiler_por_decidir) from public.cuenta_alquiler
            where usuario_id = '01920000-0000-7000-8000-0000000167b1'), '50000|20000|0',
          'b1: 50000 a cuenta, 20000 que se queda el coordinador, nada por decidir');
select is((select alquiler_por_decidir from public.cuenta_alquiler where usuario_id = '01920000-0000-7000-8000-0000000167b3'),
          20000::bigint, 'b3: sus 20000 siguen por decidir');

-- --- con la regla nueva ----------------------------------------------------------------------------------
select pg_temp.actuar_como('01920000-0000-7000-8000-0000000167c1');
select is((select format('%s|%s|%s', decision, monto_decidido, por_decidir)
             from public.decidir_alquiler_pagado('01920000-0000-7000-8000-0000000167b3', '01920000-0000-7000-8000-0000000167e1',
                                                 'DEVOLVER_AL_COLPORTOR')),
          'DEVOLVER_AL_COLPORTOR|20000|0', 'el coordinador devuelve los 20000 de b3');
select is((select format('%s|%s', ya_estaba, monto_decidido)
             from public.decidir_alquiler_pagado('01920000-0000-7000-8000-0000000167b1', '01920000-0000-7000-8000-0000000167e1',
                                                 'DEVOLVER_AL_COLPORTOR')),
          't|0', 'lo de b1 ya estaba decidido: no hace nada (no se reparte en partes)');
select pg_temp.actuar_como_servidor();
select is((select count(*)::int from public.deposito where anulado_at is not null), 1, 'solo se anuló el pago de b3');
select is((select format('%s|%s', anulado_por, monto) from public.deposito where id = '01920000-0000-7000-8000-000000016723'),
          '01920000-0000-7000-8000-0000000167c1|20000', 'anulado por el coordinador, con su monto intacto');
select is((select format('%s|%s|%s', deuda_total, alquiler_trasladado, dinero_depositado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000167b3'), '100000|0|0',
          'la deuda de b3 no se movió y su Depositado volvió a 0');
select is((select format('%s|%s|%s', deuda_total, alquiler_trasladado, dinero_depositado) from public.cuenta_colportor
            where usuario_id = '01920000-0000-7000-8000-0000000167b1'), '50000|50000|70000',
          'y la de b1 sigue como estaba');

select * from finish();
rollback;
